#!/bin/bash

# OmniBus Extra Miners - Stop Script
# Kills only the extra miners (miner-10+)

PIDS_FILE=".extra_miners_pids"

echo ""
echo "╔════════════════════════════════════════════════════════════╗"
echo "║          Stopping Extra Miners...                          ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""

# Check if PIDs file exists
if [ ! -f "$PIDS_FILE" ]; then
  echo "[STOP] ✗ No extra miners running (.extra_miners_pids not found)"
  exit 1
fi

# Count and kill PIDs
COUNT=$(wc -l < "$PIDS_FILE")
echo "[STOP] Found $COUNT extra miners to stop..."

while IFS= read -r PID; do
  if ps -p "$PID" > /dev/null 2>&1; then
    kill -9 "$PID" 2>/dev/null
    echo "[STOP] ✓ Killed miner (PID: $PID)"
  fi
done < "$PIDS_FILE"

# Clear the file
> "$PIDS_FILE"

echo ""
echo "╔════════════════════════════════════════════════════════════╗"
echo "✓ EXTRA MINERS STOPPED"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""
echo "[STOP] Genesis miners (miner-0 to miner-9) are still running"
echo ""
