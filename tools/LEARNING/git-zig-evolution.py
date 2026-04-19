#!/usr/bin/env python3
"""
git-zig-evolution.py

Analyze the evolution of core/*.zig modules over git history.
Computes:
  - Lines of code (LOC) per module over time
  - Commit/fix frequency per module (proxy for instability)
  - Complexity score (branching + function count) per module over time
  - Allocation divergence detection (introduction of allocator usage in
    previously bare-metal modules)

Outputs: evolution-report.json
"""

import argparse
import json
import os
import re
import subprocess
import sys
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

# ---------------------------------------------------------------------------
# Colours
# ---------------------------------------------------------------------------
GREEN = "\033[92m"
RED = "\033[91m"
YELLOW = "\033[93m"
CYAN = "\033[96m"
RESET = "\033[0m"


def log_info(msg: str) -> None:
    print(f"{CYAN}[INFO]{RESET} {msg}")


def log_pass(msg: str) -> None:
    print(f"{GREEN}[PASS]{RESET} {msg}")


def log_fail(msg: str) -> None:
    print(f"{RED}[FAIL]{RESET} {msg}")


def log_warn(msg: str) -> None:
    print(f"{YELLOW}[WARN]{RESET} {msg}")


# ---------------------------------------------------------------------------
# Git helpers
# ---------------------------------------------------------------------------
def run_git(args: list[str], cwd: str) -> str:
    """Run a git command and return stdout. Raises on failure."""
    result = subprocess.run(
        ["git"] + args,
        cwd=cwd,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
    )
    if result.returncode != 0:
        raise RuntimeError(f"git {' '.join(args)} failed: {result.stderr}")
    return result.stdout


def get_commits(cwd: str, max_commits: int = 200) -> list[dict[str, Any]]:
    """Return list of commits with hash, date, and message."""
    fmt = "%H|%aI|%s"
    out = run_git(
        ["log", f"--format={fmt}", f"-n{max_commits}", "--", "core/*.zig"],
        cwd=cwd,
    )
    commits: list[dict[str, Any]] = []
    for line in out.strip().splitlines():
        if "|" not in line:
            continue
        parts = line.split("|", 2)
        commits.append(
            {
                "hash": parts[0],
                "date": parts[1],
                "message": parts[2],
            }
        )
    return commits


def get_file_at_commit(cwd: str, commit_hash: str, file_path: str) -> str:
    """Return file contents at a specific commit."""
    try:
        return run_git(["show", f"{commit_hash}:{file_path}"], cwd=cwd)
    except RuntimeError:
        return ""


def list_zig_files(cwd: str, commit_hash: str) -> list[str]:
    """List core/*.zig files present at a given commit."""
    try:
        out = run_git(
            ["ls-tree", "-r", "--name-only", commit_hash, "--", "core/*.zig"],
            cwd=cwd,
        )
        return [ln for ln in out.strip().splitlines() if ln.endswith(".zig")]
    except RuntimeError:
        return []


# ---------------------------------------------------------------------------
# Metrics
# ---------------------------------------------------------------------------
def count_loc(source: str) -> int:
    """Count non-empty, non-comment lines."""
    lines = 0
    in_multiline_comment = False
    for raw in source.splitlines():
        line = raw.strip()
        if not line:
            continue
        if line.startswith("//"):
            continue
        if "/*" in line:
            if "*/" not in line:
                in_multiline_comment = True
            continue
        if in_multiline_comment:
            if "*/" in line:
                in_multiline_comment = False
            continue
        lines += 1
    return lines


def complexity_score(source: str) -> int:
    """Rough complexity: number of functions + branching keywords."""
    funcs = len(re.findall(r"\bfn\s+\w+", source))
    branches = len(
        re.findall(
            r"\b(if|else|switch|while|for|return|break|continue|catch|try)\b",
            source,
        )
    )
    return funcs + branches


def has_allocations(source: str) -> bool:
    """Detect allocator usage patterns in Zig source."""
    patterns = [
        r"\ballocator\b",
        r"\bAllocator\b",
        r"\bstd\.heap\b",
        r"\bpage_allocator\b",
        r"\bGeneralPurposeAllocator\b",
        r"\bFixedBufferAllocator\b",
        r"\.alloc\b",
        r"\.create\b",
        r"\.realloc\b",
        r"\.free\b",
    ]
    return any(re.search(p, source) for p in patterns)


