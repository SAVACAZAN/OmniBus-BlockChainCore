#!/usr/bin/env python3
"""
blockchain_analyzer.py - OmniBus Blockchain Core Analyzer v2.0

Analizeaza structura si calitatea codului blockchain:
  - Verifica toate cele 52 module Zig din core/
  - Detecteaza probleme de sintaxa Zig (zig ast-check)
  - Clasificare inteligenta: REAL / PARTIAL / STUB / EMPTY
  - Pattern-uri specifice blockchain (crypto, consensus, P2P, wallet)
  - Securitate: private key leaks, allocator misuse, panic paths
  - Scor calitate 0-100 per modul
  - Export JSON / HTML

Usage:
  python tools/blockchain_analyzer.py                    # Full scan
  python tools/blockchain_analyzer.py --module wallet    # Single module
  python tools/blockchain_analyzer.py --json report.json # Export JSON
  python tools/blockchain_analyzer.py --html report.html # Export HTML
  python tools/blockchain_analyzer.py --verbose          # Show all findings
"""

import sys
import os
import re
import json
import argparse
import subprocess
from pathlib import Path
from dataclasses import dataclass, field
from typing import List, Dict, Tuple, Optional, Set
from enum import Enum
from collections import defaultdict

# =============================================================================
# CONFIGURATION
# =============================================================================

ROOT = Path(__file__).parent.parent.parent
CORE = ROOT / "core"
TEST = ROOT / "test"
AGENT = ROOT / "agent"

class ModuleStatus(Enum):
    REAL = "REAL"
    PARTIAL = "PARTIAL"
    STUB = "STUB"
    EMPTY = "EMPTY"
    ERROR = "ERROR"

class Severity(Enum):
    PASS = "PASS"
    WARN = "WARN"
    FAIL = "FAIL"
    INFO = "INFO"

class ModuleCategory(Enum):
    CRYPTO = "CRYPTO"
    CHAIN = "CHAIN"
    NETWORK = "NETWORK"
    STORAGE = "STORAGE"
    WALLET = "WALLET"
    CONSENSUS = "CONSENSUS"
    MINING = "MINING"
    SHARD = "SHARD"
    ECONOMIC = "ECONOMIC"
    UTIL = "UTIL"

@dataclass
class Finding:
    rule_id: str
    severity: Severity
    module: str
    line: int
    message: str
    evidence: str = ""

@dataclass
class ModuleResult:
    name: str
    path: Path
    status: ModuleStatus
    category: ModuleCategory = ModuleCategory.UTIL
    lines: int = 0
    non_empty_lines: int = 0
    functions: int = 0
    pub_functions: int = 0
    exports: int = 0
    tests: int = 0
    imports: List[str] = field(default_factory=list)
    findings: List[Finding] = field(default_factory=list)
    has_init: bool = False
    has_deinit: bool = False
    has_allocator: bool = False
    score: int = 0

# =============================================================================
# MODULE CATEGORY MAP (based on actual project structure)
# =============================================================================

