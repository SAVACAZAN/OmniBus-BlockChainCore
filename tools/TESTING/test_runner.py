#!/usr/bin/env python3
"""
test_runner.py - OmniBus Blockchain Test Runner v2.0

Ruleaza toate testele Zig pentru blockchain cu raportare detaliata:
  - 8 grupuri de teste din build.zig
  - Teste individuale per modul
  - Teste din test/ directory
  - Verbose mode cu output complet
  - CI mode (JSON output)
  - Retry failed tests

Usage:
  python tools/test_runner.py                    # Run all test groups
  python tools/test_runner.py crypto             # Run test-crypto only
  python tools/test_runner.py --file secp256k1   # Run single module test
  python tools/test_runner.py --verbose          # Show full zig output
  python tools/test_runner.py --ci               # CI mode (JSON)
  python tools/test_runner.py --list             # List available tests
  python tools/test_runner.py --retry 2          # Retry failures N times
"""

import sys
import subprocess
import json
import argparse
import shutil
from pathlib import Path
from dataclasses import dataclass, field
from typing import List, Dict, Optional, Tuple
from datetime import datetime
from collections import defaultdict

ROOT = Path(__file__).parent.parent.parent
CORE = ROOT / "core"
TEST_DIR = ROOT / "test"

# =============================================================================
# TEST DEFINITIONS (matched to build.zig exactly)
# =============================================================================

TEST_GROUPS = {
    "crypto": {
        "command": "test-crypto",
        "description": "secp256k1 + BIP32 + SHA256 + RIPEMD160",
        "modules": ["secp256k1", "bip32_wallet", "crypto", "ripemd160"],
    },
    "chain": {
        "command": "test-chain",
        "description": "blockchain + genesis + consensus + mempool + database",
        "modules": ["block", "transaction", "blockchain", "genesis", "mempool",
                     "consensus", "database", "miner_genesis", "e2e_mining"],
    },
    "net": {
        "command": "test-net",
        "description": "P2P + sync + RPC + bootstrap + CLI",
        "modules": ["rpc_server", "p2p", "sync", "network", "node_launcher",
                     "bootstrap", "cli", "vault_reader"],
    },
    "shard": {
        "command": "test-shard",
        "description": "sub-blocks + sharding + blockchain v2",
        "modules": ["sub_block", "shard_config", "blockchain_v2"],
    },
    "storage": {
        "command": "test-storage",
        "description": "storage + binary codec + archive + state trie",
        "modules": ["storage", "binary_codec", "archive_manager", "prune_config",
                     "state_trie", "compact_transaction", "witness_data"],
    },
    "light": {
        "command": "test-light",
        "description": "light client + light miner + mining pool + encryption",
        "modules": ["light_client", "light_miner", "mining_pool", "key_encryption"],
    },
    "pq": {
        "command": "test-pq",
        "description": "Post-quantum crypto pure Zig (fara liboqs)",
        "modules": ["pq_crypto"],
    },
    "wallet": {
        "command": "test-wallet",
        "description": "Wallet cu PQ (necesita liboqs)",
        "modules": ["wallet"],
        "requires_liboqs": True,
    },
}

# Modules that can be tested individually but aren't in any group
EXTRA_TESTABLE = [
    "bread_ledger", "domain_minter", "spark_invariants", "ubi_distributor",
    "payment_channel", "bridge_relay", "oracle", "omni_brain",
    "synapse_priority", "os_mode", "metachain", "shard_coordinator",
    "vault_engine", "ws_server",
]

# =============================================================================
# COLORS
# =============================================================================

G = "\033[92m"; R = "\033[91m"; Y = "\033[93m"; B = "\033[94m"
C = "\033[96m"; W = "\033[0m"; BOLD = "\033[1m"; DIM = "\033[2m"

# =============================================================================
# DATA CLASSES
# =============================================================================

@dataclass
class TestResult:
    name: str
    command: str
    passed: bool
    output: str
    stderr: str = ""
    duration_ms: int = 0
    test_count: int = 0
    skip_count: int = 0
    fail_details: str = ""

@dataclass
class TestSuiteResult:
    group: str
    results: List[TestResult] = field(default_factory=list)
    total_duration_ms: int = 0

# =============================================================================
# PREREQUISITES CHECK
# =============================================================================

