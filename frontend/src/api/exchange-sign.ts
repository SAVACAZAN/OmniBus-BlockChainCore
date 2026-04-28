/**
 * exchange-sign.ts — client-side ECDSA signing for OmniBus DEX RPC.
 *
 * Server (rpc_server.zig: handleExchangePlaceOrder / handleExchangeCancelOrder)
 * verifies these exact canonical messages with secp256k1 + SHA256d.
 * Keep formats in sync — change here AND in rpc_server.zig.
 */

import * as secp from "@noble/secp256k1";
import { sha256 } from "@noble/hashes/sha2";
import { hmac } from "@noble/hashes/hmac";
import { ripemd160 } from "@noble/hashes/legacy";
import { bech32 } from "@scure/base";

const { sign, getPublicKey } = secp;

// noble/secp256k1 v2 needs an HMAC implementation registered for the
// RFC6979 deterministic-k path. We wire the noble HMAC-SHA256 once at
// module load. Without this `sign()` throws "hashes.hmacSha256Sync not set".
const sAny: any = secp;
if (sAny?.etc && !sAny.etc.hmacSha256Sync) {
  sAny.etc.hmacSha256Sync = (key: Uint8Array, ...messages: Uint8Array[]) =>
    hmac(sha256, key, concatBytes(...messages));
}
if (sAny?.utils && !sAny.utils.hmacSha256Sync) {
  // older API surface
  sAny.utils.hmacSha256Sync = (key: Uint8Array, ...messages: Uint8Array[]) =>
    hmac(sha256, key, concatBytes(...messages));
}

function concatBytes(...arrays: Uint8Array[]): Uint8Array {
  let total = 0;
  for (const a of arrays) total += a.length;
  const out = new Uint8Array(total);
  let off = 0;
  for (const a of arrays) {
    out.set(a, off);
    off += a.length;
  }
  return out;
}

/**
 * Sign a placeOrder payload. Canonical message must match
 * `buildOrderSignMessage` in rpc_server.zig exactly:
 *   "EXCHANGE_ORDER_V1\n<side>\n<pairId>\n<price>\n<amount>\n<nonce>\n<trader>"
 */
export function signPlaceOrderPayload(args: {
  privateKeyHex: string;
  trader: string;
  side: "buy" | "sell";
  pairId: number;
  priceMicroUsd: number;
  amountSat: number;
  nonce: number;
}): { signature: string; publicKey: string } {
  const msg =
    `EXCHANGE_ORDER_V1\n${args.side}\n${args.pairId}\n${args.priceMicroUsd}\n` +
    `${args.amountSat}\n${args.nonce}\n${args.trader}`;
  return signMessage(args.privateKeyHex, msg);
}

/**
 * Sign a cancelOrder payload. Canonical:
 *   "EXCHANGE_CANCEL_V1\n<orderId>\n<nonce>\n<trader>"
 */
export function signCancelOrderPayload(args: {
  privateKeyHex: string;
  orderId: number;
  trader: string;
  nonce: number;
}): { signature: string; publicKey: string } {
  const msg = `EXCHANGE_CANCEL_V1\n${args.orderId}\n${args.nonce}\n${args.trader}`;
  return signMessage(args.privateKeyHex, msg);
}

/**
 * Sign the login challenge string returned by `exchange_getAuthNonce`.
 * Canonical (built server-side too): "OmniBus Exchange Login: <nonceHex>"
 */
export function signLoginChallenge(args: {
  privateKeyHex: string;
  nonceHex: string;
}): { signature: string; publicKey: string } {
  return signMessage(args.privateKeyHex, `OmniBus Exchange Login: ${args.nonceHex}`);
}

export function signCreateApiKeyPayload(args: {
  privateKeyHex: string;
  name: string;
  owner: string;
  nonce: number;
}): { signature: string; publicKey: string } {
  const msg = `EXCHANGE_APIKEY_V1\n${args.name}\n${args.owner}\n${args.nonce}`;
  return signMessage(args.privateKeyHex, msg);
}

