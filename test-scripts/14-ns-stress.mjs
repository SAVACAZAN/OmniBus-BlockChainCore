#!/usr/bin/env node
/**
 * 14-ns-stress.mjs — Naming service (NS / .omnibus / institutional TLDs) stress test.
 *
 * What it does:
 *   1. Fetches the active TLD list via `ns_listTlds`.
 *   2. For each TLD, generates 20 random names: `stresstest-<random>.<tld>`
 *      and exercises:
 *        - registername (skipped unless --write)
 *        - resolvename
 *        - reverseresolvename
 *        - ns_getNamesByCategory
 *        - ns_expiringSoon
 *        - transfername / renewname (write only)
 *      Read-only mode (default) just calls resolve/reverse/expiringSoon for
 *      already-existing names so it never mutates state.
 *   3. Tracks success rates per TLD; writes ns-stress-report.md.
 *
 * Usage:
 *   node 14-ns-stress.mjs                                  # mainnet read-only
 *   node 14-ns-stress.mjs --chain testnet
 *   node 14-ns-stress.mjs --chain regtest --write          # actually register
 *   node 14-ns-stress.mjs --rpc http://127.0.0.1:8332 --write
 */

import { writeFileSync } from "node:fs";
import { argv, env, exit } from "node:process";

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
const NAMES_PER_TLD = parseInt(arg("--per-tld", "20"), 10);

const RPC_URLS = {
  mainnet: "https://omnibusblockchain.cc:8443/api-mainnet",
  testnet: "https://omnibusblockchain.cc:8443/api-testnet",
  regtest: "https://omnibusblockchain.cc:8443/api-regtest",
  "local-mainnet": "http://127.0.0.1:8332",
  "local-testnet": "http://127.0.0.1:18332",
  "local-regtest": "http://127.0.0.1:28332",
};
const RPC_URL = RPC_OVR || RPC_URLS[CHAIN] || RPC_URLS.mainnet;

// Fallback list — used if `ns_listTlds` doesn't exist or returns empty.
// Covers the 8 institutional TLDs documented in the OmniBus spec.
const FALLBACK_TLDS = [
  "omnibus", "arbitraje", "bank", "gov", "edu", "ngo", "news", "med",
];

// Known address (savacazan) for reverse resolve.
const KNOWN_ADDR = "ob1qzhrauq0xe9hg033ccup7vlgsdmj6kcxyza9zp0";
const KNOWN_NAME = "savacazan.omnibus";

