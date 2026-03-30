#!/usr/bin/env node
/**
 * start-network.js — Start OmniBus seed node + 10 miners
 * Each miner gets a unique mnemonic, saved to wallets/network_miners.json
 * Miners connect one by one, 60 seconds apart
 * Mining starts when 10 miners are connected
 */

const { execSync, spawn } = require("child_process");
const crypto = require("crypto");
const fs = require("fs");
const path = require("path");

const ROOT = path.resolve(__dirname, "..");
const NODE_EXE = path.join(ROOT, "zig-out", "bin", "omnibus-node.exe");
const WALLETS_DIR = path.join(ROOT, "wallets");
const LOGS_DIR = path.join(ROOT, "data", "logs");

const MINER_COUNT = parseInt(process.argv[2]) || 10; // Usage: node start-network.js [count]
const SEED_PORT = 9000; // P2P port for seed (each miner gets SEED_PORT+100+i)
const RPC_PORT = 8332;
const STAGGER_MS = 5_000; // 5 seconds between each miner

// BIP-39 first 256 words (English)
const BIP39 = [
  "abandon","ability","able","about","above","absent","absorb","abstract",
  "absurd","abuse","access","accident","account","accuse","achieve","acid",
  "acoustic","acquire","across","act","action","actor","actress","actual",
  "adapt","add","addict","address","adjust","admit","adult","advance",
  "advice","aerobic","affair","afford","afraid","again","age","agent",
  "agree","ahead","aim","air","airport","aisle","alarm","album",
  "alcohol","alert","alien","all","alley","allow","almost","alone",
  "alpha","already","also","alter","always","amateur","amazing","among",
  "amount","amused","analyst","anchor","ancient","anger","angle","angry",
  "animal","ankle","announce","annual","another","answer","antenna","antique",
  "anxiety","any","apart","apology","appear","apple","approve","april",
  "arch","arctic","area","arena","argue","arm","armed","armor",
  "army","around","arrange","arrest","arrive","arrow","art","artefact",
  "artist","artwork","ask","aspect","assault","asset","assist","assume",
  "asthma","athlete","atom","attack","attend","attitude","attract","auction",
  "audit","august","aunt","author","auto","autumn","average","avocado",
  "avoid","awake","aware","awesome","awful","awkward","axis","baby",
  "bachelor","bacon","badge","bag","balance","balcony","ball","bamboo",
  "banana","banner","bar","barely","bargain","barrel","base","basic",
  "basket","battle","beach","bean","beauty","because","become","beef",
  "before","begin","behave","behind","believe","below","belt","bench",
  "benefit","best","betray","better","between","beyond","bicycle","bid",
  "bike","bind","biology","bird","birth","bitter","black","blade",
  "blame","blanket","blast","bleak","bless","blind","blood","blossom",
  "blow","blue","blur","blush","board","boat","body","boil",
  "bomb","bone","bonus","book","boost","border","boring","borrow",
  "boss","bottom","bounce","box","boy","bracket","brain","brand",
  "brass","brave","bread","breeze","brick","bridge","brief","bright",
  "bring","brisk","broccoli","broken","bronze","broom","brother","brown",
  "brush","bubble","buddy","budget","buffalo","build","bulb","bulk",
  "bullet","bundle","bunny","burden","burger","burst","bus","business",
  "busy","butter","buyer","buzz","cabbage","cabin","cable","cactus",
];

function generateMnemonic() {
  const entropy = crypto.randomBytes(16);
  const words = [];
  for (let j = 0; j < 12; j++) {
    const idx = ((entropy[j % 16] * 256 + entropy[(j + 1) % 16]) + j * 31) % BIP39.length;
    words.push(BIP39[idx]);
  }
  return words.join(" ");
}

function deriveAddress(mnemonic) {
  const seed = crypto.pbkdf2Sync(mnemonic, "TREZOR", 2048, 64, "sha512");
  const key = crypto.createHmac("sha256", seed).update("0").digest();
  const hash = crypto.createHash("sha256").update(key).digest("hex");
  return "ob_omni_" + hash.substring(0, 32);
}

async function rpcCall(method, params = []) {
  try {
    const res = await fetch(`http://localhost:${RPC_PORT}`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ jsonrpc: "2.0", method, params, id: Date.now() }),
    });
    const data = await res.json();
    return data.result;
  } catch { return null; }
}

function sleep(ms) {
  return new Promise((r) => setTimeout(r, ms));
}

const processes = [];

function cleanup() {
  console.log("\n[SHUTDOWN] Stopping all nodes...");
  processes.forEach((p) => { try { p.kill(); } catch {} });
  try { execSync("taskkill /F /IM omnibus-node.exe", { stdio: "ignore" }); } catch {}
  process.exit(0);
}
process.on("SIGINT", cleanup);
process.on("SIGTERM", cleanup);

