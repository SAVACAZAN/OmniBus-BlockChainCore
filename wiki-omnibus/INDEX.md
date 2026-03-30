# OmniBus-BlockChainCore — Wiki Index

## Proiect
Blockchain node în Zig 0.15.2, Windows native.
Build: `zig build` cu liboqs (MinGW), JSON-RPC 2.0 pe port 8332.
Ecosistem: 8 repo-uri — OmniBus OS + BlockChainCore + HFT + Sidebar + ExoCharts + Connect + v5-CppMono + Zig-toolz.

## Fișiere wiki-kimi-omnibus (Nou - Generat 2026-03-30)

| Fișier | Conținut | Prioritate |
|--------|----------|------------|
| [wiki-kimi-omnibus/00-OMNIBUS-COMPLETE-GUIDE.md](wiki-kimi-omnibus/00-OMNIBUS-COMPLETE-GUIDE.md) | Ghid complet 360° al proiectului | ⭐⭐⭐ MUST READ |
| [wiki-kimi-omnibus/01-MODULE-CATALOG.md](wiki-kimi-omnibus/01-MODULE-CATALOG.md) | Catalog complet 69 module | ⭐⭐⭐ MUST READ |
| [wiki-kimi-omnibus/02-API-REFERENCE.md](wiki-kimi-omnibus/02-API-REFERENCE.md) | Referință API JSON-RPC 2.0 | ⭐⭐⭐ MUST READ |
| [wiki-kimi-omnibus/INDEX.md](wiki-kimi-omnibus/INDEX.md) | Index documentație kimi | ⭐⭐ MUST READ |

## Fișiere wiki (existente)

| Fișier | Conținut |
|--------|----------|
| PHASE_2_SUMMARY.md | Wallet + Crypto: BIP32/39, PQ domains, key encryption |
| PHASE_3_SUMMARY.md | Storage + Persistence: in-memory KV, RocksDB design |
| PHASE_4_SUMMARY.md | React Frontend: Explorer, Wallet, Stats, dark UI |
| PHASE_6_7_SUMMARY.md | Sub-blocks + Sharding + Pruning: 1.6TB → 50-100GB |
| PHASE_8_SUMMARY.md | SegWit-Style + State Trie + Light Client: 10-50GB |
| **PHASE_9_PLUS_AND_ECOSYSTEM.md** | **Sesiuni 2026-03-26: fix-uri, devieri, propuneri toate 8 repo-uri** |
| **OMNIBUS_OS_MODULES.md** | **OmniBus OS bare-metal: 54 module, IPC, blockchain_os, omnibus_blockchain_os, integrare BlockChainCore** |
| OMNI_ARCHITECTURE_GENESIS.md | Parametri economici, halvings, sharding, Ada Spark, HDD/SSD |
| enciclopedia.md | Referință enciclopedică completă: 8 repo-uri, protocoale, economie |
| OMNIBUS_ACADEMIC_REPORT.md | Raport academic |
| POOL.md | Mining Pool: dynamic registration, fair rewards |
| QUICK_START.md | 3-step bootstrap: genesis + extra miners |
| TROUBLESHOOTING.md | Port conflicts, miner registration, cleanup |
| CLAUDE_MEMORY.md | Fix-uri aplicate: miner-manager, run.sh, port conflicts |
| OMNIBUS_L2_STARTER.md | L2 starter notes |

## Faze implementare

| Fază | Status | Cod | Descriere |
|------|--------|-----|-----------|
| Phase 1 | ✅ | ~1,500 linii | Core blockchain: PoW, blocks, mempool, RPC |
| Phase 2 | ✅* | ~1,150 linii | Wallet BIP32/39, secp256k1 real, 5 PQ domains |
| Phase 3 | ✅ | ~600 linii | Storage in-memory (RocksDB = future) |
| Phase 4 | ✅ | ~1,300 linii | React frontend: explorer, wallet, stats |
| Phase 5 | ⏳ | - | Agent & Trading (planificat) |
| Phase 6-7 | ✅ | ~1,810 linii | Sub-blocks, sharding, pruning, compression |
| Phase 8 | ✅ | ~1,060 linii | SegWit-style, state trie, light client |
| Phase 9+ | 📋 | - | Cross-shard, Ethereum bridge, P2P sync real |
| **Sprint 1-6** | ✅ | 125+ teste | Metachain/Sharding/PaymentChannel/Oracle/Vault/OmniBrain |
| **OmniBus OS Phase 66-67** | ✅ | 3 module noi | omnibus_network_os (UDP real), miner_coordinator_os, IPC 0x86–0x88 |
| **OmniBus OS S1-S6 (Phase 71–80)** | ✅ | 10 module noi | quantum_resistant_crypto_os + pqc_gate_os + 8 security modules |
| **BlockChainCore S6** | ✅ | PEX + Sync | bootstrap PEX, downloadBlocks, applyBlock, mldsaSign/Verify |
| **Sprint S7** | ✅ | Ecosystem fixes | HFT Zig 0.15 fix, network.zig broadcast real, OmniBus-Connect 100% |

