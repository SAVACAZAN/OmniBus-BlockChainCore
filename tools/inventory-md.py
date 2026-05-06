#!/usr/bin/env python3
"""
inventory-md.py — Scan every Markdown doc in BlockChainCore, classify by
freshness/topic/state, and emit a sortable INVENTORY.md table.

WHY
---
After many sessions, dozens of MD files pile up: ROADMAP_X, PLAN_Y,
SESSION_Z, AUDIT_W, FIX_SUMMARY_DATE, NEXT_*. They overlap, supersede each
other, or are stale. This tool reads them all and tells you which to keep,
which to archive, and which to merge.

CLASSIFICATION (heuristic)
--------------------------
- date_in_name        : has YYYY-MM-DD in filename (likely session/dated)
- has_supersede_word  : contains CANCELLED/SUPERSEDED/OBSOLETE/DEPRECATED
- has_done_marker     : >= 80% lines starting with `- [x]` or `✅` in checklists
- size                : tiny (< 1 KB) / small (< 10 KB) / large
- last_git_change     : days since last commit touched it
- topic               : guessed from filename keywords + first heading

VERDICT (one of)
----------------
- KEEP_PRIMARY    : core docs (CLAUDE.md, README.md, ARCHITECTURE, SETUP)
- KEEP_REFERENCE  : current API / module reference docs
- ARCHIVE_DATED   : has date in name, older than 7 days, no DONE marker
- ARCHIVE_DONE    : phase summaries fully checked off
- ARCHIVE_DEAD    : explicit CANCELLED/SUPERSEDED/OBSOLETE
- MERGE_INTO      : appears to overlap with KEEP doc — flag for manual review
- REVIEW          : unclear — needs human eye

USAGE
-----
    python tools/inventory-md.py
    python tools/inventory-md.py --root .
    python tools/inventory-md.py --output STATUS/INVENTORY.md
    python tools/inventory-md.py --json
    python tools/inventory-md.py --apply-archive    # actually move ARCHIVE_* files
"""

from __future__ import annotations
import argparse
import json
import os
import re
import shutil
import subprocess
import sys
from dataclasses import dataclass, field, asdict
from datetime import date, datetime, timezone
from pathlib import Path

# ── Config ───────────────────────────────────────────────────────────────────

SKIP_DIRS = {
    "node_modules", "zig-out", ".zig-cache", "zig-cache", ".cache",
    "archived-4-eterniti", "8_JUNK", "html", "latex", "dist",
    ".git", "data", "backups", "STATUS",  # we don't scan our own output
}

CORE_KEEPERS = {
    "CLAUDE.md", "README.md", "SETUP.md", "API_REFERENCE.md",
    "MODULES_REFERENCE.md", "CHANGELOG.md",
}

ARCHITECTURE_HINTS = ("ARCHITECTURE", "ARCH_", "DESIGN", "SPEC")
REFERENCE_HINTS    = ("REFERENCE", "API_", "MODULES_", "_GUIDE")
PLAN_HINTS         = ("PLAN", "ROADMAP", "NEXT_", "PROMPT")
SESSION_HINTS      = ("SESSION_", "FIX_SUMMARY", "DEPLOY_", "REPORT")
AUDIT_HINTS        = ("AUDIT", "FINDINGS", "BUG_", "VULN")
PHASE_HINTS        = ("PHASE_", "_SUMMARY")

DATE_RE = re.compile(r"(20\d{2})[-_]?([01]\d)[-_]?([0-3]\d)")
SUPERSEDE_RE = re.compile(r"\b(CANCELLED|SUPERSEDED|OBSOLETE|DEPRECATED|ARCHIVED)\b", re.I)
DONE_LINE_RE = re.compile(r"^\s*[-*]\s*\[[xX]\]")
TODO_LINE_RE = re.compile(r"^\s*[-*]\s*\[\s\]")

ARCHIVE_AGE_DAYS = 7

# ── Data ─────────────────────────────────────────────────────────────────────

@dataclass
class Doc:
    path: str
    relpath: str
    size: int
    date_in_name: str | None = None
    last_git_change: str | None = None      # ISO date
    age_days: int | None = None
    topic: str = "OTHER"
    has_supersede: bool = False
    done_lines: int = 0
    todo_lines: int = 0
    first_heading: str = ""
    verdict: str = "REVIEW"
    reason: str = ""


# ── Helpers ──────────────────────────────────────────────────────────────────

def git_last_change(repo_root: Path, path: Path) -> str | None:
    try:
        out = subprocess.run(
            ["git", "-C", str(repo_root), "log", "-1", "--format=%cI", "--", str(path)],
            capture_output=True, text=True, timeout=15,
        )
        s = out.stdout.strip()
        return s if s else None
    except (OSError, subprocess.TimeoutExpired):
        return None


def days_since(iso: str | None) -> int | None:
    if not iso:
        return None
    try:
        dt = datetime.fromisoformat(iso.replace("Z", "+00:00"))
        return (datetime.now(timezone.utc) - dt).days
    except ValueError:
        return None


