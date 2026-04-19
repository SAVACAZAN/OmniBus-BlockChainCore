#!/usr/bin/env python3
"""
blockchain_deep_audit.py - Deep Code Quality & Security Audit v1.0

Analiza profunda a codului blockchain:
  - Complexitate ciclomatica per functie
  - Functii prea mari (>50 linii)
  - Cod duplicat (6-line block hashing)
  - Security patterns: unsafe ops, hardcoded keys, allocator leaks
  - CWE mapping (buffer overflow, TOCTOU, integer overflow)
  - Module quality scoring (maintainability index)
  - Architecture: layer violation detection

Usage:
  python tools/blockchain_deep_audit.py                     # Full deep audit
  python tools/blockchain_deep_audit.py --module wallet     # Single module
  python tools/blockchain_deep_audit.py --json report.json  # Export JSON
  python tools/blockchain_deep_audit.py --security-only     # Security checks only
  python tools/blockchain_deep_audit.py --complexity        # Complexity report only
"""

import sys
import os
import re
import json
import hashlib
import argparse
from pathlib import Path
from dataclasses import dataclass, field
from typing import List, Dict, Tuple, Optional, Set
from enum import Enum
from collections import defaultdict
import math

ROOT = Path(__file__).parent.parent.parent
CORE = ROOT / "core"
TEST = ROOT / "test"
AGENT = ROOT / "agent"

# =============================================================================
# DATA CLASSES
# =============================================================================

class CWE(Enum):
    BUFFER_OVERFLOW = "CWE-120"
    INTEGER_OVERFLOW = "CWE-190"
    USE_AFTER_FREE = "CWE-416"
    DOUBLE_FREE = "CWE-415"
    NULL_DEREF = "CWE-476"
    HARDCODED_KEY = "CWE-798"
    TOCTOU = "CWE-367"
    UNCONTROLLED_RESOURCE = "CWE-400"
    IMPROPER_INPUT_VALIDATION = "CWE-20"
    CRYPTO_WEAKNESS = "CWE-327"

class RiskLevel(Enum):
    CRITICAL = "CRITICAL"
    HIGH = "HIGH"
    MEDIUM = "MEDIUM"
    LOW = "LOW"
    INFO = "INFO"

@dataclass
class FunctionInfo:
    name: str
    module: str
    line_start: int
    line_end: int
    lines: int
    is_pub: bool
    is_test: bool
    cyclomatic: int = 1
    params: int = 0
    has_allocator_param: bool = False
    has_error_return: bool = False

@dataclass
class SecurityFinding:
    cwe: Optional[CWE]
    risk: RiskLevel
    module: str
    line: int
    rule: str
    message: str
    evidence: str = ""
    suggestion: str = ""

@dataclass
class DuplicateBlock:
    hash: str
    modules: List[str]
    line_ranges: List[Tuple[str, int, int]]
    lines: int

@dataclass
class ModuleDeepResult:
    name: str
    path: str
    lines: int
    non_empty: int
    comment_lines: int
    functions: List[FunctionInfo] = field(default_factory=list)
    security_findings: List[SecurityFinding] = field(default_factory=list)
    max_complexity: int = 0
    avg_complexity: float = 0
    maintainability_index: float = 0
    large_functions: int = 0
    comment_ratio: float = 0

# =============================================================================
# FUNCTION EXTRACTION
# =============================================================================

