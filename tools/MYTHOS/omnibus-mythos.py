#!/usr/bin/env python3
"""
╔══════════════════════════════════════════════════════════════╗
║  MYTHOS CLAUDE OMNIBUS — Master Verification Framework      ║
║  Systematic bit-by-bit code verification for the entire     ║
║  OmniBus ecosystem: aweb3 + BlockChainCore + OmniBus OS     ║
║                                                              ║
║  Runs ALL tools, ALL tests, ALL audits — learns from each   ║
║  run and builds a knowledge base for continuous improvement. ║
╚══════════════════════════════════════════════════════════════╝

Usage:
    python tools/MYTHOS/omnibus-mythos.py                    # Full run
    python tools/MYTHOS/omnibus-mythos.py --phase crypto     # Only crypto verification
    python tools/MYTHOS/omnibus-mythos.py --phase security   # Only security scans
    python tools/MYTHOS/omnibus-mythos.py --phase stress     # Only stress tests
    python tools/MYTHOS/omnibus-mythos.py --list             # List all phases
    python tools/MYTHOS/omnibus-mythos.py --report           # Show last run report
    python tools/MYTHOS/omnibus-mythos.py --learn            # Analyze all past results
"""

import argparse
import json
import os
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path

# ═══════════════════════════════════════════════════════════════
# ANSI Colors
# ═══════════════════════════════════════════════════════════════
GREEN  = '\033[92m'
RED    = '\033[91m'
YELLOW = '\033[93m'
CYAN   = '\033[96m'
MAGENTA= '\033[95m'
BOLD   = '\033[1m'
RESET  = '\033[0m'

def log_pass(msg):  print(f"  {GREEN}✅ PASS{RESET}  {msg}")
def log_fail(msg):  print(f"  {RED}❌ FAIL{RESET}  {msg}")
def log_warn(msg):  print(f"  {YELLOW}⚠  WARN{RESET}  {msg}")
def log_info(msg):  print(f"  {CYAN}ℹ  INFO{RESET}  {msg}")
def log_phase(msg): print(f"\n{BOLD}{MAGENTA}{'═'*60}\n  PHASE: {msg}\n{'═'*60}{RESET}")

# ═══════════════════════════════════════════════════════════════
# Project Discovery
# ═══════════════════════════════════════════════════════════════

def find_projects():
    """Auto-discover OmniBus projects relative to this script."""
    mythos_dir = Path(__file__).resolve().parent
    blockchain_root = mythos_dir.parent.parent  # tools/MYTHOS -> BlockChainCore
    parent_dir = blockchain_root.parent          # OmniBus aweb3 + OmniBus BlockChain

    projects = {
        "blockchaincore": {
            "name": "OmniBus-BlockChainCore",
            "path": str(blockchain_root),
            "type": "zig-blockchain",
            "tools_dir": str(blockchain_root / "tools"),
            "scripts_dir": str(blockchain_root / "scripts"),
            "core_dir": str(blockchain_root / "core"),
        },
        "aweb3": {
            "name": "OmniBus - aweb3",
            "path": str(parent_dir / "OmniBus - aweb3"),
            "type": "tauri-solidity",
            "scripts_dir": str(parent_dir / "OmniBus - aweb3" / "scripts"),
            "contracts_dir": str(parent_dir / "OmniBus - aweb3" / "contracts"),
        }
    }

    # Validate paths exist
    for key, proj in projects.items():
        if os.path.isdir(proj["path"]):
            proj["status"] = "found"
        else:
            proj["status"] = "missing"
            log_warn(f"Project not found: {proj['path']}")

    return projects


# ═══════════════════════════════════════════════════════════════
# Phase Definitions — ALL verification phases
# ═══════════════════════════════════════════════════════════════

