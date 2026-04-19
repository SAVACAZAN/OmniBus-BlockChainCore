#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
OmniBus Blockchain - Opcode Scanner
====================================

Scaneaza intregul codebase Zig pentru a detecta automat:
- Constants (pub const NAME = value)
- Enums si variantele lor
- Message types
- Error codes
- Magic numbers

Actualizeaza automat fisierul OPCODES.md cu informatiile noi.

Utilizare:
    python scan_opcodes.py
    python scan_opcodes.py --update  # Actualizeaza OPCODES.md
    python scan_opcodes.py --diff    # Arata diferentele fara a modifica
    python scan_opcodes.py --output opcodes_nou.md  # Output in alt fisier

Autor: OmniBus AI Collective
Versiune: 1.0.0
"""

import os
import re
import sys
import argparse
from datetime import datetime
from pathlib import Path
from typing import Dict, List, Tuple, Optional, Set
from dataclasses import dataclass, field
from collections import defaultdict


@dataclass
class Constant:
    """Reprezintă o constantă din codul Zig."""
    name: str
    value: str
    file: str
    line: int
    context: str = ""  # Comentariu deasupra sau pe aceeași linie
    is_public: bool = False


@dataclass
class EnumVariant:
    """Reprezintă o variantă de enum."""
    name: str
    value: Optional[str]
    description: str = ""


@dataclass
class EnumDef:
    """Reprezintă un enum complet."""
    name: str
    variants: List[EnumVariant]
    file: str
    line: int
    is_public: bool = False


@dataclass
class OpcodeScanResult:
    """Rezultatul complet al scanării."""
    constants: List[Constant] = field(default_factory=list)
    enums: List[EnumDef] = field(default_factory=list)
    message_types: List[Tuple[str, int, str]] = field(default_factory=list)
    error_types: List[Tuple[str, str]] = field(default_factory=list)
    magic_numbers: List[Tuple[str, str, str]] = field(default_factory=list)


class ZigParser:
    """Parser pentru fișiere Zig."""
    
    # Regex patterns pentru extragere
    CONST_PATTERN = re.compile(
        r'^\s*(pub\s+)?const\s+(\w+)\s*[:=]\s*([^;]+)(?:;|$)',
        re.MULTILINE
    )
    
    ENUM_PATTERN = re.compile(
        r'(?:pub\s+)?const\s+(\w+)\s*=\s*enum\s*\{([^}]+)\}',
        re.DOTALL
    )
    
    INLINE_ENUM_PATTERN = re.compile(
        r'pub\s+const\s+(\w+)\s*=\s*enum\s*\(\s*\w+\s*\)\s*\{([^}]+)\}',
        re.DOTALL
    )
    
    COMMENT_PATTERN = re.compile(r'//(.+)$', re.MULTILINE)
    
    def __init__(self, content: str, filename: str):
        self.content = content
        self.filename = filename
        self.lines = content.split('\n')
        
    def get_line_context(self, line_num: int) -> str:
        """Ia comentariul deasupra unei linii sau de pe aceeași linie."""
        context = []
        
        # Comentariu pe aceeași linie
        same_line_match = self.COMMENT_PATTERN.search(self.lines[line_num - 1])
        if same_line_match:
            context.append(same_line_match.group(1).strip())
        
        # Comentariu deasupra (până la 3 linii)
        for i in range(line_num - 2, max(0, line_num - 5), -1):
            line = self.lines[i].strip()
            if line.startswith('//'):
                context.insert(0, line[2:].strip())
            elif line.startswith('///'):
                context.insert(0, line[3:].strip())
            elif line and not line.startswith('//'):
                break
                
        return ' '.join(context)
    
    def parse_constants(self) -> List[Constant]:
        """Extrage toate constantele simple din fișier (fără structuri complexe)."""
        constants = []
        
        for match in self.CONST_PATTERN.finditer(self.content):
            is_pub = match.group(1) is not None
            name = match.group(2)
            value = match.group(3).strip()
            
            # Skip structuri, union-uri și tipuri complexe
            if self._is_simple_constant(value):
                # Găsește numărul liniei
                line_num = self.content[:match.start()].count('\n') + 1
                context = self.get_line_context(line_num)
                
                # Trunchiază valori foarte lungi
                if len(value) > 100:
                    value = value[:97] + "..."
                
                constants.append(Constant(
                    name=name,
                    value=value,
                    file=self.filename,
                    line=line_num,
                    context=context,
                    is_public=is_pub
                ))
            
        return constants
    
    def _is_simple_constant(self, value: str) -> bool:
        """Verifică dacă valoarea este o constantă simplă (nu structură)."""
        value = value.strip()
        
        # Liste de cuvinte cheie care indică tipuri complexe
        complex_keywords = [
            'struct {', 'union {', 'enum {', 'packed struct',
            'extern struct', 'opaque', 'fn (', '= .{', '=.{',
            'std.', 'ArrayList', 'HashMap', 'Managed('
        ]
        
        for keyword in complex_keywords:
            if keyword in value:
                return False
        
        # Acceptă numere, string-uri, arrays simple
        return True
    
    def parse_enums(self) -> List[EnumDef]:
        """Extrage toate enum-urile din fișier."""
        enums = []
        
        # Pattern 1: const Name = enum { ... }
        for match in self.ENUM_PATTERN.finditer(self.content):
            name = match.group(1)
            body = match.group(2)
            line_num = self.content[:match.start()].count('\n') + 1
            
            variants = self._parse_enum_body(body)
            enums.append(EnumDef(
                name=name,
                variants=variants,
                file=self.filename,
                line=line_num
            ))
            
        # Pattern 2: pub const Name = enum(u8) { ... }
        for match in self.INLINE_ENUM_PATTERN.finditer(self.content):
            name = match.group(1)
            body = match.group(2)
            line_num = self.content[:match.start()].count('\n') + 1
            
            variants = self._parse_enum_body(body)
            enums.append(EnumDef(
                name=name,
                variants=variants,
                file=self.filename,
                line=line_num,
                is_public=True
            ))
            
        return enums
    
    def _parse_enum_body(self, body: str) -> List[EnumVariant]:
        """Parsează corpul unui enum."""
        variants = []
        lines = body.split('\n')
        auto_value = 0
        
        for line in lines:
            line = line.strip()
            if not line or line.startswith('//'):
                continue
                
            # Pattern: Name = value,
            if '=' in line:
                parts = line.split('=', 1)
                name = parts[0].strip()
                value_part = parts[1].split(',')[0].strip()
                comment = parts[1].split('//')[1].strip() if '//' in parts[1] else ""
                
                try:
                    auto_value = int(value_part)
                except ValueError:
                    pass
                    
                variants.append(EnumVariant(
                    name=name,
                    value=value_part,
                    description=comment
                ))
            else:
                # Pattern: Name,
                name = line.rstrip(',').strip()
                if name:
                    variants.append(EnumVariant(
                        name=name,
                        value=str(auto_value),
                        description=""
                    ))
                    auto_value += 1
                    
        return variants


class OpcodeScanner:
    """Scanner pentru întregul proiect."""
    
    def __init__(self, root_dir: str):
        self.root_dir = Path(root_dir)
        self.results = OpcodeScanResult()
        
        # Fișiere și directoare de exclus
        self.excluded_dirs = {'.git', '.zig-cache', 'zig-out', 'claude-kimi-deep-gemini-opcodes'}
        self.excluded_files = {'scan_opcodes.py', 'OPCODES.md'}
        
    def should_scan_file(self, filepath: Path) -> bool:
        """Verifică dacă un fișier trebuie scanat."""
        if filepath.name in self.excluded_files:
            return False
        if filepath.suffix != '.zig':
            return False
        for part in filepath.parts:
            if part in self.excluded_dirs:
                return False
        return True
    
    def scan_file(self, filepath: Path) -> None:
        """Scanează un singur fișier."""
        try:
            with open(filepath, 'r', encoding='utf-8') as f:
                content = f.read()
                
            rel_path = str(filepath.relative_to(self.root_dir))
            parser = ZigParser(content, rel_path)
            
            # Parsează constante
            self.results.constants.extend(parser.parse_constants())
            
            # Parsează enums
            self.results.enums.extend(parser.parse_enums())
            
        except Exception as e:
            print(f"[ERROR] Eroare la scanarea {filepath}: {e}", file=sys.stderr)
    
    def scan(self) -> OpcodeScanResult:
        """Scanează întregul proiect."""
        print(f"[SCAN] Scanam directorul: {self.root_dir}")
        
        zig_files = list(self.root_dir.rglob('*.zig'))
        print(f"[FOUND] Gasite {len(zig_files)} fisiere .zig")
        
        scanned = 0
        for filepath in zig_files:
            if self.should_scan_file(filepath):
                self.scan_file(filepath)
                scanned += 1
                
        print(f"[OK] Scanate {scanned} fisiere")
        
        # Procesează rezultatele pentru a extrage tipuri speciale
        self._extract_message_types()
        self._extract_error_types()
        self._extract_magic_numbers()
        
        return self.results
    
    def _extract_message_types(self) -> None:
        """Extrage MessageType enum."""
        for enum in self.results.enums:
            if 'MessageType' in enum.name or 'MsgType' in enum.name:
                for i, variant in enumerate(enum.variants):
                    desc = variant.description if variant.description else f"Message type {variant.name}"
                    self.results.message_types.append((
                        variant.name,
                        i,
                        desc
                    ))
    
    def _extract_error_types(self) -> None:
        """Extrage tipurile de erori."""
        error_enums = [e for e in self.results.enums if 'Error' in e.name]
        for enum in error_enums:
            for variant in enum.variants:
                self.results.error_types.append((
                    enum.name,
                    variant.name
                ))
    
    def _extract_magic_numbers(self) -> None:
        """Extrage magic numbers (numere cu semnificație specială)."""
        magic_patterns = [
            (r'PORT.*=\s*(\d+)', 'Port'),
            (r'MAX.*=\s*(\d+)', 'Maximum'),
            (r'MIN.*=\s*(\d+)', 'Minimum'),
            (r'TIMEOUT.*=\s*(\d+)', 'Timeout'),
            (r'INTERVAL.*=\s*(\d+)', 'Interval'),
            (r'_MS\s*=\s*(\d+)', 'Milliseconds'),
            (r'_SEC\s*=\s*(\d+)', 'Seconds'),
        ]
        
        for const in self.results.constants:
            for pattern, category in magic_patterns:
                if re.search(pattern, const.name, re.IGNORECASE):
                    self.results.magic_numbers.append((
                        const.name,
                        const.value,
                        category
                    ))
                    break


class MarkdownGenerator:
    """Generează fișierul OPCODES.md actualizat."""
    
    def __init__(self, results: OpcodeScanResult):
        self.results = results
        
    def generate(self) -> str:
        """Generează conținutul complet al fișierului."""
        lines = []
        
        # Header
        lines.extend(self._generate_header())
        
        # Conținut existent (păstrăm structura)
        # Aici ar trebui să citim OPCODES.md existent și să actualizăm doar secțiunile relevante
        # Pentru simplitate, generăm un fișier cu toate constantele descoperite
        
        lines.extend(self._generate_constants_section())
        lines.extend(self._generate_enums_section())
        lines.extend(self._generate_message_types_section())
        lines.extend(self._generate_magic_numbers_section())
        lines.extend(self._generate_footer())
        
        return '\n'.join(lines)
    
    def _generate_header(self) -> List[str]:
        """Generează header-ul."""
        now = datetime.now().strftime('%Y-%m-%d %H:%M:%S')
        return [
            "# OmniBus Blockchain - OPCODES & CONSTANTS REFERENCE",
            "",
            "> **Scop:** Referință centralizată pentru toate opcodurile, constantele, enum-urile și codurile de mesaje.",
            f"> **Generat automat la:** {now}",
            "> **Scanat de:** scan_opcodes.py",
            "",
            "---",
            "",
            "## ⚠️ NOTĂ",
            "",
            "Acest document este generat automat de `scan_opcodes.py`.",
            "Pentru a actualiza, rulează: `python scan_opcodes.py --update`",
            "",
            "---",
            "",
        ]
    
    def _generate_constants_section(self) -> List[str]:
        """Generează secțiunea de constante."""
        lines = ["## 📊 CONSTANTE DESCOPERITE\n"]
        
        # Grupează constantele după fișier
        by_file = defaultdict(list)
        for const in self.results.constants:
            if const.is_public:  # Doar constantele publice
                by_file[const.file].append(const)
        
        for filepath, constants in sorted(by_file.items()):
            lines.append(f"### {filepath}\n")
            lines.append("| Constantă | Valoare | Descriere |")
            lines.append("|-----------|---------|-----------|")
            
            for const in sorted(constants, key=lambda c: c.name):
                desc = const.context[:60] + "..." if len(const.context) > 60 else const.context
                # Escape pipe în valori
                value = const.value.replace('|', '\\|')
                lines.append(f"| `{const.name}` | `{value}` | {desc} |")
            
            lines.append("")
            
        return lines
    
    def _generate_enums_section(self) -> List[str]:
        """Generează secțiunea de enums."""
        lines = ["## 🔢 ENUM-URI\n"]
        
        for enum in sorted(self.results.enums, key=lambda e: e.name):
            lines.append(f"### {enum.name}")
            lines.append(f"*Fișier: `{enum.file}` (linia {enum.line})*\n")
            lines.append("| Variantă | Valoare | Descriere |")
            lines.append("|----------|---------|-----------|")
            
            for variant in enum.variants:
                desc = variant.description if variant.description else "-"
                lines.append(f"| `{variant.name}` | {variant.value} | {desc} |")
            
            lines.append("")
            
        return lines
    
    def _generate_message_types_section(self) -> List[str]:
        """Generează secțiunea de tipuri de mesaje."""
        if not self.results.message_types:
            return []
            
        lines = ["## 📨 MESSAGE TYPES (Auto-detectate)\n"]
        lines.append("| Cod | Nume | Descriere |")
        lines.append("|-----|------|-----------|")
        
        for name, code, desc in sorted(self.results.message_types, key=lambda x: x[1]):
            lines.append(f"| {code} | `{name}` | {desc} |")
            
        lines.append("")
        return lines
    
    def _generate_magic_numbers_section(self) -> List[str]:
        """Generează secțiunea de magic numbers."""
        if not self.results.magic_numbers:
            return []
            
        lines = ["## 🔮 MAGIC NUMBERS\n"]
        lines.append("| Constantă | Valoare | Categorie |")
        lines.append("|-----------|---------|-----------|")
        
        # Elimină duplicate
        seen = set()
        unique_numbers = []
        for name, value, category in self.results.magic_numbers:
            key = (name, value)
            if key not in seen:
                seen.add(key)
                unique_numbers.append((name, value, category))
        
        for name, value, category in sorted(unique_numbers, key=lambda x: x[2]):
            lines.append(f"| `{name}` | `{value}` | {category} |")
            
        lines.append("")
        return lines
    
    def _generate_footer(self) -> List[str]:
        """Generează footer-ul."""
        return [
            "---",
            "",
            f"*Generat automat de scan_opcodes.py la {datetime.now().isoformat()}*",
            "",
            "**Statistici scanare:**",
            f"- Constante publice: {len([c for c in self.results.constants if c.is_public])}",
            f"- Enums: {len(self.results.enums)}",
            f"- Message types: {len(self.results.message_types)}",
            f"- Magic numbers: {len(self.results.magic_numbers)}",
            "",
        ]


def merge_with_existing(new_content: str, existing_path: Path) -> str:
    """Îmbină conținutul nou cu documentul existent, păstrând secțiunile manuale."""
    if not existing_path.exists():
        return new_content
        
    try:
        with open(existing_path, 'r', encoding='utf-8') as f:
            existing = f.read()
            
        # Pentru moment, returnăm doar conținutul nou
        # Într-o versiune viitoare, putem implementa merge inteligent
        return new_content
        
    except Exception as e:
        print(f"Avertisment: Nu pot citi fișierul existent: {e}")
        return new_content


def main():
    parser = argparse.ArgumentParser(
        description='Scaner opcoduri pentru OmniBus Blockchain',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Exemple:
  python scan_opcodes.py              # Scanare simplă
  python scan_opcodes.py --update     # Actualizează OPCODES.md
  python scan_opcodes.py --diff       # Arată diferențele
  python scan_opcodes.py --output out.md  # Salvează în alt fișier
        """
    )
    parser.add_argument('--update', action='store_true',
                        help='Actualizează OPCODES.md')
    parser.add_argument('--diff', action='store_true',
                        help='Arată diferențele fără a modifica fișiere')
    parser.add_argument('--output', '-o', type=str, default='OPCODES.md',
                        help='Fișier de output (default: OPCODES.md)')
    parser.add_argument('--root', '-r', type=str, default='..',
                        help='Directorul rădăcină al proiectului (default: ..)')
    
    args = parser.parse_args()
    
    # Determină directorul rădăcină
    script_dir = Path(__file__).parent
    if args.root == '..':
        root_dir = script_dir.parent
    else:
        root_dir = Path(args.root)
    
    print("=" * 60)
    print("[SCAN] OmniBus Blockchain - Opcode Scanner v1.0")
    print("=" * 60)
    print()
    
    # Scanare
    scanner = OpcodeScanner(root_dir)
    results = scanner.scan()
    
    # Generare conținut
    generator = MarkdownGenerator(results)
    new_content = generator.generate()
    
    # Output path
    output_path = script_dir / args.output
    
    if args.diff:
        # Arată diferențele
        if output_path.exists():
            with open(output_path, 'r', encoding='utf-8') as f:
                existing = f.read()
            if existing == new_content:
                print("\n✅ Nu sunt diferențe - documentul este la zi.")
            else:
                print("\n⚠️  Sunt diferențe între versiunea actuală și cea scanată.")
                print(f"   Rulează cu --update pentru a actualiza {args.output}")
        else:
            print(f"\n📝 Fișierul {args.output} nu există încă.")
            
    elif args.update or args.output != 'OPCODES.md':
        # Salvează fișierul
        if args.update and not args.output != 'OPCODES.md':
            # Îmbină cu existent pentru update
            final_content = merge_with_existing(new_content, output_path)
        else:
            final_content = new_content
            
        with open(output_path, 'w', encoding='utf-8') as f:
            f.write(final_content)
            
        print(f"\n[OK] Document salvat in: {output_path}")
        print(f"   - Constante scanate: {len(results.constants)}")
        print(f"   - Enums descoperite: {len(results.enums)}")
        print(f"   - Message types: {len(results.message_types)}")
        
    else:
        # Doar afiseaza statistici
        print("\n[STATS] Statistici scanare:")
        print(f"   - Total constante: {len(results.constants)}")
        print(f"   - Constante publice: {len([c for c in results.constants if c.is_public])}")
        print(f"   - Enums: {len(results.enums)}")
        print(f"   - Message types: {len(results.message_types)}")
        print(f"   - Magic numbers: {len(results.magic_numbers)}")
        print()
        print("[TIP] Foloseste --update pentru a salva rezultatele in OPCODES.md")
        print("[TIP] Foloseste --output pentru a salva in alt fisier")
    
    print()
    print("=" * 60)
    print("[DONE] Scanare completa!")
    print("=" * 60)


if __name__ == '__main__':
    main()
