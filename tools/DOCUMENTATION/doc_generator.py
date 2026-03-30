#!/usr/bin/env python3
"""
doc_generator.py - OmniBus API Documentation Generator v1.0

Generează documentație API din codul Zig:
  - Extrage comentarii /// (doc comments)
  - Parsează funcții publice și structuri
  - Generează markdown și HTML
  - Creează index navigabil

Usage:
  python tools/DOCUMENTATION/doc_generator.py              # Generează toată docs
  python tools/DOCUMENTATION/doc_generator.py --module wallet  # Doar un modul
  python tools/DOCUMENTATION/doc_generator.py --format html    # Format HTML
  python tools/DOCUMENTATION/doc_generator.py --output ./docs  # Director output
"""

import sys
import re
import json
import argparse
from pathlib import Path
from dataclasses import dataclass, field
from typing import List, Dict, Optional, Tuple
from datetime import datetime

ROOT = Path(__file__).parent.parent.parent
CORE = ROOT / "core"
OUTPUT = ROOT / "docs" / "api"

@dataclass
class FunctionDoc:
    name: str
    signature: str
    description: str
    params: List[Tuple[str, str]] = field(default_factory=list)  # (name, type)
    returns: str = ""
    examples: List[str] = field(default_factory=list)
    line: int = 0

@dataclass
class StructDoc:
    name: str
    description: str
    fields: List[Tuple[str, str, str]] = field(default_factory=list)  # (name, type, desc)
    line: int = 0

@dataclass
class ModuleDoc:
    name: str
    description: str = ""
    functions: List[FunctionDoc] = field(default_factory=list)
    structs: List[StructDoc] = field(default_factory=list)
    constants: List[Tuple[str, str, str]] = field(default_factory=list)  # (name, type, value)


def extract_doc_comments(content: str, start_line: int) -> str:
    """Extract consecutive /// comments before a line."""
    lines = content.split('\n')
    comments = []
    
    for i in range(start_line - 2, -1, -1):
        line = lines[i].strip()
        if line.startswith('///'):
            comments.insert(0, line[3:].strip())
        elif line and not line.startswith('//'):
            break
    
    return '\n'.join(comments)


def parse_function(line: str) -> Optional[Tuple[str, str, List[Tuple[str, str]]]]:
    """Parse a function signature. Returns (name, full_signature, params)."""
    # Match: pub fn name(params) !ReturnType
    match = re.match(r'(?:pub\s+)?(?:export\s+)?fn\s+(\w+)\s*\(([^)]*)\)\s*(!?[^\{]+)?', line)
    if not match:
        return None
    
    name = match.group(1)
    params_str = match.group(2).strip()
    returns = match.group(3).strip() if match.group(3) else "void"
    
    # Parse params
    params = []
    if params_str:
        for param in params_str.split(','):
            param = param.strip()
            if ':' in param:
                pname, ptype = param.split(':', 1)
                params.append((pname.strip(), ptype.strip()))
    
    return name, returns, params


def parse_struct(line: str) -> Optional[str]:
    """Parse struct name."""
    match = re.match(r'(?:pub\s+)?const\s+(\w+)\s*=\s*(?:extern\s+)?struct', line)
    if match:
        return match.group(1)
    return None


def parse_module(filepath: Path) -> ModuleDoc:
    """Parse a Zig module and extract documentation."""
    content = filepath.read_text(encoding='utf-8', errors='replace')
    lines = content.split('\n')
    
    module = ModuleDoc(name=filepath.stem)
    
    # Module description from top comments
    module_desc = []
    for line in lines:
        stripped = line.strip()
        if stripped.startswith('//!'):
            module_desc.append(stripped[3:].strip())
        elif stripped and not stripped.startswith('//'):
            break
    module.description = '\n'.join(module_desc)
    
    for i, line in enumerate(lines, 1):
        stripped = line.strip()
        
        # Parse pub functions
        if re.match(r'pub\s+(?:export\s+)?fn\s+\w+', stripped):
            func_info = parse_function(stripped)
            if func_info:
                name, returns, params = func_info
                doc = extract_doc_comments(content, i)
                
                func_doc = FunctionDoc(
                    name=name,
                    signature=stripped,
                    description=doc,
                    params=params,
                    returns=returns,
                    line=i
                )
                module.functions.append(func_doc)
        
        # Parse structs
        if 'struct' in stripped and 'const' in stripped:
            struct_name = parse_struct(stripped)
            if struct_name:
                doc = extract_doc_comments(content, i)
                module.structs.append(StructDoc(
                    name=struct_name,
                    description=doc,
                    line=i
                ))
        
        # Parse pub constants
        if re.match(r'pub\s+const\s+\w+\s*[:=]', stripped) and 'struct' not in stripped and 'fn' not in stripped:
            match = re.match(r'pub\s+const\s+(\w+)\s*[:=]\s*([^;]+)', stripped)
            if match:
                name = match.group(1)
                value = match.group(2).strip()
                module.constants.append((name, "auto", value))
    
    return module


