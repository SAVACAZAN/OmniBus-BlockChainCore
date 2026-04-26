#!/usr/bin/env python3
"""
We-Are-Here-HodLum-WORKER.py
─────────────────────────────
Standalone OmniBus miner. Takes ONLY a public wallet address — never a
mnemonic. Block rewards go to that address; the mnemonic stays in your
desktop wallet (Liberty Suite, paper backup, hardware wallet).

This is how production blockchain miners work (Bitcoin: bitcoind +
external wallet; Ethereum: --miner.etherbase=0x...; Cosmos: separate
operator key from validator key). Mnemonic on a 24/7 internet-exposed
miner = bad. Public address only = safe.

Usage:
    # First time, set your reward address (one-line file, no quotes):
    mkdir -p "$HOME/.omnibus"
    echo 'OMNIBUS_MINER_ADDRESS=ob1qzhrauq0xe9hg033ccup7vlgsdmj6kcxyza9zp0' \\
        > "$HOME/.omnibus/miner.env"

    # Or pass it inline:
    python We-Are-Here-HodLum-WORKER.py --miner-address ob1q...

    # Run:
    python We-Are-Here-HodLum-WORKER.py [--chain testnet|regtest|mainnet]

Defaults: testnet, port 9101, seed = 38.143.19.97 (omnibusblockchain.cc).
"""
from __future__ import annotations

import argparse
import os
import shutil
import signal
import subprocess
import sys
from pathlib import Path

# ─── DEFAULTS — change here, not in CLI ─────────────────────────────────────
DEFAULTS = {
    "node_id":   "We-Are-Here-HodLum-WORKER",
    "port":      "9101",
    "seed_host": "38.143.19.97",
    "chain":     "testnet",
}
SEED_PORTS = {"mainnet": "9000", "testnet": "9001", "regtest": "9002"}

HERE = Path(__file__).resolve().parent
NODE_BIN = HERE / "zig-out" / "bin" / "omnibus-node.exe"
ENV_FILE = Path.home() / ".omnibus" / "miner.env"


class C:
    RESET   = "\x1b[0m"
    DIM     = "\x1b[2m"
    BOLD    = "\x1b[1m"
    # Foreground colors
    BLACK   = "\x1b[30m"
    RED     = "\x1b[31m"
    GREEN   = "\x1b[32m"
    YELLOW  = "\x1b[33m"
    BLUE    = "\x1b[34m"
    MAGENTA = "\x1b[35m"
    CYAN    = "\x1b[36m"
    WHITE   = "\x1b[37m"
    # Bright foregrounds — pop on dark terminals
    BR_RED     = "\x1b[91m"
    BR_GREEN   = "\x1b[92m"
    BR_YELLOW  = "\x1b[93m"
    BR_BLUE    = "\x1b[94m"
    BR_MAGENTA = "\x1b[95m"
    BR_CYAN    = "\x1b[96m"
    BR_WHITE   = "\x1b[97m"
    # Aliases used elsewhere in code
    OK    = "\x1b[92m"   # bright green
    WARN  = "\x1b[93m"   # bright yellow
    ERR   = "\x1b[91m"   # bright red
    INFO  = "\x1b[96m"   # bright cyan


# Enable ANSI colors on Windows console (cmd.exe / PowerShell pre-Win11)
def _enable_ansi_on_windows():
    if sys.platform != "win32":
        return
    try:
        import ctypes
        kernel32 = ctypes.windll.kernel32
        # ENABLE_VIRTUAL_TERMINAL_PROCESSING = 0x0004
        # STD_OUTPUT_HANDLE = -11
        h = kernel32.GetStdHandle(-11)
        mode = ctypes.c_ulong()
        if kernel32.GetConsoleMode(h, ctypes.byref(mode)):
            kernel32.SetConsoleMode(h, mode.value | 0x0004)
    except Exception:
        pass


_enable_ansi_on_windows()


def banner():
    print(f"""{C.BOLD}{C.BR_CYAN}╔══════════════════════════════════════════════════════╗{C.RESET}
{C.BOLD}{C.BR_CYAN}║{C.BR_MAGENTA}   We-Are-Here-HodLum-WORKER.py {C.BR_YELLOW}— address-only miner  {C.BR_CYAN}║{C.RESET}
{C.BOLD}{C.BR_CYAN}║{C.BR_GREEN}   No mnemonic on this machine. {C.BR_YELLOW}Rewards → address.    {C.BR_CYAN}║{C.RESET}
{C.BOLD}{C.BR_CYAN}║{C.DIM}{C.BR_WHITE}   Press {C.BR_RED}{C.BOLD}Ctrl+C{C.RESET}{C.BR_CYAN}{C.BOLD}{C.DIM}{C.BR_WHITE} anytime to stop the miner cleanly.   {C.BR_CYAN}{C.BOLD}║{C.RESET}
{C.BOLD}{C.BR_CYAN}╚══════════════════════════════════════════════════════╝{C.RESET}
""")


