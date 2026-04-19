#!/usr/bin/env python3
"""
vuln-signature-updater.py — OmniBus BlockChainCore Vulnerability Rule Manager

Auto-updater and scanner for vulnerability detection rules:
  --update   Download/update rules from a manifest URL (or local git)
  --check    Load rules and scan core/*.zig for pattern matches
  --list     List all loaded rules with severity

Rules are stored in tools/SECURITY/rules/ as JSON files.
Each rule: {id, version, pattern (regex), severity, description, affected_modules, fix_suggestion}
"""

import argparse
import hashlib
import json
import os
import re
import sys
import urllib.request
import urllib.error
from datetime import datetime, timezone
from pathlib import Path

GREEN = "\033[92m"
RED = "\033[91m"
YELLOW = "\033[93m"
CYAN = "\033[96m"
BOLD = "\033[1m"
RESET = "\033[0m"

SCRIPT_DIR = Path(os.path.dirname(os.path.abspath(__file__)))
RULES_DIR = SCRIPT_DIR / "rules"
CORE_DIR = SCRIPT_DIR.parent.parent / "core"
MANIFEST_FILE = RULES_DIR / "manifest.json"
DEFAULT_RULES_FILE = RULES_DIR / "default-rules.json"

DEFAULT_UPDATE_URL = ""  # Set to GitHub raw URL or leave empty for local-only


def log_info(msg: str) -> None:
    print(f"{CYAN}[INFO]{RESET} {msg}")


def log_pass(msg: str) -> None:
    print(f"{GREEN}[PASS]{RESET} {msg}")


def log_fail(msg: str) -> None:
    print(f"{RED}[FAIL]{RESET} {msg}")


def log_warn(msg: str) -> None:
    print(f"{YELLOW}[WARN]{RESET} {msg}")


def sha256_file(path: str) -> str:
    """Compute SHA-256 of a file."""
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while True:
            chunk = f.read(8192)
            if not chunk:
                break
            h.update(chunk)
    return h.hexdigest()


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def load_rules() -> list[dict]:
    """Load all vulnerability rules from rules directory."""
    rules = []

    # Load default rules
    if DEFAULT_RULES_FILE.exists():
        try:
            with open(DEFAULT_RULES_FILE, "r", encoding="utf-8") as f:
                data = json.load(f)
            if isinstance(data, dict) and "rules" in data:
                rules.extend(data["rules"])
            elif isinstance(data, list):
                rules.extend(data)
            log_info(f"Loaded {len(rules)} rules from {DEFAULT_RULES_FILE.name}")
        except (json.JSONDecodeError, IOError) as e:
            log_fail(f"Error loading {DEFAULT_RULES_FILE}: {e}")

    # Load any additional rule files
    if RULES_DIR.exists():
        for rule_file in RULES_DIR.glob("*.json"):
            if rule_file.name in ("default-rules.json", "manifest.json"):
                continue
            try:
                with open(rule_file, "r", encoding="utf-8") as f:
                    data = json.load(f)
                extra = data.get("rules", data) if isinstance(data, dict) else data
                if isinstance(extra, list):
                    rules.extend(extra)
                    log_info(f"Loaded {len(extra)} additional rules from {rule_file.name}")
            except (json.JSONDecodeError, IOError):
                pass

    return rules


def update_rules(url: str) -> bool:
    """Check for and download updated rules from URL."""
    if not url:
        log_warn("No update URL configured. Use --url to specify one.")
        log_info("Example: --url https://raw.githubusercontent.com/org/repo/main/rules/manifest.json")
        return False

    log_info(f"Checking for updates at: {url}")

    try:
        req = urllib.request.Request(url, headers={"User-Agent": "OmniBus-VulnUpdater/1.0"})
        with urllib.request.urlopen(req, timeout=15) as resp:
            remote_data = resp.read()
    except urllib.error.URLError as e:
        log_fail(f"Failed to fetch manifest: {e}")
        return False
    except Exception as e:
        log_fail(f"Unexpected error: {e}")
        return False

    try:
        remote_manifest = json.loads(remote_data.decode("utf-8"))
    except json.JSONDecodeError as e:
        log_fail(f"Invalid JSON in remote manifest: {e}")
        return False

    # Compare versions
    remote_version = remote_manifest.get("version", "0.0.0")
    local_version = "0.0.0"
    if MANIFEST_FILE.exists():
        try:
            with open(MANIFEST_FILE, "r") as f:
                local_manifest = json.load(f)
            local_version = local_manifest.get("version", "0.0.0")
        except (json.JSONDecodeError, IOError):
            pass

    log_info(f"Local version: {local_version}")
    log_info(f"Remote version: {remote_version}")

    if remote_version <= local_version:
        log_pass("Rules are up to date.")
        return True

    # Download and verify rules
    rules_url = remote_manifest.get("rules_url", "")
    expected_sha = remote_manifest.get("sha256", "")

    if rules_url:
        try:
            req = urllib.request.Request(rules_url, headers={"User-Agent": "OmniBus-VulnUpdater/1.0"})
            with urllib.request.urlopen(req, timeout=15) as resp:
                rules_data = resp.read()
        except Exception as e:
            log_fail(f"Failed to download rules: {e}")
            return False

        # Verify checksum
        actual_sha = sha256_bytes(rules_data)
        if expected_sha and actual_sha != expected_sha:
            log_fail(f"SHA-256 mismatch! Expected: {expected_sha}, Got: {actual_sha}")
            log_fail("Rules file may be tampered. Aborting update.")
            return False

        if expected_sha:
            log_pass(f"SHA-256 verified: {actual_sha[:16]}...")

        # Save rules
        RULES_DIR.mkdir(parents=True, exist_ok=True)
        rules_path = RULES_DIR / "downloaded-rules.json"
        with open(rules_path, "wb") as f:
            f.write(rules_data)
        log_pass(f"Updated rules saved to {rules_path}")

    # Save manifest
    with open(MANIFEST_FILE, "w") as f:
        json.dump(remote_manifest, f, indent=2)
    log_pass(f"Manifest updated to version {remote_version}")

    return True


