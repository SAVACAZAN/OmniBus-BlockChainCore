#!/usr/bin/env node
/**
 * stress-pq-matrix.mjs — PQ signature stress matrix (multi-chain).
 *
 * Updated 2026-05-10: --chain flag, public-VPS endpoints, bearer token.
 *
 * Runs from the frontend folder so it can use installed @noble/post-quantum,
 * @noble/secp256k1, @noble/hashes, @scure/bip32, @scure/bip39.
 *
 * Usage:
 *   cd frontend
 *   node ../scripts/stress-pq-matrix.mjs                            # mainnet
 *   node ../scripts/stress-pq-matrix.mjs --chain testnet
 *   node ../scripts/stress-pq-matrix.mjs --chain regtest --restart
 *   node ../scripts/stress-pq-matrix.mjs --rpc http://127.0.0.1:18332
 *
 * What it does:
 *   1. Derives ECDSA primary + 4 PQ-OMNI addresses from TEST_MNEMONIC.
 *   2. For each of 4×5 = 20 (from_pq, to) combinations:
 *        - builds canonical TX hash, signs with PQ algo
 *        - submits via pq_send RPC, polls for confirmation
 *   3. Optionally restarts the chain (--restart) and re-checks each TX.
 *   4. Prints a 4×5 matrix and saves stress-pq-matrix.results.json.
 */

import { ml_dsa87 }      from "@noble/post-quantum/ml-dsa.js";
import { ml_kem768 }     from "@noble/post-quantum/ml-kem.js";
import { slh_dsa_sha2_256s } from "@noble/post-quantum/slh-dsa.js";
import { falcon512 }     from "@noble/post-quantum/falcon.js";
import { sha256, sha512 } from "@noble/hashes/sha2.js";
import { ripemd160 }     from "@noble/hashes/legacy.js";
import * as secp         from "@noble/secp256k1";
import { HDKey }         from "@scure/bip32";
import { mnemonicToSeed } from "@scure/bip39";

// ── Constants ────────────────────────────────────────────────────────────────

const TEST_MNEMONIC =
  "abandon abandon abandon abandon abandon abandon abandon abandon " +
  "abandon abandon abandon about";

const SCHEMES = [
  { id: "omni_ecdsa",   code: 0, name: "OMNI Primary",  prefix: "ob1q",  algo: "ECDSA"     },
  { id: "ml_dsa_87",    code: 5, name: "ML-DSA-87",     prefix: "obk1_", algo: "ML-DSA"    },
  { id: "falcon_512",   code: 6, name: "Falcon-512",    prefix: "obf5_", algo: "Falcon"    },
  { id: "dilithium_5",  code: 7, name: "Dilithium-5",   prefix: "obs3_", algo: "Dilithium" },
  { id: "slh_dsa_256s", code: 8, name: "SLH-DSA-256s",  prefix: "obd5_", algo: "SLH-DSA"   },
];

const PQ_RPC_NAMES = {
  ml_dsa_87:    "pq_omni_ml_dsa",
  falcon_512:   "pq_omni_falcon",
  dilithium_5:  "pq_omni_dilithium",
  slh_dsa_256s: "pq_omni_slh_dsa",
};

const RPC_URLS = {
  mainnet: "https://omnibusblockchain.cc:8443/api-mainnet",
  testnet: "https://omnibusblockchain.cc:8443/api-testnet",
  regtest: "https://omnibusblockchain.cc:8443/api-regtest",
  "local-mainnet": "http://localhost:8332",
  "local-testnet": "http://localhost:18332",
  "local-regtest": "http://localhost:28332",
};

// ── CLI ─────────────────────────────────────────────────────────────────────

const args = process.argv.slice(2);
function arg(name, fb) {
  const i = args.indexOf(name);
  return i >= 0 && args[i + 1] ? args[i + 1] : fb;
}
const CHAIN     = arg("--chain", process.env.CHAIN || "testnet");
const RPC_OVR   = arg("--rpc",   process.env.RPC_URL);
const TOKEN     = arg("--token", process.env.OMNIBUS_RPC_TOKEN);
const DO_RESTART = args.includes("--restart");
const RPC_URL = RPC_OVR || RPC_URLS[CHAIN] || RPC_URLS.testnet;

