#!/usr/bin/env python3
"""
OmniBus Blockchain Core — Address Validator

Validates OmniBus addresses (bech32, PQ domains).
"""

import argparse
import json
import re
import sys
from typing import Any, Dict, Tuple

GREEN = "\033[92m"
RED = "\033[91m"
YELLOW = "\033[93m"
RESET = "\033[0m"


def cprint(color: str, msg: str) -> None:
    print(f"{color}{msg}{RESET}")


# Bech32 character set
BECH32_CHARSET = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"


def bech32_polymod(values: list) -> int:
    generator = [0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3]
    chk = 1
    for v in values:
        b = chk >> 25
        chk = (chk & 0x1ffffff) << 5 ^ v
        for i in range(5):
            chk ^= generator[i] if ((b >> i) & 1) else 0
    return chk


def bech32_hrp_expand(hrp: str) -> list:
    return [ord(x) >> 5 for x in hrp] + [0] + [ord(x) & 31 for x in hrp]


def bech32_verify_checksum(hrp: str, data: list) -> bool:
    return bech32_polymod(bech32_hrp_expand(hrp) + data) == 1


def validate_bech32(addr: str) -> Tuple[bool, str]:
    if not (1 <= len(addr) <= 74):
        return False, "Length out of range"
    addr = addr.lower()
    if "1" not in addr:
        return False, "Missing separator '1'"
    idx = addr.rindex("1")
    hrp = addr[:idx]
    data = addr[idx + 1 :]
    if not all(c in BECH32_CHARSET for c in data):
        return False, "Invalid characters in data part"
    data_values = [BECH32_CHARSET.find(c) for c in data]
    if not bech32_verify_checksum(hrp, data_values):
        return False, "Checksum mismatch"
    return True, "Valid bech32"


def validate_omnibus(addr: str) -> Tuple[bool, str]:
    if not addr.startswith("om1"):
        return False, "OmniBus addresses must start with 'om1'"
    if addr.startswith("om1pq"):
        # PQ domain: extra validation could be added here
        if len(addr) < 20:
            return False, "PQ address too short"
        return True, "Valid OmniBus PQ address"
    return validate_bech32(addr)


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate OmniBus addresses")
    parser.add_argument("address", nargs="?", help="Address to validate")
    parser.add_argument("--file", help="File with one address per line")
    parser.add_argument("--output", default="validation-report.json", help="Output JSON path")
    args = parser.parse_args()

    cprint(GREEN, "=== OmniBus Address Validator ===")
    results: list = []
    addresses = []
    if args.address:
        addresses.append(args.address)
    if args.file:
        with open(args.file, "r", encoding="utf-8") as f:
            addresses.extend(line.strip() for line in f if line.strip())

    if not addresses:
        cprint(RED, "No addresses provided. Use positional arg or --file")
        return 1

    for addr in addresses:
        ok, msg = validate_omnibus(addr)
        color = GREEN if ok else RED
        cprint(color, f"{addr}: {msg}")
        results.append({"address": addr, "valid": ok, "message": msg})

    with open(args.output, "w", encoding="utf-8") as f:
        json.dump(results, f, indent=2)
    cprint(GREEN, f"\nReport written to {args.output}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
