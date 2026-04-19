#!/usr/bin/env python3
"""
OmniBus Blockchain - Dependency Check
======================================

Verifică dependințele externe necesare pentru build și rulare.

Utilizare:
    python dependency_check.py              # Verificare completă
    python dependency_check.py --fix        # Încearcă să rezolve problemele
    python dependency_check.py --json       # Output JSON

Autor: OmniBus AI Collective
Versiune: 1.0.0
"""

import os
import sys
import subprocess
import shutil
from pathlib import Path
from dataclasses import dataclass, asdict
from typing import List, Dict, Optional, Tuple


@dataclass
class Dependency:
    """O dependință de verificat."""
    name: str
    command: str
    min_version: Optional[str]
    required: bool
    install_help: str


@dataclass
class CheckResult:
    """Rezultatul verificării unei dependințe."""
    dependency: Dependency
    installed: bool
    version: Optional[str]
    version_ok: bool
    path: Optional[str]


class DependencyChecker:
    """Verifică dependințele proiectului."""
    
    DEPENDENCIES = [
        Dependency(
            name='Zig',
            command='zig',
            min_version='0.15.0',
            required=True,
            install_help='https://ziglang.org/download/ sau "choco install zig" pe Windows'
        ),
        Dependency(
            name='Python',
            command='python',
            min_version='3.8.0',
            required=True,
            install_help='https://python.org sau "choco install python"'
        ),
        Dependency(
            name='Git',
            command='git',
            min_version=None,
            required=True,
            install_help='https://git-scm.com sau "choco install git"'
        ),
    ]
    
    def __init__(self, project_root: Path):
        self.project_root = project_root
        self.results: List[CheckResult] = []
        
    def check_command(self, cmd: str) -> Tuple[bool, Optional[str]]:
        """Verifică dacă o comandă există și ia versiunea."""
        # Check if command exists
        if shutil.which(cmd) is None:
            return False, None
        
        # Try to get version
        version_args = ['--version', '-v', '-V', 'version']
        
        for arg in version_args:
            try:
                result = subprocess.run(
                    [cmd, arg],
                    capture_output=True,
                    text=True,
                    timeout=5
                )
                if result.returncode == 0:
                    output = result.stdout.strip() or result.stderr.strip()
                    # Extract first version-like string
                    import re
                    version_match = re.search(r'(\d+\.\d+\.?\d*)', output)
                    if version_match:
                        return True, version_match.group(1)
            except:
                pass
        
        return True, "unknown"
    
    def check_version_meets_min(self, version: str, min_version: str) -> bool:
        """Verifică dacă versiunea >= min_version."""
        try:
            v_parts = [int(x) for x in version.split('.')[:3]]
            min_parts = [int(x) for x in min_version.split('.')[:3]]
            
            # Pad with zeros
            while len(v_parts) < 3:
                v_parts.append(0)
            while len(min_parts) < 3:
                min_parts.append(0)
            
            return v_parts >= min_parts
        except (ValueError, IndexError):
            return True  # If we can't parse, assume OK
    
    def check_liboqs(self) -> CheckResult:
        """Verifică liboqs separat (opțional)."""
        dep = Dependency(
            name='liboqs',
            command='',
            min_version=None,
            required=False,
            install_help='https://github.com/open-quantum-safe/liboqs'
        )
        
        # Check common paths
        paths = [
            Path("C:/Kits work/limaje de programare/liboqs-src/build"),
            Path("/usr/local/lib/liboqs.a"),
            Path("/usr/lib/liboqs.a"),
        ]
        
        for path in paths:
            if path.exists():
                return CheckResult(
                    dependency=dep,
                    installed=True,
                    version=None,
                    version_ok=True,
                    path=str(path)
                )
        
        return CheckResult(
            dependency=dep,
            installed=False,
            version=None,
            version_ok=False,
            path=None
        )
    
    def check_ports(self) -> List[Tuple[int, bool]]:
        """Verifică dacă porturile necesare sunt libere."""
        import socket
        
        ports = [8332, 8333, 8334, 9000]
        results = []
        
        for port in ports:
            sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            sock.settimeout(1)
            result = sock.connect_ex(('127.0.0.1', port))
            sock.close()
            results.append((port, result != 0))  # True if free
        
        return results
    
    def check_all(self) -> List[CheckResult]:
        """Verifică toate dependințele."""
        for dep in self.DEPENDENCIES:
            installed, version = self.check_command(dep.command)
            
            version_ok = True
            if installed and version and dep.min_version:
                version_ok = self.check_version_meets_min(version, dep.min_version)
            
            self.results.append(CheckResult(
                dependency=dep,
                installed=installed,
                version=version,
                version_ok=version_ok,
                path=shutil.which(dep.command) if installed else None
            ))
        
        # Check liboqs separately
        self.results.append(self.check_liboqs())
        
        return self.results
    
    def all_required_ok(self) -> bool:
        """Verifică dacă toate dependințele required sunt OK."""
        for result in self.results:
            if result.dependency.required and not result.installed:
                return False
            if result.dependency.required and not result.version_ok:
                return False
        return True


