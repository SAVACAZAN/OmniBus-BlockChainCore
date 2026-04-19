#!/usr/bin/env python3
"""
OmniBus Blockchain Core — Multisig Transaction Coordinator

Helper for creating and collecting signatures for multisig transactions.
"""

import argparse
import hashlib
import json
import os
import sys
from typing import Any, Dict, List

GREEN = "\033[92m"
RED = "\033[91m"
YELLOW = "\033[93m"
RESET = "\033[0m"


def cprint(color: str, msg: str) -> None:
    print(f"{color}{msg}{RESET}")


def create_multisig_tx(inputs: List[Dict], outputs: List[Dict], m: int, n: int, pubkeys: List[str]) -> Dict[str, Any]:
    tx = {
        "version": 1,
        "inputs": inputs,
        "outputs": outputs,
        "multisig": {"m": m, "n": n, "pubkeys": pubkeys, "signatures": []},
        "txid": "",
    }
    # Compute placeholder txid
    tx_bytes = json.dumps(tx, sort_keys=True).encode()
    tx["txid"] = hashlib.sha256(tx_bytes).hexdigest()[:64]
    return tx


def add_signature(tx: Dict[str, Any], pubkey: str, signature_hex: str) -> Dict[str, Any]:
    sigs = tx["multisig"]["signatures"]
    # Prevent duplicate pubkey signatures
    for s in sigs:
        if s["pubkey"] == pubkey:
            cprint(YELLOW, f"Replacing signature for {pubkey}")
            s["signature"] = signature_hex
            return tx
    sigs.append({"pubkey": pubkey, "signature": signature_hex})
    return tx


def finalize_tx(tx: Dict[str, Any]) -> bool:
    m = tx["multisig"]["m"]
    if len(tx["multisig"]["signatures"]) >= m:
        cprint(GREEN, f"Transaction finalized with {len(tx['multisig']['signatures'])}/{m} signatures")
        return True
    else:
        cprint(RED, f"Not enough signatures: {len(tx['multisig']['signatures'])}/{m}")
        return False


def main() -> int:
    parser = argparse.ArgumentParser(description="Multisig transaction coordinator")
    sub = parser.add_subparsers(dest="cmd")

    create_p = sub.add_parser("create", help="Create a multisig tx template")
    create_p.add_argument("--m", type=int, required=True, help="Required signatures")
    create_p.add_argument("--n", type=int, required=True, help="Total signers")
    create_p.add_argument("--pubkeys", nargs="+", required=True, help="Public keys")
    create_p.add_argument("--output", default="multisig-tx.json", help="Output file")

    sign_p = sub.add_parser("sign", help="Add a signature")
    sign_p.add_argument("--tx", required=True, help="Tx file")
    sign_p.add_argument("--pubkey", required=True, help="Signer pubkey")
    sign_p.add_argument("--signature", required=True, help="Signature hex")
    sign_p.add_argument("--output", default="multisig-tx.json", help="Output file")

    finalize_p = sub.add_parser("finalize", help="Check if tx is ready to broadcast")
    finalize_p.add_argument("--tx", required=True, help="Tx file")

    args = parser.parse_args()

    if args.cmd == "create":
        tx = create_multisig_tx([], [], args.m, args.n, args.pubkeys)
        with open(args.output, "w", encoding="utf-8") as f:
            json.dump(tx, f, indent=2)
        cprint(GREEN, f"Created {args.m}-of-{args.n} multisig tx -> {args.output}")
        return 0

    if args.cmd == "sign":
        with open(args.tx, "r", encoding="utf-8") as f:
            tx = json.load(f)
        tx = add_signature(tx, args.pubkey, args.signature)
        with open(args.output, "w", encoding="utf-8") as f:
            json.dump(tx, f, indent=2)
        cprint(GREEN, f"Added signature -> {args.output}")
        return 0

    if args.cmd == "finalize":
        with open(args.tx, "r", encoding="utf-8") as f:
            tx = json.load(f)
        ok = finalize_tx(tx)
        return 0 if ok else 1

    parser.print_help()
    return 1


if __name__ == "__main__":
    sys.exit(main())
