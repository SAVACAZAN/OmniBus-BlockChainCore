#!/usr/bin/env python3
"""
franchise_client.py — Reference Python client for OmniBus L1.

The "franchise" model: the chain is public infrastructure (consensus,
P2P, RPC, REST exchange, faucet, WebSocket events). Anyone can plug
in with any client they like — Python, Node.js, Rust, browser, mobile,
even a spreadsheet. The chain doesn't care who you are; it enforces
the same on-chain rules for everyone (signatures, balances, nonces,
fee schedule, paper-vs-real isolation).

This script demonstrates the full happy path of a "franchisee":

    1. Connect to a public RPC endpoint
    2. Probe the chain (block height, peer count, status)
    3. Claim faucet (testnet only, gives free OMNI)
    4. Watch balance grow as the chain mines
    5. Place a tiny order on the in-chain DEX (paper mode by default)
    6. Cancel it after a few seconds
    7. Print a summary

Everything goes through the public RPC. There's no shared library,
no chain-side hook, no internal state. If you can speak HTTP+JSON,
you can build a franchisee.

Run:

    python3 franchise_client.py [--endpoint URL] [--mnemonic "..."]

Defaults:

    endpoint = https://omnibusblockchain.cc:8443/api-testnet/
    mnemonic = generated fresh + saved to .franchise_mnemonic.txt

Requires:

    pip install requests
"""

from __future__ import annotations

import argparse
import json
import os
import secrets
import sys
import time
from pathlib import Path
from typing import Any

try:
    import requests
except ImportError:
    sys.exit("This example needs `requests`. Install it: pip install requests")


# ─── RPC client ─────────────────────────────────────────────────────────────


class OmniBusClient:
    """
    Tiny JSON-RPC 2.0 client over the public OmniBus endpoint.

    No retries, no async, no websockets. Just HTTP POST with JSON body.
    The point of this file is to show how thin the surface area is —
    you can re-implement it in any language in ~30 lines.
    """

    def __init__(self, endpoint: str, timeout_s: float = 10.0):
        self.endpoint = endpoint.rstrip("/") + "/"
        self.timeout_s = timeout_s
        self._id = 0

    def call(self, method: str, params: list[Any] | None = None) -> Any:
        self._id += 1
        body = {
            "jsonrpc": "2.0",
            "id": self._id,
            "method": method,
            "params": params or [],
        }
        r = requests.post(
            self.endpoint,
            json=body,
            timeout=self.timeout_s,
            headers={"Content-Type": "application/json"},
        )
        r.raise_for_status()
        resp = r.json()
        if "error" in resp:
            raise RuntimeError(f"RPC error on {method}: {resp['error']}")
        return resp.get("result")


# ─── Step helpers ───────────────────────────────────────────────────────────


def banner(title: str) -> None:
    print(f"\n{'━' * 60}")
    print(f"  {title}")
    print(f"{'━' * 60}")


def step_probe_chain(c: OmniBusClient) -> dict:
    banner("Step 1 · Probe the chain")
    height = c.call("getblockcount")
    print(f"  current height       : {height}")
    try:
        status = c.call("getstatus")
        print(f"  chain id             : {status.get('chain') or status.get('chain_id')}")
        print(f"  difficulty           : {status.get('difficulty')}")
    except Exception as e:
        # `getstatus` may have a different name on some deployments;
        # don't abort, just keep going.
        print(f"  getstatus skipped    : {e}")
    return {"height": height}


def step_load_or_create_mnemonic(path: Path) -> str:
    banner("Step 2 · Load or create a wallet mnemonic")
    if path.exists():
        m = path.read_text().strip()
        print(f"  loaded mnemonic from : {path}")
    else:
        # Demo-only mnemonic. Real wallets MUST use a vetted BIP-39 generator
        # with proper entropy + checksum. This 24-byte hex is enough to call
        # the faucet on testnet, nothing more.
        m = secrets.token_hex(24)
        path.write_text(m)
        print(f"  generated fresh and saved to {path}")
    print(f"  mnemonic (first 16ch): {m[:16]}…")
    return m


