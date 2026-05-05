/**
 * pq-sign.ts — client-side post-quantum signing for OmniBus PQ-OMNI wallets.
 *
 * Uses @noble/post-quantum (JS-pure FIPS-204/205/206 implementations) so the
 * browser can produce ML-DSA-87 / Falcon-512 / SLH-DSA-256s signatures
 * without WASM. The matching chain verifier lives in
 * `core/transaction.zig:verifySignature` per scheme byte (codes 5..8).
 *
 * Each PQ-OMNI scheme derives its keys deterministically from the BIP-32
 * leaf privkey at the matching account path (m/44'/777'/5'..8'/0/N). The
 * leaf privkey acts as a 32-byte seed fed into the scheme's keypair
 * generator — same entropy bound as the BTC-compatible OMNI key, but
 * stretched into the much larger PQ key material.
 *
 * Phase-1 frontend used the secp256k1 leaf pubkey as a "fingerprint" hashed
 * into the address. Phase 3 (this module) replaces that placeholder with
 * the actual PQ pubkey hashed into the address — so addresses remain stable
 * for any user who upgrades, the address recipe just changes which bytes
 * are hashed.
 */

import { ml_dsa87 } from "@noble/post-quantum/ml-dsa";
import { falcon512 } from "@noble/post-quantum/falcon";
import { slh_dsa_sha2_256s } from "@noble/post-quantum/slh-dsa";
import { sha256, sha512 } from "@noble/hashes/sha2";
import { ripemd160 } from "@noble/hashes/legacy";
import { base58 } from "@scure/base";
import { hexToBytes, bytesToHex } from "./exchange-sign";

export type PqScheme = "ml_dsa_87" | "falcon_512" | "dilithium_5" | "slh_dsa_256s";

/**
 * Map UI scheme name → @noble/post-quantum signer instance. dilithium_5 is
 * an alias for ML-DSA-87 (FIPS 204 renamed Dilithium); we keep two distinct
 * scheme codes on chain so users can pick either label, but the math is
 * identical.
 */
function signerFor(scheme: PqScheme) {
  switch (scheme) {
    case "ml_dsa_87":
    case "dilithium_5":
      return ml_dsa87;
    case "falcon_512":
      return falcon512;
    case "slh_dsa_256s":
      return slh_dsa_sha2_256s;
  }
}

/**
 * Generate a deterministic PQ keypair from a 32-byte seed. The seed is
 * typically the BIP-32 leaf privkey at the PQ-OMNI account path.
 *
 * @noble/post-quantum's `keygen()` accepts a seed of the right length for
 * each scheme. ml_dsa87 + slh_dsa want 32 bytes; falcon512 wants 48. We
 * stretch the seed via SHA-512 when needed so callers always pass 32 bytes.
 */
export function pqKeypairFromSeed(scheme: PqScheme, seed: Uint8Array): {
  publicKey: Uint8Array;
  secretKey: Uint8Array;
} {
  const signer = signerFor(scheme);
  // Stretch 32-byte seed to whatever the scheme's keygen expects.
  let extendedSeed = seed;
  // signer.lengths.seed is the required seed length per @noble API.
  const expected = (signer as any).lengths?.seed ?? 32;
  if (seed.length !== expected) {
    if (expected === 48) {
      // Falcon needs 48 bytes — stretch via SHA-512 (first 48 bytes).
      extendedSeed = sha512(seed).slice(0, 48);
    } else if (expected === 32) {
      extendedSeed = sha256(seed).slice(0, 32);
    } else {
      // Larger seed needed — concatenate sha512 outputs.
      const out = new Uint8Array(expected);
      let off = 0;
      let counter = 0;
      while (off < expected) {
        const counterBuf = new Uint8Array(seed.length + 1);
        counterBuf.set(seed);
        counterBuf[seed.length] = counter++;
        const block = sha512(counterBuf);
        const take = Math.min(block.length, expected - off);
        out.set(block.slice(0, take), off);
        off += take;
      }
      extendedSeed = out;
    }
  }
  const kp = signer.keygen(extendedSeed);
  return {
    publicKey: kp.publicKey as Uint8Array,
    secretKey: kp.secretKey as Uint8Array,
  };
}

/** Sign an arbitrary message hash with the given PQ scheme. */
export function pqSign(scheme: PqScheme, secretKey: Uint8Array, msgHash: Uint8Array): Uint8Array {
  const signer = signerFor(scheme);
  return signer.sign(msgHash, secretKey) as Uint8Array;
}

/** Verify a PQ signature — useful for round-trip tests in the browser
 *  before sending the TX to chain. */
export function pqVerify(scheme: PqScheme, publicKey: Uint8Array, msgHash: Uint8Array, signature: Uint8Array): boolean {
  const signer = signerFor(scheme);
  return signer.verify(signature, msgHash, publicKey);
}

/**
 * Recompute the PQ-OMNI address recipe with REAL PQ pubkey bytes (not the
 * Phase-1 secp256k1 fingerprint). Same hash160 + base58check + prefix as
 * the chain's `core/isolated_wallet.zig:deriveLegacyAddress`. Keeps the
 * address format identical so existing balances on the Phase-1 placeholder
 * address stay reachable.
 */
export function pqAddressFromPublicKey(scheme: PqScheme, publicKey: Uint8Array): string {
  const prefix = ({
    ml_dsa_87: "ob_q1_",
    falcon_512: "ob_q2_",
    dilithium_5: "ob_q3_",
    slh_dsa_256s: "ob_q4_",
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
 * Build the canonical TX hash used by chain verifiers — same recipe as
 * `core/transaction.zig:calculateHash()`. SHA-256 of the colon-joined
 * fields, with optional sections appended only when present (so legacy
 * v1 TXs hash the same way they always did).
 */
export function buildTxHash(args: {
  id: number | bigint;
  from: string;
  to: string;
  amount: number | bigint;
  timestamp: number | bigint;
  nonce: number | bigint;
  schemeCode: number; // 0 = omni_ecdsa, 5..8 = PQ-OMNI
  publicKeyBytes?: Uint8Array; // PQ pubkey, mixed in when scheme != 0
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
  if (args.publicKeyBytes && args.publicKeyBytes.length > 0) {
    push(":PK:");
    parts.push(args.publicKeyBytes);
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
  return sha256(buf);
}

/** Helper that re-exports both byte conversion utilities for convenience. */
export { hexToBytes, bytesToHex };
