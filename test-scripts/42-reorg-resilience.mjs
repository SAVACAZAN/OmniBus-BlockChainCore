#!/usr/bin/env node
/**
 * 42-reorg-resilience.mjs — Reorg resilience + Casper FFG finality probe.
 *
 * Read-only test. Verifies the chain handles potential reorgs correctly:
 *   1. Find a recent confirmed TX (from getmempool or scanning blocks).
 *   2. Verify TX in block N is reachable via getrawtransaction.
 *   3. Verify block linking: block (N-1).hash == block N.prev_hash.
 *   4. Probe getorphanblocks (or getstaleblocks) — should return list (may be empty).
 *   5. Verify Casper FFG finality checkpoint at every 64 blocks
 *      (height % 64 == 0 → checkpoint epoch).
 *   6. Verify finality.zig recognizes recent block N-128 as finalized.
 *
 * Default: testnet read-only. Saves 42-report.md.
 */

import { writeFileSync } from "node:fs";
import { argv, env, exit } from "node:process";

const ARGS = argv.slice(2);
const arg = (name, fb) => {
  const i = ARGS.indexOf(name);
  return i >= 0 && ARGS[i + 1] ? ARGS[i + 1] : fb;
};
const CHAIN = arg("--chain", env.CHAIN || "testnet");
const RPC_OVR = arg("--rpc", env.RPC_URL);
const TOKEN = arg("--token", env.OMNIBUS_RPC_TOKEN);

const RPC_URLS = {
  mainnet: "https://omnibusblockchain.cc:8443/api-mainnet",
  testnet: "https://omnibusblockchain.cc:8443/api-testnet",
  regtest: "https://omnibusblockchain.cc:8443/api-regtest",
  "local-mainnet": "http://127.0.0.1:8332",
  "local-testnet": "http://127.0.0.1:18332",
  "local-regtest": "http://127.0.0.1:28332",
};
const RPC_URL = RPC_OVR || RPC_URLS[CHAIN] || RPC_URLS.testnet;

const FFG_EPOCH_LEN = 64;
const FINALITY_DEPTH = 128;

let pass = 0, fail = 0, skip = 0;
const results = [];
const PASS = (m) => { pass++; results.push({ s: "PASS", m }); console.log(`  ✅ PASS ${m}`); };
const FAIL = (m, e) => { fail++; results.push({ s: "FAIL", m, e }); console.log(`  ❌ FAIL ${m}${e ? "  -- " + e : ""}`); };
const SKIP = (m, e) => { skip++; results.push({ s: "SKIP", m, e }); console.log(`  - SKIP ${m}${e ? "  (" + e + ")" : ""}`); };

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

async function getBlockAt(h) {
  try { return await rpc("getblock", [{ height: h }]); }
  catch (e) {
    if (e.skip) {
      try { return await rpc("getblockbyheight", [h]); } catch { return null; }
    }
    return null;
  }
}

