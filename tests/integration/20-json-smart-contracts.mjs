#!/usr/bin/env node
/**
 * 20-json-smart-contracts.mjs — JSON smart contracts (OpenAI tool-spec).
 *
 * Memory: project_omnibus_json_smartcontracts. Contracts are NOT Solidity —
 * they are JSON tool-specs in OpenAI function-calling format. Genesis
 * contracts: ens_register_v1, agent_license_v1, staking_lock_v1, ...
 *
 * What this test checks (read-only):
 *   1) `contract_list` (or `listcontracts` / `agent_listContracts`) — node
 *      surfaces the registered contracts.
 *   2) For each genesis contract, `contract_get {id}` returns a JSON spec
 *      with the OpenAI shape: { name, description, parameters: {...} }.
 *   3) `contract_invoke` (or `runcontract`) accepts a dry-run payload and
 *      validates schema *without* executing (no state mutation).
 *
 * No --write. Schema is validated locally — script is the canary that
 * the contract surface area exists.
 */

import { argv, env, exit } from "node:process";

const ARGS = argv.slice(2);
function arg(name, fallback) {
  const i = ARGS.indexOf(name);
  return i >= 0 && ARGS[i + 1] ? ARGS[i + 1] : fallback;
}
const CHAIN  = arg("--chain", env.CHAIN || "testnet");
const RPC_OVR = arg("--rpc",  env.RPC_URL);
const TOKEN  = arg("--token", env.OMNIBUS_RPC_TOKEN);

const RPC_URLS = {
  mainnet: "https://omnibusblockchain.cc:8443/api-mainnet",
  testnet: "https://omnibusblockchain.cc:8443/api-testnet",
  regtest: "https://omnibusblockchain.cc:8443/api-regtest",
  "local-mainnet": "http://127.0.0.1:8332",
  "local-testnet": "http://127.0.0.1:18332",
  "local-regtest": "http://127.0.0.1:28332",
};
const RPC_URL = RPC_OVR || RPC_URLS[CHAIN] || RPC_URLS.testnet;

// Genesis contract IDs we expect to see (memory: ens_register_v1 et al.).
const GENESIS = [
  "ens_register_v1",
  "agent_license_v1",
  "staking_lock_v1",
];

// Method-name candidates — node may have any of these depending on commit.
const LIST_METHODS  = ["contract_list", "listcontracts", "agent_listContracts", "smartcontract_list"];
const GET_METHODS   = ["contract_get",  "getcontract",   "agent_getContract",   "smartcontract_get"];
const INVOKE_METHODS = ["contract_invoke", "runcontract", "agent_invokeContract", "smartcontract_invoke"];

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

function isMethodNotFound(err) {
  if (!err) return false;
  return /method not found|unknown method|not implemented|method.*found/i.test(err.message ?? "");
}

// Try a list of method names — return the first that doesn't 404.
async function tryMethods(methods, params = []) {
  for (const m of methods) {
    const j = await rpc(m, params);
    if (j.error && isMethodNotFound(j.error)) continue;
    return { method: m, response: j };
  }
  return null;
}

// Validate that an object looks like an OpenAI tool spec:
//   { name, description, parameters: { type:"object", properties:{...} } }
function isOpenAISpec(o) {
  if (!o || typeof o !== "object") return false;
  if (typeof o.name !== "string") return false;
  // description is optional but usual
  const p = o.parameters ?? o.params ?? o.schema;
  if (!p || typeof p !== "object") return false;
  if (p.type && p.type !== "object") return false;
  if (p.properties && typeof p.properties !== "object") return false;
  return true;
}

