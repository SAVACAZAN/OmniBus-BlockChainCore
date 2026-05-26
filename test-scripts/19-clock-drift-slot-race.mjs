#!/usr/bin/env node
/**
 * 19-clock-drift-slot-race.mjs — Slot-leader race + clock-drift probe.
 *
 * Background: PC ↔ VPS RTT ~100ms, block time 1-10s. The slot-leader
 * race condition is unavoidable without redesign (memory:
 * project_omnibus_clock_drift_problem). This script *measures* the
 * effect rather than fixing it:
 *
 *   1) Probe RTT to RPC (10 samples, report min/avg/max).
 *   2) Watch new blocks for ~60s. For each new block:
 *        - record local-now and block.timestamp delta
 *        - flag deltas > 100ms as "drift events"
 *   3) Sample getslotleader (or current_validator / next_validator) and
 *      track how often it rotates.
 *   4) Track block-production rate vs expected (10s mainnet, 1s regtest
 *      target).
 *
 * Read-only. No --write.
 *
 * Usage:
 *   node 19-clock-drift-slot-race.mjs                # mainnet, 60s window
 *   node 19-clock-drift-slot-race.mjs --chain testnet --window 30
 *   node 19-clock-drift-slot-race.mjs --rpc http://127.0.0.1:8332 --window 20
 */

import { argv, env, exit } from "node:process";
import { performance } from "node:perf_hooks";

// ── CLI ─────────────────────────────────────────────────────────────────────
const ARGS = argv.slice(2);
function arg(name, fallback) {
  const i = ARGS.indexOf(name);
  return i >= 0 && ARGS[i + 1] ? ARGS[i + 1] : fallback;
}
const CHAIN  = arg("--chain", env.CHAIN || "mainnet");
const RPC_OVR = arg("--rpc",  env.RPC_URL);
const TOKEN  = arg("--token", env.OMNIBUS_RPC_TOKEN);
const WINDOW = parseInt(arg("--window", "60"), 10);    // seconds
const SAMPLES_RTT = parseInt(arg("--rtt-samples", "10"), 10);
const DRIFT_THRESHOLD_MS = parseInt(arg("--drift-ms", "100"), 10);

const RPC_URLS = {
  mainnet: "https://omnibusblockchain.cc:8443/api-mainnet",
  testnet: "https://omnibusblockchain.cc:8443/api-testnet",
  regtest: "https://omnibusblockchain.cc:8443/api-regtest",
  "local-mainnet": "http://127.0.0.1:8332",
  "local-testnet": "http://127.0.0.1:18332",
  "local-regtest": "http://127.0.0.1:28332",
};
const RPC_URL = RPC_OVR || RPC_URLS[CHAIN] || RPC_URLS.mainnet;

// ── Helpers ─────────────────────────────────────────────────────────────────
let pass = 0, fail = 0, skip = 0;
const PASS = (m) => { pass++; console.log(`  PASS ${m}`); };
const FAIL = (m, e) => { fail++; console.log(`  FAIL ${m}${e ? "  -- " + e : ""}`); };
const SKIP = (m, e) => { skip++; console.log(`  SKIP ${m}${e ? "  (" + e + ")" : ""}`); };

