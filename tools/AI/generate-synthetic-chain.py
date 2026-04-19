#!/usr/bin/env python3
"""
OmniBus Blockchain Core — Synthetic Chain Generator

Generates synthetic blockchain data for ML model testing.
Outputs JSONL file with blocks and transactions.
"""

import argparse
import json
import random
import sys
from typing import Any, Dict, List

GREEN = "\033[92m"
RED = "\033[91m"
YELLOW = "\033[93m"
RESET = "\033[0m"


def cprint(color: str, msg: str) -> None:
    print(f"{color}{msg}{RESET}")


def generate_block(height: int, prev_hash: str, num_txs: int) -> Dict[str, Any]:
    txs = []
    for i in range(num_txs):
        txs.append({
            "txid": f"tx{height:06d}{i:04d}",
            "inputs": [{"prev": prev_hash, "vout": random.randint(0, 5)}],
            "outputs": [{"addr": f"om1{random.randint(0, 0xFFFF):04x}", "value": random.randint(1000, 500000)}],
            "fee": random.randint(100, 10000),
        })
    block = {
        "height": height,
        "hash": f"blk{height:08x}",
        "prev_hash": prev_hash,
        "timestamp": 1609459200 + height * 120 + random.randint(-30, 30),
        "difficulty": round(1.0 + height * 0.001 + random.gauss(0, 0.05), 4),
        "tx_count": num_txs,
        "transactions": txs,
    }
    return block


def generate_chain(num_blocks: int, output_path: str) -> None:
    prev = "0" * 64
    with open(output_path, "w", encoding="utf-8") as f:
        for h in range(num_blocks):
            num_txs = random.randint(100, 4000)
            block = generate_block(h, prev, num_txs)
            f.write(json.dumps(block) + "\n")
            prev = block["hash"]
            if h % 1000 == 0 and h > 0:
                cprint(YELLOW, f"Generated {h} blocks...")


def main() -> int:
    parser = argparse.ArgumentParser(description="Generate synthetic blockchain data")
    parser.add_argument("--blocks", type=int, default=10000, help="Number of blocks")
    parser.add_argument("--output", default="synthetic-chain.jsonl", help="Output JSONL path")
    args = parser.parse_args()

    cprint(GREEN, f"=== OmniBus Synthetic Chain Generator ===")
    generate_chain(args.blocks, args.output)
    cprint(GREEN, f"Generated {args.blocks} blocks -> {args.output}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
