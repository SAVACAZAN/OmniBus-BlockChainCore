#!/usr/bin/env python3
"""
OmniBus Blockchain - Security Scanner
======================================

Scanare rapidă pentru vulnerabilități comune.
Detectează probleme potențiale de securitate în cod.

Utilizare:
    python security_scan.py              # Scan complet
    python security_scan.py --critical   # Doar probleme critice
    python security_scan.py --json       # Output JSON

Autor: OmniBus AI Collective
Versiune: 1.0.0
"""

import os
import sys
import json
import re
from pathlib import Path
from dataclasses import dataclass, asdict
from typing import List, Dict, Tuple, Optional
from collections import defaultdict


@dataclass
class SecurityIssue:
    """Reprezintă o problemă de securitate detectată."""
    file: str
    line: int
    severity: str  # critical, high, medium, low
    category: str
    message: str
    code_snippet: str
    recommendation: str


class SecurityScanner:
    """Scaner pentru vulnerabilități de securitate."""
    
    # Pattern-uri de detectare
    PATTERNS = {
        'hardcoded_secret': {
            'pattern': re.compile(
                r'(password|secret|key|token|api_key)\s*[:=]\s*["\'][^"\']{8,}["\']',
                re.IGNORECASE
            ),
            'severity': 'critical',
            'message': 'Posibil secret hardcodat',
            'recommendation': 'Folosește variabile de mediu sau fișiere de config separate'
        },
        'unsafe_buffer': {
            'pattern': re.compile(
                r'@memcpy\s*\([^,]+,\s*[^,]+\)',
            ),
            'severity': 'medium',
            'message': '@memcpy fără verificare de dimensiune',
            'recommendation': 'Verifică dimensiunea buffer-ului înainte de copy'
        },
        'todo_security': {
            'pattern': re.compile(
                r'//.*TODO.*(security|securitate|vuln|exploit)',
                re.IGNORECASE
            ),
            'severity': 'high',
            'message': 'TODO legat de securitate',
            'recommendation': 'Rezolvă TODO-ul înainte de production'
        },
        'unchecked_allocation': {
            'pattern': re.compile(
                r'\.alloc\([^)]+\)(?!\s*catch)',
            ),
            'severity': 'low',
            'message': 'Alocare posibil fără error handling',
            'recommendation': 'Folosește try sau catch pentru alocări'
        },
        'panic_usage': {
            'pattern': re.compile(
                r'@panic\s*\(',
            ),
            'severity': 'low',
            'message': 'Utilizare @panic',
            'recommendation': 'Folosește error handling în loc de panic în production'
        },
        'debug_print': {
            'pattern': re.compile(
                r'std\.debug\.print\s*\(',
            ),
            'severity': 'low',
            'message': 'Debug print detectat',
            'recommendation': 'Înlătură debug prints înainte de release'
        },
        'unbounded_loop': {
            'pattern': re.compile(
                r'while\s*\(\s*true\s*\)',
            ),
            'severity': 'medium',
            'message': 'Loop infinit potențial periculos',
            'recommendation': 'Adaugă condiție de ieșire și verificare timeout'
        },
        'integer_overflow': {
            'pattern': re.compile(
                r'\+\s*\+|\*\s*\*|-\s*-',
            ),
            'severity': 'low',
            'message': 'Operație aritmetică care ar putea overflow',
            'recommendation': 'Folosește funcții cu checked arithmetic'
        },
        'missing_bounds_check': {
            'pattern': re.compile(
                r'\[\s*\w+\s*\](?!\s*\?|\s*orelse)',
            ),
            'severity': 'medium',
            'message': 'Acces array posibil fără bounds check',
            'recommendation': 'Verifică bounds sau folosește optional access'
        },
        'expect_usage': {
            'pattern': re.compile(
                r'\.expect\s*\(',
            ),
            'severity': 'low',
            'message': 'Utilizare .expect()',
            'recommendation': 'Folosește try/catch pentru error handling mai bun'
        },
    }
    
    def __init__(self, project_root: Path):
        self.project_root = project_root
        self.issues: List[SecurityIssue] = []
        
    def scan_file(self, filepath: Path) -> List[SecurityIssue]:
        """Scanează un singur fișier."""
        issues = []
        
        try:
            with open(filepath, 'r', encoding='utf-8') as f:
                lines = f.readlines()
        except Exception:
            return issues
        
        rel_path = str(filepath.relative_to(self.project_root))
        
        for line_num, line in enumerate(lines, 1):
            for category, rule in self.PATTERNS.items():
                if rule['pattern'].search(line):
                    # Verifică dacă e comentat
                    stripped = line.strip()
                    if stripped.startswith('//'):
                        continue
                    
                    issues.append(SecurityIssue(
                        file=rel_path,
                        line=line_num,
                        severity=rule['severity'],
                        category=category,
                        message=rule['message'],
                        code_snippet=line.strip()[:80],
                        recommendation=rule['recommendation']
                    ))
        
        return issues
    
    def scan_project(self) -> List[SecurityIssue]:
        """Scanează întregul proiect."""
        zig_files = list(self.project_root.rglob('*.zig'))
        zig_files = [
            f for f in zig_files 
            if not any(part.startswith('.') or part in ['zig-out', '.zig-cache']
                      for part in f.parts)
        ]
        
        for filepath in zig_files:
            issues = self.scan_file(filepath)
            self.issues.extend(issues)
        
        # Sortează după severitate
        severity_order = {'critical': 0, 'high': 1, 'medium': 2, 'low': 3}
        self.issues.sort(key=lambda i: severity_order.get(i.severity, 4))
        
        return self.issues
    
    def get_stats(self) -> Dict:
        """Returnează statistici despre issue-uri."""
        stats = {
            'total': len(self.issues),
            'by_severity': defaultdict(int),
            'by_category': defaultdict(int),
        }
        
        for issue in self.issues:
            stats['by_severity'][issue.severity] += 1
            stats['by_category'][issue.category] += 1
        
        return dict(stats)