def check_prerequisites() -> List[str]:
    """Check if required tools are available."""
    issues = []

    # Check zig
    zig_path = shutil.which("zig")
    if not zig_path:
        issues.append("zig not found in PATH")
    else:
        try:
            r = subprocess.run(["zig", "version"], capture_output=True, text=True, timeout=5)
            print(f"  Zig: {r.stdout.strip()} ({zig_path})")
        except Exception:
            issues.append("zig found but cannot get version")

    # Check build.zig
    if not (ROOT / "build.zig").exists():
        issues.append("build.zig not found in project root")

    # Check core/
    if not CORE.exists():
        issues.append("core/ directory not found")
    else:
        zig_count = len(list(CORE.glob("*.zig")))
        print(f"  Core modules: {zig_count}")

    # Check liboqs (optional)
    liboqs_path = Path("C:/Kits work/limaje de programare/liboqs-src/build/lib/liboqs.a")
    if liboqs_path.exists():
        print(f"  liboqs: {G}available{W}")
    else:
        print(f"  liboqs: {Y}not found (wallet tests may fail){W}")

    return issues


# =============================================================================
# TEST EXECUTION
# =============================================================================

def run_zig_build_test(name: str, verbose: bool = False, timeout: int = 120) -> TestResult:
    """Run a zig build test target."""
    start = datetime.now()
    cmd = ["zig", "build", name]

    try:
        result = subprocess.run(
            cmd, cwd=ROOT,
            capture_output=True, text=True,
            timeout=timeout
        )
        duration = int((datetime.now() - start).total_seconds() * 1000)

        passed = result.returncode == 0
        output = result.stdout
        stderr = result.stderr

        # Parse test counts from output
        test_count = 0
        skip_count = 0
        for line in (output + stderr).splitlines():
            if "test" in line.lower() and "passed" in line.lower():
                try:
                    test_count = int(re.search(r'(\d+)\s+passed', line).group(1))
                except Exception:
                    pass
            if "skipped" in line.lower():
                try:
                    skip_count = int(re.search(r'(\d+)\s+skipped', line).group(1))
                except Exception:
                    pass

        # Extract failure details
        fail_details = ""
        if not passed:
            lines = stderr.strip().split('\n')
            fail_details = '\n'.join(lines[-10:])

        return TestResult(
            name=name, command=' '.join(cmd), passed=passed,
            output=output, stderr=stderr,
            duration_ms=duration, test_count=test_count,
            skip_count=skip_count, fail_details=fail_details
        )

    except subprocess.TimeoutExpired:
        duration = int((datetime.now() - start).total_seconds() * 1000)
        return TestResult(
            name=name, command=' '.join(cmd), passed=False,
            output="", stderr=f"TIMEOUT after {timeout}s",
            duration_ms=duration, fail_details=f"Timeout after {timeout}s"
        )
    except FileNotFoundError:
        return TestResult(
            name=name, command=' '.join(cmd), passed=False,
            output="", stderr="zig not found in PATH",
            duration_ms=0, fail_details="zig binary not found"
        )
    except Exception as e:
        return TestResult(
            name=name, command=' '.join(cmd), passed=False,
            output="", stderr=str(e),
            duration_ms=0, fail_details=str(e)
        )


def run_single_module_test(module_name: str, verbose: bool = False) -> TestResult:
    """Run test for a single .zig file using zig test."""
    # Try core/ first, then test/
    module_path = CORE / f"{module_name}.zig"
    if not module_path.exists():
        module_path = TEST_DIR / f"{module_name}.zig"
    if not module_path.exists():
        return TestResult(
            name=module_name, command="", passed=False,
            output="", stderr=f"Module not found: {module_name}.zig",
            fail_details=f"File not found in core/ or test/"
        )

    start = datetime.now()
    cmd = ["zig", "test", str(module_path)]

    try:
        result = subprocess.run(
            cmd, cwd=ROOT,
            capture_output=True, text=True,
            timeout=60
        )
        duration = int((datetime.now() - start).total_seconds() * 1000)

        return TestResult(
            name=module_name, command=' '.join(cmd),
            passed=result.returncode == 0,
            output=result.stdout, stderr=result.stderr,
            duration_ms=duration,
            fail_details=result.stderr[-500:] if result.returncode != 0 else ""
        )
    except subprocess.TimeoutExpired:
        return TestResult(
            name=module_name, command=' '.join(cmd), passed=False,
            output="", stderr="TIMEOUT", duration_ms=60000,
            fail_details="Timeout after 60s"
        )
    except Exception as e:
        return TestResult(
            name=module_name, command=' '.join(cmd), passed=False,
            output="", stderr=str(e), duration_ms=0,
            fail_details=str(e)
        )