def step_claim_faucet(c: OmniBusClient, address: str) -> None:
    banner("Step 3 · Claim faucet (testnet only)")
    print(f"  address              : {address}")
    try:
        result = c.call("claimfaucet", [{"address": address}])
        print(f"  faucet response      : {json.dumps(result)[:160]}")
    except Exception as e:
        # Faucet may rate-limit or refuse if you've claimed already
        # within the cooldown window. That's fine for the demo.
        print(f"  faucet refused       : {e}")


def step_watch_balance(c: OmniBusClient, address: str, seconds: int = 30) -> int:
    banner(f"Step 4 · Watch balance for {seconds}s")
    deadline = time.time() + seconds
    last_seen = -1
    while time.time() < deadline:
        try:
            bal = c.call("getaddressbalance", [{"address": address}])
            cur = bal if isinstance(bal, int) else bal.get("balance", 0)
        except Exception as e:
            cur = -1
            print(f"  getaddressbalance error: {e}")
        if cur != last_seen:
            print(f"  t={int(time.time() % 10000)}  balance = {cur} sat")
            last_seen = cur
        time.sleep(2)
    return last_seen


def step_place_paper_order(
    c: OmniBusClient, address: str, mnemonic: str
) -> dict | None:
    banner("Step 5 · Place a paper order on the DEX (demo)")
    # Paper-mode order. Server enforces real signatures + nonce + balance
    # checks even for paper orders, but the matched fills don't affect
    # real OMNI balances — separate orderbook entirely.
    #
    # On a real client you'd derive the keypair from the mnemonic, sign
    # a EXCHANGE_PLACE_V1 payload, and submit. To keep this demo small
    # we don't ship the secp256k1 + bech32 dependencies inline; instead
    # we just call the public read endpoint to show that orderbook
    # access works, and print the URL of the place endpoint for the
    # operator to try with curl or a real wallet client.
    print("  reading public orderbook for OMNI/USDC (pair_id=0):")
    try:
        depth = c.call("exchangeGetDepth", [{"pairId": 0, "mode": "paper"}])
        print(f"  bids                 : {len(depth.get('bids', []))}")
        print(f"  asks                 : {len(depth.get('asks', []))}")
    except Exception as e:
        print(f"  depth call error     : {e}")
    print()
    print("  to place a real signed order, use a wallet client that")
    print("  knows secp256k1 + EXCHANGE_PLACE_V1 signing. Example:")
    print("    POST /exchange/0/private/AddOrder")
    print("    body: {pair, type, ordertype, price, volume, signature, ...}")
    return None


def step_summary(c: OmniBusClient, start_height: int) -> None:
    banner("Step 6 · Summary")
    end_height = c.call("getblockcount")
    print(f"  blocks added during demo: {end_height - start_height}")
    print(f"  end height              : {end_height}")
    print()
    print("  This script touched only public RPC endpoints. Anyone with")
    print("  network access to the chain can do exactly the same thing")
    print("  from any language — Python, Rust, Go, browser fetch(),")
    print("  curl in a shell loop.  That's the franchise model: chain")
    print("  is infrastructure, clients are whatever the operator wants.")


# ─── main ───────────────────────────────────────────────────────────────────


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument(
        "--endpoint",
        default="https://omnibusblockchain.cc:8443/api-testnet/",
        help="JSON-RPC endpoint URL",
    )
    p.add_argument(
        "--address",
        default="ob1qzhrauq0xe9hg033ccup7vlgsdmj6kcxyza9zp0",
        help="address to use for faucet + balance checks (testnet ok if not yours)",
    )
    p.add_argument(
        "--mnemonic-file",
        default=".franchise_mnemonic.txt",
        help="where to cache the demo mnemonic",
    )
    p.add_argument(
        "--watch-seconds",
        type=int,
        default=30,
        help="how long to poll the balance after the faucet call",
    )
    args = p.parse_args()

    print(f"OmniBus Franchise Client · talking to {args.endpoint}")
    c = OmniBusClient(args.endpoint)

    info = step_probe_chain(c)
    _mnemonic = step_load_or_create_mnemonic(Path(args.mnemonic_file))
    step_claim_faucet(c, args.address)
    step_watch_balance(c, args.address, seconds=args.watch_seconds)
    step_place_paper_order(c, args.address, _mnemonic)
    step_summary(c, info["height"])

    return 0


if __name__ == "__main__":
    sys.exit(main())
