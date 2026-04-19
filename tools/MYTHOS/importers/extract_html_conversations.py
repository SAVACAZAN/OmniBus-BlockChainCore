#!/usr/bin/env python3
"""
Extract code blocks from DeepSeek HTML conversation files.
Uses stdlib html.parser only.
"""
import argparse
import hashlib
import json
import os
import re
import sys
from html.parser import HTMLParser

GREEN = "\033[92m"
RED = "\033[91m"
YELLOW = "\033[93m"
RESET = "\033[0m"

def log_ok(m): print(f"{GREEN}[OK]{RESET} {m}")
def log_warn(m): print(f"{YELLOW}[WARN]{RESET} {m}")
def log_fail(m): print(f"{RED}[FAIL]{RESET} {m}")

class CodeExtractor(HTMLParser):
    def __init__(self):
        super().__init__()
        self.in_code = False
        self.code_lang = None
        self.current = []
        self.blocks = []
        self.text_buffer = []

    def handle_starttag(self, tag, attrs):
        attrs_dict = dict(attrs)
        if tag in ('pre', 'code'):
            self.in_code = True
            self.code_lang = attrs_dict.get('class', '').replace('language-', '')
            self.current = []
        self.text_buffer = []

    def handle_endtag(self, tag):
        if tag in ('pre', 'code') and self.in_code:
            self.in_code = False
            code = ''.join(self.current).strip()
            if len(code) > 20:
                self.blocks.append({"lang": self.code_lang or "txt", "code": code})
            self.current = []
            self.code_lang = None

    def handle_data(self, data):
        if self.in_code:
            self.current.append(data)
        else:
            self.text_buffer.append(data)

def extract_from_html(filepath):
    with open(filepath, 'r', encoding='utf-8', errors='ignore') as f:
        html = f.read()
    parser = CodeExtractor()
    parser.feed(html)
    return parser.blocks

def dedup_blocks(blocks):
    seen = set()
    unique = []
    for b in blocks:
        h = hashlib.sha256(b["code"].encode()).hexdigest()
        if h not in seen:
            seen.add(h)
            b["hash"] = h
            unique.append(b)
    return unique

def main():
    parser = argparse.ArgumentParser()
    script_dir = os.path.abspath(os.path.dirname(__file__))
    base = os.path.join(script_dir, '..', '..', '..', '..', 'mythos deepseach')
    parser.add_argument("--input-dir", default=os.path.normpath(base))
    parser.add_argument("--output", default="../imported/conversations")
    args = parser.parse_args()

    os.makedirs(args.output, exist_ok=True)
    all_blocks = []

    for fname in os.listdir(args.input_dir):
        if fname.startswith('deepseek_html_') and fname.endswith('.html'):
            path = os.path.join(args.input_dir, fname)
            log_ok(f"Parsing {fname}")
            blocks = extract_from_html(path)
            unique = dedup_blocks(blocks)
            log_ok(f"  Found {len(blocks)} code blocks, {len(unique)} unique")
            all_blocks.extend(unique)
            out_json = os.path.join(args.output, fname.replace('.html', '.json'))
            with open(out_json, 'w', encoding='utf-8') as f:
                json.dump(unique, f, indent=2)

    # Master dedup across all files
    master = dedup_blocks(all_blocks)
    with open(os.path.join(args.output, "MASTER.json"), 'w', encoding='utf-8') as f:
        json.dump({"total_unique": len(master), "blocks": master}, f, indent=2)
    log_ok(f"Total unique blocks across all HTMLs: {len(master)}")

if __name__ == "__main__":
    main()
