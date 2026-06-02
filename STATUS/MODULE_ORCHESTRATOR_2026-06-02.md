# Module Orchestrator — BlockChainCore + omnibus-crypto-core
# Audit complet 2026-06-02 | owner: savacazan.omnibus

> Acest fișier este **sursa de adevăr** pentru statusul tuturor modulelor.
> NU duplică conținut din audit-urile existente — le referențiază.
>
> **Audit-uri existente (citește pentru detalii):**
> - `PARITY_AUDIT_zig_vs_rust_2026-06-02.md` — paritate Zig↔Rust completă (20KB)
> - `BLOCKCHAIN_INVENTORY.md` — inventar general
> - `BLOCKCHAIN_DEEP_AUDIT_2026-05-13.md` — audit adânc mai vechi
> - `AUDIT_MOCK_STUB.md` — stub-uri identificate anterior
> - `AUDIT_PQ_DETERMINISTIC.md` — PQ signing audit
> - `PQ_MIGRATION_PLAN.md` — plan migrare PQ Stage 2
> - `omnibus-crypto-core/RUST_STATUS.md` — status primitives Rust (10KB)
> - `omnibus-crypto-core/reports/audit_primitives_parity_2026-06-01.md` — 66KB deep audit
> - `omnibus-crypto-core/ports-todo/` — TODO per limbaj (CPP/GO/PYTHON/ZIG)

---

## Legend

| Simbol | Înseamnă |
|--------|---------|
| ✅ FULL | Implementat complet, teste pass |
| ⚠ PARTIAL | Cod există, funcții incomplete / TODO intern |
| 🔲 STUB | Schelet fără logică (0-10 linii) |
| ❌ MISSING | Există în sursă dar lipsește din target |
| 🆕 NEW | Există doar în Rust, nu în Zig |
| 🔁 RENAMED | Același modul, alt nume |

---

## 1. BLOCKCHAIN CORE — Zig vs Rust

### 1.1 Consensus & Block

| Modul | Zig | Rust | Note |
|-------|-----|------|------|
| `consensus` | ✅ | ✅ | |
| `consensus_pouw` | ✅ | ✅ `pouw.rs` | |
| `block` | ✅ | ✅ | |
| `genesis` | ✅ | ✅ | |
| `finality` | ✅ | ✅ | |
| `mempool` | ✅ | ✅ | |
| `sub_block` | ✅ | ✅ | |
| `validator_registry` | ✅ | ✅ | |
| `compact_blocks` | ✅ | ✅ | |
| `package_relay` | ✅ | ✅ | |
| `staking` | ✅ | ✅ `validator/staking.rs` | |
| `slashing_evidence` | ✅ | ✅ `validator/slashing.rs` | |
| `spark_consensus` | ⚠ TODO | ❌ MISSING | **CRITICAL** — sub-block voting |
| `spark_invariants` | ⚠ TODO | ⚠ `node_lifecycle/spark_invariants.rs` | Parțial |
| `slot_calendar` | ⚠ TODO | ❌ MISSING | **CRITICAL** — next sprint |

### 1.2 Blockchain Ops (apply/validate)

| Modul | Zig | Rust | Note |
|-------|-----|------|------|
| `blockchain/apply` | ✅ | ✅ | |
| `blockchain/validation` | ✅ | ✅ | |
| `blockchain/balances` | ✅ | ✅ | |
| `blockchain/op_returns` | ✅ | ✅ | dispatcher stake/agent/ns/etc |
| `blockchain/persistence` | ✅ | ✅ | |
| `blockchain/reorg` | ✅ | ✅ | |
| `blockchain/mining` | ✅ | ✅ | |
| `blockchain/htlc_tx` | ✅ | ✅ | |
| `blockchain/intent_tx` | ✅ | ✅ | |
| `blockchain/address_index` | ✅ | ✅ | |
| `blockchain/pubkey_registry` | ✅ | ✅ | |
| `blockchain/governance` | ✅ | ✅ | |
| `blockchain/mempool_helpers` | ✅ | ✅ | |

### 1.3 Crypto

