#!/usr/bin/env python3
"""Master stress orchestrator for OmniBus chain core (mainnet + testnet).

Runs the documented stress plan, captures latency/status per RPC,
polls VPS resources, and emits progress.log + final report.
"""
from __future__ import annotations

import csv
import json
import os
import statistics
import subprocess
import sys
import threading
import time
import urllib.request
import urllib.error
import ssl
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timezone
from pathlib import Path

OUT_DIR = Path(r"c:/Kits work/limaje de programare/1_CORE/BlockChainCore/stress-output")
OUT_DIR.mkdir(parents=True, exist_ok=True)
PROGRESS = OUT_DIR / "progress.log"
LATENCY_CSV = OUT_DIR / "latency.csv"
REPUTATION_CSV = OUT_DIR / "reputation-timeline.csv"
ORACLE_CSV = OUT_DIR / "oracle-timeline.csv"
VPS_CSV = OUT_DIR / "vps-timeline.csv"
HEIGHT_CSV = OUT_DIR / "height-timeline.csv"
ERRORS_LOG = OUT_DIR / "errors.log"

ENDPOINTS = {
    "mainnet": "https://omnibusblockchain.cc:8443/api-mainnet",
    "testnet": "https://omnibusblockchain.cc:8443/api-testnet",
}
KNOWN_ADDR = "ob1qw6zhsqg29aht23fksk5w54lkgavatpgltqxlvl"
TREASURY_ADDR = "ob1qzhrauq0xe9hg033ccup7vlgsdmj6kcxyza9zp0"
KNOWN_NAME = "savacazan.omnibus"
KNOWN_FOREIGN = "0x000000000000000000000000000000000000dEaD"
ZERO_HASH = "0" * 64

SSL_CTX = ssl.create_default_context()

# Per-method aggregated latency and status counts
metrics_lock = threading.Lock()
metrics: dict[str, dict] = {}
errors: list[dict] = []
crashes: list[dict] = []


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def log(msg: str) -> None:
    line = f"[{now_iso()}] {msg}"
    print(line, flush=True)
    with open(PROGRESS, "a", encoding="utf-8") as fh:
        fh.write(line + "\n")


def record(method: str, chain: str, status: str, latency_ms: float, detail: str = "") -> None:
    key = f"{chain}::{method}"
    with metrics_lock:
        m = metrics.setdefault(key, {"chain": chain, "method": method,
                                     "pass": 0, "fail": 0, "skip": 0,
                                     "latencies": [], "calls": 0,
                                     "first_error": ""})
        m["calls"] += 1
        m["latencies"].append(latency_ms)
        if status == "PASS":
            m["pass"] += 1
        elif status == "FAIL":
            m["fail"] += 1
            if not m["first_error"]:
                m["first_error"] = detail[:200]
            errors.append({"ts": now_iso(), "chain": chain,
                           "method": method, "detail": detail[:300]})
        elif status == "SKIP":
            m["skip"] += 1


def call_rpc(chain: str, method: str, params=None, timeout: float = 10.0):
    url = ENDPOINTS[chain]
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method,
                       "params": params or []}).encode()
    headers = {"Content-Type": "application/json"}
    t0 = time.time()
    try:
        req = urllib.request.Request(url, data=body, headers=headers)
        with urllib.request.urlopen(req, timeout=timeout, context=SSL_CTX) as resp:
            raw = resp.read().decode("utf-8", errors="replace")
        latency = (time.time() - t0) * 1000
        try:
            data = json.loads(raw)
        except json.JSONDecodeError:
            record(method, chain, "FAIL", latency, f"non-json: {raw[:120]}")
            return None, latency, "FAIL"
        err = data.get("error") if isinstance(data, dict) else None
        if err:
            msg = err.get("message", json.dumps(err)) if isinstance(err, dict) else str(err)
            low = msg.lower()
            if any(k in low for k in ("method not found", "unknown method", "not implemented")):
                record(method, chain, "SKIP", latency, msg[:120])
                return None, latency, "SKIP"
            record(method, chain, "FAIL", latency, msg[:200])
            return None, latency, "FAIL"
        if "result" not in data:
            record(method, chain, "FAIL", latency, "no result field")
            return None, latency, "FAIL"
        record(method, chain, "PASS", latency)
        return data["result"], latency, "PASS"
    except urllib.error.HTTPError as e:
        latency = (time.time() - t0) * 1000
        try:
            raw = e.read().decode("utf-8", errors="replace")
        except Exception:
            raw = ""
        record(method, chain, "FAIL", latency, f"http_{e.code}: {raw[:120]}")
        return None, latency, "FAIL"
    except Exception as e:
        latency = (time.time() - t0) * 1000
        record(method, chain, "FAIL", latency, f"transport: {str(e)[:200]}")
        return None, latency, "FAIL"


