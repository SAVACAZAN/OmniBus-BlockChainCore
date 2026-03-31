#!/usr/bin/env python3
"""
OmniBus Blockchain - Config Validator
======================================

Validează fișierele de configurare (omnibus.toml, etc.)

Utilizare:
    python config_validator.py              # Validează toate config-urile
    python config_validator.py --file omnibus.toml  # Validare specifică
    python config_validator.py --fix        # Încearcă să repare problemele

Autor: OmniBus AI Collective
Versiune: 1.0.0
"""

import os
import sys
import re
from pathlib import Path
from dataclasses import dataclass, asdict
from typing import List, Dict, Optional, Any, Tuple


@dataclass
class ValidationError:
    """O eroare de validare."""
    file: str
    section: Optional[str]
    key: Optional[str]
    message: str
    severity: str  # error, warning


class TomlValidator:
    """Validator simplu pentru fișiere TOML."""
    
    # Validări specifice pentru omnibus.toml
    OMNIBUS_SCHEMA = {
        'network': {
            'port': {'type': 'int', 'min': 1024, 'max': 65535},
            'host': {'type': 'string'},
        },
        'mining': {
            'enabled': {'type': 'bool'},
            'threads': {'type': 'int', 'min': 0, 'max': 128},
        },
        'database': {
            'path': {'type': 'string'},
            'cache_size_mb': {'type': 'int', 'min': 16, 'max': 4096},
        },
    }
    
    def __init__(self, project_root: Path):
        self.project_root = project_root
        self.errors: List[ValidationError] = []
        
    def parse_toml_simple(self, content: str) -> Dict[str, Any]:
        """Parsează TOML simplu (fără librărie externă)."""
        data = {}
        current_section = None
        
        for line_num, line in enumerate(content.split('\n'), 1):
            line = line.strip()
            
            # Skip empty lines and comments
            if not line or line.startswith('#'):
                continue
            
            # Section
            if line.startswith('[') and line.endswith(']'):
                current_section = line[1:-1].strip()
                if current_section not in data:
                    data[current_section] = {}
                continue
            
            # Key-value pair
            if '=' in line and current_section:
                key, value = line.split('=', 1)
                key = key.strip()
                value = value.strip().split('#')[0].strip()  # Remove inline comments
                
                # Parse value
                parsed_value = self._parse_value(value)
                data[current_section][key] = parsed_value
        
        return data
    
    def _parse_value(self, value: str) -> Any:
        """Parsează o valoare TOML."""
        value = value.strip()
        
        # Boolean
        if value.lower() == 'true':
            return True
        if value.lower() == 'false':
            return False
        
        # Integer
        try:
            return int(value)
        except ValueError:
            pass
        
        # Float
        try:
            return float(value)
        except ValueError:
            pass
        
        # String (remove quotes)
        if (value.startswith('"') and value.endswith('"')) or \
           (value.startswith("'") and value.endswith("'")):
            return value[1:-1]
        
        return value
    
    def validate_omnibus_toml(self, filepath: Path) -> List[ValidationError]:
        """Validează omnibus.toml."""
        errors = []
        
        try:
            with open(filepath, 'r', encoding='utf-8') as f:
                content = f.read()
        except Exception as e:
            errors.append(ValidationError(
                file=str(filepath.name),
                section=None,
                key=None,
                message=f"Nu pot citi fișierul: {e}",
                severity='error'
            ))
            return errors
        
        # Parse
        try:
            data = self.parse_toml_simple(content)
        except Exception as e:
            errors.append(ValidationError(
                file=str(filepath.name),
                section=None,
                key=None,
                message=f"Eroare parsare TOML: {e}",
                severity='error'
            ))
            return errors
        
        # Validate against schema
        for section, keys in self.OMNIBUS_SCHEMA.items():
            if section not in data:
                errors.append(ValidationError(
                    file=str(filepath.name),
                    section=section,
                    key=None,
                    message=f"Secțiune lipsă: [{section}]",
                    severity='warning'
                ))
                continue
            
            for key, rules in keys.items():
                if key not in data[section]:
                    errors.append(ValidationError(
                        file=str(filepath.name),
                        section=section,
                        key=key,
                        message=f"Cheie lipsă: {key}",
                        severity='warning'
                    ))
                    continue
                
                value = data[section][key]
                
                # Type check
                if rules['type'] == 'int' and not isinstance(value, int):
                    errors.append(ValidationError(
                        file=str(filepath.name),
                        section=section,
                        key=key,
                        message=f"Trebuie să fie integer, nu {type(value).__name__}",
                        severity='error'
                    ))
                
                # Range check
                if rules['type'] == 'int' and isinstance(value, int):
                    if 'min' in rules and value < rules['min']:
                        errors.append(ValidationError(
                            file=str(filepath.name),
                            section=section,
                            key=key,
                            message=f"Valoare prea mică: {value} < {rules['min']}",
                            severity='error'
                        ))
                    if 'max' in rules and value > rules['max']:
                        errors.append(ValidationError(
                            file=str(filepath.name),
                            section=section,
                            key=key,
                            message=f"Valoare prea mare: {value} > {rules['max']}",
                            severity='error'
                        ))
        
        # Check file references
        if 'database' in data and 'path' in data['database']:
            db_path = data['database']['path']
            # Check if it's an absolute path or relative
            if not os.path.isabs(db_path):
                db_full_path = self.project_root / db_path
            else:
                db_full_path = Path(db_path)
            
            if not db_full_path.parent.exists():
                errors.append(ValidationError(
                    file=str(filepath.name),
                    section='database',
                    key='path',
                    message=f"Directorul pentru database nu există: {db_full_path.parent}",
                    severity='warning'
                ))
        
        return errors
    
    def validate_all(self) -> List[ValidationError]:
        """Validează toate config-urile."""
        # Check omnibus.toml
        omnibus_toml = self.project_root / 'omnibus.toml'
        if omnibus_toml.exists():
            self.errors.extend(self.validate_omnibus_toml(omnibus_toml))
        else:
            self.errors.append(ValidationError(
                file='omnibus.toml',
                section=None,
                key=None,
                message="Fișierul omnibus.toml nu există!",
                severity='error'
            ))
        
        return self.errors


