#!/bin/bash

# OmniBus Blockchain - THE ONLY SCRIPT YOU NEED
# Usage: bash run.sh [miners]  or  bash run.sh stop  or  bash run.sh reset

EXTRA_MINERS=${1:-10}
POOL_HOST="127.0.0.1"
POOL_PORT=8332
FRONTEND_PORT=8888

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Command check
if [ "$1" = "stop" ] || [ "$1" = "stop-all" ]; then
  echo -e "${RED}Stopping everything...${NC}"
  killall -9 node omnibus-node npm 2>/dev/null || true
  echo -e "${GREEN}✓ Stopped${NC}"
  exit 0
fi

if [ "$1" = "reset" ] || [ "$1" = "clean" ]; then
  echo -e "${RED}Resetting system...${NC}"
  killall -9 node omnibus-node npm 2>/dev/null || true
  sleep 1
  rm -f .miner_pids .miners_pids .extra_miners_pids .extra_miners_registry.json 2>/dev/null || true
  rm -rf logs
  mkdir -p logs
  echo -e "${GREEN}✓ Reset complete${NC}"
  echo -e "${YELLOW}Now run: bash run.sh 50${NC}"
  exit 0
fi

if [ "$1" = "status" ]; then
  curl -s http://$POOL_HOST:$POOL_PORT -X POST \
    -H "Content-Type: application/json" \
    -d '{"jsonrpc":"2.0","method":"getminerconnections","params":[],"id":1}' 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin).get('result',{}); print(f'Active: {d.get(\"active\",0)}/{d.get(\"total\",0)} miners')" 2>/dev/null || echo "RPC not responding"
  exit 0
fi

# Validate miner count
if ! [[ $EXTRA_MINERS =~ ^[0-9]+$ ]] || [ $EXTRA_MINERS -gt 200 ]; then
  echo -e "${RED}Invalid miner count. Max 200.${NC}"
  exit 1
fi

# STARTUP
echo ""
echo "╔══════════════════════════════════════════════════════════════════════════╗"
echo "║                     OmniBus Blockchain Startup                           ║"
echo "╚══════════════════════════════════════════════════════════════════════════╝"
echo ""

# Kill old processes
echo -e "${YELLOW}Cleaning up...${NC}"
killall -9 node omnibus-node npm 2>/dev/null || true
sleep 2

mkdir -p logs

# Start RPC Server
echo -e "${BLUE}Starting RPC Server...${NC}"
node rpc-server.js > logs/rpc-server.log 2>&1 &
RPC_PID=$!

# Wait for RPC to be ready
for i in {1..10}; do
  if curl -s http://$POOL_HOST:$POOL_PORT -X POST -H "Content-Type: application/json" -d '{"jsonrpc":"2.0","method":"getpoolstats","params":[],"id":1}' > /dev/null 2>&1; then
    echo -e "${GREEN}✓ RPC ready on http://$POOL_HOST:$POOL_PORT${NC}"
    break
  fi
  sleep 1
  echo -n "."
done

# Start Frontend
echo -e "${BLUE}Starting Frontend...${NC}"
(cd frontend && npm run dev > ../logs/frontend.log 2>&1) &
FRONTEND_PID=$!
sleep 6
echo -e "${GREEN}✓ Frontend on http://localhost:$FRONTEND_PORT${NC}"

# Start Miners
echo -e "${BLUE}Starting $EXTRA_MINERS extra miners...${NC}"
bash miner-manager.sh start $EXTRA_MINERS > /dev/null 2>&1
echo -e "${GREEN}✓ Miners running${NC}"

# Summary
echo ""
echo "╔══════════════════════════════════════════════════════════════════════════╗"
echo "║                         ✅ RUNNING                                      ║"
echo "╚══════════════════════════════════════════════════════════════════════════╝"
echo ""
echo -e "${GREEN}📊 Services:${NC}"
echo "  • RPC:      http://$POOL_HOST:$POOL_PORT"
echo "  • Frontend: http://localhost:$FRONTEND_PORT"
echo "  • Miners:   $EXTRA_MINERS extra (+ 10 genesis)"
echo ""
echo -e "${YELLOW}Commands (in another terminal):${NC}"
echo "  bash run.sh status          # Check miners"
echo "  bash run.sh start 50        # Add 50 miners"
echo "  bash run.sh stop            # Stop everything"
echo "  bash run.sh reset           # Reset & start fresh"
echo ""
echo -e "${BLUE}Browser:${NC} http://localhost:$FRONTEND_PORT"
echo ""
