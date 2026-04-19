#!/usr/bin/env python3
"""
build-failure-tracker.py

Track Zig build failures from CI logs or local build output files.
Extracts:
  - Most common Zig compiler error types
  - Which modules cause the most problems
  - Temporal pattern: after updating module X, module Y tends to break

Scans:
  - tools/LEARNING/data/build-logs/ for *.log files
  - git log for revert / fixup commits referencing build failures

Outputs: tools/LEARNING/data/build-history.json
"""

import argparse
import glob
import json
import os
import re
import subprocess
import sys
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

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
# Error extraction
# ---------------------------------------------------------------------------
ZIG_ERROR_PATTERNS = [
    re.compile(r"error:\s*(.*)"),
    re.compile(r"error\[(\w+)\]\s*"),
    re.compile(r"undefined\s+reference\s+to\s+(\S+)"),
    re.compile(r"expected\s+\w+,\s+found\s+\w+"),
    re.compile(r"no\s+member\s+named\s+'(\w+)'"),
    re.compile(r"unable\s+to\s+\w+"),
]


def extract_zig_errors(text: str) -> list[str]:
    errors: list[str] = []
    for line in text.splitlines():
        for pat in ZIG_ERROR_PATTERNS:
            m = pat.search(line)
            if m:
                errors.append(line.strip())
                break
    return errors


def extract_module_from_error(line: str) -> str | None:
    """Heuristic: find 'core/Foo.zig' or similar in an error line."""
    m = re.search(r"(core[\/][\w_]+\.zig)", line)
    if m:
        return Path(m.group(1)).stem
    m = re.search(r"src[\/]([\w_]+\.zig)", line)
    if m:
        return Path(m.group(1)).stem
    return None


# ---------------------------------------------------------------------------
# Log file scanning
# ---------------------------------------------------------------------------
def scan_log_files(log_dir: str) -> list[dict[str, Any]]:
    records: list[dict[str, Any]] = []
    if not os.path.isdir(log_dir):
        return records
    for fpath in glob.glob(os.path.join(log_dir, "*.log")):
        text = Path(fpath).read_text(encoding="utf-8", errors="replace")
        errors = extract_zig_errors(text)
        for err in errors:
            mod = extract_module_from_error(err)
            records.append(
                {
                    "source": fpath,
                    "error": err,
                    "module": mod,
                    "timestamp": datetime.fromtimestamp(
                        os.path.getmtime(fpath), tz=timezone.utc
                    ).isoformat(),
                }
            )
    return records


# ---------------------------------------------------------------------------
# Git history scanning
# ---------------------------------------------------------------------------
def run_git(args: list[str], cwd: str) -> str:
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


def get_changed_files(cwd: str, commit_hash: str) -> list[str]:
    out = run_git(["diff-tree", "--no-commit-id", "--name-only", "-r", commit_hash], cwd=cwd)
    return [ln for ln in out.strip().splitlines() if ln]


def scan_git_build_failures(cwd: str, max_commits: int = 200) -> list[dict[str, Any]]:
    fmt = "%H|%aI|%s"
    out = run_git(["log", f"--format={fmt}", f"-n{max_commits}"], cwd=cwd)
    records: list[dict[str, Any]] = []
    for line in out.strip().splitlines():
        if "|" not in line:
            continue
        parts = line.split("|", 2)
        h, date, msg = parts[0], parts[1], parts[2]
        lower = msg.lower()
        if any(k in lower for k in ["build", "compile", "zig build", "ci fix", "fix build", "broken build"]):
            changed = get_changed_files(cwd, h)
            zig_files = [f for f in changed if f.endswith(".zig")]
            records.append(
                {
                    "source": f"git:{h}",
                    "commit": h,
                    "date": date,
                    "message": msg,
                    "changed_files": changed,
                    "zig_files": zig_files,
                }
            )
    return records


# ---------------------------------------------------------------------------
# Pattern mining
# ---------------------------------------------------------------------------
def find_xy_patterns(records: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Find 'after X, Y breaks' patterns from consecutive build failure records."""
    xy_counts: dict[tuple[str, str], int] = defaultdict(int)
    for i in range(1, len(records)):
        prev_mods = set()
        curr_mods = set()
        for f in records[i - 1].get("zig_files", []):
            prev_mods.add(Path(f).stem)
        for f in records[i].get("zig_files", []):
            curr_mods.add(Path(f).stem)
        for p in prev_mods:
            for c in curr_mods:
                if p != c:
                    xy_counts[(p, c)] += 1

    patterns = []
    for (x, y), count in sorted(xy_counts.items(), key=lambda kv: kv[1], reverse=True):
        if count >= 2:
            patterns.append({"after_updating": x, "module_y_tends_to_break": y, "occurrences": count})
    return patterns[:20]


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def main() -> int:
    parser = argparse.ArgumentParser(description="Track Zig build failures.")
    parser.add_argument("--repo", default=".", help="Path to repository")
    parser.add_argument("--log-dir", default="tools/LEARNING/data/build-logs", help="Directory with build logs")
    parser.add_argument("--max-commits", type=int, default=200, help="Git commits to scan")
    parser.add_argument("--output", default="tools/LEARNING/data/build-history.json", help="Output path")
    args = parser.parse_args()

    repo = os.path.abspath(args.repo)

    log_info("Scanning log files …")
    log_records = scan_log_files(os.path.join(repo, args.log_dir))
    log_info(f"Log errors found: {len(log_records)}")

    log_info("Scanning git history for build failures …")
    try:
        git_records = scan_git_build_failures(repo, args.max_commits)
    except Exception as exc:
        log_warn(str(exc))
        git_records = []
    log_info(f"Git build failure commits: {len(git_records)}")

    all_records = log_records + [
        {"source": r["source"], "module": Path(f).stem, "error": r["message"], "timestamp": r["date"]}
        for r in git_records
        for f in r.get("zig_files", [])
    ]

    # Aggregate
    module_counts: dict[str, int] = defaultdict(int)
    error_counts: dict[str, int] = defaultdict(int)
    for rec in all_records:
        mod = rec.get("module")
        if mod:
            module_counts[mod] += 1
        err = rec.get("error", "unknown")
        # Bucket generic error text
        bucket = err[:120]
        error_counts[bucket] += 1

    patterns = find_xy_patterns(git_records)

    report = {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "log_records": len(log_records),
        "git_records": len(git_records),
        "top_modules_by_failure": dict(sorted(module_counts.items(), key=lambda kv: kv[1], reverse=True)[:20]),
        "top_errors": dict(sorted(error_counts.items(), key=lambda kv: kv[1], reverse=True)[:20]),
        "xy_patterns": patterns,
        "raw_records": all_records,
    }

    out_path = os.path.join(repo, args.output)
    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    with open(out_path, "w", encoding="utf-8") as fh:
        json.dump(report, fh, indent=2)

    log_pass(f"Build history written to {out_path}")
    log_info(f"Unique modules with failures: {len(module_counts)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
