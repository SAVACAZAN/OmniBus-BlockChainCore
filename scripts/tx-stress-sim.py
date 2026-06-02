#!/usr/bin/env python3
"""
tx-stress-sim.py — Long-running TX simulation for OmniBus testnet.

Purpose
-------
Run for 1 hour, 24 hours, or custom duration, generating a steady stream of
transactions across multiple "levels" so we can stress the chain without
hand-typing curl commands. Lets us watch:

  - mempool fill / drain behavior
  - block production rate when mempool is non-empty
  - balance propagation to fresh addresses
  - Rich List growth over time
  - faucet refill cadence
  - whether any TX gets silently dropped

Levels
------
  L0 — base load (1 tx every 60s, miner→miner). Produces organic chain traffic
       at a rate any healthy chain should handle for any duration.
  L1 — light burst (1 tx every 10s, between 4 derived addresses). Tests
       multi-address state updates and Rich List sorting.
  L2 — moderate burst (5 tx every 10s, fan-out from miner to 8 derived
       addresses). Tests mempool capacity at low rate.
  L3 — stress (20 tx every 10s, randomized small amounts). Designed to
       overlap multiple blocks and reveal locking / race issues.

Usage
-----
  python tx-stress-sim.py --level 0 --duration 1h
  python tx-stress-sim.py --level 1 --duration 24h
  python tx-stress-sim.py --level 2 --duration 30m --rpc http://127.0.0.1:18333
  python tx-stress-sim.py --level 3 --duration 2h --report-every 60

The script never touches keys directly — it calls `sendtransaction` RPC,
which signs with the node's wallet (OMNIBUS_MNEMONIC env). To stress-test
on the public VPS, set --rpc to https://omnibusblockchain.cc:8443/api-testnet.

Stops cleanly on Ctrl+C and prints a final report.
"""
from __future__ import annotations

import argparse
import json
import random
import signal
import sys
import time
import urllib.request
import urllib.error
from dataclasses import dataclass, field
from typing import Any


# ── Sample destinations (real testnet addresses derived from the project mnemonic).
# These are the user's wallets #1-#8 + #4 (sava). Keep this list short and
# rotate through it; goal is for Rich List to *grow* organically without
# hammering one address.
SAMPLE_RECIPIENTS = [
    "ob1q5stczt5xxxphedadlqej09f5hww22qhvrj2nln",  # #4 sava.omnibus
    "ob1q8wm5est4fft7mrj937sg9uyaz2nskgttf3ku5u",  # #1
    "ob1qpjt7gngkj79663a298schx6dkjxqf37hwfggw2",  # #2
    "ob1qqcmwu5txqt5m3wv6p3ugxp6a3q4jsntd0mxyxa",  # #3
    "ob1quax5e9hyyzmft2m2lzn735asswsw9gh4gtgess",  # #5
    "ob1qcdep7azzrr8t3x8tgn9wp6p69fc884g8g80v09",  # #6
    "ob1qdpknh5kapc22fv6s7jv0ntj7kwepqf3hcq4jrj",  # #8
    "ob1qvetjtq3swujv0jqsmw0gq84fymtfuaz5p5cjdv",  # #7 faucet
]


@dataclass
class LevelConfig:
    name: str
    tx_per_round: int
    round_interval_s: float
    amount_min_sat: int
    amount_max_sat: int
    description: str


LEVELS = {
    0: LevelConfig(
        name="L0 base load",
        tx_per_round=1,
        round_interval_s=60.0,
        amount_min_sat=1_000_000,        # 0.001 OMNI
        amount_max_sat=10_000_000,       # 0.01 OMNI
        description="1 tx / 60s, tiny amounts. Chain should run forever.",
    ),
    1: LevelConfig(
        name="L1 light",
        tx_per_round=1,
        round_interval_s=10.0,
        amount_min_sat=10_000_000,       # 0.01 OMNI
        amount_max_sat=100_000_000,      # 0.1 OMNI
        description="1 tx / 10s, mid amounts. Tests Rich List growth.",
    ),
    2: LevelConfig(
        name="L2 moderate",
        tx_per_round=5,
        round_interval_s=10.0,
        amount_min_sat=10_000_000,
        amount_max_sat=50_000_000,
        description="5 tx / 10s, fan-out. Tests mempool steady fill.",
    ),
    3: LevelConfig(
        name="L3 stress",
        tx_per_round=20,
        round_interval_s=10.0,
        amount_min_sat=1_000_000,
        amount_max_sat=20_000_000,
        description="20 tx / 10s. Designed to overlap blocks; race-test.",
    ),
}


@dataclass
class Stats:
    sent: int = 0
    accepted: int = 0
    rejected: int = 0
    rpc_errors: int = 0
    started_at: float = field(default_factory=time.time)
    last_height: int = 0
    last_mempool: int = 0
    height_at_start: int = 0


def parse_duration(s: str) -> int:
    """Accepts strings like '1h', '24h', '30m', '90s'. Returns seconds."""
    s = s.strip().lower()
    if s.endswith("h"):
        return int(float(s[:-1]) * 3600)
    if s.endswith("m"):
        return int(float(s[:-1]) * 60)
    if s.endswith("s"):
        return int(float(s[:-1]))
    return int(float(s))  # bare number = seconds


