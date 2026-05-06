#!/usr/bin/env python3
"""
inventory-scan.py — count every operation, TX type, scheme, RPC method, WS
event, and module exposed by the OmniBus blockchain core.

Run from anywhere:
    python tools/inventory-scan.py            # markdown to stdout
    python tools/inventory-scan.py --json     # machine readable
    python tools/inventory-scan.py --out STATUS/INVENTORY.md

The point: when someone asks "cate operatiuni avem?" — open this and the
answer is current, not stale. No build needed; pure regex over core/*.zig.
"""

from __future__ import annotations
import re
import json
import sys
import argparse
from pathlib import Path
from collections import defaultdict

ROOT = Path(__file__).resolve().parents[1]
CORE = ROOT / "core"
RPC  = CORE / "rpc_server.zig"
TX   = CORE / "transaction.zig"
WS   = CORE / "ws_server.zig"

RPC_RE     = re.compile(r'std\.mem\.eql\(u8,\s*method,\s*"([a-zA-Z_][\w]*)"\)')
NOT_IMPL_RE= re.compile(r'errorJson\(\s*-32601')
TXTYPE_RE  = re.compile(r'^\s*([a-z_][\w]*)\s*=\s*(0x[0-9A-Fa-f]+|\d+)\s*,', re.M)
SCHEME_RE  = re.compile(r'^\s*([a-z_][\w]*)\s*=\s*(\d+)\s*,', re.M)
WS_EVT_RE  = re.compile(r'"event"\s*:\s*"([^"]+)"|publishEvent\(\s*"([^"]+)"|broadcastEvent\(\s*"([^"]+)"')
PUBFN_RE   = re.compile(r'^pub\s+fn\s+([A-Za-z_][\w]*)\s*\(', re.M)


# ────────────────────────────────────────────────────────────────────────
# RPC methods — also classify by namespace and detect not-implemented stubs.

NAMESPACES = [
    ("Bitcoin-compatible", "getbestblockhash getdifficulty getblockhash getconnectioncount getpeerinfo getmininginfo getblockchaininfo getmempoolinfo".split()),
    ("Ethereum compat",    lambda m: m.startswith("eth_") or m == "net_version"),
    ("PQ crypto",          lambda m: m.startswith("pq_") or m in {"sendpqattest","getpqidentity"}),
    ("Name service",       lambda m: m.startswith("ns_") or m in {"registername","renewname","transfername","updatename","resolvename","reverseresolvename","listnames","getensfee","setpqaddress","setcategory","setpreferredslot","getnamesbycategory"}),
    ("Exchange (CEX-style)",       lambda m: m.startswith("exchange_")),
    ("Bridge",             lambda m: m.startswith("bridge_") or m == "getbridgestatus"),
    ("Oracle / Omnibus",   lambda m: m.startswith("omnibus_")),
    ("Faucet",             lambda m: m in {"claimfaucet","getfaucetstatus"}),
    ("Identity / KYC",     lambda m: m.startswith("identity_") or m.startswith("kyc_") or m == "getidentity"),
    ("Notarize",           lambda m: m in {"notarizedoc","verifynotarize","revokenotarize","getnotarizations"}),
    ("Escrow",             lambda m: m.startswith("escrow_") or m in {"getescrow","getescrows"}),
    ("Subscription",       lambda m: m.startswith("sub_") or m == "getsubscriptions"),
    ("Social graph",       lambda m: m in {"follow","unfollow","getfollowers","getfollowing"}),
    ("POAP",               lambda m: m.startswith("poap_") or m in {"getpoaps","getpoapevent"}),
    ("Governance",         lambda m: m.startswith("gov_") or m in {"getproposals","getproposal"}),
    ("Labels",             lambda m: m in {"applylabel","getlabels","removelabel"}),
    ("Reputation",         lambda m: m in {"getreputation","getreputationtop"}),
    ("Agents",             lambda m: m.startswith("agent_")),
    ("Staking / slashing", lambda m: m in {"submitslashevidence","getslashhistory","getstakinginfo","getvalidators","getslotleader"}),
    ("Mining / pool",      lambda m: m in {"registerminer","getpoolstats","getminerstats","getminerinfo","getnodelist","minersendtx","getmininginfo"}),
    ("Mempool",            lambda m: m in {"getmempoolsize","getmempoolstats","getmempoolinfo","sendtransaction","sendrawtransaction","sendopreturn","gettransactions","listtransactions","gettransaction","getnonce","estimatefee"}),
    ("Block / chain",      lambda m: m in {"getblock","getblocks","getblockcount","getlatestblock","getheaders","getmerkleproof","getchainmetrics","getrichlist","getstatus"}),
    ("Wallet / address",   lambda m: m in {"getbalance","getaddressbalance","getaddresshistory","listunspent","generatewallet","createmultisig","sendmultisig"}),
    ("Network / peers",    lambda m: m in {"getpeers","getsyncstatus","getnetworkinfo","getperformance"}),
    ("Clock / scheduler",  lambda m: m in {"getclockstatus","getslotcalendar","getfuturepool"}),
    ("Channels (TODO)",    lambda m: m in {"openchannel","channelpay","closechannel","getchannels"}),
]

