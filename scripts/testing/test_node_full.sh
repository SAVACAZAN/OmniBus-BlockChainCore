#!/bin/bash
# test_node_full.sh — Full node integration test
# Porneste nodul, mineaza cateva blocuri, testeaza toate RPC endpoints
# Usage: bash scripts/testing/test_node_full.sh

set -e
cd "$(dirname "$0")/../.."

echo "============================================================"
echo "  OmniBus BlockChain — Full Node Integration Test"
echo "============================================================"
echo ""

# Clean previous test data
rm -f omnibus-chain.dat test-chain.dat 2>/dev/null

# Build
echo "[BUILD] Compiling..."
zig build 2>&1 | head -3
echo "[BUILD] OK"
echo ""

# Start node in background
echo "[START] Launching node..."
./zig-out/bin/omnibus-node.exe --mode miner --node-id test-node \
  --seed-host 127.0.0.1 --seed-port 9000 > /tmp/omnibus-test.log 2>&1 &
NODE_PID=$!
echo "[START] Node PID: $NODE_PID"

# Wait for RPC to be ready
echo "[WAIT] Waiting for RPC..."
for i in $(seq 1 15); do
  if curl -s http://127.0.0.1:8332 -d '{"jsonrpc":"2.0","method":"getblockcount","params":[],"id":0}' 2>/dev/null | grep -q "result"; then
    echo "[WAIT] RPC ready after ${i}s"
    break
  fi
  sleep 1
done

