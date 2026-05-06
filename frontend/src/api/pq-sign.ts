/**
 * pq-sign.ts — client-side post-quantum signing for OmniBus PQ-OMNI wallets.
 *
 * Uses @noble/post-quantum (JS-pure FIPS-204/205/206 implementations) so the
 * browser can produce ML-DSA-87 / Falcon-512 / SLH-DSA-256s signatures
 * without WASM. The matching chain verifier lives in
 * `core/transaction.zig:verifySignature` per scheme byte (codes 5..8).
 *
 * vite.config.ts has optimizeDeps.exclude: ["@noble/post-quantum"] so Vite
 * serves the package as native ESM without pre-bundling — subpath exports
 * resolve correctly in the browser dev server.
 */

import { sha256, sha512 } from "@noble/hashes/sha2";
import { ripemd160 } from "@noble/hashes/legacy";
import { base58 } from "@scure/base";
import { hexToBytes, bytesToHex } from "./exchange-sign";
// eslint-disable-next-line @typescript-eslint/ban-ts-comment
// @ts-ignore — subpath export, resolved by Vite ESM (not pre-bundled)
import { ml_dsa87 } from "@noble/post-quantum/ml-dsa.js";
// eslint-disable-next-line @typescript-eslint/ban-ts-comment
// @ts-ignore
import { falcon512 } from "@noble/post-quantum/falcon.js";
// eslint-disable-next-line @typescript-eslint/ban-ts-comment
// @ts-ignore
import { slh_dsa_sha2_256s } from "@noble/post-quantum/slh-dsa.js";

export type PqScheme = "ml_dsa_87" | "falcon_512" | "dilithium_5" | "slh_dsa_256s";

// eslint-disable-next-line @typescript-eslint/no-explicit-any
let _pqModules: { mlDsa: any; falcon: any; slhDsa: any } | null = null;

async function pqModules() {
  if (_pqModules) return _pqModules;
  _pqModules = { mlDsa: { ml_dsa87 }, falcon: { falcon512 }, slhDsa: { slh_dsa_sha2_256s } };
  return _pqModules;
}

async function signerFor(scheme: PqScheme) {
  const m = await pqModules();
  switch (scheme) {
    case "ml_dsa_87":
    case "dilithium_5":
      return m.mlDsa.ml_dsa87;
    case "falcon_512":
      return m.falcon.falcon512;
    case "slh_dsa_256s":
      return m.slhDsa.slh_dsa_sha2_256s;
  }
}

/**
 * Generate a deterministic PQ keypair from a 32-byte seed. The seed is
 * typically the BIP-32 leaf privkey at the PQ-OMNI account path.
 *
 * Returns a Promise — callers must await. The modules load on first call
 * and are cached for subsequent calls.
 */
/**
 * Canonical seed expansion for PQ keygen — must match the chain side
 * (`core/isolated_wallet.zig:325-432`) and any stress test in
 * `tools/TESTING/`. The rule:
 *
 *   ML-DSA-87 / Dilithium-5  (expected 32 bytes) → sha256(input)
 *   Falcon-512               (expected 48 bytes) → sha512(input)[0..48]
 *   SLH-DSA-256s             (expected 96 bytes) → sha512 counter-mode
 *
 * Apply ALWAYS — even if the caller already passes 32 bytes — so derivation
 * is deterministic across UI, scripts, and chain. Skipping the hash when
 * input length already matches `expected` produced different keys for the
 * same mnemonic in two code paths and stranded test balances on
 * non-canonical addresses.
 */
export async function pqKeypairFromSeed(scheme: PqScheme, seed: Uint8Array): Promise<{
  publicKey: Uint8Array;
  secretKey: Uint8Array;
}> {
  const signer = await signerFor(scheme);
  const expected = (signer as any).lengths?.seed ?? 32;

  let extendedSeed: Uint8Array;
  if (expected === 32) {
    // ML-DSA-87 / Dilithium-5 — single SHA-256 round (deterministic, canon).
    extendedSeed = sha256(seed);
  } else if (expected === 48) {
    // Falcon-512 — first 48 bytes of SHA-512.
    extendedSeed = sha512(seed).slice(0, 48);
  } else {
    // SLH-DSA-256s (96 bytes) — counter-mode SHA-512 expansion.
    extendedSeed = new Uint8Array(expected);
    let off = 0;
    let counter = 0;
    while (off < expected) {
      const counterBuf = new Uint8Array(seed.length + 1);
      counterBuf.set(seed);
      counterBuf[seed.length] = counter++;
      const block = sha512(counterBuf);
      const take = Math.min(block.length, expected - off);
      extendedSeed.set(block.slice(0, take), off);
      off += take;
    }
  }

  const kp = signer.keygen(extendedSeed);
  return {
    publicKey: kp.publicKey as Uint8Array,
    secretKey: kp.secretKey as Uint8Array,
  };
}

