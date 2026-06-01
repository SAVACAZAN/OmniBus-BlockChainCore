# DeepSearch Prompt — Port OmniBus blockchain to C++ (full node, no stubs)

**proj**: `omnibus-node-cpp`
**run**: `2026-06-01-cpp-v1`
**target files**: `100-150` (FULL port — NOT a minimal subset). Chunk across multiple responses if needed.

**Coverage rule**: produce **EVERY file needed** for a working node — header + source for every module listed below, every test file, every CMake target, every helper. The Rust sibling port at `core-rust/src/` already has ~70 files and is itself only ~35% of the Zig source (which is ~338 files). Aim higher than Rust: complete every header AND its corresponding .cpp implementation. If a Zig module exists (anything in `core/*.zig`) and isn't trivially deprecated, it must have a C++ counterpart.
**input attachments** (you upload these before running):
- Entire `1_CORE/BlockChainCore/core/` directory (Zig source, ~338 files)
- Entire `1_CORE/BlockChainCore/core-rust/src/` directory (Rust sibling port, ~70 files)
- `1_CORE/BlockChainCore/CLAUDE.md` (parameters + DEX rules)
- `1_CORE/BlockChainCore/EVM_MODULE_DESIGN.md`

---

## Task

You are porting the OmniBus blockchain to **C++20** as a third sibling implementation alongside the existing Zig (`core/`) and Rust (`core-rust/`) ports. The C++ port must:

1. **Wire-compatible** with both Zig and Rust nodes — same TCP message format byte-for-byte. Two C++ nodes can peer with each other; a C++ node can peer with a Zig node and with a Rust node.
2. **Chain-compatible** — produces identical block hashes, identical state roots, identical chain.dat binary files.
3. **No stubs** — every function fully implemented. If a sub-system has hardware backends (GPU/ASIC mining), provide complete CPU implementation and leave hardware as separate `// TODO: hardware backend` comments only inside named function bodies.

## Hard constraints (NON-NEGOTIABLE, copy from Zig source)

These are protocol-level invariants. Compute them once from the Zig source files; the C++ port MUST reproduce them byte-for-byte:

| Value | Source | Mandatory |
|---|---|---|
| Genesis hash (all 4 networks) | `core/genesis.zig` | `82ec46e83af37b1ea0e6b3fe66a8f04795a8e8aae7db414d451eff1154245982` |
| Genesis timestamp | `core/genesis.zig` | `1743000000` (2026-03-26 UTC) |
| Network magics | `core/genesis.zig` | mainnet=`OMNI`, testnet=`TEST`, devnet=`DEVN`, regtest=`REGT` |
| Block reward sat | `core/consensus_params.zig` | `8333333` |
| Halving interval | `core/consensus_params.zig` | `126144000` blocks |
| Target block time | `core/consensus_params.zig` | `1` second |
| Sub-blocks per block | `core/consensus_params.zig` | `10` (40 ms interval each) |
| SAT per OMNI | `core/consensus_params.zig` | `1000000000` (1e9) |
| Max supply | `core/consensus_params.zig` | `21000000` OMNI (21e15 sat) |
| Difficulty retarget | `core/consensus_params.zig` | every `2016` blocks; `new = old * 2016 / clamp(actual, 504, 8064)` |
| Max block size | `core/consensus_params.zig` | `1048576` bytes (1 MiB) |
| Max block tx | `core/consensus_params.zig` | `4096` |
| Coinbase maturity | `core/consensus_params.zig` | `100` blocks |
| Fee burn pct | `core/consensus_params.zig` | `50%` |
| Native bech32 HRP | `core/bech32.zig::OB_HRP` | `"ob"` (NOT `"omni"`) |
| Native address example | derived | `ob1q…` (P2WPKH bech32 v0) |
| EVM chain ID | `core-rust/src/state.rs` | `7771` |
| RPC port | by convention | `8332` |
| WebSocket port | by convention | `8334` |
| EVM JSON-RPC port | by convention | `8333` |
| P2P default port | by convention | `9000` |
| PQ scheme prefixes | `core/wallet.zig::PqAddressPrefix` + memory `project_omnibus_pq_address_prefixes` | soulbound: `ob_k1_`, `ob_f5_`, `ob_d5_`, `ob_s3_`; transferable: `obk1_`, `obf5_`, `obd5_`, `obs3_` |
| DEX pair_id | `CLAUDE.md` | 0=OMNI/USDC, 2=LCX/USDC, 3=ETH/USDC, 5=OMNI/LCX, 6=OMNI/ETH; pair_id 1+4 RESERVED |
| BIP-44 OMNI native coin_type | wallet.zig | `777'` |
| BIP-44 EVM coin_type | standard | `60'` |
| DB file format version | `core/database.zig::DB_VERSION` | `4` |

