#!/usr/bin/env node
/**
 * send-transactions.js — Send transactions between miners
 * Usage: node scripts/send-transactions.js [count] [delay_ms]
 *   count:    number of transactions (default 10)
 *   delay_ms: delay between TXs in ms (default 500)
 *
 * Reads wallets from wallets/network_miners.json
 * Sends random amounts between random miners via RPC sendtransaction
 */

const fs = require("fs");
const path = require("path");

const TX_COUNT = parseInt(process.argv[2]) || 10;
const DELAY_MS = parseInt(process.argv[3]) || 500;
const RPC_URL = "http://localhost:8332";

async function rpcCall(method, params = []) {
  const res = await fetch(RPC_URL, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", method, params, id: Date.now() }),
  });
  const data = await res.json();
  if (data.error) throw new Error(data.error.message);
  return data.result;
}

function sleep(ms) { return new Promise(r => setTimeout(r, ms)); }

async function main() {
  // Load wallets
  const walletsPath = path.resolve(__dirname, "..", "wallets", "network_miners.json");
  if (!fs.existsSync(walletsPath)) {
    console.error("[ERROR] wallets/network_miners.json not found. Run start-network.js first.");
    process.exit(1);
  }
  const miners = JSON.parse(fs.readFileSync(walletsPath, "utf-8"));

  // Get current status
  const status = await rpcCall("getstatus");
  console.log("╔══════════════════════════════════════════════════════════════╗");
  console.log("║           OmniBus Transaction Generator                      ║");
  console.log("╚══════════════════════════════════════════════════════════════╝");
  console.log("");
  console.log(`  Node:        ${status.status} | Block #${status.blockCount}`);
  console.log(`  Miners:      ${miners.length} wallets loaded`);
  console.log(`  Transactions: ${TX_COUNT} (${DELAY_MS}ms apart)`);
  console.log(`  Seed balance: ${status.balance} SAT (${(status.balance / 1e9).toFixed(4)} OMNI)`);
  console.log("");

  // Wait until mining is active and seed has balance
  let waited = 0;
  while (true) {
    const s = await rpcCall("getstatus").catch(() => null);
    if (s && s.balance > 10000) {
      console.log(`  Balance: ${s.balance} SAT (${(s.balance/1e9).toFixed(4)} OMNI) — ready!`);
      console.log(`  Block height: ${s.blockCount}\n`);
      break;
    }
    if (waited === 0) console.log("[WAIT] Waiting for mining to start and build balance...");
    await sleep(2000);
    waited += 2;
    if (waited % 10 === 0) {
      const bal = s?.balance || 0;
      const blk = s?.blockCount || 0;
      process.stdout.write(`  ${waited}s — blocks: ${blk}, balance: ${bal} SAT\n`);
    }
  }

  // Send transactions
  let success = 0, failed = 0;
  const results = [];

  for (let i = 0; i < TX_COUNT; i++) {
    // Random sender/receiver from miners (seed can send, miners can receive)
    const receiver = miners[Math.floor(Math.random() * miners.length)];

    // Random amount: 100-1000 SAT (small amounts to avoid draining balance)
    const amount = Math.floor(Math.random() * 900) + 100;

    try {
      const result = await rpcCall("sendtransaction", [receiver.address, amount]);
      success++;
      const txid = result?.txid || "?";
      results.push({ i: i + 1, to: receiver.id, amount, txid: txid.slice(0, 16), status: "ok" });

      if ((i + 1) % 10 === 0 || i === TX_COUNT - 1) {
        console.log(`  [${i + 1}/${TX_COUNT}] ${success} ok, ${failed} failed | last: ${amount} SAT → ${receiver.id}`);
      }
    } catch (err) {
      failed++;
      results.push({ i: i + 1, to: receiver.id, amount, txid: "", status: err.message });
      if ((i + 1) % 10 === 0) {
        console.log(`  [${i + 1}/${TX_COUNT}] ${success} ok, ${failed} failed | ERROR: ${err.message}`);
      }
    }

    if (i < TX_COUNT - 1) await sleep(DELAY_MS);
  }

  // Summary
  console.log("");
  console.log("════════════════════════════════════════════════════════════════");
  console.log(`  DONE: ${success} sent, ${failed} failed out of ${TX_COUNT}`);

  const finalStatus = await rpcCall("getstatus");
  console.log(`  Block Height: ${finalStatus.blockCount}`);
  console.log(`  Mempool: ${finalStatus.mempoolSize} pending`);
  console.log(`  Seed Balance: ${finalStatus.balance} SAT`);
  console.log("");

  // Save TX log
  const logPath = path.resolve(__dirname, "..", "data", "tx_log.json");
  fs.mkdirSync(path.dirname(logPath), { recursive: true });
  fs.writeFileSync(logPath, JSON.stringify({ timestamp: new Date().toISOString(), total: TX_COUNT, success, failed, transactions: results }, null, 2));
  console.log(`  TX log: data/tx_log.json`);
}

main().catch(console.error);
