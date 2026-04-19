#!/usr/bin/env python3
"""OmniBus BlockChainCore — FIPS 140-2 Statistical Randomness Tests.

Generates 20000 bits (2500 bytes) of random data and runs:
  - Monobit test: count of 1s should be 9725-10275 (out of 20000)
  - Poker test: divide into 5000 4-bit groups, chi-squared
  - Runs test: count sequences of consecutive same bits
  - Long runs test: no run of 26+ same bits

If node has no RPC for random, uses /dev/urandom as baseline.
"""

import argparse
import http.client
import json
import math
import os
import secrets
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
P2P_PORT = 9000
SHARDS = 4
SUB_BLOCKS = 10  # 10 x 0.1s
MAX_SUPPLY = 21_000_000
SAT = int(1e9)
BLOCK_REWARD = 50
HALVING_INTERVAL = 210_000
CHAIN_DATA = "omnibus-chain.dat"

# FIPS 140-2 constants
BITS_REQUIRED = 20000
BYTES_REQUIRED = BITS_REQUIRED // 8  # 2500


def bytes_to_bits(data: bytes) -> list:
    """Convert bytes to list of bits."""
    bits = []
    for byte in data:
        for i in range(7, -1, -1):
            bits.append((byte >> i) & 1)
    return bits


def get_random_from_node(host: str, port: int, num_bytes: int) -> bytes:
    """Try to get random bytes from node RPC."""
    payload = json.dumps({
        "jsonrpc": "2.0", "id": 1,
        "method": "getrandom",
        "params": [num_bytes],
    })
    try:
        conn = http.client.HTTPConnection(host, port, timeout=5)
        conn.request("POST", "/", payload, {"Content-Type": "application/json"})
        resp = conn.getresponse()
        data = json.loads(resp.read().decode())
        conn.close()
        if "result" in data and data["result"]:
            return bytes.fromhex(data["result"])
    except Exception:
        pass
    return None


def get_random_from_urandom(num_bytes: int) -> bytes:
    """Get random bytes from OS CSPRNG."""
    return secrets.token_bytes(num_bytes)


# ---------------------------------------------------------------------------
# FIPS 140-2 Statistical Tests
# ---------------------------------------------------------------------------
def monobit_test(bits: list) -> dict:
    """FIPS 140-2 Monobit Test.
    Count of 1-bits in 20000 bits should be 9725..10275.
    """
    ones = sum(bits)
    passed = 9725 <= ones <= 10275
    return {
        "test": "monobit",
        "ones": ones,
        "zeros": len(bits) - ones,
        "range": "9725-10275",
        "passed": passed,
    }


def poker_test(bits: list) -> dict:
    """FIPS 140-2 Poker Test.
    Divide 20000 bits into 5000 4-bit groups.
    Compute chi-squared: X = (16/5000) * sum(f_i^2) - 5000
    Must be 2.16 < X < 46.17
    """
    if len(bits) < 20000:
        return {"test": "poker", "passed": False, "error": "insufficient bits"}

    # Count frequencies of each 4-bit pattern
    freq = [0] * 16
    for i in range(0, 20000, 4):
        nibble = (bits[i] << 3) | (bits[i+1] << 2) | (bits[i+2] << 1) | bits[i+3]
        freq[nibble] += 1

    # Chi-squared
    sum_sq = sum(f * f for f in freq)
    X = (16.0 / 5000.0) * sum_sq - 5000.0

    passed = 2.16 < X < 46.17

    return {
        "test": "poker",
        "chi_squared": round(X, 4),
        "range": "2.16-46.17",
        "passed": passed,
        "freq_distribution": freq,
    }


