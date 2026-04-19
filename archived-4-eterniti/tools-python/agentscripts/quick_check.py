#!/usr/bin/env python3
"""
OmniBus Blockchain - Quick Check
=================================

Verificare rapidă sintaxă + build. Ideal pentru verificare înainte de commit.
Rulează în 2-5 secunde.

Utilizare:
    python quick_check.py              # Check complet
    python quick_check.py --syntax     # Doar sintaxă
    python quick_check.py --build      # Doar build rapid
    python quick_check.py --test       # Doar teste de bază

Autor: OmniBus AI Collective
Versiune: 1.0.0
"""

import os
import sys
import subprocess
import time
from pathlib import Path
from dataclasses import dataclass, field
from typing import List, Tuple, Optional
from concurrent.futures import ThreadPoolExecutor, as_completed


@dataclass
class CheckResult:
    """Rezultatul unei verificări."""
    name: str
    passed: bool
    duration_ms: float
    output: str = ""
    error: str = ""
    details: List[str] = field(default_factory=list)


class QuickChecker:
    """Execută verificări rapide pe proiect."""
    
    def __init__(self, project_root: Path):
        self.project_root = project_root
        self.results: List[CheckResult] = []
        
    def run_command(self, cmd: List[str], timeout: int = 30) -> Tuple[bool, str, str]:
        """Execută o comandă și returnează rezultatul."""
        try:
            result = subprocess.run(
                cmd,
                cwd=self.project_root,
                capture_output=True,
                text=True,
                timeout=timeout
            )
            return result.returncode == 0, result.stdout, result.stderr
        except subprocess.TimeoutExpired:
            return False, "", "Timeout"
        except FileNotFoundError as e:
            return False, "", f"Comandă negăsită: {e}"
    
    def check_syntax(self) -> CheckResult:
        """Verifică sintaxa Zig cu zig fmt --check."""
        start = time.time()
        
        # Găsește toate fișierele .zig
        zig_files = list(self.project_root.rglob('*.zig'))
        zig_files = [f for f in zig_files 
                     if not any(part.startswith('.') or part in ['zig-out', '.zig-cache']
                               for part in f.parts)]
        
        passed_count = 0
        failed_files = []
        
        for filepath in zig_files:
            ok, stdout, stderr = self.run_command(
                ['zig', 'fmt', '--check', str(filepath)],
                timeout=5
            )
            if ok and not stderr:
                passed_count += 1
            else:
                failed_files.append(filepath.name)
        
        duration = (time.time() - start) * 1000
        
        return CheckResult(
            name="Sintaxă Zig",
            passed=passed_count == len(zig_files),
            duration_ms=duration,
            details=[f"{passed_count}/{len(zig_files)} fișiere OK"] + 
                    ([f"Failed: {', '.join(failed_files[:3])}"] if failed_files else [])
        )
    
    def check_build(self) -> CheckResult:
        """Încearcă build rapid fără liboqs."""
        start = time.time()
        
        ok, stdout, stderr = self.run_command(
            ['zig', 'build', '-Doqs=false'],
            timeout=60
        )
        
        duration = (time.time() - start) * 1000
        
        # Parse output pentru a găsi erori
        errors = []
        if stderr:
            for line in stderr.split('\n'):
                if 'error:' in line.lower():
                    errors.append(line.strip())
        
        return CheckResult(
            name="Build (fără liboqs)",
            passed=ok,
            duration_ms=duration,
            output=stdout[-500:] if stdout else "",  # Ultimele 500 caractere
            error=stderr[-500:] if stderr else "",
            details=[f"{len(errors)} erori"] if errors else ["Build reușit"]
        )
    
    def check_tests_crypto(self) -> CheckResult:
        """Rulează testele de crypto (cele mai rapide)."""
        start = time.time()
        
        ok, stdout, stderr = self.run_command(
            ['zig', 'build', 'test-crypto', '-Doqs=false'],
            timeout=45
        )
        
        duration = (time.time() - start) * 1000
        
        # Parse pentru a număra teste
        passed = 0
        failed = 0
        for line in (stdout + stderr).split('\n'):
            if 'passed' in line.lower():
                try:
                    # Format: "X passed, Y failed"
                    parts = line.split(',')
                    for part in parts:
                        if 'passed' in part:
                            passed = int(part.strip().split()[0])
                        if 'failed' in part:
                            failed = int(part.strip().split()[0])
                except (ValueError, IndexError):
                    pass
        
        return CheckResult(
            name="Teste Crypto",
            passed=ok and failed == 0,
            duration_ms=duration,
            output=stdout[-300:] if stdout else "",
            details=[f"{passed} passed, {failed} failed"] if passed or failed else ["Status necunoscut"]
        )
    
    def check_tests_chain(self) -> CheckResult:
        """Rulează testele de chain."""
        start = time.time()
        
        ok, stdout, stderr = self.run_command(
            ['zig', 'build', 'test-chain', '-Doqs=false'],
            timeout=45
        )
        
        duration = (time.time() - start) * 1000
        
        return CheckResult(
            name="Teste Chain",
            passed=ok,
            duration_ms=duration,
            output=stdout[-200:] if stdout else "",
            details=["Complete"] if ok else ["Au picat teste"]
        )
    
    def run_all(self, checks_to_run: List[str] = None) -> List[CheckResult]:
        """Rulează toate verificările."""
        all_checks = {
            'syntax': self.check_syntax,
            'build': self.check_build,
            'test-crypto': self.check_tests_crypto,
            'test-chain': self.check_tests_chain,
        }
        
        if checks_to_run:
            checks = {k: v for k, v in all_checks.items() if k in checks_to_run}
        else:
            checks = all_checks
        
        # Rulează în paralel pentru viteză
        with ThreadPoolExecutor(max_workers=2) as executor:
            futures = {executor.submit(fn()): name for name, fn in checks.items()}
            
            for future in as_completed(futures):
                result = future.result()
                self.results.append(result)
        
        # Sortează după ordinea originală
        order = ['syntax', 'build', 'test-crypto', 'test-chain']
        self.results.sort(key=lambda r: order.index(next(
            (k for k, v in all_checks.items() if v.__name__ in r.name.lower().replace(' ', '_')), 
            0
        )))
        
        return self.results