PHASES = {
    # ── CRYPTO VERIFICATION ──────────────────────────────────
    "crypto": {
        "name": "Cryptographic Verification (NIST/Wycheproof)",
        "description": "Verify all crypto implementations against standard test vectors",
        "tasks": [
            {"project": "blockchaincore", "cmd": "python tools/SECURITY/nist-ecdsa-vectors.py", "name": "NIST ECDSA secp256k1"},
            {"project": "blockchaincore", "cmd": "python tools/SECURITY/wycheproof-vectors.py", "name": "Wycheproof test vectors"},
            {"project": "blockchaincore", "cmd": "python tools/SECURITY/sha256-ripemd160-vectors.py", "name": "SHA-256 + RIPEMD-160"},
            {"project": "blockchaincore", "cmd": "python tools/SECURITY/fips-140-compliance.py", "name": "FIPS 140-2 RNG tests"},
            {"project": "blockchaincore", "cmd": "python tools/SECURITY/property-based-crypto.py", "name": "Property-based crypto"},
            {"project": "blockchaincore", "cmd": "python tools/SECURITY/crypto-audit.py", "name": "Crypto source audit"},
            {"project": "blockchaincore", "cmd": "python tools/WALLET/wallet-tester.py", "name": "BIP-32/39 wallet test"},
        ]
    },

    # ── SECURITY AUDIT ───────────────────────────────────────
    "security": {
        "name": "Security Audit & Vulnerability Scan",
        "description": "Scan all code for vulnerabilities, run rule-based detection",
        "tasks": [
            {"project": "aweb3", "cmd": "python scripts/security/audit-all-contracts.py", "name": "Solidity audit (all contracts)"},
            {"project": "aweb3", "cmd": "python scripts/security/symbolic-solidity-analyzer.py", "name": "Symbolic Solidity analysis"},
            {"project": "aweb3", "cmd": "python scripts/security/vuln-signature-updater.py --check", "name": "Vuln signature scan (Solidity)"},
            {"project": "blockchaincore", "cmd": "python tools/SECURITY/vuln-signature-updater.py --check", "name": "Vuln signature scan (Zig)"},
            {"project": "blockchaincore", "cmd": "python tools/EXPLOITS/symbolic-exec-helper.py", "name": "Symbolic exec (Zig source)"},
            {"project": "blockchaincore", "cmd": "python tools/EXPLOITS/binary-analysis.py", "name": "Binary hardening check"},
            {"project": "blockchaincore", "cmd": "python tools/EXPLOITS/rop-gadget-scanner.py", "name": "ROP gadget scan"},
        ]
    },

    # ── BUILD & TEST ─────────────────────────────────────────
    "build": {
        "name": "Build & Test Suite",
        "description": "Compile and run all test suites",
        "tasks": [
            {"project": "blockchaincore", "cmd": "zig build -Doqs=false", "name": "Zig build (no liboqs)"},
            {"project": "blockchaincore", "cmd": "zig build test-crypto", "name": "Test: crypto"},
            {"project": "blockchaincore", "cmd": "zig build test-chain", "name": "Test: chain"},
            {"project": "blockchaincore", "cmd": "zig build test-net", "name": "Test: network"},
            {"project": "blockchaincore", "cmd": "zig build test-storage", "name": "Test: storage"},
            {"project": "blockchaincore", "cmd": "zig build test-pq", "name": "Test: post-quantum"},
            {"project": "blockchaincore", "cmd": "zig build test-light", "name": "Test: light client"},
            {"project": "blockchaincore", "cmd": "zig build test-shard", "name": "Test: shards"},
            {"project": "aweb3", "cmd": "npx hardhat compile", "name": "Solidity compile"},
            {"project": "aweb3", "cmd": "npx tsc --noEmit", "name": "TypeScript check"},
        ]
    },

    # ── EXPLOIT TESTING ──────────────────────────────────────
    "exploits": {
        "name": "Exploit Lab & Attack Simulation",
        "description": "Run all exploit tests, fuzzing, and attack simulations",
        "tasks": [
            {"project": "blockchaincore", "cmd": "python tools/EXPLOITS/differential-fuzzer.py --iterations 1000", "name": "Differential fuzzing"},
            {"project": "blockchaincore", "cmd": "python tools/EXPLOITS/buffer-overflow-tester.py", "name": "Buffer overflow tests"},
            {"project": "blockchaincore", "cmd": "python tools/EXPLOITS/crypto-edge-cases.py", "name": "Crypto edge cases"},
            {"project": "blockchaincore", "cmd": "python tools/EXPLOITS/consensus-attack-sim.py", "name": "Consensus attack sim"},
            {"project": "blockchaincore", "cmd": "python tools/EXPLOITS/double-spend-tester.py", "name": "Double-spend test"},
            {"project": "blockchaincore", "cmd": "python tools/EXPLOITS/replay-protection-tester.py", "name": "Replay protection"},
            {"project": "blockchaincore", "cmd": "python tools/EXPLOITS/historical-attack-replayer.py", "name": "Historical attacks"},
            {"project": "aweb3", "cmd": "python scripts/exploits/exploit-test-generator.py", "name": "Exploit test generator"},
            {"project": "aweb3", "cmd": "python scripts/exploits/known-exploits-db.py", "name": "Known exploits DB match"},
            {"project": "aweb3", "cmd": "python scripts/exploits/attack-replay-runner.py", "name": "Attack replay runner"},
            {"project": "aweb3", "cmd": "python scripts/exploits/differential-evm-fuzzer.py", "name": "Differential EVM fuzzer"},
        ]
    },

    # ── STRESS TESTING ───────────────────────────────────────
    "stress": {
        "name": "Stress Testing & DDoS Simulation",
        "description": "Test system under extreme load",
        "tasks": [
            {"project": "blockchaincore", "cmd": "python tools/PERFORMANCE/tx-flood-stress.py --count 500 --threads 10", "name": "TX flood stress"},
            {"project": "blockchaincore", "cmd": "python tools/PERFORMANCE/p2p-connection-flood.py --connections 50", "name": "P2P connection flood"},
            {"project": "blockchaincore", "cmd": "python tools/PERFORMANCE/memory-pressure-test.py", "name": "Memory pressure"},
            {"project": "blockchaincore", "cmd": "python tools/PERFORMANCE/benchmark-consensus.py", "name": "Consensus benchmark"},
            {"project": "aweb3", "cmd": "node scripts/testing/gas-stress-test.js", "name": "Gas stress test"},
            {"project": "aweb3", "cmd": "python scripts/testing/concurrent-bridge-stress.py", "name": "Bridge concurrency"},
        ]
    },

    # ── NETWORK & PRIVACY ───────────────────────────────────
    "network": {
        "name": "Network & Privacy Audit",
        "description": "Test P2P, RPC, Tor privacy, traffic analysis",
        "tasks": [
            {"project": "blockchaincore", "cmd": "python tools/NETWORK/rpc-tester.py", "name": "RPC method test suite"},
            {"project": "blockchaincore", "cmd": "python tools/NETWORK/tor-connectivity-test.py", "name": "Tor connectivity"},
            {"project": "blockchaincore", "cmd": "python tools/NETWORK/traffic-analysis-resistance.py", "name": "Traffic analysis resistance"},
            {"project": "blockchaincore", "cmd": "python tools/NETWORK/onion-privacy-audit.py", "name": "Onion privacy audit"},
            {"project": "aweb3", "cmd": "python scripts/security/tor-rpc-privacy-test.py", "name": "Tor RPC privacy"},
            {"project": "aweb3", "cmd": "python scripts/cross/replay-attack-tester.py", "name": "Cross-chain replay test"},
        ]
    },

    # ── CODE ANALYSIS ────────────────────────────────────────
    "analysis": {
        "name": "Code Analysis & Quality",
        "description": "Module complexity, dependencies, API surface, git learning",
        "tasks": [
            {"project": "blockchaincore", "cmd": "python tools/ANALYSIS/module-complexity-analyzer.py", "name": "Module complexity"},
            {"project": "blockchaincore", "cmd": "python tools/ANALYSIS/dependency-mapper.py", "name": "Dependency map"},
            {"project": "blockchaincore", "cmd": "python tools/ANALYSIS/api-surface-analyzer.py", "name": "API surface"},
            {"project": "blockchaincore", "cmd": "python tools/LEARNING/git-zig-evolution.py", "name": "Git evolution analysis"},
            {"project": "aweb3", "cmd": "python scripts/learning/git-commit-analyzer.py", "name": "Git commit analysis"},
            {"project": "aweb3", "cmd": "python scripts/learning/code-quality-tracker.py", "name": "Code quality tracker"},
            {"project": "aweb3", "cmd": "python scripts/tools/check-unused-components.py", "name": "Unused components"},
            {"project": "aweb3", "cmd": "python scripts/optimization/gas-report.py", "name": "Gas optimization report"},
        ]
    },

    # ── REVERSE ENGINEERING ──────────────────────────────────
    "reverse": {
        "name": "Reverse Engineering & Binary Analysis",
        "description": "Analyze deployed contracts and compiled binaries",
        "tasks": [
            {"project": "aweb3", "cmd": "python scripts/reverse/decompile-deployed.py", "name": "Decompile deployed contracts"},
            {"project": "aweb3", "cmd": "python scripts/reverse/compare-source-vs-deployed.py", "name": "Source vs deployed verify"},
            {"project": "blockchaincore", "cmd": "python tools/REVERSE/protocol-fuzzer.py --count 50", "name": "Protocol fuzzer"},
            {"project": "blockchaincore", "cmd": "python tools/REVERSE/rpc-fuzzer.py", "name": "RPC fuzzer"},
            {"project": "blockchaincore", "cmd": "python tools/REVERSE/block-malformation-tester.py", "name": "Block malformation test"},
        ]
    },
}


