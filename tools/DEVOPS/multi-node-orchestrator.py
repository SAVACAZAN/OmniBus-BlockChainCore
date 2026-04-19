#!/usr/bin/env python3
"""
OmniBus BlockChainCore — Multi-Node Orchestrator
=================================================
Manages multiple local OmniBus nodes for development and testing.

Starts N nodes (1 seed + N-1 miners) on sequential ports, monitors
their health, and provides commands to stop all nodes cleanly.

Usage:
    python multi-node-orchestrator.py --count 3
    python multi-node-orchestrator.py --count 5 --base-port 9000
    python multi-node-orchestrator.py --stop
"""

import argparse
import json
import os
import signal
import subprocess
import sys
import time
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
WHITE   = "\033[97m"
BG_BLUE = "\033[44m"

PID_FILE = Path(__file__).resolve().parent / ".orchestrator-pids.json"


def find_binary() -> Path | None:
    """Locate omnibus-node binary relative to script location."""
    script_dir = Path(__file__).resolve().parent
    candidates = [
        script_dir.parent.parent / "zig-out" / "bin" / "omnibus-node.exe",
        script_dir.parent.parent / "zig-out" / "bin" / "omnibus-node",
    ]
    for c in candidates:
        if c.exists():
            return c
    return None


def save_pids(nodes: list[dict]):
    """Save running node info to PID file."""
    with open(PID_FILE, "w") as f:
        json.dump(nodes, f, indent=2)


def load_pids() -> list[dict]:
    """Load node info from PID file."""
    if PID_FILE.exists():
        with open(PID_FILE) as f:
            return json.load(f)
    return []


def is_pid_alive(pid: int) -> bool:
    """Check if a process is still running."""
    try:
        if os.name == "nt":
            result = subprocess.run(
                ["tasklist", "/FI", f"PID eq {pid}"],
                capture_output=True, text=True, timeout=5,
            )
            return str(pid) in result.stdout
        else:
            os.kill(pid, 0)
            return True
    except (OSError, subprocess.TimeoutExpired):
        return False


def kill_process(pid: int):
    """Kill a process by PID."""
    try:
        if os.name == "nt":
            subprocess.run(["taskkill", "/F", "/PID", str(pid)],
                           capture_output=True, timeout=10)
        else:
            os.kill(pid, signal.SIGTERM)
            time.sleep(1)
            try:
                os.kill(pid, signal.SIGKILL)
            except OSError:
                pass
    except Exception:
        pass


def start_nodes(binary: Path, count: int, base_port: int, rpc_base: int):
    """Start 1 seed + (count-1) miner nodes."""
    print(f"\n{BG_BLUE}{WHITE}{BOLD} OmniBus Multi-Node Orchestrator {RESET}")
    print(f"  {DIM}{'─' * 55}{RESET}")
    print(f"  {CYAN}Binary:{RESET}     {binary}")
    print(f"  {CYAN}Nodes:{RESET}      {count} (1 seed + {count - 1} miners)")
    print(f"  {CYAN}Base port:{RESET}  {base_port}")
    print(f"  {CYAN}RPC base:{RESET}   {rpc_base}")
    print(f"  {DIM}{'─' * 55}{RESET}\n")

    work_dir = binary.parent.parent.parent
    nodes = []

    # Start seed node
    seed_port = base_port
    seed_rpc = rpc_base
    seed_id = "seed-1"
    print(f"  {MAGENTA}[1/{count}]{RESET} Starting {BOLD}seed{RESET} node {seed_id} "
          f"(P2P: {seed_port}, RPC: {seed_rpc})")

    seed_cmd = [
        str(binary),
        "--mode", "seed",
        "--node-id", seed_id,
        "--port", str(seed_port),
    ]

    log_dir = work_dir / "logs"
    log_dir.mkdir(exist_ok=True)

    seed_log = open(log_dir / f"{seed_id}.log", "w")
    seed_proc = subprocess.Popen(
        seed_cmd, cwd=str(work_dir),
        stdout=seed_log, stderr=subprocess.STDOUT,
    )
    nodes.append({
        "node_id": seed_id, "mode": "seed", "pid": seed_proc.pid,
        "port": seed_port, "rpc_port": seed_rpc,
    })
    print(f"    {GREEN}[OK]{RESET} PID {seed_proc.pid}")

    # Give seed node time to bind
    time.sleep(1)

    # Start miner nodes
    for i in range(1, count):
        miner_port = base_port + i
        miner_rpc = rpc_base + i
        miner_id = f"miner-{i}"
        print(f"  {MAGENTA}[{i + 1}/{count}]{RESET} Starting {BOLD}miner{RESET} node {miner_id} "
              f"(P2P: {miner_port}, RPC: {miner_rpc})")

        miner_cmd = [
            str(binary),
            "--mode", "miner",
            "--node-id", miner_id,
            "--port", str(miner_port),
            "--seed-host", "127.0.0.1",
            "--seed-port", str(seed_port),
        ]

        miner_log = open(log_dir / f"{miner_id}.log", "w")
        miner_proc = subprocess.Popen(
            miner_cmd, cwd=str(work_dir),
            stdout=miner_log, stderr=subprocess.STDOUT,
        )
        nodes.append({
            "node_id": miner_id, "mode": "miner", "pid": miner_proc.pid,
            "port": miner_port, "rpc_port": miner_rpc,
        })
        print(f"    {GREEN}[OK]{RESET} PID {miner_proc.pid}")
        time.sleep(0.3)

    save_pids(nodes)
    print(f"\n  {DIM}{'─' * 55}{RESET}")
    print(f"  {GREEN}{BOLD}All {count} nodes started.{RESET}")
    print(f"  {DIM}PID file: {PID_FILE}{RESET}")
    print(f"  {DIM}Logs dir: {log_dir}{RESET}")
    print(f"  {DIM}Stop all: python {Path(__file__).name} --stop{RESET}\n")

    return nodes


