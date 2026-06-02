# OmniBus Blockchain Test Suite

Plain bash + curl read-only test scripts for the OmniBus chain RPC.
No state-changing calls: no stake, no order placement, no transactions.

## One-time setup

Make all scripts executable:

```bash
chmod +x test-scripts/*.sh
```

`jq` is optional but recommended (the scripts fall back to `grep`/`sed` when missing).

## Usage

```bash
# Run the entire suite on mainnet (default)
bash test-scripts/run-all.sh

# Specific chain (testnet | regtest | mainnet)
CHAIN=testnet bash test-scripts/run-all.sh
# or
bash test-scripts/run-all.sh --chain testnet

# Local seed instead of VPS
CHAIN=local-mainnet  bash test-scripts/run-all.sh   # http://127.0.0.1:8332
CHAIN=local-testnet  bash test-scripts/run-all.sh   # http://127.0.0.1:18332
CHAIN=local-regtest  bash test-scripts/run-all.sh   # http://127.0.0.1:28332

# Override URL completely
RPC_URL=https://example.com/rpc bash test-scripts/run-all.sh

# Verbose mode (show every request + response)
bash test-scripts/run-all.sh -v

# Quiet mode (only failures + summary)
bash test-scripts/run-all.sh -q

# Disable color
bash test-scripts/run-all.sh --no-color

# Single test
bash test-scripts/01-chain-basic.sh
CHAIN=testnet bash test-scripts/06-exchange.sh -v
```

## Endpoints

| chain         | URL                                                 |
| ------------- | --------------------------------------------------- |
| mainnet       | https://omnibusblockchain.cc:8443/api-mainnet       |
| testnet       | https://omnibusblockchain.cc:8443/api-testnet       |
| regtest       | https://omnibusblockchain.cc:8443/api-regtest       |
| local-mainnet | http://127.0.0.1:8332                               |
| local-testnet | http://127.0.0.1:18332                              |
| local-regtest | http://127.0.0.1:28332                              |

## Auth

If the RPC requires a Bearer token, set:

```bash
export OMNIBUS_RPC_TOKEN="…64-hex…"
```

## Suites

| script                       | covers                                               |
| ---------------------------- | ---------------------------------------------------- |
| `01-chain-basic.sh`          | block count, balance, richlist, block, perf, sync, peers, mempool |
| `02-reputation.sh`           | reputation cups (LOVE/FOOD/RENT/VACATION) + leaderboard |
| `03-stake-validators.sh`     | stake, stakers, validatorsv2, slash events           |
| `04-agents.sh`               | AI agents registry + pending decisions               |
| `05-names.sh`                | naming service (.omnibus / .arbitraje TLDs)          |
| `06-exchange.sh`             | native DEX pairs / orders / trades                   |
| `07-grid.sh`                 | grid trading bots                                    |
| `08-htlc-swap.sh`            | atomic swaps + HTLCs                                 |
| `09-oracle.sh`               | price oracle + foreign chain heights                 |
| `10-notarize-sub.sh`         | document notarization + subscriptions                |
| `11-escrow-channels.sh`      | escrow + payment channels                            |
| `12-governance.sh`           | DAO proposals                                        |
| `13-dex-multichain-stress.mjs` | DEX order stress, all 5 active pairs (read-only by default; `--write` to submit) |
| `14-ns-stress.mjs`           | naming-service registration stress                   |
| `15-htlc-stress.mjs`         | HTLC creation / claim / refund stress                |
| `16-pq-attest.sh`            | PQ identity attestation (cross-chain 7-sig binding)  |
| `17-registrar-slots.sh`      | registrar address slots (10 fixed BIP-44 indexes)    |
| `23-multiwallet-trade.mjs`   | multi-wallet trade flow (write, testnet)             |
| `24-multiwallet-stake.mjs`   | multi-wallet stake/unstake flow (write, testnet)     |
| `30-multiwallet-full-stress.mjs` | 30-min full ecosystem stress (mining + trade + stake + names) |

## Utility runners (`_*.sh` / `_*.mjs`)

| script                   | purpose                                                       |
| ------------------------ | ------------------------------------------------------------- |
| `_common.sh`             | shared helpers: rpc(), parse_flags, asserts, color output     |
| `_vps-health.sh`         | systemd state, mem, load, disk, heights, panic count, top procs |
| `_build-deploy.sh`       | local zig build → scp core/*.zig → remote build → restart → health (with rollback) |
| `_quick-stake-test.sh`   | regression: stake → balance lock → unstake → balance restored (testnet only) |
| `_quick-trade-test.sh`   | smoke test: place buy → orderbook → matching sell → recent trade (testnet only) |
| `_chain-monitor.sh`      | continuous dashboard refreshed every INTERVAL seconds, logs to file |
| `_orchestrator.mjs`      | runs 4 worker groups (rpc / stress / flows / health) in parallel via Node `worker_threads` |

## Top-level convenience runners

| runner                  | location                          | what it does                                |
| ----------------------- | --------------------------------- | ------------------------------------------- |
| `run-tests.bat`         | repo root                         | double-click → `run-all.sh --chain testnet` |
| `run-stress.bat`        | repo root                         | double-click → 30-min multi-wallet stress   |
| `Makefile` targets      | repo root                         | `make test-suite | stress | health | deploy | logs CHAIN=mainnet | restart | clean-cache | pq-matrix | quick-stake | quick-trade | monitor | orchestrate` |
| `.vscode/tasks.json`    | repo `.vscode/`                   | 12 VS Code tasks: Run All, Stress, PQ Matrix, VPS Health, Watch Logs, Restart Chains, Build+Deploy, Quick Stake/Trade, Monitor, Orchestrator |

## CI

GitHub Actions workflow at `.github/workflows/ci.yml`: lints Zig, builds, runs unit tests + smoke `01-chain-basic.sh` on PRs.

## Exit codes

- `0` — every test passed (or skipped cleanly).
- `1` — one or more tests failed.

## Conventions

- `PASS` (green) — call succeeded and validation passed.
- `FAIL` (red)   — call returned an error or a shape we didn't expect.
- `SKIP` (yellow) — RPC method not implemented, or no data exists yet (e.g. no open swaps to inspect). Skipped tests do **not** fail the suite.

## Safety

All scripts are read-only. None of them sign transactions, place orders, register names, stake, or otherwise mutate chain state. Safe to run against mainnet.
