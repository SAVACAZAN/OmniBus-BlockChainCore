#!/usr/bin/env node
/**
 * 24-multiwallet-transfers.mjs — Round-robin transfer flow.
 *
 * Each round, every wallet w[i] sends a small random amount (0.1 .. 1 OMNI)
 * to wallet w[(i+1) % 10]. Repeated for ROUNDS rounds (default 10) → up to
 * 100 TXs total. We track per-wallet nonce auto-increment, accepted/rejected/
 * failed counts, and dump a markdown report.
 *
 * Defaults to TESTNET. Use --dry-run to skip submissions and just preview.
 *
 * Usage:
 *   node 24-multiwallet-transfers.mjs                           # 10 rounds
 *   node 24-multiwallet-transfers.mjs --rounds 5
 *   node 24-multiwallet-transfers.mjs --chain regtest
 *   node 24-multiwallet-transfers.mjs --dry-run
 */

import {
  parseArgs, mkRpc, loadPool, getBalance, getNonce, submitTx,
  getTip, waitForBlock, fmtSat, header, section, sleep,
} from "./_wallet-pool.mjs";
import { writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const opts = parseArgs(process.argv);
const ctx  = mkRpc(opts);

const argv = process.argv.slice(2);
const idx = argv.indexOf("--rounds");
const ROUNDS = idx >= 0 ? parseInt(argv[idx + 1], 10) : 10;

function randAmountSat() {
  // 0.1 .. 1 OMNI (in SAT)
  const r = 0.1 + Math.random() * 0.9;
  return Math.round(r * 1e9);
}

async function main() {
  header("Multi-wallet round-robin transfers (2/10)", ctx);

  const pool = loadPool();
  console.log(`  Pool: ${pool.length} wallets`);
  console.log(`  Rounds: ${ROUNDS} × ${pool.length} = ${ROUNDS * pool.length} TXs target`);

  // ── Pre-flight: balances + nonces ────────────────────────────────────────
  section("Pre-flight balances + nonces");
  const balPre = new Array(pool.length);
  const nonceLocal = new Array(pool.length); // tracked locally so we don't refetch each round
  for (let i = 0; i < pool.length; i++) {
    balPre[i]      = await getBalance(ctx, pool[i].address);
    nonceLocal[i]  = await getNonce(ctx, pool[i].address);
    console.log(`  ${pool[i].label.padEnd(8)} bal=${fmtSat(balPre[i]).padEnd(20)} nonce=${nonceLocal[i]}`);
  }

  if (opts.dryRun) {
    console.log("\n  --dry-run set — exiting before submitting TXs");
    process.exit(0);
  }

  // ── Round-robin loop ─────────────────────────────────────────────────────
  section(`Submitting ${ROUNDS * pool.length} TXs`);
  const stats = { sent: 0, accepted: 0, failed: 0, mined: 0, perWallet: [] };
  for (let i = 0; i < pool.length; i++) {
    stats.perWallet.push({ label: pool[i].label, sent: 0, accepted: 0, failed: 0, errors: [] });
  }

  const tipStart = await getTip(ctx);
  for (let round = 0; round < ROUNDS; round++) {
    process.stdout.write(`  round ${String(round + 1).padStart(2)}/${ROUNDS}: `);
    let okThisRound = 0;
    for (let i = 0; i < pool.length; i++) {
      const from = pool[i];
      const to   = pool[(i + 1) % pool.length];
      const amt  = randAmountSat();
      stats.sent++; stats.perWallet[i].sent++;
      const r = await submitTx(ctx, from, {
        to:     to.address,
        amount: amt,
        fee:    1000,
        nonce:  nonceLocal[i],
      });
      if (r.ok) {
        stats.accepted++; stats.perWallet[i].accepted++;
        nonceLocal[i] += 1n;
        okThisRound++;
      } else {
        stats.failed++; stats.perWallet[i].failed++;
        stats.perWallet[i].errors.push(`r${round}: ${r.error.slice(0, 60)}`);
      }
      await sleep(20);
    }
    console.log(`ok=${okThisRound}/${pool.length}`);
  }

  // ── Mine + verify ────────────────────────────────────────────────────────
  section("Waiting for ~10 blocks of confirmation (max 90s)");
  const tipMid = await getTip(ctx);
  const tipFinal = await waitForBlock(ctx, tipMid + 10, 90_000);
  stats.mined = tipFinal - tipStart;
  console.log(`  Tip: ${tipStart} → ${tipFinal}  (Δ${stats.mined} blocks)`);

  // ── Post-balances ────────────────────────────────────────────────────────
  section("Post-flight balances");
  const balPost = new Array(pool.length);
  for (let i = 0; i < pool.length; i++) {
    balPost[i] = await getBalance(ctx, pool[i].address);
    const delta = balPost[i] - balPre[i];
    const sign  = delta >= 0n ? "+" : "";
    console.log(`  ${pool[i].label.padEnd(8)} ${fmtSat(balPre[i]).padEnd(18)} → ${fmtSat(balPost[i]).padEnd(18)}  (${sign}${fmtSat(delta)})`);
  }

  // ── Summary ──────────────────────────────────────────────────────────────
  section("Summary");
  console.log(`  sent=${stats.sent}  accepted=${stats.accepted}  failed=${stats.failed}  mined-blocks=${stats.mined}`);

  // ── Report ───────────────────────────────────────────────────────────────
  const lines = [];
  lines.push(`# Multi-wallet Transfers Report`);
  lines.push(``);
  lines.push(`- chain: \`${opts.chain}\``);
  lines.push(`- rpc:   \`${ctx.url}\``);
  lines.push(`- ts:    ${new Date().toISOString()}`);
  lines.push(`- rounds: ${ROUNDS}`);
  lines.push(`- TXs sent / accepted / failed: ${stats.sent} / ${stats.accepted} / ${stats.failed}`);
  lines.push(`- blocks mined during run: ${stats.mined}`);
  lines.push(``);
  lines.push(`| label | sent | accepted | failed | balance pre | balance post | delta |`);
  lines.push(`|:--|---:|---:|---:|---:|---:|---:|`);
  for (let i = 0; i < pool.length; i++) {
    const delta = balPost[i] - balPre[i];
    lines.push(`| ${pool[i].label} | ${stats.perWallet[i].sent} | ${stats.perWallet[i].accepted} | ${stats.perWallet[i].failed} | ${fmtSat(balPre[i])} | ${fmtSat(balPost[i])} | ${delta >= 0n ? "+" : ""}${fmtSat(delta)} |`);
  }
  if (stats.perWallet.some(w => w.errors.length)) {
    lines.push(``);
    lines.push(`## Errors (first 5 per wallet)`);
    for (const w of stats.perWallet) {
      if (!w.errors.length) continue;
      lines.push(`### ${w.label}`);
      for (const e of w.errors.slice(0, 5)) lines.push(`- ${e}`);
    }
  }
  const out = join(__dirname, "multiwallet-transfers-report.md");
  writeFileSync(out, lines.join("\n"));
  console.log(`  Report: ${out}`);

  process.exit(stats.failed === 0 ? 0 : 1);
}

main().catch((e) => { console.error("FATAL:", e); process.exit(1); });
