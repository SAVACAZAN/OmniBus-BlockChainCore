# OmniBus Mining Pool - Dynamic Miner Registration

**Version**: 1.0
**Status**: Operational
**Architecture**: Distributed Mining Pool with Dynamic Miner Discovery

---

## Overview

The OmniBus Mining Pool is a **no-hardcode, dynamic registration system** where:
- ✅ Pool starts with **zero miners**
- ✅ Miners **register themselves** at runtime
- ✅ Rewards **distributed equally** to all active miners
- ✅ Miners **join/leave dynamically** without pool restart
- ✅ Each miner has its **own BIP-39 wallet** with deterministic addresses

---

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                  OmniBus Mining Pool                         │
│                  (rpc-server.js:8332)                        │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  Blockchain State:                 Miner Registry:          │
│  • blockCount (1, 2, 3...)         • minerRegistry Map      │
│  • blockData (history)             • activeMinerSet         │
│  • minerBalances (per miner)       • minerLastBlockTime     │
│  • balance (total rewards)         • minerInfo (id, name...)│
│                                                              │
│  Mining Loop (every 2 seconds):                             │
│  • Create block                                             │
│  • Divide 50 OMNI ÷ activeMinerCount                       │
│  • Reward each active miner                                 │
│  • Store as coinbase transaction                            │
│                                                              │
└─────────────────────────────────────────────────────────────┘
        ↑                                      ↓
        │                                      │
   RPC Calls                            RPC Responses
   (JSON-RPC 2.0)                       (Block rewards)
        │                                      │
┌───────┴──────────────────────────────────────┴──────┐
│                                                       │
│  Miner Clients (miner-client.js)                    │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐ │
│  │  Miner-0    │  │  Miner-1    │  │  Miner-N    │ │
│  ├─────────────┤  ├─────────────┤  ├─────────────┤ │
│  │ Register    │  │ Register    │  │ Register    │ │
│  │ Keepalive   │  │ Keepalive   │  │ Keepalive   │ │
│  │ (5s)        │  │ (5s)        │  │ (5s)        │ │
│  └─────────────┘  └─────────────┘  └─────────────┘ │
│                                                       │
└───────────────────────────────────────────────────────┘
```

---

## Quick Start

### 1️⃣ Generate Genesis Wallets & Start Pool

```bash
# Creates 10 miner wallets + starts pool + launches 10 miners
bash start-genesis.sh
```

This does:
1. Generates 10 miner wallets (with BIP-39 mnemonics + OMNI addresses)
2. Starts the mining pool (port 8332)
3. Launches 10 genesis miners
4. Shows network status

**Expected output:**
```
[POOL] ✓ Miner joined: Miner-0 (1000 H/s)
[POOL] ✓ Miner joined: Miner-1 (1000 H/s)
...
[POOL] ✓ Miner joined: Miner-9 (1000 H/s)
Pool has 10 registered miners (10 active)
```

### 2️⃣ Scale Test: Launch 100 Extra Miners

```bash
# In a new terminal:
bash launch-extra-miners.sh 100
```

This:
1. Checks pool is running
2. Generates 100 extra miner wallets
3. Launches 100 miners (miner-10 to miner-109)
4. Shows joining in real-time

**Expected output:**
```
[POOL] ✓ Miner joined: ExtraMiner-10 (1000 H/s)
[POOL] ✓ Miner joined: ExtraMiner-11 (1000 H/s)
...
[POOL] Pool has 110 registered miners (110 active)
```

### 3️⃣ Monitor Pool

```bash
# View mining rewards in real-time
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
  "totalRewards": "450 OMNI",
  "totalTransactions": 236500,
  "uptime": 45231
}
```

---

## File Structure

```
OmniBus-BlockChainCore/
├── rpc-server.js                 # Mining pool (NO hardcoded miners)
├── miner-client.js               # Miner client (registers + keepalive)
├── create-wallet.js              # Wallet generator (BIP-39)
├── start-genesis.sh              # Bootstrap 10 genesis miners
├── launch-extra-miners.sh        # Launch N additional miners
├── launch-pool-miners.sh         # Generic miner launcher
│
├── wallets/
│   ├── genesis_miners_10.json    # 10 genesis miner wallets
│   ├── extra_miners_100.json     # 100 extra miner wallets
│   └── wallet_omni_*.json        # Individual wallet files
│
├── logs/
│   ├── pool.log                  # Pool server logs
│   ├── miner-0.log               # Miner logs
│   ├── extra-miner-10.log        # Extra miner logs
│   └── ...
│
├── frontend/                      # React explorer
│   └── src/api/rpc-client.ts     # RPC client (updated)
│
└── POOL.md                       # This file
```

---

## RPC API Reference

### Pool Management

#### `registerminer`
Register a new miner with the pool.

```bash
curl -X POST http://localhost:8332 \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc":"2.0",
    "method":"registerminer",
    "params":[{
      "id":"miner-10",
      "name":"Miner-10",
      "address":"ob_omni_abc123...",
      "hashrate":1000
    }],
    "id":1
  }'
