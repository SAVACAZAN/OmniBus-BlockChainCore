#!/usr/bin/env python3
"""
OmniBus BlockChainCore — API Surface Analyzer
===============================================
Scans core/*.zig files for ``pub fn`` declarations and catalogs the
entire public API surface of the project.

Features:
  - Lists all public functions grouped by module
  - Detects potentially unused public functions (pub fn not @imported
    by any other module)
  - Counts pub const, pub var, pub struct, pub enum too
  - Exports results as table + JSON

Usage:
    python api-surface-analyzer.py
    python api-surface-analyzer.py --source-dir ../../core
    python api-surface-analyzer.py --json-output api.json --show-unused
"""

import argparse
import json
import re
import sys
from collections import defaultdict
from pathlib import Path

# ── ANSI colours ─────────────────────────────────────────────────────
RESET   = "\033[0m"
BOLD    = "\033[1m"
DIM     = "\033[2m"
RED     = "\033[91m"
GREEN   = "\033[92m"
YELLOW  = "\033[93m"
CYAN    = "\033[96m"
MAGENTA = "\033[95m"
WHITE   = "\033[97m"
BG_BLUE = "\033[44m"

# Patterns
PUB_FN_RE     = re.compile(r'pub\s+(?:export\s+)?fn\s+(\w+)\s*\(([^)]*)\)')
PUB_CONST_RE  = re.compile(r'pub\s+const\s+(\w+)')
PUB_VAR_RE    = re.compile(r'pub\s+var\s+(\w+)')
PUB_STRUCT_RE = re.compile(r'pub\s+const\s+(\w+)\s*=\s*(?:extern\s+)?struct')
PUB_ENUM_RE   = re.compile(r'pub\s+const\s+(\w+)\s*=\s*enum')
IMPORT_RE     = re.compile(r'@import\s*\(\s*"([^"]+)"\s*\)')
FIELD_ACCESS_RE = re.compile(r'\.(\w+)')


def analyze_file(filepath: Path) -> dict:
    """Extract all public symbols from a .zig file."""
    try:
        content = filepath.read_text(encoding="utf-8", errors="replace")
    except Exception as exc:
        return {"error": str(exc)}

    module = filepath.stem

    pub_fns = []
    for match in PUB_FN_RE.finditer(content):
        name = match.group(1)
        params_raw = match.group(2).strip()
        # Count params (rough)
        param_count = len([p for p in params_raw.split(",") if p.strip()]) if params_raw else 0
        # Find line number
        line_num = content[:match.start()].count("\n") + 1
        pub_fns.append({
            "name": name,
            "params": param_count,
            "params_raw": params_raw[:80],
            "line": line_num,
        })

    pub_structs = [m.group(1) for m in PUB_STRUCT_RE.finditer(content)]
    pub_enums = [m.group(1) for m in PUB_ENUM_RE.finditer(content)]

    # pub const that aren't structs/enums
    all_pub_const = [m.group(1) for m in PUB_CONST_RE.finditer(content)]
    pub_consts = [c for c in all_pub_const if c not in pub_structs and c not in pub_enums]

    pub_vars = [m.group(1) for m in PUB_VAR_RE.finditer(content)]
    imports = IMPORT_RE.findall(content)

    return {
        "module": module,
        "path": str(filepath),
        "pub_fns": pub_fns,
        "pub_structs": pub_structs,
        "pub_enums": pub_enums,
        "pub_consts": pub_consts,
        "pub_vars": pub_vars,
        "imports": imports,
        "total_pub_symbols": len(pub_fns) + len(pub_structs) + len(pub_enums) + len(pub_consts) + len(pub_vars),
    }


def find_unused_pub_fns(all_results: list) -> dict:
    """
    Find pub fn declarations that are never referenced in other modules.
    A pub fn is 'used' if another file imports the module AND references
    the function name.
    """
    # Build: which modules import which files
    module_imports = {}  # module -> list of imported module names
    module_content = {}  # module -> full file content

    for r in all_results:
        if "error" in r:
            continue
        mod = r["module"]
        module_imports[mod] = [
            imp.replace(".zig", "") for imp in r["imports"]
        ]
        try:
            module_content[mod] = Path(r["path"]).read_text(encoding="utf-8", errors="replace")
        except Exception:
            module_content[mod] = ""

    unused = defaultdict(list)  # module -> [fn_name, ...]

    for r in all_results:
        if "error" in r:
            continue
        mod = r["module"]
        for fn in r["pub_fns"]:
            fn_name = fn["name"]
            # Check if any other module references this function
            is_used = False
            for other_mod, content in module_content.items():
                if other_mod == mod:
                    continue
                # Check if other_mod imports this module and uses the fn
                if mod in module_imports.get(other_mod, []):
                    if re.search(r'\.' + re.escape(fn_name) + r'\b', content):
                        is_used = True
                        break
                # Also check direct name usage (less accurate)
                if fn_name in content and fn_name not in ("init", "deinit", "main"):
                    is_used = True
                    break

            if not is_used:
                unused[mod].append(fn_name)

    return dict(unused)


