#!/usr/bin/env python3
"""
Module Mapper — Parse v2.sat / v2.satellite tree structure and map to existing files.
Generates MODULE_MANIFEST.json with coverage stats.
"""
import argparse
import json
import os
import re

GREEN = "\033[92m"
YELLOW = "\033[93m"
RESET = "\033[0m"

def log_ok(m): print(f"{GREEN}[OK]{RESET} {m}")

def parse_v2_sat(filepath):
    with open(filepath, 'r', encoding='utf-8', errors='ignore') as f:
        lines = f.readlines()

    modules = []
    current_module = None
    current_files = []

    for line in lines:
        stripped = line.strip()
        if not stripped:
            continue
        # Module header: anything containing "XX_module_name/"
        m = re.search(r'(\d+_[\w]+)/', stripped)
        if m:
            if current_module:
                modules.append({"id": current_module, "planned_files": current_files})
            current_module = m.group(1)
            current_files = []
            continue
        # File line: may have leading tree chars, then filename
        fm = re.search(r'([\w_]+\.(?:py|rs|go|zig|cpp|c|asm|js|sol|sh|s|json|md|txt|yml|toml))', stripped)
        if fm and current_module:
            current_files.append(fm.group(1))

    if current_module:
        modules.append({"id": current_module, "planned_files": current_files})
    return modules

def find_existing_mapping(filename, project_dir):
    """Try to find if a planned file already exists under a different name."""
    name = os.path.splitext(filename)[0].lower()
    mappings = {
        "bit_fuzzer": ("tools/EXPLOITS/differential-fuzzer.py", "EXISTS"),
        "bit_property_test": ("tools/SECURITY/property-based-crypto.py", "PARTIAL"),
        "bit_z3_solver": ("tools/EXPLOITS/symbolic-exec-helper.py", "PARTIAL"),
        "pow_validator": ("tools/CONSENSUS/difficulty-simulator.py", "PARTIAL"),
        "rop_gadget_finder": ("tools/EXPLOITS/rop-gadget-scanner.py", "EXISTS"),
        "afl_plus_plus_bridge": (None, "MISSING"),
        "consensus_pow_bit": ("tools/CONSENSUS/difficulty-simulator.py", "PARTIAL"),
        "consensus_pos_bit": ("tools/CONSENSUS/finality-checker.py", "PARTIAL"),
        "block_validator": ("core/block_validator.zig", "PARTIAL"),
        "tx_parser": ("core/tx_parser.zig", "PARTIAL"),
        "state_trie": ("core/state_trie.zig", "PARTIAL"),
        "wallet_tester": ("tools/WALLET/wallet-tester.py", "EXISTS"),
        "address_validator": ("tools/WALLET/address-validator.py", "EXISTS"),
        "crypto_audit": ("tools/SECURITY/crypto-audit.py", "EXISTS"),
        "p2p_attack": ("tools/SECURITY/p2p-attack-simulator.py", "EXISTS"),
        "benchmark_crypto": ("tools/PERFORMANCE/benchmark-crypto.zig", "EXISTS"),
        "fork_detector": ("tools/CONSENSUS/fork-detector.py", "EXISTS"),
        "train_anomaly": ("tools/AI/train-anomaly-detector.py", "EXISTS"),
        "rpc_tester": ("tools/NETWORK/rpc-tester.py", "EXISTS"),
        "difficulty_simulator": ("tools/CONSENSUS/difficulty-simulator.py", "EXISTS"),
        "node_health_monitor": ("scripts/devops/node-health-monitor.py", "EXISTS"),
        "backup_chain": ("scripts/devops/backup-chain-data.sh", "EXISTS"),
        "zig_error_decoder": ("tools/DEBUG/zig-error-decoder.py", "EXISTS"),
        "core_dump_analyzer": ("tools/DEBUG/core-dump-analyzer.py", "EXISTS"),
        "dependency_graph": ("tools/DEBUG/dependency-graph.py", "EXISTS"),
    }
    for key, val in mappings.items():
        if key in name:
            return val
    # Generic check: look for partial match in existing files
    for root, _, files in os.walk(project_dir):
        for f in files:
            base = os.path.splitext(f)[0].lower()
            if name in base or base in name:
                rel = os.path.relpath(os.path.join(root, f), project_dir)
                return (rel, "SIMILAR")
    return (None, "MISSING")

def main():
    parser = argparse.ArgumentParser()
    script_dir = os.path.abspath(os.path.dirname(__file__))
    base = os.path.join(script_dir, '..', '..', '..', '..', 'mythos deepseach', 'v2.sat')
    parser.add_argument("--input", default=os.path.normpath(base))
    parser.add_argument("--project", default="../..")
    parser.add_argument("--output", default="../imported/MODULE_MANIFEST.json")
    args = parser.parse_args()

    project_dir = os.path.abspath(args.project)
    log_ok(f"Parsing {args.input}")
    modules = parse_v2_sat(args.input)
    log_ok(f"Found {len(modules)} modules")

    total_planned = 0
    total_impl = 0
    manifest = {"modules": []}

    for mod in modules:
        planned = len(mod["planned_files"])
        total_planned += planned
        impl_list = []
        missing_list = []
        impl_count = 0
        for pf in mod["planned_files"]:
            mapped, status = find_existing_mapping(pf, project_dir)
            if status in ("EXISTS", "PARTIAL", "SIMILAR"):
                impl_list.append(f"{pf} -> {mapped} ({status})")
                impl_count += 1
            else:
                missing_list.append(pf)
        total_impl += impl_count
        manifest["modules"].append({
            "id": mod["id"],
            "planned_files": planned,
            "implemented_files": impl_count,
            "implemented_list": impl_list,
            "missing_list": missing_list
        })

    manifest["total_planned"] = total_planned
    manifest["total_implemented"] = total_impl
    manifest["total_missing"] = total_planned - total_impl
    manifest["coverage_percent"] = round((total_impl / total_planned) * 100, 1) if total_planned else 0

    with open(args.output, 'w', encoding='utf-8') as f:
        json.dump(manifest, f, indent=2)
    log_ok(f"MODULE_MANIFEST.json: {total_planned} planned, {total_impl} implemented, {manifest['coverage_percent']}% coverage")

if __name__ == "__main__":
    main()
