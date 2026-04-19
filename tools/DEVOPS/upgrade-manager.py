#!/usr/bin/env python3
"""
OmniBus BlockChainCore — Upgrade Manager
=========================================
Handles safe node upgrades with automatic backup and rollback:

  1. Backup chain data (omnibus-chain.dat) + config
  2. Stop running node (if PID known)
  3. Rebuild from source (zig build)
  4. Verify new binary exists and is executable
  5. Restart node

If the build fails, automatic rollback restores the previous binary.

Usage:
    python upgrade-manager.py
    python upgrade-manager.py --backup-first
    python upgrade-manager.py --no-restart --backup-dir /tmp/omnibus-backup
"""

import argparse
import os
import platform
import shutil
import subprocess
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
WHITE   = "\033[97m"
BG_RED  = "\033[41m"

OK   = f"{GREEN}[OK]{RESET}"
FAIL = f"{RED}[FAIL]{RESET}"
WARN = f"{YELLOW}[WARN]{RESET}"
STEP = f"{CYAN}>>>{RESET}"


def find_project_root() -> Path:
    d = Path(__file__).resolve().parent
    for _ in range(6):
        if (d / "build.zig").exists():
            return d
        d = d.parent
    return Path(__file__).resolve().parent.parent.parent


def find_binary(project_root: Path) -> Path | None:
    for name in ("omnibus-node.exe", "omnibus-node"):
        p = project_root / "zig-out" / "bin" / name
        if p.exists():
            return p
    return None


def get_binary_info(binary: Path) -> dict:
    """Get binary size and modification time."""
    if not binary.exists():
        return {"exists": False}
    stat = binary.stat()
    return {
        "exists": True,
        "size": stat.st_size,
        "mtime": datetime.fromtimestamp(stat.st_mtime).strftime("%Y-%m-%d %H:%M:%S"),
    }


def backup_files(project_root: Path, backup_dir: Path) -> bool:
    """Backup chain data, config, and current binary."""
    print(f"\n  {STEP} {BOLD}Step 1: Backup{RESET}")

    backup_dir.mkdir(parents=True, exist_ok=True)
    files_to_backup = [
        ("omnibus-chain.dat", "Chain data"),
        ("omnibus.toml", "Config"),
        ("omnibus.log", "Logs"),
    ]

    backed_up = 0
    binary = find_binary(project_root)
    if binary and binary.exists():
        dest = backup_dir / binary.name
        shutil.copy2(str(binary), str(dest))
        print(f"    {OK} Binary: {binary.name} ({binary.stat().st_size / 1024:.0f} KB)")
        backed_up += 1

    for filename, label in files_to_backup:
        src = project_root / filename
        if src.exists():
            dest = backup_dir / filename
            shutil.copy2(str(src), str(dest))
            size = src.stat().st_size
            print(f"    {OK} {label}: {filename} ({size / 1024:.0f} KB)")
            backed_up += 1
        else:
            print(f"    {DIM}[SKIP] {label}: {filename} not found{RESET}")

    if backed_up > 0:
        print(f"    {OK} Backup saved to: {backup_dir}")
        return True
    else:
        print(f"    {WARN} Nothing to backup")
        return True


def stop_node(project_root: Path) -> int | None:
    """Attempt to stop running node. Returns PID if found."""
    print(f"\n  {STEP} {BOLD}Step 2: Stop running node{RESET}")

    # Check orchestrator PID file
    pid_file = Path(__file__).resolve().parent / ".orchestrator-pids.json"
    if pid_file.exists():
        import json
        try:
            nodes = json.loads(pid_file.read_text())
            for node in nodes:
                pid = node.get("pid")
                if pid:
                    try:
                        if os.name == "nt":
                            subprocess.run(["taskkill", "/F", "/PID", str(pid)],
                                           capture_output=True, timeout=10)
                        else:
                            os.kill(pid, 15)
                        print(f"    {OK} Stopped node {node.get('node_id', '?')} (PID {pid})")
                    except Exception:
                        pass
            return nodes[0]["pid"] if nodes else None
        except Exception:
            pass

    # Try to find by process name
    try:
        if os.name == "nt":
            result = subprocess.run(
                ["tasklist", "/FI", "IMAGENAME eq omnibus-node.exe", "/FO", "CSV"],
                capture_output=True, text=True, timeout=10,
            )
            lines = result.stdout.strip().split("\n")
            if len(lines) > 1:
                for line in lines[1:]:
                    parts = line.strip('"').split('","')
                    if len(parts) >= 2:
                        pid = int(parts[1])
                        subprocess.run(["taskkill", "/F", "/PID", str(pid)],
                                       capture_output=True, timeout=10)
                        print(f"    {OK} Stopped omnibus-node.exe (PID {pid})")
                        return pid
        else:
            result = subprocess.run(["pkill", "-f", "omnibus-node"],
                                    capture_output=True, timeout=10)
            if result.returncode == 0:
                print(f"    {OK} Stopped omnibus-node process")
                return -1
    except Exception:
        pass

    print(f"    {DIM}[SKIP] No running node found{RESET}")
    return None


