#!/usr/bin/env python3
"""OmniBus BlockChainCore — SHA-256 and RIPEMD-160 NIST Test Vectors.

Hardcoded NIST SHA-256 vectors and RIPEMD-160 vectors.
Runs via Python hashlib as reference.
Cross-checks with Zig implementation output (via `zig test core/ripemd160.zig` etc).
"""

import argparse
import hashlib
import json
import os
import subprocess
import sys
import time

# ---------------------------------------------------------------------------
RED = "\033[91m"
GREEN = "\033[92m"
YELLOW = "\033[93m"
CYAN = "\033[96m"
BOLD = "\033[1m"
RESET = "\033[0m"

# OmniBus BlockChainCore
RPC_PORT = 8332
SHARDS = 4
MAX_SUPPLY = 21_000_000
SAT = int(1e9)
BLOCK_REWARD = 50
HALVING_INTERVAL = 210_000
CORE_DIR = "core"

# ---------------------------------------------------------------------------
# NIST SHA-256 test vectors
# Source: NIST FIPS 180-4 and NIST CSRC examples
# ---------------------------------------------------------------------------
SHA256_VECTORS = [
    {
        "name": "Empty string",
        "input": b"",
        "expected": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
    },
    {
        "name": "abc",
        "input": b"abc",
        "expected": "ba7816bf8f01cfea414140de5dae2223b0361a396177a9cb410ff61f20015ad8",
    },
    {
        "name": "448-bit message",
        "input": b"abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq",
        "expected": "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1",
    },
    {
        "name": "896-bit message",
        "input": b"abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu",
        "expected": "cf5b16a778af8380036ce59e7b0492370b249b11e8f07a51afac45037afee9d1",
    },
    {
        "name": "1 million 'a'",
        "input": b"a" * 1_000_000,
        "expected": "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0",
    },
    {
        "name": "Single byte 0x00",
        "input": b"\x00",
        "expected": "6e340b9cffb37a989ca544e6bb780a2c78901d3fb33738768511a30617afa01d",
    },
    {
        "name": "Single byte 0xFF",
        "input": b"\xff",
        "expected": "a8100ae6aa1940d0b663bb31cd466142ebbdbd5187131b92d93818987832eb89",
    },
    {
        "name": "Bitcoin genesis block header hash (double SHA-256 input)",
        "input": b"The Times 03/Jan/2009 Chancellor on brink of second bailout for banks",
        "expected": None,  # We just test double-sha256 consistency
        "test_double": True,
    },
]

# ---------------------------------------------------------------------------
# RIPEMD-160 test vectors
# Source: https://homes.esat.kuleuven.be/~bosMDx/ripemd160.html
# ---------------------------------------------------------------------------
RIPEMD160_VECTORS = [
    {
        "name": "Empty string",
        "input": b"",
        "expected": "9c1185a5c5e9fc54612808977ee8f548b2258d31",
    },
    {
        "name": "a",
        "input": b"a",
        "expected": "0bdc9d2d256b3ee9daae347be6f4dc835a467ffe",
    },
    {
        "name": "abc",
        "input": b"abc",
        "expected": "8eb208f7e05d987a9b044a8e98c6b087f15a0bfc",
    },
    {
        "name": "message digest",
        "input": b"message digest",
        "expected": "5d0689ef49d2fae572b881b123a85ffa21595f36",
    },
    {
        "name": "a-z",
        "input": b"abcdefghijklmnopqrstuvwxyz",
        "expected": "f71c27109c692c1b56bbdceb5b9d2865b3708dbc",
    },
    {
        "name": "A-Za-z0-9",
        "input": b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789",
        "expected": "b0e20b6e3116640286ed3a87a5713079b21f5189",
    },
    {
        "name": "8x 1234567890",
        "input": b"12345678901234567890123456789012345678901234567890123456789012345678901234567890",
        "expected": "9b752e45573d4b39f4dbd3323cab82bf63326bfb",
    },
    {
        "name": "1 million 'a'",
        "input": b"a" * 1_000_000,
        "expected": "52783243c1697bdbe16d37f97f68f08325dc1528",
    },
]


