#!/usr/bin/env python3
"""
OmniBus Blockchain Core — Log Aggregator

Reads log files from scripts/logs/, merges by timestamp,
filters by severity (INFO/WARN/ERROR). Colored terminal output.
"""

import argparse
import glob
import os
import re
import sys
from datetime import datetime
from pathlib import Path

# ANSI colors
COLORS = {
    "ERROR": "\033[91m",    # red
    "WARN":  "\033[93m",    # yellow
    "WARNING": "\033[93m",  # yellow (alias)
    "INFO":  "\033[92m",    # green
    "DEBUG": "\033[90m",    # gray
}
CYAN = "\033[96m"
DIM = "\033[2m"
BOLD = "\033[1m"
RESET = "\033[0m"

# Common timestamp patterns in OmniBus logs
TIMESTAMP_PATTERNS = [
    # ISO 8601: 2026-04-19T12:30:45.123Z
    re.compile(r"(\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:?\d{2})?)"),
    # Simple: 2026-04-19 12:30:45
    re.compile(r"(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})"),
    # Time only: [12:30:45]
    re.compile(r"\[(\d{2}:\d{2}:\d{2})\]"),
]

# Severity detection patterns
SEVERITY_PATTERN = re.compile(
    r"\b(ERROR|WARN(?:ING)?|INFO|DEBUG|FATAL|CRITICAL)\b", re.IGNORECASE
)


class LogEntry:
    __slots__ = ("timestamp_raw", "timestamp_sort", "severity", "source", "line")

    def __init__(self, timestamp_raw: str, timestamp_sort: str, severity: str, source: str, line: str):
        self.timestamp_raw = timestamp_raw
        self.timestamp_sort = timestamp_sort
        self.severity = severity
        self.source = source
        self.line = line


def extract_timestamp(line: str) -> tuple[str, str]:
    """Extract timestamp from log line. Returns (raw, sortable) or fallbacks."""
    for pat in TIMESTAMP_PATTERNS:
        m = pat.search(line)
        if m:
            raw = m.group(1)
            # Normalize for sorting
            sortable = raw.replace("T", " ").replace("Z", "").rstrip("+-0123456789:")
            return raw, sortable
    return "", "9999-99-99 99:99:99"  # unknown timestamps sort last


def detect_severity(line: str) -> str:
    """Detect log severity from line content."""
    m = SEVERITY_PATTERN.search(line)
    if m:
        sev = m.group(1).upper()
        if sev == "WARNING":
            sev = "WARN"
        if sev in ("FATAL", "CRITICAL"):
            sev = "ERROR"
        return sev

    # Heuristic fallback
    lower = line.lower()
    if "error" in lower or "fail" in lower or "panic" in lower or "crash" in lower:
        return "ERROR"
    elif "warn" in lower:
        return "WARN"
    return "INFO"


def parse_log_file(filepath: str) -> list[LogEntry]:
    """Parse a single log file into LogEntry list."""
    entries = []
    source = os.path.basename(filepath)
    try:
        with open(filepath, "r", encoding="utf-8", errors="replace") as f:
            for line in f:
                line = line.rstrip("\n\r")
                if not line.strip():
                    continue
                ts_raw, ts_sort = extract_timestamp(line)
                severity = detect_severity(line)
                entries.append(LogEntry(ts_raw, ts_sort, severity, source, line))
    except (OSError, IOError) as e:
        print(f"{COLORS['ERROR']}[ERROR] Cannot read {filepath}: {e}{RESET}", file=sys.stderr)
    return entries


def colorize_severity(severity: str) -> str:
    color = COLORS.get(severity, RESET)
    return f"{color}{severity:5s}{RESET}"


def format_entry(entry: LogEntry, show_source: bool = True) -> str:
    """Format a log entry for colored terminal output."""
    parts = []
    if entry.timestamp_raw:
        parts.append(f"{DIM}{entry.timestamp_raw}{RESET}")
    parts.append(colorize_severity(entry.severity))
    if show_source:
        parts.append(f"{CYAN}{entry.source:20s}{RESET}")

    # Colorize the message based on severity
    msg_color = COLORS.get(entry.severity, "")
    parts.append(f"{msg_color}{entry.line}{RESET}")
    return " | ".join(parts)


