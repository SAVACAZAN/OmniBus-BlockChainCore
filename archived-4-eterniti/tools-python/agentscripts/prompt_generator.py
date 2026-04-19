#!/usr/bin/env python3
"""
OmniBus Blockchain - Prompt Generator
======================================

Generează prompturi context-aware pentru alți agenți AI.
Include starea proiectului, erori recente, TODO-uri relevante.

Utilizare:
    python prompt_generator.py --task "Implement LMD GHOST"
    python prompt_generator.py --task "Fix bug in p2p" --include-todos
    python prompt_generator.py --file core/consensus.zig

Autor: OmniBus AI Collective
Versiune: 1.0.0
"""

import os
import sys
import subprocess
from pathlib import Path
from typing import List, Dict, Optional
from dataclasses import dataclass


@dataclass
class ProjectContext:
    """Contextul proiectului pentru prompt."""
    zig_version: str
    files_count: int
    loc_total: int
    build_status: str
    test_status: str
    recent_commits: List[str]
    relevant_todos: List[str]
    open_issues: List[str]


class PromptGenerator:
    """Generează prompturi pentru agenți AI."""
    
    def __init__(self, project_root: Path):
        self.project_root = project_root
        
    def get_zig_version(self) -> str:
        """Ia versiunea Zig."""
        try:
            result = subprocess.run(
                ['zig', 'version'],
                capture_output=True,
                text=True,
                timeout=5
            )
            if result.returncode == 0:
                return result.stdout.strip()
        except:
            pass
        return "unknown"
    
    def get_project_stats(self) -> Dict:
        """Ia statistici despre proiect."""
        zig_files = list(self.project_root.rglob('*.zig'))
        zig_files = [f for f in zig_files if not any(p.startswith('.') for p in f.parts)]
        
        loc_total = 0
        for f in zig_files:
            try:
                with open(f, 'r') as file:
                    loc_total += len(file.readlines())
            except:
                pass
        
        return {
            'files': len(zig_files),
            'loc': loc_total,
        }
    
    def get_recent_commits(self, count: int = 3) -> List[str]:
        """Ia commit-urile recente."""
        try:
            result = subprocess.run(
                ['git', 'log', f'-{count}', '--oneline'],
                cwd=self.project_root,
                capture_output=True,
                text=True,
                timeout=5
            )
            if result.returncode == 0:
                return [line.strip() for line in result.stdout.strip().split('\n') if line.strip()]
        except:
            pass
        return []
    
    def get_build_status(self) -> str:
        """Verifică statusul build-ului."""
        try:
            result = subprocess.run(
                ['zig', 'build', '-Doqs=false'],
                cwd=self.project_root,
                capture_output=True,
                text=True,
                timeout=30
            )
            return "OK" if result.returncode == 0 else "FAIL"
        except:
            return "UNKNOWN"
    
    def get_relevant_todos(self, keyword: Optional[str] = None) -> List[str]:
        """Ia TODO-uri relevante."""
        todos = []
        
        zig_files = list(self.project_root.rglob('*.zig'))
        zig_files = [f for f in zig_files if not any(p.startswith('.') for p in f.parts)]
        
        for filepath in zig_files:
            try:
                with open(filepath, 'r', encoding='utf-8') as f:
                    lines = f.readlines()
                
                rel_path = str(filepath.relative_to(self.project_root))
                
                for i, line in enumerate(lines, 1):
                    if 'TODO' in line or 'FIXME' in line or 'BUG' in line:
                        if keyword and keyword.lower() not in line.lower():
                            continue
                        
                        todo_text = line.strip()
                        if len(todo_text) > 100:
                            todo_text = todo_text[:97] + "..."
                        
                        todos.append(f"{rel_path}:{i}: {todo_text}")
                        
                        if len(todos) >= 10:  # Max 10 TODOs
                            return todos
            except:
                pass
        
        return todos
    
    def generate_prompt(self, task: str, include_todos: bool = True, 
                       include_files: Optional[List[str]] = None) -> str:
        """Generează promptul complet."""
        
        # Gather context
        zig_version = self.get_zig_version()
        stats = self.get_project_stats()
        commits = self.get_recent_commits(3)
        build_status = self.get_build_status()
        todos = self.get_relevant_todos(task.split()[0] if task else None) if include_todos else []
        
        # Build prompt
        prompt_parts = []
        
        # Header
        prompt_parts.append("=" * 70)
        prompt_parts.append("PROMPT PENTRU AI AGENT - OmniBus Blockchain")
        prompt_parts.append("=" * 70)
        prompt_parts.append("")
        
        # Role
        prompt_parts.append("ROL:")
        prompt_parts.append("Ești un dezvoltator Zig expert specializat în blockchain.")
        prompt_parts.append("Cunoști bine: Zig 0.15+, cryptography, P2P networking, consensus algorithms.")
        prompt_parts.append("")
        
        # Context proiect
        prompt_parts.append("CONTEX PROIECT:")
        prompt_parts.append(f"- Nume: OmniBus Blockchain")
        prompt_parts.append(f"- Limbaj: Zig {zig_version}")
        prompt_parts.append(f"- Dimensiune: {stats['files']} fișiere, {stats['loc']:,} linii de cod")
        prompt_parts.append(f"- Build status: {build_status}")
        prompt_parts.append(f"- Arhitectură: PoW + Casper FFG (hybrid), Sharding, 1s block time")
        prompt_parts.append("")
        
        # Recent activity
        if commits:
            prompt_parts.append("ACTIVITATE RECENTĂ:")
            for commit in commits[:3]:
                prompt_parts.append(f"  - {commit}")
            prompt_parts.append("")
        
        # Task
        prompt_parts.append("=" * 70)
        prompt_parts.append("TASK:")
        prompt_parts.append("=" * 70)
        prompt_parts.append(task)
        prompt_parts.append("")
        
        # Relevant TODOs
        if todos:
            prompt_parts.append("TODO-URI RELEVANTE:")
            for todo in todos[:5]:
                prompt_parts.append(f"  {todo}")
            prompt_parts.append("")
        
        # Specific files
        if include_files:
            prompt_parts.append("FIȘIERE SPECIFICE:")
            for filepath in include_files:
                full_path = self.project_root / filepath
                if full_path.exists():
                    try:
                        with open(full_path, 'r') as f:
                            content = f.read()
                            lines = content.split('\n')
                            prompt_parts.append(f"\n--- {filepath} ({len(lines)} linii) ---")
                            prompt_parts.append(content[:2000])  # Primele 2000 caractere
                            if len(content) > 2000:
                                prompt_parts.append("... [truncated]")
                    except Exception as e:
                        prompt_parts.append(f"[Eroare citire {filepath}: {e}]")
            prompt_parts.append("")
        
        # References
        prompt_parts.append("REFERINȚE:")
        prompt_parts.append("- OPCODES.md - Constante și opcoduri")
        prompt_parts.append("- CLAUDE.md - Ghid dezvoltare")
        prompt_parts.append("")
        
        # Requirements
        prompt_parts.append("=" * 70)
        prompt_parts.append("CERINȚE:")
        prompt_parts.append("=" * 70)
        prompt_parts.append("1. Respectă stilul de cod existent")
        prompt_parts.append("2. Adaugă teste pentru codul nou")
        prompt_parts.append("3. Verifică că build-ul trece: zig build -Doqs=false")
        prompt_parts.append("4. Actualizează OPCODES.md dacă adaugi constante noi")
        prompt_parts.append("5. Folosește arena allocator unde e posibil")
        prompt_parts.append("")
        
        # Output
        prompt_parts.append("OUTPUT AȘTEPTAT:")
        prompt_parts.append("- Cod Zig funcțional")
        prompt_parts.append("- Teste unitare")
        prompt_parts.append("- Explicație scurtă a schimbărilor")
        prompt_parts.append("")
        prompt_parts.append("=" * 70)
        
        return '\n'.join(prompt_parts)


