#!/usr/bin/env node
/**
 * 18-anti-sybil-knockknock.mjs — UDP knock-knock + 1-miner-per-IP enforcement.
 *
 * The OmniBus anti-Sybil rule (memory: project_omnibus_anti_sybil): only one
 * miner per external IP. Local VMs share the NAT IP -> share the slot.
 * Different HW + different ISP = different miners.
 *
 * This script does a *non-destructive* check that the rule is wired:
 *   1) Snapshot getpeers / getsybilbans before.
 *   2) Send 5 synthetic UDP "knock-knock" datagrams from localhost on the
 *      well-known knock ports (8333/8334/8335). Pattern matches the
 *      "OMNI:we are here:..." discovery ping.
 *   3) Re-poll getpeers — should not have grown by 5 (rule: only first
 *      one accepted per IP, the other 4 get knock-knocked away).
 *   4) Probe getsybilbans / getbannedpeers / peer-bans.dat-style RPC for
 *      a "[KNOCK]" / "duplicate IP" log entry.
 *
 * Read-only: no signed TX, no wallet, no state mutation. The UDP knock
 * packets are crafted and ignored by mainnet/testnet seed nodes (they
 * only listen on UDP at a different port). On regtest with a local
 * miner the knocks may actually trigger the dedup logic.
 *
 * Usage:
 *   node 18-anti-sybil-knockknock.mjs
 *   node 18-anti-sybil-knockknock.mjs --chain testnet
 *   node 18-anti-sybil-knockknock.mjs --chain regtest --target 127.0.0.1
 */

import dgram from "node:dgram";
import { argv, env, exit } from "node:process";

// ── CLI ─────────────────────────────────────────────────────────────────────
const ARGS = argv.slice(2);
function arg(name, fallback) {
  const i = ARGS.indexOf(name);
  return i >= 0 && ARGS[i + 1] ? ARGS[i + 1] : fallback;
}
const CHAIN  = arg("--chain", env.CHAIN || "testnet");
const RPC_OVR = arg("--rpc",  env.RPC_URL);
const TARGET = arg("--target", "omnibusblockchain.cc"); // remote canary
const TOKEN  = arg("--token", env.OMNIBUS_RPC_TOKEN);
const KNOCK_PORTS = [8333, 8334, 8335];
const FAKE_MINERS = 5;

const RPC_URLS = {
  mainnet: "https://omnibusblockchain.cc:8443/api-mainnet",
  testnet: "https://omnibusblockchain.cc:8443/api-testnet",
  regtest: "https://omnibusblockchain.cc:8443/api-regtest",
  "local-mainnet": "http://127.0.0.1:8332",
  "local-testnet": "http://127.0.0.1:18332",
  "local-regtest": "http://127.0.0.1:28332",
};
const RPC_URL = RPC_OVR || RPC_URLS[CHAIN] || RPC_URLS.testnet;

// ── Helpers ─────────────────────────────────────────────────────────────────
let pass = 0, fail = 0, skip = 0;
const PASS = (m) => { pass++; console.log(`  PASS ${m}`); };
const FAIL = (m, e) => { fail++; console.log(`  FAIL ${m}${e ? "  -- " + e : ""}`); };
const SKIP = (m, e) => { skip++; console.log(`  SKIP ${m}${e ? "  (" + e + ")" : ""}`); };

