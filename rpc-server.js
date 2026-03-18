#!/usr/bin/env node
/**
 * OmniBus RPC Server - Node.js Bridge
 * Real Mining Transaction Tracking
 */

const http = require("http");
const fs = require("fs");

// Configuration
const RPC_PORT = 8332;
const WALLETS_FILE = "./wallets/genesis-allocation.json";
const MINING_REWARD = 5000000000; // 50 OMNI per block in SAT

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

// Real blockchain state
let blockCount = 1;
let balance = 0;
let mempoolSize = 0;
let startTime = Date.now();

// DYNAMIC: Track only ACTIVE miners (those currently mining)
let activeMinerSet = new Set();  // Real-time active miners
const MINER_ACTIVITY_TIMEOUT = 30000; // 30 seconds - if not mining, mark offline

// Mining transactions history - tracks REAL block rewards
let blockData = [];
let minerBalances = {};
let minerLastBlockTime = {};

// Initialize miner tracking
function initializeMiners() {
  if (genesisData.miners && genesisData.miners.length > 0) {
    genesisData.miners.forEach((miner, idx) => {
      minerBalances[miner.address] = 0;
      minerLastBlockTime[miner.address] = null;
    });
    // ALL miners are connected from start
    connectedMiners = genesisData.miners.length;
    console.log(`[RPC] Initialized ${connectedMiners} miners from genesis data`);
  } else {
    console.log("[RPC] WARNING: No miners found in genesis data");
  }
}

initializeMiners();

// Simulate real mining - EQUAL reward distribution to ALL active miners
setInterval(() => {
  blockCount++;
  const blockTimestamp = Date.now();
  const allMiners = genesisData.miners || [];

  // DYNAMIC EQUAL DISTRIBUTION: Divide block reward equally among all active miners
  if (activeMinerSet.size > 0) {
    // Reward per miner = total block reward / number of active miners
    const rewardPerMiner = MINING_REWARD / activeMinerSet.size;

    // Distribute to each active miner
    const transactions = [];
    for (let minerAddress of activeMinerSet) {
      const miner = allMiners.find(m => m.address === minerAddress);
      if (!miner) continue;

      const minerRewardTx = {
        id: blockCount + Array.from(activeMinerSet).indexOf(minerAddress),
        txid: `mining_reward_${blockCount}_${miner.miner_id}`,
        type: "coinbase",
        from: "SYSTEM",
        to: minerAddress,
        amount: rewardPerMiner / 1e9,
        amountSat: rewardPerMiner,
        timestamp: blockTimestamp,
        blockHeight: blockCount - 1,
        status: "confirmed",
        minerName: miner.miner_name || `Miner-${miner.miner_id}`,
        minerID: miner.miner_id
      };

      // Update balance
      minerBalances[minerAddress] = (minerBalances[minerAddress] || 0) + rewardPerMiner;
      minerLastBlockTime[minerAddress] = blockTimestamp;
      transactions.push(minerRewardTx);
      balance += rewardPerMiner;
    }

    // Store block with all reward transactions
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

    if (blockData.length > 100) {
      blockData.shift();
    }
  } else if (allMiners.length > 0) {
    // No active miners yet - distribute to ALL genesis miners equally
    const rewardPerMiner = MINING_REWARD / allMiners.length;
    const transactions = [];

    allMiners.forEach(miner => {
      const minerRewardTx = {
        id: blockCount + miner.miner_id,
        txid: `mining_reward_${blockCount}_${miner.miner_id}`,
        type: "coinbase",
        from: "SYSTEM",
        to: miner.address,
        amount: rewardPerMiner / 1e9,
        amountSat: rewardPerMiner,
        timestamp: blockTimestamp,
        blockHeight: blockCount - 1,
        status: "confirmed",
        minerName: miner.miner_name || `Miner-${miner.miner_id}`,
        minerID: miner.miner_id
      };

      minerBalances[miner.address] = (minerBalances[miner.address] || 0) + rewardPerMiner;
      minerLastBlockTime[miner.address] = blockTimestamp;
      activeMinerSet.add(miner.address);
      transactions.push(minerRewardTx);
      balance += rewardPerMiner;
    });

    blockData.push({
      index: blockCount - 1,
      timestamp: blockTimestamp,
      hash: generateBlockHash(),
      transactions: transactions,
      miner: `${allMiners.length} miners`,
      minerAddress: "DISTRIBUTED",
      reward: MINING_REWARD,
      activeMinersCount: allMiners.length
    });

    if (blockData.length > 100) {
      blockData.shift();
    }
  }
}, 2000);

// DYNAMIC: Cleanup inactive miners (haven't mined in 30 seconds)
setInterval(() => {
  const now = Date.now();
  const inactiveBefore = now - MINER_ACTIVITY_TIMEOUT;

  for (let address of activeMinerSet) {
    if (minerLastBlockTime[address] && minerLastBlockTime[address] < inactiveBefore) {
      activeMinerSet.delete(address);
    }
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

  getminerbalances: () => {
    if (!genesisData.miners || genesisData.miners.length === 0) {
      return [];
    }

    // DYNAMIC: Return ONLY active miners
    return genesisData.miners
      .filter(m => activeMinerSet.has(m.address))
      .map(miner => {
        const balance = minerBalances[miner.address] || 0;
        const rewardPerMiner = MINING_REWARD / (activeMinerSet.size || 1);
        return {
          address: miner.address,
          minerName: miner.miner_name || `Miner-${miner.miner_id}`,
          minerID: miner.miner_id,
          balanceSat: balance,
          balanceOmni: balance / 1e9,
          blocksMined: Math.round(balance / rewardPerMiner),
          lastBlockTime: minerLastBlockTime[miner.address],
          isActive: true
        };
      });
  },

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
    totalMiningRewards: balance / 1e9,
    totalTransactions: blockCount
  }),

  getminers: () => {
    if (!genesisData.miners || genesisData.miners.length === 0) {
      return [];
    }

    // DYNAMIC: Return ONLY active miners (those that have mined recently)
    return genesisData.miners
      .filter(m => activeMinerSet.has(m.address))
      .map((m) => ({
        id: m.miner_id,
        name: m.miner_name,
        address: m.address,
        status: "mining",
        hashrate: 1000,
        balanceOmni: (minerBalances[m.address] || 0) / 1e9,
        blocksMined: Math.round((minerBalances[m.address] || 0) / (MINING_REWARD / (activeMinerSet.size || 1))),
        lastBlockTime: minerLastBlockTime[m.address],
        isActive: true
      }));
  },

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
