# OmniBus Test Scripts Inventory (2026-05-10)

## Locations scanned
- **Local Windows**: `c:/Kits work/limaje de programare/1_CORE/BlockChainCore/`
- **VPS**: `/root/omnibus-blockchain/` via `ssh omnibus-vps`
- **Gitea**: `/home/gitea-data/git/repositories/`
  - `omnibus/blockchaincore.git`
  - `omnibus/devsec-suite.git`
  - `cazan/understandgame-master.git`
  - **NU există** repo-uri `kimi-audit-*` sau `findings/`

## Status legend
- 🆕 NEW — creat azi (2026-05-10)
- ✅ ACTIVE — modificat în ultima săptămână
- 🟡 STALE — modificat 1-3 luni
- ⚫ ABANDONED — modificat > 3 luni

## Inventar complet

### test-scripts/ (NEW — 17 scripturi)
| Script | Lines | Purpose |
|--------|-------|---------|
| `_common.sh` | 248 | Shared helpers (rpc, assert, color) |
| `run-all.sh` | 111 | Master runner |
| `01-chain-basic.sh` | 53 | getblockcount, getbalance, getrichlist, getblock |
| `02-reputation.sh` | 48 | LOVE/FOOD/RENT/VACATION cups |
| `03-stake-validators.sh` | 43 | stake, unstake, validators |
| `04-agents.sh` | 30 | Agent registration |
| `05-names.sh` | 48 | .omnibus naming service |
| `06-exchange.sh` | 53 | Native DEX pairs/orders/trades |
| `07-grid.sh` | 42 | Grid trading |
| `08-htlc-swap.sh` | 47 | HTLC atomic swap |
| `09-oracle.sh` | 38 | Oracle subsystem |
| `10-notarize-sub.sh` | 32 | Notarize/subscriptions |
| `11-escrow-channels.sh` | 20 | Escrow + channels |
| `12-governance.sh` | 24 | DAO governance |
| `13-dex-multichain-stress.mjs` | 280 | Multi-chain DEX stress (5 active pair_ids) |
| `14-ns-stress.mjs` | 310 | Naming service stress (8 TLDs) |
| `15-htlc-stress.mjs` | 324 | Cross-chain HTLC stress |

### test-scripts/legacy-updated/ (NEW — 7 scripturi)
Multi-chain support added:
- `rpc-tester.py` — 80+ RPC methods, multi-chain
- `tx-stress-sim.py`, `tx-stress-sim2.py` — TX stress (read-only default)
- `tx-flood-stress.py` — TX flood multi-chain
- `stress-pq-matrix.mjs` — PQ matrix multi-chain
- `fund-pq-then-stress.mjs` — fund+stress
- `pq-paritate-test.mjs` — noble↔liboqs parity

### test/*.zig (Unit tests Zig)
| File | Lines | Last Modified | Status |
|------|-------|---------------|--------|
| `test-pq-schemes-comprehensive.zig` | 463 | 2026-05-05 | ✅ ACTIVE |
| `blockchain_test.zig` | 96 | 2026-03-18 | ⚫ ABANDONED |
| `consensus_test.zig` | 473 | 2026-03-31 | ⚫ ABANDONED |
| `crypto_advanced_test.zig` | 351 | 2026-03-31 | ⚫ ABANDONED |
| `mempool_test.zig` | 478 | 2026-03-31 | ⚫ ABANDONED |
| `phase2_crypto_test.zig` | 134 | 2026-03-18 | ⚫ ABANDONED |
| `sharding_test.zig` | 485 | 2026-03-31 | ⚫ ABANDONED |
| `storage_test.zig` | 528 | 2026-03-31 | ⚫ ABANDONED |

**3008 linii total. Doar 1 din 8 actualizat în mai 2026.**

### tools/ (50+ scripturi STALE — 2026-04-19)

**EXPLOITS** (6 scripturi, ~1900 linii):
- consensus-attack-sim, crypto-edge-cases, double-spend-tester
- historical-attack-replayer, network-partition-sim, replay-protection-tester

**SECURITY** (10 scripturi, ~3000 linii):
- crypto-audit, fips-140-compliance, nist-ecdsa-vectors
- p2p-attack-simulator, property-based-crypto, sha256-ripemd160-vectors
- wycheproof-vectors, vuln-signature-updater, fuzz-harness.zig

**PERFORMANCE** (7 scripturi, ~1380 linii):
- tx-flood-stress, memory-pressure-test, p2p-connection-flood
- benchmark-consensus, benchmark-crypto.zig, profile-hot-paths.sh, memory-usage-analyzer

