# OmniBus BlockChain Core - Development Guide

**Project:** OmniBus BlockChain Core
**Status:** Phase 1 - Core Blockchain Development
**Languages:** Zig (backend), TypeScript (frontend)
**Platforms:** Windows, Linux, macOS

---

## Project Overview

OmniBus-BlockChainCore is a cross-platform blockchain implementation designed for:
- High-performance consensus (Proof-of-Work, 10-second blocks)
- Multi-client support with trading agents
- Post-quantum cryptography (5 OMNI address domains per client)
- Ethereum bridge for USDC on-ramp (Sepolia testnet)
- Web explorer and wallet interface

---

## Architecture

### Backend (Zig)
```
core/
├── main.zig              Entry point (mining loop)
├── blockchain.zig        Blockchain engine, chain management
├── block.zig             Block structure, validation
├── transaction.zig       Transaction structure, validation
├── wallet.zig            Wallet with 5 PQ address pairs
├── rpc_server.zig        JSON-RPC 2.0 endpoint
└── crypto.zig            (Placeholder) Cryptographic functions

agent/
├── agent_manager.zig     Multi-client manager
└── trading_agent.zig     Trading logic (Phase 2)
```

### Frontend (TypeScript + React)
```
frontend/
├── src/
│   ├── pages/            Block explorer, wallet, transactions
│   ├── components/       UI components
│   ├── api/              RPC client wrapper
│   └── main.tsx          App entry
└── index.html
```

---

## Development Phases

### Phase 1: Core Blockchain (Current - Week 1)
**Status:** In Progress

**Files to Create/Modify:**
- ✅ blockchain.zig - Consensus & chain management
- ✅ block.zig - Block validation
- ✅ transaction.zig - TX validation
- ✅ wallet.zig - 5 PQ address generation
- ✅ rpc_server.zig - JSON-RPC endpoints
- ⏳ mempool.zig - Transaction pool optimization
- ⏳ consensus.zig - Difficulty adjustment

**Milestones:**
- [ ] Block mining works (10-second blocks)
- [ ] Mempool accepts transactions
- [ ] JSON-RPC returns block data
- [ ] Wallet generates 5 OMNI addresses per client
- [ ] Basic unit tests pass

**Commands:**
```bash
make build-core       # Compile blockchain
make run-node         # Start mining
make test             # Run tests
```

---

### Phase 2: Wallet & Security (Week 2)
- HD Wallet (BIP-32/39)
- Key derivation for 5 PQ domains
- Transaction signing (Dilithium-5, Kyber-768, etc.)
- Private key encryption
- Secp256k1 for ERC20 bridge

---

### Phase 3: RPC & Storage (Week 3)
- Full JSON-RPC 2.0 spec
- RocksDB persistent storage
- Transaction indexing
- Block sync between nodes

---

### Phase 4: Frontend (Week 4)
- React block explorer
- Web wallet (send/receive)
- Real-time updates (WebSocket)
- TailwindCSS styling

---

### Phase 5: Agent & Trading (Week 5)
- Multi-client trading agents
- Order execution
- PnL tracking
- Integration with OmniBus bare-metal system

---

## Key Design Principles

1. **Determinism:** All nodes compute identical results
2. **Performance:** Sub-second block times, <100ms TX confirmation
3. **Post-Quantum Security:** All addresses use PQ algorithms
4. **Memory Safety:** Zig's memory safety + TypeScript type safety
5. **Cross-Platform:** Build once, run on Windows/Linux/macOS

---

## Data Structures

### Blockchain
```zig
pub const Block = struct {
    index: u32,
    timestamp: i64,
    transactions: ArrayList(Transaction),
    previous_hash: []const u8,
    nonce: u64,
    hash: []const u8,
};

pub const Transaction = struct {
    id: u32,
    from_address: []const u8,
    to_address: []const u8,
    amount: u64,          // in SAT
    timestamp: i64,
    signature: []const u8,
    hash: []const u8,
};
```

### Wallet
```zig
pub const Address = struct {
    domain: []const u8,              // omnibus.omni, omnibus.love, etc.
    algorithm: []const u8,           // Kyber-768, Falcon-512, etc.
    omni_address: []const u8,        // ob_omni_, ob_k1_, etc.
    erc20_address: []const u8,       // 0x... for Ethereum
    public_key: []const u8,
    security_level: u32,             // 256, 192, 128 bits
};
```

---

## Blockchain Parameters

| Parameter | Value | Notes |
|-----------|-------|-------|
| Block Time | 10s | Retargets if needed |
| Block Size | 1 MB | Max transaction data per block |
| Max TX Size | 100 KB | Single transaction limit |
| Difficulty | Dynamic | Starts at 4 leading zeros |
| Supply | 21M OMNI | Fixed, like Bitcoin |
| Block Reward | 50 OMNI | Halves every 210k blocks |
| SAT/OMNI | 100M | 1 OMNI = 100,000,000 SAT |

---

## RPC API (JSON-RPC 2.0)

### Endpoints
- `http://localhost:8332` - HTTP
- `ws://localhost:8333` - WebSocket

### Methods

