#!/usr/bin/env python3
"""OmniBus BlockChainCore — Memory Pressure Test.

Sends via RPC (port 8332):
  - Extremely long string params (1MB)
  - Deeply nested JSON (100 levels)
  - Array with 100k elements
  - Binary data in hex fields

Checks node doesn't crash (ping after each test).
Reports which inputs caused errors vs crashes.
Stdlib only (http.client).
"""

import argparse
import http.client
import json
import sys
import time

# ---------------------------------------------------------------------------
RED = "\033[91m"
GREEN = "\033[92m"
YELLOW = "\033[93m"
CYAN = "\033[96m"
BOLD = "\033[1m"
RESET = "\033[0m"

# OmniBus BlockChainCore
RPC_PORT = 8332
P2P_PORT = 9000
SHARDS = 4
SUB_BLOCKS_PER_BLOCK = 10  # 10 x 0.1s
MAX_SUPPLY = 21_000_000
SAT = int(1e9)
BLOCK_REWARD = 50
HALVING_INTERVAL = 210_000
CHAIN_DATA = "omnibus-chain.dat"


def rpc_raw(host: str, port: int, payload: str, timeout: int = 10) -> dict:
    """Send raw JSON payload to RPC."""
    try:
        conn = http.client.HTTPConnection(host, port, timeout=timeout)
        conn.request("POST", "/", payload, {
            "Content-Type": "application/json",
            "Content-Length": str(len(payload)),
        })
        resp = conn.getresponse()
        status = resp.status
        data = resp.read().decode("utf-8", errors="replace")
        conn.close()
        return {"status": status, "body": data[:1000], "crashed": False}
    except (ConnectionRefusedError, ConnectionResetError, BrokenPipeError):
        return {"status": 0, "body": "", "crashed": True}
    except Exception as exc:
        return {"status": 0, "body": str(exc), "crashed": "refused" in str(exc).lower()}


def ping_node(host: str, port: int) -> bool:
    """Verify node is alive with a simple getblockcount."""
    payload = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "getblockcount", "params": []})
    try:
        conn = http.client.HTTPConnection(host, port, timeout=5)
        conn.request("POST", "/", payload, {"Content-Type": "application/json"})
        resp = conn.getresponse()
        resp.read()
        conn.close()
        return resp.status in (200, 400, 500)  # Any HTTP response = alive
    except Exception:
        return False


class TestResult:
    def __init__(self, name: str, description: str):
        self.name = name
        self.description = description
        self.response_status = 0
        self.response_body = ""
        self.node_alive_after = True
        self.error_type = "none"  # none, error_response, crash, timeout
        self.elapsed_ms = 0

    def to_dict(self):
        return {
            "name": self.name,
            "description": self.description,
            "response_status": self.response_status,
            "error_type": self.error_type,
            "node_alive_after": self.node_alive_after,
            "elapsed_ms": self.elapsed_ms,
        }


def test_long_string(host: str, port: int) -> TestResult:
    """Send 1MB string parameter."""
    result = TestResult("long_string_1mb", "1MB string in JSON-RPC params")
    long_str = "A" * (1024 * 1024)  # 1MB
    payload = json.dumps({
        "jsonrpc": "2.0", "id": 1,
        "method": "getblock",
        "params": [long_str],
    })

    t0 = time.time()
    resp = rpc_raw(host, port, payload, timeout=30)
    result.elapsed_ms = round((time.time() - t0) * 1000)
    result.response_status = resp["status"]
    result.response_body = resp["body"]

    if resp["crashed"]:
        result.error_type = "crash"
        result.node_alive_after = False
    elif resp["status"] == 0:
        result.error_type = "timeout"
    else:
        result.error_type = "error_response"  # Expected: node rejects gracefully

    # Verify alive
    time.sleep(0.5)
    result.node_alive_after = ping_node(host, port)
    return result


def test_deeply_nested_json(host: str, port: int) -> TestResult:
    """Send 100-level nested JSON."""
    result = TestResult("nested_json_100", "100-level deep nested JSON")

    # Build nested structure manually (json.dumps might be slow)
    inner = '"deep"'
    for _ in range(100):
        inner = '{"level": ' + inner + '}'

    payload = '{"jsonrpc":"2.0","id":1,"method":"echo","params":[' + inner + ']}'

    t0 = time.time()
    resp = rpc_raw(host, port, payload, timeout=15)
    result.elapsed_ms = round((time.time() - t0) * 1000)
    result.response_status = resp["status"]

    if resp["crashed"]:
        result.error_type = "crash"
    elif resp["status"] == 0:
        result.error_type = "timeout"
    else:
        result.error_type = "error_response"

    time.sleep(0.5)
    result.node_alive_after = ping_node(host, port)
    return result


def test_large_array(host: str, port: int) -> TestResult:
    """Send array with 100k elements."""
    result = TestResult("large_array_100k", "Array with 100,000 elements in params")

    elements = ",".join(str(i) for i in range(100_000))
    payload = '{"jsonrpc":"2.0","id":1,"method":"batch","params":[[' + elements + ']]}'

    t0 = time.time()
    resp = rpc_raw(host, port, payload, timeout=30)
    result.elapsed_ms = round((time.time() - t0) * 1000)
    result.response_status = resp["status"]

    if resp["crashed"]:
        result.error_type = "crash"
    elif resp["status"] == 0:
        result.error_type = "timeout"
    else:
        result.error_type = "error_response"

    time.sleep(0.5)
    result.node_alive_after = ping_node(host, port)
    return result


