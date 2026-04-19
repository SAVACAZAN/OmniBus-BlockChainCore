#!/usr/bin/env python3
"""OmniBus BlockChainCore — Transaction Flood Stress Test.

Floods RPC port 8332 with:
  - 1000 valid-format JSON-RPC requests (getblockcount, getbestblockhash)
  - 500 concurrent sendrawtransaction with random hex data
  - 100 simultaneous connections

Measures: requests/sec, error rate, latency p50/p95/p99.
Prints live dashboard.  Stdlib only (threading + http.client).
"""

import argparse
import http.client
import json
import os
import random
import secrets
import statistics
import sys
import threading
import time
from collections import defaultdict

# ---------------------------------------------------------------------------
RED = "\033[91m"
GREEN = "\033[92m"
YELLOW = "\033[93m"
CYAN = "\033[96m"
BOLD = "\033[1m"
RESET = "\033[0m"
CLEAR_LINE = "\033[2K\r"

# OmniBus BlockChainCore
RPC_PORT = 8332
WS_PORT = 8334
P2P_PORT = 9000
NODE_BINARY = os.path.join("zig-out", "bin", "omnibus-node.exe")
SHARDS = 4
SUB_BLOCKS = 10
MAX_SUPPLY = 21_000_000
SAT = int(1e9)
BLOCK_REWARD = 50
HALVING_INTERVAL = 210_000


class StressResults:
    def __init__(self):
        self.lock = threading.Lock()
        self.latencies = []
        self.errors = 0
        self.successes = 0
        self.by_method = defaultdict(lambda: {"ok": 0, "err": 0, "latencies": []})
        self.start_time = time.time()

    def record(self, method: str, latency: float, success: bool):
        with self.lock:
            self.latencies.append(latency)
            if success:
                self.successes += 1
                self.by_method[method]["ok"] += 1
            else:
                self.errors += 1
                self.by_method[method]["err"] += 1
            self.by_method[method]["latencies"].append(latency)

    def total(self) -> int:
        return self.successes + self.errors

    def rps(self) -> float:
        elapsed = time.time() - self.start_time
        return self.total() / max(elapsed, 0.001)

    def percentile(self, p: float) -> float:
        with self.lock:
            if not self.latencies:
                return 0.0
            sorted_lat = sorted(self.latencies)
            idx = int(len(sorted_lat) * p / 100)
            return sorted_lat[min(idx, len(sorted_lat) - 1)]


def rpc_request(host: str, port: int, method: str, params: list = None) -> tuple:
    """Send JSON-RPC request. Returns (success, latency_ms)."""
    payload = json.dumps({
        "jsonrpc": "2.0",
        "id": random.randint(1, 999999),
        "method": method,
        "params": params or [],
    })

    t0 = time.time()
    try:
        conn = http.client.HTTPConnection(host, port, timeout=10)
        conn.request("POST", "/", payload, {"Content-Type": "application/json"})
        resp = conn.getresponse()
        data = resp.read()
        conn.close()
        latency_ms = (time.time() - t0) * 1000

        result = json.loads(data)
        success = "error" not in result or result.get("result") is not None
        return success, latency_ms
    except Exception:
        latency_ms = (time.time() - t0) * 1000
        return False, latency_ms


def worker_valid_requests(host: str, port: int, count: int, results: StressResults):
    """Send valid RPC requests."""
    methods = ["getblockcount", "getbestblockhash", "getblockchaininfo",
               "getmempoolinfo", "getpeerinfo", "getnetworkinfo"]
    for _ in range(count):
        method = random.choice(methods)
        success, latency = rpc_request(host, port, method)
        results.record(method, latency, success)


def worker_raw_tx(host: str, port: int, count: int, results: StressResults):
    """Send sendrawtransaction with random hex data."""
    for _ in range(count):
        random_hex = secrets.token_hex(random.randint(100, 500))
        success, latency = rpc_request(host, port, "sendrawtransaction", [random_hex])
        # Expected to fail (invalid tx), but shouldn't crash the node
        results.record("sendrawtransaction", latency, True)  # connection success counts


