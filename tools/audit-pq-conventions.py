#!/usr/bin/env python3
"""
audit-pq-conventions.py — Static audit of PQ-OMNI scheme/prefix conventions
across the OmniBus BlockChainCore codebase.

WHY THIS EXISTS
---------------
Multiple sessions and agents have written code for PQ signing using slightly
different mappings between (prefix, scheme name, BIP-44 account, scheme code).
The canonical mapping lives in core/transaction.zig + core/isolated_wallet.zig.
This script flags every file that deviates so we can keep a single source of
truth.

WHAT IT DOES
------------
Scans .zig / .ts / .tsx / .mjs / .js / .py files for occurrences of:
  - prefixes:  obk1_, obf5_, obd5_, obs3_  +  ob_k1_, ob_f5_, ob_d5_, ob_s3_
  - schemes:   ml_dsa_87, falcon_512, dilithium_5, slh_dsa_256s
  - soulbound: love_dilithium, food_falcon, rent_slh_dsa, vacation_kem
  - hybrid:    hybrid_q1..q4
  - BIP-44:    m/44'/777'/<N>'/0/0  for N in 5..13
  - codes:     scheme codes 1..12

Then per file infers which (prefix → scheme) mapping is used, compares it
against the canonical mapping, and emits a markdown report.

CANONICAL MAPPING (from core/transaction.zig:180-201)
-----------------------------------------------------
    obk1_  ⇄  ML-DSA-87       (code 5)   m/44'/777'/5'/0/0
    obf5_  ⇄  Falcon-512      (code 6)   m/44'/777'/6'/0/0
    obs3_  ⇄  Dilithium-5     (code 7)   m/44'/777'/7'/0/0
    obd5_  ⇄  SLH-DSA-256s    (code 8)   m/44'/777'/8'/0/0

Soulbound (non-transferable, with leading underscore):
    ob_k1_ ⇄ love_dilithium   (code 1)
    ob_f5_ ⇄ food_falcon      (code 2)
    ob_d5_ ⇄ rent_slh_dsa     (code 3)
    ob_s3_ ⇄ vacation_kem     (code 4)

USAGE
-----
    python tools/audit-pq-conventions.py
    python tools/audit-pq-conventions.py --output PQ_AUDIT_$(date +%F).md
    python tools/audit-pq-conventions.py --json   # machine-readable
    python tools/audit-pq-conventions.py --fail-on-drift   # exit 1 on drift (CI)
"""

from __future__ import annotations
import argparse
import json
import os
import re
import sys
from dataclasses import dataclass, field, asdict
from datetime import date
from pathlib import Path
from typing import Optional

# ── Canonical mapping ────────────────────────────────────────────────────────

CANON = {
    "obk1_": ("ML-DSA-87",    "ml_dsa_87",    5, "pq_omni_ml_dsa"),
    "obf5_": ("Falcon-512",   "falcon_512",   6, "pq_omni_falcon"),
    "obs3_": ("Dilithium-5",  "dilithium_5",  7, "pq_omni_dilithium"),
    "obd5_": ("SLH-DSA-256s", "slh_dsa_256s", 8, "pq_omni_slh_dsa"),
}

SOULBOUND = {
    "ob_k1_": ("love_dilithium", 1),
    "ob_f5_": ("food_falcon",    2),
    "ob_d5_": ("rent_slh_dsa",   3),
    "ob_s3_": ("vacation_kem",   4),
}

PREFIXES_TRANSFER = list(CANON.keys())
PREFIXES_SOULBOUND = list(SOULBOUND.keys())
ALL_PREFIXES = PREFIXES_TRANSFER + PREFIXES_SOULBOUND
SCHEME_NAMES = ["ml_dsa_87", "falcon_512", "dilithium_5", "slh_dsa_256s"]
PQ_OMNI_ENUMS = ["pq_omni_ml_dsa", "pq_omni_falcon", "pq_omni_dilithium", "pq_omni_slh_dsa"]

EXTENSIONS = {".zig", ".ts", ".tsx", ".mjs", ".js", ".py"}
SKIP_DIRS = {
    "node_modules", "zig-out", ".zig-cache", "zig-cache", ".cache",
    "archived-4-eterniti", "8_JUNK", "html", "latex", "dist",
    ".git", "data", "backups",
}