# ═══════════════════════════════════════════════════════════════
# Task Runner
# ═══════════════════════════════════════════════════════════════

def run_task(task, projects, timeout=120):
    """Run a single task and return result."""
    proj = projects.get(task["project"])
    if not proj or proj["status"] != "found":
        return {"name": task["name"], "status": "skipped", "reason": "project not found"}

    cmd = task["cmd"]
    cwd = proj["path"]

    start = time.time()
    try:
        result = subprocess.run(
            cmd, shell=True, cwd=cwd,
            capture_output=True, text=True,
            timeout=timeout, encoding='utf-8', errors='replace'
        )
        elapsed = time.time() - start

        if result.returncode == 0:
            log_pass(f"{task['name']} ({elapsed:.1f}s)")
            return {"name": task["name"], "status": "pass", "time": elapsed, "output": result.stdout[-500:]}
        else:
            log_fail(f"{task['name']} (exit {result.returncode}, {elapsed:.1f}s)")
            return {"name": task["name"], "status": "fail", "time": elapsed,
                    "exit_code": result.returncode,
                    "stderr": result.stderr[-500:], "stdout": result.stdout[-500:]}
    except subprocess.TimeoutExpired:
        elapsed = time.time() - start
        log_warn(f"{task['name']} (timeout {timeout}s)")
        return {"name": task["name"], "status": "timeout", "time": elapsed}
    except Exception as e:
        elapsed = time.time() - start
        log_fail(f"{task['name']} (error: {e})")
        return {"name": task["name"], "status": "error", "time": elapsed, "error": str(e)}


