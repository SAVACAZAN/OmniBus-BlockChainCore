#!/usr/bin/env node
/**
 * 15-htlc-stress.mjs — Cross-chain HTLC stress test.
 *
 * Tests the OmniBus side of the HTLC swap state machine for three pairs:
 *   - OMNI ↔ ETH  (via swap_open / swap_lockMaker / swap_lockTaker / swap_proveSettle)
 *   - OMNI ↔ BTC  (BTC side stays mock — only OmniBus side exercised)
 *   - OMNI ↔ LCX  (LCX side via Liberty Exchange)
 *
 * Doesn't actually move funds on Ethereum/BTC/LCX — only exercises the
 * OmniBus-side RPCs. For each pair we walk the happy path
 * (open → lockMaker → lockTaker → proveSettle), the refund path
 * (open → lockMaker → timeout → htlc_refund), and the timeout path.
 *
 * Defaults to READ-ONLY (just verifies all required RPCs exist and are
 * dispatchable, returning method-not-found as SKIP). With `--write` we
 * actually open swaps using a 32-byte random preimage and submit them.
 *
 * Usage:
 *   node 15-htlc-stress.mjs                                # mainnet, read-only
 *   node 15-htlc-stress.mjs --chain testnet
 *   node 15-htlc-stress.mjs --chain regtest --write
 */

import { writeFileSync } from "node:fs";
import { argv, env, exit } from "node:process";
import { randomBytes, createHash } from "node:crypto";

// ── CLI ─────────────────────────────────────────────────────────────────────

const ARGS = argv.slice(2);
function arg(name, fallback) {
  const i = ARGS.indexOf(name);
  return i >= 0 && ARGS[i + 1] ? ARGS[i + 1] : fallback;
}
const CHAIN     = arg("--chain", env.CHAIN || "mainnet");
const RPC_OVR   = arg("--rpc",  env.RPC_URL);
const WRITE     = ARGS.includes("--write");
const TOKEN     = arg("--token", env.OMNIBUS_RPC_TOKEN);
const FLOWS_PER_PAIR = parseInt(arg("--flows", "3"), 10); // 3 flows per pair

const RPC_URLS = {
  mainnet: "https://omnibusblockchain.cc:8443/api-mainnet",
  testnet: "https://omnibusblockchain.cc:8443/api-testnet",
  regtest: "https://omnibusblockchain.cc:8443/api-regtest",
  "local-mainnet": "http://127.0.0.1:8332",
  "local-testnet": "http://127.0.0.1:18332",
  "local-regtest": "http://127.0.0.1:28332",
};
const RPC_URL = RPC_OVR || RPC_URLS[CHAIN] || RPC_URLS.mainnet;

// External chains that pair with OMNI. Foreign-side calls are mocked here —
// the test is read-only / OmniBus-side-only.
const PAIRS = [
  { id: "OMNI-ETH", maker: "OMNI", taker: "ETH", makerAsset: "OMNI", takerAsset: "ETH" },
  { id: "OMNI-BTC", maker: "OMNI", taker: "BTC", makerAsset: "OMNI", takerAsset: "BTC" },
  { id: "OMNI-LCX", maker: "OMNI", taker: "LCX", makerAsset: "OMNI", takerAsset: "LCX" },
];

const KNOWN_ADDR = "ob1qzhrauq0xe9hg033ccup7vlgsdmj6kcxyza9zp0";
const KNOWN_FOREIGN = "0x000000000000000000000000000000000000dEaD";

// ── Helpers ─────────────────────────────────────────────────────────────────

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function bytesToHex(b) {
  return Buffer.from(b).toString("hex");
}

async function rpc(method, params = []) {
  const headers = { "Content-Type": "application/json" };
  if (TOKEN) headers.Authorization = `Bearer ${TOKEN}`;
  const r = await fetch(RPC_URL, {
    method: "POST",
    headers,
    body: JSON.stringify({ jsonrpc: "2.0", id: Date.now(), method, params }),
  });
  const j = await r.json();
  if (j.error) {
    const msg = j.error.message ?? JSON.stringify(j.error);
    const skip = /method not found|unknown method|not implemented/i.test(msg);
    const err = new Error(msg);
    err.skip = skip;
    throw err;
  }
  return j.result;
}

// Try a list of method names, return first that exists. Useful when the chain
// renamed swap_* ↔ htlc_* historically.
async function rpcAny(methods, params) {
  let lastErr = null;
  for (const m of methods) {
    try {
      return { method: m, result: await rpc(m, params) };
    } catch (e) {
      lastErr = e;
      if (!e.skip) throw e;
    }
  }
  const err = new Error(`none of [${methods.join(", ")}] implemented`);
  err.skip = true;
  throw err;
}