CATEGORY_MAP = {
    # Crypto Layer
    "crypto": ModuleCategory.CRYPTO,
    "secp256k1": ModuleCategory.CRYPTO,
    "ripemd160": ModuleCategory.CRYPTO,
    "pq_crypto": ModuleCategory.CRYPTO,
    "key_encryption": ModuleCategory.CRYPTO,
    "bip32_wallet": ModuleCategory.CRYPTO,
    # Chain Layer
    "block": ModuleCategory.CHAIN,
    "blockchain": ModuleCategory.CHAIN,
    "blockchain_v2": ModuleCategory.CHAIN,
    "transaction": ModuleCategory.CHAIN,
    "genesis": ModuleCategory.CHAIN,
    "mempool": ModuleCategory.CHAIN,
    "compact_transaction": ModuleCategory.CHAIN,
    # Consensus
    "consensus": ModuleCategory.CONSENSUS,
    "e2e_mining": ModuleCategory.CONSENSUS,
    "miner_genesis": ModuleCategory.CONSENSUS,
    # Network
    "p2p": ModuleCategory.NETWORK,
    "sync": ModuleCategory.NETWORK,
    "network": ModuleCategory.NETWORK,
    "bootstrap": ModuleCategory.NETWORK,
    "rpc_server": ModuleCategory.NETWORK,
    "ws_server": ModuleCategory.NETWORK,
    "node_launcher": ModuleCategory.NETWORK,
    "cli": ModuleCategory.NETWORK,
    # Storage
    "database": ModuleCategory.STORAGE,
    "storage": ModuleCategory.STORAGE,
    "binary_codec": ModuleCategory.STORAGE,
    "archive_manager": ModuleCategory.STORAGE,
    "prune_config": ModuleCategory.STORAGE,
    "state_trie": ModuleCategory.STORAGE,
    "witness_data": ModuleCategory.STORAGE,
    # Wallet
    "wallet": ModuleCategory.WALLET,
    "vault_engine": ModuleCategory.WALLET,
    "vault_reader": ModuleCategory.WALLET,
    # Mining
    "mining_pool": ModuleCategory.MINING,
    "light_miner": ModuleCategory.MINING,
    "light_client": ModuleCategory.MINING,
    "main": ModuleCategory.MINING,
    # Shard
    "sub_block": ModuleCategory.SHARD,
    "shard_config": ModuleCategory.SHARD,
    "shard_coordinator": ModuleCategory.SHARD,
    "metachain": ModuleCategory.SHARD,
    # Economic
    "bread_ledger": ModuleCategory.ECONOMIC,
    "domain_minter": ModuleCategory.ECONOMIC,
    "spark_invariants": ModuleCategory.ECONOMIC,
    "ubi_distributor": ModuleCategory.ECONOMIC,
    "payment_channel": ModuleCategory.ECONOMIC,
    "bridge_relay": ModuleCategory.ECONOMIC,
    "oracle": ModuleCategory.ECONOMIC,
    "omni_brain": ModuleCategory.ECONOMIC,
    "synapse_priority": ModuleCategory.ECONOMIC,
    "os_mode": ModuleCategory.UTIL,
    # New modules
    "schnorr": ModuleCategory.CRYPTO,
    "multisig": ModuleCategory.CRYPTO,
    "governance": ModuleCategory.CONSENSUS,
    "finality": ModuleCategory.CONSENSUS,
}

# =============================================================================
# BLOCKCHAIN-SPECIFIC PATTERNS
# =============================================================================

# Indicators that code is REAL blockchain implementation
BLOCKCHAIN_REAL_INDICATORS = [
    re.compile(r'pub\s+fn\s+\w+'),                    # Public functions
    re.compile(r'const\s+\w+\s*=\s*struct'),          # Struct definitions
    re.compile(r'test\s+"'),                           # Test blocks
    re.compile(r'@import\s*\('),                       # Imports
    re.compile(r'pub\s+const'),                        # Public constants
    # Blockchain-specific
    re.compile(r'sha256|SHA256|Sha256'),               # Hash functions
    re.compile(r'secp256k1|ecdsa|ECDSA'),              # Signing
    re.compile(r'bip32|bip39|BIP32|BIP39'),            # HD wallet
    re.compile(r'merkle|MerkleRoot|merkle_root'),      # Merkle trees
    re.compile(r'genesis|Genesis'),                    # Genesis block
    re.compile(r'mempool|Mempool'),                    # Transaction pool
    re.compile(r'consensus|Consensus'),                # Consensus
    re.compile(r'mining|mineBlock|mine_block|nonce'),  # Mining
    re.compile(r'difficulty|retarget'),                # Difficulty adjustment
    re.compile(r'transaction|Transaction'),            # TX handling
    re.compile(r'block\.hash|previous_hash|prev_hash'),# Block linking
    re.compile(r'validate|verify|Verify'),             # Validation
    re.compile(r'sign|signature|Signature'),           # Signing
    re.compile(r'allocator'),                          # Memory management
    re.compile(r'deinit|defer\s'),                     # Cleanup
]

# Patterns that indicate STUB/placeholder
STUB_PATTERNS = [
    re.compile(r'\btodo\b|\bTODO\b', re.I),
    re.compile(r'\bstub\b|\bSTUB\b', re.I),
    re.compile(r'not\s+implemented', re.I),
    re.compile(r'placeholder', re.I),
    re.compile(r'@panic\s*\(\s*"not implemented"\s*\)'),
    re.compile(r'@panic\s*\(\s*"TODO"\s*\)'),
    re.compile(r'return\s+error\.NotImplemented'),
    re.compile(r'unreachable;\s*//.*todo', re.I),
]

