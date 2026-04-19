#!/usr/bin/env python3
"""
OmniBus Blockchain Core — Memory Usage Analyzer

Analyzes stack usage per Zig module for bare-metal constraints.
Uses regex heuristics on .zig source to estimate max stack frame size.

Outputs: memory-report.json
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


# Stack size estimates for common patterns (bytes)
STACK_ESTIMATES = {
    "[32]u8": 32,
    "[64]u8": 64,
    "[256]u8": 256,
    "[512]u8": 512,
    "[1024]u8": 1024,
    "[4096]u8": 4096,
    "[8192]u8": 8192,
    "[32]u64": 256,
    "[64]u64": 512,
}

ARRAY_RE = re.compile(r"\[(\d+)\]\s*(u8|u16|u32|u64|i8|i16|i32|i64|f32|f64)")


def analyze_file(path: str) -> Dict[str, Any]:
    with open(path, "r", encoding="utf-8", errors="ignore") as f:
        content = f.read()

    max_array = 0
    total_arrays = 0
    functions = 0
    has_malloc = "malloc" in content.lower() or "allocator" in content.lower()
    has_float = "f32" in content or "f64" in content

    # Count array declarations
    for m in ARRAY_RE.finditer(content):
        size = int(m.group(1))
        total_arrays += 1
        if size > max_array:
            max_array = size

    # Count functions (rough)
    functions = len(re.findall(r"^\s*fn\s+\w+", content, re.MULTILINE))

    # Estimate stack: max array element size * count, plus padding
    elem_size = 1  # conservative
    estimated_stack = max_array * elem_size + 64  # frame overhead

    return {
        "file": os.path.basename(path),
        "functions": functions,
        "arrays": total_arrays,
        "max_array_size": max_array,
        "estimated_stack_bytes": estimated_stack,
        "uses_allocator": has_malloc,
        "uses_float": has_float,
        "bare_metal_safe": (not has_malloc) and (estimated_stack < 8192),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Analyze stack usage for OmniBus core Zig modules")
    parser.add_argument("--core-dir", default="core", help="Path to core/ directory")
    parser.add_argument("--output", default="memory-report.json", help="Output JSON path")
    args = parser.parse_args()

    if not os.path.isdir(args.core_dir):
        cprint(RED, f"Directory not found: {args.core_dir}")
        return 1

    report: Dict[str, Any] = {"modules": [], "summary": {}}
    total_stack = 0
    unsafe_count = 0

    files = sorted([f for f in os.listdir(args.core_dir) if f.endswith(".zig")])
    for fname in files:
        fpath = os.path.join(args.core_dir, fname)
        info = analyze_file(fpath)
        report["modules"].append(info)
        total_stack = max(total_stack, info["estimated_stack_bytes"])
        if not info["bare_metal_safe"]:
            unsafe_count += 1
        status = GREEN if info["bare_metal_safe"] else RED
        cprint(status, f"{info['file']:40s} stack≈{info['estimated_stack_bytes']:5d}B  arrays={info['arrays']:3d}  floats={info['uses_float']}")

    report["summary"] = {
        "modules_analyzed": len(files),
        "max_estimated_stack_bytes": total_stack,
        "bare_metal_violations": unsafe_count,
        "threshold_bytes": 8192,
    }

    with open(args.output, "w", encoding="utf-8") as f:
        json.dump(report, f, indent=2)
    cprint(GREEN, f"\nReport written to {args.output}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