def rebuild(project_root: Path) -> bool:
    """Run zig build."""
    print(f"\n  {STEP} {BOLD}Step 3: Rebuild from source{RESET}")
    print(f"    {DIM}Running zig build in {project_root}...{RESET}")

    try:
        result = subprocess.run(
            ["zig", "build"],
            cwd=str(project_root),
            capture_output=True, text=True, timeout=300,
        )
        if result.returncode == 0:
            print(f"    {OK} Build succeeded")
            return True
        else:
            print(f"    {FAIL} Build failed!")
            stderr = result.stderr.strip()
            if stderr:
                for line in stderr.split("\n")[:10]:
                    print(f"    {DIM}{line}{RESET}")
            return False
    except FileNotFoundError:
        print(f"    {FAIL} Zig compiler not found in PATH")
        return False
    except subprocess.TimeoutExpired:
        print(f"    {FAIL} Build timed out (300s)")
        return False


def verify_binary(project_root: Path) -> bool:
    """Verify the new binary exists."""
    print(f"\n  {STEP} {BOLD}Step 4: Verify new binary{RESET}")
    binary = find_binary(project_root)
    if not binary:
        print(f"    {FAIL} Binary not found in zig-out/bin/")
        return False
    info = get_binary_info(binary)
    print(f"    {OK} Binary: {binary.name}")
    print(f"    {OK} Size: {info['size'] / 1024:.0f} KB")
    print(f"    {OK} Built: {info['mtime']}")
    return True


def rollback(project_root: Path, backup_dir: Path):
    """Restore binary from backup."""
    print(f"\n  {BG_RED}{WHITE}{BOLD} ROLLBACK {RESET}")
    for name in ("omnibus-node.exe", "omnibus-node"):
        backup_bin = backup_dir / name
        if backup_bin.exists():
            dest = project_root / "zig-out" / "bin" / name
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(str(backup_bin), str(dest))
            print(f"    {OK} Restored {name} from backup")
            return
    print(f"    {FAIL} No backup binary found to restore")


def restart_node(project_root: Path, mode: str = "seed"):
    """Restart the node."""
    print(f"\n  {STEP} {BOLD}Step 5: Restart node{RESET}")
    binary = find_binary(project_root)
    if not binary:
        print(f"    {FAIL} Cannot restart — binary not found")
        return

    cmd = [str(binary), "--mode", mode, "--node-id", f"{mode}-upgraded"]

    log_dir = project_root / "logs"
    log_dir.mkdir(exist_ok=True)
    log_file = open(log_dir / "omnibus-upgraded.log", "w")

    proc = subprocess.Popen(cmd, cwd=str(project_root),
                             stdout=log_file, stderr=subprocess.STDOUT)
    print(f"    {OK} Node started (PID {proc.pid}, mode: {mode})")
    print(f"    {DIM}Log: {log_dir / 'omnibus-upgraded.log'}{RESET}")


def main():
    parser = argparse.ArgumentParser(
        description="OmniBus Upgrade Manager — safe node upgrades with rollback",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "Examples:\n"
            "  python upgrade-manager.py\n"
            "  python upgrade-manager.py --backup-first\n"
            "  python upgrade-manager.py --no-restart --backup-dir ./my-backup"
        ),
    )
    parser.add_argument("--backup-first", action="store_true", default=True,
                        help="Backup chain data before upgrade (default: True)")
    parser.add_argument("--no-backup", action="store_true",
                        help="Skip backup step")
    parser.add_argument("--no-restart", action="store_true",
                        help="Don't restart the node after upgrade")
    parser.add_argument("--backup-dir", type=str, default=None,
                        help="Backup directory (default: tools/DEVOPS/backups/<timestamp>)")
    parser.add_argument("--mode", choices=["seed", "miner"], default="seed",
                        help="Node mode for restart (default: seed)")
    args = parser.parse_args()

    project_root = find_project_root()
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    backup_dir = Path(args.backup_dir) if args.backup_dir else (
        Path(__file__).resolve().parent / "backups" / timestamp
    )

    print(f"\n{CYAN}{BOLD}  OmniBus Upgrade Manager{RESET}")
    print(f"  {DIM}{'─' * 55}{RESET}")
    print(f"  {CYAN}Project:{RESET}     {project_root}")
    print(f"  {CYAN}Backup dir:{RESET}  {backup_dir}")
    print(f"  {CYAN}Platform:{RESET}    {platform.system()}")

    current_binary = find_binary(project_root)
    if current_binary:
        info = get_binary_info(current_binary)
        print(f"  {CYAN}Current:{RESET}    {current_binary.name} ({info['size'] / 1024:.0f} KB, {info['mtime']})")

    # Step 1: Backup
    if not args.no_backup:
        backup_files(project_root, backup_dir)
    else:
        print(f"\n  {WARN} Backup skipped (--no-backup)")

    # Step 2: Stop node
    stop_node(project_root)

    # Step 3: Rebuild
    build_ok = rebuild(project_root)

    if not build_ok:
        print(f"\n  {RED}{BOLD}Build failed!{RESET}")
        if not args.no_backup:
            rollback(project_root, backup_dir)
            print(f"  {GREEN}Previous binary restored from backup.{RESET}")
        sys.exit(1)

    # Step 4: Verify
    if not verify_binary(project_root):
        if not args.no_backup:
            rollback(project_root, backup_dir)
        sys.exit(1)

    # Step 5: Restart
    if not args.no_restart:
        restart_node(project_root, args.mode)
    else:
        print(f"\n  {DIM}[SKIP] Restart skipped (--no-restart){RESET}")

    print(f"\n  {DIM}{'─' * 55}{RESET}")
    print(f"  {GREEN}{BOLD}Upgrade complete!{RESET}\n")


if __name__ == "__main__":
    main()