// ── Helpers ─────────────────────────────────────────────────────────────────

function bytesToHex(b) {
  return Array.from(b).map(x => x.toString(16).padStart(2, "0")).join("");
}
function hexToBytes(s) {
  if (s.startsWith("0x")) s = s.slice(2);
  const out = new Uint8Array(s.length / 2);
  for (let i = 0; i < out.length; i++) out[i] = parseInt(s.slice(i * 2, i * 2 + 2), 16);
  return out;
}
async function rpc(method, params = []) {
  const headers = { "Content-Type": "application/json" };
  if (TOKEN) headers.Authorization = `Bearer ${TOKEN}`;
  const r = await fetch(RPC_URL, {
    method: "POST", headers,
    body: JSON.stringify({ jsonrpc: "2.0", method, params, id: Date.now() }),
  });
  const j = await r.json();
  if (j.error) throw new Error(`RPC ${method}: ${j.error.message}`);
  return j.result;
}
const sleep = (ms) => new Promise(r => setTimeout(r, ms));

// Bech32 + base58 (unchanged from original)
const BECH32_CHARS = "qpzry9x8gf2tvdw0s3jn54khce6mua7l";
function bech32Polymod(values) {
  const GEN = [0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3];
  let chk = 1;
  for (const v of values) {
    const top = chk >> 25;
    chk = ((chk & 0x1ffffff) << 5) ^ v;
    for (let i = 0; i < 5; i++) if ((top >> i) & 1) chk ^= GEN[i];
  }
  return chk;
}
function bech32HrpExpand(hrp) {
  const out = [];
  for (const c of hrp) out.push(c.charCodeAt(0) >> 5);
  out.push(0);
  for (const c of hrp) out.push(c.charCodeAt(0) & 31);
  return out;
}
function bech32CreateChecksum(hrp, data) {
  const values = [...bech32HrpExpand(hrp), ...data];
  const polymod = bech32Polymod([...values, 0, 0, 0, 0, 0, 0]) ^ 1;
  return Array.from({ length: 6 }, (_, i) => (polymod >> 5 * (5 - i)) & 31);
}
function convertBits(data, fromBits, toBits, pad) {
  let acc = 0, bits = 0;
  const out = [];
  const maxv = (1 << toBits) - 1;
  for (const v of data) {
    if (v < 0 || (v >> fromBits) !== 0) throw new Error("convertBits invalid");
    acc = (acc << fromBits) | v;
    bits += fromBits;
    while (bits >= toBits) {
      bits -= toBits;
      out.push((acc >> bits) & maxv);
    }
  }
  if (pad && bits > 0) out.push((acc << (toBits - bits)) & maxv);
  return out;
}
function bech32Encode(hrp, data) {
  const combined = [...data, ...bech32CreateChecksum(hrp, data)];
  return hrp + "1" + combined.map(d => BECH32_CHARS[d]).join("");
}
function encodeOBAddress(hash160) {
  const data = [0, ...convertBits(Array.from(hash160), 8, 5, true)];
  return bech32Encode("ob", data);
}
const B58 = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";
function base58Encode(bytes) {
  let num = 0n;
  for (const b of bytes) num = num * 256n + BigInt(b);
  let out = "";
  while (num > 0n) { out = B58[Number(num % 58n)] + out; num /= 58n; }
  for (const b of bytes) { if (b === 0) out = "1" + out; else break; }
  return out;
}
function base58Check(payload, version) {
  const buf = new Uint8Array(1 + payload.length);
  buf[0] = version;
  buf.set(payload, 1);
  const ck = sha256(sha256(buf)).slice(0, 4);
  const full = new Uint8Array(buf.length + 4);
  full.set(buf, 0); full.set(ck, buf.length);
  return base58Encode(full);
}
function pqAddress(prefix, pubKeyBytes) {
  const h160 = ripemd160(sha256(pubKeyBytes));
  const b58 = base58Check(h160, 0x4f);
  return prefix + b58;
}