/** Sign an arbitrary message hash with the given PQ scheme. */
export async function pqSign(scheme: PqScheme, secretKey: Uint8Array, msgHash: Uint8Array): Promise<Uint8Array> {
  const signer = await signerFor(scheme);
  return signer.sign(msgHash, secretKey) as Uint8Array;
}

/** Verify a PQ signature. */
export async function pqVerify(scheme: PqScheme, publicKey: Uint8Array, msgHash: Uint8Array, signature: Uint8Array): Promise<boolean> {
  const signer = await signerFor(scheme);
  return signer.verify(signature, msgHash, publicKey);
}

/**
 * Recompute the PQ-OMNI address from a PQ public key.
 * Synchronous — uses only @noble/hashes which Vite resolves fine.
 */
export function pqAddressFromPublicKey(scheme: PqScheme, publicKey: Uint8Array): string {
  // Canon — must match core/transaction.zig:180-201 + core/isolated_wallet.zig:64-67.
  // obs3_ = Dilithium-5, obd5_ = SLH-DSA-256s. Do NOT swap without updating chain code.
  const prefix = ({
    ml_dsa_87:    "obk1_",
    falcon_512:   "obf5_",
    dilithium_5:  "obs3_",
    slh_dsa_256s: "obd5_",
  } as Record<PqScheme, string>)[scheme];
  const h160 = ripemd160(sha256(publicKey));
  const versioned = new Uint8Array(1 + h160.length);
  versioned[0] = 0x4f;
  versioned.set(h160, 1);
  const checksum = sha256(sha256(versioned)).slice(0, 4);
  const full = new Uint8Array(versioned.length + 4);
  full.set(versioned);
  full.set(checksum, versioned.length);
  return prefix + base58.encode(full);
}

/**
 * Build the canonical TX hash — same recipe as core/transaction.zig:calculateHash().
 *
 * CRITICAL ALIGNMENT (verified live 2026-05-06 via stress-test.mjs):
 *   1. Chain hashes `self.public_key` which is the HEX STRING stored in
 *      tx.public_key (rpc_server.zig:10713 sets it from extractStr "public_key").
 *      So we MUST hash the hex form, NOT raw bytes.
 *   2. Chain finalises with SHA-256d (double): `Crypto.sha256(sha256_state)`
 *      at transaction.zig:417. We must do the same.
 *   3. `publicKeyBytes` legacy param still accepted — converts to hex internally.
 */
export function buildTxHash(args: {
  id: number | bigint;
  from: string;
  to: string;
  amount: number | bigint;
  timestamp: number | bigint;
  nonce: number | bigint;
  schemeCode: number;
  publicKeyBytes?: Uint8Array;
  publicKeyHex?: string;
  fee?: number | bigint;
  locktime?: number | bigint;
  opReturn?: string;
}): Uint8Array {
  const enc = new TextEncoder();
  const parts: Uint8Array[] = [];
  const push = (s: string) => parts.push(enc.encode(s));
  push(String(args.id));
  push(":");
  push(args.from);
  push(":");
  push(args.to);
  push(":");
  push(String(args.amount));
  push(":");
  push(String(args.timestamp));
  push(":");
  push(String(args.nonce));
  if (args.schemeCode !== 0) {
    push(":SC:");
    push(String(args.schemeCode));
  }
  // Public key MUST be hashed as hex string (matches chain's tx.public_key).
  let pubHex = args.publicKeyHex;
  if (!pubHex && args.publicKeyBytes && args.publicKeyBytes.length > 0) {
    pubHex = bytesToHex(args.publicKeyBytes);
  }
  if (pubHex && pubHex.length > 0) {
    push(":PK:");
    push(pubHex);
  }
  if (args.fee && BigInt(args.fee) > 0n) {
    push(":");
    push(String(args.fee));
  }
  if (args.locktime && BigInt(args.locktime) > 0n) {
    push(":");
    push(`lt${String(args.locktime)}`);
  }
  if (args.opReturn && args.opReturn.length > 0) {
    push(":OP:");
    push(args.opReturn);
  }
  const total = parts.reduce((n, p) => n + p.length, 0);
  const buf = new Uint8Array(total);
  let off = 0;
  for (const p of parts) { buf.set(p, off); off += p.length; }
  // SHA-256d (double) — chain does Crypto.sha256(sha256_state) at transaction.zig:417
  return sha256(sha256(buf));
}

export { hexToBytes, bytesToHex };