def classify_topic(name: str) -> str:
    upper = name.upper()
    if name in CORE_KEEPERS:
        return "CORE"
    if any(h in upper for h in ARCHITECTURE_HINTS):
        return "ARCHITECTURE"
    if any(h in upper for h in REFERENCE_HINTS):
        return "REFERENCE"
    if any(h in upper for h in AUDIT_HINTS):
        return "AUDIT"
    if any(h in upper for h in PHASE_HINTS):
        return "PHASE"
    if any(h in upper for h in SESSION_HINTS):
        return "SESSION"
    if any(h in upper for h in PLAN_HINTS):
        return "PLAN"
    return "OTHER"


def first_heading(text: str) -> str:
    for line in text.splitlines()[:30]:
        if line.startswith("# "):
            return line[2:].strip()[:80]
    return ""


def scan(repo_root: Path) -> list[Doc]:
    docs: list[Doc] = []
    for dirpath, dirnames, filenames in os.walk(repo_root):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS and not d.startswith(".")]
        for name in filenames:
            if not name.lower().endswith(".md"):
                continue
            p = Path(dirpath) / name
            try:
                text = p.read_text(encoding="utf-8", errors="replace")
                size = p.stat().st_size
            except OSError:
                continue
            rel = str(p.relative_to(repo_root)).replace("\\", "/")
            d = Doc(path=str(p), relpath=rel, size=size)

            m = DATE_RE.search(name)
            if m:
                d.date_in_name = f"{m.group(1)}-{m.group(2)}-{m.group(3)}"

            d.has_supersede = bool(SUPERSEDE_RE.search(text[:2000]))
            d.done_lines = sum(1 for ln in text.splitlines() if DONE_LINE_RE.match(ln))
            d.todo_lines = sum(1 for ln in text.splitlines() if TODO_LINE_RE.match(ln))
            d.first_heading = first_heading(text)
            d.topic = classify_topic(name)
            d.last_git_change = git_last_change(repo_root, p)
            d.age_days = days_since(d.last_git_change)

            decide(d)
            docs.append(d)
    docs.sort(key=lambda x: (verdict_order(x.verdict), x.relpath))
    return docs


def decide(d: Doc) -> None:
    name = Path(d.relpath).name

    if d.has_supersede:
        d.verdict = "ARCHIVE_DEAD"
        d.reason = "explicit CANCELLED/SUPERSEDED/OBSOLETE marker"
        return

    if name in CORE_KEEPERS:
        d.verdict = "KEEP_PRIMARY"
        d.reason = "core project documentation"
        return

    if d.topic == "ARCHITECTURE":
        d.verdict = "KEEP_PRIMARY"
        d.reason = "architecture / design doc"
        return

    if d.topic == "REFERENCE":
        d.verdict = "KEEP_REFERENCE"
        d.reason = "API / module reference"
        return

    # PHASE summaries with all boxes checked → done
    if d.topic == "PHASE":
        if d.todo_lines == 0 and d.done_lines >= 3:
            d.verdict = "ARCHIVE_DONE"
            d.reason = f"phase doc, {d.done_lines} ✅ checks, no open TODO"
            return

    # Dated session docs older than threshold → archive
    if d.date_in_name:
        try:
            age = (date.today() - date.fromisoformat(d.date_in_name)).days
        except ValueError:
            age = None
        if age is not None and age > ARCHIVE_AGE_DAYS and d.topic in ("SESSION", "AUDIT", "PLAN", "PHASE"):
            d.verdict = "ARCHIVE_DATED"
            d.reason = f"dated {d.date_in_name} ({age}d ago), topic={d.topic}"
            return

    if d.topic == "SESSION" and (d.age_days or 0) > ARCHIVE_AGE_DAYS:
        d.verdict = "ARCHIVE_DATED"
        d.reason = f"session doc, last touched {d.age_days}d ago"
        return

    if d.topic == "PLAN" and d.todo_lines == 0 and d.done_lines > 0:
        d.verdict = "ARCHIVE_DONE"
        d.reason = "plan with all items completed"
        return

    if d.topic == "PLAN":
        d.verdict = "KEEP_REFERENCE"
        d.reason = f"open plan ({d.todo_lines} TODO)"
        return

    d.verdict = "REVIEW"
    d.reason = "no clear classification — needs human eye"


VERDICT_ORDER = ["KEEP_PRIMARY", "KEEP_REFERENCE", "REVIEW", "ARCHIVE_DEAD",
                 "ARCHIVE_DONE", "ARCHIVE_DATED", "MERGE_INTO"]

def verdict_order(v: str) -> int:
    try:
        return VERDICT_ORDER.index(v)
    except ValueError:
        return 99


# ── Render ───────────────────────────────────────────────────────────────────