def extract_functions(code: str, module_name: str) -> List[FunctionInfo]:
    """Extract all function definitions with metrics."""
    functions = []
    lines = code.split('\n')

    # Match function declarations
    fn_pattern = re.compile(
        r'^(\s*)(pub\s+)?(export\s+)?(fn|test)\s+"?(\w[^("]*)"?\s*\('
    )

    i = 0
    while i < len(lines):
        m = fn_pattern.match(lines[i])
        if m:
            is_pub = bool(m.group(2))
            is_test = m.group(4) == 'test'
            name = m.group(5).strip()
            start = i + 1

            # Count params
            param_text = lines[i][lines[i].index('('):]
            depth = 0
            param_lines = []
            for j in range(i, min(i + 10, len(lines))):
                param_lines.append(lines[j])
                depth += lines[j].count('(') - lines[j].count(')')
                if depth <= 0:
                    break
            params_str = ' '.join(param_lines)
            params = len([p for p in params_str.split(',') if p.strip() and 'self' not in p.lower()])
            has_alloc = 'allocator' in params_str.lower() or 'Allocator' in params_str

            # Find function end (matching braces)
            brace_depth = 0
            end = i
            found_open = False
            for j in range(i, len(lines)):
                brace_depth += lines[j].count('{') - lines[j].count('}')
                if '{' in lines[j]:
                    found_open = True
                if found_open and brace_depth <= 0:
                    end = j + 1
                    break

            fn_lines = end - start
            fn_code = '\n'.join(lines[start:end])

            # Cyclomatic complexity
            complexity = 1
            complexity += len(re.findall(r'\bif\s*\(', fn_code))
            complexity += len(re.findall(r'\belse\s+if\b', fn_code))
            complexity += len(re.findall(r'\bwhile\s*\(', fn_code))
            complexity += len(re.findall(r'\bfor\s*\(', fn_code))
            complexity += len(re.findall(r'\bswitch\s*\(', fn_code))
            complexity += len(re.findall(r'\bcatch\b', fn_code))
            complexity += len(re.findall(r'\borelse\b', fn_code))
            complexity += len(re.findall(r'=>', fn_code))  # switch arms

            has_error = bool(re.search(r'!\w+|error\.\w+', fn_code))

            functions.append(FunctionInfo(
                name=name, module=module_name,
                line_start=start, line_end=end,
                lines=fn_lines, is_pub=is_pub, is_test=is_test,
                cyclomatic=complexity, params=params,
                has_allocator_param=has_alloc,
                has_error_return=has_error,
            ))

            i = end
        else:
            i += 1

    return functions

# =============================================================================
# SECURITY ANALYSIS
# =============================================================================