def runs_test(bits: list) -> dict:
    """FIPS 140-2 Runs Test.
    Count runs (sequences of same bit) of length 1-6+.
    Each length must fall within specified range.
    """
    # FIPS 140-2 ranges for 20000 bits
    ranges = {
        1: (2315, 2685),
        2: (1114, 1386),
        3: (527, 723),
        4: (240, 384),
        5: (103, 209),
        6: (103, 209),  # 6+ grouped
    }

    runs_0 = {i: 0 for i in range(1, 7)}  # runs of 0s
    runs_1 = {i: 0 for i in range(1, 7)}  # runs of 1s

    current_bit = bits[0]
    run_length = 1

    for i in range(1, len(bits)):
        if bits[i] == current_bit:
            run_length += 1
        else:
            # Record the run
            capped = min(run_length, 6)
            if current_bit == 0:
                runs_0[capped] += 1
            else:
                runs_1[capped] += 1
            current_bit = bits[i]
            run_length = 1

    # Record final run
    capped = min(run_length, 6)
    if current_bit == 0:
        runs_0[capped] += 1
    else:
        runs_1[capped] += 1

    # Check ranges
    all_passed = True
    details = []
    for length in range(1, 7):
        low, high = ranges[length]
        count_0 = runs_0[length]
        count_1 = runs_1[length]
        pass_0 = low <= count_0 <= high
        pass_1 = low <= count_1 <= high
        if not pass_0 or not pass_1:
            all_passed = False
        details.append({
            "length": length if length < 6 else "6+",
            "runs_of_0": count_0,
            "runs_of_1": count_1,
            "range": f"{low}-{high}",
            "passed": pass_0 and pass_1,
        })

    return {
        "test": "runs",
        "passed": all_passed,
        "details": details,
    }


def long_runs_test(bits: list) -> dict:
    """FIPS 140-2 Long Runs Test.
    No run of 26 or more consecutive identical bits.
    """
    max_run = 1
    current_run = 1

    for i in range(1, len(bits)):
        if bits[i] == bits[i-1]:
            current_run += 1
            max_run = max(max_run, current_run)
        else:
            current_run = 1

    passed = max_run < 26

    return {
        "test": "long_runs",
        "max_run_length": max_run,
        "threshold": 26,
        "passed": passed,
    }


def autocorrelation_test(bits: list, shift: int = 1) -> dict:
    """Additional: autocorrelation test (not FIPS required but useful)."""
    n = len(bits)
    matches = sum(1 for i in range(n - shift) if bits[i] == bits[i + shift])
    ratio = matches / (n - shift)
    # Should be close to 0.5
    deviation = abs(ratio - 0.5)
    passed = deviation < 0.02  # Within 2%

    return {
        "test": "autocorrelation",
        "shift": shift,
        "match_ratio": round(ratio, 6),
        "deviation_from_half": round(deviation, 6),
        "passed": passed,
    }


