#!/usr/bin/env python3
"""
OmniBus BlockChainCore — Chain Growth Tracker
==============================================
Monitors the omnibus-chain.dat file size over time and logs growth
data to MONITORING/data/chain-growth.csv.  Calculates the growth rate
in bytes/hour and raises alerts when growth stops (node not mining)
or grows abnormally fast (possible spam / attack).

Uses only Python stdlib.

Usage:
    python chain-growth-tracker.py
    python chain-growth-tracker.py --chain-file ../../omnibus-chain.dat --interval 60
    python chain-growth-tracker.py --max-rate 50000000 --stale-minutes 30
"""

import argparse
import csv
import os
import sys
import time
from datetime import datetime
from pathlib import Path

# ── ANSI colours ─────────────────────────────────────────────────────
RESET   = "\033[0m"
BOLD    = "\033[1m"
DIM     = "\033[2m"
RED     = "\033[91m"
GREEN   = "\033[92m"
YELLOW  = "\033[93m"
CYAN    = "\033[96m"
MAGENTA = "\033[95m"
BG_RED  = "\033[41m"
WHITE   = "\033[97m"


def format_bytes(n: float) -> str:
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if abs(n) < 1024:
            return f"{n:.2f} {unit}"
        n /= 1024
    return f"{n:.2f} PB"


def ensure_csv(csv_path: Path):
    """Create CSV with header if it doesn't exist."""
    csv_path.parent.mkdir(parents=True, exist_ok=True)
    if not csv_path.exists():
        with open(csv_path, "w", newline="") as f:
            writer = csv.writer(f)
            writer.writerow(["timestamp", "epoch", "size_bytes", "delta_bytes", "rate_bytes_per_hour", "alert"])


def append_row(csv_path: Path, row: list):
    with open(csv_path, "a", newline="") as f:
        writer = csv.writer(f)
        writer.writerow(row)


def print_banner():
    print(f"{CYAN}{BOLD}")
    print("  ╔══════════════════════════════════════════╗")
    print("  ║   OmniBus Chain Growth Tracker           ║")
    print("  ╚══════════════════════════════════════════╝")
    print(f"{RESET}")


def main():
    parser = argparse.ArgumentParser(
        description="Track omnibus-chain.dat growth over time",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "Examples:\n"
            "  python chain-growth-tracker.py\n"
            "  python chain-growth-tracker.py --interval 30 --stale-minutes 15\n"
            "  python chain-growth-tracker.py --chain-file /data/omnibus-chain.dat"
        ),
    )
    script_dir = Path(__file__).resolve().parent
    default_chain = script_dir.parent.parent / "omnibus-chain.dat"

    parser.add_argument("--chain-file", type=str, default=str(default_chain),
                        help=f"Path to chain data file (default: {default_chain})")
    parser.add_argument("--interval", type=int, default=60,
                        help="Check interval in seconds (default: 60)")
    parser.add_argument("--max-rate", type=int, default=100_000_000,
                        help="Max acceptable growth rate bytes/hour before alert (default: 100MB/h)")
    parser.add_argument("--stale-minutes", type=int, default=20,
                        help="Minutes without growth before stale alert (default: 20)")
    parser.add_argument("--csv-output", type=str, default=None,
                        help="CSV output path (default: MONITORING/data/chain-growth.csv)")
    args = parser.parse_args()

    chain_path = Path(args.chain_file)
    csv_path = Path(args.csv_output) if args.csv_output else (script_dir / "data" / "chain-growth.csv")

    print_banner()
    print(f"  {CYAN}Chain file:{RESET}   {chain_path}")
    print(f"  {CYAN}CSV output:{RESET}   {csv_path}")
    print(f"  {CYAN}Interval:{RESET}     {args.interval}s")
    print(f"  {CYAN}Max rate:{RESET}     {format_bytes(args.max_rate)}/h")
    print(f"  {CYAN}Stale after:{RESET}  {args.stale_minutes} min")
    print(f"{DIM}{'─' * 55}{RESET}")

    if not chain_path.exists():
        print(f"  {YELLOW}WARNING:{RESET} Chain file not found yet: {chain_path}")
        print(f"  {DIM}Will start tracking once the file appears.{RESET}")

    ensure_csv(csv_path)

    prev_size = None
    prev_time = None
    last_growth_time = time.time()
    sample_count = 0

    try:
        while True:
            now = time.time()
            timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")

            if not chain_path.exists():
                print(f"  {DIM}[{timestamp}]{RESET} {YELLOW}Waiting for chain file...{RESET}")
                time.sleep(args.interval)
                continue

            current_size = chain_path.stat().st_size
            sample_count += 1

            delta = 0
            rate = 0.0
            alert = ""

            if prev_size is not None and prev_time is not None:
                delta = current_size - prev_size
                elapsed_hours = (now - prev_time) / 3600.0
                rate = delta / elapsed_hours if elapsed_hours > 0 else 0

                if delta > 0:
                    last_growth_time = now

                # Check stale
                minutes_since_growth = (now - last_growth_time) / 60.0
                if minutes_since_growth >= args.stale_minutes:
                    alert = "STALE"
                    print(f"  {BG_RED}{WHITE}{BOLD} ALERT {RESET} {RED}No chain growth for {minutes_since_growth:.0f} min — node may not be mining!{RESET}")
                # Check explosion
                elif rate > args.max_rate:
                    alert = "RAPID_GROWTH"
                    print(f"  {BG_RED}{WHITE}{BOLD} ALERT {RESET} {RED}Abnormal growth rate: {format_bytes(rate)}/h — possible spam attack!{RESET}")

            # Log to CSV
            append_row(csv_path, [timestamp, int(now), current_size, delta, f"{rate:.2f}", alert])

            # Print status line
            delta_str = f"+{format_bytes(delta)}" if delta > 0 else f"{format_bytes(delta)}"
            delta_colour = GREEN if delta > 0 else (YELLOW if delta == 0 else RED)
            rate_str = format_bytes(abs(rate))

            print(
                f"  {DIM}[{timestamp}]{RESET}  "
                f"Size: {BOLD}{format_bytes(current_size)}{RESET}  "
                f"Delta: {delta_colour}{delta_str}{RESET}  "
                f"Rate: {MAGENTA}{rate_str}/h{RESET}  "
                f"{'  ' + RED + alert + RESET if alert else ''}"
            )

            prev_size = current_size
            prev_time = now
            time.sleep(args.interval)

    except KeyboardInterrupt:
        print(f"\n{YELLOW}Tracker stopped after {sample_count} samples.{RESET}")
        print(f"{DIM}Data saved to: {csv_path}{RESET}")
        sys.exit(0)


if __name__ == "__main__":
    main()
