# 01 — Module IMPLEMENTATE în `core/`

Snapshot: 2026-05-19 · 156 fișiere `.zig` în `core/`

## 1. Core L1 (UTXO + Mempool + TX)

| Modul | LOC | Status | Note |
|-------|-----|--------|------|
| `core/utxo.zig` | 389 | ✅ DONE | `UTXOSet`, `selectUTXOs` greedy, RwLock thread-safe |
| `core/mempool.zig` | 1030 | ✅ DONE | RBF (`canBeReplacedBy`), orphan tracking, stats, `estimateTxSize` |
| `core/transaction.zig` | 1061 | ✅ DONE | TX builder + serializer (SIGHASH_ALL implicit) |
| `core/script.zig` | 735 | ✅ DONE | OpCodes, `ScriptVM`, P2PKH, P2SH, multisig |
| `core/psbt.zig` | 298 | ✅ DONE | BIP-174 PSBT pentru OmniBus TX |
| `core/block.zig` | – | ✅ DONE | Block structure, header, merkle root |
| `core/multisig.zig` | – | ✅ DONE | M-of-N multisig |
| `core/bech32.zig` | – | ✅ DONE | `ob1q...` adrese OmniBus |

## 2. Consensus & Finality

| Modul | Status | Note |
|-------|--------|------|
| `core/sub_block.zig` | ✅ DONE | 10 × 0.1s sub-blocks → 1 KeyBlock |
| `core/consensus_pouw.zig` | ✅ DONE | PoW + PoS hybrid |
| `core/finality.zig` | ✅ DONE | Casper FFG checkpoints |
| `core/staking.zig` | ✅ DONE | Bond / unbond / slashing logic |
| `core/governance.zig` | ✅ DONE | Voting on-chain |
| `core/governance_onchain.zig` | ✅ DONE | Persistent proposals |
| `core/validator_registry.zig` | ✅ DONE | Validator election |
| `core/metachain.zig` | ✅ DONE | 4-shard architecture coordination |
| `core/shard_coordinator.zig` | ✅ DONE | Cross-shard messages |
| `core/shard_config.zig` | ✅ DONE | Shard params |

## 3. Crypto Primitives

| Modul | Status | Note |
|-------|--------|------|
| `core/secp256k1.zig` | ✅ DONE | ECDSA pur Zig, low-S enforced |
| `core/schnorr.zig` | ✅ DONE (284 LOC) | BIP-340 — NU integrat cu script engine pt P2TR |
| `core/bls_signatures.zig` | ✅ DONE | BLS12-381 |
| `core/pq_crypto.zig` | ✅ DONE (603 LOC) | liboqs: ML-DSA-87, Falcon-512, SLH-DSA-256s, ML-KEM-768 |
| `core/ripemd160.zig` | ✅ DONE | Pentru BTC-style addresses |
| `core/key_encryption.zig` | ✅ DONE | AES-GCM wrapping |
| `core/crypto.zig` | ✅ DONE | SHA-2/3 helpers |
| `core/bip32_wallet.zig` | ✅ DONE (995 LOC) | HD wallet, BIP-44, change address derivation |
| `core/wallet.zig` | ✅ DONE (951 LOC) | 5 domenii PQ, integrare liboqs |

## 4. Networking & P2P

| Modul | Status | Note |
|-------|--------|------|
| `core/network.zig` / `core/p2p.zig` | ✅ DONE | TCP transport, handshake |
| `core/encrypted_p2p.zig` | ✅ DONE | Noise-style encryption (clasic, NU PQ-hybrid încă) |
| `core/peer_scoring.zig` | ✅ DONE | Reputation tracking |
| `core/peer_persist.zig` | ✅ DONE | Peer db |
| `core/kademlia_dht.zig` | ✅ DONE | DHT peer discovery |
| `core/dns_registry.zig` | ✅ DONE | DNS seed |
| `core/sync.zig` | ✅ DONE | Block sync (basic) |
| `core/ws_server` (in main) | ✅ DONE | WebSocket events port 8334 |
| `core/rpc_server` (in main) | ✅ DONE | JSON-RPC 2.0 port 8332 |
| `core/tor_proxy.zig` | ✅ DONE | Tor support |

## 5. Storage