export function signRevokeApiKeyPayload(args: {
  privateKeyHex: string;
  keyId: string;
  owner: string;
  nonce: number;
}): { signature: string; publicKey: string } {
  const msg = `EXCHANGE_APIKEY_REVOKE_V1\n${args.keyId}\n${args.owner}\n${args.nonce}`;
  return signMessage(args.privateKeyHex, msg);
}

export function signDepositPayload(args: {
  privateKeyHex: string;
  owner: string;
  token: string;
  amount: number;
  nonce: number;
}): { signature: string; publicKey: string } {
  const msg = `EXCHANGE_DEPOSIT_V1\n${args.owner}\n${args.token}\n${args.amount}\n${args.nonce}`;
  return signMessage(args.privateKeyHex, msg);
}

export function signWithdrawPayload(args: {
  privateKeyHex: string;
  owner: string;
  token: string;
  amount: number;
  nonce: number;
}): { signature: string; publicKey: string } {
  const msg = `EXCHANGE_WITHDRAW_V1\n${args.owner}\n${args.token}\n${args.amount}\n${args.nonce}`;
  return signMessage(args.privateKeyHex, msg);
}

/**
 * ECDSA secp256k1 signer — the chain verify path uses
 * `EcdsaSecp256k1Sha256oSha256` which prehashes with SHA256d. We pre-hash
 * here too and pass `prehash:false` so noble does not double-hash.
 */
function signMessage(privKeyHex: string, msg: string): {
  signature: string;
  publicKey: string;
} {
  if (privKeyHex.startsWith("0x")) privKeyHex = privKeyHex.slice(2);
  if (privKeyHex.length !== 64) throw new Error("private key must be 32 bytes hex");
  const priv = hexToBytes(privKeyHex);
  const msgBytes = new TextEncoder().encode(msg);

  // SHA256(SHA256(msg)) — Bitcoin/OmniBus convention
  const h1 = sha256(msgBytes);
  const h2 = sha256(h1);

  // noble/secp256k1 v2: sign() takes a *message hash* (not raw message) so
  // we feed h2 directly. lowS=true normalizes (s ≤ n/2) — prevents
  // malleability and matches Bitcoin convention.
  const sig = sign(h2, priv, { lowS: true });
  const sigBytes = sig.toBytes(); // 64 bytes compact (r || s)
  const pub = getPublicKey(priv, true); // 33 bytes compressed

  return {
    signature: bytesToHex(sigBytes),
    publicKey: bytesToHex(pub),
  };
}

/**
 * Derive the OmniBus native address (ob1q…) from a compressed public key.
 * Hash160 (SHA256 + RIPEMD160), bech32 with HRP "ob", witness version 0.
 * Matches `bech32_mod.encodeOBAddress` in core/bech32.zig.
 */
export function deriveOBAddress(publicKeyHex: string): string {
  const pub = hexToBytes(publicKeyHex);
  if (pub.length !== 33) throw new Error("public key must be 33 bytes compressed");
  const h160 = ripemd160(sha256(pub));
  const words = bech32.toWords(h160);
  const versioned = [0, ...words];
  return bech32.encode("ob", versioned);
}

/**
 * Derive both compressed pubkey and ob1q address from a private-key hex.
 * Convenience for the keystore unlock UX.
 */
export function deriveAddressFromPrivKey(privKeyHex: string): {
  publicKey: string;
  address: string;
} {
  if (privKeyHex.startsWith("0x")) privKeyHex = privKeyHex.slice(2);
  const priv = hexToBytes(privKeyHex);
  const pub = getPublicKey(priv, true);
  const pubHex = bytesToHex(pub);
  return { publicKey: pubHex, address: deriveOBAddress(pubHex) };
}

// ── hex helpers ──────────────────────────────────────────────────────
export function hexToBytes(hex: string): Uint8Array {
  if (hex.startsWith("0x")) hex = hex.slice(2);
  if (hex.length % 2 !== 0) throw new Error("odd-length hex");
  const out = new Uint8Array(hex.length / 2);
  for (let i = 0; i < out.length; i++) {
    out[i] = parseInt(hex.substr(i * 2, 2), 16);
  }
  return out;
}

export function bytesToHex(bytes: Uint8Array): string {
  return Array.from(bytes)
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}