# Security patterns specific to blockchain
SECURITY_PATTERNS = [
    # CRITICAL - Private key handling
    (re.compile(r'private_key.*=\s*"[0-9a-fA-F]+"'), "FAIL", "SEC-KEY-01", "Hardcoded private key detected"),
    (re.compile(r'@memset\s*\(\s*&\s*self\.private'), "PASS", "SEC-KEY-02", "Private key zeroed on cleanup (good)"),
    (re.compile(r'private_key'), "INFO", "SEC-KEY-03", "Private key handling present"),

    # Memory safety
    (re.compile(r'@panic\s*\('), "WARN", "SEC-MEM-01", "Panic call - may crash node"),
    (re.compile(r'unreachable'), "WARN", "SEC-MEM-02", "Unreachable - undefined behavior if reached"),
    (re.compile(r'@intCast'), "INFO", "SEC-MEM-03", "Integer cast - check for overflow"),
    (re.compile(r'@ptrCast'), "WARN", "SEC-MEM-04", "Pointer cast - verify safety"),
    (re.compile(r'while\s*\(\s*true\s*\)'), "WARN", "SEC-MEM-05", "Infinite loop potential"),

    # Allocator discipline
    (re.compile(r'GeneralPurposeAllocator'), "INFO", "SEC-ALLOC-01", "GPA allocator used"),
    (re.compile(r'ArenaAllocator'), "INFO", "SEC-ALLOC-02", "Arena allocator used"),
    (re.compile(r'allocator\.alloc\('), "INFO", "SEC-ALLOC-03", "Manual allocation"),
    (re.compile(r'defer\s+.*\.deinit\(\)'), "PASS", "SEC-ALLOC-04", "Defer deinit pattern (good)"),

    # Crypto correctness
    (re.compile(r'pub\s+fn\s+verify'), "PASS", "SEC-CRYPTO-01", "Verification function present"),
    (re.compile(r'pub\s+fn\s+sign'), "PASS", "SEC-CRYPTO-02", "Signing function present"),
    (re.compile(r'HMAC|hmac'), "PASS", "SEC-CRYPTO-03", "HMAC authentication present"),
    (re.compile(r'AES|aes.*256|Aes256'), "PASS", "SEC-CRYPTO-04", "AES encryption present"),

    # Consensus safety
    (re.compile(r'validateBlock|validate_block'), "PASS", "SEC-CONS-01", "Block validation present"),
    (re.compile(r'double.*spend|replay.*attack', re.I), "INFO", "SEC-CONS-02", "Anti-replay/double-spend referenced"),

    # Network
    (re.compile(r'timeout|TIMEOUT'), "PASS", "SEC-NET-01", "Timeout handling present"),
    (re.compile(r'0\.0\.0\.0'), "WARN", "SEC-NET-02", "Binding to all interfaces"),
]

# =============================================================================
# ANALYSIS FUNCTIONS
# =============================================================================

def check_syntax(path: Path) -> Tuple[Optional[bool], str]:
    """Check Zig syntax using zig ast-check."""
    try:
        result = subprocess.run(
            ["zig", "ast-check", str(path)],
            capture_output=True, text=True, timeout=15
        )
        return result.returncode == 0, result.stderr[:300] if result.stderr else ""
    except FileNotFoundError:
        return None, "zig not found in PATH"
    except subprocess.TimeoutExpired:
        return None, "ast-check timeout"
    except Exception as e:
        return None, str(e)[:100]


def extract_imports(code: str) -> List[str]:
    """Extract @import statements."""
    imports = []
    for m in re.finditer(r'@import\s*\(\s*"([^"]+)"\s*\)', code):
        imp = m.group(1)
        if imp != "std" and imp != "builtin":
            imports.append(imp.replace(".zig", ""))
    return imports


def count_tests(code: str) -> int:
    """Count test blocks."""
    return len(re.findall(r'test\s+"[^"]*"', code))


