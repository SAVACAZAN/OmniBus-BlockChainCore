#!/usr/bin/env node
/**
 * OmniBus Mining Pool - Dynamic Miner Registration
 * Accepts miners at runtime, no hardcoded lists
 */

const http = require("http");
const fs = require("fs");

// Configuration
const RPC_PORT = 8332;
const MINING_REWARD = 5000000000; // 50 OMNI per block in SAT
const MINER_ACTIVITY_TIMEOUT = 30000; // 30 seconds - if no keepalive, mark offline

// Real blockchain state
let blockCount = 1;
let balance = 0;
let mempoolSize = 0;
let startTime = Date.now();

// DYNAMIC MINING POOL: Miners register themselves at runtime
let minerRegistry = new Map();  // address → { id, name, hashrate, joinedAt, lastKeepalive }
let activeMinerSet = new Set();  // Currently mining addresses
let minerBalances = {};          // address → balance in SAT
let minerLastBlockTime = {};     // address → last reward timestamp

// Mining transactions history
let blockData = [];

console.log(`[POOL] OmniBus Mining Pool v1.0`);
console.log(`[POOL] Listening on port ${RPC_PORT}`);
console.log(`[POOL] Waiting for miners to register...`);

// Mining loop - EQUAL distribution to ALL active registered miners
setInterval(() => {
  blockCount++;
  const blockTimestamp = Date.now();

  // Only mine if we have active miners
  if (activeMinerSet.size > 0) {
    const rewardPerMiner = MINING_REWARD / activeMinerSet.size;
    const transactions = [];

    // Distribute block reward equally to all active miners
    for (let minerAddress of activeMinerSet) {
      const minerInfo = minerRegistry.get(minerAddress);
      if (!minerInfo) continue;

      const minerRewardTx = {
        id: blockCount * 10000 + minerRegistry.size,
        txid: `mining_reward_${blockCount}_${minerInfo.id}`,
        type: "coinbase",
        from: "SYSTEM",
        to: minerAddress,
        amount: rewardPerMiner / 1e9,      // OMNI
        amountSat: rewardPerMiner,         // SAT
        timestamp: blockTimestamp,
        blockHeight: blockCount - 1,
        status: "confirmed",
        minerName: minerInfo.name,
        minerID: minerInfo.id
      };

      minerBalances[minerAddress] = (minerBalances[minerAddress] || 0) + rewardPerMiner;
      minerLastBlockTime[minerAddress] = blockTimestamp;
      transactions.push(minerRewardTx);
      balance += rewardPerMiner;
    }

    // Store block
    blockData.push({
      index: blockCount - 1,
      timestamp: blockTimestamp,
      hash: generateBlockHash(),
      transactions: transactions,
      miner: `${activeMinerSet.size} miners`,
      minerAddress: "DISTRIBUTED",
      reward: MINING_REWARD,
      activeMinersCount: activeMinerSet.size
    });

    // Keep last 100 blocks
    if (blockData.length > 100) {
      blockData.shift();
    }
  }
}, 2000);

// Cleanup inactive miners (no keepalive for 30+ seconds)
setInterval(() => {
  const now = Date.now();
  const inactiveBefore = now - MINER_ACTIVITY_TIMEOUT;
  let disconnected = [];

  for (let [address, minerInfo] of minerRegistry.entries()) {
    if (minerInfo.lastKeepalive < inactiveBefore) {
      activeMinerSet.delete(address);
      disconnected.push(minerInfo.name);
    }
  }

  if (disconnected.length > 0) {
    console.log(`[POOL] Disconnected: ${disconnected.join(", ")}`);
  }
}, 5000);

function generateBlockHash() {
  const timestamp = Date.now();
  const random = Math.random().toString(36).substring(2, 15);
  return "0x" + (timestamp.toString(16) + random).substring(0, 64);
}

