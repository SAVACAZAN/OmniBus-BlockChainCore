#!/usr/bin/env python3
"""
wiki_sync.py — OmniBus BlockChainCore Wiki/Docs Synchronization Tool

Detects discrepancies between actual code (core/*.zig) and documentation
(wiki-omnibus/, docs/api/). Reports what's out of sync and optionally
generates a sync status report.

Usage:
    python tools/SYNC/wiki_sync.py                  # Full report
    python tools/SYNC/wiki_sync.py --check           # Exit 1 if out of sync (CI mode)
    python tools/SYNC/wiki_sync.py --json            # JSON output
    python tools/SYNC/wiki_sync.py --fix-index       # Auto-update wiki INDEX module table
"""

import os
import re
import sys
import json
import hashlib
from pathlib import Path
from datetime import datetime

# ── Paths ────────────────────────────────────────────────────────────────────

ROOT = Path(__file__).resolve().parent.parent.parent
CORE_DIR = ROOT / "core"
DOCS_DIR = ROOT / "docs" / "api"
WIKI_DIR = ROOT / "wiki-omnibus"
INDEX_MD = WIKI_DIR / "INDEX.md"
BUILD_ZIG = ROOT / "build.zig"


# ── Helpers ──────────────────────────────────────────────────────────────────

def get_zig_modules() -> dict[str, Path]:
    """Return dict of module_name -> path for all core/*.zig files."""
    modules = {}
    if CORE_DIR.exists():
        for f in sorted(CORE_DIR.glob("*.zig")):
            modules[f.stem] = f
    return modules


def get_doc_files() -> dict[str, Path]:
    """Return dict of module_name -> path for all docs/api/*.md files."""
    docs = {}
    if DOCS_DIR.exists():
        for f in sorted(DOCS_DIR.glob("*.md")):
            docs[f.stem] = f
    return docs


def get_wiki_index_modules() -> set[str]:
    """Parse INDEX.md and extract module names from the 'Module core' table."""
    modules = set()
    if not INDEX_MD.exists():
        return modules
    text = INDEX_MD.read_text(encoding="utf-8")
    # Match lines like: | core/something.zig | ... |
    for m in re.finditer(r"\|\s*core/(\w+)\.zig\s*\|", text):
        modules.add(m.group(1))
    return modules


def get_build_test_modules() -> set[str]:
    """Parse build.zig and extract module names registered in test steps."""
    modules = set()
    if not BUILD_ZIG.exists():
        return modules
    text = BUILD_ZIG.read_text(encoding="utf-8")
    for m in re.finditer(r'"core/(\w+)\.zig"', text):
        modules.add(m.group(1))
    return modules


def extract_pub_functions(zig_path: Path) -> list[str]:
    """Extract public function names from a .zig file."""
    fns = []
    try:
        text = zig_path.read_text(encoding="utf-8")
        for m in re.finditer(r"pub\s+fn\s+(\w+)", text):
            fns.append(m.group(1))
    except Exception:
        pass
    return fns


def extract_doc_functions(md_path: Path) -> list[str]:
    """Extract function names documented in a .md API doc."""
    fns = []
    try:
        text = md_path.read_text(encoding="utf-8")
        for m in re.finditer(r"###\s+`(\w+)`", text):
            fns.append(m.group(1))
    except Exception:
        pass
    return fns


def extract_constants_from_zig(zig_path: Path) -> dict[str, str]:
    """Extract pub const NAME = VALUE from .zig file."""
    consts = {}
    try:
        text = zig_path.read_text(encoding="utf-8")
        for m in re.finditer(r"pub\s+const\s+(\w+)\s*[=:]\s*(.+?);", text):
            consts[m.group(1)] = m.group(2).strip()
    except Exception:
        pass
    return consts


def extract_rpc_methods(rpc_path: Path) -> list[str]:
    """Extract RPC method names from rpc_server.zig dispatch function."""
    methods = []
    try:
        text = rpc_path.read_text(encoding="utf-8")
        for m in re.finditer(r'eql\(u8,\s*method,\s*"(\w+)"\)', text):
            methods.append(m.group(1))
    except Exception:
        pass
    return methods


