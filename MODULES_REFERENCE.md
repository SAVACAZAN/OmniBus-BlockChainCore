# OmniBus Blockchain — 97 Modules Reference

**Quick lookup for all modules. For full details, see MASTER_PROMPT_KIMI_CLAUDE.md**

## 0. Entry Points

| Module | Lines | Purpose | Key Functions |
|--------|-------|---------|----------------|
| `main.zig` | 2624 | Process init, CLI parse, orchestrate subsystems | `acquireSingleInstanceLock()`, `main()` |
| `cli.zig` | ~500 | Command-line argument parsing | `parse_args()`, `validate_chain_mode()` |
| `node_launcher.zig` | ~300 | Spawn worker threads for RPC, WS, mining | `launch_rpc_server()`, `launch_miner()` |

## 1. Cryptography (Layer 1)

| Module | Lines | Purpose | Key Functions |
|--------|-------|---------|----------------|
| `secp256k1.zig` | ~1500 | ECDSA signing + verification | `sign()`, `verify()`, `pubkey_from_privkey()`, `recover()` |
| `bip32_wallet.zig` | 882 | HD wallet derivation (BIP32/BIP39) | `derive_path()`, `hardened_child()`, `mnemonic_to_seed()` |
| `ripemd160.zig` | ~800 | RIPEMD-160 hash | `hash()` |
| `schnorr.zig` | ~600 | Schnorr signatures | `sign_schnorr()`, `verify_schnorr()` |
| `bls_signatures.zig` | ~700 | BLS aggregate signatures | `sign_bls()`, `verify_bls()`, `aggregate()` |
| `pq_crypto.zig` | ~1200 | Post-quantum (ML-DSA, Falcon, SLH-DSA, ML-KEM) | `ml_dsa_sign()`, `falcon_sign()`, `ml_kem_encap()` |
| `multisig.zig` | ~500 | Multi-signature scripts | `verify_multisig_2of3()`, `verify_multisig_mofn()` |
| `key_encryption.zig` | ~400 | AES-256-GCM key encryption | `encrypt_privkey()`, `decrypt_privkey()` |

