# OmniBus Mining Pool - Quick Start Guide

## 🚀 3-Step Network Bootstrap

### Step 1: Start Genesis (10 miners + Pool)

```bash
cd /home/kiss/OmniBus-BlockChainCore
bash start-genesis.sh
```

**What happens:**
```
✓ Generates 10 miner wallets with BIP-39 seeds
✓ Starts mining pool on port 8332
✓ Launches 10 miners (miner-0 to miner-9)
✓ Mining begins immediately

[GENESIS] ✓ Pool started and listening on 127.0.0.1:8332
[MINER] ✓ Successfully registered!
[MINER] Miner ID: miner-0
[MINER] Sending keepalive every 5 seconds...
[POOL] ✓ Miner joined: Miner-0 (1000 H/s)
[POOL] ✓ Miner joined: Miner-1 (1000 H/s)
...
```

**Pool will mine automatically:**
- Block #1 (50 OMNI ÷ 10 miners = 5 OMNI each)
- Block #2 (50 OMNI ÷ 10 miners = 5 OMNI each)
- ... continuing indefinitely

---

### Step 2: Scale Test (Add 100 Extra Miners)

**In a new terminal:**

```bash
cd /home/kiss/OmniBus-BlockChainCore
bash launch-extra-miners.sh 100
```

**What happens:**
```
[EXTRA] Generating wallets for 100 extra miners...
[EXTRA] ✓ Wallets generated
[EXTRA] Starting 100 miners...

[POOL] ✓ Miner joined: ExtraMiner-10 (1000 H/s)
[POOL] ✓ Miner joined: ExtraMiner-11 (1000 H/s)
...
[POOL] Pool has 110 registered miners (110 active)
```

**Reward distribution automatically adjusts:**
- Block #N (50 OMNI ÷ 110 miners = 0.4545 OMNI each)
- No code changes needed, pool adapts instantly

---

### Step 3: Monitor Network

**Check pool status:**

```bash
curl -s -X POST http://127.0.0.1:8332 \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"getpoolstats","params":[],"id":1}' | jq .
```

**Output:**
```json
{
  "version": "1.0",
  "status": "operational",
  "registeredMiners": 110,
  "activeMiningMiners": 110,
  "blockHeight": 2150,
  "totalRewards": 450000000000,
  "totalTransactions": 236500,
  "uptime": 45231
}
```

**View active miners:**

```bash
curl -s -X POST http://127.0.0.1:8332 \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"getminers","params":[],"id":1}' | jq '.[0:3]'
```

**Output (first 3):**
```json
[
  {
    "id": "miner-0",
    "name": "Miner-0",
    "address": "ob1qx787af2p22knzjlakn7ehz9r77p3ak2w...",
    "status": "mining",
    "hashrate": 1000,
    "balanceOmni": 450.0,
    "blocksMined": 450,
    "isActive": true
  },
  {
    "id": "miner-1",
    "name": "Miner-1",
    "address": "ob_omni_def456...",
    "status": "mining",
    "hashrate": 1000,
    "balanceOmni": 450.0,
    "blocksMined": 450,
    "isActive": true
  },
  ...
]
```

---

## 📊 Monitoring in Real-Time

### Pool Logs
```bash
tail -f logs/pool.log
```

### Miner Logs
```bash
tail -f logs/miner-0.log        # Genesis miner
tail -f logs/extra-miner-10.log # Extra miner
```

### Block Mining
```bash
# Watch blocks mined (every 2 seconds)
watch -n 0.5 'curl -s http://127.0.0.1:8332 -H "Content-Type: application/json" \
  -d "{\"jsonrpc\":\"2.0\",\"method\":\"getblockcount\",\"params\":[],\"id\":1}" | jq .result'
```

### Transaction Count
```bash
curl -s http://127.0.0.1:8332 -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"gettransactioncount","params":[],"id":1}' | jq .result
```

---

## 🎯 Key Concepts

### ✅ What Changed

| Before | After |
|--------|-------|
| 110 miners hardcoded in genesis-allocation.json | 0 miners at startup |
| Genesis file loaded, then never changed | Miners register dynamically |
| Can't test with different miner counts | Scale from 10 to 1000+ instantly |
| Pool restart needed for changes | Add/remove miners without restart |
| Unclear who gets rewards | Transparent: 50 OMNI ÷ active miners |

### ✅ How Rewards Work

```
Block Mined (every 2 seconds)
    ↓
Pool divides 50 OMNI equally
    ↓
110 active miners → each gets 0.4545 OMNI
    ↓
Stored as 110 coinbase transactions
    ↓
Each miner's balance increases by 0.4545 OMNI
    ↓
Total pool balance increases by 50 OMNI
```

### ✅ How Miner Discovery Works

```
Miner starts
    ↓
Calls: registerminer({id, name, address, hashrate})
    ↓
Pool adds to minerRegistry Map
    ↓
Pool adds to activeMinerSet
    ↓
Miner starts sending keepalive every 5 seconds
    ↓
Pool keeps resetting 30-second timeout
    ↓
If no keepalive for 30s → removed from activeMinerSet
    ↓
Rewards go to remaining miners instead
```

