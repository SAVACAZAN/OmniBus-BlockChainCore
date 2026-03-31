#!/usr/bin/env python3
"""
blockchain_dependency_graph.py - Module Dependency Analyzer v1.0

Analizeaza graful de dependente intre modulele blockchain:
  - Cine @import pe cine
  - Detecteaza dependente circulare
  - Gaseste module izolate (zombies)
  - Calculeaza coupling/cohesion per modul
  - Gaseste single points of failure (hub modules)
  - Genereaza graf DOT pentru Graphviz
  - Layer analysis (crypto -> chain -> network -> storage -> node)

Usage:
  python tools/blockchain_dependency_graph.py                 # Full analysis
  python tools/blockchain_dependency_graph.py --dot graph.dot # Export Graphviz DOT
  python tools/blockchain_dependency_graph.py --json deps.json
  python tools/blockchain_dependency_graph.py --module p2p    # Show deps for p2p
"""

import sys
import re
import json
import argparse
from pathlib import Path
from dataclasses import dataclass, field
from typing import List, Dict, Set, Tuple, Optional
from collections import defaultdict

ROOT = Path(__file__).parent.parent.parent
CORE = ROOT / "core"
TEST = ROOT / "test"
AGENT = ROOT / "agent"

# =============================================================================
# DATA CLASSES
# =============================================================================

@dataclass
class ModuleNode:
    name: str
    path: str
    imports: List[str] = field(default_factory=list)       # who I import
    imported_by: List[str] = field(default_factory=list)    # who imports me
    layer: int = 0
    lines: int = 0
    pub_functions: int = 0
    tests: int = 0

@dataclass
class CycleInfo:
    modules: List[str]
    length: int

# =============================================================================
# LAYER DEFINITIONS
# =============================================================================

LAYER_MAP = {
    0: ("CRYPTO", [
        "crypto", "secp256k1", "ripemd160", "pq_crypto", "key_encryption",
        "schnorr", "multisig", "bech32", "encrypted_p2p",
    ]),
    1: ("TYPES", [
        "transaction", "block", "bip32_wallet", "compact_transaction", "witness_data",
        "hex_utils", "utxo", "psbt", "block_filter", "htlc",
        "compact_blocks", "tx_receipt",
    ]),
    2: ("CORE", [
        "blockchain", "blockchain_v2", "genesis", "consensus", "mempool", "wallet",
        "sub_block", "miner_genesis", "e2e_mining", "finality", "governance",
        "shard_config", "prune_config", "archive_manager", "binary_codec",
        "spark_invariants", "chain_config", "light_client", "database",
    ]),
    3: ("NETWORK", [
        "p2p", "sync", "bootstrap", "network", "ws_server",
        "peer_scoring", "kademlia_dht", "dns_registry", "tor_proxy",
    ]),
    4: ("STORAGE", [
        "storage", "state_trie",
    ]),
    5: ("NODE", [
        "node_launcher", "cli", "vault_reader", "vault_engine",
        "mining_pool", "light_miner",
        "shard_coordinator", "metachain", "miner_wallet",
        "lightning", "payment_channel", "staking", "benchmark",
    ]),
    6: ("SERVICE", [
        "rpc_server",
        "bread_ledger", "domain_minter", "ubi_distributor",
        "bridge_relay", "oracle", "omni_brain",
        "synapse_priority", "os_mode", "guardian",
        "agent_manager",
    ]),
    7: ("ENTRY", ["main"]),
}

def get_layer(module_name: str) -> int:
    for layer_num, (_, modules) in LAYER_MAP.items():
        if module_name in modules:
            return layer_num
    return 99

def get_layer_name(layer_num: int) -> str:
    if layer_num in LAYER_MAP:
        return LAYER_MAP[layer_num][0]
    return "UNKNOWN"

# =============================================================================
# GRAPH BUILDING
# =============================================================================

def build_graph() -> Dict[str, ModuleNode]:
    """Build dependency graph from all Zig files."""
    graph = {}

    scan_dirs = [(CORE, "core"), (TEST, "test"), (AGENT, "agent")]

    for d, label in scan_dirs:
        if not d.exists():
            continue
        for fpath in sorted(d.glob("*.zig")):
            name = fpath.stem
            try:
                code = fpath.read_text(encoding='utf-8', errors='replace')
            except Exception:
                continue

            # Extract imports (only local ones, not std/builtin)
            imports = []
            for m in re.finditer(r'@import\s*\(\s*"([^"]+)"\s*\)', code):
                imp = m.group(1).replace(".zig", "")
                if imp not in ("std", "builtin"):
                    imports.append(imp)

            lines = code.count('\n')
            pub_fns = len(re.findall(r'pub\s+(?:export\s+)?fn\s+\w+', code))
            tests = len(re.findall(r'test\s+"[^"]*"', code))

            graph[name] = ModuleNode(
                name=name, path=str(fpath),
                imports=imports, layer=get_layer(name),
                lines=lines, pub_functions=pub_fns, tests=tests,
            )

    # Build reverse edges (imported_by)
    for name, node in graph.items():
        for imp in node.imports:
            if imp in graph:
                graph[imp].imported_by.append(name)

    return graph