def main() -> int:
    parser = argparse.ArgumentParser(
        description="OmniBus Log Aggregator — merge and filter logs with colored output"
    )
    parser.add_argument(
        "--dir", default=None,
        help="Directory containing log files (default: scripts/logs/ relative to project root)"
    )
    parser.add_argument(
        "--pattern", default="*.log",
        help="Glob pattern for log files within --dir (default: *.log)"
    )
    parser.add_argument(
        "--severity", "-s", default=None, choices=["INFO", "WARN", "ERROR", "DEBUG"],
        help="Filter: show only this severity and above"
    )
    parser.add_argument(
        "--tail", "-n", type=int, default=0,
        help="Show only the last N entries (0 = all)"
    )
    parser.add_argument(
        "--no-color", action="store_true",
        help="Disable colored output"
    )
    args = parser.parse_args()

    # Disable colors if requested
    if args.no_color:
        for key in COLORS:
            COLORS[key] = ""
        global CYAN, DIM, BOLD, RESET
        CYAN = DIM = BOLD = RESET = ""

    # Resolve log directory
    if args.dir:
        log_dir = args.dir
    else:
        script_dir = os.path.dirname(os.path.abspath(__file__))
        log_dir = os.path.join(script_dir, "..", "logs")

    log_dir = os.path.abspath(log_dir)

    if not os.path.isdir(log_dir):
        print(f"{COLORS['ERROR']}[ERROR] Log directory not found: {log_dir}{RESET}", file=sys.stderr)
        print(f"{DIM}Create it or specify --dir{RESET}", file=sys.stderr)
        return 1

    # Find log files
    search_pattern = os.path.join(log_dir, args.pattern)
    files = sorted(glob.glob(search_pattern))
    if not files:
        # Also check subdirectories
        search_pattern = os.path.join(log_dir, "**", args.pattern)
        files = sorted(glob.glob(search_pattern, recursive=True))

    if not files:
        print(f"{COLORS['WARN']}[WARN] No log files found matching: {search_pattern}{RESET}")
        return 0

    print(f"{BOLD}{CYAN}=== OmniBus Log Aggregator ==={RESET}")
    print(f"{DIM}Directory: {log_dir}{RESET}")
    print(f"{DIM}Files:     {len(files)}{RESET}")
    print()

    # Severity hierarchy for filtering
    severity_order = {"DEBUG": 0, "INFO": 1, "WARN": 2, "ERROR": 3}
    min_severity = severity_order.get(args.severity, 0) if args.severity else 0

    # Parse all log files
    all_entries: list[LogEntry] = []
    for filepath in files:
        entries = parse_log_file(filepath)
        all_entries.extend(entries)
        print(f"{DIM}  Loaded {len(entries):>6d} entries from {os.path.basename(filepath)}{RESET}")

    # Filter by severity
    if args.severity:
        all_entries = [e for e in all_entries if severity_order.get(e.severity, 0) >= min_severity]

    # Sort by timestamp
    all_entries.sort(key=lambda e: e.timestamp_sort)

    # Tail
    if args.tail > 0:
        all_entries = all_entries[-args.tail:]

    print(f"\n{DIM}--- Showing {len(all_entries)} entries ---{RESET}\n")

    show_source = len(files) > 1
    for entry in all_entries:
        print(format_entry(entry, show_source=show_source))

    # Summary
    counts = {"ERROR": 0, "WARN": 0, "INFO": 0, "DEBUG": 0}
    for e in all_entries:
        counts[e.severity] = counts.get(e.severity, 0) + 1

    print(f"\n{DIM}--- Summary ---{RESET}")
    for sev in ["ERROR", "WARN", "INFO", "DEBUG"]:
        if counts.get(sev, 0) > 0:
            print(f"  {colorize_severity(sev)}: {counts[sev]}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