**NETWORK** (6 scripturi, ~1280 linii):
- onion-privacy-audit, tor-connectivity-test, p2p-test-harness
- rpc-tester, traffic-analysis-resistance, ws-monitor

**REVERSE/WALLET/LEARNING** (~10 scripturi, ~2500 linii)

### Active circuits (root-level, mai 2026)
| Script | Lines | Purpose |
|--------|-------|---------|
| `circuit_v4_bidirectional.py` | 376 | Bidirectional signed TX flow |
| `circuit_v3_signed.py` | 278 | Signed TX circuit v3 |
| `circuit_10h_v2.py` | 210 | 10h pacing v2 |
| `circuit_10h.py` | 248 | 10h v1 |
| `quantum_circuit.py` | 92 | Q-prefix quantum |
| `pq_send_test.py` | 335 | Sign+submit FROM Quantum |
| `stake_test.py` | 449 | Stake + role detection |
| `persistence_smoke_test.py` | 300 | Chainstate restart |
| `chain_stub_pq.py` | 220 | Python PQ stub |

### Frontend stress
| Script | Lines | Purpose |
|--------|-------|---------|
| `frontend/fund-pq-then-stress.mjs` | 205 | Fund PQ + stress |
| `frontend/stress-test.mjs` | 223 | Frontend stress |
| `frontend/pq-paritate-test.mjs` | 71 | noble↔liboqs verify |

### VPS-only (lipsesc local)
- `scripts/testing/run-all-tests.sh`
- `scripts/testing/test-single-module.sh`
- `scripts/testing/test_node_full.sh`
- `test_results/stress/2026-04-25/` — 24 CSV-uri din ultimul stress (doar artefacte)

## Concluzii

### Cele mai bune scripturi de folosit ACUM
1. `test-scripts/run-all.sh` — suite numerotat 01-15 (complet, NEW)
2. `tools/TESTING/stress-pq-matrix.mjs` — PQ stress
3. `frontend/fund-pq-then-stress.mjs` — fund + flood
4. `circuit_v4_bidirectional.py` — bidirectional signed TX
5. `pq_send_test.py` + `stake_test.py` — roluri / quantum
6. `persistence_smoke_test.py` — restart safety

### Scripturi învechite (cleanup candidates)
- `tx-stress-sim.py` + `tx-stress-sim2.py` — suprapuse cu `circuit_v4` și `13-dex-multichain-stress.mjs`
- `test_v3_e2e.sh` — înlocuit de `run-all.sh`
- `circuit_10h.py` — v2 mai bun
- `test_ecdsa_path.zig` — probe ad-hoc
- `archived-4-eterniti/tools-python/*` și `New Folder/`

### Unit tests Zig din martie
7 din 8 sunt din martie 2026 — necesită refresh sau confirmare că încă rulează cu `zig build test` actual.

### tools/* (50 fișiere)
Tot ce e în `tools/{EXPLOITS,SECURITY,PERFORMANCE,NETWORK,LEARNING,REVERSE,WALLET}/` datează din 2026-04-19. Bloc atomic neatins de 3 săptămâni — fie integrat în CI, fie marcat explicit ca scaffolding pre-MYTHOS.

### Lipsuri evidente (TESTE LIPSĂ)
- ❌ `pq_attest` cross-chain identity (cele 7 semnături)
- ❌ Registrarul de adrese fixe (10 slots: savacazan/admin/exchange/ens/sava/blockchain/tornetwork/faucet/cazan/database)
- ❌ `getrichlist` returning `roles[]` (cu excepția `stake_test.py`)
- ❌ Anti-Sybil knock-knock UDP
- ❌ Clock-drift / slot-leader race condition
- ❌ Smart-contracts JSON OpenAI-style
- ❌ **NEW: Stake balance lock** (TX-ul de stake debitează balance-ul corect?)
- ❌ **NEW: Reputation hooks live** (LOVE/FOOD/RENT/VACATION cresc per bloc?)

### Duplicate de clarificat
- `tools/TESTING/stress-pq-matrix.{mjs,zig}` — care e canonic?

### Gitea
Doar 3 repo-uri:
- `omnibus/blockchaincore.git`
- `omnibus/devsec-suite.git`
- `cazan/understandgame-master.git`

`MEMORY.md` menționează `.ecosystem/agents/` (Kimi/MYTHOS workspace) dar **directorul lipsește atât local cât și pe VPS**.

---

*Generated: 2026-05-10. Scripts continue to run in background — see STRESS_TEST_REPORT_*.md and SECURITY_STRESS_REPORT_*.md for live findings.*