def rpc(url: str, method: str, params: list[Any] | None = None, *, timeout: float = 5.0) -> Any:
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params or []}).encode()
    req = urllib.request.Request(url, data=body, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        data = json.loads(resp.read().decode())
    if "error" in data and data["error"]:
        raise RuntimeError(f"{method}: {data['error'].get('message', data['error'])}")
    return data.get("result")


def chain_snapshot(rpc_url: str) -> tuple[int, int]:
    """(height, mempool_size). Returns (-1, -1) on RPC failure."""
    try:
        info = rpc(rpc_url, "getblockchaininfo")
        return int(info.get("blocks", 0)), int(info.get("mempool_size", 0))
    except Exception:
        return -1, -1


def send_one(rpc_url: str, to_addr: str, amount_sat: int) -> tuple[bool, str]:
    """Returns (accepted, txid_or_error)."""
    try:
        result = rpc(rpc_url, "sendtransaction", [to_addr, amount_sat])
        if isinstance(result, dict) and result.get("status") == "accepted":
            return True, result.get("txid", "")
        return False, str(result)
    except Exception as e:
        return False, str(e)


def report(stats: Stats, rpc_url: str) -> None:
    elapsed = time.time() - stats.started_at
    h, mp = chain_snapshot(rpc_url)
    blocks_added = h - stats.height_at_start if h >= 0 and stats.height_at_start else 0
    rate_sent = stats.sent / max(1.0, elapsed / 60.0)
    accept_pct = 100.0 * stats.accepted / max(1, stats.sent)
    print(
        f"[REPORT t={int(elapsed)}s] "
        f"sent={stats.sent} accepted={stats.accepted} ({accept_pct:.1f}%) "
        f"rejected={stats.rejected} rpc_err={stats.rpc_errors} | "
        f"height={h} (+{blocks_added}) mempool={mp} | rate={rate_sent:.2f} tx/min",
        flush=True,
    )


def main() -> int:
    p = argparse.ArgumentParser(description="OmniBus testnet TX stress simulator.")
    p.add_argument("--level", type=int, default=0, choices=sorted(LEVELS.keys()),
                   help="Load level (0–3). See LEVELS in source for details.")
    p.add_argument("--duration", default="1h",
                   help="Run length: '1h', '24h', '30m', '90s'. Default 1h.")
    p.add_argument("--rpc", default="http://127.0.0.1:18333",
                   help="RPC URL (default: PC testnet miner). Use https://omnibusblockchain.cc:8443/api-testnet for VPS.")
    p.add_argument("--report-every", type=int, default=30,
                   help="Print a status line every N seconds. Default 30.")
    p.add_argument("--seed", type=int, default=None,
                   help="Random seed for reproducibility.")
    args = p.parse_args()

    if args.seed is not None:
        random.seed(args.seed)

    cfg = LEVELS[args.level]
    duration_s = parse_duration(args.duration)
    deadline = time.time() + duration_s

    stats = Stats()
    h0, _ = chain_snapshot(args.rpc)
    if h0 < 0:
        print(f"ERROR: cannot reach RPC at {args.rpc}", file=sys.stderr)
        return 2
    stats.height_at_start = h0
    stats.last_height = h0

    # Clean shutdown on Ctrl+C: print a final report then exit.
    stopping = False

    def on_sigint(_sig, _frame):
        nonlocal stopping
        if stopping:
            sys.exit(1)
        stopping = True
        print("\n[CTRL-C] stopping, final report below…", flush=True)

    signal.signal(signal.SIGINT, on_sigint)

    print(
        f"=== OmniBus TX stress sim ===\n"
        f"  level:       {cfg.name} — {cfg.description}\n"
        f"  tx/round:    {cfg.tx_per_round}\n"
        f"  interval:    {cfg.round_interval_s}s\n"
        f"  amount:      {cfg.amount_min_sat}–{cfg.amount_max_sat} SAT\n"
        f"  duration:    {duration_s}s ({args.duration})\n"
        f"  rpc:         {args.rpc}\n"
        f"  start height:{h0}\n"
        f"  recipients:  {len(SAMPLE_RECIPIENTS)} addresses (rotation)\n"
        f"  Ctrl+C to stop early — final report on exit.\n",
        flush=True,
    )

    last_report = time.time()

    while not stopping and time.time() < deadline:
        # Send one round of TXs.
        for _ in range(cfg.tx_per_round):
            if stopping:
                break
            to_addr = random.choice(SAMPLE_RECIPIENTS)
            amt = random.randint(cfg.amount_min_sat, cfg.amount_max_sat)
            stats.sent += 1
            ok, info = send_one(args.rpc, to_addr, amt)
            if ok:
                stats.accepted += 1
            else:
                low = info.lower() if isinstance(info, str) else ""
                if "rpc" in low or "connect" in low or "timeout" in low:
                    stats.rpc_errors += 1
                else:
                    stats.rejected += 1
                # Don't spam the console; periodic report shows totals.

        # Periodic status line.
        if time.time() - last_report >= args.report_every:
            report(stats, args.rpc)
            last_report = time.time()

        # Sleep for the round interval, with a short tick so Ctrl+C is responsive.
        end_round = time.time() + cfg.round_interval_s
        while not stopping and time.time() < end_round and time.time() < deadline:
            time.sleep(min(0.5, end_round - time.time()))

    # Final report.
    print("\n=== FINAL REPORT ===")
    report(stats, args.rpc)
    elapsed = time.time() - stats.started_at
    print(
        f"  duration:  {int(elapsed)}s\n"
        f"  sent:      {stats.sent}\n"
        f"  accepted:  {stats.accepted}\n"
        f"  rejected:  {stats.rejected}\n"
        f"  rpc errs:  {stats.rpc_errors}\n",
        flush=True,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
