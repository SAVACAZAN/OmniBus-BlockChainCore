#!/usr/bin/env node
/**
 * OmniBus Mining Pool - Miner Client
 * Registers with pool and sends keepalive signals
 */

const http = require("http");

// Configuration
const POOL_HOST = "127.0.0.1";
const POOL_PORT = 8332;
const MINER_ID = process.argv[2] || `miner-${Math.floor(Math.random() * 10000)}`;
const MINER_NAME = process.argv[3] || MINER_ID;
const MINER_ADDRESS = process.argv[4] || `ob_omni_${MINER_ID.replace(/[^a-z0-9]/g, '')}xxx`;
const HASHRATE = parseInt(process.argv[5]) || 1000;
const KEEPALIVE_INTERVAL = 5000; // 5 seconds

// RPC request helper
function rpcCall(method, params = []) {
  return new Promise((resolve, reject) => {
    const postData = JSON.stringify({
      jsonrpc: "2.0",
      method: method,
      params: params,
      id: Math.floor(Math.random() * 10000),
    });

    const options = {
      hostname: POOL_HOST,
      port: POOL_PORT,
      path: "/",
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "Content-Length": Buffer.byteLength(postData),
      },
    };

    const req = http.request(options, (res) => {
      let data = "";

      res.on("data", (chunk) => {
        data += chunk;
      });

      res.on("end", () => {
        try {
          const response = JSON.parse(data);
          if (response.error) {
            reject(new Error(`RPC Error: ${response.error.message}`));
          } else {
            resolve(response.result);
          }
        } catch (err) {
          reject(err);
        }
      });
    });

    req.on("error", (err) => {
      reject(err);
    });

    req.write(postData);
    req.end();
  });
}

// Register with pool
async function registerWithPool() {
  try {
    console.log(`[MINER] Attempting to register with pool at ${POOL_HOST}:${POOL_PORT}...`);

    const result = await rpcCall("registerminer", [
      {
        id: MINER_ID,
        name: MINER_NAME,
        address: MINER_ADDRESS,
        hashrate: HASHRATE,
      },
    ]);

    console.log(`[MINER] ✓ Successfully registered!`);
    console.log(`[MINER] Miner ID: ${MINER_ID}`);
    console.log(`[MINER] Address: ${MINER_ADDRESS}`);
    console.log(`[MINER] Hashrate: ${HASHRATE} H/s`);
    console.log(`[MINER] Pool has ${result.minerCount} registered miners (${result.activeMiners} active)`);
    console.log("");
    console.log(`[MINER] Sending keepalive every ${KEEPALIVE_INTERVAL / 1000} seconds...`);
    console.log("");

    // Send keepalive every 5 seconds
    setInterval(async () => {
      try {
        const status = await rpcCall("minerkeepalive", [MINER_ADDRESS]);

        // Log stats every 10 keepalives (50 seconds)
        if (Math.random() < 0.1) {
          try {
            const poolStats = await rpcCall("getpoolstats");
            console.log(
              `[MINER] Pool: ${poolStats.activeMiningMiners}/${poolStats.registeredMiners} miners, Block #${poolStats.blockHeight}, ⛏️  ${(poolStats.totalRewards / 1e9).toFixed(2)} OMNI mined`
            );
          } catch (err) {
            // Silent fail on stats
          }
        }
      } catch (err) {
        console.error(`[MINER] ✗ Keepalive failed: ${err.message}`);
      }
    }, KEEPALIVE_INTERVAL);

  } catch (err) {
    console.error(`[MINER] ✗ Registration failed: ${err.message}`);
    console.error(`[MINER] Make sure pool is running on ${POOL_HOST}:${POOL_PORT}`);
    process.exit(1);
  }
}

// Graceful shutdown
process.on("SIGINT", () => {
  console.log("");
  console.log(`[MINER] Disconnecting from pool...`);
  process.exit(0);
});

// Start
console.log("");
console.log("╔════════════════════════════════════════════════════════════╗");
console.log("║         OmniBus Mining Pool - Miner Client                 ║");
console.log("║                      v1.0                                  ║");
console.log("╚════════════════════════════════════════════════════════════╝");
console.log("");

registerWithPool();