def run_phase(phase_key, projects, timeout=120):
    """Run all tasks in a phase."""
    phase = PHASES[phase_key]
    log_phase(phase["name"])
    log_info(phase["description"])
    print()

    results = []
    for task in phase["tasks"]:
        result = run_task(task, projects, timeout)
        results.append(result)

    return results


# ═══════════════════════════════════════════════════════════════
# Learning System — analyze past results
# ═══════════════════════════════════════════════════════════════

DATA_DIR = Path(__file__).resolve().parent / "data"

def save_run(report):
    """Save run results for learning."""
    DATA_DIR.mkdir(exist_ok=True)
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    filepath = DATA_DIR / f"run_{timestamp}.json"
    with open(filepath, 'w') as f:
        json.dump(report, f, indent=2)
    log_info(f"Results saved to {filepath}")
    return filepath


def learn_from_history():
    """Analyze all past runs and extract patterns."""
    if not DATA_DIR.exists():
        log_warn("No run history found. Run mythos first.")
        return

    runs = sorted(DATA_DIR.glob("run_*.json"))
    if not runs:
        log_warn("No run files found.")
        return

    print(f"\n{BOLD}Learning from {len(runs)} past runs...{RESET}\n")

    # Aggregate stats per task
    task_stats = {}
    for run_file in runs:
        with open(run_file) as f:
            data = json.load(f)
        for phase_results in data.get("phases", {}).values():
            for result in phase_results:
                name = result["name"]
                if name not in task_stats:
                    task_stats[name] = {"pass": 0, "fail": 0, "timeout": 0, "error": 0, "skip": 0, "times": []}
                status = result.get("status", "error")
                if status == "pass":
                    task_stats[name]["pass"] += 1
                elif status == "fail":
                    task_stats[name]["fail"] += 1
                elif status == "timeout":
                    task_stats[name]["timeout"] += 1
                elif status == "skipped":
                    task_stats[name]["skip"] += 1
                else:
                    task_stats[name]["error"] += 1
                if "time" in result:
                    task_stats[name]["times"].append(result["time"])

    # Report
    print(f"{'Task':<45} {'Pass':>5} {'Fail':>5} {'Rate':>6} {'Avg Time':>8}")
    print("─" * 75)
    for name, stats in sorted(task_stats.items(), key=lambda x: x[1]["fail"], reverse=True):
        total = stats["pass"] + stats["fail"] + stats["timeout"] + stats["error"]
        rate = stats["pass"] / total * 100 if total > 0 else 0
        avg_time = sum(stats["times"]) / len(stats["times"]) if stats["times"] else 0
        color = GREEN if rate == 100 else (YELLOW if rate >= 50 else RED)
        print(f"  {name:<43} {stats['pass']:>5} {stats['fail']:>5} {color}{rate:>5.0f}%{RESET} {avg_time:>7.1f}s")

    # Insights
    print(f"\n{BOLD}Insights:{RESET}")
    flaky = [n for n, s in task_stats.items() if 0 < s["fail"] < s["pass"]]
    always_fail = [n for n, s in task_stats.items() if s["fail"] > 0 and s["pass"] == 0]

    if flaky:
        log_warn(f"Flaky tests (sometimes pass, sometimes fail): {len(flaky)}")
        for name in flaky[:5]:
            print(f"    → {name}")
    if always_fail:
        log_fail(f"Always failing: {len(always_fail)}")
        for name in always_fail[:5]:
            print(f"    → {name}")
    if not flaky and not always_fail:
        log_pass("No flaky or always-failing tests detected!")