def scan_zig_files(rules: list[dict]) -> list[dict]:
    """Scan core/*.zig files for vulnerability pattern matches."""
    if not CORE_DIR.exists():
        log_fail(f"Core directory not found: {CORE_DIR}")
        return []

    zig_files = list(CORE_DIR.glob("*.zig"))
    log_info(f"Scanning {len(zig_files)} Zig source files in {CORE_DIR}")

    findings = []
    compiled_rules = []
    for rule in rules:
        pattern = rule.get("pattern", "")
        if not pattern:
            continue
        try:
            regex = re.compile(pattern, re.IGNORECASE | re.MULTILINE)
            compiled_rules.append((rule, regex))
        except re.error as e:
            log_warn(f"Invalid regex in rule {rule.get('id', '?')}: {e}")

    for zig_file in sorted(zig_files):
        try:
            content = zig_file.read_text(encoding="utf-8", errors="replace")
        except IOError:
            continue

        lines = content.splitlines()

        for rule, regex in compiled_rules:
            for i, line in enumerate(lines, 1):
                if regex.search(line):
                    findings.append({
                        "rule_id": rule.get("id", "?"),
                        "severity": rule.get("severity", "INFO"),
                        "description": rule.get("description", ""),
                        "file": str(zig_file.name),
                        "line": i,
                        "matched_text": line.strip()[:120],
                        "fix_suggestion": rule.get("fix_suggestion", ""),
                    })

    return findings


def list_rules(rules: list[dict]) -> None:
    """Display all loaded rules."""
    severity_colors = {"CRITICAL": RED, "HIGH": RED, "MEDIUM": YELLOW, "LOW": GREEN, "INFO": CYAN}

    print(f"\n{BOLD}{'ID':<12s} {'Sev':<10s} {'Description'}{RESET}")
    print(f"{'-'*12} {'-'*10} {'-'*50}")
    for rule in sorted(rules, key=lambda r: r.get("id", "")):
        sev = rule.get("severity", "INFO")
        color = severity_colors.get(sev, RESET)
        desc = rule.get("description", "")[:60]
        print(f"{rule.get('id', '?'):<12s} {color}{sev:<10s}{RESET} {desc}")
    print(f"\nTotal: {len(rules)} rules loaded")


def main() -> int:
    parser = argparse.ArgumentParser(
        description="OmniBus Vulnerability Rule Manager — update rules and scan Zig source",
    )
    parser.add_argument("--update", action="store_true", help="Check for and download rule updates")
    parser.add_argument("--check", action="store_true", help="Scan core/*.zig for vulnerability matches")
    parser.add_argument("--list", action="store_true", help="List all loaded rules")
    parser.add_argument("--url", default=DEFAULT_UPDATE_URL, help="URL for rule manifest")
    parser.add_argument("--output", "-o", default=None, help="Save scan results to JSON file")
    args = parser.parse_args()

    print(f"\n{BOLD}{'='*60}{RESET}")
    print(f"{BOLD}  OmniBus Vulnerability Signature Manager{RESET}")
    print(f"{BOLD}{'='*60}{RESET}\n")

    if not any([args.update, args.check, args.list]):
        parser.print_help()
        return 0

    if args.update:
        update_rules(args.url)
        print()

    rules = load_rules()

    if args.list:
        list_rules(rules)
        print()

    if args.check:
        if not rules:
            log_fail("No rules loaded. Run with --list to verify.")
            return 1

        findings = scan_zig_files(rules)

        # Display results
        severity_colors = {"CRITICAL": RED, "HIGH": RED, "MEDIUM": YELLOW, "LOW": GREEN, "INFO": CYAN}
        print(f"\n{BOLD}Scan Results:{RESET}")

        if not findings:
            log_pass("No vulnerability patterns matched. Code looks clean!")
        else:
            critical = sum(1 for f in findings if f["severity"] in ("CRITICAL", "HIGH"))
            medium = sum(1 for f in findings if f["severity"] == "MEDIUM")
            low = sum(1 for f in findings if f["severity"] in ("LOW", "INFO"))

            for finding in findings:
                color = severity_colors.get(finding["severity"], RESET)
                print(f"\n  {color}[{finding['severity']}]{RESET} {finding['rule_id']}: {finding['description']}")
                print(f"    File: {finding['file']}:{finding['line']}")
                print(f"    Match: {finding['matched_text']}")
                if finding["fix_suggestion"]:
                    print(f"    Fix: {finding['fix_suggestion']}")

            print(f"\n{BOLD}Summary:{RESET}")
            print(f"  {RED}Critical/High:{RESET} {critical}")
            print(f"  {YELLOW}Medium:{RESET}        {medium}")
            print(f"  {GREEN}Low/Info:{RESET}       {low}")
            print(f"  Total:          {len(findings)}")

        if args.output:
            report = {
                "timestamp": datetime.now(tz=timezone.utc).isoformat(),
                "rules_loaded": len(rules),
                "findings_count": len(findings),
                "findings": findings,
            }
            with open(args.output, "w") as f:
                json.dump(report, f, indent=2)
            log_info(f"Report saved to {args.output}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