| Modul | Zig | Rust | Note |
|-------|-----|------|------|
| `secp256k1` | ✅ | ✅ wrapper | Rust → omnibus-crypto-core |
| `bech32` | ✅ | ✅ wrapper | |
| `bip32_wallet` | ✅ | ✅ | |
| `pq_crypto` | ✅ | ✅ | via liboqs |
| `pq_migrate_consensus` | ✅ | ✅ | Stage 1 shipped |
| `schnorr` | ✅ | ✅ | |
| `ripemd160` | ✅ | ⚠ 25 linii wrapper | thin wrapper |
| `bls_signatures` | ✅ shim | ✅ `crypto/bls.rs` | simulare |
| `double_ratchet` | ✅ | ✅ | |
| `key_encryption` | ✅ | ✅ | |
| `hex_utils` | ⚠ TODO | ✅ | Zig are TODO minor |

### 1.4 Wallet & Keys

| Modul | Zig | Rust | Note |
|-------|-----|------|------|
| `wallet` | ✅ | ✅ | |
| `bip32_wallet` | ✅ | ✅ | |
| `isolated_wallet` | ✅ | ✅ | |
| `miner_wallet` | ✅ | ✅ | |
| `cold_wallet` | ✅ | ✅ | |
| `coin_control` | ✅ | ✅ | |
| `fee_estimator` | ✅ | ✅ | |
| `multisig` | ✅ | ✅ | |
| `psbt` | ✅ | ✅ | |
| `script` | ✅ | ✅ | |
| `segwit` | ✅ | ✅ | |
| `sighash` | ✅ | ✅ | |
| `timelock_vault` | ✅ | ✅ | |
| `vault_engine` | ✅ | ✅ | |
| `covenant` | ✅ | ✅ | |
| `treasury_agent` | ✅ | ✅ | |
| `treasury_multi` | ✅ | ✅ | |
| `registrar_addresses` | ✅ | ✅ | |
| `utxo` | ✅ | ✅ | |
| `payment_channel` | ✅ | ✅ | |

### 1.5 DEX & Trading

| Modul | Zig | Rust | Note |
|-------|-----|------|------|
| `matching_engine` | ✅ | ✅ | |
| `dex_settler` | ✅ | ✅ `bridge/bridge_native.rs`? | verifică |
| `grid_engine` | ✅ | ✅ `dex/grid_engine.rs` | |
| `htlc` | ✅ | ✅ | |
| `htlc_btc` | ✅ | ✅ | |
| `htlc_persist` | ✅ | ✅ | |
| `orderbook_sync` | ✅ | ✅ | |
| `order_swap_link` | ✅ | ✅ | |
| `pair_registry` | ✅ | ✅ | |
| `fills_log` | ✅ | ✅ | |
| `token_whitelist` | ⚠ TODO | ✅ | Zig are TODO |
| `intent_registry` | ✅ | ✅ | |
| `strategy_registry` | ✅ | ❌ MISSING | **HIGH** — agenții depind |

### 1.6 Bridge & Cross-Chain

| Modul | Zig | Rust | Note |
|-------|-----|------|------|
| `bridge_native` | ✅ | ✅ | |
| `bridge_listener` | ✅ | ✅ | |
| `bridge_relay` | ✅ | ✅ | |
| `evm_escrow_watcher` | ✅ | ❌ MISSING | **HIGH** — cross-chain settlement |
| `evm_executor` | ✅ | ❌ MISSING? | poate e în `evm/executor.rs` |
| `evm_signer` | ✅ | ✅ | |
| `evm_rpc_client` | ✅ | ✅ | |
| `settlement_submitter` | ✅ | ✅ | |
| `escrow` | ✅ | ✅ | |
| `chain_rpc_client` | ✅ | ✅ | |
| `cross_chain_oracle` | ✅ | ✅ | |
| `spv_btc` | ⚠ TODO | ✅ | Zig are TODO |
| `spv_eth` | ✅ | ✅ | |

### 1.7 Identity & Social

| Modul | Zig | Rust | Note |
|-------|-----|------|------|
| `identity` (DID/OBM/Manifest) | ✅ | ✅ | full paritate |
| `id_compliance` / KYC | ✅ | ✅ | |
| `id_disclosure` | ✅ | ✅ | |
| `id_economic` | ✅ | ✅ | |
| `id_facets` (social/cultural/professional) | ✅ | ✅ | |
| `reputation` | ✅ | ✅ | |
| `reputation_manager` | ✅ | ✅ | |
| `social_graph` | ✅ | ✅ | |
| `notarize` | ✅ | ✅ | |
| `poap` | ✅ | ✅ | |
| `ubi_distributor` | ✅ | ✅ | |
| `bread_ledger` | ✅ | ✅ | |
| `domain_minter` | ✅ | ✅ | |
| `label` | ✅ social/ | ✅ identity/ | loc diferit |
| `subscription` | ✅ | ✅ | |

