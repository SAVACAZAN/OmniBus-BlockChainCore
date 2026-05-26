#!/usr/bin/env node
/**
 * 27-multiwallet-stake-validators.mjs — Staking + validator promotion.
 *
 * Five wallets stake escalating amounts (10 / 50 / 100 / 500 / 1000 OMNI)
 * via op_return-style "stake:<amount>" memo TXs. We then:
 *   - getstakers   → check our 5 appear
 *   - become_validator on the largest staker
 *   - getvalidatorsv2 → confirm tier classification
 *   - validator_heartbeat ×5 across ~5 minutes
 *   - getreputation per staker (RENT cup should grow)
 *
 * Defaults to TESTNET. Use --dry-run to skip writes.
 *
 * Usage:
 *   node 27-multiwallet-stake-validators.mjs              # full flow
 *   node 27-multiwallet-stake-validators.mjs --dry-run    # read-only
 *   node 27-multiwallet-stake-validators.mjs --hb-rounds 3 --hb-interval 30
 */

import {
  parseArgs, mkRpc, loadPool, getBalance, getNonce,
  submitMemoTx, getTip, waitForBlock,
  fmtSat, fmtAddr, header, section, sleep,
} from "./_wallet-pool.mjs";
import { writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const opts = parseArgs(process.argv);
const ctx  = mkRpc(opts);

const argv = process.argv.slice(2);
function intArg(name, fb) {
  const i = argv.indexOf(name);
  return i >= 0 ? parseInt(argv[i + 1], 10) : fb;
}

// 5 stakers with escalating amounts (in OMNI).
const STAKE_OMNI = [10, 50, 100, 500, 1000];

// Heartbeat configuration.
const HB_ROUNDS   = intArg("--hb-rounds",   5);  // default 5 heartbeats
const HB_INTERVAL = intArg("--hb-interval", 30); // default 30s between

async function main() {
  header("Multi-wallet staking + validators (5/10)", ctx);
  const pool = loadPool();

  // We use wallets 0..4 as the 5 stakers (large funding required).
  const stakers = pool.slice(0, 5);
  console.log(`  Stakers: ${stakers.map(s => s.label).join(", ")}`);
  console.log(`  Stake amounts: ${STAKE_OMNI.join(", ")} OMNI`);
  console.log(`  Heartbeat: ${HB_ROUNDS} rounds × ${HB_INTERVAL}s = ${HB_ROUNDS * HB_INTERVAL}s total`);

  // ── Pre-state ────────────────────────────────────────────────────────────
  section("Pre-flight balances");
  const balPre = [];
  for (const w of stakers) {
    const b = await getBalance(ctx, w.address);
    balPre.push(b);
    console.log(`  ${w.label.padEnd(8)} ${fmtAddr(w.address).padEnd(28)} ${fmtSat(b)}`);
  }

  const stats = {
    staked: 0, stakeFailed: 0,
    listedStakers: 0, becameValidator: false,
    validatorTier: null,
    heartbeats: 0, heartbeatFailed: 0,
    repBefore: [], repAfter: [],
    errors: [],
  };

  // ── Snapshot pre-stake reputation ────────────────────────────────────────
  section("Reputation snapshot — pre-stake");
  for (const w of stakers) {
    try {
      const r = await ctx.call("getreputation", [{ address: w.address }]);
      stats.repBefore.push({ wallet: w.label, rep: r });
      const cups = r?.cups ?? r?.scores ?? r;
      console.log(`  ${w.label.padEnd(8)} ${JSON.stringify(cups).slice(0, 100)}`);
    } catch (e) {
      if (!e.skip) stats.errors.push(`getreputation pre ${w.label}: ${e.message.slice(0, 50)}`);
    }
  }

  // ── Stake TXs ────────────────────────────────────────────────────────────
  if (!opts.dryRun) {
    section("Stake TXs (op_return memo: stake:<sat>)");
    for (let k = 0; k < stakers.length; k++) {
      const w = stakers[k];
      const omni = STAKE_OMNI[k];
      const sat  = BigInt(Math.round(omni * 1e9));
      const memo = `stake:${sat}`;
      const r = await submitMemoTx(ctx, w, {
        to:       w.address,
        amount:   1, // op_return TX with minimal carry amount
        opReturn: memo,
      });
      if (r.ok) {
        stats.staked++;
        console.log(`  ${w.label.padEnd(8)} stake ${omni} OMNI → OK txid=${r.txid.slice(0, 16)}…`);
      } else {
        stats.stakeFailed++;
        stats.errors.push(`stake ${w.label}: ${r.error.slice(0, 60)}`);
        console.log(`  ${w.label.padEnd(8)} stake ${omni} OMNI → FAIL ${r.error.slice(0, 60)}`);
      }
      await sleep(80);
    }
  }

  // Wait for confirmation.
  if (!opts.dryRun) {
    section("Waiting ~10 blocks for stake confirmation (max 90s)");
    const tipS = await getTip(ctx);
    const tipE = await waitForBlock(ctx, tipS + 10, 90_000);
    console.log(`  Tip: ${tipS} → ${tipE}`);
  }

  // ── List stakers ─────────────────────────────────────────────────────────
  section("getstakers (limit=20)");
  try {
    const r = await ctx.call("getstakers", [{ limit: 20 }]);
    const arr = Array.isArray(r) ? r : (r?.stakers ?? []);
    stats.listedStakers = Array.isArray(arr) ? arr.length : 0;
    console.log(`  ${stats.listedStakers} stakers visible chain-wide`);
    // Filter to our 5
    const ourAddrs = new Set(stakers.map(s => s.address));
    const ours = (arr ?? []).filter(s => ourAddrs.has(s.address ?? s.addr ?? ""));
    console.log(`  Of these, ${ours.length} are from our pool`);
    for (const s of ours.slice(0, 10)) {
      console.log(`    ${fmtAddr(s.address ?? s.addr)} stake=${s.stake ?? s.amount ?? "?"}`);
    }
  } catch (e) {
    console.log(`  ${e.skip ? "SKIP" : `ERR ${e.message.slice(0, 60)}`}`);
  }

  // ── Promote largest staker ───────────────────────────────────────────────
  if (!opts.dryRun) {
    section(`become_validator on ${stakers[stakers.length - 1].label} (largest stake)`);
    const big = stakers[stakers.length - 1];
    try {
      const r = await ctx.call("become_validator", [{ address: big.address }]);
      if (r) {
        stats.becameValidator = true;
        console.log(`  OK: ${JSON.stringify(r).slice(0, 100)}`);
      }
    } catch (e) {
      console.log(`  ${e.skip ? "SKIP" : `ERR ${e.message.slice(0, 60)}`}`);
    }
  }

  // ── Validator info ───────────────────────────────────────────────────────
  section("getvalidatorsv2 (tier classification)");
  try {
    const r = await ctx.call("getvalidatorsv2", [{ limit: 50 }]);
    const arr = Array.isArray(r) ? r : (r?.validators ?? []);
    const ourAddrs = new Set(stakers.map(s => s.address));
    const ours = (arr ?? []).filter(v => ourAddrs.has(v.address ?? v.addr ?? ""));
    console.log(`  ${arr?.length ?? 0} validators chain-wide; ${ours.length} from our pool`);
    for (const v of ours.slice(0, 5)) {
      const tier = v.tier ?? v.rank ?? "?";
      stats.validatorTier = tier;
      console.log(`    ${fmtAddr(v.address ?? v.addr)} tier=${tier} stake=${v.stake ?? "?"}`);
    }
  } catch (e) {
    console.log(`  ${e.skip ? "SKIP" : `ERR ${e.message.slice(0, 60)}`}`);
  }

  // ── Heartbeat loop ───────────────────────────────────────────────────────
  if (!opts.dryRun) {
    section(`Heartbeat loop (${HB_ROUNDS} × ${HB_INTERVAL}s)`);
    const validator = stakers[stakers.length - 1];
    for (let r = 0; r < HB_ROUNDS; r++) {
      try {
        const resp = await ctx.call("validator_heartbeat", [{ address: validator.address }]);
        if (resp) {
          stats.heartbeats++;
          console.log(`    [${r + 1}/${HB_ROUNDS}] OK ${JSON.stringify(resp).slice(0, 60)}`);
        }
      } catch (e) {
        stats.heartbeatFailed++;
        console.log(`    [${r + 1}/${HB_ROUNDS}] ${e.skip ? "SKIP" : `ERR ${e.message.slice(0, 60)}`}`);
      }
      if (r < HB_ROUNDS - 1) await sleep(HB_INTERVAL * 1000);
    }
  }

  // ── Reputation after ─────────────────────────────────────────────────────
  section("Reputation snapshot — post-stake / heartbeat");
  for (const w of stakers) {
    try {
      const r = await ctx.call("getreputation", [{ address: w.address }]);
      stats.repAfter.push({ wallet: w.label, rep: r });
      const cups = r?.cups ?? r?.scores ?? r;
      console.log(`  ${w.label.padEnd(8)} ${JSON.stringify(cups).slice(0, 100)}`);
    } catch (e) {
      if (!e.skip) stats.errors.push(`getreputation post ${w.label}: ${e.message.slice(0, 50)}`);
    }
  }

  // ── Summary + report ─────────────────────────────────────────────────────
  section("Summary");
  console.log(`  staked=${stats.staked}/${stakers.length}  validator=${stats.becameValidator}  tier=${stats.validatorTier}  heartbeats=${stats.heartbeats}/${HB_ROUNDS}`);

  const lines = [];
  lines.push(`# Multi-wallet Stake / Validator Report`);
  lines.push(``);
  lines.push(`- chain: \`${opts.chain}\``);
  lines.push(`- rpc:   \`${ctx.url}\``);
  lines.push(`- mode:  ${opts.dryRun ? "**dry-run**" : "**WRITE**"}`);
  lines.push(`- ts:    ${new Date().toISOString()}`);
  lines.push(``);
  lines.push(`| metric | value |`);
  lines.push(`|:--|---:|`);
  lines.push(`| staked TXs | ${stats.staked} / ${stakers.length} |`);
  lines.push(`| stake-failed | ${stats.stakeFailed} |`);
  lines.push(`| listed stakers (chain-wide) | ${stats.listedStakers} |`);
  lines.push(`| became_validator | ${stats.becameValidator} |`);
  lines.push(`| validator tier (largest) | ${stats.validatorTier ?? "n/a"} |`);
  lines.push(`| heartbeats sent | ${stats.heartbeats} / ${HB_ROUNDS} |`);
  lines.push(`| heartbeat failed | ${stats.heartbeatFailed} |`);
  if (stats.errors.length) {
    lines.push(``);
    lines.push(`## Errors`);
    for (const e of stats.errors.slice(0, 10)) lines.push(`- ${e}`);
  }
  const out = join(__dirname, "multiwallet-stake-report.md");
  writeFileSync(out, lines.join("\n"));
  console.log(`  Report: ${out}`);

  process.exit(stats.errors.length === 0 ? 0 : 1);
}

main().catch((e) => { console.error("FATAL:", e); process.exit(1); });