---

## 🔧 Common Commands

### Start Everything
```bash
bash start-genesis.sh           # Pool + 10 miners
```

### Add More Miners
```bash
bash launch-extra-miners.sh 50   # Add 50 more
bash launch-extra-miners.sh 100  # Add 100 more
bash launch-extra-miners.sh 1000 # Add 1000 (stress test)
```

### Stop All Miners
```bash
cat .miners_pids | xargs kill
cat .extra_miners_pids | xargs kill
```

### Stop Pool
```bash
kill $(pgrep -f "rpc-server.js")
```

### Check Miner Count
```bash
curl -s http://127.0.0.1:8332 \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"getminers","params":[],"id":1}' | jq 'length'
```

### Get Specific Miner Balance
```bash
curl -s http://127.0.0.1:8332 \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"getminerbalances","params":[],"id":1}' | jq '.[] | select(.minerName == "miner-0")'
```

---

## 📝 File Organization

```
Wallets (auto-generated):
  wallets/genesis_miners_10.json      ← BIP-39 seeds for genesis
  wallets/extra_miners_100.json       ← BIP-39 seeds for extra

Logs (real-time monitoring):
  logs/pool.log                       ← Pool mining activity
  logs/miner-0.log                    ← Individual miner logs
  logs/extra-miner-10.log             ← Extra miner logs

PID Files (for cleanup):
  .miners_pids                        ← PIDs of genesis miners
  .extra_miners_pids                  ← PIDs of extra miners

Source Code:
  rpc-server.js                       ← Mining pool (0 hardcoding)
  miner-client.js                     ← Miner executable
  create-wallet.js                    ← Wallet generator

Scripts:
  start-genesis.sh                    ← All-in-one bootstrap
  launch-extra-miners.sh              ← Scale up
  launch-pool-miners.sh               ← Generic launcher

Docs:
  POOL.md                             ← Full API reference
  QUICK_START.md                      ← This file
```

---

## 🧪 Testing Scenarios

### Scenario 1: Verify Equal Distribution (10 miners)

```bash
# Start genesis
bash start-genesis.sh

# Wait 30 seconds for blocks to mine
sleep 30

# Check all miners have equal balance
curl -s http://127.0.0.1:8332 \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"getminerbalances","params":[],"id":1}' | jq '.[] | .balanceOmni'
```

**Expected output:** All miners show same balance (e.g., 30.5 OMNI)

### Scenario 2: Dynamic Scaling (10 → 110 miners)

```bash
# Terminal 1: Start genesis
bash start-genesis.sh

# Wait a few blocks
sleep 10

# Terminal 2: Add 100 miners
bash launch-extra-miners.sh 100

# Watch reward per miner decrease
curl -s http://127.0.0.1:8332 \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"getminerbalances","params":[],"id":1}' | jq '.[0] | {name: .minerName, balance: .balanceOmni}'
```

**Observation:** New miners start at 0 OMNI, then gain ~0.4545 OMNI/block

### Scenario 3: Miner Disconnect & Failover

```bash
# Terminal 1: Start genesis
bash start-genesis.sh

# Terminal 2: Stop one miner
kill $(head -1 .miners_pids)

# Pool detects timeout (30s) and reallocates rewards

# Remaining 9 miners now get: 50 OMNI ÷ 9 = 5.555 OMNI/block
curl -s http://127.0.0.1:8332 \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"getminerstatus","params":[],"id":1}' | jq '.activeMiningMiners'
```

**Expected:** activeMiningMiners drops from 10 → 9, rewards increase for remaining

---

## 💡 Why This Design?

### Problem Solved
- ❌ Before: "ca la noi daor sunt harcodate nu?!" (everything is hardcoded!)
- ✅ After: Pool accepts miners dynamically, no restart needed

### Benefits
- **Zero Hardcoding**: Miners register at runtime
- **Scalable**: From 10 to 1000+ without code changes
- **Fair**: Automatic equal distribution
- **Resilient**: Automatic disconnect detection
- **Deterministic**: Every miner can verify their own rewards
- **Verifiable**: All wallets have BIP-39 seeds (exportable)

---

## 🚨 Troubleshooting

**"Pool won't start"**
```bash
# Check if port 8332 is in use
lsof -i :8332

# Kill any existing process
kill $(lsof -t -i :8332)

# Try again
bash start-genesis.sh
```

**"Miners won't register"**
```bash
# Check pool is running
curl http://127.0.0.1:8332 -d '...'

# Check logs
tail logs/pool.log
tail logs/miner-0.log
```

**"Balance not increasing"**
```bash
# Check blockCount increasing
curl ... getblockcount | jq .result

# Check miner is in active set
curl ... getminers | jq 'length'

# If 0: pool has no active miners (check logs)
```

---

## 📚 More Info

See [POOL.md](POOL.md) for:
- Complete RPC API reference
- Wallet generation details
- Reward distribution formulas
- BIP-39 mnemonic structure
- Performance metrics

---

**Ready?** → `bash start-genesis.sh` 🚀
