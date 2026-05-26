# Python Tools Index — BlockChainCore

Index la toate scripturile Python utile (audit, raport, test, monitoring, devops).
Toate au docstring în antet — vezi acolo pt detalii. Categorii grupate după folder.

## Repo-root scripts (test rapid + circuit traffic)

| Script | Scop |
|---|---|
| `circuit_v4_bidirectional.py` | Generator traffic bidirectional (ECDSA + PQ + NS register) |
| `circuit_v3_signed.py` | Versiune anterioară (signed tx mix) |
| `circuit_10h_v2.py`, `circuit_10h.py` | Pacing 10h pentru testnet sustained load |
| `quantum_circuit.py`, `regenerate_quantum_pool.py` | Generator adrese Quantum pool |
| `generate_addresses_pool.py` | Pool adrese deterministe pt test |
| `pq_send_test.py` | TX cu semnătură PQ |
| `chain_stub_pq.py` | Stub server pt test PQ flows |
| `stake_test.py` | Stake/unstake flow validator |
| `test_rest_hmac.py` | REST API + HMAC auth |
| `persistence_smoke_test.py` | Restart-and-recover smoke test |
| `tx-stress-sim.py`, `tx-stress-sim2.py` | TX flood pe mempool |
| `We-Are-Here-HodLum-WORKER.py` | Worker miner extern |

## scripts/cross/ — multi-repo orchestration

| Script | Scop |
|---|---|
| `omnibus-dashboard.py` | Dashboard text live (BlockChainCore + aweb3 Liberty + bridge + alerts) |
| `unified-health-check.py` | Health JSON pt ambele proiecte (RPC 8332 + 8545) |
| `sync-deployments.py` | Sync adrese contracte între BlockChainCore și aweb3, output `deployment-sync.json` |
| `bridge-e2e-test.py` | Test e2e bridge OmniBus ↔ EVM |

## scripts/devops/ — operare

| Script | Scop |
|---|---|
| `node-health-monitor.py` | Watcher health continuu, alert pe degradare |
| `log-aggregator.py` | Agregare loguri din toate nodurile |

## tools/ — root tooling

| Script | Scop |
|---|---|
| `inventory-scan.py` | Count operations / TX types / schemes / RPC methods / WS events / modules |
| `inventory-md.py` | Clasifică toate `.md` din repo (freshness/topic/state), output `INVENTORY.md` |
| `consolidate-status.py` | Extrage TODO/DONE/BLOCKED din toate `.md`, output `STATUS.md` consolidat |
| `audit-pq-conventions.py` | Static audit convenții PQ (prefix, scheme name, BIP-44 account, scheme code) |
| `bootstrap-context.py` | Generează context pt sesiune nouă Claude |

## tools/SECURITY/ — audit crypto

| Script | Scop |
|---|---|
| `crypto-audit.py` | Audit implementări crypto din `core/` (secp256k1, BIP32, schnorr, etc.) |
| `fips-140-compliance.py` | Verifică conformitate FIPS-140 |
| `nist-ecdsa-vectors.py` | Test vectors NIST pt ECDSA |
| `wycheproof-vectors.py` | Google Wycheproof test vectors |
| `sha256-ripemd160-vectors.py` | Hash test vectors |
| `property-based-crypto.py` | Property-based testing crypto primitives |
| `p2p-attack-simulator.py` | Sim atacuri pe stack P2P |
| `vuln-signature-updater.py` | Update DB semnături vulnerabilități |

## tools/MONITORING/ — runtime monitoring

| Script | Scop |
|---|---|
| `node-status-monitor.py` | Poll RPC every N seconds, afișează status |
| `chain-growth-tracker.py` | Monitor `omnibus-chain.dat` size over time |
| `alert-manager.py` | Manager alerte pe metrici |

## tools/CONSENSUS/ — consens

| Script | Scop |
|---|---|
| `difficulty-simulator.py` | Sim difficulty adjustment over time |
| `finality-checker.py` | Verifică Casper FFG finality |
| `fork-detector.py` | Detector fork-uri pe-chain |
| `shard-balance-analyzer.py` | Analizează echilibru între cele 4 shards |

## tools/ANALYSIS/ — analiză statică

| Script | Scop |
|---|---|
| `api-surface-analyzer.py` | Analiză suprafață API (RPC + WS) |
| `dependency-mapper.py` | Hartă dependențe intre module |
| `module-complexity-analyzer.py` | Metrici complexitate per modul |

## tools/PERFORMANCE/ — benchmark + stress

| Script | Scop |
|---|---|
| `benchmark-consensus.py` | Bench consens (TX/s, latență) |
| `memory-pressure-test.py` | Memory pressure test |
| `memory-usage-analyzer.py` | Analiză profile memorie |
| `p2p-connection-flood.py` | Flood conexiuni P2P |
| `tx-flood-stress.py` | TX flood stress test |

## tools/NETWORK/ — testing rețea