// RPC Methods
const rpcMethods = {
  getblockcount: () => blockCount,

  getblock: (params) => {
    const blockIdx = params[0] || 0;
    const block = blockData.find(b => b.index === blockIdx);

    if (block) {
      return {
        index: block.index,
        timestamp: block.timestamp,
        transactions: block.transactions,
        hash: block.hash,
        miner: block.miner,
        minerAddress: block.minerAddress,
        reward: block.reward / 1e9
      };
    }

    return {
      index: blockIdx,
      timestamp: Date.now(),
      transactions: [],
      hash: generateBlockHash()
    };
  },

  getlatestblock: () => {
    const latestBlock = blockData[blockData.length - 1];
    if (latestBlock) {
      return {
        index: latestBlock.index,
        timestamp: latestBlock.timestamp,
        transactions: latestBlock.transactions,
        hash: latestBlock.hash,
        miner: latestBlock.miner,
        minerAddress: latestBlock.minerAddress,
        reward: latestBlock.reward / 1e9
      };
    }
    return { index: blockCount - 1, timestamp: Date.now(), transactions: [], hash: generateBlockHash() };
  },

  getbalance: () => balance,

  getmempoolsize: () => mempoolSize,

  getmempooltransactions: () => [],

  gettransactioncount: () => {
    // REAL: Total transactions = all transactions across all blocks
    let totalTxCount = 0;
    blockData.forEach(block => {
      totalTxCount += (block.transactions ? block.transactions.length : 0);
    });
    return totalTxCount;
  },

  gettransactionhistory: (params) => {
    const limit = params[0] || 20;
    const allTransactions = [];

    // Collect all transactions from recent blocks
    blockData.slice(-Math.min(limit, blockData.length)).forEach(block => {
      allTransactions.push(...block.transactions);
    });

    return allTransactions.reverse().slice(0, limit);
  },

  // Pool-specific RPC methods
  registerminer: (params) => {
    // params: [{ id: "miner-1", name: "Miner-1", address: "ob_omni_...", hashrate: 1000 }]
    if (!params || !params[0]) {
      return { success: false, error: "Missing miner registration data" };
    }

    const minerData = params[0];
    const { id, name, address, hashrate } = minerData;

    if (!address) {
      return { success: false, error: "Missing miner address" };
    }

    // Register miner
    minerRegistry.set(address, {
      id: id || `miner-${minerRegistry.size}`,
      name: name || `Miner-${minerRegistry.size}`,
      hashrate: hashrate || 1000,
      joinedAt: Date.now(),
      lastKeepalive: Date.now()
    });

    // Activate miner
    activeMinerSet.add(address);
    if (!minerBalances[address]) {
      minerBalances[address] = 0;
    }

    const minerInfo = minerRegistry.get(address);
    console.log(`[POOL] ✓ Miner joined: ${minerInfo.name} (${hashrate || 1000} H/s)`);

    return {
      success: true,
      message: `${minerInfo.name} registered`,
      minerCount: minerRegistry.size,
      activeMiners: activeMinerSet.size
    };
  },

  minerkeepalive: (params) => {
    // params: [address]
    if (!params || !params[0]) {
      return { success: false, error: "Missing miner address" };
    }

    const address = params[0];
    const minerInfo = minerRegistry.get(address);

    if (!minerInfo) {
      return { success: false, error: "Miner not registered" };
    }

    // Update keepalive timestamp
    minerInfo.lastKeepalive = Date.now();
    activeMinerSet.add(address);

    return {
      success: true,
      message: "Keepalive received",
      isActive: true
    };
  },

  getminerstatus: () => ({
    poolStatus: "running",
    blockCount: blockCount,
    currentDifficulty: 4,
    timestamp: Date.now(),
    totalRegisteredMiners: minerRegistry.size,
    activeMiningMiners: activeMinerSet.size,
    totalHashrate: Array.from(minerRegistry.values()).reduce((sum, m) => sum + (m.hashrate || 1000), 0),
    poolReady: activeMinerSet.size >= 1,
    miningStarted: blockCount > 1,
    totalMiningRewards: balance / 1e9,
    totalTransactions: blockData.reduce((sum, block) => sum + (block.transactions ? block.transactions.length : 0), 0),
    blockReward: MINING_REWARD / 1e9  // 50 OMNI
  }),

  getminerbalances: () => {
    const result = [];

    // Return only active miners with their balances
    for (let [address, minerInfo] of minerRegistry.entries()) {
      if (activeMinerSet.has(address)) {
        const balance = minerBalances[address] || 0;
        const rewardPerMiner = MINING_REWARD / (activeMinerSet.size || 1);

        result.push({
          address: address,
          minerName: minerInfo.name,
          minerID: minerInfo.id,
          balanceSat: balance,
          balanceOmni: balance / 1e9,
          blocksMined: Math.round(balance / rewardPerMiner),
          lastBlockTime: minerLastBlockTime[address] || minerInfo.joinedAt,
          isActive: true,
          joinedAt: minerInfo.joinedAt
        });
      }
    }

    return result;
  },

  getminers: () => {
    const result = [];

    // Return only active miners
    for (let [address, minerInfo] of minerRegistry.entries()) {
      if (activeMinerSet.has(address)) {
        result.push({
          id: minerInfo.id,
          name: minerInfo.name,
          address: address,
          status: "mining",
          hashrate: minerInfo.hashrate || 1000,
          balanceOmni: (minerBalances[address] || 0) / 1e9,
          blocksMined: minerLastBlockTime[address] ?
            Math.round((minerBalances[address] || 0) / (MINING_REWARD / (activeMinerSet.size || 1))) : 0,
          lastBlockTime: minerLastBlockTime[address] || minerInfo.joinedAt,
          isActive: true,
          joinedAt: minerInfo.joinedAt
        });
      }
    }

    return result;
  },

  getpoolstats: () => ({
    version: "1.0",
    status: "operational",
    registeredMiners: minerRegistry.size,
    activeMiningMiners: activeMinerSet.size,
    blockHeight: blockCount,
    totalRewards: balance / 1e9,
    totalTransactions: blockData.reduce((sum, block) => sum + (block.transactions ? block.transactions.length : 0), 0),
    uptime: Date.now() - startTime
  }),

  startgenesis: () => true
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
  console.log("");
  console.log(`╔════════════════════════════════════════════════════════════╗`);
  console.log(`║         OmniBus Mining Pool - Dynamic Registry             ║`);
  console.log(`║                     v1.0 Operational                       ║`);
  console.log(`╚════════════════════════════════════════════════════════════╝`);
  console.log("");
  console.log(`[POOL] JSON-RPC 2.0 Server on http://localhost:${RPC_PORT}`);
  console.log("");
  console.log(`[POOL] MINING POOL METHODS:`);
  console.log(`       • registerminer       - Register a new miner`);
  console.log(`       • minerkeepalive      - Send keepalive signal`);
  console.log(`       • getminerstatus     - Pool status + reward rate`);
  console.log(`       • getminerbalances   - All active miner balances`);
  console.log(`       • getminers          - All active miners`);
  console.log(`       • getpoolstats       - Detailed pool stats`);
  console.log("");
  console.log(`[POOL] BLOCKCHAIN METHODS:`);
  console.log(`       • getblockcount      - Current block number`);
  console.log(`       • getblock           - Get block by index`);
  console.log(`       • getlatestblock     - Get last block`);
  console.log(`       • getbalance         - Total pool balance`);
  console.log(`       • gettransactioncount - Total tx count`);
  console.log(`       • gettransactionhistory - Recent transactions`);
  console.log("");
  console.log(`[POOL] STATUS: Waiting for miners to register...`);
  console.log("");
});

process.on("SIGINT", () => {
  console.log("[RPC] Server shutting down...");
  server.close();
  process.exit(0);
});