# ── Run definitions ─────────────────────────────────────────────────────────

CHAIN_BASIC = [
    ("getblockcount", []),
    ("getblockchaininfo", []),
    ("getbestblockhash", []),
    ("getbalance", [TREASURY_ADDR]),
    ("getbalance", [KNOWN_ADDR]),
    ("getrichlist", [10]),
    ("getperformance", []),
    ("getsyncstatus", []),
    ("getpeers", []),
    ("getpeerinfo", []),
    ("getnetworkinfo", []),
    ("getmempoolinfo", []),
    ("getrawmempool", []),
    ("listunspent", [{"address": KNOWN_ADDR}]),
    ("getnonce", [KNOWN_ADDR]),
]

REPUTATION = [
    ("getreputation", [KNOWN_ADDR]),
    ("getreputation", [TREASURY_ADDR]),
    ("getreputationtop", []),
]

STAKE = [
    ("getstake", [KNOWN_ADDR]),
    ("getstake", [TREASURY_ADDR]),
    ("getstakers", []),
    ("getvalidators", []),
    ("getvalidatorsv2", []),
    ("getslashevents", []),
]

AGENTS = [
    ("getagents", []),
    ("agent_list", []),
    ("getagent", [{"address": KNOWN_ADDR}]),
    ("getagent", [{"id": 0}]),
    ("agent_pending_decisions", []),
]

NAMES = [
    ("resolvename", [KNOWN_NAME]),
    ("reverseresolvename", [KNOWN_ADDR]),
    ("ns_listTlds", []),
    ("ns_yearTiers", []),
    ("ns_stats", []),
    ("ns_getensfee", [{"tld": "omnibus"}]),
    ("ns_getNamesByCategory", [{"category": "omnibus"}]),
    ("ns_expiringSoon", [{"within_blocks": 100000}]),
]

EXCHANGE = [
    ("exchange_listPairs", []),
    ("exchange_pairInfo", [{"pair_id": 0}]),
    ("exchange_pairInfo", [{"pair_id": 2}]),
    ("exchange_pairInfo", [{"pair_id": 3}]),
    ("exchange_pairInfo", [{"pair_id": 5}]),
    ("exchange_pairInfo", [{"pair_id": 6}]),
    ("exchange_listOrders", [{"pair_id": 0}]),
    ("exchange_listOrders", [{"pair_id": 2}]),
    ("exchange_listOrders", [{"pair_id": 3}]),
    ("exchange_listOrders", [{"pair_id": 5}]),
    ("exchange_listOrders", [{"pair_id": 6}]),
    ("exchange_getRecentTrades", [{"pair_id": 0, "limit": 10}]),
    ("exchange_getRecentTrades", [{"pair_id": 2, "limit": 10}]),
    ("exchange_getRecentTrades", [{"pair_id": 3, "limit": 10}]),
    ("exchange_getUserOrders", [{"trader": KNOWN_ADDR}]),
]

GRID = [
    ("grid_list", [{"owner": KNOWN_ADDR}]),
    ("grid_list", [{}]),
    ("grid_status", [{"grid_id": 0}]),
]

HTLC = [
    ("htlc_get", [{"htlc_id": 0}]),
    ("swap_get", [{"swap_id": 0}]),
    ("swap_list", []),
    ("htlc_list", []),
    ("bridge_list", []),
]

