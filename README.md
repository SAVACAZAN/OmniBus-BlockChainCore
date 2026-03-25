# OmniBus-BlockChainCore

**Blockchain post-quantum nativ Windows + Linux**
**Versiune:** 1.0.0-dev · **Limbă:** Zig 0.15.2 + Node.js + TypeScript/React
**GitHub:** https://github.com/SAVACAZAN/OmniBus-BlockChainCore

---

## Ce este

Nod blockchain complet cu criptografie post-quantum reală:
- **secp256k1 ECDSA** pur Zig (Bitcoin-compatible, zero dependențe externe)
- **RIPEMD-160** pur Zig (193 linii, testat cu standard vectors Bitcoin)
- **BIP-32/39 HD wallet** cu HMAC-SHA512 real, 5 domenii PQ
- **liboqs** — ML-DSA-87, Falcon-512, SLH-DSA-256s, ML-KEM-768
- **JSON-RPC 2.0** pe port 8332
- **Mining pool** Node.js cu înregistrare dinamică miners

---

## Build rapid

```bash
# Instalare Zig 0.15.2 (Windows)
winget install zig.zig

# Build
cd "C:\Kits work\limaje de programare\OmniBus-BlockChainCore"
zig build

# Rulare nod seed
.\zig-out\bin\omnibus-node.exe --mode seed --node-id node-1 --port 9000

# Rulare ca miner
.\zig-out\bin\omnibus-node.exe --mode miner --node-id miner-1 --seed-host 127.0.0.1 --seed-port 9000
```

**Prerequisit liboqs** (compilat cu MinGW):
```bash
git clone https://github.com/open-quantum-safe/liboqs liboqs-src
cd liboqs-src && mkdir build && cd build
cmake -G "MinGW Makefiles" -DOQS_USE_OPENSSL=OFF ..
mingw32-make -j4
```
Path așteptat: `C:\Kits work\limaje de programare\liboqs-src\build\lib\liboqs.a`

---

## Structura proiectului

```
OmniBus-BlockChainCore/
├── core/
│   ├── main.zig              Entry: vault reader, blockchain, wallet, RPC thread, mining
│   ├── blockchain.zig        Chain ArrayList, PoW mining SHA256d, mempool
│   ├── block.zig             Block struct, hash, validare
│   ├── transaction.zig       TX sign/verify secp256k1, SHA256d, VALID_PREFIXES
│   ├── wallet.zig            fromMnemonic(), 5 adrese PQ, createTransaction()
│   ├── bip32_wallet.zig      BIP-32/39 PBKDF2-HMAC-SHA512 real
│   ├── secp256k1.zig         ECDSA real via Zig stdlib (zero dep externe)
│   ├── ripemd160.zig         RIPEMD-160 complet pur Zig, 80 runde
│   ├── crypto.zig            SHA256, SHA256d, HMAC-SHA256/512
│   ├── pq_crypto.zig         liboqs FFI: ML-DSA-87, Falcon-512, SLH-DSA, KEM
│   ├── rpc_server.zig        HTTP JSON-RPC 2.0, ws2_32.recv, port 8332
│   ├── vault_reader.zig      Mnemonic: Named Pipe → env → dev default
│   ├── cli.zig               --mode / --node-id / --port / --hashrate
│   ├── node_launcher.zig     Seed / Miner mode, readyForMining
│   ├── network.zig           P2P peer management
│   ├── bootstrap.zig         Peer registration, stale cleanup 60s
│   ├── mining_pool.zig       Reward proporțional, inactive cleanup 300s
│   ├── blockchain_v2.zig     Sub-blocks 0.1s, 7 shards, pruning, binary codec
│   ├── compact_transaction.zig  161 bytes/TX (63% vs 432B)
│   ├── state_trie.zig        AccountState HashMap, merkle root SHA256
│   ├── light_client.zig      BlockHeader 200B, SPV, BloomFilter, fastSync
│   ├── storage.zig           In-memory KV: BlockStore, TxIndex, AddrIndex
│   └── database.zig          Database unified (RocksDB = TODO)
│
├── agent/
│   └── agent_manager.zig     Agent struct, AgentManager (3 sample agents)
│
├── frontend/                 TypeScript + React
│   └── src/
│       ├── App.tsx           SPA 5 pagini: dashboard/miners/distribution/blocks/network
│       ├── api/rpc-client.ts JSON-RPC 2.0 wrapper, 18 metode
│       ├── pages/GenesisCountdown.tsx
│       └── components/       Stats.tsx, BlockExplorer.tsx, Wallet.tsx
│
├── rpc-server.js             Mining pool Node.js: 18 metode RPC, balances.json
├── miner-client.js           Miner: registerminer + keepalive 5s
├── create-wallet.js          Generator wallet BIP-39 + ob_omni_ address
├── wallets/                  genesis-allocation.json, genesis_miners_*.json
├── wiki-omnibus/             Documentație completă (INDEX.md + OMNIBUS_ACADEMIC_REPORT.md)
└── build.zig                 Build config Zig 0.15.2 + liboqs linkage
```

