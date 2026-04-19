#!/usr/bin/env python3
"""
OmniBus Blockchain Core — Difficulty Adjustment Simulator

Simulates difficulty adjustment given block times history.
Outputs predicted difficulty curve.
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


TARGET_BLOCK_TIME = 120  # seconds
DIFF_ADJUSTMENT_INTERVAL = 144  # blocks


def simulate_difficulty(block_times: List[float]) -> List[Dict[str, Any]]:
    """Given a list of block times, return difficulty per interval."""
    difficulties: List[Dict[str, Any]] = []
    current_diff = 1.0

    for i in range(0, len(block_times), DIFF_ADJUSTMENT_INTERVAL):
        interval = block_times[i : i + DIFF_ADJUSTMENT_INTERVAL]
        if len(interval) < 2:
            break
        avg_time = sum(interval) / len(interval)
        # Simple proportional adjustment
        adjustment = TARGET_BLOCK_TIME / avg_time if avg_time > 0 else 1.0
        adjustment = max(0.25, min(4.0, adjustment))  # limit adjustment factor
        current_diff *= adjustment
        difficulties.append({
            "interval_start": i,
            "interval_end": i + len(interval),
            "avg_block_time_sec": round(avg_time, 2),
            "adjustment_factor": round(adjustment, 4),
            "new_difficulty": round(current_diff, 4),
        })
    return difficulties


def generate_synthetic_history(num_blocks: int, noise_factor: float = 0.2) -> List[float]:
    times = []
    for i in range(num_blocks):
        base = TARGET_BLOCK_TIME
        noise = random.uniform(-noise_factor * base, noise_factor * base)
        trend = math.sin(i / 500.0) * 20  # periodic trend
        times.append(max(10, base + noise + trend))
    return times


def main() -> int:
    parser = argparse.ArgumentParser(description="Simulate difficulty adjustment")
    parser.add_argument("--blocks", type=int, default=1000, help="Number of blocks to simulate")
    parser.add_argument("--noise", type=float, default=0.2, help="Noise factor (0-1)")
    parser.add_argument("--input", help="JSON file with block_times list")
    parser.add_argument("--output", default="difficulty-curve.json", help="Output JSON path")
    args = parser.parse_args()

    import random

    if args.input:
        with open(args.input, "r", encoding="utf-8") as f:
            data = json.load(f)
        block_times = data["block_times"]
    else:
        block_times = generate_synthetic_history(args.blocks, args.noise)

    curve = simulate_difficulty(block_times)

    cprint(GREEN, "=== OmniBus Difficulty Simulator ===")
    cprint(YELLOW, f"Simulated {len(block_times)} blocks -> {len(curve)} adjustment intervals")
    for point in curve[:5]:
        cprint(GREEN, f"  blocks {point['interval_start']}-{point['interval_end']}: diff={point['new_difficulty']:.4f} (avg_time={point['avg_block_time_sec']}s)")
    if len(curve) > 5:
        cprint(YELLOW, f"  ... and {len(curve)-5} more intervals")

    with open(args.output, "w", encoding="utf-8") as f:
        json.dump({"target_block_time": TARGET_BLOCK_TIME, "curve": curve}, f, indent=2)
    cprint(GREEN, f"\nCurve written to {args.output}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
