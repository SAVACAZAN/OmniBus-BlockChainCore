# OmniBus BlockChain Core

**Cross-Platform Blockchain Implementation** (Windows + Linux)
**Version:** 1.0.0-dev
**Languages:** Zig (backend) + TypeScript (frontend)
**Status:** 🚀 Development Started

---

## 🎯 PROJECT SCOPE

### Core Components
1. **Blockchain Engine** (Zig)
   - Proof-of-Work consensus
   - Block validation & mining
   - Transaction pool (mempool)
   - Post-quantum cryptography

2. **Wallet Manager** (Zig)
   - Multi-signature wallet support
   - BIP-32/39 HD wallet derivation
   - Private key management

3. **RPC Server** (Zig)
   - JSON-RPC 2.0 HTTP/WebSocket endpoint
   - getblock, gettransaction, sendtransaction, getbalance

4. **Agent System** (Zig)
   - Multi-client manager
   - Trading integration

5. **Explorer** (TypeScript + React)
   - Block explorer UI
   - Transaction history
   - Address lookup

6. **Web Wallet** (TypeScript + React)
   - Send/receive transactions
   - Balance management

---

## 📁 PROJECT STRUCTURE

```
OmniBus-BlockChainCore/
├── core/                          # Zig blockchain engine
│   ├── blockchain.zig             – Main blockchain logic
│   ├── block.zig                  – Block structure
│   ├── transaction.zig            – TX structure
│   ├── wallet.zig                 – Wallet & key management
│   ├── mempool.zig                – Transaction pool
│   ├── rpc_server.zig             – JSON-RPC endpoint
│   ├── consensus.zig              – Proof-of-Work
│   ├── crypto.zig                 – Cryptographic functions
│   └── main.zig                   – Entry point
│
├── frontend/                      # TypeScript + React
│   ├── src/
│   │   ├── pages/
│   │   │   ├── BlockExplorer.tsx
│   │   │   ├── Wallet.tsx
│   │   │   └── Transactions.tsx
│   │   ├── api/
│   │   │   └── rpc-client.ts
│   │   └── App.tsx
│   └── package.json
│
├── agent/                         # Trading agent (Zig)
│   ├── agent_manager.zig
│   └── trading_agent.zig
│
├── test/
├── docs/
├── build.zig
├── Makefile
└── CLAUDE.md
```

---

## 🚀 QUICK START

```bash
cd /home/kiss/OmniBus-BlockChainCore

# Build blockchain core
make build-core

# Start node
make run-node

# Frontend (in another terminal)
cd frontend
npm install
npm run dev
```

---

## 📋 DEVELOPMENT PHASES

**Phase 1:** Core Blockchain (Week 1)
- Block validation, mining, mempool
- JSON-RPC basics

**Phase 2:** Wallet & Security (Week 2)
- HD wallet (BIP-32/39)
- Key derivation (5 PQ domains)
- Transaction signing

**Phase 3:** RPC & Storage (Week 3)
- Full JSON-RPC 2.0
- Block storage (RocksDB)
- Indexing & sync

**Phase 4:** Frontend (Week 4)
- Block explorer
- Web wallet
- Real-time updates

**Phase 5:** Agent & Trading (Week 5)
- Multi-client manager
- Trading agent
- Order execution

---

**Status:** 🚀 Starting Phase 1

