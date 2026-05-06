# OmniBus BlockChainCore — Stability Report
**Period**: last 6 months (approximately Nov 2025 – May 2026)
**Generated**: 2026-05-07
**Scope**: `core/*.zig` — git history analysis only, no code was modified

---

## 1. Top 10 Churn Ranking

Churn = total lines inserted + deleted across all commits in the period.
Fix ratio = fix/crash/panic commits as a share of all commits touching that file.
Change rate = churn LOC / current file LOC (volatility density).

| Rank | File | Commits | Churn LOC | +ins / -del | Fix commits | Fix ratio | Current LOC | Churn/LOC |
|------|------|---------|-----------|-------------|-------------|-----------|-------------|-----------|
| 1 | `core/rpc_server.zig` | 68 | 15,273 | +14,064 / -1,209 | 37 | **54%** | 13,116 | **1.16** |
| 2 | `core/main.zig` | 69 | 3,891 | +3,298 / -593 | 41 | **59%** | 2,734 | **1.42** |
| 3 | `core/p2p.zig` | 39 | 4,661 | +4,378 / -283 | 30 | **77%** | 4,105 | **1.14** |
| 4 | `core/blockchain.zig` | 35 | 4,833 | +4,407 / -426 | 19 | **54%** | 4,097 | **1.18** |
| 5 | `core/ws_exchange_feed.zig` | 16 | 2,292 | +1,893 / -399 | 10 | **63%** | 1,494 | **1.53** |
| 6 | `core/pq_crypto.zig` | 6 | 2,116 | +1,329 / -787 | 0 | 0% | 542 | **3.90** |
| 7 | `core/database.zig` | 10 | 1,970 | +1,918 / -52 | 6 | **60%** | 1,866 | **1.06** |
| 8 | `core/dns_registry.zig` | 10 | 1,723 | +1,598 / -125 | 4 | **40%** | 1,687 | **1.02** |
| 9 | `core/transaction.zig` | 12 | 1,270 | +1,150 / -120 | 7 | **58%** | 1,030 | **1.23** |
| 10 | `core/isolated_wallet.zig` | 4 | 1,022 | +996 / -26 | 0 | 0% | 970 | **1.05** |

**Notable outlier**: `core/pq_crypto.zig` — only 6 commits but churn/LOC ratio of 3.9, meaning the file was effectively rewritten twice over. The large deletion run (−787) corresponds to ripping out the Pure-Zig SHAKE mock and replacing it with real liboqs bindings (`17236fb`).

**`core/main.zig`** has the highest fix ratio at 59% and the second-highest churn/LOC. It is the orchestrator entry point and absorbs every integration mismatch from other modules.

---

## 2. Coupling Map — Top 10 Strongest Pairs

Co-change percentage = fraction of File A's commits where File B also changed.

| Rank | File A | File B | A→B co-change | B→A co-change | Interpretation |
|------|--------|--------|---------------|---------------|----------------|
| 1 | `rpc_server.zig` | `main.zig` | 49% (33/68) | 48% (33/69) | Strongest coupling in repo — every new RPC endpoint requires main.zig wiring |
| 2 | `blockchain.zig` | `rpc_server.zig` | 57% (20/35) | 29% (20/68) | State mutations always surface as new RPC fields |
| 3 | `blockchain.zig` | `main.zig` | 54% (19/35) | 28% (19/69) | Subsystem lifecycle managed directly in main |
| 4 | `p2p.zig` | `main.zig` | 51% (20/39) | 29% (20/69) | P2P node init tightly bound to main startup sequence |
| 5 | `p2p.zig` | `rpc_server.zig` | 30% (12/39) | 18% (12/68) | Sync-state / IBD progress exposed via RPC |
| 6 | `p2p.zig` | `blockchain.zig` | 30% (12/39) | 34% (12/35) | Reorg and block apply shared between both |
| 7 | `database.zig` | `blockchain.zig` | 60% (6/10) | 17% (6/35) | Storage schema changes always chase chain state changes |
| 8 | `database.zig` | `rpc_server.zig` | 60% (6/10) | 9% (6/68) | DB layout changes bubble up to RPC serialisation |
| 9 | `ws_exchange_feed.zig` | `rpc_server.zig` | 43% (7/16) | 10% (7/68) | Price-feed data consumed by RPC arbitrage endpoints |
| 10 | `database.zig` | `storage.zig` | 40% (4/10) | ~100% (4/4) | These two files are conceptually the same layer |

**Pairs exceeding 50% co-change** (threshold for "effectively one module"):
- `rpc_server.zig` ↔ `main.zig`: 49%/48% — nearly symmetric, very tight
- `blockchain.zig` → `rpc_server.zig`: 57%
- `blockchain.zig` → `main.zig`: 54%
- `p2p.zig` → `main.zig`: 51%
- `database.zig` → `blockchain.zig`: 60%
- `database.zig` → `rpc_server.zig`: 60%