# Wait for blocks to be mined (difficulty 4, needs ~10-30s for first blocks)
echo "[MINE] Waiting for blocks to be mined..."
for i in $(seq 1 20); do
  BLOCKS=$(curl -s -X POST http://127.0.0.1:8332 -d '{"jsonrpc":"2.0","method":"getblockcount","params":[],"id":0}' 2>&1)
  COUNT=$(echo "$BLOCKS" | grep -o '"result":[0-9]*' | grep -o '[0-9]*')
  if [ "$COUNT" -gt "2" ]; then
    echo "[MINE] $COUNT blocks mined after ${i}s"
    break
  fi
  sleep 1
done

PASS=0
FAIL=0
TOTAL=0

run_test() {
  TOTAL=$((TOTAL + 1))
  local name="$1"
  local data="$2"
  local expect="$3"

  echo -n "  TEST $TOTAL: $name... "
  RESULT=$(curl -s -X POST http://127.0.0.1:8332 -d "$data" 2>&1)

  if echo "$RESULT" | grep -q "$expect"; then
    echo "PASS"
    PASS=$((PASS + 1))
  else
    echo "FAIL"
    echo "    Expected: $expect"
    echo "    Got: $RESULT"
    FAIL=$((FAIL + 1))
  fi
}

echo ""
echo "============================================================"
echo "  Running RPC Tests"
echo "============================================================"

# Basic chain
run_test "getblockcount" \
  '{"jsonrpc":"2.0","method":"getblockcount","params":[],"id":1}' \
  '"result":'

run_test "getbalance" \
  '{"jsonrpc":"2.0","method":"getbalance","params":[],"id":2}' \
  '"balance":'

run_test "getlatestblock" \
  '{"jsonrpc":"2.0","method":"getlatestblock","params":[],"id":3}' \
  '"hash":'

run_test "getstatus" \
  '{"jsonrpc":"2.0","method":"getstatus","params":[],"id":4}' \
  '"status":"running"'

run_test "getnetworkinfo" \
  '{"jsonrpc":"2.0","method":"getnetworkinfo","params":[],"id":5}' \
  '"omnibus-mainnet"'

run_test "getminerinfo" \
  '{"jsonrpc":"2.0","method":"getminerinfo","params":[],"id":6}' \
  '"status":"active"'

run_test "getmempoolsize (empty)" \
  '{"jsonrpc":"2.0","method":"getmempoolsize","params":[],"id":7}' \
  '"result":0'

# Block queries
run_test "getblock 0 (genesis)" \
  '{"jsonrpc":"2.0","method":"getblock","params":["0"],"id":8}' \
  '"height":0'

run_test "getblock 1 (first mined)" \
  '{"jsonrpc":"2.0","method":"getblock","params":["1"],"id":9}' \
  '"height":1'

run_test "getblocks range" \
  '{"jsonrpc":"2.0","method":"getblocks","params":[0, 3],"id":10}' \
  '"blocks":'

# Mining stats
run_test "getminerstats" \
  '{"jsonrpc":"2.0","method":"getminerstats","params":[],"id":11}' \
  '"totalMiners":'

run_test "getpoolstats" \
  '{"jsonrpc":"2.0","method":"getpoolstats","params":[],"id":12}' \
  '"blockRewardSAT":8333333'

# Transaction
run_test "sendtransaction" \
  '{"jsonrpc":"2.0","method":"sendtransaction","params":["ob_omni_test_receiver", 50000],"id":13}' \
  '"status":"accepted"'

sleep 1

run_test "getmempoolsize (after TX)" \
  '{"jsonrpc":"2.0","method":"getmempoolsize","params":[],"id":14}' \
  '"result":'

# Wait for TX to be mined
sleep 3

run_test "getaddressbalance receiver" \
  '{"jsonrpc":"2.0","method":"getaddressbalance","params":["ob_omni_test_receiver"],"id":15}' \
  '"balance":'

run_test "gettransactions" \
  '{"jsonrpc":"2.0","method":"gettransactions","params":[],"id":16}' \
  '"transactions":'

# Network
run_test "getsyncstatus" \
  '{"jsonrpc":"2.0","method":"getsyncstatus","params":[],"id":17}' \
  '"status":'

run_test "getpeers" \
  '{"jsonrpc":"2.0","method":"getpeers","params":[],"id":18}' \
  '"count":'

# Registration
run_test "registerminer" \
  '{"jsonrpc":"2.0","method":"registerminer","params":["ob_omni_new_miner", "miner-2"],"id":19}' \
  '"registered"'

# Error handling
run_test "unknown method" \
  '{"jsonrpc":"2.0","method":"nonexistent","params":[],"id":20}' \
  '"Method not found"'

run_test "invalid request (no method)" \
  '{"jsonrpc":"2.0","params":[],"id":21}' \
  '"Invalid request"'

# Cleanup
echo ""
echo "============================================================"
echo "  Stopping node..."
echo "============================================================"
kill $NODE_PID 2>/dev/null
wait $NODE_PID 2>/dev/null

# Persistence test
echo ""
echo "============================================================"
echo "  Persistence Test (restart node)"
echo "============================================================"
./zig-out/bin/omnibus-node.exe --mode miner --node-id test-node \
  --seed-host 127.0.0.1 --seed-port 9000 > /tmp/omnibus-test2.log 2>&1 &
NODE_PID2=$!
sleep 5

TOTAL=$((TOTAL + 1))
echo -n "  TEST $TOTAL: chain persisted after restart... "
BLOCKS=$(curl -s -X POST http://127.0.0.1:8332 -d '{"jsonrpc":"2.0","method":"getblockcount","params":[],"id":99}' 2>&1)
if echo "$BLOCKS" | grep -q '"result":[0-9]'; then
  COUNT=$(echo "$BLOCKS" | grep -o '"result":[0-9]*' | grep -o '[0-9]*')
  if [ "$COUNT" -gt "1" ]; then
    echo "PASS (restored $COUNT blocks)"
    PASS=$((PASS + 1))
  else
    echo "FAIL (only $COUNT blocks)"
    FAIL=$((FAIL + 1))
  fi
else
  echo "FAIL (no response)"
  FAIL=$((FAIL + 1))
fi

kill $NODE_PID2 2>/dev/null
wait $NODE_PID2 2>/dev/null

# Summary
echo ""
echo "============================================================"
echo "  TEST RESULTS"
echo "============================================================"
echo "  Total:  $TOTAL"
echo "  Passed: $PASS"
echo "  Failed: $FAIL"
echo "============================================================"

# Cleanup
rm -f omnibus-chain.dat 2>/dev/null

if [ $FAIL -eq 0 ]; then
  echo "  ALL TESTS PASSED!"
  exit 0
else
  echo "  SOME TESTS FAILED!"
  exit 1
fi
