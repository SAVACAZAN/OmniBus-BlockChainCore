#!/usr/bin/env python3
"""
Deduplicator — Scan all imported files, compute SHA-256, cross-reference with existing tools/scripts.
Generates MASTER_INDEX.json.
"""
import argparse
import hashlib
import json
import os
import re
import sys

GREEN = "\033[92m"
RED = "\033[91m"
YELLOW = "\033[93m"
RESET = "\033[0m"

def log_ok(m): print(f"{GREEN}[OK]{RESET} {m}")
def log_warn(m): print(f"{YELLOW}[WARN]{RESET} {m}")

def classify_attack(code):
    code_lower = code.lower()
    mapping = [
        ("reentrancy", ["reentrancy", "reentrant", "fallback", "call.value", "send("]),
        ("flash_loan", ["flashloan", "flash_loan", "flash loan", "aave", "dy/dx", "uniswapv2", "swap("]),
        ("oracle", ["oracle", "chainlink", "price feed", "manipulat", "getprice", "latestanswer"]),
        ("governance", ["governance", "proposal", "vote", "timelock", "governorbravo", "snapshot"]),
        ("mev", ["mev", "sandwich", "frontrun", "backrun", "jaredfromsubway", "bundle", "flashbots"]),
        ("access_control", ["access control", "onlyowner", "ownable", "modifier", "roles", "permission"]),
        ("bridge", ["bridge", "cross-chain", "wormhole", "axelar", "layerzero", "multichain", "portal"]),
        ("consensus", ["consensus", "pow", "pos", "51%", "long range", "nothing at stake", "finality"]),
        ("denial_of_service", ["dos", "gas limit", "block stuffing", "exhaust", "revert loop", "infinite loop"]),
        ("wallet", ["wallet", "private key", "mnemonic", "seed phrase", "bip39", "hd wallet"]),
        ("privacy", ["privacy", "tornado", "zk-snark", "mixer", "anonymity", "shielded"]),
    ]
    for attack, keywords in mapping:
        if any(k in code_lower for k in keywords):
            return attack
    return "general"

def load_existing_tools(project_dir):
    """Scan tools/ and scripts/ for existing files to cross-reference."""
    existing = []
    scan_dirs = [
        os.path.join(project_dir, 'tools'),
        os.path.join(project_dir, 'scripts')
    ]
    for base in scan_dirs:
        if not os.path.exists(base):
            continue
        for root, _, files in os.walk(base):
            for f in files:
                if f.endswith(('.py', '.js', '.sol', '.rs', '.go', '.zig', '.cpp', '.c', '.asm', '.sh', '.ts')):
                    path = os.path.join(root, f)
                    try:
                        with open(path, 'r', encoding='utf-8', errors='ignore') as fh:
                            content = fh.read()
                        existing.append({
                            "path": os.path.relpath(path, project_dir),
                            "hash": hashlib.sha256(content.encode()).hexdigest(),
                            "size": len(content)
                        })
                    except:
                        pass
    return existing

def file_ext_to_lang(ext):
    mapping = {"py": "python", "js": "javascript", "ts": "typescript", "sol": "solidity",
               "rs": "rust", "go": "go", "zig": "zig", "cpp": "cpp", "c": "c",
               "asm": "asm", "sh": "bash", "cs": "csharp", "txt": "text", "json": "json"}
    return mapping.get(ext.lower(), ext.lower())

def load_code_blocks(imported_dir):
    """Scan blocks/ directory for individual files and return list of dicts."""
    blocks = []
    blocks_dir = os.path.join(imported_dir, "blocks")
    if not os.path.exists(blocks_dir):
        return blocks
    for f in sorted(os.listdir(blocks_dir)):
        if f.endswith('.json'):
            continue
        path = os.path.join(blocks_dir, f)
        if not os.path.isfile(path):
            continue
        try:
            with open(path, 'r', encoding='utf-8', errors='ignore') as fh:
                code = fh.read()
            h = hashlib.sha256(code.encode()).hexdigest()
            # Parse filename: NNN_ext_attacktype.ext
            m = re.match(r'^(\d{3})_(\w+)_(\w+)\.(\w+)$', f)
            if m:
                _, ext, attack, fext = m.groups()
                lang = file_ext_to_lang(ext)
                atype = attack
            else:
                ext = os.path.splitext(f)[1].lstrip('.')
                lang = file_ext_to_lang(ext)
                atype = classify_attack(code)
            blocks.append({
                "hash": h,
                "language": lang,
                "type": atype,
                "source": "all_codes",
                "file": f"blocks/{f}",
                "lines": code.count('\n') + 1,
                "size": len(code)
            })
        except Exception as e:
            log_warn(f"Failed reading {f}: {e}")
    return blocks

