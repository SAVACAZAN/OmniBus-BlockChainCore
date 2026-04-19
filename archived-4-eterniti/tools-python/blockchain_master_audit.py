#!/usr/bin/env python3
"""
blockchain_master_audit.py - Master Audit Orchestrator v1.0

Ruleaza TOATE tool-urile de audit si genereaza un raport consolidat:
  1. blockchain_analyzer.py  - Module status + quality scores
  2. test_runner.py          - Test execution results
  3. blockchain_deep_audit.py - Complexity + security
  4. blockchain_dependency_graph.py - Dependencies + architecture

Usage:
  python tools/blockchain_master_audit.py              # Run all + generate report
  python tools/blockchain_master_audit.py --skip-tests # Skip test execution
  python tools/blockchain_master_audit.py --json       # Also export all JSON
  python tools/blockchain_master_audit.py --html       # Also export HTML
"""

import sys
import subprocess
import json
import argparse
from pathlib import Path
from datetime import datetime
from typing import List, Dict, Any, Optional

ROOT = Path(__file__).parent.parent
TOOLS = Path(__file__).parent
REPORTS = ROOT / "reports"

G = "\033[92m"; Y = "\033[93m"; R = "\033[91m"; B = "\033[94m"
C = "\033[96m"; W = "\033[0m"; BOLD = "\033[1m"; DIM = "\033[2m"

# =============================================================================
# TOOL DEFINITIONS
# =============================================================================

AUDIT_TOOLS = [
    {
        "name": "Module Analyzer",
        "script": "ANALYSIS/blockchain_analyzer.py",
        "args": [],
        "json_arg": "--json",
        "html_arg": "--html",
        "timeout": 120,
        "critical": True,
    },
    {
        "name": "Deep Audit",
        "script": "ANALYSIS/blockchain_deep_audit.py",
        "args": [],
        "json_arg": "--json",
        "html_arg": None,
        "timeout": 120,
        "critical": True,
    },
    {
        "name": "Dependency Graph",
        "script": "ANALYSIS/blockchain_dependency_graph.py",
        "args": [],
        "json_arg": "--json",
        "html_arg": None,
        "dot_arg": "--dot",
        "timeout": 60,
        "critical": False,
    },
    {
        "name": "Test Runner",
        "script": "TESTING/test_runner.py",
        "args": [],
        "json_arg": "--json",
        "html_arg": None,
        "timeout": 300,
        "critical": False,
        "skip_flag": "skip_tests",
    },
]


def run_tool(tool: dict, json_dir: Path = None, html_dir: Path = None,
             dot_dir: Path = None) -> dict:
    """Run a single audit tool."""
    script = TOOLS / tool["script"]
    if not script.exists():
        return {"name": tool["name"], "status": "MISSING", "output": f"{script} not found"}

    cmd = [sys.executable, str(script)] + tool["args"]

    # Add JSON export
    if json_dir and tool.get("json_arg"):
        json_file = json_dir / f"{Path(tool['script']).stem}.json"
        cmd += [tool["json_arg"], str(json_file)]

    # Add HTML export
    if html_dir and tool.get("html_arg"):
        html_file = html_dir / f"{Path(tool['script']).stem}.html"
        cmd += [tool["html_arg"], str(html_file)]

    # Add DOT export
    if dot_dir and tool.get("dot_arg"):
        dot_file = dot_dir / f"{Path(tool['script']).stem}.dot"
        cmd += [tool["dot_arg"], str(dot_file)]

    print(f"\n  {BOLD}{C}[{tool['name']}]{W}")
    print(f"  Command: {' '.join(cmd)}")
    print(f"  {'-' * 60}")

    try:
        result = subprocess.run(
            cmd, capture_output=False, text=True,
            timeout=tool["timeout"], cwd=ROOT
        )
        return {
            "name": tool["name"],
            "status": "PASS" if result.returncode == 0 else "FAIL",
            "returncode": result.returncode,
        }
    except subprocess.TimeoutExpired:
        print(f"  {R}TIMEOUT after {tool['timeout']}s{W}")
        return {"name": tool["name"], "status": "TIMEOUT"}
    except Exception as e:
        print(f"  {R}ERROR: {e}{W}")
        return {"name": tool["name"], "status": "ERROR", "error": str(e)}


def ordinal(n: int) -> str:
    if 11 <= (n % 100) <= 13:
        return f"{n}th"
    return f"{n}" + {1: "st", 2: "nd", 3: "rd"}.get(n % 10, "th")


def get_next_report_path(reports_dir: Path) -> Path:
    i = 1
    while True:
        candidate = reports_dir / f"MASTER_AUDIT_REPORT-{ordinal(i)}.md"
        if not candidate.exists():
            return candidate
        i += 1