# ── Regex patterns ───────────────────────────────────────────────────────────

# Captures `<prefix>` near `<scheme_name>` in same line — used to infer mapping
# Examples it matches:
#   .pq_omni_ml_dsa => "obk1_"
#   ml_dsa_87:    "obk1_"
#   { id: "ml_dsa_87",   ..., prefix: "obk1_"  }
#   "obk1_" -> ML-DSA
PAIR_REGEXES = [
    # zig: .pq_omni_X => "PREFIX"
    re.compile(r'\.(pq_omni_\w+)\s*=>\s*"([a-z_0-9]+_)"'),
    # ts/js: id: "scheme",   prefix: "PREFIX"  (same line, prefix may follow)
    re.compile(r'"(ml_dsa_87|falcon_512|dilithium_5|slh_dsa_256s)"[^"\n]*?prefix:\s*"([a-z_0-9]+_)"'),
    # ts/js: scheme: "X" ... prefix: "Y"
    re.compile(r'scheme:\s*"(ml_dsa_87|falcon_512|dilithium_5|slh_dsa_256s)"[^"\n]*?prefix:\s*"([a-z_0-9]+_)"'),
    # object literal: ml_dsa_87:    "obk1_"
    re.compile(r'(ml_dsa_87|falcon_512|dilithium_5|slh_dsa_256s):\s*"([a-z_0-9]+_)"'),
    # zig pair on consecutive matches: "obk1_" => .pq_omni_X
    re.compile(r'"([a-z_0-9]+_)"\s*=>\s*\.(pq_omni_\w+)'),
    # zig: startsWith(u8, addr, "PREFIX")) return .pq_omni_X
    re.compile(r'startsWith\([^)]*"([a-z_0-9]+_)"[^)]*\)\s*\)\s*return\s+\.(pq_omni_\w+)'),
]

BIP44_RE = re.compile(r"m/44'/777'/(\d+)'/0/0")
SCHEME_NEAR_PATH_WINDOW = 3  # lines

# ── Data classes ─────────────────────────────────────────────────────────────

@dataclass
class FileFinding:
    path: str
    mappings: dict[str, str] = field(default_factory=dict)   # prefix → scheme_name
    bip44: dict[str, int] = field(default_factory=dict)       # scheme_name → account
    drifts: list[str] = field(default_factory=list)
    aligned: list[str] = field(default_factory=list)
    raw_hits: dict[str, list[int]] = field(default_factory=dict)  # token → line numbers

    @property
    def has_drift(self) -> bool:
        return bool(self.drifts)

    @property
    def is_relevant(self) -> bool:
        return bool(self.mappings or self.bip44 or self.raw_hits)


# ── Scanning ─────────────────────────────────────────────────────────────────

