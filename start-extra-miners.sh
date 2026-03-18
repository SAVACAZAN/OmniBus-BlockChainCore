#!/bin/bash

# OmniBus - Start 100 Extra Miners
# Connects to existing seed node at 127.0.0.1:9000
# Separate from genesis 10 miners

set -e

SEED_HOST="127.0.0.1"
SEED_PORT="9000"
EXTRA_MINERS=100
LOGS_DIR="./logs"
PIDS_FILE=".extra_miners_pids"

echo "==================================================="
echo "🚀 OmniBus Extra Miners - Starting 100 Nodes"
echo "==================================================="

# Create logs directory
mkdir -p "$LOGS_DIR"

# Clear previous PIDs
> "$PIDS_FILE"

# Launch 100 extra miners (miner-10 to miner-109)
echo "[BOOT] Launching ${EXTRA_MINERS} extra miners..."
for i in $(seq 10 $((9 + EXTRA_MINERS))); do
  MINER_ID="extra-miner-$i"
  LOG_FILE="$LOGS_DIR/extra-miner-${i}.log"

  ./omnibus-node \
    --mode miner \
    --node-id "$MINER_ID" \
    --seed-host "$SEED_HOST" \
    --seed-port "$SEED_PORT" \
    --hashrate 1000 \
    > "$LOG_FILE" 2>&1 &

  PID=$!
  echo "$PID" >> "$PIDS_FILE"

  if [ $((($i - 9) % 10)) -eq 0 ]; then
    echo "[BOOT] Started miners $((i-9))-$i/$EXTRA_MINERS..."
  fi

  # Small delay to avoid overwhelming system
  sleep 0.05
done

echo ""
echo "==================================================="
echo "✓ EXTRA MINERS STARTED"
echo "==================================================="
echo "Total extra miners: $EXTRA_MINERS"
echo "Seed node: $SEED_HOST:$SEED_PORT"
echo "PIDs saved to: $PIDS_FILE"
echo "Logs: $LOGS_DIR/extra-miner-*.log"
echo ""
echo "To stop all extra miners:"
echo "  cat $PIDS_FILE | xargs kill"
echo ""

# Keep script running
wait
