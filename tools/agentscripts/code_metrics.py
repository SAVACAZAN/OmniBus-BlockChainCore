#!/usr/bin/env python3
"""
OmniBus Blockchain - Code Metrics
==================================

Calculează metrici de cod: LOC, complexitate, raport teste/cod, etc.
Ideal pentru a monitoriza creșterea proiectului.

Utilizare:
    python code_metrics.py              # Metrici complete
    python code_metrics.py --summary    # Doar sumar
    python code_metrics.py --trend      # Compară cu rularea anterioară
    python code_metrics.py --json       # Output JSON

Autor: OmniBus AI Collective
Versiune: 1.0.0
"""

import os
import sys
import json
import re
from pathlib import Path
from dataclasses import dataclass, asdict
from typing import Dict, List, Tuple
from collections import defaultdict
import math


@dataclass
class FileMetrics:
    """Metrici pentru un singur fișier."""
    path: str
    lines_total: int
    lines_code: int
    lines_blank: int
    lines_comment: int
    functions: int
    structs: int
    tests: int
    complexity_score: int  # Aproximativ


@dataclass
class ProjectMetrics:
    """Metrici pentru întregul proiect."""
    total_files: int
    total_lines: int
    total_code_lines: int
    total_blank_lines: int
    total_comment_lines: int
    total_functions: int
    total_structs: int
    total_tests: int
    avg_file_size: float
    largest_files: List[Tuple[str, int]]
    test_to_code_ratio: float
    complexity_avg: float


class CodeAnalyzer:
    """Analizează codul Zig pentru metrici."""
    
    def __init__(self, project_root: Path):
        self.project_root = project_root
        self.file_metrics: List[FileMetrics] = []
        
    def analyze_file(self, filepath: Path) -> FileMetrics:
        """Analizează un singur fișier."""
        try:
            with open(filepath, 'r', encoding='utf-8') as f:
                content = f.read()
                lines = content.split('\n')
        except Exception:
            return None
        
        total_lines = len(lines)
        blank_lines = 0
        comment_lines = 0
        code_lines = 0
        functions = 0
        structs = 0
        tests = 0
        
        in_multiline_comment = False
        
        for line in lines:
            stripped = line.strip()
            
            # Blank line
            if not stripped:
                blank_lines += 1
                continue
            
            # Comment
            if stripped.startswith('//'):
                comment_lines += 1
                continue
            
            if stripped.startswith('/*'):
                in_multiline_comment = True
            
            if in_multiline_comment:
                comment_lines += 1
                if '*/' in stripped:
                    in_multiline_comment = False
                continue
            
            # Code line
            code_lines += 1
            
            # Count functions
            if re.match(r'^\s*(pub\s+)?fn\s+\w+', line):
                functions += 1
            
            # Count structs
            if re.match(r'^\s*(pub\s+)?const\s+\w+\s*=\s*struct', line):
                structs += 1
            
            # Count tests
            if re.match(r'^\s*test\s+["\']', line) or re.match(r'^\s*test\s*\{', line):
                tests += 1
        
        # Calculate complexity (simplified)
        complexity = self._calculate_complexity(content)
        
        return FileMetrics(
            path=str(filepath.relative_to(self.project_root)),
            lines_total=total_lines,
            lines_code=code_lines,
            lines_blank=blank_lines,
            lines_comment=comment_lines,
            functions=functions,
            structs=structs,
            tests=tests,
            complexity_score=complexity
        )
    
    def _calculate_complexity(self, content: str) -> int:
        """Calculează un scor de complexitate aproximativ."""
        complexity = 0
        
        # Control flow statements
        complexity += len(re.findall(r'\b(if|else|while|for|switch|return)\b', content))
        
        # Function calls (indică modularity)
        complexity += len(re.findall(r'\w+\(', content)) // 5
        
        # Error handling
        complexity += len(re.findall(r'try\s+|catch\s+|err\s*!=\s*null', content))
        
        return complexity
    
    def analyze_project(self) -> ProjectMetrics:
        """Analizează întregul proiect."""
        zig_files = list(self.project_root.rglob('*.zig'))
        zig_files = [
            f for f in zig_files 
            if not any(part.startswith('.') or part in ['zig-out', '.zig-cache']
                      for part in f.parts)
        ]
        
        for filepath in zig_files:
            metrics = self.analyze_file(filepath)
            if metrics:
                self.file_metrics.append(metrics)
        
        # Calculate totals
        total_lines = sum(f.lines_total for f in self.file_metrics)
        total_code = sum(f.lines_code for f in self.file_metrics)
        total_blank = sum(f.lines_blank for f in self.file_metrics)
        total_comment = sum(f.lines_comment for f in self.file_metrics)
        total_functions = sum(f.functions for f in self.file_metrics)
        total_structs = sum(f.structs for f in self.file_metrics)
        total_tests = sum(f.tests for f in self.file_metrics)
        
        # Find largest files
        largest = sorted(
            [(f.path, f.lines_total) for f in self.file_metrics],
            key=lambda x: x[1],
            reverse=True
        )[:10]
        
        # Calculate ratios
        test_ratio = (total_tests * 10) / total_code if total_code > 0 else 0
        avg_complexity = sum(f.complexity_score for f in self.file_metrics) / len(self.file_metrics) if self.file_metrics else 0
        
        return ProjectMetrics(
            total_files=len(self.file_metrics),
            total_lines=total_lines,
            total_code_lines=total_code,
            total_blank_lines=total_blank,
            total_comment_lines=total_comment,
            total_functions=total_functions,
            total_structs=total_structs,
            total_tests=total_tests,
            avg_file_size=total_lines / len(self.file_metrics) if self.file_metrics else 0,
            largest_files=largest,
            test_to_code_ratio=test_ratio,
            complexity_avg=avg_complexity
        )