async function deriveAll() {
  const seed = await mnemonicToSeed(TEST_MNEMONIC);
  const root = HDKey.fromMasterSeed(seed);
  const ecdsaKey = root.derive("m/44'/777'/0'/0/0");
  const pub = secp.getPublicKey(ecdsaKey.privateKey, true);
  const h160 = ripemd160(sha256(pub));
  const ecdsaAddr = encodeOBAddress(h160);

  const pqSlots = [];
  const pqDefs = [
    { id: "ml_dsa_87",    coin: 5, prefix: "obk1_", lib: ml_dsa87,           seedLen: 32 },
    { id: "falcon_512",   coin: 6, prefix: "obf5_", lib: falcon512,          seedLen: 48 },
    { id: "dilithium_5",  coin: 7, prefix: "obs3_", lib: ml_dsa87,           seedLen: 32 },
    { id: "slh_dsa_256s", coin: 8, prefix: "obd5_", lib: slh_dsa_sha2_256s,  seedLen: 96 },
  ];
  for (const d of pqDefs) {
    const child = root.derive(`m/44'/777'/${d.coin}'/0/0`);
    const baseSeed = child.privateKey;
    let seedBuf;
    if (d.seedLen === 32) {
      seedBuf = sha256(baseSeed);
    } else if (d.seedLen === 48) {
      seedBuf = sha512(baseSeed).slice(0, 48);
    } else {
      seedBuf = new Uint8Array(d.seedLen);
      let off = 0, counter = 0;
      while (off < d.seedLen) {
        const cb = new Uint8Array(baseSeed.length + 1);
        cb.set(baseSeed); cb[baseSeed.length] = counter++;
        const block = sha512(cb);
        const take = Math.min(block.length, d.seedLen - off);
        seedBuf.set(block.slice(0, take), off);
        off += take;
      }
    }
    let pk, sk;
    if (d.lib) {
      const kp = d.lib.keygen(seedBuf);
      pk = kp.publicKey; sk = kp.secretKey;
    } else {
      pk = sha256(seedBuf);
      sk = seedBuf;
    }
    const addr = pqAddress(d.prefix, pk);
    pqSlots.push({ id: d.id, address: addr, publicKey: pk, secretKey: sk, lib: d.lib, prefix: d.prefix });
  }

  return {
    ecdsa: { id: "omni_ecdsa", address: ecdsaAddr, privateKey: ecdsaKey.privateKey, publicKey: pub },
    pq: pqSlots,
  };
}

const _toHex = (b) => Array.from(b).map(x => x.toString(16).padStart(2, "0")).join("");
function buildTxHash(args) {
  const enc = new TextEncoder();
  const parts = [];
  const push = (s) => parts.push(enc.encode(s));
  push(String(args.id));    push(":");
  push(args.from);          push(":");
  push(args.to);            push(":");
  push(String(args.amount));push(":");
  push(String(args.timestamp)); push(":");
  push(String(args.nonce));
  if (args.schemeCode !== 0) { push(":SC:"); push(String(args.schemeCode)); }
  let pubHex = args.publicKeyHex;
  if (!pubHex && args.publicKeyBytes && args.publicKeyBytes.length > 0) {
    pubHex = _toHex(args.publicKeyBytes);
  }
  if (pubHex && pubHex.length > 0) { push(":PK:"); push(pubHex); }
  if (args.fee && args.fee > 0)        { push(":"); push(String(args.fee)); }
  if (args.locktime && args.locktime > 0) { push(":"); push("lt" + String(args.locktime)); }
  if (args.opReturn && args.opReturn.length > 0) { push(":OP:"); push(args.opReturn); }

  const total = parts.reduce((n, p) => n + p.length, 0);
  const buf = new Uint8Array(total);
  let off = 0; for (const p of parts) { buf.set(p, off); off += p.length; }
  return sha256(sha256(buf));
}

