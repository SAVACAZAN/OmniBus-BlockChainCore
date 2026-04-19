#!/usr/bin/env python3
"""
Claude Chat Bridge — interactive chat via claude -p
Reads lines from stdin, sends each to claude -p, prints response.
Used by MYTHOS LAB Tauri app to embed Claude chat in a terminal widget.
"""
import subprocess
import sys
import os

sys.stdout.reconfigure(encoding='utf-8', errors='replace')
sys.stderr.reconfigure(encoding='utf-8', errors='replace')

WORK_DIR = os.path.dirname(os.path.abspath(__file__))
PROJ_ROOT = os.path.dirname(os.path.dirname(WORK_DIR))  # BlockChainCore root

print("=== Claude Chat Bridge ===", flush=True)
print(f"Working dir: {PROJ_ROOT}", flush=True)
print("Type your message and press Enter. Type 'exit' to quit.", flush=True)
print("Each message is sent to: claude -p \"your message\"", flush=True)
print("---", flush=True)

while True:
    try:
        sys.stdout.write("\nYou> ")
        sys.stdout.flush()
        line = sys.stdin.readline()
        if not line:
            break
        msg = line.strip()
        if not msg:
            continue
        if msg.lower() in ('exit', 'quit', '/exit', '/quit'):
            print("Goodbye!", flush=True)
            break

        print(f"\n[Sending to Claude...]", flush=True)

        try:
            result = subprocess.run(
                ['claude', '-p', msg],
                capture_output=True,
                text=True,
                encoding='utf-8',
                errors='replace',
                timeout=120,
                cwd=PROJ_ROOT
            )
            if result.stdout:
                print(f"\nClaude> {result.stdout.strip()}", flush=True)
            if result.stderr:
                for err_line in result.stderr.strip().split('\n'):
                    if 'Warning: no stdin' not in err_line:
                        print(f"[stderr] {err_line}", flush=True)
            if result.returncode != 0 and not result.stdout:
                print(f"[ERROR] Claude exited with code {result.returncode}", flush=True)
        except subprocess.TimeoutExpired:
            print("[ERROR] Claude timed out (120s)", flush=True)
        except FileNotFoundError:
            print("[ERROR] 'claude' not found in PATH. Install Claude Code CLI first.", flush=True)
            break

    except KeyboardInterrupt:
        print("\nInterrupted.", flush=True)
        break
    except EOFError:
        break

print("--- Chat ended ---", flush=True)
