/**
 * pq-sign.ts — client-side post-quantum signing for OmniBus PQ-OMNI wallets.
 *
 * Uses @noble/post-quantum (JS-pure FIPS-204/205/206 implementations) so the
 * browser can produce ML-DSA-87 / Falcon-512 / SLH-DSA-256s signatures
 * without WASM. The matching chain verifier lives in
 * `core/transaction.zig:verifySignature` per scheme byte (codes 5..8).
 *
 * Vite 4 cannot statically resolve this package's subpath exports.
 * We load them lazily via base64-decoded dynamic imports so the esbuild
 * scanner never sees the module specifier strings.
 */

import { sha256, sha512 } from "@noble/hashes/sha2";
import { ripemd160 } from "@noble/hashes/legacy";
import { base58 } from "@scure/base";
import { hexToBytes, bytesToHex } from "./exchange-sign";

export type PqScheme = "ml_dsa_87" | "falcon_512" | "dilithium_5" | "slh_dsa_256s";

// Lazy-loaded module cache — populated on first call to pqKeypairFromSeed.
// eslint-disable-next-line @typescript-eslint/no-explicit-any
let _pqModules: { mlDsa: any; falcon: any; slhDsa: any } | null = null;

// Vite 4 esbuild scanner finds strings in comments too. Base64-encoded:
// ml-dsa.js = QG5vYmxlL3Bvc3QtcXVhbnR1bS9tbC1kc2EuanM=
// falcon.js  = QG5vYmxlL3Bvc3QtcXVhbnR1bS9mYWxjb24uanM=
// slh-dsa.js = QG5vYmxlL3Bvc3QtcXVhbnR1bS9zbGgtZHNhLmpz
const _dynImport = new Function("p", "return import(p)") as (p: string) => Promise<any>;
const _ML_DSA_PATH  = atob("QG5vYmxlL3Bvc3QtcXVhbnR1bS9tbC1kc2EuanM=");
const _FALCON_PATH  = atob("QG5vYmxlL3Bvc3QtcXVhbnR1bS9mYWxjb24uanM=");
const _SLH_DSA_PATH = atob("QG5vYmxlL3Bvc3QtcXVhbnR1bS9zbGgtZHNhLmpz");

async function pqModules() {
  if (_pqModules) return _pqModules;
  const [ml, fa, sl] = await Promise.all([
    _dynImport(_ML_DSA_PATH),
    _dynImport(_FALCON_PATH),
    _dynImport(_SLH_DSA_PATH),
  ]);
  _pqModules = { mlDsa: ml, falcon: fa, slhDsa: sl };
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
export async function pqKeypairFromSeed(scheme: PqScheme, seed: Uint8Array): Promise<{
  publicKey: Uint8Array;
  secretKey: Uint8Array;
}> {
  const signer = await signerFor(scheme);
  let extendedSeed = seed;
  const expected = (signer as any).lengths?.seed ?? 32;
  if (seed.length !== expected) {
    if (expected === 48) {
      extendedSeed = sha512(seed).slice(0, 48);
    } else if (expected === 32) {
      extendedSeed = sha256(seed).slice(0, 32);
    } else {
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
 * Build the canonical TX hash — same recipe as core/transaction.zig:calculateHash().
 * Synchronous.
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

export { hexToBytes, bytesToHex };
