# 03 — Gap Analysis: ce LIPSEȘTE vs promptul original

Snapshot: 2026-05-19

Compar promptul original (cele 3 secțiuni mari: P2P/Consensus, PQ Security, Block Explorer)
+ auditul wallet (10 primitive + axa multi-chain) cu starea actuală din `core/`.

## Secțiunea 1 — INFRASTRUCTURĂ P2P & CONSENSUS

### 1.1 P2P Networking enhancement

| Cerință prompt | Status | Modul existent / lipsă |
|----------------|--------|------------------------|
| Kademlia DHT discovery | ✅ DONE | `core/kademlia_dht.zig` |
| Noise framework cu PQ handshake (X25519 + ML-KEM-768) | 🔴 MISSING | `core/encrypted_p2p.zig` are doar clasic |
| Yamux multiplexing | 🔴 MISSING | Nu există stream muxer |
| Gossip-sub pubsub | 🟡 PARTIAL | Există gossip basic în p2p, nu gossip-sub spec |
| Handshake cu version + genesis hash | ✅ DONE | În p2p.zig |
| Peer scoring + ban | ✅ DONE | `core/peer_scoring.zig` |
| Rate limiting / anti-DDoS | 🟡 PARTIAL | Există basic în p2p, lipsește per-message-class |

**Module noi de creat**:
- `core/pq_handshake.zig` — Hybrid Noise XK cu X25519 + ML-KEM-768
- `core/stream_mux.zig` — Yamux/Mplex pentru multiplexing
- `core/gossipsub.zig` — Gossip-sub v1.1 spec compliant
- `core/rate_limiter.zig` — Token bucket per peer per message type

### 1.2 Consensus PoS Hybrid

| Cerință | Status |
|---------|--------|
| Staking (bond, unbond, slashing) | ✅ DONE — `core/staking.zig` |
| Validator set election + rotation | ✅ DONE — `core/validator_registry.zig` |
| Block production schedule by stake | ✅ DONE — în consensus + finality |
| Finality gadget (Casper FFG / Tendermint) | ✅ DONE — `core/finality.zig` |
| View change / timeout | 🟡 PARTIAL — există în finality, dar fără teste edge cases |
| Slashing evidence (double signing) | 🟡 PARTIAL — staking.zig are slashing, dar nu evidence aggregator |

**Module noi de creat**:
- `core/slashing_evidence.zig` — collect, verify, aggregate evidence + onchain submission

### 1.3 Sync enhancements

| Cerință | Status |
|---------|--------|
| Fast sync (headers + state snapshot) | 🔴 MISSING |
| Warp sync (trusted state root) | 🔴 MISSING |
| P2P block download cu batching | 🟡 PARTIAL |
| Checkpoint sync | 🔴 MISSING |

**Module noi**:
- `core/fast_sync.zig`
- `core/warp_sync.zig`
- `core/checkpoint_sync.zig`

### 1.4 Mempool improvements

| Cerință | Status |
|---------|--------|
| RBF complet | ✅ DONE |
| Package relay / CPFP | 🔴 MISSING |
| Prioritization (fee, address) | 🟡 PARTIAL |
| Persistence între restarts | 🔴 MISSING |

**Extensii**:
- Adaugă `MempoolPersist` în `core/mempool.zig`
- Modul nou `core/package_relay.zig`

## Secțiunea 2 — SECURITATE POST-QUANTUM

### 2.1 PQ pentru P2P

| Cerință | Status |
|---------|--------|
| Hybrid KEM (X25519 + ML-KEM-768) | 🔴 MISSING — vezi 1.1 mai sus |
| Session key ratcheting (double ratchet) | 🔴 MISSING |

**Module**:
- `core/pq_handshake.zig` (vezi 1.1)
- `core/double_ratchet.zig`

### 2.2 PQ pentru tranzacții

| Cerință | Status |
|---------|--------|
| Hybrid signatures (ML-DSA-65 + ECDSA) | 🟡 PARTIAL — `wallet.zig` are 5 domenii PQ separate, dar nu hybrid în același TX |
| TX format multi-signature schemes | 🟡 PARTIAL — există dar nu standardizat |
| Upgrade path pentru existing keys | 🔴 MISSING |

**Module**:
- `core/hybrid_signature.zig` — ECDSA + ML-DSA in same TX
- `core/key_migration.zig` — migrate de la clasic la PQ keys

### 2.3 PQ pentru bridge

