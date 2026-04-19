#!/usr/bin/env python3
"""
OmniBus Blockchain Core — Fork Detector

Detects chain forks from block headers and calculates reorg depth.
Outputs: fork-report.json
"""

import argparse
import json
import sys
from typing import Any, Dict, List, Optional, Set, Tuple

GREEN = "\033[92m"
RED = "\033[91m"
YELLOW = "\033[93m"
RESET = "\033[0m"


def cprint(color: str, msg: str) -> None:
    print(f"{color}{msg}{RESET}")


def detect_forks(headers: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
    """Given a list of headers with {hash, prev_hash, height}, detect forks."""
    by_height: Dict[int, List[str]] = {}
    hash_to_header: Dict[str, Dict[str, Any]] = {}
    for h in headers:
        height = h["height"]
        bh = h["hash"]
        by_height.setdefault(height, []).append(bh)
        hash_to_header[bh] = h

    forks: List[Dict[str, Any]] = []
    for height, hashes in by_height.items():
        if len(hashes) > 1:
            # Find common ancestor
            ancestors: List[Set[str]] = []
            for bh in hashes:
                chain = set()
                cur = bh
                while cur in hash_to_header:
                    chain.add(cur)
                    cur = hash_to_header[cur].get("prev_hash", "")
                ancestors.append(chain)
            common = set.intersection(*ancestors) if ancestors else set()
            common_ancestor = max(
                (hash_to_header[h]["height"] for h in common if h in hash_to_header),
                default=-1,
            )
            reorg_depth = height - common_ancestor if common_ancestor >= 0 else height
            forks.append({
                "height": height,
                " competing_heads": hashes,
                "common_ancestor_height": common_ancestor,
                "reorg_depth": reorg_depth,
            })
    return forks


def main() -> int:
    parser = argparse.ArgumentParser(description="Detect blockchain forks")
    parser.add_argument("--input", required=True, help="JSON file with block headers list")
    parser.add_argument("--output", default="fork-report.json", help="Output JSON path")
    args = parser.parse_args()

    with open(args.input, "r", encoding="utf-8") as f:
        data = json.load(f)
    headers = data.get("headers", [])

    cprint(GREEN, "=== OmniBus Fork Detector ===")
    forks = detect_forks(headers)

    if not forks:
        cprint(GREEN, "No forks detected.")
    else:
        cprint(RED, f"Detected {len(forks)} fork(s):")
        for fk in forks:
            cprint(YELLOW, f"  Height {fk['height']}: heads={fk[' competing_heads']}, reorg_depth={fk['reorg_depth']}")

    report = {"headers_analyzed": len(headers), "forks": forks}
    with open(args.output, "w", encoding="utf-8") as f:
        json.dump(report, f, indent=2)
    cprint(GREEN, f"\nReport written to {args.output}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
