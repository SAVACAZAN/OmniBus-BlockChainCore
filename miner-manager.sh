#!/bin/bash

# OmniBus Miner Manager - Dynamic Control
# Usage: bash miner-manager.sh [command] [count]
# Commands: start 100, stop 50, status, killall

set -e

PIDS_FILE=".extra_miners_pids"
LOGS_DIR="./logs"
POOL_HOST="127.0.0.1"
POOL_PORT=8332
CURRENT_EXTRA_MINERS=0

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Load current extra miner count
load_current_count() {
  if [ -f "$PIDS_FILE" ]; then
    CURRENT_EXTRA_MINERS=$(wc -l < "$PIDS_FILE" | tr -d ' ')
  fi
}

# Get actual running processes
get_running_count() {
  RUNNING=0
  if [ -f "$PIDS_FILE" ]; then
    while IFS= read -r PID; do
      if [ -n "$PID" ] && ps -p "$PID" > /dev/null 2>&1; then
        ((RUNNING++))
      fi
    done < "$PIDS_FILE"
  fi
  echo $RUNNING
}

# Start N extra miners
start_miners() {
  local count=$1
  if [ "$count" -gt 200 ]; then
    echo -e "${RED}[ERROR] Max 200 miners allowed${NC}"
    exit 1
  fi

  load_current_count
  local running=$(get_running_count)

  echo -e "${GREEN}[STARTING] $count extra miners...${NC}"
  mkdir -p "$LOGS_DIR"

  # If PIDs file doesn't exist, create it
  if [ ! -f "$PIDS_FILE" ]; then
    > "$PIDS_FILE"
  fi

  local start_id=$((10 + running))
  local end_id=$((9 + running + count))

  for i in $(seq $start_id $end_id); do
    local MINER_ID="miner-$i"
    local LOG_FILE="$LOGS_DIR/extra-miner-${i}.log"

    node ./miner-client.js "$MINER_ID" "ExtraMiner-$i" "ob_omni_extra${i}xxx" 1000 \
      > "$LOG_FILE" 2>&1 &

    local PID=$!
    echo "$PID" >> "$PIDS_FILE"

    if [ $((($i - 9) % 20)) -eq 0 ]; then
      echo -e "${GREEN}  ✓ Started miners 10-$i/$count${NC}"
    fi

    sleep 0.02
  done

  sleep 3
  echo -e "${GREEN}[SUCCESS] $count extra miners launched${NC}"
  status_miners
}

# Stop N extra miners
stop_miners() {
  local count=$1
  if [ -z "$count" ]; then
    count=$(get_running_count)
  fi

  if [ $count -eq 0 ]; then
    echo -e "${YELLOW}[INFO] No extra miners running${NC}"
    return
  fi

  echo -e "${RED}[STOPPING] $count extra miners...${NC}"

  local stopped=0
  if [ -f "$PIDS_FILE" ]; then
    while IFS= read -r PID; do
      if [ -n "$PID" ] && ps -p "$PID" > /dev/null 2>&1; then
        kill -9 "$PID" 2>/dev/null
        echo -e "${RED}  ✗ Killed miner (PID: $PID)${NC}"
        ((stopped++))
        if [ $stopped -ge $count ]; then
          break
        fi
      fi
    done < "$PIDS_FILE"
  fi

  > "$PIDS_FILE"
  echo -e "${RED}[SUCCESS] Stopped $stopped extra miners${NC}"
}

# Show status
status_miners() {
  echo ""
  echo "╔════════════════════════════════════════════════════════════╗"
  echo "║          OmniBus Miner Status                              ║"
  echo "╚════════════════════════════════════════════════════════════╝"
  echo ""

  # Check pool
  local pool_status=$(curl -s http://$POOL_HOST:$POOL_PORT -X POST \
    -H "Content-Type: application/json" \
    -d '{"jsonrpc":"2.0","method":"getpoolstats","params":[],"id":1}' 2>/dev/null || echo "{}")

  local registered=$(echo "$pool_status" | grep -o '"registeredMiners":[0-9]*' | cut -d: -f2)
  local active=$(echo "$pool_status" | grep -o '"activeMiningMiners":[0-9]*' | cut -d: -f2)

  echo -e "Pool Status:"
  echo -e "  Registered: $registered"
  echo -e "  ${GREEN}Active: $active${NC}"
  echo ""

  local running=$(get_running_count)
  echo -e "Extra Miners:"
  echo -e "  ${GREEN}Running: $running${NC}"
  echo -e "  PIDs file: $PIDS_FILE"
  echo ""
}

# Show help
show_help() {
  echo ""
  echo "╔════════════════════════════════════════════════════════════╗"
  echo "║     OmniBus Miner Manager - Dynamic Control                ║"
  echo "╚════════════════════════════════════════════════════════════╝"
  echo ""
  echo "Usage: bash miner-manager.sh [command] [count]"
  echo ""
  echo "Commands:"
  echo "  start [N]      - Start N extra miners (max 200)"
  echo "  stop [N]       - Stop N extra miners"
  echo "  status         - Show current status"
  echo "  killall        - Kill all extra miners"
  echo ""
  echo "Examples:"
  echo "  bash miner-manager.sh start 100    # Start 100 miners"
  echo "  bash miner-manager.sh stop 50      # Stop 50 miners"
  echo "  bash miner-manager.sh status       # Show status"
  echo "  bash miner-manager.sh killall      # Kill all extra miners"
  echo ""
}

# Main
case "${1:-status}" in
  start)
    if [ -z "$2" ]; then
      echo -e "${RED}[ERROR] Please specify count: bash miner-manager.sh start 100${NC}"
      exit 1
    fi
    start_miners "$2"
    ;;
  stop)
    stop_miners "$2"
    status_miners
    ;;
  status)
    status_miners
    ;;
  killall)
    stop_miners 999
    ;;
  *)
    show_help
    exit 1
    ;;
esac

echo ""