ORACLE = [
    ("omnibus_getexchangefeed", []),
    ("omnibus_getallprices", []),
    ("omnibus_getarbitrage", []),
    ("omnibus_getoracleprices", []),
    ("omnibus_getoraclepolicy", []),
]

NOTARIZE = [
    ("verifynotarize", [{"hash": ZERO_HASH}]),
    ("getnotarizations", [{"owner": KNOWN_ADDR}]),
    ("getsubscriptions", [{"address": KNOWN_ADDR}]),
]

ESCROW = [
    ("getescrow", [{"escrow_id": 0}]),
    ("getescrows", [{"address": KNOWN_ADDR}]),
    ("getchannels", [{"address": KNOWN_ADDR}]),
]

GOVERNANCE = [
    ("getproposals", []),
    ("getproposal", [{"proposal_id": 0}]),
    ("getvotes", [{"proposal_id": 0}]),
    ("governance_list", []),
]


def run_batch(name: str, items: list, chains: list[str], reps: int = 1, label: str = "") -> dict:
    label = label or name
    counts = {"PASS": 0, "FAIL": 0, "SKIP": 0, "calls": 0}
    t0 = time.time()
    for _ in range(reps):
        for chain in chains:
            for method, params in items:
                _, _, status = call_rpc(chain, method, params, timeout=8.0)
                counts[status] = counts.get(status, 0) + 1
                counts["calls"] += 1
    dur = time.time() - t0
    log(f"  [{label}] reps={reps} chains={chains} -> calls={counts['calls']} pass={counts['PASS']} fail={counts['FAIL']} skip={counts['SKIP']} ({dur:.1f}s)")
    return counts


def snapshot_heights() -> dict:
    out = {}
    for chain in ENDPOINTS:
        r, _, _ = call_rpc(chain, "getblockcount", [])
        mp, _, _ = call_rpc(chain, "getmempoolinfo", [])
        mp_size = ""
        if isinstance(mp, dict):
            mp_size = mp.get("size", mp.get("count", ""))
        out[chain] = {"height": r, "mempool": mp_size}
    return out


def append_csv(path: Path, header: list[str], row: list) -> None:
    new = not path.exists()
    with open(path, "a", newline="", encoding="utf-8") as fh:
        w = csv.writer(fh)
        if new:
            w.writerow(header)
        w.writerow(row)


def poll_vps_metrics() -> dict:
    """Use SSH to grab VPS load, RAM, log tail. Returns dict; on failure, empty."""
    out = {}
    try:
        r = subprocess.run(
            ["ssh", "-o", "ConnectTimeout=8", "-o", "BatchMode=yes",
             "omnibus-vps", "uptime; echo '---FREE---'; free -m | head -3; "
             "echo '---PANIC---'; tail -200 /var/log/omnibus/mainnet.log 2>/dev/null | "
             "grep -iE 'panic|abort|segv|fatal' | tail -5; "
             "echo '---PANIC-T---'; tail -200 /var/log/omnibus/testnet.log 2>/dev/null | "
             "grep -iE 'panic|abort|segv|fatal' | tail -5"],
            capture_output=True, text=True, timeout=20)
        out["raw"] = r.stdout
        out["err"] = r.stderr
        # parse
        text = r.stdout
        for ln in text.splitlines():
            if "load average" in ln:
                out["uptime"] = ln.strip()
            if ln.startswith("Mem:"):
                parts = ln.split()
                if len(parts) >= 4:
                    out["mem_total"] = parts[1]
                    out["mem_used"] = parts[2]
                    out["mem_free"] = parts[3]
        # check for panic
        if "panic" in text.lower() or "segv" in text.lower() or "abort" in text.lower():
            for ln in text.splitlines():
                low = ln.lower()
                if any(k in low for k in ("panic", "segv", "abort", "fatal")) and "PANIC" not in ln:
                    crashes.append({"ts": now_iso(), "line": ln.strip()})
    except Exception as e:
        out["err"] = str(e)
    return out


# ── Run drivers ─────────────────────────────────────────────────────────────

