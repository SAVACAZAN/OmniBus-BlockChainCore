#!/usr/bin/env python3
"""
OmniBus Blockchain Core — Shard Balance Analyzer

Analyzes load distribution across 4 shards.
Outputs: shard-balance.json
"""

import argparse
import json
import math
import sys
from typing import Any, Dict, List

GREEN = "\033[92m"
RED = "\033[91m"
YELLOW = "\033[93m"
RESET = "\033[0m"


def cprint(color: str, msg: str) -> None:
    print(f"{color}{msg}{RESET}")


def analyze_shards(txs_per_shard: List[int]) -> Dict[str, Any]:
    n = len(txs_per_shard)
    total = sum(txs_per_shard)
    avg = total / n if n > 0 else 0
    variance = sum((x - avg) ** 2 for x in txs_per_shard) / n if n > 0 else 0
    stddev = math.sqrt(variance)
    cv = (stddev / avg * 100) if avg > 0 else 0

    max_shard = max(txs_per_shard) if txs_per_shard else 0
    min_shard = min(txs_per_shard) if txs_per_shard else 0
    imbalance = ((max_shard - min_shard) / avg * 100) if avg > 0 else 0

    shards = []
    for i, count in enumerate(txs_per_shard):
        shards.append({"shard_id": i, "tx_count": count, "share_pct": round(count / total * 100, 2) if total else 0})

    return {
        "shards": shards,
        "total_transactions": total,
        "average_per_shard": round(avg, 2),
        "stddev": round(stddev, 2),
        "coefficient_of_variation_pct": round(cv, 2),
        "imbalance_pct": round(imbalance, 2),
        "balanced": cv < 20.0,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Analyze shard load balance")
    parser.add_argument("--input", help="JSON file with {'shards': [tx_count, ...]}")
    parser.add_argument("--output", default="shard-balance.json", help="Output JSON path")
    args = parser.parse_args()

    if args.input:
        with open(args.input, "r", encoding="utf-8") as f:
            data = json.load(f)
        txs = data.get("shards", [])
    else:
        # Default synthetic distribution
        txs = [2450, 2380, 2600, 2570]

    report = analyze_shards(txs)

    cprint(GREEN, "=== OmniBus Shard Balance Analyzer ===")
    for sh in report["shards"]:
        cprint(YELLOW, f"  Shard {sh['shard_id']}: {sh['tx_count']} txs ({sh['share_pct']}%)")
    status_color = GREEN if report["balanced"] else RED
    cprint(status_color, f"CV={report['coefficient_of_variation_pct']}% Imbalance={report['imbalance_pct']}% -> {'BALANCED' if report['balanced'] else 'UNBALANCED'}")

    with open(args.output, "w", encoding="utf-8") as f:
        json.dump(report, f, indent=2)
    cprint(GREEN, f"\nReport written to {args.output}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