def run_test_directory() -> List[TestResult]:
    """Run all test files from test/ directory."""
    results = []
    if not TEST_DIR.exists():
        return results

    for f in sorted(TEST_DIR.glob("*.zig")):
        print(f"    {DIM}test/{f.name}{W}", end='', flush=True)
        r = run_single_module_test(f.stem)
        status = f"{G}PASS{W}" if r.passed else f"{R}FAIL{W}"
        print(f"\r    [{status}] test/{f.name} ({r.duration_ms}ms)")
        results.append(r)

    return results


# =============================================================================
# REPORT
# =============================================================================

def print_group_result(group_name: str, info: dict, result: TestResult):
    """Print result for a test group."""
    status = f"{G}PASS{W}" if result.passed else f"{R}FAIL{W}"
    liboqs = f" {Y}(liboqs){W}" if info.get("requires_liboqs") else ""
    print(f"  [{status}] {group_name:<12} {result.duration_ms:>6}ms  "
          f"{DIM}{info['description']}{W}{liboqs}")

    if not result.passed and result.fail_details:
        for line in result.fail_details.split('\n')[-3:]:
            if line.strip():
                print(f"         {R}{line.strip()[:80]}{W}")


def print_summary(group_results: Dict[str, TestResult], extra_results: List[TestResult]):
    """Print full test summary."""
    all_results = list(group_results.values()) + extra_results

    passed = sum(1 for r in all_results if r.passed)
    failed = len(all_results) - passed
    total_ms = sum(r.duration_ms for r in all_results)

    print(f"\n{'=' * 60}")
    print(f"  {BOLD}TEST SUMMARY{W}")
    print(f"{'=' * 60}")

    # Groups
    for name, result in group_results.items():
        status = f"{G}PASS{W}" if result.passed else f"{R}FAIL{W}"
        print(f"  [{status}] {name:<20} ({result.duration_ms}ms)")

    # Extra (test/ dir)
    if extra_results:
        print(f"\n  {C}test/ directory:{W}")
        for r in extra_results:
            status = f"{G}PASS{W}" if r.passed else f"{R}FAIL{W}"
            print(f"  [{status}] {r.name:<20} ({r.duration_ms}ms)")

    print(f"\n{'-' * 60}")
    total_str = f"{G}{passed} passed{W}" if failed == 0 else f"{G}{passed} passed{W}, {R}{failed} failed{W}"
    print(f"  Total: {len(all_results)} | {total_str} | {total_ms}ms")
    print(f"{'=' * 60}\n")

    return failed == 0


def export_json(group_results: Dict[str, TestResult], extra_results: List[TestResult], path: Path):
    """Export results to JSON."""
    all_results = list(group_results.values()) + extra_results
    data = {
        "tool": "test_runner",
        "version": "2.0",
        "timestamp": datetime.now().isoformat(),
        "total": len(all_results),
        "passed": sum(1 for r in all_results if r.passed),
        "failed": sum(1 for r in all_results if not r.passed),
        "total_duration_ms": sum(r.duration_ms for r in all_results),
        "groups": {
            name: {
                "passed": r.passed,
                "duration_ms": r.duration_ms,
                "command": r.command,
                "fail_details": r.fail_details if not r.passed else "",
            }
            for name, r in group_results.items()
        },
        "test_files": [
            {
                "name": r.name,
                "passed": r.passed,
                "duration_ms": r.duration_ms,
                "command": r.command,
            }
            for r in extra_results
        ]
    }
    with open(path, 'w') as f:
        json.dump(data, f, indent=2)
    print(f"  Results exported to: {path}")


# =============================================================================
# MAIN
# =============================================================================

import re