def generate_master_report(tool_results: List, report_path: Path):
    """Generate consolidated markdown report."""
    now = datetime.now()

    with open(report_path, 'w', encoding='utf-8') as f:
        f.write("# OmniBus Blockchain - Master Audit Report\n\n")
        f.write(f"**Date:** {now.strftime('%Y-%m-%d %H:%M:%S')}\n")
        f.write(f"**Tool:** blockchain_master_audit.py v1.0\n\n")

        f.write("## Audit Results\n\n")
        f.write("| Tool | Status | Details |\n")
        f.write("|------|--------|---------|\n")

        passed = 0
        total = len(tool_results)

        for r in tool_results:
            status = r["status"]
            if status == "PASS":
                icon = "PASS"
                passed += 1
            elif status == "FAIL":
                icon = "FAIL"
            elif status == "TIMEOUT":
                icon = "TIMEOUT"
            elif status == "SKIP":
                icon = "SKIP"
                total -= 1
            else:
                icon = "ERROR"

            details = r.get("error", f"Exit code: {r.get('returncode', 'N/A')}")
            f.write(f"| {r['name']} | {icon} | {details} |\n")

        f.write(f"\n**Overall: {passed}/{total} tools passed**\n\n")

        f.write("## Quick Links\n\n")
        f.write("- `reports/blockchain_analyzer.json` - Module quality data\n")
        f.write("- `reports/blockchain_deep_audit.json` - Security & complexity\n")
        f.write("- `reports/blockchain_dependency_graph.json` - Import graph\n")
        f.write("- `reports/blockchain_dependency_graph.dot` - Graphviz visualization\n")
        f.write("- `reports/test_runner.json` - Test results\n\n")

        f.write("## How to Read\n\n")
        f.write("1. **Module Analyzer** - Check which modules are REAL vs STUB\n")
        f.write("2. **Deep Audit** - Look for CRITICAL/HIGH security findings\n")
        f.write("3. **Dependency Graph** - Check for circular deps and layer violations\n")
        f.write("4. **Test Runner** - Which test groups pass/fail\n\n")

        f.write(f"---\n*Generated by OmniBus Blockchain Master Audit v1.0*\n")

    print(f"\n  {G}Master report: {report_path}{W}")


# =============================================================================
# MAIN
# =============================================================================

from typing import List

def main():
    parser = argparse.ArgumentParser(description="OmniBus Blockchain Master Audit v1.0")
    parser.add_argument("--skip-tests", action="store_true", help="Skip test execution")
    parser.add_argument("--json", action="store_true", help="Export all JSON reports")
    parser.add_argument("--html", action="store_true", help="Export HTML reports")
    parser.add_argument("--no-report", action="store_true", help="Don't generate master report")
    args = parser.parse_args()

    print(f"\n{'=' * 70}")
    print(f"  {BOLD}OmniBus Blockchain - MASTER AUDIT v1.0{W}")
    print(f"  {DIM}{datetime.now().strftime('%Y-%m-%d %H:%M:%S')}{W}")
    print(f"{'=' * 70}")

    # Create reports directory
    REPORTS.mkdir(exist_ok=True)
    json_dir = REPORTS if args.json else None
    html_dir = REPORTS if args.html else None
    dot_dir = REPORTS

    tool_results = []
    start_time = datetime.now()

    for tool in AUDIT_TOOLS:
        # Skip tests if requested
        if args.skip_tests and tool.get("skip_flag") == "skip_tests":
            print(f"\n  {Y}[SKIP] {tool['name']}{W}")
            tool_results.append({"name": tool["name"], "status": "SKIP"})
            continue

        result = run_tool(tool, json_dir, html_dir, dot_dir)
        tool_results.append(result)

    # Summary
    duration = (datetime.now() - start_time).total_seconds()

    print(f"\n{'=' * 70}")
    print(f"  {BOLD}MASTER AUDIT SUMMARY{W}")
    print(f"{'=' * 70}")

    for r in tool_results:
        status = r["status"]
        col = {
            "PASS": G, "FAIL": R, "TIMEOUT": Y, "SKIP": DIM, "ERROR": R, "MISSING": R
        }.get(status, "")
        print(f"  [{col}{status:>7}{W}] {r['name']}")

    passed = sum(1 for r in tool_results if r["status"] == "PASS")
    ran = sum(1 for r in tool_results if r["status"] != "SKIP")
    print(f"\n  Result: {BOLD}{passed}/{ran} passed{W} in {duration:.1f}s")

    # Generate master report
    if not args.no_report:
        report_path = get_next_report_path(REPORTS)
        generate_master_report(tool_results, report_path)

    print(f"{'=' * 70}\n")

    # Exit code
    critical_fails = sum(1 for r in tool_results
                        if r["status"] == "FAIL"
                        and any(t["name"] == r["name"] and t.get("critical")
                               for t in AUDIT_TOOLS))
    sys.exit(1 if critical_fails > 0 else 0)

if __name__ == "__main__":
    main()
