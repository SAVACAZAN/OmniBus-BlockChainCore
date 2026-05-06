#!/usr/bin/env node
/**
 * pq-tx-roundtrip.mjs
 *
 * Tests the full TX path:
 *   1. Build TX with same params we'd send via pq_send
 *   2. Compute tx_hash JS-side via buildTxHash()
 *   3. Sign tx_hash with noble
 *   4. Submit to pq_verify_test (bypasses chain TX reconstruction):
 *        verify(scheme, pubkey, tx_hash, sig)  → must be TRUE
 *   5. Submit to pq_send  → if FALSE, chain reconstructs tx_hash differently.
 *
 * Compares: does pq_verify_test pass? does pq_send pass with same data?
 *
 *   ✓ + ✓  = pipeline ok
 *   ✓ + ✗  = chain TX hash recipe differs from JS buildTxHash
 *   ✗ + ✗  = library mismatch
 */

import { ml_dsa87 } from "@noble/post-quantum/ml-dsa.js";
import { sha256, sha512 } from "@noble/hashes/sha2.js";
import { ripemd160 }      from "@noble/hashes/legacy.js";
import { HDKey }          from "@scure/bip32";
import { mnemonicToSeedSync } from "@scure/bip39";
import { base58 }         from "@scure/base";

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

const TEST_MNEMONIC =
  "abandon abandon abandon abandon abandon abandon abandon abandon " +
  "abandon abandon abandon about";

// Derive ML-DSA keypair from BIP-44 m/44'/777'/5'/0/0
const seed = mnemonicToSeedSync(TEST_MNEMONIC);
const root = HDKey.fromMasterSeed(seed);
const child = root.derive("m/44'/777'/5'/0/0");
const pqSeed = sha256(child.privateKey);  // 32 bytes
const kp = ml_dsa87.keygen(pqSeed);

// Recompute address with prefix obk1_ (canon ML-DSA)
const h160 = ripemd160(sha256(kp.publicKey));
const versioned = new Uint8Array(21);
versioned[0] = 0x4f;
versioned.set(h160, 1);
const checksum = sha256(sha256(versioned)).slice(0, 4);
const full = new Uint8Array(25);
full.set(versioned);
full.set(checksum, 21);
const fromAddr = "obk1_" + base58.encode(full);

const toAddr = "ob1qw6zhsqg29aht23fksk5w54lkgavatpgltqxlvl";  // ECDSA primary

console.log("From  :", fromAddr);
console.log("To    :", toAddr);
console.log("PK len:", kp.publicKey.length);
console.log();

// Get nonce
const nr = await rpc("getnonce", [fromAddr]);
const nonce = (typeof nr.result === "object" ? nr.result.nonce : nr.result) || 0;

// Build tx_hash exactly per chain calculateHash() recipe
function buildTxHash({ id, from, to, amount, timestamp, nonce, schemeCode, publicKeyHex, fee }) {
  const enc = new TextEncoder();
  const parts = [];
  const push = (s) => parts.push(enc.encode(s));
  push(String(id)); push(":");
  push(from); push(":");
  push(to); push(":");
  push(String(amount)); push(":");
  push(String(timestamp)); push(":");
  push(String(nonce));
  if (schemeCode !== 0) { push(":SC:"); push(String(schemeCode)); }
  if (publicKeyHex && publicKeyHex.length > 0) { push(":PK:"); push(publicKeyHex); }
  if (fee && fee > 0) { push(":"); push(String(fee)); }
  const total = parts.reduce((n, p) => n + p.length, 0);
  const buf = new Uint8Array(total);
  let off = 0;
  for (const p of parts) { buf.set(p, off); off += p.length; }
  return sha256(sha256(buf));   // SHA-256d
}

const txId     = 12345;        // fixed for reproducibility
const timestamp= Math.floor(Date.now() / 1000);
const fee      = 1;
const amount   = 1000;
const schemeCode = 5;
const pubHex   = toHex(kp.publicKey);

const txHash = buildTxHash({
  id: txId, from: fromAddr, to: toAddr, amount,
  timestamp, nonce, schemeCode, publicKeyHex: pubHex, fee,
});

console.log("tx_hash JS :", toHex(txHash));

// Sign tx_hash with noble
const sig = ml_dsa87.sign(txHash, kp.secretKey);
console.log("sig len    :", sig.length);
console.log();

// Test 1: pq_verify_test with the EXACT msg (tx_hash) we signed
const v = await rpc("pq_verify_test", [{
  scheme: "ml_dsa_87",
  public_key: pubHex,
  message:    toHex(txHash),
  signature:  toHex(sig),
}]);
console.log("pq_verify_test (direct):");
console.log("  ", JSON.stringify(v.result || v.error));
console.log();

// Test 2: pq_send — chain rebuilds tx_hash from fields, then verifies with same sig
const s = await rpc("pq_send", [{
  from: fromAddr, to: toAddr, amount, fee,
  scheme: "pq_omni_ml_dsa",
  signature: toHex(sig),
  public_key: pubHex,
  id: txId, timestamp, nonce,
}]);
console.log("pq_send:");
console.log("  ", JSON.stringify(s.result || s.error));
console.log();

// Diagnosis
const v_ok = v.result?.verified === true;
const s_ok = !s.error;
if (v_ok && s_ok) {
  console.log("✅ Both pass — pipeline works end-to-end!");
  process.exit(0);
} else if (v_ok && !s_ok) {
  console.log("⚠ pq_verify_test ✓ but pq_send ✗");
  console.log("→ chain rebuilds tx_hash with different recipe than JS buildTxHash.");
  console.log("→ inspect core/transaction.zig:calculateHash() vs JS buildTxHash above.");
  process.exit(1);
} else if (!v_ok && !s_ok) {
  console.log("✗ pq_verify_test fails — library issue (noble ↔ liboqs framing).");
  process.exit(1);
} else {
  console.log("?? pq_send ✓ but pq_verify_test ✗ (impossible state)");
  process.exit(1);
}
