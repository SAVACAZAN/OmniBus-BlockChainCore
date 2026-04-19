#!/usr/bin/env python3
"""
sync-deployments.py

Synchronize contract addresses between BlockChainCore and aweb3 Liberty.
Reads deployment artifacts from both projects and produces a unified
address map.  Optionally writes the map back to both projects so they
stay in sync.

Outputs: scripts/cross/deployment-sync.json
"""

import argparse
import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

GREEN = "\033[92m"
RED = "\033[91m"
YELLOW = "\033[93m"
CYAN = "\033[96m"
RESET = "\033[0m"


def log_info(msg: str) -> None:
    print(f"{CYAN}[INFO]{RESET} {msg}")


def log_pass(msg: str) -> None:
    print(f"{GREEN}[PASS]{RESET} {msg}")


def log_fail(msg: str) -> None:
    print(f"{RED}[FAIL]{RESET} {msg}")


def log_warn(msg: str) -> None:
    print(f"{YELLOW}[WARN]{RESET} {msg}")


# ---------------------------------------------------------------------------
# Discovery helpers
# ---------------------------------------------------------------------------
def find_json_artifacts(root: str, filename_patterns: list[str]) -> list[str]:
    found: list[str] = []
    for dirpath, _, filenames in os.walk(root):
        for fname in filenames:
            if any(pat in fname for pat in filename_patterns):
                found.append(os.path.join(dirpath, fname))
    return found


def extract_addresses_from_artifact(path: str) -> dict[str, str]:
    """Try to read Hardhat / Foundry / custom artifact JSON for address."""
    try:
        data = json.loads(Path(path).read_text(encoding="utf-8"))
    except Exception:
        return {}
    addresses: dict[str, str] = {}
    # Hardhat format
    if isinstance(data, dict):
        addr = data.get("address") or data.get("receipt", {}).get("contractAddress")
        if addr:
            contract_name = data.get("contractName") or Path(path).stem
            addresses[contract_name] = addr
        # Foundry broadcast format nested
        for k, v in data.items():
            if isinstance(v, dict):
                sub = v.get("address") or v.get("receipt", {}).get("contractAddress")
                if sub:
                    addresses[k] = sub
    return addresses


def extract_zig_addresses(repo: str) -> dict[str, str]:
    """Look for contract address constants in Zig source or config files."""
    addresses: dict[str, str] = {}
    for root, _, files in os.walk(repo):
        for f in files:
            if f.endswith(".zig") or f.endswith(".json"):
                fpath = os.path.join(root, f)
                try:
                    text = Path(fpath).read_text(encoding="utf-8", errors="replace")
                except Exception:
                    continue
                # Look for 0x40 hex addresses
                for m in __import__("re").finditer(r"(bridge|contract|token|vault|oracle|locker)_?(\w*)\s*[=:]\s*\"(0x[a-fA-F0-9]{40})\"", text):
                    key = m.group(1) + (f"_{m.group(2)}" if m.group(2) else "")
                    addresses[key] = m.group(3)
                for m in __import__("re").finditer(r"\"(0x[a-fA-F0-9]{40})\"", text):
                    addr = m.group(1)
                    # assign generic key if not matched above
                    if addr not in addresses.values():
                        addresses[f"unknown_{addr[:6]}"] = addr
    return addresses


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def main() -> int:
    parser = argparse.ArgumentParser(description="Synchronize deployment addresses.")
    parser.add_argument("--blockchain-core", default=".", help="BlockChainCore repo path")
    parser.add_argument("--aweb3", default="../OmniBus - aweb3", help="aweb3 repo path")
    parser.add_argument("--output", default="scripts/cross/deployment-sync.json", help="Output path")
    parser.add_argument("--write-back", action="store_true", help="Write unified map back to both repos")
    args = parser.parse_args()

    core_path = os.path.abspath(args.blockchain_core)
    aweb3_path = os.path.abspath(args.aweb3)

    log_info("Scanning aweb3 deployment artifacts …")
    aweb3_artifacts = find_json_artifacts(aweb3_path, ["deployment", "artifact", "broadcast", ".json"])
    aweb3_addrs: dict[str, str] = {}
    for art in aweb3_artifacts:
        addrs = extract_addresses_from_artifact(art)
        aweb3_addrs.update(addrs)
    log_info(f"Found {len(aweb3_addrs)} addresses in aweb3")

    log_info("Scanning BlockChainCore for address references …")
    core_addrs = extract_zig_addresses(core_path)
    log_info(f"Found {len(core_addrs)} addresses in BlockChainCore")

    # Build unified map
    unified: dict[str, dict[str, str]] = {
        "aweb3": aweb3_addrs,
        "blockchain_core": core_addrs,
    }

    # Cross-check mismatches
    mismatches: list[dict[str, Any]] = []
    for name, addr in aweb3_addrs.items():
        for cname, caddr in core_addrs.items():
            if name.lower() in cname.lower() or cname.lower() in name.lower():
                if addr.lower() != caddr.lower():
                    mismatches.append({"contract": name, "aweb3": addr, "blockchain_core": caddr})

    if mismatches:
        log_warn(f"{len(mismatches)} address mismatches detected")
        for m in mismatches:
            log_warn(f"  {m['contract']}: aweb3={m['aweb3']} core={m['blockchain_core']}")
    else:
        log_pass("No address mismatches detected")

    report = {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "unified": unified,
        "mismatches": mismatches,
    }

    out_path = os.path.join(core_path, args.output)
    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    with open(out_path, "w", encoding="utf-8") as fh:
        json.dump(report, fh, indent=2)

    if args.write_back:
        core_map_path = os.path.join(core_path, "scripts", "cross", "contract-addresses.json")
        aweb3_map_path = os.path.join(aweb3_path, "scripts", "contract-addresses.json")
        for p in [core_map_path, aweb3_map_path]:
            os.makedirs(os.path.dirname(p), exist_ok=True)
            with open(p, "w", encoding="utf-8") as fh:
                json.dump(unified, fh, indent=2)
        log_info(f"Wrote unified map back to {core_map_path} and {aweb3_map_path}")

    log_pass(f"Sync report written to {out_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
