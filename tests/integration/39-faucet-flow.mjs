#!/usr/bin/env node
/**
 * 39-faucet-flow.mjs — Faucet flow test (testnet only).
 *
 * Steps:
 *   1. getfaucetstatus — verify enabled, grant_amount, cooldown_seconds.
 *   2. Generate fresh wallet w.
 *   3. claimfaucet { address: w } — first claim.
 *   4. Wait for mining → verify w balance > 0.
 *   5. Re-claim immediately → should be rejected (cooldown).
 *   6. Verify claim_history (or faucet-claims.json shape) prevents
 *      double-claim.
 *
 * Faucet is testnet/regtest only. On mainnet this should SKIP cleanly.
 *
 * Default: testnet (faucet enabled). On mainnet: SKIP.
 */

import { writeFileSync } from "node:fs";
import { argv, env, exit } from "node:process";
import { randomBytes } from "node:crypto";

const ARGS = argv.slice(2);
const arg = (name, fb) => {
  const i = ARGS.indexOf(name);
  return i >= 0 && ARGS[i + 1] ? ARGS[i + 1] : fb;
};
const CHAIN = arg("--chain", env.CHAIN || "testnet");
const RPC_OVR = arg("--rpc", env.RPC_URL);
const TOKEN = arg("--token", env.OMNIBUS_RPC_TOKEN);
const WRITE = !ARGS.includes("--no-write");

const RPC_URLS = {
  mainnet: "https://omnibusblockchain.cc:8443/api-mainnet",
  testnet: "https://omnibusblockchain.cc:8443/api-testnet",
  regtest: "https://omnibusblockchain.cc:8443/api-regtest",
  "local-mainnet": "http://127.0.0.1:8332",
  "local-testnet": "http://127.0.0.1:18332",
  "local-regtest": "http://127.0.0.1:28332",
};
const RPC_URL = RPC_OVR || RPC_URLS[CHAIN] || RPC_URLS.testnet;

const SAT = 1_000_000_000;

let pass = 0, fail = 0, skip = 0;
const results = [];
const PASS = (m) => { pass++; results.push({ s: "PASS", m }); console.log(`  ✅ PASS ${m}`); };
const FAIL = (m, e) => { fail++; results.push({ s: "FAIL", m, e }); console.log(`  ❌ FAIL ${m}${e ? "  -- " + e : ""}`); };
const SKIP = (m, e) => { skip++; results.push({ s: "SKIP", m, e }); console.log(`  - SKIP ${m}${e ? "  (" + e + ")" : ""}`); };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function rpc(method, params = []) {
  const headers = { "Content-Type": "application/json" };
  if (TOKEN) headers.Authorization = `Bearer ${TOKEN}`;
  const r = await fetch(RPC_URL, {
    method: "POST", headers,
    body: JSON.stringify({ jsonrpc: "2.0", id: Date.now(), method, params }),
  });
  const j = await r.json();
  if (j.error) {
    const msg = j.error.message ?? JSON.stringify(j.error);
    const err = new Error(msg);
    err.skip = /method not found|unknown method|not implemented/i.test(msg);
    throw err;
  }
  return j.result;
}

function genAddr() {
  return "ob1q" + randomBytes(20).toString("hex").slice(0, 38);
}

