#!/bin/bash

# OmniBus Miner Keepalive Monitor
# Detects dead miners and removes them from registry
# Run in background: nohup bash monitor-miners.sh > logs/monitor.log 2>&1 &

PIDS_FILE=".extra_miners_pids"
LOGS_DIR="./logs"
POOL_HOST="127.0.0.1"
POOL_PORT=8332
CHECK_INTERVAL=30  # seconds

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}[MONITOR] Miner Keepalive Monitor started${NC}"
echo "[MONITOR] Check interval: ${CHECK_INTERVAL}s"
echo "[MONITOR] Monitoring file: $PIDS_FILE"
echo ""

while true; do
  TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
  DEAD_COUNT=0
  ALIVE_COUNT=0

  if [ -f "$PIDS_FILE" ]; then
    while IFS= read -r PID; do
      if [ -n "$PID" ]; then
        if ! ps -p "$PID" > /dev/null 2>&1; then
          echo -e "${RED}[$TIMESTAMP] DEAD: miner PID $PID${NC}"
          ((DEAD_COUNT++))
        else
          ((ALIVE_COUNT++))
        fi
      fi
    done < "$PIDS_FILE"
  fi

  # Clean up dead PIDs
  if [ $DEAD_COUNT -gt 0 ]; then
    echo -e "${RED}[$TIMESTAMP] Found $DEAD_COUNT dead miners, cleaning up...${NC}"

    # Rebuild PIDs file with only alive processes
    TEMP_FILE="${PIDS_FILE}.tmp"
    > "$TEMP_FILE"

    while IFS= read -r PID; do
      if [ -n "$PID" ] && ps -p "$PID" > /dev/null 2>&1; then
        echo "$PID" >> "$TEMP_FILE"
      fi
    done < "$PIDS_FILE"

    mv "$TEMP_FILE" "$PIDS_FILE"
    echo -e "${GREEN}[$TIMESTAMP] Cleanup complete. Alive: $ALIVE_COUNT${NC}"
  fi

  # Get pool status
  POOL_RESP=$(curl -s http://$POOL_HOST:$POOL_PORT -X POST \
    -H "Content-Type: application/json" \
    -d '{"jsonrpc":"2.0","method":"getpoolstats","params":[],"id":1}' 2>/dev/null || echo "{}")

  ACTIVE=$(echo "$POOL_RESP" | grep -o '"activeMiningMiners":[0-9]*' | cut -d: -f2)

  echo -e "${YELLOW}[$TIMESTAMP] Pool: $ACTIVE active | Local: $ALIVE_COUNT alive${NC}"

  sleep $CHECK_INTERVAL
done
