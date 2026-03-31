#!/usr/bin/env python3
"""
OmniBus Blockchain - Project Health Check
=========================================

Check rapid al stării proiectului pentru AI agents.
Fără dependințe externe - rulează în <1 secundă.

Utilizare:
    python project_health.py
    python project_health.py --json     # Output JSON pentru parsare
    python project_health.py --quiet    # Doar cod de ieșire (0=OK, 1=probleme)

Autor: OmniBus AI Collective
Versiune: 1.0.0
"""

import os
import sys
import subprocess
import json
from pathlib import Path
from dataclasses import dataclass, asdict
from typing import Dict, List, Optional, Tuple


@dataclass
class HealthStatus:
    """Rezultatul verificării stării proiectului."""
    zig_installed: bool = False
    zig_version: str = "unknown"
    zig_min_version: str = "0.15.0"
    zig_version_ok: bool = False
    liboqs_installed: bool = False
    liboqs_path: Optional[str] = None
    files_zig: int = 0
    files_test: int = 0
    constants_count: int = 0
    enums_count: int = 0
    loc_total: int = 0
    loc_tests: int = 0
    build_zig_present: bool = False
    omnibus_toml_present: bool = False
    opcodes_md_present: bool = False
    readme_present: bool = False
    errors: List[str] = None
    warnings: List[str] = None

    def __post_init__(self):
        if self.errors is None:
            self.errors = []
        if self.warnings is None:
            self.warnings = []

    @property
    def is_healthy(self) -> bool:
        """Verifică dacă proiectul e suficient de sănătos pentru lucru."""
        return (
            self.zig_installed and
            self.zig_version_ok and
            self.build_zig_present and
            len(self.errors) == 0
        )


class Colors:
    """Coduri de culoare pentru terminal."""
    RESET = '\033[0m'
    GREEN = '\033[92m'
    YELLOW = '\033[93m'
    RED = '\033[91m'
    BLUE = '\033[94m'
    BOLD = '\033[1m'

    @classmethod
    def disable(cls):
        """Dezactivează culorile (pentru pipe/output non-TTY)."""
        cls.RESET = ''
        cls.GREEN = ''
        cls.YELLOW = ''
        cls.RED = ''
        cls.BLUE = ''
        cls.BOLD = ''


def get_zig_version() -> Tuple[bool, str]:
    """Detectează versiunea Zig instalată."""
    try:
        result = subprocess.run(
            ['zig', 'version'],
            capture_output=True,
            text=True,
            timeout=5
        )
        if result.returncode == 0:
            version = result.stdout.strip()
            return True, version
    except (subprocess.TimeoutExpired, FileNotFoundError):
        pass
    return False, "unknown"


def check_version_meets_min(version: str, min_version: str) -> bool:
    """Verifică dacă versiunea e >= min_version."""
    try:
        v_parts = [int(x) for x in version.split('.')[:2]]
        min_parts = [int(x) for x in min_version.split('.')[:2]]
        return v_parts >= min_parts
    except (ValueError, IndexError):
        return False


def check_liboqs() -> Tuple[bool, Optional[str]]:
    """Verifică dacă liboqs e instalat."""
    # Check common paths
    paths_to_check = [
        Path("C:/Kits work/limaje de programare/liboqs-src/build"),
        Path("/usr/local/lib/liboqs.a"),
        Path("/usr/lib/liboqs.a"),
        Path.home() / "liboqs" / "build",
    ]
    
    for path in paths_to_check:
        if path.exists():
            return True, str(path)
    
    # Check via pkg-config
    try:
        result = subprocess.run(
            ['pkg-config', '--exists', 'liboqs'],
            capture_output=True,
            timeout=2
        )
        if result.returncode == 0:
            return True, "system"
    except (subprocess.TimeoutExpired, FileNotFoundError):
        pass
    
    return False, None