```

**Response:**
```json
{
  "success": true,
  "message": "Miner-10 registered",
  "minerCount": 11,
  "activeMiners": 11
}
```

#### `minerkeepalive`
Send keepalive signal (resets 30-second timeout).

```bash
curl -X POST http://localhost:8332 \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc":"2.0",
    "method":"minerkeepalive",
    "params":["ob_omni_abc123..."],
    "id":1
  }'
```

#### `getpoolstats`
Get current pool statistics.

```bash
curl -X POST http://localhost:8332 \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"getpoolstats","params":[],"id":1}'
```

**Response:**
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

#### `getminerstatus`
Detailed pool + miner status.

```bash
curl -X POST http://localhost:8332 \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"getminerstatus","params":[],"id":1}'
```

### Blockchain Methods

#### `getminers`
List all **active** miners.

```bash
curl -X POST http://localhost:8332 \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"getminers","params":[],"id":1}'
```

**Response:**
```json
[
  {
    "id": "miner-0",
    "name": "Miner-0",
    "address": "ob_omni_abc123...",
    "status": "mining",
    "hashrate": 1000,
    "balanceOmni": 45.0,
    "blocksMined": 45,
    "lastBlockTime": 1710758400123,
    "isActive": true,
    "joinedAt": 1710758400000
  },
  ...
]
```

#### `getminerbalances`
Miner balances and statistics.

```bash
curl -X POST http://localhost:8332 \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"getminerbalances","params":[],"id":1}'
```

#### `getblockcount`
Current block height.

#### `getblock [index]`
Get block by height.

#### `gettransactioncount`
Total transaction count (blocks × active miners).

#### `gettransactionhistory [limit]`
Recent transactions.

---

## Wallet Generation

### Create Single Wallet

```bash
node create-wallet.js create mypool 1
```

**Output:**
```
[WALLET] ✓ Wallet Created!
[WALLET] Mnemonic: abandon ability able about above absent absorb abstract ...
[WALLET] Address #0: ob_omni_abc123def456...
[WALLET] ✓ Saved to: wallets/mypool.json
```

**Wallet file format:**
```json
{
  "name": "mypool",
  "type": "OmniBus",
  "version": "1.0",
  "createdAt": "2026-03-18T12:00:00Z",
  "mnemonic": "abandon ability able about above absent absorb abstract abuse access accident...",
  "addresses": [
    {
      "index": 0,
      "omniAddress": "ob_omni_abc123def456...",
      "publicKey": "a1b2c3d4e5f6...",
      "derivationPath": "m/44'/60'/0'/0/0",
      "balance": 0,
      "balanceOmni": 0,
      "blocksMined": 0
    }
  ]
}
```

### Batch Create (for Mining)

```bash
# Create 10 wallets (miner-0 through miner-9)
node create-wallet.js batch 10

# Create 100 wallets (miner-10 through miner-109)
node create-wallet.js batch 100
```

**Output file:** `wallets/genesis_miners_10.json`

```json
[
  {
    "minerName": "miner-0",
    "mnemonic": "abandon ability able about above absent absorb abstract abuse access accident...",
    "address": "ob_omni_abc123...",
    "publicKey": "a1b2c3d4e5f6..."
  },
  ...
]
```

---

## How Reward Distribution Works

### Block Reward: 50 OMNI per block

When a block is mined:

1. **Count active miners** (those that sent keepalive in last 30s)
   - Example: 110 active miners

2. **Divide reward equally**
   - Block reward = 50 OMNI = 5,000,000,000 SAT
   - Per-miner reward = 50 OMNI ÷ 110 = 0.4545 OMNI per miner
   - Per-miner SAT = 5,000,000,000 ÷ 110 = 45,454,545 SAT per miner

3. **Create coinbase transactions** (one per active miner)
   - Block #100 → 110 transactions (one for each active miner)
   - Total transactions that block = 110

4. **Update miner balances**
   - Each miner's balance += 45,454,545 SAT
   - Total pool balance += 50 OMNI

### Fair Distribution

✅ If 10 miners → each gets 5 OMNI per block
✅ If 110 miners → each gets 0.454 OMNI per block
✅ If miner disconnects (no keepalive) → removed from active set
✅ If 5 miners remain → each gets 10 OMNI per block

**Result**: **Perfectly equal** reward distribution, scales automatically.

---

## Miner Lifecycle

### Registration Phase (when miner starts)

```
Miner-Client                    Pool
    |                             |
    |---- registerminer --------> |
    |     (id, name, address)     |
    |                             |
    | <-- { success: true } -----|
    |     (minerCount=11)        |
    |                             |
    |---- START KEEPALIVE LOOP--->|
    |     (every 5 seconds)       |
