/**
 * exchange-sign.ts — client-side ECDSA signing for OmniBus DEX RPC.
 *
 * Server (rpc_server.zig: handleExchangePlaceOrder / handleExchangeCancelOrder)
 * verifies these exact canonical messages with secp256k1 + SHA256d.
 * Keep formats in sync — change here AND in rpc_server.zig.
 */

import { sign, getPublicKey } from "@noble/secp256k1";
import { sha256 } from "@noble/hashes/sha2";
import { ripemd160 } from "@noble/hashes/legacy";
import { bech32 } from "@scure/base";

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
