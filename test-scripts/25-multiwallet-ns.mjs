#!/usr/bin/env node
/**
 * 25-multiwallet-ns.mjs — Naming-service flow across the 10-wallet pool.
 *
 * Exercises the full NS surface against ten distinct wallets:
 *   - registername "wallet<i>.omnibus" (per wallet)
 *   - resolvename / reverseresolvename
 *   - transfername (w[3] → w[7])
 *   - renewname    (w[0] +1y)
 *   - setpqaddress (w[0] sets a PQ alias on wallet0.omnibus)
 *   - setcategory  (w[1] tags wallet1.omnibus = "personal")
 *   - ns_expiringSoon
 *   - ns_getNamesByCategory
 *
 * Defaults to TESTNET. Use --dry-run to skip mutating RPCs and just probe.
 *
 * Usage:
 *   node 25-multiwallet-ns.mjs                    # testnet, full flow
 *   node 25-multiwallet-ns.mjs --dry-run          # read-only inspection
 *   node 25-multiwallet-ns.mjs --chain regtest
 */

import {
  parseArgs, mkRpc, loadPool, getBalance, getNonce,
  submitTx, submitMemoTx, getTip, waitForBlock,
  fmtSat, fmtAddr, header, section, sleep,
} from "./_wallet-pool.mjs";
import { writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const opts = parseArgs(process.argv);
const ctx  = mkRpc(opts);

// Names always live under the .omnibus TLD for the test.
const TLD = "omnibus";
const nameFor = (i) => `wallet${i}.${TLD}`;

// Default register fee on testnet is 0.1 OMNI (project_omnibus_evm_build_blocker memory).
// We let the chain compute the actual fee — we just send a TX with a memo;
// the chain pulls the fee out of the amount.
const REGISTER_FEE_SAT = 100_000_000; // 0.1 OMNI buffer

async function main() {
  header("Multi-wallet NS / .omnibus flow (3/10)", ctx);

  const pool = loadPool();
  console.log(`  Pool: ${pool.length} wallets`);

  // ── Cheap probes (sanity) ────────────────────────────────────────────────
  section("Sanity: NS RPC inventory");
  for (const m of ["ns_listTlds", "ns_yearTiers", "ns_getensfee", "ns_stats"]) {
    try {
      const params = m === "ns_getensfee" ? [{ tld: TLD }] : [];
      const r = await ctx.call(m, params);
      console.log(`  ${m}: ${JSON.stringify(r).slice(0, 120)}`);
    } catch (e) {
      console.log(`  ${m}: ${e.skip ? "SKIP" : `ERR ${e.message.slice(0, 60)}`}`);
    }
  }

  // ── Pre-state balances ───────────────────────────────────────────────────
  section("Pre-flight balances");
  const balPre = [];
  for (const w of pool) {
    const b = await getBalance(ctx, w.address);
    balPre.push(b);
    console.log(`  ${w.label.padEnd(8)} ${fmtAddr(w.address).padEnd(28)} ${fmtSat(b)}`);
  }

  const stats = {
    registered: 0, registerFailed: 0,
    resolved:   0, resolveFailed:  0,
    reverseHits:0,
    transferred:0,
    renewed:    0,
    setpq:      0,
    setcat:     0,
    expiringQueried: 0,
    errors: [],
  };

  // ── 1) Register wallet<i>.omnibus from each wallet ───────────────────────
  if (!opts.dryRun) {
    section("Register wallet<i>.omnibus (10 names, one per wallet)");
    for (let i = 0; i < pool.length; i++) {
      const name = nameFor(i);
      const w    = pool[i];
      // Try the dedicated registername RPC (object-form). Falls back to a
      // memo TX if the chain only accepts the on-chain registration path.
      let ok = false, txid = "";
      try {
        const r = await ctx.call("registername", [{
          name, address: w.address, years: 1,
        }]);
        if (r?.txid || r?.tx_id || r?.status === "ok" || r?.success) {
          ok = true; txid = r.txid ?? r.tx_id ?? "";
        }
      } catch (e) {
        if (e.skip) {
          // Fall back to a memo TX with op_return = "ns:register:<name>"
          try {
            const memo = `ns:register:${name}`;
            const r = await submitMemoTx(ctx, w, {
              to:       w.address, amount: REGISTER_FEE_SAT,
              opReturn: memo,
            });
            if (r.ok) { ok = true; txid = r.txid; }
          } catch { /* fall through */ }
        } else {
          stats.errors.push(`register ${name}: ${e.message.slice(0, 80)}`);
        }
      }
      if (ok) {
        stats.registered++;
        console.log(`  ${name.padEnd(20)} OK ${txid.slice(0, 16)}…`);
      } else {
        stats.registerFailed++;
        console.log(`  ${name.padEnd(20)} FAIL`);
      }
      await sleep(60);
    }
  }

  // ── 2) Resolve each name ─────────────────────────────────────────────────
  section("Resolve each wallet<i>.omnibus");
  for (let i = 0; i < pool.length; i++) {
    const name = nameFor(i);
    try {
      const r = await ctx.call("resolvename", [name]);
      const addr = typeof r === "string" ? r : (r?.address ?? r?.addr ?? "");
      if (addr) {
        stats.resolved++;
        const match = addr === pool[i].address ? "✓" : "≠";
        console.log(`  ${name.padEnd(20)} → ${fmtAddr(addr)} [${match}]`);
      } else {
        stats.resolveFailed++;
        console.log(`  ${name.padEnd(20)} → (empty)`);
      }
    } catch (e) {
      stats.resolveFailed++;
      const tag = /not found|does not exist|unregistered/i.test(e.message) ? "unregistered" : "ERR";
      console.log(`  ${name.padEnd(20)} → ${tag}`);
    }
  }

  // ── 3) Reverse-resolve a few wallets ─────────────────────────────────────
  section("Reverse-resolve wallet[5] and wallet[2]");
  for (const i of [5, 2]) {
    try {
      const r = await ctx.call("reverseresolvename", [pool[i].address]);
      const name = typeof r === "string" ? r : (r?.name ?? "");
      if (name) {
        stats.reverseHits++;
        console.log(`  ${fmtAddr(pool[i].address)} → ${name}`);
      } else {
        console.log(`  ${fmtAddr(pool[i].address)} → (none)`);
      }
    } catch (e) {
      console.log(`  ${fmtAddr(pool[i].address)} → ${e.skip ? "SKIP" : "ERR"}`);
    }
  }

  if (!opts.dryRun) {
    // ── 4) Transfer wallet3.omnibus → wallet7 ──────────────────────────────
    section("Transfer wallet3.omnibus → wallet7");
    try {
      const r = await ctx.call("transfername", [{
        name: nameFor(3), new_owner: pool[7].address,
      }]);
      if (r) {
        stats.transferred++;
        console.log(`  OK: ${JSON.stringify(r).slice(0, 80)}`);
      }
    } catch (e) {
      console.log(`  ${e.skip ? "SKIP" : `ERR ${e.message.slice(0, 60)}`}`);
    }

    // ── 5) Renew wallet0.omnibus +1y ────────────────────────────────────────
    section("Renew wallet0.omnibus +1y");
    try {
      const r = await ctx.call("renewname", [{ name: nameFor(0), years: 1 }]);
      if (r) {
        stats.renewed++;
        console.log(`  OK: ${JSON.stringify(r).slice(0, 80)}`);
      }
    } catch (e) {
      console.log(`  ${e.skip ? "SKIP" : `ERR ${e.message.slice(0, 60)}`}`);
    }

    // ── 6) Set PQ address on wallet0.omnibus ───────────────────────────────
    section("setpqaddress on wallet0.omnibus (alias = wallet0 OMNI addr as placeholder)");
    try {
      const r = await ctx.call("setpqaddress", [{
        name: nameFor(0),
        scheme: "ml_dsa_87",
        pq_address: `obk1_${pool[0].address.slice(4, 36)}`,
      }]);
      if (r) {
        stats.setpq++;
        console.log(`  OK: ${JSON.stringify(r).slice(0, 80)}`);
      }
    } catch (e) {
      console.log(`  ${e.skip ? "SKIP" : `ERR ${e.message.slice(0, 60)}`}`);
    }

    // ── 7) Tag wallet1.omnibus category="personal" ─────────────────────────
    section('setcategory wallet1.omnibus = "personal"');
    try {
      const r = await ctx.call("setcategory", [{
        name: nameFor(1), category: "personal",
      }]);
      if (r) {
        stats.setcat++;
        console.log(`  OK: ${JSON.stringify(r).slice(0, 80)}`);
      }
    } catch (e) {
      console.log(`  ${e.skip ? "SKIP" : `ERR ${e.message.slice(0, 60)}`}`);
    }

    await sleep(2000);
  }

  // ── 8) Expiring-soon query ───────────────────────────────────────────────
  section("ns_expiringSoon (within next 100k blocks)");
  try {
    const r = await ctx.call("ns_expiringSoon", [{ tld: TLD, within_blocks: 100000 }]);
    stats.expiringQueried = 1;
    const arr = Array.isArray(r) ? r : (r?.names ?? []);
    console.log(`  ${Array.isArray(arr) ? arr.length : "?"} names expiring soon`);
  } catch (e) {
    console.log(`  ${e.skip ? "SKIP" : `ERR ${e.message.slice(0, 60)}`}`);
  }

  // ── 9) getNamesByCategory ────────────────────────────────────────────────
  section('ns_getNamesByCategory category="personal"');
  try {
    const r = await ctx.call("ns_getNamesByCategory", [{ category: "personal" }]);
    const arr = Array.isArray(r) ? r : (r?.names ?? []);
    console.log(`  ${Array.isArray(arr) ? arr.length : "?"} names tagged "personal"`);
    if (Array.isArray(arr)) {
      for (const n of arr.slice(0, 5)) console.log(`    - ${typeof n === "string" ? n : JSON.stringify(n)}`);
    }
  } catch (e) {
    console.log(`  ${e.skip ? "SKIP" : `ERR ${e.message.slice(0, 60)}`}`);
  }

  // ── Summary + report ─────────────────────────────────────────────────────
  section("Summary");
  console.log(`  registered=${stats.registered}/${pool.length}  resolved=${stats.resolved}  reverseHits=${stats.reverseHits}`);
  console.log(`  transferred=${stats.transferred}  renewed=${stats.renewed}  setpq=${stats.setpq}  setcat=${stats.setcat}`);
  console.log(`  errors=${stats.errors.length}`);

  const lines = [];
  lines.push(`# Multi-wallet NS Report`);
  lines.push(``);
  lines.push(`- chain: \`${opts.chain}\``);
  lines.push(`- rpc:   \`${ctx.url}\``);
  lines.push(`- mode:  ${opts.dryRun ? "**dry-run**" : "**WRITE**"}`);
  lines.push(`- ts:    ${new Date().toISOString()}`);
  lines.push(``);
  lines.push(`| metric | value |`);
  lines.push(`|:--|---:|`);
  lines.push(`| registered | ${stats.registered} / ${pool.length} |`);
  lines.push(`| resolved | ${stats.resolved} |`);
  lines.push(`| reverse-resolve hits | ${stats.reverseHits} |`);
  lines.push(`| transferred | ${stats.transferred} |`);
  lines.push(`| renewed | ${stats.renewed} |`);
  lines.push(`| setpqaddress | ${stats.setpq} |`);
  lines.push(`| setcategory | ${stats.setcat} |`);
  lines.push(`| expiringSoon queried | ${stats.expiringQueried} |`);
  if (stats.errors.length) {
    lines.push(``);
    lines.push(`## Errors`);
    for (const e of stats.errors.slice(0, 10)) lines.push(`- ${e}`);
  }
  const out = join(__dirname, "multiwallet-ns-report.md");
  writeFileSync(out, lines.join("\n"));
  console.log(`  Report: ${out}`);

  process.exit(stats.errors.length === 0 ? 0 : 1);
}

main().catch((e) => { console.error("FATAL:", e); process.exit(1); });
