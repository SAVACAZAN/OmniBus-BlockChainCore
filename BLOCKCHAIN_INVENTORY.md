# BlockChainCore Inventory Report (2026-05-13)

## 1. Core Modules (root level - top 30 by LOC)

| File | LOC | Tests | pub fn | TODOs | SHA-256 (16) | Status |
|------|-----|-------|--------|-------|--------------|--------|
| rpc_server.zig | 17919 | 42 | 15 | 7 | DCBFD635519D4B13 | PARTIAL |
| cli_audit.zig | 6350 | 12 | 1 | 0 | 69FA75A0D9F3F9C1 | COMPLETE |
| blockchain.zig | 5441 | 93 | 61 | 2 | A4808DE3A2BB2636 | COMPLETE |
| p2p.zig | 4248 | 48 | 90 | 1 | B35F5E6A04348FB3 | COMPLETE |
| main.zig | 3357 | 0 | 6 | 5 | B67E9CE6DBCF5B68 | PARTIAL |
| database.zig | 1866 | 11 | 31 | 0 | FA0DE09470CE49E4 | COMPLETE |
| dns_registry.zig | 1823 | 36 | 60 | 0 | C088784F70A42A45 | COMPLETE |
| ws_exchange_feed.zig | 1494 | 27 | 19 | 0 | 2484FFFD3D2D8BBE | COMPLETE |
| staking.zig | 1086 | 24 | 30 | 0 | 208E9C793CA24101 | COMPLETE |
| transaction.zig | 1054 | 14 | 19 | 0 | E7EE7DC5D7107337 | COMPLETE |
| mempool.zig | 1030 | 23 | 21 | 1 | 35FFEC08405B317A | COMPLETE |
| payment_channel.zig | 987 | 27 | 25 | 0 | BFF71D2149E5A7E8 | COMPLETE |
| matching_engine.zig | 986 | 17 | 22 | 0 | D0013EEB01ED6E83 | COMPLETE |
| orderbook_sync.zig | 983 | 12 | 19 | 0 | D0B06ACB47DB39E2 | COMPLETE |
| light_client.zig | 978 | 27 | 36 | 0 | 4286E2D85632F29B | COMPLETE |
| isolated_wallet.zig | 970 | 13 | 18 | 9 | 840BF68F6365B55D | PARTIAL |
| tx_payload.zig | 918 | 20 | 34 | 0 | 6CDE7F5AAB9228F4 | COMPLETE |
| spv_eth.zig | 916 | 17 | 6 | 2 | 52BC5095EA2C63D5 | COMPLETE |
| governance_onchain.zig | 901 | 23 | 22 | 0 | D70EF4C016EF81E5 | COMPLETE |
| bip32_wallet.zig | 882 | 18 | 29 | 0 | C8CF8FA01E1D703B | COMPLETE |
| bridge_listener.zig | 881 | 14 | 24 | 0 | 1DAC1846D2D8088D | COMPLETE |
| consensus_pouw.zig | 841 | 16 | 18 | 0 | C595A41D23AE0255 | COMPLETE |
| wallet.zig | 840 | 5 | 19 | 0 | 0665C9961D8DDF20 | COMPLETE |
| settlement_submitter.zig | 824 | 16 | 20 | 0 | 6C171B003D468E4D | COMPLETE |
| orchestrator.zig | 810 | 22 | 24 | 0 | 2AB448D1B65F6EE9 | COMPLETE |
| bootstrap.zig | 809 | 11 | 32 | 0 | A172F79E9F3107A8 | COMPLETE |
| multisig.zig | 878 | 28 | 20 | 0 | 234089AFC82A4B00 | COMPLETE |
| sync.zig | 748 | 15 | 28 | 0 | 3D67223CE6927BF3 | COMPLETE |
| ws_server.zig | 737 | 3 | 18 | 1 | DFF9A8B04F3F523C | COMPLETE |
| script.zig | 735 | 23 | 11 | 0 | C68EEDA5175D9678 | COMPLETE |

## 2. Submodules

### Identity (core/identity/*.zig)