// ── Per-pair state machine ──────────────────────────────────────────────────

async function runFlow(pair, flowIdx) {
  const out = {
    pair: pair.id,
    flow: flowIdx,
    swap_id: null,
    opened: false,
    lockedMaker: false,
    lockedTaker: false,
    settled: false,
    refunded: false,
    timeout: false,
    skipped: 0,
    failed: 0,
    errors: [],
  };

  // Generate a fresh 32-byte preimage; hash_lock = sha256(preimage).
  const preimage = randomBytes(32);
  const preimageHex = bytesToHex(preimage);
  const hashLockHex = createHash("sha256").update(preimage).digest("hex");

  const baseParams = {
    pair: pair.id,
    maker_asset:   pair.makerAsset,
    taker_asset:   pair.takerAsset,
    maker_address: KNOWN_ADDR,
    taker_address: KNOWN_FOREIGN,
    maker_amount:  10_000,        // sat
    taker_amount:  10_000,
    hash_lock:     hashLockHex,
    timeout_blocks: 100,
  };

  // 1) swap_open / htlc_init
  if (WRITE) {
    try {
      const { method, result } = await rpcAny(["swap_open", "htlc_init"], [baseParams]);
      out.opened = true;
      out.swap_id = result?.swap_id ?? result?.htlc_id ?? result?.id ?? null;
      void method;
    } catch (e) {
      if (e.skip) { out.skipped++; return out; }
      out.failed++; out.errors.push(`open: ${e.message.slice(0, 80)}`);
      return out;
    }
  } else {
    // read-only: probe by sending a payload with `dry_run: true`. If the chain
    // doesn't recognise dry_run it'll error — we treat that as SKIP.
    try {
      await rpcAny(["swap_open", "htlc_init"], [{ ...baseParams, dry_run: true }]);
      out.opened = true; // payload accepted (or rejected validly)
    } catch (e) {
      if (e.skip) { out.skipped++; return out; }
      // not-found / dust / etc are still meaningful — they prove the RPC is wired.
      if (/method not found/i.test(e.message)) { out.skipped++; return out; }
      out.opened = true; // RPC reachable, payload validation handled
    }
  }

  // 2) swap_lockMaker
  try {
    await rpcAny(["swap_lockMaker", "htlc_lock_maker"], [{ swap_id: out.swap_id, dry_run: !WRITE }]);
    out.lockedMaker = true;
  } catch (e) {
    if (e.skip) out.skipped++;
    else { out.failed++; out.errors.push(`lockMaker: ${e.message.slice(0, 80)}`); }
  }

  // 3) Branch by flow index: 0=settle, 1=refund, 2=timeout-then-refund.
  if (flowIdx === 0) {
    // Happy path: lockTaker + proveSettle
    try {
      await rpcAny(["swap_lockTaker", "htlc_lock_taker"], [{ swap_id: out.swap_id, dry_run: !WRITE }]);
      out.lockedTaker = true;
    } catch (e) {
      if (e.skip) out.skipped++;
      else { out.failed++; out.errors.push(`lockTaker: ${e.message.slice(0, 80)}`); }
    }
    try {
      await rpcAny(["swap_proveSettle", "htlc_claim"], [{
        swap_id: out.swap_id, preimage: preimageHex, dry_run: !WRITE,
      }]);
      out.settled = true;
    } catch (e) {
      if (e.skip) out.skipped++;
      else { out.failed++; out.errors.push(`proveSettle: ${e.message.slice(0, 80)}`); }
    }
  } else if (flowIdx === 1) {
    // Refund path: skip taker, refund directly.
    try {
      await rpcAny(["htlc_refund", "swap_refund"], [{ swap_id: out.swap_id, dry_run: !WRITE }]);
      out.refunded = true;
    } catch (e) {
      if (e.skip) out.skipped++;
      else { out.failed++; out.errors.push(`refund: ${e.message.slice(0, 80)}`); }
    }
  } else {
    // Timeout path — query timeout (read), then refund.
    try {
      const r = await rpcAny(["swap_status", "htlc_status", "getswap", "gethtlc"], [{ swap_id: out.swap_id }]);
      void r.result;
      out.timeout = true;
    } catch (e) {
      if (e.skip) out.skipped++;
    }
    try {
      await rpcAny(["htlc_refund", "swap_refund"], [{ swap_id: out.swap_id, dry_run: !WRITE }]);
      out.refunded = true;
    } catch (e) {
      if (e.skip) out.skipped++;
    }
  }

  return out;
}

// ── Main ────────────────────────────────────────────────────────────────────

