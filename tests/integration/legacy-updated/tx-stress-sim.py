#!/usr/bin/env python3
"""
tx-stress-sim.py — Long-running TX simulation for OmniBus (multi-chain).

Updated 2026-05-10: --chain flag, public-VPS endpoints, bearer token support.

Levels
------
  L0 — base load (1 tx every 60s). Forever-safe.
  L1 — light burst (1 tx every 10s).
  L2 — moderate burst (5 tx every 10s).
  L3 — stress (20 tx every 10s).

Usage
-----
  python tx-stress-sim.py --level 0 --duration 1h
  python tx-stress-sim.py --level 1 --duration 24h --chain testnet
  python tx-stress-sim.py --level 3 --duration 30m --chain regtest
  python tx-stress-sim.py --level 2 --duration 2h --rpc http://127.0.0.1:18332

Stops cleanly on Ctrl+C and prints a final report.

Note: this script defaults to READ-ONLY when --read-only or no --write flag is
given; in read-only mode it never calls `sendtransaction` — instead it just
polls `getblockcount` / `getmempoolinfo` to measure chain liveness. Use
--write to actually issue TXs (requires the node to hold the sender wallet).
"""
from __future__ import annotations

import argparse
import json
import os
import random
import signal
import sys
import time
import urllib.request
import urllib.error
from dataclasses import dataclass, field
from typing import Any


CHAIN_URLS = {
    "mainnet":       "https://omnibusblockchain.cc:8443/api-mainnet",
    "testnet":       "https://omnibusblockchain.cc:8443/api-testnet",
    "regtest":       "https://omnibusblockchain.cc:8443/api-regtest",
    "local-mainnet": "http://127.0.0.1:8332",
    "local-testnet": "http://127.0.0.1:18332",
    "local-regtest": "http://127.0.0.1:28332",
}

# Real testnet recipients (rotation pool).
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
    0: LevelConfig("L0 base load",  1, 60.0, 1_000_000, 10_000_000,
                   "1 tx / 60s, tiny amounts. Forever-safe."),
    1: LevelConfig("L1 light",      1, 10.0, 10_000_000, 100_000_000,
                   "1 tx / 10s, mid amounts."),
    2: LevelConfig("L2 moderate",   5, 10.0, 10_000_000, 50_000_000,
                   "5 tx / 10s, fan-out."),
    3: LevelConfig("L3 stress",    20, 10.0, 1_000_000, 20_000_000,
                   "20 tx / 10s. Race-test."),
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
    s = s.strip().lower()
    if s.endswith("h"): return int(float(s[:-1]) * 3600)
    if s.endswith("m"): return int(float(s[:-1]) * 60)
    if s.endswith("s"): return int(float(s[:-1]))
    return int(float(s))


def rpc(url: str, method: str, params: list[Any] | None = None,
        *, timeout: float = 5.0, token: str | None = None) -> Any:
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method,
                       "params": params or []}).encode()
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    req = urllib.request.Request(url, data=body, headers=headers)
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        data = json.loads(resp.read().decode())
    if "error" in data and data["error"]:
        raise RuntimeError(f"{method}: {data['error'].get('message', data['error'])}")
    return data.get("result")


def chain_snapshot(rpc_url: str, token: str | None) -> tuple[int, int]:
    try:
        h = int(rpc(rpc_url, "getblockcount", token=token))
    except Exception:
        return -1, -1
    mp = 0
    try:
        info = rpc(rpc_url, "getmempoolinfo", token=token)
        if isinstance(info, dict):
            mp = int(info.get("size", info.get("mempool_size", 0)))
    except Exception:
        pass
    return h, mp


def send_one(rpc_url: str, to_addr: str, amount_sat: int, token: str | None) -> tuple[bool, str]:
    try:
        result = rpc(rpc_url, "sendtransaction", [to_addr, amount_sat], token=token)
        if isinstance(result, dict) and result.get("status") == "accepted":
            return True, result.get("txid", "")
        return False, str(result)
    except Exception as e:
        return False, str(e)


