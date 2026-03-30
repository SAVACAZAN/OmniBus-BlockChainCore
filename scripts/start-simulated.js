#!/usr/bin/env node
/**
 * start-simulated.js — Start seed node + register N virtual miners (1 process only!)
 *
 * Instead of spawning 100 omnibus-node.exe processes, this starts ONE seed node
 * and registers N miners via RPC. The seed mines blocks and distributes rewards
 * round-robin to all registered miners.
 *
 * Usage: node scripts/start-simulated.js [miners] [stagger_ms]
 *   miners:     number of virtual miners (default 20)
 *   stagger_ms: delay between registrations (default 2000)
 */

const { execSync, spawn } = require("child_process");
const crypto = require("crypto");
const fs = require("fs");
const path = require("path");

const MINER_COUNT = parseInt(process.argv[2]) || 20;
const STAGGER_MS = parseInt(process.argv[3]) || 2000;
const ROOT = path.resolve(__dirname, "..");
const NODE_EXE = path.join(ROOT, "zig-out", "bin", "omnibus-node.exe");
const WALLETS_DIR = path.join(ROOT, "wallets");
const LOGS_DIR = path.join(ROOT, "data", "logs");
const RPC_PORT = 8332;

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
    if (data.error) throw new Error(data.error.message);
    return data.result;
  } catch (e) { return null; }
}

function sleep(ms) { return new Promise(r => setTimeout(r, ms)); }

let seedProc = null;
function cleanup() {
  console.log("\n[SHUTDOWN] Stopping seed node...");
  if (seedProc) try { seedProc.kill(); } catch {}
  try { execSync("taskkill /F /IM omnibus-node.exe", { stdio: "ignore" }); } catch {}
  process.exit(0);
}
process.on("SIGINT", cleanup);
process.on("SIGTERM", cleanup);

