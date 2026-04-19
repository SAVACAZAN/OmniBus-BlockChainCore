#!/usr/bin/env python3
"""
OmniBus BlockChainCore — Dependency Mapper
===========================================
Scans core/*.zig files for @import statements and builds a dependency
graph between modules.  Detects circular dependencies.

Output formats:
  - Adjacency list (text table)
  - DOT format (for Graphviz: dot -Tpng deps.dot -o deps.png)
  - JSON graph

Usage:
    python dependency-mapper.py
    python dependency-mapper.py --source-dir ../../core
    python dependency-mapper.py --dot-output deps.dot --json-output deps.json
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


def scan_imports(filepath: Path) -> list[str]:
    """Extract @import targets from a .zig file."""
    try:
        content = filepath.read_text(encoding="utf-8", errors="replace")
    except Exception:
        return []

    pattern = re.compile(r'@import\s*\(\s*"([^"]+)"\s*\)')
    return pattern.findall(content)


def build_graph(source_dir: Path) -> tuple[dict, set]:
    """Build dependency graph.  Returns (graph, all_modules)."""
    zig_files = sorted(source_dir.glob("*.zig"))
    if not zig_files:
        zig_files = sorted(source_dir.rglob("*.zig"))

    graph = defaultdict(set)       # module -> set of dependencies
    all_modules = set()
    external_deps = set()

    for f in zig_files:
        module_name = f.stem
        all_modules.add(module_name)
        imports = scan_imports(f)

        for imp in imports:
            if imp.endswith(".zig"):
                dep_name = imp.replace(".zig", "")
                graph[module_name].add(dep_name)
            elif imp == "std" or imp == "builtin":
                external_deps.add(imp)
            else:
                # Could be a package or relative path
                dep_name = imp.split("/")[-1].replace(".zig", "")
                graph[module_name].add(dep_name)

    return dict(graph), all_modules, external_deps


def find_cycles(graph: dict) -> list[list[str]]:
    """Detect circular dependencies using DFS."""
    cycles = []
    visited = set()
    rec_stack = set()
    path = []

    def dfs(node):
        visited.add(node)
        rec_stack.add(node)
        path.append(node)

        for neighbor in graph.get(node, set()):
            if neighbor not in visited:
                dfs(neighbor)
            elif neighbor in rec_stack:
                # Found a cycle
                cycle_start = path.index(neighbor)
                cycle = path[cycle_start:] + [neighbor]
                cycles.append(cycle)

        path.pop()
        rec_stack.discard(node)

    for node in graph:
        if node not in visited:
            dfs(node)

    return cycles


def compute_stats(graph: dict, all_modules: set) -> dict:
    """Compute graph statistics."""
    reverse_graph = defaultdict(set)
    for src, deps in graph.items():
        for dep in deps:
            reverse_graph[dep].add(src)

    stats = {}
    for m in all_modules:
        out_degree = len(graph.get(m, set()))
        in_degree = len(reverse_graph.get(m, set()))
        stats[m] = {
            "out_degree": out_degree,   # depends on N modules
            "in_degree": in_degree,      # used by N modules
            "is_leaf": out_degree == 0 and in_degree > 0,
            "is_root": in_degree == 0 and out_degree > 0,
            "is_isolated": out_degree == 0 and in_degree == 0,
        }
    return stats


def generate_dot(graph: dict, all_modules: set, cycles: list) -> str:
    """Generate DOT format for Graphviz."""
    cycle_edges = set()
    for cycle in cycles:
        for i in range(len(cycle) - 1):
            cycle_edges.add((cycle[i], cycle[i + 1]))

    lines = ['digraph OmniBusDeps {']
    lines.append('    rankdir=LR;')
    lines.append('    node [shape=box, style=filled, fillcolor="#e8f4f8", fontname="Consolas"];')
    lines.append('    edge [color="#666666"];')
    lines.append('')

    for module in sorted(all_modules):
        if module not in graph and not any(module in deps for deps in graph.values()):
            lines.append(f'    "{module}" [fillcolor="#ffe0e0"];')  # isolated = red

    for src, deps in sorted(graph.items()):
        for dep in sorted(deps):
            if dep in all_modules:
                color = 'color="red", penwidth=2' if (src, dep) in cycle_edges else ''
                lines.append(f'    "{src}" -> "{dep}" [{color}];')

    lines.append('}')
    return '\n'.join(lines)


def print_adjacency(graph: dict, stats: dict, all_modules: set):
    """Print adjacency list as table."""
    print(f"\n{BG_BLUE}{WHITE}{BOLD} OmniBus Dependency Map {RESET}\n")

    print(f"  {BOLD}{'Module':<35s}  {'Out':>3s}  {'In':>3s}  {'Dependencies'}{RESET}")
    print(f"  {DIM}{'─' * 90}{RESET}")

    for module in sorted(all_modules):
        deps = sorted(graph.get(module, set()))
        s = stats.get(module, {})
        out_d = s.get("out_degree", 0)
        in_d = s.get("in_degree", 0)

        # Colour based on role
        if s.get("is_isolated"):
            mod_col = DIM
        elif s.get("is_root"):
            mod_col = YELLOW
        elif s.get("is_leaf"):
            mod_col = GREEN
        else:
            mod_col = CYAN

        deps_str = ", ".join(deps[:8])
        if len(deps) > 8:
            deps_str += f" (+{len(deps) - 8} more)"

        name = module if len(module) <= 35 else module[:32] + "..."
        print(f"  {mod_col}{name:<35s}{RESET}  {out_d:3d}  {in_d:3d}  {DIM}{deps_str}{RESET}")

    print(f"  {DIM}{'─' * 90}{RESET}")


def print_cycles(cycles: list):
    """Print detected cycles."""
    if not cycles:
        print(f"\n  {GREEN}{BOLD}No circular dependencies detected.{RESET}")
        return

    print(f"\n  {RED}{BOLD}Circular Dependencies Detected: {len(cycles)}{RESET}")
    print(f"  {DIM}{'─' * 60}{RESET}")
    for i, cycle in enumerate(cycles, 1):
        chain = " -> ".join(cycle)
        print(f"  {RED}{i}.{RESET} {YELLOW}{chain}{RESET}")


def print_summary(all_modules: set, graph: dict, stats: dict, external_deps: set):
    """Print summary stats."""
    total_edges = sum(len(deps) for deps in graph.values())
    roots = [m for m, s in stats.items() if s.get("is_root")]
    leaves = [m for m, s in stats.items() if s.get("is_leaf")]
    isolated = [m for m, s in stats.items() if s.get("is_isolated")]

    print(f"\n  {MAGENTA}{BOLD}Summary{RESET}")
    print(f"  {DIM}{'─' * 40}{RESET}")
    print(f"    Total modules:    {BOLD}{len(all_modules)}{RESET}")
    print(f"    Total edges:      {total_edges}")
    print(f"    Root modules:     {len(roots)} {DIM}(depend on others but nobody depends on them){RESET}")
    print(f"    Leaf modules:     {len(leaves)} {DIM}(depended upon but depend on nothing){RESET}")
    print(f"    Isolated:         {len(isolated)} {DIM}(no internal deps){RESET}")
    print(f"    External deps:    {', '.join(sorted(external_deps)) or 'none'}")

    if roots:
        print(f"\n    {YELLOW}Root modules:{RESET} {', '.join(sorted(roots)[:10])}")
    if leaves:
        print(f"    {GREEN}Leaf modules:{RESET} {', '.join(sorted(leaves)[:10])}")
    print()


def main():
    parser = argparse.ArgumentParser(
        description="Map Zig module dependencies in OmniBus BlockChainCore",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "Examples:\n"
            "  python dependency-mapper.py\n"
            "  python dependency-mapper.py --dot-output deps.dot\n"
            "  python dependency-mapper.py --json-output deps.json"
        ),
    )
    script_dir = Path(__file__).resolve().parent
    default_src = script_dir.parent.parent / "core"

    parser.add_argument("--source-dir", type=str, default=str(default_src),
                        help=f"Source directory to scan (default: {default_src})")
    parser.add_argument("--dot-output", type=str, default=None,
                        help="Export DOT graph for Graphviz")
    parser.add_argument("--json-output", type=str, default=None,
                        help="Export dependency data as JSON")
    args = parser.parse_args()

    source_dir = Path(args.source_dir)
    if not source_dir.exists():
        print(f"{RED}ERROR:{RESET} Source directory not found: {source_dir}")
        sys.exit(1)

    print(f"{CYAN}Scanning Zig files in {source_dir}...{RESET}")

    graph, all_modules, external_deps = build_graph(source_dir)

    if not all_modules:
        print(f"{RED}ERROR:{RESET} No .zig files found.")
        sys.exit(1)

    stats = compute_stats(graph, all_modules)
    cycles = find_cycles(graph)

    print_adjacency(graph, stats, all_modules)
    print_cycles(cycles)
    print_summary(all_modules, graph, stats, external_deps)

    if args.dot_output:
        dot_content = generate_dot(graph, all_modules, cycles)
        Path(args.dot_output).write_text(dot_content)
        print(f"{GREEN}DOT graph exported to {args.dot_output}{RESET}")
        print(f"{DIM}Render: dot -Tpng {args.dot_output} -o deps.png{RESET}")

    if args.json_output:
        export = {
            "modules": sorted(all_modules),
            "graph": {k: sorted(v) for k, v in graph.items()},
            "cycles": cycles,
            "stats": stats,
            "external_deps": sorted(external_deps),
        }
        with open(args.json_output, "w") as f:
            json.dump(export, f, indent=2)
        print(f"{GREEN}JSON exported to {args.json_output}{RESET}")


if __name__ == "__main__":
    main()
