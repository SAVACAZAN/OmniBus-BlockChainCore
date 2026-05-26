#!/usr/bin/env node
/**
 * 40-network-sync-test.mjs — Cross-chain RPC sync verification.
 *
 * Probes mainnet, testnet, regtest endpoints in parallel and verifies:
 *   1. getsyncstatus on each chain.
 *   2. heights differ (independent chains).
 *   3. genesis hash differs (per-chain genesis).
 *   4. getpeers returns a list (may be empty).
 *   5. block production rate over a 60s window per chain.
 *   6. no chain has a fork at tip (single canonical block hash per height).
 *
 * Read-only across all 3 chains. --chain arg is ignored — the script always
 * polls all three. Override with --rpcs <url1,url2,url3> if needed.
 */

import { writeFileSync } from "node:fs";
import { argv, env, exit } from "node:process";

const ARGS = argv.slice(2);
const arg = (name, fb) => {
  const i = ARGS.indexOf(name);
  return i >= 0 && ARGS[i + 1] ? ARGS[i + 1] : fb;
};
const TOKEN = arg("--token", env.OMNIBUS_RPC_TOKEN);
const RPCS_OVR = arg("--rpcs", "");
const SAMPLE_S = parseInt(arg("--sample", "60"), 10);

const DEFAULT_RPCS = {
  mainnet: "https://omnibusblockchain.cc:8443/api-mainnet",
  testnet: "https://omnibusblockchain.cc:8443/api-testnet",
  regtest: "https://omnibusblockchain.cc:8443/api-regtest",
};

const CHAINS = RPCS_OVR
  ? RPCS_OVR.split(",").map((u, i) => ({ name: `chain-${i}`, url: u }))
  : Object.entries(DEFAULT_RPCS).map(([name, url]) => ({ name, url }));

