#!/usr/bin/env python3
"""
OmniBus Blockchain - TODO Extractor
====================================

Extrage toate TODO-urile, FIXME-urile și BUG-urile din cod.
Grupate după fișier și prioritate. Ideal pentru tracking taskuri.

Utilizare:
    python todo_extractor.py              # Afișează toate TODO-urile
    python todo_extractor.py --high       # Doar prioritate înaltă
    python todo_extractor.py --json       # Output JSON
    python todo_extractor.py --count      # Doar numărătoare

Autor: OmniBus AI Collective
Versiune: 1.0.0
"""

import os
import sys
import json
import re
from pathlib import Path
from dataclasses import dataclass, asdict
from typing import List, Dict, Optional, Tuple
from collections import defaultdict


@dataclass
class TodoItem:
    """Reprezintă un item TODO/FIXME/BUG."""
    file: str
    line: int
    type: str  # TODO, FIXME, BUG, HACK, XXX, NOTE
    priority: str  # high, medium, low
    text: str
    author: Optional[str] = None
    context: str = ""  # Linia de cod unde apare


class TodoExtractor:
    """Extrage TODO-uri din fișierele Zig."""
    
    # Pattern-uri pentru detectare
    TODO_PATTERN = re.compile(
        r'//\s*(TODO|FIXME|BUG|HACK|XXX|NOTE)[\s:]*\(?(?P<prio>HIGH|LOW|MEDIUM)?\)?[:\s-]*\s*(?P<text>.*)',
        re.IGNORECASE
    )
    
    AUTHOR_PATTERN = re.compile(
        r'@(\w+)'
    )
    
    PRIORITY_KEYWORDS = {
        'high': ['high', 'critical', 'urgent', 'important', 'security'],
        'medium': ['medium', 'normal', 'should'],
        'low': ['low', 'minor', 'optional', 'nice'],
    }
    
    def __init__(self, project_root: Path):
        self.project_root = project_root
        self.todos: List[TodoItem] = []
        
    def determine_priority(self, text: str, explicit: Optional[str]) -> str:
        """Determină prioritatea bazată pe text și marker explicit."""
        text_lower = text.lower()
        
        # Dacă e explicit marcat
        if explicit:
            explicit_lower = explicit.lower()
            if explicit_lower in ['high', 'critical']:
                return 'high'
            elif explicit_lower == 'low':
                return 'low'
            return 'medium'
        
        # Verifică cuvinte cheie
        for prio, keywords in self.PRIORITY_KEYWORDS.items():
            for keyword in keywords:
                if keyword in text_lower:
                    return prio
        
        # Default bazat pe tip
        return 'high'  # FIXME/BUG = high by default
    
    def extract_author(self, text: str) -> Tuple[str, str]:
        """Extrage autorul din text (@username)."""
        match = self.AUTHOR_PATTERN.search(text)
        if match:
            author = match.group(1)
            text_clean = text.replace(f'@{author}', '').strip()
            return author, text_clean
        return None, text
    
    def scan_file(self, filepath: Path) -> List[TodoItem]:
        """Scanează un singur fișier pentru TODO-uri."""
        items = []
        
        try:
            with open(filepath, 'r', encoding='utf-8') as f:
                lines = f.readlines()
        except Exception:
            return items
        
        rel_path = str(filepath.relative_to(self.project_root))
        
        for line_num, line in enumerate(lines, 1):
            match = self.TODO_PATTERN.search(line)
            if match:
                todo_type = match.group(1).upper()
                explicit_prio = match.group('prio')
                text = match.group('text').strip()
                
                # Skip dacă e gol
                if not text:
                    continue
                
                # Extrage autor
                author, text_clean = self.extract_author(text)
                
                # Determină prioritatea
                priority = self.determine_priority(text_clean, explicit_prio)
                
                # Pentru TODO normal, prioritatea default e medium
                if todo_type == 'TODO' and not explicit_prio:
                    priority = 'medium'
                
                # Context (codul de pe linia respectivă)
                context = line.strip()
                
                items.append(TodoItem(
                    file=rel_path,
                    line=line_num,
                    type=todo_type,
                    priority=priority,
                    text=text_clean,
                    author=author,
                    context=context
                ))
        
        return items
    
    def scan_project(self) -> List[TodoItem]:
        """Scanează întregul proiect."""
        zig_files = list(self.project_root.rglob('*.zig'))
        
        # Filtrează fișierele relevante
        zig_files = [
            f for f in zig_files 
            if not any(part.startswith('.') or part in ['zig-out', '.zig-cache']
                      for part in f.parts)
        ]
        
        for filepath in zig_files:
            items = self.scan_file(filepath)
            self.todos.extend(items)
        
        # Sortează după prioritate și fișier
        priority_order = {'high': 0, 'medium': 1, 'low': 2}
        self.todos.sort(key=lambda t: (priority_order.get(t.priority, 1), t.file, t.line))
        
        return self.todos
    
    def get_stats(self) -> Dict:
        """Returnează statistici despre TODO-uri."""
        stats = {
            'total': len(self.todos),
            'by_type': defaultdict(int),
            'by_priority': defaultdict(int),
            'by_file': defaultdict(int),
        }
        
        for todo in self.todos:
            stats['by_type'][todo.type] += 1
            stats['by_priority'][todo.priority] += 1
            stats['by_file'][todo.file] += 1
        
        return dict(stats)


