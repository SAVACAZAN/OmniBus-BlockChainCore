# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/)
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [v0.3.2] - 2026-04-25 (later same day)

### Fixed — DB path wiring + chain selection (was incomplete in v0.3.0)

**Critical bugs discovered & fixed during live multi-chain testing:**

1. **DB cross-contamination** — `--testnet` was writing to `omnibus-chain.dat` (mainnet DB). Cause: `main.zig` had hardcoded `const DB_PATH = "omnibus-chain.dat"`. Fix: replaced with runtime `db_path` calculated per chain via `database_mod.dbPathForChain(allocator, short_name)`. 8 references updated.

2. **Chain selection ignored** — `--regtest` flag parsed correctly but `main.zig` still used legacy `if (config.testnet) testnet else mainnet` boolean. Fix: switched from `cli.parseArgs(args)` to `cli.parseArgsFull(args)`, then `switch (parsed.chain_mode)` for ChainConfig selection.

3. **DB path safety** — Mainnet now prefers legacy `omnibus-chain.dat` if present (back-compat with existing user data). Testnet/regtest **always** use `data/{chain}/chain.dat` — never legacy.

### Verified live

- `--mainnet` → loads `omnibus-chain.dat` (140 blocks restored OK)
- `--testnet` → uses `data/testnet/chain.dat` (isolated)
- `--regtest` → uses `data/regtest/chain.dat` (isolated)

### Added — 7 missing standard Bitcoin RPC methods

`core/rpc_server.zig` extended with:

| Method | Returns |
|--------|---------|
| `getbestblockhash` | hex hash of latest block |
| `getdifficulty` | current network difficulty |
| `getblockhash(height)` | hash at given height (error -8 if out of range) |
| `getblock(hash)` | full block JSON: hash, height, timestamp, previousHash, merkleRoot, difficulty, nonce, txCount, size, miner, rewardSAT (error -5 if not found) |
| `getconnectioncount` | peer count |
| `getpeerinfo` | array of peer details (id, addr, host, port, height, version, alive) |
| `getmininginfo` | object: blocks, difficulty, networkhashps, hashrate, pooledtx, chain, currentblockreward |

**RPC coverage:** 12/12 methods verified live (was 5/12 before).

### Test infrastructure

- New folder `test_results/{date}/` with subdirs: `01_unit_tests/`, `02_rpc_tests/`, `03_p2p_sync/`, `04_node_logs/`
- Unit tests: 8/8 PASS (test, test-crypto, test-chain, test-net, test-shard, test-storage, test-light, test-pq)
- P2P sync verified at 2 nodes (block announce + gossip relay)
- Live RPC tests scripted

### DB safety trail

Backups maintained: `omnibus-chain.dat.backup-20260425-1230` (pre-test snapshot), `omnibus-chain.dat.test-tainted-1237` (test-mined version, kept for reference, not active).

## [v0.3.0] - 2026-04-25

### Added — Multi-chain Selection (Mainnet / Testnet / Regtest)

**Wired ChainConfig as primary network configuration** (was: legacy `NetworkConfig` in `genesis.zig`).

**`core/chain_config.zig`** — was already defined, now actually used:
- 4 chain modes: `.mainnet` (chain_id=1), `.testnet` (chain_id=2), `.devnet` (chain_id=3, enum only), `.regtest` (chain_id=4, fast mining)
- Per-chain network magic bytes (P2P message identification, prevents cross-network connection)
- Per-chain ports: mainnet 8332/8333/8334, testnet 18332/18333/18334, regtest 28332/28333/28334
- Per-chain genesis hash + timestamp + difficulty
- Mainnet checkpoints for fast-sync

**`core/cli.zig`** — new chain flags (mutually exclusive):
- `--chain MODE` — explicit chain selection (mainnet | testnet | regtest)
- `--mainnet`, `--testnet`, `--regtest` — short aliases
- Conflict detection: `--mainnet --testnet` returns `error.ConflictingChainFlags`
- Backward compat: legacy `--testnet` boolean still works
- New `parseArgsFull()` returns `ParsedArgs { node, chain_mode }`; legacy `parseArgs()` preserved

**`core/database.zig`** — DB path separation per chain:
- New `dbPathForChain(allocator, chain_name)` — returns `data/{chain}/chain.dat`
- Auto-creates directory tree
- Backward compat: legacy `omnibus-chain.dat` at root still loadable
- `checkLegacyMigration()` warns if user has legacy DB but new layout missing

**`core/main.zig`** — uses `ChainConfig` instead of deprecated `NetworkConfig`:
- Configuration selection wired to `config.chain_mode`
- Calls `GenesisState.fromChainConfig(net_cfg, allocator)` (new API)
- Imports `ChainConfig`, `ChainId` from chain_config.zig