def stress_concurrent(method: str, chain: str, total: int, concurrency: int) -> dict:
    """Concurrent flood of getblockcount-like read."""
    log(f"  flood {method} on {chain}: {total} reqs x {concurrency} threads")
    ok = 0
    fail = 0
    latencies = []
    t0 = time.time()
    def worker():
        _, lat, st = call_rpc(chain, method, [], timeout=8.0)
        return st, lat
    with ThreadPoolExecutor(max_workers=concurrency) as ex:
        futs = [ex.submit(worker) for _ in range(total)]
        for f in as_completed(futs):
            st, lat = f.result()
            latencies.append(lat)
            if st == "PASS":
                ok += 1
            else:
                fail += 1
    dur = time.time() - t0
    p50 = statistics.median(latencies) if latencies else 0
    p95 = sorted(latencies)[int(len(latencies)*0.95)] if latencies else 0
    p99 = sorted(latencies)[int(len(latencies)*0.99)] if latencies else 0
    rps = total / max(dur, 0.001)
    log(f"  flood done: ok={ok} fail={fail} rps={rps:.1f} p50={p50:.1f}ms p95={p95:.1f}ms p99={p99:.1f}ms")
    return {"ok": ok, "fail": fail, "rps": rps, "p50": p50, "p95": p95, "p99": p99}


def reputation_snapshot() -> None:
    for chain in ENDPOINTS:
        r, _, _ = call_rpc(chain, "getreputation", [KNOWN_ADDR])
        cups = {}
        if isinstance(r, dict):
            c = r.get("cups", r)
            if isinstance(c, dict):
                cups = c
            else:
                cups = r
        love = cups.get("love", "") if isinstance(cups, dict) else ""
        food = cups.get("food", "") if isinstance(cups, dict) else ""
        rent = cups.get("rent", "") if isinstance(cups, dict) else ""
        vac = cups.get("vacation", "") if isinstance(cups, dict) else ""
        total = ""
        if isinstance(r, dict):
            total = r.get("reputation", r.get("total", ""))
        append_csv(REPUTATION_CSV,
                   ["ts", "chain", "address", "love", "food", "rent", "vacation", "total"],
                   [now_iso(), chain, KNOWN_ADDR, love, food, rent, vac, total])


def oracle_snapshot() -> None:
    for chain in ENDPOINTS:
        prices, _, _ = call_rpc(chain, "omnibus_getoracleprices", [])
        ts = now_iso()
        if isinstance(prices, dict):
            for sym, p in prices.items():
                if isinstance(p, dict):
                    pr = p.get("price", "")
                    age = p.get("timestamp_ms", p.get("ts_ms", ""))
                    append_csv(ORACLE_CSV,
                               ["ts", "chain", "symbol", "price", "ts_ms"],
                               [ts, chain, sym, pr, age])
                else:
                    append_csv(ORACLE_CSV,
                               ["ts", "chain", "symbol", "price", "ts_ms"],
                               [ts, chain, sym, p, ""])
        elif isinstance(prices, list):
            for p in prices:
                if isinstance(p, dict):
                    sym = p.get("symbol", p.get("pair", ""))
                    pr = p.get("price", "")
                    age = p.get("timestamp_ms", p.get("ts_ms", ""))
                    append_csv(ORACLE_CSV,
                               ["ts", "chain", "symbol", "price", "ts_ms"],
                               [ts, chain, sym, pr, age])


def height_snapshot() -> None:
    snap = snapshot_heights()
    append_csv(HEIGHT_CSV,
               ["ts", "mainnet_height", "mainnet_mempool",
                "testnet_height", "testnet_mempool"],
               [now_iso(),
                snap["mainnet"]["height"], snap["mainnet"]["mempool"],
                snap["testnet"]["height"], snap["testnet"]["mempool"]])


def vps_snapshot() -> None:
    v = poll_vps_metrics()
    append_csv(VPS_CSV,
               ["ts", "uptime", "mem_total", "mem_used", "mem_free", "raw_len"],
               [now_iso(), v.get("uptime", ""), v.get("mem_total", ""),
                v.get("mem_used", ""), v.get("mem_free", ""), len(v.get("raw", ""))])


# ── Main run plan ───────────────────────────────────────────────────────────