def analyze_module(module_path: Path, verbose: bool = False) -> ModuleResult:
    """Analyze a single Zig module with blockchain-specific checks."""
    name = module_path.stem

    try:
        code = module_path.read_text(encoding='utf-8', errors='replace')
    except Exception as e:
        return ModuleResult(
            name=name, path=module_path, status=ModuleStatus.ERROR,
            findings=[Finding("READ", Severity.FAIL, name, 0, f"Cannot read: {e}")]
        )

    lines = code.count('\n')
    non_empty = sum(1 for l in code.splitlines() if l.strip() and not l.strip().startswith('//'))

    # Count functions
    all_fns = re.findall(r'(?:pub\s+)?(?:export\s+)?fn\s+\w+', code)
    pub_fns = re.findall(r'pub\s+(?:export\s+)?fn\s+\w+', code)
    exports = re.findall(r'(?:pub\s+)?export\s+fn\s+\w+', code)

    # Extract imports and tests
    imports = extract_imports(code)
    tests = count_tests(code)

    # Check key patterns
    has_init = bool(re.search(r'(?:pub\s+)?fn\s+init(?:With\w+)?\s*\(', code))
    has_deinit = bool(re.search(r'(?:pub\s+)?fn\s+deinit\s*\(', code))
    has_allocator = bool(re.search(r'allocator|Allocator', code))

    # Stub detection
    stub_hits = [p.pattern for p in STUB_PATTERNS if p.search(code)]

    # Real indicator counting
    real_hits = sum(1 for p in BLOCKCHAIN_REAL_INDICATORS if p.search(code))

    # Determine status
    is_crypto_module = CATEGORY_MAP.get(name) in (ModuleCategory.CRYPTO, ModuleCategory.CONSENSUS)
    if non_empty < 10:
        status = ModuleStatus.EMPTY
    elif stub_hits and real_hits < 4:
        status = ModuleStatus.STUB
    elif stub_hits and real_hits >= 4:
        status = ModuleStatus.PARTIAL
    elif real_hits >= 5 and len(pub_fns) > 0:
        status = ModuleStatus.REAL
    elif is_crypto_module and len(pub_fns) >= 3 and tests > 0:
        # Crypto/stateless modules don't need init/deinit to be REAL
        status = ModuleStatus.REAL
    elif real_hits >= 4 and tests > 3:
        status = ModuleStatus.REAL
    elif real_hits >= 4:
        status = ModuleStatus.PARTIAL
    else:
        status = ModuleStatus.PARTIAL

    # Category
    category = CATEGORY_MAP.get(name, ModuleCategory.UTIL)

    # Security findings
    findings = []
    for pattern, sev, rule_id, msg in SECURITY_PATTERNS:
        for match in pattern.finditer(code):
            line_num = code[:match.start()].count('\n') + 1
            findings.append(Finding(
                rule_id=rule_id, severity=Severity(sev),
                module=name, line=line_num, message=msg,
                evidence=match.group(0)[:60]
            ))

    # Syntax check
    if module_path.suffix == '.zig':
        syntax_ok, syntax_err = check_syntax(module_path)
        if syntax_ok is False:
            findings.append(Finding(
                rule_id="SYNTAX", severity=Severity.FAIL,
                module=name, line=0,
                message=f"Syntax error: {syntax_err[:100]}",
            ))
        elif syntax_ok is True:
            findings.append(Finding(
                rule_id="SYNTAX", severity=Severity.PASS,
                module=name, line=0, message="Syntax OK"
            ))

    # Check init/deinit pairs for modules with allocators
    if has_allocator and has_init and not has_deinit:
        findings.append(Finding(
            rule_id="SEC-ALLOC-05", severity=Severity.WARN,
            module=name, line=0,
            message="Has init() + allocator but no deinit() - potential memory leak"
        ))

    # Check test coverage
    if tests == 0 and status in (ModuleStatus.REAL, ModuleStatus.PARTIAL):
        findings.append(Finding(
            rule_id="TEST-01", severity=Severity.WARN,
            module=name, line=0,
            message="No inline tests found in module"
        ))

    # Calculate score (0-100)
    score = 0
    if status == ModuleStatus.REAL: score += 40
    elif status == ModuleStatus.PARTIAL: score += 20
    elif status == ModuleStatus.STUB: score += 5

    if len(all_fns) > 3: score += 5
    if len(all_fns) > 10: score += 5
    if len(pub_fns) > 0: score += 5
    if len(exports) > 0: score += 5
    if non_empty > 50: score += 5
    if non_empty > 200: score += 5
    if tests > 0: score += 10
    if tests > 3: score += 5
    if has_init: score += 5
    if has_deinit: score += 5
    if has_allocator and has_deinit: score += 5

    # Penalty for failures
    fail_count = sum(1 for f in findings if f.severity == Severity.FAIL)
    score -= fail_count * 10

    return ModuleResult(
        name=name, path=module_path, status=status, category=category,
        lines=lines, non_empty_lines=non_empty,
        functions=len(all_fns), pub_functions=len(pub_fns),
        exports=len(exports), tests=tests,
        imports=imports, findings=findings,
        has_init=has_init, has_deinit=has_deinit,
        has_allocator=has_allocator,
        score=max(0, min(100, score))
    )