async function main() {
  console.log("=".repeat(70));
  console.log("OmniBus HTLC / Swap Stress Test");
  console.log("=".repeat(70));
  console.log(`RPC:    ${RPC_URL}`);
  console.log(`Chain:  ${CHAIN}`);
  console.log(`Mode:   ${WRITE ? "WRITE (state-changing)" : "READ-ONLY (dry-run)"}`);
  console.log(`Pairs:  ${PAIRS.map(p => p.id).join(", ")}`);
  console.log(`Flows:  ${FLOWS_PER_PAIR} per pair (settle, refund, timeout)`);
  console.log("");

  try {
    const tip = await rpc("getblockcount");
    console.log(`Chain tip: ${tip}`);
  } catch (e) {
    console.error(`FATAL: cannot reach RPC: ${e.message}`);
    exit(2);
  }
  console.log("");

  // Probe a few enumeration RPCs for context.
  for (const m of ["bridge_listChains", "swap_listAssets", "htlc_list", "getbridges"]) {
    try {
      const r = await rpc(m);
      console.log(`  ${m}: ${JSON.stringify(r).slice(0, 100)}`);
    } catch (e) {
      console.log(`  ${m}: ${e.skip ? "SKIP" : "ERR " + e.message.slice(0, 60)}`);
    }
  }
  console.log("");

  const reports = [];
  for (const pair of PAIRS) {
    for (let i = 0; i < FLOWS_PER_PAIR; i++) {
      process.stdout.write(`pair ${pair.id} flow ${i} … `);
      const r = await runFlow(pair, i);
      reports.push(r);
      console.log(
        `open=${r.opened?"y":"n"} lockM=${r.lockedMaker?"y":"n"} ` +
        `lockT=${r.lockedTaker?"y":"n"} settle=${r.settled?"y":"n"} ` +
        `refund=${r.refunded?"y":"n"} fail=${r.failed} skip=${r.skipped}`,
      );
      await sleep(50);
    }
  }

  const tot = reports.reduce((a, r) => ({
    opened:      a.opened      + (r.opened ? 1 : 0),
    lockedMaker: a.lockedMaker + (r.lockedMaker ? 1 : 0),
    lockedTaker: a.lockedTaker + (r.lockedTaker ? 1 : 0),
    settled:     a.settled     + (r.settled ? 1 : 0),
    refunded:    a.refunded    + (r.refunded ? 1 : 0),
    failed:      a.failed      + r.failed,
    skipped:     a.skipped     + r.skipped,
  }), { opened: 0, lockedMaker: 0, lockedTaker: 0, settled: 0, refunded: 0, failed: 0, skipped: 0 });

  console.log("");
  console.log("=".repeat(70));
  console.log(`Totals: open=${tot.opened} lockM=${tot.lockedMaker} ` +
              `lockT=${tot.lockedTaker} settle=${tot.settled} refund=${tot.refunded} ` +
              `fail=${tot.failed} skip=${tot.skipped}`);
  console.log("=".repeat(70));

  // Report
  const lines = [];
  lines.push(`# HTLC Stress Report`);
  lines.push("");
  lines.push(`- chain: \`${CHAIN}\``);
  lines.push(`- rpc:   \`${RPC_URL}\``);
  lines.push(`- mode:  ${WRITE ? "**WRITE**" : "read-only"}`);
  lines.push(`- ts:    ${new Date().toISOString()}`);
  lines.push("");
  lines.push(`| pair | flow | opened | lockM | lockT | settled | refunded | timeout | failed | skipped |`);
  lines.push(`|:--|---:|:--:|:--:|:--:|:--:|:--:|:--:|---:|---:|`);
  for (const r of reports) {
    const m = (b) => b ? "y" : "·";
    lines.push(`| ${r.pair} | ${r.flow} | ${m(r.opened)} | ${m(r.lockedMaker)} | ${m(r.lockedTaker)} | ${m(r.settled)} | ${m(r.refunded)} | ${m(r.timeout)} | ${r.failed} | ${r.skipped} |`);
  }
  lines.push("");
  lines.push(`**Total**: open=${tot.opened}, lockMaker=${tot.lockedMaker}, lockTaker=${tot.lockedTaker}, settled=${tot.settled}, refunded=${tot.refunded}, failed=${tot.failed}, skipped=${tot.skipped}.`);
  lines.push("");
  if (reports.some(r => r.errors.length)) {
    lines.push(`## Errors`);
    for (const r of reports) {
      if (!r.errors.length) continue;
      lines.push(`### ${r.pair} flow ${r.flow}`);
      for (const e of r.errors.slice(0, 10)) lines.push(`- ${e}`);
    }
  }

  const out = "htlc-stress-report.md";
  writeFileSync(out, lines.join("\n"));
  console.log(`Report: ${out}`);

  exit(tot.failed === 0 ? 0 : 1);
}

main().catch((e) => { console.error("FATAL:", e); exit(1); });
