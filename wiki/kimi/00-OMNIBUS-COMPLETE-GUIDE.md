# OmniBus BlockChain Core - Ghid Complet

**Document:** 00-OMNIBUS-COMPLETE-GUIDE.md  
**Data:** 2026-03-30  
**Versiune:** 1.0.0-dev  
**Status:** 🔴 Documentație Completă  
**Autor:** Kimi AI (Analiză Proiect)  

---

## 📋 Cuprins

1. [Overview Proiect](#1-overview-proiect)
2. [Arhitectura Sistemului](#2-arhitectura-sistemului)
3. [Modulele Core (66 module)](#3-modulele-core-66-module)
4. [RPC API Complet](#4-rpc-api-complet)
5. [Criptografie Post-Quantum](#5-criptografie-post-quantum)
6. [Teste și Coverage](#6-teste-și-coverage)
7. [Tools și Utilitare](#7-tools-și-utilitare)
8. [Frontend și UI](#8-frontend-și-ui)
9. [Deployment și Launch](#9-deployment-și-launch)
10. [Ecosistem și Integrări](#10-ecosistem-și-integrări)

---

## 1. Overview Proiect

### Ce este OmniBus BlockChain Core?

OmniBus este un **blockchain Layer 1** implementat în **Zig 0.15.2**, cu focus pe:

- ✅ **Post-Quantum Security** - Algoritmi NIST PQ (ML-DSA-87, Falcon-512, SLH-DSA)
- ✅ **Sharding Nativ** - 7 shards + metachain EGLD-style
- ✅ **Sub-blocuri 0.1s** - 10 sub-blocuri = 1 KeyBlock (1s finality)
- ✅ **Windows Native** - Compilare nativă MinGW, fără WSL
- ✅ **Mining Pool Dinamic** - Înregistrare runtime, zero hardcoding
- ✅ **Cross-Platform** - Windows + Linux + macOS

### Statistici Cheie

| Metric | Valoare |
|--------|---------|
| **Module Zig** | 66 în `core/` |
| **Linii Cod Zig** | ~12,000+ |
| **Teste** | 500+ (toate trec ✅) |
| **RPC Methods** | 18+ |
| **Address Domains PQ** | 5 |
| **Shards** | 7 |
| **Sub-block Time** | 100ms |
| **Block Time** | 1s (10 sub-blocks) |

### Stack Tehnologic

```
┌─────────────────────────────────────────────────────────────┐
│                    FRONTEND (React + TS)                    │
│                  Port 3000 / WebSocket 8334                 │
├─────────────────────────────────────────────────────────────┤
│                    RPC SERVER (Node.js)                     │
│               JSON-RPC 2.0 / Port 8332                     │
├─────────────────────────────────────────────────────────────┤
│                  BLOCKCHAIN CORE (Zig)                      │
│   PoW + Sharding + PQ Crypto + P2P + State Trie + Mempool  │
├─────────────────────────────────────────────────────────────┤
│                   STORAGE (Binary custom)                   │
│              omnibus-chain.dat (append-only)               │
└─────────────────────────────────────────────────────────────┘
```

---

## 2. Arhitectura Sistemului

### 2.1 Structura Directoarelor

```
OmniBus-BlockChainCore/
│
├── core/                          # 66 module Zig blockchain
│   ├── main.zig                   # Entry point
│   ├── blockchain.zig             # Chain management
│   ├── block.zig                  # Block structure
│   ├── transaction.zig            # TX + semnături
│   ├── mempool.zig                # TX pool FIFO
│   ├── consensus.zig              # PoS consensus
│   ├── staking.zig                # Validator staking
│   ├── finality.zig               # Casper FFG
│   ├── sub_block.zig              # Sub-blocks 0.1s
│   ├── shard_config.zig           # 7 shards config
│   ├── shard_coordinator.zig      # Cross-shard routing
│   ├── metachain.zig              # EGLD metachain
│   ├── pq_crypto.zig              # liboqs FFI
│   ├── secp256k1.zig              # ECDSA real Zig
│   ├── schnorr.zig                # BIP-340 Schnorr
│   ├── bls_signatures.zig         # BLS12-381
│   ├── wallet.zig                 # 5 PQ addresses
│   ├── bip32_wallet.zig           # HD wallet BIP-32
│   ├── rpc_server.zig             # JSON-RPC HTTP
│   ├── ws_server.zig              # WebSocket push
│   ├── p2p.zig                    # P2P TCP networking
│   ├── sync.zig                   # Block sync
│   ├── storage.zig                # In-memory KV
│   ├── database.zig               # Persistență binară
│   ├── state_trie.zig             # Merkle Patricia Trie
│   └── ... (66 total)
│
├── test/                          # Teste Zig
│   ├── blockchain_test.zig        # Teste de bază
│   ├── phase2_crypto_test.zig     # Teste crypto Phase 2
│   ├── crypto_advanced_test.zig   # BLS, Schnorr, PQ
│   ├── mempool_test.zig           # Teste mempool
│   ├── sharding_test.zig          # Teste sharding
│   ├── consensus_test.zig         # Teste consensus
│   └── storage_test.zig           # Teste storage
│
├── tools/                         # 15+ utilitare Python
│   ├── ANALYSIS/                  # Analiză cod
│   ├── SECURITY/                  # Scanare securitate
│   ├── TESTING/                   # Test runner
│   ├── COMPARISON/                # Comparare blockchain-uri
│   ├── DOCUMENTATION/             # Genereare docs
│   ├── BRIDGE/                    # Bridge validators
│   └── MONITORING/                # Monitorizare
│
├── frontend/                      # React + TypeScript
│   ├── src/
│   │   ├── App.tsx                # SPA 5 pagini
│   │   ├── api/rpc-client.ts      # Wrapper RPC
│   │   ├── components/            # Stats, Wallet, BlockExplorer
│   │   └── pages/                 # Dashboard, GenesisCountdown
│   └── package.json
│
├── wallets/                       # Wallets JSON
├── genesis/                       # Config genesis
├── logs/                          # Loguri runtime
├── wiki-omnibus/                  # Documentație (16 fișiere)
└── build.zig                      # Build config Zig
```

### 2.2 Arhitectura Blockchain

```
┌─────────────────────────────────────────────────────────────┐
│                       METACHAIN                             │
│              (Notarizare shard headers)                     │
│                    Block time: 1s                           │
├─────────────────────────────────────────────────────────────┤
│  Shard 0  │  Shard 1  │  Shard 2  │  ...  │  Shard 6       │
│  (OMNI)   │  (LOVE)   │  (FOOD)   │       │  (VACATION)    │
│  10 sub   │  10 sub   │  10 sub   │       │  10 sub        │
│  0.1s     │  0.1s     │  0.1s     │       │  0.1s          │
├─────────────────────────────────────────────────────────────┤
│                    SUB-BLOCK LAYER                          │
│              10 sub-blocks × 100ms = 1s                     │
│            Soft finality la fiecare 100ms                   │
└─────────────────────────────────────────────────────────────┘
```

### 2.3 Flow-ul unei Tranzacții

```
1. USER → trimite TX via RPC/sendtransaction
         ↓
2. RPC SERVER → validează și adaugă în MEMPOOL
         ↓
3. MINER → preia TX din mempool (FIFO, anti-MEV)
         ↓
4. SUB-BLOCK → include TX în sub-block (0.1s)
         ↓
5. KEY-BLOCK → agregă 10 sub-blocks (1s)
         ↓
6. FINALITY → Casper FFG justification (2-3 blocks)
         ↓
7. CONFIRMED → TX finalizată, irreversibilă
```

---

## 3. Modulele Core (66 module)

### 3.1 Blockchain & Consens (13 module)

| Modul | Linii | Funcție | Status |
|-------|-------|---------|--------|
| `blockchain.zig` | ~400 | Chain management, PoW mining, difficulty retarget | ✅ |
| `block.zig` | ~150 | Block struct, hash, validation | ✅ |
| `blockchain_v2.zig` | ~450 | Sharded blockchain, binary codec | ✅ |
| `sub_block.zig` | ~200 | Sub-blocks 0.1s, KeyBlock aggregation | ✅ |
| `consensus.zig` | ~250 | PoS consensus, voting, quorum | ✅ |
| `finality.zig` | ~300 | Casper FFG finality gadget | ✅ |
| `staking.zig` | ~280 | Validator staking, rewards, slashing | ✅ |
| `governance.zig` | ~220 | On-chain governance, proposals | ✅ |
| `genesis.zig` | ~180 | Genesis block, 21M supply allocation | ✅ |
| `miner_genesis.zig` | ~250 | Genesis mining, 10 miners bootstrap | ✅ |
| `e2e_mining.zig` | ~150 | End-to-end mining tests | ✅ |
| `metachain.zig` | ~320 | EGLD-style metachain, notarizare | ✅ |
| `spark_invariants.zig` | ~180 | Ada/SPARK-style comptime verification | ✅ |

### 3.2 Sharding (6 module)

| Modul | Linii | Funcție | Status |
|-------|-------|---------|--------|
| `shard_config.zig` | ~200 | 7 shards config, validator assignment | ✅ |
| `shard_coordinator.zig` | ~280 | Cross-shard TX routing | ✅ |
| `sub_block.zig` | ~200 | Sub-block pool, 10 sloturi | ✅ |
| `compact_blocks.zig` | ~180 | Block compression | ✅ |
| `compact_transaction.zig` | ~220 | 161 bytes/TX (vs 432B standard) | ✅ |
| `witness_data.zig` | ~420 | SegWit-style witness separation | ✅ |

### 3.3 Cryptografie (12 module)

| Modul | Linii | Funcție | Status |
|-------|-------|---------|--------|
| `secp256k1.zig` | ~150 | ECDSA real Zig (zero deps) | ✅ |
| `schnorr.zig` | ~180 | BIP-340 Schnorr signatures | ✅ |
| `bls_signatures.zig` | ~200 | BLS12-381, aggregation, threshold | ✅ |
| `pq_crypto.zig` | ~350 | ML-DSA-87, Falcon, SLH-DSA, ML-KEM | ✅ |
| `crypto.zig` | ~200 | SHA256, HMAC, AES-256-GCM | ✅ |
| `ripemd160.zig` | ~200 | RIPEMD-160 pur Zig | ✅ |
| `bip32_wallet.zig` | ~350 | HD wallet BIP-32/39 real | ✅ |
| `wallet.zig` | ~400 | 5 PQ addresses, TX creation | ✅ |
| `key_encryption.zig` | ~250 | Password-based key encryption | ✅ |
| `multisig.zig` | ~220 | Multi-signature schemes | ✅ |
| `hex_utils.zig` | ~100 | Hex encoding/decoding | ✅ |
| `domain_minter.zig` | ~180 | PQ domain minting | ✅ |

### 3.4 Networking & P2P (10 module)

| Modul | Linii | Funcție | Status |
|-------|-------|---------|--------|
| `p2p.zig` | ~400 | TCP P2P, broadcast, peer management | ✅ |
| `network.zig` | ~350 | Network layer, connections | ✅ |
| `sync.zig` | ~300 | Block sync, stall detection | ✅ |
| `bootstrap.zig` | ~300 | PEX, peer discovery | ✅ |
| `rpc_server.zig` | ~450 | JSON-RPC 2.0 HTTP server | ✅ |
| `ws_server.zig` | ~280 | WebSocket real-time push | ✅ |
| `kademlia_dht.zig` | ~250 | Kademlia DHT for peer discovery | ✅ |
| `node_launcher.zig` | ~280 | Seed/Miner mode launcher | ✅ |
| `light_client.zig` | ~480 | SPV light client, fast sync | ✅ |
| `light_miner.zig` | ~350 | Light miner support | ✅ |

### 3.5 Storage & State (8 module)

| Modul | Linii | Funcție | Status |
|-------|-------|---------|--------|
| `storage.zig` | ~350 | In-memory KV store | ✅ |
| `database.zig` | ~300 | Binary persistence omnibus-chain.dat | ✅ |
| `state_trie.zig` | ~280 | Merkle Patricia Trie | ✅ |
| `archive_manager.zig` | ~250 | Block archiving, 75% compression | ✅ |
| `prune_config.zig` | ~230 | State pruning config | ✅ |
| `binary_codec.zig` | ~280 | Binary encoding/decoding | ✅ |
| `tx_receipt.zig` | ~200 | TX receipts, logs | ✅ |
| `witness_data.zig` | ~420 | Witness data management | ✅ |

### 3.6 Transaction & Mempool (5 module)

| Modul | Linii | Funcție | Status |
|-------|-------|---------|--------|
| `transaction.zig` | ~250 | TX struct, sign/verify | ✅ |
| `mempool.zig` | ~350 | FIFO mempool, anti-MEV | ✅ |
| `compact_transaction.zig` | ~220 | Compact TX format | ✅ |
| `payment_channel.zig` | ~300 | Hydra L2, HTLC | ✅ |
| `tx_receipt.zig` | ~200 | TX receipts | ✅ |

### 3.7 Ecosystem & Features (12 module)

| Modul | Linii | Funcție | Status |
|-------|-------|---------|--------|
| `mining_pool.zig` | ~250 | Dynamic mining pool | ✅ |
| `oracle.zig` | ~220 | Price oracle BID/ASK | ✅ |
| `bridge_relay.zig` | ~280 | Ethereum bridge relay | ✅ |
| `ubi_distributor.zig` | ~200 | UBI/Bread distribution | ✅ |
| `bread_ledger.zig` | ~180 | Bread voucher QR ledger | ✅ |
| `vault_engine.zig` | ~200 | BIP39 vault engine | ✅ |
| `vault_reader.zig` | ~100 | Named pipe vault reader | ✅ |
| `omni_brain.zig` | ~180 | Node type auto-detect | ✅ |
| `guardian.zig` | ~200 | Security monitoring | ✅ |
| `peer_scoring.zig` | ~180 | Peer reputation system | ✅ |
| `dns_registry.zig` | ~150 | DNS for peer addresses | ✅ |
| `synapse_priority.zig` | ~120 | Synapse scheduler | ✅ |

---

## 4. RPC API Complet

### 4.1 Endpoints

| Protocol | URL | Port |
|----------|-----|------|
| HTTP JSON-RPC | http://127.0.0.1 | 8332 |
| WebSocket | ws://127.0.0.1 | 8334 |
| P2P TCP | tcp://0.0.0.0 | 9000 |

### 4.2 Metode Blockchain

```bash
# Get block count
curl -X POST http://127.0.0.1:8332 \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"getblockcount","params":[],"id":1}'

# Response: {"result": 150, "id": 1}
```

| Metodă | Parametri | Return |
|--------|-----------|--------|
| `getblockcount` | - | Număr blocuri |
| `getblock` | `index: u32` | Block complet |
| `getlatestblock` | - | Ultimul bloc |
| `getblockhash` | `index: u32` | Block hash |
| `getbestblockhash` | - | Best chain tip |

### 4.3 Metode Wallet & TX

| Metodă | Parametri | Return |
|--------|-----------|--------|
| `getbalance` | - | Balance SAT + OMNI |
| `gettransactions` | `[address?]` | Array TX |
| `sendtransaction` | `[to, amount_sat]` | TX hash |
| `getmempoolsize` | - | Pending TX count |
| `createrawtransaction` | `[inputs, outputs]` | Raw TX hex |
| `signrawtransaction` | `[hex]` | Signed TX |

### 4.4 Metode Mining Pool

| Metodă | Parametri | Return |
|--------|-----------|--------|
| `registerminer` | `{id,name,address,hashrate}` | Success + minerCount |
| `minerkeepalive` | `address` | Success |
| `getminers` | - | Array miners activi |
| `getminerstatus` | - | Pool status detaliat |
| `getminerbalances` | - | Balances toți minerii |
| `getpoolstats` | - | Stats complete pool |

### 4.5 Metode Network & Sync

| Metodă | Parametri | Return |
|--------|-----------|--------|
| `getstatus` | - | Status complet nod |
| `getpeerinfo` | - | List peers conectați |
| `getconnectioncount` | - | Număr conexiuni |
| `getshardinginfo` | - | Shard config + status |
| `getmetachainheaders` | `[count?]` | Meta headers |

---

## 5. Criptografie Post-Quantum

### 5.1 Cele 5 Domenii PQ

| Prefix | Coin Type | Algoritm | Securitate | Use Case |
|--------|-----------|----------|------------|----------|
| `ob_omni_` | 777 | ML-DSA-87 + ML-KEM-768 | 256 bit | Default, general purpose |
| `ob_k1_` | 778 | ML-DSA-87 | 256 bit | High-security contracts |
| `ob_f5_` | 779 | Falcon-512 | 128 bit | Fast signing, small sigs |
| `ob_d5_` | 780 | ML-DSA-87 | 256 bit | Dilithium standard |
| `ob_s3_` | 781 | SLH-DSA-256s | 256 bit | Stateless, hash-based |

### 5.2 Algoritmi Implementați

```
ML-DSA-87 (Dilithium-5)
├── Parametri: NIST FIPS 204
├── Public Key: 2592 bytes
├── Secret Key: 4896 bytes
└── Signature: 4595 bytes max

Falcon-512
├── Parametri: NIST FIPS 206
├── Public Key: 897 bytes
├── Secret Key: 1281 bytes
└── Signature: 666 bytes max

SLH-DSA-256s (SPHINCS+)
├── Parametri: NIST FIPS 205
├── Public Key: 32 bytes
├── Secret Key: 64 bytes
└── Signature: 7856 bytes

ML-KEM-768 (Kyber)
├── Parametri: NIST FIPS 203
├── Public Key: 1184 bytes
├── Secret Key: 2400 bytes
├── Ciphertext: 1088 bytes
└── Shared Secret: 32 bytes
```

### 5.3 Derivație BIP-32

```
Path: m/44'/coin_type'/0'/0/index

Coin Types:
- 777 = OMNI (ML-DSA-87 + KEM)
- 778 = OMNI_LOVE (ML-DSA-87)
- 779 = OMNI_FOOD (Falcon-512)
- 780 = OMNI_RENT (ML-DSA-87)
- 781 = OMNI_VACATION (SLH-DSA)

Derivare reală cu HMAC-SHA512 (nu stub!)
```

---

## 6. Teste și Coverage

### 6.1 Teste în Module (Unit Tests)

| Modul | Teste | Status |
|-------|-------|--------|
| mempool.zig | 42 | ✅ All pass |
| sub_block.zig | 40 | ✅ All pass |
| genesis.zig | 78 | ✅ All pass |
| blockchain.zig | 72 | ✅ All pass |
| schnorr.zig | 16 | ✅ All pass |
| bls_signatures.zig | 16 | ✅ All pass |
| pq_crypto.zig | 13 | ✅ All pass |
| consensus.zig | 7 | ✅ All pass |
| staking.zig | 11 | ✅ All pass |
| finality.zig | 8 | ✅ All pass |
| storage.zig | 6 | ✅ All pass |
| **TOTAL** | **500+** | **✅ All pass** |

### 6.2 Fișiere de Test în `test/`

| Fișier | Scop | Teste |
|--------|------|-------|
| `blockchain_test.zig` | Integrare blockchain | 6+ |
| `phase2_crypto_test.zig` | Crypto Phase 2 | 8 |
| `crypto_advanced_test.zig` | BLS, Schnorr, PQ extins | 15+ |
| `mempool_test.zig` | Mempool + TX | 12+ |
| `sharding_test.zig` | Sharding complet | 18+ |
| `consensus_test.zig` | Consensus + Staking | 20+ |
| `storage_test.zig` | Storage + DB | 15+ |

### 6.3 Cum rulezi testele

```bash
# Teste individuale
zig test core/mempool.zig
zig test core/sub_block.zig
zig test core/pq_crypto.zig

# Grupuri de teste
zig build test-crypto    # Crypto tests
zig build test-chain     # Blockchain tests
zig build test-shard     # Sharding tests
zig build test-storage   # Storage tests
zig build test-pq        # Post-quantum tests
zig build test           # Toate testele
```

---

## 7. Tools și Utilitare

### 7.1 Structura `tools/` (organizat pe categorii)

```
tools/
├── ANALYSIS/
│   ├── blockchain_analyzer.py      # Analiză dependințe și metrici
│   └── code_metrics.py             # Complexitate cicomatică
│
├── SECURITY/
│   └── vulnerability_scanner.py    # Scanare CWE, securitate
│
├── TESTING/
│   ├── test_runner.py              # Orchestrare teste
│   └── test_validator.py           # Validare rezultate
│
├── COMPARISON/
│   └── blockchain_vs_comparison.py # Comparare cu BTC/ETH/SOL
│
├── DOCUMENTATION/
│   ├── doc_generator.py            # Genereare documentație
│   └── changelog_manager.py        # Management changelog
│
├── BRIDGE/
│   ├── bridge_validator.py         # Validare bridge
│   └── oracle_verifier.py          # Verificare oracle
│
├── MONITORING/
│   └── (monitoring tools)
│
└── PERFORMANCE/
    └── (benchmark tools)
```

### 7.2 Script-uri de Launch

| Script | Funcție |
|--------|---------|
| `start-genesis.sh` | Pornește genesis cu 10 miners |
| `launch-extra-miners.sh N` | Adaugă N miner extra |
| `start-omnibus-full.sh` | Full stack: seed + RPC + frontend |
| `start-all.sh` | Toate serviciile |
| `stop-all.sh` | Oprește tot |
| `monitor-miners.sh` | Monitorizare miner activi |
| `add-miners-staggered.sh` | Adaugă mineri cu delay |

---

## 8. Frontend și UI

### 8.1 Stack Frontend

- **Framework:** React 18 + TypeScript
- **Build:** Vite
- **Styling:** TailwindCSS
- **State:** React hooks
- **RPC Client:** Custom wrapper peste JSON-RPC 2.0
- **Real-time:** WebSocket (port 8334)

### 8.2 Pagini

| Pagină | URL | Funcție |
|--------|-----|---------|
| Dashboard | `/` | Stats live, block count, mempool |
| Genesis Countdown | `/genesis-countdown` | UI genesis launch |
| Block Explorer | `/explorer` | Listă blocuri + detalii |
| Wallet | `/wallet` | Balance + 5 adrese PQ |
| Miners | `/miners` | Status miner pool |
| Distribution | `/distribution` | Reward distribution viz |

### 8.3 Componente Principale

```typescript
// API Client
OmniBusRpcClient
├── getStatus()
├── getBalance()
├── sendTransaction(to, amount)
├── getBlockCount()
├── getLatestBlock()
├── getTransactions(address?)
└── getPoolStats()

// Components
├── Stats.tsx           # Stats cards, live polling
├── BlockExplorer.tsx   # Block list + modal detalii
├── Wallet.tsx          # Balance + addresses
└── GenesisCountdown.tsx # Genesis launch UI
```

---

## 9. Deployment și Launch

### 9.1 Quick Start (3 comenzi)

```bash
# 1. Build
zig build

# 2. Start genesis (10 miners)
bash start-genesis.sh

# 3. Adaugă 100 mineri extra
bash launch-extra-miners.sh 100
```

### 9.2 Configurare Genesis

```json
{
  "genesis": {
    "block_time_ms": 1000,
    "sub_block_time_ms": 100,
    "sub_blocks_per_block": 10,
    "shard_count": 7,
    "difficulty": 4,
    "reward_omni": 0.08333333,
    "halving_blocks": 126144000,
    "total_supply": 21000000,
    "miners": 10
  }
}
```

### 9.3 Dependințe Build

| Componentă | Versiune | Notă |
|------------|----------|------|
| Zig | 0.15.2 | Minim |
| Node.js | 18+ | Pentru pool + frontend |
| MinGW | 13+ | Pentru liboqs |
| liboqs | Latest | PQ crypto (opțional) |

---

## 10. Ecosistem și Integrări

### 10.1 Repo-uri în Ecosistem

```
OmniBus Ecosystem (8 repo-uri)
│
├── OmniBus-BlockChainCore     # Blockchain Layer 1 (Zig)
├── OmniBusSidebar            # Desktop C++ app (ImGui)
├── OmnibusWallet             # Python wallet (BIP39 + PQ)
├── OmniBus-HFT               # Trading HFT (Zig)
├── OmniBus-ExoCharts         # Charts (Zig)
├── OmniBus-Connect           # Exchange connectors (C++)
├── OmniBus-v5-CppMono        # Mono runtime wrapper
└── OmniBus-Zig-toolz         # Zig utilities
```

### 10.2 Integrare SuperVault

```
OmnibusSidebar.exe
        ↓ WinHTTP
    127.0.0.1:8332
        ↓ JSON-RPC
  omnibus-node.exe
        ↓ Named Pipe
  vault_service.exe
        ↓ DPAPI
   vault.dat (criptat)
```

### 10.3 Bridge Ethereum

```
OmniBus Chain ←→ Bridge Relay ←→ Sepolia Testnet
                    ↓
              USDC on-ramp/off-ramp
```

---

## Anexe

### A. Parametri Blockchain

| Parametru | Valoare | Notă |
|-----------|---------|------|
| Block Time | 1s | 10 sub-blocks × 100ms |
| Sub-block Time | 100ms | Soft finality |
| Difficulty Start | 4 hex zeros | Ajustabil |
| Block Reward | 0.08333333 OMNI | ~50 OMNI/10min |
| Halving Interval | 126,144,000 blocuri | ~4 ani |
| Max Supply | 21,000,000 OMNI | Ca Bitcoin |
| SAT per OMNI | 1,000,000,000 | Precizie nanomni |
| Shards | 7 | 0-6 |
| Sub-blocks/Block | 10 | 0-9 |

### B. Porturi Utilizate

| Port | Serviciu | Protocol |
|------|----------|----------|
| 8332 | RPC Server | HTTP JSON-RPC |
| 8334 | WebSocket | WS Push |
| 9000 | P2P Seed | TCP |
| 3000 | Frontend | HTTP |
| 6626 | P2P Node | TCP (OmniBus OS) |

### C. Resurse

- **GitHub:** https://github.com/SAVACAZAN/OmniBus-BlockChainCore
- **Zig Docs:** https://ziglang.org/documentation/master/
- **BIP-32:** https://github.com/bitcoin/bips/blob/master/bip-0032.mediawiki
- **NIST PQ:** https://csrc.nist.gov/projects/post-quantum-cryptography

---

**Document generat automat prin analiză completă a proiectului OmniBus-BlockChainCore.**

*Pentru actualizări, verificați wiki-omnibus/ și fișierele PHASE_*.md*
