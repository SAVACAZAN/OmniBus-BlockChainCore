#!/usr/bin/env python3
"""OmniBus BlockChainCore — Transaction Flood Stress Test (multi-chain).

Updated 2026-05-10: --chain flag, public-VPS endpoints (HTTPS), bearer token.

Floods RPC with:
  - 1000 valid-format JSON-RPC requests (getblockcount, getbestblockhash, ...)
  - 500 concurrent sendrawtransaction with random hex data
  - 100 simultaneous half-open connections

Measures: requests/sec, error rate, latency p50/p95/p99.

Usage:
  python tx-flood-stress.py                              # mainnet
  python tx-flood-stress.py --chain testnet
  python tx-flood-stress.py --chain regtest
  python tx-flood-stress.py --rpc http://127.0.0.1:8332  # explicit override
  python tx-flood-stress.py --threads 50 --count 5000

Stdlib only (threading + http.client + ssl).
"""
from __future__ import annotations

import argparse
import http.client
import json
import os
import random
import secrets
import socket
import ssl
import statistics
import sys
import threading
import time
from collections import defaultdict
from urllib.parse import urlparse

RED = "\033[91m"
GREEN = "\033[92m"
YELLOW = "\033[93m"
CYAN = "\033[96m"
BOLD = "\033[1m"
RESET = "\033[0m"
CLEAR_LINE = "\033[2K\r"

CHAIN_URLS = {
    "mainnet":       "https://omnibusblockchain.cc:8443/api-mainnet",
    "testnet":       "https://omnibusblockchain.cc:8443/api-testnet",
    "regtest":       "https://omnibusblockchain.cc:8443/api-regtest",
    "local-mainnet": "http://127.0.0.1:8332",
    "local-testnet": "http://127.0.0.1:18332",
    "local-regtest": "http://127.0.0.1:28332",
}

SHARDS = 4


class StressResults:
    def __init__(self):
        self.lock = threading.Lock()
        self.latencies = []
        self.errors = 0
        self.successes = 0
        self.by_method = defaultdict(lambda: {"ok": 0, "err": 0, "latencies": []})
        self.start_time = time.time()

    def record(self, method, latency, success):
        with self.lock:
            self.latencies.append(latency)
            if success:
                self.successes += 1
                self.by_method[method]["ok"] += 1
            else:
                self.errors += 1
                self.by_method[method]["err"] += 1
            self.by_method[method]["latencies"].append(latency)

    def total(self):
        return self.successes + self.errors

    def rps(self):
        elapsed = time.time() - self.start_time
        return self.total() / max(elapsed, 0.001)

    def percentile(self, p):
        with self.lock:
            if not self.latencies:
                return 0.0
            sorted_lat = sorted(self.latencies)
            idx = int(len(sorted_lat) * p / 100)
            return sorted_lat[min(idx, len(sorted_lat) - 1)]


def parse_url(url):
    """Returns (scheme, host, port, path)."""
    u = urlparse(url)
    scheme = u.scheme or "http"
    host = u.hostname or "127.0.0.1"
    port = u.port or (443 if scheme == "https" else 80)
    path = u.path or "/"
    return scheme, host, port, path


def rpc_request(scheme, host, port, path, method, params=None, token=None, timeout=10):
    payload = json.dumps({
        "jsonrpc": "2.0",
        "id": random.randint(1, 999999),
        "method": method,
        "params": params or [],
    })
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"

    t0 = time.time()
    try:
        if scheme == "https":
            ctx = ssl.create_default_context()
            conn = http.client.HTTPSConnection(host, port, timeout=timeout, context=ctx)
        else:
            conn = http.client.HTTPConnection(host, port, timeout=timeout)
        conn.request("POST", path, payload, headers)
        resp = conn.getresponse()
        data = resp.read()
        conn.close()
        latency_ms = (time.time() - t0) * 1000
        try:
            result = json.loads(data)
            success = "error" not in result or result.get("result") is not None
        except json.JSONDecodeError:
            success = False
        return success, latency_ms
    except Exception:
        latency_ms = (time.time() - t0) * 1000
        return False, latency_ms