def scan_all_modules() -> List[ModuleResult]:
    """Scan core/, test/, agent/ directories."""
    results = []

    dirs = [(CORE, "core"), (TEST, "test"), (AGENT, "agent")]
    for d, label in dirs:
        if not d.exists():
            continue
        zig_files = sorted(d.glob("*.zig"))
        print(f"  Scanning {len(zig_files)} Zig files in {label}/...")
        for fpath in zig_files:
            result = analyze_module(fpath)
            results.append(result)

    return results


# =============================================================================
# REPORTS
# =============================================================================

G = "\033[92m"; Y = "\033[93m"; R = "\033[91m"; B = "\033[94m"; C = "\033[96m"; W = "\033[0m"; BOLD = "\033[1m"

STATUS_COLORS = {
    ModuleStatus.REAL: G,
    ModuleStatus.PARTIAL: Y,
    ModuleStatus.STUB: Y,
    ModuleStatus.EMPTY: R,
    ModuleStatus.ERROR: R,
}

def print_report(results: List[ModuleResult], verbose: bool = False):
    SEP = "=" * 90

    print(f"\n{SEP}")
    print(f"  {BOLD}OmniBus Blockchain Core - Module Analysis v2.0{W}")
    print(f"  Scanned: {len(results)} modules")
    print(f"{SEP}\n")

    # Group by category
    by_category = defaultdict(list)
    for r in results:
        by_category[r.category].append(r)

    cat_order = [
        ModuleCategory.CRYPTO, ModuleCategory.CHAIN, ModuleCategory.CONSENSUS,
        ModuleCategory.NETWORK, ModuleCategory.STORAGE, ModuleCategory.WALLET,
        ModuleCategory.MINING, ModuleCategory.SHARD, ModuleCategory.ECONOMIC,
        ModuleCategory.UTIL
    ]

    for cat in cat_order:
        mods = by_category.get(cat, [])
        if not mods:
            continue

        print(f"\n  {BOLD}{C}[{cat.value}]{W}")
        print(f"  {'Module':<30} {'Status':<10} {'Lines':>6} {'Funcs':>6} {'Tests':>6} {'Score':>6}")
        print(f"  {'-' * 76}")

        for r in sorted(mods, key=lambda x: -x.score):
            col = STATUS_COLORS.get(r.status, "")
            init_mark = "I" if r.has_init else "."
            deinit_mark = "D" if r.has_deinit else "."
            alloc_mark = "A" if r.has_allocator else "."
            marks = f"[{init_mark}{deinit_mark}{alloc_mark}]"

            print(f"  {r.name:<25} {marks} {col}{r.status.value:<10}{W} "
                  f"{r.non_empty_lines:>6} {r.functions:>6} {r.tests:>6} {r.score:>5}%")

    # Summary
    counts = defaultdict(int)
    total_lines = 0
    total_tests = 0
    total_fns = 0
    for r in results:
        counts[r.status.value] += 1
        total_lines += r.non_empty_lines
        total_tests += r.tests
        total_fns += r.functions

    print(f"\n{SEP}")
    print(f"  {BOLD}SUMMARY{W}")
    print(f"{SEP}")
    print(f"  {G}REAL:     {counts.get('REAL', 0):>3}{W} modules")
    print(f"  {Y}PARTIAL:  {counts.get('PARTIAL', 0):>3}{W} modules")
    print(f"  {Y}STUB:     {counts.get('STUB', 0):>3}{W} modules")
    print(f"  {R}EMPTY:    {counts.get('EMPTY', 0):>3}{W} modules")
    print(f"  {R}ERROR:    {counts.get('ERROR', 0):>3}{W} modules")
    print(f"  {'':3s}Total:   {len(results):>3} modules | {total_lines:,} LOC | {total_fns} functions | {total_tests} tests")

    # Average score
    avg = sum(r.score for r in results) / len(results) if results else 0
    print(f"\n  Average Quality Score: {BOLD}{avg:.1f}%{W}")

    # Findings summary
    all_findings = [f for r in results for f in r.findings]
    fails = [f for f in all_findings if f.severity == Severity.FAIL]
    warns = [f for f in all_findings if f.severity == Severity.WARN]

    if fails:
        print(f"\n  {R}FAILURES ({len(fails)}):{W}")
        for f in fails[:15]:
            print(f"    [{f.rule_id}] {f.module}:{f.line} - {f.message}")

    if warns and verbose:
        print(f"\n  {Y}WARNINGS ({len(warns)}):{W}")
        for f in warns[:20]:
            print(f"    [{f.rule_id}] {f.module}:{f.line} - {f.message}")
    elif warns:
        print(f"\n  {Y}WARNINGS: {len(warns)} (use --verbose to see){W}")

    # Modules without tests
    no_tests = [r for r in results if r.tests == 0 and r.status == ModuleStatus.REAL]
    if no_tests:
        print(f"\n  {Y}REAL modules without tests:{W}")
        for r in no_tests:
            print(f"    - {r.name}")

    print(f"\n{SEP}\n")