---

## 3. Revert Log

There were no `git revert` commits in the period. However, three commits contain "revert" in their body — meaning the author manually reversed a prior decision within a follow-up fix commit:

### 3a. `fef75d9` — `fix(lcx-ws): connect to '/' not '/ws'`
**What was tried**: The `/ws` path was used for the LCX WebSocket endpoint, following an early reading of a Python SDK helper that appended `/ws`.
**Why it was reverted**: Live testing against `wss://exchange-api.lcx.com` showed that `/ws` accepts the WebSocket upgrade and even acknowledges subscriptions, but never streams ticker data. The actual working path is `/`. The correct subscribe format also changed — using a Pair field on a ticker subscription is wrong; the brand-less subscribe streams all pairs.
**Files affected**: `core/ws_exchange_feed.zig`

### 3b. `c1934fb` — `fix(lcx-ws): correct format — keys-as-pair-name + windowed parse`
**What was tried**: The previous parse assumed the LCX snapshot frame had pair names as JSON values (`data.pair`), matching the documented format.
**Why it was reverted**: Live frame inspection showed the real format uses pair names as JSON keys (`"BTC/USDC": {bestBid: ..., bestAsk: ...}`). The old parser therefore always read the first pair's bid/ask for every slot, explaining the persistent `n/a` display.
**Files affected**: `core/ws_exchange_feed.zig`

### 3c. `da92b5b` — `fix(ns): keep 5/10 OMNI registration price`
**What was tried**: A prior commit introduced a per-chain discount on name registration fees, reducing the price on testnet/regtest.
**Why it was reverted**: The user clarified that 5 OMNI is the domain registrar price the buyer pays — not a network gas fee — and should be identical across all chains. The per-chain discount was semantically wrong.
**Files affected**: `core/rpc_server.zig`

**Pattern**: All three reversals stem from the same root: building against documentation or assumption rather than live system behaviour. The LCX reversals happened in rapid succession (two commits within hours) — a classic documentation/reality gap in an external API integration.

---

## 4. Critical Bug History — Crash Events

Beyond clean reverts, the following classes of crash/SEGFAULT bugs were fixed in this period:

| Commit | Module | Bug Class | Root Cause |
|--------|--------|-----------|------------|
| `acfcfd2` | `blockchain.zig` | Dangling pointer SEGFAULT | `getOrPut(address)` borrows the key then dupes it after; realloc during the gap invalidates the borrow |
| `e770ddd` | `blockchain.zig` | HashMap race / use-after-free | `mineBlockForMiner` skipped the global mutex but still touched `self.balances`; concurrent RPC reads caused bucket realloc mid-iteration |
| `1fef278` | `rpc_server.zig` | Use-after-free in defer chain | Defers run in reverse order — `fetchSub(ctx.active_counter)` ran after `ctx` was already freed |
| `63c7c38` | `p2p.zig` + `blockchain.zig` | Segfault after reorg | Reorg truncation did not recalculate balances from the now-canonical chain |
| `19607a6` | `database.zig` | Duplicate address keys on restore | HashMap keys not duped when restoring from DB; original string data freed before map read |
| `1cffdc6` | `rpc_server.zig` | Crash on getOrderbook | Large struct allocated on stack; exceeded stack limit. Fixed with `page_allocator` |
| `6903a77` | `main.zig` | Linux stack overflow | `P2PNode` allocated on stack (too large for Linux default thread stack) |

All seven crashes are memory-safety bugs in Zig code that uses manual allocation: dupe-before-use violations, missing mutex coverage, and stack-size assumptions. This is a systemic pattern in `blockchain.zig` and `rpc_server.zig`.

---

## 5. Top 5 Stability Concerns

### Concern 1 — `core/rpc_server.zig` is a God Object (15,273 churn LOC, 54% fix ratio, 13,116 current LOC)

`rpc_server.zig` grew from a thin JSON-RPC dispatcher to containing business logic for exchange operations, name-service registration, oracle aggregation, bridge endpoints, and EVM stubs. Every new feature in the last 6 months added 200–1,600 lines directly to this file. Its 54% fix ratio means more than half its commits are corrections rather than additions.

**Recommendation**: Decompose into at minimum 4 focused files:
- `rpc_exchange.zig` — exchange/paper trading endpoints
- `rpc_ns.zig` — DNS/name-service endpoints
- `rpc_chain.zig` — block/tx/mempool/balance queries
- `rpc_server.zig` — dispatcher + auth only

