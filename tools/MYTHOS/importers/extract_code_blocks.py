#!/usr/bin/env python3
"""
Extract code blocks from all_codes_2026-04-19.txt
Parse, deduplicate, classify, save individual files + INDEX.json
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
def log_fail(m): print(f"{RED}[FAIL]{RESET} {m}")

LANG_MAP = {
    "PYTHON": "py", "SOLIDITY": "sol", "RUST": "rs", "GO": "go",
    "ZIG": "zig", "ASM": "asm", "ASSEMBLY": "asm", "JAVASCRIPT": "js",
    "JS": "js", "C": "c", "C++": "cpp", "CPP": "cpp", "CS": "cs",
    "C#": "cs", "TYPESCRIPT": "ts", "BASH": "sh", "SHELL": "sh",
    "HTML": "html", "JSON": "json", "YAML": "yml", "TOML": "toml"
}

ATTACK_KEYWORDS = {
    "reentrancy": ["reentrancy", "reentrant", "recursive call"],
    "flash_loan": ["flash loan", "flashloan", "aave flash"],
    "oracle": ["oracle", "price manipulation", "chainlink"],
    "consensus": ["consensus", "51%", "selfish mining", "fork"],
    "p2p": ["p2p", "peer", "eclipse", "sybil"],
    "bridge": ["bridge", "cross chain", "wormhole", "layerzero"],
    "wallet": ["wallet", "mnemonic", "private key", "bip32", "bip39"],
    "mev": ["mev", "sandwich", "front run", "front-running"],
    "side_channel": ["timing", "side channel", "cache"],
    "governance": ["governance", "vote", "dao", "proposal"],
    "access_control": ["onlyowner", "access control", "tx.origin"],
    "overflow": ["overflow", "underflow", "integer"],
    "delegatecall": ["delegatecall", "proxy"],
    "denial_of_service": ["dos", "gas limit", "unbounded loop"]
}

def classify_attack(code):
    code_lower = code.lower()
    scores = {}
    for attack, keywords in ATTACK_KEYWORDS.items():
        score = sum(1 for k in keywords if k in code_lower)
        if score:
            scores[attack] = score
    if not scores:
        return "general"
    return max(scores, key=scores.get)

def normalize_code(code):
    # Remove 'pythonCopyDownload' artifacts and similar
    code = re.sub(r'^(python|solidity|rust|go|zig|asm|cpp|c#|cs|js|ts)CopyDownload', '', code, flags=re.IGNORECASE)
    code = re.sub(r'^(python|solidity|rust|go|zig|asm|cpp|c#|cs|js|ts)Copy', '', code, flags=re.IGNORECASE)
    return code.strip()

def parse_blocks(filepath):
    with open(filepath, 'r', encoding='utf-8', errors='ignore') as f:
        content = f.read()

    pattern = r'\[BLOCK\s+(\d+)\]\s*-\s*(\w+)\s*\n-{80,}\s*\n(.*?)(?:\n={80,}|\Z)'
    matches = re.findall(pattern, content, re.DOTALL)
    blocks = []
    for num, lang, code in matches:
        code = normalize_code(code)
        if len(code.strip()) < 10:
            continue
        blocks.append({
            "id": int(num),
            "language": lang.upper(),
            "ext": LANG_MAP.get(lang.upper(), "txt"),
            "code": code,
            "attack_type": classify_attack(code),
            "lines": code.count('\n') + 1
        })
    return blocks

def dedup_blocks(blocks):
    seen = {}
    unique = []
    duplicates = []
    for b in blocks:
        h = hashlib.sha256(b["code"].encode()).hexdigest()
        if h in seen:
            duplicates.append({"id": b["id"], "duplicate_of": seen[h]["id"]})
        else:
            seen[h] = b
            b["hash"] = h
            unique.append(b)
    return unique, duplicates

def main():
    parser = argparse.ArgumentParser()
    script_dir = os.path.abspath(os.path.dirname(__file__))
    base = os.path.join(script_dir, '..', '..', '..', '..', 'mythos deepseach', 'all_codes_2026-04-19.txt')
    parser.add_argument("--input", default=os.path.normpath(base))
    parser.add_argument("--output", default="../imported/blocks")
    args = parser.parse_args()

    if not os.path.exists(args.input):
        log_fail(f"Input not found: {args.input}")
        sys.exit(1)

    os.makedirs(args.output, exist_ok=True)
    log_ok(f"Parsing {args.input}")
    blocks = parse_blocks(args.input)
    log_ok(f"Found {len(blocks)} raw blocks")

    unique, dups = dedup_blocks(blocks)
    log_ok(f"Unique: {len(unique)} | Duplicates: {len(dups)}")

    by_lang = {}
    by_attack = {}
    for b in unique:
        by_lang[b["ext"]] = by_lang.get(b["ext"], 0) + 1
        by_attack[b["attack_type"]] = by_attack.get(b["attack_type"], 0) + 1
        fname = f"{b['id']:03d}_{b['ext']}_{b['attack_type']}.{b['ext']}"
        fpath = os.path.join(args.output, fname)
        with open(fpath, 'w', encoding='utf-8') as f:
            f.write(b["code"])

    index = {
        "total_raw": len(blocks),
        "total_unique": len(unique),
        "duplicates_removed": len(dups),
        "by_language": by_lang,
        "by_attack_type": by_attack,
        "duplicates": dups
    }
    idx_path = os.path.join(args.output, "INDEX.json")
    with open(idx_path, 'w', encoding='utf-8') as f:
        json.dump(index, f, indent=2)
    log_ok(f"Saved {len(unique)} files + INDEX.json to {args.output}")

if __name__ == "__main__":
    main()
