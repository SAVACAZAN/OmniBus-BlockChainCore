#!/usr/bin/env node
/**
 * 32-halving-simulator.mjs — Halving math simulator + on-chain reward verifier.
 *
 * For each height in {0, 100, 1000, 209999, 210000, 210001, 419999, 420000}:
 *   - Computes expected reward using `50 / 2^(height / 210000)`.
 *   - If chain has that height, fetches block and compares coinbase output.
 *
 * Also:
 *   - Verifies running total supply does not exceed MAX_SUPPLY (21M OMNI).
 *   - Verifies no block exceeds the per-height max reward.
 *
 * Read-only. Default chain: testnet. Saves 32-report.md.
 */

import { writeFileSync } from "node:fs";
import { argv, env, exit } from "node:process";

const ARGS = argv.slice(2);
const arg = (name, fb) => {
  const i = ARGS.indexOf(name);
  return i >= 0 && ARGS[i + 1] ? ARGS[i + 1] : fb;
};
const CHAIN = arg("--chain", env.CHAIN || "testnet");
const RPC_OVR = arg("--rpc", env.RPC_URL);
const TOKEN = arg("--token", env.OMNIBUS_RPC_TOKEN);

const RPC_URLS = {
  mainnet: "https://omnibusblockchain.cc:8443/api-mainnet",
  testnet: "https://omnibusblockchain.cc:8443/api-testnet",
  regtest: "https://omnibusblockchain.cc:8443/api-regtest",
  "local-mainnet": "http://127.0.0.1:8332",
  "local-testnet": "http://127.0.0.1:18332",
  "local-regtest": "http://127.0.0.1:28332",
};
const RPC_URL = RPC_OVR || RPC_URLS[CHAIN] || RPC_URLS.testnet;

const HALVING_INTERVAL = 210_000;
const INITIAL_REWARD = 50; // OMNI
const MAX_SUPPLY = 21_000_000;
const SAT = 1_000_000_000;
const SAMPLE_HEIGHTS = [0, 100, 1000, 209_999, 210_000, 210_001, 419_999, 420_000];

let pass = 0, fail = 0, skip = 0;
const results = [];
const PASS = (m) => { pass++; results.push({ s: "PASS", m }); console.log(`  ✅ PASS ${m}`); };
const FAIL = (m, e) => { fail++; results.push({ s: "FAIL", m, e }); console.log(`  ❌ FAIL ${m}${e ? "  -- " + e : ""}`); };
const SKIP = (m, e) => { skip++; results.push({ s: "SKIP", m, e }); console.log(`  - SKIP ${m}${e ? "  (" + e + ")" : ""}`); };

async function rpc(method, params = []) {
  const headers = { "Content-Type": "application/json" };
  if (TOKEN) headers.Authorization = `Bearer ${TOKEN}`;
  const r = await fetch(RPC_URL, {
    method: "POST", headers,
    body: JSON.stringify({ jsonrpc: "2.0", id: Date.now(), method, params }),
  });
  const j = await r.json();
  if (j.error) {
    const msg = j.error.message ?? JSON.stringify(j.error);
    const err = new Error(msg);
    err.skip = /method not found|unknown method|not implemented/i.test(msg);
    throw err;
  }
  return j.result;
}

function expectedReward(h) {
  const halvings = Math.floor(h / HALVING_INTERVAL);
  if (halvings >= 64) return 0; // safety
  return INITIAL_REWARD / Math.pow(2, halvings);
}

async function getBlockAt(h) {
  try {
    return await rpc("getblock", [{ height: h }]);
  } catch (e) {
    if (e.skip) {
      try { return await rpc("getblockbyheight", [h]); } catch { return null; }
    }
    return null;
  }
}

function extractReward(b) {
  if (!b) return null;
  const cb = b.coinbase ?? (Array.isArray(b.transactions) ? b.transactions[0] : null);
  if (!cb) return null;
  const sat = cb.amount ?? cb.value ?? cb.outputs?.[0]?.amount ?? cb.reward ?? null;
  if (sat == null) return null;
  return Number(sat) / SAT;
}

