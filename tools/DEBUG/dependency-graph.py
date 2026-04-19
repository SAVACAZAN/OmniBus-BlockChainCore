#!/usr/bin/env python3
"""
OmniBus Blockchain Core — Dependency Graph Generator

Generates dependency graph between core/*.zig modules.
Outputs: dependency-graph.json + optional .dot for Graphviz.
"""

import argparse
import json
import os
import re
import sys
from typing import Any, Dict, List, Set, Tuple

GREEN = "\033[92m"
RED = "\033[91m"
YELLOW = "\033[93m"
RESET = "\033[0m"


def cprint(color: str, msg: str) -> None:
    print(f"{color}{msg}{RESET}")


def extract_imports(filepath: str) -> List[str]:
    imports = []
    with open(filepath, "r", encoding="utf-8", errors="ignore") as f:
        content = f.read()
    # Match @import("core/module.zig") or @import("module.zig")
    for m in re.finditer(r'@import\("([^"]+)"\)', content):
        imp = m.group(1)
        base = os.path.basename(imp)
        if base.endswith(".zig"):
            imports.append(base)
    return imports


def build_graph(core_dir: str) -> Tuple[List[str], List[Dict[str, str]]]:
    files = sorted([f for f in os.listdir(core_dir) if f.endswith(".zig")])
    nodes = [f for f in files]
    edges: List[Dict[str, str]] = []
    for f in files:
        fpath = os.path.join(core_dir, f)
        imports = extract_imports(fpath)
        for imp in imports:
            if imp in files and imp != f:
                edges.append({"source": f, "target": imp})
    return nodes, edges


def generate_dot(nodes: List[str], edges: List[Dict[str, str]]) -> str:
    lines = ["digraph OmniBusDeps {"]
    lines.append('  rankdir=LR;')
    lines.append('  node [shape=box, style=filled, fillcolor="#1f2833", fontcolor="#66fcf1"];')
    for n in nodes:
        lines.append(f'  "{n}" ;')
    for e in edges:
        lines.append(f'  "{e["source"]}" -> "{e["target"]}" [color="#45a29e"];')
    lines.append("}")
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(description="Generate dependency graph for core/*.zig")
    parser.add_argument("--core-dir", default="core", help="Path to core/ directory")
    parser.add_argument("--json", default="dependency-graph.json", help="Output JSON path")
    parser.add_argument("--dot", help="Output Graphviz .dot path")
    args = parser.parse_args()

    cprint(GREEN, "=== OmniBus Dependency Graph Generator ===")
    nodes, edges = build_graph(args.core_dir)
    cprint(YELLOW, f"Nodes: {len(nodes)}, Edges: {len(edges)}")

    graph = {"nodes": nodes, "edges": edges}
    with open(args.json, "w", encoding="utf-8") as f:
        json.dump(graph, f, indent=2)
    cprint(GREEN, f"JSON written to {args.json}")

    if args.dot:
        dot = generate_dot(nodes, edges)
        with open(args.dot, "w", encoding="utf-8") as f:
            f.write(dot)
        cprint(GREEN, f"DOT written to {args.dot}")
        cprint(YELLOW, f"Render with: dot -Tpng {args.dot} -o deps.png")

    return 0


if __name__ == "__main__":
    sys.exit(main())
