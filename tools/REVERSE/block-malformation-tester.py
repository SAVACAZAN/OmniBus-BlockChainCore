#!/usr/bin/env python3
"""
block-malformation-tester.py

Construct invalid blocks and submit them to a BlockChainCore node via RPC
 to verify they are rejected.  Malformations include:
  - wrong previous block hash
  - timestamp in the future
  - difficulty mismatch
  - double-spend transaction inside block
  - invalid signature
  - oversized block

Outputs: block-validation-report.json
"""

import argparse
import hashlib
import json
import os
import random
import struct
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
# Helpers
# ---------------------------------------------------------------------------
def rpc_call(url: str, method: str, params: list[Any] | dict[str, Any] | None = None,
             auth: tuple[str, str] | None = None, timeout: float = 10.0) -> dict[str, Any]:
    payload = {"jsonrpc": "2.0", "method": method, "id": random.randint(1, 100000)}
    if params is not None:
        payload["params"] = params
    try:
        resp = requests.post(url, json=payload, auth=auth, timeout=timeout)
        return resp.json()
    except Exception as exc:
        return {"error": str(exc)}


def make_tx(inputs: list[dict[str, Any]], outputs: list[dict[str, Any]]) -> dict[str, Any]:
    return {
        "version": 1,
        "inputs": inputs,
        "outputs": outputs,
        "locktime": 0,
    }


def make_block(prev_hash: str, merkle_root: str, timestamp: int, bits: int, nonce: int,
               txs: list[dict[str, Any]]) -> dict[str, Any]:
    return {
        "header": {
            "version": 1,
            "prev_block": prev_hash,
            "merkle_root": merkle_root,
            "timestamp": timestamp,
            "bits": bits,
            "nonce": nonce,
        },
        "transactions": txs,
    }


def double_sha256(data: bytes) -> bytes:
    return hashlib.sha256(hashlib.sha256(data).digest()).digest()


def hash_block_header(header: dict[str, Any]) -> str:
    """Minimal block header hash for testing (little-endian concatenation)."""
    blob = struct.pack("<I", header["version"])
    blob += bytes.fromhex(header["prev_block"])[::-1]
    blob += bytes.fromhex(header["merkle_root"])[::-1]
    blob += struct.pack("<I", header["timestamp"])
    blob += struct.pack("<I", header["bits"])
    blob += struct.pack("<I", header["nonce"])
    return double_sha256(blob)[::-1].hex()