def classify(method: str) -> str:
    for name, rule in NAMESPACES:
        if isinstance(rule, list):
            if method in rule:
                return name
        elif callable(rule):
            try:
                if rule(method):
                    return name
            except Exception:
                pass
    # Dynamic fallback — group by leading `prefix_` so namespaces added in
    # the future show up grouped instead of all dumped under "Other".
    if "_" in method:
        prefix = method.split("_", 1)[0]
        if 2 <= len(prefix) <= 12:
            return f"Other ({prefix}_*)"
    return "Other"


def scan_rpc():
    text = RPC.read_text(encoding="utf-8", errors="replace")
    methods = set()
    not_impl = set()
    # walk line by line so we can pair the method match with errorJson on same line
    for line in text.splitlines():
        m = RPC_RE.search(line)
        if not m:
            continue
        name = m.group(1)
        methods.add(name)
        if NOT_IMPL_RE.search(line):
            not_impl.add(name)
    by_ns = defaultdict(list)
    for m in sorted(methods):
        by_ns[classify(m)].append(m)
    return {
        "total": len(methods),
        "implemented": len(methods - not_impl),
        "stubs":       sorted(not_impl),
        "by_namespace": {k: sorted(v) for k, v in by_ns.items()},
    }


# ────────────────────────────────────────────────────────────────────────
# TX types and schemes from transaction.zig

def scan_block(text: str, enum_name: str):
    """Extract `name = N,` from `pub const ENUM = enum(...){ ... };`."""
    pat = re.compile(rf'pub const\s+{enum_name}\s*=\s*enum\([^)]+\)\s*\{{', re.S)
    m = pat.search(text)
    if not m:
        return []
    start = m.end()
    depth = 1
    i = start
    while i < len(text) and depth > 0:
        if text[i] == "{": depth += 1
        elif text[i] == "}": depth -= 1
        i += 1
    body = text[start:i-1]
    out = []
    for line in body.splitlines():
        # Strip comments to keep regex simple.
        line = re.sub(r"//.*$", "", line)
        m = re.match(r'\s*([a-z_][\w]*)\s*=\s*(0x[0-9A-Fa-f]+|\d+)\s*,', line)
        if m:
            out.append((m.group(1), int(m.group(2), 0)))
    return out


def scan_tx():
    text = TX.read_text(encoding="utf-8", errors="replace")
    types   = scan_block(text, "TxType")
    schemes = scan_block(text, "Scheme")
    return {
        "tx_types":  [{"name": n, "code": f"0x{c:02X}"} for n, c in types],
        "schemes":   [{"name": n, "code": c} for n, c in schemes],
        "tx_count":  len(types),
        "scheme_count": len(schemes),
    }


# ────────────────────────────────────────────────────────────────────────
# Module surface — pub fn count + LOC per file.

def scan_modules():
    files = sorted(p for p in CORE.glob("*.zig"))
    rows = []
    total_loc = 0
    total_pubfn = 0
    for f in files:
        try:
            t = f.read_text(encoding="utf-8", errors="replace")
        except Exception:
            continue
        loc = t.count("\n") + 1
        pubfns = len(PUBFN_RE.findall(t))
        rows.append({"file": f.name, "loc": loc, "pub_fn": pubfns})
        total_loc += loc
        total_pubfn += pubfns
    return {
        "module_count": len(rows),
        "total_loc":    total_loc,
        "total_pub_fn": total_pubfn,
        "modules":      rows,
    }