## Expected file layout

Use this exact layout (POSIX paths). Modern C++20, header-only where it makes sense.

```
core-cpp/
├── CMakeLists.txt
├── README.md
├── include/omnibus/
│   ├── types.hpp            // Address, Hash256, U256, U128, Sig64
│   ├── codec.hpp            // LEB128 varint, LE u8/u16/u32/u64, lp1/lp4
│   ├── crypto/
│   │   ├── sha256.hpp       // SHA-256 (use OpenSSL/libsodium)
│   │   ├── keccak.hpp       // Keccak-256 for EVM
│   │   ├── ripemd160.hpp
│   │   ├── secp256k1.hpp    // wraps libsecp256k1 — compressed/uncompressed pubkey, hash160
│   │   ├── bech32.hpp       // HRP="ob"
│   │   ├── bip32.hpp        // BIP-39 PBKDF2-HMAC-SHA512 + BIP-32 CKD
│   │   └── pq.hpp           // liboqs: ML-DSA-87, Falcon-512, SLH-DSA-256s, ML-KEM-768
│   ├── wallet/
│   │   ├── hd.hpp           // omni_address(idx) m/44'/777'/.., evm_address(idx) m/44'/60'/..
│   │   └── address.hpp      // EIP-55 checksum + Address kinds
│   ├── consensus/
│   │   ├── params.hpp       // hard constants table above
│   │   ├── block.hpp        // Block, Tx, Merkle root (hash matches Zig)
│   │   ├── sub_block.hpp    // SubBlock, KeyBlock
│   │   ├── genesis.hpp      // build_genesis_block(network)
│   │   ├── pow.hpp          // SHA-256d + target check + retarget formula
│   │   ├── finality.hpp     // Casper FFG attestation + checkpoint
│   │   └── mempool.hpp      // FIFO + BIP-125 RBF
│   ├── storage/
│   │   ├── chain_db.hpp     // chain.dat v4 (8 sections, CRC32-IEEE per section)
│   │   ├── state_trie.hpp
│   │   └── compact_tx.hpp   // 161-byte CompactTransaction
│   ├── p2p/
│   │   ├── wire.hpp         // MsgHeader 9B, Hello 79B, Welcome 46B, Stable 10B, BlockAnnounce 90B V2
│   │   ├── peer.hpp         // TCP connection + handshake state
│   │   ├── scoring.hpp      // peer reputation + persistent ban list
│   │   ├── sync.hpp         // BlockHeader V3 130B, SyncManager
│   │   ├── bootstrap.hpp    // PeerManager, SEED_PEERS, /16 anti-eclipse
│   │   └── node.hpp         // P2PNode orchestrator (accept loop, miner dialer)
│   ├── dex/
│   │   ├── pair.hpp         // ASSET_CHAINS table, PAIR_ROUTES
│   │   ├── order.hpp
│   │   ├── matching.hpp     // price-time FIFO matcher with Merkle orderbook root
│   │   ├── htlc.hpp         // preimage backend-only, Init/BothLocked/Claimed/TimedOut
│   │   ├── grid.hpp         // create/cancel/tick → fills + follow_orders
│   │   └── oracle.hpp
│   ├── identity/
│   │   ├── did.hpp          // did:omnibus:<base58>
│   │   ├── obm.hpp          // 1-byte badges, 8 positions, threshold 5000
│   │   ├── manifest.hpp     // 10-leaf Merkle, FieldIndex 0..=9
│   │   ├── salt.hpp         // 32-byte; chmod 0600 on Unix
│   │   ├── kyc.hpp
│   │   ├── mica.hpp         // MicaReport v1 + canonical JSON pre-hash
│   │   ├── ns.hpp           // .omnibus / .arbitraje fees, register/transfer/resolve
│   │   └── facets/{social,professional,cultural,economic}.hpp
│   ├── governance/
│   │   └── proposal.hpp     // create/vote/finalize, quorum→veto→threshold tally
│   ├── validator/
│   │   ├── tier.hpp         // Omni(100)/Love(1k)/Food(10k)/Rent(100k)/Vacation(500k)
│   │   ├── staking.hpp
│   │   ├── set.hpp
│   │   └── slashing.hpp     // 33%/10%/1% + 10% reporter reward
│   ├── mining/
│   │   ├── engine.hpp       // mining loop + sub-block pacing
│   │   ├── pool.hpp
│   │   └── stratum.hpp      // v1 over TCP line-delimited JSON-RPC
│   ├── light/
│   │   ├── spv.hpp          // SpvBlockHeader 124B
│   │   ├── bloom.hpp        // 513B, Murmur seed-rotation
│   │   └── client.hpp
│   ├── rpc/
│   │   ├── server.hpp       // HTTP JSON-RPC on :8332
│   │   ├── eth.hpp          // eth_* methods on :8333
│   │   └── native.hpp       // ~140 OmniBus native methods
│   ├── ws/
│   │   ├── server.hpp       // WebSocket :8334
│   │   └── events.hpp       // 17 event types + topic bitmask
│   ├── shard/
│   │   ├── coordinator.hpp  // 4-shard route by SHA-256(addr)[0..2] % NUM_SHARDS
│   │   └── metachain.hpp
│   ├── agents/
│   │   ├── tier.hpp         // T1Mining → T4Arbitrage thresholds + hysteresis
│   │   ├── executor.hpp
│   │   └── manager.hpp
│   ├── vault.hpp            // Windows: \\.\pipe\OmnibusVault; Unix: /var/run/omnibus/vault.sock
│   ├── guardian.hpp         // Block size/tx checks + EGLD-style 2FA account guardian
│   └── dns.hpp
├── src/                      // .cpp files implementing the headers
│   └── (mirror of include/omnibus/)
├── apps/
│   ├── omnibus-node.cpp     // main(): CLI --mode {seed,miner,evm} mirror
│   └── omnibus-cli.cpp      // CLI tool for wallet ops
└── tests/                    // unit tests (Catch2 or gtest)
    ├── test_vectors.cpp     // BIP-39 PBKDF2 official, Trezor BIP-44 ETH, EIP-55, bech32, CRC32, genesis
    └── ...
```

