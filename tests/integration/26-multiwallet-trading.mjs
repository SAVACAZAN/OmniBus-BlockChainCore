#!/usr/bin/env node
/**
 * 26-multiwallet-trading.mjs — DEX trading flow across the 10-wallet pool.
 *
 * Pair_id 0 (OMNI/USDC):
 *   - wallets 0..4 act as MAKERS (place buy orders below mid-price)
 *   - wallets 5..9 act as TAKERS (place sell orders at/just above mid)
 *
 * Pair_id 5 (OMNI/LCX): roles inverted — wallets 0..4 = sellers, 5..9 = buyers.
 *
 * For each placed order we record the order_id and try to cancel a few of
 * them mid-flow to exercise `exchange_cancelOrder`. After both rounds we
 * fetch each wallet's open orders and print per-pair volumes.
 *
 * Defaults to TESTNET. --dry-run uses `exchange_validateOrder` (or just
 * builds payloads locally if validate isn't available) and skips submit.
 *
 * Usage:
 *   node 26-multiwallet-trading.mjs                 # testnet, full flow
 *   node 26-multiwallet-trading.mjs --dry-run
 *   node 26-multiwallet-trading.mjs --chain regtest
 */

import {
  parseArgs, mkRpc, loadPool, fmtAddr, fmtSat,
  header, section, sleep,
} from "./_wallet-pool.mjs";
import { writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const opts = parseArgs(process.argv);
const ctx  = mkRpc(opts);

// Two pairs exercised, with role assignment per the test brief.
const PAIRS = [
  { id: 0, name: "OMNI/USDC", makerSide: "buy",  takerSide: "sell" },
  { id: 5, name: "OMNI/LCX",  makerSide: "sell", takerSide: "buy"  },
];

async function pairMidPrice(pairId) {
  // Try exchange_pairInfo first; fall back to top-of-book or 1.0.
  try {
    const info = await ctx.call("exchange_pairInfo", [{ pair_id: pairId }]);
    const mid = Number(info?.last_price ?? info?.mid_price ?? info?.price ?? 0);
    if (mid && isFinite(mid)) return mid;
  } catch { /* fall through */ }
  try {
    const ob = await ctx.call("exchange_getOrderbook", [{ pair_id: pairId }]);
    const bestBid = ob?.bids?.[0]?.price ?? 0;
    const bestAsk = ob?.asks?.[0]?.price ?? 0;
    if (bestBid && bestAsk) return (Number(bestBid) + Number(bestAsk)) / 2;
    if (bestBid) return Number(bestBid);
    if (bestAsk) return Number(bestAsk);
  } catch { /* fall through */ }
  return 1.0;
}

async function placeOrder(pair, wallet, side, price, amount) {
  // The DEX expects micro-USD price + SAT amount with a wallet-signed
  // EXCHANGE_ORDER_V1 message. We delegate to the chain's positional
  // wrapper if available; if not, use named params directly. The chain
  // either accepts the order on the miner wallet's behalf (default UI
  // path) or rejects with a signature requirement — both useful signals.
  const payload = {
    pair_id: pair.id,
    side, price, amount,
    trader: wallet.address,
  };
  try {
    const r = await ctx.call("exchange_placeOrder", [payload]);
    return { ok: true, order: r };
  } catch (e) {
    return { ok: false, error: e.message, code: e.code, skip: e.skip };
  }
}

async function validateOrder(pair, wallet, side, price, amount) {
  try {
    const r = await ctx.call("exchange_validateOrder", [{
      pair_id: pair.id, side, price, amount, trader: wallet.address,
    }]);
    return { ok: true, order: r };
  } catch (e) {
    return { ok: false, error: e.message, skip: e.skip };
  }
}

async function tradePair(pair, pool, dryRun, perPairStats) {
  const stats = perPairStats[pair.id];
  console.log(`\n  pair ${pair.id} ${pair.name} — fetching mid-price…`);
  const mid = await pairMidPrice(pair.id);
  stats.mid = mid;
  console.log(`    mid=${mid}`);

  const makers = pool.slice(0, 5);
  const takers = pool.slice(5);
  const orderIds = [];

  // Makers post 1 order each, slightly below/above mid depending on role.
  for (let k = 0; k < makers.length; k++) {
    const w = makers[k];
    const stepPct = (k + 1) * 0.005; // 0.5%, 1%, 1.5%, …
    const price = pair.makerSide === "buy" ? mid * (1 - stepPct) : mid * (1 + stepPct);
    const amount = 1; // 1 unit base
    stats.placed++;
    const r = dryRun
      ? await validateOrder(pair, w, pair.makerSide, price, amount)
      : await placeOrder(pair, w, pair.makerSide, price, amount);
    if (r.ok) {
      stats.accepted++;
      const oid = r.order?.order_id ?? r.order?.orderId ?? r.order?.id ?? null;
      if (oid !== null) orderIds.push({ wallet: w, oid });
      console.log(`    maker ${w.label} ${pair.makerSide}@${price.toFixed(6)} → OK ${oid ?? ""}`);
    } else {
      if (r.skip) stats.skipped++; else stats.failed++;
      stats.errors.push(`maker ${w.label}: ${r.error.slice(0, 60)}`);
      console.log(`    maker ${w.label} ${pair.makerSide}@${price.toFixed(6)} → ${r.skip ? "SKIP" : "FAIL"} ${r.error.slice(0, 50)}`);
    }
    await sleep(40);
  }

  // Takers post 1 order each, near mid (small deviations).
  for (let k = 0; k < takers.length; k++) {
    const w = takers[k];
    const stepPct = (k + 1) * 0.002;
    const price = pair.takerSide === "sell" ? mid * (1 + stepPct) : mid * (1 - stepPct);
    const amount = 1;
    stats.placed++;
    const r = dryRun
      ? await validateOrder(pair, w, pair.takerSide, price, amount)
      : await placeOrder(pair, w, pair.takerSide, price, amount);
    if (r.ok) {
      stats.accepted++;
      const oid = r.order?.order_id ?? r.order?.orderId ?? r.order?.id ?? null;
      if (oid !== null) orderIds.push({ wallet: w, oid });
      // If the order_id came back as filled, count that.
      if (r.order?.status === "filled" || r.order?.filled) stats.filled++;
      console.log(`    taker ${w.label} ${pair.takerSide}@${price.toFixed(6)} → OK ${oid ?? ""}`);
    } else {
      if (r.skip) stats.skipped++; else stats.failed++;
      stats.errors.push(`taker ${w.label}: ${r.error.slice(0, 60)}`);
      console.log(`    taker ${w.label} ${pair.takerSide}@${price.toFixed(6)} → ${r.skip ? "SKIP" : "FAIL"} ${r.error.slice(0, 50)}`);
    }
    await sleep(40);
  }

  // Cancel a couple of mid-flow orders if we got order ids back.
  if (!dryRun && orderIds.length > 0) {
    const toCancel = orderIds.slice(0, Math.min(3, orderIds.length));
    for (const { wallet, oid } of toCancel) {
      try {
        await ctx.call("exchange_cancelOrder", [{
          pair_id: pair.id, order_id: oid, trader: wallet.address,
        }]);
        stats.cancelled++;
        console.log(`    cancel ${wallet.label} oid=${oid} → OK`);
      } catch (e) {
        if (!e.skip) stats.errors.push(`cancel ${oid}: ${e.message.slice(0, 60)}`);
      }
      await sleep(40);
    }
  }

  // Per-wallet open orders (sanity).
  for (const w of pool) {
    try {
      const r = await ctx.call("exchange_getUserOrders", [{ trader: w.address }]);
      const arr = Array.isArray(r) ? r : (r?.orders ?? []);
      stats.userOrders.push({ wallet: w.label, count: Array.isArray(arr) ? arr.length : 0 });
    } catch (e) {
      if (!e.skip) stats.errors.push(`getUserOrders ${w.label}: ${e.message.slice(0, 50)}`);
    }
  }
}

async function main() {
  header("Multi-wallet trading flow (4/10)", ctx);
  const pool = loadPool();
  console.log(`  Pool: ${pool.length}`);
  console.log(`  Pairs: ${PAIRS.map(p => `${p.id}=${p.name}`).join(", ")}`);

  // Reachability
  try {
    const tip = await ctx.call("getblockcount");
    console.log(`  Tip: ${tip}`);
  } catch (e) {
    console.error(`FATAL: ${e.message}`);
    process.exit(2);
  }

  const perPairStats = {};
  for (const p of PAIRS) {
    perPairStats[p.id] = {
      pair_id: p.id, name: p.name, mid: 0,
      placed: 0, accepted: 0, cancelled: 0, filled: 0, failed: 0, skipped: 0,
      errors: [], userOrders: [],
    };
  }

  for (const pair of PAIRS) {
    await tradePair(pair, pool, opts.dryRun, perPairStats);
  }

  // ── Summary ──────────────────────────────────────────────────────────────
  section("Summary");
  let totalPlaced = 0, totalAccepted = 0, totalCancelled = 0, totalFilled = 0, totalFailed = 0;
  for (const p of PAIRS) {
    const s = perPairStats[p.id];
    console.log(`  ${p.name.padEnd(10)} mid=${s.mid.toFixed(6)} placed=${s.placed} ok=${s.accepted} cancel=${s.cancelled} fill=${s.filled} fail=${s.failed} skip=${s.skipped}`);
    totalPlaced += s.placed; totalAccepted += s.accepted;
    totalCancelled += s.cancelled; totalFilled += s.filled;
    totalFailed += s.failed;
  }
  console.log(`  TOTAL    placed=${totalPlaced} ok=${totalAccepted} cancel=${totalCancelled} fill=${totalFilled} fail=${totalFailed}`);

  // ── Report ───────────────────────────────────────────────────────────────
  const lines = [];
  lines.push(`# Multi-wallet Trading Report`);
  lines.push(``);
  lines.push(`- chain: \`${opts.chain}\``);
  lines.push(`- rpc:   \`${ctx.url}\``);
  lines.push(`- mode:  ${opts.dryRun ? "**dry-run (validate only)**" : "**WRITE**"}`);
  lines.push(`- ts:    ${new Date().toISOString()}`);
  lines.push(``);
  lines.push(`| pair_id | pair | mid | placed | accepted | cancelled | filled | failed | skipped |`);
  lines.push(`|---:|:--|---:|---:|---:|---:|---:|---:|---:|`);
  for (const p of PAIRS) {
    const s = perPairStats[p.id];
    lines.push(`| ${p.id} | ${p.name} | ${s.mid.toFixed(6)} | ${s.placed} | ${s.accepted} | ${s.cancelled} | ${s.filled} | ${s.failed} | ${s.skipped} |`);
  }
  lines.push(``);
  lines.push(`**Total**: ${totalAccepted}/${totalPlaced} accepted, ${totalCancelled} cancelled, ${totalFilled} filled, ${totalFailed} failed.`);
  lines.push(``);
  lines.push(`## Per-wallet open orders snapshot`);
  for (const p of PAIRS) {
    const s = perPairStats[p.id];
    if (!s.userOrders.length) continue;
    lines.push(`### pair ${p.id} ${p.name}`);
    lines.push(`| wallet | open orders |`);
    lines.push(`|:--|---:|`);
    for (const u of s.userOrders) lines.push(`| ${u.wallet} | ${u.count} |`);
  }
  if (Object.values(perPairStats).some(s => s.errors.length)) {
    lines.push(``);
    lines.push(`## Errors (first 10 per pair)`);
    for (const p of PAIRS) {
      const s = perPairStats[p.id];
      if (!s.errors.length) continue;
      lines.push(`### pair ${p.id} ${p.name}`);
      for (const e of s.errors.slice(0, 10)) lines.push(`- ${e}`);
    }
  }
  const out = join(__dirname, "multiwallet-trading-report.md");
  writeFileSync(out, lines.join("\n"));
  console.log(`  Report: ${out}`);

  process.exit(totalFailed === 0 ? 0 : 1);
}

main().catch((e) => { console.error("FATAL:", e); process.exit(1); });
