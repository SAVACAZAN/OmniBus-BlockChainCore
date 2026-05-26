"""
persistence_smoke_test.py - verify chainstate survives restart.

Sends stake + agent-register TXs to the chain wallet, waits for confirmation,
restarts the testnet service, and checks that the state persisted.

Loops 3 times so stake should accumulate 100, 200, 300 OMNI across iterations.

Capture pre-restart and post-restart state, diff them, fail if any field
changed unexpectedly. Stake must be EXACTLY equal before/after; agent role
must remain TRUE; balance/txCount/sent must NOT decrease.

Usage:
    python persistence_smoke_test.py
"""

import json
import subprocess
import sys
import time
import urllib.request
import urllib.error
from typing import Any, Dict, Optional

# ─── Config ─────────────────────────────────────────────────────────────────
RPC_URL    = "https://omnibusblockchain.cc:8443/api-testnet"
TOKEN      = "31926ece83bb8c9317ead56d60de99ed38c5d1e345055aedb0acf5db6512b8c4"
VPS_HOST   = "root@38.143.19.97"
SERVICE    = "omnibus-testnet"
CHAIN_ADDR = "ob1qw6zhsqg29aht23fksk5w54lkgavatpgltqxlvl"

# Stake delta per iteration: 100 OMNI = 100 * 1e9 sat
STAKE_DELTA_SAT = 100_000_000_000
# Iterations
N_ITER = 3
# Block confirmation timeout (testnet ~1s/block)
CONFIRM_TIMEOUT = 30
# Service restart wait timeout
RESTART_TIMEOUT = 60