async function main() {
  console.log("╔══════════════════════════════════════════════════════════════╗");
  console.log("║      OmniBus Simulated Network (1 process, N miners)        ║");
  console.log("╚══════════════════════════════════════════════════════════════╝");
  console.log("");
  console.log(`  Mode:     SIMULATED (1 seed process, ${MINER_COUNT} virtual miners)`);
  console.log(`  Stagger:  ${STAGGER_MS}ms between registrations`);
  console.log(`  RPC:      http://localhost:${RPC_PORT}`);
  console.log(`  WS:       ws://localhost:8334`);
  console.log(`  Frontend: http://localhost:8888`);
  console.log("");

  // Cleanup old
  console.log("[CLEANUP] Stopping existing nodes...");
  try { execSync("taskkill /F /IM omnibus-node.exe", { stdio: "ignore" }); } catch {}
  await sleep(2000);

  // Generate wallets
  fs.mkdirSync(WALLETS_DIR, { recursive: true });
  fs.mkdirSync(LOGS_DIR, { recursive: true });

  // Reuse existing wallets or generate new
  const walletsPath = path.join(WALLETS_DIR, "network_miners.json");
  let miners;
  if (fs.existsSync(walletsPath)) {
    miners = JSON.parse(fs.readFileSync(walletsPath, "utf-8"));
    if (miners.length >= MINER_COUNT) {
      miners = miners.slice(0, MINER_COUNT);
      console.log(`[WALLETS] Reusing ${MINER_COUNT} existing wallets`);
    } else {
      miners = null; // regenerate
    }
  }

  if (!miners) {
    console.log(`[WALLETS] Will generate ${MINER_COUNT} wallets via Zig (after seed starts)...`);
    miners = null; // generate after seed is running
  } else {
    console.log(`  First: ${miners[0].address.slice(0, 32)}...`);
    console.log(`  Last:  ${miners[MINER_COUNT - 1].address.slice(0, 32)}...`);
  }
  console.log("");

  // Check existing chain
  const dbPath = path.join(ROOT, "omnibus-chain.dat");
  if (fs.existsSync(dbPath)) {
    console.log(`[DB] Existing chain: ${(fs.statSync(dbPath).size / 1024).toFixed(1)} KB — continuing`);
  } else {
    console.log("[DB] Fresh start from genesis");
  }

  // Start seed node
  console.log("\n[SEED] Starting seed node...");
  const seedEnv = {
    ...process.env,
    OMNIBUS_MNEMONIC: "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about",
  };
  seedProc = spawn(NODE_EXE, ["--mode", "seed", "--node-id", "seed-1", "--port", "9000"], {
    env: seedEnv,
    stdio: ["ignore",
      fs.openSync(path.join(LOGS_DIR, "seed.log"), "w"),
      fs.openSync(path.join(LOGS_DIR, "seed.log"), "a")],
  });
  console.log(`  PID: ${seedProc.pid}`);

  // Wait for RPC
  let ready = false;
  for (let i = 0; i < 15; i++) {
    await sleep(1000);
    const st = await rpcCall("getstatus");
    if (st?.status === "running") { ready = true; break; }
  }
  if (!ready) { console.log("  [FAIL] Seed not responding!"); return; }

  const st = await rpcCall("getstatus");
  console.log(`  [OK] Seed running — block #${st.blockCount}, balance ${st.balance} SAT`);
  console.log("");

  // Generate wallets via Zig CLI (--generate-wallet) for identical address derivation
  if (!miners) {
    console.log(`[WALLETS] Generating ${MINER_COUNT} wallets via Zig...`);
    miners = [];
    for (let i = 0; i < MINER_COUNT; i++) {
      const mnemonic = generateMnemonic();
      let address;
      try {
        // Use Zig node to derive address identically to the blockchain
        const env = { ...process.env, OMNIBUS_MNEMONIC: mnemonic };
        const result = execSync(`"${NODE_EXE}" --generate-wallet`, { env, timeout: 10000, encoding: "utf-8" });
        const parsed = JSON.parse(result.trim());
        address = parsed.address;
      } catch {
        // Fallback: JS derivation (hex, not Base58 — TX-uri vor merge dar adrese diferite)
        address = deriveAddress(mnemonic);
      }
      miners.push({ id: `miner-${i}`, mnemonic, address, port: 9100 + i });
      if ((i + 1) % 10 === 0) console.log(`  Generated ${i + 1}/${MINER_COUNT}...`);
    }
    fs.writeFileSync(walletsPath, JSON.stringify(miners, null, 2));
    console.log(`  ${MINER_COUNT} wallets saved to wallets/network_miners.json`);
    console.log(`  First: ${miners[0].address.slice(0, 36)}...`);
    console.log(`  Last:  ${miners[MINER_COUNT - 1].address.slice(0, 36)}...`);
    console.log("");
  }

  // Register miners one by one
  console.log(`[MINERS] Registering ${MINER_COUNT} virtual miners...\n`);

  for (let i = 0; i < MINER_COUNT; i++) {
    const m = miners[i];
    await rpcCall("registerminer", [m.address, m.id]);

    if ((i + 1) % 10 === 0 || i === MINER_COUNT - 1) {
      const s = await rpcCall("getstatus");
      console.log(`  [${i + 1}/${MINER_COUNT}] registered | blocks: ${s?.blockCount || "?"} | miners: ${i + 2}`);
    }

    if (i < MINER_COUNT - 1) await sleep(STAGGER_MS);
  }

  console.log("");
  console.log("╔══════════════════════════════════════════════════════════════╗");
  console.log(`║   ${MINER_COUNT} miners registered! Mining active.                      ║`);
  console.log("╚══════════════════════════════════════════════════════════════╝");
  console.log("");
  console.log("  Frontend:  http://localhost:8888");
  console.log("  Wallets:   wallets/network_miners.json");
  console.log("  Logs:      data/logs/seed.log");
  console.log("  Stop:      Ctrl+C");
  console.log("");
  console.log("  Send TXs:  node scripts/send-transactions.js 200 100");
  console.log("");

  // Status loop
  while (true) {
    await sleep(15000);
    const s = await rpcCall("getstatus");
    if (!s) { console.log("[WARN] Node not responding"); continue; }
    const time = new Date().toLocaleTimeString();
    console.log(`[STATUS] ${time} | Block #${s.blockCount} | Balance: ${s.balance} SAT | Mempool: ${s.mempoolSize}`);
  }
}

main().catch(console.error);
