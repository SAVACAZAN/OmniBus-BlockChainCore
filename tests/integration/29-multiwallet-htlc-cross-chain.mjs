#!/usr/bin/env node
/**
 * 29-multiwallet-htlc-cross-chain.mjs — Cross-chain HTLC across the pool.
 *
 * Three swap pairs exercised:
 *   pair 1: OMNI (wallet0 maker) ↔ ETH  (wallet1 taker)
 *   pair 2: OMNI (wallet2 maker) ↔ BTC  (wallet3 taker)
 *   pair 3: OMNI (wallet4 maker) ↔ LCX  (wallet5 taker)
 *
 * For each we walk:
 *   swap_open → swap_lockMaker → swap_lockTaker → swap_proveSettle (happy path)
 *   refund flow on a second iteration.
 *
 * The foreign side stays mocked — only the OmniBus-side RPCs are exercised.
 * Defaults to TESTNET. Use --dry-run for read-only / dry runs.
 *
 * Usage:
 *   node 29-multiwallet-htlc-cross-chain.mjs
 *   node 29-multiwallet-htlc-cross-chain.mjs --dry-run
 *   node 29-multiwallet-htlc-cross-chain.mjs --chain regtest
 */

import {
  parseArgs, mkRpc, loadPool,
  header, section, sleep,
} from "./_wallet-pool.mjs";
import { writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { randomBytes, createHash } from "node:crypto";

const __dirname = dirname(fileURLToPath(import.meta.url));
const opts = parseArgs(process.argv);
const ctx  = mkRpc(opts);

const FOREIGN_ETH = "0x000000000000000000000000000000000000dEaD";
const FOREIGN_BTC = "bc1qmocked000000000000000000000000000000000";
const FOREIGN_LCX = "0x000000000000000000000000000000000000beef";

function makePairs(pool) {
  return [
    { id: "OMNI-ETH", maker: pool[0], takerForeign: FOREIGN_ETH, makerAsset: "OMNI", takerAsset: "ETH" },
    { id: "OMNI-BTC", maker: pool[2], takerForeign: FOREIGN_BTC, makerAsset: "OMNI", takerAsset: "BTC" },
    { id: "OMNI-LCX", maker: pool[4], takerForeign: FOREIGN_LCX, makerAsset: "OMNI", takerAsset: "LCX" },
  ];
}

async function rpcAny(methods, params) {
  let last;
  for (const m of methods) {
    try {
      const r = await ctx.call(m, params);
      return { method: m, result: r };
    } catch (e) {
      last = e;
      if (!e.skip) throw e;
    }
  }
  const err = new Error(`none of [${methods.join(", ")}] implemented`);
  err.skip = true;
  throw err;
}

async function happyPath(pair, dryRun) {
  const out = {
    pair: pair.id, mode: "settle",
    opened: false, lockedMaker: false, lockedTaker: false, settled: false,
    swap_id: null, errors: [],
  };
  const preimage = randomBytes(32);
  const preimageHex = preimage.toString("hex");
  const hashLockHex = createHash("sha256").update(preimage).digest("hex");

  const baseParams = {
    pair: pair.id,
    maker_asset: pair.makerAsset,
    taker_asset: pair.takerAsset,
    maker_address: pair.maker.address,
    taker_address: pair.takerForeign,
    maker_amount: 100_000,  // SAT
    taker_amount: 100_000,
    hash_lock: hashLockHex,
    timeout_blocks: 100,
  };

  // 1) open
  try {
    const params = dryRun ? [{ ...baseParams, dry_run: true }] : [baseParams];
    const r = await rpcAny(["swap_open", "htlc_init"], params);
    out.opened = true;
    out.swap_id = r.result?.swap_id ?? r.result?.htlc_id ?? r.result?.id ?? null;
  } catch (e) {
    if (!e.skip) out.errors.push(`open: ${e.message.slice(0, 60)}`);
    return out;
  }

  // 2) lockMaker
  try {
    await rpcAny(["swap_lockMaker", "htlc_lock_maker"],
      [{ swap_id: out.swap_id, dry_run: dryRun }]);
    out.lockedMaker = true;
  } catch (e) {
    if (!e.skip) out.errors.push(`lockMaker: ${e.message.slice(0, 60)}`);
  }

  // 3) lockTaker (foreign side mocked — RPC accepts/rejects identically)
  try {
    await rpcAny(["swap_lockTaker", "htlc_lock_taker"],
      [{ swap_id: out.swap_id, dry_run: dryRun }]);
    out.lockedTaker = true;
  } catch (e) {
    if (!e.skip) out.errors.push(`lockTaker: ${e.message.slice(0, 60)}`);
  }

  // 4) proveSettle (reveal preimage)
  try {
    await rpcAny(["swap_proveSettle", "htlc_claim"],
      [{ swap_id: out.swap_id, preimage: preimageHex, dry_run: dryRun }]);
    out.settled = true;
  } catch (e) {
    if (!e.skip) out.errors.push(`proveSettle: ${e.message.slice(0, 60)}`);
  }
  return out;
}

async function refundPath(pair, dryRun) {
  const out = {
    pair: pair.id, mode: "refund",
    opened: false, lockedMaker: false, refunded: false,
    swap_id: null, errors: [],
  };
  const preimage = randomBytes(32);
  const hashLockHex = createHash("sha256").update(preimage).digest("hex");

  const baseParams = {
    pair: pair.id,
    maker_asset: pair.makerAsset,
    taker_asset: pair.takerAsset,
    maker_address: pair.maker.address,
    taker_address: pair.takerForeign,
    maker_amount: 50_000,
    taker_amount: 50_000,
    hash_lock: hashLockHex,
    timeout_blocks: 1,    // tiny timeout for refund-soon scenarios
  };

  try {
    const params = dryRun ? [{ ...baseParams, dry_run: true }] : [baseParams];
    const r = await rpcAny(["swap_open", "htlc_init"], params);
    out.opened = true;
    out.swap_id = r.result?.swap_id ?? r.result?.htlc_id ?? r.result?.id ?? null;
  } catch (e) {
    if (!e.skip) out.errors.push(`open: ${e.message.slice(0, 60)}`);
    return out;
  }
  try {
    await rpcAny(["swap_lockMaker", "htlc_lock_maker"],
      [{ swap_id: out.swap_id, dry_run: dryRun }]);
    out.lockedMaker = true;
  } catch (e) {
    if (!e.skip) out.errors.push(`lockMaker: ${e.message.slice(0, 60)}`);
  }
  try {
    await rpcAny(["htlc_refund", "swap_refund"],
      [{ swap_id: out.swap_id, dry_run: dryRun }]);
    out.refunded = true;
  } catch (e) {
    if (!e.skip) out.errors.push(`refund: ${e.message.slice(0, 60)}`);
  }
  return out;
}

async function main() {
  header("Multi-wallet HTLC cross-chain (7/10)", ctx);
  const pool = loadPool();
  const PAIRS = makePairs(pool);

  console.log(`  Pairs: ${PAIRS.map(p => p.id).join(", ")}`);

  // Reachability + bridge probe.
  try {
    const tip = await ctx.call("getblockcount");
    console.log(`  Tip: ${tip}`);
  } catch (e) {
    console.error(`FATAL: ${e.message}`);
    process.exit(2);
  }
  for (const m of ["bridge_listChains", "swap_listAssets", "htlc_list"]) {
    try {
      const r = await ctx.call(m, []);
      console.log(`  ${m}: ${JSON.stringify(r).slice(0, 100)}`);
    } catch (e) {
      console.log(`  ${m}: ${e.skip ? "SKIP" : `ERR ${e.message.slice(0, 60)}`}`);
    }
  }

  const reports = [];
  for (const pair of PAIRS) {
    section(`Pair ${pair.id} — happy + refund flows`);
    const happy  = await happyPath(pair, opts.dryRun);
    reports.push(happy);
    console.log(`    [settle] open=${happy.opened ? "y" : "n"} lockM=${happy.lockedMaker ? "y" : "n"} lockT=${happy.lockedTaker ? "y" : "n"} settle=${happy.settled ? "y" : "n"} errs=${happy.errors.length}`);
    await sleep(80);

    const refund = await refundPath(pair, opts.dryRun);
    reports.push(refund);
    console.log(`    [refund] open=${refund.opened ? "y" : "n"} lockM=${refund.lockedMaker ? "y" : "n"} refund=${refund.refunded ? "y" : "n"} errs=${refund.errors.length}`);
    await sleep(80);
  }

  // ── Aggregate ────────────────────────────────────────────────────────────
  const tot = reports.reduce((a, r) => ({
    opened:  a.opened  + (r.opened ? 1 : 0),
    locked:  a.locked  + (r.lockedMaker ? 1 : 0) + (r.lockedTaker ? 1 : 0),
    settled: a.settled + (r.settled ? 1 : 0),
    refund:  a.refund  + (r.refunded ? 1 : 0),
    errors:  a.errors  + r.errors.length,
  }), { opened: 0, locked: 0, settled: 0, refund: 0, errors: 0 });

  section("Summary");
  console.log(`  open=${tot.opened}  lock=${tot.locked}  settle=${tot.settled}  refund=${tot.refund}  errors=${tot.errors}`);

  // ── Per-chain success rates ──────────────────────────────────────────────
  const perChain = {};
  for (const r of reports) {
    perChain[r.pair] ??= { settle: 0, refund: 0, errors: 0, runs: 0 };
    perChain[r.pair].runs++;
    if (r.settled)  perChain[r.pair].settle++;
    if (r.refunded) perChain[r.pair].refund++;
    perChain[r.pair].errors += r.errors.length;
  }
  for (const [chain, s] of Object.entries(perChain)) {
    console.log(`  ${chain}: settle=${s.settle} refund=${s.refund} errors=${s.errors}`);
  }

  // ── Report ───────────────────────────────────────────────────────────────
  const lines = [];
  lines.push(`# Multi-wallet HTLC Cross-Chain Report`);
  lines.push(``);
  lines.push(`- chain: \`${opts.chain}\``);
  lines.push(`- rpc:   \`${ctx.url}\``);
  lines.push(`- mode:  ${opts.dryRun ? "**dry-run**" : "**WRITE**"}`);
  lines.push(`- ts:    ${new Date().toISOString()}`);
  lines.push(``);
  lines.push(`| pair | mode | opened | lockMaker | lockTaker | settled | refunded | errors |`);
  lines.push(`|:--|:--|:--:|:--:|:--:|:--:|:--:|---:|`);
  for (const r of reports) {
    const m = (b) => b ? "y" : "·";
    lines.push(`| ${r.pair} | ${r.mode} | ${m(r.opened)} | ${m(r.lockedMaker)} | ${m(r.lockedTaker ?? false)} | ${m(r.settled ?? false)} | ${m(r.refunded ?? false)} | ${r.errors.length} |`);
  }
  lines.push(``);
  lines.push(`## Per-chain success`);
  lines.push(`| chain | runs | settled | refunded | errors |`);
  lines.push(`|:--|---:|---:|---:|---:|`);
  for (const [chain, s] of Object.entries(perChain)) {
    lines.push(`| ${chain} | ${s.runs} | ${s.settle} | ${s.refund} | ${s.errors} |`);
  }
  if (reports.some(r => r.errors.length)) {
    lines.push(``);
    lines.push(`## Errors`);
    for (const r of reports) {
      if (!r.errors.length) continue;
      lines.push(`### ${r.pair} ${r.mode}`);
      for (const e of r.errors.slice(0, 5)) lines.push(`- ${e}`);
    }
  }
  const out = join(__dirname, "multiwallet-htlc-report.md");
  writeFileSync(out, lines.join("\n"));
  console.log(`  Report: ${out}`);

  process.exit(tot.errors === 0 ? 0 : 1);
}

main().catch((e) => { console.error("FATAL:", e); process.exit(1); });