### 1.8 Agenți

| Modul | Zig | Rust | Note |
|-------|-----|------|------|
| `agent_config` | ✅ | ✅ | |
| `agent_executor` | ✅ | ✅ | |
| `agent_manager` | ✅ | ✅ + duplicat `manager.rs` | dublu în Rust |
| `agent_tier` | ✅ | ✅ | |
| `agent_wallet` | ✅ | ✅ | |
| `omni_brain` | ✅ | ✅ | |
| `strategy_registry` | ✅ | ❌ MISSING | **CRITICAL** |
| `treasury_agent` | ✅ | ✅ | |

### 1.9 RPC Layer

| Modul | Zig | Rust | Note |
|-------|-----|------|------|
| `rpc/chain` | ✅ | ✅ | |
| `rpc/eth` | ✅ | ✅ `eth_methods.rs` | renamed |
| `rpc/mining` | ⚠ TODO | ✅ | |
| `rpc/mempool` | ✅ | ✅ | |
| `rpc/wallet` | ✅ | ✅ | |
| `rpc/wallet_advanced` | ✅ | ✅ | |
| `rpc/agents` | ⚠ TODO | ✅ | |
| `rpc/identity` | ✅ | ✅ | |
| `rpc/governance` | ✅ | ✅ | |
| `rpc/consensus` | ✅ | ✅ | |
| `rpc/dex/exchange` | ✅ | ✅ | |
| `rpc/omniscript` | ✅ | ✅ | |
| `rpc/pq` | ✅ | ✅ | |
| `rpc/oracle` | ✅ | ✅ | |
| `rpc/lightning` | ✅ | ✅ | |
| `rpc/social` | ✅ | ✅ | |
| `rpc/ns` | ✅ | ✅ | |
| `rpc/notarize` | ✅ | ✅ | |
| `rpc/spv` | ✅ | ✅ | |
| `rpc/swap` | ✅ | ✅ | |
| `rpc/subscription` | ✅ | ✅ | |
| `rpc/escrow` | ✅ | ✅ | |
| `rpc/net` | ✅ | ✅ | |
| `rpc/slot_calendar` | ⚠ TODO | ❌ MISSING | **CRITICAL** |
| `rpc/spark` | ✅ | ❌ MISSING | **HIGH** |
| `rpc/strategies` | ✅ | ❌ MISSING | **HIGH** |
| `rpc/native_methods` | ❌ | 🆕 Rust only | nou în Rust |
| `rpc/helpers` | ❌ | 🆕 Rust only | nou în Rust |
| `rpc/server` | ⚠ rpc_server.zig TODO | ✅ `rpc/server.rs` | Rust mai curat |

### 1.10 Node Lifecycle

| Modul | Zig | Rust | Note |
|-------|-----|------|------|
| `node/config_setup` | ✅ | ✅ | |
| `node/db_setup` | ✅ | ✅ | |
| `node/rpc_thread` | ✅ | ✅ | |
| `node/p2p_init` | ✅ | ✅ | |
| `node/mining_periodic` | ✅ | ✅ | |
| `node/faucet_thread` | ✅ | ✅ | |
| `node/slot_leader` | ✅ | ✅ | |
| `node/peer_persistence` | ✅ | ✅ | |
| `node/state_save` | ✅ | ✅ | |
| `node/mempool_verifier` | ✅ | ✅ | |
| `node/graceful_shutdown` | ✅ | ✅ | |
| `node/mining_telemetry` | ✅ | ✅ | |
| `node/oracle_bridge` | ✅ | ✅ | |
| `node/wallet_setup` | ✅ | ✅ | |

### 1.11 Infrastructure

| Modul | Zig | Rust | Note |
|-------|-----|------|------|
| `p2p` (gossip/peer/wire/sync) | ✅ | ✅ | |
| `kademlia_dht` | ✅ network/ | ✅ p2p/kademlia.rs | loc diferit |
| `tor_proxy` | ✅ network/ | ✅ p2p/tor_proxy.rs | loc diferit |
| `storage` (kv/wal/chainstate) | ✅ | ✅ | |
| `ws_server` | ✅ | ✅ | |
| `ws_client` | ✅ | ✅ | |
| `ws_exchange_feed` | ✅ | ✅ | |
| `lightning` | ✅ | ✅ | |
| `evm/` (executor/state/types) | ✅ | ✅ | |
| `omniscript/` | ✅ | ✅ (lipsă lexer.rs + tests.rs) | |
| `wasm_exports` | ✅ | ❌ MISSING | low priority |
| `safety/` | ❌ | 🆕 Rust only (6 fișiere) | **FEATURE NOU** |
| `CLI sub-comenzi` (23 zig) | ✅ | ⚠ agregat în 1 fișier | user experience |