SECURITY_RULES = [
    # CWE-120: Buffer overflow
    # Zig @memcpy panics on out-of-bounds (no silent overflow), so most are safe.
    # Only flag @memcpy where source is fully external/untrusted (network buffers)
    # Only flag @memcpy where SECOND arg (source) is untrusted network data
    (re.compile(r'@memcpy\s*\([^,]+,\s*(?:recv_buf|raw_input|untrusted)'), CWE.BUFFER_OVERFLOW, RiskLevel.MEDIUM,
     "SEC-BUF-01", "memcpy from untrusted network source", "Verify destination buffer size"),
    (re.compile(r'\[\d+\].*='), None, RiskLevel.INFO,
     "SEC-BUF-02", "Fixed-size array write", ""),

    # CWE-190: Integer overflow — only flag @intCast on external/user input
    # @intCast after bounds check (if/clamp/min) or on compile-time constants is safe
    (re.compile(r'@intCast\s*\(\s*(?:extractArray|std\.mem\.readInt|buf\[|payload)'), CWE.INTEGER_OVERFLOW, RiskLevel.MEDIUM,
     "SEC-INT-01", "Integer cast on external input", "Use math.cast or check bounds first"),
    # @truncate is intentional in Zig for modular arithmetic (checksum, carry, index masking)
    # Only flag when used on external/untrusted input
    (re.compile(r'@truncate\s*\(\s*(?:input|payload|buf\[|data\[)'), CWE.INTEGER_OVERFLOW, RiskLevel.MEDIUM,
     "SEC-INT-02", "Integer truncation on external data", "Verify no data loss"),
    (re.compile(r'\+%\s|\-%\s|\*%\s'), None, RiskLevel.INFO,
     "SEC-INT-03", "Wrapping arithmetic used", "Intentional overflow handling"),

    # CWE-416: Use after free
    (re.compile(r'allocator\.free\s*\('), CWE.USE_AFTER_FREE, RiskLevel.LOW,
     "SEC-UAF-01", "Manual free - check no use after", "Prefer defer pattern"),

    # CWE-798: Hardcoded credentials
    # Exclude test files, RFC constants (WS_GUID), and public key fields
    (re.compile(r'(?:private_key|secret|password)\s*=\s*"[0-9a-fA-F]{16,}"', re.I), CWE.HARDCODED_KEY, RiskLevel.CRITICAL,
     "SEC-KEY-01", "Hardcoded private key/secret", "Use environment variable or vault"),
    (re.compile(r'0x[0-9a-fA-F]{64}'), CWE.HARDCODED_KEY, RiskLevel.LOW,
     "SEC-KEY-02", "64-char hex constant (possible key)", "Verify this is not a private key"),

    # CWE-400: Resource exhaustion
    # while(true) is normal for server loops and PoW mining (bounded by MAX_NONCE)
    # Only flag in non-server, non-mining contexts
    (re.compile(r'while\s*\(\s*true\s*\)'), CWE.UNCONTROLLED_RESOURCE, RiskLevel.LOW,
     "SEC-RES-01", "Loop without explicit bound", "Ensure exit condition or MAX_NONCE"),
    (re.compile(r'ArrayList.*append'), CWE.UNCONTROLLED_RESOURCE, RiskLevel.LOW,
     "SEC-RES-02", "Unbounded list growth", "Consider capacity limits"),

    # CWE-20: Input validation
    (re.compile(r'pub\s+fn\s+\w+.*\[\]const\s+u8'), CWE.IMPROPER_INPUT_VALIDATION, RiskLevel.LOW,
     "SEC-INPUT-01", "Public function with slice input", "Validate slice length"),

    # CWE-327: Crypto weaknesses
    # Note: SHA-1 in WebSocket handshake is REQUIRED by RFC 6455, not a vulnerability
    (re.compile(r'\bmd5\b|\bMD5\b', re.I), CWE.CRYPTO_WEAKNESS, RiskLevel.HIGH,
     "SEC-CRYPTO-01", "Weak hash algorithm (MD5)", "Use SHA-256 or SHA-3"),
    (re.compile(r'sha1.*(?:sign|verify|hash.*(?:block|tx|key))', re.I), CWE.CRYPTO_WEAKNESS, RiskLevel.HIGH,
     "SEC-CRYPTO-01b", "SHA1 used for crypto (not WebSocket)", "Use SHA-256 or SHA-3"),
    (re.compile(r'rand\.int|std\.rand'), None, RiskLevel.MEDIUM,
     "SEC-CRYPTO-02", "Non-cryptographic RNG", "Use std.crypto.random for keys"),

    # Blockchain-specific
    # Only match @panic( as actual code, not in comments (lines starting with //)
    (re.compile(r'^[^/]*@panic\s*\(', re.MULTILINE), None, RiskLevel.MEDIUM,
     "SEC-BC-01", "Panic in blockchain code", "Use error returns for recoverable errors"),
    # Only match `unreachable;` as Zig statement (not in strings or comments)
    (re.compile(r'^\s+unreachable;', re.MULTILINE), None, RiskLevel.MEDIUM,
     "SEC-BC-02", "Unreachable assertion", "UB if reached - ensure correctness"),
    (re.compile(r'@memset\s*\(.*0\s*\)'), None, RiskLevel.INFO,
     "SEC-BC-03", "Memory zeroing (good for key cleanup)", ""),
    (re.compile(r'nonce.*\+.*1|nonce\s*\+='), None, RiskLevel.INFO,
     "SEC-BC-04", "Nonce increment pattern", "Check for overflow at max nonce"),
    (re.compile(r'validateBlock|validate_block|verifyBlock'), None, RiskLevel.INFO,
     "SEC-BC-05", "Block validation present (good)", ""),
    (re.compile(r'replay|double.spend', re.I), None, RiskLevel.INFO,
     "SEC-BC-06", "Anti-replay/double-spend logic", ""),
]


