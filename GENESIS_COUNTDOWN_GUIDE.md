# Genesis Countdown Guide

**Date:** March 18, 2026
**Feature:** Light Miners + Genesis Countdown UI
**Status:** ✅ COMPLETE

---

## 🚀 What is Genesis Countdown?

Genesis Countdown is the **initialization sequence** for OmniBus blockchain. It displays:
- Real-time blockchain status
- Connected miners
- When genesis mining will start
- Live miner statistics
- Ability to launch multiple light miners simultaneously

**Target:** Launch with minimum 3 light miners connected, then begin mining genesis blocks.

---

## 🖥️ Components

### 1. **Light Miner** (`light_miner.zig`)
Individual lightweight miner instance that can:
- Run independently on same machine
- Connect to seed node
- Submit mining shares
- Report status and statistics

**Features:**
- Unique ID per instance (0-9)
- Hashrate: 1000 H/s per miner
- Share submission tracking
- Block mining tracking
- Automatic status updates

### 2. **Miner Pool** (`light_miner.zig`)
Manages multiple light miners:
- Register miners
- Track connection status
- Count connected miners
- Detect genesis readiness (≥3 miners)
- Start genesis mining

### 3. **Genesis Countdown UI** (`GenesisCountdown.tsx`)
React page showing:
- Blockchain status (initializing → ready → mining)
- Miner count (0/10 → 3/10 → 10/10)
- Live miner statistics
- Start genesis button
- Launch miners button

### 4. **Light Miner Launchers**
- `launch-light-miners.bat` (Windows)
- `launch-light-miners.sh` (Linux/macOS)

---

## 📋 Architecture

```
User Browser (React)
    ↓
  Genesis Countdown UI
    ↓ (Polls every 2-3 seconds)
    ↓
  RPC Server (port 8332)
    ├─ getGenesisStatus()
    ├─ getMiners()
    └─ startGenesis()
    ↓
Blockchain Core
    ├─ MinerPool (tracks miners)
    ├─ Light Miners (10 instances)
    └─ Genesis Logic
```

---

## 🎯 Quick Start

### **Step 1: Build the Blockchain**
```bash
cd /home/kiss/OmniBus-BlockChainCore
zig build-exe -O ReleaseFast core/main.zig --name omnibus-node
```

Expected output:
```
✅ omnibus-node 2.4M created
```

### **Step 2: Start Seed Node** (Terminal 1)
```bash
./omnibus-node --mode seed --node-id seed-1 --primary --port 9000
```

Expected output:
```
[BOOTSTRAP] Seed node 'seed-1' initialized (primary)
[BOOTSTRAP] Waiting for miners on 127.0.0.1:9000
```

### **Step 3: Start RPC Server** (Terminal 2)
```bash
./omnibus-node --mode rpc
```

Expected output:
```
[RPC] Server listening on http://localhost:8332
```

### **Step 4: Start Frontend** (Terminal 3)
```bash
cd frontend && npm install && npm start
```

Expected output:
```
➜ Browser ready at http://localhost:3000
```

### **Step 5: Launch Light Miners** (Terminal 4 or Windows Explorer)

**Windows:**
```cmd
launch-light-miners.bat
```

**Linux/macOS:**
```bash
chmod +x launch-light-miners.sh
./launch-light-miners.sh
```

Expected output:
```
Starting light-miner-1...
Starting light-miner-2...
Starting light-miner-3...
...
All 10 miners launched!
```

### **Step 6: Open Genesis Countdown in Browser**
```
http://localhost:3000/genesis-countdown
```

Watch as miners connect and genesis becomes ready!

---

## 📊 UI Flow

### **Phase 1: Initializing** (0 miners)
```
Status: initializing
Miners: 0/10
Genesis Ready: ⏳ Waiting
Action: Launch miners
```

### **Phase 2: Waiting for Miners** (1-2 miners)
```
Status: waiting
Miners: 2/10
Genesis Ready: ⏳ Waiting (need 3)
Action: Wait or launch more miners
```

### **Phase 3: Genesis Ready** (3+ miners)
```
Status: ready
Miners: 5/10
Genesis Ready: ✓ Ready
Action: Click "Start Genesis" button
```

### **Phase 4: Genesis Mining** (all miners)
```
Status: mining
Miners: 10/10
Genesis Ready: 🎉 Genesis Mining Started!
Action: Watch blocks appear in explorer
```

---

## 🔍 Genesis Status Indicators

### **Blockchain Status**
| Status | Meaning | Miners Needed |
|--------|---------|--------------|
| `initializing` | System starting | 0 |
| `waiting` | Waiting for miners | <3 |
| `ready` | Ready to start | ≥3 |
| `mining` | Genesis in progress | ≥3 |
| `error` | Network error | Any |