def scan_file(path: Path) -> Optional[FileFinding]:
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return None

    # Cheap pre-filter: skip files with no PQ token at all
    needles = ALL_PREFIXES + SCHEME_NAMES + PQ_OMNI_ENUMS + ["m/44'/777'/"]
    if not any(n in text for n in needles):
        return None

    finding = FileFinding(path=str(path))
    lines = text.splitlines()

    # Collect raw token line numbers (first 5 occurrences each)
    for token in ALL_PREFIXES + SCHEME_NAMES + PQ_OMNI_ENUMS:
        hits: list[int] = []
        for i, line in enumerate(lines, start=1):
            if token in line:
                hits.append(i)
                if len(hits) >= 5:
                    break
        if hits:
            finding.raw_hits[token] = hits

    # Pair regexes — extract prefix↔scheme mappings
    for rx in PAIR_REGEXES:
        for m in rx.finditer(text):
            a, b = m.group(1), m.group(2)
            if a in ALL_PREFIXES:
                prefix, scheme = a, b
            elif b in ALL_PREFIXES:
                prefix, scheme = b, a
            else:
                # Both might be schemes/enums; skip
                continue
            # Normalize scheme to bare name (strip pq_omni_ prefix)
            if scheme.startswith("pq_omni_"):
                bare = scheme[len("pq_omni_"):]
                bare = {"ml_dsa": "ml_dsa_87", "falcon": "falcon_512",
                        "dilithium": "dilithium_5", "slh_dsa": "slh_dsa_256s"}.get(bare, bare)
                scheme = bare
            if scheme in SCHEME_NAMES:
                # Record first mapping seen per prefix
                if prefix not in finding.mappings:
                    finding.mappings[prefix] = scheme

    # BIP-44 paths — try to associate account number with a scheme name in
    # the surrounding lines (±SCHEME_NEAR_PATH_WINDOW).
    for i, line in enumerate(lines):
        m = BIP44_RE.search(line)
        if not m:
            continue
        account = int(m.group(1))
        if account < 1 or account > 20:
            continue
        # Look for scheme name nearby
        lo = max(0, i - SCHEME_NEAR_PATH_WINDOW)
        hi = min(len(lines), i + SCHEME_NEAR_PATH_WINDOW + 1)
        window = " ".join(lines[lo:hi])
        for s in SCHEME_NAMES:
            if s in window and s not in finding.bip44:
                finding.bip44[s] = account
                break

    # Compare against canon
    for prefix, scheme in finding.mappings.items():
        if prefix in CANON:
            canon_scheme = CANON[prefix][1]
            if scheme == canon_scheme:
                finding.aligned.append(f'{prefix} → {scheme}')
            else:
                finding.drifts.append(
                    f'{prefix} → {scheme}  (canon: {canon_scheme})'
                )
        elif prefix in SOULBOUND:
            # Soulbound prefixes shouldn't map to PQ-OMNI transferable names
            if scheme in SCHEME_NAMES:
                finding.drifts.append(
                    f'{prefix} → {scheme}  (canon: {prefix} is soulbound, not transferable PQ-OMNI)'
                )

    canon_paths = {"ml_dsa_87": 5, "falcon_512": 6, "dilithium_5": 7, "slh_dsa_256s": 8}
    for scheme, account in finding.bip44.items():
        canon_account = canon_paths.get(scheme)
        if canon_account is None:
            continue
        if account != canon_account:
            finding.drifts.append(
                f"BIP-44: {scheme} → m/44'/777'/{account}'/0/0  (canon: {canon_account}')"
            )
        else:
            finding.aligned.append(f"BIP-44: {scheme} → {account}'")

    return finding if finding.is_relevant else None


def walk(root: Path) -> list[FileFinding]:
    findings: list[FileFinding] = []
    for dirpath, dirnames, filenames in os.walk(root):
        # Filter dirs in-place to skip
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS and not d.startswith(".")]
        for name in filenames:
            p = Path(dirpath) / name
            if p.suffix.lower() not in EXTENSIONS:
                continue
            f = scan_file(p)
            if f is not None:
                findings.append(f)
    findings.sort(key=lambda x: (not x.has_drift, x.path))
    return findings


# ── Report rendering ─────────────────────────────────────────────────────────