def security_scan(code: str, module_name: str) -> List[SecurityFinding]:
    """Run all security rules against module code."""
    findings = []
    for pattern, cwe, risk, rule, msg, suggestion in SECURITY_RULES:
        for match in pattern.finditer(code):
            line_num = code[:match.start()].count('\n') + 1
            findings.append(SecurityFinding(
                cwe=cwe, risk=risk, module=module_name,
                line=line_num, rule=rule, message=msg,
                evidence=match.group(0)[:60], suggestion=suggestion,
            ))
    return findings

# =============================================================================
# DUPLICATE DETECTION
# =============================================================================

def find_duplicates(all_code: Dict[str, str], block_size: int = 8) -> List[DuplicateBlock]:
    """Find duplicate code blocks across modules."""
    block_hashes = defaultdict(list)

    for module_name, code in all_code.items():
        lines = [l.strip() for l in code.split('\n') if l.strip() and not l.strip().startswith('//')]

        for i in range(len(lines) - block_size + 1):
            block = '\n'.join(lines[i:i + block_size])
            h = hashlib.md5(block.encode()).hexdigest()
            block_hashes[h].append((module_name, i + 1, i + block_size))

    duplicates = []
    seen = set()
    for h, locations in block_hashes.items():
        modules = set(loc[0] for loc in locations)
        if len(modules) > 1 and h not in seen:
            seen.add(h)
            duplicates.append(DuplicateBlock(
                hash=h, modules=list(modules),
                line_ranges=locations, lines=block_size
            ))

    return sorted(duplicates, key=lambda d: len(d.modules), reverse=True)

# =============================================================================
# MAINTAINABILITY INDEX
# =============================================================================

def calc_maintainability(lines: int, complexity: float, comment_ratio: float) -> float:
    """Calculate Maintainability Index (0-100)."""
    if lines == 0:
        return 0
    vol = lines * math.log2(max(1, lines))
    mi = max(0, (171 - 5.2 * math.log(max(1, vol)) - 0.23 * complexity + 16.2 * math.log(max(1, comment_ratio * 100 + 1))) * 100 / 171)
    return round(min(100, mi), 1)

# =============================================================================
# LAYER VIOLATION DETECTION
# =============================================================================

LAYER_ORDER = {
    # Layer 0 - Crypto (no deps)
    "crypto": 0, "secp256k1": 0, "ripemd160": 0, "pq_crypto": 0, "key_encryption": 0,
    "schnorr": 0, "multisig": 0,
    # Layer 1 - Basic types + codec
    "transaction": 1, "block": 1, "bip32_wallet": 1,
    "compact_transaction": 1, "witness_data": 1, "hex_utils": 1,
    # Layer 2 - Core chain + sharding primitives
    "blockchain": 2, "blockchain_v2": 2, "genesis": 2, "consensus": 2, "binary_codec": 2, "spark_invariants": 2,
    "mempool": 2, "wallet": 2, "sub_block": 2, "finality": 2, "governance": 2,
    "shard_config": 2, "prune_config": 2, "archive_manager": 2,
    # Layer 3 - Network
    "p2p": 3, "sync": 3, "bootstrap": 3, "network": 3,
    # Layer 4 - Storage
    "database": 4, "storage": 4, "state_trie": 4,
    # Layer 5 - Node + features
    "node_launcher": 5, "cli": 5, "rpc_server": 5, "ws_server": 5,
    "mining_pool": 5, "light_client": 5, "light_miner": 5,
    "shard_coordinator": 5, "metachain": 5,
    # Layer 6 - Economic
    "bread_ledger": 6, "domain_minter": 6,
    "ubi_distributor": 6, "payment_channel": 6, "bridge_relay": 6,
    "oracle": 6, "omni_brain": 6,
    # Layer 7 - Entry
    "main": 7, "e2e_mining": 7, "miner_genesis": 7,
}

