#!/usr/bin/env node
/**
 * pq-paritate-noble-vs-liboqs.mjs
 *
 * Goal: definitively answer whether @noble/post-quantum signatures verify
 * under chain's liboqs OQS_SIG_verify.
 *
 * For each of {ML-DSA-87, Falcon-512, SLH-DSA-256s}:
 *   1. noble keygen → (pk, sk)
 *   2. noble self-verify a sig over a fixed message  (sanity)
 *   3. send (pk, msg, sig) to chain `pq_verify_test` RPC → liboqs verifies
 *
 * If step 3 returns verified:true → libraries interoperate. If false →
 * sig framing differs (context byte / domain sep / variant mismatch).
 *
 * Usage:
 *   node pq-paritate-noble-vs-liboqs.mjs --rpc https://omnibusblockchain.cc:8443/api-testnet
 */

import { ml_dsa87 }          from "@noble/post-quantum/ml-dsa.js";
import { falcon512 }         from "@noble/post-quantum/falcon.js";
import { slh_dsa_sha2_256s } from "@noble/post-quantum/slh-dsa.js";

let RPC = "http://localhost:18332";
const argv = process.argv.slice(2);
for (let i = 0; i < argv.length; i++) if (argv[i] === "--rpc") RPC = argv[++i];

async function rpc(method, params) {
  const r = await fetch(RPC, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", method, params, id: Date.now() }),
  });
  return r.json();
}

const toHex = (b) => Array.from(b).map(x => x.toString(16).padStart(2, "0")).join("");

const SCHEMES = [
  { name: "ml_dsa_87",    lib: ml_dsa87,           seedLen: 32 },
  { name: "falcon_512",   lib: falcon512,          seedLen: 48 },
  { name: "slh_dsa_256s", lib: slh_dsa_sha2_256s,  seedLen: 96 },
];

console.log("=".repeat(70));
console.log("PQ paritate — noble (frontend) ↔ liboqs (chain)");
console.log("=".repeat(70));
console.log("RPC:", RPC);

const tip = await rpc("getblockcount", []);
console.log("Chain tip:", tip?.result ?? "?");
console.log();

let pass = 0, fail = 0;

for (const s of SCHEMES) {
  console.log(`── ${s.name} ────────────────────────────────────────`);

  // Deterministic seed for reproducibility
  const seed = new Uint8Array(s.seedLen);
  for (let i = 0; i < seed.length; i++) seed[i] = (i * 7 + 13) & 0xff;

  const kp = s.lib.keygen(seed);
  const msg = new TextEncoder().encode(`paritate test for ${s.name}`);
  const sig = s.lib.sign(msg, kp.secretKey);

  console.log(`  pk: ${kp.publicKey.length} bytes`);
  console.log(`  sk: ${kp.secretKey.length} bytes`);
  console.log(`  msg: ${msg.length} bytes`);
  console.log(`  sig: ${sig.length} bytes`);

  // noble API: verify(sig, msg, publicKey)  — sig FIRST!
  const nobleSelf = s.lib.verify(sig, msg, kp.publicKey);
  console.log(`  noble.verify(...)         : ${nobleSelf ? "✓ true" : "✗ false"}`);
  if (!nobleSelf) {
    fail++;
    console.log(`  → noble's own verify failed; library is broken. Skipping chain test.`);
    console.log();
    continue;
  }

  const r = await rpc("pq_verify_test", [{
    scheme:     s.name,
    public_key: toHex(kp.publicKey),
    message:    toHex(msg),
    signature:  toHex(sig),
  }]);

  if (r.error) {
    console.log(`  liboqs.verify(...)        : ✗ RPC error — ${r.error.message}`);
    fail++;
  } else {
    const ok = r.result?.verified === true;
    console.log(`  liboqs.verify(...)        : ${ok ? "✓ true" : "✗ false"}  (chain reported ${JSON.stringify(r.result)})`);
    if (ok) pass++; else fail++;
  }
  console.log();
}

console.log("=".repeat(70));
console.log(`RESULT: ${pass}/${SCHEMES.length} schemes interoperate noble ↔ liboqs`);
console.log("=".repeat(70));
process.exit(fail === 0 ? 0 : 1);