def load_address_from_env_file() -> str | None:
    """Read miner address from the env file. Tolerant to PowerShell's
    UTF-16-with-BOM default — `echo > file` on Windows produces
    UTF-16-LE with a 0xFF 0xFE prefix, which breaks naive UTF-8 reads.
    Try utf-8 first, then utf-16, then latin-1 as a last resort."""
    print(f"{C.DIM}[DEBUG] load_address_from_env_file: ENV_FILE = {ENV_FILE}{C.RESET}")
    print(f"{C.DIM}[DEBUG] is_file() = {ENV_FILE.is_file()}{C.RESET}")
    if not ENV_FILE.is_file():
        print(f"{C.DIM}[DEBUG] env file does not exist, returning None{C.RESET}")
        return None
    raw_bytes = ENV_FILE.read_bytes()
    print(f"{C.DIM}[DEBUG] read {len(raw_bytes)} bytes; first 8: {raw_bytes[:8]!r}{C.RESET}")
    # Strip BOMs / try a few encodings in order.
    text: str | None = None
    used_enc: str = ""
    for enc in ("utf-8-sig", "utf-16", "utf-8", "latin-1"):
        try:
            text = raw_bytes.decode(enc)
            used_enc = enc
            break
        except UnicodeDecodeError as e:
            print(f"{C.DIM}[DEBUG] decode {enc} failed: {e}{C.RESET}")
            continue
    if text is None:
        print(f"{C.ERR}[DEBUG] NO encoding worked!{C.RESET}")
        return None
    print(f"{C.DIM}[DEBUG] decoded with {used_enc}; text repr: {text!r}{C.RESET}")
    for line in text.splitlines():
        line = line.strip().lstrip("﻿")  # extra BOM safety
        print(f"{C.DIM}[DEBUG] line: {line!r}{C.RESET}")
        if line.startswith("OMNIBUS_MINER_ADDRESS="):
            addr = line.split("=", 1)[1].strip().strip('"').strip("'")
            if addr:
                print(f"{C.DIM}[DEBUG] found address: {addr!r}{C.RESET}")
                return addr
    print(f"{C.DIM}[DEBUG] no OMNIBUS_MINER_ADDRESS line found{C.RESET}")
    return None


def resolve_miner_address(cli_value: str | None) -> str:
    # Priority: CLI flag > env file > OMNIBUS_MINER_ADDRESS env var.
    addr = cli_value
    if not addr:
        addr = load_address_from_env_file()
    if not addr:
        addr = os.environ.get("OMNIBUS_MINER_ADDRESS")
    if not addr:
        print(f"{C.ERR}[ERROR]{C.RESET} No miner reward address provided.")
        print()
        print("Provide one of:")
        print(f"  1. CLI flag: --miner-address ob1q...")
        print(f"  2. Env file: {ENV_FILE}")
        print(f"     Contents: OMNIBUS_MINER_ADDRESS=ob1q...")
        print(f"  3. Env var: OMNIBUS_MINER_ADDRESS=ob1q... python {Path(__file__).name}")
        sys.exit(1)
    addr = addr.strip()
    if not addr.startswith("ob1q") or len(addr) < 30:
        print(f"{C.WARN}[WARN]{C.RESET} address doesn't look like an OmniBus address: {addr!r}")
        print(f"  Expected something like: ob1qzhrauq0xe9hg033ccup7vlgsdmj6kcxyza9zp0")
        print(f"  Continuing anyway...")
    return addr


def find_binary() -> Path:
    if NODE_BIN.is_file():
        return NODE_BIN
    found = shutil.which("omnibus-node.exe") or shutil.which("omnibus-node")
    if found:
        return Path(found)
    print(f"{C.ERR}[ERROR]{C.RESET} omnibus-node.exe not found at {NODE_BIN}")
    print("Build it first:")
    print(f"  cd \"{HERE}\"")
    print("  zig build -Doqs=false")
    sys.exit(1)


