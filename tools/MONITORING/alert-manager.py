#!/usr/bin/env python3
"""
OmniBus BlockChainCore — Alert Manager
=======================================
Unified health-check and alert system for OmniBus blockchain nodes.

Checks performed:
  1. RPC reachable (JSON-RPC 2.0 on configured port)
  2. Chain growing (block height increasing between checks)
  3. Peers > 0 (node is connected to network)
  4. Disk space OK (configurable threshold)

Severity levels:  CRITICAL / WARNING / INFO / OK

Can be invoked once (for cron) or in continuous mode.

Usage:
    python alert-manager.py
    python alert-manager.py --host 127.0.0.1 --port 8332
    python alert-manager.py --config thresholds.json --continuous --interval 60
"""

import argparse
import http.client
import json
import os
import shutil
import sys
import time
from datetime import datetime
from pathlib import Path

# ── ANSI colours ─────────────────────────────────────────────────────
RESET    = "\033[0m"
BOLD     = "\033[1m"
DIM      = "\033[2m"
RED      = "\033[91m"
GREEN    = "\033[92m"
YELLOW   = "\033[93m"
CYAN     = "\033[96m"
MAGENTA  = "\033[95m"
WHITE    = "\033[97m"
BG_RED   = "\033[41m"
BG_YELLOW = "\033[43m"
BG_GREEN = "\033[42m"
BG_CYAN  = "\033[46m"

SEVERITY_COLOURS = {
    "CRITICAL": f"{BG_RED}{WHITE}{BOLD}",
    "WARNING":  f"{BG_YELLOW}{WHITE}{BOLD}",
    "INFO":     f"{BG_CYAN}{WHITE}",
    "OK":       f"{BG_GREEN}{WHITE}",
}

DEFAULT_THRESHOLDS = {
    "rpc_timeout_seconds": 5,
    "min_peers": 1,
    "min_disk_free_gb": 1.0,
    "max_stale_blocks_checks": 3,
    "chain_file": "omnibus-chain.dat",
}


def rpc_call(host: str, port: int, method: str, params=None, timeout: int = 5):
    """JSON-RPC 2.0 call.  Returns (result, error_string)."""
    payload = json.dumps({
        "jsonrpc": "2.0", "id": 1,
        "method": method, "params": params or [],
    })
    try:
        conn = http.client.HTTPConnection(host, port, timeout=timeout)
        conn.request("POST", "/", body=payload,
                     headers={"Content-Type": "application/json"})
        resp = conn.getresponse()
        data = json.loads(resp.read().decode())
        conn.close()
        if "error" in data and data["error"]:
            return None, str(data["error"])
        return data.get("result"), None
    except Exception as exc:
        return None, str(exc)


def emit_alert(severity: str, check: str, message: str):
    """Print a coloured alert line to stdout."""
    ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    sev_col = SEVERITY_COLOURS.get(severity, "")
    print(f"  {DIM}[{ts}]{RESET}  {sev_col} {severity:8s} {RESET}  {BOLD}{check}{RESET}: {message}")


def check_rpc_reachable(host: str, port: int, timeout: int) -> list:
    alerts = []
    result, err = rpc_call(host, port, "getblockchaininfo", timeout=timeout)
    if err:
        alerts.append(("CRITICAL", "RPC", f"Cannot reach node at {host}:{port} — {err}"))
    else:
        alerts.append(("OK", "RPC", f"Node reachable at {host}:{port}"))
    return alerts, result


def check_peers(host: str, port: int, min_peers: int, timeout: int) -> list:
    alerts = []
    result, err = rpc_call(host, port, "getnetworkinfo", timeout=timeout)
    if err:
        alerts.append(("WARNING", "Peers", f"Cannot query peers — {err}"))
        return alerts
    peers = result.get("connections", 0) if result else 0
    if peers < min_peers:
        alerts.append(("WARNING", "Peers", f"Peer count {peers} < minimum {min_peers}"))
    else:
        alerts.append(("OK", "Peers", f"{peers} connected peers"))
    return alerts


def check_disk_space(chain_file: str, min_free_gb: float) -> list:
    alerts = []
    path = Path(chain_file).resolve()
    check_dir = path.parent if path.parent.exists() else Path(".")
    try:
        usage = shutil.disk_usage(str(check_dir))
        free_gb = usage.free / (1024 ** 3)
        if free_gb < min_free_gb:
            alerts.append(("CRITICAL", "Disk", f"Only {free_gb:.2f} GB free (threshold: {min_free_gb} GB)"))
        else:
            alerts.append(("OK", "Disk", f"{free_gb:.1f} GB free"))
    except Exception as exc:
        alerts.append(("WARNING", "Disk", f"Cannot check disk space — {exc}"))
    return alerts


