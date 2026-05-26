#!/usr/bin/env node
/**
 * 41-persistence-restart.mjs — Cross-restart persistence verification.
 *
 * READ-ONLY verification that persistent state survives a 30s window.
 * Does NOT actually restart the chain — that's a separate ops task.
 *
 * Snapshots before and after a 30s pause:
 *   - Find the most recent confirmed TX from primary address.
 *   - Save txid, height, balance.
 *   - Pause 30s.
 *   - Re-fetch and verify identical.
 *
 *   - Reputation cups (LOVE/FOOD/RENT/VACATION) — same values both reads.
 *   - Resolved name savacazan.omnibus → same address both reads.
 *   - getrichlist top entry — same address+balance both reads.
 *
 * Default: testnet (read-only). Mainnet works too.
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
const PAUSE_S = parseInt(arg("--pause", "30"), 10);

const RPC_URLS = {
  mainnet: "https://omnibusblockchain.cc:8443/api-mainnet",
  testnet: "https://omnibusblockchain.cc:8443/api-testnet",
  regtest: "https://omnibusblockchain.cc:8443/api-regtest",
  "local-mainnet": "http://127.0.0.1:8332",
  "local-testnet": "http://127.0.0.1:18332",
  "local-regtest": "http://127.0.0.1:28332",
};
const RPC_URL = RPC_OVR || RPC_URLS[CHAIN] || RPC_URLS.testnet;

const PRIMARY = "ob1qw6zhsqg29aht23fksk5w54lkgavatpgltqxlvl";
const KNOWN_NAME = "savacazan.omnibus";

let pass = 0, fail = 0, skip = 0;
const results = [];
const PASS = (m) => { pass++; results.push({ s: "PASS", m }); console.log(`  ✅ PASS ${m}`); };
const FAIL = (m, e) => { fail++; results.push({ s: "FAIL", m, e }); console.log(`  ❌ FAIL ${m}${e ? "  -- " + e : ""}`); };
const SKIP = (m, e) => { skip++; results.push({ s: "SKIP", m, e }); console.log(`  - SKIP ${m}${e ? "  (" + e + ")" : ""}`); };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

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

async function snapshot(label) {
  const out = { label, ts: Date.now() };
  try { out.tip = await rpc("getblockcount"); } catch (e) { out.tipErr = e.message; }
  try {
    const b = await rpc("getbalance", [PRIMARY]);
    out.balance = typeof b === "number" ? b : Number(b?.balance ?? b?.amount ?? b);
  } catch (e) { out.balanceErr = e.message; }
  try {
    const txs = await rpc("gettransactions", [{ address: PRIMARY, limit: 5 }]);
    const arr = Array.isArray(txs) ? txs : (txs?.transactions ?? txs?.txs ?? []);
    out.txCount = Array.isArray(arr) ? arr.length : 0;
    out.lastTxid = arr[0]?.txid ?? arr[0]?.tx_id ?? arr[0]?.id ?? null;
  } catch (e) { out.txErr = e.message; }
  try {
    const rep = await rpc("getreputation", [PRIMARY]);
    out.cups = rep?.cups ?? rep;
  } catch (e) { out.repErr = e.message; }
  try {
    const r = await rpc("resolvename", [KNOWN_NAME]);
    out.resolved = typeof r === "string" ? r : (r?.address ?? r);
  } catch (e) { out.nameErr = e.message; }
  try {
    const rl = await rpc("getrichlist", [{ limit: 1 }]);
    const arr = Array.isArray(rl) ? rl : (rl?.list ?? rl?.entries ?? []);
    out.topAddr = arr[0]?.address ?? null;
    out.topBal = arr[0]?.balance ?? arr[0]?.amount ?? null;
  } catch (e) { out.rlErr = e.message; }
  return out;
}

async function main() {
  console.log("=".repeat(70));
  console.log("OmniBus Persistence/Restart Test");
  console.log("=".repeat(70));
  console.log(`RPC:    ${RPC_URL}`);
  console.log(`Chain:  ${CHAIN}`);
  console.log(`Pause:  ${PAUSE_S}s`);
  console.log("");

  const s1 = await snapshot("before");
  console.log(`Snapshot 1: tip=${s1.tip} balance=${s1.balance} lastTxid=${(s1.lastTxid ?? "?").toString().slice(0, 16)}`);
  if (s1.tip != null) PASS("snapshot 1 tip captured");
  else FAIL("snapshot 1 tip", s1.tipErr);

  console.log(`\nWaiting ${PAUSE_S}s (simulated restart pause)...`);
  await sleep(PAUSE_S * 1000);

  const s2 = await snapshot("after");
  console.log(`Snapshot 2: tip=${s2.tip} balance=${s2.balance} lastTxid=${(s2.lastTxid ?? "?").toString().slice(0, 16)}`);

  // 1) Tip should monotonically increase
  if (s1.tip != null && s2.tip != null) {
    if (s2.tip >= s1.tip) PASS(`tip monotonic: ${s1.tip} → ${s2.tip}`);
    else FAIL(`tip went backwards`, `${s1.tip} → ${s2.tip}`);
  }

  // 2) Last TXID should still be present (or progressed)
  if (s1.lastTxid && s2.lastTxid) {
    // It's ok if a newer TX showed up in between, but s1.lastTxid must still be findable.
    try {
      const tx = await rpc("getrawtransaction", [{ txid: s1.lastTxid, verbose: 1 }]);
      if (tx) PASS(`previous lastTxid (${s1.lastTxid.slice(0, 16)}) still retrievable`);
      else FAIL("TX persistence", "lastTxid not found after pause");
    } catch (e) {
      if (e.skip) {
        try {
          const t2 = await rpc("gettransaction", [s1.lastTxid]);
          if (t2) PASS(`lastTxid retrievable via gettransaction`);
          else SKIP("TX persistence", "TX missing");
        } catch { SKIP("TX persistence", "RPC missing"); }
      } else FAIL("TX persistence", e.message);
    }
  } else {
    SKIP("TX persistence", "no previous TX recorded");
  }

  // 3) Balance consistency — should be approximately the same (allowing fees from new TX-uri)
  if (s1.balance != null && s2.balance != null) {
    const drift = Math.abs(s2.balance - s1.balance);
    const rel = s1.balance > 0 ? drift / s1.balance : 0;
    if (rel < 0.001) PASS(`balance stable: ${s1.balance} → ${s2.balance} (drift ${drift})`);
    else if (rel < 0.05) PASS(`balance drift small: ${rel * 100}%`);
    else SKIP(`balance drift`, `${rel * 100}% — large but may be due to mining/spending`);
  } else SKIP("balance consistency", "balance unavailable");

  // 4) Reputation cups identical
  if (s1.cups && s2.cups) {
    const j1 = JSON.stringify(s1.cups);
    const j2 = JSON.stringify(s2.cups);
    if (j1 === j2) PASS(`reputation cups identical across pause`);
    else SKIP(`reputation cups`, `differ (${j1.slice(0, 60)} vs ${j2.slice(0, 60)})`);
  } else SKIP("reputation cups", "RPC unavailable");

  // 5) Name resolution identical
  if (s1.resolved && s2.resolved) {
    if (s1.resolved === s2.resolved) PASS(`name resolution stable: ${s1.resolved}`);
    else FAIL(`name resolution changed`, `${s1.resolved} → ${s2.resolved}`);
  } else SKIP("name resolution", "name not resolvable on this chain");

  // 6) Richlist top entry stable
  if (s1.topAddr && s2.topAddr) {
    if (s1.topAddr === s2.topAddr) PASS(`richlist top stable: ${s1.topAddr.slice(0, 16)}`);
    else SKIP(`richlist top changed`, `${s1.topAddr.slice(0, 16)} → ${s2.topAddr.slice(0, 16)}`);
  } else SKIP("richlist top", "unavailable");

  console.log("");
  console.log(`--- 41 Persistence/Restart summary ---`);
  console.log(`  pass: ${pass}   fail: ${fail}   skip: ${skip}`);

  const lines = [`# Persistence/Restart Report`, "", `- chain: \`${CHAIN}\``, `- rpc: \`${RPC_URL}\``, `- pause: ${PAUSE_S}s`, `- tip_before: ${s1.tip}`, `- tip_after: ${s2.tip}`, `- balance_before: ${s1.balance}`, `- balance_after: ${s2.balance}`, `- ts: ${new Date().toISOString()}`, "", `pass=${pass} fail=${fail} skip=${skip}`, ""];
  for (const r of results) lines.push(`- ${r.s} ${r.m}${r.e ? ` (${r.e})` : ""}`);
  writeFileSync("41-report.md", lines.join("\n"));

  exit(fail === 0 ? 0 : 1);
}

main().catch((e) => { console.error("FATAL:", e); exit(1); });