def run_plan() -> None:
    log("=== STRESS TEST START ===")
    log(f"Output dir: {OUT_DIR}")

    # Baseline
    log("--- Baseline snapshot ---")
    height_snapshot()
    vps_snapshot()
    reputation_snapshot()
    oracle_snapshot()

    chains = ["mainnet", "testnet"]

    # Run 1: Chain basics (10x)
    log("--- Run 1: Chain basics x10 ---")
    run_batch("chain-basic", CHAIN_BASIC, chains, reps=10, label="01-chain")

    height_snapshot(); reputation_snapshot()

    # Run 2: Reputation (20x with 30s sampling)
    log("--- Run 2: Reputation x20 ---")
    run_batch("reputation", REPUTATION, chains, reps=20, label="02-reputation")
    reputation_snapshot()

    # Run 3: Stake/Validators x10
    log("--- Run 3: Stake/Validators x10 ---")
    run_batch("stake", STAKE, chains, reps=10, label="03-stake")

    height_snapshot()

    # Run 4: Agents x10
    log("--- Run 4: Agents x10 ---")
    run_batch("agents", AGENTS, chains, reps=10, label="04-agents")

    # Run 5: Names x10
    log("--- Run 5: Names x10 ---")
    run_batch("names", NAMES, chains, reps=10, label="05-names")

    height_snapshot(); vps_snapshot()

    # Run 6: Exchange/DEX x10
    log("--- Run 6: Exchange x10 ---")
    run_batch("exchange", EXCHANGE, chains, reps=10, label="06-exchange")

    # Run 7: Grid x10
    log("--- Run 7: Grid x10 ---")
    run_batch("grid", GRID, chains, reps=10, label="07-grid")

    # Run 8: HTLC x10
    log("--- Run 8: HTLC x10 ---")
    run_batch("htlc", HTLC, chains, reps=10, label="08-htlc")

    height_snapshot(); reputation_snapshot()

    # Run 9: Oracle x20 + timeline
    log("--- Run 9: Oracle x20 ---")
    for i in range(10):
        run_batch("oracle", ORACLE, chains, reps=2, label=f"09-oracle-{i+1}/10")
        oracle_snapshot()

    # Run 10: Notarize/Sub x5
    log("--- Run 10: Notarize/Sub x5 ---")
    run_batch("notarize", NOTARIZE, chains, reps=5, label="10-notarize")

    # Run 11: Escrow/Channels x5
    log("--- Run 11: Escrow/Channels x5 ---")
    run_batch("escrow", ESCROW, chains, reps=5, label="11-escrow")

    # Run 12: Governance x5
    log("--- Run 12: Governance x5 ---")
    run_batch("governance", GOVERNANCE, chains, reps=5, label="12-governance")

    height_snapshot(); vps_snapshot()

    # Run 13: Heavy concurrent read flood (replaces tx-flood read-only)
    log("--- Run 13: Concurrent flood ---")
    flood_results = {}
    for chain in chains:
        flood_results[f"{chain}_blockcount"] = stress_concurrent(
            "getblockcount", chain, 500, 30)
        flood_results[f"{chain}_richlist"] = stress_concurrent(
            "getrichlist", chain, 200, 20)
        flood_results[f"{chain}_oracle"] = stress_concurrent(
            "omnibus_getoracleprices", chain, 200, 20)
    with open(OUT_DIR / "flood_results.json", "w", encoding="utf-8") as fh:
        json.dump(flood_results, fh, indent=2)

    height_snapshot(); vps_snapshot()

    # Run 14: Full method matrix (one pass each chain) — many "fail" expected
    # because many state-changing methods reject without signed input. Track them.
    log("--- Run 14: Full method matrix probe ---")
    full_methods = (CHAIN_BASIC + REPUTATION + STAKE + AGENTS + NAMES +
                    EXCHANGE + GRID + HTLC + ORACLE + NOTARIZE + ESCROW +
                    GOVERNANCE)
    run_batch("full-matrix", full_methods, chains, reps=2, label="14-full-matrix")

    # Run 15: Final snapshots
    log("--- Run 15: Final snapshots ---")
    reputation_snapshot()
    oracle_snapshot()
    height_snapshot()
    vps_snapshot()

    log("=== STRESS TEST END ===")