*Phase 2: secp256k1 real ✅, BIP32 derivare reala ✅, PQ via liboqs ✅ (Windows)
**Sprint 1-6: implementate în sesiunile 2026-03 — 1261/1263 teste trec (2 failing, vezi PHASE_9)

## Module core

| Fișier | Status | Descriere |
|--------|--------|-----------|
| core/main.zig | ✅ | Entry: blockchain + wallet + RPC thread + mining loop + **metachain/shard integrat** |
| core/blockchain.zig | ✅ | Chain, blocks, mempool, mining PoW |
| core/block.zig | ✅ | Block struct, hash, validation |
| core/transaction.zig | ✅ | TX struct, sign() secp256k1 real, verify() |
| core/wallet.zig | ✅ | fromMnemonic(), 5 adrese PQ, createTransaction() |
| core/secp256k1.zig | ✅ | ECDSA real: privkey→pubkey→hash160→sign→verify |
| core/bip32_wallet.zig | ✅ | HD derivare reală (HMAC-SHA512), BIP-44 paths, 5 domenii PQ |
| core/ripemd160.zig | ✅ | RIPEMD-160 pur Zig (193 linii, Bitcoin-compatible) |
| core/crypto.zig | ✅ | SHA256, SHA256d, HMAC-SHA256, AES-256 |
| core/pq_crypto.zig | ✅ | ML-DSA-87, Falcon-512, SLH-DSA-256s via liboqs |
| core/rpc_server.zig | ✅ | HTTP JSON-RPC 2.0, ws2_32.recv, **39 metode** |
| core/vault_reader.zig | ✅ | Named Pipe → env var → dev mnemonic fallback |
| core/cli.zig | ✅ | Argumente CLI: mode/seed/miner |
| core/node_launcher.zig | ✅ | NodeLauncher, seed/miner mode, mining start |
| core/metachain.zig | ✅ | EGLD-style metachain, beginMetaBlock/addShardHeader/finalize |
| core/shard_coordinator.zig | ✅ | 4 sharduri, getShardForAddress() |
| core/payment_channel.zig | ✅ | Hydra L2, HTLC |
| core/spark_invariants.zig | ✅ | Ada/SPARK Zig comptime — 17/17 invarianți |
| core/oracle.zig | ✅ | BID/ASK per exchange (nu median global), bestAsk/bestBid |
| core/bridge_relay.zig | ✅ | Ethereum bridge relay |
| core/domain_minter.zig | ✅ | Mintare domenii PQ |
| core/vault_engine.zig | ✅ | Mnemonic BIP39 → vault |
| core/ubi_distributor.zig | ✅ | UBI/paine/epoch reward |
| core/bread_ledger.zig | ✅ | BreadVoucher QR ledger |
| core/os_mode.zig | ✅ | Detectare mod OS |
| core/synapse_priority.zig | ✅ | Synapse scheduler priority |
| core/omni_brain.zig | ✅ | NodeType auto-detect: full/trading/validator/light |
| core/archive_manager.zig | ✅ | Compresie blocuri vechi |
| core/light_miner.zig | ✅ | Light miner support |
| core/mining_pool.zig | ✅ | Pool dinamic, rewards fair |
| core/bootstrap.zig | ✅ | Peer discovery, seed node |
| core/sync.zig | ✅ | Block sync, stall detection |
| core/network.zig | ✅ | P2P connections, broadcast real (broadcast_fn pointer → P2PNode.broadcastBlock) |
| core/mempool.zig | ✅ | TX pool, size tracking |
| core/database.zig | ✅ | Persistență binară omnibus-chain.dat |
| core/storage.zig | ✅ | KV storage, fix deinit memory leak |
| core/genesis.zig | ✅ | GenesisState, NetworkConfig (mainnet/testnet), genesis block validation |
| core/consensus.zig | ✅ | ConsensusEngine, PoW validation, modular pt PBFT |
| core/p2p.zig | ✅ | TCP real transport, binary protocol, peer connections, broadcastBlock |
| core/sub_block.zig | ✅ | 10 sub-blocks × 100ms → 1 KeyBlock, SubBlockEngine |
| core/blockchain_v2.zig | ✅ | Enhanced chain: sub-blocks, sharding, binary encoding, pruning |
| core/shard_config.zig | ✅ | 7-way sharding, load balancing, shard assignment |
| core/binary_codec.zig | ✅ | Varint encoding, 93% compression, block serialization |
| core/prune_config.zig | ✅ | Configurable retention, max 10K blocks, auto-prune |
| core/compact_transaction.zig | ✅ | SegWit-style compact TX, 161 bytes/TX (63% reduction) |
| core/witness_data.zig | ✅ | Signature witness separation, 95% reduction |
| core/state_trie.zig | ✅ | AccountState Merkle trie, 50MB vs 1.6TB pt 1M+ accounts |
| core/light_client.zig | ✅ | SPV proofs, BloomFilter, 200B headers, mobile sync |
| core/key_encryption.zig | ✅ | AES-256 key encryption, password verification |
| core/miner_genesis.zig | ✅ | Genesis allocation for initial miners |
| core/e2e_mining.zig | ✅ | End-to-end mining integration test |
| core/ws_server.zig | ✅ | WebSocket server port 8334, real-time push la React frontend |
| core/finality.zig | ✅ | Casper FFG finality, checkpoints, attestations, supermajority |
| core/governance.zig | ✅ | Governance proposals, voting, parameter updates, veto |
| core/staking.zig | ✅ | Validator staking, slashing (equivocation/downtime), unbonding |
| core/chain_config.zig | ✅ | Chain config (mainnet/testnet/regtest), fee estimation |
| core/peer_scoring.zig | ✅ | Peer reputation scoring, banning peers |
| core/dns_registry.zig | ✅ | Decentralized DNS registry cu renewal periods |
| core/guardian.zig | ✅ | Account guardians, activation delay 20K blocks |
| core/compact_blocks.zig | ✅ | Compact block relay, ~90% bandwidth reduction |
| core/kademlia_dht.zig | ✅ | Kademlia DHT routing, XOR distance, peer discovery |
| core/schnorr.zig | ✅ | BIP-340 Schnorr signatures over secp256k1 |
| core/multisig.zig | ✅ | M-of-N multisig, timelock contracts |
| core/bls_signatures.zig | ✅ | BLS threshold signatures (t-of-n) |
| core/tx_receipt.zig | ✅ | Transaction receipts cu event logs |
| core/hex_utils.zig | ✅ | Shared hex/hash utility functions |
| core/benchmark.zig | ✅ | Performance benchmarks for core operations |
| core/miner_wallet.zig | ✅ | Miner-specific wallet functionality |
| core/script.zig | ✅ | Transaction scripting engine (Bitcoin-style) |