def worker_valid_requests(scheme, host, port, path, count, token, results):
    methods = ["getblockcount", "getbestblockhash", "getblockchaininfo",
               "getmempoolinfo", "getpeerinfo", "getnetworkinfo"]
    for _ in range(count):
        method = random.choice(methods)
        success, latency = rpc_request(scheme, host, port, path, method, token=token)
        results.record(method, latency, success)


def worker_raw_tx(scheme, host, port, path, count, token, results):
    for _ in range(count):
        random_hex = secrets.token_hex(random.randint(100, 500))
        success, latency = rpc_request(scheme, host, port, path, "sendrawtransaction", [random_hex], token=token)
        # Connection success counts; chain rejects payload — that's expected.
        results.record("sendrawtransaction", latency, True)


def worker_connection_hold(scheme, host, port, _path, duration, _token, results):
    """Hold a half-open TCP/TLS connection."""
    try:
        if scheme == "https":
            ctx = ssl.create_default_context()
            sock = socket.create_connection((host, port), timeout=5)
            sock = ctx.wrap_socket(sock, server_hostname=host)
        else:
            sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            sock.settimeout(5)
            sock.connect((host, port))
        t0 = time.time()
        sock.sendall(b"POST / HTTP/1.1\r\nHost: localhost\r\nContent-Length: 999999\r\n\r\n")
        time.sleep(duration)
        try:
            sock.close()
        except Exception:
            pass
        latency = (time.time() - t0) * 1000
        results.record("connection_hold", latency, True)
    except Exception:
        results.record("connection_hold", 0, False)


def print_dashboard(results, phase):
    total = results.total()
    rps = results.rps()
    err_rate = (results.errors / max(total, 1)) * 100
    p50 = results.percentile(50)
    p95 = results.percentile(95)
    p99 = results.percentile(99)
    sys.stdout.write(f"{CLEAR_LINE}{CYAN}[{phase}]{RESET} "
                     f"total={total} rps={rps:.0f} "
                     f"err={err_rate:.1f}% "
                     f"p50={p50:.1f}ms p95={p95:.1f}ms p99={p99:.1f}ms")
    sys.stdout.flush()


def run_phase(name, target, args_list, results, thread_count):
    threads = []
    for i in range(thread_count):
        t = threading.Thread(target=target, args=args_list[i % len(args_list)], daemon=True)
        threads.append(t)
    for t in threads:
        t.start()
    while any(t.is_alive() for t in threads):
        print_dashboard(results, name)
        time.sleep(0.5)
    for t in threads:
        t.join(timeout=15)
    print_dashboard(results, name)
    print()