def print_metrics(metrics: ProjectMetrics, file_metrics: List[FileMetrics]):
    """Afișează metricile într-un format uman-citibil."""
    GREEN = '\033[92m'
    YELLOW = '\033[93m'
    RED = '\033[91m'
    BLUE = '\033[94m'
    RESET = '\033[0m'
    BOLD = '\033[1m'
    
    print(f"\n{BOLD}╔══════════════════════════════════════════════════════════════╗{RESET}")
    print(f"{BOLD}║              OmniBus Blockchain - Code Metrics               ║{RESET}")
    print(f"{BOLD}╚══════════════════════════════════════════════════════════════╝{RESET}\n")
    
    # Summary
    print(f"  {BOLD}Sumar General:{RESET}\n")
    print(f"    Fișiere .zig:       {BOLD}{metrics.total_files}{RESET}")
    print(f"    Linii totale:       {metrics.total_lines:,}")
    print(f"    Linii de cod:       {GREEN}{metrics.total_code_lines:,}{RESET}")
    print(f"    Linii goale:        {metrics.total_blank_lines:,}")
    print(f"    Linii comentarii:   {YELLOW}{metrics.total_comment_lines:,}{RESET}")
    print(f"    Medie/fișier:       {metrics.avg_file_size:.0f} linii")
    
    # Code components
    print(f"\n  {BOLD}Componente Cod:{RESET}\n")
    print(f"    Funcții:            {metrics.total_functions}")
    print(f"    Structuri:          {metrics.total_structs}")
    print(f"    Teste:              {BLUE}{metrics.total_tests}{RESET}")
    
    # Quality metrics
    print(f"\n  {BOLD}Metrici Calitate:{RESET}\n")
    
    # Test ratio
    ratio_color = GREEN if metrics.test_to_code_ratio > 0.3 else YELLOW if metrics.test_to_code_ratio > 0.1 else RED
    print(f"    Raport test/cod:    {ratio_color}{metrics.test_to_code_ratio:.1%}{RESET}")
    print(f"                       (țintă: >30%, minim: 10%)")
    
    # Comment ratio
    comment_ratio = metrics.total_comment_lines / metrics.total_code_lines if metrics.total_code_lines > 0 else 0
    comment_color = GREEN if comment_ratio > 0.1 else YELLOW
    print(f"    Raport comment/cod: {comment_color}{comment_ratio:.1%}{RESET}")
    
    # Complexity
    print(f"    Complexitate medie: {metrics.complexity_avg:.0f}/fișier")
    
    # Largest files
    print(f"\n  {BOLD}Top 10 Fișiere ca Mărime:{RESET}\n")
    for i, (path, lines) in enumerate(metrics.largest_files, 1):
        color = RED if lines > 1000 else YELLOW if lines > 500 else RESET
        print(f"    {i:2}. {path:45} {color}{lines:5}{RESET} linii")
    
    print()


def print_summary(metrics: ProjectMetrics):
    """Afișează doar sumarul."""
    GREEN = '\033[92m'
    RESET = '\033[0m'
    BOLD = '\033[1m'
    
    print(f"\n  {BOLD}Sumar Rapid:{RESET}")
    print(f"    {metrics.total_files} fișiere, {metrics.total_lines:,} linii, {metrics.total_tests} teste")
    
    ratio = metrics.test_to_code_ratio
    status = "✓" if ratio > 0.3 else "⚠" if ratio > 0.1 else "✗"
    print(f"    Raport test/cod: {ratio:.1%} {status}")
    print()


def main():
    import argparse
    
    parser = argparse.ArgumentParser(
        description='Calculează metrici de cod pentru OmniBus',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Exemple:
  python code_metrics.py              # Metrici complete
  python code_metrics.py --summary    # Doar sumar
  python code_metrics.py --json       # Output JSON
        """
    )
    parser.add_argument('--summary', '-s', action='store_true',
                        help='Doar sumar, nu detalii complete')
    parser.add_argument('--json', action='store_true',
                        help='Output în format JSON')
    parser.add_argument('--top', type=int, default=10,
                        help='Număr fișiere top (default: 10)')
    
    args = parser.parse_args()
    
    # Find project root
    script_dir = Path(__file__).parent
    project_root = script_dir.parent.parent
    
    # Analyze
    analyzer = CodeAnalyzer(project_root)
    metrics = analyzer.analyze_project()
    
    # Output
    if args.json:
        data = {
            'project': asdict(metrics),
            'files': [asdict(f) for f in analyzer.file_metrics]
        }
        print(json.dumps(data, indent=2))
    elif args.summary:
        print_summary(metrics)
    else:
        print_metrics(metrics, analyzer.file_metrics)
    
    # Exit code based on test coverage
    if metrics.test_to_code_ratio < 0.1:
        sys.exit(1)  # Prea puține teste
    sys.exit(0)


if __name__ == '__main__':
    main()
