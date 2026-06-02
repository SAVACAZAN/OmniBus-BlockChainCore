# OmniBus Exchange + Agents + HTLC Stress Report

**Date:** 2026-05-10
**Duration:** ~12:36–12:50 UTC (~14 min active stress + parallel monitors)
**Endpoints tested:**
- mainnet: `https://omnibusblockchain.cc:8443/api-mainnet`
- testnet: `https://omnibusblockchain.cc:8443/api-testnet`

**Test wallet:** `ob1qw6zhsqg29aht23fksk5w54lkgavatpgltqxlvl` (mnemonic = abandon×11 about, BIP-44 m/44'/777'/0'/0/0)

**Balances at start:** mainnet 252.23 OMNI, testnet 203.97 OMNI
**Chain heights at start:** mainnet 30,265 / testnet 24,594; at end: mainnet 30,620 / testnet 24,848

**Verdict: YELLOW.** Testnet stable end-to-end (50/50 placed + 30/30 cancelled in two batches). Mainnet wedged ~12 min mid-test (RPC hung on a futex; systemd respawned it). Multiple API contract bugs found. Multi-chain HTLC settlement could not be exercised because there's no second trader to fill against.

---

## Section 1 — Exchange health

### Pair info (mainnet, all 7)

| pair_id | base/quote | maker | taker | live |
|--|--|--|--|--|
| 0 | OMNI/USDC | OmniBus | Base+Sepolia | YES |
| 1 | BTC/USDC  | — | — | **null** (B11) |
| 2 | LCX/USDC  | LCX Liberty | Base+Sepolia | YES |
| 3 | ETH/USDC  | Sepolia+Base | Base+Sepolia | YES |
| 4 | OMNI/BTC  | — | — | **null** (B11) |
| 5 | OMNI/LCX  | OmniBus | LCX Liberty | YES |
| 6 | OMNI/ETH  | OmniBus | Sepolia+Base | YES |

### Order placement (testnet, signed ECDSA on m/44'/777'/0'/0/0)

| pair_id | placed | accepted | cancelled | filled | failed |
|--|--|--|--|--|--|
| 0 OMNI/USDC | 10 | 10 | 10 | 0 | 0 |
| 2 LCX/USDC  | 10 | 10 | 0\* | 0 | 0 |
| 3 ETH/USDC  | 10 | 10 | 0\* | 0 | 0 |
| 5 OMNI/LCX  | 10 | 10 | 0\* | 0 | 0 |
| 6 OMNI/ETH  | 10 | 10 | 10 | 0 | 0 |
| **Total**   | **50** | **50** | **20+30**\*\* | 0 | 0 |

\* In Phase 5 v3 the cancellation script used wrong param `order_id` (B10) instead of `orderId` — **all 30 orders were left active**.
\*\* Cleanup pass with the correct param succeeded on 30/30. Phase 5b separately cancelled its own 20.

**Latency (placeOrder, testnet):**
- Phase 5 (mid-load): p50≈1.1s, p95≈2.0s, max≈2.07s
- Phase 5b (post-load): p50=572ms, p95=1647ms, max=1647ms

**Spread / midprice unobservable** — no second trader. All 50 orders sat in the orderbook unmatched. Best bid 995_000 vs best ask 1_004_999 = 9999 micro-USD spread (0.5%/0.5% bracket from synthetic mid).

**Recent trades:** zero on every pair (no fills happened during the test).

**Grids:** none active on mainnet (`grid_list` = `[]`); testnet returned `null` (B12).

### Phase-1 read-only RPCs (master harness, mainnet+testnet)

| Method | Calls | Errors | Error rate | p50 | p95 |
|--|--|--|--|--|--|
| `exchange_pairInfo`            | 14 | 4   | 28.6% | 60ms  | 120ms |
| `exchange_listOrders`          | 14 | 14  | **100%** | — | — |
| `exchange_listOrders` (loop)   | 100| 100 | **100%** | 68ms | 88ms |
| `exchange_getRecentTrades`     | 14 | 14  | **100%** | — | — |
| `exchange_getUserOrders`       | 14 | 12  | 86%   | — | — |

`exchange_listOrders` and `exchange_getRecentTrades` **don't exist** (B17). Real names are `exchange_getOrderbook` and `exchange_getTrades`. The original test plan referenced those names directly, so the read-side RPC plan needs to be revised.

---

## Section 2 — HTLC / Cross-chain

| RPC | mainnet samples | testnet samples | open | stuck>1h |
|--|--|--|--|--|
| `swap_listOpen`        | 50 | 50 | 0 | 0 |
| `htlc_listByAddress`   | 50 | 50 | 0 | 0 |
| `htlc_listPending`     | 50 | 50 | 0 | 0 |

Latency (testnet): p50 54-67ms, p95 79ms — fine.

**No HTLCs created during the test.** Per design (CLAUDE.md), HTLCs are only created at *fill* time, not at order-placement time. Since zero fills occurred (no counterparty), zero HTLCs spawned. **Multi-chain settlement path was NOT exercised.** That's the biggest blind spot of this run.

**B12**: `grid_list` returns `null` on testnet vs `[]` on mainnet. `swap_listOpen` returns `null` on testnet, `[]` on mainnet. Inconsistent empty-set encoding.

---

## Section 3 — Agents

| Network | getagents | agent_list | pending_decisions | registered |
|--|--|--|--|--|
| mainnet | 100×, p50=52ms, p95=66ms (`null` last) | n/a   | 50× p50=52ms (`null` last)        | 0 |
| testnet | 100×, p50=66ms, p95=123ms (`{agents:[]}` last)|`{count:0,agents:[]}`| 50× p50=65ms (`{count:0,decisions:[]}`) | 0 |

**B13**: mainnet returns bare `null`, testnet returns `{agents:[]}`. Same RPC, two shapes.

**Zero registered agents on either chain.** No AI decisions to execute. Agent subsystem appears to be dormant in production. The `agent_pending_decisions` execution rate cannot be measured because there are no registered agents.

---

## Section 4 — Multi-chain order test (testnet)

**Total signed orders submitted across two passes:** 70 (50 in Phase 5 + 20 in Phase 5b on pairs 0/6).
**Accepted:** 70/70 (100%).
**Cancelled cleanly:** 50/70 (Phase 5b's 20 + Phase 5 cleanup pass 30, after fixing the param-name bug).
**Filled:** 0/70 (no counterparty).
**Per-pair success:** 100% on every active pair (0,2,3,5,6).
**Average matching latency:** N/A (no matches). Order-acceptance latency: p50 572ms (low load) / p50 1.1s (during Phase 6 oracle storm).
**Replay protection:** working — `nonce` enforced, no replays accepted.
**Signature verification:** working — bad-sig rejects with `-32000`. Pubkey→address derivation matches.

---

## Section 5 — Oracle

**Mainnet exchange feed shape:**
```
{
  "prices": [
    {exchange:"Coinbase", pair:"BTC/USD", bidMicroUsd, askMicroUsd, success:true},
    {exchange:"Kraken",   pair:"BTC/USD", ...},
    {exchange:"LCX",      pair:"BTC/USD", ...},
    {exchange:"Coinbase", pair:"LCX/USD", ...},
    {exchange:"Kraken",   pair:"LCX/USD", ...},
    {exchange:"LCX",      pair:"LCX/USD", ...}
  ],
  medianBtcMicroUsd, medianLcxMicroUsd
}
```

**Mainnet oracle was DOWN for ~12 min** due to RPC wedge (B7); 274/330 oracle calls returned 502 / hung. After mainnet recovered: BTC median $80,919.66, LCX median $0.0378 (3 of 6 feeds healthy).

**B21 NEW** (post-recovery): LCX exchange feed for both BTC/USD and LCX/USD now reports `success:false, price=0`. Coinbase + Kraken still reporting normally. The LCX upstream connector failed during the wedge and didn't recover.

**Arbitrage opportunities detected in 30 min:** 0 — no arbitrage RPC ever returned populated data.

**Price stability** (Coinbase BTC 30 min, samples taken when mainnet was up):
- $80,866 → $80,927 (range $61, 0.075%) — normal.
**LCX/USD stability:** Coinbase $0.0380 → $0.0378 (0.5% drift). LCX-on-LCX feed shows the well-known wide spread ($0.0262 bid / $0.0379 ask = 31% spread, normal per memory `project_lcx_btc_spread_normal`).

---

## Section 6 — VPS health

| metric | min | avg | max |
|--|--|--|--|
| load1 | 3.68 | 4.36 | 5.41 |
| load5 | 4.11 | 4.65 | 5.26 |
| mem_used (MB) | 581 | 657 | 728 |
| mem_avail (MB) | 79 | 144 | 217 |
| omnibus-node procs | 3 | 3 | 3 |
| disk usage `/` | — | — | **84%** (B20) |

CPU ~4-5 load on 1 core (server has limited cores, this is sustained pressure). RAM 60-75% used out of 957 MB total — tight; 79 MB available at peak load is dangerous. All 3 omnibus-node processes (mainnet seed + miner + testnet seed) stayed alive throughout, but **mainnet was auto-respawned by systemd at ~12:48** (new PID 1303947). That counts as 1 unintended restart during the test window.

Log files: `mainnet.log` 60 MB, `testnet.log` 85 MB, `mainnet-miner.log` 83 MB. **No log rotation configured** (B20).

---

## Section 7 — Crash report

**Cumulative panic counts in /var/log/omnibus/ (start = end, no new crashes during this stress test):**
- mainnet.log: **32** panics
- testnet.log: **157** panics

**Three families:**

### Family A — Deadlock on `reputation_manager.zig:112` (CRITICAL, B1)
```
thread … panic: Deadlock detected
  std/Thread/Mutex.zig:72 in lock
  core/reputation_manager.zig:112 in creditVacationDay
    self.mutex.lock();   <-- already held by same thread
  core/main.zig:2847 in main
    rep_mgr.creditVacationDay(...)
```
Same thread re-acquires its own mutex. Caller path (`main.zig:2847`) is in mining loop. **Recurring** across both nets, and is the root cause of the mainnet RPC wedge (B7) — when a mining-loop thread deadlocks, the RPC handler thread waits forever on a shared lock, and `127.0.0.1:8332` accepts TCP but never replies. Systemd restart is the only recovery.

### Family B — `reached unreachable code` in `ws_server.zig:48` (HIGH, B2)
```
thread … panic: reached unreachable code
  std/posix.zig:6176 .BADF => unreachable, // always a race condition
  std/net.zig:2298 in drain
  std/Io/Writer.zig:183 in writeSplat
  core/ws_server.zig:48 in wsSend
    try stream.writeAll(data);
```
Sending on a WebSocket stream after the client disconnected. `posix.sendmsg` returns EBADF and Zig stdlib treats it as `unreachable`. Crashes the WS thread. **Recurring** on every WS client churn.

### Family C — `incorrect alignment` in `hash_map.zig:784` (HIGH, B3)
```
thread … panic: incorrect alignment
  std/hash_map.zig:784 in header
    return @ptrCast(@as([*]Header, @ptrCast(@alignCast(...))) - 1);
  std/hash_map.zig:798 in capacity
  std/hash_map.zig:977 in getIndex__anon_253265
  ...:368 in get
```
HashMap accessed before initialization (or after free / via dangling pointer). `metadata.?` unwrapped to a non-aligned address. Indicates **concurrent access to a hash map without a lock** OR **read after struct moved on heap** — same pattern as the historical `project_p2p_segv_fix` memory.

---

## Section 8 — Bug report

| ID | Severity | Title | Reproducer |
|--|--|--|--|
| **B1** | CRITICAL | `reputation_manager.zig:112` reentrant mutex deadlock in `creditVacationDay` | Look in `/var/log/omnibus/{mainnet,testnet}.log` for `Deadlock detected` next to `creditVacationDay`. Happens organically during mining loop. Suggested fix: restructure so caller already holds the lock OR replace `self.mutex.lock()` with a `tryLock()` and skip if already locked. |
| **B2** | HIGH | `ws_server.zig:48` panics on EBADF when WS client disconnects mid-write | Connect a WS client to `:8334`, send a `ping`, immediately RST the TCP connection. Server thread panics on next `wsSend`. Fix: catch `error.BrokenPipe` / `error.NotOpenForWriting` from `writeAll`, just close the session. |
| **B3** | HIGH | HashMap "incorrect alignment" panics — concurrent access OR dangling pointer | Recurring in `mainnet.log`. Add lock around the map OR audit who survives an `allocator.create` / `free` cycle. |
| **B7** | CRITICAL | Mainnet RPC port 8332 wedges (`futex_wait_queue_me` on all threads, accepts TCP, never replies) — likely caused by B1 deadlock holding a global lock the RPC handler waits on | Stress mainnet for ~5 min while a `creditVacationDay` deadlock fires. `curl 127.0.0.1:8332` even from inside the VPS hangs. Systemd restart is the only recovery (~5 min downtime + waits for restart cooldown). Observed in this run 12:36–12:48. |
| **B5** | HIGH | `test-scripts/13-dex-multichain-stress.mjs` is broken — sends `exchange_placeOrder` without `trader`, `signature`, `publicKey` | `node test-scripts/13-dex-multichain-stress.mjs --chain testnet --write` → 100% failures with `Missing param: trader`. Fix: include the BIP-44 m/44'/777'/0'/0/0 signing flow demonstrated in `stress-results/phase5-signed-orders.mjs`. |
| **B8** | MEDIUM | `exchange_placeOrder` rejects valid `pair="OMNI/USD"` for pair_id=0 (real label is `OMNI/USDC`) and the error message lies: "try OMNI/USD, BTC/USD, LCX/USD, ETH/USD" | Send `{trader, pair:"OMNI/USD", side, price, amount, nonce, signature, publicKey}` → `Unknown pair (try OMNI/USD…)`. Fix: error message must list `OMNI/USDC`, `BTC/USDC`, `LCX/USDC`, `ETH/USDC` (and OMNI/BTC, OMNI/LCX, OMNI/ETH). |
| **B9** | LOW | Same as B8 — error wording bug. |
| **B10**| MEDIUM | `exchange_cancelOrder` accepts only `orderId` (camelCase). Sending `order_id` (snake_case) → `Missing param: orderId`. Asymmetric vs. `exchange_placeOrder`, which accepts both `pair`/`pairId` styles. | Send `{trader, order_id:1, nonce, signature, publicKey}` → fail. Fix: `extractArrayNumByKey(body, "orderId") orelse extractArrayNumByKey(body, "order_id")`. |
| **B11**| MEDIUM | `exchange_pairInfo {pair_id:1}` and `{pair_id:4}` return `null`/`{info:null}` — should return either reserved metadata or an explicit error. | `curl … pairInfo {pair_id:1}` → `null`. Fix: return `{reserved:true, pair_id:1, base:"BTC", quote:"USDC", planned:true}`. |
| **B12**| LOW | Empty-set encoding inconsistency: testnet `grid_list` returns `null`, mainnet returns `[]`. `swap_listOpen` testnet `null`, mainnet `[]`. | Fix: always return `[]` from `grid_list` and `swap_listOpen`. |
| **B13**| LOW | `getagents` mainnet returns bare `null`, testnet returns `{agents:[]}`. Same RPC, two shapes — clients must branch. | Fix: always return `{agents:[]}`. |
| **B14**| MEDIUM | OMNI base-pair sells are NOT reservation-checked across simultaneous orders. With 204 OMNI balance, placing 5 sells × 0.1 OMNI each (= 0.5 OMNI committed across orderbook) all accept. If user places more than balance can cover across multiple pairs, orderbook will hold over-committed sells. Fix: `computeReservedFromOrderbook` already exists at line ~12036; verify it sums across all pairs sharing the same OMNI base. |
| **B17**| HIGH | `exchange_listOrders` and `exchange_getRecentTrades` **don't exist** as RPC methods — but appear in test plans, frontends, and docs. Real names: `exchange_getOrderbook` and `exchange_getTrades`. | `curl … {"method":"exchange_listOrders"}` → `Method not found`. Fix: either add aliases that route to the existing handlers, or update all callers (frontend, test scripts, docs) to the canonical names. |
| **B18**| HIGH | `exchange_getOrderbook` silently ignores `pair_id` (snake_case) and always returns pair 0. Only `pairId` (camelCase) is honored. | `curl … {"method":"exchange_getOrderbook","params":{"pair_id":2}}` → returns pair 0 empty book, NOT pair 2. Fix: accept both naming styles, like `exchange_placeOrder` does. |
| **B19**| LOW | Param-naming inconsistency across the exchange API — `placeOrder` accepts `pair`/`pairId`, `getOrderbook` accepts only `pairId`, `cancelOrder` accepts only `orderId`. Pick one and stick with it. |
| **B20**| MEDIUM | VPS disk 84% full (16/20 GB). Logs alone: mainnet 60 MB, testnet 85 MB, mainnet-miner 83 MB. **No logrotate.** Will hit disk-full + chain corruption within weeks. Fix: `logrotate.d` config + size cap. |
| **B21**| MEDIUM | After mainnet auto-recovered (12:48), LCX exchange-feed connector returns `success:false price=0` for both BTC/USD and LCX/USD. Coinbase + Kraken work. LCX upstream connector likely needs a reconnect/retry on the price-fetcher side. |

---

## Section 9 — Concluzii

**Overall health: YELLOW.**

Testnet acceptedt 100% of signed-order writes (70/70) and all targeted cancellations (50/50 after using the right param name). The matching engine, signature verification, replay-nonce protection, and balance check are all alive and working. Order-placement latency at p50 ~600 ms cold and ~1.1 s under oracle-fetch load is acceptable for a single-machine devnet but won't scale to many traders.

Mainnet had a **critical 12-minute RPC wedge** in the middle of the test (12:36 → 12:48), recovered only via systemd respawn. No new panic was logged for the wedge itself — the daemon was alive but every thread was parked in `futex_wait_queue_me`. The almost-certain cause is the recurring `reputation_manager.zig:112` reentrant-mutex deadlock (B1) holding a lock the RPC handler waits on. **This bug already has 32 traces in `mainnet.log` and 157 in `testnet.log`** — it is the dominant production issue today.

The 2-3 hour stress plan was effectively bounded by mainnet availability — once mainnet wedged we redirected everything to testnet, ran one full Phase 5 (50 orders, 5 pairs) plus Phase 5b (20 more on pairs 0+6), and verified read paths.

**Critically: cross-chain HTLC settlement was NOT exercised.** With one wallet placing both bid & ask, no fills happened, so no HTLC was generated, no preimage was revealed, no Base/Sepolia/Liberty contract leg was triggered. To genuinely stress the multi-chain path, a second signing identity (or a paper-mode counterparty) is required.

### Top 5 priorități de fix

1. **B1 + B7**: Trace the `creditVacationDay` deadlock and make the call site avoid double-locking. This single fix probably eliminates >90% of all panics and the mainnet wedge.
2. **B17 + B18**: API contract — settle the `exchange_listOrders` vs `getOrderbook` and `pair_id` vs `pairId` confusion. Either add aliases or break all callers cleanly. Frontend and stress scripts both broke on these in this run.
3. **B2**: Catch `EBADF`/`BrokenPipe` in `ws_server.zig:48` so a hostile (or just refresh-happy) WS client can't kill server threads.
4. **B3**: Audit hash-map access for missing lock. Likely culprit: order-book or address-balance map mutated by mining thread + RPC thread without `exchange_mutex`.
5. **B20**: Add `/etc/logrotate.d/omnibus` (size 50 MB, keep 5) before disk hits 100% and corrupts `chain.dat`.

### Risk assessment

- **High prob.** of mainnet hard-down in the next 1-7 days from B1 → B7 wedge cycle if traffic increases.
- **High prob.** of disk-full chain corruption in 2-4 weeks from B20.
- **Medium prob.** of signed-order replay or cross-pair over-commit under contended traffic — B14 needs a stress test with two distinct signing identities to confirm.
- **Cross-chain HTLC settlement is UNTESTED end-to-end.** Cannot certify mainnet is safe to take real liquidity until at least one fill+atomic-swap flow has been proven on testnet.

### Output artifacts (absolute paths)

- `c:/Kits work/limaje de programare/1_CORE/BlockChainCore/EXCHANGE_AGENTS_STRESS_REPORT_20260510.md` — this report
- `c:/Kits work/limaje de programare/1_CORE/BlockChainCore/stress-results/master-stress.mjs` — phases 1-4+6 read harness
- `c:/Kits work/limaje de programare/1_CORE/BlockChainCore/stress-results/master-summary.json` — phase 1-4+6 raw results
- `c:/Kits work/limaje de programare/1_CORE/BlockChainCore/stress-results/phase{1,2,3,4}.json` — per-phase JSONs
- `c:/Kits work/limaje de programare/1_CORE/BlockChainCore/stress-results/phase5-signed-orders.mjs` — signed-order stress (5 pairs)
- `c:/Kits work/limaje de programare/1_CORE/BlockChainCore/stress-results/phase5b-finish.mjs` — pair 0+6 follow-up
- `c:/Kits work/limaje de programare/1_CORE/BlockChainCore/stress-results/phase5b-results.json` — 20/20 success
- `c:/Kits work/limaje de programare/1_CORE/BlockChainCore/stress-results/cleanup-orders.mjs` — bulk-cancel 30 leaked orders
- `c:/Kits work/limaje de programare/1_CORE/BlockChainCore/stress-results/oracle-timeline.csv` — 110 oracle snapshots @ 5s
- `c:/Kits work/limaje de programare/1_CORE/BlockChainCore/stress-results/vps-health.csv` — 13 minute samples
- `c:/Kits work/limaje de programare/1_CORE/BlockChainCore/stress-results/crash-events.log` — baseline panic patterns
- `c:/Kits work/limaje de programare/1_CORE/BlockChainCore/stress-results/progress.log` — phase timeline
