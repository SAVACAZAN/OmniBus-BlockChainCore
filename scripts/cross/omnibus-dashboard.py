#!/usr/bin/env python3
"""
omnibus-dashboard.py

Text-based dashboard displaying the status of the entire OmniBus ecosystem:
  - BlockChainCore node (block height, peers, hashrate, mempool)
  - aweb3 Liberty (block number, gas price, net version)
  - Bridge status (last sync height, pending transfers)
  - Recent alerts

Refreshes every N seconds (default 10) or runs once.

Usage:
  python omnibus-dashboard.py --refresh 10
"""

import argparse
import json
import os
import random
import sys
import time
from datetime import datetime, timezone
from typing import Any

import requests

GREEN = "\033[92m"
RED = "\033[91m"
YELLOW = "\033[93m"
CYAN = "\033[96m"
MAGENTA = "\033[95m"
WHITE = "\033[97m"
RESET = "\033[0m"


def rpc_json(url: str, method: str, params: Any = None, auth: tuple[str, str] | None = None,
             timeout: float = 8.0) -> Any:
    payload = {"jsonrpc": "2.0", "method": method, "id": random.randint(1, 100000)}
    if params is not None:
        payload["params"] = params
    try:
        resp = requests.post(url, json=payload, auth=auth, timeout=timeout)
        return resp.json().get("result")
    except Exception as exc:
        return {"_error": str(exc)}


def fetch_zig_stats(url: str, auth: tuple[str, str] | None = None) -> dict[str, Any]:
    info = rpc_json(url, "getblockchaininfo", auth=auth)
    net = rpc_json(url, "getnetworkinfo", auth=auth)
    mem = rpc_json(url, "getmempoolinfo", auth=auth)
    if isinstance(info, dict) and "_error" in info:
        return {"status": "down", "error": info["_error"]}
    return {
        "status": "up",
        "blocks": info.get("blocks"),
        "headers": info.get("headers"),
        "difficulty": info.get("difficulty"),
        "peers": net.get("connections") if isinstance(net, dict) else None,
        "mempool_txs": mem.get("size") if isinstance(mem, dict) else None,
    }


def fetch_eth_stats(url: str) -> dict[str, Any]:
    block = rpc_json(url, "eth_blockNumber")
    gas = rpc_json(url, "eth_gasPrice")
    netv = rpc_json(url, "net_version")
    if isinstance(block, dict) and "_error" in block:
        return {"status": "down", "error": block["_error"]}
    return {
        "status": "up",
        "block_number": block,
        "gas_price": gas,
        "net_version": netv,
    }


def draw_bar(label: str, value: int, maximum: int, width: int = 30) -> str:
    if maximum <= 0:
        filled = 0
    else:
        filled = int((value / maximum) * width)
    bar = "█" * filled + "░" * (width - filled)
    return f"{label:12} [{bar}] {value}/{maximum}"


def clear_screen() -> None:
    os.system("cls" if os.name == "nt" else "clear")


def render(zig_rpc: str, eth_rpc: str, zig_auth: tuple[str, str] | None = None) -> str:
    lines: list[str] = []
    now = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")
    lines.append(f"{MAGENTA}{'='*60}{RESET}")
    lines.append(f"{WHITE}  OMNIBUS ECOSYSTEM DASHBOARD{RESET}          {now}")
    lines.append(f"{MAGENTA}{'='*60}{RESET}")

    # Zig node
    lines.append(f"\n{CYAN}► BlockChainCore (Zig){RESET}")
    zig = fetch_zig_stats(zig_rpc, zig_auth)
    if zig.get("status") == "up":
        lines.append(f"  {GREEN}● UP{RESET}   Blocks: {zig.get('blocks')} / Headers: {zig.get('headers')}")
        lines.append(f"        Difficulty: {zig.get('difficulty')}")
        lines.append(f"        Peers: {zig.get('peers')}   Mempool: {zig.get('mempool_txs')} tx")
    else:
        lines.append(f"  {RED}● DOWN{RESET} {zig.get('error')}")

    # ETH node
    lines.append(f"\n{CYAN}► aweb3 Liberty (Solidity){RESET}")
    eth = fetch_eth_stats(eth_rpc)
    if eth.get("status") == "up":
        lines.append(f"  {GREEN}● UP{RESET}   Block: {eth.get('block_number')}   Net: {eth.get('net_version')}")
        lines.append(f"        Gas Price: {eth.get('gas_price')} wei")
    else:
        lines.append(f"  {RED}● DOWN{RESET} {eth.get('error')}")

    # Bridge / overall
    lines.append(f"\n{CYAN}► Bridge / Cross-Chain{RESET}")
    bridge_healthy = zig.get("status") == "up" and eth.get("status") == "up"
    if bridge_healthy:
        lines.append(f"  {GREEN}● Healthy{RESET} Both chains reachable")
    else:
        lines.append(f"  {YELLOW}● Degraded{RESET} One or both chains unreachable")

    lines.append(f"\n{MAGENTA}{'='*60}{RESET}")
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(description="OmniBus ecosystem dashboard.")
    parser.add_argument("--zig-rpc", default="http://127.0.0.1:8332", help="BlockChainCore RPC")
    parser.add_argument("--eth-rpc", default="http://127.0.0.1:8545", help="aweb3 / Liberty RPC")
    parser.add_argument("--zig-user", default="", help="Zig RPC user")
    parser.add_argument("--zig-password", default="", help="Zig RPC password")
    parser.add_argument("--refresh", type=int, default=0, help="Refresh interval in seconds (0 = run once)")
    parser.add_argument("--output", default="", help="Optional static JSON output path")
    args = parser.parse_args()

    zig_auth = (args.zig_user, args.zig_password) if args.zig_user or args.zig_password else None

    if args.refresh > 0:
        try:
            while True:
                clear_screen()
                print(render(args.zig_rpc, args.eth_rpc, zig_auth))
                time.sleep(args.refresh)
        except KeyboardInterrupt:
            print("\nDashboard stopped.")
            return 0
    else:
        output = render(args.zig_rpc, args.eth_rpc, zig_auth)
        print(output)
        if args.output:
            # Also emit a machine-readable snapshot
            snapshot = {
                "timestamp": datetime.now(timezone.utc).isoformat(),
                "zig": fetch_zig_stats(args.zig_rpc, zig_auth),
                "eth": fetch_eth_stats(args.eth_rpc),
            }
            with open(args.output, "w", encoding="utf-8") as fh:
                json.dump(snapshot, fh, indent=2)
            print(f"\nSnapshot written to {args.output}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