def test_binary_hex(host: str, port: int) -> TestResult:
    """Send large binary data encoded as hex."""
    result = TestResult("binary_hex_500k", "500KB of hex data in sendrawtransaction")

    import secrets
    hex_data = secrets.token_hex(500_000)  # 500KB = 1M hex chars
    payload = json.dumps({
        "jsonrpc": "2.0", "id": 1,
        "method": "sendrawtransaction",
        "params": [hex_data],
    })

    t0 = time.time()
    resp = rpc_raw(host, port, payload, timeout=30)
    result.elapsed_ms = round((time.time() - t0) * 1000)
    result.response_status = resp["status"]

    if resp["crashed"]:
        result.error_type = "crash"
    elif resp["status"] == 0:
        result.error_type = "timeout"
    else:
        result.error_type = "error_response"

    time.sleep(0.5)
    result.node_alive_after = ping_node(host, port)
    return result


def test_malformed_json(host: str, port: int) -> TestResult:
    """Send malformed JSON."""
    result = TestResult("malformed_json", "Invalid JSON (truncated, wrong encoding)")

    payloads = [
        '{"jsonrpc":"2.0","id":1,"method":"get',  # truncated
        '\x00\x01\x02\x03\xff\xfe',  # binary garbage
        '{"jsonrpc":"2.0","id":1,' + '"' * 50000,  # quote flood
        '{"jsonrpc":"2.0","id":' + '9' * 100000 + '}',  # huge number
    ]

    worst_type = "none"
    for i, payload in enumerate(payloads):
        t0 = time.time()
        resp = rpc_raw(host, port, payload, timeout=10)
        elapsed = (time.time() - t0) * 1000

        if resp["crashed"]:
            worst_type = "crash"
            break
        elif resp["status"] == 0:
            worst_type = "timeout"

        time.sleep(0.2)

    result.error_type = worst_type if worst_type != "none" else "error_response"
    result.elapsed_ms = round(elapsed)
    result.node_alive_after = ping_node(host, port)
    return result


def test_zero_content_length(host: str, port: int) -> TestResult:
    """Send with Content-Length: 0 but non-empty body."""
    result = TestResult("zero_content_length", "Content-Length:0 with non-empty body")

    try:
        conn = http.client.HTTPConnection(host, port, timeout=10)
        body = '{"jsonrpc":"2.0","id":1,"method":"getblockcount"}'
        conn.request("POST", "/", body, {
            "Content-Type": "application/json",
            "Content-Length": "0",
        })
        t0 = time.time()
        resp = conn.getresponse()
        resp.read()
        result.elapsed_ms = round((time.time() - t0) * 1000)
        result.response_status = resp.status
        result.error_type = "error_response"
        conn.close()
    except Exception:
        result.error_type = "timeout"

    result.node_alive_after = ping_node(host, port)
    return result


def main():
    parser = argparse.ArgumentParser(
        description="OmniBus BlockChainCore — Memory Pressure Test"
    )
    parser.add_argument("--host", default="127.0.0.1", help="RPC host")
    parser.add_argument("--port", type=int, default=RPC_PORT, help=f"RPC port (default: {RPC_PORT})")
    parser.add_argument("--json", action="store_true", help="JSON output")
    args = parser.parse_args()

    print(f"{CYAN}{BOLD}{'='*60}")
    print(f" OmniBus BlockChainCore — Memory Pressure Test")
    print(f" Target: {args.host}:{args.port}")
    print(f" Chain data: {CHAIN_DATA}")
    print(f" Max supply: {MAX_SUPPLY:,} OMNI ({SAT} SAT/OMNI)")
    print(f"{'='*60}{RESET}\n")

    # Preflight
    alive = ping_node(args.host, args.port)
    if not alive:
        print(f"{RED}[ERROR] Node not responding at {args.host}:{args.port}{RESET}")
        if not args.json:
            sys.exit(1)

    tests = [
        ("1MB string param", test_long_string),
        ("100-level nested JSON", test_deeply_nested_json),
        ("100k element array", test_large_array),
        ("500KB hex binary", test_binary_hex),
        ("Malformed JSON", test_malformed_json),
        ("Zero Content-Length", test_zero_content_length),
    ]

    results = []
    any_crash = False

    for name, test_fn in tests:
        print(f"{GREEN}[TEST] {name} ...{RESET}", end=" ", flush=True)
        result = test_fn(args.host, args.port)
        results.append(result)

        if not result.node_alive_after:
            any_crash = True
            print(f"{RED}CRASH! Node died!{RESET}")
            print(f"{RED}  Stopping further tests — node is down{RESET}")
            break
        elif result.error_type == "timeout":
            print(f"{YELLOW}TIMEOUT ({result.elapsed_ms}ms){RESET}")
        else:
            print(f"{GREEN}OK — graceful error ({result.elapsed_ms}ms){RESET}")

    # Build report
    report = {
        "target": f"{args.host}:{args.port}",
        "tests": [r.to_dict() for r in results],
        "crashes": sum(1 for r in results if not r.node_alive_after),
        "timeouts": sum(1 for r in results if r.error_type == "timeout"),
        "graceful_errors": sum(1 for r in results if r.error_type == "error_response"),
        "verdict": "FAIL — NODE CRASHED" if any_crash else "PASS",
    }

    if args.json:
        print(json.dumps(report, indent=2))
    else:
        print(f"\n{CYAN}{'='*60}")
        print(f" RESULTS")
        print(f"{'='*60}{RESET}")
        print(f"  Tests run:       {len(results)}")
        print(f"  Crashes:         {RED}{report['crashes']}{RESET}")
        print(f"  Timeouts:        {YELLOW}{report['timeouts']}{RESET}")
        print(f"  Graceful:        {GREEN}{report['graceful_errors']}{RESET}")
        vc = GREEN if not any_crash else RED
        print(f"\n  Verdict:         {vc}{BOLD}{report['verdict']}{RESET}")

    sys.exit(0 if not any_crash else 1)


if __name__ == "__main__":
    main()