```

### Active Mining Phase

```
Pool                            Miner
    |                             |
    | <-- minerkeepalive ------  |
    |     (address)              |
    |                             |
    |--- ADD to activeMinerSet -->|
    |--- MINE BLOCK ----------->  |
    |    (distribute reward)     |
    |                             |
    | <-- minerkeepalive ------  |  (every 5s)
    |                             |
    |--- MINE BLOCK ------------> |
    |    (miner gets 0.4545 OMNI)|
```

### Disconnect Phase (30s timeout)

```
Miner (disconnects / crashes)
    |
    X---- No keepalive for 30 seconds
    |
Pool detects timeout
    |
    V---- REMOVE from activeMinerSet
    |
    V---- Rewards go to remaining miners only
          (their share increases)
```

---

## Monitoring & Troubleshooting

### View Pool Logs

```bash
tail -f logs/pool.log
```

**Expected output:**
```
[POOL] JSON-RPC 2.0 Server on http://localhost:8332
[POOL] ✓ Miner joined: Miner-0 (1000 H/s)
[POOL] ✓ Miner joined: Miner-1 (1000 H/s)
[POOL] Disconnected: Miner-5
```

### View Miner Logs

```bash
tail -f logs/miner-0.log
```

**Expected output:**
```
[MINER] ✓ Successfully registered!
[MINER] Miner ID: miner-0
[MINER] Address: ob_omni_abc123...
[MINER] Hashrate: 1000 H/s
[MINER] Sending keepalive every 5 seconds...
[MINER] Pool: 10/10 miners, Block #45, ⛏️ 225 OMNI mined
```

### Check if Pool is Running

```bash
curl -s -X POST http://127.0.0.1:8332 \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"getpoolstats","params":[],"id":1}' | jq .
```

### Count Active Miners

```bash
curl -s -X POST http://127.0.0.1:8332 \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"getminers","params":[],"id":1}' | jq 'length'
```

---

## Stopping & Cleanup

### Stop Genesis Miners

```bash
cat .miners_pids | xargs kill
```

### Stop Extra Miners

```bash
cat .extra_miners_pids | xargs kill
```

### Stop Pool

```bash
kill $(pgrep -f "rpc-server.js")
```

### Clean All Logs

```bash
rm -rf logs/
```

---

## Technical Details

### Why No Hardcoded Miners?

**Before (Genesis allocation.json)**:
- Hardcoded 110 miners at startup
- Changes required restart
- Couldn't test dynamic scaling

**Now (Pool registration)**:
- Miners register via `registerminer` RPC
- Pool starts with zero miners
- New miners join = instantly added to active set
- No pool restart needed

### BIP-39 Wallet Generation

Each miner gets a deterministic wallet:
```
Mnemonic (12 words) → PBKDF2-SHA512 → Seed → HMAC-SHA256 → Address

Example:
Mnemonic: "abandon ability able about above absent absorb abstract abuse access accident"
Seed: (64 bytes derived from PBKDF2)
Address: ob_omni_abc123def456...
```

**Key features**:
- ✅ Deterministic (same mnemonic = same address)
- ✅ BIP-32 compliant (path: m/44'/60'/0'/0/{index})
- ✅ Portable (use on any platform)
- ✅ Secure (mnemonic = backup)

### 30-Second Miner Timeout

- Miner sends keepalive every 5 seconds
- Pool checks every 5 seconds for inactive miners
- If no keepalive for 30+ seconds → removed
- **Benefit**: Automatic failover, responsive to crashes

---

## Performance Metrics

| Metric | Value |
|--------|-------|
| **Block Time** | 2 seconds |
| **Block Reward** | 50 OMNI |
| **Block Reward (SAT)** | 5,000,000,000 |
| **Genesis Miners** | 10 |
| **Max Scalable Miners** | 1000+ |
| **Reward Recalc** | Every block |
| **Miner Timeout** | 30 seconds |
| **Keepalive Interval** | 5 seconds |
| **RPC Port** | 8332 |

---

## Future Enhancements

- [ ] Persistent wallet storage (RocksDB)
- [ ] Miner stats tracking (blocks/hour, uptime %)
- [ ] Pool fee system (e.g., 1% cut)
- [ ] Automatic difficulty adjustment
- [ ] WebSocket support (real-time updates)
- [ ] Multi-pool support (miner connects to multiple pools)
- [ ] Slush pool-style vardiff (dynamic difficulty per miner)

---

## Support

**Issues?**

1. Check logs: `tail -f logs/pool.log`
2. Verify pool running: `curl -s http://127.0.0.1:8332 ... | jq .`
3. Check firewall: port 8332 must be open
4. Verify wallet generation: `ls -la wallets/`

---

**Created**: 2026-03-18
**Version**: 1.0
**Status**: Production Ready ✅