def print_results(results: List[CheckResult], ports: List[Tuple[int, bool]]):
    """Afișează rezultatele."""
    GREEN = '\033[92m'
    RED = '\033[91m'
    YELLOW = '\033[93m'
    RESET = '\033[0m'
    BOLD = '\033[1m'
    
    print(f"\n{BOLD}╔══════════════════════════════════════════════════════════════╗{RESET}")
    print(f"{BOLD}║           OmniBus Blockchain - Dependency Check              ║{RESET}")
    print(f"{BOLD}╚══════════════════════════════════════════════════════════════╝{RESET}\n")
    
    print(f"  {BOLD}Dependințe:{RESET}\n")
    
    for result in results:
        status = f"{GREEN}✓{RESET}" if result.installed else f"{RED}✗{RESET}"
        
        if result.dependency.required:
            req_marker = f"{RED}*required{RESET}"
        else:
            req_marker = f"{YELLOW}optional{RESET}"
        
        print(f"    [{status}] {result.dependency.name:15} {req_marker:12}", end="")
        
        if result.installed:
            version_str = result.version or "unknown"
            if result.dependency.min_version and not result.version_ok:
                print(f" {YELLOW}{version_str} (need >= {result.dependency.min_version}){RESET}")
            else:
                print(f" {GREEN}{version_str}{RESET}")
        else:
            print(f" {RED}NOT INSTALLED{RESET}")
            print(f"           Help: {result.dependency.install_help}")
    
    # Ports
    print(f"\n  {BOLD}Porturi:{RESET}\n")
    for port, is_free in ports:
        status = f"{GREEN}✓ FREE{RESET}" if is_free else f"{RED}✗ IN USE{RESET}"
        service = {8332: 'RPC', 8333: 'P2P', 8334: 'WebSocket', 9000: 'P2P Alt'}.get(port, '?')
        print(f"    [{status}] Port {port:4} ({service})")
    
    print()


def main():
    import argparse
    
    parser = argparse.ArgumentParser(
        description='Verifică dependințele OmniBus',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Exemple:
  python dependency_check.py              # Verificare completă
  python dependency_check.py --json       # Output JSON
        """
    )
    parser.add_argument('--json', action='store_true',
                        help='Output JSON')
    parser.add_argument('--quiet', '-q', action='store_true',
                        help='Doar cod de ieșire')
    
    args = parser.parse_args()
    
    # Find project root
    script_dir = Path(__file__).parent
    project_root = script_dir.parent.parent
    
    # Check
    checker = DependencyChecker(project_root)
    results = checker.check_all()
    ports = checker.check_ports()
    
    # Output
    if args.quiet:
        sys.exit(0 if checker.all_required_ok() else 1)
    elif args.json:
        data = {
            'dependencies': [
                {
                    'name': r.dependency.name,
                    'installed': r.installed,
                    'version': r.version,
                    'required': r.dependency.required,
                }
                for r in results
            ],
            'ports': [{'port': p, 'free': f} for p, f in ports],
            'all_ok': checker.all_required_ok()
        }
        print(json.dumps(data, indent=2))
    else:
        print_results(results, ports)
        
        if checker.all_required_ok():
            print(f"  {GREEN}{BOLD}✓ Toate dependințele required sunt instalate!{RESET}\n")
        else:
            print(f"  {RED}{BOLD}✗ Lipsesc dependințe required!{RESET}\n")
            print(f"  Vezi mai sus pentru instrucțiuni de instalare.\n")
    
    sys.exit(0 if checker.all_required_ok() else 1)


if __name__ == '__main__':
    main()