def file_hash(path: Path) -> str:
    """SHA256 hash of file contents for change detection."""
    try:
        return hashlib.sha256(path.read_bytes()).hexdigest()[:12]
    except Exception:
        return "missing"


# ── Analysis ─────────────────────────────────────────────────────────────────

def analyze() -> dict:
    """Run full sync analysis, return structured report."""
    zig_modules = get_zig_modules()
    doc_files = get_doc_files()
    wiki_modules = get_wiki_index_modules()
    build_modules = get_build_test_modules()

    zig_names = set(zig_modules.keys())
    doc_names = set(doc_files.keys())

    report = {
        "timestamp": datetime.now().isoformat(),
        "total_zig_modules": len(zig_names),
        "total_docs": len(doc_names),
        "total_wiki_indexed": len(wiki_modules),
        "total_build_tested": len(build_modules),
        "issues": [],
    }

    # 1. Docs without matching .zig
    orphan_docs = doc_names - zig_names
    for name in sorted(orphan_docs):
        report["issues"].append({
            "type": "orphan_doc",
            "severity": "warning",
            "module": name,
            "message": f"docs/api/{name}.md exists but core/{name}.zig does not",
        })

    # 2. .zig without matching doc
    undocumented = zig_names - doc_names
    for name in sorted(undocumented):
        report["issues"].append({
            "type": "missing_doc",
            "severity": "error",
            "module": name,
            "message": f"core/{name}.zig has no docs/api/{name}.md",
        })

    # 3. Wiki INDEX missing modules
    wiki_missing = zig_names - wiki_modules
    for name in sorted(wiki_missing):
        report["issues"].append({
            "type": "wiki_missing",
            "severity": "warning",
            "module": name,
            "message": f"core/{name}.zig not listed in wiki-omnibus/INDEX.md",
        })

    # 4. Wiki INDEX phantom modules (listed but don't exist)
    phantom = wiki_modules - zig_names
    for name in sorted(phantom):
        report["issues"].append({
            "type": "phantom_module",
            "severity": "error",
            "module": name,
            "message": f"wiki INDEX lists core/{name}.zig but file does not exist",
        })

    # 5. Build.zig missing modules (not tested)
    untested = zig_names - build_modules
    for name in sorted(untested):
        report["issues"].append({
            "type": "untested",
            "severity": "info",
            "module": name,
            "message": f"core/{name}.zig not registered in build.zig test steps",
        })

    # 6. Function coverage spot-check (docs vs code)
    fn_issues = []
    for name in sorted(zig_names & doc_names):
        code_fns = set(extract_pub_functions(zig_modules[name]))
        doc_fns = set(extract_doc_functions(doc_files[name]))
        missing_in_doc = code_fns - doc_fns
        # Filter out init/deinit/test helpers that are commonly undocumented
        missing_significant = {f for f in missing_in_doc
                               if not f.startswith("test") and f not in ("deinit",)}
        if len(missing_significant) > 3:  # Only flag if substantial gap
            fn_issues.append({
                "type": "undocumented_functions",
                "severity": "warning",
                "module": name,
                "message": f"{len(missing_significant)} pub functions in code not in doc",
                "functions": sorted(missing_significant),
            })
    report["issues"].extend(fn_issues)

    # 7. RPC method sync
    rpc_path = CORE_DIR / "rpc_server.zig"
    if rpc_path.exists():
        actual_methods = extract_rpc_methods(rpc_path)
        wiki_text = INDEX_MD.read_text(encoding="utf-8") if INDEX_MD.exists() else ""
        wiki_rpc = set(re.findall(r"\|\s*(\w+)\s*\|", wiki_text))
        missing_rpc = set(actual_methods) - wiki_rpc
        if missing_rpc:
            report["issues"].append({
                "type": "rpc_undocumented",
                "severity": "warning",
                "module": "rpc_server",
                "message": f"{len(missing_rpc)} RPC methods in code not in wiki INDEX",
                "methods": sorted(missing_rpc),
            })

    # 8. Module hashes (for change tracking)
    report["module_hashes"] = {}
    for name, path in sorted(zig_modules.items()):
        report["module_hashes"][name] = file_hash(path)

    # Summary
    errors = sum(1 for i in report["issues"] if i["severity"] == "error")
    warnings = sum(1 for i in report["issues"] if i["severity"] == "warning")
    report["summary"] = {
        "errors": errors,
        "warnings": warnings,
        "info": sum(1 for i in report["issues"] if i["severity"] == "info"),
        "sync_status": "OUT_OF_SYNC" if errors > 0 else ("DRIFT" if warnings > 0 else "IN_SYNC"),
    }

    return report


