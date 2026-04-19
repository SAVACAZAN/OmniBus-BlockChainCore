#!/usr/bin/env python3
"""
OmniBus BlockChainCore — Module Complexity Analyzer
====================================================
Analyzes all core/*.zig source files and computes complexity metrics:

  - Lines of code (total / non-blank / non-comment)
  - Function count (fn keyword)
  - Test block count (test "..." blocks)
  - Import count (@import statements)
  - Complexity score (weighted formula)

Outputs a ranked table and optional JSON export.

Usage:
    python module-complexity-analyzer.py
    python module-complexity-analyzer.py --source-dir ../../core
    python module-complexity-analyzer.py --json-output complexity.json --top 20
"""

import argparse
import json
import os
import re
import sys
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

# Complexity weights
W_LINES     = 1.0
W_FUNCTIONS = 5.0
W_TESTS     = 2.0
W_IMPORTS   = 1.5


def analyze_file(filepath: Path) -> dict:
    """Analyze a single .zig file and return metrics."""
    try:
        content = filepath.read_text(encoding="utf-8", errors="replace")
    except Exception as exc:
        return {"error": str(exc)}

    lines = content.split("\n")
    total_lines = len(lines)
    blank_lines = sum(1 for l in lines if not l.strip())
    comment_lines = sum(1 for l in lines if l.strip().startswith("//"))
    code_lines = total_lines - blank_lines - comment_lines

    # Count functions: pub fn, fn, export fn
    fn_pattern = re.compile(r'\b(?:pub\s+)?(?:export\s+)?fn\s+\w+')
    functions = len(fn_pattern.findall(content))

    # Count test blocks: test "name" {
    test_pattern = re.compile(r'\btest\s+"[^"]*"')
    tests = len(test_pattern.findall(content))

    # Count imports: @import("...")
    import_pattern = re.compile(r'@import\s*\(\s*"([^"]+)"\s*\)')
    imports_raw = import_pattern.findall(content)
    imports = len(imports_raw)
    import_names = list(set(imports_raw))

    # Count pub fn specifically
    pub_fn_pattern = re.compile(r'\bpub\s+fn\s+\w+')
    pub_functions = len(pub_fn_pattern.findall(content))

    # Complexity score
    score = (
        code_lines * W_LINES +
        functions * W_FUNCTIONS +
        tests * W_TESTS +
        imports * W_IMPORTS
    ) / 100.0

    return {
        "file": filepath.name,
        "path": str(filepath),
        "total_lines": total_lines,
        "code_lines": code_lines,
        "blank_lines": blank_lines,
        "comment_lines": comment_lines,
        "functions": functions,
        "pub_functions": pub_functions,
        "tests": tests,
        "imports": imports,
        "import_names": import_names,
        "complexity_score": round(score, 2),
    }


def print_table(results: list, top_n: int | None):
    """Print a formatted table of results."""
    # Sort by complexity descending
    results.sort(key=lambda r: r.get("complexity_score", 0), reverse=True)
    if top_n:
        results = results[:top_n]

    # Header
    print(f"\n{BG_BLUE}{WHITE}{BOLD} OmniBus Module Complexity Analysis {RESET}\n")
    header = (
        f"  {'#':>3s}  {'Module':<35s}  {'Lines':>6s}  {'Code':>6s}  "
        f"{'Funcs':>5s}  {'PubFn':>5s}  {'Tests':>5s}  {'Imps':>4s}  {'Score':>7s}"
    )
    print(f"{BOLD}{header}{RESET}")
    print(f"  {DIM}{'─' * 95}{RESET}")

    for i, r in enumerate(results, 1):
        if "error" in r:
            print(f"  {i:3d}  {r['file']:<35s}  {RED}ERROR: {r['error']}{RESET}")
            continue

        # Colour score
        score = r["complexity_score"]
        if score > 20:
            score_col = RED
        elif score > 10:
            score_col = YELLOW
        else:
            score_col = GREEN

        name = r["file"]
        if len(name) > 35:
            name = name[:32] + "..."

        print(
            f"  {i:3d}  {CYAN}{name:<35s}{RESET}  "
            f"{r['total_lines']:6d}  {r['code_lines']:6d}  "
            f"{r['functions']:5d}  {r['pub_functions']:5d}  "
            f"{r['tests']:5d}  {r['imports']:4d}  "
            f"{score_col}{score:7.2f}{RESET}"
        )

    print(f"  {DIM}{'─' * 95}{RESET}")