def print_api_table(all_results: list):
    """Print grouped API surface."""
    print(f"\n{BG_BLUE}{WHITE}{BOLD} OmniBus Public API Surface {RESET}\n")

    # Summary table
    print(f"  {BOLD}{'Module':<30s}  {'PubFn':>5s}  {'Struct':>6s}  {'Enum':>4s}  {'Const':>5s}  {'Var':>3s}  {'Total':>5s}{RESET}")
    print(f"  {DIM}{'─' * 75}{RESET}")

    for r in sorted(all_results, key=lambda x: x.get("total_pub_symbols", 0), reverse=True):
        if "error" in r:
            continue
        mod = r["module"]
        if len(mod) > 30:
            mod = mod[:27] + "..."
        print(
            f"  {CYAN}{mod:<30s}{RESET}  "
            f"{len(r['pub_fns']):5d}  "
            f"{len(r['pub_structs']):6d}  "
            f"{len(r['pub_enums']):4d}  "
            f"{len(r['pub_consts']):5d}  "
            f"{len(r['pub_vars']):3d}  "
            f"{BOLD}{r['total_pub_symbols']:5d}{RESET}"
        )

    print(f"  {DIM}{'─' * 75}{RESET}")


def print_detailed(all_results: list, show_params: bool):
    """Print detailed function list per module."""
    print(f"\n{MAGENTA}{BOLD}  Detailed Public Functions{RESET}")
    print(f"  {DIM}{'─' * 70}{RESET}")

    for r in sorted(all_results, key=lambda x: x.get("module", "")):
        if "error" in r or not r["pub_fns"]:
            continue
        print(f"\n  {CYAN}{BOLD}{r['module']}{RESET} ({len(r['pub_fns'])} pub fn)")
        for fn in sorted(r["pub_fns"], key=lambda f: f["line"]):
            params_hint = f" ({fn['params']} params)" if fn["params"] > 0 else "()"
            line_hint = f" L{fn['line']}"
            print(f"    {GREEN}fn{RESET} {fn['name']}{DIM}{params_hint}{line_hint}{RESET}")


def print_unused(unused: dict):
    """Print unused public functions."""
    if not unused:
        print(f"\n  {GREEN}All public functions appear to be referenced externally.{RESET}")
        return

    total = sum(len(fns) for fns in unused.values())
    print(f"\n  {YELLOW}{BOLD}Potentially Unused Public Functions: {total}{RESET}")
    print(f"  {DIM}(pub fn not referenced via @import in other modules){RESET}")
    print(f"  {DIM}{'─' * 60}{RESET}")

    for mod in sorted(unused):
        fns = unused[mod]
        print(f"  {CYAN}{mod}{RESET}:")
        for fn_name in sorted(fns):
            print(f"    {YELLOW}pub fn {fn_name}{RESET}")

    print(f"\n  {DIM}Note: Some may be used via comptime or as callbacks.{RESET}")


def main():
    parser = argparse.ArgumentParser(
        description="Analyze the public API surface of OmniBus Zig modules",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "Examples:\n"
            "  python api-surface-analyzer.py\n"
            "  python api-surface-analyzer.py --show-unused --detailed\n"
            "  python api-surface-analyzer.py --json-output api.json"
        ),
    )
    script_dir = Path(__file__).resolve().parent
    default_src = script_dir.parent.parent / "core"

    parser.add_argument("--source-dir", type=str, default=str(default_src),
                        help=f"Source directory (default: {default_src})")
    parser.add_argument("--json-output", type=str, default=None, help="Export to JSON")
    parser.add_argument("--show-unused", action="store_true", help="Detect unused pub fns")
    parser.add_argument("--detailed", action="store_true", help="Show full function list")
    args = parser.parse_args()

    source_dir = Path(args.source_dir)
    if not source_dir.exists():
        print(f"{RED}ERROR:{RESET} Source directory not found: {source_dir}")
        sys.exit(1)

    zig_files = sorted(source_dir.glob("*.zig"))
    if not zig_files:
        zig_files = sorted(source_dir.rglob("*.zig"))

    if not zig_files:
        print(f"{RED}ERROR:{RESET} No .zig files found in {source_dir}")
        sys.exit(1)

    print(f"{CYAN}Scanning {len(zig_files)} Zig files...{RESET}")

    all_results = [analyze_file(f) for f in zig_files]
    valid = [r for r in all_results if "error" not in r]

    print_api_table(all_results)

    if args.detailed:
        print_detailed(all_results, show_params=True)

    if args.show_unused:
        unused = find_unused_pub_fns(all_results)
        print_unused(unused)

    # Summary
    total_pub = sum(r.get("total_pub_symbols", 0) for r in valid)
    total_fns = sum(len(r.get("pub_fns", [])) for r in valid)
    print(f"\n  {BOLD}Total:{RESET} {total_pub} public symbols across {len(valid)} modules ({total_fns} functions)\n")

    if args.json_output:
        export = {
            "modules": [
                {k: v for k, v in r.items() if k != "path"}
                for r in all_results if "error" not in r
            ],
            "total_pub_symbols": total_pub,
            "total_pub_functions": total_fns,
        }
        if args.show_unused:
            export["unused_pub_fns"] = find_unused_pub_fns(all_results)

        with open(args.json_output, "w") as f:
            json.dump(export, f, indent=2)
        print(f"{GREEN}JSON exported to {args.json_output}{RESET}")


if __name__ == "__main__":
    main()