def main():
    import argparse
    
    parser = argparse.ArgumentParser(
        description='Generează prompturi pentru AI agents',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Exemple:
  python prompt_generator.py --task "Implement LMD GHOST fork choice"
  python prompt_generator.py --task "Fix memory leak" --include-todos
  python prompt_generator.py --file core/p2p.zig --task "Add rate limiting"
        """
    )
    parser.add_argument('--task', '-t', required=True,
                        help='Descrierea task-ului')
    parser.add_argument('--include-todos', action='store_true',
                        help='Include TODO-uri relevante')
    parser.add_argument('--file', '-f', action='append',
                        help='Include conținutul unui fișier (poate fi folosit de multiple ori)')
    parser.add_argument('--output', '-o',
                        help='Salvează promptul în fișier')
    
    args = parser.parse_args()
    
    # Find project root
    script_dir = Path(__file__).parent
    project_root = script_dir.parent.parent
    
    # Generate
    generator = PromptGenerator(project_root)
    prompt = generator.generate_prompt(
        task=args.task,
        include_todos=args.include_todos,
        include_files=args.file
    )
    
    # Output
    if args.output:
        with open(args.output, 'w', encoding='utf-8') as f:
            f.write(prompt)
        print(f"[OK] Prompt salvat în: {args.output}")
    else:
        print(prompt)


if __name__ == '__main__':
    main()