def load_satellite(imported_dir):
    """Scan satellite/ directory."""
    blocks = []
    sat_dir = os.path.join(imported_dir, "satellite")
    if not os.path.exists(sat_dir):
        return blocks
    for f in sorted(os.listdir(sat_dir)):
        if f == "INDEX.json":
            continue
        path = os.path.join(sat_dir, f)
        if not os.path.isfile(path):
            continue
        try:
            with open(path, 'r', encoding='utf-8', errors='ignore') as fh:
                code = fh.read()
            h = hashlib.sha256(code.encode()).hexdigest()
            ext = os.path.splitext(f)[1].lstrip('.')
            blocks.append({
                "hash": h,
                "language": file_ext_to_lang(ext),
                "type": classify_attack(code),
                "source": "satellite",
                "file": f"satellite/{f}",
                "lines": code.count('\n') + 1,
                "size": len(code)
            })
        except Exception as e:
            log_warn(f"Failed reading satellite {f}: {e}")
    return blocks

def load_conversations(imported_dir):
    """Load from conversations MASTER.json."""
    blocks = []
    master_path = os.path.join(imported_dir, "conversations", "MASTER.json")
    if not os.path.exists(master_path):
        return blocks
    with open(master_path, 'r', encoding='utf-8') as f:
        data = json.load(f)
    for b in data.get("blocks", []):
        code = b.get("code", "")
        h = b.get("hash") or hashlib.sha256(code.encode()).hexdigest()
        blocks.append({
            "hash": h,
            "language": file_ext_to_lang(b.get("lang", "txt")),
            "type": classify_attack(code),
            "source": "conversations",
            "file": "conversations/MASTER.json",
            "lines": code.count('\n') + 1,
            "size": len(code)
        })
    return blocks

def similarity(a, b):
    """Simple similarity: common lines ratio."""
    la = set(a.splitlines())
    lb = set(b.splitlines())
    if not la or not lb:
        return 0.0
    inter = len(la & lb)
    return inter / max(len(la), len(lb))

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--project", default="../..", help="Path to BlockChainCore root")
    parser.add_argument("--imported", default="../imported")
    parser.add_argument("--output", default="../imported/MASTER_INDEX.json")
    args = parser.parse_args()

    project_dir = os.path.abspath(args.project)
    imported_dir = os.path.abspath(args.imported)

    log_ok("Loading existing tools/scripts...")
    existing = load_existing_tools(project_dir)
    log_ok(f"Found {len(existing)} existing source files")

    # Pre-load existing contents for fuzzy matching
    existing_contents = {}
    for e in existing:
        if e["path"] not in existing_contents:
            try:
                with open(os.path.join(project_dir, e["path"]), 'r', encoding='utf-8', errors='ignore') as fh:
                    existing_contents[e["path"]] = fh.read()
            except:
                existing_contents[e["path"]] = ""

    all_raw = []
    all_raw.extend(load_code_blocks(imported_dir))
    all_raw.extend(load_satellite(imported_dir))
    all_raw.extend(load_conversations(imported_dir))
    log_ok(f"Loaded {len(all_raw)} raw blocks from all sources")

    seen_hashes = set()
    all_blocks = []
    dup_count = 0

    for b in all_raw:
        h = b["hash"]
        if h in seen_hashes:
            dup_count += 1
            continue
        seen_hashes.add(h)

        # Cross-check
        already_impl = False
        matching = None
        for e in existing:
            if e["hash"] == h:
                already_impl = True
                matching = e["path"]
                break
        # Fuzzy fallback
        if not already_impl:
            code_path = os.path.join(imported_dir, b["file"])
            try:
                if os.path.exists(code_path):
                    with open(code_path, 'r', encoding='utf-8', errors='ignore') as fh:
                        code_content = fh.read()
                else:
                    # For conversation blocks stored inline
                    code_content = ""
            except:
                code_content = ""
            if code_content:
                for e in existing:
                    if similarity(code_content, existing_contents.get(e["path"], "")) > 0.85:
                        already_impl = True
                        matching = e["path"]
                        break

        all_blocks.append({
            "id": len(all_blocks) + 1,
            "hash": h,
            "language": b["language"],
            "type": b["type"],
            "source": b["source"],
            "file": b["file"],
            "already_implemented": already_impl,
            "matching_file": matching,
            "lines": b["lines"],
            "size": b["size"]
        })

    total = len(all_raw)
    unique = len(all_blocks)
    already = sum(1 for b in all_blocks if b["already_implemented"])

    master = {
        "total_extracted": total,
        "unique_blocks": unique,
        "duplicates_removed": dup_count,
        "already_implemented": already,
        "new_blocks": unique - already,
        "by_language": {},
        "by_type": {},
        "blocks": all_blocks
    }
    for b in all_blocks:
        master["by_language"][b["language"]] = master["by_language"].get(b["language"], 0) + 1
        master["by_type"][b["type"]] = master["by_type"].get(b["type"], 0) + 1

    os.makedirs(os.path.dirname(args.output), exist_ok=True)
    with open(args.output, 'w', encoding='utf-8') as f:
        json.dump(master, f, indent=2)
    log_ok(f"MASTER_INDEX.json: {total} raw -> {unique} unique ({dup_count} dupes removed)")
    log_ok(f"  {already} already implemented, {unique - already} new")

if __name__ == "__main__":
    main()