def main():
    parser = argparse.ArgumentParser(description="OmniBus Blockchain Test Runner v2.0")
    parser.add_argument("test", nargs="?", help="Test group to run (crypto/chain/net/shard/storage/light/pq/wallet)")
    parser.add_argument("--file", "-f", help="Test a single module by name")
    parser.add_argument("--verbose", "-v", action="store_true", help="Show full zig output")
    parser.add_argument("--ci", action="store_true", help="CI mode (JSON output)")
    parser.add_argument("--json", metavar="FILE", help="Export JSON report")
    parser.add_argument("--list", "-l", action="store_true", help="List available tests")
    parser.add_argument("--retry", type=int, default=0, help="Retry failed tests N times")
    parser.add_argument("--test-dir", action="store_true", help="Also run tests from test/ directory")
    parser.add_argument("--timeout", type=int, default=120, help="Timeout per test group (seconds)")
    args = parser.parse_args()

    print(f"\n{'=' * 60}")
    print(f"  {BOLD}OmniBus Blockchain Test Runner v2.0{W}")
    print(f"{'=' * 60}\n")

    # List mode
    if args.list:
        print(f"  {BOLD}Test Groups (from build.zig):{W}")
        for name, info in TEST_GROUPS.items():
            liboqs = " (requires liboqs)" if info.get("requires_liboqs") else ""
            print(f"    {C}{name:<10}{W} {info['description']}{liboqs}")
            print(f"             modules: {', '.join(info['modules'])}")
        print(f"\n  {BOLD}Test Files (test/ directory):{W}")
        if TEST_DIR.exists():
            for f in sorted(TEST_DIR.glob("*.zig")):
                print(f"    {f.stem}")
        print(f"\n  {BOLD}Extra Testable Modules:{W}")
        for m in EXTRA_TESTABLE:
            exists = (CORE / f"{m}.zig").exists()
            mark = G + "+" + W if exists else R + "-" + W
            print(f"    [{mark}] {m}")
        return

    # Prerequisites
    issues = check_prerequisites()
    if issues:
        for i in issues:
            print(f"  {R}ERROR: {i}{W}")
        sys.exit(1)
    print()

    group_results = {}
    extra_results = []

    # Single file mode
    if args.file:
        print(f"  Testing module: {args.file}")
        result = run_single_module_test(args.file, args.verbose)
        status = f"{G}PASS{W}" if result.passed else f"{R}FAIL{W}"
        print(f"  [{status}] {args.file} ({result.duration_ms}ms)")
        if args.verbose and (result.output or result.stderr):
            print(f"\n{DIM}{result.output}{result.stderr}{W}")
        if not result.passed and result.fail_details:
            print(f"\n  {R}Error:{W}\n{result.fail_details}")
        sys.exit(0 if result.passed else 1)

    # Specific group
    if args.test:
        if args.test not in TEST_GROUPS:
            print(f"  {R}Unknown test group: {args.test}{W}")
            print(f"  Available: {', '.join(TEST_GROUPS.keys())}")
            sys.exit(1)
        info = TEST_GROUPS[args.test]
        print(f"  Running: {args.test} - {info['description']}")
        result = run_zig_build_test(info['command'], args.verbose, args.timeout)
        print_group_result(args.test, info, result)
        if args.verbose and (result.output or result.stderr):
            print(f"\n{DIM}{result.output}{result.stderr}{W}")
        group_results[args.test] = result
    else:
        # All groups
        print(f"  {BOLD}Running all test groups...{W}\n")
        for name, info in TEST_GROUPS.items():
            result = run_zig_build_test(info['command'], args.verbose, args.timeout)

            # Retry logic
            retries = 0
            while not result.passed and retries < args.retry:
                retries += 1
                print(f"    {Y}Retry {retries}/{args.retry}...{W}")
                result = run_zig_build_test(info['command'], args.verbose, args.timeout)

            print_group_result(name, info, result)
            if args.verbose and result.stderr:
                print(f"    {DIM}{result.stderr[:200]}{W}")
            group_results[name] = result

    # Test directory
    if args.test_dir or (not args.test and not args.file):
        if TEST_DIR.exists() and list(TEST_DIR.glob("*.zig")):
            print(f"\n  {BOLD}Running test/ directory...{W}")
            extra_results = run_test_directory()

    # Summary
    all_passed = print_summary(group_results, extra_results)

    # Export
    json_path = Path(args.json) if args.json else (Path("test_results.json") if args.ci else None)
    if json_path:
        export_json(group_results, extra_results, json_path)

    sys.exit(0 if all_passed else 1)

if __name__ == "__main__":
    main()
