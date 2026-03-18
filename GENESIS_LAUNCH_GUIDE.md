# Complete Genesis Launch Guide

**Date:** March 18, 2026
**Status:** ✅ Ready for Production
**Features:** One-Click Genesis + Automatic Wallet Generation + Token Distribution

---

## 🎯 What Happens When You Launch Genesis?

This guide explains the **complete initialization flow** for OmniBus blockchain genesis:

1. **Automatic Wallet Generation** – Creates unique addresses for all 10 miners
2. **Token Distribution** – Allocates 21M OMNI equally across miners
3. **Network Startup** – Launches seed node, RPC, frontend, and 10 miners
4. **Genesis Ready** – When 3+ miners connect, genesis is ready to begin
5. **Mining Starts** – Click "Start Genesis" to mine the first block

---

## 📋 Quick Start (3 Commands)

### **Windows:**
```powershell
# Make script executable
Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope CurrentUser

# Run startup script
.\start-omnibus-full.ps1

# Opens Genesis Countdown UI automatically
```

### **Linux/macOS:**
```bash
chmod +x start-omnibus-full.sh
./start-omnibus-full.sh
```

Then open: **http://localhost:3000/genesis-countdown**

---

## 🏗️ Architecture: How Genesis Works

### **1. Wallet Generation**

```
Startup Script
    ↓
Generate 10 Unique Wallets
    ├─ miner-0 → ob_omni_miner01xxxxxxxxxxxxx
    ├─ miner-1 → ob_omni_miner02xxxxxxxxxxxxx
    ├─ miner-2 → ob_omni_miner03xxxxxxxxxxxxx
    └─ ... (miner-9)
    ↓
Save to: wallets/genesis-allocation.json
```

**Each miner wallet includes:**
- Unique ID (0-9)
- Unique address (5 PQ algorithm domains)
- Genesis allocation (2.1M OMNI each)
- Initial balance (set at creation)

### **2. Token Distribution**

```
Total Supply: 21,000,000 OMNI
    ↓
Divided equally:
    21,000,000 ÷ 10 = 2,100,000 OMNI per miner
    ↓
Each miner receives:
    - 2.1M OMNI (210,000,000,000 SAT)
    - In genesis block (block height 0)
    - Non-spendable until genesis complete
    ↓
After genesis:
    - Miners can spend/trade tokens
    - Mining rewards accrue
    - Smart contracts available
```

### **3. Network Topology**

```
Seed Node (Port 9000)
    ├─ Miner 0 (hashrate: 1000 H/s)
    ├─ Miner 1 (hashrate: 1000 H/s)
    ├─ Miner 2 (hashrate: 1000 H/s)
    ├─ ... Miner 9
    └─ Total: 10,000 H/s
    ↓
RPC Server (Port 8332)
    └─ getGenesisStatus, getMiners, startGenesis
    ↓
Frontend (Port 3000)
    └─ Genesis Countdown UI
        └─ Displays miner status, ready to start
```

---

## 📊 Step-by-Step Flow

### **Step 1: Script Starts**
```
✅ Check omnibus-node exists
✅ Create logs/, wallets/, genesis/ directories
✅ Generate 10 miner wallets
   - Save to wallets/genesis-allocation.json
   - Display each miner's address + allocation
```

### **Step 2: Seed Node Launches**
```
✅ Start: ./omnibus-node --mode seed --port 9000
✅ Status: Listening for miners...
✅ Log: logs/seed-node.log
```

### **Step 3: RPC Server Launches**
```
✅ Start: ./omnibus-node --mode rpc --port 8332
✅ Status: Ready for API calls
✅ Log: logs/rpc-server.log
```

### **Step 4: Frontend Launches**
```
✅ Start: npm start (in frontend/)
✅ Opens: http://localhost:3000
✅ Genesis: http://localhost:3000/genesis-countdown
```

### **Step 5: 10 Miners Launch** (one every 500ms)
```
✅ Miner 1: ./omnibus-node --mode miner --node-id miner-0 --seed-host 127.0.0.1 --seed-port 9000
✅ Miner 2: ./omnibus-node --mode miner --node-id miner-1 ...
...
✅ Miner 10: ./omnibus-node --mode miner --node-id miner-9 ...
```

Each miner:
- Connects to seed node
- Receives its wallet address
- Starts mining (1000 H/s)
- Reports status every 2 seconds

### **Step 6: Genesis Countdown UI Updates**
```
Miners Connected: 0/10 → 1/10 → 2/10 → 3/10 → ... → 10/10
Genesis Ready: ⏳ Waiting → ✓ Ready
Start Button: Disabled → Enabled (when ≥3 miners)
```

