#!/usr/bin/env python3
"""
rpc-fuzzer.py

Fuzz the JSON-RPC interface of a BlockChainCore node.
Sends malformed JSON-RPC requests:
  - missing fields, wrong types
  - huge payloads
  - deeply nested objects
  - SQL injection attempts inside params
  - null bytes and unicode exploits

Outputs: rpc-vulnerabilities.json
"""

import argparse
import json
import os
import random
import string
import sys
import time
from datetime import datetime, timezone
from typing import Any

import requests

GREEN = "\033[92m"
RED = "\033[91m"
YELLOW = "\033[93m"
CYAN = "\033[96m"
RESET = "\033[0m"


def log_info(msg: str) -> None:
    print(f"{CYAN}[INFO]{RESET} {msg}")


def log_pass(msg: str) -> None:
    print(f"{GREEN}[PASS]{RESET} {msg}")


def log_fail(msg: str) -> None:
    print(f"{RED}[FAIL]{RESET} {msg}")


def log_warn(msg: str) -> None:
    print(f"{YELLOW}[WARN]{RESET} {msg}")


# ---------------------------------------------------------------------------
# Payload generators
# ---------------------------------------------------------------------------
def build_payload(method: str | None, params: Any, req_id: Any = 1) -> dict[str, Any] | str:
    payload: dict[str, Any] = {"jsonrpc": "2.0"}
    if method is not None:
        payload["method"] = method
    if params is not None:
        payload["params"] = params
    if req_id is not None:
        payload["id"] = req_id
    return payload


def random_string(length: int) -> str:
    return "".join(random.choices(string.ascii_letters + string.digits, k=length))


def deep_nest(depth: int) -> Any:
    if depth <= 0:
        return {"key": "value"}
    return {"nested": deep_nest(depth - 1)}


def fuzz_cases() -> list[dict[str, Any]]:
    cases: list[dict[str, Any]] = []

    # 1. Valid baseline
    cases.append(
        {
            "name": "valid_getblockcount",
            "payload": build_payload("getblockcount", []),
            "expect_error": False,
        }
    )

    # 2. Missing method
    cases.append(
        {
            "name": "missing_method",
            "payload": build_payload(None, []),
            "expect_error": True,
        }
    )

    # 3. Missing params
    cases.append(
        {
            "name": "missing_params",
            "payload": {"jsonrpc": "2.0", "method": "getblockcount", "id": 1},
            "expect_error": False,
        }
    )

    # 4. Wrong type for params
    cases.append(
        {
            "name": "params_as_string",
            "payload": build_payload("getblockcount", "not_an_array"),
            "expect_error": True,
        }
    )

    # 5. Huge payload
    huge = [random_string(1024) for _ in range(1024)]
    cases.append(
        {
            "name": "huge_payload_1mb",
            "payload": build_payload("getblockcount", huge),
            "expect_error": True,
        }
    )

    # 6. Deeply nested object
    cases.append(
        {
            "name": "deeply_nested_100",
            "payload": build_payload("getblockcount", deep_nest(100)),
            "expect_error": True,
        }
    )

    # 7. SQL injection in param
    sql_inject = "' OR '1'='1'; DROP TABLE blocks; --"
    cases.append(
        {
            "name": "sql_injection_string",
            "payload": build_payload("getblock", [sql_inject]),
            "expect_error": True,
        }
    )

    # 8. Null bytes in JSON
    cases.append(
        {
            "name": "null_bytes_in_json",
            "payload_raw": '{"jsonrpc": "2.0", "method": "getblock\u0000count", "params": [], "id": 1}',
            "expect_error": True,
        }
    )

    # 9. Unicode exploits
    cases.append(
        {
            "name": "unicode_overload",
            "payload": build_payload("getblockcount", ["\u0000\uFFFF\u202E" * 1000]),
            "expect_error": True,
        }
    )

    # 10. Negative id
    cases.append(
        {
            "name": "negative_id",
            "payload": build_payload("getblockcount", [], -999),
            "expect_error": False,
        }
    )

    # 11. Method as array
    cases.append(
        {
            "name": "method_is_array",
            "payload": build_payload(["getblockcount"], []),
            "expect_error": True,
        }
    )

    # 12. Empty batch
    cases.append(
        {
            "name": "empty_batch",
            "payload": [],
            "expect_error": True,
        }
    )

    # 13. Batch with one bad entry
    cases.append(
        {
            "name": "batch_mixed",
            "payload": [
                build_payload("getblockcount", []),
                build_payload(None, []),
            ],
            "expect_error": False,
        }
    )

    # 14. Very large number
    cases.append(
        {
            "name": "extreme_number",
            "payload": build_payload("getblockcount", [10**100]),
            "expect_error": True,
        }
    )

    # 15. JSON with trailing garbage
    cases.append(
        {
            "name": "trailing_garbage",
            "payload_raw": '{"jsonrpc":"2.0","method":"getblockcount","params":[],"id":1}GARBAGE',
            "expect_error": True,
        }
    )

    return cases