| Script | Scop |
|---|---|
| `rpc-tester.py` | Test toate metodele RPC |
| `ws-monitor.py` | Monitor WebSocket events (port 8334) |
| `p2p-test-harness.py` | Test harness pt P2P layer |
| `tor-connectivity-test.py` | Test conectivitate Tor |
| `onion-privacy-audit.py` | Audit privacy peste Onion routing |
| `traffic-analysis-resistance.py` | Test rezistență la traffic analysis |

## tools/EXPLOITS/ — adversarial testing

| Script | Scop |
|---|---|
| `consensus-attack-sim.py` | Sim atacuri pe consens |
| `crypto-edge-cases.py` | Edge cases crypto primitives |
| `double-spend-tester.py` | Test double-spend resistance |
| `replay-protection-tester.py` | Test EIP-155 / chain_id replay protection |
| `network-partition-sim.py` | Sim partiționare rețea |
| `historical-attack-replayer.py` | Replay atacuri cunoscute (Bitcoin/ETH istorice) |

## tools/REVERSE/ — fuzzing

| Script | Scop |
|---|---|
| `block-malformation-tester.py` | Fuzz blocuri malformate |

## tools/AI/ — ML pe chain data

| Script | Scop |
|---|---|
| `difficulty-predictor.py` | ML predictor difficulty |
| `generate-synthetic-chain.py` | Generator chain sintetic pt training |
| `network-health-scorer.py` | Score health rețea via ML |
| `train-anomaly-detector.py` | Train anomaly detector |

## tools/LEARNING/ — meta (învățare din evolutia codului)

| Script | Scop |
|---|---|
| `build-failure-tracker.py` | Track build failures over time |
| `consensus-evolution-analyzer.py` | Analiză evolutia codului de consens |
| `crypto-implementation-tracker.py` | Track schimbări implementare crypto |
| `git-zig-evolution.py` | Git history specific pe `.zig` files |
| `peer-behavior-learner.py` | Învățare comportament peers |
| `test-failure-learner.py` | Învățare patterns test failures |

## tools/TESTING/ — test reporting

| Script | Scop |
|---|---|
| `generate-test-report.py` | Pipe `zig test` → HTML report. Uz: `zig build test-crypto 2>&1 \| python3 tools/TESTING/generate-test-report.py --output report.html` |

## tools/DEVOPS/ — deployment

| Script | Scop |
|---|---|
| `deploy-node.py` | Deploy nod la VPS |
| `multi-node-orchestrator.py` | Orchestrare multi-nod |
| `upgrade-manager.py` | Upgrade rolling cu rollback |

## tools/CODEGEN/ — generare cod

| Script | Scop |
|---|---|
| `build-zig-updater.py` | Update `build.zig` automat |
| `generate-rpc-method.py` | Generează scaffolding RPC method nou |

## tools/DEBUG/ — debug helpers

| Script | Scop |
|---|---|
| `core-dump-analyzer.py` | Analiză core dumps (Linux) |
| `dependency-graph.py` | Graf dependențe Zig modules |
| `zig-error-decoder.py` | Decode Zig error traces |

## tools/WALLET/ — wallet tooling

| Script | Scop |
|---|---|
| `address-validator.py` | Validează adrese OMNI/PQ/Quantum |
| `key-backup-tool.py` | Backup chei (vault format) |
| `multisig-coordinator.py` | Coordonator multisig N-of-M |
| `wallet-tester.py` | Test wallet end-to-end |

## tools/pqc-quality-scanner/ — calitate output PQC

Modulul scanează output-ul cheilor/semnăturilor PQ pt randomness, avalanche
effect, NIST SP 800-22 statistical tests, periodicity.

| Test | Fișier |
|---|---|
| Entropy estimation | `tests/entropy.py` |
| Avalanche effect | `tests/avalanche.py` |
| NIST SP 800-22 | `tests/nist_sp800_22.py` |
| Periodicity | `tests/periodicity.py` |
| Runner | `run.py` |

## Frontend / Misc

| Script | Scop |
|---|---|
| `scripts/frontend/generate-rpc-client.py` | Generează TypeScript client din schema RPC |
| `scripts/generate_miners.py` | Generează wallets miners (BIP-44) |
| `scripts/generate_multiwallet.py` | Generează multiwallet HD |
| `scripts/skills/generate-agent.py` | Generează skill nou (Claude agent) |
| `examples/client_python/franchise_client.py` | Client Python exemplu pt franchise API |
| `tests/treasury_flow_test.py` | Test flow treasury |
| `stress-output/orchestrator.py`, `orchestrator2.py` | Orchestrator stress |
| `stress-output/build_final_report.py` | Build raport final stress |
| `stress-output/sustain.py` | Sustained load runner |
| `test_results/stress/report.py` | Report generator stress |
| `test-scripts/legacy-updated/rpc-tester.py` | RPC tester (legacy updated) |

## Cum se folosesc (pattern comun)

Majoritatea acceptă `--help`:
```bash
python tools/SECURITY/crypto-audit.py --help
python tools/inventory-scan.py --json
python tools/inventory-scan.py --out STATUS/INVENTORY.md
```

Pentru audit/raport pre-commit:
```bash
python tools/audit-pq-conventions.py        # check PQ conventions
python tools/inventory-scan.py              # count surface area
python scripts/cross/unified-health-check.py # health both repos
```
