#!/usr/bin/env node
/**
 * fund-pq-then-stress.mjs — fund 4 PQ wallets, then flood TXs (multi-chain).
 *
 * Updated 2026-05-10: --chain flag, public-VPS endpoints, bearer token.
 *
 * Step 1: Fund 4 PQ addresses from the ECDSA primary (which has balance).
 * Step 2: Wait for confirmation.
 * Step 3: Run the 4×5 PQ→* matrix.
 *
 * Run from frontend/ folder (needs @noble/post-quantum, @scure/bip32/39):
 *   node fund-pq-then-stress.mjs                          # mainnet
 *   node fund-pq-then-stress.mjs --chain testnet
 *   node fund-pq-then-stress.mjs --chain regtest
 *   node fund-pq-then-stress.mjs --rpc http://localhost:8332
 */

import { ml_dsa87 }      from "@noble/post-quantum/ml-dsa.js";
import { falcon512 }     from "@noble/post-quantum/falcon.js";
import { slh_dsa_sha2_256s } from "@noble/post-quantum/slh-dsa.js";
import { sha256, sha512 } from "@noble/hashes/sha2.js";
import { ripemd160 }     from "@noble/hashes/legacy.js";
import { HDKey }         from "@scure/bip32";
import { mnemonicToSeed } from "@scure/bip39";
import { secp256k1 }     from "@noble/curves/secp256k1.js";

const TEST_MNEMONIC =
  "abandon abandon abandon abandon abandon abandon abandon abandon " +
  "abandon abandon abandon about";

const PQ_SLOTS = [
  { id: "ml_dsa_87",    account: 5, prefix: "obk1_", lib: ml_dsa87,           rpcName: "pq_omni_ml_dsa",    code: 5 },
  { id: "falcon_512",   account: 6, prefix: "obf5_", lib: falcon512,          rpcName: "pq_omni_falcon",    code: 6 },
  { id: "dilithium_5",  account: 7, prefix: "obs3_", lib: ml_dsa87,           rpcName: "pq_omni_dilithium", code: 7 },
  { id: "slh_dsa_256s", account: 8, prefix: "obd5_", lib: slh_dsa_sha2_256s,  rpcName: "pq_omni_slh_dsa",   code: 8 },
];

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
const RPC_URL = RPC_OVR || RPC_URLS[CHAIN] || RPC_URLS.testnet;

const bytesToHex = (b) => Array.from(b).map(x => x.toString(16).padStart(2, "0")).join("");
const sleep = (ms) => new Promise(r => setTimeout(r, ms));

async function rpc(method, params = []) {
  const headers = { "Content-Type": "application/json" };
  if (TOKEN) headers.Authorization = `Bearer ${TOKEN}`;
  const r = await fetch(RPC_URL, {
    method: "POST", headers,
    body: JSON.stringify({ jsonrpc: "2.0", method, params, id: Date.now() }),
  });
  const j = await r.json();
  if (j.error) throw new Error(j.error.message ?? JSON.stringify(j.error));
  return j.result;
}

