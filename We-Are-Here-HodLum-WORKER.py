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
    RESET = "\x1b[0m"
    DIM   = "\x1b[2m"
    OK    = "\x1b[32m"
    WARN  = "\x1b[33m"
    ERR   = "\x1b[31m"
    INFO  = "\x1b[36m"
    BOLD  = "\x1b[1m"


def banner():
    print(f"""{C.BOLD}{C.INFO}
╔══════════════════════════════════════════════════════╗
║   We-Are-Here-HodLum-WORKER.py — address-only miner  ║
║   No mnemonic on this machine. Rewards → address.    ║
╚══════════════════════════════════════════════════════╝{C.RESET}
""")


def load_address_from_env_file() -> str | None:
    if not ENV_FILE.is_file():
        return None
    for line in ENV_FILE.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if line.startswith("OMNIBUS_MINER_ADDRESS="):
            addr = line.split("=", 1)[1].strip().strip('"').strip("'")
            if addr:
                return addr
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

    print(f"{C.INFO}Binary:        {C.RESET}{binary}")
    print(f"{C.INFO}Working dir:   {C.RESET}{work_dir}")
    print(f"{C.INFO}Chain:         {C.RESET}{args.chain}  →  seed {args.seed_host}:{seed_port}")
    print(f"{C.INFO}Node ID:       {C.RESET}{args.node_id}")
    print(f"{C.INFO}P2P port:      {C.RESET}{args.port}")
    print(f"{C.INFO}Reward addr:   {C.OK}{miner_addr}{C.RESET}")
    print(f"{C.INFO}Mnemonic:      {C.DIM}none on this machine (good){C.RESET}")
    print(f"\n{C.DIM}# {' '.join(cmd)}{C.RESET}\n")
    print(f"{C.BOLD}─── miner output ───{C.RESET}")

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
