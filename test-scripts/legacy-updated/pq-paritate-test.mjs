#!/usr/bin/env node
/**
 * pq-paritate-test.mjs — noble signs, RPC verifies via pq_verify (multi-chain).
 *
 * Updated 2026-05-10: --chain flag, public-VPS endpoints, bearer token.
 *
 * Goal: prove that the liboqs (or pure-Zig) backend accepts @noble/post-quantum
 * signatures across schemes ML-DSA-87, Falcon-512, SLH-DSA-256s.
 *
 * Usage:
 *   node pq-paritate-test.mjs                                # mainnet
 *   node pq-paritate-test.mjs --chain testnet
 *   node pq-paritate-test.mjs --chain regtest
 *   node pq-paritate-test.mjs --rpc http://localhost:8332
 */

import { ml_dsa87 }      from "@noble/post-quantum/ml-dsa.js";
import { falcon512 }     from "@noble/post-quantum/falcon.js";
import { slh_dsa_sha2_256s } from "@noble/post-quantum/slh-dsa.js";
import { sha256 }        from "@noble/hashes/sha2.js";

const RPC_URLS = {
  mainnet: "https://omnibusblockchain.cc:8443/api-mainnet",
  testnet: "https://omnibusblockchain.cc:8443/api-testnet",
  regtest: "https://omnibusblockchain.cc:8443/api-regtest",
  "local-mainnet": "http://localhost:8332",
  "local-testnet": "http://localhost:18332",
  "local-regtest": "http://localhost:28332",
};

const args = process.argv.slice(2);
function arg(name, fb) {
  const i = args.indexOf(name);
  return i >= 0 && args[i + 1] ? args[i + 1] : fb;
}
const CHAIN   = arg("--chain", process.env.CHAIN || "testnet");
const RPC_OVR = arg("--rpc",   process.env.RPC_URL);
const TOKEN   = arg("--token", process.env.OMNIBUS_RPC_TOKEN);
// Backward-compat: if first positional arg is a URL, treat as RPC override.
const POS_URL = args.find(a => a.startsWith("http://") || a.startsWith("https://"));
const RPC = POS_URL || RPC_OVR || RPC_URLS[CHAIN] || RPC_URLS.testnet;

async function rpc(method, params = []) {
  const headers = { "Content-Type": "application/json" };
  if (TOKEN) headers.Authorization = `Bearer ${TOKEN}`;
  const r = await fetch(RPC, {
    method: "POST", headers,
    body: JSON.stringify({ jsonrpc: "2.0", method, params, id: Date.now() }),
  });
  return r.json();
}

const bytesToHex = (b) => Array.from(b).map(x => x.toString(16).padStart(2, "0")).join("");

const tests = [
  { name: "ml_dsa_87",     lib: ml_dsa87,           seed_len: 32, scheme_code: 1 },
  { name: "falcon_512",    lib: falcon512,          seed_len: 48, scheme_code: 2 },
  { name: "slh_dsa_256s",  lib: slh_dsa_sha2_256s,  seed_len: 96, scheme_code: 3 },
];

console.log("PQ paritate: noble (frontend) → liboqs (backend) verify");
console.log(`Chain: ${CHAIN}`);
console.log(`RPC:   ${RPC}`);
console.log(`Auth:  ${TOKEN ? "Bearer (set)" : "none"}`);
const info = await rpc("getblockchaininfo");
console.log("Chain tip:", info.result?.blocks ?? "?");
console.log();

let pass = 0, fail = 0;
for (const t of tests) {
  const base = sha256(new TextEncoder().encode(`pq-test-${t.name}`));
  const seed = new Uint8Array(t.seed_len);
  for (let i = 0; i < t.seed_len; i += 32) {
    const chunk = sha256(new Uint8Array([...base, i / 32]));
    seed.set(chunk.slice(0, Math.min(32, t.seed_len - i)), i);
  }
  const kp = t.lib.keygen(seed);
  const msg = new TextEncoder().encode(`hello ${t.name} from noble`);
  const sig = t.lib.sign(kp.secretKey, msg);
  const noble_ok = t.lib.verify(kp.publicKey, msg, sig);
  console.log(`${t.name}:`);
  console.log(`  pubkey: ${kp.publicKey.length} bytes`);
  console.log(`  sig:    ${sig.length} bytes`);
  console.log(`  noble self-verify: ${noble_ok ? "✓" : "✗"}`);

  if (!noble_ok) { fail++; continue; }

  const verify_result = await rpc("pq_verify", [
    t.scheme_code,
    bytesToHex(kp.publicKey),
    bytesToHex(msg),
    bytesToHex(sig),
  ]);
  if (verify_result.error) {
    console.log(`  RPC pq_verify: ERROR - ${verify_result.error.message}`);
    fail++;
  } else {
    const ok = verify_result.result === true || verify_result.result === "ok";
    console.log(`  RPC pq_verify: ${ok ? "✓ liboqs accepted noble sig" : "✗ liboqs rejected noble sig"}`);
    if (ok) pass++; else fail++;
  }
  console.log();
}

console.log(`Result: ${pass}/${tests.length} liboqs accepts noble signatures`);
process.exit(fail === 0 ? 0 : 1);