| Method | Params | Returns |
|--------|--------|---------|
| `getblockcount` | none | Block count |
| `getblock` | `index` | Block object |
| `getlatestblock` | none | Latest block |
| `getbalance` | none | Wallet balance |
| `sendtransaction` | `to`, `amount` | TX hash |
| `gettransaction` | `txid` | TX object |
| `getmempoolsize` | none | # of pending TX |

### Example Request
```bash
curl -X POST http://localhost:8332 \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"getblockcount","params":[],"id":1}'
```

---

## Building & Running

### Prerequisites
- Zig 0.15.2+ (https://ziglang.org)
- Node.js 18+ (for frontend)
- Make (build automation)

### Build All
```bash
cd /home/kiss/OmniBus-BlockChainCore
make all                # Build backend + frontend
```

### Run Blockchain
```bash
make run-node           # Terminal 1: Start mining (port implicit)
make run-rpc            # Terminal 2: Start RPC server (port 8332)
make run-frontend       # Terminal 3: Start web UI (port 5173)
```

### Testing
```bash
make test               # Run Zig tests
cd frontend && npm test # Run React tests
```

---

## Memory Layout

**Blockchain State** (in-memory for Phase 1):
- Genesis block: Fixed
- Active chain: ArrayList (grows as blocks mined)
- Mempool: ArrayList (transactions waiting for block)
- Wallet: Single wallet with 5 OMNI addresses + ERC20 bridge address

**Phase 3+ Persistence:**
- RocksDB for block storage (rocksdb-zig wrapper)
- Indexed by: block height, TX hash, address

---

## Testing Strategy

### Unit Tests (Zig)
```zig
// test/blockchain_test.zig
test "block mining" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();

    _ = try bc.mineBlock();
    try testing.expectEqual(bc.getBlockCount(), 2); // genesis + 1
}
```

### Integration Tests
- Wallet generate & sign transaction
- RPC server responds to methods
- Block validation rejects invalid transactions

### Acceptance Tests (Frontend)
- Explorer loads block list
- Wallet shows 5 addresses
- Can initiate send transaction

---

## Common Tasks

### Add New RPC Method
1. Add function to `rpc_server.zig`
2. Update `RPCServer` struct
3. Add to API docs in README.md
4. Test with `curl` command

### Add New Transaction Type
1. Extend `Transaction` struct in `transaction.zig`
2. Update `validateTransaction()` logic
3. Update block mining to handle new type
4. Test with mining loop

### Modify Wallet Address Generation
1. Edit `wallet.zig` `Address` struct
2. Update 5-domain loop in `init()`
3. Verify ERC20 bridge address compatibility
4. Test with `./omnibus-node`

---

## Debugging

### Print Block Data
```zig
var block = bc.getLatestBlock();
std.debug.print("Block {d}: {s}\n", .{ block.index, block.hash });
```

### Enable RPC Logging
```bash
OMNIBUS_DEBUG=1 make run-rpc    # (if implemented)
```

### Frontend Network Errors
Check browser console (F12) for:
- CORS errors (RPC server must allow requests)
- Connection refused (RPC not running on :8332)
- JSON parse errors (malformed response)

---

## Git Workflow

### Every Commit
Include all 9 co-authors:
```bash
git commit -m "Phase 73: [Feature] Description

Co-Authored-By: OmniBus AI v1.stable <learn@omnibus.ai>
Co-Authored-By: Google Gemini <gemini-cli-agent@google.com>
Co-Authored-By: DeepSeek AI <noreply@deepseek.com>
Co-Authored-By: Claude 4.5 Haiku (Code) <claude-code@anthropic.com>
Co-Authored-By: Claude 4.5 Haiku <haiku-4.5@anthropic.com>
Co-Authored-By: Claude 4.5 Sonnet <sonnet-4.5@anthropic.com>
Co-Authored-By: Claude 4.5 Opus <opus-4.5@anthropic.com>
Co-Authored-By: Perplexity AI <support@perplexity.ai>
Co-Authored-By: Ollama <hello@ollama.com>"
```

---

## Resources

- **Zig Documentation**: https://ziglang.org/learn/overview
- **Bitcoin Whitepaper**: https://bitcoin.org/bitcoin.pdf (reference for PoW)
- **BIP-32 HD Wallets**: https://github.com/bitcoin/bips/blob/master/bip-0032.mediawiki
- **JSON-RPC 2.0 Spec**: https://www.jsonrpc.org/specification

---

## Next Steps

1. **Phase 1 TODO:**
   - [ ] Test block mining end-to-end
   - [ ] Verify wallet address generation
   - [ ] Implement mempool cleanup (remove old TX)
   - [ ] Add difficulty adjustment algorithm
   - [ ] Write unit tests

2. **Phase 2 TODO:**
   - [ ] BIP-32/39 HD wallet derivation
   - [ ] Real signature algorithms (Dilithium-5, Kyber-768)
   - [ ] Private key encryption (AES-256)

3. **Phase 3 TODO:**
   - [ ] RocksDB integration
   - [ ] Full JSON-RPC 2.0 spec
   - [ ] Block synchronization between peers

---

**Last Updated:** 2026-03-18
**Created by:** 9-AI Collaborative System
**Status:** 🚀 Phase 1 Active Development