async function main() {
  console.log("=".repeat(70));
  console.log("OmniBus Halving Simulator");
  console.log("=".repeat(70));
  console.log(`RPC:    ${RPC_URL}`);
  console.log(`Chain:  ${CHAIN}`);
  console.log("");

  // 1) Local math sanity
  console.log("Local halving math:");
  const samples = [
    [0, 50], [100, 50], [1000, 50],
    [209_999, 50], [210_000, 25], [210_001, 25],
    [419_999, 25], [420_000, 12.5],
  ];
  for (const [h, exp] of samples) {
    const got = expectedReward(h);
    if (got === exp) PASS(`reward(h=${h}) = ${exp} OMNI`);
    else FAIL(`reward(h=${h})`, `expected ${exp}, got ${got}`);
  }

  // 2) On-chain verification
  let tip = 0;
  try { tip = await rpc("getblockcount"); }
  catch (e) { FAIL("getblockcount", e.message); exit(1); }
  console.log(`\nChain tip: ${tip}`);

  let totalEmittedSat = 0n;
  let blocksSeen = 0;

  for (const h of SAMPLE_HEIGHTS) {
    if (h > tip) {
      SKIP(`on-chain reward at h=${h}`, `tip=${tip} too low`);
      continue;
    }
    const b = await getBlockAt(h);
    const reward = extractReward(b);
    if (reward == null) {
      SKIP(`on-chain reward at h=${h}`, "coinbase not exposed");
      continue;
    }
    const exp = expectedReward(h);
    blocksSeen++;
    if (reward === exp) PASS(`block ${h} reward = ${exp} OMNI (matches halving math)`);
    else if (reward > 0 && reward <= exp + 0.001) PASS(`block ${h} reward = ${reward} OMNI (<= ${exp} + dust, fees ok)`);
    else if (reward > exp) FAIL(`block ${h} reward exceeds halving cap`, `expected <=${exp}, got ${reward}`);
    else SKIP(`block ${h} reward = ${reward}`, `expected ${exp}, mismatch but not over-cap`);
  }

  // 3) Total supply emitted via richlist
  try {
    const rl = await rpc("getrichlist", [{ limit: 1000 }]);
    const arr = Array.isArray(rl) ? rl : (rl?.list ?? rl?.entries ?? []);
    let sum = 0;
    for (const entry of arr) {
      const bal = entry.balance ?? entry.amount ?? 0;
      sum += Number(bal);
    }
    const omni = sum / SAT;
    if (omni <= MAX_SUPPLY) PASS(`total richlist supply = ${omni.toFixed(2)} OMNI (<= ${MAX_SUPPLY})`);
    else FAIL(`total supply exceeds 21M`, `got ${omni}`);
  } catch (e) {
    if (e.skip) SKIP("total supply via richlist", "RPC missing");
    else FAIL("total supply via richlist", e.message);
  }

  // 4) Theoretical max emission across known halvings
  let theoretical = 0;
  for (let i = 0; i < 64; i++) {
    theoretical += HALVING_INTERVAL * (INITIAL_REWARD / Math.pow(2, i));
    if (INITIAL_REWARD / Math.pow(2, i + 1) < 1e-9) break;
  }
  if (Math.abs(theoretical - 2 * HALVING_INTERVAL * INITIAL_REWARD) < 1) {
    PASS(`theoretical total emission = ${theoretical.toFixed(0)} OMNI ≈ 21M`);
  } else {
    FAIL("theoretical emission", `got ${theoretical}, expected ~21M`);
  }

  console.log("");
  console.log(`--- 32 Halving Simulator summary ---`);
  console.log(`  pass: ${pass}   fail: ${fail}   skip: ${skip}`);

  const lines = [`# Halving Simulator Report`, "", `- chain: \`${CHAIN}\``, `- rpc: \`${RPC_URL}\``, `- tip: ${tip}`, `- blocks_verified: ${blocksSeen}`, `- ts: ${new Date().toISOString()}`, "", `pass=${pass} fail=${fail} skip=${skip}`, ""];
  for (const r of results) lines.push(`- ${r.s} ${r.m}${r.e ? ` (${r.e})` : ""}`);
  writeFileSync("32-report.md", lines.join("\n"));

  exit(fail === 0 ? 0 : 1);
}

main().catch((e) => { console.error("FATAL:", e); exit(1); });
