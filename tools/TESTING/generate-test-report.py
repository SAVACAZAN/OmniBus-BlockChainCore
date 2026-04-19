#!/usr/bin/env python3
"""
OmniBus Blockchain Core — Test Report Generator

Parses zig test / zig build output and generates an HTML report.
Usage: zig build test-crypto 2>&1 | python3 generate-test-report.py --output report.html
"""

import argparse
import re
import sys
from datetime import datetime
from typing import List, Dict

GREEN = "\033[92m"
RED = "\033[91m"
YELLOW = "\033[93m"
RESET = "\033[0m"


def cprint(color: str, msg: str) -> None:
    print(f"{color}{msg}{RESET}")


def parse_input(lines: List[str]) -> Dict:
    modules: List[Dict] = []
    current_module = ""
    current_tests: List[Dict] = []
    passed = 0
    failed = 0
    skipped = 0

    # Regex patterns
    module_re = re.compile(r"Test\s+\d+/\d+\s+(.+?)\.\.\.")
    pass_re = re.compile(r"\[PASS\]|passed|\s+OK\s")
    fail_re = re.compile(r"\[FAIL\]|failed|error:")
    test_line_re = re.compile(r"(\d+) passed;\s*(\d+) skipped;\s*(\d+) failed")

    for raw in lines:
        line = raw.rstrip()
        m = module_re.search(line)
        if m:
            if current_module:
                modules.append({"name": current_module, "tests": current_tests})
            current_module = m.group(1)
            current_tests = []

        if "passed" in line.lower() and "failed" in line.lower():
            tm = test_line_re.search(line)
            if tm:
                passed += int(tm.group(1))
                skipped += int(tm.group(2))
                failed += int(tm.group(3))

        if pass_re.search(line):
            current_tests.append({"name": line, "status": "PASS"})
        elif fail_re.search(line):
            current_tests.append({"name": line, "status": "FAIL"})

    if current_module:
        modules.append({"name": current_module, "tests": current_tests})

    return {
        "modules": modules,
        "passed": passed,
        "failed": failed,
        "skipped": skipped,
        "total": passed + failed + skipped,
        "timestamp": datetime.utcnow().isoformat() + "Z",
    }


def generate_html(data: Dict) -> str:
    total = data["total"]
    passed = data["passed"]
    failed = data["failed"]
    skipped = data["skipped"]
    pass_pct = (passed / total * 100) if total else 0

    rows = ""
    for mod in data["modules"]:
        mod_pass = sum(1 for t in mod["tests"] if t["status"] == "PASS")
        mod_fail = sum(1 for t in mod["tests"] if t["status"] == "FAIL")
        status_color = "green" if mod_fail == 0 else "red"
        rows += f"""
        <tr>
          <td>{mod['name']}</td>
          <td style="color:green">{mod_pass}</td>
          <td style="color:red">{mod_fail}</td>
          <td style="color:{status_color}">{'PASS' if mod_fail == 0 else 'FAIL'}</td>
        </tr>
        """

    html = f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>OmniBus Test Report</title>
<style>
  body {{ font-family: sans-serif; margin: 2rem; background:#0b0c10; color:#c5c6c7; }}
  h1 {{ color:#66fcf1; }}
  table {{ border-collapse: collapse; width: 100%; margin-top:1rem; }}
  th, td {{ border: 1px solid #45a29e; padding: 0.5rem; text-align: left; }}
  th {{ background:#1f2833; color:#66fcf1; }}
  .summary {{ margin-top:1rem; padding:1rem; background:#1f2833; border-radius:6px; }}
  .bar {{ height:20px; background:#45a29e; border-radius:4px; }}
</style>
</head>
<body>
<h1>OmniBus Test Report</h1>
<p>Generated: {data['timestamp']}</p>
<div class="summary">
  <strong>Summary:</strong> {passed} passed, {failed} failed, {skipped} skipped (total {total})<br>
  <div class="bar" style="width:{pass_pct:.1f}%"></div> {pass_pct:.1f}% pass rate
</div>
<table>
<tr><th>Module</th><th>Passed</th><th>Failed</th><th>Status</th></tr>
{rows}
</table>
</body>
</html>"""
    return html


def main() -> int:
    parser = argparse.ArgumentParser(description="Generate HTML test report from Zig test output")
    parser.add_argument("--output", default="test-report.html", help="Output HTML file")
    parser.add_argument("--input", default="-", help="Input file (default: stdin)")
    args = parser.parse_args()

    if args.input == "-":
        lines = sys.stdin.readlines()
    else:
        with open(args.input, "r", encoding="utf-8") as f:
            lines = f.readlines()

    data = parse_input(lines)
    html = generate_html(data)

    with open(args.output, "w", encoding="utf-8") as f:
        f.write(html)

    cprint(GREEN, f"Report written to {args.output}")
    cprint(GREEN, f"Tests: {data['passed']} passed, {data['failed']} failed, {data['skipped']} skipped")
    return 0 if data["failed"] == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