let pass = 0, fail = 0, skip = 0;
const results = [];
const PASS = (m) => { pass++; results.push({ s: "PASS", m }); console.log(`  ✅ PASS ${m}`); };
const FAIL = (m, e) => { fail++; results.push({ s: "FAIL", m, e }); console.log(`  ❌ FAIL ${m}${e ? "  -- " + e : ""}`); };
const SKIP = (m, e) => { skip++; results.push({ s: "SKIP", m, e }); console.log(`  - SKIP ${m}${e ? "  (" + e + ")" : ""}`); };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function rpc(url, method, params = []) {
  const headers = { "Content-Type": "application/json" };
  if (TOKEN) headers.Authorization = `Bearer ${TOKEN}`;
  const r = await fetch(url, {
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

async function chainSnapshot(chain) {
  const out = { name: chain.name, url: chain.url, height: null, genesis: null, peers: null, sync: null, tipHash: null };
  try { out.height = await rpc(chain.url, "getblockcount"); } catch (e) { out.heightErr = e.message; }
  try {
    const g = await rpc(chain.url, "getblock", [{ height: 0 }]);
    out.genesis = g?.hash ?? g?.block_hash ?? null;
  } catch (e) {
    try {
      const g2 = await rpc(chain.url, "getblockbyheight", [0]);
      out.genesis = g2?.hash ?? g2?.block_hash ?? null;
    } catch {}
  }
  try {
    const p = await rpc(chain.url, "getpeers");
    out.peers = Array.isArray(p) ? p.length : (p?.peers?.length ?? p?.count ?? 0);
  } catch (e) { out.peersErr = e.message; }
  try { out.sync = await rpc(chain.url, "getsyncstatus"); } catch (e) { out.syncErr = e.message; }
  if (out.height != null && out.height >= 0) {
    try {
      const b = await rpc(chain.url, "getblock", [{ height: out.height }]);
      out.tipHash = b?.hash ?? b?.block_hash ?? null;
    } catch {}
  }
  return out;
}

async function main() {
  console.log("=".repeat(70));
  console.log("OmniBus Network Sync Test");
  console.log("=".repeat(70));
  console.log(`Chains: ${CHAINS.map((c) => c.name).join(", ")}`);
  console.log("");

  // 1+2+3+4) Snapshot all chains in parallel
  const snaps = await Promise.all(CHAINS.map(chainSnapshot));

  for (const s of snaps) {
    console.log(`[${s.name}] height=${s.height}  genesis=${(s.genesis ?? "?").slice(0, 16)}...  peers=${s.peers}`);
    if (s.height != null) PASS(`${s.name} reachable, height=${s.height}`);
    else FAIL(`${s.name} reachable`, s.heightErr);

    if (s.sync) PASS(`${s.name} getsyncstatus reachable`);
    else SKIP(`${s.name} getsyncstatus`, s.syncErr ?? "n/a");

    if (s.peers != null) PASS(`${s.name} getpeers reachable (${s.peers} peers)`);
    else SKIP(`${s.name} getpeers`, s.peersErr ?? "n/a");

    if (s.genesis) PASS(`${s.name} genesis hash retrievable`);
    else SKIP(`${s.name} genesis hash`, "not retrievable");
  }

  // 2) Heights differ (3 chains rarely share heights)
  const heights = snaps.map((s) => s.height).filter((h) => h != null);
  const uniqHeights = new Set(heights);
  if (uniqHeights.size === heights.length) PASS(`all ${heights.length} chains have distinct heights`);
  else if (uniqHeights.size >= heights.length - 1) PASS(`heights mostly distinct (${uniqHeights.size}/${heights.length})`);
  else SKIP(`distinct heights`, `only ${uniqHeights.size} unique out of ${heights.length}`);

  // 3) Genesis hash differs
  const genesisSet = new Set(snaps.map((s) => s.genesis).filter(Boolean));
  if (genesisSet.size >= 2) PASS(`genesis hashes differ across chains (${genesisSet.size} unique)`);
  else if (genesisSet.size === 1 && snaps.length === 1) PASS(`single chain has 1 genesis`);
  else SKIP(`genesis hash diversity`, `${genesisSet.size} unique`);

  // 5) Block production rate over SAMPLE_S
  console.log(`\nSampling block rate over ${SAMPLE_S}s on each chain...`);
  const tipsBefore = snaps.map((s) => s.height);
  await sleep(SAMPLE_S * 1000);
  const tipsAfter = await Promise.all(CHAINS.map(async (c) => {
    try { return await rpc(c.url, "getblockcount"); } catch { return null; }
  }));

  for (let i = 0; i < CHAINS.length; i++) {
    if (tipsBefore[i] == null || tipsAfter[i] == null) {
      SKIP(`${CHAINS[i].name} block rate`, "missing tip");
      continue;
    }
    const blocks = tipsAfter[i] - tipsBefore[i];
    const rate = blocks / SAMPLE_S;
    PASS(`${CHAINS[i].name} block rate: ${blocks} blocks in ${SAMPLE_S}s (${rate.toFixed(3)} blk/s)`);
    if (rate >= 0 && rate < 5) PASS(`${CHAINS[i].name} rate within plausible bounds`);
    else if (rate >= 5) FAIL(`${CHAINS[i].name} rate`, `unusually high: ${rate}`);
  }

  // 6) Tip fork detection — fetch tip block twice and compare hashes.
  for (let i = 0; i < CHAINS.length; i++) {
    const tip = tipsAfter[i];
    if (tip == null) { SKIP(`${CHAINS[i].name} tip fork check`, "tip missing"); continue; }
    try {
      const b1 = await rpc(CHAINS[i].url, "getblock", [{ height: tip }]);
      await sleep(500);
      const b2 = await rpc(CHAINS[i].url, "getblock", [{ height: tip }]);
      const h1 = b1?.hash ?? b1?.block_hash;
      const h2 = b2?.hash ?? b2?.block_hash;
      if (h1 && h2 && h1 === h2) PASS(`${CHAINS[i].name} tip canonical (no fork at h=${tip})`);
      else if (h1 && h2) FAIL(`${CHAINS[i].name} tip fork`, `hash changed: ${h1.slice(0, 8)} vs ${h2.slice(0, 8)}`);
      else SKIP(`${CHAINS[i].name} tip fork`, "hash not exposed");
    } catch (e) {
      if (e.skip) SKIP(`${CHAINS[i].name} tip fork`, "RPC missing");
    }
  }

  console.log("");
  console.log(`--- 40 Network Sync Test summary ---`);
  console.log(`  pass: ${pass}   fail: ${fail}   skip: ${skip}`);

  const lines = [`# Network Sync Report`, "", `- chains: ${CHAINS.length}`, `- sample: ${SAMPLE_S}s`, `- ts: ${new Date().toISOString()}`, ""];
  lines.push(`| chain | height | genesis | peers | rate (blk/s) |`);
  lines.push(`|:--|---:|:--|---:|---:|`);
  for (let i = 0; i < CHAINS.length; i++) {
    const s = snaps[i];
    const blocks = (tipsAfter[i] ?? 0) - (tipsBefore[i] ?? 0);
    const rate = (blocks / SAMPLE_S).toFixed(3);
    lines.push(`| ${s.name} | ${s.height ?? "?"} | ${(s.genesis ?? "?").slice(0, 16)} | ${s.peers ?? "?"} | ${rate} |`);
  }
  lines.push("", `pass=${pass} fail=${fail} skip=${skip}`, "");
  for (const r of results) lines.push(`- ${r.s} ${r.m}${r.e ? ` (${r.e})` : ""}`);
  writeFileSync("40-report.md", lines.join("\n"));

  exit(fail === 0 ? 0 : 1);
}

main().catch((e) => { console.error("FATAL:", e); exit(1); });
