#!/bin/bash

# OmniBus Genesis - Bootstrap Network
# 1. Create 10 miner wallets with addresses
# 2. Start mining pool
# 3. Launch genesis miners
# 4. Show network status

set -e

NUM_GENESIS_MINERS=10
POOL_PORT=8332
RPC_HOST="127.0.0.1"

echo ""
echo "╔════════════════════════════════════════════════════════════╗"
echo "║            OmniBus Genesis - Network Bootstrap              ║"
echo "║              Phase 1: 10 Genesis Miners                     ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""

# Step 1: Generate genesis miner wallets
echo "[GENESIS] Step 1: Generating $NUM_GENESIS_MINERS miner wallets with addresses..."
node ./create-wallet.js batch $NUM_GENESIS_MINERS

echo ""
echo "=================================================="
echo ""

# Step 2: Start mining pool in background
echo "[GENESIS] Step 2: Starting OmniBus Mining Pool..."
node ./rpc-server.js > ./logs/pool.log 2>&1 &
POOL_PID=$!
echo "[GENESIS] Pool PID: $POOL_PID"

# Give pool time to start
sleep 2

# Check if pool is running
if ! ps -p $POOL_PID > /dev/null; then
  echo "[GENESIS] ✗ Pool failed to start. Check logs/pool.log"
  exit 1
fi

echo "[GENESIS] ✓ Pool started and listening on $RPC_HOST:$POOL_PORT"

echo ""
echo "=================================================="
echo ""

# Step 3: Launch genesis miners
echo "[GENESIS] Step 3: Launching $NUM_GENESIS_MINERS genesis miners..."
bash ./launch-pool-miners.sh $NUM_GENESIS_MINERS

echo ""
echo "=================================================="
echo ""

# Step 4: Show network status
echo "[GENESIS] Step 4: Network Status..."
sleep 3

echo ""
echo "[GENESIS] Checking pool status..."

curl -s -X POST http://$RPC_HOST:$POOL_PORT \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"getpoolstats","params":[],"id":1}' | jq '.' 2>/dev/null || echo "Status check failed (pool may still be initializing)"

echo ""
echo "╔════════════════════════════════════════════════════════════╗"
echo "✓ GENESIS NETWORK OPERATIONAL"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""
echo "[GENESIS] Summary:"
echo "          • Pool server running (PID: $POOL_PID)"
echo "          • Genesis miners: $NUM_GENESIS_MINERS"
echo "          • Mining pool: http://$RPC_HOST:$POOL_PORT"
echo "          • Logs: ./logs/"
echo ""
echo "[GENESIS] Next steps:"
echo "          1. Monitor mining: tail -f ./logs/pool.log"
echo "          2. Launch extra 100 miners: bash ./launch-extra-miners.sh 100"
echo "          3. View explorer: http://localhost:8888"
echo ""
echo "[GENESIS] To stop everything:"
echo "          kill $POOL_PID"
echo "          cat .miners_pids | xargs kill"
echo ""