def count_zig_files(root_dir: Path) -> Tuple[int, int, int, int]:
    """Numără fișierele Zig, testele, liniile de cod."""
    zig_count = 0
    test_count = 0
    loc_total = 0
    loc_tests = 0
    constants_count = 0
    enums_count = 0
    
    for filepath in root_dir.rglob('*.zig'):
        # Skip cache și output
        if any(part.startswith('.') or part in ['zig-out', '.zig-cache'] 
               for part in filepath.parts):
            continue
            
        zig_count += 1
        
        try:
            with open(filepath, 'r', encoding='utf-8') as f:
                content = f.read()
                lines = content.split('\n')
                loc_total += len(lines)
                
                # Numără test blocks
                if 'test "' in content or 'test {' in content:
                    test_count += 1
                    loc_tests += len([l for l in lines if l.strip().startswith('test ')])
                
                # Numără constante și enum-uri (aproximativ)
                constants_count += content.count('pub const')
                enums_count += content.count('= enum')
        except Exception:
            pass
    
    return zig_count, test_count, loc_total, loc_tests, constants_count, enums_count


def check_project_structure(root_dir: Path) -> Dict[str, bool]:
    """Verifică structura de bază a proiectului."""
    return {
        'build_zig': (root_dir / 'build.zig').exists(),
        'omnibus_toml': (root_dir / 'omnibus.toml').exists(),
        'opcodes_md': (root_dir / 'claude-kimi-deep-gemini-opcodes' / 'OPCODES.md').exists(),
        'readme': (root_dir / 'README.md').exists(),
        'core_dir': (root_dir / 'core').exists(),
        'test_dir': (root_dir / 'test').exists(),
    }


def analyze_project(root_dir: Path) -> HealthStatus:
    """Analizează starea completă a proiectului."""
    status = HealthStatus()
    
    # Check Zig
    status.zig_installed, status.zig_version = get_zig_version()
    if status.zig_installed:
        status.zig_version_ok = check_version_meets_min(
            status.zig_version, 
            status.zig_min_version
        )
    else:
        status.errors.append("Zig nu este instalat sau nu e în PATH")
    
    # Check liboqs
    status.liboqs_installed, status.liboqs_path = check_liboqs()
    if not status.liboqs_installed:
        status.warnings.append("liboqs nu e detectat (opțional, doar pentru PQ crypto)")
    
    # Count files and LOC
    (
        status.files_zig,
        status.files_test,
        status.loc_total,
        status.loc_tests,
        status.constants_count,
        status.enums_count
    ) = count_zig_files(root_dir)
    
    # Check structure
    structure = check_project_structure(root_dir)
    status.build_zig_present = structure['build_zig']
    status.omnibus_toml_present = structure['omnibus_toml']
    status.opcodes_md_present = structure['opcodes_md']
    status.readme_present = structure['readme']
    
    if not status.build_zig_present:
        status.errors.append("Lipsește build.zig - proiectul nu poate fi compilat")
    
    return status


