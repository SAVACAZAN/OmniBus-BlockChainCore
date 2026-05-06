#!/usr/bin/env python3
"""
bootstrap-context.py — Generate INFRASTRUCTURE.md describing the live state of
the BlockChainCore project: VPS hosts, SSH config, git remotes, branches,
running services, ports, build commands. Auto-discovered, not hand-written.

WHY
---
Every new agent / Claude session needs to re-learn the same trivia:
  - which VPS, which port, which user
  - where the repo lives on VPS
  - which branch is live, which commit is on prod
  - how to deploy, how to restart
This script reads it from real sources (git, ~/.ssh/config, optional VPS query)
and writes a single Markdown doc that any agent reads first.

USAGE
-----
    python tools/bootstrap-context.py                       # local-only (fast)
    python tools/bootstrap-context.py --query-vps           # also SSH to VPS for live state
    python tools/bootstrap-context.py --output STATUS/INFRASTRUCTURE.md
"""

from __future__ import annotations
import argparse
import json
import os
import platform
import re
import shutil
import socket
import subprocess
import sys
from datetime import date
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parent

# ── Helpers ──────────────────────────────────────────────────────────────────

def run(cmd: list[str], cwd: Path | None = None, timeout: int = 15) -> str:
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout,
                             encoding="utf-8", errors="replace",
                             cwd=str(cwd) if cwd else None)
        s = out.stdout if out.stdout else ""
        return s.strip()
    except (OSError, subprocess.TimeoutExpired) as e:
        return f"<error: {e}>"
    except FileNotFoundError as e:
        return f"<not found: {e}>"