### **Miner Status**
| Status | Color | Meaning |
|--------|-------|---------|
| `online` | 🟢 Green | Connected & mining |
| `connecting` | 🟡 Yellow | Connecting to seed |
| `offline` | 🔴 Red | Not connected |
| `block_found` | ✨ Cyan | Found a block! |
| `error` | 🔴 Red | Connection error |

---

## 📈 Miner Metrics

Each miner shows:
- **Blocks Mined** – Number of blocks found by this miner
- **Hashrate** – 1000 H/s per light miner
- **Shares** – accepted/submitted ratio
- **Uptime** – Seconds connected
- **Progress Bar** – Share acceptance ratio

**Example:**
```
light-miner-1
Status: mining ⚡
Blocks: 5
Hashrate: 1000 H/s
Shares: 47/50
Uptime: 125s
Progress: 94% ████████░
```

---

## 🛠️ Files Added/Modified

### **New Files**
```
core/
├─ light_miner.zig                (270+ lines) ✅
├─ rpc_server.zig                 (UPDATED - new RPC methods)

frontend/src/pages/
├─ GenesisCountdown.tsx           (350+ lines) ✅

scripts/
├─ launch-light-miners.bat        (Windows launcher) ✅
├─ launch-light-miners.sh         (Linux/macOS launcher) ✅

docs/
└─ GENESIS_COUNTDOWN_GUIDE.md     (This file) ✅
```

### **Modified Files**
```
core/
├─ rpc_server.zig                 (Added:
                                   - getGenesisStatus()
                                   - getMiners()
                                   - startGenesis())
```

---

## 🔧 Configuration

### **Light Miner Settings**
```zig
// In light_miner.zig
const MINER_ID = 0..9;           // 10 instances
const HASHRATE = 1000;            // H/s per miner
const MIN_FOR_GENESIS = 3;        // Minimum miners needed
```

### **Genesis Countdown Settings**
```tsx
// In GenesisCountdown.tsx
const POLL_INTERVAL = 2000;       // ms - update frequency
const MIN_MINERS = 3;             // genesis threshold
const UPDATE_DELAY = 3000;        // ms - miner update
```

### **Seed Node Settings**
```bash
# In launch scripts
SEED_HOST="127.0.0.1"
SEED_PORT="9000"
HASHRATE="1000"
```

---

## 📊 Example Output

### **Console (Seed Node)**
```
[BOOTSTRAP] Seed node 'seed-1' initialized (primary)
[BOOTSTRAP] Waiting for miners on 127.0.0.1:9000
[NETWORK] Miner connected: miner-1 (hashrate: 1000 H/s)
[NETWORK] Miner connected: miner-2 (hashrate: 1000 H/s)
[NETWORK] Miner connected: miner-3 (hashrate: 1000 H/s)
[GENESIS] Ready to start! 3 miners connected
[GENESIS] Starting genesis mining...
[BLOCKCHAIN] Block 0 mined by miner-1 (hash: 00001a2b...)
[BLOCKCHAIN] Block 1 mined by miner-2 (hash: 00001c3d...)
[BLOCKCHAIN] Block 2 mined by miner-3 (hash: 00001e4f...)
```

### **Browser (Genesis Countdown)**
```
Network Status: mining
Block Height: 3
Difficulty: 4

Miners Connected: 3/10
Total Hashrate: 3,000 H/s

Genesis Ready: ✓ Ready
Genesis Mining: 🎉 Started!

[light-miner-1] ⚡ mining | Blocks: 1 | Hashrate: 1000 H/s
[light-miner-2] ⚡ mining | Blocks: 1 | Hashrate: 1000 H/s
[light-miner-3] ⚡ mining | Blocks: 1 | Hashrate: 1000 H/s
```

---

## 🚨 Troubleshooting

### **Problem: Miners won't connect**
**Solution:**
1. Verify seed node is running: `./omnibus-node --mode seed --node-id seed-1 --port 9000`
2. Check firewall isn't blocking port 9000
3. Verify miners use correct seed address: `--seed-host 127.0.0.1 --seed-port 9000`

### **Problem: Genesis won't start even with 3 miners**
**Solution:**
1. Click "Start Genesis" button in UI
2. Check browser console (F12) for errors
3. Verify RPC server is running on port 8332

### **Problem: Miners keep disconnecting**
**Solution:**
1. Reduce number of miners (try 5 instead of 10)
2. Increase seed node timeout
3. Check system CPU/RAM usage (may be overloaded)

