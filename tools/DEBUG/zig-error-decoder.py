#!/usr/bin/env python3
"""
OmniBus Blockchain Core — Zig Error Decoder

Parses Zig compile errors and suggests fixes.
"""

import argparse
import json
import re
import sys
from typing import Any, Dict, List

GREEN = "\033[92m"
RED = "\033[91m"
YELLOW = "\033[93m"
RESET = "\033[0m"


def cprint(color: str, msg: str) -> None:
    print(f"{color}{msg}{RESET}")


ERROR_PATTERNS: List[Dict[str, Any]] = [
    {
        "regex": re.compile(r"error: use of undeclared identifier '(\w+)'"),
        "suggestion": "Add missing import or variable declaration for '{match}'.",
    },
    {
        "regex": re.compile(r"error: expected type '(.+?)', found '(.+?)'"),
        "suggestion": "Type mismatch: cast from '{group2}' to '{group1}' using @intCast, @truncate, or @as.",
    },
    {
        "regex": re.compile(r"error: no field named '(\w+)' in struct '(.+?)'"),
        "suggestion": "Field '{match}' missing in struct '{group2}'. Check field name or update struct definition.",
    },
    {
        "regex": re.compile(r"error: unreachable code"),
        "suggestion": "Remove or guard code after a return, break, or unreachable statement.",
    },
    {
        "regex": re.compile(r"error: cannot assign to constant"),
        "suggestion": "Change 'const' to 'var' for the binding you need to mutate.",
    },
]


def decode_errors(text: str) -> List[Dict[str, str]]:
    results = []
    for line in text.splitlines():
        for pat in ERROR_PATTERNS:
            m = pat["regex"].search(line)
            if m:
                suggestion = pat["suggestion"]
                for i, g in enumerate(m.groups(), 1):
                    suggestion = suggestion.replace(f"{{group{i}}}", g)
                suggestion = suggestion.replace("{match}", m.group(1))
                results.append({"error": line.strip(), "suggestion": suggestion})
                break
    return results


def main() -> int:
    parser = argparse.ArgumentParser(description="Decode Zig compile errors and suggest fixes")
    parser.add_argument("--input", default="-", help="File with zig build output (default: stdin)")
    parser.add_argument("--output", default="zig-fix-suggestions.json", help="Output JSON path")
    args = parser.parse_args()

    if args.input == "-":
        text = sys.stdin.read()
    else:
        with open(args.input, "r", encoding="utf-8") as f:
            text = f.read()

    cprint(GREEN, "=== OmniBus Zig Error Decoder ===")
    results = decode_errors(text)

    for r in results:
        cprint(RED, f"ERROR: {r['error']}")
        cprint(YELLOW, f"  -> {r['suggestion']}")

    with open(args.output, "w", encoding="utf-8") as f:
        json.dump({"errors": results}, f, indent=2)
    cprint(GREEN, f"\nSuggestions written to {args.output}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