def stop_nodes():
    """Stop all nodes tracked in PID file."""
    nodes = load_pids()
    if not nodes:
        print(f"  {YELLOW}No running nodes found (PID file empty or missing).{RESET}")
        return

    print(f"\n{CYAN}{BOLD}  Stopping {len(nodes)} nodes...{RESET}")
    print(f"  {DIM}{'─' * 55}{RESET}")

    for node in nodes:
        pid = node["pid"]
        alive = is_pid_alive(pid)
        status = f"{GREEN}running{RESET}" if alive else f"{DIM}already stopped{RESET}"
        print(f"  {node['node_id']:12s}  PID {pid:6d}  {status}", end="")

        if alive:
            kill_process(pid)
            print(f"  -> {RED}killed{RESET}")
        else:
            print()

    PID_FILE.unlink(missing_ok=True)
    print(f"\n  {GREEN}{BOLD}All nodes stopped.{RESET}\n")


def status_nodes():
    """Show status of tracked nodes."""
    nodes = load_pids()
    if not nodes:
        print(f"  {YELLOW}No tracked nodes.{RESET}")
        return

    print(f"\n{CYAN}{BOLD}  Node Status{RESET}")
    print(f"  {DIM}{'─' * 60}{RESET}")
    print(f"  {'Node ID':<14s} {'Mode':<8s} {'PID':<8s} {'P2P Port':<10s} {'Status'}")
    print(f"  {DIM}{'─' * 60}{RESET}")

    for node in nodes:
        alive = is_pid_alive(node["pid"])
        status = f"{GREEN}RUNNING{RESET}" if alive else f"{RED}STOPPED{RESET}"
        print(f"  {node['node_id']:<14s} {node['mode']:<8s} {node['pid']:<8d} {node['port']:<10d} {status}")

    print(f"  {DIM}{'─' * 60}{RESET}\n")


def monitor_loop(interval: int):
    """Continuously monitor node status."""
    print(f"{CYAN}Monitoring nodes (interval: {interval}s). Ctrl+C to stop.{RESET}")
    try:
        while True:
            os.system("cls" if os.name == "nt" else "clear")
            status_nodes()
            nodes = load_pids()
            dead = [n for n in nodes if not is_pid_alive(n["pid"])]
            if dead:
                for n in dead:
                    print(f"  {RED}WARNING:{RESET} {n['node_id']} (PID {n['pid']}) has stopped!")
            time.sleep(interval)
    except KeyboardInterrupt:
        print(f"\n{YELLOW}Monitoring stopped.{RESET}")


def main():
    parser = argparse.ArgumentParser(
        description="OmniBus Multi-Node Orchestrator",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "Examples:\n"
            "  python multi-node-orchestrator.py --count 3\n"
            "  python multi-node-orchestrator.py --count 5 --base-port 9100\n"
            "  python multi-node-orchestrator.py --status\n"
            "  python multi-node-orchestrator.py --stop"
        ),
    )
    parser.add_argument("--count", type=int, default=3, help="Number of nodes to start (default: 3)")
    parser.add_argument("--base-port", type=int, default=9000, help="Base P2P port (default: 9000)")
    parser.add_argument("--rpc-base", type=int, default=8332, help="Base RPC port (default: 8332)")
    parser.add_argument("--stop", action="store_true", help="Stop all running nodes")
    parser.add_argument("--status", action="store_true", help="Show status of tracked nodes")
    parser.add_argument("--monitor", action="store_true", help="Continuously monitor node health")
    parser.add_argument("--interval", type=int, default=10, help="Monitor interval in seconds (default: 10)")
    args = parser.parse_args()

    if args.stop:
        stop_nodes()
        return

    if args.status:
        status_nodes()
        return

    if args.monitor:
        monitor_loop(args.interval)
        return

    # Start mode
    binary = find_binary()
    if not binary:
        print(f"  {RED}ERROR:{RESET} Cannot find omnibus-node binary in zig-out/bin/")
        print(f"  {DIM}Run 'zig build' first, or use deploy-node.py{RESET}")
        sys.exit(1)

    if args.count < 1:
        print(f"  {RED}ERROR:{RESET} --count must be >= 1")
        sys.exit(1)

    start_nodes(binary, args.count, args.base_port, args.rpc_base)


if __name__ == "__main__":
    main()