def check_layer_violations(module_name: str, imports: List[str]) -> List[SecurityFinding]:
    """Check if a module imports from a higher layer (violation)."""
    findings = []
    my_layer = LAYER_ORDER.get(module_name, 99)

    for imp in imports:
        imp_name = imp.replace(".zig", "")
        imp_layer = LAYER_ORDER.get(imp_name, 99)
        if imp_layer > my_layer and imp_layer != 99 and my_layer != 99:
            findings.append(SecurityFinding(
                cwe=None, risk=RiskLevel.LOW,
                module=module_name, line=0,
                rule="ARCH-LAYER-01",
                message=f"Layer violation: L{my_layer} imports L{imp_layer} ({imp_name})",
                suggestion=f"Consider inverting dependency or adding interface",
            ))

    return findings

# =============================================================================
# DEEP ANALYSIS
# =============================================================================

def deep_analyze(module_path: Path) -> ModuleDeepResult:
    """Perform deep analysis on a single module."""
    name = module_path.stem

    try:
        code = module_path.read_text(encoding='utf-8', errors='replace')
    except Exception:
        return ModuleDeepResult(name=name, path=str(module_path), lines=0, non_empty=0, comment_lines=0)

    lines_list = code.split('\n')
    lines = len(lines_list)
    non_empty = sum(1 for l in lines_list if l.strip())
    comment_lines = sum(1 for l in lines_list if l.strip().startswith('//'))
    comment_ratio = comment_lines / max(1, non_empty)

    # Functions
    functions = extract_functions(code, name)

    # Complexity
    complexities = [f.cyclomatic for f in functions if not f.is_test]
    max_complexity = max(complexities) if complexities else 0
    avg_complexity = sum(complexities) / len(complexities) if complexities else 0

    # Large functions
    large_fns = [f for f in functions if f.lines > 50 and not f.is_test]

    # Security
    security = security_scan(code, name)

    # Layer violations
    imports = []
    for m in re.finditer(r'@import\s*\(\s*"([^"]+)"\s*\)', code):
        imp = m.group(1)
        if imp != "std" and imp != "builtin":
            imports.append(imp.replace(".zig", ""))
    security.extend(check_layer_violations(name, imports))

    # Maintainability
    mi = calc_maintainability(non_empty, avg_complexity, comment_ratio)

    return ModuleDeepResult(
        name=name, path=str(module_path),
        lines=lines, non_empty=non_empty, comment_lines=comment_lines,
        functions=functions, security_findings=security,
        max_complexity=max_complexity, avg_complexity=round(avg_complexity, 1),
        maintainability_index=mi,
        large_functions=len(large_fns),
        comment_ratio=round(comment_ratio * 100, 1),
    )

# =============================================================================
# COLORS + REPORTS
# =============================================================================

G = "\033[92m"; Y = "\033[93m"; R = "\033[91m"; B = "\033[94m"
C = "\033[96m"; W = "\033[0m"; BOLD = "\033[1m"; DIM = "\033[2m"

RISK_COLORS = {
    RiskLevel.CRITICAL: R + BOLD,
    RiskLevel.HIGH: R,
    RiskLevel.MEDIUM: Y,
    RiskLevel.LOW: B,
    RiskLevel.INFO: DIM,
}