**`core/genesis.zig`** — accepts ChainConfig:
- New `GenesisState.fromChainConfig(cc, allocator)`
- New `buildBlockchainFromChain(chain_config, allocator)`
- Legacy `GenesisState.init(NetworkConfig, ...)` preserved for tests/back-compat
- `NetworkConfig.fromChainConfig(cc)` adapter for legacy callers
- Per-chain genesis message via `genesisMessageFor(chain_id)`

### Compatibility

- All old CLI scripts using `--testnet` continue to work
- Existing `omnibus-chain.dat` at root still loadable (legacy fallback)
- Legacy `NetworkConfig` API preserved in `genesis.zig` (deprecated, but functional)

### Verified

- `zig build -Doqs=false` — exit 0, no warnings
- `omnibus-node.exe --help` — new CHAIN SELECTION section displayed correctly

### Known Issues

- `chain_config.zig` field `MAINNET_CHECKPOINTS[0].hash` has 65 chars (typo, expected 64) — not yet fixed
- `ChainId.devnet` enum value exists but `ChainConfig.devnet()` constructor not implemented
- Tests in `genesis.zig` still reference legacy `NetworkConfig` — pass but use deprecated API

### Co-Authors

5 parallel sub-agents executed this migration:
- A1 — main.zig wiring
- A2 — CLI flags
- A3 — database path separation
- A4 — genesis.zig ChainConfig accept
- A5 — full audit (read-only)

## [v0.2.0] - 2026-03-31

### Added — Bech32 Addresses + Full BTC Parity (115%)

**8 New Core Modules:**
- `bech32.zig` — Bech32/Bech32m encoder/decoder (BIP-173/350), HRP="ob"
- `utxo.zig` — Full UTXO set with address index, coin selection, coinbase maturity
- `psbt.zig` — Partially Signed Bitcoin Transactions (BIP-174), multisig workflow
- `block_filter.zig` — Compact Block Filters (BIP-157/158), GCS encoding
- `htlc.zig` — Hash Time-Locked Contracts + registry (Lightning prereq)
- `lightning.zig` — Lightning Network: channels, invoices, routing, liquidity
- `tor_proxy.zig` — Tor SOCKS5 proxy support, .onion detection
- `encrypted_p2p.zig` — BIP-324 encrypted P2P transport (ECDH + AES-256-GCM)

**Bech32 Address Migration:**
- Native OMNI (coin 777): `ob_omni_` -> `ob1q...` (42 chars, identical to BTC `bc1q`)
- PQ domains keep unique prefixes: `ob_k1_`, `ob_f5_`, `ob_d5_`, `ob_s3_`
- 346 test addresses migrated across 28 files

**Full BTC Wallet Metadata:**
- master_fingerprint, parent_fingerprint, network (OMNI/TOMNI)
- xpub/xprv extended key serialization (Base58Check) per domain
- WIF private key encoding, hash160, script_pubkey, witness_version
- Full derivation path string (m/44'/777'/0'/0/0)
- Passphrase support (BIP-39, was TODO)

**Transaction Upgrades:**
- RBF (Replace-By-Fee): sequence field, opt-in, mempool replacement
- CPFP (Child-Pays-For-Parent): package feerate calculation
- Change addresses: chain=1 derivation (deriveChangeAddress/Key)
- UTXO tracking integrated in blockchain.zig addBlock flow

**19-Chain Multi-Wallet:**
- `scripts/generate_multiwallet.py`: OMNI(5) + BTC(4) + ETH + SOL + ADA + DOT + EGLD + ATOM + XLM + XRP + BNB + OP + LTC(2) + DOGE + BCH
- 138 addresses from 1 mnemonic, account-based structure with xpub/xprv

**Comparison Tool:**
- `FULLBTCDEV/generate_comparison.py`: auto-scans 78 .zig modules vs Bitcoin
- 10 category reports: 115% BTC parity + 30 unique extras

### Changed
- `build.zig` — fixed WASM step (addLog not available in Zig 0.15)
- `blockchain.zig` — log truncation increased from 20 to 42 chars (full Bech32)
- `mempool.zig` — nonce per TX in test helpers (prevents RBF conflicts)

---

## [v0.1.0] - 2026-03-30

### Added

- sub_block.zig â€” 10 Ã— 0.1s â†’ 1 KeyBlock + integrat in main (a5e66f3)
- p2p.zig â€” transport TCP real + integrat in main (78b1153)
- integreaza genesis + mempool + consensus in main.zig (bef7070)
- genesis + mempool + consensus â€” modulare, nu afecteaza trecutul (87e03e2)
- adauga BFT, Oracle, Slashing, Bots, MEV in arhitectura OMNI (555d2ab)
- corect parametri economici OMNI + doc arhitectura completa (4f5187f)
- Base58Check address encoding â€” match Python OmnibusWallet (a910943)
- genesis-ready â€” block reward, balance tracking, public RPC, miner registration (5d4984a)
- validateTransaction real, gettransactions RPC, database persistence (4f5d4a1)
