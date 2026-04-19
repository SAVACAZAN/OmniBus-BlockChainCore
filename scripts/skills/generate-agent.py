#!/usr/bin/env python3
"""
OmniBus Blockchain Core — Claude Agent Generator

Generates a .claude/agents/<name>.md file from a template with
proper YAML frontmatter. Takes --name, --model, --description args.
"""

import argparse
import os
import sys
from datetime import datetime, timezone

# ANSI colors
GREEN = "\033[92m"
RED = "\033[91m"
YELLOW = "\033[93m"
CYAN = "\033[96m"
DIM = "\033[2m"
RESET = "\033[0m"


AGENT_TEMPLATE = """---
name: "{name}"
model: "{model}"
description: "{description}"
created: "{created}"
version: "1.0"
tags:
  - omnibus
  - blockchain
  - {domain}
---

# {title}

## Role

{description}

## Model

`{model}`

## Capabilities

- Analyze and improve OmniBus blockchain components in `core/`
- Generate tests, benchmarks, and documentation
- Review Zig 0.15.2 code for correctness, safety, and performance
- Work with secp256k1, BIP-32/39, post-quantum crypto (liboqs)
- Understand Casper FFG consensus and 4-shard architecture

## Tools

- **Zig 0.15.2** — bare-metal blockchain core
- **Python 3.12** — scripts, testing, tooling
- **Bash / PowerShell** — devops, deployment
- **Node.js** — miner client, frontend tooling

## Workspace

```
OmniBus-BlockChainCore/
├── core/          # Zig modules (secp256k1, p2p, rpc, wallet, etc.)
├── frontend/      # React + TypeScript dashboard
├── scripts/       # Python/Bash devops & tools
├── test/          # Standalone test files
└── build.zig      # Build system
```

## Guidelines

1. **No malloc/free in Zig** — use fixed-size arrays or stack allocations
2. **No floating-point** — use fixed-point scaled integers for prices (1 OMNI = 1e9 sat)
3. **Pure Zig crypto** — secp256k1, RIPEMD-160, BIP-32 are all implemented from scratch
4. **Tests inline** — each `core/*.zig` file contains its own `test` blocks
5. **JSON-RPC 2.0** — all RPC methods follow the standard, port 8332
6. **Minimal changes** — focused, single-purpose commits

## Ports

| Service   | Port |
|-----------|------|
| RPC HTTP  | 8332 |
| WebSocket | 8334 |
| P2P       | 9000+|

## Key Commands

```bash
zig build              # Build node binary
zig build test         # Run all tests
zig build run          # Start node
```

## Created

{created}
"""


def generate_agent(
    name: str,
    model: str,
    description: str,
    output_dir: str,
) -> str:
    """Generate agent file and return the output path."""
    # Derive title from name
    title = name.replace("-", " ").replace("_", " ").title()

    # Derive domain tag from name
    domain_keywords = {
        "crypto": "cryptography",
        "wallet": "wallet",
        "p2p": "networking",
        "network": "networking",
        "rpc": "rpc",
        "mining": "mining",
        "miner": "mining",
        "consensus": "consensus",
        "shard": "sharding",
        "storage": "storage",
        "frontend": "frontend",
        "test": "testing",
    }
    domain = "core"
    name_lower = name.lower()
    for keyword, tag in domain_keywords.items():
        if keyword in name_lower:
            domain = tag
            break

    created = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    content = AGENT_TEMPLATE.format(
        name=name,
        title=title,
        model=model,
        description=description,
        domain=domain,
        created=created,
    )

    # Create output directory
    os.makedirs(output_dir, exist_ok=True)

    # Write file
    filename = f"{name}.md"
    filepath = os.path.join(output_dir, filename)
    with open(filepath, "w", encoding="utf-8") as f:
        f.write(content)

    return filepath


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Generate a Claude agent .md file with YAML frontmatter"
    )
    parser.add_argument(
        "--name", required=True,
        help="Agent slug name (e.g., blockchain-auditor, crypto-reviewer)"
    )
    parser.add_argument(
        "--model", default="claude-sonnet-4-20250514",
        help="Model identifier (default: claude-sonnet-4-20250514)"
    )
    parser.add_argument(
        "--description", default="OmniBus Blockchain Core specialist agent",
        help="Agent description / role summary"
    )
    parser.add_argument(
        "--output-dir", default=None,
        help="Output directory (default: .claude/agents/ relative to project root)"
    )
    args = parser.parse_args()

    # Resolve output directory
    if args.output_dir:
        out_dir = args.output_dir
    else:
        script_dir = os.path.dirname(os.path.abspath(__file__))
        project_root = os.path.abspath(os.path.join(script_dir, "..", ".."))
        out_dir = os.path.join(project_root, ".claude", "agents")

    print(f"{CYAN}=== OmniBus Agent Generator ==={RESET}")
    print(f"{DIM}Name:        {args.name}{RESET}")
    print(f"{DIM}Model:       {args.model}{RESET}")
    print(f"{DIM}Description: {args.description}{RESET}")
    print(f"{DIM}Output dir:  {out_dir}{RESET}")
    print()

    filepath = generate_agent(
        name=args.name,
        model=args.model,
        description=args.description,
        output_dir=out_dir,
    )

    print(f"{GREEN}[DONE]{RESET} Agent created: {filepath}")
    print(f"{DIM}Preview the first few lines:{RESET}")
    with open(filepath, "r") as f:
        for i, line in enumerate(f):
            if i >= 12:
                print(f"{DIM}  ...{RESET}")
                break
            print(f"{DIM}  {line.rstrip()}{RESET}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