# =============================================================================
# ANALYSIS
# =============================================================================

def find_cycles(graph: Dict[str, ModuleNode]) -> List[CycleInfo]:
    """Find circular dependencies using DFS."""
    cycles = []
    visited = set()
    path = []
    path_set = set()

    def dfs(node_name):
        if node_name in path_set:
            # Found cycle
            idx = path.index(node_name)
            cycle = path[idx:] + [node_name]
            cycles.append(CycleInfo(modules=cycle, length=len(cycle) - 1))
            return
        if node_name in visited:
            return

        visited.add(node_name)
        path.append(node_name)
        path_set.add(node_name)

        node = graph.get(node_name)
        if node:
            for imp in node.imports:
                if imp in graph:
                    dfs(imp)

        path.pop()
        path_set.discard(node_name)

    for name in graph:
        dfs(name)

    # Deduplicate cycles
    seen = set()
    unique = []
    for c in cycles:
        key = tuple(sorted(c.modules[:-1]))
        if key not in seen:
            seen.add(key)
            unique.append(c)

    return unique


def find_zombies(graph: Dict[str, ModuleNode]) -> List[str]:
    """Find isolated modules (no imports, not imported by anyone)."""
    zombies = []
    for name, node in graph.items():
        if name == "main":
            continue
        if not node.imports and not node.imported_by:
            zombies.append(name)
    return zombies


def find_hubs(graph: Dict[str, ModuleNode], threshold: int = 5) -> List[Tuple[str, int, int]]:
    """Find hub modules (high in-degree or out-degree)."""
    hubs = []
    for name, node in graph.items():
        in_deg = len(node.imported_by)
        out_deg = len(node.imports)
        if in_deg >= threshold or out_deg >= threshold:
            hubs.append((name, in_deg, out_deg))
    return sorted(hubs, key=lambda x: -(x[1] + x[2]))


def calc_coupling(graph: Dict[str, ModuleNode]) -> Dict[str, float]:
    """Calculate coupling score per module (0=isolated, 1=maximum coupling)."""
    n = len(graph)
    if n <= 1:
        return {}
    coupling = {}
    for name, node in graph.items():
        total_connections = len(set(node.imports) | set(node.imported_by))
        coupling[name] = round(total_connections / (n - 1), 3)
    return coupling


def find_layer_violations(graph: Dict[str, ModuleNode]) -> List[Tuple[str, str, int, int]]:
    """Find imports that go UP in layers (violations)."""
    violations = []
    for name, node in graph.items():
        for imp in node.imports:
            if imp in graph:
                my_layer = node.layer
                imp_layer = graph[imp].layer
                # Only flag when lower layer imports higher layer
                if imp_layer > my_layer and my_layer != 99 and imp_layer != 99:
                    violations.append((name, imp, my_layer, imp_layer))
    return violations


# =============================================================================
# OUTPUT
# =============================================================================

G = "\033[92m"; Y = "\033[93m"; R = "\033[91m"; B = "\033[94m"
C = "\033[96m"; W = "\033[0m"; BOLD = "\033[1m"; DIM = "\033[2m"

LAYER_COLORS = {
    0: "\033[95m",  # Purple - Crypto
    1: "\033[96m",  # Cyan - Types
    2: "\033[92m",  # Green - Core
    3: "\033[94m",  # Blue - Network
    4: "\033[93m",  # Yellow - Storage
    5: "\033[97m",  # White - Node
    6: "\033[33m",  # Dark yellow - Features
    7: "\033[36m",  # Dark cyan - Economic
    8: "\033[91m",  # Red - Entry
}


