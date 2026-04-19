#!/usr/bin/env python3
"""
crypto-implementation-tracker.py

Track the evolution of cryptographic implementations in a BlockChainCore
repository via git history.  Monitors:
  - secp256k1.zig iterations, bug fixes, test vector changes
  - BIP-32 derivation path handling changes
  - Crypto-related API surface changes over time

Outputs: crypto-evolution-timeline.json
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


def get_crypto_commits(cwd: str, max_commits: int = 300) -> list[dict[str, str]]:
    fmt = "%H|%aI|%s"
    # commits touching crypto-related files
    paths = ["core/secp256k1.zig", "core/crypto.zig", "core/bip32_wallet.zig", "core/schnorr.zig"]
    out = run_git(["log", f"--format={fmt}", f"-n{max_commits}", "--"] + paths, cwd=cwd)
    commits: list[dict[str, str]] = []
    seen = set()
    for line in out.strip().splitlines():
        if "|" not in line:
            continue
        parts = line.split("|", 2)
        h = parts[0]
        if h in seen:
            continue
        seen.add(h)
        commits.append({"hash": h, "date": parts[1], "message": parts[2]})
    return commits


def get_changed_files(cwd: str, commit_hash: str) -> list[str]:
    out = run_git(["diff-tree", "--no-commit-id", "--name-only", "-r", commit_hash], cwd=cwd)
    return [ln for ln in out.strip().splitlines() if ln]


def get_file_diff(cwd: str, commit_hash: str, file_path: str) -> str:
    try:
        parent = run_git(["rev-list", "--parents", "-n1", commit_hash], cwd=cwd).strip().split()[1]
    except Exception:
        parent = f"{commit_hash}^"
    try:
        return run_git(["diff", parent, commit_hash, "--", file_path], cwd=cwd)
    except RuntimeError:
        return ""


def get_file_at_commit(cwd: str, commit_hash: str, file_path: str) -> str:
    try:
        return run_git(["show", f"{commit_hash}:{file_path}"], cwd=cwd)
    except RuntimeError:
        return ""


def classify_commit(message: str) -> list[str]:
    tags: list[str] = []
    m = message.lower()
    if any(w in m for w in ["fix", "bug", "patch", "repair"]):
        tags.append("bugfix")
    if any(w in m for w in ["test", "spec", "vector"]):
        tags.append("test-related")
    if any(w in m for w in ["perf", "optim", "speed", "fast"]):
        tags.append("performance")
    if any(w in m for w in ["refactor", "clean", "restructure"]):
        tags.append("refactor")
    if any(w in m for w in ["feat", "add", "introduce", "implement", "new"]):
        tags.append("feature")
    if not tags:
        tags.append("misc")
    return tags


def extract_bip32_paths(source: str) -> list[str]:
    """Find BIP-32 derivation path strings in source code."""
    return list(dict.fromkeys(re.findall(r"m/[\d'h/]+", source)))


def extract_secp256k1_functions(source: str) -> list[str]:
    """Find public function names in secp256k1 source."""
    return re.findall(r"\bpub\s+fn\s+([\w_]+)", source)


def extract_test_vectors(source: str) -> list[str]:
    """Find hard-coded hex test vectors (>= 32 hex chars)."""
    return list(dict.fromkeys(re.findall(r"[0-9a-fA-F]{64,}", source)))


def analyze_crypto_evolution(cwd: str, max_commits: int) -> dict[str, Any]:
    log_info("Fetching crypto-related commits …")
    commits = get_crypto_commits(cwd, max_commits)
    log_info(f"Unique crypto commits: {len(commits)}")

    secp_timeline: list[dict[str, Any]] = []
    bip32_timeline: list[dict[str, Any]] = []
    crypto_api_changes: list[dict[str, Any]] = []

    secp_funcs_over_time: dict[str, list[str]] = {}
    bip32_paths_over_time: dict[str, list[str]] = {}

    for idx, commit in enumerate(commits):
        changed = get_changed_files(cwd, commit["hash"])
        tags = classify_commit(commit["message"])

        # secp256k1 tracking
        if "core/secp256k1.zig" in changed:
            src = get_file_at_commit(cwd, commit["hash"], "core/secp256k1.zig")
            diff = get_file_diff(cwd, commit["hash"], "core/secp256k1.zig")
            funcs = extract_secp256k1_functions(src)
            vectors = extract_test_vectors(src)
            secp_timeline.append(
                {
                    "commit": commit["hash"],
                    "date": commit["date"],
                    "message": commit["message"],
                    "tags": tags,
                    "functions": funcs,
                    "function_count": len(funcs),
                    "test_vectors_count": len(vectors),
                    "diff_lines": len(diff.splitlines()),
                }
            )
            secp_funcs_over_time[commit["hash"]] = funcs

        # BIP-32 tracking
        if "core/bip32_wallet.zig" in changed:
            src = get_file_at_commit(cwd, commit["hash"], "core/bip32_wallet.zig")
            diff = get_file_diff(cwd, commit["hash"], "core/bip32_wallet.zig")
            paths = extract_bip32_paths(src)
            bip32_timeline.append(
                {
                    "commit": commit["hash"],
                    "date": commit["date"],
                    "message": commit["message"],
                    "tags": tags,
                    "derivation_paths": paths,
                    "path_count": len(paths),
                    "diff_lines": len(diff.splitlines()),
                }
            )
            bip32_paths_over_time[commit["hash"]] = paths

        # General crypto API surface
        crypto_files = [c for c in changed if "crypto" in c.lower() and c.endswith(".zig")]
        for cf in crypto_files:
            src = get_file_at_commit(cwd, commit["hash"], cf)
            funcs = extract_secp256k1_functions(src)
            crypto_api_changes.append(
                {
                    "commit": commit["hash"],
                    "date": commit["date"],
                    "file": cf,
                    "message": commit["message"],
                    "tags": tags,
                    "public_functions": funcs,
                }
            )

        if (idx + 1) % 20 == 0 or idx == len(commits) - 1:
            log_info(f"  processed {idx + 1}/{len(commits)} commits")

    # Summaries
    bugfix_count = sum(1 for e in secp_timeline if "bugfix" in e["tags"])
    test_change_count = sum(1 for e in secp_timeline if "test-related" in e["tags"])

    report = {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "commits_scanned": len(commits),
        "summary": {
            "secp256k1_commits": len(secp_timeline),
            "secp256k1_bugfixes": bugfix_count,
            "secp256k1_test_changes": test_change_count,
            "bip32_commits": len(bip32_timeline),
            "crypto_api_changes": len(crypto_api_changes),
        },
        "secp256k1_timeline": secp_timeline,
        "bip32_timeline": bip32_timeline,
        "crypto_api_changes": crypto_api_changes,
    }
    return report


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Track crypto implementation evolution via git history."
    )
    parser.add_argument("--repo", default=".", help="Path to git repository")
    parser.add_argument(
        "--max-commits", type=int, default=300, help="Max commits (default: 300)"
    )
    parser.add_argument(
        "--output",
        default="tools/LEARNING/crypto-evolution-timeline.json",
        help="Output JSON path",
    )
    args = parser.parse_args()

    repo = os.path.abspath(args.repo)
    if not os.path.isdir(os.path.join(repo, ".git")):
        log_fail(f"{repo} is not a git repository.")
        return 1

    try:
        report = analyze_crypto_evolution(repo, args.max_commits)
    except Exception as exc:
        log_fail(str(exc))
        return 1

    out_path = os.path.join(repo, args.output)
    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    with open(out_path, "w", encoding="utf-8") as fh:
        json.dump(report, fh, indent=2)

    log_pass(f"Report written to {out_path}")
    log_info(
        f"secp256k1 commits: {report['summary']['secp256k1_commits']}, "
        f"BIP-32 commits: {report['summary']['bip32_commits']}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
