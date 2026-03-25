# OmniBus-BlockChainCore — Wiki Index

## Proiect
Blockchain node în Zig 0.15.2, Windows native.
Build: `zig build` cu liboqs (MinGW), JSON-RPC 2.0 pe port 8332.

## Fișiere wiki

| Fișier | Conținut |
|--------|----------|
| PHASE_2_SUMMARY.md | Wallet + Crypto: BIP32/39, PQ domains, key encryption |
| PHASE_3_SUMMARY.md | Storage + Persistence: in-memory KV, RocksDB design |
| PHASE_4_SUMMARY.md | React Frontend: Explorer, Wallet, Stats, dark UI |
| PHASE_6_7_SUMMARY.md | Sub-blocks + Sharding + Pruning: 1.6TB → 50-100GB |
| PHASE_8_SUMMARY.md | SegWit-Style + State Trie + Light Client: 10-50GB |
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
| Phase 9+ | 📋 | - | Cross-shard, Ethereum bridge, P2P sync |

*Phase 2: secp256k1 real ✅, BIP32 derivare reala ✅, PQ via liboqs ✅ (Windows)

## Module core

| Fișier | Status | Descriere |
|--------|--------|-----------|
| core/main.zig | ✅ | Entry: blockchain + wallet + RPC thread + mining loop |
| core/blockchain.zig | ✅ | Chain, blocks, mempool, mining PoW |
| core/block.zig | ✅ | Block struct, hash, validation |
| core/transaction.zig | ✅ | TX struct, sign() secp256k1 real, verify() |
| core/wallet.zig | ✅ | fromMnemonic(), 5 adrese PQ, createTransaction() |
| core/bip32_wallet.zig | ✅ | HD derivare reala (HMAC-SHA512), 5 domenii PQ |
| core/secp256k1.zig | ✅ | ECDSA real: privkey→pubkey→hash160→sign→verify |
| core/ripemd160.zig | ✅ | RIPEMD-160 pur Zig |
| core/crypto.zig | ✅ | SHA256, SHA256d, HMAC-SHA256, AES-256 |
| core/pq_crypto.zig | ✅ | ML-DSA-87, Falcon-512, SLH-DSA-256s via liboqs |
| core/rpc_server.zig | ✅ | HTTP JSON-RPC 2.0, ws2_32.recv, 6 metode |
| core/vault_reader.zig | ✅ | Named Pipe → env var → dev mnemonic fallback |
| core/cli.zig | ✅ | Argumente CLI: mode/seed/miner |
| core/node_launcher.zig | ✅ | NodeLauncher, seed/miner mode, mining start |

## RPC API (port 8332)

| Metodă | Params | Return |
|--------|--------|--------|
| getblockcount | - | număr blocks |
| getbalance | - | address, balance, balanceOMNI, nodeHeight |
| getlatestblock | - | index, hash, timestamp, nonce, txCount |
| getmempoolsize | - | număr TX pending |
| getstatus | - | status, blockCount, mempoolSize, address, balance |
| sendtransaction | [to, amount_sat] | txid, from, to, amount, status |

## Adrese PQ (5 domenii)

| Prefix | Coin Type | Algoritm | Security |
|--------|-----------|----------|----------|
| ob_omni_ | 777 | ML-DSA-87 + KEM | 256 bit |
| ob_k1_ | 778 | ML-DSA-87 | 256 bit |
| ob_f5_ | 779 | Falcon-512 | 128 bit |
| ob_d5_ | 780 | Dilithium-5 | 256 bit |
| ob_s3_ | 781 | SLH-DSA-256s | 256 bit |

## Dependențe externe

- **liboqs** — `C:/Kits work/limaje de programare/liboqs-src/build/`
  - Compilat cu MinGW + CMake (-DOQS_USE_OPENSSL=OFF)
  - `liboqs.a` linkuit static în omnibus-node.exe

## TODO prioritar

1. `gettransactions` RPC endpoint (history TX per adresă)
2. RocksDB persistence (Phase 3 → disk)
3. P2P node sync protocol
4. Phase 5: agent system + trading
5. Ethereum bridge (USDC/Sepolia)
6. WebSocket real-time pentru frontend
7. Linux build (WSL/native)

## Conflicte documentare cunoscute

- PHASE_2_SUMMARY marchează BIP32 "✅ COMPLETE" — în realitate e implementat real (HMAC-SHA512) dar README-WALLET spune "XOR simplificat" (referință la versiunea veche din WSL)
- PHASE_3 = in-memory, PHASE_6-7 = assume disk — consistent, nu conflict