def print_status(status: HealthStatus, use_colors: bool = True):
    """Afișează starea într-un format uman-citibil."""
    if not use_colors:
        Colors.disable()
    
    c = Colors
    
    print(f"\n{c.BOLD}╔══════════════════════════════════════════════════════════════╗{c.RESET}")
    print(f"{c.BOLD}║        OmniBus Blockchain - Project Health Check             ║{c.RESET}")
    print(f"{c.BOLD}╚══════════════════════════════════════════════════════════════╝{c.RESET}\n")
    
    # Zig status
    zig_color = c.GREEN if status.zig_version_ok else c.RED
    if not status.zig_installed:
        zig_color = c.RED
        print(f"  [{c.RED}FAIL{c.RESET}] Zig: {c.RED}NU este instalat{c.RESET}")
    else:
        version_status = "OK" if status.zig_version_ok else f"necesită >= {status.zig_min_version}"
        print(f"  [{zig_color}{'OK' if status.zig_version_ok else 'WARN'}{c.RESET}] Zig: {status.zig_version} {version_status}")
    
    # liboqs
    if status.liboqs_installed:
        print(f"  [{c.GREEN}OK{c.RESET}] liboqs: {c.GREEN}detectat{c.RESET} ({status.liboqs_path})")
    else:
        print(f"  [{c.YELLOW}OPT{c.RESET}] liboqs: {c.YELLOW}opțional, nu e detectat{c.RESET}")
    
    # Files
    print(f"\n  {c.BOLD}Cod:{c.RESET}")
    print(f"  [{c.GREEN}OK{c.RESET}] Fișiere .zig: {status.files_zig}")
    print(f"  [{c.GREEN}OK{c.RESET}] Fișiere cu teste: {status.files_test}")
    print(f"  [{c.GREEN}OK{c.RESET}] Linii de cod: {status.loc_total:,}")
    print(f"  [{c.GREEN}OK{c.RESET}] Linii de test: {status.loc_tests:,}")
    print(f"  [{c.GREEN}OK{c.RESET}] Constante: {status.constants_count}")
    print(f"  [{c.GREEN}OK{c.RESET}] Enums: {status.enums_count}")
    
    # Structure
    print(f"\n  {c.BOLD}Structură:{c.RESET}")
    struct_color = c.GREEN if status.build_zig_present else c.RED
    print(f"  [{struct_color}{'OK' if status.build_zig_present else 'FAIL'}{c.RESET}] build.zig")
    
    struct_color = c.GREEN if status.omnibus_toml_present else c.YELLOW
    print(f"  [{struct_color}{'OK' if status.omnibus_toml_present else 'WARN'}{c.RESET}] omnibus.toml")
    
    struct_color = c.GREEN if status.opcodes_md_present else c.YELLOW
    print(f"  [{struct_color}{'OK' if status.opcodes_md_present else 'WARN'}{c.RESET}] OPCODES.md")
    
    struct_color = c.GREEN if status.readme_present else c.YELLOW
    print(f"  [{struct_color}{'OK' if status.readme_present else 'WARN'}{c.RESET}] README.md")
    
    # Errors
    if status.errors:
        print(f"\n  {c.BOLD}{c.RED}ERORI ({len(status.errors)}):{c.RESET}")
        for error in status.errors:
            print(f"    {c.RED}•{c.RESET} {error}")
    
    # Warnings
    if status.warnings:
        print(f"\n  {c.BOLD}{c.YELLOW}AVERTISMENTE ({len(status.warnings)}):{c.RESET}")
        for warning in status.warnings:
            print(f"    {c.YELLOW}•{c.RESET} {warning}")
    
    # Summary
    print(f"\n  {c.BOLD}{'═' * 60}{c.RESET}")
    if status.is_healthy:
        print(f"  {c.GREEN}{c.BOLD}STATUS: PROIECT SĂNĂTOS ✓{c.RESET}")
        print(f"  {c.GREEN}Poți începe să lucrezi pe acest proiect.{c.RESET}")
    else:
        print(f"  {c.RED}{c.BOLD}STATUS: PROBLEME DETECTATE ✗{c.RESET}")
        print(f"  {c.RED}Rezolvă erorile de mai sus înainte de a continua.{c.RESET}")
    print(f"  {c.BOLD}{'═' * 60}{c.RESET}\n")


def main():
    import argparse
    
    parser = argparse.ArgumentParser(
        description='Verificare rapidă starea proiectului OmniBus Blockchain',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Exemple:
  python project_health.py              # Verificare standard
  python project_health.py --json       # Output JSON
  python project_health.py --quiet      # Doar cod de ieșire
  python project_health.py --no-color   # Fără culori
        """
    )
    parser.add_argument('--json', action='store_true',
                        help='Output în format JSON')
    parser.add_argument('--quiet', '-q', action='store_true',
                        help='Doar cod de ieșire (0=sănătos, 1=probleme)')
    parser.add_argument('--no-color', action='store_true',
                        help='Dezactivează culorile în output')
    
    args = parser.parse_args()
    
    # Find project root
    script_dir = Path(__file__).parent
    project_root = script_dir.parent.parent
    
    # Analyze
    status = analyze_project(project_root)
    
    # Output
    if args.quiet:
        sys.exit(0 if status.is_healthy else 1)
    elif args.json:
        print(json.dumps(asdict(status), indent=2))
    else:
        use_colors = not args.no_color and sys.stdout.isatty()
        print_status(status, use_colors)
    
    sys.exit(0 if status.is_healthy else 1)


if __name__ == '__main__':
    main()
