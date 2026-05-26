#!/usr/bin/env python3
"""
OmniBus Blockchain Core — JSON-RPC 2.0 Test Suite (multi-chain, full coverage).

Updated 2026-05-10 to cover the full current RPC surface (stake/validators,
agents, reputation, names+, notarize, subscriptions, escrow, channels,
multisig, oracle, grid, htlc/bridge/swap).

Usage:
    python rpc-tester.py                                # mainnet (default)
    python rpc-tester.py --chain testnet
    python rpc-tester.py --chain regtest
    python rpc-tester.py --rpc http://127.0.0.1:8332    # explicit override
    python rpc-tester.py --token "$OMNIBUS_RPC_TOKEN"   # bearer for non-loopback
    python rpc-tester.py --json --output report.json
    python rpc-tester.py --skip-stress                  # don't run flood phase

Each method sends minimal valid params (or empty []). Any non-error response is
PASS, "method not found" is SKIP, anything else is FAIL.

stdlib-only (urllib + threading); NO external deps required.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import threading
import time
import urllib.request
import urllib.error
from concurrent.futures import ThreadPoolExecutor, as_completed
from typing import Any, Dict, List, Optional, Tuple

GREEN = "\033[92m"
RED = "\033[91m"
YELLOW = "\033[93m"
CYAN = "\033[96m"
RESET = "\033[0m"


def cprint(color: str, msg: str) -> None:
    print(f"{color}{msg}{RESET}")


# ── Multi-chain endpoint table ───────────────────────────────────────────────

CHAIN_URLS = {
    "mainnet":       "https://omnibusblockchain.cc:8443/api-mainnet",
    "testnet":       "https://omnibusblockchain.cc:8443/api-testnet",
    "regtest":       "https://omnibusblockchain.cc:8443/api-regtest",
    "local-mainnet": "http://127.0.0.1:8332",
    "local-testnet": "http://127.0.0.1:18332",
    "local-regtest": "http://127.0.0.1:28332",
}

# ── RPC method catalogue (grouped) ───────────────────────────────────────────
# Each entry = (method, params). Use minimal valid params or [] if optional.

KNOWN_ADDR    = "ob1qzhrauq0xe9hg033ccup7vlgsdmj6kcxyza9zp0"
KNOWN_NAME    = "savacazan.omnibus"
KNOWN_FOREIGN = "0x000000000000000000000000000000000000dEaD"
ZERO_HASH     = "0" * 64

CORE_METHODS: List[Tuple[str, List[Any]]] = [
    ("getblockchaininfo",  []),
    ("getblockcount",      []),
    ("getbestblockhash",   []),
    ("getblock",           [ZERO_HASH]),
    ("getrawmempool",      []),
    ("getmempoolinfo",     []),
    ("getpeerinfo",        []),
    ("getnetworkinfo",     []),
    ("getnonce",           [KNOWN_ADDR]),
    ("getbalance",         [{"address": KNOWN_ADDR}]),
    ("getrichlist",        []),
    ("listunspent",        [{"address": KNOWN_ADDR}]),
]

STAKE_METHODS: List[Tuple[str, List[Any]]] = [
    ("getstake",           [KNOWN_ADDR]),
    ("getstakers",         []),
    ("getvalidators",      []),
    ("getvalidatorsv2",    []),
    ("validator_heartbeat",[{"validator": KNOWN_ADDR}]),
    ("getslashevents",     []),
    ("become_validator",   [{"address": KNOWN_ADDR, "stake": 100}]),
    ("stake",              [{"address": KNOWN_ADDR, "amount": 1}]),
    ("unstake",            [{"address": KNOWN_ADDR, "amount": 1}]),
]

AGENT_METHODS: List[Tuple[str, List[Any]]] = [
    ("getagents",          []),
    ("agent_list",         []),
    ("getagent",           [{"address": KNOWN_ADDR}]),
    ("agent_register",     [{"name": "stress-agent", "owner": KNOWN_ADDR}]),
    ("agent_unregister",   [{"name": "stress-agent"}]),
    ("agent_edit",         [{"name": "stress-agent", "metadata": "{}"}]),
    ("agent_follow",       [{"name": "stress-agent", "follower": KNOWN_ADDR}]),
]

REPUTATION_METHODS: List[Tuple[str, List[Any]]] = [
    ("getreputation",      [KNOWN_ADDR]),
    ("getreputationtop",   []),
]

NAMES_METHODS: List[Tuple[str, List[Any]]] = [
    ("resolvename",        [KNOWN_NAME]),
    ("reverseresolvename", [KNOWN_ADDR]),
    ("registername",       [{"name": "stress-test.omnibus", "address": KNOWN_ADDR, "years": 1}]),
    ("transfername",       [{"name": "stress-test.omnibus", "new_owner": KNOWN_ADDR}]),
    ("renewname",          [{"name": "stress-test.omnibus", "years": 1}]),
    ("ns_listTlds",        []),
    ("ns_getensfee",       [{"tld": "omnibus"}]),
    ("ns_yearTiers",       []),
    ("ns_stats",           []),
    ("ns_getNamesByCategory", [{"category": "omnibus"}]),
    ("ns_expiringSoon",    [{"within_blocks": 100000}]),
]

NOTARIZE_METHODS: List[Tuple[str, List[Any]]] = [
    ("notarizedoc",        [{"hash": ZERO_HASH, "owner": KNOWN_ADDR}]),
    ("verifynotarize",     [{"hash": ZERO_HASH}]),
    ("revokenotarize",     [{"hash": ZERO_HASH}]),
    ("getnotarizations",   [{"owner": KNOWN_ADDR}]),
]

SUB_METHODS: List[Tuple[str, List[Any]]] = [
    ("sub_create",         [{"merchant": KNOWN_ADDR, "subscriber": KNOWN_ADDR, "amount": 1, "interval_blocks": 100}]),
    ("sub_cancel",         [{"sub_id": 0}]),
    ("getsubscriptions",   [{"address": KNOWN_ADDR}]),
]

ESCROW_METHODS: List[Tuple[str, List[Any]]] = [
    ("escrow_create",      [{"buyer": KNOWN_ADDR, "seller": KNOWN_ADDR, "arbiter": KNOWN_ADDR, "amount": 1}]),
    ("escrow_release",     [{"escrow_id": 0}]),
    ("escrow_refund",      [{"escrow_id": 0}]),
    ("escrow_dispute",     [{"escrow_id": 0}]),
    ("getescrow",          [{"escrow_id": 0}]),
    ("getescrows",         [{"address": KNOWN_ADDR}]),
]

CHANNEL_METHODS: List[Tuple[str, List[Any]]] = [
    ("openchannel",        [{"counterparty": KNOWN_ADDR, "capacity": 1_000_000}]),
    ("channelpay",         [{"channel_id": 0, "amount": 1}]),
    ("closechannel",       [{"channel_id": 0}]),
    ("getchannels",        [{"address": KNOWN_ADDR}]),
]

MULTISIG_METHODS: List[Tuple[str, List[Any]]] = [
    ("createmultisig",     [{"signers": [KNOWN_ADDR], "threshold": 1}]),
    ("sendmultisig",       [{"multisig": KNOWN_ADDR, "to": KNOWN_ADDR, "amount": 1}]),
]

ORACLE_METHODS: List[Tuple[str, List[Any]]] = [
    ("omnibus_getexchangefeed", []),
    ("omnibus_getallprices",    []),
    ("omnibus_getarbitrage",    []),
    ("omnibus_getoracleprices", []),
    ("omnibus_getoraclepolicy", []),
]

GRID_METHODS: List[Tuple[str, List[Any]]] = [
    ("grid_create",        [{"pair_id": 0, "price_low": 1, "price_high": 2,
                             "levels": 5, "total_base": 10, "total_quote": 10,
                             "owner": KNOWN_ADDR}]),
    ("grid_cancel",        [{"grid_id": 0}]),
    ("grid_list",          [{"owner": KNOWN_ADDR}]),
    ("grid_status",        [{"grid_id": 0}]),
]

EXCHANGE_METHODS: List[Tuple[str, List[Any]]] = [
    ("exchange_listPairs",      []),
    ("exchange_pairInfo",       [{"pair_id": 0}]),
    ("exchange_listOrders",     [{"pair_id": 0}]),
    ("exchange_getUserOrders",  [{"trader": KNOWN_ADDR}]),
    ("exchange_getRecentTrades",[{"pair_id": 0, "limit": 10}]),
]

HTLC_METHODS: List[Tuple[str, List[Any]]] = [
    ("htlc_init",          [{"hash_lock": ZERO_HASH, "amount": 1, "timeout_blocks": 100,
                             "maker": KNOWN_ADDR, "taker": KNOWN_FOREIGN}]),
    ("htlc_claim",         [{"htlc_id": 0, "preimage": ZERO_HASH}]),
    ("htlc_refund",        [{"htlc_id": 0}]),
    ("bridge_lock",        [{"chain": "ETH", "address": KNOWN_FOREIGN, "amount": 1}]),
    ("bridge_settle",      [{"bridge_id": 0}]),
    ("swap_open",          [{"pair": "OMNI-ETH", "hash_lock": ZERO_HASH,
                             "maker_amount": 1, "taker_amount": 1, "timeout_blocks": 100,
                             "maker_address": KNOWN_ADDR, "taker_address": KNOWN_FOREIGN}]),
    ("swap_lockMaker",     [{"swap_id": 0}]),
    ("swap_lockTaker",     [{"swap_id": 0}]),
    ("swap_proveSettle",   [{"swap_id": 0, "preimage": ZERO_HASH}]),
    ("swap_refund",        [{"swap_id": 0}]),
]

GROUPS = [
    ("Core",        CORE_METHODS),
    ("Stake",       STAKE_METHODS),
    ("Agents",      AGENT_METHODS),
    ("Reputation",  REPUTATION_METHODS),
    ("Names",       NAMES_METHODS),
    ("Notarize",    NOTARIZE_METHODS),
    ("Subscriptions", SUB_METHODS),
    ("Escrow",      ESCROW_METHODS),
    ("Channels",    CHANNEL_METHODS),
    ("Multisig",    MULTISIG_METHODS),
    ("Oracle",      ORACLE_METHODS),
    ("Grid",        GRID_METHODS),
    ("Exchange",    EXCHANGE_METHODS),
    ("HTLC/Bridge", HTLC_METHODS),
]


# ── Tester ───────────────────────────────────────────────────────────────────

class RPCTester:
    def __init__(self, url: str, token: Optional[str] = None) -> None:
        self.url = url
        self.token = token
        self.results: List[Dict[str, Any]] = []
        self._lock = threading.Lock()

    def _call(self, method: str, params: List[Any], timeout: float = 10.0) -> Dict[str, Any]:
        body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method,
                           "params": params or []}).encode()
        headers = {"Content-Type": "application/json"}
        if self.token:
            headers["Authorization"] = f"Bearer {self.token}"
        try:
            req = urllib.request.Request(self.url, data=body, headers=headers)
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                raw = resp.read().decode()
                code = resp.status
            try:
                data = json.loads(raw)
            except json.JSONDecodeError:
                return {"method": method, "status_code": code, "transport_error": "non-json", "body": raw[:120]}
            return {"method": method, "status_code": code, "data": data}
        except urllib.error.HTTPError as e:
            try:
                raw = e.read().decode()
                data = json.loads(raw)
                return {"method": method, "status_code": e.code, "data": data}
            except Exception:
                return {"method": method, "transport_error": f"http_{e.code}"}
        except Exception as e:
            return {"method": method, "transport_error": str(e)[:120]}

    @staticmethod
    def _classify(call: Dict[str, Any]) -> Tuple[str, str]:
        """Returns (status, detail). status in {PASS, FAIL, SKIP}."""
        if call.get("transport_error"):
            return "FAIL", f"transport: {call['transport_error']}"
        data = call.get("data") or {}
        err = data.get("error") if isinstance(data, dict) else None
        if err:
            msg = err.get("message", json.dumps(err)) if isinstance(err, dict) else str(err)
            low = msg.lower()
            if any(k in low for k in ("method not found", "unknown method", "not implemented")):
                return "SKIP", f"not implemented: {msg[:80]}"
            return "FAIL", msg[:120]
        if "result" not in data:
            return "FAIL", "no result field"
        return "PASS", json.dumps(data["result"])[:80]

    def test_group(self, name: str, methods: List[Tuple[str, List[Any]]]) -> Dict[str, int]:
        cprint(CYAN, f"\n--- {name} ({len(methods)} methods) ---")
        counts = {"PASS": 0, "FAIL": 0, "SKIP": 0}
        for method, params in methods:
            call = self._call(method, params)
            status, detail = self._classify(call)
            counts[status] += 1
            color = {"PASS": GREEN, "FAIL": RED, "SKIP": YELLOW}[status]
            tag = {"PASS": "[PASS]", "FAIL": "[FAIL]", "SKIP": "[SKIP]"}[status]
            cprint(color, f"  {tag} {method:40s} {detail}")
            with self._lock:
                self.results.append({
                    "group": name, "method": method, "status": status, "detail": detail,
                })
        return counts

    def test_error_handling(self) -> Dict[str, int]:
        cprint(CYAN, "\n--- Error Handling ---")
        counts = {"PASS": 0, "FAIL": 0}
        # Invalid method should return error
        call = self._call("nonexistent_method_xxx", [])
        data = call.get("data") or {}
        has_err = bool((isinstance(data, dict) and data.get("error")) or call.get("transport_error"))
        if has_err:
            counts["PASS"] += 1; cprint(GREEN, "  [PASS] invalid method returns error")
            self.results.append({"group": "Errors", "method": "nonexistent_method_xxx", "status": "PASS", "detail": "ok"})
        else:
            counts["FAIL"] += 1; cprint(RED, "  [FAIL] invalid method silently succeeded")
            self.results.append({"group": "Errors", "method": "nonexistent_method_xxx", "status": "FAIL", "detail": str(data)[:120]})
        return counts

    def stress_test(self, concurrency: int = 50, total: int = 500) -> Dict[str, int]:
        cprint(CYAN, f"\n--- Stress Test (getblockcount × {total}, {concurrency} threads) ---")
        ok = 0
        fail = 0

        def worker(_: int) -> bool:
            call = self._call("getblockcount", [], timeout=5.0)
            if call.get("transport_error"):
                return False
            data = call.get("data") or {}
            return isinstance(data, dict) and "result" in data

        t0 = time.time()
        with ThreadPoolExecutor(max_workers=concurrency) as ex:
            futures = [ex.submit(worker, i) for i in range(total)]
            for fut in as_completed(futures):
                if fut.result():
                    ok += 1
                else:
                    fail += 1
        elapsed = time.time() - t0
        rps = total / max(elapsed, 0.001)

        cprint(GREEN if fail == 0 else (YELLOW if fail < total // 10 else RED),
               f"  Stress: {ok} OK, {fail} FAIL — {rps:.1f} rps over {elapsed:.2f}s")
        self.results.append({
            "group": "Stress", "method": "getblockcount", "status": "PASS" if fail == 0 else "FAIL",
            "detail": f"{ok}/{total} ok, {rps:.1f} rps",
        })
        return {"PASS": ok, "FAIL": fail}

    def run(self, skip_stress: bool = False) -> Dict[str, Any]:
        cprint(GREEN, f"=== OmniBus JSON-RPC Tester  ({self.url}) ===")
        # Reachability check
        snap = self._call("getblockcount", [])
        if snap.get("transport_error"):
            cprint(RED, f"FATAL: cannot reach {self.url}: {snap['transport_error']}")
            return {"rpc_url": self.url, "results": [], "reachable": False}

        totals = {"PASS": 0, "FAIL": 0, "SKIP": 0}
        for name, methods in GROUPS:
            c = self.test_group(name, methods)
            for k in totals:
                totals[k] += c.get(k, 0)

        err = self.test_error_handling()
        totals["PASS"] += err.get("PASS", 0)
        totals["FAIL"] += err.get("FAIL", 0)

        if not skip_stress:
            st = self.stress_test()
            # stress totals not folded into method totals (different unit)
            totals["stress_ok"] = st["PASS"]
            totals["stress_fail"] = st["FAIL"]

        cprint(CYAN, "\n--- Summary ---")
        cprint(GREEN,  f"  PASS: {totals['PASS']}")
        cprint(YELLOW, f"  SKIP: {totals['SKIP']}")
        cprint(RED,    f"  FAIL: {totals['FAIL']}")

        return {
            "rpc_url": self.url, "totals": totals, "results": self.results,
            "reachable": True,
        }


def main() -> int:
    p = argparse.ArgumentParser(description="Test OmniBus JSON-RPC interface (multi-chain).")
    p.add_argument("--chain", default=os.environ.get("CHAIN", "mainnet"),
                   choices=list(CHAIN_URLS.keys()),
                   help="Endpoint preset. Default: mainnet (or $CHAIN env).")
    p.add_argument("--rpc", default=None,
                   help="Explicit RPC URL (overrides --chain).")
    p.add_argument("--token", default=os.environ.get("OMNIBUS_RPC_TOKEN"),
                   help="Bearer token. Default: $OMNIBUS_RPC_TOKEN.")
    p.add_argument("--output", default="rpc-test-report.json",
                   help="JSON output path.")
    p.add_argument("--json", action="store_true", help="Print JSON summary on stdout.")
    p.add_argument("--skip-stress", action="store_true",
                   help="Skip the 500-request stress phase.")
    args = p.parse_args()

    url = args.rpc or CHAIN_URLS[args.chain]
    tester = RPCTester(url=url, token=args.token)
    report = tester.run(skip_stress=args.skip_stress)

    with open(args.output, "w", encoding="utf-8") as f:
        json.dump(report, f, indent=2)
    cprint(GREEN, f"\nReport written to {args.output}")

    if args.json:
        print(json.dumps(report, indent=2))

    if not report.get("reachable"):
        return 2
    return 1 if report["totals"].get("FAIL", 0) > 0 else 0


if __name__ == "__main__":
    sys.exit(main())