## Dependencies allowed

- `libsecp256k1` (Bitcoin Core's) — secp256k1 ECDSA
- `liboqs` — PQ (ML-DSA, Falcon, SLH-DSA, ML-KEM)
- `OpenSSL` or `libsodium` — SHA-256, SHA-512, HMAC, AES if needed
- `Boost.Asio` — async TCP (preferred over raw sockets)
- `nlohmann/json` — JSON serialization
- `spdlog` — logging
- `Catch2` or `gtest` — tests
- `cmake` ≥ 3.20 build

No exotic deps. C++20 (concepts, ranges, `<format>` OK).

## Test vectors that MUST pass

Embed these in `tests/test_vectors.cpp` and run them in `ctest`:

1. **BIP-39 PBKDF2 official**: mnemonic = `"abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"`, passphrase = `"TREZOR"` → master_seed[0..32] = `c55257c360c07c72029aebc1b53c05ed0362ada38ead3e3e9efa3708e5349553` (hex)
2. **Trezor BIP-44 ETH**: same mnemonic + `m/44'/60'/0'/0/0` → EVM address = `0x9858EfFD232B4033E47d90003D41EC34EcaEda94`
3. **Bech32 ob1q roundtrip**: hash160=`751e76e8...3bd6` + HRP=`"ob"` → `ob1q...` (42 chars)
4. **EIP-55 checksum**: `0x5aaeb6053f...` mixed case → `0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed`
5. **CRC32-IEEE**: `crc32(b"123456789") == 0xCBF43926`
6. **Genesis hash**: build_genesis_block(MAINNET).hash == `82ec46e83af37b1ea0e6b3fe66a8f04795a8e8aae7db414d451eff1154245982`
7. **SubBlock pacing**: SUB_BLOCKS_PER_BLOCK=10, SUB_BLOCK_INTERVAL_MS=40
8. **PQ deterministic**: derive_keypair(seed, coin=777, ML_DSA_87, idx=0) twice → identical pubkey
9. **HTLC preimage hidden**: SwapRegistry::revealed_preimage() returns nullopt before Claim
10. **Reserved pair_id 1+4**: matching engine rejects place_order with pair_id ∈ {1, 4}

## Cross-impl peering test

Document in `README.md` how to:
- Start a C++ seed node: `./omnibus-node --mode seed --port 9000`
- Start a Zig miner: `./omnibus-node.exe --mode miner --seed-host 127.0.0.1 --seed-port 9000`
- Verify HELLO/WELCOME/STABLE handshake completes
- Verify they produce the same chain head hash after N blocks (use chain.dat diff)

## What NOT to do

- Do NOT use templates excessively — readable C++20, not C++ template metaprogramming.
- Do NOT introduce a custom build system — CMake only.
- Do NOT skip endianness; everything network-byte/storage-byte must match Zig + Rust LE conventions in `core/binary_codec.zig` + `core-rust/src/storage/codec.rs`.
- Do NOT generate stubs that throw `std::runtime_error("TODO")` — implement everything fully or omit the function entirely with a comment.
- Do NOT change pair_id, port numbers, magic bytes, chain_id, genesis hash, or block reward. These are protocol invariants.

---

## OUTPUT FORMAT — OEP-1 (Omni Extraction Protocol v1)

Your response MUST emit each file in its own fenced code block. The FIRST LINE inside each block is an OEP-1 metadata header in the language-appropriate single-line comment:

  `// OEP-1 <seq>/<total> | path=<relative-path> | proj=omnibus-node-cpp | run=2026-06-01-cpp-v1`

For CMakeLists.txt use `#` comment. For README.md use `<!-- ... -->`.

After the last block, emit ONE trailer line outside any code block:
  `END OEP-1 RUN: proj=omnibus-node-cpp | run=2026-06-01-cpp-v1 | files=<N>/<N> | status=complete`

Example header (C++ file):
```cpp
// OEP-1 1/30 | path=include/omnibus/types.hpp | proj=omnibus-node-cpp | run=2026-06-01-cpp-v1
#pragma once
// ... file content ...
```

## Chunking strategy (USE IT — output WILL exceed one response)

You are producing 100-150 files. A single response can hold maybe 30-50 medium files before truncation. Plan to chunk:

1. **First response**: emit files seq=1 to seq=N₁ (where N₁ is the most you can fit cleanly). End with trailer:
   `END OEP-1 RUN: proj=omnibus-node-cpp | run=2026-06-01-cpp-v1 | files=N₁/TOTAL | status=partial`
2. **User reruns** with the same prompt + says "continue from seq=N₁+1". You emit seq=N₁+1 onward. End with `status=partial` if more remain, `status=complete` on the last chunk.
3. Each chunk = complete files only. NEVER split a single file across chunks.
4. Once you have all of them, the trailer of the FINAL chunk must say `status=complete` and `files=TOTAL/TOTAL`.

When in doubt, **prefer more, smaller files** (a single header per type, a single .cpp per major operation) over fewer mega-files. Each file has a clear single responsibility so future agents can edit one without re-reading everything.

If you reach the response limit mid-file, drop that file entirely from the chunk; emit it complete in the next chunk. Do not emit half a file.