def scan_ws():
    if not WS.exists():
        return {"event_names": [], "event_count": 0}
    text = WS.read_text(encoding="utf-8", errors="replace")
    names = set()
    for m in WS_EVT_RE.finditer(text):
        for g in m.groups():
            if g:
                names.add(g)
    return {"event_names": sorted(names), "event_count": len(names)}


# ────────────────────────────────────────────────────────────────────────
# Render

def render_markdown(data) -> str:
    rpc, tx, mod, ws = data["rpc"], data["tx"], data["modules"], data["ws"]
    out = []
    out.append("# OmniBus BlockChainCore — Operation Inventory")
    out.append("")
    out.append(f"_Generated by `tools/inventory-scan.py` · pure regex over `core/*.zig`._")
    out.append("")
    out.append("## Top-line counts")
    out.append("")
    out.append("| Metric | Count |")
    out.append("|---|---:|")
    out.append(f"| RPC methods (total)        | **{rpc['total']}** |")
    out.append(f"| RPC implemented            | {rpc['implemented']} |")
    out.append(f"| RPC stubs (not yet impl.)  | {len(rpc['stubs'])} |")
    out.append(f"| TX types (TxType enum)     | **{tx['tx_count']}** |")
    out.append(f"| Address schemes (Scheme)   | **{tx['scheme_count']}** |")
    out.append(f"| WebSocket event types      | {ws['event_count']} |")
    out.append(f"| `core/*.zig` modules       | {mod['module_count']} |")
    out.append(f"| `pub fn` across core       | {mod['total_pub_fn']} |")
    out.append(f"| Lines of Zig in core       | {mod['total_loc']:,} |")
    out.append("")
    out.append("## RPC methods by namespace")
    out.append("")
    out.append("| Namespace | Count | Methods |")
    out.append("|---|---:|---|")
    for ns, methods in sorted(rpc["by_namespace"].items(), key=lambda kv: (-len(kv[1]), kv[0])):
        out.append(f"| {ns} | {len(methods)} | `{'`, `'.join(methods)}` |")
    out.append("")
    if rpc["stubs"]:
        out.append("### RPC stubs (return -32601 not-implemented)")
        out.append("")
        for s in rpc["stubs"]:
            out.append(f"- `{s}`")
        out.append("")
    out.append("## TX types (chain-level operations)")
    out.append("")
    out.append("| Code | Name |")
    out.append("|---|---|")
    for t in tx["tx_types"]:
        out.append(f"| `{t['code']}` | `{t['name']}` |")
    out.append("")
    out.append("## Address schemes")
    out.append("")
    out.append("| Code | Name |")
    out.append("|---:|---|")
    for s in tx["schemes"]:
        out.append(f"| {s['code']} | `{s['name']}` |")
    out.append("")
    out.append("## Top 15 modules by `pub fn` surface")
    out.append("")
    out.append("| Module | pub fn | LOC |")
    out.append("|---|---:|---:|")
    top = sorted(mod["modules"], key=lambda r: -r["pub_fn"])[:15]
    for r in top:
        out.append(f"| `{r['file']}` | {r['pub_fn']} | {r['loc']:,} |")
    out.append("")
    return "\n".join(out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--json", action="store_true", help="print JSON instead of markdown")
    ap.add_argument("--out", help="write output to file (default: stdout)")
    args = ap.parse_args()

    data = {
        "rpc":     scan_rpc(),
        "tx":      scan_tx(),
        "modules": scan_modules(),
        "ws":      scan_ws(),
    }
    text = json.dumps(data, indent=2) if args.json else render_markdown(data)
    if args.out:
        Path(args.out).write_text(text, encoding="utf-8")
        print(f"wrote {args.out}", file=sys.stderr)
    else:
        sys.stdout.write(text)
        sys.stdout.write("\n")


if __name__ == "__main__":
    main()
