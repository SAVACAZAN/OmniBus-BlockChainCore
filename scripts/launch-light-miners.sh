#!/bin/bash
# OmniBus Light Miner Launcher (Linux/macOS)
# Launches multiple independent light miner instances

set -e

echo ""
echo "========================================"
echo "OmniBus Light Miner Launcher"
echo "========================================"
echo ""

# Check if omnibus-node executable exists
if [ ! -f "./omnibus-node" ]; then
    echo "ERROR: omnibus-node not found in current directory"
    echo "Please compile with: zig build-exe -O ReleaseFast core/main.zig --name omnibus-node"
    echo ""
    exit 1
fi

# Configuration
SEED_HOST="127.0.0.1"
SEED_PORT="9000"
HASHRATE="1000"

echo "Launching 10 light miner instances..."
echo "Seed node: $SEED_HOST:$SEED_PORT"
echo "Hashrate per miner: $HASHRATE H/s"
echo ""

# Create logs directory
mkdir -p logs

# Launch 10 miners
for i in {1..10}; do
    MINER_ID="light-miner-$i"
    NODE_ID="miner-$i"
    LOG_FILE="logs/$MINER_ID.log"

    echo "Starting $MINER_ID..."

    # Launch miner in background, redirect output to log file
    ./omnibus-node \
        --mode miner \
        --node-id "$NODE_ID" \
        --seed-host "$SEED_HOST" \
        --seed-port "$SEED_PORT" \
        --hashrate "$HASHRATE" \
        > "$LOG_FILE" 2>&1 &

    # Store PID for later
    echo $! >> .miner_pids

    # Small delay between launches
    sleep 1
done

echo ""
echo "========================================"
echo "All 10 miners launched!"
echo "========================================"
echo ""
echo "Miners will connect to: $SEED_HOST:$SEED_PORT"
echo ""
echo "Open your browser to:"
echo "  http://localhost:3000/genesis-countdown"
echo ""
echo "View miner logs:"
echo "  tail -f logs/light-miner-1.log"
echo ""
echo "Stop all miners:"
echo "  pkill -f omnibus-node"
echo ""