| Modul | Status |
|-------|--------|
| `core/storage.zig` | ✅ DONE |
| `core/binary_codec.zig` | ✅ DONE |
| `core/archive_manager.zig` | ✅ DONE |
| `core/state_trie.zig` | ✅ DONE |
| `core/compact_blocks.zig` | ✅ DONE |
| `core/compact_transaction.zig` | ✅ DONE |
| `core/witness_data.zig` | ✅ DONE |
| `core/prune_config.zig` | ✅ DONE |

## 6. Cross-Chain & Bridge

| Modul | Status | Note |
|-------|--------|------|
| `core/bridge_native.zig` | ✅ DONE | OmniBus ↔ other chains generic |
| `core/bridge_relay.zig` | ✅ DONE | Relay messages |
| `core/htlc.zig` / `core/htlc_btc.zig` | ✅ DONE (534 LOC BTC) | HTLC native + BTC HTLC (SIGHASH parțial) |
| `core/htlc_persist.zig` | ✅ DONE | Persistent HTLCs |
| `core/atomic_swap.zig` | ✅ DONE | Atomic swap protocol |
| `core/evm_signer.zig` | 🟡 PARTIAL (459 LOC) | DOAR legacy TX, fără EIP-1559 |
| `core/evm_rpc_client.zig` / `core/evm_ffi.zig` | ✅ DONE | `eth_sendRawTransaction` |
| `core/spv_btc.zig` / `core/spv_eth.zig` | ✅ DONE | SPV proofs |
| `core/cross_chain_oracle.zig` | ✅ DONE | Cross-chain price/state oracle |
| `core/oracle.zig` / `core/oracle_fetcher.zig` / `core/oracle_policy.zig` | ✅ DONE | Quorum oracle, 4 keys testnet |
| `core/price_oracle.zig` | ✅ DONE | Chainlink/Pyth/CoinGecko fetcher |

## 7. DEX / Orderbook

| Modul | Status |
|-------|--------|
| `core/orderbook_sync.zig` | ✅ DONE |
| `core/pair_registry.zig` | ✅ DONE |
| `core/order_swap_link.zig` | ✅ DONE |
| `core/matching_engine.zig` | ✅ DONE |
| `core/intent_registry.zig` | ✅ DONE |
| `core/escrow.zig` | ✅ DONE |

## 8. Agents / Identity / Misc

| Modul | Status |
|-------|--------|
| `core/agent_*` (config, tier, executor, wallet, manager) | ✅ DONE |
| `core/identity.zig` / `core/kyc.zig` / `core/reputation.zig` | ✅ DONE |
| `core/treasury_agent.zig` / `core/faucet.zig` | ✅ DONE |
| `core/social_graph.zig` / `core/subscription.zig` / `core/label.zig` | ✅ DONE |
| `core/notarize.zig` / `core/domain_minter.zig` | ✅ DONE |
| `core/vault_engine.zig` / `core/vault_reader.zig` | ✅ DONE |
| `core/ubi_distributor.zig` / `core/bread_ledger.zig` | ✅ DONE |
| `core/omni_brain.zig` / `core/synapse_priority.zig` | ✅ DONE |
| `core/lightning.zig` / `core/channel_persist.zig` | ✅ DONE |
| `core/light_client.zig` / `core/light_miner.zig` / `core/mining_pool.zig` | ✅ DONE |
| `core/guardian.zig` / `core/spark_invariants.zig` | ✅ DONE |
| `core/miner_wallet.zig` / `core/miner_genesis.zig` | ✅ DONE |
| `core/isolated_wallet.zig` | ✅ DONE |
| `core/benchmark.zig` | ✅ DONE |
| `core/wasm_exports.zig` | ✅ DONE |

## Verdict scurt

**L1 OmniBus = production-grade.** Primitivele esențiale sunt acoperite:
UTXO + mempool RBF + script engine + PSBT + multisig + HTLC + PQ crypto +
consensus PoW/PoS hybrid + finality + governance + bridge + oracle.

Lipsurile (vezi `03_GAP_ANALYSIS.md`) sunt:
1. **SIGHASH multi-mode** în `transaction.zig` (NONE/SINGLE/ANYONECANPAY)
2. **Coin Control** (frozen UTXOs + manual selection)
3. **Fee estimator dinamic** (sat/vbyte priority classes)
4. **EIP-1559** în `evm_signer.zig`
5. **P2WPKH / P2TR** în `script.zig` (wire `schnorr.zig` la script)
6. **PQ hybrid handshake** în `encrypted_p2p.zig` (X25519 + ML-KEM-768)
7. **Wallet multi-chain** (BTC native, SOL, TON) — în repo separat `wallet-core/`
