// PQ paritate test: noble signs, RPC verifies via pq_verify_test
// Goal: prove that liboqs backend accepts @noble/post-quantum signatures
import { ml_dsa87 }      from "@noble/post-quantum/ml-dsa.js";
import { falcon512 }     from "@noble/post-quantum/falcon.js";
import { slh_dsa_sha2_256s } from "@noble/post-quantum/slh-dsa.js";
import { sha256 }        from "@noble/hashes/sha2.js";

const RPC = process.argv[2] || "http://localhost:8332";

async function rpc(method, params = []) {
  const r = await fetch(RPC, {
    method: "POST", headers: { "Content-Type": "application/json" },
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
console.log("RPC:", RPC);
const info = await rpc("getblockchaininfo");
console.log("Chain tip:", info.result?.blocks ?? "?");
console.log();

let pass = 0, fail = 0;
for (const t of tests) {
  // Build seed of correct length
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

  // Try RPC pq_verify (if exists in our chain)
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