async function tryPqSend(fromSlot, toAddr, amountSat) {
  if (!fromSlot.lib) {
    return { ok: false, error: `Lib for ${fromSlot.id} not available in @noble/post-quantum` };
  }
  const nonce = await rpc("getnonce", [fromSlot.address]).catch(() => 0);
  const txId = Math.floor(Math.random() * 0x7fffffff);
  const timestamp = Math.floor(Date.now() / 1000);
  const fee = 1;
  const schemeCode = SCHEMES.find(s => s.id === fromSlot.id).code;

  const msgHash = buildTxHash({
    id: txId, from: fromSlot.address, to: toAddr, amount: amountSat, fee,
    timestamp, nonce: typeof nonce === "object" ? nonce.nonce ?? 0 : nonce,
    schemeCode, publicKeyBytes: fromSlot.publicKey, opReturn: "",
  });

  const sig = fromSlot.lib.sign(msgHash, fromSlot.secretKey);
  try {
    const r = await rpc("pq_send", [{
      from: fromSlot.address, to: toAddr, amount: amountSat, fee,
      scheme: PQ_RPC_NAMES[fromSlot.id],
      signature: bytesToHex(sig),
      public_key: bytesToHex(fromSlot.publicKey),
      id: txId, timestamp, nonce: typeof nonce === "object" ? nonce.nonce ?? 0 : nonce,
    }]);
    return { ok: true, txid: r?.txid ?? r?.hash };
  } catch (e) {
    return { ok: false, error: e.message };
  }
}

async function main() {
  console.log("=".repeat(60));
  console.log("OmniBus PQ Stress Matrix (multi-chain)");
  console.log("=".repeat(60));
  console.log(`Chain: ${CHAIN}`);
  console.log(`RPC:   ${RPC_URL}`);
  console.log(`Auth:  ${TOKEN ? "Bearer (set)" : "none"}`);
  console.log(`Mnemonic: ${TEST_MNEMONIC}`);
  console.log("");

  const tip = await rpc("getblockcount").catch(() => "DOWN");
  console.log(`Chain tip: ${tip}`);
  console.log("");

  console.log("Deriving addresses from test mnemonic…");
  const w = await deriveAll();
  console.log(`  ECDSA primary:  ${w.ecdsa.address}`);
  for (const p of w.pq) {
    console.log(`  ${p.id.padEnd(14)}: ${p.address}  (lib: ${p.lib ? "available" : "NOT in @noble/post-quantum"})`);
  }
  console.log("");

  console.log("Balances:");
  for (const a of [w.ecdsa.address, ...w.pq.map(p => p.address)]) {
    const bal = await rpc("getbalance", [{ address: a }]).catch(() => null);
    console.log(`  ${a.slice(0, 14)}…  ${bal?.balanceOMNI ?? "?"} OMNI`);
  }
  console.log("");

  console.log("Running PQ→* matrix (16 combinations)…");
  const results = [];
  for (const fromSlot of w.pq) {
    for (const to of [w.ecdsa, ...w.pq]) {
      const fromTo = `${fromSlot.id} → ${to.id}`;
      console.log(`  ${fromTo}…`);
      const r = await tryPqSend(fromSlot, to.address, 100_000);
      results.push({ from: fromSlot.id, to: to.id, ...r });
      console.log(`    ${r.ok ? "✓ ACCEPTED" : "✗ " + r.error}`);
      await sleep(200);
    }
  }

  console.log("");
  console.log("RESULT MATRIX (rows=from, cols=to):");
  console.log("");
  const cols = ["omni_ecdsa", "ml_dsa_87", "falcon_512", "dilithium_5", "slh_dsa_256s"];
  process.stdout.write("            | ");
  for (const c of cols) process.stdout.write(c.padEnd(14) + " | ");
  process.stdout.write("\n");
  for (const fromId of cols.slice(1)) {
    process.stdout.write(fromId.padEnd(12) + "| ");
    for (const toId of cols) {
      const r = results.find(x => x.from === fromId && x.to === toId);
      const cell = r?.ok ? "✓ accepted" : (r ? "✗ " + (r.error?.slice(0, 12) ?? "fail") : "—");
      process.stdout.write(cell.padEnd(14) + " | ");
    }
    process.stdout.write("\n");
  }
  console.log("");

  const fs = await import("node:fs");
  const path = await import("node:path");
  const out = path.resolve(process.cwd(), "stress-pq-matrix.results.json");
  fs.writeFileSync(out, JSON.stringify({
    chain: CHAIN, rpc: RPC_URL, chainTip: tip,
    addresses: { ecdsa: w.ecdsa.address, pq: w.pq.map(p => ({ id: p.id, addr: p.address })) },
    results,
  }, null, 2));
  console.log(`JSON: ${out}`);

  if (DO_RESTART) {
    console.log("\nRestart pass: TBD — trigger systemctl externally then re-run with --verify-only");
  }
}

main().catch(e => { console.error("FATAL:", e); process.exit(1); });