def report(stats: Stats, rpc_url: str, token: str | None) -> None:
    elapsed = time.time() - stats.started_at
    h, mp = chain_snapshot(rpc_url, token)
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
    p = argparse.ArgumentParser(description="OmniBus TX stress simulator (multi-chain).")
    p.add_argument("--level", type=int, default=0, choices=sorted(LEVELS.keys()))
    p.add_argument("--duration", default="1h",
                   help="Run length: '1h', '24h', '30m', '90s'.")
    p.add_argument("--chain", default=os.environ.get("CHAIN", "mainnet"),
                   choices=list(CHAIN_URLS.keys()),
                   help="Endpoint preset. Default: mainnet.")
    p.add_argument("--rpc", default=None,
                   help="Explicit RPC URL (overrides --chain).")
    p.add_argument("--token", default=os.environ.get("OMNIBUS_RPC_TOKEN"),
                   help="Bearer token. Default: $OMNIBUS_RPC_TOKEN.")
    p.add_argument("--report-every", type=int, default=30)
    p.add_argument("--seed", type=int, default=None)
    p.add_argument("--write", action="store_true",
                   help="Actually submit TXs. Default = read-only liveness probe.")
    args = p.parse_args()

    if args.seed is not None:
        random.seed(args.seed)

    rpc_url = args.rpc or CHAIN_URLS[args.chain]
    cfg = LEVELS[args.level]
    duration_s = parse_duration(args.duration)
    deadline = time.time() + duration_s

    stats = Stats()
    h0, _ = chain_snapshot(rpc_url, args.token)
    if h0 < 0:
        print(f"ERROR: cannot reach RPC at {rpc_url}", file=sys.stderr)
        return 2
    stats.height_at_start = h0
    stats.last_height = h0

    stopping = False

    def on_sigint(_sig, _frame):
        nonlocal stopping
        if stopping:
            sys.exit(1)
        stopping = True
        print("\n[CTRL-C] stopping, final report below…", flush=True)

    signal.signal(signal.SIGINT, on_sigint)

    print(
        f"=== OmniBus TX stress sim (multi-chain) ===\n"
        f"  level:        {cfg.name} — {cfg.description}\n"
        f"  tx/round:     {cfg.tx_per_round}\n"
        f"  interval:     {cfg.round_interval_s}s\n"
        f"  amount:       {cfg.amount_min_sat}–{cfg.amount_max_sat} SAT\n"
        f"  duration:     {duration_s}s ({args.duration})\n"
        f"  chain:        {args.chain}\n"
        f"  rpc:          {rpc_url}\n"
        f"  auth:         {'Bearer (set)' if args.token else 'none (loopback only)'}\n"
        f"  start height: {h0}\n"
        f"  recipients:   {len(SAMPLE_RECIPIENTS)} addresses\n"
        f"  mode:         {'WRITE' if args.write else 'READ-ONLY (liveness only)'}\n"
        f"  Ctrl+C to stop early — final report on exit.\n",
        flush=True,
    )

    last_report = time.time()
    while not stopping and time.time() < deadline:
        for _ in range(cfg.tx_per_round):
            if stopping:
                break
            to_addr = random.choice(SAMPLE_RECIPIENTS)
            amt = random.randint(cfg.amount_min_sat, cfg.amount_max_sat)
            stats.sent += 1
            if args.write:
                ok, info = send_one(rpc_url, to_addr, amt, args.token)
                if ok:
                    stats.accepted += 1
                else:
                    low = info.lower() if isinstance(info, str) else ""
                    if "rpc" in low or "connect" in low or "timeout" in low:
                        stats.rpc_errors += 1
                    else:
                        stats.rejected += 1
            else:
                # Read-only liveness probe — count it as accepted iff RPC is up.
                h, _ = chain_snapshot(rpc_url, args.token)
                if h > 0:
                    stats.accepted += 1
                else:
                    stats.rpc_errors += 1

        if time.time() - last_report >= args.report_every:
            report(stats, rpc_url, args.token)
            last_report = time.time()

        end_round = time.time() + cfg.round_interval_s
        while not stopping and time.time() < end_round and time.time() < deadline:
            time.sleep(min(0.5, end_round - time.time()))

    print("\n=== FINAL REPORT ===")
    report(stats, rpc_url, args.token)
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