def print_todos(todos: List[TodoItem], filter_priority: Optional[str] = None):
    """Afișează TODO-urile într-un format uman-citibil."""
    GREEN = '\033[92m'
    YELLOW = '\033[93m'
    RED = '\033[91m'
    BLUE = '\033[94m'
    RESET = '\033[0m'
    BOLD = '\033[1m'
    
    if filter_priority:
        todos = [t for t in todos if t.priority == filter_priority]
    
    if not todos:
        print(f"\n  {GREEN}Nu s-au găsit TODO-uri conform filtrului.{RESET}\n")
        return
    
    print(f"\n{BOLD}╔══════════════════════════════════════════════════════════════╗{RESET}")
    print(f"{BOLD}║              OmniBus Blockchain - TODO Extractor             ║{RESET}")
    print(f"{BOLD}╚══════════════════════════════════════════════════════════════╝{RESET}\n")
    
    # Grupează după prioritate
    by_priority = defaultdict(list)
    for todo in todos:
        by_priority[todo.priority].append(todo)
    
    priority_colors = {
        'high': RED,
        'medium': YELLOW,
        'low': BLUE,
    }
    
    for priority in ['high', 'medium', 'low']:
        if priority not in by_priority:
            continue
        
        color = priority_colors.get(priority, RESET)
        items = by_priority[priority]
        
        print(f"\n  {color}{BOLD}[{priority.upper()}] ({len(items)} itemi){RESET}\n")
        
        # Grupează după fișier
        by_file = defaultdict(list)
        for item in items:
            by_file[item.file].append(item)
        
        for filepath, file_items in sorted(by_file.items()):
            print(f"    {BOLD}{filepath}{RESET}")
            
            for item in file_items:
                type_indicator = {
                    'FIXME': f"{RED}⚠{RESET}",
                    'BUG': f"{RED}🐛{RESET}",
                    'TODO': f"{YELLOW}□{RESET}",
                    'HACK': f"{BLUE}🔧{RESET}",
                    'XXX': f"{YELLOW}⚡{RESET}",
                    'NOTE': f"{GREEN}📝{RESET}",
                }.get(item.type, "•")
                
                author_str = f" @{item.author}" if item.author else ""
                print(f"      {type_indicator} Line {item.line:4}:{author_str} {item.text}")
    
    print()


def print_stats(stats: Dict):
    """Afișează statistici."""
    GREEN = '\033[92m'
    YELLOW = '\033[93m'
    RED = '\033[91m'
    RESET = '\033[0m'
    BOLD = '\033[1m'
    
    print(f"\n  {BOLD}Statistici:{RESET}\n")
    print(f"    Total TODO-uri: {BOLD}{stats['total']}{RESET}")
    
    print(f"\n    {BOLD}După tip:{RESET}")
    for todo_type, count in sorted(stats['by_type'].items()):
        color = {'FIXME': RED, 'BUG': RED, 'TODO': YELLOW}.get(todo_type, RESET)
        print(f"      {color}{todo_type:8}{RESET}: {count}")
    
    print(f"\n    {BOLD}După prioritate:{RESET}")
    for prio, count in [('high', stats['by_priority'].get('high', 0)),
                        ('medium', stats['by_priority'].get('medium', 0)),
                        ('low', stats['by_priority'].get('low', 0))]:
        color = {'high': RED, 'medium': YELLOW, 'low': ''}.get(prio, '')
        print(f"      {color}{prio:8}{RESET}: {count}")
    
    print(f"\n    {BOLD}Top 5 fișiere cu cele mai multe TODO-uri:{RESET}")
    sorted_files = sorted(stats['by_file'].items(), key=lambda x: x[1], reverse=True)[:5]
    for filepath, count in sorted_files:
        print(f"      {filepath}: {count}")
    
    print()


def main():
    import argparse
    
    parser = argparse.ArgumentParser(
        description='Extrage TODO-uri din codul OmniBus',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Exemple:
  python todo_extractor.py              # Toate TODO-urile
  python todo_extractor.py --high       # Doar HIGH priority
  python todo_extractor.py --json       # Output JSON
  python todo_extractor.py --count      # Doar statistici
        """
    )
    parser.add_argument('--high', action='store_true',
                        help='Doar TODO-uri cu prioritate HIGH')
    parser.add_argument('--medium', action='store_true',
                        help='Doar TODO-uri cu prioritate MEDIUM')
    parser.add_argument('--low', action='store_true',
                        help='Doar TODO-uri cu prioritate LOW')
    parser.add_argument('--json', action='store_true',
                        help='Output în format JSON')
    parser.add_argument('--count', action='store_true',
                        help='Doar statistici, nu lista completă')
    parser.add_argument('--type', choices=['TODO', 'FIXME', 'BUG', 'HACK', 'XXX', 'NOTE'],
                        help='Filtrează după tip')
    
    args = parser.parse_args()
    
    # Find project root
    script_dir = Path(__file__).parent
    project_root = script_dir.parent.parent
    
    # Extract
    extractor = TodoExtractor(project_root)
    todos = extractor.scan_project()
    
    # Filter
    if args.type:
        todos = [t for t in todos if t.type == args.type]
    
    # Determine priority filter
    priority_filter = None
    if args.high:
        priority_filter = 'high'
    elif args.medium:
        priority_filter = 'medium'
    elif args.low:
        priority_filter = 'low'
    
    # Output
    if args.json:
        data = {
            'todos': [asdict(t) for t in todos],
            'stats': extractor.get_stats()
        }
        print(json.dumps(data, indent=2))
    elif args.count:
        print_stats(extractor.get_stats())
    else:
        print_todos(todos, priority_filter)
        print_stats(extractor.get_stats())
    
    # Exit code based on high priority todos
    high_count = sum(1 for t in todos if t.priority == 'high')
    sys.exit(1 if high_count > 10 else 0)


if __name__ == '__main__':
    main()