def print_results(results: List[CheckResult]):
    """Afișează rezultatele."""
    GREEN = '\033[92m'
    RED = '\033[91m'
    YELLOW = '\033[93m'
    RESET = '\033[0m'
    BOLD = '\033[1m'
    
    print(f"\n{BOLD}╔══════════════════════════════════════════════════════════════╗{RESET}")
    print(f"{BOLD}║              OmniBus Blockchain - Quick Check                ║{RESET}")
    print(f"{BOLD}╚══════════════════════════════════════════════════════════════╝{RESET}\n")
    
    total_time = 0
    all_passed = True
    
    for result in results:
        status = f"{GREEN}✓{RESET}" if result.passed else f"{RED}✗{RESET}"
        print(f"  [{status}] {result.name:20} {result.duration_ms:6.0f}ms", end="")
        
        if result.details:
            print(f"  ({result.details[0]})")
        else:
            print()
        
        if not result.passed:
            all_passed = False
            if result.error:
                error_lines = result.error.strip().split('\n')[-3:]  # Ultimele 3 linii
                for line in error_lines:
                    print(f"       {RED}{line}{RESET}")
        
        total_time += result.duration_ms
    
    print(f"\n  {'─' * 60}")
    print(f"  Timp total: {total_time/1000:.1f}s")
    
    if all_passed:
        print(f"\n  {GREEN}{BOLD}✓ TOATE VERIFICĂRILE AU TRECUT{RESET}")
    else:
        print(f"\n  {RED}{BOLD}✗ AU PICAT VERIFICĂRI{RESET}")
    
    print()


def main():
    import argparse
    
    parser = argparse.ArgumentParser(
        description='Verificare rapidă sintaxă + build',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Exemple:
  python quick_check.py              # Toate verificările
  python quick_check.py --syntax     # Doar sintaxă
  python quick_check.py --build      # Doar build
  python quick_check.py --test       # Doar teste
        """
    )
    parser.add_argument('--syntax', action='store_true',
                        help='Doar verificare sintaxă')
    parser.add_argument('--build', action='store_true',
                        help='Doar build')
    parser.add_argument('--test', action='store_true',
                        help='Doar teste')
    parser.add_argument('--no-color', action='store_true',
                        help='Fără culori')
    
    args = parser.parse_args()
    
    if args.no_color:
        # Dezactivează culorile
        import builtins
        builtins.print = lambda *args, **kwargs: __builtins__['print'](*[
            str(arg).replace('\033[92m', '').replace('\033[91m', '')
                     .replace('\033[93m', '').replace('\033[0m', '')
                     .replace('\033[1m', '')
            for arg in args
        ], **kwargs)
    
    # Determine which checks to run
    specific_checks = []
    if args.syntax:
        specific_checks.append('syntax')
    if args.build:
        specific_checks.append('build')
    if args.test:
        specific_checks.extend(['test-crypto', 'test-chain'])
    
    # Find project root
    script_dir = Path(__file__).parent
    project_root = script_dir.parent.parent
    
    print("\n  [INFO] Rulează verificări... (poate dura 10-30 secunde)\n")
    
    # Run checks
    checker = QuickChecker(project_root)
    results = checker.run_all(specific_checks if specific_checks else None)
    
    # Print results
    print_results(results)
    
    # Exit code
    all_passed = all(r.passed for r in results)
    sys.exit(0 if all_passed else 1)


if __name__ == '__main__':
    main()