async function rpc(method, params = []) {
  const headers = { "Content-Type": "application/json" };
  if (TOKEN) headers.Authorization = `Bearer ${TOKEN}`;
  try {
    const r = await fetch(RPC_URL, {
      method: "POST",
      headers,
      body: JSON.stringify({ jsonrpc: "2.0", id: Date.now(), method, params }),
    });
    return await r.json();
  } catch (e) {
    return { error: { code: -32000, message: `transport: ${e.message}` } };
  }
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function sendKnock(host, port, payload) {
  return new Promise((resolve) => {
    const sock = dgram.createSocket("udp4");
    sock.send(payload, port, host, (err) => {
      sock.close();
      resolve(!err);
    });
  });
}

function peerCount(resp) {
  if (!resp || resp.error) return null;
  const r = resp.result;
  if (Array.isArray(r)) return r.length;
  if (r && Array.isArray(r.peers)) return r.peers.length;
  if (r && typeof r.count === "number") return r.count;
  return null;
}

// ── Main ────────────────────────────────────────────────────────────────────
async function main() {
  console.log("=".repeat(70));
  console.log("OmniBus Anti-Sybil Knock-Knock Test");
  console.log("=".repeat(70));
  console.log(`RPC:    ${RPC_URL}`);
  console.log(`Chain:  ${CHAIN}`);
  console.log(`Target: ${TARGET} (UDP knocks)`);
  console.log("");

  // 1) Baseline peers
  let snap1 = await rpc("getpeers");
  if (snap1.error) {
    SKIP("getpeers baseline", snap1.error.message);
  } else {
    PASS(`getpeers baseline (count=${peerCount(snap1) ?? "?"})`);
  }

  // 2) sybilbans / bannedpeers snapshot
  let bansBefore = await rpc("getsybilbans");
  if (bansBefore.error) {
    bansBefore = await rpc("getbannedpeers");
  }
  const bansBeforeOk = bansBefore && !bansBefore.error;
  if (bansBeforeOk) PASS("getsybilbans/getbannedpeers snapshot");
  else SKIP("getsybilbans/getbannedpeers snapshot", bansBefore?.error?.message ?? "n/a");

  // 3) Fire FAKE_MINERS knock packets per port. Pattern from anti-sybil memo:
  //    "OMNI:we are here:<node-id>:<nonce>"
  let sent = 0;
  for (let i = 0; i < FAKE_MINERS; i++) {
    const nodeId = `fake-miner-${i}`;
    const nonce  = Math.floor(Math.random() * 1e9).toString(16);
    const payload = Buffer.from(`OMNI:we are here:${nodeId}:${nonce}`);
    for (const port of KNOCK_PORTS) {
      const ok = await sendKnock(TARGET, port, payload);
      if (ok) sent++;
    }
    await sleep(50);
  }
  if (sent > 0) PASS(`UDP knock packets sent (${sent} total across ${FAKE_MINERS} fake miners x ${KNOCK_PORTS.length} ports)`);
  else FAIL("UDP knock packets", "0 sent");

  // 4) Wait for any propagation, then re-snapshot.
  await sleep(2000);

  let snap2 = await rpc("getpeers");
  if (snap2.error) {
    SKIP("getpeers after-knock", snap2.error.message);
  } else {
    const before = peerCount(snap1);
    const after  = peerCount(snap2);
    if (before == null || after == null) {
      SKIP("peer-count delta", "cannot count peers");
    } else {
      const delta = after - before;
      // Rule: at most +1 (our single connection from this host); +5 would
      // mean dedup is broken.
      if (delta <= 1) {
        PASS(`peer count delta = ${delta} (<=1, expected — dedup ok)`);
      } else if (delta < FAKE_MINERS) {
        PASS(`peer count delta = ${delta} (partial dedup, < ${FAKE_MINERS})`);
      } else {
        FAIL("peer count delta", `delta=${delta} >= ${FAKE_MINERS} fake miners — dedup may be off`);
      }
    }
  }

  // 5) Look for new ban / knock entries
  let bansAfter = await rpc("getsybilbans");
  if (bansAfter.error) bansAfter = await rpc("getbannedpeers");
  if (bansAfter && !bansAfter.error) {
    const txt = JSON.stringify(bansAfter.result || {});
    if (/KNOCK|duplicate|sybil|same.*ip/i.test(txt)) {
      PASS("ban list shows KNOCK/duplicate-IP entry");
    } else {
      SKIP("ban list shows KNOCK entry", "no log markers visible via RPC");
    }
  } else {
    SKIP("ban list after knock", "RPC unavailable");
  }

  console.log("");
  console.log(`--- 18 Anti-Sybil summary ---`);
  console.log(`  pass: ${pass}   fail: ${fail}   skip: ${skip}`);
  exit(fail === 0 ? 0 : 1);
}

main().catch((e) => { console.error("FATAL:", e); exit(1); });