def main():
    parser = argparse.ArgumentParser(
        description="OmniBus BlockChainCore — FIPS 140-2 Randomness Tests"
    )
    parser.add_argument("--rpc-host", default="127.0.0.1", help="Node RPC host")
    parser.add_argument("--source", choices=["node", "urandom", "both"],
                        default="both",
                        help="Random source (default: both)")
    parser.add_argument("--json", action="store_true", help="JSON output")
    args = parser.parse_args()

    print(f"{CYAN}{BOLD}{'='*60}")
    print(f" OmniBus BlockChainCore — FIPS 140-2 Randomness Tests")
    print(f" Bits: {BITS_REQUIRED} | Bytes: {BYTES_REQUIRED}")
    print(f" RPC: {args.rpc_host}:{RPC_PORT}")
    print(f" Source: {args.source}")
    print(f" Chain: {CHAIN_DATA} | Shards: {SHARDS}")
    print(f"{'='*60}{RESET}\n")

    sources = {}

    # Try node RPC
    if args.source in ("node", "both"):
        print(f"{GREEN}[SOURCE] Attempting node RPC ...{RESET}")
        node_random = get_random_from_node(args.rpc_host, RPC_PORT, BYTES_REQUIRED)
        if node_random:
            sources["node_rpc"] = node_random
            print(f"  {GREEN}Got {len(node_random)} bytes from node{RESET}")
        else:
            print(f"  {YELLOW}Node PRNG not available via RPC{RESET}")
            if args.source == "node":
                print(f"  {YELLOW}Node needs getrandom RPC method for PRNG testing{RESET}")

    # OS CSPRNG
    if args.source in ("urandom", "both"):
        print(f"{GREEN}[SOURCE] OS CSPRNG (urandom) ...{RESET}")
        sources["urandom"] = get_random_from_urandom(BYTES_REQUIRED)
        print(f"  {GREEN}Got {BYTES_REQUIRED} bytes from OS CSPRNG{RESET}")

    if not sources:
        print(f"{RED}[ERROR] No random source available{RESET}")
        sys.exit(1)

    all_results = {}
    t0 = time.time()

    for source_name, random_bytes in sources.items():
        print(f"\n{CYAN}{BOLD}--- Testing source: {source_name} ---{RESET}")

        bits = bytes_to_bits(random_bytes)
        if len(bits) < BITS_REQUIRED:
            print(f"{RED}  Insufficient bits: {len(bits)} < {BITS_REQUIRED}{RESET}")
            continue

        bits = bits[:BITS_REQUIRED]  # Trim to exactly 20000

        results = []

        # 1. Monobit
        print(f"  {GREEN}[1/5] Monobit test ...{RESET}", end=" ")
        r = monobit_test(bits)
        results.append(r)
        color = GREEN if r["passed"] else RED
        print(f"{color}{'PASS' if r['passed'] else 'FAIL'} (ones={r['ones']}){RESET}")

        # 2. Poker
        print(f"  {GREEN}[2/5] Poker test ...{RESET}", end=" ")
        r = poker_test(bits)
        results.append(r)
        color = GREEN if r["passed"] else RED
        print(f"{color}{'PASS' if r['passed'] else 'FAIL'} (X={r.get('chi_squared', 'N/A')}){RESET}")

        # 3. Runs
        print(f"  {GREEN}[3/5] Runs test ...{RESET}", end=" ")
        r = runs_test(bits)
        results.append(r)
        color = GREEN if r["passed"] else RED
        print(f"{color}{'PASS' if r['passed'] else 'FAIL'}{RESET}")

        # 4. Long runs
        print(f"  {GREEN}[4/5] Long runs test ...{RESET}", end=" ")
        r = long_runs_test(bits)
        results.append(r)
        color = GREEN if r["passed"] else RED
        print(f"{color}{'PASS' if r['passed'] else 'FAIL'} (max={r['max_run_length']}){RESET}")

        # 5. Autocorrelation (bonus)
        print(f"  {GREEN}[5/5] Autocorrelation test ...{RESET}", end=" ")
        r = autocorrelation_test(bits)
        results.append(r)
        color = GREEN if r["passed"] else RED
        print(f"{color}{'PASS' if r['passed'] else 'FAIL'} "
              f"(deviation={r['deviation_from_half']}){RESET}")

        all_passed = all(r["passed"] for r in results)
        all_results[source_name] = {
            "tests": results,
            "all_passed": all_passed,
        }

    elapsed = time.time() - t0

    # Overall verdict
    overall_pass = all(v["all_passed"] for v in all_results.values())

    report = {
        "tool": "OmniBus FIPS 140-2 compliance",
        "bits_tested": BITS_REQUIRED,
        "sources": {k: {"all_passed": v["all_passed"],
                        "tests": [t["test"] + ": " + ("PASS" if t["passed"] else "FAIL")
                                  for t in v["tests"]]}
                    for k, v in all_results.items()},
        "elapsed_seconds": round(elapsed, 2),
        "verdict": "PASS" if overall_pass else "FAIL",
        "note": ("Node PRNG testing requires integration — "
                 "add getrandom RPC to omnibus-node"
                 if "node_rpc" not in all_results else ""),
    }

    if args.json:
        # Include full test details in JSON
        report["full_results"] = {k: v["tests"] for k, v in all_results.items()}
        print(json.dumps(report, indent=2))
    else:
        print(f"\n{CYAN}{'='*60}")
        print(f" FIPS 140-2 COMPLIANCE RESULTS")
        print(f"{'='*60}{RESET}")
        for src, data in all_results.items():
            sc = GREEN if data["all_passed"] else RED
            print(f"  {src}: {sc}{BOLD}{'PASS' if data['all_passed'] else 'FAIL'}{RESET}")
        vc = GREEN if overall_pass else RED
        print(f"\n  Overall: {vc}{BOLD}{report['verdict']}{RESET}")
        if report["note"]:
            print(f"  {YELLOW}Note: {report['note']}{RESET}")
        print(f"  Elapsed: {elapsed:.2f}s")

    sys.exit(0 if overall_pass else 1)


if __name__ == "__main__":
    main()
