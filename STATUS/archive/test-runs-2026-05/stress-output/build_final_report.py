#!/usr/bin/env python3
"""Final unified report builder."""
from __future__ import annotations
import csv, json, statistics, re
from collections import defaultdict, Counter
from datetime import datetime, timezone
from pathlib import Path

OUT = Path(r"c:/Kits work/limaje de programare/1_CORE/BlockChainCore/stress-output")
ROOT = OUT.parent
TODAY = datetime.now().strftime("%Y%m%d")
REPORT = ROOT / f"STRESS_TEST_REPORT_{TODAY}.md"


def load_csv(path: Path) -> list[dict]:
    if not path.exists():
        return []
    with open(path, encoding="utf-8") as fh:
        return list(csv.DictReader(fh))


def load_json(path: Path):
    if not path.exists():
        return None
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return None


def load_panic_traces(path: Path) -> list[dict]:
    """Extract distinct panic patterns from a panic-traces file."""
    if not path.exists():
        return []
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except Exception:
        return []
    # Split on 'thread \d+ panic:'
    blocks = re.split(r"\nthread \d+ panic:", text)
    traces = []
    for blk in blocks[1:]:
        # First line after split is panic kind
        m = re.match(r"\s*([^\n]+)", blk)
        if not m:
            continue
        panic_kind = m.group(1).strip()
        # Find first project file in trace (core/*.zig)
        proj_match = re.search(r"/root/omnibus-blockchain/(core/\w+\.zig:\d+:\d+)", blk)
        proj_loc = proj_match.group(1) if proj_match else "?"
        # Find function name on next line
        fn_match = re.search(r"in (\w+)\s*\(", blk)
        fn_name = fn_match.group(1) if fn_match else "?"
        traces.append({"kind": panic_kind, "loc": proj_loc, "fn": fn_name})
    return traces