def print_errors(errors: List[ValidationError]):
    """Afișează erorile."""
    RED = '\033[91m'
    YELLOW = '\033[93m'
    RESET = '\033[0m'
    BOLD = '\033[1m'
    
    if not errors:
        print(f"\n  {GREEN}✓ Toate configurațiile sunt valide!{RESET}\n")
        return
    
    print(f"\n{BOLD}╔══════════════════════════════════════════════════════════════╗{RESET}")
    print(f"{BOLD}║            OmniBus Blockchain - Config Validator             ║{RESET}")
    print(f"{BOLD}╚══════════════════════════════════════════════════════════════╝{RESET}\n")
    
    # Group by file
    by_file = {}
    for error in errors:
        if error.file not in by_file:
            by_file[error.file] = []
        by_file[error.file].append(error)
    
    for filepath, file_errors in by_file.items():
        print(f"  {BOLD}{filepath}{RESET}\n")
        
        for error in file_errors:
            color = RED if error.severity == 'error' else YELLOW
            location = ""
            if error.section:
                location += f"[{error.section}]"
            if error.key:
                location += f".{error.key}"
            
            if location:
                print(f"    [{color}{error.severity.upper()}{RESET}] {location}")
            else:
                print(f"    [{color}{error.severity.upper()}{RESET}]")
            print(f"           {error.message}")
        
        print()


def main():
    import argparse
    
    parser = argparse.ArgumentParser(
        description='Validează configurările OmniBus',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Exemple:
  python config_validator.py              # Validează toate config-urile
  python config_validator.py --json       # Output JSON
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
    
    # Validate
    validator = TomlValidator(project_root)
    errors = validator.validate_all()
    
    # Count by severity
    error_count = sum(1 for e in errors if e.severity == 'error')
    warning_count = sum(1 for e in errors if e.severity == 'warning')
    
    # Output
    if args.quiet:
        sys.exit(0 if error_count == 0 else 1)
    elif args.json:
        print(json.dumps([asdict(e) for e in errors], indent=2))
    else:
        print_errors(errors)
        
        if errors:
            print(f"  Total: {error_count} erori, {warning_count} avertismente\n")
        else:
            GREEN = '\033[92m'
            RESET = '\033[0m'
            print(f"  {GREEN}✓ Configurație validă!{RESET}\n")
    
    sys.exit(0 if error_count == 0 else 1)


if __name__ == '__main__':
    main()