def generate_markdown(module: ModuleDoc) -> str:
    """Generate markdown documentation for a module."""
    md = f"# Module: `{module.name}`\n\n"
    
    if module.description:
        md += f"{module.description}\n\n"
    
    # Table of contents
    md += "## Contents\n\n"
    if module.structs:
        md += "- [Structs](#structs)\n"
    if module.constants:
        md += "- [Constants](#constants)\n"
    if module.functions:
        md += "- [Functions](#functions)\n"
    md += "\n"
    
    # Structs
    if module.structs:
        md += "## Structs\n\n"
        for s in module.structs:
            md += f"### `{s.name}`\n\n"
            if s.description:
                md += f"{s.description}\n\n"
            md += f"*Line: {s.line}*\n\n"
    
    # Constants
    if module.constants:
        md += "## Constants\n\n"
        md += "| Name | Type | Value |\n"
        md += "|------|------|-------|\n"
        for name, typ, value in module.constants[:20]:  # Limit to 20
            md += f"| `{name}` | {typ} | `{value[:50]}{'...' if len(value) > 50 else ''}` |\n"
        md += "\n"
    
    # Functions
    if module.functions:
        md += "## Functions\n\n"
        for f in module.functions:
            md += f"### `{f.name}`\n\n"
            if f.description:
                md += f"{f.description}\n\n"
            
            md += "```zig\n"
            md += f"{f.signature}\n"
            md += "```\n\n"
            
            if f.params:
                md += "**Parameters:**\n\n"
                for pname, ptype in f.params:
                    md += f"- `{pname}`: `{ptype}`\n"
                md += "\n"
            
            if f.returns and f.returns != "void":
                md += f"**Returns:** `{f.returns}`\n\n"
            
            md += f"*Line: {f.line}*\n\n"
            md += "---\n\n"
    
    return md


def generate_html_index(modules: List[ModuleDoc]) -> str:
    """Generate HTML index page."""
    module_links = "\n".join([
        f'<li><a href="{m.name}.html">{m.name}</a> - {len(m.functions)} functions, {len(m.structs)} structs</li>'
        for m in sorted(modules, key=lambda x: x.name)
    ])
    
    html = f"""<!DOCTYPE html>
<html><head>
<meta charset="utf-8">
<title>OmniBus Blockchain API Documentation</title>
<style>
body {{ font-family: 'Segoe UI', sans-serif; max-width: 1200px; margin: 0 auto; padding: 20px; background: #1a1a2e; color: #e0e0e0; }}
h1 {{ color: #74c0fc; }}
h2 {{ color: #63e6be; }}
a {{ color: #74c0fc; text-decoration: none; }}
a:hover {{ text-decoration: underline; }}
ul {{ line-height: 1.8; }}
.stats {{ background: #16213e; padding: 15px; border-radius: 8px; margin: 20px 0; }}
</style>
</head><body>
<h1>🚀 OmniBus Blockchain API Documentation</h1>
<p>Generated: {datetime.now().strftime('%Y-%m-%d %H:%M')}</p>

<div class="stats">
<h2>Statistics</h2>
<p>Total modules: {len(modules)}</p>
<p>Total functions: {sum(len(m.functions) for m in modules)}</p>
<p>Total structs: {sum(len(m.structs) for m in modules)}</p>
</div>

<h2>Modules</h2>
<ul>
{module_links}
</ul>

<p style="margin-top: 40px; color: #888;">Generated by OmniBus Doc Generator</p>
</body></html>"""
    
    return html


