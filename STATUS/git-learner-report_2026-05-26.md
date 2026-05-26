# Git Learner Report — 2026-05-26

> Analysis period: last 6 months (Nov 2025 – May 2026). Total commits: 452. Focus: core/*.zig (deepsearch/ excluded).

---

## Top Churn (6mo)

| File | Commits | Last Touched |
|------|---------|--------------|
| rpc_server.zig | 112 | 2026-05-26 |
| main.zig | 87 | 2026-05-23 |
| blockchain.zig | 52 | 2026-05-26 |
| p2p.zig | 44 | 2026-05-25 |
| ws_exchange_feed.zig | 17 | 2026-05-12 |
| transaction.zig | 16 | 2026-05-26 |
| dns_registry.zig | 12 | 2026-05-07 |
| database.zig | 11 | 2026-05-26 |
| evm_escrow_watcher.zig | 11 | 2026-05-25 |
| node_launcher.zig | 11 | 2026-05-13 |
| cli.zig | 11 | 2026-04-28 |
| wallet.zig | 10 | 2026-05-26 |
| pq_crypto.zig | 9 | 2026-05-26 |
| ws_server.zig | 9 | 2026-05-14 |
| dex_settler.zig | 8 | 2026-05-25 |
| genesis.zig | 7 | 2026-05-26 |
| bip32_wallet.zig | 6 | 2026-05-26 |
| blockchain_v2.zig | 6 | 2026-05-25 |
| mempool.zig | 6 | 2026-05-26 |
| block.zig | 6 | 2026-05-26 |

---

## Top Coupling

Co-change frequency: how often the top-10 churned files appear in the same commit as other core files.

- **rpc_server.zig** -> main.zig (18), blockchain.zig (11), ws_server.zig (4), transaction.zig (4)
- **main.zig** -> rpc_server.zig (18), p2p.zig (14), blockchain.zig (9), oracle_fetcher.zig (4)
- **blockchain.zig** -> main.zig (9), p2p.zig (8), rpc_server.zig (11), transaction.zig (5)
- **p2p.zig** -> main.zig (14), blockchain.zig (8), rpc_server.zig (5)
- **ws_exchange_feed.zig** -> rpc_server.zig (3), ws_server.zig (2), oracle_fetcher.zig (2)
- **transaction.zig** -> rpc_server.zig (4), blockchain.zig (5), main.zig (3)
- **dns_registry.zig** -> p2p.zig (4), mempool.zig (2), crypto.zig (1)
- **database.zig** -> blockchain.zig (3), p2p.zig (2)
- **evm_escrow_watcher.zig** -> dex_settler.zig (5), evm_rpc_client.zig (2)
- **node_launcher.zig** -> main.zig (3), wallet.zig (2), pq_crypto.zig (2)

---

## Fix-Churn Leaders

| File | Fix Commits | Total Commits | Fix Rate |
|------|-------------|---------------|----------|
| p2p.zig | 25 | 44 | 57% |
| ws_exchange_feed.zig | 8 | 17 | 47% |
| rpc_server.zig | 28 | 112 | 25% |
| blockchain.zig | 12 | 52 | 23% |
| pq_crypto.zig | 2 | 9 | 22% |
| main.zig | 18 | 87 | 21% |
| database.zig | 2 | 11 | 18% |
| node_launcher.zig | 2 | 11 | 18% |
| genesis.zig | 1 | 7 | 14% |
| transaction.zig | 2 | 16 | 13% |

---

## Stability Ranking (least stable first)

1. **p2p.zig** -- 57% fix rate + 44 commits; recurring races on inbound peer dispatch, sync wire format, SIGABRT on closed-fd writes, and hash comparison bugs in reorg paths. Structural concurrency issues.
2. **ws_exchange_feed.zig** -- 47% fix rate; LCX parser rewrites happened 5 times in sequence (window parse, bracket balancing, path, subscribe format, buffer size); protocol assumption drift each time exchange changed API.
3. **rpc_server.zig** -- highest absolute churn (112); 28 fix commits covering use-after-free, mutex missing on concurrent reads, port binding hardcoded, chain_id mapping errors. Acts as integration layer for everything.
4. **blockchain.zig** -- 23% fix rate + 52 commits; mutex missing on balance HashMap (UAF), credit/debit races, reorg truncation segfaults. Core state mutated from P2P and RPC threads simultaneously.
5. **main.zig** -- 21% fix rate + 87 commits; wire-everything orchestrator, so every subsystem addition creates drift; Linux/Windows portability issues surfaced repeatedly.
6. **ws_server.zig** -- 22% fix rate; SEGFAULT in broadcast race, port hardcoded, coupled to blockchain for timestamp units.
7. **database.zig** -- 18% fix rate; duplicate key restoration bug when reloading balances/nonces caused HashMap corruption.
8. **evm_escrow_watcher.zig** -- tightly coupled to dex_settler.zig; settler restart replay and watcher cursor persistence required simultaneous fixes; changes always arrive in pairs.
9. **node_launcher.zig** -- 18% fix rate; MIN_PEERS/MIN_MINERS threshold mismatch vs NodeLauncher created split behavior; config constant divergence pattern.
10. **pq_crypto.zig** -- 22% fix rate; algorithm name mismatches across domain_minter + bip32_wallet; sensitive to multi-agent drift in naming conventions.

---

## Recommendations

- **Fuzz p2p.zig message parsing** -- wire format for MsgGetHeaders, PONG, WELCOME, and block_announce has been patched 7+ times; a round-trip serialization test would have caught most regressions before merge.
- **Split rpc_server.zig into router + handlers** -- at 112 commits it is the single most-edited file; separating method dispatch from blockchain queries would localize future changes and reduce coupling to every subsystem.
- **Add a mutex audit CI step for blockchain.zig** -- at least 3 separate UAF/race fixes in balance HashMap; verifying all HashMap write paths hold the chain mutex at compile time would prevent recurrence.
- **Isolate the LCX WebSocket parser behind an adapter** -- ws_exchange_feed.zig had 5 sequential rewrites; a typed Feed interface would prevent each API change from rippling into arbitrage/oracle logic.
- **Consolidate consensus constants into chain_config.zig** -- MIN_PEERS_FOR_MINING, slot timing, and difficulty params appear in at least 4 files; constant drift caused repeated fix commits in node_launcher, bootstrap, and consensus.
