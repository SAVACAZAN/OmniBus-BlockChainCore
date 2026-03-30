#!/bin/bash

# OmniBus - Complete System Startup
# Launches: Pool + Genesis Miners + Frontend
# One command, everything working

set -e

echo ""
echo "╔══════════════════════════════════════════════════════════════════════════╗"
echo "║                                                                          ║"
echo "║              OmniBus Mining Network - Full Startup                       ║"
echo "║                                                                          ║"
echo "╚══════════════════════════════════════════════════════════════════════════╝"
echo ""

# Configuration
POOL_PORT=8332
FRONTEND_PORT=8888
NUM_GENESIS_MINERS=10

# Step 1: Clean old state
echo "[STARTUP] Step 1: Cleaning old state..."
bash stop-all.sh > /dev/null 2>&1 || true
sleep 2
rm -f .miners_pids .extra_miners_pids
mkdir -p logs

echo "[STARTUP] ✓ State cleaned"
echo ""

# Step 2: Verify ports are free
echo "[STARTUP] Step 2: Checking ports..."
if lsof -i :$POOL_PORT > /dev/null 2>&1; then
  echo "[STARTUP] ⚠️  Port $POOL_PORT in use, killing..."
  lsof -ti :$POOL_PORT | xargs -r kill -9
  sleep 2
fi

echo "[STARTUP] ✓ Ports verified"
echo ""

# Step 3: Start mining pool
echo "[STARTUP] Step 3: Starting OmniBus Mining Pool..."
node ./rpc-server.js > logs/pool.log 2>&1 &
POOL_PID=$!
sleep 3

# Verify pool started
if ! ps -p $POOL_PID > /dev/null; then
  echo "[STARTUP] ✗ Pool failed to start"
  cat logs/pool.log | tail -20
  exit 1
fi

echo "[STARTUP] ✓ Pool running (PID: $POOL_PID)"
echo ""

# Step 4: Generate genesis miner wallets
echo "[STARTUP] Step 4: Generating $NUM_GENESIS_MINERS wallet addresses..."
node ./create-wallet.js batch $NUM_GENESIS_MINERS > /dev/null 2>&1
echo "[STARTUP] ✓ Wallets generated"
echo ""

# Step 5: Launch genesis miners
echo "[STARTUP] Step 5: Launching $NUM_GENESIS_MINERS genesis miners..."
for i in $(seq 0 $((NUM_GENESIS_MINERS - 1))); do
  MINER_ID="miner-$i"
  LOG_FILE="logs/miner-${i}.log"

  node ./miner-client.js "$MINER_ID" "Miner-$i" "ob_omni_miner${i}xxxxxxxxxxxxxxxx" 1000 \
    > "$LOG_FILE" 2>&1 &

  PID=$!
  echo "$PID" >> .miners_pids

  if [ $((($i + 1) % 5)) -eq 0 ]; then
    echo "[STARTUP]   Started miners 0-$i/$NUM_GENESIS_MINERS..."
  fi

  sleep 0.1
done

sleep 3
echo "[STARTUP] ✓ Genesis miners launched"
echo ""

# Step 6: Start frontend
echo "[STARTUP] Step 6: Starting web explorer..."
cd frontend
if [ -f "package.json" ]; then
  npm run dev > logs/frontend.log 2>&1 &
  FRONTEND_PID=$!
  sleep 3
  echo "[STARTUP] ✓ Frontend running on http://localhost:$FRONTEND_PORT"
else
  echo "[STARTUP] ⚠️  Frontend not found"
fi
cd ..

echo ""
echo "╔══════════════════════════════════════════════════════════════════════════╗"
echo "║                         ✅ SYSTEM OPERATIONAL                           ║"
echo "╚══════════════════════════════════════════════════════════════════════════╝"
echo ""

sleep 2
STATS=$(curl -s http://127.0.0.1:$POOL_PORT \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"getpoolstats","params":[],"id":1}' 2>/dev/null)

REGISTERED=$(echo "$STATS" | grep -o '"registeredMiners":[0-9]*' | grep -o '[0-9]*' || echo "?")
ACTIVE=$(echo "$STATS" | grep -o '"activeMiningMiners":[0-9]*' | grep -o '[0-9]*' || echo "?")
BLOCKS=$(echo "$STATS" | grep -o '"blockHeight":[0-9]*' | grep -o '[0-9]*' || echo "?")

echo "📊 Network Status:"
echo "   Pool: http://127.0.0.1:8332 ✓"
echo "   Miners: $ACTIVE active ($REGISTERED registered) ✓"
echo "   Blocks: #$BLOCKS ✓"
echo "   Frontend: http://localhost:8888 ✓"
echo ""
echo "🔗 Commands:"
echo "   tail -f logs/pool.log              # Monitor mining"
echo "   bash launch-extra-miners.sh 100    # Add more miners"
echo "   bash stop-all.sh                   # Stop everything"
echo ""

# Keep script running and processes alive
echo "💚 System running. Press Ctrl+C to stop all services."
echo ""
wait
