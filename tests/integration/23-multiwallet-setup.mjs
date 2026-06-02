#!/usr/bin/env node
/**
 * 23-multiwallet-setup.mjs — Generate the 10-wallet pool, fund wallets 1..9
 * from wallet 0 (the primary), and persist the pool to `wallet-pool.json`.
 *
 * Each non-primary wallet receives 5 OMNI from wallet 0. After funding we
 * wait for ~10 blocks of confirmation and then verify balances.
 *
 * Defaults to TESTNET. Add --dry-run to skip the funding TXs (just print
 * the pool + balances).
 *
 * Usage:
 *   node 23-multiwallet-setup.mjs                 # testnet, fund + verify
 *   node 23-multiwallet-setup.mjs --dry-run       # no TXs, just inspect
 *   node 23-multiwallet-setup.mjs --chain regtest --write
 *   node 23-multiwallet-setup.mjs --amount 5      # OMNI per wallet
 */

import {
  parseArgs, mkRpc, makePool, savePool, getBalance, getNonce, submitTx,
  getTip, waitForBlock, fmtSat, fmtAddr, header, section, sleep,
  POOL_FILE_DEFAULT, SAT_PER_OMNI,
} from "./_wallet-pool.mjs";
import { writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));

const opts = parseArgs(process.argv);
const ctx  = mkRpc(opts);

// Per-wallet funding amount (in OMNI). Test brief calls for 5 OMNI each.
const argv = process.argv.slice(2);
const amountIdx = argv.indexOf("--amount");
const FUND_OMNI = amountIdx >= 0 ? parseFloat(argv[amountIdx + 1]) : 5;
const FUND_SAT  = BigInt(Math.round(FUND_OMNI * 1e9));

async function main() {
  header("Multi-wallet setup (1/10) — derive + fund + persist", ctx);

  // ── Derive pool ──────────────────────────────────────────────────────────
  const pool = makePool();

  section("Derived pool (10 wallets, m/44'/777'/0'/0/0)");
  console.log("  idx label    OMNI address                                EVM address");
  console.log("  --- -------- -------------------------------------------- ------------------------------------------");
  for (const w of pool) {
    console.log(`  ${String(w.i).padEnd(3)} ${w.label.padEnd(8)} ${w.address.padEnd(44)} ${w.evm}`);
  }

  // ── Save snapshot first (so subsequent scripts can run even if funding fails) ──
  const poolPath = savePool(pool);
  console.log(`\n  Pool snapshot → ${poolPath}`);

  // ── Reachability ─────────────────────────────────────────────────────────
  let tip0;
  try {
    tip0 = await getTip(ctx);
    console.log(`  Chain tip: ${tip0}`);
  } catch (e) {
    console.error(`FATAL: cannot reach RPC ${ctx.url}: ${e.message}`);
    process.exit(2);
  }

  // ── Pre-funding balances ─────────────────────────────────────────────────
  section("Pre-funding balances");
  const preBal = [];
  for (const w of pool) {
    const sat = await getBalance(ctx, w.address);
    preBal.push(sat);
    console.log(`  ${w.label.padEnd(8)} ${fmtAddr(w.address).padEnd(28)} ${fmtSat(sat)}`);
  }

  if (opts.dryRun) {
    console.log("\n  --dry-run set — skipping funding TXs");
    process.exit(0);
  }

  // ── Sanity: primary must have enough to fund 9 × FUND_OMNI + fees ────────
  const need = FUND_SAT * 9n + 100_000n; // 0.0001 OMNI fees
  if (preBal[0] < need) {
    console.log(`\n  WARNING: wallet0 balance ${fmtSat(preBal[0])} < required ${fmtSat(need)}`);
    console.log("  Continuing anyway — TXs that exceed balance will be rejected.");
  }

  // ── Funding loop ─────────────────────────────────────────────────────────
  section("Funding wallets 1..9 from wallet0");
  const funded   = [];
  const rejected = [];
  // Use a single growing nonce — the chain assigns nonces per-sender so we
  // pull once and increment locally to avoid 9 round-trips.
  let nonce = await getNonce(ctx, pool[0].address);
  for (let i = 1; i < pool.length; i++) {
    const target = pool[i];
    process.stdout.write(`  ${pool[0].label} → ${target.label.padEnd(8)} ${FUND_OMNI} OMNI … `);
    const r = await submitTx(ctx, pool[0], {
      to:     target.address,
      amount: Number(FUND_SAT),
      fee:    1000,
      nonce,
    });
    if (r.ok) {
      funded.push({ to: target.label, txid: r.txid });
      console.log(`OK txid=${r.txid.slice(0, 16)}…`);
      nonce += 1n;
    } else {
      rejected.push({ to: target.label, error: r.error });
      console.log(`FAIL ${r.error.slice(0, 60)}`);
    }
    await sleep(50);
  }

  // ── Wait for confirmation ────────────────────────────────────────────────
  section("Waiting for ~10 blocks of confirmation (max 60s)");
  const target = tip0 + 10;
  const tipFinal = await waitForBlock(ctx, target, 60_000);
  console.log(`  Tip after wait: ${tipFinal} (started at ${tip0}, target ${target})`);

  // ── Post-funding balances ────────────────────────────────────────────────
  section("Post-funding balances (expect 5 OMNI on wallets 1..9)");
  let allOk = true;
  const post = [];
  for (const w of pool) {
    const sat = await getBalance(ctx, w.address);
    post.push(sat);
    const tag = w.i === 0 ? "primary" : (sat >= FUND_SAT ? "OK" : "LOW");
    if (w.i !== 0 && sat < FUND_SAT) allOk = false;
    console.log(`  ${w.label.padEnd(8)} ${fmtAddr(w.address).padEnd(28)} ${fmtSat(sat).padEnd(18)} [${tag}]`);
  }

  // ── Markdown report ──────────────────────────────────────────────────────
  const report = [];
  report.push(`# Multi-wallet Setup Report`);
  report.push(``);
  report.push(`- chain: \`${opts.chain}\``);
  report.push(`- rpc:   \`${ctx.url}\``);
  report.push(`- ts:    ${new Date().toISOString()}`);
  report.push(`- per-wallet funding: ${FUND_OMNI} OMNI`);
  report.push(``);
  report.push(`| idx | label | address | EVM | pre | post | delta |`);
  report.push(`|---:|:--|:--|:--|---:|---:|---:|`);
  for (const w of pool) {
    const delta = post[w.i] - preBal[w.i];
    report.push(`| ${w.i} | ${w.label} | \`${w.address}\` | \`${w.evm}\` | ${fmtSat(preBal[w.i])} | ${fmtSat(post[w.i])} | ${delta >= 0n ? "+" : ""}${fmtSat(delta)} |`);
  }
  report.push(``);
  report.push(`- TXs accepted: ${funded.length}/${pool.length - 1}`);
  report.push(`- TXs rejected: ${rejected.length}`);
  if (rejected.length) {
    report.push(``);
    report.push(`### Rejected`);
    for (const r of rejected) report.push(`- ${r.to}: ${r.error}`);
  }
  const outFile = join(__dirname, "multiwallet-setup-report.md");
  writeFileSync(outFile, report.join("\n"));
  console.log(`\n  Report: ${outFile}`);
  console.log(`  Pool:   ${poolPath}`);

  process.exit(allOk ? 0 : 1);
}

main().catch((e) => { console.error("FATAL:", e); process.exit(1); });
