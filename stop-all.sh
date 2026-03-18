#!/bin/bash

# OmniBus Mining Pool - Stop All Processes
# Kills pool and all miners cleanly

echo ""
echo "╔════════════════════════════════════════════════════════════╗"
echo "║           Stopping OmniBus Mining Pool...                  ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""

# Kill all miner-client processes
echo "[STOP] Killing miner clients..."
pkill -9 -f "miner-client.js" 2>/dev/null || true

# Kill all RPC server processes
echo "[STOP] Killing pool server..."
pkill -9 -f "rpc-server.js" 2>/dev/null || true

# Wait for processes to die
sleep 2

# Clean up PIDs
echo "[STOP] Cleaning up PID files..."
rm -f .miners_pids .extra_miners_pids

# Verify
if pgrep -f "miner-client\|rpc-server" > /dev/null 2>&1; then
  echo "[STOP] ✗ Some processes still running"
  ps aux | grep -E "miner-client|rpc-server" | grep -v grep
else
  echo "[STOP] ✓ All processes stopped"
fi

echo ""
echo "[STOP] Cleanup complete!"
echo ""
echo "To start fresh:"
echo "  bash start-genesis.sh"
echo ""
