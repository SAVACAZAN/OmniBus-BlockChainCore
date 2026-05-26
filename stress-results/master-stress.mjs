#!/usr/bin/env node
// Master stress harness — Exchange + Agents + HTLC + Oracle
// Runs phases 1-4, 6 (read-only). Phase 5 deferred to existing 13-dex-multichain-stress.mjs.

import fs from 'node:fs';
import path from 'node:path';

const RESULTS = 'c:/Kits work/limaje de programare/1_CORE/BlockChainCore/stress-results';
const ENDPOINTS = {
  mainnet: 'https://omnibusblockchain.cc:8443/api-mainnet',
  testnet: 'https://omnibusblockchain.cc:8443/api-testnet',
};
const WALLET = 'ob1qw6zhsqg29aht23fksk5w54lkgavatpgltqxlvl';

let id = 0;
const errors = []; // {phase, method, error, ts}
const latencies = []; // {phase, method, ms, ok}

function nowIso() { return new Date().toISOString(); }
function log(line) {
  const s = `[${nowIso()}] ${line}`;
  console.log(s);
  fs.appendFileSync(path.join(RESULTS, 'progress.log'), s + '\n');
}
function logErr(phase, method, err) {
  errors.push({ phase, method, error: String(err).slice(0, 300), ts: nowIso() });
}

async function rpc(net, method, params, phase = 'na') {
  const url = ENDPOINTS[net];
  const start = Date.now();
  try {
    const res = await fetch(url, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ jsonrpc: '2.0', method, params: params || {}, id: ++id }),
      signal: AbortSignal.timeout(20000),
    });
    const dt = Date.now() - start;
    const j = await res.json();
    latencies.push({ phase, method, ms: dt, ok: !j.error });
    if (j.error) {
      logErr(phase, method, j.error.message || JSON.stringify(j.error));
      return { ok: false, error: j.error, ms: dt };
    }
    return { ok: true, result: j.result, ms: dt };
  } catch (e) {
    const dt = Date.now() - start;
    latencies.push({ phase, method, ms: dt, ok: false });
    logErr(phase, method, e.message || String(e));
    return { ok: false, error: e.message, ms: dt };
  }
}

function pct(arr, p) {
  if (!arr.length) return 0;
  const sorted = [...arr].sort((a, b) => a - b);
  return sorted[Math.floor(sorted.length * p / 100)];
}

const phaseStats = {};
function record(phase, method, ms, ok) {
  phaseStats[phase] ??= { calls: 0, errors: 0, lat: [] };
  phaseStats[phase].calls++;
  if (!ok) phaseStats[phase].errors++;
  phaseStats[phase].lat.push(ms);
}

// ---------------------------- PHASE 1: Exchange RPC reads ----------------------------
async function phase1() {
  log('=== PHASE 1: Exchange RPC reads ===');
  const out = { mainnet: {}, testnet: {} };
  for (const net of ['mainnet', 'testnet']) {
    out[net].pairs = {};
    for (let pid = 0; pid < 7; pid++) {
      const info = await rpc(net, 'exchange_pairInfo', { pair_id: pid }, 'phase1');
      const orders = await rpc(net, 'exchange_listOrders', { pair_id: pid }, 'phase1');
      const trades = await rpc(net, 'exchange_getRecentTrades', { pair_id: pid, limit: 50 }, 'phase1');
      const userOrd = await rpc(net, 'exchange_getUserOrders', { trader: WALLET }, 'phase1');
      record('phase1', 'pairInfo', info.ms, info.ok);
      record('phase1', 'listOrders', orders.ms, orders.ok);
      record('phase1', 'recentTrades', trades.ms, trades.ok);
      record('phase1', 'userOrders', userOrd.ms, userOrd.ok);
      const ob = orders.ok ? orders.result : { asks: [], bids: [] };
      const asks = ob?.asks || ob?.sell || [];
      const bids = ob?.bids || ob?.buy || [];
      out[net].pairs[pid] = {
        info: info.ok ? info.result : null,
        asks_count: Array.isArray(asks) ? asks.length : 0,
        bids_count: Array.isArray(bids) ? bids.length : 0,
        best_ask: Array.isArray(asks) && asks[0] ? asks[0] : null,
        best_bid: Array.isArray(bids) && bids[0] ? bids[0] : null,
        recent_trades_count: trades.ok && Array.isArray(trades.result) ? trades.result.length :
                             trades.ok && trades.result?.trades ? trades.result.trades.length : 0,
        user_orders_count: userOrd.ok && Array.isArray(userOrd.result) ? userOrd.result.length :
                           userOrd.ok && userOrd.result?.orders ? userOrd.result.orders.length : 0,
      };
    }
  }
  // 100x latency loop on pair 0 mainnet
  log('  100x latency loop pair_id=0 mainnet...');
  const lats = [];
  for (let i = 0; i < 100; i++) {
    const r = await rpc('mainnet', 'exchange_listOrders', { pair_id: 0 }, 'phase1_loop');
    lats.push(r.ms);
    record('phase1_loop', 'listOrders', r.ms, r.ok);
  }
  out.loop_p50 = pct(lats, 50);
  out.loop_p95 = pct(lats, 95);
  out.loop_p99 = pct(lats, 99);
  out.loop_max = Math.max(...lats);
  fs.writeFileSync(path.join(RESULTS, 'phase1.json'), JSON.stringify(out, null, 2));
  log(`  done. p50=${out.loop_p50}ms p95=${out.loop_p95}ms p99=${out.loop_p99}ms`);
  return out;
}

