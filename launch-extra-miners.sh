#!/bin/bash

# OmniBus Extra Miners - Network Scaling Test
# Launches N additional miners to test pool's dynamic registration

set -e

NUM_MINERS=${1:-100}
POOL_HOST="127.0.0.1"
POOL_PORT=8332
LOGS_DIR="./logs"
PIDS_FILE=".extra_miners_pids"
WALLET_FILE="./wallets/extra_miners_${NUM_MINERS}.json"

echo ""
echo "╔════════════════════════════════════════════════════════════╗"
echo "║          OmniBus Extra Miners - Scaling Test                ║"
echo "║               Launching $NUM_MINERS additional miners              ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""

# Check if pool is running
echo "[EXTRA] Checking pool status..."
curl -s -X POST http://$POOL_HOST:$POOL_PORT \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"getpoolstats","params":[],"id":1}' > /dev/null 2>&1 || {
  echo "[EXTRA] ✗ Pool is not running at $POOL_HOST:$POOL_PORT"
  echo "[EXTRA] Start the pool first: bash start-genesis.sh"
  exit 1
}
echo "[EXTRA] ✓ Pool is running"
echo ""

# Create logs directory
mkdir -p "$LOGS_DIR"

# Generate wallets for extra miners (starting from miner-10)
echo "[EXTRA] Generating wallets for $NUM_MINERS extra miners..."
node ./create-wallet.js batch $NUM_MINERS > /dev/null 2>&1 &
WALLET_PID=$!
wait $WALLET_PID

echo "[EXTRA] ✓ Wallets generated"
echo ""

# Clear previous PIDs
> "$PIDS_FILE"

echo "[EXTRA] Starting $NUM_MINERS miners..."
echo ""

# Launch miners (miner-10 through miner-N+9)
for i in $(seq 10 $((9 + NUM_MINERS))); do
  MINER_ID="miner-$i"
  LOG_FILE="$LOGS_DIR/extra-miner-${i}.log"

  node ./miner-client.js "$MINER_ID" "ExtraMiner-$i" "ob_omni_extra${i}xxxxxxxxxx" 1000 \
    > "$LOG_FILE" 2>&1 &

  PID=$!
  echo "$PID" >> "$PIDS_FILE"

  if [ $((($i - 9) % 10)) -eq 0 ]; then
    echo "[EXTRA] Started miners $((i-9))-$i/$NUM_MINERS..."
  fi

  # Small delay to prevent overwhelming the pool
  sleep 0.05
done

echo ""
echo "╔════════════════════════════════════════════════════════════╗"
echo "✓ EXTRA MINERS LAUNCHED"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""
echo "[EXTRA] Summary:"
echo "        • Total extra miners: $NUM_MINERS"
echo "        • Pool: $POOL_HOST:$POOL_PORT"
echo "        • Logs: $LOGS_DIR/extra-miner-*.log"
echo "        • PIDs: $PIDS_FILE"
echo ""
echo "[EXTRA] Monitor pool status:"
echo "        curl -X POST http://$POOL_HOST:$POOL_PORT \\\\
echo "          -H 'Content-Type: application/json' \\\\
echo "          -d '{\"jsonrpc\":\"2.0\",\"method\":\"getpoolstats\",\"params\":[],\"id\":1}' | jq ."
echo ""
echo "[EXTRA] View miner logs:"
echo "        tail -f $LOGS_DIR/extra-miner-10.log"
echo ""
echo "[EXTRA] Stop all extra miners:"
echo "        cat $PIDS_FILE | xargs kill"
echo ""