# ── Output ───────────────────────────────────────────────────────────────────

def print_report(report: dict):
    """Print human-readable sync report."""
    print("=" * 70)
    print("  OmniBus BlockChainCore — Wiki/Docs Sync Report")
    print(f"  {report['timestamp']}")
    print("=" * 70)
    print()
    print(f"  Zig modules:     {report['total_zig_modules']}")
    print(f"  API docs:        {report['total_docs']}")
    print(f"  Wiki indexed:    {report['total_wiki_indexed']}")
    print(f"  Build tested:    {report['total_build_tested']}")
    print()

    status = report["summary"]["sync_status"]
    status_icon = {"IN_SYNC": "[OK]", "DRIFT": "[WARN]", "OUT_OF_SYNC": "[FAIL]"}
    print(f"  Status: {status_icon.get(status, '?')} {status}")
    print(f"  Errors: {report['summary']['errors']}  Warnings: {report['summary']['warnings']}  Info: {report['summary']['info']}")
    print()

    if not report["issues"]:
        print("  No issues found — everything is in sync!")
        return

    severity_order = {"error": 0, "warning": 1, "info": 2}
    sorted_issues = sorted(report["issues"], key=lambda i: severity_order.get(i["severity"], 9))

    icons = {"error": "[ERR]", "warning": "[WARN]", "info": "[INFO]"}

    for issue in sorted_issues:
        icon = icons.get(issue["severity"], "?")
        print(f"  {icon} [{issue['type']}] {issue['message']}")
        if "functions" in issue:
            for fn in issue["functions"][:5]:
                print(f"      - {fn}()")
            if len(issue["functions"]) > 5:
                print(f"      ... and {len(issue['functions']) - 5} more")
        if "methods" in issue:
            for m in issue["methods"][:5]:
                print(f"      - {m}")
            if len(issue["methods"]) > 5:
                print(f"      ... and {len(issue['methods']) - 5} more")

    print()
    print("-" * 70)
    print(f"  Run with --json for machine-readable output")
    print(f"  Run with --check for CI exit code (1 = out of sync)")


def save_status_file(report: dict):
    """Save sync status to data/wiki_sync_status.json for tracking over time."""
    data_dir = ROOT / "data"
    data_dir.mkdir(exist_ok=True)
    status_file = data_dir / "wiki_sync_status.json"

    # Load existing history or start fresh
    history = []
    if status_file.exists():
        try:
            history = json.loads(status_file.read_text(encoding="utf-8"))
        except Exception:
            history = []

    # Append current snapshot (keep last 50)
    snapshot = {
        "timestamp": report["timestamp"],
        "status": report["summary"]["sync_status"],
        "errors": report["summary"]["errors"],
        "warnings": report["summary"]["warnings"],
        "modules": report["total_zig_modules"],
        "docs": report["total_docs"],
        "hashes": report["module_hashes"],
    }
    history.append(snapshot)
    history = history[-50:]

    status_file.write_text(json.dumps(history, indent=2), encoding="utf-8")
    print(f"\n  Status saved to {status_file.relative_to(ROOT)}")


# ── Main ─────────────────────────────────────────────────────────────────────

def main():
    args = sys.argv[1:]
    report = analyze()

    if "--json" in args:
        print(json.dumps(report, indent=2))
    else:
        print_report(report)
        save_status_file(report)

    if "--check" in args:
        sys.exit(1 if report["summary"]["errors"] > 0 else 0)


if __name__ == "__main__":
    main()