// ── Helpers ─────────────────────────────────────────────────────────────────

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function rand() {
  return Math.random().toString(36).slice(2, 10);
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

// ── Per-TLD stress ──────────────────────────────────────────────────────────

async function stressTld(tld) {
  const out = {
    tld,
    generated: 0,
    registered: 0,
    resolved: 0,
    reverseHits: 0,
    transferred: 0,
    renewed: 0,
    expiring: 0,
    failed: 0,
    skipped: 0,
    errors: [],
  };

  const names = [];
  for (let i = 0; i < NAMES_PER_TLD; i++) {
    names.push(`stresstest-${rand()}.${tld}`);
  }
  out.generated = names.length;

  // ns_expiringSoon (cheap, per-TLD).
  try {
    const r = await rpc("ns_expiringSoon", [{ tld, within_blocks: 100000 }]);
    if (Array.isArray(r) || (r && typeof r === "object")) {
      const arr = Array.isArray(r) ? r : (r.names ?? []);
      out.expiring = Array.isArray(arr) ? arr.length : 0;
    }
  } catch (e) {
    if (e.skip) out.skipped++; else { out.failed++; out.errors.push(`expiringSoon: ${e.message.slice(0, 80)}`); }
  }

  // ns_getNamesByCategory — try a generic category (institutional uses category=tld).
  try {
    const r = await rpc("ns_getNamesByCategory", [{ category: tld }]);
    void r;
  } catch (e) {
    if (e.skip) out.skipped++;
  }

  // Resolve + register loop.
  for (const name of names) {
    if (WRITE) {
      try {
        const r = await rpc("registername", [{ name, address: KNOWN_ADDR, years: 1 }]);
        if (r?.txid || r?.tx_id || r?.status === "ok") {
          out.registered++;
        } else {
          out.failed++;
          out.errors.push(`register ${name}: empty`);
        }
      } catch (e) {
        if (e.skip) out.skipped++;
        else { out.failed++; out.errors.push(`register ${name}: ${e.message.slice(0, 80)}`); }
      }
      await sleep(50);
    }

    // Always try resolve (read-only).
    try {
      const r = await rpc("resolvename", [name]);
      if (r) out.resolved++;
    } catch (e) {
      if (e.skip) { out.skipped++; }
      // For unregistered names this is expected to fail with "not found";
      // only count true RPC errors as failures.
      else if (!/not found|does not exist|unregistered/i.test(e.message)) {
        out.failed++;
        out.errors.push(`resolve ${name}: ${e.message.slice(0, 80)}`);
      }
    }

    if (WRITE) {
      // transfername to self (no-op semantically but exercises the path).
      try {
        await rpc("transfername", [{ name, new_owner: KNOWN_ADDR }]);
        out.transferred++;
      } catch (e) {
        if (e.skip) out.skipped++;
      }
      // renewname for 1 more year.
      try {
        await rpc("renewname", [{ name, years: 1 }]);
        out.renewed++;
      } catch (e) {
        if (e.skip) out.skipped++;
      }
      await sleep(50);
    }
  }

  // Reverse resolve a known address.
  try {
    const r = await rpc("reverseresolvename", [KNOWN_ADDR]);
    if (typeof r === "string" || (r && r.name)) out.reverseHits++;
  } catch (e) {
    if (e.skip) out.skipped++;
  }

  return out;
}

// ── Main ────────────────────────────────────────────────────────────────────

async function main() {
  console.log("=".repeat(70));
  console.log("OmniBus NS (.omnibus) Stress Test");
  console.log("=".repeat(70));
  console.log(`RPC:    ${RPC_URL}`);
  console.log(`Chain:  ${CHAIN}`);
  console.log(`Mode:   ${WRITE ? "WRITE (state-changing)" : "READ-ONLY"}`);
  console.log(`Names:  ${NAMES_PER_TLD} per TLD`);
  console.log("");

  try {
    const tip = await rpc("getblockcount");
    console.log(`Chain tip: ${tip}`);
  } catch (e) {
    console.error(`FATAL: cannot reach RPC: ${e.message}`);
    exit(2);
  }
  console.log("");

  // Discover TLDs
  let tlds = [];
  try {
    const list = await rpc("ns_listTlds");
    if (Array.isArray(list)) {
      tlds = list.map(x => typeof x === "string" ? x : (x.tld ?? x.name ?? "")).filter(Boolean);
    } else if (list && typeof list === "object") {
      tlds = Object.keys(list);
    }
  } catch (e) {
    if (!e.skip) console.error(`ns_listTlds: ${e.message}`);
  }
  if (!tlds.length) {
    console.log(`(ns_listTlds unavailable — using fallback list)`);
    tlds = FALLBACK_TLDS.slice();
  }
  console.log(`TLDs:   ${tlds.join(", ")}`);
  console.log("");

  // Quick stats (cheap)
  for (const m of ["ns_yearTiers", "ns_stats", "ns_getensfee"]) {
    try {
      const params = m === "ns_getensfee" ? [{ tld: tlds[0] }] : [];
      const r = await rpc(m, params);
      console.log(`  ${m}: ${JSON.stringify(r).slice(0, 100)}`);
    } catch (e) {
      console.log(`  ${m}: ${e.skip ? "SKIP (not implemented)" : "ERR " + e.message.slice(0, 60)}`);
    }
  }

  // Probe known name once (sanity).
  try {
    const r = await rpc("resolvename", [KNOWN_NAME]);
    console.log(`  resolvename(${KNOWN_NAME}): ${typeof r === "string" ? r : JSON.stringify(r).slice(0, 60)}`);
  } catch (e) {
    console.log(`  resolvename(${KNOWN_NAME}): ${e.skip ? "SKIP" : "ERR"}`);
  }
  console.log("");

  const reports = [];
  for (const tld of tlds) {
    process.stdout.write(`tld .${tld.padEnd(10)} … `);
    const r = await stressTld(tld);
    reports.push(r);
    console.log(
      `gen=${r.generated} reg=${r.registered} res=${r.resolved} ` +
      `rev=${r.reverseHits} exp=${r.expiring} fail=${r.failed} skip=${r.skipped}`,
    );
  }

  const tot = reports.reduce((a, r) => ({
    generated:  a.generated  + r.generated,
    registered: a.registered + r.registered,
    resolved:   a.resolved   + r.resolved,
    failed:     a.failed     + r.failed,
    skipped:    a.skipped    + r.skipped,
  }), { generated: 0, registered: 0, resolved: 0, failed: 0, skipped: 0 });

  console.log("");
  console.log("=".repeat(70));
  console.log(`Totals: gen=${tot.generated} reg=${tot.registered} ` +
              `res=${tot.resolved} fail=${tot.failed} skip=${tot.skipped}`);
  console.log("=".repeat(70));

  // Report
  const lines = [];
  lines.push(`# NS Stress Report`);
  lines.push("");
  lines.push(`- chain: \`${CHAIN}\``);
  lines.push(`- rpc:   \`${RPC_URL}\``);
  lines.push(`- mode:  ${WRITE ? "**WRITE**" : "read-only"}`);
  lines.push(`- ts:    ${new Date().toISOString()}`);
  lines.push("");
  lines.push(`| TLD | generated | registered | resolved | reverse | expiring | transferred | renewed | failed | skipped |`);
  lines.push(`|:--|---:|---:|---:|---:|---:|---:|---:|---:|---:|`);
  for (const r of reports) {
    lines.push(`| .${r.tld} | ${r.generated} | ${r.registered} | ${r.resolved} | ${r.reverseHits} | ${r.expiring} | ${r.transferred} | ${r.renewed} | ${r.failed} | ${r.skipped} |`);
  }
  lines.push("");
  lines.push(`**Total**: ${tot.registered}/${tot.generated} registered, ${tot.resolved} resolved, ${tot.failed} failed, ${tot.skipped} skipped.`);
  lines.push("");
  if (reports.some(r => r.errors.length)) {
    lines.push(`## Errors`);
    for (const r of reports) {
      if (!r.errors.length) continue;
      lines.push(`### .${r.tld}`);
      for (const e of r.errors.slice(0, 10)) lines.push(`- ${e}`);
    }
  }
  const out = "ns-stress-report.md";
  writeFileSync(out, lines.join("\n"));
  console.log(`Report: ${out}`);

  exit(tot.failed === 0 ? 0 : 1);
}

main().catch((e) => { console.error("FATAL:", e); exit(1); });