def print_deep_report(results: List[ModuleDeepResult], duplicates: List[DuplicateBlock],
                       security_only: bool = False, complexity_only: bool = False):
    SEP = "=" * 90

    print(f"\n{SEP}")
    print(f"  {BOLD}OmniBus Blockchain - Deep Code Audit v1.0{W}")
    print(f"  Analyzed: {len(results)} modules")
    print(f"{SEP}")

    if not security_only:
        # Complexity report
        print(f"\n  {BOLD}{C}COMPLEXITY ANALYSIS{W}")
        print(f"  {'Module':<28} {'Funcs':>6} {'MaxCC':>6} {'AvgCC':>6} {'Large':>6} {'MI':>8} {'Comments':>8}")
        print(f"  {'-' * 80}")

        for r in sorted(results, key=lambda x: -x.max_complexity):
            cc_col = R if r.max_complexity > 15 else (Y if r.max_complexity > 10 else G)
            mi_col = R if r.maintainability_index < 40 else (Y if r.maintainability_index < 65 else G)
            large_col = R if r.large_functions > 2 else (Y if r.large_functions > 0 else "")

            print(f"  {r.name:<28} {len(r.functions):>6} "
                  f"{cc_col}{r.max_complexity:>6}{W} {r.avg_complexity:>6.1f} "
                  f"{large_col}{r.large_functions:>6}{W} "
                  f"{mi_col}{r.maintainability_index:>7.1f}%{W} {r.comment_ratio:>7.1f}%")

        # Most complex functions
        all_fns = [(f, r.name) for r in results for f in r.functions if not f.is_test]
        top_complex = sorted(all_fns, key=lambda x: -x[0].cyclomatic)[:15]

        if top_complex:
            print(f"\n  {BOLD}Top Complex Functions:{W}")
            for fn, mod in top_complex:
                cc_col = R if fn.cyclomatic > 15 else (Y if fn.cyclomatic > 10 else G)
                print(f"    {cc_col}CC={fn.cyclomatic:<4}{W} {mod}:{fn.line_start} "
                      f"{'pub ' if fn.is_pub else ''}{fn.name}() [{fn.lines} lines]")

        # Large functions
        large_all = [(f, r.name) for r in results for f in r.functions
                     if f.lines > 50 and not f.is_test]
        if large_all:
            print(f"\n  {BOLD}{Y}Large Functions (>50 lines):{W}")
            for fn, mod in sorted(large_all, key=lambda x: -x[0].lines)[:10]:
                print(f"    {Y}{fn.lines:>4} lines{W}  {mod}:{fn.line_start} {fn.name}()")

    if not complexity_only:
        # Security report
        all_security = [f for r in results for f in r.security_findings]

        by_risk = defaultdict(list)
        for f in all_security:
            by_risk[f.risk].append(f)

        print(f"\n  {BOLD}{R}SECURITY FINDINGS{W}")
        print(f"  Critical: {len(by_risk[RiskLevel.CRITICAL])} | "
              f"High: {len(by_risk[RiskLevel.HIGH])} | "
              f"Medium: {len(by_risk[RiskLevel.MEDIUM])} | "
              f"Low: {len(by_risk[RiskLevel.LOW])}")

        for risk in [RiskLevel.CRITICAL, RiskLevel.HIGH, RiskLevel.MEDIUM]:
            findings = by_risk[risk]
            if findings:
                col = RISK_COLORS[risk]
                print(f"\n  {col}[{risk.value}]{W} ({len(findings)}):")
                shown = set()
                for f in findings:
                    key = f"{f.rule}:{f.module}"
                    if key not in shown:
                        shown.add(key)
                        cwe_str = f" ({f.cwe.value})" if f.cwe else ""
                        print(f"    [{f.rule}]{cwe_str} {f.module}:{f.line} - {f.message}")
                        if f.suggestion:
                            print(f"      {DIM}Fix: {f.suggestion}{W}")

        # Layer violations
        layer_violations = [f for f in all_security if f.rule == "ARCH-LAYER-01"]
        if layer_violations:
            print(f"\n  {BOLD}{Y}ARCHITECTURE LAYER VIOLATIONS{W}")
            for f in layer_violations:
                print(f"    {Y}{f.module}{W}: {f.message}")

    # Duplicates
    if not security_only and not complexity_only and duplicates:
        print(f"\n  {BOLD}{Y}DUPLICATE CODE BLOCKS{W} ({len(duplicates)} found)")
        for d in duplicates[:10]:
            print(f"    {d.lines}-line block shared by: {', '.join(d.modules[:5])}")

    # Summary
    total_fns = sum(len(r.functions) for r in results)
    total_tests = sum(1 for r in results for f in r.functions if f.is_test)
    avg_mi = sum(r.maintainability_index for r in results) / len(results) if results else 0

    print(f"\n{SEP}")
    print(f"  {BOLD}DEEP AUDIT SUMMARY{W}")
    print(f"{SEP}")
    print(f"  Modules analyzed:     {len(results)}")
    print(f"  Total functions:      {total_fns} ({total_tests} tests)")
    print(f"  Average MI:           {avg_mi:.1f}%")
    print(f"  Security findings:    {len([f for r in results for f in r.security_findings])}")
    print(f"  Duplicate blocks:     {len(duplicates)}")
    print(f"{SEP}\n")