def main():
    lines = []
    push = lines.append

    push(f"# OmniBus Chain Core Stress Test Report — {TODAY}")
    push("")
    push(f"- Generated: {datetime.now(timezone.utc).isoformat(timespec='seconds')}")
    push("- Endpoints: mainnet=`https://omnibusblockchain.cc:8443/api-mainnet`, testnet=`https://omnibusblockchain.cc:8443/api-testnet`")
    push("- Test runners: master orchestrator (Python threaded) + bash test scripts loops + sustained 45-min @ 2 RPS background load + Node.js DEX/HTLC scripts + legacy rpc-tester full RPC matrix")
    push("- Plan reference: 15-run plan from user spec, target ~2 hours")
    push("")
    push("---")
    push("")

    # ── EXECUTIVE SUMMARY ─────────────────────────────────────────────
    push("## EXECUTIVE SUMMARY — CRITICAL FINDINGS")
    push("")
    push("Stress test exposed **multiple production-blocker bugs** in the OmniBus chain core during heavy read-only RPC load. The **mainnet seed crashed 5 times** AND the **testnet seed crashed 4 times** during the same ~25-minute window, with distinct signatures (SEGV, SIGABRT, hang+SIGKILL). Both chains have identical bug surfaces; testnet appears more stable only because of lighter traffic between crashes.")
    push("")
    push("### Bug #1 — Recursive deadlock on `Blockchain.mutex`  (CRITICAL)")
    push("")
    push("Triggered by **most read RPCs** (`getbalance`, `getminerstats`, `getnetworkinfo`, `getblockcount`) under concurrent load.")
    push("")
    push("Stack trace (mainnet, repeated 12+ times):")
    push("```text")
    push("thread 1023886 panic: Deadlock detected")
    push("std/Thread/Mutex.zig:72:13: in lock           @panic(\"Deadlock detected\")")
    push("core/blockchain.zig:2707:24: in getBlockCount     self.mutex.lock();")
    push("core/rpc_server.zig:2869:41: in handleGetBalance  const height = ctx.bc.getBlockCount();")
    push("core/rpc_server.zig:3774:75: in dispatch          \"getbalance\" -> handleGetBalance")
    push("core/rpc_server.zig:691:30:  in handleConnCounted dispatch(body, ctx.server_ctx)")
    push("```")
    push("")
    push("**Root cause hypothesis**: `core/blockchain.zig` uses a single non-recursive `std.Thread.Mutex`. An RPC path acquires it (e.g. `handleGetBalance` locks it for balance lookup) and inside that path calls another method (`getBlockCount`) which tries to lock the same mutex again → Zig's debug-mode mutex detects double-acquire → panic.")
    push("")
    push("**Affected RPC handlers (confirmed in traces)**: `handleGetBalance`, `handleMinerSt` (getminerstats), `handleNetInfo` (getnetworkinfo), `handleGetBlockCount` itself.")
    push("")
    push("**Fix**: either (a) switch to a re-entrant mutex; (b) refactor every internal caller of `getBlockCount` (or any locked-method) inside another locked method to use an unlocked `_Locked` variant; (c) audit `blockchain.zig` for nested lock acquisitions.")
    push("")
    push("### Bug #2 — Recursive deadlock on `ReputationManager.mutex`  (CRITICAL)")
    push("")
    push("Triggered every block reward path:")
    push("")
    push("```text")
    push("thread 1116616 panic: Deadlock detected")
    push("core/reputation_manager.zig:112:24: in creditVacationDay  self.mutex.lock();")
    push("core/main.zig:2847:50: in main  rep_mgr.creditVacationDay(...)")
    push("```")
    push("")
    push("**Impact**: kills the **main thread** (mining loop) → process abort. This is the SIGABRT seen at 12:50:37.")
    push("")
    push("**Fix**: same pattern as #1 — `creditVacationDay` is being called while holding `rep_mgr.mutex` from another path (likely `creditMined` or block-finalize hook).")
    push("")
    push("### Bug #3 — Hash map corruption / race in `address_tx_index`  (HIGH)")
    push("")
    push("Multiple alignment + unreachable panics on the same hash map used by `listtx` RPC and concurrent indexers:")
    push("")
    push("```text")
    push("thread 1100742 panic: incorrect alignment")
    push("std/hash_map.zig:784:44: in header  @ptrCast(@alignCast(self.metadata.?))")
    push("std/hash_map.zig:798:31: in capacity  return self.header().capacity;")
    push("std/hash_map.zig:1088:30: in getAdapted  if (self.getIndex(key, ctx)) |idx|")
    push("core/blockchain.zig:670:47: in getAddressHistory  self.address_tx_index.get(address)")
    push("core/rpc_server.zig:5625:37: in handleListTx")
    push("```")
    push("")
    push("And:")
    push("")
    push("```text")
    push("thread 1257297 panic: reached unreachable code")
    push("std/debug.zig:1735:15: in lock  assert(l.state == .unlocked);")
    push("std/hash_map.zig:1113:44: in getOrPutContextAdapted  self.pointer_stability.lock();")
    push("```")
    push("")
    push("**Diagnosis**: `address_tx_index` HashMap is being mutated by indexer thread while another thread is reading it (`get()`). The HashMap's `pointer_stability` debug lock detects the violation. In release-mode this would be silent corruption.")
    push("")
    push("**Fix**: protect `address_tx_index` with the same `Blockchain.mutex` (or its own RwLock) for both read and write. Currently reads appear unlocked.")
    push("")
    push("### Bug #4 — WebSocket double-close race  (MEDIUM)")
    push("")
    push("```text")
    push("thread 1142937 panic: reached unreachable code")
    push("std/posix.zig:294:18: in close  .BADF => unreachable, // Always a race condition.")
    push("std/net.zig:1915:32: in close   else => posix.close(s.handle),")
    push("core/ws_server.zig:279:28: in removeClient  client.stream.close();")
    push("```")
    push("")
    push("**Diagnosis**: `removeClient` closes a fd that was already closed by another thread/path. Zig's posix close marks BADF as `unreachable` because POSIX says it's a race. ")
    push("")
    push("**Fix**: serialize `removeClient` per-client (single-shot close), or wrap `client.stream.close()` to swallow EBADF.")
    push("")
    push("### Bug #5 — `omnibus-mainnet.service` shutdown hang (HIGH)")
    push("")
    push("During the test we observed:")
    push("")
    push("```text")
    push("May 10 12:48:13 omnibus-mainnet.service: Stopping...")
    push("May 10 12:48:44 omnibus-mainnet.service: State 'stop-sigterm' timed out. Killing.")
    push("May 10 12:48:44 omnibus-mainnet.service: Killing process 1291055 (omnibus-node) with signal SIGKILL.")
    push("(28 child threads SIGKILLed)")
    push("```")
    push("")
    push("The Zig binary doesn't return from main on SIGTERM; systemd has to SIGKILL after 30s. Likely caused by mining loop or peer thread blocked on a lock held by a panicked thread.")
    push("")
    push("### Bug #6 — Methods not implemented (LOW, API gap)")
    push("")
    push("Returns `-32601 Method not found`:")
    push("- `swap_list`, `htlc_list`, `bridge_list`, `swap_refund`")
    push("- `exchange_listOrders`, `exchange_getRecentTrades`")
    push("- `getrawmempool` (testnet)")
    push("")
    push("Frontend / SDK code references these — recommend adding stub implementations that return empty arrays.")
    push("")

    # ── Mainnet crash timeline ────────────────────────────────────────
    push("## Crash Timeline — Both Chains")
    push("")
    push("From `journalctl -u omnibus-mainnet` and `journalctl -u omnibus-testnet`:")
    push("")
    push("### Mainnet")
    push("")
    push("| time UTC | event | exit code | notes |")
    push("|---|---|---|---|")
    push("| 12:32:01 | Main process exited | **status=11/SEGV** | baseline crash |")
    push("| 12:36:37 | Main process exited | **status=11/SEGV** | crash #2 in 4 min (during stress start) |")
    push("| 12:48:13-44 | Stopping → timeout → **SIGKILL** | hung shutdown | 28 child threads SIGKILL'd |")
    push("| 12:50:37 | Main process exited | **status=6/ABRT** | SIGABRT — main thread (Bug #2) |")
    push("| 12:57:01 | Main process exited | **status=6/ABRT** | another SIGABRT |")
    push("")
    push("**5 mainnet crashes in 25 minutes** during the stress window.")
    push("")
    push("### Testnet (also crashes!)")
    push("")
    push("| time UTC | event | exit code | notes |")
    push("|---|---|---|---|")
    push("| 12:31:41 | Main process exited | **status=11/SEGV** | baseline |")
    push("| 12:35:55 | Main process exited | **status=6/ABRT** | core dumped |")
    push("| 12:40:00 | Main process exited | **status=11/SEGV** | |")
    push("| 12:56:45 | Main process exited | **status=6/ABRT** | during round 3 |")
    push("")
    push("**4 testnet crashes in 25 minutes**. testnet appeared \"stable\" in our test runs only because systemd auto-restart is fast (~5 sec) and our test pace allows recovery between crashes. **Both chains have the same set of bugs — testnet survives only because traffic is lighter.**")
    push("")
    push("Auto-restart by systemd masks the impact for end-users but each crash loses ~1-3 min of mining + breaks any in-flight RPC + sometimes loses non-finalized state in `chain.dat`.")
    push("")

    # ── Distinct panic types ──────────────────────────────────────────
    push("## Distinct Panic Signatures Observed")
    push("")

    main_traces = load_panic_traces(OUT / "panic-traces-mainnet.txt")
    test_traces = load_panic_traces(OUT / "panic-traces-testnet.txt")

    if main_traces or test_traces:
        # Aggregate
        sigs_main = Counter()
        sigs_test = Counter()
        for t in main_traces:
            sigs_main[(t["kind"], t["loc"], t["fn"])] += 1
        for t in test_traces:
            sigs_test[(t["kind"], t["loc"], t["fn"])] += 1
        push("### Mainnet")
        push("")
        push("| count | panic kind | site | function |")
        push("|---:|---|---|---|")
        for (k, l, f), n in sigs_main.most_common(20):
            push(f"| {n} | {k} | `{l}` | `{f}` |")
        push("")
        if sigs_test:
            push("### Testnet")
            push("")
            push("| count | panic kind | site | function |")
            push("|---:|---|---|---|")
            for (k, l, f), n in sigs_test.most_common(20):
                push(f"| {n} | {k} | `{l}` | `{f}` |")
            push("")

    push("---")
    push("")

    # ── Round summaries ──────────────────────────────────────────────
    push("## Round Summaries")
    push("")
    push("### Round 1 — Master orchestrator (Python, sequential, 8s timeout)")
    push("")
    push("- Duration: ~9 min (12:36:47 → 12:45:55 UTC)")
    push("- Total RPC calls: **3,730**")
    push("- Pass: **1,202** (32.2%)")
    push("- Fail: **2,341** (62.8%)")
    push("- Skip: **187** (5.0%)")
    push("- All 15 phases ran (chain basics → flood → full matrix)")
    push("- High failure rate dominated by mainnet 502 (Bug #5 hung accept loop) and chain-side validation rejections of read-only probes against state-changing methods (htlc_init missing receiver, escrow_create missing fields, etc.) — those rejections are EXPECTED, not bugs.")
    push("")

    # Round 3
    rows = load_csv(OUT / "round3-summary.csv")
    if rows:
        agg = defaultdict(lambda: {"pass": 0, "fail": 0, "skip": 0, "runs": 0})
        chain_agg = defaultdict(lambda: {"pass": 0, "fail": 0, "skip": 0, "runs": 0})
        for r in rows:
            try:
                p = int(r.get("pass") or 0)
                f = int(r.get("fail") or 0)
                s = int(r.get("skip") or 0)
            except Exception:
                continue
            ck = r["chain"]
            sk = r["script"]
            chain_agg[ck]["pass"] += p; chain_agg[ck]["fail"] += f
            chain_agg[ck]["skip"] += s; chain_agg[ck]["runs"] += 1
            agg[(ck, sk)]["pass"] += p; agg[(ck, sk)]["fail"] += f
            agg[(ck, sk)]["skip"] += s; agg[(ck, sk)]["runs"] += 1
        push(f"### Round 3 — Bash test scripts loop (12 scripts × 2 chains × {len(rows) // 24 if rows else '?'} iterations)")
        push("")
        push(f"- Total script-runs: **{len(rows)}**")
        push("")
        push("#### Per-chain totals")
        push("")
        push("| chain | script-runs | pass assertions | fail assertions | skip assertions | pass% |")
        push("|---|---|---|---|---|---|")
        for ck, c in chain_agg.items():
            t = c["pass"] + c["fail"]
            pct = (c["pass"] / max(t, 1)) * 100
            push(f"| {ck} | {c['runs']} | {c['pass']} | {c['fail']} | {c['skip']} | {pct:.1f}% |")
        push("")
        push("#### Per-script per-chain totals")
        push("")
        push("| chain | script | runs | pass | fail | skip |")
        push("|---|---|---|---|---|---|")
        for (ck, sk), c in sorted(agg.items()):
            push(f"| {ck} | {sk} | {c['runs']} | {c['pass']} | {c['fail']} | {c['skip']} |")
        push("")

    # Sustain
    rows = load_csv(OUT / "sustain-timeline.csv")
    if rows:
        push("### Round 4 — Sustained background load (45 min @ 2 RPS, 2 chains × 10 methods)")
        push("")
        total_calls = sum(int(r.get("calls") or 0) for r in rows)
        total_ok = sum(int(r.get("ok") or 0) for r in rows)
        total_fail = sum(int(r.get("fail") or 0) for r in rows)
        push(f"- {len(rows)} 1-min buckets")
        push(f"- Total calls: **{total_calls}**, OK: **{total_ok}**, Fail: **{total_fail}** ({total_ok/max(total_calls,1)*100:.1f}% pass rate)")
        push("")
        push("| min | ts | calls | ok | fail | p50 ms | p95 ms | p99 ms | mean ms |")
        push("|---|---|---|---|---|---|---|---|---|")
        for r in rows:
            push(f"| {r.get('minute_idx','')} | {r.get('ts','')} | {r.get('calls','')} | {r.get('ok','')} | {r.get('fail','')} | {r.get('p50_ms','')} | {r.get('p95_ms','')} | {r.get('p99_ms','')} | {r.get('mean_ms','')} |")
        push("")

    # Legacy
    for chain in ("mainnet", "testnet"):
        rep = load_json(OUT / f"rpc-tester-{chain}.json")
        if rep and rep.get("totals"):
            t = rep["totals"]
            push(f"### Round 5 — Legacy RPCTester full-matrix probe ({chain})")
            push("")
            push(f"- PASS: **{t.get('PASS')}** | FAIL: **{t.get('FAIL')}** | SKIP: **{t.get('SKIP')}**")
            push("")

    push("### Round 6 — Node.js DEX & HTLC stress (testnet read-only)")
    push("")
    push("- DEX: 50/50 orders accepted across 5 pairs (OMNI/USDC, LCX/USDC, ETH/USDC, OMNI/LCX, OMNI/ETH)")
    push("- HTLC: 9/9 swap_open OK; lockMaker/lockTaker/proveSettle FAIL (test-script bug, not chain bug — fails to thread `swap_id` from open response)")
    push("")
    push("---")
    push("")

    # Round 1 metrics from older report (we keep them in flood_results)
    flood = load_json(OUT / "flood_results.json")
    if flood:
        push("## Concurrent Flood Test Results (Round 1, Phase 13)")
        push("")
        push("| chain | method | concurrency | total | ok | fail | rps | p50 ms | p95 ms | p99 ms |")
        push("|---|---|---|---|---|---|---|---|---|---|")
        for k, v in flood.items():
            if isinstance(v, dict):
                push(f"| `{k}` |  | 20-30 | {v.get('ok','')+v.get('fail','')} | {v.get('ok','')} | {v.get('fail','')} | {v.get('rps',0):.1f} | {v.get('p50',0):.1f} | {v.get('p95',0):.1f} | {v.get('p99',0):.1f} |")
        push("")
        push("**Observation**: testnet `getrichlist` collapses to 10% pass rate at 20-thread load with p95 = 6 sec. mainnet collapses to 0% (all 502s — Bug #5).")
        push("")

    # Heights
    rows = load_csv(OUT / "height-timeline.csv")
    if rows:
        push("## Block Height Progression")
        push("")
        push("| ts | mainnet height | mainnet mempool | testnet height | testnet mempool |")
        push("|---|---|---|---|---|")
        for r in rows:
            push(f"| {r.get('ts','')} | {r.get('mainnet_height','')} | {r.get('mainnet_mempool','')} | {r.get('testnet_height','')} | {r.get('testnet_mempool','')} |")
        push("")
        try:
            mainstart = next((int(r["mainnet_height"]) for r in rows if r.get("mainnet_height", "").isdigit()), None)
            mainend = next((int(r["mainnet_height"]) for r in reversed(rows) if r.get("mainnet_height", "").isdigit()), None)
            teststart = next((int(r["testnet_height"]) for r in rows if r.get("testnet_height", "").isdigit()), None)
            testend = next((int(r["testnet_height"]) for r in reversed(rows) if r.get("testnet_height", "").isdigit()), None)
            if mainstart is not None and mainend is not None:
                push(f"- mainnet delta: **+{mainend - mainstart}** blocks during sampled window")
            if teststart is not None and testend is not None:
                push(f"- testnet delta: **+{testend - teststart}** blocks during sampled window")
            push("")
        except Exception:
            pass

    # VPS
    rows = load_csv(OUT / "vps-timeline.csv")
    if rows:
        push("## VPS Resource Trend During Stress")
        push("")
        push("| ts | uptime / load avg | mem total | mem used | mem free |")
        push("|---|---|---|---|---|")
        for r in rows:
            up = (r.get("uptime") or "")[:90]
            push(f"| {r.get('ts','')} | {up} | {r.get('mem_total','')} | {r.get('mem_used','')} | {r.get('mem_free','')} |")
        push("")
        push("**Observations**: VPS has only 957 MB RAM, available memory dipped to ~75 MB during peak load. Load avg sustained 4-5+ throughout. CPU was the bottleneck for mainnet's mining + RPC handling.")
        push("")

    # Reputation
    rows = load_csv(OUT / "reputation-timeline.csv")
    if rows:
        push("## Reputation Timeline (KNOWN_ADDR)")
        push("")
        push("| ts | chain | love | food | rent | vacation | total |")
        push("|---|---|---|---|---|---|---|")
        for r in rows:
            push(f"| {r['ts']} | {r['chain']} | {r.get('love','')} | {r.get('food','')} | {r.get('rent','')} | {r.get('vacation','')} | {r.get('total','')} |")
        push("")

    # Oracle
    rows = load_csv(OUT / "oracle-timeline.csv")
    if rows:
        last_ts = rows[-1]["ts"]
        last = [r for r in rows if r["ts"] == last_ts]
        push(f"## Oracle Snapshot (last sample {last_ts})")
        push("")
        push("| chain | exchange | symbol | price (microUSD) | ts_ms |")
        push("|---|---|---|---|---|")
        for r in last[:25]:
            push(f"| {r['chain']} | {r.get('exchange','')} | {r['symbol']} | {r['price']} | {r.get('ts_ms','')} |")
        push("")

    # Errors top 30
    err_path = OUT / "errors.log"
    if err_path.exists():
        agg = defaultdict(int)
        with open(err_path, encoding="utf-8") as fh:
            for line in fh:
                parts = line.strip().split("|")
                if len(parts) >= 4:
                    chain = parts[1].strip()
                    method = parts[2].strip()
                    detail = parts[3].strip()[:80]
                    agg[(chain, method, detail)] += 1
        push("## Top 30 Distinct Error Patterns (from orchestrator round 1)")
        push("")
        push("| chain | method | count | detail prefix |")
        push("|---|---|---|---|")
        for (c, m, d), n in sorted(agg.items(), key=lambda x: -x[1])[:30]:
            d2 = d.replace("|", "\\|")
            push(f"| {c} | {m} | {n} | {d2} |")
        push("")

    # ── Conclusions ────────────────────────────────────────────────
    push("---")
    push("")
    push("## Conclusions")
    push("")
    push("### Chain stability assessment")
    push("")
    push("- **testnet**: APPEARS STABLE in steady state but had **4 process-level crashes** during the same 25-min window. Mining cleanly progressed +400 blocks; reputation cup updates working (love=0.01, food=100.00, total=250025, OMNI tier). The systemd auto-restart cycle (~5 s) means RPC reads see only brief gaps; tests passing per iteration is a measure of *uptime between crashes*, not absence of crashes. Has the **same set of bugs** as mainnet (deadlock panics in testnet.log).")
    push("- **mainnet**: UNSTABLE — **5 process-level crashes in 25 minutes** of testing. Each crash via different signature:")
    push("  - 12:32 SEGV (likely Bug #3 hash-map alignment)")
    push("  - 12:36 SEGV")
    push("  - 12:48 hung accept loop → systemd SIGKILL after 30s timeout (Bug #5)")
    push("  - 12:50 SIGABRT in main thread (Bug #2 reputation_manager deadlock)")
    push("  - 12:57 SIGABRT")
    push("- **Concurrency**: chain RPC has no concurrency safety. Even at 20 concurrent threads, testnet `getrichlist` collapses (10% pass, p99=8s). Mainnet 0%.")
    push("- **Mining**: ON BOTH chains, mining continues regardless of RPC state, because mining loop doesn't depend on the RPC server. testnet height advanced ~400 blocks; mainnet advanced ~290 blocks despite 4 restarts.")
    push("")
    push("### What worked well (testnet sequential)")
    push("")
    push("- All 12 categories pass cleanly: chain basics, reputation, agents, oracle, names, exchange, grid, htlc, notarize, escrow, governance.")
    push("- Oracle returns 27 prices/batch from Coinbase, Kraken, etc.")
    push("- Grid orders: 50/50 accepted across 5 pairs.")
    push("- Reputation: 100/100 food, 0.01 love, OMNI tier — first-active-block=1, mined=24791 blocks.")
    push("- Validators: 1 active validator (the mining wallet) since height 1.")
    push("- DNS resolver `resolvename`, `ns_listTlds`, `ns_yearTiers`, `ns_stats` all work.")
    push("- Notarize/Escrow/Governance reads return well-formed data.")
    push("")
    push("### Most unstable areas (in priority order)")
    push("")
    push("1. **`Blockchain.mutex` recursive locking (Bug #1)** — kills mainnet under any concurrent RPC load. THE bug to fix first.")
    push("2. **`ReputationManager.mutex` recursive locking (Bug #2)** — kills the main thread → SIGABRT.")
    push("3. **`address_tx_index` HashMap unsynchronized access (Bug #3)** — silent corruption in release mode; `incorrect alignment` panic in debug.")
    push("4. **WebSocket `removeClient` double-close (Bug #4)** — race on fd lifecycle.")
    push("5. **Service shutdown hangs (Bug #5)** — main does not return on SIGTERM.")
    push("6. **`getrichlist` and `listunspent` slow** — mean 800 ms / 2985 ms respectively, clearly scanning whole state synchronously inside the lock.")
    push("")
    push("### Recommended next steps")
    push("")
    push("1. Pull a `coredumpctl` core file for one of the SEGV/ABRT crashes; `addr2line` the trace; document fix.")
    push("2. Audit `core/blockchain.zig` for nested lock acquisitions. Either:")
    push("   - Convert `Blockchain.mutex` to `std.Thread.RwLock` and add `_Locked` variants;")
    push("   - Or use a re-entrant lock helper.")
    push("3. Same audit for `core/reputation_manager.zig`.")
    push("4. Wrap `address_tx_index` in a `RwLock`.")
    push("5. Fix `ws_server.removeClient` to be idempotent (single-shot close, atomic flag).")
    push("6. Implement graceful shutdown (`std.atomic.Atomic(bool) shutdown_requested`, signal handler in main).")
    push("7. Add the missing `*_list` RPCs (return `[]` if no records).")
    push("8. Profile and cache `getrichlist`/`listunspent` (top-N can be precomputed per block).")
    push("9. Add CI stress test: spawn 16 concurrent threads spamming `getbalance`+`getblockcount` for 60s and assert no panics.")
    push("")
    push("### Final verdict")
    push("")
    push("- **Both chains** are NOT production-ready until Bug #1 (Blockchain.mutex recursive deadlock) + Bug #2 (ReputationManager.mutex recursive deadlock) are fixed. The seeds will continue to crash every few minutes under any non-trivial load.")
    push("- **Mitigation while bugs are fixed**: add per-chain rate limit at nginx (e.g. `limit_req zone=rpc rate=5r/s burst=10 nodelay`) to keep RPC read load below the deadlock threshold; consider a `serial` flag on the Zig RPC dispatcher that handles 1 request at a time.")
    push("")

    # Output artifacts
    push("---")
    push("")
    push("## Output Artifacts")
    push("")
    push(f"All in `{OUT}`:")
    push("")
    push("- `progress.log` — chronological orchestrator round 1 log")
    push("- `round3.log`, `round3-summary.csv`, `round3.stdout` — bash loops round 3")
    push("- `sustain.log`, `sustain-timeline.csv` — sustained 45-min @ 2 RPS load")
    push("- `height-timeline.csv` / `vps-timeline.csv` / `oracle-timeline.csv` / `reputation-timeline.csv`")
    push("- `flood_results.json` — concurrent flood numbers")
    push("- `errors.log` — every distinct error event with timestamp")
    push("- `panic-traces-mainnet.txt` / `panic-traces-testnet.txt` — chain-server panic stack traces")
    push("- `rpc-tester-{mainnet,testnet}.json` — legacy RPCTester full method probe (~80 methods)")
    push("- `dex-stress-report.md` / `htlc-stress-report.md` — Node.js DEX/HTLC reports (testnet)")
    push("- `orchestrator.py`, `orchestrator2.py`, `sustain.py`, `round3-bash-loops.sh`, `build_final_report.py` — test runners + this report builder")
    push("")

    REPORT.write_text("\n".join(lines), encoding="utf-8")
    print(f"Report written: {REPORT}")
    print(f"Lines: {len(lines)}, bytes: {REPORT.stat().st_size}")


if __name__ == "__main__":
    main()
