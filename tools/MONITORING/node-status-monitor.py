#!/usr/bin/env python3
"""
OmniBus BlockChainCore — Node Status Monitor
=============================================
Polls the OmniBus node JSON-RPC endpoint every N seconds and displays
a live terminal dashboard showing block height, peer count, mempool
size, mining status, and uptime.

Uses only Python stdlib (http.client for JSON-RPC 2.0 over HTTP).

Usage:
    python node-status-monitor.py
    python node-status-monitor.py --host 192.168.1.50 --port 8332 --interval 5
"""

import argparse
import http.client
import json
import os
import sys
import time
from datetime import datetime, timedelta

# ── ANSI colours ─────────────────────────────────────────────────────
RESET   = "\033[0m"
BOLD    = "\033[1m"
DIM     = "\033[2m"
RED     = "\033[91m"
GREEN   = "\033[92m"
YELLOW  = "\033[93m"
CYAN    = "\033[96m"
MAGENTA = "\033[95m"
WHITE   = "\033[97m"
BG_BLUE = "\033[44m"


def clear_screen():
    os.system("cls" if os.name == "nt" else "clear")


def rpc_call(host: str, port: int, method: str, params=None, timeout: int = 5):
    """Send a JSON-RPC 2.0 request and return the result (or None on error)."""
    payload = json.dumps({
        "jsonrpc": "2.0",
        "id": 1,
        "method": method,
        "params": params or [],
    })
    try:
        conn = http.client.HTTPConnection(host, port, timeout=timeout)
        conn.request("POST", "/", body=payload, headers={
            "Content-Type": "application/json",
        })
        resp = conn.getresponse()
        data = json.loads(resp.read().decode())
        conn.close()
        if "result" in data:
            return data["result"]
        return None
    except Exception:
        return None


def format_bytes(n: int) -> str:
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if abs(n) < 1024:
            return f"{n:.1f} {unit}"
        n /= 1024
    return f"{n:.1f} PB"


def severity_colour(ok: bool) -> str:
    return GREEN if ok else RED


def render_dashboard(host: str, port: int, start_time: float, poll_count: int):
    """Fetch data and print dashboard."""
    now = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    uptime_delta = timedelta(seconds=int(time.time() - start_time))

    # ── RPC calls ────────────────────────────────────────────────────
    info        = rpc_call(host, port, "getblockchaininfo")
    net_info    = rpc_call(host, port, "getnetworkinfo")
    mempool     = rpc_call(host, port, "getmempoolinfo")
    mining      = rpc_call(host, port, "getmininginfo")
    node_info   = rpc_call(host, port, "getnodeinfo")

    node_online = info is not None

    # Extract values (fallback to "?" if RPC down)
    block_height = info.get("blocks", "?")         if info else "?"
    best_hash    = info.get("bestblockhash", "?")   if info else "?"
    chain        = info.get("chain", "?")           if info else "?"
    peers        = net_info.get("connections", "?")  if net_info else "?"
    mempool_size = mempool.get("size", "?")          if mempool else "?"
    mempool_bytes = mempool.get("bytes", 0)          if mempool else 0
    is_mining    = mining.get("mining", False)        if mining else False
    hashrate     = mining.get("hashrate", 0)          if mining else 0
    difficulty   = mining.get("difficulty", "?")      if mining else "?"
    node_id      = node_info.get("node_id", "?")     if node_info else "?"
    node_uptime  = node_info.get("uptime", "?")       if node_info else "?"

    # ── Render ───────────────────────────────────────────────────────
    clear_screen()

    print(f"{BG_BLUE}{BOLD}{WHITE} OmniBus Node Status Monitor {RESET}")
    print(f"{DIM}{'─' * 60}{RESET}")
    print(f"  {CYAN}Host:{RESET}  {host}:{port}    {CYAN}Time:{RESET}  {now}")
    print(f"  {CYAN}Monitor uptime:{RESET}  {uptime_delta}    {CYAN}Polls:{RESET}  {poll_count}")
    print(f"{DIM}{'─' * 60}{RESET}")

    status_label = f"{GREEN}ONLINE{RESET}" if node_online else f"{RED}OFFLINE{RESET}"
    print(f"  {BOLD}Node status:{RESET}   {status_label}")
    print(f"  {BOLD}Node ID:{RESET}       {node_id}")
    print(f"  {BOLD}Chain:{RESET}         {chain}")
    print(f"  {BOLD}Node uptime:{RESET}   {node_uptime}")
    print()

    # Block info
    print(f"  {MAGENTA}[Blockchain]{RESET}")
    print(f"    Block height :  {YELLOW}{block_height}{RESET}")
    print(f"    Best hash    :  {DIM}{str(best_hash)[:40]}...{RESET}" if len(str(best_hash)) > 40 else f"    Best hash    :  {DIM}{best_hash}{RESET}")
    print(f"    Difficulty   :  {difficulty}")
    print()

    # Network
    peers_ok = isinstance(peers, int) and peers > 0
    print(f"  {MAGENTA}[Network]{RESET}")
    print(f"    Peers        :  {severity_colour(peers_ok)}{peers}{RESET}")
    print()

    # Mempool
    print(f"  {MAGENTA}[Mempool]{RESET}")
    print(f"    Transactions :  {mempool_size}")
    print(f"    Size         :  {format_bytes(mempool_bytes) if isinstance(mempool_bytes, (int, float)) else '?'}")
    print()

    # Mining
    mining_label = f"{GREEN}ACTIVE{RESET}" if is_mining else f"{YELLOW}INACTIVE{RESET}"
    print(f"  {MAGENTA}[Mining]{RESET}")
    print(f"    Status       :  {mining_label}")
    print(f"    Hash rate    :  {hashrate} H/s")
    print()

    print(f"{DIM}{'─' * 60}{RESET}")
    if not node_online:
        print(f"  {RED}{BOLD}WARNING:{RESET} {RED}Cannot reach node RPC at {host}:{port}{RESET}")
        print(f"  {DIM}Ensure omnibus-node.exe is running and RPC is enabled.{RESET}")
    else:
        print(f"  {GREEN}All systems nominal.{RESET}")
    print(f"{DIM}  Press Ctrl+C to exit.{RESET}")


def main():
    parser = argparse.ArgumentParser(
        description="OmniBus Node Status Monitor — live terminal dashboard",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="Example:\n  python node-status-monitor.py --host 127.0.0.1 --port 8332 --interval 10",
    )
    parser.add_argument("--host", default="127.0.0.1", help="Node RPC host (default: 127.0.0.1)")
    parser.add_argument("--port", type=int, default=8332, help="Node RPC port (default: 8332)")
    parser.add_argument("--interval", type=int, default=10, help="Poll interval in seconds (default: 10)")
    args = parser.parse_args()

    start_time = time.time()
    poll_count = 0

    print(f"{CYAN}Starting OmniBus Node Status Monitor...{RESET}")
    print(f"{DIM}Target: {args.host}:{args.port}  Interval: {args.interval}s{RESET}")

    try:
        while True:
            poll_count += 1
            render_dashboard(args.host, args.port, start_time, poll_count)
            time.sleep(args.interval)
    except KeyboardInterrupt:
        print(f"\n{YELLOW}Monitor stopped.{RESET}")
        sys.exit(0)


if __name__ == "__main__":
    main()