const BECH32 = "qpzry9x8gf2tvdw0s3jn54khce6mua7l";
function bech32Polymod(v) { const G = [0x3b6a57b2,0x26508e6d,0x1ea119fa,0x3d4233dd,0x2a1462b3]; let c = 1; for (const x of v) { const t = c >> 25; c = ((c & 0x1ffffff) << 5) ^ x; for (let i = 0; i < 5; i++) if ((t >> i) & 1) c ^= G[i]; } return c; }
function bech32Cs(hrp, d) { const e = []; for (const c of hrp) e.push(c.charCodeAt(0) >> 5); e.push(0); for (const c of hrp) e.push(c.charCodeAt(0) & 31); const p = bech32Polymod([...e, ...d, 0,0,0,0,0,0]) ^ 1; return Array.from({length:6}, (_,i) => (p >> 5*(5-i)) & 31); }
function convertBits(d, fb, tb, pad) { let acc = 0, bits = 0; const out = []; const m = (1 << tb) - 1; for (const v of d) { acc = (acc << fb) | v; bits += fb; while (bits >= tb) { bits -= tb; out.push((acc >> bits) & m); } } if (pad && bits > 0) out.push((acc << (tb - bits)) & m); return out; }
function obAddr(h160) { const d = [0, ...convertBits(Array.from(h160), 8, 5, true)]; return "ob1" + [...d, ...bech32Cs("ob", d)].map(x => BECH32[x]).join(""); }
function pqAddr(prefix, h160) { const b58 = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"; let n = 0n; for (const b of h160) n = n*256n + BigInt(b); let r = ""; while (n > 0n) { r = b58[Number(n%58n)] + r; n /= 58n; } return prefix + r; }

function stretchSeed(seed, expected) {
  if (seed.length === expected) return seed;
  if (expected === 32) return sha256(seed).slice(0, 32);
  if (expected === 48) return sha512(seed).slice(0, 48);
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
  const ecdsaKey = root.derive("m/44'/777'/0'/0/0");
  const pubFull = secp256k1.getPublicKey(ecdsaKey.privateKey, true);
  const ecdsaH160 = ripemd160(sha256(pubFull));
  const ecdsaAddr = obAddr(ecdsaH160);

  const slots = [];
  for (const s of PQ_SLOTS) {
    const child = root.derive(`m/44'/777'/${s.account}'/0/0`);
    const seedLen = s.lib.lengths?.seed ?? 32;
    const finalSeed = stretchSeed(child.privateKey, seedLen);
    const kp = s.lib.keygen(finalSeed);
    const pkH160 = ripemd160(sha256(kp.publicKey));
    slots.push({
      id: s.id, code: s.code, scheme: s.rpcName, lib: s.lib, prefix: s.prefix,
      address: pqAddr(s.prefix, pkH160),
      publicKey: kp.publicKey,
      secretKey: kp.secretKey,
    });
  }
  return { ecdsa: { address: ecdsaAddr, key: ecdsaKey, pubFull }, slots };
}

async function main() {
  const w = await deriveAll();
  console.log("=".repeat(70));
  console.log("Funding PQ addresses then running stress-test (multi-chain)");
  console.log("=".repeat(70));
  console.log(`Chain: ${CHAIN}`);
  console.log(`RPC:   ${RPC_URL}`);
  console.log(`Auth:  ${TOKEN ? "Bearer (set)" : "none"}`);
  const tip = await rpc("getblockchaininfo");
  console.log("Chain tip:", tip.blocks);
  console.log();

  // Step 1: Fund each PQ slot from ECDSA primary
  const ecdsaBal = await rpc("getbalance", [{ address: w.ecdsa.address }]);
  console.log(`ECDSA primary: ${w.ecdsa.address}`);
  console.log(`  balance: ${ecdsaBal.balanceOMNI} OMNI`);
  if (parseFloat(ecdsaBal.balanceOMNI) < 0.4) {
    console.log("ERROR: Need ≥0.4 OMNI on ECDSA primary to fund 4 PQ slots");
    process.exit(1);
  }
  console.log();

  console.log("Step 1: Fund PQ addresses (0.05 OMNI each)");
  for (const s of w.slots) {
    try {
      const r = await rpc("sendfrom", [{
        from_address: w.ecdsa.address,
        to_address: s.address,
        amount: 0.05,
        privkey_hex: bytesToHex(w.ecdsa.key.privateKey),
      }]);
      console.log(`  ECDSA → ${s.id.padEnd(14)} → ${s.address}: ✓ tx=${r?.txid?.slice(0,16) ?? "?"}`);
    } catch (e) {
      console.log(`  ECDSA → ${s.id}: ✗ ${e.message}`);
    }
    await sleep(200);
  }
  console.log();

  // Step 2: Wait for confirmation
  console.log("Step 2: Waiting for confirmation (max 30s)...");
  const startBlocks = (await rpc("getblockchaininfo")).blocks;
  for (let i = 0; i < 30; i++) {
    await sleep(1000);
    const cur = (await rpc("getblockchaininfo")).blocks;
    if (cur > startBlocks) {
      console.log(`  Confirmed at block ${cur} (after ${i+1}s)`);
      break;
    }
    if (i === 29) console.log("  Timeout but continuing");
  }
  console.log();

  console.log("Step 3: Verifying PQ balances after funding");
  for (const s of w.slots) {
    const bal = await rpc("getbalance", [{ address: s.address }]);
    console.log(`  ${s.id.padEnd(14)}: ${bal.balanceOMNI} OMNI`);
  }
  console.log();

  console.log("Step 4: Run 4×5 = 20 PQ→* TXs");
  const dests = [{ id: "omni_ecdsa", address: w.ecdsa.address }, ...w.slots];
  let pass = 0, fail = 0;
  const errs = {};
  for (const from of w.slots) {
    for (const to of dests) {
      try {
        await rpc("getbalance", [{ address: from.address }]).catch(() => null);
        const txReq = {
          from_address: from.address,
          to_address: to.address,
          amount: 0.001,
          public_key_hex: bytesToHex(from.publicKey),
          scheme: from.scheme,
        };
        const built = await rpc("buildtransaction", [txReq]);
        const msgHash = Uint8Array.from(Buffer.from(built.hash, "hex"));
        const sig = from.lib.sign(from.secretKey, msgHash);
        const sigHex = bytesToHex(sig);
        const send = await rpc("sendrawtransaction", [{
          ...built,
          signature: sigHex,
        }]);
        console.log(`  ${from.id.padEnd(14)} → ${to.id.padEnd(14)}: ✓ ${send?.txid?.slice(0,16) ?? "OK"}`);
        pass++;
      } catch (e) {
        const m = e.message.slice(0, 60);
        errs[m] = (errs[m] ?? 0) + 1;
        console.log(`  ${from.id.padEnd(14)} → ${to.id.padEnd(14)}: ✗ ${m}`);
        fail++;
      }
      await sleep(150);
    }
  }
  console.log();
  console.log("=".repeat(70));
  console.log(`Result: ${pass}/20 PQ TXs accepted`);
  if (Object.keys(errs).length) {
    console.log("Errors:");
    for (const [m, c] of Object.entries(errs)) console.log(`  [${c}x] ${m}`);
  }
  console.log("=".repeat(70));
  process.exit(fail === 0 ? 0 : 1);
}

main().catch(e => { console.error(e); process.exit(1); });