def main():
    parser = argparse.ArgumentParser(description="OmniBus BlockChainCore — TX Flood Stress (multi-chain)")
    parser.add_argument("--chain", default=os.environ.get("CHAIN", "mainnet"),
                        choices=list(CHAIN_URLS.keys()),
                        help="Endpoint preset. Default: mainnet.")
    parser.add_argument("--rpc", default=None,
                        help="Explicit RPC URL (overrides --chain).")
    parser.add_argument("--token", default=os.environ.get("OMNIBUS_RPC_TOKEN"),
                        help="Bearer token. Default: $OMNIBUS_RPC_TOKEN.")
    parser.add_argument("--threads", type=int, default=20,
                        help="Thread count per phase (default: 20)")
    parser.add_argument("--count", type=int, default=1000,
                        help="Requests for phase 1 (default: 1000)")
    parser.add_argument("--skip-rawtx", action="store_true",
                        help="Skip the random sendrawtransaction phase.")
    parser.add_argument("--skip-conn-flood", action="store_true",
                        help="Skip the half-open connection phase (often blocked by load-balancer).")
    parser.add_argument("--json", action="store_true", help="JSON output")
    args = parser.parse_args()

    url = args.rpc or CHAIN_URLS[args.chain]
    scheme, host, port, path = parse_url(url)

    print(f"{CYAN}{BOLD}{'='*60}")
    print(f" OmniBus — TX Flood Stress Test")
    print(f" Chain:   {args.chain}")
    print(f" Target:  {url}  ({scheme}://{host}:{port}{path})")
    print(f" Threads: {args.threads} | Shards: {SHARDS}")
    print(f" Auth:    {'Bearer (set)' if args.token else 'none'}")
    print(f"{'='*60}{RESET}\n")

    print(f"{GREEN}[PREFLIGHT] Checking RPC ...{RESET}")
    ok, lat = rpc_request(scheme, host, port, path, "getblockcount", token=args.token)
    if not ok:
        print(f"{RED}[ERROR] Cannot reach {url}{RESET}")
        if not args.json:
            sys.exit(1)
    else:
        print(f"  reachable, latency={lat:.1f}ms")

    results = StressResults()
    t_start = time.time()

    print(f"\n{GREEN}[PHASE 1] {args.count} valid JSON-RPC requests ...{RESET}")
    per_thread = max(1, args.count // args.threads)
    phase1_args = [(scheme, host, port, path, per_thread, args.token, results)] * args.threads
    run_phase("VALID-RPC", worker_valid_requests, phase1_args, results, args.threads)

    if not args.skip_rawtx:
        print(f"{GREEN}[PHASE 2] 500 sendrawtransaction with random hex ...{RESET}")
        rawtx_per_thread = max(1, 500 // args.threads)
        phase2_args = [(scheme, host, port, path, rawtx_per_thread, args.token, results)] * args.threads
        run_phase("RAW-TX", worker_raw_tx, phase2_args, results, args.threads)

    if not args.skip_conn_flood:
        print(f"{GREEN}[PHASE 3] 100 simultaneous half-open connections ...{RESET}")
        phase3_args = [(scheme, host, port, path, 5.0, args.token, results)] * 100
        run_phase("CONN-FLOOD", worker_connection_hold, phase3_args, results, 100)

    print(f"\n{GREEN}[POST-CHECK] Verifying RPC still alive ...{RESET}")
    ok, lat = rpc_request(scheme, host, port, path, "getblockcount", token=args.token)
    node_alive = ok

    elapsed = time.time() - t_start

    report = {
        "chain": args.chain,
        "target": url,
        "total_requests": results.total(),
        "successes": results.successes,
        "errors": results.errors,
        "error_rate_pct": round((results.errors / max(results.total(), 1)) * 100, 2),
        "requests_per_sec": round(results.rps(), 1),
        "latency_p50_ms": round(results.percentile(50), 2),
        "latency_p95_ms": round(results.percentile(95), 2),
        "latency_p99_ms": round(results.percentile(99), 2),
        "node_alive_after": node_alive,
        "elapsed_seconds": round(elapsed, 2),
        "by_method": {
            m: {"ok": d["ok"], "err": d["err"],
                "avg_ms": round(statistics.mean(d["latencies"]), 2) if d["latencies"] else 0}
            for m, d in results.by_method.items()
        },
    }

    if args.json:
        print(json.dumps(report, indent=2))
    else:
        alive_color = GREEN if node_alive else RED
        print(f"\n{CYAN}{'='*60}")
        print(f" STRESS TEST RESULTS")
        print(f"{'='*60}{RESET}")
        print(f"  Chain:           {report['chain']}")
        print(f"  Total requests:  {report['total_requests']}")
        print(f"  Successes:       {GREEN}{report['successes']}{RESET}")
        print(f"  Errors:          {RED}{report['errors']}{RESET}")
        print(f"  Error rate:      {report['error_rate_pct']}%")
        print(f"  Requests/sec:    {BOLD}{report['requests_per_sec']}{RESET}")
        print(f"  Latency p50:     {report['latency_p50_ms']}ms")
        print(f"  Latency p95:     {report['latency_p95_ms']}ms")
        print(f"  Latency p99:     {report['latency_p99_ms']}ms")
        print(f"  Node alive:      {alive_color}{node_alive}{RESET}")
        print(f"  Elapsed:         {elapsed:.2f}s")
        print(f"\n  {BOLD}Per method:{RESET}")
        for m, d in report["by_method"].items():
            print(f"    {m:30s} ok={d['ok']:5d} err={d['err']:3d} avg={d['avg_ms']:.1f}ms")

    sys.exit(0 if node_alive else 1)


if __name__ == "__main__":
    main()
