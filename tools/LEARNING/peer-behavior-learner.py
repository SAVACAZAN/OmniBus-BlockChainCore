#!/usr/bin/env python3
"""
peer-behavior-learner.py

Learn from peer scoring history to identify malicious patterns and
 optimize peer scoring weights.

Scans:
  - core/peer_scoring.zig (if present) for constants / weights
  - tools/LEARNING/data/peer-scores.jsonl for historical records
  - RPC getpeerinfo for live peer data

Outputs: peer-behavior-model.json
"""

import argparse
import glob
import json
import os
import random
import re
import sys
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path
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
# Data ingestion
# ---------------------------------------------------------------------------
def load_peer_score_jsonl(data_dir: str) -> list[dict[str, Any]]:
    records: list[dict[str, Any]] = []
    pattern = os.path.join(data_dir, "*.jsonl")
    for fpath in glob.glob(pattern):
        with open(fpath, "r", encoding="utf-8", errors="replace") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    records.append(json.loads(line))
                except json.JSONDecodeError:
                    continue
    return records


def fetch_live_peers(rpc_url: str, auth: tuple[str, str] | None = None) -> list[dict[str, Any]]:
    payload = {"jsonrpc": "2.0", "method": "getpeerinfo", "id": random.randint(1, 100000)}
    try:
        resp = requests.post(rpc_url, json=payload, auth=auth, timeout=10.0)
        result = resp.json().get("result", [])
        if isinstance(result, list):
            return result
    except Exception as exc:
        log_warn(f"RPC getpeerinfo failed: {exc}")
    return []


def parse_scoring_weights(repo_path: str) -> dict[str, Any]:
    """Extract heuristic weights from peer_scoring.zig if available."""
    fpath = os.path.join(repo_path, "core", "peer_scoring.zig")
    if not os.path.isfile(fpath):
        return {}
    text = Path(fpath).read_text(encoding="utf-8", errors="replace")
    weights: dict[str, Any] = {}
    for m in re.finditer(r"(\w+)\s*[=:]\s*(\d+)", text):
        key, val = m.group(1), int(m.group(2))
        if any(k in key.lower() for k in ["score", "weight", "penalt", "ban", "threshold"]):
            weights[key] = val
    return weights


# ---------------------------------------------------------------------------
# Learning
# ---------------------------------------------------------------------------
def analyze_records(records: list[dict[str, Any]]) -> dict[str, Any]:
    peer_stats: dict[str, dict[str, Any]] = defaultdict(
        lambda: {"events": 0, "penalties": 0, "last_score": None, "reasons": defaultdict(int)}
    )

    for rec in records:
        peer_id = rec.get("peer_id") or rec.get("id") or rec.get("addr", "unknown")
        stats = peer_stats[peer_id]
        stats["events"] += 1
        score = rec.get("score")
        if score is not None:
            if stats["last_score"] is not None and score < stats["last_score"]:
                stats["penalties"] += 1
                reason = rec.get("reason", "unknown")
                stats["reasons"][reason] += 1
            stats["last_score"] = score

    # Identify malicious patterns
    malicious: list[dict[str, Any]] = []
    for peer_id, stats in peer_stats.items():
        if stats["penalties"] >= 3:
            top_reason = max(stats["reasons"].items(), key=lambda kv: kv[1])[0] if stats["reasons"] else "unknown"
            malicious.append(
                {
                    "peer_id": peer_id,
                    "total_events": stats["events"],
                    "penalties": stats["penalties"],
                    "top_reason": top_reason,
                }
            )

    # Optimize weights (simple heuristic: increase weight for top penalty reasons)
    global_reasons: dict[str, int] = defaultdict(int)
    for stats in peer_stats.values():
        for reason, count in stats["reasons"].items():
            global_reasons[reason] += count

    optimized_weights: dict[str, float] = {}
    total = sum(global_reasons.values()) or 1
    for reason, count in global_reasons.items():
        optimized_weights[reason] = round(count / total, 4)

    return {
        "peers_observed": len(peer_stats),
        "malicious_peers_detected": len(malicious),
        "malicious_list": malicious,
        "penalty_reason_distribution": dict(global_reasons),
        "optimized_weight_map": optimized_weights,
    }


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def main() -> int:
    parser = argparse.ArgumentParser(description="Learn peer behavior patterns.")
    parser.add_argument("--repo", default=".", help="Repository path")
    parser.add_argument("--data-dir", default="tools/LEARNING/data", help="JSONL data directory")
    parser.add_argument("--rpc-url", default="", help="Optional RPC URL for live peers")
    parser.add_argument("--user", default="", help="RPC user")
    parser.add_argument("--password", default="", help="RPC password")
    parser.add_argument("--output", default="tools/LEARNING/peer-behavior-model.json", help="Output path")
    args = parser.parse_args()

    repo = os.path.abspath(args.repo)
    data_dir = os.path.join(repo, args.data_dir)

    log_info("Loading historical peer score records …")
    records = load_peer_score_jsonl(data_dir)
    log_info(f"Loaded {len(records)} records")

    if args.rpc_url:
        auth = (args.user, args.password) if args.user or args.password else None
        live = fetch_live_peers(args.rpc_url, auth)
        log_info(f"Live peers fetched: {len(live)}")
        records.extend(live)

    weights = parse_scoring_weights(repo)
    log_info(f"Scoring weights from source: {len(weights)}")

    analysis = analyze_records(records)
    analysis["static_weights_from_code"] = weights

    report = {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "records_processed": len(records),
        "analysis": analysis,
    }

    out_path = os.path.join(repo, args.output)
    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    with open(out_path, "w", encoding="utf-8") as fh:
        json.dump(report, fh, indent=2)

    log_pass(f"Peer behavior model written to {out_path}")
    log_info(f"Malicious peers detected: {analysis['malicious_peers_detected']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
