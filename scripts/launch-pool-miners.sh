#!/bin/bash

# OmniBus Mining Pool - Launch Miners
# Starts N miner clients that register with the pool dynamically

set -e

POOL_HOST="127.0.0.1"
POOL_PORT=8332
NUM_MINERS=${1:-10}
LOGS_DIR="./logs"
PIDS_FILE=".miners_pids"

echo ""
echo "╔════════════════════════════════════════════════════════════╗"
echo "║      OmniBus Mining Pool - Launching Miners                ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""

# Create logs directory
mkdir -p "$LOGS_DIR"

# Clear previous PIDs
> "$PIDS_FILE"

echo "[LAUNCH] Starting $NUM_MINERS miners..."
echo ""

# Launch miners
for i in $(seq 0 $((NUM_MINERS - 1))); do
  MINER_ID="miner-$i"
  LOG_FILE="$LOGS_DIR/miner-${i}.log"

  node ./miner-client.js "$MINER_ID" "Miner-$i" "ob_omni_miner${i}xxxxxxxxxxxxxxxx" 1000 \
    > "$LOG_FILE" 2>&1 &

  PID=$!
  echo "$PID" >> "$PIDS_FILE"

  if [ $((($i + 1) % 5)) -eq 0 ]; then
    echo "[LAUNCH] Started miners 0-$i/$NUM_MINERS..."
  fi

  # Small delay to prevent overwhelming the pool
  sleep 0.1
done

echo ""
echo "╔════════════════════════════════════════════════════════════╗"
echo "✓ ALL MINERS STARTED"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""
echo "[LAUNCH] Summary:"
echo "         • Total miners launched: $NUM_MINERS"
echo "         • Pool host: $POOL_HOST:$POOL_PORT"
echo "         • Logs directory: $LOGS_DIR/"
echo "         • PIDs saved to: $PIDS_FILE"
echo ""
echo "[LAUNCH] To view miner logs:"
echo "         tail -f $LOGS_DIR/miner-0.log"
echo ""
echo "[LAUNCH] To stop all miners:"
echo "         cat $PIDS_FILE | xargs kill"
echo ""
echo "[LAUNCH] To check pool status:"
echo "         curl -X POST http://$POOL_HOST:$POOL_PORT \\\\
echo "           -H 'Content-Type: application/json' \\\\
echo "           -d '{\"jsonrpc\":\"2.0\",\"method\":\"getpoolstats\",\"params\":[],\"id\":1}'"
echo ""

# Keep script running
wait