**Test Vectors Needed:**
- Bitcoin Core BIP-340 Schnorr test vectors
- NIST FIPS 203/204/205/206 PQ test vectors
- BIP32 test vectors (m/44'/0'/0'/0/0)

---

## 2. Chain Core (Layer 2)

| Module | Lines | Purpose | Key Functions |
|--------|-------|---------|----------------|
| `blockchain.zig` | 3502 | Blockchain state machine | `add_block()`, `validate_block()`, `reorg()`, `get_block()` |
| `block.zig` | ~1200 | Block structure + validation | `Block.new()`, `Block.hash()`, `validate_header()` |
| `transaction.zig` | ~1500 | TX structure + validation | `Transaction.new()`, `sign_tx()`, `verify_tx()` |
| `utxo.zig` | 704 | UTXO set management | `add_utxo()`, `spend_utxo()`, `get_balance()`, `get_unspent()` |
| `consensus.zig` | ~1000 | PoW consensus + difficulty | `validate_proof_of_work()`, `next_difficulty()`, `mine_block()` |
| `finality.zig` | ~900 | Casper FFG finality + checkpoints | `finalize_checkpoint()`, `is_finalized()`, `revert_to_checkpoint()` |
| `genesis.zig` | ~600 | Genesis block + initial state | `genesis_mainnet()`, `genesis_testnet()`, `genesis_regtest()` |

**Test Vectors:**
- Bitcoin Core genesis block
- Block hash verification (SHA256)
- UTXO consistency check across 10 blocks
- Difficulty adjustment (every 144 blocks)

---

## 3. Storage (Layer 3)

| Module | Lines | Purpose | Key Functions |
|--------|-------|---------|----------------|
| `database.zig` | 1788 | Persistence (chain.dat, chainstate.wal) | `load_chain()`, `save_block()`, `checkpoint()`, `prune()` |
| `storage.zig` | ~1100 | Low-level KV store (LMDB-like) | `put()`, `get()`, `delete()`, `iterator()` |
| `state_trie.zig` | ~900 | Merkle trie for state (addresses, balances) | `add_node()`, `compute_root()`, `proof_of_inclusion()` |
| `binary_codec.zig` | ~1000 | Serialize/deserialize structures | `encode_block()`, `decode_tx()`, `varint_encode()` |
| `archive_manager.zig` | ~800 | Block archival + pruning | `archive_range()`, `delete_blocks()`, `compact()` |
| `compact_blocks.zig` | ~600 | Compact block format (BIP152) | `to_compact()`, `reconstruct_from_compact()` |
| `compact_transaction.zig` | ~500 | TX compression | `shortid()`, `reconstruct_tx()` |

**Test Vectors:**
- Merkle root computation (10 TXs)
- State trie proof of inclusion
- Serialize/deserialize round-trip (block → bytes → block)

---

## 4. Mempool (Layer 4)

| Module | Lines | Purpose | Key Functions |
|--------|-------|---------|----------------|
| `mempool.zig` | 870 | TX pool (FIFO, fee-sorted) | `add_tx()`, `remove_tx()`, `get_highest_fee()`, `evict_by_size()` |

**Constraints:**
- Max 10,000 TXs
- Max 1 MB total
- Evict lowest-fee on overflow
- No double-spends

---

## 5. Wallet (Layer 5)

| Module | Lines | Purpose | Key Functions |
|--------|-------|---------|----------------|
| `wallet.zig` | 840 | Main wallet, mnemonic recovery | `from_mnemonic()`, `derive_address()`, `sign_tx()`, `export_xprv()` |
| `isolated_wallet.zig` | 936 | 5 isolated seeds (OMNI/LOVE/FOOD/RENT/VACATION) | `init_5_domains()`, `address_for_domain()`, `sign_domain()` |
| `miner_wallet.zig` | ~600 | Miner reward auto-sweep | `collect_rewards()`, `auto_forward_to_vault()` |
| `vault_reader.zig` | ~400 | Read mnemonic from SuperVault, env, or dev default | `read_mnemonic()`, `read_from_named_pipe()` |

**Test Vectors:**
- BIP39 mnemonic → seed → xprv → address
- 5-domain address derivation with per-domain schemes
- Isolated wallet recovery from mnemonic

---

## 6. Network (Layer 6)

| Module | Lines | Purpose | Key Functions |
|--------|-------|---------|----------------|
| `p2p.zig` | 4095 | TCP peer-to-peer network | `connect_peer()`, `broadcast_block()`, `knock_knock_dedup()` |
| `sync.zig` | ~1200 | Full block sync from peers | `sync_blocks()`, `catch_up()`, `verify_chain_on_sync()` |
| `bootstrap.zig` | ~500 | Peer discovery (hardcoded seeds) | `get_seed_nodes()`, `dns_seed_lookup()` |
| `kademlia_dht.zig` | ~700 | Kademlia DHT for peer routing | `find_closest()`, `store_value()`, `find_value()` |
| `peer_scoring.zig` | ~600 | Peer reputation + ban | `good_block()`, `bad_block()`, `ban_peer()`, `is_banned()` |
| `ws_server.zig` | ~1200 | WebSocket push (blocks, TXs) | `push_block()`, `push_tx()`, `broadcast_to_clients()` |
| `ws_client.zig` | ~400 | WS client (for testing) | `connect()`, `send()`, `recv()` |
| `encrypted_p2p.zig` | ~500 | Optional P2P encryption | `handshake()`, `encrypt_msg()`, `decrypt_msg()` |
| `tor_proxy.zig` | ~400 | Tor integration (onion routing) | `connect_via_tor()`, `get_onion_address()` |

**Test Scenarios:**
- Connect 10 peers, mine 5 blocks, verify all peers receive
- Drop peer, reconnect, sync from last block
- Sybil attack (100 fake peers), ensure ban
- Network partition + healing

---

## 7. RPC (Layer 7)

| Module | Lines | Purpose | Key Functions |
|--------|-------|---------|----------------|
| `rpc_server.zig` | 9524 | JSON-RPC 2.0 HTTP server | `serve_getblockcount()`, `serve_sendtx()`, `serve_getbalance()`, etc. (50+ endpoints) |

**Covered Endpoints (50+):**
- Blockchain: `getblockcount`, `getblock`, `getblocktime`, `getdifficulty`
- Chain: `sendtx`, `gettransaction`, `getmempoolinfo`, `estimatefee`
- Wallet: `getbalance`, `listunspent`, `getnewaddress`, `dumpprivkey`
- Exchange: `exchange_getTicker`, `exchange_getOpenOrders`, `exchange_addOrder`
- Crypto: `pq_listSchemes`, `pq_createAddress`, `pq_sign`
- Contracts: `dns_register`, `dns_lookup`, `agent_list`
- Governance: `governance_getVotes`, `governance_castVote`
- Oracle: `oracle_getPrice`, `oracle_subscribe`

---

## 8. DNS / Names (Layer 8)

| Module | Lines | Purpose | Key Functions |
|--------|-------|---------|----------------|
| `dns_registry.zig` | 955 | .omnibus / .arbitraje name reservation | `register()`, `lookup()`, `is_available()`, `transfer()`, `expire()` |
| `registrar_addresses.zig` | ~400 | 10 registrar wallet addresses (ENS, faucet, treasury, etc.) | `get_treasury()`, `get_faucet()`, `get_ens_registrar()` |
| `domain_minter.zig` | ~300 | Domain creation + revenue distribution | `mint_domain()`, `distribute_revenue()` |

**Contract Rules:**
- 5 OMNI base fee (.omnibus), 10 OMNI (.arbitraje)
- Premium pricing: 1-char × 200, 2-char × 100, 3-char × 20, 4-char × 4, 5+ × 1
- Auto-register via `ns_claim:name.tld` op_return memo + fee transfer
- 365-day expiry, grace period 30 days

---

## 9. Exchange / DEX (Layer 9)

| Module | Lines | Purpose | Key Functions |
|--------|-------|---------|----------------|
| `matching_engine.zig` | 986 | Order matching (bid/ask, FIFO) | `add_order()`, `match_orders()`, `fill_order()` |
| `orderbook_sync.zig` | 983 | Broadcast orderbook state to peers | `sync_orderbook()`, `publish_update()` |
| `oracle.zig` | ~600 | Price oracle aggregation | `record_price()`, `get_median()`, `detect_outlier()` |
| `oracle_fetcher.zig` | ~700 | Fetch prices from Kraken/LCX/Binance | `fetch_kraken()`, `fetch_lcx()`, `fetch_binance()`, `median()` |
| `oracle_types.zig` | ~200 | PricePoint, PriceFeed structs |
| `oracle_policy.zig` | ~300 | Oracle governance (add/remove sources) |
| `pair_registry.zig` | ~400 | Trading pair definitions (BTC/USD, OMNI/BTC, etc.) | `get_pairs()`, `add_pair()`, `validate_pair()` |
| `ws_exchange_feed.zig` | 1494 | Real-time exchange feed via WebSocket | `stream_trades()`, `stream_ticker()` |

**Test Scenarios:**
- Place 1000 buy/sell orders, measure match latency
- Oracle: 3 sources, compute median price
- Stress: 10 TPS trading, verify UTXO consistency

---

## 10. Agents / AI (Layer 10)

| Module | Lines | Purpose | Key Functions |
|--------|-------|---------|----------------|
| `agent_manager.zig` | ~700 | Agent lifecycle + spawning | `spawn_agent()`, `kill_agent()`, `list_agents()` |
| `agent_executor.zig` | ~600 | Execute agent instructions (deterministic) | `execute_instruction()`, `apply_state_change()` |
| `agent_tier.zig` | ~300 | Agent tiers (t1_mining, t2_trading, t3_arb) | `get_tier()`, `upgrade_tier()`, `get_allocation()` |
| `agent_wallet.zig` | ~400 | Agent-owned funds + custody | `deposit()`, `withdraw()`, `get_balance()` |
| `agent_config.zig` | ~300 | Config schema (JSON) for agents | `load_config()`, `validate_config()` |
| `treasury_agent.zig` | ~700 | Autonomous market maker (grid orders) | `place_grid_orders()`, `rebalance()`, `collect_fees()` |
| `omni_brain.zig` | ~800 | ML model inference (tinyML) | `predict_price()`, `predict_demand()`, `get_feature_vector()` |

**Agent Tiers:**
- **t1_mining**: Collect block rewards, forward to treasury
- **t2_trading**: Place limit orders, arbitrage
- **t3_arb**: Cross-exchange swap routing
- **t4_governance**: Vote on proposals
- **t5_custom**: User-defined logic (LLM-powered)

---

## 11. Staking / Governance (Layer 11)

| Module | Lines | Purpose | Key Functions |
|--------|-------|---------|----------------|
| `staking.zig` | 1086 | Staking lock + withdrawal | `lock_stake()`, `unlock_stake()`, `get_stake()`, `claim_rewards()` |
| `validator_registry.zig` | ~600 | Active validator set (top 100 by stake) | `register_validator()`, `unregister_validator()`, `is_active()` |
| `governance.zig` | ~800 | Voting on protocol changes | `create_proposal()`, `vote()`, `execute_if_passed()`, `tally()` |
| `reputation.zig` | ~700 | 4-tier reputation system | `add_reputation()`, `get_reputation()`, `check_badge()` |
| `reputation_manager.zig` | ~400 | Reputation automation (claims, checks) | `claim_faucet()`, `verify_kyc()`, `increment_tier()` |
| `guardian.zig` | ~500 | Emergency pause + upgrade path | `pause_feature()`, `unpause_feature()`, `propose_upgrade()` |

**Staking Model:**
- Min 1000 OMNI to validate
- Rewards: 20% APY for validators
- Slashing: 10% for equivocation, 25% for censorship
- Reputation tiers: LOVE (liquidity), FOOD (activity), RENT (reliability), VACATION (wealth)

---

## 12. Sharding (Layer 12)

| Module | Lines | Purpose | Key Functions |
|--------|-------|---------|----------------|
| `shard_coordinator.zig` | ~700 | Shard assignment + cross-shard routing | `get_shard_for_address()`, `route_tx_to_shard()`, `collect_cross_receipts()` |
| `shard_config.zig` | ~300 | Shard topology (4 shards) | `get_shard_count()`, `get_shard_nodes()` |
| `metachain.zig` | ~700 | Metachain (finality across shards) | `finalize_shard_checkpoint()`, `verify_cross_shard_receipt()` |
| `sub_block.zig` | ~600 | Sub-block engine (10 × 0.1s sub-blocks → 1 KeyBlock) | `mine_sub_block()`, `aggregate_to_keyblock()` |

**Sharding Model:**
- 4 shards (shard_0, shard_1, shard_2, shard_3)
- Each address assigned to shard via hash(address) % 4
- Metachain finalizes cross-shard receipts every KeyBlock
- Sub-blocks allow parallel TX processing

---

## 13. Special / Advanced

| Module | Lines | Purpose | Key Functions |
|--------|-------|---------|----------------|
| `payment_channel.zig` | 983 | Lightning-like payment channels | `open_channel()`, `update_state()`, `settle()` |
| `htlc.zig` | ~500 | Hash Time Locked Contracts | `create_htlc()`, `redeem_htlc()`, `timeout_refund()` |
| `bridge_native.zig` | ~600 | Bridge to native chains (Bitcoin, Ethereum) | `lock_asset()`, `mint_wrapped()`, `burn_wrapped()` |
| `bridge_listener.zig` | 881 | Listen for bridge events on remote chains | `watch_bitcoin()`, `watch_ethereum()`, `record_lock()` |
| `bridge_relay.zig` | ~400 | Relay bridge signatures to settlement | `submit_signatures()`, `finalize_mint()` |
| `light_client.zig` | 978 | SPV light client (verify headers, not full blocks) | `verify_header()`, `verify_merkle_proof()`, `sync_headers()` |
| `light_miner.zig` | ~500 | Mobile miner (low-power) | `mine_with_limited_resources()` |
| `mining_pool.zig` | ~600 | Mining pool coordinator | `distribute_shares()`, `track_hashrate()`, `payout()` |
| `script.zig` | ~700 | Script validation (P2PKH, P2WPKH, P2TR) | `execute_script()`, `verify_witness()` |
| `psbt.zig` | ~500 | Partially Signed Bitcoin Transactions | `create_psbt()`, `sign_psbt()`, `finalize_psbt()` |
| `kyc.zig` | ~400 | KYC flow (compliance) | `verify_identity()`, `check_sanction_list()` |
| `identity.zig` | ~500 | Identity provider + DID | `create_identity()`, `sign_attestation()`, `verify_attestation()` |
| `settlement_submitter.zig` | ~400 | Auto-submit settlements to chain | `queue_settlement()`, `submit_batch()` |
| `bread_ledger.zig` | ~600 | Bread ledger (proof of reserves) | `record_reserve()`, `audit_reserve()`, `publish_proof()` |

---

## Test / Benchmark Modules

| Module | Lines | Purpose |
|--------|-------|---------|
| `integration_test.zig` | 962 | End-to-end: mine 100 blocks, verify chain |
| `isolated_wallet_test.zig` | ~400 | 5-domain wallet + PQ signing |
| `dns_registry_test.zig` | ~300 | Name registration, lookup, expiry |
| `ws_client_test.zig` | ~200 | WebSocket push events |
| `e2e_mining.zig` | ~400 | Mining loop + reward distribution |
| `benchmark.zig` | ~300 | Measure TPS, latency, throughput |
| `spark_invariants.zig` | ~400 | Property-based testing (SPARK formal methods) |

---

## Statistics

- **Total modules**: 97
- **Total lines**: 69,197 (Zig)
- **Largest module**: rpc_server.zig (9524 lines, 50+ endpoints)
- **Smallest modules**: ~200 lines (config, types, utilities)

---

## Code Generation Priority Order

When porting to new language, follow this order:

1. **Crypto** (secp256k1, BIP32, RIPEMD, PQ) — 6 days
2. **Chain** (blockchain, block, TX, UTXO, consensus) — 2 days
3. **Storage** (database, state trie, codec) — 1.5 days
4. **Wallet** (isolated_wallet, mnemonic, signing) — 1 day
5. **Network** (P2P, RPC, WS) — 2 days
6. **Contracts** (DNS, agents, staking, governance) — 2 days
7. **Tests + Stress + Exploit** (50 test scripts) — 1 week

**Total**: ~4-5 weeks for high-quality, audited port

---

## Resources

- **MASTER_PROMPT_KIMI_CLAUDE.md** — Full architecture + code generation rules
- **openapi_rpc_spec.json** — OpenAPI 3.1 RPC specification
- **MODULES_REFERENCE.md** (this file) — Quick module lookup
- **test_vectors.json** (to create) — Bitcoin Core + NIST test vectors
- **stress_test_suite.py** (to create) — 30-50 deterministic test scripts
