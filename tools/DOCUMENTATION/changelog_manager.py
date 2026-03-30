#!/usr/bin/env python3
"""
changelog_manager.py - OmniBus Changelog & Release Manager v1.0

Gestionează changelog și release notes:
  - Parsează commit-uri git pentru changes
  - Categorizează: Added, Changed, Fixed, Security
  - Generează CHANGELOG.md în format Keep a Changelog
  - Sugerează version bumping (semver)
  - Crează release notes pentru GitHub

Usage:
  python tools/DOCUMENTATION/changelog_manager.py              # Generează changelog
  python tools/DOCUMENTATION/changelog_manager.py --since v1.0.0  # De la versiune
  python tools/DOCUMENTATION/changelog_manager.py --bump major    # Sugerează bump
  python tools/DOCUMENTATION/changelog_manager.py --release       # Crează release
"""

import sys
import re
import subprocess
import argparse
from pathlib import Path
from dataclasses import dataclass, field
from typing import List, Dict, Optional, Tuple
from datetime import datetime
from collections import defaultdict

ROOT = Path(__file__).parent.parent.parent
CHANGELOG = ROOT / "CHANGELOG.md"

@dataclass
class Change:
    category: str  # added, changed, fixed, removed, security, deprecated
    message: str
    commit_hash: str
    author: str
    scope: str = ""  # Modulul afectat (ex: wallet, consensus)

@dataclass
class Release:
    version: str
    date: str
    changes: List[Change] = field(default_factory=list)
    yanked: bool = False


class ChangelogManager:
    """Manages changelog generation and versioning."""
    
    CATEGORIES = {
        "added": "Added",
        "changed": "Changed", 
        "deprecated": "Deprecated",
        "removed": "Removed",
        "fixed": "Fixed",
        "security": "Security",
    }
    
    def __init__(self, root: Path):
        self.root = root
        self.changes: List[Change] = []
    
    def parse_commits(self, since: Optional[str] = None) -> List[Change]:
        """Parse git commits for conventional commit format."""
        cmd = ["git", "log", "--pretty=format:%H|%s|%an"]
        if since:
            cmd.extend([f"{since}..HEAD"])
        else:
            cmd.extend(["-30"])  # Last 30 commits
        
        try:
            result = subprocess.run(
                cmd,
                cwd=self.root,
                capture_output=True,
                text=True,
                timeout=30
            )
            
            changes = []
            for line in result.stdout.strip().split('\n'):
                if '|' not in line:
                    continue
                
                parts = line.split('|')
                if len(parts) < 3:
                    continue
                
                commit_hash, message, author = parts[0], parts[1], parts[2]
                
                # Parse conventional commit format: type(scope): message
                match = re.match(r'^(\w+)(?:\(([^)]+)\))?\s*:\s*(.+)$', message)
                if match:
                    commit_type, scope, msg = match.groups()
                    category = self._map_commit_type(commit_type)
                    
                    changes.append(Change(
                        category=category,
                        message=msg,
                        commit_hash=commit_hash[:7],
                        author=author,
                        scope=scope or ""
                    ))
            
            return changes
            
        except subprocess.CalledProcessError as e:
            print(f"Error running git: {e}")
            return []
        except FileNotFoundError:
            print("Git not found in PATH")
            return []
    
    def _map_commit_type(self, commit_type: str) -> str:
        """Map conventional commit type to changelog category."""
        mapping = {
            "feat": "added",
            "feature": "added",
            "add": "added",
            "fix": "fixed",
            "bugfix": "fixed",
            "change": "changed",
            "update": "changed",
            "refactor": "changed",
            "deprecate": "deprecated",
            "remove": "removed",
            "delete": "removed",
            "security": "security",
            "perf": "changed",
            "docs": "added",
            "test": "added",
        }
        return mapping.get(commit_type.lower(), "changed")
    
    def suggest_version_bump(self, changes: List[Change]) -> Tuple[str, str]:
        """Suggest version bump based on changes."""
        has_breaking = any("breaking" in c.message.lower() or "BREAKING" in c.message for c in changes)
        has_features = any(c.category == "added" for c in changes)
        has_fixes = any(c.category == "fixed" for c in changes)
        
        if has_breaking:
            return "major", "Breaking changes detected - suggest MAJOR version bump"
        elif has_features:
            return "minor", "New features detected - suggest MINOR version bump"
        elif has_fixes:
            return "patch", "Bug fixes detected - suggest PATCH version bump"
        else:
            return "none", "No significant changes - version can remain"
    
    def generate_changelog(self, changes: List[Change], version: str = "Unreleased") -> str:
        """Generate changelog content."""
        # Group by category
        by_category = defaultdict(list)
        for change in changes:
            by_category[change.category].append(change)
        
        lines = [
            "# Changelog",
            "",
            "All notable changes to this project will be documented in this file.",
            "",
            "The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/)",
            "and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).",
            "",
            f"## [{version}] - {datetime.now().strftime('%Y-%m-%d')}",
            "",
        ]
        
        # Add categories in order
        for cat_key, cat_name in self.CATEGORIES.items():
            if cat_key in by_category:
                lines.append(f"### {cat_name}")
                lines.append("")
                for change in by_category[cat_key]:
                    scope = f"**{change.scope}**: " if change.scope else ""
                    lines.append(f"- {scope}{change.message} ({change.commit_hash})")
                lines.append("")
        
        return '\n'.join(lines)
    
    def generate_release_notes(self, changes: List[Change], version: str) -> str:
        """Generate release notes for GitHub."""
        by_category = defaultdict(list)
        for change in changes:
            by_category[change.category].append(change)
        
        lines = [
            f"# Release {version}",
            "",
            f"**Release Date:** {datetime.now().strftime('%Y-%m-%d')}",
            "",
            "## What's Changed",
            "",
        ]
        
        for cat_key, cat_name in self.CATEGORIES.items():
            if cat_key in by_category:
                lines.append(f"### {cat_name} 🎉" if cat_key == "added" else f"### {cat_name}")
                lines.append("")
                for change in by_category[cat_key]:
                    scope = f"**{change.scope}**: " if change.scope else ""
                    lines.append(f"- {scope}{change.message}")
                lines.append("")
        
        lines.extend([
            "## Contributors",
            "",
        ])
        
        contributors = set(c.author for c in changes)
        for author in sorted(contributors):
            lines.append(f"- @{author}")
        
        return '\n'.join(lines)
    
    def get_current_version(self) -> str:
        """Get current version from git tags."""
        try:
            result = subprocess.run(
                ["git", "describe", "--tags", "--abbrev=0"],
                cwd=self.root,
                capture_output=True,
                text=True,
                timeout=10
            )
            return result.stdout.strip()
        except:
            return "v0.0.0"
    
    def bump_version(self, current: str, bump_type: str) -> str:
        """Bump version according to semver."""
        # Remove 'v' prefix if present
        version = current.lstrip('v')
        parts = version.split('.')
        
        if len(parts) != 3:
            parts = ['0', '0', '0']
        
        major, minor, patch = int(parts[0]), int(parts[1]), int(parts[2])
        
        if bump_type == "major":
            return f"v{major + 1}.0.0"
        elif bump_type == "minor":
            return f"v{major}.{minor + 1}.0"
        elif bump_type == "patch":
            return f"v{major}.{minor}.{patch + 1}"
        else:
            return current