### 1.12 Governance & Light

| Modul | Zig | Rust | Note |
|-------|-----|------|------|
| `governance` | ✅ | ✅ | |
| `governance_onchain` | ✅ | ✅ | |
| `light_client` | ✅ | ✅ | |
| `light_miner` | ✅ | ✅ | |
| `block_filter` (BIP-158) | ✅ | ✅ `light/bloom.rs` | Rust are bloom |
| `multisig` complet | ✅ | ✅ | |
| `shard_coordinator` | ✅ | ✅ | |
| `oracle` / `price_oracle` | ✅ | ✅ | |

---

## 2. omnibus-crypto-core — Status per modul

### 2.1 Core Crypto (SOLID)

| Modul | Status | Note |
|-------|--------|------|
| `pq/` (ML-DSA, Falcon, SLH-DSA, ML-KEM) | ✅ FULL | via liboqs FFI, deterministic |
| `pq/det_rng.rs` | ✅ FULL | HKDF-SHA512 canonical seed |
| `hd/bip32, bip39, bip44` | ✅ FULL | |
| `keystore/` (AES-256-GCM, Argon2id) | ✅ FULL | |
| `secp256k1_impl` | ✅ FULL | |
| `ed25519_impl` | ✅ FULL | |
| `wasm/bindings.rs` | ✅ FULL | 1666 linii |
| `hardware/` (Ledger/Trezor/WebAuthn) | ✅ FULL | |
| `mpc/sss, frost_dkg, frost_secp` | ✅ FULL | |
| `omniscript/` (signer/verifier/types) | ✅ FULL | |

### 2.2 tx_builder — Cross-Chain (~20 chain-uri)

| Chain | Status |
|-------|--------|
| Bitcoin (BTC + PSBT + BIP-143) | ✅ FULL |
| Ethereum (EIP-1559 + EIP-712 + ERC-20) | ✅ FULL |
| Solana | ✅ FULL |
| Cosmos | ✅ FULL |
| Cardano | ✅ FULL |
| Polkadot | ✅ FULL |
| TON | ✅ FULL |
| Tron | ✅ FULL |
| XRP | ✅ FULL |
| Stellar | ✅ FULL |
| Zilliqa | ✅ FULL |
| Algorand | ✅ FULL |
| EGLD (MultiversX) | ✅ FULL |
| NEAR | ✅ FULL |

### 2.3 Stub-uri adevărate (logică lipsă)

| Fișier | Ce lipsește | Prioritate |
|--------|------------|-----------|
| `aa/entrypoint.rs` (1 linie) | ERC-4337 EntryPoint | MEDIUM |
| `aa/paymaster.rs` (1 linie) | ERC-4337 Paymaster | MEDIUM |
| `aa/userop.rs` (1 linie) | UserOperation struct | MEDIUM |
| `mpc/frost.rs` (1 linie) | FROST threshold (frost_secp OK) | LOW |
| `mpc/gg20.rs` (1 linie) | GG20 threshold | LOW |
| `script/taproot.rs` (1 linie) | BIP-341 Taproot tweak | HIGH pt BTC parity |
| `primitives/hash/keccak256.rs` | re-export din legacy | LOW (funcționează) |
| `primitives/kdf/hmac_sha512.rs` | re-export din legacy | LOW (funcționează) |

### 2.4 Porturi pending (omnibus-crypto-core/ports-todo/)

| Limbaj | Fișier TODO | Status |
|--------|------------|--------|
| C++ | `CPP_TODO.md` | pending |
| Go | `GO_TODO.md` | pending |
| Python | `PYTHON_TODO.md` | pending |
| Zig | `ZIG_TODO.md` | pending |

---

## 3. Priorități acțiuni — Ordered

### P0 — Blocante imediat (sprint curent)

| # | Task | Unde | Efort |
|---|------|------|-------|
| 1 | `slot_calendar.zig` — implementează logica (structuri există) | BlockChainCore/core/ | 1 zi |
| 2 | `rpc/slot_calendar.zig` — completează TODO | BlockChainCore/core/rpc/ | 2 ore |
| 3 | `strategy_registry.rs` — portare din Zig | BlockChainCore/core-rust/ | 1 zi |
| 4 | `rpc/strategies.rs` — portare din Zig | BlockChainCore/core-rust/rpc/ | 3 ore |