| File | LOC | Tests | pub fn | TODOs | SHA-256 (16) | Status |
|------|-----|-------|--------|-------|--------------|--------|
| identity.zig | 31 | 1 | 0 | 0 | 66D1F704BFFD8C06 | STUB |
| id_compliance.zig | 476 | 8 | 10 | 3 | A8264015FC538C2D | COMPLETE (refactored 2026-05-13) |
| id_economic.zig | 492 | 8 | 6 | 0 | C7B4C4B2292458E1 | COMPLETE |
| id_cultural.zig | 378 | 7 | 5 | 0 | 194C0337F3F3F08C | COMPLETE |
| id_types.zig | 101 | 3 | 0 | 0 | 354821141214AF61 | STUB |
| id_manifest.zig | 152 | 3 | 4 | 0 | BABA62C37EC39B38 | COMPLETE |
| id_merkle.zig | 178 | 5 | 5 | 0 | 912264640EBD817D | COMPLETE |
| id_obm.zig | 121 | 5 | 2 | 0 | E97EDBEE5B79E85D | COMPLETE |
| id_professional.zig | 290 | 7 | 4 | 0 | 0EF0671C5BA0228C | COMPLETE |
| id_salt.zig | 163 | 4 | 5 | 0 | 15471FBC407B717E | COMPLETE |
| id_social.zig | 215 | 6 | 3 | 0 | BACD2691C214C8E1 | COMPLETE |
| id_disclosure.zig | 196 | 3 | 3 | 0 | 68531E5EB96610C1 | COMPLETE |
| id_did.zig | 116 | 5 | 4 | 0 | 22926169BFD5A25F | COMPLETE |
| id_base58.zig | 77 | 3 | 1 | 0 | BC12987CB0663490 | COMPLETE |

### Store (core/store/*.zig)

| File | LOC | Tests | pub fn | TODOs | SHA-256 (16) | Status |
|------|-----|-------|--------|-------|--------------|--------|
| chainstate.zig | 255 | 5 | 11 | 0 | AA768E77FD068269 | COMPLETE |
| kv.zig | 365 | 4 | 7 | 0 | A44ED608F065753F | COMPLETE |
| wal.zig | 372 | 4 | 6 | 0 | 354821141214AF61 | COMPLETE |

## 3. Standalone Tests

| File | LOC | Tests | SHA-256 (16) |
|------|-----|-------|--------------|
| blockchain_test.zig | 96 | 7 | 48A13A1524AE3904 |
| consensus_test.zig | 473 | 26 | 0EA038E591E5A7E0 |
| crypto_advanced_test.zig | 351 | 19 | E31BD7A617CF54A1 |
| mempool_test.zig | 478 | 17 | 4253866CF3E3AF9F |
| phase2_crypto_test.zig | 134 | 9 | D3BAF40FD76A9705 |
| sharding_test.zig | 485 | 21 | B87988ED56CEEA8D |
| storage_test.zig | 528 | 29 | BC4AE7AC0E06EA40 |
| test-pq-schemes-comprehensive.zig | 463 | 13 | 496BE0D469E1F5D1 |

## 4. RPC Endpoints (~60 total in rpc_server.zig)

| RPC Method | Status | Notes |
|------------|--------|-------|
| getblockcount | IMPLEMENTED | Blockchain height |
| getbalance | IMPLEMENTED | Address balance |
| getwalletsummary | IMPLEMENTED | Atomic wallet snapshot |
| listunspent | IMPLEMENTED | UTXO enumeration |
| getlatestblock | IMPLEMENTED | Last block data |
| getmempoolsize | IMPLEMENTED | TX pool stats |
| getstatus | IMPLEMENTED | Node status |
| sendtransaction | IMPLEMENTED | TX submission |
| gettransactions | IMPLEMENTED | TX history |
| registerminer | IMPLEMENTED | Miner registration |
| getpoolstats | IMPLEMENTED | Mining pool stats |
| getaddressbalance | IMPLEMENTED | Address balance |
| getmempoolstats | IMPLEMENTED | Mempool detail |
| getpeers | IMPLEMENTED | Peer list |
| getsyncstatus | IMPLEMENTED | Sync progress |
| getnetworkinfo | IMPLEMENTED | Network info |
| getblock | IMPLEMENTED | Block lookup |
| getblocks | IMPLEMENTED | Multiple blocks |
| getminerstats | IMPLEMENTED | Miner stats |
| getvalidators | IMPLEMENTED | Validator registry |
| getslotleader | IMPLEMENTED | Current slot leader |
| omnibus_getminers | IMPLEMENTED | Miners list |
| omnibus_getoracleprices | IMPLEMENTED | Oracle prices |
| omnibus_getblockprices | IMPLEMENTED | Block prices |
| omnibus_getpricerange | IMPLEMENTED | Price range |
| omnibus_getexchangefeed | IMPLEMENTED | Exchange feed |
| omnibus_getallprices | IMPLEMENTED | All prices |
| omnibus_getarbitrage | IMPLEMENTED | Arbitrage data |
| omnibus_getfxrate | IMPLEMENTED | FX rates |
| omnibus_getorderbook | IMPLEMENTED | DEX orderbook |
| omnibus_getbridgestatus | IMPLEMENTED | Bridge status |
| omnibus_getoraclepolicy | IMPLEMENTED | Oracle policy GET |
| omnibus_setoraclepolicy | IMPLEMENTED | Oracle policy SET |
| omnibus_gettotalmined | IMPLEMENTED | Total mined |
| omnibus_bridge_limits | IMPLEMENTED | Bridge limits |
| eth_call | CONDITIONAL | Falls back to EVM executor if `evm_enabled` |
| eth_estimateGas | CONDITIONAL | Same |
| eth_getBalance | CONDITIONAL | Same |
| eth_getCode | CONDITIONAL | Same |