// ---------------------------- PHASE 2: Grid trading ----------------------------
async function phase2() {
  log('=== PHASE 2: Grid trading ===');
  const out = { mainnet: {}, testnet: {} };
  for (const net of ['mainnet', 'testnet']) {
    const list = await rpc(net, 'grid_list', {}, 'phase2');
    record('phase2', 'grid_list', list.ms, list.ok);
    out[net].grids = list.ok ? list.result : null;
    if (list.ok && Array.isArray(list.result)) {
      out[net].statuses = [];
      for (const g of list.result.slice(0, 20)) {
        const gid = g.grid_id || g.id || g;
        const st = await rpc(net, 'grid_status', { grid_id: gid }, 'phase2');
        record('phase2', 'grid_status', st.ms, st.ok);
        out[net].statuses.push({ grid_id: gid, ok: st.ok, status: st.result, error: st.error });
      }
    }
  }
  fs.writeFileSync(path.join(RESULTS, 'phase2.json'), JSON.stringify(out, null, 2));
  log('  done');
  return out;
}

// ---------------------------- PHASE 3: HTLC / Atomic Swaps ----------------------------
async function phase3() {
  log('=== PHASE 3: HTLC / Atomic Swaps ===');
  const out = { mainnet: {}, testnet: {} };
  for (const net of ['mainnet', 'testnet']) {
    // 50x swap_listOpen
    const lats = [];
    let lastResult = null;
    for (let i = 0; i < 50; i++) {
      const r = await rpc(net, 'swap_listOpen', {}, 'phase3');
      record('phase3', 'swap_listOpen', r.ms, r.ok);
      lats.push(r.ms);
      if (r.ok) lastResult = r.result;
    }
    out[net].swap_listOpen = { samples: 50, p50: pct(lats, 50), p95: pct(lats, 95), last: lastResult };

    // 50x htlc_listByAddress
    const lats2 = [];
    let lastH = null;
    for (let i = 0; i < 50; i++) {
      const r = await rpc(net, 'htlc_listByAddress', { address: WALLET }, 'phase3');
      record('phase3', 'htlc_listByAddress', r.ms, r.ok);
      lats2.push(r.ms);
      if (r.ok) lastH = r.result;
    }
    out[net].htlc_listByAddress = { samples: 50, p50: pct(lats2, 50), last: lastH };

    // 50x htlc_listPending
    const lats3 = [];
    let lastP = null;
    for (let i = 0; i < 50; i++) {
      const r = await rpc(net, 'htlc_listPending', {}, 'phase3');
      record('phase3', 'htlc_listPending', r.ms, r.ok);
      lats3.push(r.ms);
      if (r.ok) lastP = r.result;
    }
    out[net].htlc_listPending = { samples: 50, p50: pct(lats3, 50), last: lastP };

    // For each open swap → swap_status
    const swaps = lastResult && Array.isArray(lastResult) ? lastResult :
                  lastResult?.swaps || lastResult?.open || [];
    out[net].swap_statuses = [];
    if (Array.isArray(swaps)) {
      for (const s of swaps.slice(0, 30)) {
        const sid = s.swap_id || s.id || s;
        const st = await rpc(net, 'swap_status', { swap_id: sid }, 'phase3');
        record('phase3', 'swap_status', st.ms, st.ok);
        // Detect stuck > 1h
        const created = s.created_at || s.timestamp || s.ts || 0;
        const ageHours = created ? (Date.now() / 1000 - created) / 3600 : 0;
        out[net].swap_statuses.push({
          swap_id: sid,
          ok: st.ok,
          age_hours: ageHours.toFixed(2),
          stuck: ageHours > 1,
          state: st.result?.state || st.result?.status || null,
        });
      }
    }
  }
  fs.writeFileSync(path.join(RESULTS, 'phase3.json'), JSON.stringify(out, null, 2));
  log('  done');
  return out;
}

