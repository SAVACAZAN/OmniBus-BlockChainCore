#!/usr/bin/env python3
"""
test-failure-learner.py

Parse the git log of a BlockChainCore repository to identify commits where
 tests failed (CI failures, manual fix-up commits, or commit messages that
 mention a failing test).  Cross-reference the failing test with the files
 that changed in the commit and in the preceding commit to build
 "if you change X, check test Y" heuristics.

Outputs: failure-patterns.json
"""

import argparse
import json
import os
import re
import subprocess
import sys
from collections import defaultdict
from datetime import datetime, timezone
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


def get_all_commits(cwd: str, max_commits: int = 500) -> list[dict[str, str]]:
    fmt = "%H|%aI|%s"
    out = run_git(["log", f"--format={fmt}", f"-n{max_commits}"], cwd=cwd)
    commits: list[dict[str, str]] = []
    for line in out.strip().splitlines():
        if "|" not in line:
            continue
        parts = line.split("|", 2)
        commits.append({"hash": parts[0], "date": parts[1], "message": parts[2]})
    return commits


def get_changed_files(cwd: str, commit_hash: str) -> list[str]:
    out = run_git(["diff-tree", "--no-commit-id", "--name-only", "-r", commit_hash], cwd=cwd)
    return [ln for ln in out.strip().splitlines() if ln]


def extract_test_names(message: str) -> list[str]:
    """Heuristic extraction of test names from commit messages."""
    names: list[str] = []
    # Patterns like "test: foo_bar", "fix test_foo", "foo.test.zig", etc.
    patterns = [
        r"test[:\s]+([\w_]+)",
        r"test_([\w_]+)",
        r"([\w_]+\.test\.zig)",
        r"([\w_]+_test\.zig)",
    ]
    for pat in patterns:
        for m in re.finditer(pat, message, re.IGNORECASE):
            names.append(m.group(1))
    return list(dict.fromkeys(names))


def is_test_failure_commit(message: str) -> bool:
    msg = message.lower()
    indicators = [
        "fix test",
        "test fail",
        "failing test",
        "broken test",
        "test broken",
        "test panic",
        "test crash",
        "ci fix",
        "ci: fix",
        "regression",
        "revert",
    ]
    return any(ind in msg for ind in indicators)


def find_preceding_commit(cwd: str, commit_hash: str) -> str | None:
    try:
        out = run_git(["rev-list", "--parents", "-n1", commit_hash], cwd=cwd)
        parts = out.strip().split()
        return parts[1] if len(parts) > 1 else None
    except RuntimeError:
        return None


def learn_failures(cwd: str, max_commits: int) -> dict[str, Any]:
    log_info(f"Fetching up to {max_commits} commits …")
    commits = get_all_commits(cwd, max_commits)
    log_info(f"Total commits: {len(commits)}")

    patterns: list[dict[str, Any]] = []
    test_failure_count = 0

    for idx, commit in enumerate(commits):
        if not is_test_failure_commit(commit["message"]):
            continue

        test_failure_count += 1
        changed = get_changed_files(cwd, commit["hash"])
        tests = extract_test_names(commit["message"])

        # Also try to infer test file from changed files
        for f in changed:
            if "test" in f.lower() and f.endswith(".zig"):
                base = os.path.basename(f)
                if base not in tests:
                    tests.append(base)

        # Look at parent commit for files that might have caused the break
        parent = find_preceding_commit(cwd, commit["hash"])
        parent_changed: list[str] = []
        if parent:
            parent_changed = get_changed_files(cwd, parent)

        all_files = list(dict.fromkeys(changed + parent_changed))
        source_files = [f for f in all_files if f.endswith(".zig") and "test" not in f.lower()]

        patterns.append(
            {
                "commit": commit["hash"],
                "date": commit["date"],
                "message": commit["message"],
                "tests_mentioned": tests,
                "files_changed": changed,
                "likely_source_files": source_files,
                "parent_commit": parent,
            }
        )

        if (idx + 1) % 50 == 0:
            log_info(f"  scanned {idx + 1}/{len(commits)} commits, found {test_failure_count} failures")

    # Build aggregated "if X then Y" rules
    rules: list[dict[str, Any]] = []
    file_to_tests: dict[str, list[str]] = defaultdict(list)
    for p in patterns:
        for src in p["likely_source_files"]:
            for tst in p["tests_mentioned"]:
                file_to_tests[src].append(tst)

    for src_file, test_list in file_to_tests.items():
        freq: dict[str, int] = defaultdict(int)
        for t in test_list:
            freq[t] += 1
        top_tests = sorted(freq.items(), key=lambda x: x[1], reverse=True)[:5]
        rules.append(
            {
                "if_you_change": src_file,
                "check_tests": [t[0] for t in top_tests],
                "confidence_hits": [t[1] for t in top_tests],
            }
        )

    report = {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "commits_scanned": len(commits),
        "test_failure_commits_found": test_failure_count,
        "patterns": patterns,
        "rules": rules,
    }
    return report


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Learn test failure patterns from git history."
    )
    parser.add_argument("--repo", default=".", help="Path to git repository")
    parser.add_argument(
        "--max-commits", type=int, default=500, help="Commits to scan (default: 500)"
    )
    parser.add_argument(
        "--output",
        default="tools/LEARNING/failure-patterns.json",
        help="Output JSON path",
    )
    args = parser.parse_args()

    repo = os.path.abspath(args.repo)
    if not os.path.isdir(os.path.join(repo, ".git")):
        log_fail(f"{repo} is not a git repository.")
        return 1

    try:
        report = learn_failures(repo, args.max_commits)
    except Exception as exc:
        log_fail(str(exc))
        return 1

    out_path = os.path.join(repo, args.output)
    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    with open(out_path, "w", encoding="utf-8") as fh:
        json.dump(report, fh, indent=2)

    log_pass(f"Report written to {out_path}")
    log_info(f"Failure commits found: {report['test_failure_commits_found']}")
    log_info(f"Heuristic rules generated: {len(report['rules'])}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