def main():
    parser = argparse.ArgumentParser(description="Changelog Manager")
    parser.add_argument("--since", help="Generate changelog since this version/tag")
    parser.add_argument("--bump", choices=["major", "minor", "patch"], help="Version bump type")
    parser.add_argument("--release", action="store_true", help="Create release notes")
    parser.add_argument("--output", type=Path, help="Output file")
    args = parser.parse_args()
    
    print("\n" + "=" * 60)
    print("  OmniBus Changelog Manager")
    print("=" * 60)
    
    manager = ChangelogManager(ROOT)
    
    # Parse commits
    print("\nParsing git commits...")
    changes = manager.parse_commits(args.since)
    print(f"Found {len(changes)} changes")
    
    if not changes:
        print("No changes found!")
        sys.exit(0)
    
    # Get current version
    current_version = manager.get_current_version()
    print(f"Current version: {current_version}")
    
    # Suggest version bump
    bump_type, reason = manager.suggest_version_bump(changes)
    print(f"\nSuggestion: {reason}")
    
    # Determine target version
    if args.bump:
        target_version = manager.bump_version(current_version, args.bump)
    else:
        target_version = manager.bump_version(current_version, bump_type)
    
    print(f"Target version: {target_version}")
    
    if args.release:
        # Generate release notes
        content = manager.generate_release_notes(changes, target_version)
        output = args.output or ROOT / "RELEASE_NOTES.md"
    else:
        # Generate changelog
        content = manager.generate_changelog(changes, target_version)
        output = args.output or CHANGELOG
    
    output.write_text(content, encoding='utf-8')
    print(f"\nGenerated: {output}")
    
    print("\n" + "=" * 60)
    print("Done!")
    print("=" * 60 + "\n")

if __name__ == "__main__":
    main()