def colorize_log_line(line: str) -> str:
    if "[REWARD]" in line:
        return f"{C.OK}{line}{C.RESET}"
    if "[SLOT]" in line and "Not my turn" in line:
        return f"{C.DIM}{line}{C.RESET}"
    if "[SLOT]" in line and "Reject" in line:
        return f"{C.ERR}{line}{C.RESET}"
    if "[IBD]" in line:
        return f"{C.INFO}{line}{C.RESET}"
    if "[FORK-RECOVERY]" in line or "panic" in line.lower() or "Segfault" in line:
        return f"{C.ERR}{C.BOLD}{line}{C.RESET}"
    if "[MINER] Reward address" in line:
        return f"{C.OK}{C.BOLD}{line}{C.RESET}"
    if "[P2P] Connected to peer" in line or "[IBD] Exited" in line:
        return f"{C.OK}{line}{C.RESET}"
    if "WARN" in line or "[CHECKPOINT]" in line:
        return f"{C.WARN}{line}{C.RESET}"
    return line


def run_miner(args):
    binary = find_binary()
    miner_addr = resolve_miner_address(args.miner_address)
    seed_port = SEED_PORTS.get(args.chain, "9001")

    work_dir = Path.home() / ".omnibus" / "worker-data"
    work_dir.mkdir(parents=True, exist_ok=True)

    cmd = [
        str(binary),
        "--mode", "miner",
        "--chain", args.chain,
        "--node-id", args.node_id,
        "--port", args.port,
        "--seed-host", args.seed_host,
        "--seed-port", seed_port,
        "--miner-address", miner_addr,
    ]

    # Config panel — different color per field for instant scanability.
    print(f"{C.BR_CYAN}┌─ {C.BOLD}Config{C.RESET}{C.BR_CYAN} ─────────────────────────────────────────────────{C.RESET}")
    print(f"  {C.BR_BLUE}Binary:      {C.WHITE}{binary}{C.RESET}")
    print(f"  {C.BR_BLUE}Working dir: {C.WHITE}{work_dir}{C.RESET}")
    print(f"  {C.BR_MAGENTA}Chain:       {C.BR_YELLOW}{args.chain}{C.RESET}  {C.DIM}→{C.RESET}  {C.CYAN}seed {args.seed_host}:{seed_port}{C.RESET}")
    print(f"  {C.BR_MAGENTA}Node ID:     {C.BR_GREEN}{args.node_id}{C.RESET}")
    print(f"  {C.BR_MAGENTA}P2P port:    {C.BR_YELLOW}{args.port}{C.RESET}")
    print(f"  {C.BR_RED}Reward addr: {C.OK}{C.BOLD}>>> {miner_addr} <<<{C.RESET}")
    print(f"  {C.BR_BLUE}Mnemonic:    {C.GREEN}{C.DIM}(none on this machine — good){C.RESET}")
    print(f"{C.BR_CYAN}└──────────────────────────────────────────────────────────{C.RESET}")
    print(f"\n{C.DIM}{C.WHITE}$ {' '.join(cmd)}{C.RESET}\n")
    print(f"{C.BR_MAGENTA}{C.BOLD}─── miner output (Ctrl+C to stop) ───{C.RESET}")

    proc = subprocess.Popen(
        cmd,
        cwd=str(work_dir),
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        bufsize=1,
    )

    def on_sigint(_sig, _frame):
        print(f"\n{C.WARN}[CTRL-C]{C.RESET} stopping miner (PID {proc.pid})...")
        try:
            proc.terminate()
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            print(f"{C.ERR}timeout, killing{C.RESET}")
            proc.kill()
        sys.exit(0)

    signal.signal(signal.SIGINT, on_sigint)
    if hasattr(signal, "SIGBREAK"):
        signal.signal(signal.SIGBREAK, on_sigint)

    try:
        for line in proc.stdout:
            sys.stdout.write(colorize_log_line(line))
            sys.stdout.flush()
    except KeyboardInterrupt:
        on_sigint(None, None)
    finally:
        rc = proc.wait()
        print(f"\n{C.DIM}miner exited with code {rc}{C.RESET}")
        sys.exit(rc)


def main():
    parser = argparse.ArgumentParser(description="OmniBus address-only miner.")
    parser.add_argument("--miner-address", default=None,
                        help="OmniBus address that gets the block rewards. "
                             "Falls back to OMNIBUS_MINER_ADDRESS env or ~/.omnibus/miner.env.")
    parser.add_argument("--chain",     default=DEFAULTS["chain"],
                        choices=["mainnet", "testnet", "regtest"])
    parser.add_argument("--node-id",   default=DEFAULTS["node_id"])
    parser.add_argument("--port",      default=DEFAULTS["port"])
    parser.add_argument("--seed-host", default=DEFAULTS["seed_host"])
    args = parser.parse_args()

    banner()
    run_miner(args)


if __name__ == "__main__":
    main()