def generate_html(module: ModuleDoc) -> str:
    """Generate HTML documentation for a module."""
    func_sections = ""
    for f in module.functions:
        params_html = ""
        if f.params:
            params_html = "<h4>Parameters:</h4><ul>" + "".join([
                f"<li><code>{p[0]}</code>: <code>{p[1]}</code></li>"
                for p in f.params
            ]) + "</ul>"
        
        func_sections += f"""
        <div class="function">
            <h3><code>{f.name}</code></h3>
            <p>{f.description or "No description available."}</p>
            <pre><code>{f.signature}</code></pre>
            {params_html}
            <p class="line">Line: {f.line}</p>
        </div>
        """
    
    html = f"""<!DOCTYPE html>
<html><head>
<meta charset="utf-8">
<title>{module.name} - OmniBus API</title>
<style>
body {{ font-family: 'Segoe UI', sans-serif; max-width: 1000px; margin: 0 auto; padding: 20px; background: #1a1a2e; color: #e0e0e0; }}
h1 {{ color: #74c0fc; }}
h2 {{ color: #63e6be; border-bottom: 1px solid #2d3561; padding-bottom: 10px; }}
h3 {{ color: #ffa94d; }}
h4 {{ color: #cc5de8; }}
code {{ background: #16213e; padding: 2px 6px; border-radius: 4px; font-family: 'Consolas', monospace; }}
pre {{ background: #16213e; padding: 15px; border-radius: 8px; overflow-x: auto; }}
pre code {{ background: none; padding: 0; }}
.function {{ background: #16213e; padding: 20px; margin: 20px 0; border-radius: 8px; }}
.line {{ color: #888; font-size: 0.9em; }}
a {{ color: #74c0fc; }}
a.back {{ display: inline-block; margin-bottom: 20px; }}
</style>
</head><body>
<a href="index.html" class="back">← Back to Index</a>
<h1>Module: <code>{module.name}</code></h1>
<p>{module.description or "No module description available."}</p>

<h2>Functions ({len(module.functions)})</h2>
{func_sections or "<p>No public functions documented.</p>"}

<p style="margin-top: 40px; color: #888;">Generated by OmniBus Doc Generator</p>
</body></html>"""
    
    return html


def main():
    parser = argparse.ArgumentParser(description="OmniBus API Documentation Generator")
    parser.add_argument("--module", help="Generate docs for specific module")
    parser.add_argument("--format", choices=["md", "html"], default="md", help="Output format")
    parser.add_argument("--output", type=Path, default=OUTPUT, help="Output directory")
    args = parser.parse_args()
    
    print("\n" + "=" * 60)
    print("  OmniBus API Documentation Generator")
    print("=" * 60)
    
    # Create output directory
    args.output.mkdir(parents=True, exist_ok=True)
    
    if args.module:
        # Single module
        filepath = CORE / f"{args.module}.zig"
        if not filepath.exists():
            print(f"ERROR: Module not found: {filepath}")
            sys.exit(1)
        
        print(f"\nParsing: {filepath.name}")
        module = parse_module(filepath)
        
        if args.format == "md":
            output = args.output / f"{module.name}.md"
            output.write_text(generate_markdown(module), encoding='utf-8')
        else:
            output = args.output / f"{module.name}.html"
            output.write_text(generate_html(module), encoding='utf-8')
        
        print(f"Generated: {output}")
    
    else:
        # All modules
        zig_files = sorted(CORE.glob("*.zig"))
        modules = []
        
        print(f"\nParsing {len(zig_files)} modules...\n")
        
        for i, filepath in enumerate(zig_files):
            print(f"  [{i+1}/{len(zig_files)}] {filepath.name:<40}", end='\r')
            module = parse_module(filepath)
            modules.append(module)
            
            if args.format == "md":
                output = args.output / f"{module.name}.md"
                output.write_text(generate_markdown(module), encoding='utf-8')
            else:
                output = args.output / f"{module.name}.html"
                output.write_text(generate_html(module), encoding='utf-8')
        
        print(" " * 60, end='\r')
        
        # Generate index
        if args.format == "html":
            index_path = args.output / "index.html"
            index_path.write_text(generate_html_index(modules), encoding='utf-8')
            print(f"\nIndex: {index_path}")
        
        # Generate summary
        total_funcs = sum(len(m.functions) for m in modules)
        total_structs = sum(len(m.structs) for m in modules)
        
        print(f"\n{'='*60}")
        print(f"  Generated {len(modules)} documentation files")
        print(f"  Total functions: {total_funcs}")
        print(f"  Total structs: {total_structs}")
        print(f"  Output: {args.output}")
        print(f"{'='*60}\n")

if __name__ == "__main__":
    main()