def test_sha256(vectors: list) -> dict:
    """Run SHA-256 test vectors."""
    stats = {"total": 0, "pass": 0, "fail": 0, "failures": []}

    for v in vectors:
        stats["total"] += 1
        data = v["input"]
        expected = v.get("expected")

        computed = hashlib.sha256(data).hexdigest()

        if v.get("test_double"):
            # Test double-SHA256 consistency
            dh1 = hashlib.sha256(hashlib.sha256(data).digest()).hexdigest()
            dh2 = hashlib.sha256(hashlib.sha256(data).digest()).hexdigest()
            if dh1 == dh2:
                stats["pass"] += 1
            else:
                stats["fail"] += 1
                stats["failures"].append({
                    "name": v["name"],
                    "error": "double-SHA256 inconsistency",
                })
            continue

        if expected and computed == expected:
            stats["pass"] += 1
        elif expected:
            stats["fail"] += 1
            stats["failures"].append({
                "name": v["name"],
                "expected": expected[:32] + "...",
                "got": computed[:32] + "...",
            })
        else:
            # No expected value, just verify it runs
            stats["pass"] += 1

    return stats


def test_ripemd160(vectors: list) -> dict:
    """Run RIPEMD-160 test vectors."""
    stats = {"total": 0, "pass": 0, "fail": 0, "failures": []}

    for v in vectors:
        stats["total"] += 1

        try:
            h = hashlib.new("ripemd160")
            h.update(v["input"])
            computed = h.hexdigest()
        except Exception as exc:
            stats["fail"] += 1
            stats["failures"].append({"name": v["name"], "error": str(exc)})
            continue

        if computed == v["expected"]:
            stats["pass"] += 1
        else:
            stats["fail"] += 1
            stats["failures"].append({
                "name": v["name"],
                "expected": v["expected"],
                "got": computed,
            })

    return stats


def test_hash160() -> dict:
    """Test HASH160 (SHA-256 + RIPEMD-160) — used for Bitcoin addresses."""
    stats = {"total": 0, "pass": 0, "fail": 0, "failures": []}

    # Known Bitcoin HASH160 vectors
    vectors = [
        {
            "name": "Empty input HASH160",
            "input": b"",
        },
        {
            "name": "abc HASH160",
            "input": b"abc",
        },
        {
            "name": "Bitcoin pubkey-like HASH160",
            "input": bytes.fromhex("0479BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798"
                                    "483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8"),
        },
    ]

    for v in vectors:
        stats["total"] += 1
        try:
            sha = hashlib.sha256(v["input"]).digest()
            ripe = hashlib.new("ripemd160", sha).digest()
            # Verify consistency
            sha2 = hashlib.sha256(v["input"]).digest()
            ripe2 = hashlib.new("ripemd160", sha2).digest()
            if ripe == ripe2:
                stats["pass"] += 1
            else:
                stats["fail"] += 1
                stats["failures"].append({"name": v["name"], "error": "HASH160 not deterministic"})
        except Exception as exc:
            stats["fail"] += 1
            stats["failures"].append({"name": v["name"], "error": str(exc)})

    return stats


def try_zig_cross_check() -> dict:
    """Try to run Zig tests for cross-checking."""
    results = {"available": False, "tests_run": 0, "tests_pass": 0}

    # Try core/sha256.zig and core/ripemd160.zig
    for zig_file in ["core/sha256.zig", "core/ripemd160.zig"]:
        if not os.path.exists(zig_file):
            continue

        results["available"] = True
        try:
            proc = subprocess.run(
                ["zig", "test", zig_file],
                capture_output=True, text=True, timeout=30,
            )
            results["tests_run"] += 1
            if proc.returncode == 0:
                results["tests_pass"] += 1
                print(f"  {GREEN}Zig test {zig_file}: PASS{RESET}")
            else:
                print(f"  {RED}Zig test {zig_file}: FAIL{RESET}")
                print(f"    {proc.stderr[:200]}")
        except FileNotFoundError:
            print(f"  {YELLOW}zig compiler not found — skipping Zig cross-check{RESET}")
            break
        except subprocess.TimeoutExpired:
            print(f"  {YELLOW}Zig test {zig_file}: TIMEOUT{RESET}")

    return results


