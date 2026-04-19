#!/usr/bin/env python3
"""
consensus-evolution-analyzer.py

Analyze how the consensus layer changed over time using on-chain data
 queried via RPC or simulation:
  - Real block times vs target (10 s)
  - Difficulty adjustment correctness / oscillation
  - Fork frequency

Outputs: consensus-health-over-time.json
"""

import argparse
import json
import math
import os
import random
import sys
import time
from collections import defaultdict
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
# RPC helpers
# ---------------------------------------------------------------------------
def rpc(url: str, method: str, params: Any = None, auth: tuple[str, str] | None = None, timeout: float = 10.0) -> Any:
    payload = {"jsonrpc": "2.0", "method": method, "id": random.randint(1, 100000)}
    if params is not None:
        payload["params"] = params
    try:
        resp = requests.post(url, json=payload, auth=auth, timeout=timeout)
        data = resp.json()
        return data.get("result")
    except Exception as exc:
        return {"_error": str(exc)}


def fetch_block_headers(url: str, count: int, auth: tuple[str, str] | None = None) -> list[dict[str, Any]]:
    """Fetch the last *count* block headers via RPC."""
    info = rpc(url, "getblockchaininfo", auth=auth)
    if isinstance(info, dict) and "_error" in info:
        return []
    height = info.get("blocks", 0)
    headers: list[dict[str, Any]] = []
    for h in range(max(0, height - count + 1), height + 1):
        hash_val = rpc(url, "getblockhash", [h], auth=auth)
        if isinstance(hash_val, dict) and "_error" in hash_val:
            continue
        block = rpc(url, "getblock", [hash_val], auth=auth)
        if isinstance(block, dict) and "_error" in block:
            continue
        headers.append(
            {
                "height": block.get("height"),
                "hash": block.get("hash"),
                "time": block.get("time"),
                "bits": block.get("bits"),
                "difficulty": block.get("difficulty"),
                "previousblockhash": block.get("previousblockhash"),
            }
        )
    return headers


# ---------------------------------------------------------------------------
# Analysis
# ---------------------------------------------------------------------------
def analyze_headers(headers: list[dict[str, Any]], target_interval: float = 10.0) -> dict[str, Any]:
    if len(headers) < 2:
        return {"error": "Not enough blocks"}

    # Sort by height
    headers.sort(key=lambda x: x.get("height", 0))

    block_times: list[float] = []
    difficulties: list[float] = []
    for i in range(1, len(headers)):
        dt = headers[i]["time"] - headers[i - 1]["time"]
        block_times.append(dt)
        difficulties.append(headers[i].get("difficulty", 0.0))

    avg_block_time = sum(block_times) / len(block_times)
    min_bt = min(block_times)
    max_bt = max(block_times)
    std_bt = math.sqrt(sum((t - avg_block_time) ** 2 for t in block_times) / len(block_times))

    # Difficulty oscillation: variance of difficulty changes
    diff_changes = [difficulties[i] - difficulties[i - 1] for i in range(1, len(difficulties))]
    avg_diff_change = sum(diff_changes) / len(diff_changes) if diff_changes else 0.0
    diff_oscillation = math.sqrt(sum((d - avg_diff_change) ** 2 for d in diff_changes) / len(diff_changes)) if diff_changes else 0.0

    # Fork detection (same height, different hash) - not available from single node
    # We simulate a metric based on orphan probability
    fork_guess = sum(1 for t in block_times if t < target_interval / 2) / len(block_times)

    per_block = [
        {
            "height": headers[i]["height"],
            "block_time_sec": round(block_times[i - 1], 2),
            "difficulty": difficulties[i - 1],
        }
        for i in range(1, len(headers))
    ]

    return {
        "blocks_analyzed": len(headers),
        "target_interval_sec": target_interval,
        "average_block_time_sec": round(avg_block_time, 2),
        "min_block_time_sec": round(min_bt, 2),
        "max_block_time_sec": round(max_bt, 2),
        "stddev_block_time": round(std_bt, 2),
        "difficulty_oscillation": round(diff_oscillation, 4),
        "fork_probability_guess": round(fork_guess, 4),
        "per_block": per_block,
    }


def simulate_chain(num_blocks: int = 200, target_interval: float = 10.0) -> list[dict[str, Any]]:
    """Generate a synthetic chain for offline analysis."""
    headers: list[dict[str, Any]] = []
    t = int(time.time()) - num_blocks * target_interval
    diff = 1.0
    for h in range(num_blocks):
        # Variable block time with noise
        noise = random.gauss(0, target_interval * 0.3)
        bt = max(1.0, target_interval + noise)
        t += int(bt)
        diff *= target_interval / bt  # naive difficulty adjustment
        diff = max(0.1, diff)
        headers.append(
            {
                "height": h,
                "hash": f"simhash{h:06x}",
                "time": t,
                "bits": int(diff * 65535),
                "difficulty": round(diff, 4),
                "previousblockhash": f"simhash{h - 1:06x}" if h > 0 else "0" * 64,
            }
        )
    return headers


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def main() -> int:
    parser = argparse.ArgumentParser(description="Analyze consensus health over time.")
    parser.add_argument("--rpc-url", default="http://127.0.0.1:8332", help="Node RPC URL")
    parser.add_argument("--user", default="", help="RPC user")
    parser.add_argument("--password", default="", help="RPC password")
    parser.add_argument("--blocks", type=int, default=200, help="Blocks to analyze")
    parser.add_argument("--simulate", action="store_true", help="Run in simulation mode")
    parser.add_argument("--output", default="tools/LEARNING/consensus-health-over-time.json", help="Output path")
    args = parser.parse_args()

    if args.simulate:
        log_info("Running in simulation mode …")
        headers = simulate_chain(args.blocks)
    else:
        auth = (args.user, args.password) if args.user or args.password else None
        log_info(f"Fetching up to {args.blocks} block headers from {args.rpc_url} …")
        headers = fetch_block_headers(args.rpc_url, args.blocks, auth)
        if not headers:
            log_warn("No blocks fetched; falling back to simulation")
            headers = simulate_chain(args.blocks)

    analysis = analyze_headers(headers)

    report = {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "mode": "simulation" if args.simulate else "rpc",
        "analysis": analysis,
    }

    out_path = os.path.abspath(args.output)
    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    with open(out_path, "w", encoding="utf-8") as fh:
        json.dump(report, fh, indent=2)

    log_pass(f"Consensus health report written to {out_path}")
    if "average_block_time_sec" in analysis:
        log_info(f"Average block time: {analysis['average_block_time_sec']} s (target {analysis['target_interval_sec']} s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