def write_report() -> None:
    log("--- Writing report ---")
    today = datetime.now().strftime("%Y%m%d")
    report_path = OUT_DIR.parent / f"STRESS_TEST_REPORT_{today}.md"

    # Aggregate
    total_calls = sum(m["calls"] for m in metrics.values())
    total_pass = sum(m["pass"] for m in metrics.values())
    total_fail = sum(m["fail"] for m in metrics.values())
    total_skip = sum(m["skip"] for m in metrics.values())

    # Heights
    heights = []
    if HEIGHT_CSV.exists():
        with open(HEIGHT_CSV, encoding="utf-8") as fh:
            r = csv.DictReader(fh)
            heights = list(r)

    # Top slowest by mean latency (calls > 5)
    method_stats = []
    for key, m in metrics.items():
        if m["calls"] >= 3:
            lats = m["latencies"]
            mean = statistics.mean(lats)
            med = statistics.median(lats)
            mx = max(lats)
            method_stats.append({
                "key": key, "chain": m["chain"], "method": m["method"],
                "calls": m["calls"], "pass": m["pass"], "fail": m["fail"],
                "skip": m["skip"], "mean_ms": mean, "med_ms": med,
                "max_ms": mx, "first_error": m["first_error"],
            })
    method_stats.sort(key=lambda x: x["mean_ms"], reverse=True)

    # Group by category for pass/fail breakdown
    cat_map = {
        "Chain Basic": [m[0] for m in CHAIN_BASIC],
        "Reputation": [m[0] for m in REPUTATION],
        "Stake/Validators": [m[0] for m in STAKE],
        "Agents": [m[0] for m in AGENTS],
        "Names": [m[0] for m in NAMES],
        "Exchange/DEX": [m[0] for m in EXCHANGE],
        "Grid": [m[0] for m in GRID],
        "HTLC": [m[0] for m in HTLC],
        "Oracle": [m[0] for m in ORACLE],
        "Notarize/Sub": [m[0] for m in NOTARIZE],
        "Escrow/Channels": [m[0] for m in ESCROW],
        "Governance": [m[0] for m in GOVERNANCE],
    }
    cat_results = {}
    for cat, names in cat_map.items():
        cat_results[cat] = {"pass": 0, "fail": 0, "skip": 0, "calls": 0}
        for m in metrics.values():
            if m["method"] in names:
                cat_results[cat]["pass"] += m["pass"]
                cat_results[cat]["fail"] += m["fail"]
                cat_results[cat]["skip"] += m["skip"]
                cat_results[cat]["calls"] += m["calls"]

    # Errors grouped
    err_by_method = {}
    for e in errors:
        k = f"{e['chain']}::{e['method']}"
        err_by_method.setdefault(k, []).append(e["detail"])

    lines = []
    lines.append(f"# OmniBus Chain Core Stress Test Report — {today}")
    lines.append("")
    lines.append(f"- Generated: {now_iso()}")
    lines.append(f"- Endpoints: mainnet={ENDPOINTS['mainnet']}, testnet={ENDPOINTS['testnet']}")
    lines.append(f"- Total RPC calls: **{total_calls}**")
    lines.append(f"- Pass: **{total_pass}** ({total_pass/max(total_calls,1)*100:.1f}%)")
    lines.append(f"- Fail: **{total_fail}** ({total_fail/max(total_calls,1)*100:.1f}%)")
    lines.append(f"- Skip: **{total_skip}** ({total_skip/max(total_calls,1)*100:.1f}%)")
    lines.append("")

    # Heights
    lines.append("## Block Height Progression")
    lines.append("")
    if heights:
        first = heights[0]
        last = heights[-1]
        lines.append(f"| chain | start height | end height | delta | mempool start | mempool end |")
        lines.append(f"|---|---|---|---|---|---|")
        for c in ("mainnet", "testnet"):
            try:
                start_h = int(first.get(f"{c}_height") or 0)
                end_h = int(last.get(f"{c}_height") or 0)
                delta = end_h - start_h
                lines.append(f"| {c} | {start_h} | {end_h} | +{delta} | {first.get(f'{c}_mempool','')} | {last.get(f'{c}_mempool','')} |")
            except Exception:
                pass
    lines.append("")

    # Per-category results
    lines.append("## Pass/Fail/Skip per Category")
    lines.append("")
    lines.append("| category | calls | pass | fail | skip | pass% |")
    lines.append("|---|---|---|---|---|---|")
    for cat, c in cat_results.items():
        pct = (c["pass"] / max(c["calls"], 1)) * 100
        lines.append(f"| {cat} | {c['calls']} | {c['pass']} | {c['fail']} | {c['skip']} | {pct:.1f}% |")
    lines.append("")

    # Top slow
    lines.append("## Top 10 Slowest RPCs (mean latency)")
    lines.append("")
    lines.append("| chain | method | calls | mean ms | median ms | max ms | pass | fail |")
    lines.append("|---|---|---|---|---|---|---|---|")
    for m in method_stats[:15]:
        lines.append(f"| {m['chain']} | {m['method']} | {m['calls']} | "
                     f"{m['mean_ms']:.1f} | {m['med_ms']:.1f} | {m['max_ms']:.1f} | "
                     f"{m['pass']} | {m['fail']} |")
    lines.append("")

    # Top fast (sanity)
    method_stats_asc = sorted(method_stats, key=lambda x: x["mean_ms"])
    lines.append("## Top 10 Fastest RPCs")
    lines.append("")
    lines.append("| chain | method | calls | mean ms | median ms |")
    lines.append("|---|---|---|---|---|")
    for m in method_stats_asc[:10]:
        lines.append(f"| {m['chain']} | {m['method']} | {m['calls']} | "
                     f"{m['mean_ms']:.1f} | {m['med_ms']:.1f} |")
    lines.append("")

    # Errors
    lines.append("## Errors Found")
    lines.append("")
    if not err_by_method:
        lines.append("*No RPC errors recorded.*")
    else:
        lines.append(f"Total error events: **{len(errors)}** across **{len(err_by_method)}** distinct method/chain pairs.")
        lines.append("")
        lines.append("| chain | method | count | first error |")
        lines.append("|---|---|---|---|")
        for k, v in sorted(err_by_method.items(), key=lambda x: -len(x[1]))[:30]:
            chain, method = k.split("::", 1)
            sample = v[0].replace("|", "\\|").replace("\n", " ")[:120]
            lines.append(f"| {chain} | {method} | {len(v)} | {sample} |")
    lines.append("")

    # Crashes
    lines.append("## Crashes / Panics Detected on VPS")
    lines.append("")
    if not crashes:
        lines.append("*No panic/SIGABRT/SEGV/fatal lines detected during polling window in /var/log/omnibus/*.log*")
    else:
        lines.append(f"Detected {len(crashes)} concerning log lines:")
        lines.append("```")
        for c in crashes[:30]:
            lines.append(f"{c['ts']} :: {c['line']}")
        lines.append("```")
    lines.append("")

    # Flood
    flood_path = OUT_DIR / "flood_results.json"
    if flood_path.exists():
        with open(flood_path, encoding="utf-8") as fh:
            flood = json.load(fh)
        lines.append("## Flood Test Results (concurrent read load)")
        lines.append("")
        lines.append("| run | ok | fail | rps | p50 ms | p95 ms | p99 ms |")
        lines.append("|---|---|---|---|---|---|---|")
        for k, v in flood.items():
            lines.append(f"| {k} | {v['ok']} | {v['fail']} | {v['rps']:.1f} | {v['p50']:.1f} | {v['p95']:.1f} | {v['p99']:.1f} |")
        lines.append("")

    # VPS resource trend
    if VPS_CSV.exists():
        with open(VPS_CSV, encoding="utf-8") as fh:
            rows = list(csv.DictReader(fh))
        if rows:
            lines.append("## VPS Resource Trend")
            lines.append("")
            lines.append("| ts | uptime/load | mem total | mem used | mem free |")
            lines.append("|---|---|---|---|---|")
            for r in rows:
                up = (r.get("uptime") or "")[-80:]
                lines.append(f"| {r['ts']} | {up} | {r.get('mem_total','')} | {r.get('mem_used','')} | {r.get('mem_free','')} |")
            lines.append("")

    # Oracle freshness
    if ORACLE_CSV.exists():
        with open(ORACLE_CSV, encoding="utf-8") as fh:
            rows = list(csv.DictReader(fh))
        if rows:
            lines.append("## Oracle Freshness Snapshot (last sample)")
            lines.append("")
            lines.append("| ts | chain | symbol | price | ts_ms |")
            lines.append("|---|---|---|---|---|")
            # Last batch
            last_ts = rows[-1]["ts"]
            for r in rows:
                if r["ts"] == last_ts:
                    lines.append(f"| {r['ts']} | {r['chain']} | {r['symbol']} | {r['price']} | {r['ts_ms']} |")
            lines.append("")

    # Reputation timeline
    if REPUTATION_CSV.exists():
        with open(REPUTATION_CSV, encoding="utf-8") as fh:
            rows = list(csv.DictReader(fh))
        if rows:
            lines.append("## Reputation Timeline (KNOWN_ADDR)")
            lines.append("")
            lines.append("| ts | chain | love | food | rent | vacation | total |")
            lines.append("|---|---|---|---|---|---|---|")
            for r in rows:
                lines.append(f"| {r['ts']} | {r['chain']} | {r.get('love','')} | {r.get('food','')} | {r.get('rent','')} | {r.get('vacation','')} | {r.get('total','')} |")
            lines.append("")

    # Conclusions
    fail_rate = total_fail / max(total_calls, 1) * 100
    lines.append("## Conclusions")
    lines.append("")
    stable = "stable" if fail_rate < 5 and not crashes else "unstable"
    lines.append(f"- Chain stability: **{stable}** "
                 f"({fail_rate:.1f}% RPC fail rate, {len(crashes)} crash lines)")
    if heights and len(heights) >= 2:
        try:
            for c in ("mainnet", "testnet"):
                start_h = int(heights[0].get(f"{c}_height") or 0)
                end_h = int(heights[-1].get(f"{c}_height") or 0)
                lines.append(f"- {c}: progressed {end_h - start_h} blocks during run")
        except Exception:
            pass

    # Identify worst categories
    worst = max(cat_results.items(),
                key=lambda x: x[1]["fail"] / max(x[1]["calls"], 1))
    lines.append(f"- Worst category by fail count: **{worst[0]}** "
                 f"({worst[1]['fail']}/{worst[1]['calls']} fails)")

    lines.append("")
    lines.append(f"- Output artifacts in `{OUT_DIR}`:")
    lines.append("  - `progress.log` — chronological run log")
    lines.append("  - `latency.csv`, `height-timeline.csv`, `vps-timeline.csv`")
    lines.append("  - `oracle-timeline.csv`, `reputation-timeline.csv`")
    lines.append("  - `flood_results.json`, `errors.log`")

    report_path.write_text("\n".join(lines), encoding="utf-8")
    log(f"Report written to {report_path}")

    # Errors detail file
    with open(ERRORS_LOG, "w", encoding="utf-8") as fh:
        for e in errors:
            fh.write(f"{e['ts']} | {e['chain']} | {e['method']} | {e['detail']}\n")


def main() -> int:
    # Periodic VPS poller (every 5 min)
    stop_flag = threading.Event()

    def poller():
        while not stop_flag.is_set():
            for _ in range(60):  # 60 * 5s = 5 min
                if stop_flag.is_set():
                    return
                time.sleep(5)
            try:
                vps_snapshot()
                height_snapshot()
            except Exception as e:
                log(f"poller error: {e}")

    t = threading.Thread(target=poller, daemon=True)
    t.start()

    try:
        run_plan()
    except KeyboardInterrupt:
        log("INTERRUPTED")
    except Exception as e:
        log(f"FATAL in run_plan: {e}")
        import traceback
        log(traceback.format_exc())
    finally:
        stop_flag.set()
        write_report()
    return 0


if __name__ == "__main__":
    sys.exit(main())