def generate_json(results: List[ModuleResult], path: Path):
    data = {
        "tool": "blockchain_analyzer",
        "version": "2.0",
        "modules": [
            {
                "name": r.name,
                "path": str(r.path),
                "category": r.category.value,
                "status": r.status.value,
                "lines": r.lines,
                "non_empty_lines": r.non_empty_lines,
                "functions": r.functions,
                "pub_functions": r.pub_functions,
                "exports": r.exports,
                "tests": r.tests,
                "imports": r.imports,
                "has_init": r.has_init,
                "has_deinit": r.has_deinit,
                "has_allocator": r.has_allocator,
                "score": r.score,
                "findings": [
                    {"rule": f.rule_id, "severity": f.severity.value,
                     "line": f.line, "message": f.message, "evidence": f.evidence}
                    for f in r.findings
                ]
            }
            for r in results
        ],
        "summary": {
            "total": len(results),
            "real": sum(1 for r in results if r.status == ModuleStatus.REAL),
            "partial": sum(1 for r in results if r.status == ModuleStatus.PARTIAL),
            "stub": sum(1 for r in results if r.status == ModuleStatus.STUB),
            "empty": sum(1 for r in results if r.status == ModuleStatus.EMPTY),
            "avg_score": sum(r.score for r in results) / len(results) if results else 0,
        }
    }
    with open(path, 'w', encoding='utf-8') as f:
        json.dump(data, f, indent=2)
    print(f"  JSON report: {path}")


