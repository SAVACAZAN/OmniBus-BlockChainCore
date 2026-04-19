#!/usr/bin/env python3
"""
OmniBus Blockchain Core — Casper FFG Finality Checker

Verifies checkpoint justification and finalization across epochs.
"""

import argparse
import json
import sys
from typing import Any, Dict, List

GREEN = "\033[92m"
RED = "\033[91m"
YELLOW = "\033[93m"
RESET = "\033[0m"


def cprint(color: str, msg: str) -> None:
    print(f"{color}{msg}{RESET}")


def check_finality(checkpoints: List[Dict[str, Any]]) -> Dict[str, Any]:
    """Given checkpoints with {epoch, hash, votes, justified, finalized}, verify Casper rules."""
    results: List[Dict[str, Any]] = []
    last_justified = -1
    last_finalized = -1

    for cp in sorted(checkpoints, key=lambda x: x["epoch"]):
        epoch = cp["epoch"]
        votes = cp.get("votes", 0)
        threshold = cp.get("threshold", 100)
        justified = votes >= threshold
        finalized = False

        # Finalization rule: two consecutive justified checkpoints
        if justified and last_justified == epoch - 1:
            finalized = True

        cp_result = {
            "epoch": epoch,
            "hash": cp["hash"],
            "votes": votes,
            "threshold": threshold,
            "justified": justified,
            "finalized": finalized,
        }
        results.append(cp_result)

        if justified:
            last_justified = epoch
        if finalized:
            last_finalized = epoch

    return {
        "checkpoints": results,
        "last_justified_epoch": last_justified,
        "last_finalized_epoch": last_finalized,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Check Casper FFG finality")
    parser.add_argument("--input", required=True, help="JSON file with checkpoints list")
    parser.add_argument("--output", default="finality-report.json", help="Output JSON path")
    args = parser.parse_args()

    with open(args.input, "r", encoding="utf-8") as f:
        data = json.load(f)
    checkpoints = data.get("checkpoints", [])

    cprint(GREEN, "=== OmniBus Finality Checker ===")
    report = check_finality(checkpoints)

    cprint(YELLOW, f"Checkpoints analyzed: {len(report['checkpoints'])}")
    cprint(GREEN if report["last_finalized_epoch"] >= 0 else RED,
           f"Last justified epoch: {report['last_justified_epoch']}")
    cprint(GREEN if report["last_finalized_epoch"] >= 0 else RED,
           f"Last finalized epoch: {report['last_finalized_epoch']}")

    with open(args.output, "w", encoding="utf-8") as f:
        json.dump(report, f, indent=2)
    cprint(GREEN, f"\nReport written to {args.output}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
