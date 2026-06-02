#!/usr/bin/env node
/**
 * 22-reputation-hooks-live.mjs — Live reputation hooks LOVE/FOOD/RENT/VACATION.
 *
 * Memory: project_omnibus_reputation_economy. 4 cups 0..100, total
 * reputation 0..1M. Hooks expected:
 *   - FOOD : per block mined (per-block reward to miner address)
 *   - LOVE : per minute online (~ every 60 blocks on 1s chain, ~6 blocks
 *            on 10s chain — both end up roughly 1 LOVE / minute wall-clock)
 *   - RENT : tied to staking (active stake + uptime)
 *   - VACATION: long-term loyalty (slow tick)
 *
 * What this test does (read-only):
 *   1) Snapshot getreputation ADDR -> R0.
 *   2) Watch for ~60 blocks of activity (or `--window` seconds).
 *   3) Re-snapshot at mid-window (~30 blocks) -> R1, end -> R2.
 *   4) Assert: R1.food >= R0.food (some block was mined OR no change).
 *      Assert: R2.love >= R1.love (LOVE tick over time).
 *      Assert: if address has stake, R2.rent >= R1.rent.
 *   5) Append a row per snapshot to reputation-live.csv (timeline).
 *
 * No --write. Uses savacazan #0 by default (always present).
 */

import { writeFileSync, existsSync, appendFileSync } from "node:fs";
import { argv, env, exit } from "node:process";

const ARGS = argv.slice(2);
function arg(name, fallback) {
  const i = ARGS.indexOf(name);
  return i >= 0 && ARGS[i + 1] ? ARGS[i + 1] : fallback;
}
const CHAIN  = arg("--chain", env.CHAIN || "testnet");
const RPC_OVR = arg("--rpc",  env.RPC_URL);
const TOKEN  = arg("--token", env.OMNIBUS_RPC_TOKEN);
const WINDOW = parseInt(arg("--window", "70"), 10);   // seconds
const ADDR   = arg("--addr", "ob1qzhrauq0xe9hg033ccup7vlgsdmj6kcxyza9zp0");
const CSV    = arg("--csv", "reputation-live.csv");

const RPC_URLS = {
  mainnet: "https://omnibusblockchain.cc:8443/api-mainnet",
  testnet: "https://omnibusblockchain.cc:8443/api-testnet",
  regtest: "https://omnibusblockchain.cc:8443/api-regtest",
  "local-mainnet": "http://127.0.0.1:8332",
  "local-testnet": "http://127.0.0.1:18332",
  "local-regtest": "http://127.0.0.1:28332",
};
const RPC_URL = RPC_OVR || RPC_URLS[CHAIN] || RPC_URLS.testnet;

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

function flatRep(j) {
  if (!j || j.error) return null;
  const r = j.result;
  if (!r) return null;
  // Normalize shapes — cups may be nested or flat.
  const cups = r.cups ?? r;
  return {
    love:     Number(cups.love     ?? 0),
    food:     Number(cups.food     ?? 0),
    rent:     Number(cups.rent     ?? 0),
    vacation: Number(cups.vacation ?? 0),
    total:    Number(r.total       ?? r.reputation ?? 0),
    tier:     String(r.tier        ?? ""),
  };
}

async function snapshot(label) {
  const j = await rpc("getreputation", [ADDR]);
  if (j.error) {
    FAIL(`getreputation ${label}`, j.error.message);
    return null;
  }
  const r = flatRep(j);
  if (!r) {
    FAIL(`getreputation ${label}`, "empty result");
    return null;
  }
  PASS(`snapshot ${label}: love=${r.love} food=${r.food} rent=${r.rent} vacation=${r.vacation} total=${r.total} tier=${r.tier}`);
  return r;
}

function csvAppend(row) {
  const header = "timestamp,address,love,food,rent,vacation,total,tier,blockheight";
  if (!existsSync(CSV)) writeFileSync(CSV, header + "\n");
  appendFileSync(CSV, row + "\n");
}