def render_markdown(docs: list[Doc], repo_root: Path) -> str:
    today = date.today().isoformat()
    out: list[str] = []
    out.append(f"# Markdown inventory — {today}")
    out.append("")
    out.append(f"Auto-generated by `tools/inventory-md.py`. Re-run after each session.")
    out.append("")
    out.append(f"Repo root: `{repo_root}`")
    out.append("")
    out.append("## Verdict legend")
    out.append("")
    out.append("- **KEEP_PRIMARY** — core docs, never touch")
    out.append("- **KEEP_REFERENCE** — active references, keep")
    out.append("- **REVIEW** — needs your eye, classification unclear")
    out.append("- **ARCHIVE_DEAD** — has CANCELLED/SUPERSEDED marker → move to archiveREADME/")
    out.append("- **ARCHIVE_DONE** — phase doc fully completed → archive")
    out.append("- **ARCHIVE_DATED** — old session/audit doc → archive")
    out.append("- **MERGE_INTO** — overlaps with another KEEP doc → manual merge")
    out.append("")

    # Summary
    counts: dict[str, int] = {}
    for d in docs:
        counts[d.verdict] = counts.get(d.verdict, 0) + 1
    out.append("## Summary")
    out.append("")
    out.append(f"Total: **{len(docs)}** markdown files")
    out.append("")
    out.append("| Verdict | Count |")
    out.append("|---|---|")
    for v in VERDICT_ORDER:
        if counts.get(v, 0):
            out.append(f"| {v} | {counts[v]} |")
    out.append("")

    # Group by verdict
    for verdict in VERDICT_ORDER:
        group = [d for d in docs if d.verdict == verdict]
        if not group:
            continue
        out.append(f"## {verdict} ({len(group)})")
        out.append("")
        out.append("| File | Topic | Size | Date in name | Last git | Age | TODO/Done | Reason |")
        out.append("|---|---|---|---|---|---|---|---|")
        for d in group:
            size_kb = f"{d.size//1024}K" if d.size >= 1024 else f"{d.size}B"
            age = f"{d.age_days}d" if d.age_days is not None else "?"
            last = (d.last_git_change or "")[:10]
            out.append(f"| `{d.relpath}` | {d.topic} | {size_kb} | {d.date_in_name or ''} | {last} | {age} | {d.todo_lines}/{d.done_lines} | {d.reason} |")
        out.append("")

    return "\n".join(out) + "\n"


# ── Apply archive ────────────────────────────────────────────────────────────

def apply_archive(docs: list[Doc], repo_root: Path) -> tuple[int, list[str]]:
    archive_dir = repo_root / "STATUS" / "archiveREADME"
    archive_dir.mkdir(parents=True, exist_ok=True)
    moved: list[str] = []
    log_lines = [f"# Archived MD index", "", f"Generated by `tools/inventory-md.py --apply-archive` on {date.today().isoformat()}.", "", "| File | Verdict | Reason | Original location |", "|---|---|---|---|"]
    for d in docs:
        if d.verdict not in ("ARCHIVE_DEAD", "ARCHIVE_DONE", "ARCHIVE_DATED"):
            continue
        src = Path(d.path)
        if not src.exists():
            continue
        # Flatten name to avoid collisions: replace / with __
        flat_name = d.relpath.replace("/", "__")
        dst = archive_dir / flat_name
        if dst.exists():
            continue  # already archived in a previous run
        shutil.move(str(src), str(dst))
        moved.append(d.relpath)
        log_lines.append(f"| `{flat_name}` | {d.verdict} | {d.reason} | `{d.relpath}` |")
    (archive_dir / "INDEX.md").write_text("\n".join(log_lines) + "\n", encoding="utf-8")
    return len(moved), moved


# ── Main ─────────────────────────────────────────────────────────────────────

def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=None, help="Repo root (default: parent of this script's dir)")
    ap.add_argument("--output", default=None, help="Output path (default: STATUS/INVENTORY.md)")
    ap.add_argument("--json", action="store_true", help="Emit JSON to stdout")
    ap.add_argument("--apply-archive", action="store_true",
                    help="Actually move ARCHIVE_* files to STATUS/archiveREADME/")
    args = ap.parse_args()

    script_dir = Path(__file__).resolve().parent
    repo_root = Path(args.root).resolve() if args.root else script_dir.parent
    if not repo_root.exists():
        print(f"ERROR: repo root not found: {repo_root}", file=sys.stderr)
        return 2

    docs = scan(repo_root)

    if args.json:
        json.dump([asdict(d) for d in docs], sys.stdout, indent=2)
        sys.stdout.write("\n")
        return 0

    out_path = Path(args.output) if args.output else repo_root / "STATUS" / "INVENTORY.md"
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(render_markdown(docs, repo_root), encoding="utf-8")
    print(f"Scanned {len(docs)} markdown files.")
    for v in VERDICT_ORDER:
        c = sum(1 for d in docs if d.verdict == v)
        if c:
            print(f"  {v}: {c}")
    print(f"Report: {out_path}")

    if args.apply_archive:
        n, moved = apply_archive(docs, repo_root)
        print(f"\nArchived {n} files to STATUS/archiveREADME/")
        for m in moved[:10]:
            print(f"  -> {m}")
        if n > 10:
            print(f"  ... and {n - 10} more (see STATUS/archiveREADME/INDEX.md)")

    return 0


if __name__ == "__main__":
    sys.exit(main())
