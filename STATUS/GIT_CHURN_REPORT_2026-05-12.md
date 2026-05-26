# Git Churn / Coupling / Revert Report -- 2026-05-12

**Repo:** 1_CORE/BlockChainCore  
**History span:** 2026-03-18 to 2026-05-11 (~8 weeks)  
**Total commits analyzed:** 325  
**Scope:** core/*.zig primary, other files noted where relevant

---

## Top Churning Files (all-time, by commit count)

| Rank | File | Commits | Fix commits | Fix ratio |
|------|------|---------|-------------|----------|
| 1 | `core/rpc_server.zig` | 84 | 19 | 23% |
| 2 | `core/main.zig` | 76 | 22 | 29% |
| 3 | `core/blockchain.zig` | 44 | 10 | 23% |
| 4 | `core/p2p.zig` | 42 | 22 | 52% |
| 5 | `core/ws_exchange_feed.zig` | 16 | 8 | 50% |
| 6 | `core/transaction.zig` | 14 | 2 | 14% |
| 7 | `core/dns_registry.zig` | 12 | 2 | 17% |
| 8 | `core/cli.zig` | 11 | 2 | 18% |
| 9 | `core/database.zig` | 10 | 0 | 0% |
| 10 | `core/node_launcher.zig` | 10 | 2 | 20% |
| 11 | `core/wallet.zig` | 9 | 0 | 0% |
| 12 | `core/pq_crypto.zig` | 8 | 3 | 38% |
| 13 | `core/ws_server.zig` | 7 | 2 | 29% |
| 14 | `core/mempool.zig` | 6 | 2 | 33% |
| 15 | `core/genesis.zig` | 6 | 0 | 0% |
| 16 | `core/block.zig` | 6 | 0 | 0% |
| 17 | `core/bootstrap.zig` | 5 | 2 | 40% |
| 18 | `core/bip32_wallet.zig` | 5 | 1 | 20% |
| 19 | `core/secp256k1.zig` | 4 | 2 | 50% |
| 20 | `core/oracle_fetcher.zig` | 4 | 3 | 75% |

Single-commit files (introduced once, never revisited -- 50+ files):  
`core/grid_engine.zig`, `core/htlc.zig`, `core/htlc_btc.zig`, `core/escrow.zig`,  
`core/finality.zig`, `core/consensus.zig`, `core/lightning.zig`, all `core/identity/*.zig`,  
`core/cold_wallet.zig`, `core/covenant.zig`, `core/treasury_multi.zig`, etc.

---

## Top Coupled Pairs (co-changed in same commit)

| File A | File B | Co-changes | Interpretation |
|--------|--------|------------|----------------|
| `core/main.zig` | `core/rpc_server.zig` | 41 | New RPC always needs main wiring |
| `core/blockchain.zig` | `core/rpc_server.zig` | 28 | Chain state exposed via RPC |
| `core/blockchain.zig` | `core/main.zig` | 25 | Subsystem init flows through main |
| `core/main.zig` | `core/p2p.zig` | 21 | P2P config changes need main re-wire |
| `core/blockchain.zig` | `core/p2p.zig` | 14 | Block propagation tightly coupled |
| `core/p2p.zig` | `core/rpc_server.zig` | 13 | Peer state surfaced via RPC |
| `core/rpc_server.zig` | `core/transaction.zig` | 11 | TX types evolved with RPC |
| `core/blockchain.zig` | `core/transaction.zig` | 10 | TX validation lives in chain |
| `core/dns_registry.zig` | `core/rpc_server.zig` | 9 | NS RPC passes through rpc_server |
| `core/cli.zig` | `core/main.zig` | 8 | CLI args parsed before main runs |
| `core/rpc_server.zig` | `core/wallet.zig` | 7 | Wallet RPCs use wallet internals |
| `core/rpc_server.zig` | `core/ws_exchange_feed.zig` | 7 | Exchange feed pushed via WS RPC |
| `core/cli.zig` | `core/node_launcher.zig` | 7 | Launch mode determined by CLI |
| `core/blockchain.zig` | `core/dns_registry.zig` | 6 | NS records stored in chain state |
| `core/blockchain.zig` | `core/database.zig` | 6 | Chain persistence |
| `core/block.zig` | `core/blockchain.zig` | 6 | Block struct changes ripple to chain |
| `core/blockchain.zig` | `core/wallet.zig` | 6 | Wallet-derived addresses used in chain |
| `core/database.zig` | `core/rpc_server.zig` | 6 | DB schema changes require RPC update |
| `core/blockchain.zig` | `core/mempool.zig` | 5 | Mempool feeds chain |
| `core/cli.zig` | `core/rpc_server.zig` | 6 | CLI commands mirror RPC methods |

---

## Reverted Commits

| Commit | Message | Files |
|--------|---------|-------|
| `127191c` | fix(vite): allow public domain + revert to plain prefix proxy keys | frontend only (not core Zig) |

Only 1 explicit revert in 325 commits. Several multi-fix sweep commits indicate implicit rollbacks
of prior broken states. Notable: `75a5b3a fix(security+consensus+exchange): 8 blocker fixes from
agent sweep` touches 14 files at once -- a broad regression correction.

Implicit rollback indicators:

- `core/p2p.zig` -- 22 fix commits in 42 total (off-by-one, wire-format, reconnect bugs recurred)
- `core/oracle_fetcher.zig` -- 3 fixes in 4 commits (near-immediate corrections after introduction)
- `core/rpc_server.zig` -- KYC/escrow/exchange logic required 3 rollback-style fixes in quick succession

---

## Stability Ranking

Verdict scale: Stable / Moderate / Unstable / Hot

| Rank | File | Churn | Top coupled-with | Fix ratio | Verdict |
|------|------|-------|-----------------|-----------|--------|
| 1 (least stable) | `core/rpc_server.zig` | 84 | main, blockchain, p2p | 23% | Hot -- god file, all features land here first |
| 2 | `core/main.zig` | 76 | rpc_server, blockchain, p2p | 29% | Hot -- orchestrator, every subsystem touches it |
| 3 | `core/p2p.zig` | 42 | main, blockchain, rpc_server | 52% | Unstable -- wire protocol bugs recur; highest fix ratio |
| 4 | `core/blockchain.zig` | 44 | rpc_server, main, p2p | 23% | Unstable -- large surface, many features piled on top |
| 5 | `core/ws_exchange_feed.zig` | 16 | rpc_server | 50% | Unstable -- half its commits are fixes; exchange feed evolving |
| 6 | `core/oracle_fetcher.zig` | 4 | main | 75% | Unstable -- nearly every touch is a fix; introduced broken |
| 7 | `core/transaction.zig` | 14 | rpc_server, blockchain | 14% | Moderate -- mostly feat additions, few fixes |
| 8 | `core/dns_registry.zig` | 12 | rpc_server, blockchain | 17% | Moderate -- active NS phase-2 work, low fix ratio |
| 9 | `core/pq_crypto.zig` | 8 | main | 38% | Moderate -- liboqs binding churn; gated correctly now |
| 10 | `core/mempool.zig` | 6 | blockchain | 33% | Moderate -- RBF + sig verification added late |
| 11 | `core/secp256k1.zig` | 4 | p2p, blockchain | 50% | Moderate -- low-S fix + PoW speedup; security-critical |
| 12 | `core/bootstrap.zig` | 5 | main, p2p | 40% | Moderate -- discovery logic still being tuned |
| 13 | `core/database.zig` | 10 | blockchain, rpc_server | 0% | Stable -- no fix commits; schema evolves cleanly |
| 14 | `core/wallet.zig` | 9 | rpc_server, blockchain | 0% | Stable -- PQ domains added cleanly, no regressions |
| 15 | `core/genesis.zig` | 6 | blockchain | 0% | Stable -- config param tuning only |
| 16 | `core/block.zig` | 6 | blockchain | 0% | Stable -- struct definition, rarely broken |
| 17 | `core/bip32_wallet.zig` | 5 | wallet | 20% | Stable -- 1 fix for algorithm name alignment |
| 18 | `core/cli.zig` | 11 | main, node_launcher | 18% | Stable -- argument parsing, low risk |
| 19 | `core/node_launcher.zig` | 10 | cli, main | 20% | Stable -- launch orchestration, infrequent breaks |
| 20+ | `core/finality.zig, core/consensus.zig, core/identity/*.zig, core/htlc*.zig` | 1 each | -- | 0% | Stable (untested) -- single introduction, no rework yet |

---

## Recommendations

1. **Split `core/rpc_server.zig` immediately.** At 84 commits and 22k+ lines in a single file,
   it is the single biggest risk surface. Group by domain: `rpc_exchange.zig`, `rpc_wallet.zig`,
   `rpc_ns.zig`, `rpc_chain.zig`. This will also break the 41-commit coupling lock with `main.zig`.

2. **Stabilize `core/p2p.zig` before mainnet.** 22 of 42 commits are fixes -- the highest fix ratio
   among high-churn files. The wire protocol (PONG height echo, hash truncation, reconnect logic) has
   had at least 8 distinct bug cycles. Write a property-based fuzz test for the P2P message codec.

3. **Quarantine `core/oracle_fetcher.zig`.** 75% fix ratio signals this module needs either a
   complete rewrite or removal from the critical mining path. The consensus/oracle decoupling fix
   (ea9e0bc) was the right call -- extend it further with fully async, non-blocking oracle queries.

4. **Add integration smoke tests for the main + rpc_server coupling cluster.** These two files change
   together in 41 commits with no automated guard. A minimal RPC harness (spin node, call 5-10 RPCs,
   assert non-error) would catch wiring regressions before they accumulate.

5. **Treat single-commit files as untested stubs.** Files like `core/lightning.zig`,
   `core/grid_engine.zig`, `core/intent_registry.zig`, and all `core/identity/*.zig` have never
   been revisited. Validate each with `zig build test-*` before treating as production-ready.

6. **Freeze feature additions to `core/ws_exchange_feed.zig`.** 50% fix ratio in 16 commits suggests
   the exchange WebSocket feed was shipped before the underlying data model stabilized. Validate
   existing fixes on testnet before adding more features.

7. **Introduce a `ChainState` read interface to decouple `core/blockchain.zig`.** It appears in 9
   of the top-20 coupled pairs (rpc_server, main, p2p, transaction, database, wallet, dns_registry,
   mempool, block). An interface boundary would limit blast radius when the chain struct changes.