### Concern 2 — `core/main.zig` is the wrong integration layer (3,891 churn, 59% fix ratio)

`main.zig` is the global wiring harness. Currently it: starts subsystems, owns the mining loop, manages slot timing, holds oracle injection logic, and patches Linux/Windows portability gaps. The 59% fix ratio is the highest in the repo — most fixes here are "I wired X wrong" or "X boot order is wrong", not logical bugs in main itself. The 33-commit coupling with `rpc_server.zig` confirms they share responsibilities that should be separated.

**Recommendation**: Extract a `core/node.zig` that owns subsystem lifecycle (init order, shutdown), leaving `main.zig` as a thin CLI-to-node bridge. The mining loop belongs in `orchestrator.zig`, which already exists and already co-changes with `main.zig` in 5 commits.

### Concern 3 — `core/p2p.zig` has 77% fix ratio — protocol instability (39 commits, 30 of them fixes)

P2P had the most sustained bug-fix stream of any module: wire-format mismatches (8 vs 10 bytes), hash truncation bugs (32-char vs 256-bit), inbound peer registration omission, PONG echoing wrong height, sync trigger off-by-ones, and reorg/segfault cascades. Seven of these bugs were found only on a live multi-node VPS — they were invisible in single-node dev mode.

**Recommendation**: The P2P wire protocol needs a versioned protocol specification (a small `.md` or a comment block with field offsets and invariants) pinned at the top of `p2p.zig`. Every one of the eight wire-format bugs was caused by the format living only in the author's head. Additionally, a two-node integration test (`zig build test-net`) should run on every commit.

### Concern 4 — `core/database.zig` + `core/storage.zig` are two files for the same concept

`database.zig` (10 changes) and `storage.zig` (4 changes) co-change at 40%+ and serve overlapping roles: both manage on-disk persistence of chain state. The 60% co-change rate of `database.zig` with both `blockchain.zig` and `rpc_server.zig` means every schema change touches at least three files. The UTXO/chainstate refactor (Phase B/C) required changes to all three simultaneously.

**Recommendation**: Merge `storage.zig` into `database.zig` under a clear layering contract: `database.zig` owns the binary format and read/write primitives; `blockchain.zig` owns the in-memory state and calls database for persistence. The `core/store/` subdirectory (WAL + KV + chainstate) already provides a better split — `database.zig` should become a thin adapter over it.

### Concern 5 — `core/ws_exchange_feed.zig` is brittle against external API drift (63% fix ratio, 3 reversals in one session)

All three revert events in the period came from this file. The LCX WebSocket integration was written against documentation that did not match the live server. The fix cycle (wrong path → right path → wrong format → right format) spanned multiple commits in a single day, indicating the external API is not being tested against a live connection before merge.

**Recommendation**: Add a `tools/lcx_ws_probe.sh` (or equivalent) that connects to LCX and prints a raw frame dump. Run this before touching `ws_exchange_feed.zig`. The parser logic (windowed key scan for `"BTC/USDC":{`) is fragile — consider using Zig's `std.json` streaming tokenizer instead of marker-based substring search.

---

## 6. Coupling — Should Any Pairs Be Merged?

Based on co-change > 50%:

| Pair | Action |
|------|--------|
| `rpc_server.zig` ↔ `main.zig` | Do NOT merge; instead extract an explicit `node.zig` to break the direct coupling. Both files are already too large. |
| `blockchain.zig` → `rpc_server.zig` (57%) | Establish a clean API: `blockchain.zig` exposes typed query functions; `rpc_server.zig` calls them. Currently RPC directly inspects blockchain internals. |
| `blockchain.zig` → `main.zig` (54%) | Resolved by the `node.zig` extraction above. |
| `database.zig` → `blockchain.zig` (60%) | Merge `storage.zig` into `database.zig` (see Concern 4). Define a `Persistence` interface that `blockchain.zig` calls. |
| `p2p.zig` → `main.zig` (51%) | Already partially addressed by `orchestrator.zig`; complete the extraction. |

---

## 7. Summary Table

| Module | Verdict | Priority |
|--------|---------|----------|
| `rpc_server.zig` | God object — split into 4 focused files | CRITICAL |
| `p2p.zig` | Protocol instability — needs spec + integration test | HIGH |
| `main.zig` | Wrong integration layer — extract `node.zig` | HIGH |
| `database.zig` + `storage.zig` | Two files, one concept — merge | MEDIUM |
| `ws_exchange_feed.zig` | Fragile external API parsing — add live probe tool + use streaming JSON | MEDIUM |
| `pq_crypto.zig` | One large rewrite (SHAKE mock → liboqs) — stable now, monitor | LOW |
| `blockchain.zig` | Two SEGFAULT bugs fixed; memory model needs audit | HIGH |