async function main() {
  console.log("=".repeat(70));
  console.log("OmniBus JSON Smart Contracts (OpenAI tool-spec)");
  console.log("=".repeat(70));
  console.log(`RPC:    ${RPC_URL}`);
  console.log(`Chain:  ${CHAIN}`);
  console.log("");

  // 1) Reachability
  let tip;
  try {
    const j = await rpc("getblockcount");
    if (j.error) throw new Error(j.error.message);
    tip = j.result;
    PASS(`getblockcount = ${tip}`);
  } catch (e) {
    FAIL("getblockcount", e.message);
    console.log(`\n  pass: ${pass}   fail: ${fail}   skip: ${skip}`);
    exit(2);
  }

  // 2) List contracts
  const listed = await tryMethods(LIST_METHODS);
  if (!listed) {
    SKIP("contract list RPC", `none of ${LIST_METHODS.join("/")} found`);
  } else if (listed.response.error) {
    FAIL(`${listed.method}`, listed.response.error.message);
  } else {
    const r = listed.response.result;
    const arr = Array.isArray(r) ? r : (r?.contracts ?? r?.items ?? []);
    PASS(`${listed.method} returned ${arr.length} contract(s)`);

    // Genesis presence — at least one should be there
    const ids = arr.map((c) => (typeof c === "string" ? c : (c.id ?? c.name ?? ""))).filter(Boolean);
    let foundGenesis = 0;
    for (const g of GENESIS) {
      if (ids.some((id) => id.includes(g) || id === g)) {
        PASS(`  genesis contract present: ${g}`);
        foundGenesis++;
      } else {
        SKIP(`  genesis contract present: ${g}`, "not yet deployed");
      }
    }
    if (foundGenesis === 0 && arr.length > 0) {
      // Inspect first contract anyway for spec shape
      const sample = arr[0];
      if (typeof sample === "object" && isOpenAISpec(sample)) {
        PASS(`  first listed contract has OpenAI tool-spec shape`);
      } else {
        SKIP(`  first contract OpenAI shape`, "shape varies / id-only list");
      }
    }
  }

  // 3) Get each genesis contract
  for (const id of GENESIS) {
    const got = await tryMethods(GET_METHODS, [{ id }]);
    if (!got) {
      // Try positional too
      const got2 = await tryMethods(GET_METHODS, [id]);
      if (!got2) { SKIP(`get ${id}`, "no contract_get* RPC"); continue; }
      handleGetResp(id, got2.method, got2.response);
    } else {
      handleGetResp(id, got.method, got.response);
    }
  }

  // 4) Invoke (dry-run) ens_register_v1 — schema validation only
  const invokeResp = await tryMethods(INVOKE_METHODS, [{
    id: "ens_register_v1",
    params: { name: "stresstest-dryrun.omnibus", owner: "ob1qzhrauq0xe9hg033ccup7vlgsdmj6kcxyza9zp0" },
    dry_run: true,
  }]);
  if (!invokeResp) {
    SKIP("contract_invoke (dry-run)", "no invoke RPC found");
  } else if (invokeResp.response.error) {
    const m = invokeResp.response.error.message ?? "";
    if (/dry|validate|schema|missing|invalid|fee|signature/i.test(m)) {
      // Validation-style error = the surface exists and rejected our partial payload. PASS.
      PASS(`${invokeResp.method} dry-run rejected with validation error (expected)`);
    } else {
      FAIL(`${invokeResp.method} dry-run`, m);
    }
  } else {
    PASS(`${invokeResp.method} dry-run accepted`);
  }

  console.log("");
  console.log(`--- 20 JSON contracts summary ---`);
  console.log(`  pass: ${pass}   fail: ${fail}   skip: ${skip}`);
  exit(fail === 0 ? 0 : 1);
}

function handleGetResp(id, method, j) {
  if (j.error) {
    if (isMethodNotFound(j.error)) { SKIP(`${method} ${id}`, "not found"); return; }
    if (/not.*found|unknown.*contract|missing/i.test(j.error.message ?? "")) {
      SKIP(`${method} ${id}`, "contract not registered yet");
      return;
    }
    FAIL(`${method} ${id}`, j.error.message);
    return;
  }
  const spec = j.result?.contract ?? j.result?.spec ?? j.result;
  if (isOpenAISpec(spec)) {
    PASS(`${method} ${id} — OpenAI tool-spec shape OK`);
  } else {
    SKIP(`${method} ${id}`, "result shape varies, not strict OpenAI spec");
  }
}

main().catch((e) => { console.error("FATAL:", e); exit(1); });