def read_file(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return ""


# ── Discovery ────────────────────────────────────────────────────────────────

def discover_git(repo: Path) -> dict:
    info = {}
    info["branch"] = run(["git", "branch", "--show-current"], cwd=repo)
    info["head"] = run(["git", "log", "-1", "--format=%h %s", "HEAD"], cwd=repo)
    raw_remotes = run(["git", "remote", "-v"], cwd=repo)
    remotes: dict[str, dict] = {}
    for line in raw_remotes.splitlines():
        parts = line.split()
        if len(parts) >= 3:
            name, url, kind = parts[0], parts[1], parts[2].strip("()")
            r = remotes.setdefault(name, {})
            r[kind] = redact_url(url)
    info["remotes"] = remotes
    raw_branches = run(["git", "branch", "-a"], cwd=repo)
    info["branches"] = [b.strip().lstrip("* ") for b in raw_branches.splitlines() if b.strip()]
    info["uncommitted"] = run(["git", "status", "--short"], cwd=repo).splitlines()[:20]
    info["recent_commits"] = run(["git", "log", "--oneline", "-10"], cwd=repo).splitlines()
    return info


def redact_url(url: str) -> str:
    # Hide tokens in URLs like http://user:TOKEN@host
    return re.sub(r"://([^:]+):[^@]+@", r"://\1:***@", url)


def discover_ssh() -> list[dict]:
    """Read ~/.ssh/config and pull out Host entries."""
    home = Path.home()
    cfg = home / ".ssh" / "config"
    if not cfg.exists():
        return []
    entries: list[dict] = []
    current: dict | None = None
    for raw in read_file(cfg).splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.lower().startswith("host "):
            if current and current.get("alias"):
                entries.append(current)
            current = {"alias": line.split(None, 1)[1]}
        elif current is not None and " " in line:
            k, v = line.split(None, 1)
            current[k.lower()] = v
    if current and current.get("alias"):
        entries.append(current)
    # Skip wildcards
    return [e for e in entries if "*" not in e.get("alias", "") and "?" not in e.get("alias", "")]


def discover_local_env(repo: Path) -> dict:
    return {
        "platform": platform.platform(),
        "python": sys.version.split()[0],
        "shell": os.environ.get("SHELL") or os.environ.get("ComSpec", "?"),
        "cwd": os.getcwd(),
        "user": os.environ.get("USER") or os.environ.get("USERNAME", "?"),
        "hostname": socket.gethostname(),
        "zig": shutil.which("zig") or "<not in PATH>",
        "node": shutil.which("node") or "<not in PATH>",
        "ssh": shutil.which("ssh") or "<not in PATH>",
    }


def query_vps(host: str) -> dict:
    """Optionally SSH to VPS and pull live state."""
    info: dict = {"host": host}
    info["uname"]    = run(["ssh", "-o", "ConnectTimeout=10", host, "uname -srm"], timeout=20)
    info["uptime"]   = run(["ssh", host, "uptime"], timeout=20)
    info["services"] = run(["ssh", host, "systemctl list-units --type=service --state=running 2>/dev/null | grep -i omnibus"], timeout=20).splitlines()
    info["ports"]    = run(["ssh", host, "ss -tln 2>/dev/null | awk 'NR>1 {print $4}' | sort -u | head -40"], timeout=20).splitlines()
    info["repo"]     = run(["ssh", host, "cd /root/omnibus-blockchain 2>/dev/null && git log -1 --format='%h %s' && git branch --show-current"], timeout=20)
    return info


# ── Render ───────────────────────────────────────────────────────────────────

def render(repo: Path, git_info: dict, ssh_info: list[dict], env_info: dict,
           vps_info: dict | None) -> str:
    today = date.today().isoformat()
    out: list[str] = []
    out.append(f"# BlockChainCore — Infrastructure Snapshot ({today})")
    out.append("")
    out.append("Auto-generated by `tools/bootstrap-context.py`. **Read this first.**")
    out.append("")
    out.append("## Local environment")
    out.append("")
    out.append(f"- **OS:** {env_info['platform']}")
    out.append(f"- **Hostname:** `{env_info['hostname']}`")
    out.append(f"- **User:** `{env_info['user']}`")
    out.append(f"- **CWD:** `{env_info['cwd']}`")
    out.append(f"- **Python:** {env_info['python']}")
    out.append(f"- **zig:** `{env_info['zig']}`")
    out.append(f"- **node:** `{env_info['node']}`")
    out.append(f"- **ssh:** `{env_info['ssh']}`")
    out.append("")
    out.append(f"- **Repo path:** `{repo}`")
    out.append("")

    out.append("## Git")
    out.append("")
    out.append(f"- **Branch:** `{git_info['branch']}`")
    out.append(f"- **HEAD:** `{git_info['head']}`")
    out.append("")
    out.append("**Remotes (tokens redacted):**")
    out.append("")
    for name, urls in git_info["remotes"].items():
        for kind, url in urls.items():
            out.append(f"- `{name}` ({kind}): `{url}`")
    out.append("")
    out.append("**Local branches:**")
    out.append("")
    for b in git_info["branches"][:20]:
        out.append(f"- `{b}`")
    if len(git_info["branches"]) > 20:
        out.append(f"- ... ({len(git_info['branches']) - 20} more)")
    out.append("")
    if git_info["uncommitted"]:
        out.append("**Uncommitted changes (first 20 lines):**")
        out.append("")
        out.append("```")
        for line in git_info["uncommitted"]:
            out.append(line)
        out.append("```")
        out.append("")
    out.append("**Recent commits:**")
    out.append("")
    out.append("```")
    for c in git_info["recent_commits"]:
        out.append(c)
    out.append("```")
    out.append("")

    out.append("## SSH hosts (from `~/.ssh/config`)")
    out.append("")
    if not ssh_info:
        out.append("_No `~/.ssh/config` found or no host entries._")
    else:
        out.append("| Alias | HostName | User | IdentityFile |")
        out.append("|---|---|---|---|")
        for e in ssh_info:
            out.append(f"| `{e.get('alias','?')}` | `{e.get('hostname','?')}` | `{e.get('user','?')}` | `{e.get('identityfile','?')}` |")
    out.append("")

    if vps_info:
        out.append(f"## VPS live state (`{vps_info['host']}`)")
        out.append("")
        out.append(f"- **Uname:** `{vps_info.get('uname','?')}`")
        out.append(f"- **Uptime:** `{vps_info.get('uptime','?')}`")
        out.append("")
        out.append("**Services running (omnibus*):**")
        out.append("")
        out.append("```")
        for s in vps_info.get("services", []):
            out.append(s)
        out.append("```")
        out.append("")
        out.append("**Listening ports:**")
        out.append("")
        out.append("```")
        for p in vps_info.get("ports", []):
            out.append(p)
        out.append("```")
        out.append("")
        out.append("**Repo on VPS (`/root/omnibus-blockchain`):**")
        out.append("")
        out.append("```")
        out.append(vps_info.get("repo", "?"))
        out.append("```")
        out.append("")

    out.append("## Canonical commands (BlockChainCore)")
    out.append("")
    out.append("```bash")
    out.append("# Build (Windows local)")
    out.append("zig build")
    out.append("")
    out.append("# Build with PQ (liboqs)")
    out.append("zig build -Doptimize=ReleaseSafe -Doqs=true")
    out.append("")
    out.append("# Run seed node (mainnet)")
    out.append("./zig-out/bin/omnibus-node.exe --mode seed --node-id node-1 --port 9000")
    out.append("")
    out.append("# Tests")
    out.append("zig build test           # all (no liboqs)")
    out.append("zig build test-crypto    # secp256k1, bip32, etc.")
    out.append("zig build test-pq        # PQ pure-Zig (no liboqs)")
    out.append("zig build test-wallet    # wallet (requires liboqs)")
    out.append("")
    out.append("# VPS deploy via git bundle (no token needed)")
    out.append("git bundle create /tmp/deploy.bundle <last-vps-commit>..HEAD")
    out.append("scp /tmp/deploy.bundle omnibus-vps:/tmp/")
    out.append("ssh omnibus-vps 'cd /root/omnibus-blockchain && git fetch /tmp/deploy.bundle <branch>:<branch>-NEW && git reset --hard <branch>-NEW'")
    out.append("ssh omnibus-vps 'cd /root/omnibus-blockchain && rm -rf .zig-cache zig-out && zig build -Doptimize=ReleaseSafe -Doqs=true'")
    out.append("ssh omnibus-vps 'systemctl restart omnibus-testnet'")
    out.append("```")
    out.append("")

    out.append("## Audit tools")
    out.append("")
    out.append("- `tools/audit-pq-conventions.py` — scan PQ prefix/scheme drift across codebase")
    out.append("- `tools/inventory-md.py` — classify all `.md` files (KEEP / ARCHIVE / REVIEW)")
    out.append("- `tools/consolidate-status.py` — extract TODO/DONE/BLOCKED into single STATUS.md")
    out.append("- `tools/bootstrap-context.py` — this file (run again to refresh)")
    out.append("")

    return "\n".join(out) + "\n"


# ── Main ─────────────────────────────────────────────────────────────────────

def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=None)
    ap.add_argument("--output", default=None)
    ap.add_argument("--query-vps", default=None,
                    help="SSH alias of VPS to query for live state (e.g., omnibus-vps)")
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()

    repo = Path(args.root).resolve() if args.root else REPO_ROOT
    git_info = discover_git(repo)
    ssh_info = discover_ssh()
    env_info = discover_local_env(repo)
    vps_info = query_vps(args.query_vps) if args.query_vps else None

    if args.json:
        payload = {"git": git_info, "ssh": ssh_info, "env": env_info, "vps": vps_info}
        json.dump(payload, sys.stdout, indent=2)
        sys.stdout.write("\n")
        return 0

    out_path = Path(args.output) if args.output else repo / "STATUS" / "INFRASTRUCTURE.md"
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(render(repo, git_info, ssh_info, env_info, vps_info), encoding="utf-8")
    print(f"Wrote: {out_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