def generate_html(results: List[ModuleResult], path: Path):
    by_cat = defaultdict(list)
    for r in results:
        by_cat[r.category.value].append(r)

    rows = ""
    for r in sorted(results, key=lambda x: (x.category.value, -x.score)):
        color = {"REAL": "#b2f2bb", "PARTIAL": "#fff3bf", "STUB": "#ffe8cc",
                 "EMPTY": "#ffc9c9", "ERROR": "#ffc9c9"}.get(r.status.value, "#f0f0f0")
        fails = sum(1 for f in r.findings if f.severity == Severity.FAIL)
        warns = sum(1 for f in r.findings if f.severity == Severity.WARN)
        rows += f"""
        <tr style="background: {color}20">
            <td><b>{r.name}</b></td>
            <td><span class="cat">{r.category.value}</span></td>
            <td style="background: {color}">{r.status.value}</td>
            <td>{r.non_empty_lines}</td>
            <td>{r.functions}</td>
            <td>{r.tests}</td>
            <td>{'I' if r.has_init else '-'}{'D' if r.has_deinit else '-'}{'A' if r.has_allocator else '-'}</td>
            <td>{fails}F/{warns}W</td>
            <td><b>{r.score}%</b></td>
        </tr>"""

    avg = sum(r.score for r in results) / len(results) if results else 0
    total_real = sum(1 for r in results if r.status == ModuleStatus.REAL)

    html = f"""<!DOCTYPE html>
<html><head>
<meta charset="utf-8">
<title>OmniBus Blockchain Analysis v2.0</title>
<style>
body {{ font-family: 'Consolas', monospace; background: #0d1117; color: #c9d1d9; padding: 20px; }}
h1 {{ color: #58a6ff; margin-bottom: 5px; }}
h2 {{ color: #8b949e; font-weight: normal; }}
table {{ border-collapse: collapse; width: 100%; font-size: 13px; }}
th {{ background: #161b22; color: #58a6ff; padding: 10px; text-align: left; position: sticky; top: 0; }}
td {{ padding: 8px 10px; border-bottom: 1px solid #21262d; }}
tr:hover td {{ background: rgba(88,166,255,0.05); }}
.cat {{ background: #1f2937; padding: 2px 6px; border-radius: 3px; font-size: 11px; }}
.stats {{ display: flex; gap: 20px; margin: 15px 0; }}
.stat {{ background: #161b22; padding: 15px; border-radius: 8px; text-align: center; }}
.stat-val {{ font-size: 28px; font-weight: bold; color: #58a6ff; }}
.stat-label {{ color: #8b949e; font-size: 12px; }}
</style>
</head><body>
<h1>OmniBus Blockchain Core Analysis</h1>
<h2>{len(results)} modules scanned | Average Score: {avg:.1f}%</h2>
<div class="stats">
  <div class="stat"><div class="stat-val">{total_real}</div><div class="stat-label">REAL</div></div>
  <div class="stat"><div class="stat-val">{sum(r.non_empty_lines for r in results):,}</div><div class="stat-label">Lines of Code</div></div>
  <div class="stat"><div class="stat-val">{sum(r.functions for r in results)}</div><div class="stat-label">Functions</div></div>
  <div class="stat"><div class="stat-val">{sum(r.tests for r in results)}</div><div class="stat-label">Tests</div></div>
</div>
<table>
<thead><tr>
  <th>Module</th><th>Category</th><th>Status</th><th>LOC</th><th>Funcs</th><th>Tests</th><th>IDA</th><th>Findings</th><th>Score</th>
</tr></thead>
<tbody>{rows}</tbody>
</table>
</body></html>"""

    with open(path, 'w', encoding='utf-8') as f:
        f.write(html)
    print(f"  HTML report: {path}")


# =============================================================================
# MAIN
# =============================================================================

def main():
    parser = argparse.ArgumentParser(description="OmniBus Blockchain Core Analyzer v2.0")
    parser.add_argument("--module", help="Analyze specific module")
    parser.add_argument("--json", metavar="FILE", help="Export JSON report")
    parser.add_argument("--html", metavar="FILE", help="Export HTML report")
    parser.add_argument("--verbose", "-v", action="store_true", help="Show all findings")
    args = parser.parse_args()

    print(f"\n{'=' * 60}")
    print(f"  {BOLD}OmniBus Blockchain Core Analyzer v2.0{W}")
    print(f"{'=' * 60}")

    if args.module:
        module_path = CORE / f"{args.module}.zig"
        if not module_path.exists():
            print(f"  ERROR: Module not found: {module_path}")
            sys.exit(1)
        results = [analyze_module(module_path, args.verbose)]
    else:
        results = scan_all_modules()

    print_report(results, verbose=args.verbose)

    if args.json:
        generate_json(results, Path(args.json))
    if args.html:
        generate_html(results, Path(args.html))

    has_errors = any(r.status == ModuleStatus.ERROR for r in results)
    sys.exit(1 if has_errors else 0)

if __name__ == "__main__":
    main()