### **Problem: Genesis Countdown page won't load**
**Solution:**
1. Verify frontend is running: `npm start` in `frontend/` directory
2. Check http://localhost:3000 works first
3. Check browser console for CORS/connection errors
4. Ensure RPC server is accessible at http://localhost:8332

### **Problem: Can't compile light_miner.zig**
**Solution:**
```bash
# Ensure Zig 0.15.2+
zig version

# Clean build
rm -rf .zig-cache
zig build-exe -O ReleaseFast core/main.zig --name omnibus-node
```

---

## 📖 API Reference

### **RPC Methods**

#### `getGenesisStatus`
Returns current genesis state.

**Request:**
```json
{
  "jsonrpc": "2.0",
  "method": "getGenesisStatus",
  "params": [],
  "id": 1
}
```

**Response:**
```json
{
  "jsonrpc": "2.0",
  "result": {
    "status": "mining",
    "blockCount": 3,
    "currentDifficulty": 4,
    "timestamp": 1710768000,
    "connectedMiners": 3,
    "totalMiners": 10,
    "totalHashrate": 3000,
    "genesisReady": true,
    "genesisStarted": true,
    "minersRequired": 3
  },
  "id": 1
}
```

#### `getMiners`
Returns list of connected miners.

**Request:**
```json
{
  "jsonrpc": "2.0",
  "method": "getMiners",
  "params": [],
  "id": 1
}
```

**Response:**
```json
{
  "jsonrpc": "2.0",
  "result": [
    {
      "id": 0,
      "name": "light-miner-1",
      "status": "mining",
      "isConnected": true,
      "blocksMined": 1,
      "sharesSubmitted": 47,
      "sharesAccepted": 47,
      "hashrate": 1000,
      "uptime": 125
    }
  ],
  "id": 1
}
```

#### `startGenesis`
Begins genesis mining.

**Request:**
```json
{
  "jsonrpc": "2.0",
  "method": "startGenesis",
  "params": [],
  "id": 1
}
```

**Response:**
```json
{
  "jsonrpc": "2.0",
  "result": true,
  "id": 1
}
```

---

## 🎯 Use Cases

### **Testing Blockchain**
1. Launch seed node
2. Launch 3 light miners
3. Watch genesis start
4. Monitor blocks being mined
5. Use explorer to view blocks

### **Demo/Presentation**
1. Show Genesis Countdown page
2. Launch miners on demand
3. Show real-time miner statistics
4. Show blocks appearing in explorer
5. Impressive! 🎉

### **Development**
1. Test miner connection logic
2. Test block validation
3. Test state transitions
4. Monitor network behavior
5. Debug issues with real miners

---

## 📚 Related Documentation

- **[PHASE_8_SUMMARY.md](./PHASE_8_SUMMARY.md)** – Storage optimization (SegWit, State Trie, Light Client)
- **[PHASE_6_7_SUMMARY.md](./PHASE_6_7_SUMMARY.md)** – Sub-blocks, Binary encoding, Pruning
- **[README.md](./README.md)** – Project overview
- **[CLAUDE.md](./CLAUDE.md)** – Development guidelines

---

## 🚀 Next Steps

1. **Phase 9:** Multi-shard mining (parallel sub-blocks across shards)
2. **Phase 10:** Mobile light miners (iOS/Android app)
3. **Phase 11:** Automated miner scaling (auto-spawn based on difficulty)
4. **Phase 12:** Network performance dashboard

---

## ✅ Checklist: Genesis Countdown Ready

- [x] Light Miner backend (`light_miner.zig`)
- [x] Miner Pool manager
- [x] Genesis Countdown UI (`GenesisCountdown.tsx`)
- [x] RPC API methods (getGenesisStatus, getMiners, startGenesis)
- [x] Windows launcher (`launch-light-miners.bat`)
- [x] Linux/macOS launcher (`launch-light-miners.sh`)
- [x] Documentation (this guide)
- [x] Build succeeds: `omnibus-node 2.4M`

---

**Status:** 🚀 **Ready for Genesis Launch**

**Commands to Launch Genesis:**

```bash
# Terminal 1: Seed Node
./omnibus-node --mode seed --node-id seed-1 --primary --port 9000

# Terminal 2: RPC Server
./omnibus-node --mode rpc

# Terminal 3: Frontend
cd frontend && npm start

# Terminal 4: Light Miners (Windows)
launch-light-miners.bat

# OR Terminal 4: Light Miners (Linux/macOS)
./launch-light-miners.sh

# Then open browser:
# http://localhost:3000/genesis-countdown
```

**Watch genesis begin with minimum 3 miners connected!** 🎉

---

**Last Updated:** March 18, 2026
**Feature Status:** ✅ Complete & Ready
**Next Phase:** Distributed Genesis (Phase 9)