def print_issues(issues: List[SecurityIssue], min_severity: Optional[str] = None):
    """Afișează issue-urile."""
    RED = '\033[91m'
    YELLOW = '\033[93m'
    BLUE = '\033[94m'
    GREEN = '\033[92m'
    RESET = '\033[0m'
    BOLD = '\033[1m'
    
    if min_severity:
        severity_order = {'critical': 0, 'high': 1, 'medium': 2, 'low': 3}
        min_level = severity_order.get(min_severity, 0)
        issues = [i for i in issues if severity_order.get(i.severity, 4) <= min_level]
    
    if not issues:
        print(f"\n  {GREEN}Nu s-au găsit probleme de securitate!{RESET}\n")
        return
    
    print(f"\n{BOLD}╔══════════════════════════════════════════════════════════════╗{RESET}")
    print(f"{BOLD}║            OmniBus Blockchain - Security Scan                ║{RESET}")
    print(f"{BOLD}╚══════════════════════════════════════════════════════════════╝{RESET}\n")
    
    # Grupează după severitate
    by_severity = defaultdict(list)
    for issue in issues:
        by_severity[issue.severity].append(issue)
    
    colors = {
        'critical': RED,
        'high': RED,
        'medium': YELLOW,
        'low': BLUE,
    }
    
    for severity in ['critical', 'high', 'medium', 'low']:
        if severity not in by_severity:
            continue
        
        color = colors.get(severity, RESET)
        items = by_severity[severity]
        
        print(f"\n  {color}{BOLD}[{severity.upper()}] ({len(items)} issue-uri){RESET}\n")
        
        for issue in items:
            print(f"    {color}•{RESET} {BOLD}{issue.file}:{issue.line}{RESET}")
            print(f"      {issue.message}")
            print(f"      {YELLOW}Cod:{RESET} {issue.code_snippet[:60]}")
            print(f"      {GREEN}Recomandare:{RESET} {issue.recommendation}")
            print()


def print_stats(stats: Dict):
    """Afișează statistici."""
    RED = '\033[91m'
    YELLOW = '\033[93m'
    GREEN = '\033[92m'
    RESET = '\033[0m'
    BOLD = '\033[1m'
    
    print(f"\n  {BOLD}Statistici Securitate:{RESET}\n")
    print(f"    Total issue-uri: {BOLD}{stats['total']}{RESET}")
    
    print(f"\n    {BOLD}După severitate:{RESET}")
    for severity in ['critical', 'high', 'medium', 'low']:
        count = stats['by_severity'].get(severity, 0)
        color = {'critical': RED, 'high': RED, 'medium': YELLOW, 'low': GREEN}.get(severity, RESET)
        print(f"      {color}{severity:10}{RESET}: {count}")
    
    if stats['by_severity'].get('critical', 0) > 0:
        print(f"\n    {RED}{BOLD}⚠ PROBLEME CRITICE DETECTATE!{RESET}")
    elif stats['by_severity'].get('high', 0) > 0:
        print(f"\n    {YELLOW}{BOLD}⚠ Probleme HIGH detectate{RESET}")
    else:
        print(f"\n    {GREEN}{BOLD}✓ Niciun risc critic{RESET}")
    
    print()


def main():
    import argparse
    
    parser = argparse.ArgumentParser(
        description='Scanare securitate pentru OmniBus',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Exemple:
  python security_scan.py              # Scan complet
  python security_scan.py --critical   # Doar critice
  python security_scan.py --high       # Doar high+
  python security_scan.py --json       # Output JSON
        """
    )
    parser.add_argument('--critical', action='store_true',
                        help='Doar probleme critice')
    parser.add_argument('--high', action='store_true',
                        help='Doar high și critical')
    parser.add_argument('--json', action='store_true',
                        help='Output JSON')
    parser.add_argument('--stats', action='store_true',
                        help='Doar statistici')
    
    args = parser.parse_args()
    
    # Find project root
    script_dir = Path(__file__).parent
    project_root = script_dir.parent.parent
    
    # Scan
    scanner = SecurityScanner(project_root)
    issues = scanner.scan_project()
    
    # Filter
    min_severity = None
    if args.critical:
        min_severity = 'critical'
    elif args.high:
        min_severity = 'high'
    
    # Output
    if args.json:
        data = {
            'issues': [asdict(i) for i in issues],
            'stats': scanner.get_stats()
        }
        print(json.dumps(data, indent=2))
    elif args.stats:
        print_stats(scanner.get_stats())
    else:
        print_issues(issues, min_severity)
        print_stats(scanner.get_stats())
    
    # Exit code
    stats = scanner.get_stats()
    critical = stats['by_severity'].get('critical', 0)
    high = stats['by_severity'].get('high', 0)
    
    if critical > 0:
        sys.exit(2)  # Critical issues
    elif high > 5:
        sys.exit(1)  # Too many high issues
    sys.exit(0)


if __name__ == '__main__':
    main()