def fix_indicator(commit_msg: str) -> bool:
    """Heuristic: does the commit message indicate a fix?"""
    msg = commit_msg.lower()
    keywords = ["fix", "bug", "patch", "repair", "correct", "resolve", "hotfix"]
    return any(kw in msg for kw in keywords)


# ---------------------------------------------------------------------------
# Main analysis
# ---------------------------------------------------------------------------
def analyze_evolution(cwd: str, max_commits: int) -> dict[str, Any]:
    log_info(f"Fetching up to {max_commits} commits touching core/*.zig …")
    commits = get_commits(cwd, max_commits)
    if not commits:
        log_warn("No commits found for core/*.zig")
        return {"generated_at": datetime.now(timezone.utc).isoformat(), "modules": {}}

    log_info(f"Analyzing {len(commits)} commits …")

    # Per-commit per-module metrics
    module_history: dict[str, list[dict[str, Any]]] = defaultdict(list)
    module_fix_count: dict[str, int] = defaultdict(int)

    for idx, commit in enumerate(commits):
        files = list_zig_files(cwd, commit["hash"])
        for fpath in files:
            source = get_file_at_commit(cwd, commit["hash"], fpath)
            if not source:
                continue
            module_name = Path(fpath).stem
            module_history[module_name].append(
                {
                    "commit": commit["hash"],
                    "date": commit["date"],
                    "loc": count_loc(source),
                    "complexity": complexity_score(source),
                    "allocations": has_allocations(source),
                }
            )
            if fix_indicator(commit["message"]):
                module_fix_count[module_name] += 1

        if (idx + 1) % 20 == 0 or idx == len(commits) - 1:
            log_info(f"  processed {idx + 1}/{len(commits)} commits")

    # Aggregate per-module
    modules: dict[str, Any] = {}
    for mod, history in module_history.items():
        history.sort(key=lambda x: x["date"])
        loc_start = history[0]["loc"] if history else 0
        loc_end = history[-1]["loc"] if history else 0
        loc_growth = loc_end - loc_start
        avg_complexity = sum(h["complexity"] for h in history) / len(history)
        max_complexity = max(h["complexity"] for h in history)

        # Detect allocation divergence: first snapshot no alloc, later snapshot has alloc
        alloc_diverged = False
        first_no_alloc = any(not h["allocations"] for h in history)
        later_has_alloc = any(h["allocations"] for h in history[1:])
        if first_no_alloc and later_has_alloc:
            alloc_diverged = True

        modules[mod] = {
            "file": f"core/{mod}.zig",
            "commits_analyzed": len(history),
            "fix_count": module_fix_count[mod],
            "loc_start": loc_start,
            "loc_end": loc_end,
            "loc_growth": loc_growth,
            "growth_percent": round((loc_growth / max(loc_start, 1)) * 100, 2),
            "average_complexity": round(avg_complexity, 2),
            "max_complexity": max_complexity,
            "allocation_diverged": alloc_diverged,
            "history": history,
        }

    report = {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "commits_scanned": len(commits),
        "modules": modules,
    }
    return report


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Analyze Zig core module evolution via git history."
    )
    parser.add_argument(
        "--repo",
        default=".",
        help="Path to the BlockChainCore git repository (default: current dir)",
    )
    parser.add_argument(
        "--max-commits",
        type=int,
        default=200,
        help="Maximum commits to scan (default: 200)",
    )
    parser.add_argument(
        "--output",
        default="tools/LEARNING/evolution-report.json",
        help="Output JSON path",
    )
    args = parser.parse_args()

    repo = os.path.abspath(args.repo)
    if not os.path.isdir(os.path.join(repo, ".git")):
        log_fail(f"{repo} does not appear to be a git repository.")
        return 1

    try:
        report = analyze_evolution(repo, args.max_commits)
    except Exception as exc:
        log_fail(str(exc))
        return 1

    out_path = os.path.join(repo, args.output)
    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    with open(out_path, "w", encoding="utf-8") as fh:
        json.dump(report, fh, indent=2)

    log_pass(f"Report written to {out_path}")
    log_info(f"Modules analyzed: {len(report['modules'])}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