def render_markdown(findings: list[FileFinding], root: Path) -> str:
    drift_files = [f for f in findings if f.has_drift]
    aligned_files = [f for f in findings if not f.has_drift]
    today = date.today().isoformat()

    out: list[str] = []
    out.append(f"# PQ-OMNI convention audit — {today}")
    out.append("")
    out.append("Generated by `tools/audit-pq-conventions.py`. Re-run anytime to refresh.")
    out.append("")
    out.append("## Canonical mapping (chain authority)")
    out.append("")
    out.append("Source: `core/transaction.zig:180-201` + `core/isolated_wallet.zig:64-96`.")
    out.append("")
    out.append("| Prefix | Scheme | Code | BIP-44 account |")
    out.append("|---|---|---|---|")
    for prefix, (display, name, code, _) in CANON.items():
        canon_paths = {"ml_dsa_87": 5, "falcon_512": 6, "dilithium_5": 7, "slh_dsa_256s": 8}
        out.append(f"| `{prefix}` | {display} (`{name}`) | {code} | `m/44'/777'/{canon_paths[name]}'/0/0` |")
    out.append("")
    out.append("Soulbound (non-transferable):")
    out.append("")
    out.append("| Prefix | Scheme | Code |")
    out.append("|---|---|---|")
    for prefix, (name, code) in SOULBOUND.items():
        out.append(f"| `{prefix}` | `{name}` | {code} |")
    out.append("")

    # Summary
    total = len(findings)
    out.append("## Summary")
    out.append("")
    out.append(f"- Files scanned and matching PQ tokens: **{total}**")
    out.append(f"- Files with drift: **{len(drift_files)}**")
    out.append(f"- Files canon-aligned: **{len(aligned_files)}**")
    out.append("")

    if drift_files:
        out.append("## ⚠️ Files OUT OF SYNC")
        out.append("")
        for f in drift_files:
            rel = Path(f.path).resolve().relative_to(root.resolve()) if root in Path(f.path).resolve().parents else Path(f.path)
            out.append(f"### `{rel}`")
            out.append("")
            if f.mappings:
                out.append("**Inferred mappings:**")
                out.append("")
                for prefix, scheme in sorted(f.mappings.items()):
                    canon_scheme = CANON.get(prefix, (None, None))[1]
                    flag = "✅" if scheme == canon_scheme else ("❌ DRIFT" if canon_scheme else "ℹ️")
                    out.append(f"- `{prefix}` → `{scheme}`  {flag}")
                out.append("")
            if f.bip44:
                out.append("**BIP-44 paths:**")
                out.append("")
                for scheme, account in sorted(f.bip44.items()):
                    canon_paths = {"ml_dsa_87": 5, "falcon_512": 6, "dilithium_5": 7, "slh_dsa_256s": 8}
                    canon = canon_paths.get(scheme)
                    flag = "✅" if account == canon else "❌ DRIFT"
                    out.append(f"- `{scheme}` → `m/44'/777'/{account}'/0/0`  {flag} (canon: `{canon}'`)")
                out.append("")
            if f.drifts:
                out.append("**Drift details:**")
                out.append("")
                for d in f.drifts:
                    out.append(f"- {d}")
                out.append("")

    if aligned_files:
        out.append("## ✅ Files canon-aligned")
        out.append("")
        for f in aligned_files:
            rel = Path(f.path).resolve().relative_to(root.resolve()) if root in Path(f.path).resolve().parents else Path(f.path)
            tokens = sorted(f.raw_hits.keys())[:6]
            out.append(f"- `{rel}`  ({', '.join(tokens)}{'...' if len(f.raw_hits) > 6 else ''})")
        out.append("")

    return "\n".join(out) + "\n"


# ── Main ─────────────────────────────────────────────────────────────────────

def main() -> int:
    ap = argparse.ArgumentParser(description="Audit PQ-OMNI convention drift.")
    ap.add_argument("--root", default=None,
                    help="Root dir to scan (default: parent of this script's dir).")
    ap.add_argument("--output", default=None,
                    help="Markdown output path (default: PQ_AUDIT_<today>.md in root).")
    ap.add_argument("--json", action="store_true",
                    help="Emit JSON instead of Markdown to stdout.")
    ap.add_argument("--fail-on-drift", action="store_true",
                    help="Exit 1 if any drift detected (for CI).")
    args = ap.parse_args()

    script_dir = Path(__file__).resolve().parent
    root = Path(args.root).resolve() if args.root else script_dir.parent
    if not root.exists():
        print(f"ERROR: root path does not exist: {root}", file=sys.stderr)
        return 2

    findings = walk(root)

    if args.json:
        json.dump([asdict(f) for f in findings], sys.stdout, indent=2)
        sys.stdout.write("\n")
    else:
        report = render_markdown(findings, root)
        out_path = Path(args.output) if args.output else root / f"PQ_AUDIT_{date.today().isoformat()}.md"
        out_path.write_text(report, encoding="utf-8")
        drift_count = sum(1 for f in findings if f.has_drift)
        print(f"Scanned {len(findings)} relevant files. Drift: {drift_count}.")
        print(f"Report: {out_path}")

    if args.fail_on_drift and any(f.has_drift for f in findings):
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