### **Step 7: User Clicks "Start Genesis"**
```
✅ RPC Call: startGenesis()
✅ Blockchain: Mine first block (block height 0)
✅ Reward: 50 OMNI distributed
✅ Status: Mining blocks every 1 second
```

### **Step 8: First Blocks Appear**
```
Block 0: mined by miner-2 (50 OMNI reward)
Block 1: mined by miner-5 (50 OMNI reward)
Block 2: mined by miner-1 (50 OMNI reward)
...
Status: ✅ Genesis Complete!
```

---

## 💰 Token Economics at Genesis

### **Supply Distribution**
```
Total OMNI Supply: 21,000,000
├─ Genesis Allocation: 21,000,000 (100%)
│  ├─ Miner 0: 2,100,000 OMNI
│  ├─ Miner 1: 2,100,000 OMNI
│  ├─ Miner 2: 2,100,000 OMNI
│  ├─ ...
│  └─ Miner 9: 2,100,000 OMNI
└─ Total: 21,000,000 OMNI distributed

Mining Rewards (post-genesis):
├─ Block Reward: 50 OMNI per block
├─ Blocks per day: 86,400
├─ Daily emission: 4,320,000 OMNI
├─ Halving: Every 210,000 blocks (~2.43 years)
└─ Total forever: 21,000,000 OMNI (fixed)
```

### **Address Formats**

Each miner has 5 unique addresses (post-quantum cryptography):

```
1. ob_omni_miner01xxxxxxxxxxxxx (Dilithium-5 + Kyber-768, 256-bit)
2. ob_k1_miner01xxxxxxxxxxxxxxx (Kyber-768, 256-bit)
3. ob_f5_miner01xxxxxxxxxxxxxxx (Falcon-512, 192-bit)
4. ob_d5_miner01xxxxxxxxxxxxxxx (Dilithium-5, 256-bit)
5. ob_s3_miner01xxxxxxxxxxxxxxx (SPHINCS+, 128-bit)

Primary address (for mining rewards):
→ ob_omni_miner01xxxxxxxxxxxxx (Dilithium-5 + Kyber-768)
```

---

## 📁 Generated Files

### **After Running Script**

```
OmniBus-BlockChainCore/
├─ logs/
│  ├─ seed-node.log          (Seed node output)
│  ├─ rpc-server.log         (RPC server output)
│  ├─ frontend.log           (Frontend output)
│  ├─ light-miner-01.log     (Miner 1 output)
│  ├─ light-miner-02.log     (Miner 2 output)
│  └─ ... (all 10 miners)
│
├─ wallets/
│  └─ genesis-allocation.json (Token distribution)
│
└─ genesis/
   └─ (reserved for genesis block data)
```

### **wallets/genesis-allocation.json Structure**

```json
{
  "genesis_timestamp": "2026-03-18T12:34:56Z",
  "total_supply_omni": 21000000,
  "miners": [
    {
      "miner_id": 0,
      "miner_name": "miner-0",
      "address": "ob_omni_miner01xxxxxxxxxxxxx",
      "allocated_omni": 2100000,
      "allocated_sat": 210000000000,
      "status": "genesis_allocated"
    },
    {
      "miner_id": 1,
      "miner_name": "miner-1",
      "address": "ob_omni_miner02xxxxxxxxxxxxx",
      "allocated_omni": 2100000,
      "allocated_sat": 210000000000,
      "status": "genesis_allocated"
    },
    ...
  ]
}
```

---

## 🔄 Real-Time Monitoring

### **Genesis Countdown UI** (Auto-updates every 2 seconds)

Shows:
- **Blockchain Status** – initializing → waiting → ready → mining
- **Miners Connected** – 0/10 → 3/10 → 10/10 (with status badges)
- **Individual Miner Cards** – Each shows:
  - Status (🟢 mining, 🟡 connecting, 🔴 offline)
  - Blocks mined
  - Shares submitted/accepted
  - Hashrate
  - Uptime
- **Network Stats** – Total hashrate, block height, difficulty
- **Start Button** – Enabled when genesis ready

### **Log File Monitoring**

```bash
# Watch seed node
tail -f logs/seed-node.log

# Watch miner 1
tail -f logs/light-miner-01.log

# Watch all miners
tail -f logs/light-miner-*.log

# Watch RPC
tail -f logs/rpc-server.log
```

### **RPC API Status**

```bash
# Check genesis status
curl -X POST http://localhost:8332 \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"getGenesisStatus","params":[],"id":1}'

# Returns:
{
  "result": {
    "status": "mining",
    "blockCount": 5,
    "connectedMiners": 10,
    "genesisStarted": true,
    "genesisReady": true
  }
}
```

---

## ⚠️ Troubleshooting

### **Problem: Script won't run (PowerShell)**
```powershell
Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope CurrentUser
# Then try again
.\start-omnibus-full.ps1
```

