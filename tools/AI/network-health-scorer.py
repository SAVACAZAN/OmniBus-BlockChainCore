#!/usr/bin/env python3
"""
OmniBus Blockchain Core — Network Health Scorer

Scoring model: peer count, block propagation time, mempool size -> health score 0-100.
Outputs: health-score.json
"""

import argparse
import json
import sys
from typing import Any, Dict

GREEN = "\033[92m"
RED = "\033[91m"
YELLOW = "\033[93m"
RESET = "\033[0m"


def cprint(color: str, msg: str) -> None:
    print(f"{color}{msg}{RESET}")


def compute_health(peer_count: int, propagation_ms: float, mempool_size: int) -> Dict[str, Any]:
    # Peer score: 0 peers = 0, 8+ peers = 40
    peer_score = min(40, peer_count * 5)

    # Propagation score: <100ms = 30, >1000ms = 0
    prop_score = max(0, 30 - int((max(0, propagation_ms - 100)) / 30))

    # Mempool score: 0 txs = 0, 1000+ txs = 30
    mempool_score = min(30, mempool_size // 33)

    total = peer_score + prop_score + mempool_score
    status = "HEALTHY" if total >= 80 else "DEGRADED" if total >= 50 else "CRITICAL"
    return {
        "peer_count": peer_count,
        "propagation_ms": propagation_ms,
        "mempool_size": mempool_size,
        "peer_score": peer_score,
        "propagation_score": prop_score,
        "mempool_score": mempool_score,
        "total_score": total,
        "status": status,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Score OmniBus network health")
    parser.add_argument("--peers", type=int, default=8, help="Number of connected peers")
    parser.add_argument("--propagation-ms", type=float, default=150, help="Block propagation time ms")
    parser.add_argument("--mempool", type=int, default=1200, help="Mempool transaction count")
    parser.add_argument("--output", default="health-score.json", help="Output JSON path")
    args = parser.parse_args()

    cprint(GREEN, "=== OmniBus Network Health Scorer ===")
    report = compute_health(args.peers, args.propagation_ms, args.mempool)

    color = GREEN if report["status"] == "HEALTHY" else YELLOW if report["status"] == "DEGRADED" else RED
    cprint(color, f"Score: {report['total_score']}/100 ({report['status']})")
    cprint(YELLOW, f"  Peers: {report['peer_score']} pts | Propagation: {report['propagation_score']} pts | Mempool: {report['mempool_score']} pts")

    with open(args.output, "w", encoding="utf-8") as f:
        json.dump(report, f, indent=2)
    cprint(GREEN, f"\nReport written to {args.output}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
