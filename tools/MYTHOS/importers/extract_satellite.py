#!/usr/bin/env python3
"""
Extract code blocks from savacazan.satellite (31K lines, mixed text + real code)
Detects code blocks by language-specific start patterns.
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

START_PATTERNS = {
    "cpp": [r'^#include\s+<', r'^using\s+namespace', r'^int\s+main\s*\(', r'^class\s+\w', r'^struct\s+\w', r'^void\s+\w', r'^template\s*<', r'^#define\s+', r'^#pragma\s+'],
    "py":  [r'^def\s+\w+\s*\(', r'^class\s+\w+', r'^import\s+\w', r'^from\s+\w+\s+import', r'^#!/usr/bin/env\s+python'],
    "go":  [r'^package\s+\w', r'^func\s+\w', r'^import\s+\(', r'^import\s+"'],
    "rs":  [r'^fn\s+\w', r'^use\s+\w', r'^mod\s+\w', r'^struct\s+\w', r'^impl\s+', r'^pub\s+'],
    "asm": [r'^section\s+\.', r'^global\s+\w', r'^BITS\s+\d', r'^push\s+', r'^mov\s+', r'^jmp\s+', r'^call\s+', r'^%define\s+', r'^;\s*\[', r'^\[BITS\s+'],
    "cs":  [r'^using\s+System', r'^namespace\s+\w', r'^class\s+\w', r'^static\s+void\s+Main', r'^public\s+class'],
    "js":  [r'^const\s+\w+\s*=', r'^function\s+\w', r'^class\s+\w', r'^import\s+\{', r'^export\s+'],
    "sol": [r'^pragma\s+solidity', r'^contract\s+\w', r'^interface\s+\w', r'^library\s+\w', r'^//\s*SPDX'],
    "zig": [r'^const\s+\w+\s*=', r'^pub\s+fn\s+', r'^fn\s+\w', r'^test\s+\{'],
    "sh":  [r'^#!/bin/bash', r'^#!/bin/sh', r'^echo\s+', r'^function\s+\w'],
}

LANG_NAMES = {"cpp": "C++", "py": "Python", "go": "Go", "rs": "Rust", "asm": "ASM", "cs": "C#", "js": "JavaScript", "sol": "Solidity", "zig": "Zig", "sh": "Shell"}

def detect_language(lines):
    scores = {lang: 0 for lang in START_PATTERNS}
    for line in lines[:50]:
        for lang, patterns in START_PATTERNS.items():
            for pat in patterns:
                if re.search(pat, line):
                    scores[lang] += 1
    if not any(scores.values()):
        return None
    return max(scores, key=scores.get)

def is_code_line(line):
    stripped = line.strip()
    if not stripped:
        return False
    # Skip obvious text lines
    text_markers = [' lectur', ' citit', ' raspuns', ' acest', ' conversa', ' text', '====', '----', '  ', 'Vrei ', 'Spune-mi ', 'Poti ', 'Aici ', 'Explic']
    for m in text_markers:
        if m in stripped[:60]:
            return False
    code_markers = ['def ', 'class ', 'import ', 'from ', '#include', 'using ', 'int ', 'void ', 'fn ', 'pub ', 'const ', 'package ', 'func ', 'pragma ', 'contract ', 'struct ', 'mov ', 'push ', 'jmp ', 'echo ', '#!/']
    for m in code_markers:
        if stripped.startswith(m):
            return True
    if re.match(r'^\s*(//|#|/\*|\*|\[|\{|\}|\))', stripped):
        return True
    if re.match(r'^\s*[a-zA-Z_][a-zA-Z0-9_]*\s*[=\(]', stripped):
        return True
    return False

def extract_blocks(filepath):
    with open(filepath, 'r', encoding='utf-8', errors='ignore') as f:
        lines = f.readlines()

    blocks = []
    i = 0
    total = len(lines)
    while i < total:
        # Find code start
        if not is_code_line(lines[i]):
            i += 1
            continue
        block_lines = []
        while i < total and (is_code_line(lines[i]) or lines[i].strip() == ''):
            block_lines.append(lines[i].rstrip('\n'))
            i += 1
        # Require minimum size
        code_text = '\n'.join(block_lines).strip()
        if len(code_text) < 80 or code_text.count('\n') < 3:
            continue
        lang = detect_language(block_lines)
        if not lang:
            continue
        blocks.append({
            "language": lang,
            "code": code_text,
            "lines": len(block_lines),
            "hash": hashlib.sha256(code_text.encode()).hexdigest()[:16]
        })
    return blocks

def main():
    parser = argparse.ArgumentParser()
    script_dir = os.path.abspath(os.path.dirname(__file__))
    base = os.path.join(script_dir, '..', '..', '..', '..', 'mythos deepseach', 'savacazan.satellite')
    parser.add_argument("--input", default=os.path.normpath(base))
    parser.add_argument("--output", default="../imported/satellite")
    args = parser.parse_args()

    if not os.path.exists(args.input):
        log_fail(f"Input not found: {args.input}")
        sys.exit(1)

    os.makedirs(args.output, exist_ok=True)
    log_ok(f"Parsing {args.input}")
    blocks = extract_blocks(args.input)
    log_ok(f"Extracted {len(blocks)} code blocks")

    by_lang = {}
    for idx, b in enumerate(blocks, 1):
        by_lang[b["language"]] = by_lang.get(b["language"], 0) + 1
        ext = b["language"]
        fname = f"{idx:04d}_{ext}_{b['hash']}.{ext}"
        fpath = os.path.join(args.output, fname)
        with open(fpath, 'w', encoding='utf-8') as f:
            f.write(b["code"])

    index = {
        "total": len(blocks),
        "by_language": {LANG_NAMES.get(k,k): v for k,v in by_lang.items()},
        "blocks": [{k:v for k,v in b.items() if k != 'code'} for b in blocks]
    }
    idx_path = os.path.join(args.output, "INDEX.json")
    with open(idx_path, 'w', encoding='utf-8') as f:
        json.dump(index, f, indent=2)
    log_ok(f"Saved {len(blocks)} files + INDEX.json to {args.output}")

if __name__ == "__main__":
    main()
