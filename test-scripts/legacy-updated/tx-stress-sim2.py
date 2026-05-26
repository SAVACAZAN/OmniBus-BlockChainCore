#!/usr/bin/env python3
"""
tx-stress-sim2.py — Long-running TX simulation (multi-chain, advanced).

Updated 2026-05-10: --chain flag, public-VPS endpoints, default read-only.

Levels
------
  L0 — base load   :  2 tx / 30s
  L1 — light       :  3 tx / 8s
  L2 — moderate    : 15 tx / 10s
  L3 — stress      : 50 tx / 10s   (300 tx/min)
  L4 — extreme     : 100 tx / 8s   (750 tx/min)

Usage
-----
  python tx-stress-sim2.py --level 0 --duration 1h
  python tx-stress-sim2.py --chain testnet --level 1 --duration 24h
  python tx-stress-sim2.py --chain regtest --level 3 --duration 30m --burst-mode --write

  # Public VPS testnet (needs token):
  export OMNIBUS_RPC_TOKEN=...
  python tx-stress-sim2.py --chain testnet --level 1 --duration 1h --write
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

BASE_RECIPIENTS = [
    "ob1qzhrauq0xe9hg033ccup7vlgsdmj6kcxyza9zp0",  # rank 2 — savacazan.omnibus
    "ob1qvetjtq3swujv0jqsmw0gq84fymtfuaz5p5cjdv",  # rank 3 — testnet faucet
    "ob1qpjt7gngkj79663a298schx6dkjxqf37hwfggw2",
    "ob1qqcmwu5txqt5m3wv6p3ugxp6a3q4jsntd0mxyxa",
    "ob1quax5e9hyyzmft2m2lzn735asswsw9gh4gtgess",
    "ob1qdpknh5kapc22fv6s7jv0ntj7kwepqf3hcq4jrj",
    "ob1q5stczt5xxxphedadlqej09f5hww22qhvrj2nln",
    "ob1q8wm5est4fft7mrj937sg9uyaz2nskgttf3ku5u",
    "ob1qcdep7azzrr8t3x8tgn9wp6p69fc884g8g80v09",
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
    0: LevelConfig("L0 base load",    2, 30.0, 1_000,  10_000, "2 tx / 30s, dust amounts."),
    1: LevelConfig("L1 light",        3,  8.0, 10_000, 100_000, "3 tx / 8s, mid amounts."),
    2: LevelConfig("L2 moderate",    15, 10.0, 10_000, 50_000,  "15 tx / 10s, fan-out."),
    3: LevelConfig("L3 stress",      50, 10.0,  1_000, 20_000,  "50 tx / 10s (300 tx/min)."),
    4: LevelConfig("L4 extreme",    100,  8.0,  1_000, 15_000,  "100 tx / 8s (750 tx/min)."),
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
    last_report_time: float = 0.0
    addr_stats: dict[str, int] = field(default_factory=dict)


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


def report(stats: Stats, rpc_url: str, token: str | None, detailed: bool = False) -> None:
    elapsed = time.time() - stats.started_at
    h, mp = chain_snapshot(rpc_url, token)
    blocks_added = (h - stats.height_at_start) if (h >= 0 and stats.height_at_start) else 0
    rate_per_min = stats.sent / max(1.0, elapsed / 60.0)
    accept_pct = 100.0 * stats.accepted / max(1, stats.sent)
    print(
        f"[REPORT t={int(elapsed)}s] "
        f"sent={stats.sent} accepted={stats.accepted} ({accept_pct:.1f}%) "
        f"rejected={stats.rejected} rpc_err={stats.rpc_errors} | "
        f"height={h} (+{blocks_added}) mempool={mp} | rate={rate_per_min:.2f} tx/min",
        flush=True,
    )
    if detailed and stats.addr_stats:
        top_addrs = sorted(stats.addr_stats.items(), key=lambda x: x[1], reverse=True)[:5]
        print("  Top 5 recipients:")
        for addr, count in top_addrs:
            short = addr[-12:] if len(addr) > 12 else addr
            print(f"    ...{short}: {count} tx", flush=True)


def main() -> int:
    p = argparse.ArgumentParser(description="OmniBus TX stress simulator (multi-chain, advanced).")
    p.add_argument("--level", type=int, default=0, choices=sorted(LEVELS.keys()))
    p.add_argument("--duration", default="1h")
    p.add_argument("--chain", default=os.environ.get("CHAIN", "mainnet"),
                   choices=list(CHAIN_URLS.keys()))
    p.add_argument("--rpc", default=None, help="Explicit RPC URL (overrides --chain).")
    p.add_argument("--token", default=os.environ.get("OMNIBUS_RPC_TOKEN"))
    p.add_argument("--report-every", type=int, default=30)
    p.add_argument("--seed", type=int, default=None)
    p.add_argument("--num-addresses", type=int, default=len(BASE_RECIPIENTS))
    p.add_argument("--detailed-stats", action="store_true")
    p.add_argument("--burst-mode", action="store_true")
    p.add_argument("--write", action="store_true",
                   help="Actually submit TXs. Default = read-only liveness probe.")
    args = p.parse_args()

    if args.seed is not None:
        random.seed(args.seed)

    n_addr = max(1, min(args.num_addresses, len(BASE_RECIPIENTS)))
    if args.num_addresses > len(BASE_RECIPIENTS):
        print(f"[WARN] --num-addresses={args.num_addresses} > pool size {len(BASE_RECIPIENTS)}; "
              f"clamping to {n_addr}", file=sys.stderr)
    recipient_pool = BASE_RECIPIENTS[:n_addr]

    rpc_url = args.rpc or CHAIN_URLS[args.chain]
    cfg = LEVELS[args.level]
    duration_s = parse_duration(args.duration)
    deadline = time.time() + duration_s

    stats = Stats()
    stats.last_report_time = time.time()

    h0, _ = chain_snapshot(rpc_url, args.token)
    if h0 < 0:
        print(f"ERROR: cannot reach RPC at {rpc_url} "
              f"(token {'set' if args.token else 'NOT set'})", file=sys.stderr)
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
        f"=== OmniBus TX stress sim2 (multi-chain) ===\n"
        f"  level:        {cfg.name} — {cfg.description}\n"
        f"  tx/round:     {cfg.tx_per_round}\n"
        f"  interval:     {cfg.round_interval_s}s\n"
        f"  amount:       {cfg.amount_min_sat}–{cfg.amount_max_sat} SAT\n"
        f"  duration:     {duration_s}s ({args.duration})\n"
        f"  chain:        {args.chain}\n"
        f"  rpc:          {rpc_url}\n"
        f"  auth:         {'Bearer (set)' if args.token else 'none (loopback only)'}\n"
        f"  start height: {h0}\n"
        f"  recipients:   {len(recipient_pool)} addresses (rotation)\n"
        f"  burst mode:   {'ON' if args.burst_mode else 'OFF'}\n"
        f"  mode:         {'WRITE' if args.write else 'READ-ONLY (liveness only)'}\n"
        f"  Ctrl+C to stop early.\n",
        flush=True,
    )

    last_report = time.time()
    round_start_time = time.time()

    while not stopping and time.time() < deadline:
        if args.burst_mode:
            for i in range(cfg.tx_per_round):
                if stopping:
                    break
                to_addr = random.choice(recipient_pool)
                if random.random() < 0.2:
                    amt = random.randint(cfg.amount_max_sat // 2, cfg.amount_max_sat)
                else:
                    amt = random.randint(cfg.amount_min_sat, max(cfg.amount_min_sat, cfg.amount_max_sat // 2))
                stats.sent += 1
                if args.write:
                    ok, info = send_one(rpc_url, to_addr, amt, args.token)
                    if ok:
                        stats.accepted += 1
                        stats.addr_stats[to_addr] = stats.addr_stats.get(to_addr, 0) + 1
                    else:
                        low = info.lower() if isinstance(info, str) else ""
                        if "rpc" in low or "connect" in low or "timeout" in low or "urlopen" in low:
                            stats.rpc_errors += 1
                        else:
                            stats.rejected += 1
                else:
                    h, _ = chain_snapshot(rpc_url, args.token)
                    if h > 0:
                        stats.accepted += 1
                    else:
                        stats.rpc_errors += 1
                if i and i % 10 == 0:
                    time.sleep(0.01)
            elapsed_round = time.time() - round_start_time
            sleep_left = cfg.round_interval_s - elapsed_round
            if sleep_left > 0:
                time.sleep(sleep_left)
            round_start_time = time.time()
        else:
            tx_interval = (cfg.round_interval_s / cfg.tx_per_round) if cfg.tx_per_round > 0 else cfg.round_interval_s
            for _ in range(cfg.tx_per_round):
                if stopping:
                    break
                to_addr = random.choice(recipient_pool)
                rand_choice = random.random()
                if rand_choice < 0.7:
                    amt = random.randint(cfg.amount_min_sat, cfg.amount_max_sat)
                elif rand_choice < 0.85:
                    upper = max(cfg.amount_max_sat + 1, int(cfg.amount_max_sat * 1.5))
                    amt = random.randint(cfg.amount_max_sat, upper)
                else:
                    amt = random.randint(max(1, cfg.amount_min_sat // 10), cfg.amount_min_sat)
                stats.sent += 1
                if args.write:
                    ok, info = send_one(rpc_url, to_addr, amt, args.token)
                    if ok:
                        stats.accepted += 1
                        stats.addr_stats[to_addr] = stats.addr_stats.get(to_addr, 0) + 1
                    else:
                        low = info.lower() if isinstance(info, str) else ""
                        if "rpc" in low or "connect" in low or "timeout" in low or "urlopen" in low:
                            stats.rpc_errors += 1
                        else:
                            stats.rejected += 1
                else:
                    h, _ = chain_snapshot(rpc_url, args.token)
                    if h > 0:
                        stats.accepted += 1
                    else:
                        stats.rpc_errors += 1
                time.sleep(tx_interval * 0.9)
        if time.time() - last_report >= args.report_every:
            report(stats, rpc_url, args.token, args.detailed_stats)
            last_report = time.time()

    print("\n=== FINAL REPORT ===")
    report(stats, rpc_url, args.token, True)
    elapsed = time.time() - stats.started_at
    accept_pct = 100.0 * stats.accepted / max(1, stats.sent)
    print(
        f"  duration:     {int(elapsed)}s\n"
        f"  sent:         {stats.sent}\n"
        f"  accepted:     {stats.accepted}\n"
        f"  rejected:     {stats.rejected}\n"
        f"  rpc errs:     {stats.rpc_errors}\n"
        f"  accept rate:  {accept_pct:.1f}%\n"
        f"  avg tx/min:   {stats.sent / max(1.0, elapsed / 60.0):.2f}\n",
        flush=True,
    )
    if stats.addr_stats:
        print("\n  Address distribution (top 10):")
        top_addrs = sorted(stats.addr_stats.items(), key=lambda x: x[1], reverse=True)[:10]
        for addr, count in top_addrs:
            short = addr[-12:] if len(addr) > 12 else addr
            pct = 100.0 * count / stats.sent
            print(f"    ...{short}: {count} tx ({pct:.1f}%)", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
