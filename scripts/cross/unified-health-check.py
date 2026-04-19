#!/usr/bin/env python3
"""
unified-health-check.py

Check the health of both OmniBus projects:
  - BlockChainCore Zig node (RPC port 8332)
  - aweb3 Liberty Solidity contracts (RPC port 8545)

Outputs: unified-health.json
"""

import argparse
import json
import os
import random
import sys
from datetime import datetime, timezone
from typing import Any

import requests

GREEN = "\033[92m"
RED = "\033[91m"
YELLOW = "\033[93m"
CYAN = "\033[96m"
RESET = "\033[0m"


def log_info(msg: str) -> None:
    print(f"{CYAN}[INFO]{RESET} {msg}")


def log_pass(msg: str) -> None:
    print(f"{GREEN}[PASS]{RESET} {msg}")


def log_fail(msg: str) -> None:
    print(f"{RED}[FAIL]{RESET} {msg}")


def log_warn(msg: str) -> None:
    print(f"{YELLOW}[WARN]{RESET} {msg}")


# ---------------------------------------------------------------------------
# Health checkers
# ---------------------------------------------------------------------------
def check_zig_node(url: str, auth: tuple[str, str] | None = None) -> dict[str, Any]:
    payload = {"jsonrpc": "2.0", "method": "getblockchaininfo", "id": random.randint(1, 100000)}
    try:
        resp = requests.post(url, json=payload, auth=auth, timeout=10.0)
        data = resp.json()
        result = data.get("result")
        if result:
            return {
                "status": "healthy",
                "blocks": result.get("blocks"),
                "headers": result.get("headers"),
                "bestblockhash": result.get("bestblockhash"),
                "difficulty": result.get("difficulty"),
            }
        return {"status": "unhealthy", "error": data.get("error")}
    except Exception as exc:
        return {"status": "unreachable", "error": str(exc)}


def check_eth_node(url: str) -> dict[str, Any]:
    payload = {"jsonrpc": "2.0", "method": "eth_blockNumber", "id": random.randint(1, 100000)}
    try:
        resp = requests.post(url, json=payload, timeout=10.0)
        data = resp.json()
        result = data.get("result")
        if result:
            return {"status": "healthy", "block_number": result}
        return {"status": "unhealthy", "error": data.get("error")}
    except Exception as exc:
        return {"status": "unreachable", "error": str(exc)}


def check_eth_net_version(url: str) -> dict[str, Any]:
    payload = {"jsonrpc": "2.0", "method": "net_version", "id": random.randint(1, 100000)}
    try:
        resp = requests.post(url, json=payload, timeout=10.0)
        data = resp.json()
        result = data.get("result")
        return {"status": "healthy", "net_version": result}
    except Exception as exc:
        return {"status": "unreachable", "error": str(exc)}


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def main() -> int:
    parser = argparse.ArgumentParser(description="Unified health check for OmniBus ecosystem.")
    parser.add_argument("--zig-rpc", default="http://127.0.0.1:8332", help="BlockChainCore RPC")
    parser.add_argument("--eth-rpc", default="http://127.0.0.1:8545", help="aweb3 / Liberty RPC")
    parser.add_argument("--zig-user", default="", help="Zig RPC user")
    parser.add_argument("--zig-password", default="", help="Zig RPC password")
    parser.add_argument("--output", default="scripts/cross/unified-health.json", help="Output path")
    args = parser.parse_args()

    zig_auth = (args.zig_user, args.zig_password) if args.zig_user or args.zig_password else None

    log_info("Checking BlockChainCore Zig node …")
    zig_health = check_zig_node(args.zig_rpc, zig_auth)
    if zig_health["status"] == "healthy":
        log_pass(f"  Zig node up at height {zig_health.get('blocks')}")
    else:
        log_fail(f"  Zig node {zig_health['status']}: {zig_health.get('error')}")

    log_info("Checking aweb3 Liberty node …")
    eth_health = check_eth_node(args.eth_rpc)
    eth_net = check_eth_net_version(args.eth_rpc)
    if eth_health["status"] == "healthy":
        log_pass(f"  ETH node up at block {eth_health.get('block_number')}")
    else:
        log_fail(f"  ETH node {eth_health['status']}: {eth_health.get('error')}")

    overall_healthy = zig_health["status"] == "healthy" and eth_health["status"] == "healthy"

    report = {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "overall_healthy": overall_healthy,
        "zig_node": {
            "rpc_url": args.zig_rpc,
            **zig_health,
        },
        "eth_node": {
            "rpc_url": args.eth_rpc,
            **eth_health,
            **eth_net,
        },
    }

    out_path = os.path.abspath(args.output)
    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    with open(out_path, "w", encoding="utf-8") as fh:
        json.dump(report, fh, indent=2)

    log_pass(f"Health report written to {out_path}")
    return 0 if overall_healthy else 1


if __name__ == "__main__":
    sys.exit(main())
