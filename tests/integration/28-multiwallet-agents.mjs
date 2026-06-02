#!/usr/bin/env node
/**
 * 28-multiwallet-agents.mjs — Agent registration flow.
 *
 * Three wallets register agents with distinct strategies:
 *   wallet0 → arbitrage
 *   wallet1 → market_maker
 *   wallet2 → oracle_relay
 *
 * Other wallets `agent_follow` the registered agents, then we exercise
 * agent_edit (change fee_bps) and agent_unregister.
 *
 * Defaults to TESTNET. Use --dry-run for read-only inspection.
 *
 * Usage:
 *   node 28-multiwallet-agents.mjs
 *   node 28-multiwallet-agents.mjs --dry-run
 *   node 28-multiwallet-agents.mjs --chain regtest
 */

import {
  parseArgs, mkRpc, loadPool, fmtAddr,
  header, section, sleep,
} from "./_wallet-pool.mjs";
import { writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const opts = parseArgs(process.argv);
const ctx  = mkRpc(opts);

const AGENTS = [
  { walletIdx: 0, strategy: "arbitrage",     fee_bps: 10, name: "alex-arb" },
  { walletIdx: 1, strategy: "market_maker",  fee_bps: 25, name: "alex-mm"  },
  { walletIdx: 2, strategy: "oracle_relay",  fee_bps: 5,  name: "alex-oracle" },
];

async function main() {
  header("Multi-wallet agents (6/10)", ctx);
  const pool = loadPool();
  console.log(`  Agents to register: ${AGENTS.length}`);

  // Reachability probe + initial agent count.
  let preCount = 0;
  try {
    const r = await ctx.call("getagents", [{ limit: 100 }]);
    const arr = Array.isArray(r) ? r : (r?.agents ?? []);
    preCount = Array.isArray(arr) ? arr.length : 0;
    console.log(`  Pre-existing agents: ${preCount}`);
  } catch (e) {
    console.log(`  getagents: ${e.skip ? "SKIP" : `ERR ${e.message.slice(0, 60)}`}`);
  }

  const stats = {
    registered: 0, registerFailed: 0,
    followed: 0, followFailed: 0,
    edited: 0, editFailed: 0,
    unregistered: 0, unregisterFailed: 0,
    listedAgents: 0,
    errors: [],
  };

  // ── 1) Register 3 agents ─────────────────────────────────────────────────
  if (!opts.dryRun) {
    section("agent_register (3 distinct strategies)");
    for (const a of AGENTS) {
      const w = pool[a.walletIdx];
      try {
        const r = await ctx.call("agent_register", [{
          owner: w.address,
          name:  a.name,
          strategy: a.strategy,
          fee_bps: a.fee_bps,
        }]);
        if (r) {
          stats.registered++;
          console.log(`  ${w.label} → ${a.strategy.padEnd(14)} (${a.name}) → OK ${JSON.stringify(r).slice(0, 60)}`);
        }
      } catch (e) {
        stats.registerFailed++;
        stats.errors.push(`register ${a.name}: ${e.message.slice(0, 60)}`);
        console.log(`  ${w.label} → ${a.strategy} → ${e.skip ? "SKIP" : `FAIL ${e.message.slice(0, 60)}`}`);
      }
      await sleep(80);
    }
  }

  // ── 2) Wallet1 follows wallet0's agent, wallet5 follows wallet2's ────────
  if (!opts.dryRun) {
    section("agent_follow (cross-wallet follow)");
    const followPairs = [
      { follower: pool[1], target: pool[0], targetAgent: AGENTS[0].name },
      { follower: pool[5], target: pool[2], targetAgent: AGENTS[2].name },
      { follower: pool[8], target: pool[1], targetAgent: AGENTS[1].name },
    ];
    for (const f of followPairs) {
      try {
        const r = await ctx.call("agent_follow", [{
          follower: f.follower.address,
          owner:    f.target.address,
          agent:    f.targetAgent,
        }]);
        if (r) {
          stats.followed++;
          console.log(`  ${f.follower.label} → ${f.targetAgent} → OK`);
        }
      } catch (e) {
        stats.followFailed++;
        stats.errors.push(`follow ${f.targetAgent}: ${e.message.slice(0, 60)}`);
        console.log(`  ${f.follower.label} → ${f.targetAgent} → ${e.skip ? "SKIP" : `FAIL ${e.message.slice(0, 60)}`}`);
      }
      await sleep(60);
    }
  }

  // ── 3) Listing ───────────────────────────────────────────────────────────
  section("getagents (post-register)");
  try {
    const r = await ctx.call("getagents", [{ limit: 100 }]);
    const arr = Array.isArray(r) ? r : (r?.agents ?? []);
    stats.listedAgents = Array.isArray(arr) ? arr.length : 0;
    console.log(`  Total agents: ${stats.listedAgents} (delta=${stats.listedAgents - preCount})`);
    const ourOwners = new Set(AGENTS.map(a => pool[a.walletIdx].address));
    const ours = (arr ?? []).filter(g => ourOwners.has(g.owner ?? g.address ?? ""));
    for (const g of ours.slice(0, 10)) {
      console.log(`    ${(g.name ?? "?").padEnd(20)} owner=${fmtAddr(g.owner ?? g.address)} strategy=${g.strategy ?? "?"} fee=${g.fee_bps ?? "?"}bps`);
    }
  } catch (e) {
    console.log(`  ${e.skip ? "SKIP" : `ERR ${e.message.slice(0, 60)}`}`);
  }

  // ── 4) Edit fee_bps on first agent ───────────────────────────────────────
  if (!opts.dryRun) {
    section("agent_edit (change fee_bps on alex-arb)");
    const w = pool[AGENTS[0].walletIdx];
    try {
      const r = await ctx.call("agent_edit", [{
        owner: w.address,
        name:  AGENTS[0].name,
        fee_bps: 20, // bumped from 10 → 20
      }]);
      if (r) {
        stats.edited++;
        console.log(`  alex-arb fee_bps 10 → 20 → OK ${JSON.stringify(r).slice(0, 60)}`);
      }
    } catch (e) {
      stats.editFailed++;
      stats.errors.push(`edit alex-arb: ${e.message.slice(0, 60)}`);
      console.log(`  alex-arb edit → ${e.skip ? "SKIP" : `FAIL ${e.message.slice(0, 60)}`}`);
    }
  }

  // ── 5) Unregister last agent ─────────────────────────────────────────────
  if (!opts.dryRun) {
    section("agent_unregister (alex-oracle)");
    const w = pool[AGENTS[2].walletIdx];
    try {
      const r = await ctx.call("agent_unregister", [{
        owner: w.address,
        name:  AGENTS[2].name,
      }]);
      if (r) {
        stats.unregistered++;
        console.log(`  alex-oracle → OK`);
      }
    } catch (e) {
      stats.unregisterFailed++;
      stats.errors.push(`unregister alex-oracle: ${e.message.slice(0, 60)}`);
      console.log(`  alex-oracle → ${e.skip ? "SKIP" : `FAIL ${e.message.slice(0, 60)}`}`);
    }
  }

  // ── Summary + report ─────────────────────────────────────────────────────
  section("Summary");
  console.log(`  registered=${stats.registered}/${AGENTS.length}  followed=${stats.followed}  edited=${stats.edited}  unregistered=${stats.unregistered}  listed=${stats.listedAgents}`);

  const lines = [];
  lines.push(`# Multi-wallet Agents Report`);
  lines.push(``);
  lines.push(`- chain: \`${opts.chain}\``);
  lines.push(`- rpc:   \`${ctx.url}\``);
  lines.push(`- mode:  ${opts.dryRun ? "**dry-run**" : "**WRITE**"}`);
  lines.push(`- ts:    ${new Date().toISOString()}`);
  lines.push(``);
  lines.push(`| metric | value |`);
  lines.push(`|:--|---:|`);
  lines.push(`| pre-existing agents | ${preCount} |`);
  lines.push(`| registered | ${stats.registered} / ${AGENTS.length} |`);
  lines.push(`| followed | ${stats.followed} |`);
  lines.push(`| edited | ${stats.edited} |`);
  lines.push(`| unregistered | ${stats.unregistered} |`);
  lines.push(`| listed (post) | ${stats.listedAgents} |`);
  if (stats.errors.length) {
    lines.push(``);
    lines.push(`## Errors`);
    for (const e of stats.errors.slice(0, 10)) lines.push(`- ${e}`);
  }
  const out = join(__dirname, "multiwallet-agents-report.md");
  writeFileSync(out, lines.join("\n"));
  console.log(`  Report: ${out}`);

  process.exit(stats.errors.length === 0 ? 0 : 1);
}

main().catch((e) => { console.error("FATAL:", e); process.exit(1); });