async function main() {
  console.log("╔══════════════════════════════════════════════════════════════╗");
  console.log("║           OmniBus Network — 10 Miner Startup                ║");
  console.log("╚══════════════════════════════════════════════════════════════╝");
  console.log("");
  console.log(`  Seed node:  port ${SEED_PORT} (RPC ${RPC_PORT}, WS 8334)`);
  console.log(`  Miners:     ${MINER_COUNT} (staggered ${STAGGER_MS / 1000}s apart)`);
  console.log(`  Wallets:    wallets/network_miners.json`);
  console.log("");

  // Cleanup
  console.log("[CLEANUP] Stopping existing nodes...");
  try { execSync("taskkill /F /IM omnibus-node.exe", { stdio: "ignore" }); } catch {}
  await sleep(2000);

  // Check existing chain
  const dbPath = path.join(ROOT, "omnibus-chain.dat");
  if (fs.existsSync(dbPath)) {
    const size = fs.statSync(dbPath).size;
    console.log(`[DB] Existing chain found: ${dbPath} (${(size/1024).toFixed(1)} KB) — continuing`);
  } else {
    console.log("[DB] No chain file — starting from genesis");
  }
  console.log("");

  // Generate wallets
  fs.mkdirSync(WALLETS_DIR, { recursive: true });
  fs.mkdirSync(LOGS_DIR, { recursive: true });

  console.log(`[WALLETS] Generating ${MINER_COUNT} unique wallets...`);
  const miners = [];
  for (let i = 0; i < MINER_COUNT; i++) {
    const mnemonic = generateMnemonic();
    const address = deriveAddress(mnemonic);
    miners.push({ id: `miner-${i}`, mnemonic, address, port: SEED_PORT + 100 + i });
    console.log(`  Miner ${i}: ${address.slice(0, 28)}... | ${mnemonic.split(" ").slice(0, 3).join(" ")}...`);
  }
  fs.writeFileSync(path.join(WALLETS_DIR, "network_miners.json"), JSON.stringify(miners, null, 2));
  console.log(`\n  Saved to wallets/network_miners.json\n`);

  // Start seed node
  console.log("[SEED] Starting seed node...");
  const seedEnv = { ...process.env, OMNIBUS_MNEMONIC: "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about" };
  const seedProc = spawn(NODE_EXE, ["--mode", "seed", "--node-id", "seed-1", "--port", String(SEED_PORT)], {
    env: seedEnv,
    stdio: ["ignore", fs.openSync(path.join(LOGS_DIR, "seed.log"), "w"), fs.openSync(path.join(LOGS_DIR, "seed.log"), "a")],
  });
  processes.push(seedProc);
  console.log(`  PID: ${seedProc.pid}`);
  await sleep(5000);

  // Verify seed
  const status = await rpcCall("getstatus");
  if (status?.status === "running") {
    console.log(`  [OK] Seed running — block height: ${status.blockCount}`);
  } else {
    console.log("  [FAIL] Seed not responding! Check data/logs/seed.log");
    return;
  }
  console.log("");

  // Start miners staggered
  console.log(`[MINERS] Starting ${MINER_COUNT} miners (${STAGGER_MS / 1000}s apart)...\n`);

  for (let i = 0; i < MINER_COUNT; i++) {
    const m = miners[i];
    console.log(`  [${i + 1}/${MINER_COUNT}] Starting ${m.id} on port ${m.port}...`);
    console.log(`          Mnemonic: ${m.mnemonic.split(" ").slice(0, 4).join(" ")}...`);

    const minerEnv = { ...process.env, OMNIBUS_MNEMONIC: m.mnemonic };
    const minerProc = spawn(NODE_EXE, [
      "--mode", "miner", "--node-id", m.id,
      "--seed-host", "127.0.0.1", "--seed-port", String(SEED_PORT),
      "--port", String(m.port),
    ], {
      env: minerEnv,
      stdio: ["ignore", fs.openSync(path.join(LOGS_DIR, `${m.id}.log`), "w"), fs.openSync(path.join(LOGS_DIR, `${m.id}.log`), "a")],
    });
    processes.push(minerProc);
    console.log(`          PID: ${minerProc.pid}`);

    // Register with seed — params: [address, node_id]
    await sleep(2000);
    await rpcCall("registerminer", [m.address, m.id]);

    const st = await rpcCall("getstatus");
    console.log(`          Registered. Height: ${st?.blockCount || "?"}, Mempool: ${st?.mempoolSize || 0}`);
    console.log("");

    // Wait before next miner
    if (i < MINER_COUNT - 1) {
      const remaining = MINER_COUNT - i - 1;
      console.log(`  --- Waiting ${STAGGER_MS / 1000}s before next miner (${remaining} remaining) ---\n`);
      await sleep(STAGGER_MS);
    }
  }

  console.log("╔══════════════════════════════════════════════════════════════╗");
  console.log(`║   All ${MINER_COUNT} miners started! Mining should begin now.             ║`);
  console.log("╚══════════════════════════════════════════════════════════════╝");
  console.log("");
  console.log("  Frontend:  http://localhost:8888");
  console.log("  Wallets:   wallets/network_miners.json");
  console.log("  Logs:      data/logs/");
  console.log("  Stop all:  Ctrl+C or taskkill /F /IM omnibus-node.exe");
  console.log("");

  // Status loop
  while (true) {
    await sleep(30000);
    const st = await rpcCall("getstatus");
    const ms = await rpcCall("getminerstats");
    const time = new Date().toLocaleTimeString();
    console.log(`[STATUS] ${time} | Blocks: ${st?.blockCount || "?"} | Miners: ${ms?.totalMiners || "?"} | Balance: ${st?.balance || 0} SAT`);
  }
}

main().catch(console.error);
