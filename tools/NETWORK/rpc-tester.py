#!/usr/bin/env python3
"""
OmniBus Blockchain Core — JSON-RPC 2.0 Test Suite

Tests each method, verifies error handling, stress tests with concurrent requests.
"""

import argparse
import json
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from typing import Any, Dict, List, Optional
import requests

GREEN = "\033[92m"
RED = "\033[91m"
YELLOW = "\033[93m"
RESET = "\033[0m"


def cprint(color: str, msg: str) -> None:
    print(f"{color}{msg}{RESET}")


RPC_METHODS = [
    ("getblockchaininfo", []),
    ("getblockcount", []),
    ("getbestblockhash", []),
    ("getblock", ["0000000000000000000000000000000000000000000000000000000000000000"]),
    ("getrawmempool", []),
    ("sendrawtransaction", ["00"]),
    ("getpeerinfo", []),
]


class RPCTester:
    def __init__(self, url: str = "http://127.0.0.1:8332", user: str = "", password: str = ""):
        self.url = url
        self.headers = {"Content-Type": "application/json"}
        self.session = requests.Session()
        self.session.headers.update(self.headers)
        if user:
            self.session.auth = (user, password)
        self.results: List[Dict[str, Any]] = []

    def _call(self, method: str, params: List[Any]) -> Dict[str, Any]:
        payload = {"jsonrpc": "2.0", "id": 1, "method": method, "params": params}
        try:
            resp = self.session.post(self.url, json=payload, timeout=10)
            return {"method": method, "status_code": resp.status_code, "body": resp.text}
        except requests.RequestException as e:
            return {"method": method, "error": str(e)}

    def test_methods(self) -> None:
        cprint(YELLOW, "\n--- RPC Method Tests ---")
        for method, params in RPC_METHODS:
            res = self._call(method, params)
            ok = "error" not in res
            color = GREEN if ok else RED
            self.results.append({"check": f"rpc_{method}", "status": "PASS" if ok else "FAIL", "detail": res.get("body", res.get("error", ""))[:120]})
            cprint(color, f"{'[PASS]' if ok else '[FAIL]'} {method}")

    def test_error_handling(self) -> None:
        cprint(YELLOW, "\n--- Error Handling Tests ---")
        # Invalid method
        res = self._call("nonexistent_method", [])
        has_error = "error" in res.get("body", "").lower() or res.get("status_code", 200) != 200
        self.results.append({"check": "error_invalid_method", "status": "PASS" if has_error else "FAIL", "detail": res.get("body", "")[:120]})
        cprint(GREEN if has_error else RED, f"{'[PASS]' if has_error else '[FAIL]'} Invalid method returns error")

        # Invalid params (too many)
        res2 = self._call("getblockcount", ["extra"])
        has_err2 = "error" in res2.get("body", "").lower()
        self.results.append({"check": "error_invalid_params", "status": "PASS" if has_err2 else "FAIL", "detail": res2.get("body", "")[:120]})
        cprint(GREEN if has_err2 else YELLOW, f"{'[PASS]' if has_err2 else '[WARN]'} Invalid params returns error")

    def stress_test(self, concurrency: int = 50, requests_count: int = 500) -> None:
        cprint(YELLOW, f"\n--- Stress Test ({requests_count} req @ {concurrency} threads) ---")
        ok = 0
        fail = 0

        def worker(_: int) -> bool:
            r = self._call("getblockcount", [])
            return "error" not in r

        with ThreadPoolExecutor(max_workers=concurrency) as ex:
            futures = [ex.submit(worker, i) for i in range(requests_count)]
            for fut in as_completed(futures):
                if fut.result():
                    ok += 1
                else:
                    fail += 1

        self.results.append({"check": "stress_test", "status": "PASS" if fail == 0 else "FAIL", "detail": f"{ok} OK, {fail} FAIL"})
        cprint(GREEN if fail == 0 else RED, f"Stress: {ok} OK, {fail} FAIL")

    def run(self) -> Dict[str, Any]:
        cprint(GREEN, "=== OmniBus JSON-RPC Tester ===")
        self.test_methods()
        self.test_error_handling()
        self.stress_test()
        return {"rpc_url": self.url, "results": self.results}


def main() -> int:
    parser = argparse.ArgumentParser(description="Test OmniBus JSON-RPC interface")
    parser.add_argument("--url", default="http://127.0.0.1:8332", help="RPC URL")
    parser.add_argument("--user", default="", help="RPC user")
    parser.add_argument("--password", default="", help="RPC password")
    parser.add_argument("--output", default="rpc-test-report.json", help="Output JSON path")
    args = parser.parse_args()

    tester = RPCTester(url=args.url, user=args.user, password=args.password)
    report = tester.run()

    with open(args.output, "w", encoding="utf-8") as f:
        json.dump(report, f, indent=2)
    cprint(GREEN, f"\nReport written to {args.output}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