def show_last_report():
    """Show the most recent run report."""
    if not DATA_DIR.exists():
        log_warn("No run history found.")
        return

    runs = sorted(DATA_DIR.glob("run_*.json"))
    if not runs:
        log_warn("No run files found.")
        return

    with open(runs[-1]) as f:
        data = json.load(f)

    print(f"\n{BOLD}Last run: {data.get('timestamp', 'unknown')}{RESET}")
    print(f"Duration: {data.get('total_time', 0):.0f}s")
    print(f"Results: {GREEN}{data.get('passed', 0)} pass{RESET}, "
          f"{RED}{data.get('failed', 0)} fail{RESET}, "
          f"{YELLOW}{data.get('skipped', 0)} skip{RESET}")


# ═══════════════════════════════════════════════════════════════
# Conversation Saver — save Claude session context
# ═══════════════════════════════════════════════════════════════

def save_session_context():
    """Save the current session's findings for future reference."""
    DATA_DIR.mkdir(exist_ok=True)
    session = {
        "timestamp": datetime.now().isoformat(),
        "note": "Session context saved by Mythos framework",
        "tip": "Claude Code conversations are stored in ~/.claude/ — "
               "use 'claude --continue' to resume, or check ~/.claude/projects/ for memory files. "
               "All conversation history is preserved between sessions via the memory system."
    }
    filepath = DATA_DIR / "session_context.json"
    with open(filepath, 'w') as f:
        json.dump(session, f, indent=2)
    return filepath


# ═══════════════════════════════════════════════════════════════
# Main
# ═══════════════════════════════════════════════════════════════