// ---------------------------- PHASE 4: Agents ----------------------------
async function phase4() {
  log('=== PHASE 4: Agents ===');
  const out = { mainnet: {}, testnet: {} };
  for (const net of ['mainnet', 'testnet']) {
    // 100x getagents
    const lats = [];
    let lastList = null;
    for (let i = 0; i < 100; i++) {
      const r = await rpc(net, 'getagents', {}, 'phase4');
      record('phase4', 'getagents', r.ms, r.ok);
      lats.push(r.ms);
      if (r.ok) lastList = r.result;
    }
    out[net].getagents = { samples: 100, p50: pct(lats, 50), p95: pct(lats, 95), last: lastList };

    // For each agent → getagent + agent_status
    const agents = Array.isArray(lastList) ? lastList :
                   lastList?.agents || [];
    out[net].agents_detailed = [];
    if (Array.isArray(agents)) {
      for (const a of agents.slice(0, 20)) {
        const aid = a.id || a.agent_id || a;
        const ga = await rpc(net, 'getagent', { id: aid }, 'phase4');
        record('phase4', 'getagent', ga.ms, ga.ok);
        const st = await rpc(net, 'agent_status', { id: aid }, 'phase4');
        record('phase4', 'agent_status', st.ms, st.ok);
        out[net].agents_detailed.push({ id: aid, info: ga.result, status: st.result });
      }
    }

    // 50x agent_list (legacy) + agent_pending_decisions
    const al = await rpc(net, 'agent_list', {}, 'phase4');
    record('phase4', 'agent_list', al.ms, al.ok);
    out[net].agent_list_legacy = al.result;

    const lats2 = [];
    let lastPD = null;
    for (let i = 0; i < 50; i++) {
      const r = await rpc(net, 'agent_pending_decisions', {}, 'phase4');
      record('phase4', 'agent_pending_decisions', r.ms, r.ok);
      lats2.push(r.ms);
      if (r.ok) lastPD = r.result;
    }
    out[net].pending_decisions = { samples: 50, p50: pct(lats2, 50), last: lastPD };
  }
  fs.writeFileSync(path.join(RESULTS, 'phase4.json'), JSON.stringify(out, null, 2));
  log('  done');
  return out;
}

