#!/usr/bin/env node
/**
 * stress-test.mjs — End-to-end PQ matrix using EXACT frontend derivation logic.
 * Run from frontend/ folder: node stress-test.mjs --rpc http://localhost:18332
 */

import { ml_dsa87 }      from "@noble/post-quantum/ml-dsa.js";
import { falcon512 }     from "@noble/post-quantum/falcon.js";
import { slh_dsa_sha2_256s } from "@noble/post-quantum/slh-dsa.js";
import { sha256, sha512 } from "@noble/hashes/sha2.js";
import { ripemd160 }     from "@noble/hashes/legacy.js";
import { HDKey }         from "@scure/bip32";
import { mnemonicToSeed } from "@scure/bip39";
import { base58 }        from "@scure/base";

const TEST_MNEMONIC =
  "abandon abandon abandon abandon abandon abandon abandon abandon " +
  "abandon abandon abandon about";

// EXACT frontend mapping (post fix 2026-05-06)
const PQ_SLOTS = [
  { id: "ml_dsa_87",    account: 5, prefix: "obk1_", lib: ml_dsa87,           rpcName: "pq_omni_ml_dsa",    code: 5 },
  { id: "falcon_512",   account: 6, prefix: "obf5_", lib: falcon512,          rpcName: "pq_omni_falcon",    code: 6 },
  { id: "dilithium_5",  account: 7, prefix: "obs3_", lib: ml_dsa87,           rpcName: "pq_omni_dilithium", code: 7 },
  { id: "slh_dsa_256s", account: 8, prefix: "obd5_", lib: slh_dsa_sha2_256s,  rpcName: "pq_omni_slh_dsa",   code: 8 },
];

let RPC_URL = "http://localhost:18332";
const args = process.argv.slice(2);
for (let i = 0; i < args.length; i++) if (args[i] === "--rpc") RPC_URL = args[++i];

const bytesToHex = (b) => Array.from(b).map(x => x.toString(16).padStart(2, "0")).join("");

async function rpc(method, params = []) {
  const r = await fetch(RPC_URL, {
    method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", method, params, id: Date.now() }),
  });
  const j = await r.json();
  if (j.error) throw new Error(j.error.message);
  return j.result;
}
const sleep = (ms) => new Promise(r => setTimeout(r, ms));

// Bech32 encode (mirrors frontend)
const BECH32 = "qpzry9x8gf2tvdw0s3jn54khce6mua7l";
function bech32Polymod(v) { const G = [0x3b6a57b2,0x26508e6d,0x1ea119fa,0x3d4233dd,0x2a1462b3]; let c = 1; for (const x of v) { const t = c >> 25; c = ((c & 0x1ffffff) << 5) ^ x; for (let i = 0; i < 5; i++) if ((t >> i) & 1) c ^= G[i]; } return c; }
function bech32Cs(hrp, d) { const e = []; for (const c of hrp) e.push(c.charCodeAt(0) >> 5); e.push(0); for (const c of hrp) e.push(c.charCodeAt(0) & 31); const p = bech32Polymod([...e, ...d, 0,0,0,0,0,0]) ^ 1; return Array.from({length:6}, (_,i) => (p >> 5*(5-i)) & 31); }
function convertBits(d, fb, tb, pad) { let acc = 0, bits = 0; const out = []; const m = (1 << tb) - 1; for (const v of d) { acc = (acc << fb) | v; bits += fb; while (bits >= tb) { bits -= tb; out.push((acc >> bits) & m); } } if (pad && bits > 0) out.push((acc << (tb - bits)) & m); return out; }
function obAddr(h160) { const d = [0, ...convertBits(Array.from(h160), 8, 5, true)]; return "ob1" + [...d, ...bech32Cs("ob", d)].map(x => BECH32[x]).join(""); }

// Stretch seed for libraries that need different lengths
function stretchSeed(seed, expected) {
  if (seed.length === expected) return seed;
  if (expected === 32) return sha256(seed).slice(0, 32);
  if (expected === 48) return sha512(seed).slice(0, 48);
  // SLH-DSA needs 96 bytes
  const out = new Uint8Array(expected);
  let off = 0, counter = 0;
  while (off < expected) {
    const buf = new Uint8Array(seed.length + 1);
    buf.set(seed); buf[seed.length] = counter++;
    const blk = sha512(buf);
    const take = Math.min(blk.length, expected - off);
    out.set(blk.slice(0, take), off);
    off += take;
  }
  return out;
}

async function deriveAll() {
  const seed = await mnemonicToSeed(TEST_MNEMONIC);
  const root = HDKey.fromMasterSeed(seed);

  // ECDSA primary
  const { secp256k1 } = await import("@noble/curves/secp256k1.js");
  const ecdsaKey = root.derive("m/44'/777'/0'/0/0");
  const pubFull = secp256k1.getPublicKey(ecdsaKey.privateKey, true);
  const ecdsaH160 = ripemd160(sha256(pubFull));
  const ecdsaAddr = obAddr(ecdsaH160);

  const slots = [];
  for (const s of PQ_SLOTS) {
    const child = root.derive(`m/44'/777'/${s.account}'/0/0`);
    const expected = s.lib.lengths?.seed ?? 32;
    const seedBuf = stretchSeed(child.privateKey, expected);
    const kp = s.lib.keygen(seedBuf);
    // Address: prefix + base58check(0x4f, ripemd160(sha256(pk)))
    const h160 = ripemd160(sha256(kp.publicKey));
    const versioned = new Uint8Array(21);
    versioned[0] = 0x4f;
    versioned.set(h160, 1);
    const ck = sha256(sha256(versioned)).slice(0, 4);
    const full = new Uint8Array(25);
    full.set(versioned); full.set(ck, 21);
    const addr = s.prefix + base58.encode(full);
    slots.push({ ...s, address: addr, publicKey: kp.publicKey, secretKey: kp.secretKey });
  }
  return { ecdsa: { id: "omni_ecdsa", address: ecdsaAddr, code: 0 }, slots };
}