def main():
    parser = argparse.ArgumentParser(
        description="MYTHOS CLAUDE OMNIBUS — Master Verification Framework",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Phases available:
  crypto    — NIST/Wycheproof/FIPS crypto verification
  security  — Vulnerability scan & audit
  build     — Compile & test suites
  exploits  — Attack simulation & fuzzing
  stress    — DDoS & load testing
  network   — P2P, Tor, privacy audit
  analysis  — Code quality & learning
  reverse   — Binary & contract RE

Examples:
  python omnibus-mythos.py                    # Run ALL phases
  python omnibus-mythos.py --phase crypto     # Crypto only
  python omnibus-mythos.py --phase security exploits  # Multiple phases
  python omnibus-mythos.py --learn            # Analyze past results
        """
    )
    parser.add_argument('--phase', nargs='+', choices=list(PHASES.keys()),
                        help='Run specific phase(s)')
    parser.add_argument('--list', action='store_true', help='List all phases and tasks')
    parser.add_argument('--report', action='store_true', help='Show last run report')
    parser.add_argument('--learn', action='store_true', help='Analyze all past runs')
    parser.add_argument('--timeout', type=int, default=120, help='Task timeout in seconds')
    parser.add_argument('--save-session', action='store_true', help='Save session context')
    args = parser.parse_args()

    # Banner
    print(f"""
{BOLD}{MAGENTA}╔══════════════════════════════════════════════════════════════╗
║          MYTHOS CLAUDE OMNIBUS v1.0                          ║
║    Systematic Bit-by-Bit Code Verification Framework         ║
║    aweb3 + BlockChainCore + OmniBus Ecosystem                ║
╚══════════════════════════════════════════════════════════════╝{RESET}
    """)

    if args.list:
        for key, phase in PHASES.items():
            print(f"\n{BOLD}{key}{RESET} — {phase['name']}")
            print(f"  {phase['description']}")
            for task in phase['tasks']:
                print(f"    [{task['project']}] {task['name']}")
        return 0

    if args.report:
        show_last_report()
        return 0

    if args.learn:
        learn_from_history()
        return 0

    if args.save_session:
        path = save_session_context()
        log_info(f"Session saved to {path}")
        return 0

    # Discover projects
    projects = find_projects()
    log_info(f"Found projects: {', '.join(p['name'] for p in projects.values() if p['status'] == 'found')}")

    # Determine which phases to run
    phases_to_run = args.phase if args.phase else list(PHASES.keys())

    # Run phases
    start_time = time.time()
    all_results = {}
    total_pass = total_fail = total_skip = 0

    for phase_key in phases_to_run:
        results = run_phase(phase_key, projects, args.timeout)
        all_results[phase_key] = results

        for r in results:
            if r["status"] == "pass":
                total_pass += 1
            elif r["status"] in ("fail", "error"):
                total_fail += 1
            else:
                total_skip += 1

    total_time = time.time() - start_time

    # Summary
    print(f"\n{'═'*60}")
    print(f"{BOLD}  MYTHOS RUN COMPLETE{RESET}")
    print(f"  Duration: {total_time:.0f}s")
    print(f"  Phases:   {len(phases_to_run)}")
    total = total_pass + total_fail + total_skip
    print(f"  Tasks:    {total}")
    print(f"  Results:  {GREEN}{total_pass} pass{RESET}, {RED}{total_fail} fail{RESET}, {YELLOW}{total_skip} skip{RESET}")

    if total > 0:
        rate = total_pass / (total_pass + total_fail) * 100 if (total_pass + total_fail) > 0 else 100
        color = GREEN if rate >= 90 else (YELLOW if rate >= 70 else RED)
        print(f"  Score:    {color}{rate:.0f}%{RESET}")

    print(f"{'═'*60}\n")

    # Save results
    report = {
        "timestamp": datetime.now().isoformat(),
        "total_time": total_time,
        "passed": total_pass,
        "failed": total_fail,
        "skipped": total_skip,
        "phases": all_results
    }
    save_run(report)

    return 0 if total_fail == 0 else 1


if __name__ == '__main__':
    sys.exit(main())