def check_chain_growing(host, port, timeout, prev_height) -> tuple:
    """Returns (alerts, current_height)."""
    alerts = []
    result, err = rpc_call(host, port, "getblockchaininfo", timeout=timeout)
    if err:
        return [("WARNING", "Chain", "Cannot query block height")], prev_height

    height = result.get("blocks", 0) if result else 0
    if prev_height is not None and height <= prev_height:
        alerts.append(("WARNING", "Chain", f"Block height unchanged at {height} — node may not be mining"))
    elif prev_height is not None:
        alerts.append(("OK", "Chain", f"Chain growing: {prev_height} -> {height} (+{height - prev_height} blocks)"))
    else:
        alerts.append(("INFO", "Chain", f"Initial block height: {height}"))
    return alerts, height


def load_config(config_path: str | None) -> dict:
    cfg = dict(DEFAULT_THRESHOLDS)
    if config_path and Path(config_path).exists():
        with open(config_path) as f:
            user_cfg = json.load(f)
        cfg.update(user_cfg)
    return cfg


def run_checks(host, port, cfg, prev_height):
    """Run all checks, return (all_alerts, new_height)."""
    timeout = cfg["rpc_timeout_seconds"]
    all_alerts = []

    rpc_alerts, rpc_result = check_rpc_reachable(host, port, timeout)
    all_alerts.extend(rpc_alerts)

    # Only run further checks if RPC is reachable
    if rpc_result is not None:
        all_alerts.extend(check_peers(host, port, cfg["min_peers"], timeout))
        chain_alerts, new_height = check_chain_growing(host, port, timeout, prev_height)
        all_alerts.extend(chain_alerts)
    else:
        new_height = prev_height

    script_dir = Path(__file__).resolve().parent
    chain_path = script_dir.parent.parent / cfg["chain_file"]
    all_alerts.extend(check_disk_space(str(chain_path), cfg["min_disk_free_gb"]))

    return all_alerts, new_height


def print_header():
    print(f"\n{CYAN}{BOLD}  OmniBus Alert Manager{RESET}")
    print(f"  {DIM}{'─' * 55}{RESET}")


def print_summary(alerts):
    crits = sum(1 for s, _, _ in alerts if s == "CRITICAL")
    warns = sum(1 for s, _, _ in alerts if s == "WARNING")
    oks   = sum(1 for s, _, _ in alerts if s == "OK")
    print(f"  {DIM}{'─' * 55}{RESET}")
    parts = []
    if crits:
        parts.append(f"{RED}{crits} critical{RESET}")
    if warns:
        parts.append(f"{YELLOW}{warns} warnings{RESET}")
    parts.append(f"{GREEN}{oks} ok{RESET}")
    print(f"  Summary: {', '.join(parts)}")
    return crits


def main():
    parser = argparse.ArgumentParser(
        description="OmniBus Alert Manager — unified node health checks",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "Config JSON example:\n"
            '  {"rpc_timeout_seconds": 5, "min_peers": 2, "min_disk_free_gb": 5.0}\n\n'
            "Examples:\n"
            "  python alert-manager.py --host 127.0.0.1 --port 8332\n"
            "  python alert-manager.py --continuous --interval 60\n"
            "  python alert-manager.py --config /etc/omnibus/alerts.json"
        ),
    )
    parser.add_argument("--host", default="127.0.0.1", help="Node RPC host (default: 127.0.0.1)")
    parser.add_argument("--port", type=int, default=8332, help="Node RPC port (default: 8332)")
    parser.add_argument("--config", default=None, help="Path to thresholds JSON config file")
    parser.add_argument("--continuous", action="store_true", help="Run continuously instead of once")
    parser.add_argument("--interval", type=int, default=60, help="Check interval in seconds for continuous mode (default: 60)")
    args = parser.parse_args()

    cfg = load_config(args.config)

    if args.config and Path(args.config).exists():
        print(f"{DIM}  Loaded config from {args.config}{RESET}")

    prev_height = None

    if args.continuous:
        print(f"{CYAN}Running in continuous mode (interval: {args.interval}s). Ctrl+C to stop.{RESET}")
        try:
            while True:
                print_header()
                alerts, prev_height = run_checks(args.host, args.port, cfg, prev_height)
                for sev, check, msg in alerts:
                    emit_alert(sev, check, msg)
                print_summary(alerts)
                time.sleep(args.interval)
        except KeyboardInterrupt:
            print(f"\n{YELLOW}Alert manager stopped.{RESET}")
            sys.exit(0)
    else:
        print_header()
        alerts, _ = run_checks(args.host, args.port, cfg, prev_height)
        for sev, check, msg in alerts:
            emit_alert(sev, check, msg)
        crits = print_summary(alerts)
        sys.exit(2 if crits > 0 else 0)


if __name__ == "__main__":
    main()