def print_report(graph: Dict[str, ModuleNode], cycles: List[CycleInfo],
                 zombies: List[str], hubs: List[Tuple[str, int, int]],
                 violations: List[Tuple[str, str, int, int]],
                 coupling: Dict[str, float], specific_module: str = None):
    SEP = "=" * 90

    print(f"\n{SEP}")
    print(f"  {BOLD}OmniBus Blockchain - Dependency Graph Analysis v1.0{W}")
    print(f"  Modules: {len(graph)} | Edges: {sum(len(n.imports) for n in graph.values())}")
    print(f"{SEP}")

    if specific_module:
        node = graph.get(specific_module)
        if not node:
            print(f"  {R}Module not found: {specific_module}{W}")
            return
        print(f"\n  {BOLD}Module: {specific_module}{W} (Layer {node.layer}: {get_layer_name(node.layer)})")
        print(f"  Lines: {node.lines} | Pub functions: {node.pub_functions} | Tests: {node.tests}")
        print(f"  Coupling: {coupling.get(specific_module, 0):.3f}")
        print(f"\n  {C}Imports ({len(node.imports)}):{W}")
        for imp in sorted(node.imports):
            layer = get_layer(imp)
            col = LAYER_COLORS.get(layer, "")
            print(f"    -> {col}{imp}{W} (L{layer}: {get_layer_name(layer)})")
        print(f"\n  {C}Imported by ({len(node.imported_by)}):{W}")
        for imp in sorted(node.imported_by):
            layer = get_layer(imp)
            col = LAYER_COLORS.get(layer, "")
            print(f"    <- {col}{imp}{W} (L{layer}: {get_layer_name(layer)})")
        return

    # Layer-by-layer view
    print(f"\n  {BOLD}DEPENDENCY MAP BY LAYER{W}\n")

    for layer_num in sorted(LAYER_MAP.keys()):
        layer_name, _ = LAYER_MAP[layer_num]
        col = LAYER_COLORS.get(layer_num, "")
        layer_modules = [n for n in graph.values() if n.layer == layer_num]

        if not layer_modules:
            continue

        print(f"  {col}{BOLD}Layer {layer_num}: {layer_name}{W} ({len(layer_modules)} modules)")

        for node in sorted(layer_modules, key=lambda n: -len(n.imported_by)):
            in_deg = len(node.imported_by)
            out_deg = len(node.imports)
            imports_str = ", ".join(node.imports[:5])
            if len(node.imports) > 5:
                imports_str += f" +{len(node.imports)-5}"
            bar_in = ">" * min(in_deg, 20)
            bar_out = "<" * min(out_deg, 20)

            print(f"    {col}{node.name:<25}{W} "
                  f"in={G}{in_deg:<3}{W} out={B}{out_deg:<3}{W} "
                  f"{DIM}-> {imports_str}{W}")

        print()

    # Hubs
    if hubs:
        print(f"  {BOLD}{Y}HUB MODULES (high connectivity){W}")
        for name, in_deg, out_deg in hubs[:10]:
            total = in_deg + out_deg
            bar = "#" * min(total, 30)
            print(f"    {name:<25} in={in_deg:<3} out={out_deg:<3} "
                  f"total={total:<3} {Y}{bar}{W}")
        print()

    # Cycles
    if cycles:
        print(f"  {BOLD}{R}CIRCULAR DEPENDENCIES ({len(cycles)}){W}")
        for c in cycles[:10]:
            print(f"    {R}{' -> '.join(c.modules)}{W}")
        print()
    else:
        print(f"  {G}No circular dependencies found!{W}\n")

    # Layer violations
    if violations:
        print(f"  {BOLD}{Y}LAYER VIOLATIONS ({len(violations)}){W}")
        for src, dst, src_layer, dst_layer in violations[:15]:
            print(f"    {Y}{src}{W} (L{src_layer}) imports {R}{dst}{W} (L{dst_layer}) "
                  f"- {get_layer_name(src_layer)} -> {get_layer_name(dst_layer)}")
        print()

    # Zombies
    if zombies:
        print(f"  {BOLD}{DIM}ISOLATED MODULES ({len(zombies)}){W}")
        for z in zombies:
            print(f"    {DIM}{z} (no imports, not imported){W}")
        print()

    # Stats
    degrees = [(n, len(n.imports), len(n.imported_by)) for n in graph.values()]
    avg_in = sum(d[2] for d in degrees) / len(degrees) if degrees else 0
    avg_out = sum(d[1] for d in degrees) / len(degrees) if degrees else 0
    avg_coupling = sum(coupling.values()) / len(coupling) if coupling else 0

    print(f"{SEP}")
    print(f"  {BOLD}GRAPH METRICS{W}")
    print(f"{SEP}")
    print(f"  Nodes (modules):      {len(graph)}")
    print(f"  Edges (imports):      {sum(len(n.imports) for n in graph.values())}")
    print(f"  Avg in-degree:        {avg_in:.1f}")
    print(f"  Avg out-degree:       {avg_out:.1f}")
    print(f"  Avg coupling:         {avg_coupling:.3f}")
    print(f"  Circular deps:        {len(cycles)}")
    print(f"  Layer violations:     {len(violations)}")
    print(f"  Isolated modules:     {len(zombies)}")
    print(f"{SEP}\n")


