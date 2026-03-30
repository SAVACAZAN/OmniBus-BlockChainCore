#!/bin/bash

# OmniBus - Complete System Reset
# Kills EVERYTHING and clears state

echo ""
echo "╔══════════════════════════════════════════════════════════════════════════╗"
echo "║                     OMNIBUS COMPLETE RESET                              ║"
echo "║           Killing all processes and clearing state...                   ║"
echo "╚══════════════════════════════════════════════════════════════════════════╝"
echo ""

# Step 1: Kill all node processes (WSL)
echo "[RESET] Killing all Node.js processes..."
wsl.exe -e bash -c 'killall -9 node 2>/dev/null || true'
sleep 1

# Step 2: Kill all omnibus-node processes
echo "[RESET] Killing all omnibus-node processes..."
wsl.exe -e bash -c 'killall -9 omnibus-node 2>/dev/null || true'
sleep 1

# Step 3: Kill any npm processes
echo "[RESET] Killing npm processes..."
wsl.exe -e bash -c 'killall -9 npm 2>/dev/null || true'
sleep 1

# Step 4: Clear PID files
echo "[RESET] Clearing PID files..."
rm -f .miner_pids .miners_pids .extra_miners_pids .extra_miners_registry.json 2>/dev/null || true

# Step 5: Clear logs
echo "[RESET] Clearing logs..."
rm -rf logs 2>/dev/null || true
mkdir -p logs
touch logs/.gitkeep

# Step 6: Clear any port locks
echo "[RESET] Clearing ports (8332, 8888)..."
wsl.exe -e bash -c 'lsof -ti:8332,8888 | xargs kill -9 2>/dev/null || true' > /dev/null 2>&1
sleep 2

echo ""
echo "╔══════════════════════════════════════════════════════════════════════════╗"
echo "║                     ✅ RESET COMPLETE                                   ║"
echo "╚══════════════════════════════════════════════════════════════════════════╝"
echo ""

echo "✓ All Node processes killed"
echo "✓ All omnibus-node processes killed"
echo "✓ All PID files cleared"
echo "✓ All logs cleared"
echo "✓ Ports freed (8332, 8888)"
echo ""

echo "🚀 Ready to start fresh!"
echo ""
echo "Next commands:"
echo "  bash start-all.sh 50      # Start with 50 miners"
echo "  bash start-all.sh         # Start with default 10 miners"
echo ""