# ---------------------------------------------------------------------------
# RPC interaction
# ---------------------------------------------------------------------------
def send_rpc(url: str, payload: dict[str, Any] | list[Any] | str, timeout: float = 10.0) -> dict[str, Any]:
    result: dict[str, Any] = {
        "http_status": None,
        "response": None,
        "error": None,
        "elapsed_ms": 0.0,
    }
    headers = {"Content-Type": "application/json"}
    start = time.perf_counter()
    try:
        if isinstance(payload, str):
            resp = requests.post(url, data=payload, headers=headers, timeout=timeout)
        else:
            resp = requests.post(url, json=payload, headers=headers, timeout=timeout)
        result["http_status"] = resp.status_code
        try:
            result["response"] = resp.json()
        except Exception:
            result["response"] = resp.text[:512]
    except requests.exceptions.ConnectionError as exc:
        result["error"] = f"ConnectionError: {exc}"
    except requests.exceptions.Timeout:
        result["error"] = "Timeout"
    except Exception as exc:
        result["error"] = f"Exception: {exc}"
    result["elapsed_ms"] = round((time.perf_counter() - start) * 1000, 2)
    return result


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def main() -> int:
    parser = argparse.ArgumentParser(description="Fuzz BlockChainCore JSON-RPC.")
    parser.add_argument("--url", default="http://127.0.0.1:8332", help="RPC endpoint")
    parser.add_argument("--user", default="", help="RPC username")
    parser.add_argument("--password", default="", help="RPC password")
    parser.add_argument("--timeout", type=float, default=10.0, help="Request timeout")
    parser.add_argument("--output", default="tools/REVERSE/rpc-vulnerabilities.json", help="Output path")
    parser.add_argument("--cooldown", type=float, default=0.2, help="Seconds between requests")
    args = parser.parse_args()

    session = requests.Session()
    if args.user or args.password:
        session.auth = (args.user, args.password)

    cases = fuzz_cases()
    log_info(f"Running {len(cases)} RPC fuzz cases against {args.url}")

    results: list[dict[str, Any]] = []
    for case in cases:
        raw = case.get("payload_raw")
        payload = raw if raw is not None else case["payload"]
        log_info(f"Case: {case['name']}")
        probe = send_rpc(args.url, payload, args.timeout)

        has_error = probe["error"] is not None
        rpc_error = False
        if isinstance(probe.get("response"), dict) and "error" in probe["response"] and probe["response"]["error"] is not None:
            rpc_error = True

        unexpected = False
        if not case["expect_error"] and (has_error or rpc_error):
            unexpected = True
            log_warn(f"  Unexpected error on {case['name']}: {probe['error'] or probe['response']}")
        elif case["expect_error"] and not has_error and not rpc_error:
            # If it didn't error when we expected an error, that's interesting but not necessarily a vuln
            pass

        if has_error and probe["error"] == "Timeout":
            log_fail(f"  Timeout on {case['name']} — possible DoS vector")
            unexpected = True

        if probe["http_status"] not in (200, 400, 401, 403, 404, 500, None):
            log_warn(f"  Unusual HTTP {probe['http_status']} on {case['name']}")
            unexpected = True

        results.append(
            {
                "name": case["name"],
                "expected_error": case["expect_error"],
                "http_status": probe["http_status"],
                "rpc_error": rpc_error,
                "network_error": probe["error"],
                "response_preview": probe["response"],
                "elapsed_ms": probe["elapsed_ms"],
                "unexpected": unexpected,
            }
        )
        time.sleep(args.cooldown)

    report = {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "target_url": args.url,
        "cases_run": len(cases),
        "unexpected_behaviors": sum(1 for r in results if r["unexpected"]),
        "results": results,
    }

    out_path = os.path.abspath(args.output)
    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    with open(out_path, "w", encoding="utf-8") as fh:
        json.dump(report, fh, indent=2)

    log_pass(f"RPC fuzz report written to {out_path}")
    log_info(f"Unexpected behaviors: {report['unexpected_behaviors']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