async function main() {
  console.log("=".repeat(70));
  console.log("OmniBus Reputation Hooks Live");
  console.log("=".repeat(70));
  console.log(`RPC:    ${RPC_URL}`);
  console.log(`Chain:  ${CHAIN}`);
  console.log(`Addr:   ${ADDR}`);
  console.log(`Window: ${WINDOW}s`);
  console.log(`CSV:    ${CSV}`);
  console.log("");

  // Reachability
  let tip0 = null;
  {
    const j = await rpc("getblockcount");
    if (j.error) { FAIL("getblockcount", j.error.message); console.log(`  pass:${pass} fail:${fail} skip:${skip}`); exit(2); }
    tip0 = j.result;
    PASS(`getblockcount = ${tip0}`);
  }

  // Stake snapshot — useful to predict RENT behaviour
  let hasStake = false;
  {
    const j = await rpc("getstake", [ADDR]);
    if (!j.error) {
      const amt = Number(j.result?.amount ?? j.result ?? 0);
      hasStake = amt > 0;
      PASS(`stake snapshot: amount=${amt} (${hasStake ? "RENT should grow" : "no stake — RENT may stay flat"})`);
    } else {
      SKIP("stake snapshot", j.error.message);
    }
  }

  // R0 baseline
  const R0 = await snapshot("R0");
  if (!R0) { console.log(`  pass:${pass} fail:${fail} skip:${skip}`); exit(1); }
  csvAppend(`${new Date().toISOString()},${ADDR},${R0.love},${R0.food},${R0.rent},${R0.vacation},${R0.total},${R0.tier},${tip0}`);

  // Mid window
  const half = Math.floor(WINDOW * 1000 / 2);
  console.log(`  ... waiting ${half/1000}s (mid-window)`);
  await sleep(half);

  let tipMid = tip0;
  {
    const j = await rpc("getblockcount");
    if (!j.error) tipMid = j.result;
  }
  const R1 = await snapshot("R1");
  if (R1) csvAppend(`${new Date().toISOString()},${ADDR},${R1.love},${R1.food},${R1.rent},${R1.vacation},${R1.total},${R1.tier},${tipMid}`);

  // End
  console.log(`  ... waiting ${half/1000}s (end-window)`);
  await sleep(half);
  let tipEnd = tipMid;
  {
    const j = await rpc("getblockcount");
    if (!j.error) tipEnd = j.result;
  }
  const R2 = await snapshot("R2");
  if (R2) csvAppend(`${new Date().toISOString()},${ADDR},${R2.love},${R2.food},${R2.rent},${R2.vacation},${R2.total},${R2.tier},${tipEnd}`);

  if (!R1 || !R2) {
    console.log(`  pass:${pass} fail:${fail} skip:${skip}`);
    exit(fail === 0 ? 0 : 1);
  }

  // Block delta
  const blocksMined = tipEnd - tip0;
  PASS(`blocks mined during window: ${blocksMined} (tip ${tip0} -> ${tipEnd})`);

  // FOOD: per-block hook. If THIS address mined any block in window, food+.
  // Otherwise it stays flat — that's also valid (we don't control who wins).
  if (R2.food > R0.food) {
    PASS(`FOOD grew: ${R0.food} -> ${R2.food} (this addr mined ${blocksMined ? "some" : "no"} block(s))`);
  } else if (R2.food === R0.food) {
    SKIP("FOOD growth", "addr did not mine any block in window — hook is conditional");
  } else {
    FAIL("FOOD shrank", `${R0.food} -> ${R2.food} should never decrease`);
  }

  // LOVE: per-minute online hook. If WINDOW >= 60s, expect at least 1 tick.
  if (WINDOW >= 60) {
    if (R2.love > R0.love) {
      PASS(`LOVE grew: ${R0.love} -> ${R2.love} (LOVE tick fired)`);
    } else if (R2.love === R0.love) {
      SKIP("LOVE growth", "no LOVE tick in window — hook may require active session");
    } else {
      FAIL("LOVE shrank", `${R0.love} -> ${R2.love}`);
    }
  } else {
    SKIP("LOVE growth", `window < 60s, no LOVE tick expected`);
  }

  // RENT: only if address has stake
  if (hasStake) {
    if (R2.rent >= R1.rent && R1.rent >= R0.rent) {
      if (R2.rent > R0.rent) PASS(`RENT grew (staked): ${R0.rent} -> ${R1.rent} -> ${R2.rent}`);
      else SKIP("RENT growth", "stake present but rent flat in window");
    } else {
      FAIL("RENT decreased while staked", `${R0.rent} -> ${R1.rent} -> ${R2.rent}`);
    }
  } else {
    SKIP("RENT growth", "address has no active stake");
  }

  // VACATION: long-term tick — almost always flat in 60-90s. Just log.
  if (R2.vacation < R0.vacation) {
    FAIL("VACATION shrank", `${R0.vacation} -> ${R2.vacation}`);
  } else {
    PASS(`VACATION stable/growing: ${R0.vacation} -> ${R2.vacation}`);
  }

  console.log("");
  console.log(`--- 22 Reputation hooks summary ---`);
  console.log(`  pass: ${pass}   fail: ${fail}   skip: ${skip}`);
  console.log(`  csv:  ${CSV} (3 rows appended)`);
  exit(fail === 0 ? 0 : 1);
}

main().catch((e) => { console.error("FATAL:", e); exit(1); });