def print_summary(results: list):
    """Print aggregate summary."""
    valid = [r for r in results if "error" not in r]
    if not valid:
        print(f"  {YELLOW}No valid files analyzed.{RESET}")
        return

    total_lines = sum(r["total_lines"] for r in valid)
    total_code = sum(r["code_lines"] for r in valid)
    total_funcs = sum(r["functions"] for r in valid)
    total_pub = sum(r["pub_functions"] for r in valid)
    total_tests = sum(r["tests"] for r in valid)
    total_imports = sum(r["imports"] for r in valid)
    avg_score = sum(r["complexity_score"] for r in valid) / len(valid)

    print(f"\n  {MAGENTA}{BOLD}Summary{RESET}")
    print(f"  {DIM}{'─' * 40}{RESET}")
    print(f"    Files analyzed:   {BOLD}{len(valid)}{RESET}")
    print(f"    Total lines:      {total_lines:,}")
    print(f"    Code lines:       {total_code:,}")
    print(f"    Functions:        {total_funcs:,} ({total_pub:,} public)")
    print(f"    Test blocks:      {total_tests:,}")
    print(f"    Imports:          {total_imports:,}")
    print(f"    Avg complexity:   {avg_score:.2f}")
    print(f"    Most complex:     {YELLOW}{valid[0]['file']}{RESET} (score: {valid[0]['complexity_score']})")
    print()


def main():
    parser = argparse.ArgumentParser(
        description="Analyze Zig module complexity in OmniBus BlockChainCore",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "Complexity score = (code_lines*1.0 + functions*5.0 + tests*2.0 + imports*1.5) / 100\n\n"
            "Examples:\n"
            "  python module-complexity-analyzer.py\n"
            "  python module-complexity-analyzer.py --top 10\n"
            "  python module-complexity-analyzer.py --json-output results.json"
        ),
    )
    script_dir = Path(__file__).resolve().parent
    default_src = script_dir.parent.parent / "core"

    parser.add_argument("--source-dir", type=str, default=str(default_src),
                        help=f"Source directory to scan (default: {default_src})")
    parser.add_argument("--top", type=int, default=None, help="Show only top N results")
    parser.add_argument("--json-output", type=str, default=None, help="Export results to JSON file")
    parser.add_argument("--sort-by", choices=["score", "lines", "functions", "tests"],
                        default="score", help="Sort criterion (default: score)")
    args = parser.parse_args()

    source_dir = Path(args.source_dir)
    if not source_dir.exists():
        print(f"{RED}ERROR:{RESET} Source directory not found: {source_dir}")
        print(f"{DIM}Make sure you're running from the correct location.{RESET}")
        sys.exit(1)

    zig_files = sorted(source_dir.glob("*.zig"))
    if not zig_files:
        # Try recursive
        zig_files = sorted(source_dir.rglob("*.zig"))

    if not zig_files:
        print(f"{RED}ERROR:{RESET} No .zig files found in {source_dir}")
        sys.exit(1)

    print(f"{CYAN}Scanning {len(zig_files)} Zig files in {source_dir}...{RESET}")

    results = []
    for f in zig_files:
        results.append(analyze_file(f))

    # Sort
    sort_keys = {
        "score": "complexity_score",
        "lines": "code_lines",
        "functions": "functions",
        "tests": "tests",
    }
    key = sort_keys.get(args.sort_by, "complexity_score")
    results.sort(key=lambda r: r.get(key, 0), reverse=True)

    print_table(results, args.top)
    print_summary(results)

    if args.json_output:
        # Remove non-serializable bits
        output = [dict(r) for r in results]
        with open(args.json_output, "w") as f:
            json.dump(output, f, indent=2)
        print(f"{GREEN}JSON exported to {args.json_output}{RESET}")


if __name__ == "__main__":
    main()