// ---------------------------- PHASE 6: Oracle ----------------------------
async function phase6Snapshot() {
  const ts = nowIso();
  const r1 = await rpc('mainnet', 'omnibus_getexchangefeed', {}, 'phase6');
  record('phase6', 'getexchangefeed', r1.ms, r1.ok);
  const r2 = await rpc('mainnet', 'omnibus_getallprices', { offset: 0, limit: 50 }, 'phase6');
  record('phase6', 'getallprices', r2.ms, r2.ok);
  const r3 = await rpc('mainnet', 'omnibus_getarbitrage', {}, 'phase6');
  record('phase6', 'getarbitrage', r3.ms, r3.ok);

  // Extract prices - feed = {prices:[{exchange,pair,bidMicroUsd,askMicroUsd,success}]}
  const feed = r1.result || {};
  const allP = r2.result || {};
  const arb = r3.result || {};
  const prices = feed.prices || [];
  function pick(ex, pair) {
    const e = prices.find(p => p.exchange === ex && p.pair === pair);
    return e ? (e.bidMicroUsd / 1e6).toFixed(4) : '';
  }
  const arbCount = Array.isArray(arb) ? arb.length :
                   (arb?.opportunities?.length || arb?.arbitrage?.length || 0);
  const row = {
    ts,
    btc_coinbase: pick('Coinbase', 'BTC/USD'),
    btc_kraken: pick('Kraken', 'BTC/USD'),
    btc_lcx: pick('LCX', 'BTC/USD'),
    lcx_coinbase: pick('Coinbase', 'LCX/USD'),
    lcx_kraken: pick('Kraken', 'LCX/USD'),
    lcx_lcx: pick('LCX', 'LCX/USD'),
    arb_count: arbCount,
    median_btc: feed.medianBtcMicroUsd ? (feed.medianBtcMicroUsd / 1e6).toFixed(4) : '',
    median_lcx: feed.medianLcxMicroUsd ? (feed.medianLcxMicroUsd / 1e6).toFixed(6) : '',
    allprices_count: Array.isArray(allP) ? allP.length :
                     (allP?.prices?.length || Object.keys(allP || {}).length),
  };
  return row;
}

async function phase6Run(durationMs) {
  log(`=== PHASE 6: Oracle (${durationMs / 60000}min) ===`);
  const csvPath = path.join(RESULTS, 'oracle-timeline.csv');
  fs.writeFileSync(csvPath, 'ts,btc_coinbase,btc_kraken,btc_lcx,lcx_coinbase,lcx_kraken,lcx_lcx,arb_count,median_btc,median_lcx,allprices_count\n');
  const start = Date.now();
  let snapshots = 0;
  while (Date.now() - start < durationMs) {
    const r = await phase6Snapshot();
    fs.appendFileSync(csvPath,
      `${r.ts},${r.btc_coinbase},${r.btc_kraken},${r.btc_lcx},${r.lcx_coinbase},${r.lcx_kraken},${r.lcx_lcx},${r.arb_count},${r.median_btc},${r.median_lcx},${r.allprices_count}\n`
    );
    snapshots++;
    if (snapshots % 12 === 0) log(`  Phase6 snapshots: ${snapshots}`);
    await new Promise(r => setTimeout(r, 5000));
  }
  log(`  done. ${snapshots} snapshots`);
  return { snapshots };
}

// ---------------------------- main ----------------------------
async function main() {
  fs.writeFileSync(path.join(RESULTS, 'progress.log'), `=== Stress test start ${nowIso()} ===\n`);
  log('Master stress harness booting');

  const summary = {};
  summary.phase1 = await phase1();
  summary.phase2 = await phase2();
  summary.phase3 = await phase3();
  summary.phase4 = await phase4();
  // Phase 6 short loop (10 min) — runs in main thread
  const dur = parseInt(process.env.PHASE6_MIN || '8', 10) * 60 * 1000;
  summary.phase6 = await phase6Run(dur);

  // Stats
  summary.phaseStats = {};
  for (const [p, s] of Object.entries(phaseStats)) {
    summary.phaseStats[p] = {
      calls: s.calls, errors: s.errors, error_rate: (s.errors / s.calls).toFixed(4),
      p50: pct(s.lat, 50), p95: pct(s.lat, 95), p99: pct(s.lat, 99), max: Math.max(...s.lat),
    };
  }
  summary.errors = errors;
  summary.error_count = errors.length;
  summary.total_calls = latencies.length;
  fs.writeFileSync(path.join(RESULTS, 'master-summary.json'), JSON.stringify(summary, null, 2));
  log(`=== ALL PHASES DONE === total_calls=${summary.total_calls} errors=${summary.error_count}`);
}

main().catch(e => {
  log(`FATAL: ${e.message}\n${e.stack}`);
  process.exit(1);
});