# ---------------------------------------------------------------------------
# Malformation generators
# ---------------------------------------------------------------------------
def malformed_blocks(node_info: dict[str, Any]) -> list[dict[str, Any]]:
    prev_hash = node_info.get("bestblockhash", "0" * 64)
    bits = node_info.get("bits", 0x1d00ffff)
    now = int(time.time())

    valid_input = {
        "txid": "a" * 64,
        "vout": 0,
        "scriptSig": "",
        "sequence": 0xFFFFFFFF,
    }
    valid_output = {"value": 5000000000, "scriptPubKey": "OP_DUP OP_HASH160 abcd OP_EQUALVERIFY OP_CHECKSIG"}
    tx = make_tx([valid_input], [valid_output])

    cases: list[dict[str, Any]] = []

    # 1. Wrong prev_hash
    cases.append(
        {
            "name": "wrong_prev_hash",
            "block": make_block("f" * 64, "0" * 64, now, bits, 0, [tx]),
            "should_reject": True,
        }
    )

    # 2. Future timestamp (+2 hours)
    cases.append(
        {
            "name": "future_timestamp",
            "block": make_block(prev_hash, "0" * 64, now + 7200, bits, 0, [tx]),
            "should_reject": True,
        }
    )

    # 3. Difficulty mismatch (too easy)
    cases.append(
        {
            "name": "difficulty_too_low",
            "block": make_block(prev_hash, "0" * 64, now, 0x207fffff, 0, [tx]),
            "should_reject": True,
        }
    )

    # 4. Double-spend inside block (same input used twice)
    tx1 = make_tx([valid_input], [{"value": 2500000000, "scriptPubKey": ""}])
    tx2 = make_tx([valid_input], [{"value": 2500000000, "scriptPubKey": ""}])
    cases.append(
        {
            "name": "double_spend_inside_block",
            "block": make_block(prev_hash, "0" * 64, now, bits, 0, [tx1, tx2]),
            "should_reject": True,
        }
    )

    # 5. Invalid signature (scriptSig is garbage)
    bad_input = {
        "txid": "b" * 64,
        "vout": 0,
        "scriptSig": "INVALID_SIG_GARBAGE",
        "sequence": 0xFFFFFFFF,
    }
    bad_tx = make_tx([bad_input], [valid_output])
    cases.append(
        {
            "name": "invalid_signature",
            "block": make_block(prev_hash, "0" * 64, now, bits, 0, [bad_tx]),
            "should_reject": True,
        }
    )

    # 6. Oversized block (many large transactions)
    huge_txs = []
    for _ in range(2000):
        out = [{"value": 1, "scriptPubKey": "0" * 1000}]
        huge_txs.append(make_tx([{"txid": "c" * 64, "vout": 0, "scriptSig": "", "sequence": 0}], out))
    cases.append(
        {
            "name": "oversized_block",
            "block": make_block(prev_hash, "0" * 64, now, bits, 0, huge_txs),
            "should_reject": True,
        }
    )

    # 7. Zero transactions (empty block)
    cases.append(
        {
            "name": "empty_block",
            "block": make_block(prev_hash, "0" * 64, now, bits, 0, []),
            "should_reject": True,
        }
    )

    # 8. Negative timestamp
    cases.append(
        {
            "name": "negative_timestamp",
            "block": make_block(prev_hash, "0" * 64, -1, bits, 0, [tx]),
            "should_reject": True,
        }
    )

    return cases


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def main() -> int:
    parser = argparse.ArgumentParser(description="Test block validation rejection.")
    parser.add_argument("--rpc-url", default="http://127.0.0.1:8332", help="Node RPC URL")
    parser.add_argument("--user", default="", help="RPC username")
    parser.add_argument("--password", default="", help="RPC password")
    parser.add_argument("--output", default="tools/REVERSE/block-validation-report.json", help="Output path")
    args = parser.parse_args()

    auth = (args.user, args.password) if args.user or args.password else None

    log_info("Querying node info …")
    info = rpc_call(args.rpc_url, "getblockchaininfo", auth=auth)
    if "error" in info and info["error"] is not None:
        log_fail(f"RPC getblockchaininfo failed: {info['error']}")
        return 1
    node_info = info.get("result", {})

    cases = malformed_blocks(node_info)
    log_info(f"Testing {len(cases)} malformed block variants …")

    results: list[dict[str, Any]] = []
    for case in cases:
        log_info(f"Case: {case['name']}")
        resp = rpc_call(args.rpc_url, "submitblock", [json.dumps(case["block"])], auth=auth)
        error = resp.get("error")
        rejected = error is not None

        if case["should_reject"] and rejected:
            log_pass(f"  Correctly rejected: {error}")
        elif case["should_reject"] and not rejected:
            log_fail(f"  NOT rejected — potential vulnerability! result={resp.get('result')}")
        elif not case["should_reject"] and rejected:
            log_warn(f"  Unexpected rejection: {error}")
        else:
            log_pass("  Accepted as expected")

        results.append(
            {
                "name": case["name"],
                "should_reject": case["should_reject"],
                "rejected": rejected,
                "error": error,
                "result": resp.get("result"),
            }
        )

    report = {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "rpc_url": args.rpc_url,
        "cases": len(cases),
        "rejections_as_expected": sum(
            1 for r in results if r["should_reject"] == r["rejected"]
        ),
        "results": results,
    }

    out_path = os.path.abspath(args.output)
    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    with open(out_path, "w", encoding="utf-8") as fh:
        json.dump(report, fh, indent=2)

    log_pass(f"Report written to {out_path}")
    failed = sum(1 for r in results if r["should_reject"] and not r["rejected"])
    if failed:
        log_fail(f"{failed} malformed blocks were NOT rejected — review needed")
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