### P1 — Sprint următor

| # | Task | Unde | Efort |
|---|------|------|-------|
| 5 | `spark_consensus.zig` — sub-block voting (TODO → real) | BlockChainCore/core/ | 3-5 zile |
| 6 | `rpc/spark.rs` — portare din Zig | BlockChainCore/core-rust/rpc/ | 1 zi |
| 7 | `bridge/evm_escrow_watcher.rs` — portare din Zig | BlockChainCore/core-rust/bridge/ | 2 zile |
| 8 | `pq_migrate Stage 2` — TxType + mempool + RPC | BlockChainCore/core/ + core-rust/ | 3-5 zile |

### P2 — Backlog

| # | Task | Unde | Efort |
|---|------|------|-------|
| 9 | `script/taproot.rs` — BIP-341 implementare reală | omnibus-crypto-core/rust/ | 3 zile |
| 10 | `omniscript/lexer.rs` + `tests.rs` | BlockChainCore/core-rust/ | 1 zi |
| 11 | CLI Rust sub-comenzi (23 → dedicate) | BlockChainCore/core-rust/cli/ | 2 zile |
| 12 | `aa/` ERC-4337 complet | omnibus-crypto-core/rust/ | 1 săpt |
| 13 | AuxPoW merged mining | BlockChainCore/core/ | 3-5 zile |
| 14 | `wasm_exports.rs` | BlockChainCore/core-rust/ | 1 zi |

### P3 — Porturi limbaje (omnibus-crypto-core)

| # | Task | Fișier |
|---|------|--------|
| 15 | Port C++ | `ports-todo/CPP_TODO.md` |
| 16 | Port Go | `ports-todo/GO_TODO.md` |
| 17 | Port Python | `ports-todo/PYTHON_TODO.md` |
| 18 | Port Zig | `ports-todo/ZIG_TODO.md` |

---

## 4. Cross-repo dependencies

```
omnibus-crypto-core (primitives)
    ↑ folosit de:
    ├── BlockChainCore/core-rust/ (crypto wrappers)
    ├── BlockChainCore/core/omniscript/ (PQ signing)
    ├── 3_DESKTOP_APPS/aweb3/ (WASM bindings)
    ├── 3_DESKTOP_APPS/dapps/58_OmniWallet/ (WASM)
    └── 2_SDK/omnibus-sdk-rs/ (Rust SDK)

BlockChainCore/core/ (Zig — chain primar port 8332)
    ↑ folosit de:
    ├── BlockChainCore/core-rust/ (sibling node port 8333)
    ├── OmnibusAgentOS/ (JSON-RPC 2.0)
    ├── 2_SDK/Connect/ (Python API)
    └── 4_EXCHANGE_STACK/zig-hft/ (direct Zig import)
```

---

## 5. Fișiere audit existente — index

| Fișier | Conținut | Data |
|--------|---------|------|
| `PARITY_AUDIT_zig_vs_rust_2026-06-02.md` | Paritate completă filename-level | 2026-06-02 |
| `BLOCKCHAIN_INVENTORY.md` | Inventar general module | vechi |
| `BLOCKCHAIN_DEEP_AUDIT_2026-05-13.md` | Deep audit mai vechi | 2026-05-13 |
| `AUDIT_MOCK_STUB.md` | Stub-uri identificate | vechi |
| `AUDIT_PQ_DETERMINISTIC.md` | PQ signing audit | 2026-05-17 |
| `AUDIT_PQ_SIGNING_AND_PERSISTENCE.md` | PQ + TX persistence | vechi |
| `PQ_MIGRATION_PLAN.md` | Plan Stage 1 done → Stage 2 | curent |
| `NEXT_SESSION_PLAN.md` | Slot Calendar + SPARK | 2026-04-28 |
| `omnibus-crypto-core/RUST_STATUS.md` | Status complet Rust primitives | curent |
| `omnibus-crypto-core/reports/audit_primitives_parity_2026-06-01.md` | 66KB deep audit primitives | 2026-06-01 |
| `omnibus-crypto-core/CBOM.md` | Crypto Bill of Materials | curent |
| `omnibus-crypto-core/THREAT_MODEL.md` | 37KB threat model | curent |
| `blockchain-security-auditor/audit_*.md` | Daily audit logs (mai-iun 2026) | ongoing |

---

*Generat: 2026-06-02 | Actualizat la fiecare sprint major*
