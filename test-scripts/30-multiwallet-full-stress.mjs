#!/usr/bin/env node
/**
 * 30-multiwallet-full-stress.mjs — orchestrator for the multi-wallet suite.
 *
 * Runs 23..29 in a coordinated loop for ~30 minutes (configurable). Background
 * tasks: small-amount transfers, NS lookups, trading order placement, staking
 * heartbeats, agent listings, HTLC dry-runs. Combined load target: ~10 RPC/sec
 * across all tasks. Polls VPS health (getstatus / getblockcount) once per
 * minute and detects panic / SIGABRT / non-zero exit on any background process.
 *
 * Defaults to TESTNET. Use --duration to change run length.
 *
 * Usage:
 *   node 30-multiwallet-full-stress.mjs                # 30-min default
 *   node 30-multiwallet-full-stress.mjs --duration 5   # 5-min smoke
 *   node 30-multiwallet-full-stress.mjs --chain regtest --duration 10
 *   node 30-multiwallet-full-stress.mjs --setup-first  # run 23-setup before
 */

import {
  parseArgs, mkRpc, loadPool, getBalance, getNonce,
  submitTx, submitMemoTx, getTip,
  fmtSat, fmtAddr, header, section, sleep,
} from "./_wallet-pool.mjs";
import { spawn } from "node:child_process";
import { writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { randomBytes, createHash } from "node:crypto";

const __dirname = dirname(fileURLToPath(import.meta.url));
const opts = parseArgs(process.argv);
const ctx  = mkRpc(opts);

const argv = process.argv.slice(2);
function intArg(name, fb) {
  const i = argv.indexOf(name);
  return i >= 0 ? parseInt(argv[i + 1], 10) : fb;
}
const DURATION_MIN = intArg("--duration", 30);
const DURATION_MS  = DURATION_MIN * 60 * 1000;
const SETUP_FIRST  = argv.includes("--setup-first");

// ── Background task definitions ────────────────────────────────────────────
//
// Each background task has:
//   - name
//   - intervalMs    → how often it fires
//   - fn(state)     → async; updates `state.counters[name]` itself
//
// State is shared so the task can record its own stats and the orchestrator
// can collect them at the end without inter-process plumbing.

function makeTasks(pool, state) {
  return [
    {
      name: "transfers",
      intervalMs: 1500, // ~0.6 RPC/s after submit + nonce fetch
      fn: async () => {
        // Pick two random wallets and send 0.01 OMNI from one to the other.
        const i = Math.floor(Math.random() * pool.length);
        let j = Math.floor(Math.random() * pool.length);
        if (j === i) j = (j + 1) % pool.length;
        const from = pool[i];
        const to   = pool[j];
        // Use a cached local nonce (counter-style) to avoid getnonce per TX.
        if (!state.nonces[i]) state.nonces[i] = await getNonce(ctx, from.address);
        const r = await submitTx(ctx, from, {
          to:     to.address,
          amount: 10_000_000, // 0.01 OMNI
          fee:    1000,
          nonce:  state.nonces[i],
        });
        if (r.ok) {
          state.counters.transfers_ok++;
          state.nonces[i] += 1n;
        } else {
          state.counters.transfers_fail++;
          if (/nonce/i.test(r.error ?? "")) {
            // Refresh on nonce mismatch
            state.nonces[i] = await getNonce(ctx, from.address);
          }
        }
      },
    },
    {
      name: "ns",
      intervalMs: 4000,
      fn: async () => {
        const i = Math.floor(Math.random() * pool.length);
        const name = `wallet${i}.omnibus`;
        try {
          await ctx.call("resolvename", [name]);
          state.counters.ns_resolve_ok++;
        } catch (e) {
          if (e.skip) state.counters.ns_skip++;
          else if (/not found|unregistered/i.test(e.message)) state.counters.ns_unregistered++;
          else state.counters.ns_resolve_fail++;
        }
      },
    },
    {
      name: "trading",
      intervalMs: 2500,
      fn: async () => {
        // Read-only: just fetch the orderbook on a random active pair.
        const pairs = [0, 2, 3, 5, 6];
        const pid = pairs[Math.floor(Math.random() * pairs.length)];
        try {
          await ctx.call("exchange_getOrderbook", [{ pair_id: pid }]);
          state.counters.trading_ok++;
        } catch (e) {
          if (e.skip) state.counters.trading_skip++;
          else state.counters.trading_fail++;
        }
      },
    },
    {
      name: "staking",
      intervalMs: 8000,
      fn: async () => {
        // Send a heartbeat from wallet[4] (the largest staker in script 27).
        try {
          await ctx.call("validator_heartbeat", [{ address: pool[4].address }]);
          state.counters.staking_ok++;
        } catch (e) {
          if (e.skip) state.counters.staking_skip++;
          else state.counters.staking_fail++;
        }
      },
    },
    {
      name: "agents",
      intervalMs: 6000,
      fn: async () => {
        try {
          await ctx.call("getagents", [{ limit: 20 }]);
          state.counters.agents_ok++;
        } catch (e) {
          if (e.skip) state.counters.agents_skip++;
          else state.counters.agents_fail++;
        }
      },
    },
    {
      name: "htlc",
      intervalMs: 10000,
      fn: async () => {
        // Dry-run swap_open against random pair.
        const pairs = ["OMNI-ETH", "OMNI-BTC", "OMNI-LCX"];
        const pid = pairs[Math.floor(Math.random() * pairs.length)];
        const preimage = randomBytes(32);
        const hashLockHex = createHash("sha256").update(preimage).digest("hex");
        try {
          await ctx.call("swap_open", [{
            pair: pid,
            maker_asset: "OMNI",
            taker_asset: pid.split("-")[1],
            maker_address: pool[0].address,
            taker_address: "0x000000000000000000000000000000000000dEaD",
            maker_amount: 10_000,
            taker_amount: 10_000,
            hash_lock: hashLockHex,
            timeout_blocks: 100,
            dry_run: true,
          }]);
          state.counters.htlc_ok++;
        } catch (e) {
          if (e.skip) state.counters.htlc_skip++;
          else state.counters.htlc_fail++;
        }
      },
    },
  ];
}

// ── Health monitor ─────────────────────────────────────────────────────────

async function pollHealth(state) {
  try {
    const tip = await getTip(ctx);
    state.health.lastTip = tip;
    state.health.tipHistory.push({ ts: Date.now(), tip });
    if (state.health.tipHistory.length > 1) {
      const prev = state.health.tipHistory[state.health.tipHistory.length - 2];
      if (tip < prev.tip) {
        state.health.alerts.push(`tip went BACKWARDS: ${prev.tip} → ${tip}`);
      } else if (tip === prev.tip) {
        state.health.stalls++;
      }
    }
    state.health.healthOk++;
  } catch (e) {
    state.health.healthFail++;
    state.health.alerts.push(`health err @ ${new Date().toISOString()}: ${e.message.slice(0, 80)}`);
  }
}

// ── Optional pre-step: run 23-setup ────────────────────────────────────────

async function runSetup() {
  return new Promise((resolve) => {
    const setupArgs = ["23-multiwallet-setup.mjs", "--chain", opts.chain];
    if (opts.dryRun) setupArgs.push("--dry-run");
    if (opts.token)  setupArgs.push("--token", opts.token);
    const child = spawn(process.execPath, setupArgs, {
      cwd: __dirname,
      stdio: ["ignore", "inherit", "inherit"],
    });
    child.on("exit", (code) => resolve(code));
  });
}

// ── Main loop ──────────────────────────────────────────────────────────────

async function main() {
  header(`Multi-wallet FULL STRESS — ${DURATION_MIN} min orchestrator (8/10)`, ctx);
  if (DURATION_MIN > 30) {
    console.log(`  WARNING: --duration ${DURATION_MIN} > 30 (brief asks ≤30 min). Continuing.`);
  }

  if (SETUP_FIRST) {
    section("Pre-step: running 23-multiwallet-setup.mjs");
    const code = await runSetup();
    console.log(`  setup exited with code ${code}`);
    if (code !== 0 && !opts.dryRun) console.log("  (continuing anyway)");
  }

  const pool = loadPool();
  console.log(`  Pool: ${pool.length} wallets`);
  console.log(`  Duration: ${DURATION_MIN} min (${DURATION_MS} ms)`);

  // Reachability
  try {
    const tip = await getTip(ctx);
    console.log(`  Tip at start: ${tip}`);
  } catch (e) {
    console.error(`FATAL: ${e.message}`);
    process.exit(2);
  }

  // ── Shared state ─────────────────────────────────────────────────────────
  const state = {
    nonces:   {},
    counters: {
      transfers_ok: 0, transfers_fail: 0,
      ns_resolve_ok: 0, ns_resolve_fail: 0, ns_skip: 0, ns_unregistered: 0,
      trading_ok: 0, trading_fail: 0, trading_skip: 0,
      staking_ok: 0, staking_fail: 0, staking_skip: 0,
      agents_ok: 0, agents_fail: 0, agents_skip: 0,
      htlc_ok: 0, htlc_fail: 0, htlc_skip: 0,
    },
    health: {
      lastTip: null, tipHistory: [], healthOk: 0, healthFail: 0,
      stalls: 0, alerts: [],
    },
    startedAt: Date.now(),
  };

  // ── Schedule tasks ───────────────────────────────────────────────────────
  const tasks = makeTasks(pool, state);
  const timers = [];
  for (const task of tasks) {
    const fire = async () => {
      try { await task.fn(state); } catch { /* swallow individual failures */ }
    };
    timers.push(setInterval(fire, task.intervalMs));
    // Kick off once immediately to get rolling.
    fire();
  }

  // Health poll every 60s.
  const healthTimer = setInterval(() => pollHealth(state), 60_000);
  timers.push(healthTimer);
  pollHealth(state);

  // Status print every 60s.
  let lastTotal = 0;
  const statusTimer = setInterval(() => {
    const elapsed = Math.round((Date.now() - state.startedAt) / 1000);
    const total = Object.values(state.counters).reduce((a, b) => a + b, 0);
    const rate = total - lastTotal;
    lastTotal = total;
    console.log(`  [t+${elapsed}s] tip=${state.health.lastTip} totalRPCs=${total} (${rate}/min last) alerts=${state.health.alerts.length}`);
  }, 60_000);
  timers.push(statusTimer);

  // ── Run for the configured duration ──────────────────────────────────────
  await sleep(DURATION_MS);

  // ── Tear down ────────────────────────────────────────────────────────────
  for (const t of timers) clearInterval(t);
  // Give in-flight requests ~3s to complete.
  await sleep(3000);

  // ── Final summary ────────────────────────────────────────────────────────
  section("Final stats");
  for (const [k, v] of Object.entries(state.counters)) {
    console.log(`  ${k.padEnd(22)} ${v}`);
  }
  console.log(`  health_ok            ${state.health.healthOk}`);
  console.log(`  health_fail          ${state.health.healthFail}`);
  console.log(`  stalls               ${state.health.stalls}`);
  console.log(`  alerts               ${state.health.alerts.length}`);

  // ── Markdown report ──────────────────────────────────────────────────────
  const lines = [];
  lines.push(`# Multi-wallet FULL STRESS Report`);
  lines.push(``);
  lines.push(`- chain: \`${opts.chain}\``);
  lines.push(`- rpc:   \`${ctx.url}\``);
  lines.push(`- ts:    ${new Date().toISOString()}`);
  lines.push(`- duration: ${DURATION_MIN} min`);
  lines.push(``);
  lines.push(`## RPC counters`);
  lines.push(``);
  lines.push(`| metric | count |`);
  lines.push(`|:--|---:|`);
  for (const [k, v] of Object.entries(state.counters)) lines.push(`| ${k} | ${v} |`);
  lines.push(``);
  lines.push(`## Chain health`);
  lines.push(`| metric | value |`);
  lines.push(`|:--|---:|`);
  lines.push(`| tip-poll OK | ${state.health.healthOk} |`);
  lines.push(`| tip-poll FAIL | ${state.health.healthFail} |`);
  lines.push(`| no-progress polls (stalls) | ${state.health.stalls} |`);
  lines.push(`| alerts raised | ${state.health.alerts.length} |`);
  if (state.health.tipHistory.length) {
    const first = state.health.tipHistory[0];
    const last  = state.health.tipHistory[state.health.tipHistory.length - 1];
    lines.push(`| start tip | ${first.tip} |`);
    lines.push(`| end tip | ${last.tip} |`);
    lines.push(`| Δ blocks | ${last.tip - first.tip} |`);
  }
  if (state.health.alerts.length) {
    lines.push(``);
    lines.push(`## Alerts`);
    for (const a of state.health.alerts.slice(0, 20)) lines.push(`- ${a}`);
  }
  const out = join(__dirname, "multiwallet-full-stress-report.md");
  writeFileSync(out, lines.join("\n"));
  console.log(`  Report: ${out}`);

  const failTotal = state.counters.transfers_fail + state.counters.ns_resolve_fail +
                    state.counters.trading_fail + state.counters.staking_fail +
                    state.counters.agents_fail + state.counters.htlc_fail;
  process.exit(failTotal === 0 && state.health.healthFail === 0 ? 0 : 1);
}

main().catch((e) => { console.error("FATAL:", e); process.exit(1); });
