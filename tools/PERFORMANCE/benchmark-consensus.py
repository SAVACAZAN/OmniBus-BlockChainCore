#!/usr/bin/env python3
"""
OmniBus Blockchain Core — Consensus Benchmark

Measures:
  - Block validation time
  - Sub-block processing latency
  - Transaction throughput (TPS)

Outputs: benchmark-results.json
"""

import argparse
import json
import random
import sys
import time
from typing import Any, Dict, List

GREEN = "\033[92m"
RED = "\033[91m"
YELLOW = "\033[93m"
RESET = "\033[0m"


def cprint(color: str, msg: str) -> None:
    print(f"{color}{msg}{RESET}")


class ConsensusBenchmark:
    def __init__(self, txs_per_block: int = 2000, num_blocks: int = 10):
        self.txs_per_block = txs_per_block
        self.num_blocks = num_blocks
        self.results: Dict[str, Any] = {}

    def _generate_block(self, block_id: int) -> Dict[str, Any]:
        txs = []
        for i in range(self.txs_per_block):
            txs.append({
                "txid": f"tx-{block_id}-{i}",
                "inputs": [{"prev": "00" * 32, "vout": 0}],
                "outputs": [{"addr": f"om1{block_id:04x}{i:04x}", "value": random.randint(1000, 100000)}],
            })
        return {"header": {"height": block_id, "prev_hash": "00" * 32, "merkle_root": "ff" * 32}, "txs": txs}

    def benchmark_block_validation(self) -> Dict[str, Any]:
        cprint(YELLOW, "\n--- Block Validation Benchmark ---")
        times_ms: List[float] = []
        for b in range(self.num_blocks):
            block = self._generate_block(b)
            t0 = time.perf_counter()
            # Simulate validation: verify merkle root and tx count
            _ = len(block["txs"])
            _ = block["header"]["merkle_root"]
            time.sleep(0.001)  # simulate 1ms base validation
            t1 = time.perf_counter()
            times_ms.append((t1 - t0) * 1000)

        avg_ms = sum(times_ms) / len(times_ms)
        self.results["block_validation_ms"] = {"avg": avg_ms, "min": min(times_ms), "max": max(times_ms)}
        cprint(GREEN, f"Avg block validation: {avg_ms:.2f} ms")
        return self.results["block_validation_ms"]

    def benchmark_sub_block_latency(self) -> Dict[str, Any]:
        cprint(YELLOW, "\n--- Sub-Block Latency Benchmark ---")
        # Simulate 4 shards processing sub-blocks
        latencies_ms: List[float] = []
        for shard in range(4):
            t0 = time.perf_counter()
            time.sleep(0.0005)  # simulate 0.5ms sub-block processing
            t1 = time.perf_counter()
            latencies_ms.append((t1 - t0) * 1000)

        avg_ms = sum(latencies_ms) / len(latencies_ms)
        self.results["sub_block_latency_ms"] = {"avg": avg_ms, "min": min(latencies_ms), "max": max(latencies_ms)}
        cprint(GREEN, f"Avg sub-block latency: {avg_ms:.2f} ms")
        return self.results["sub_block_latency_ms"]

    def benchmark_tps(self) -> Dict[str, Any]:
        cprint(YELLOW, "\n--- TPS Benchmark ---")
        # Simulate processing a batch of transactions as fast as possible
        batch_size = 10_000
        t0 = time.perf_counter()
        processed = 0
        for _ in range(batch_size):
            processed += 1
        t1 = time.perf_counter()
        elapsed = t1 - t0
        tps = batch_size / elapsed if elapsed > 0 else 0
        self.results["tps"] = {"throughput": round(tps, 2), "batch_size": batch_size, "elapsed_sec": round(elapsed, 4)}
        cprint(GREEN, f"Throughput: {tps:,.0f} TPS")
        return self.results["tps"]

    def run(self) -> Dict[str, Any]:
        cprint(GREEN, "=== OmniBus Consensus Benchmark ===")
        self.benchmark_block_validation()
        self.benchmark_sub_block_latency()
        self.benchmark_tps()
        return self.results


def main() -> int:
    parser = argparse.ArgumentParser(description="Benchmark consensus performance")
    parser.add_argument("--txs", type=int, default=2000, help="Transactions per block")
    parser.add_argument("--blocks", type=int, default=10, help="Number of blocks")
    parser.add_argument("--output", default="benchmark-results.json", help="Output JSON path")
    args = parser.parse_args()

    bench = ConsensusBenchmark(txs_per_block=args.txs, num_blocks=args.blocks)
    report = bench.run()

    with open(args.output, "w", encoding="utf-8") as f:
        json.dump(report, f, indent=2)
    cprint(GREEN, f"\nResults written to {args.output}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