## RPC API (port 8332) — 39 metode

| Metodă | Params | Return |
|--------|--------|--------|
| getblockcount | - | număr blocks |
| getbalance | - | address, balance, balanceOMNI, nodeHeight |
| getlatestblock | - | index, hash, timestamp, nonce, txCount |
| getmempoolsize | - | număr TX pending |
| getstatus | - | status, blockCount, mempoolSize, address, balance |
| sendtransaction | [to, amount_sat] | txid, from, to, amount, status |
| gettransactions | [address?] | array TX: txid/from/to/amount/status/direction/blockHeight |
| registerminer | [miner_id, address] | status, miner_id |
| getpoolstats | - | active_miners, total_blocks, rewards |
| getaddressbalance | [address] | address, balance, balanceOMNI |
| getmempoolstats | - | size, bytes, oldest_tx, fee_stats |
| getpeers | - | array peers: id, host, port, latency |
| getsyncstatus | - | local_height, network_height, syncing |
| getnetworkinfo | - | version, peers, protocol, uptime |
| getblock | [index] | block object complet |
| getblocks | [from, count?] | array blocks |
| getminerstats | - | hashrate, blocks_mined, rewards |
| getminerinfo | [miner_id] | miner details |
| getnodelist | - | array nodes in retea |
| generatewallet | - | Generate new wallet keypair |
| estimatefee | [blocks?] | Fee estimation per byte |
| getaddresshistory | [address] | Full TX history for address |
| getnonce | [address] | Next nonce for address |
| gettransaction | [txid] | Single TX by hash |
| listtransactions | [count?, skip?] | Recent transactions list |
| getheaders | [from, count?] | Block headers for light clients |
| getmerkleproof | [txid] | Merkle proof for TX inclusion |
| getperformance | - | Node performance metrics |
| getstakinginfo | - | Staking stats, validators, rewards |
| getslashhistory | - | Slashing events history |
| submitslashevidence | [evidence] | Submit validator misbehavior proof |
| createmultisig | [m, pubkeys[]] | Create M-of-N multisig address |
| sendmultisig | [to, amount, sigs[]] | Send from multisig |
| openchannel | [peer, amount] | Open payment channel (L2) |
| closechannel | [channel_id] | Close payment channel |
| channelpay | [channel_id, amount] | Pay through channel |
| getchannels | - | List open payment channels |
| sendopreturn | [data] | Send OP_RETURN TX (data embed) |
| minersendtx | [miner_id, to, amount] | Miner-initiated transaction |