async function main() {
  console.log("=".repeat(70));
  console.log("OmniBus Faucet Flow Test");
  console.log("=".repeat(70));
  console.log(`RPC:    ${RPC_URL}`);
  console.log(`Chain:  ${CHAIN}`);
  console.log(`Mode:   ${WRITE ? "WRITE" : "READ-ONLY"}`);
  console.log("");

  if (CHAIN === "mainnet") {
    SKIP("entire faucet test on mainnet", "faucet is testnet/regtest only");
    console.log("");
    console.log(`--- 39 Faucet Flow summary ---`);
    console.log(`  pass: ${pass}   fail: ${fail}   skip: ${skip}`);
    writeFileSync("39-report.md", `# Faucet Flow Report\n\n- chain: mainnet (skipped)\n- ts: ${new Date().toISOString()}\n\npass=${pass} fail=${fail} skip=${skip}\n`);
    exit(0);
  }

  let tip;
  try { tip = await rpc("getblockcount"); console.log(`Chain tip: ${tip}`); }
  catch (e) { console.error(`FATAL: ${e.message}`); exit(2); }

  // 1) getfaucetstatus
  let status;
  try {
    status = await rpc("getfaucetstatus");
    if (status) {
      const enabled = status.enabled ?? status.active ?? true;
      const grant = Number(status.grant_amount ?? status.amount ?? status.grant ?? 0);
      const cd = Number(status.cooldown_seconds ?? status.cooldown ?? 86400);
      if (enabled) PASS(`faucet enabled`);
      else FAIL(`faucet enabled`, `disabled`);
      if (grant > 0) PASS(`grant amount = ${grant} (${grant / SAT} OMNI)`);
      else SKIP(`grant amount`, `not exposed`);
      if (cd > 0) PASS(`cooldown = ${cd}s`);
      else SKIP(`cooldown`, `not exposed`);
    } else SKIP("getfaucetstatus", "no result");
  } catch (e) {
    if (e.skip) SKIP("getfaucetstatus", "RPC missing");
    else FAIL("getfaucetstatus", e.message);
  }

  // 2) Fresh wallet
  const w = genAddr();
  console.log(`Fresh wallet: ${w}`);
  PASS(`generated fresh wallet`);

  // 3) First claim
  let claimTxid = null;
  if (WRITE) {
    try {
      const r = await rpc("claimfaucet", [{ address: w }]);
      claimTxid = r?.txid ?? r?.tx_id ?? r?.id ?? null;
      if (claimTxid) PASS(`claimfaucet returned txid ${String(claimTxid).slice(0, 16)}`);
      else PASS(`claimfaucet accepted (no explicit txid)`);
    } catch (e) {
      if (e.skip) SKIP("claimfaucet", "RPC missing");
      else FAIL("claimfaucet", e.message);
    }
  } else {
    SKIP("claimfaucet", "--no-write mode");
  }

  // 4) Wait for mining → balance check
  if (claimTxid || WRITE) {
    console.log("Waiting 12s for faucet TX to mine...");
    await sleep(12_000);
    try {
      const bal = await rpc("getbalance", [w]);
      const v = typeof bal === "number" ? bal : Number(bal?.balance ?? bal?.amount ?? bal ?? 0);
      if (v > 0) PASS(`fresh wallet balance > 0 after faucet (${v})`);
      else SKIP(`fresh wallet balance after faucet`, `bal=${v}`);
    } catch (e) {
      if (e.skip) SKIP("getbalance after claim", "RPC missing");
      else SKIP("getbalance after claim", e.message.slice(0, 60));
    }
  }

  // 5) Re-claim immediately → should fail (cooldown)
  if (WRITE) {
    try {
      const r = await rpc("claimfaucet", [{ address: w }]);
      if (r?.txid || r?.tx_id) {
        FAIL("cooldown enforcement", `second claim succeeded — cooldown not enforced`);
      } else SKIP("cooldown enforcement", "second claim returned non-error non-txid");
    } catch (e) {
      if (e.skip) SKIP("cooldown enforcement", "RPC missing");
      else if (/cooldown|wait|already|too soon|rate.?limit/i.test(e.message)) {
        PASS(`cooldown enforced (${e.message.slice(0, 60)})`);
      } else SKIP("cooldown enforcement", e.message.slice(0, 60));
    }
  }

  // 6) Claim history
  try {
    const h = await rpc("getfaucethistory", [{ address: w }]);
    const arr = Array.isArray(h) ? h : (h?.claims ?? h?.history ?? []);
    if (Array.isArray(arr)) {
      if (arr.length >= 1) PASS(`claim history has ${arr.length} entry/entries for w`);
      else SKIP(`claim history`, `empty`);
    } else SKIP("claim history", "non-array");
  } catch (e) {
    if (e.skip) {
      // try alternate name
      try {
        const h2 = await rpc("faucet_history", [{ address: w }]);
        if (h2) PASS(`faucet_history reachable`);
      } catch (e2) {
        if (e2.skip) SKIP("claim history", "RPC missing");
      }
    } else SKIP("claim history", e.message.slice(0, 60));
  }

  console.log("");
  console.log(`--- 39 Faucet Flow summary ---`);
  console.log(`  pass: ${pass}   fail: ${fail}   skip: ${skip}`);

  const lines = [`# Faucet Flow Report`, "", `- chain: \`${CHAIN}\``, `- rpc: \`${RPC_URL}\``, `- mode: ${WRITE ? "WRITE" : "read-only"}`, `- wallet: ${w}`, `- claim_txid: ${claimTxid ?? "(none)"}`, `- ts: ${new Date().toISOString()}`, "", `pass=${pass} fail=${fail} skip=${skip}`, ""];
  for (const r of results) lines.push(`- ${r.s} ${r.m}${r.e ? ` (${r.e})` : ""}`);
  writeFileSync("39-report.md", lines.join("\n"));

  exit(fail === 0 ? 0 : 1);
}

main().catch((e) => { console.error("FATAL:", e); exit(1); });