### Outstanding RPC TODOs (7)
- eth_call / eth_estimateGas EVM integration polish
- Oracle quorum validation (cross-chain anchor)
- Grid trading RPC endpoints (grid_create/cancel/status)
- POAP / NFT redemption RPC
- SPV verification RPC polish
- Settlement completion tracking

## 5. EVM Status

**Files:**
- `core/evm_executor.zig` (218 LOC, 8 pub fn, 0 TODOs) — Zig wrapper over FFI
- `core/evm_ffi.zig` (50 LOC) — extern bindings to Rust static lib
- `evm/` directory expected to contain Rust crate `omnibus_evm` producing `evm/target/release/omnibus_evm.dll`

**Current state:**
- Conditional via `-Devm=true/false` flag
- When `-Devm=true`: build links Rust DLL → eth_call/eth_estimateGas/eth_getBalance/eth_getCode use real EVM
- When `-Devm=false`: build trips because `build.zig` still references the lib (this is the bug you hit today)
- Rust source for `omnibus_evm` not present in current snapshot of `evm/` → either deleted or never committed

**Recommendation (mine):** Disable EVM cleanly via build flag default `-Devm=false` AND make `evm_ffi.zig` import + lib linkage truly conditional. Keep `evm_executor.zig` as the stable wrapper. Postpone real EVM (Solidity bytecode) until JSON-smart-contracts MVP ships — they are the differentiator, EVM compat is commodity.

## 6. Documentation (root .md)

| File | Subject |
|------|---------|
| README.md | Main entry point |
| CLAUDE.md | Architecture + build/test guide |
| API_REFERENCE.md | JSON-RPC endpoint reference |
| MODULES_REFERENCE.md | Core module descriptions |
| CHANGELOG.md | Version history |
| SETUP.md | Dev environment setup |
| DEVOPS_SETUP.md | CI/CD config |
| CI_CD_SETUP_REPORT.md | Build pipeline |
| DEX_GRID_SPEC.md | Grid trading spec |
| COMPARISON_BITCOIN.md | OmniBus vs Bitcoin |
| ARCH_BITCOIN_STORAGE.md | Storage layer |
| BEFORE_PUSHING.md | Pre-commit checklist |
| SECURITY_STRESS_REPORT_20260510.md | Security stress test |
| STRESS_TEST_AGGREGATE_REPORT_2026-05-10.md | Aggregate test report |

## 7. Summary

- **101,269 LOC** Zig in `core/`
- **3,008 LOC** in standalone `test/`
- **1,590 tests total** (1,449 embedded + 141 standalone)
- **2,014 public functions**
- **74 TODO/FIXME** markers across whole repo

**Health:** 121 modules COMPLETE, 20 PARTIAL, 7 STUB. ~85% of large modules are complete.

### Top 5 modules needing attention
1. `rpc_server.zig` — 17.9k LOC, 7 TODOs (EVM + oracle + grid RPCs)
2. `isolated_wallet.zig` — 9 TODOs (PQ key derivation)
3. `poap.zig` — 13 TODOs (NFT/badge system)
4. `intent_registry.zig` — 6 TODOs (order routing edges)
5. `main.zig` — 5 TODOs (subsystem init polish)

### Recommended order
1. Fix EVM build gating (immediate — unblocks `zig build`)
2. P4-1 id_compliance DONE
3. P4-2 rpc_server per-request arena
4. P4-3 consensus PBFT (if mainnet needs it)
5. Grid trading RPCs (DEX_GRID_SPEC.md)
6. POAP system completion
7. Isolated wallet PQ finalization