| Cerință | Status |
|---------|--------|
| HTLC cu PQ commitment | 🔴 MISSING |
| Oracle signatures PQ | 🟡 PARTIAL — oracle există dar semnături clasice |

### 2.4 HSM

| Cerință | Status |
|---------|--------|
| PKCS#11 wrapper | 🔴 MISSING |
| Remote signer pattern | 🔴 MISSING |

**Module**:
- `core/hsm_pkcs11.zig`
- `core/remote_signer.zig`

## Secțiunea 3 — BLOCK EXPLORER

Conform promptului: backend separat de node, PostgreSQL + indexer + API + frontend.

**Status**: 🔴 MISSING complet din `core/` (corect — nu e treaba node-ului).

**Recomandare**: repo separat `block-explorer/` (Rust sau Go), care ascultă events via WebSocket
de la `ws_server` (port 8334) + face queries via JSON-RPC (port 8332).

Stack sugerat:
- Backend: Go + PostgreSQL + Redis (cache)
- Frontend: React + TypeScript (există deja `frontend/` în repo pentru wallet — poate fi extins)
- API: REST + GraphQL

## Secțiunea AUDIT WALLET — Axa 2 multi-chain

Decizia clară:

### Ce STA în `core/` (extinde L1 OmniBus):

| Modul de creat | LOC est | Effort |
|----------------|---------|--------|
| `core/fee_estimator.zig` (înlocuiește `chain_config.FeeEstimator`) | ~250 | 4h |
| `core/coin_control.zig` (frozen UTXOs + manual select) | ~200 | 3h |
| Extensii `core/transaction.zig` (SIGHASH flags) | +150 | 3-4h |
| Extensii `core/script.zig` (P2WPKH + P2TR) | +400 | 4-6h |
| Extensii `core/evm_signer.zig` (EIP-1559) | +200 | 2-3h |
| Extensii `core/bip32_wallet.zig` (deriveSolana, deriveTon, deriveBitcoinSegwit) | +300 | 4h |

### Ce MERGE în repo separat `wallet-core/` (NU dilua L1):

| Modul | LOC est | Effort |
|-------|---------|--------|
| `btc/tx_builder.zig` + `btc/rpc_client.zig` (P2WPKH/P2TR raw TX + bitcoind RPC) | ~800 | 6-8h |
| `sol/ed25519_wrapper.zig` + `sol/borsh.zig` + `sol/tx_builder.zig` + `sol/rpc_client.zig` | ~1200 | 1-2 zile |
| `ton/cell.zig` + `ton/tl_b.zig` + `ton/address.zig` + `ton/tx_builder.zig` + `ton/rpc_client.zig` | ~1500 | 2-3 zile |
| Trait-uri comune `common/{AddressGenerator,TxBuilder,Signer,RpcClient}.zig` | ~300 | 1 zi |

Draft-urile există deja în `code/` (vezi `02_STATUS_IN_PROGRESS.md` secțiunea B).

## Prioritizare finală

### P0 — fix-uri critice în core/ (1-2 zile total)
1. Fix `build.zig` aggregation (15-30 min)
2. Fix `oracle_fetcher` const/mutable (1-2h)
3. Fix `dns_registry` test mismatch (1-2h)

### P1 — completări L1 production-grade (1 săptămână)
4. `core/fee_estimator.zig` dinamic
5. SIGHASH flags în `transaction.zig`
6. P2WPKH / P2TR în `script.zig` (wire schnorr la script)
7. EIP-1559 în `evm_signer.zig`
8. `core/coin_control.zig`
9. Mempool persistence + CPFP

### P2 — diferențiator PQ (1-2 săptămâni)
10. `core/pq_handshake.zig` (X25519 + ML-KEM-768 hybrid)
11. `core/hybrid_signature.zig` (ECDSA + ML-DSA în același TX)
12. `core/double_ratchet.zig`
13. PQ signatures pe HTLC + oracle

### P3 — Sync + scaling (1-2 săptămâni)
14. `core/fast_sync.zig`
15. `core/warp_sync.zig`
16. `core/checkpoint_sync.zig`
17. `core/gossipsub.zig` spec compliant

### P4 — Multi-chain wallet (repo separat `wallet-core/`)
18. BTC stack (tx_builder + rpc_client + fee_estimator)
19. SOL stack (ed25519 + borsh + tx + rpc)
20. TON stack (cell + tl-b + tx + rpc)

### P5 — Infrastructură vizibilă
21. Block Explorer (repo separat)
22. HSM PKCS#11 wrapper