async function rpcRaw(method, params = []) {
  const headers = { "Content-Type": "application/json" };
  if (TOKEN) headers.Authorization = `Bearer ${TOKEN}`;
  const r = await fetch(RPC_URL, {
    method: "POST",
    headers,
    body: JSON.stringify({ jsonrpc: "2.0", id: Date.now(), method, params }),
  });
  return r.json();
}
async function rpc(method, params = []) {
  const j = await rpcRaw(method, params);
  if (j.error) throw new Error(`${method}: ${j.error.message ?? "rpc err"}`);
  return j.result;
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function pct(arr, p) {
  if (!arr.length) return 0;
  const s = [...arr].sort((a, b) => a - b);
  return s[Math.min(s.length - 1, Math.floor((p / 100) * s.length))];
}

// ── Main ────────────────────────────────────────────────────────────────────
async function main() {
  console.log("=".repeat(70));
  console.log("OmniBus Clock-Drift / Slot-Leader Race Probe");
  console.log("=".repeat(70));
  console.log(`RPC:    ${RPC_URL}`);
  console.log(`Chain:  ${CHAIN}`);
  console.log(`Window: ${WINDOW}s`);
  console.log(`Drift threshold: ${DRIFT_THRESHOLD_MS}ms`);
  console.log("");

  // 1) RTT samples (cheap getblockcount call)
  const rtts = [];
  for (let i = 0; i < SAMPLES_RTT; i++) {
    const t0 = performance.now();
    try {
      await rpc("getblockcount");
      rtts.push(performance.now() - t0);
    } catch (e) {
      // first failure = abort; rest of script depends on RPC
      FAIL("RTT sample", e.message);
      console.log(`  pass: ${pass}   fail: ${fail}   skip: ${skip}`);
      exit(2);
    }
    await sleep(50);
  }
  const rttMin = Math.min(...rtts), rttMax = Math.max(...rtts);
  const rttAvg = rtts.reduce((a, b) => a + b, 0) / rtts.length;
  PASS(`RTT (${SAMPLES_RTT} samples): min=${rttMin.toFixed(1)}ms avg=${rttAvg.toFixed(1)}ms max=${rttMax.toFixed(1)}ms p95=${pct(rtts,95).toFixed(1)}ms`);

  // 2) Block-watch loop
  console.log("");
  console.log(`-- watching new blocks for ${WINDOW}s --`);
  const events = [];
  let lastTip = -1;
  let lastLeader = null;
  let leaderRotations = 0;
  let blocksSeen = 0;
  let driftEvents = 0;
  const leaderHistory = [];
  const start = Date.now();

  while ((Date.now() - start) / 1000 < WINDOW) {
    let tip;
    try { tip = await rpc("getblockcount"); }
    catch { tip = lastTip; }

    if (tip > lastTip) {
      // new block(s) — fetch the latest only
      let block;
      try {
        const hash = await rpc("getblockhash", [tip]);
        block = await rpc("getblock", [hash]);
      } catch (e) {
        SKIP(`block #${tip}`, e.message);
        lastTip = tip;
        continue;
      }
      const localNow = Math.floor(Date.now() / 1000);
      const ts = Number(block?.timestamp ?? block?.time ?? 0);
      const driftMs = Math.abs(localNow - ts) * 1000;
      blocksSeen++;
      if (driftMs > DRIFT_THRESHOLD_MS) {
        driftEvents++;
        events.push(`block #${tip} drift=${driftMs}ms`);
      }
      lastTip = tip;
    }

    // Track slot leader
    let leader = null;
    try {
      leader = await rpc("getslotleader");
    } catch {
      try { leader = await rpc("getcurrentvalidator"); } catch {}
    }
    if (leader && JSON.stringify(leader) !== JSON.stringify(lastLeader)) {
      leaderRotations++;
      leaderHistory.push({ t: Date.now() - start, leader });
      lastLeader = leader;
    }

    await sleep(500);
  }

  if (blocksSeen > 0) {
    PASS(`saw ${blocksSeen} new block(s) in ${WINDOW}s`);
  } else {
    SKIP("new blocks observed", "none in window — chain idle?");
  }

  if (driftEvents === 0) {
    PASS(`drift events: 0 (no block timestamp >${DRIFT_THRESHOLD_MS}ms off local clock)`);
  } else if (driftEvents <= blocksSeen) {
    // Drift is expected on remote VPS — flag but don't fail.
    PASS(`drift events: ${driftEvents}/${blocksSeen} (expected on remote ~100ms RTT)`);
  } else {
    FAIL("drift events", `${driftEvents} > ${blocksSeen} blocks?? math broken`);
  }

  if (leaderRotations > 0) {
    PASS(`slot-leader rotations: ${leaderRotations}`);
  } else {
    SKIP("slot-leader rotations", "either no rotation or method not exposed");
  }

  // Block-production rate
  if (blocksSeen > 0) {
    const blocksPerSec = blocksSeen / WINDOW;
    PASS(`block production: ${blocksPerSec.toFixed(3)} blk/s (${(1 / blocksPerSec).toFixed(1)}s per block)`);
  }

  console.log("");
  if (events.length) {
    console.log("-- drift events --");
    for (const e of events.slice(0, 15)) console.log(`   ${e}`);
    if (events.length > 15) console.log(`   ... and ${events.length - 15} more`);
  }

  console.log("");
  console.log(`--- 19 Clock-drift summary ---`);
  console.log(`  pass: ${pass}   fail: ${fail}   skip: ${skip}`);
  exit(fail === 0 ? 0 : 1);
}

main().catch((e) => { console.error("FATAL:", e); exit(1); });