### **Problem: Port already in use**
```bash
# Kill existing processes
pkill -f omnibus-node
pkill -f "npm start"

# Wait 2 seconds, then restart
sleep 2
./start-omnibus-full.ps1  # Windows: .\start-omnibus-full.ps1
```

### **Problem: Miners won't connect**
1. Check `logs/seed-node.log` for errors
2. Verify seed node is running: `netstat -an | grep 9000`
3. Check firewall (port 9000 should be open)

### **Problem: Genesis won't start even with 3+ miners**
1. Open browser console (F12)
2. Check for errors
3. Verify RPC server is running: `http://localhost:8332`
4. Check `logs/rpc-server.log`

### **Problem: "omnibus-node.exe not found"**
```bash
# Recompile
zig build-exe -O ReleaseFast core/main.zig --name omnibus-node
```

---

## 🎯 Command Reference

### **PowerShell (Windows)**
```powershell
# Run full genesis startup
.\start-omnibus-full.ps1

# Kill all miners
taskkill /IM omnibus-node.exe /F

# View logs
Get-Content logs/seed-node.log -Tail 20 -Wait
```

### **Bash (Linux/macOS)**
```bash
# Run full genesis startup
./start-omnibus-full.sh

# Kill all miners
pkill -f omnibus-node

# View logs
tail -f logs/seed-node.log
```

---

## 📊 Expected Output

### **When Genesis Countdown UI Loads**
```
┌─ Blockchain Status ──────────┐
│ Status: mining               │
│ Block Height: 0              │
│ Difficulty: 4                │
└──────────────────────────────┘

┌─ Miners Connected ───────────┐
│ Connected: 10/10             │
│ Total Hashrate: 10,000 H/s   │
│ Min. Required: 3             │
└──────────────────────────────┘

┌─ Genesis Ready ──────────────┐
│ Status: ✓ Ready              │
│ [Start Genesis] button ✅    │
└──────────────────────────────┘
```

### **When Genesis is Started**
```
[GENESIS] Starting with 10 miners, 10000 H/s total hashrate
[BLOCKCHAIN] Block 0 mined by miner-5 (hash: 00001a2b...)
[BLOCKCHAIN] Block 1 mined by miner-1 (hash: 00001c3d...)
[BLOCKCHAIN] Block 2 mined by miner-3 (hash: 00001e4f...)
```

---

## 🚀 Advanced Features

### **Scaling (20+ Miners)**
```bash
# Modify script to increase MINERS_COUNT
$MINERS_COUNT = 20  # PowerShell
# OR
MINERS_COUNT=20     # Bash

# Each miner will receive less tokens but network hash grows
# Total hashrate: 20 × 1000 = 20,000 H/s
```

### **Custom Hashrate**
```bash
# Modify HASHRATE in script
# Affects difficulty adjustment
```

### **Persistent State**
```bash
# Genesis data saved to:
wallets/genesis-allocation.json
genesis/genesis-block.bin  # Created when genesis starts

# Can resume from checkpoint
```

---

## 🎉 Success Criteria

Genesis is **successful** when:
- ✅ All 10 miners launch and connect
- ✅ Genesis Countdown UI shows 10/10 miners
- ✅ Status changes to "Ready"
- ✅ "Start Genesis" button enabled
- ✅ User clicks button and blocks begin mining
- ✅ Explorer shows Block 0, 1, 2, etc.
- ✅ Miners receive block rewards

---

## 📚 Related Documentation

- **[PHASE_8_SUMMARY.md](./PHASE_8_SUMMARY.md)** – Storage optimization
- **[GENESIS_COUNTDOWN_GUIDE.md](./GENESIS_COUNTDOWN_GUIDE.md)** – UI details
- **[README.md](./README.md)** – Project overview

---

## 💡 Tips

1. **First run takes ~10 seconds** – miners need time to connect
2. **Monitor logs** – `tail -f logs/*.log` to see everything
3. **Check UI every 2 seconds** – updates in real-time
4. **Keep terminal open** – scripts run background processes
5. **Ctrl+C to stop** – cleans up running processes

---

## 🔐 Security Notes

- Genesis wallets use **post-quantum cryptography** (Kyber, Dilithium, Falcon, SPHINCS+)
- Addresses are **deterministic** (reproducible from seed)
- Token allocation is **immutable** at genesis
- Miners cannot double-spend (blockchain enforces)

---

**Status:** 🚀 **Ready for Genesis Launch**

Run now:
```bash
# Windows
.\start-omnibus-full.ps1

# Linux/macOS
./start-omnibus-full.sh
```

Then open: **http://localhost:3000/genesis-countdown**

Happy mining! 🎉