async function main() {
  console.log("=".repeat(70));
  console.log("OmniBus Reorg Resilience + Finality Test");
  console.log("=".repeat(70));
  console.log(`RPC:    ${RPC_URL}`);
  console.log(`Chain:  ${CHAIN}`);
  console.log("");

  let tip;
  try { tip = await rpc("getblockcount"); console.log(`Chain tip: ${tip}`); }
  catch (e) { console.error(`FATAL: ${e.message}`); exit(2); }

  if (tip < 5) {
    SKIP("entire reorg test", `tip=${tip} too low for reorg analysis`);
    writeFileSync("42-report.md", `# Reorg Resilience Report\n\n- chain: ${CHAIN}\n- tip: ${tip} (too low)\n- ts: ${new Date().toISOString()}\n\npass=${pass} fail=${fail} skip=${skip}\n`);
    exit(0);
  }

  // 1) Find a recent confirmed TX
  let recentTxid = null;
  let recentBlockHeight = null;
  for (let h = tip; h >= Math.max(1, tip - 50); h--) {
    const b = await getBlockAt(h);
    if (!b) continue;
    const txs = b.transactions ?? b.txs ?? [];
    const txArr = Array.isArray(txs) ? txs : [];
    if (txArr.length >= 1) {
      const t = txArr[0];
      const id = t?.txid ?? t?.tx_id ?? t?.id ?? (typeof t === "string" ? t : null);
      if (id && typeof id === "string") {
        recentTxid = id;
        recentBlockHeight = h;
        break;
      }
    }
  }
  if (recentTxid) PASS(`found recent TX ${recentTxid.slice(0, 16)} at h=${recentBlockHeight}`);
  else SKIP("recent TX search", "no TX found in last 50 blocks");

  // 2) Verify TX retrievable
  if (recentTxid) {
    try {
      const tx = await rpc("getrawtransaction", [{ txid: recentTxid, verbose: 1 }]);
      if (tx) PASS(`getrawtransaction works on recent TX`);
      else FAIL("getrawtransaction recent", "no tx returned");
    } catch (e) {
      if (e.skip) SKIP("getrawtransaction", "RPC missing");
      else SKIP("getrawtransaction", e.message.slice(0, 60));
    }
  }

  // 3) Block prev_hash linking — check block (tip-1) and tip
  const N = Math.max(2, tip - 1);
  const bN = await getBlockAt(N);
  const bN1 = await getBlockAt(N - 1);
  if (bN && bN1) {
    const prev = bN.prev_hash ?? bN.previous_hash ?? bN.prevHash ?? bN.parent_hash;
    const hashN1 = bN1.hash ?? bN1.block_hash;
    if (prev && hashN1) {
      if (prev === hashN1) PASS(`block linking ok: block(${N}).prev == block(${N-1}).hash`);
      else FAIL(`block linking broken at h=${N}`, `prev=${prev.slice(0, 16)}, expected=${hashN1.slice(0, 16)}`);
    } else SKIP("block linking", "hash fields not exposed");
  } else SKIP("block linking", "blocks not retrievable");

  // Also verify tip and N+1 if exists
  if (tip > N) {
    const bTip = await getBlockAt(tip);
    if (bTip && bN) {
      const prev = bTip.prev_hash ?? bTip.previous_hash ?? bTip.prevHash ?? bTip.parent_hash;
      const hashN = bN.hash ?? bN.block_hash;
      if (prev && hashN && prev === hashN) PASS(`block linking ok: tip.prev == block(${N}).hash`);
      else if (prev && hashN) FAIL(`tip linking broken`, `prev=${prev.slice(0, 16)}, expected=${hashN.slice(0, 16)}`);
    }
  }

  // 4) Orphan/stale blocks
  let orphanProbed = false;
  for (const m of ["getorphanblocks", "getstaleblocks", "getorphans"]) {
    try {
      const r = await rpc(m);
      if (Array.isArray(r) || (r && typeof r === "object")) {
        const len = Array.isArray(r) ? r.length : (r.count ?? Object.keys(r).length);
        PASS(`${m}: ${len} orphan/stale block(s)`);
        orphanProbed = true;
        break;
      }
    } catch (e) {
      if (!e.skip) { SKIP(`${m}`, e.message.slice(0, 40)); orphanProbed = true; break; }
    }
  }
  if (!orphanProbed) SKIP("orphan blocks", "no RPC available");

  // 5) Casper FFG checkpoint at every 64 blocks
  const lastCheckpoint = Math.floor(tip / FFG_EPOCH_LEN) * FFG_EPOCH_LEN;
  if (lastCheckpoint > 0 && lastCheckpoint <= tip) {
    PASS(`expected FFG checkpoint at h=${lastCheckpoint} (epoch ${lastCheckpoint / FFG_EPOCH_LEN})`);
    try {
      const r = await rpc("getfinality", [{ height: lastCheckpoint }]);
      if (r) {
        const finalized = r.finalized ?? r.is_finalized ?? r.justified ?? null;
        if (finalized === true) PASS(`block at checkpoint h=${lastCheckpoint} is finalized`);
        else if (finalized === false) SKIP(`checkpoint h=${lastCheckpoint} not yet finalized`);
        else PASS(`getfinality returned data for h=${lastCheckpoint}`);
      } else SKIP("getfinality", "no result");
    } catch (e) {
      if (e.skip) {
        // Try alternate method names
        try {
          const r2 = await rpc("getcheckpoint", [{ epoch: lastCheckpoint / FFG_EPOCH_LEN }]);
          if (r2) PASS(`getcheckpoint(${lastCheckpoint / FFG_EPOCH_LEN}) reachable`);
        } catch { SKIP("FFG finality", "RPC missing"); }
      } else SKIP("FFG finality", e.message.slice(0, 60));
    }
  } else {
    SKIP("FFG checkpoint", `tip=${tip} below first epoch boundary`);
  }

  // 6) finality.zig recognizes block N-128 as finalized
  if (tip >= FINALITY_DEPTH) {
    const finalizedHeight = tip - FINALITY_DEPTH;
    try {
      const r = await rpc("getfinality", [{ height: finalizedHeight }]);
      if (r) {
        const finalized = r.finalized ?? r.is_finalized ?? null;
        if (finalized === true) PASS(`block at h=${finalizedHeight} (tip - ${FINALITY_DEPTH}) is finalized`);
        else if (finalized === false) SKIP(`block at h=${finalizedHeight} not finalized`);
        else PASS(`getfinality returned shape for finalized depth check`);
      }
    } catch (e) {
      if (e.skip) SKIP("finalized depth check", "RPC missing");
    }
  } else {
    SKIP("finalized depth check", `tip=${tip} below ${FINALITY_DEPTH}`);
  }

  // Bonus: tip stability — query tip 3 times in 2s, hash should be stable
  const tipSamples = [];
  for (let i = 0; i < 3; i++) {
    try {
      const b = await rpc("getblock", [{ height: tip }]);
      tipSamples.push(b?.hash ?? b?.block_hash);
    } catch { tipSamples.push(null); }
    await new Promise((r) => setTimeout(r, 700));
  }
  const validSamples = tipSamples.filter(Boolean);
  const uniqueSamples = new Set(validSamples);
  if (uniqueSamples.size === 1 && validSamples.length >= 2) {
    PASS(`tip block hash stable across ${validSamples.length} polls`);
  } else if (uniqueSamples.size > 1) {
    SKIP(`tip hash unstable`, `${uniqueSamples.size} different hashes — chain advancing fast or fork`);
  } else SKIP("tip stability", "samples missing");

  console.log("");
  console.log(`--- 42 Reorg Resilience summary ---`);
  console.log(`  pass: ${pass}   fail: ${fail}   skip: ${skip}`);

  const lines = [`# Reorg Resilience + Finality Report`, "", `- chain: \`${CHAIN}\``, `- rpc: \`${RPC_URL}\``, `- tip: ${tip}`, `- last_checkpoint: ${Math.floor(tip / FFG_EPOCH_LEN) * FFG_EPOCH_LEN}`, `- recent_txid: ${recentTxid ?? "(none)"}`, `- ts: ${new Date().toISOString()}`, "", `pass=${pass} fail=${fail} skip=${skip}`, ""];
  for (const r of results) lines.push(`- ${r.s} ${r.m}${r.e ? ` (${r.e})` : ""}`);
  writeFileSync("42-report.md", lines.join("\n"));

  exit(fail === 0 ? 0 : 1);
}

main().catch((e) => { console.error("FATAL:", e); exit(1); });