*gettransactions: scanare mempool + blocuri, filtru opțional pe adresă*

## Adrese PQ (5 domenii)

| Prefix | Coin Type | Algoritm | Security |
|--------|-----------|----------|----------|
| ob_omni_ | 777 | ML-DSA-87 + KEM | 256 bit |
| ob_k1_ | 778 | ML-DSA-87 | 256 bit |
| ob_f5_ | 779 | Falcon-512 | 128 bit |
| ob_d5_ | 780 | Dilithium-5 | 256 bit |
| ob_s3_ | 781 | SLH-DSA-256s | 256 bit |

## Dependențe externe

- **liboqs static** (BlockChainCore) — `C:/Kits work/limaje de programare/liboqs-src/build/`
  - Compilat cu MinGW + CMake (-DOQS_USE_OPENSSL=OFF)
  - `liboqs.a` linkuit static în omnibus-node.exe
- **liboqs DLL** (OmnibusWallet Python) — `C:\Users\cazan\_oqs\liboqs.dll`
  - Compilat cu BUILD_SHARED_LIBS=ON, MinGW Makefiles
  - Folosit via ctypes în pq_sign.py (nu liboqs-python, care e stricat pe Windows)
  - Algoritmi confirmați: `ML-DSA-87`, `Falcon-512`, `SLH_DSA_PURE_SHAKE_256S`

## TODO prioritar (actualizat 2026-03-27)

### OmniBus OS (make build ✅ — 50+ module cu cod real)
1. ~~miner_coordinator_os~~ ✅ Phase 67 implementat (1896B)
2. ~~omnibus_network_os DEV_MODE=false~~ ✅ UDP E1000 real (1572B)
3. ~~IPC miner_coordinator ↔ omnibus_blockchain~~ ✅ opcodes 0x86/0x87/0x88
4. ~~miner_coordinator_os → `p2p_node.zig` DEV_MODE=false~~ ✅ port 6626 real, seeds 10.0.2.2/10.0.2.15, poll_recv() activ
5. `on_ramp_os`, `staking_boost_os`, `status_token_os` — export symbols fix ✅

### BlockChainCore
6. ~~RocksDB persistence~~ ✅ database.zig: binar OMNI, appendBlock O(1), atomic rename
7. ~~P2P full sync~~ ✅ p2p.zig: TCP real, startListener, broadcastBlock, applyBlocksFromPeer
8. ~~WebSocket real-time pentru frontend React~~ ✅ ws_server.zig port 8334, Stats.tsx live push
9. ~~Difficulty auto-retarget la fiecare 2016 blocuri~~ ✅ blockchain.zig: retargetDifficulty(), clamp ±4x, [1..256]

### OmnibusSidebar / SuperVault
10. ~~mod_wallet.cpp → `gettransactions` RPC vizibil în UI~~ ✅
11. ~~vault_manager_gui.cpp → update opcodes 0x41–0x4C~~ ✅ v3.0: status FREE/PAID/NOTPAID, SET_STATUS 0x46

