# OmniBus Mining Pool - Troubleshooting Guide

## Issue: Showing 110 Miners Even After Fresh Start

**Problem:** You started `bash start-genesis.sh` expecting 10 miners, but see 110.

**Cause:** Old miner processes still running from previous tests.

**Solution:**

```bash
# 1. Stop everything
bash stop-all.sh

# 2. Verify port is free
lsof -i :8332

# 3. Start fresh
bash start-genesis.sh
```

---

## Issue: Port 8332 Already in Use

**Error:**
```
Error: listen EADDRINUSE: address already in use 127.0.0.1:8332
```

**Solution:**

```bash
# Kill process on port 8332
lsof -ti :8332 | xargs -r kill -9

# Wait 2 seconds
sleep 2

# Start pool
node ./rpc-server.js
```

---

## Issue: Miners Won't Register

**Error:**
```
[MINER] ✗ Registration failed: Pool not running
```

**Solution:**

```bash
# Check if pool is running
ps aux | grep rpc-server.js

# If not, start it
node ./rpc-server.js > logs/pool.log 2>&1 &

# Verify it's listening
curl http://127.0.0.1:8332 -d '...'
```

---

## Issue: Rewards Not Increasing

**Problem:** Balances stay at 0 or don't change.

**Cause:**
1. Pool not mining (no active miners)
2. Miners not registered
3. Network issue

**Debug Steps:**

```bash
# 1. Check if pool has active miners
curl -s http://127.0.0.1:8332 \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"getpoolstats","params":[],"id":1}' | grep -o "activeMiningMiners":[0-9]*

# 2. Check miner logs
tail logs/miner-0.log
tail logs/extra-miner-10.log

# 3. Check if miner client registered successfully
grep "Successfully registered" logs/miner-*.log
```

---

## Issue: Frontend Not Updating in Real-Time

**Problem:** Web explorer shows stale data.

**Cause:**
1. Frontend caches data
2. RPC endpoint not responding fast enough
3. Browser cache

**Solution:**

```bash
# 1. Hard refresh browser
Ctrl+Shift+R (or Cmd+Shift+R on Mac)

# 2. Check RPC is responsive
curl -s http://127.0.0.1:8332 \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"getblockcount","params":[],"id":1}'

# 3. Restart pool
bash stop-all.sh
sleep 2
node ./rpc-server.js > logs/pool.log 2>&1 &
```

---

## Complete Cleanup & Reset

**To start completely fresh:**

```bash
# Step 1: Stop everything
bash stop-all.sh

# Step 2: Kill any lingering processes
pkill -9 -f node 2>/dev/null || true

# Step 3: Wait for port to free
sleep 3

# Step 4: Verify port is free
lsof -i :8332 || echo "✓ Port 8332 is free"

# Step 5: Remove old logs and PIDs
rm -f logs/*.log .miners_pids .extra_miners_pids

# Step 6: Start fresh
bash start-genesis.sh
```

---

## Quick Status Check

```bash
# Is pool running?
curl -s http://127.0.0.1:8332 \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"getpoolstats","params":[],"id":1}' 2>/dev/null && echo "✓ Pool running" || echo "✗ Pool not responding"

# How many miners?
curl -s http://127.0.0.1:8332 \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"getminers","params":[],"id":1}' 2>/dev/null | grep -o '"id"' | wc -l

# What block height?
curl -s http://127.0.0.1:8332 \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"getblockcount","params":[],"id":1}' 2>/dev/null
```

---

## Log Files Location

```
logs/
  ├── pool.log              # Pool mining activity
  ├── genesis_launch.log    # Genesis miner startup
  ├── extra_launch.log      # Extra miner startup
  ├── miner-0.log           # Individual miner logs
  ├── miner-1.log
  ├── extra-miner-10.log
  └── ...
```

**View logs in real-time:**

```bash
tail -f logs/pool.log              # Pool mining
tail -f logs/miner-0.log           # Specific miner
tail -f logs/extra-miner-10.log    # Extra miner
```

---

## Performance Checklist

- [ ] Pool starts without errors
- [ ] Miners register within 5 seconds
- [ ] Blocks mining every 2 seconds (blockHeight increasing)
- [ ] Miner balances increasing
- [ ] Adding 100 extra miners works
- [ ] All miners have nearly equal balances (adjusted for join time)
- [ ] No lingering processes after `stop-all.sh`

---

## Still Having Issues?

1. Check the logs first: `tail logs/pool.log`
2. Verify processes: `pgrep -f "rpc-server\|miner-client" -l`
3. Check port: `lsof -i :8332`
4. Full reset: See "Complete Cleanup & Reset" section
5. Check POOL.md for API reference