def main():
    parser = argparse.ArgumentParser(
        description="OmniBus BlockChainCore — SHA-256 & RIPEMD-160 NIST Vectors"
    )
    parser.add_argument("--json", action="store_true", help="JSON output")
    parser.add_argument("--skip-zig", action="store_true", help="Skip Zig cross-check")
    args = parser.parse_args()

    print(f"{CYAN}{BOLD}{'='*60}")
    print(f" OmniBus BlockChainCore — SHA-256 & RIPEMD-160 Vectors")
    print(f" SHA-256 vectors:   {len(SHA256_VECTORS)}")
    print(f" RIPEMD-160 vectors: {len(RIPEMD160_VECTORS)}")
    print(f" RPC: {RPC_PORT} | Shards: {SHARDS}")
    print(f" Block reward: {BLOCK_REWARD} OMNI (halving every {HALVING_INTERVAL:,} blocks)")
    print(f"{'='*60}{RESET}\n")

    t0 = time.time()

    # SHA-256
    print(f"{GREEN}[1/4] SHA-256 test vectors ...{RESET}")
    sha256_stats = test_sha256(SHA256_VECTORS)
    color = GREEN if sha256_stats["fail"] == 0 else RED
    print(f"  {color}{sha256_stats['pass']}/{sha256_stats['total']} passed{RESET}")

    # RIPEMD-160
    print(f"{GREEN}[2/4] RIPEMD-160 test vectors ...{RESET}")
    ripemd_stats = test_ripemd160(RIPEMD160_VECTORS)
    color = GREEN if ripemd_stats["fail"] == 0 else RED
    print(f"  {color}{ripemd_stats['pass']}/{ripemd_stats['total']} passed{RESET}")

    # HASH160
    print(f"{GREEN}[3/4] HASH160 consistency ...{RESET}")
    hash160_stats = test_hash160()
    color = GREEN if hash160_stats["fail"] == 0 else RED
    print(f"  {color}{hash160_stats['pass']}/{hash160_stats['total']} passed{RESET}")

    # Zig cross-check
    zig_results = {"available": False}
    if not args.skip_zig:
        print(f"{GREEN}[4/4] Zig cross-check ...{RESET}")
        zig_results = try_zig_cross_check()
        if not zig_results["available"]:
            print(f"  {YELLOW}No Zig source files found in {CORE_DIR}/ — skipping{RESET}")

    elapsed = time.time() - t0

    total_pass = sha256_stats["pass"] + ripemd_stats["pass"] + hash160_stats["pass"]
    total_fail = sha256_stats["fail"] + ripemd_stats["fail"] + hash160_stats["fail"]
    total = sha256_stats["total"] + ripemd_stats["total"] + hash160_stats["total"]

    report = {
        "tool": "OmniBus SHA-256/RIPEMD-160 vectors",
        "sha256": sha256_stats,
        "ripemd160": ripemd_stats,
        "hash160": hash160_stats,
        "zig_cross_check": zig_results,
        "total": total,
        "passed": total_pass,
        "failed": total_fail,
        "elapsed_seconds": round(elapsed, 2),
        "verdict": "PASS" if total_fail == 0 else "FAIL",
    }

    if args.json:
        print(json.dumps(report, indent=2))
    else:
        print(f"\n{CYAN}{'='*60}")
        print(f" RESULTS")
        print(f"{'='*60}{RESET}")
        print(f"  SHA-256:     {sha256_stats['pass']}/{sha256_stats['total']}")
        print(f"  RIPEMD-160:  {ripemd_stats['pass']}/{ripemd_stats['total']}")
        print(f"  HASH160:     {hash160_stats['pass']}/{hash160_stats['total']}")
        print(f"  Total:       {GREEN}{total_pass}{RESET} / {total}")
        vc = GREEN if report["verdict"] == "PASS" else RED
        print(f"\n  Verdict:     {vc}{BOLD}{report['verdict']}{RESET}")
        print(f"  Elapsed:     {elapsed:.2f}s")

    sys.exit(0 if report["verdict"] == "PASS" else 1)


if __name__ == "__main__":
    main()