function buildHash(args) {
  const enc = new TextEncoder();
  const parts = [];
  const push = (s) => parts.push(typeof s === "string" ? enc.encode(s) : s);
  push(String(args.id)); push(":"); push(args.from); push(":"); push(args.to); push(":");
  push(String(args.amount)); push(":"); push(String(args.timestamp)); push(":"); push(String(args.nonce));
  if (args.schemeCode !== 0) { push(":SC:"); push(String(args.schemeCode)); }
  // BUG FIX 2026-05-06: chain hashes self.public_key which is the HEX STRING
  // stored in tx.public_key (rpc_server.zig:10713 sets pk_owned = hex). So
  // frontend MUST hash the hex string, not the raw bytes.
  if (args.publicKeyHex) { push(":PK:"); push(args.publicKeyHex); }
  if (args.fee && args.fee > 0) { push(":"); push(String(args.fee)); }
  if (args.opReturn) { push(":OP:"); push(args.opReturn); }
  const total = parts.reduce((n, p) => n + p.length, 0);
  const buf = new Uint8Array(total);
  let off = 0;
  for (const p of parts) { buf.set(p, off); off += p.length; }
  // SHA-256d (double) — matches Crypto.sha256(sha256(...)) at transaction.zig:417
  return sha256(sha256(buf));
}

async function tryPqSend(slot, toAddr, amountSat) {
  let nonce = 0;
  try {
    const r = await rpc("getnonce", [slot.address]);
    nonce = typeof r === "object" ? (r.nonce ?? 0) : r;
  } catch {}
  const txId = Math.floor(Math.random() * 0x7fffffff);
  const timestamp = Math.floor(Date.now() / 1000);
  const fee = 1;

  const hash = buildHash({
    id: txId, from: slot.address, to: toAddr, amount: amountSat, fee,
    timestamp, nonce, schemeCode: slot.code,
    publicKeyHex: bytesToHex(slot.publicKey),
  });
  console.log(`    [DBG] tx_id=${txId} ts=${timestamp} nonce=${nonce} hash=${bytesToHex(hash)}`);

  const sig = slot.lib.sign(hash, slot.secretKey);

  try {
    const r = await rpc("pq_send", [{
      from: slot.address, to: toAddr, amount: amountSat, fee,
      scheme: slot.rpcName,
      signature: bytesToHex(sig),
      public_key: bytesToHex(slot.publicKey),
      id: txId, timestamp, nonce,
    }]);
    return { ok: true, txid: r?.txid ?? r?.hash };
  } catch (e) {
    return { ok: false, error: e.message };
  }
}

async function main() {
  console.log("=".repeat(70));
  console.log("OmniBus PQ Stress Matrix — frontend-aligned derivation");
  console.log("=".repeat(70));
  console.log(`RPC: ${RPC_URL}`);

  const tip = await rpc("getblockcount").catch(() => "DOWN");
  console.log(`Chain tip: ${tip}\n`);

  const w = await deriveAll();
  console.log(`Addresses derived:`);
  console.log(`  ECDSA primary:  ${w.ecdsa.address}`);
  for (const s of w.slots) {
    const bal = await rpc("getbalance", [{ address: s.address }]).catch(() => null);
    console.log(`  ${s.id.padEnd(14)}: ${s.address}  (bal: ${bal?.balanceOMNI ?? "?"})`);
  }
  console.log("");

  // PQ→PQ + PQ→ECDSA matrix (16 cells)
  const dests = [w.ecdsa, ...w.slots];
  console.log("Running 4×5 = 20 PQ→* attempts (each is a real on-chain TX)...\n");
  const results = [];
  for (const from of w.slots) {
    for (const to of dests) {
      const r = await tryPqSend(from, to.address, 100_000);
      results.push({ from: from.id, to: to.id, ...r });
      console.log(`  ${from.id.padEnd(14)} → ${to.id.padEnd(14)} : ${r.ok ? "✓ ACCEPTED " + r.txid?.slice(0,12) : "✗ " + r.error}`);
      await sleep(150);
    }
  }

  // Print matrix
  console.log("\n" + "=".repeat(70));
  console.log("MATRIX (rows = from, cols = to):");
  console.log("=".repeat(70));
  const cols = ["omni_ecdsa", "ml_dsa_87", "falcon_512", "dilithium_5", "slh_dsa_256s"];
  const colWidth = 14;
  process.stdout.write("from \\ to    ");
  for (const c of cols) process.stdout.write(c.padEnd(colWidth) + " ");
  process.stdout.write("\n");
  for (const fid of cols.slice(1)) {
    process.stdout.write(fid.padEnd(13));
    for (const tid of cols) {
      const r = results.find(x => x.from === fid && x.to === tid);
      const cell = r?.ok ? "OK" : (r?.error ? "FAIL" : "—");
      process.stdout.write(cell.padEnd(colWidth) + " ");
    }
    process.stdout.write("\n");
  }

  // Errors summary
  const errs = results.filter(r => !r.ok);
  if (errs.length > 0) {
    console.log("\nErrors:");
    const grouped = {};
    for (const e of errs) {
      const k = e.error?.slice(0, 60) ?? "unknown";
      grouped[k] = (grouped[k] ?? 0) + 1;
    }
    for (const [msg, n] of Object.entries(grouped)) {
      console.log(`  [${n}x] ${msg}`);
    }
  }

  console.log(`\nSuccess rate: ${results.filter(r => r.ok).length}/${results.length}`);
}

main().catch(e => { console.error("FATAL:", e); process.exit(1); });