### Alte repo-uri
12. ~~HFT-MultiExchange: Zig 0.14 → 0.15.2 upgrade (gzip fix)~~ ✅ DONE (std.Io.Writer.Allocating → ArrayList)
13. ~~ExoCharts: Zig 0.12 → 0.15.2 upgrade~~ ✅ N/A — deja Zig 0.15, fără probleme
14. ~~OmniBus-Connect: live trading auth complet~~ ✅ DONE — WinCrypt real deja 100%

## Devieri față de concept inițial

| # | Parametru | Concept inițial | Implementat real |
|---|-----------|----------------|-----------------|
| D1 | Block time | 10s | **1s** cu 10 micro-blocks × 100ms |
| D2 | Reward | 50 OMNI/bloc | **0.08333333 OMNI/bloc** (=50 OMNI/10min) |
| D3 | Halving | 210,000 blocuri | **126,144,000 blocuri** (~4 ani la 1 bloc/s) |
| D4 | Domenii PQ Python | 5 domenii | **4 domenii** (vacation=food, ob_omni_ lipsă) |
| D5 | Vault | Windows only | **Cross-platform**: DPAPI Win + libsodium Linux |
| D6 | SLH-DSA name | SLH-DSA-SHAKE-256s | **SLH_DSA_PURE_SHAKE_256S** (DLL MinGW) |
| D7 | sendtransaction | Via SuperVault | **Direct WinHTTP → :8332** (corect, nu needs vault) |
| D8 | omnibus_blockchain_os memory | 64KB | **512KB code + 512KB data** (BSS prea mare pentru tabele) |
| D9 | wallet_manager.ld | 64KB | **2MB code** (stubs BIP32/secp256k1 depășesc 1.2MB) |
| D10 | miner_coordinator IPC opcodes | 0x74/0x75/0x76 | **0x86/0x87/0x88** (0x74–0x76 ocupate de airdrop/stake) |
| D11 | p2p_node seed peers | 10.0.0.1–3 | **10.0.2.2 + 10.0.2.15** (QEMU NAT gateway + guest loopback) |

## Parametri economici (din blockchain.zig)

| Parametru | Valoare | Note |
|-----------|---------|------|
| MAX_SUPPLY_SAT | 21,000,000 × 1e9 | Fixed supply |
| BLOCK_REWARD_SAT | 8,333,333 | ≈0.0083 OMNI/bloc |
| HALVING_INTERVAL | 126,144,000 blocks | ~4 ani la 1 bloc/s |
| TARGET_BLOCK_TIME_S | 1 | Cu 10 sub-blocks × 100ms |
| RETARGET_INTERVAL | 2,016 blocks | Bitcoin-style |
| MIN_DIFFICULTY | 1 | Minim permis |
| MAX_DIFFICULTY | 256 | Full SHA-256 range |
| FEE_BURN_PCT | 50% | EIP-1559 style, jumătate arse |
| TX_MIN_FEE | 1 SAT | Anti-spam |
| COINBASE_MATURITY | 100 blocks | Reward spendable după 100 blocks |
| DUST_THRESHOLD_SAT | 100 | TX sub 100 SAT = dust |
| SAT/OMNI | 1,000,000,000 (1e9) | **NU** 1e8 ca Bitcoin |

## Conflicte documentare cunoscute

- PHASE_2_SUMMARY marchează BIP32 "✅ COMPLETE" — implementat real (HMAC-SHA512) dar README-WALLET vechi spune "XOR simplificat" (referință la versiunea WSL anterioară)
- PHASE_3 = in-memory, PHASE_6-7 = assume disk — consistent, nu conflict
- enciclopedia.md menționează 6 repo-uri — în realitate sunt **8** (ExoCharts + Zig-toolz adăugate ulterior)
- CLAUDE.md (root) are block time 10s, max TX 100KB — deviat la 1s (vezi D1 mai sus)
- `agent/agent_manager.zig` și `scripts/start-omnibus-full.ps1` folosesc 1e8 SAT/OMNI — **BUG**, trebuie 1e9
- Total module core/: **69 fișiere .zig** (nu 54 — acelea sunt modulele OmniBus OS bare-metal)
- Total RPC methods: **39** (nu 19 — actualizat 2026-03-31)
- Total funcții publice documentate: **873**
- Total structuri documentate: **217**