---

## RPC API — port 8332

```bash
# Status nod
curl -s -X POST http://127.0.0.1:8332 \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"getstatus","params":[]}'

# Balance wallet
curl -s -X POST http://127.0.0.1:8332 \
  -d '{"jsonrpc":"2.0","id":1,"method":"getbalance","params":[]}'

# Trimite tranzacție (amount în SAT, 1 OMNI = 1e9 SAT)
curl -s -X POST http://127.0.0.1:8332 \
  -d '{"jsonrpc":"2.0","id":1,"method":"sendtransaction","params":["ob_omni_abc123",1000000000]}'
```

| Metodă | Descriere |
|--------|-----------|
| `getblockcount` | Număr blocuri în chain |
| `getbalance` | Address + balance OMNI + confirmed + nodeHeight |
| `getlatestblock` | Ultimul bloc: hash, index, nonce, txCount |
| `getmempoolsize` | TX în așteptare |
| `getstatus` | Status complet: blockCount, mempoolSize, address, balance |
| `sendtransaction` | Creează + semnează TX secp256k1 → mempool |

---

## Wallet — 5 Domenii Post-Quantum

| Prefix | CoinType | Algoritm | Security |
|--------|----------|----------|----------|
| `ob_omni_` | 777 | ML-DSA-87 + ML-KEM-768 | 256 bit |
| `ob_k1_` | 778 | ML-DSA-87 (Dilithium-5) | 256 bit |
| `ob_f5_` | 779 | Falcon-512 | 128 bit |
| `ob_d5_` | 780 | ML-DSA-87 | 256 bit |
| `ob_s3_` | 781 | SLH-DSA-256s (SPHINCS+) | 256 bit |

Derivare: `m/44'/coin_type'/0` via HMAC-SHA512 (BIP-32 complet)
Format adresă: `prefix` + primii 12 hex din `RIPEMD160(SHA256(pubkey))`

---

## Parametri Blockchain

| Parametru | Valoare |
|-----------|---------|
| Block time | 10s |
| Difficulty start | 4 zero hex (PoW SHA256d) |
| Block reward | 50 OMNI |
| 1 OMNI | 1,000,000,000 SAT |
| Supply maxim | 21,000,000 OMNI |
| Halving | la 210,000 blocuri |
| Signature | secp256k1 ECDSA |

---

## Mining Pool (Node.js)

```bash
# Generează wallets pentru miners
node create-wallet.js batch 10

# Start complet (pool + 10 genesis miners)
bash start-genesis.sh

# Adaugă miners extra
bash add-miners-staggered.sh 100 10 5   # 100 miners, batch 10, delay 5s

# Monitorizare
curl -s -X POST http://127.0.0.1:8332 \
  -d '{"jsonrpc":"2.0","id":1,"method":"getpoolstats","params":[]}'
```

Pool features:
- Zero hardcoding — miners se înregistrează dinamic via `registerminer`
- Keepalive timeout 30s (auto-remove miners inactivi)
- Reward distribuit egal la toți miners activi
- `balances.json` persistent

---

## Tests

```bash
zig build test-crypto    # secp256k1, BIP32, SHA256d
zig build test-pq        # ML-DSA-87, Falcon-512, SLH-DSA-256s, ML-KEM-768
zig build test-wallet    # wallet complet + PQ signing (Test H — toate 5 domenii)
zig build test           # toate testele
```

---

## Integrare SuperVault

Mnemonicul se citește automat în ordine de prioritate:
1. Named Pipe `\\.\pipe\OmnibusVault` (dacă `vault_service.exe` rulează)
2. Env var `OMNIBUS_MNEMONIC`
3. Dev default (`abandon` × 11 + `about`)

```bash
set OMNIBUS_MNEMONIC=word1 word2 ... word12
.\zig-out\bin\omnibus-node.exe --mode seed
```

---

## Status implementare

| Componentă | Status | Scor |
|------------|--------|------|
| Crypto (secp256k1, BIP32, PQ liboqs) | Funcțional | 90% |
| Blockchain (blocks, PoW, mempool) | Funcțional | 90% |
| Transaction signing (ECDSA real) | Funcțional | 95% |
| RPC Server JSON-RPC 2.0 | Funcțional | 95% |
| Mining Pool Node.js | Funcțional | 95% |
| React Frontend | Funcțional | 85% |
| SuperVault integration | Funcțional | 90% |
| Storage / Persistență disc | TODO | 30% |
| P2P Network TCP real | Parțial | 35% |
| Trading Agent | Planificat | 0% |

**Audit complet:** `wiki-omnibus/OMNIBUS_ACADEMIC_REPORT.md`

---

## Legătură cu OmnibusSidebar

`mod_wallet.cpp` din OmnibusSidebar (C++) se conectează direct la acest nod via WinHTTP:
```
OmnibusSidebar.exe → HTTP POST 127.0.0.1:8332 → omnibus-node.exe
```
Aceleași prefixe adrese (`ob_omni_`, `ob_k1_`, etc.) și aceleași coin types (777-781) în ambele proiecte.