# ─── RPC helper ─────────────────────────────────────────────────────────────
def rpc(method: str, params: Optional[list] = None, timeout: int = 15) -> Dict[str, Any]:
    payload = json.dumps({
        "jsonrpc": "2.0", "id": 1, "method": method, "params": params or [],
    }).encode()
    req = urllib.request.Request(
        RPC_URL,
        data=payload,
        headers={
            "Authorization": f"Bearer {TOKEN}",
            "Content-Type": "application/json",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return json.loads(r.read())
    except urllib.error.URLError as e:
        return {"error": {"message": str(e)}}
    except Exception as e:
        return {"error": {"message": f"{type(e).__name__}: {e}"}}


def ssh(cmd: str, timeout: int = 30) -> tuple[int, str]:
    full = ["ssh", "-o", "ConnectTimeout=10", "-o", "StrictHostKeyChecking=no",
            VPS_HOST, cmd]
    try:
        r = subprocess.run(full, capture_output=True, text=True, timeout=timeout)
        return r.returncode, (r.stdout + r.stderr).strip()
    except subprocess.TimeoutExpired:
        return -1, "TIMEOUT"


# ─── State capture ──────────────────────────────────────────────────────────
def get_chain_entry(addr: str) -> Optional[Dict[str, Any]]:
    """Pull our address entry out of getrichlist (top 1000)."""
    r = rpc("getrichlist", [1000])
    if "error" in r:
        return None
    for e in r.get("result", {}).get("entries", []):
        if e["address"] == addr:
            return e
    return None


def capture_state(addr: str) -> Dict[str, Any]:
    entry = get_chain_entry(addr) or {}
    bal = rpc("getbalance", [addr]).get("result", {})
    height = rpc("getblockcount").get("result", 0)
    return {
        "height":      height,
        "balance":     entry.get("balance", bal.get("balance", 0)),
        "stake":       entry.get("stake", 0),
        "is_validator": entry.get("isValidator", False),
        "is_agent":    "agent" in entry.get("roles", []),
        "is_miner":    "miner" in entry.get("roles", []),
        "tx_count":    entry.get("txCount", 0),
        "sent":        entry.get("sent", 0),
        "received":    entry.get("received", 0),
        "blocks_mined": entry.get("blocksMined", 0),
    }


def diff_state(pre: Dict[str, Any], post: Dict[str, Any]) -> list[str]:
    """Return list of unexpected diffs (post should be >= pre for monotonic fields)."""
    issues = []
    # Stake MUST persist exactly
    if pre["stake"] != post["stake"]:
        issues.append(f"stake changed: {pre['stake']} -> {post['stake']}")
    # Agent role MUST persist (once true, stays true)
    if pre["is_agent"] and not post["is_agent"]:
        issues.append(f"is_agent lost: True -> False")
    # tx_count, sent, blocks_mined: monotonic (can grow during restart due to mining)
    for key in ("tx_count", "sent", "blocks_mined"):
        if post[key] < pre[key]:
            issues.append(f"{key} regressed: {pre[key]} -> {post[key]}")
    return issues


# ─── Service control ────────────────────────────────────────────────────────
def restart_service() -> bool:
    print(f"  [restart] systemctl restart {SERVICE}", flush=True)
    rc, _ = ssh(f"systemctl restart {SERVICE}", timeout=30)
    if rc != 0:
        return False
    deadline = time.time() + RESTART_TIMEOUT
    while time.time() < deadline:
        r = rpc("getblockcount", timeout=5)
        if "result" in r:
            print(f"  [restart] RPC live, height={r['result']}", flush=True)
            return True
        time.sleep(2)
    return False


# ─── TX builders ────────────────────────────────────────────────────────────
def send_stake(amount_sat: int) -> Optional[str]:
    """Send stake TX: chain -> chain (self), amount=delta, op_return=stake:<delta>.

    sendtransaction reads `to`/`amount`/`fee` from positional params (`extractArrayNum`)
    but `op_return` from a JSON top-level key (`extractStr` scans whole body). So we
    use positional params [to, amount, fee] AND a sibling `op_return` field.
    """
    op_ret = f"stake:{amount_sat}"
    r = _post({
        "jsonrpc":   "2.0",
        "id":        1,
        "method":    "sendtransaction",
        "params":    [CHAIN_ADDR, amount_sat, 100],   # [to, amount, fee=100 sat]
        "op_return": op_ret,
    })
    if "error" in r:
        print(f"  [stake] ERROR: {r['error']}", flush=True)
        return None
    return r.get("result", {}).get("txid")


def send_agent_register(label: str) -> Optional[str]:
    """Send agent register TX via sendopreturn."""
    op_ret = f"agent:register:{label}"
    r = _post({
        "jsonrpc": "2.0", "id": 1, "method": "sendopreturn",
        "params": [op_ret],
    })
    if "error" in r:
        print(f"  [agent] ERROR: {r['error']}", flush=True)
        return None
    return r.get("result", {}).get("txid")


def _post(payload: dict, timeout: int = 15) -> Dict[str, Any]:
    req = urllib.request.Request(
        RPC_URL,
        data=json.dumps(payload).encode(),
        headers={"Authorization": f"Bearer {TOKEN}", "Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return json.loads(r.read())
    except Exception as e:
        return {"error": {"message": f"{type(e).__name__}: {e}"}}


def wait_height_advance(start_height: int, n_blocks: int = 1) -> int:
    """Block until chain height advances by n_blocks. Return new height."""
    target = start_height + n_blocks
    deadline = time.time() + CONFIRM_TIMEOUT
    while time.time() < deadline:
        h = rpc("getblockcount", timeout=5).get("result", 0)
        if h >= target:
            return h
        time.sleep(1)
    return rpc("getblockcount", timeout=5).get("result", 0)


# ─── Main loop ──────────────────────────────────────────────────────────────
def main() -> int:
    print("=" * 70)
    print("OmniBus persistence smoke test")
    print(f"  RPC : {RPC_URL}")
    print(f"  Addr: {CHAIN_ADDR}")
    print(f"  Iter: {N_ITER}, stake delta = {STAKE_DELTA_SAT} sat ({STAKE_DELTA_SAT // 1_000_000_000} OMNI)")
    print("=" * 70, flush=True)

    overall_pass = True
    total_summary = []

    initial = capture_state(CHAIN_ADDR)
    print(f"\nINITIAL state:  height={initial['height']} stake={initial['stake']} "
          f"is_agent={initial['is_agent']} txs={initial['tx_count']}\n", flush=True)

    for i in range(1, N_ITER + 1):
        print(f"--- Iteration {i}/{N_ITER} -----------------------------------------------", flush=True)

        # 1) Send stake TX
        txid_stake = send_stake(STAKE_DELTA_SAT)
        print(f"  [{i}] stake TX:   {txid_stake or 'FAILED'}", flush=True)

        # 2) Send agent register TX
        label = f"smoke_test_{i}_{int(time.time())}"
        txid_agent = send_agent_register(label)
        print(f"  [{i}] agent TX:   {txid_agent or 'FAILED'}  (label={label})", flush=True)

        if not txid_stake or not txid_agent:
            print(f"  [{i}] FAIL - TX submission errors", flush=True)
            overall_pass = False
            total_summary.append((i, False, "tx submission failed", {}, {}))
            continue

        # 3) Wait for next block confirmation (need 1-2 blocks)
        h0 = rpc("getblockcount").get("result", 0)
        h1 = wait_height_advance(h0, 2)
        print(f"  [{i}] confirmed:  height {h0} -> {h1}", flush=True)

        # 4) Capture pre-restart state
        pre = capture_state(CHAIN_ADDR)
        print(f"  [{i}] PRE-restart: stake={pre['stake']} is_agent={pre['is_agent']} "
              f"txs={pre['tx_count']} sent={pre['sent']}", flush=True)

        # 5) Restart service
        if not restart_service():
            print(f"  [{i}] FAIL - service restart timeout", flush=True)
            overall_pass = False
            total_summary.append((i, False, "restart timeout", pre, {}))
            continue

        # 6) Capture post-restart state
        post = capture_state(CHAIN_ADDR)
        print(f"  [{i}] POST-restart: stake={post['stake']} is_agent={post['is_agent']} "
              f"txs={post['tx_count']} sent={post['sent']}", flush=True)

        # 7) Diff
        issues = diff_state(pre, post)
        if issues:
            print(f"  [{i}] FAIL - persistence issues:", flush=True)
            for issue in issues:
                print(f"        - {issue}", flush=True)
            overall_pass = False
            total_summary.append((i, False, "; ".join(issues), pre, post))
        else:
            print(f"  [{i}] PASS - stake/agent/tx_count survived restart", flush=True)
            total_summary.append((i, True, "ok", pre, post))

        print()

    # ─── Summary ────────────────────────────────────────────────────────────
    print("=" * 70)
    print("SUMMARY")
    print("=" * 70)
    final = capture_state(CHAIN_ADDR)
    expected_stake = initial["stake"] + STAKE_DELTA_SAT * sum(1 for r in total_summary if r[1])
    print(f"  Initial  stake : {initial['stake']:>20} sat")
    print(f"  Expected stake : {expected_stake:>20} sat (initial + N_pass x delta)")
    print(f"  Actual final   : {final['stake']:>20} sat")
    print(f"  Initial agent  : {initial['is_agent']}")
    print(f"  Final agent    : {final['is_agent']}")
    print()
    for i, ok, msg, pre, post in total_summary:
        status = "PASS" if ok else "FAIL"
        print(f"  Iter {i}: {status} - {msg}")
        if pre and post:
            print(f"           pre  stake={pre['stake']:>15} agent={pre['is_agent']} txs={pre['tx_count']}")
            print(f"           post stake={post['stake']:>15} agent={post['is_agent']} txs={post['tx_count']}")
    print()

    if overall_pass and final["stake"] == expected_stake:
        print("OVERALL: PASS")
        return 0
    else:
        if final["stake"] != expected_stake:
            print(f"OVERALL: FAIL - final stake mismatch (got {final['stake']}, expected {expected_stake})")
        else:
            print("OVERALL: FAIL - see iteration failures above")
        return 1


if __name__ == "__main__":
    sys.exit(main())
