#!/usr/bin/env python3
"""
OmniBus Blockchain Core — Core Dump Analyzer

Analyzes crash dumps (stack traces, registers) and extracts actionable info.
"""

import argparse
import json
import os
import re
import sys
from typing import Any, Dict, List

GREEN = "\033[92m"
RED = "\033[91m"
YELLOW = "\033[93m"
RESET = "\033[0m"


def cprint(color: str, msg: str) -> None:
    print(f"{color}{msg}{RESET}")


def analyze_dump(dump_path: str) -> Dict[str, Any]:
    if not os.path.isfile(dump_path):
        raise FileNotFoundError(dump_path)

    with open(dump_path, "r", encoding="utf-8", errors="ignore") as f:
        content = f.read()

    # Extract stack frames
    frames: List[Dict[str, str]] = []
    frame_re = re.compile(r"(\d+):\s+0x[0-9a-f]+\s+in\s+(.+?)\s+\((.+?)\)")
    for m in frame_re.finditer(content):
        frames.append({"index": m.group(1), "function": m.group(2), "location": m.group(3)})

    # Extract signal
    signal = "UNKNOWN"
    sig_re = re.compile(r"signal\s+(SIG\w+|\d+)")
    sm = sig_re.search(content)
    if sm:
        signal = sm.group(1)

    # Extract fault address
    fault_addr = "N/A"
    addr_re = re.compile(r"fault addr\s+(0x[0-9a-f]+)", re.IGNORECASE)
    am = addr_re.search(content)
    if am:
        fault_addr = am.group(1)

    return {
        "dump_file": dump_path,
        "signal": signal,
        "fault_address": fault_addr,
        "stack_frames": frames,
        "frame_count": len(frames),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Analyze core crash dumps")
    parser.add_argument("dump", help="Path to crash dump / stack trace file")
    parser.add_argument("--output", default="dump-analysis.json", help="Output JSON path")
    args = parser.parse_args()

    cprint(GREEN, "=== OmniBus Core Dump Analyzer ===")
    try:
        report = analyze_dump(args.dump)
    except FileNotFoundError:
        cprint(RED, f"Dump file not found: {args.dump}")
        return 1

    cprint(YELLOW, f"Signal: {report['signal']}")
    cprint(YELLOW, f"Fault address: {report['fault_address']}")
    cprint(YELLOW, f"Stack frames: {report['frame_count']}")
    for fr in report["stack_frames"][:5]:
        cprint(GREEN, f"  #{fr['index']} {fr['function']} at {fr['location']}")

    with open(args.output, "w", encoding="utf-8") as f:
        json.dump(report, f, indent=2)
    cprint(GREEN, f"\nAnalysis written to {args.output}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