def generate_dot(graph: Dict[str, ModuleNode], path: Path):
    """Generate Graphviz DOT file."""
    dot_colors = {
        0: "#c084fc",  # Purple - Crypto
        1: "#67e8f9",  # Cyan - Types
        2: "#86efac",  # Green - Core
        3: "#93c5fd",  # Blue - Network
        4: "#fde047",  # Yellow - Storage
        5: "#e5e7eb",  # Gray - Node
        6: "#fdba74",  # Orange - Features
        7: "#5eead4",  # Teal - Economic
        8: "#fca5a5",  # Red - Entry
    }

    lines = ['digraph BlockchainDeps {']
    lines.append('  rankdir=TB;')
    lines.append('  node [shape=box, style="filled,rounded", fontname="Consolas"];')
    lines.append('  edge [color="#666666"];')
    lines.append('')

    # Create subgraphs per layer
    for layer_num in sorted(LAYER_MAP.keys()):
        layer_name, _ = LAYER_MAP[layer_num]
        layer_modules = [n for n in graph.values() if n.layer == layer_num]
        if not layer_modules:
            continue

        color = dot_colors.get(layer_num, "#f0f0f0")
        lines.append(f'  subgraph cluster_L{layer_num} {{')
        lines.append(f'    label="L{layer_num}: {layer_name}";')
        lines.append(f'    style=dashed; color="{color}";')
        for node in layer_modules:
            lines.append(f'    "{node.name}" [fillcolor="{color}", '
                         f'label="{node.name}\\n{node.lines}L {node.pub_functions}fn"];')
        lines.append('  }')
        lines.append('')

    # Edges
    for name, node in graph.items():
        for imp in node.imports:
            if imp in graph:
                # Red for violations, gray for normal
                if node.layer < graph[imp].layer and node.layer != 99 and graph[imp].layer != 99:
                    lines.append(f'  "{name}" -> "{imp}" [color="red", penwidth=2];')
                else:
                    lines.append(f'  "{name}" -> "{imp}";')

    lines.append('}')

    with open(path, 'w') as f:
        f.write('\n'.join(lines))
    print(f"  DOT graph exported: {path}")
    print(f"  Render with: dot -Tpng {path} -o graph.png")


def export_json(graph: Dict[str, ModuleNode], cycles, zombies, hubs, violations, coupling, path: Path):
    data = {
        "tool": "blockchain_dependency_graph",
        "version": "1.0",
        "modules": {
            name: {
                "layer": node.layer,
                "layer_name": get_layer_name(node.layer),
                "lines": node.lines,
                "pub_functions": node.pub_functions,
                "tests": node.tests,
                "imports": node.imports,
                "imported_by": node.imported_by,
                "coupling": coupling.get(name, 0),
            }
            for name, node in graph.items()
        },
        "cycles": [{"modules": c.modules, "length": c.length} for c in cycles],
        "zombies": zombies,
        "hubs": [{"name": h[0], "in": h[1], "out": h[2]} for h in hubs],
        "violations": [{"from": v[0], "to": v[1], "from_layer": v[2], "to_layer": v[3]} for v in violations],
        "metrics": {
            "nodes": len(graph),
            "edges": sum(len(n.imports) for n in graph.values()),
            "cycles": len(cycles),
            "violations": len(violations),
            "zombies": len(zombies),
        }
    }
    with open(path, 'w') as f:
        json.dump(data, f, indent=2)
    print(f"  JSON exported: {path}")


# =============================================================================
# MAIN
# =============================================================================

def main():
    parser = argparse.ArgumentParser(description="OmniBus Blockchain Dependency Graph v1.0")
    parser.add_argument("--module", "-m", help="Show deps for specific module")
    parser.add_argument("--dot", metavar="FILE", help="Export Graphviz DOT file")
    parser.add_argument("--json", metavar="FILE", help="Export JSON report")
    args = parser.parse_args()

    print(f"\n{'=' * 60}")
    print(f"  {BOLD}OmniBus Blockchain Dependency Graph v1.0{W}")
    print(f"{'=' * 60}")

    print(f"\n  Building dependency graph...")
    graph = build_graph()
    print(f"  Found {len(graph)} modules")

    # Analysis
    cycles = find_cycles(graph)
    zombies = find_zombies(graph)
    hubs = find_hubs(graph)
    coupling = calc_coupling(graph)
    violations = find_layer_violations(graph)

    # Report
    print_report(graph, cycles, zombies, hubs, violations, coupling, args.module)

    if args.dot:
        generate_dot(graph, Path(args.dot))
    if args.json:
        export_json(graph, cycles, zombies, hubs, violations, coupling, Path(args.json))

    sys.exit(1 if cycles else 0)

if __name__ == "__main__":
    main()
