#!/usr/bin/env node
/**
 * OmniBus RPC Server - Node.js Bridge
 * Handles JSON-RPC 2.0 requests and returns blockchain data
 */

const http = require("http");
const fs = require("fs");

// Configuration
const RPC_PORT = 8332;
const WALLETS_FILE = "./wallets/genesis-allocation.json";

// Load genesis data
let genesisData = {
  miners: [],
  totalSupply: 21000000,
};

try {
  if (fs.existsSync(WALLETS_FILE)) {
    const data = fs.readFileSync(WALLETS_FILE, "utf8");
    genesisData = JSON.parse(data);
  }
} catch (err) {
  console.error("Failed to load genesis data:", err.message);
}

// Mock blockchain state
let blockCount = 1;
let balance = 50000000000; // 50 OMNI in SAT
let mempoolSize = 0;
let connectedMiners = 0;

// Simulate mining progress
setInterval(() => {
  blockCount++;
  if (blockCount % 10 === 0) {
    connectedMiners = Math.min(10, connectedMiners + 1);
  }
}, 2000);

// RPC Methods
const rpcMethods = {
  getblockcount: () => blockCount,
  getblock: (params) => ({
    index: params[0] || 0,
    timestamp: Date.now(),
    transactions: [],
    hash: "0x" + Math.random().toString(16).slice(2),
  }),
  getlatestblock: () => ({
    index: blockCount - 1,
    timestamp: Date.now(),
    transactions: [],
    hash: "0x" + Math.random().toString(16).slice(2),
  }),
  getbalance: () => balance,
  getmempoolsize: () => mempoolSize,
  getmempooltransactions: () => [],
  getgenesiesstatus: () => ({
    status: "mining",
    blockCount: blockCount,
    currentDifficulty: 4,
    timestamp: Date.now(),
    connectedMiners: connectedMiners,
    totalMiners: 10,
    totalHashrate: connectedMiners * 1000,
    genesisReady: connectedMiners >= 3,
    genesisStarted: blockCount > 1,
    minersRequired: 3,
  }),
  getminers: () =>
    genesisData.miners.map((m) => ({
      id: m.miner_id,
      name: m.miner_name,
      address: m.address,
      status: "mining",
      hashrate: 1000,
    })),
  startgenesis: () => true,
};

// HTTP Server
const server = http.createServer((req, res) => {
  // CORS headers
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Access-Control-Allow-Methods", "POST, GET, OPTIONS");
  res.setHeader("Access-Control-Allow-Headers", "Content-Type");
  res.setHeader("Content-Type", "application/json");

  if (req.method === "OPTIONS") {
    res.writeHead(200);
    res.end();
    return;
  }

  if (req.method !== "POST") {
    res.writeHead(405);
    res.end(JSON.stringify({ error: "Method not allowed" }));
    return;
  }

  let body = "";
  req.on("data", (chunk) => {
    body += chunk.toString();
  });

  req.on("end", () => {
    try {
      const request = JSON.parse(body);
      const method = request.method.toLowerCase();
      const params = request.params || [];
      const id = request.id || 1;

      let result;
      let error = null;

      if (rpcMethods[method]) {
        result = rpcMethods[method](params);
      } else {
        error = {
          code: -32601,
          message: "Method not found",
        };
      }

      const response = {
        jsonrpc: "2.0",
        id: id,
        ...(error ? { error } : { result }),
      };

      res.writeHead(200);
      res.end(JSON.stringify(response));
    } catch (err) {
      res.writeHead(400);
      res.end(
        JSON.stringify({
          jsonrpc: "2.0",
          error: { code: -32700, message: "Parse error" },
          id: null,
        })
      );
    }
  });
});

server.listen(RPC_PORT, "127.0.0.1", () => {
  console.log(`[RPC] JSON-RPC 2.0 Server`);
  console.log(`  - Listening on: http://localhost:${RPC_PORT}`);
  console.log(
    `  - Methods: getblockcount, getblock, getbalance, getmempoolsize`
  );
  console.log(`  - Genesis: getgenesiesstatus, getminers, startgenesis`);
});

process.on("SIGINT", () => {
  console.log("[RPC] Server shutting down...");
  server.close();
  process.exit(0);
});