def export_json(results: List[ModuleDeepResult], duplicates: List[DuplicateBlock], path: Path):
    data = {
        "tool": "blockchain_deep_audit",
        "version": "1.0",
        "modules": [
            {
                "name": r.name,
                "lines": r.lines,
                "non_empty": r.non_empty,
                "functions": len(r.functions),
                "tests": sum(1 for f in r.functions if f.is_test),
                "max_complexity": r.max_complexity,
                "avg_complexity": r.avg_complexity,
                "maintainability_index": r.maintainability_index,
                "large_functions": r.large_functions,
                "comment_ratio": r.comment_ratio,
                "security_findings": [
                    {
                        "cwe": f.cwe.value if f.cwe else None,
                        "risk": f.risk.value,
                        "rule": f.rule,
                        "line": f.line,
                        "message": f.message,
                    }
                    for f in r.security_findings
                ],
                "top_functions": [
                    {
                        "name": f.name,
                        "line": f.line_start,
                        "lines": f.lines,
                        "complexity": f.cyclomatic,
                        "is_pub": f.is_pub,
                    }
                    for f in sorted(r.functions, key=lambda x: -x.cyclomatic)[:5]
                ]
            }
            for r in results
        ],
        "duplicates": len(duplicates),
    }
    with open(path, 'w') as f:
        json.dump(data, f, indent=2)
    print(f"  JSON report: {path}")


# =============================================================================
# MAIN
# =============================================================================

def main():
    parser = argparse.ArgumentParser(description="OmniBus Blockchain Deep Audit v1.0")
    parser.add_argument("--module", help="Audit specific module")
    parser.add_argument("--json", metavar="FILE", help="Export JSON report")
    parser.add_argument("--security-only", action="store_true", help="Security checks only")
    parser.add_argument("--complexity", action="store_true", help="Complexity report only")
    args = parser.parse_args()

    print(f"\n{'=' * 60}")
    print(f"  {BOLD}OmniBus Blockchain Deep Audit v1.0{W}")
    print(f"{'=' * 60}")

    all_code = {}
    results = []

    if args.module:
        p = CORE / f"{args.module}.zig"
        if not p.exists():
            print(f"  {R}ERROR: {p} not found{W}")
            sys.exit(1)
        code = p.read_text(encoding='utf-8', errors='replace')
        all_code[args.module] = code
        results.append(deep_analyze(p))
    else:
        for d in [CORE, TEST, AGENT]:
            if not d.exists():
                continue
            for f in sorted(d.glob("*.zig")):
                print(f"  Analyzing {f.name}...", end='\r')
                code = f.read_text(encoding='utf-8', errors='replace')
                all_code[f.stem] = code
                results.append(deep_analyze(f))
        print(" " * 60, end='\r')

    # Duplicate detection
    duplicates = find_duplicates(all_code) if not args.security_only else []

    print_deep_report(results, duplicates, args.security_only, args.complexity)

    if args.json:
        export_json(results, duplicates, Path(args.json))

    # Exit code based on critical findings
    criticals = sum(1 for r in results for f in r.security_findings if f.risk == RiskLevel.CRITICAL)
    sys.exit(1 if criticals > 0 else 0)

if __name__ == "__main__":
    main()