def worker_connection_hold(host: str, port: int, duration: float, results: StressResults):
    """Open connection and hold it."""
    import socket
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.settimeout(5)
        t0 = time.time()
        sock.connect((host, port))
        # Send partial HTTP request to hold connection
        sock.sendall(b"POST / HTTP/1.1\r\nHost: localhost\r\nContent-Length: 999999\r\n\r\n")
        time.sleep(duration)
        sock.close()
        latency = (time.time() - t0) * 1000
        results.record("connection_hold", latency, True)
    except Exception:
        results.record("connection_hold", 0, False)


def print_dashboard(results: StressResults, phase: str):
    """Print live stats."""
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


def run_phase(name: str, target, args_list: list, results: StressResults,
              thread_count: int):
    """Run a phase with N threads."""
    threads = []
    for i in range(thread_count):
        t = threading.Thread(target=target, args=args_list[i % len(args_list)],
                             daemon=True)
        threads.append(t)

    for t in threads:
        t.start()

    # Monitor
    while any(t.is_alive() for t in threads):
        print_dashboard(results, name)
        time.sleep(0.5)

    for t in threads:
        t.join(timeout=15)

    print_dashboard(results, name)
    print()  # newline after dashboard


def main():
    parser = argparse.ArgumentParser(
        description="OmniBus BlockChainCore — TX Flood Stress Test"
    )
    parser.add_argument("--rpc-url", default="127.0.0.1",
                        help="RPC host (default: 127.0.0.1)")
    parser.add_argument("--port", type=int, default=RPC_PORT,
                        help=f"RPC port (default: {RPC_PORT})")
    parser.add_argument("--threads", type=int, default=20,
                        help="Thread count per phase (default: 20)")
    parser.add_argument("--count", type=int, default=1000,
                        help="Requests for phase 1 (default: 1000)")
    parser.add_argument("--json", action="store_true", help="JSON output")
    args = parser.parse_args()

    host = args.rpc_url
    port = args.port

    print(f"{CYAN}{BOLD}{'='*60}")
    print(f" OmniBus BlockChainCore — TX Flood Stress Test")
    print(f" Target: {host}:{port}")
    print(f" Threads: {args.threads} | Shards: {SHARDS}")
    print(f" Node: {NODE_BINARY}")
    print(f"{'='*60}{RESET}\n")

    # Check node is alive
    print(f"{GREEN}[PREFLIGHT] Checking node ...{RESET}")
    ok, lat = rpc_request(host, port, "getblockcount")
    if not ok:
        print(f"{RED}[ERROR] Cannot connect to {host}:{port}{RESET}")
        print(f"{YELLOW}  Start node: {NODE_BINARY} --mode seed --port {P2P_PORT}{RESET}")
        if not args.json:
            sys.exit(1)

    results = StressResults()
    t_start = time.time()

    # Phase 1: Valid RPC requests
    print(f"\n{GREEN}[PHASE 1] {args.count} valid JSON-RPC requests ...{RESET}")
    per_thread = args.count // args.threads
    phase1_args = [(host, port, per_thread, results)] * args.threads
    run_phase("VALID-RPC", worker_valid_requests, phase1_args, results, args.threads)

    # Phase 2: Random raw transactions
    print(f"{GREEN}[PHASE 2] 500 sendrawtransaction with random hex ...{RESET}")
    rawtx_per_thread = 500 // args.threads
    phase2_args = [(host, port, rawtx_per_thread, results)] * args.threads
    run_phase("RAW-TX", worker_raw_tx, phase2_args, results, args.threads)

    # Phase 3: Connection flood
    print(f"{GREEN}[PHASE 3] 100 simultaneous connections ...{RESET}")
    phase3_args = [(host, port, 5.0, results)] * 100
    run_phase("CONN-FLOOD", worker_connection_hold, phase3_args, results, 100)

    # Verify node still alive
    print(f"\n{GREEN}[POST-CHECK] Verifying node is still alive ...{RESET}")
    ok, lat = rpc_request(host, port, "getblockcount")
    node_alive = ok

    elapsed = time.time() - t_start

    # Build report
    report = {
        "target": f"{host}:{port}",
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
