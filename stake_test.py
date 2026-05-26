#!/usr/bin/env python3
"""stake_test.py -- register testnet addresses as VALIDATORs by submitting
`stake:<amount>` op_return transactions, then verify role detection via
`getrichlist`.

Two flows:

  Option A (mandatory, always works):
    Use chain wallet's `sendtransaction` + op_return = "stake:..." to stake
    the chain wallet to itself. Proves role-detection logic end-to-end on
    one address. Sends 100 / 50 / 25 OMNI = 175 OMNI total stake.

  Option B (best effort):
    Pick 4 ECDSA pool addresses, fund each with 110 OMNI from chain wallet,
    then build 4 signed `sendrawtransaction` calls with op_return =
    "stake:100000000000". If submission fails (mempool refusal), report and
    skip -- leaves Option A's effect intact for verification.

Usage:
    OMNIBUS_RPC_TOKEN=<bearer> python stake_test.py [--skip-b]
"""
import json
import os
import sys
import time
import hashlib
import urllib.request
import urllib.error

# Force UTF-8 stdout on Windows so Unicode prints don't crash on cp1252.
try:
    sys.stdout.reconfigure(encoding="utf-8")  # type: ignore[attr-defined]
except Exception:
    pass

try:
    from coincurve import PrivateKey  # type: ignore
    HAVE_COINCURVE = True
except ImportError:
    HAVE_COINCURVE = False

RPC_URL = os.environ.get(
    "OMNIBUS_RPC_URL", "https://omnibusblockchain.cc:8443/api-testnet"
)
TOKEN = os.environ.get(
    "OMNIBUS_RPC_TOKEN",
    "31926ece83bb8c9317ead56d60de99ed38c5d1e345055aedb0acf5db6512b8c4",
)

VALIDATOR_MIN_STAKE = 100_000_000_000  # 100 OMNI in SAT
SAT_PER_OMNI = 1_000_000_000
SKIP_B = "--skip-b" in sys.argv


# -- RPC helpers ---------------------------------------------------------
def rpc(method, params, retries=3, timeout=15, extra_top_level=None):
    """Send a JSON-RPC 2.0 request.

    `extra_top_level` is a dict whose key/value pairs are spliced into the
    top-level request body (NOT inside `params`). The Zig server's
    `extractStr` scans the entire body, so injecting `op_return` there is
    picked up by `handleSendTx` even with positional `params`.
    """
    payload = {"jsonrpc": "2.0", "id": 1, "method": method, "params": params}
    if extra_top_level:
        payload.update(extra_top_level)
    body = json.dumps(payload).encode()
    headers = {"Content-Type": "application/json"}
    if TOKEN:
        headers["Authorization"] = f"Bearer {TOKEN}"
    last_err = None
    for attempt in range(retries):
        try:
            req = urllib.request.Request(
                RPC_URL, method="POST", headers=headers, data=body
            )
            return json.loads(
                urllib.request.urlopen(req, timeout=timeout).read().decode()
            )
        except urllib.error.HTTPError as e:
            try:
                return json.loads(e.read().decode())
            except Exception:
                last_err = e
        except (urllib.error.URLError, ConnectionRefusedError, TimeoutError) as e:
            last_err = e
            if attempt < retries - 1:
                time.sleep(2)
    raise last_err


def get_block_count():
    r = rpc("getblockcount", [])
    res = r.get("result", 0)
    if isinstance(res, dict):
        return res.get("blockCount", 0)
    if isinstance(res, int):
        return res
    # Fallback: pull from getstatus
    try:
        return rpc("getstatus", [])["result"]["blockCount"]
    except Exception:
        return 0


def wait_for_blocks(start_block, target_blocks=1, max_wait=120):
    """Poll getblockcount until it advances by `target_blocks`."""
    deadline = time.time() + max_wait
    print(f"[WAIT]  current block={start_block}, waiting for +{target_blocks}...")
    while time.time() < deadline:
        try:
            cur = get_block_count()
            if cur >= start_block + target_blocks:
                print(f"[WAIT]  block advanced to {cur} (waited "
                      f"{int(deadline - time.time())}s left)")
                return cur
        except Exception as e:
            print(f"[WAIT]  rpc error: {e}")
        time.sleep(3)
    print(f"[WAIT]  timeout -- block did not advance to "
          f"{start_block + target_blocks} within {max_wait}s")
    return get_block_count()


# -- Tx hash + signing (mirrors transaction.zig:calculateHash) -----------
def calculate_tx_hash(tx_id, from_addr, to_addr, amount, timestamp, nonce,
                      scheme=0, public_key="", fee=0, locktime=0,
                      op_return=""):
    h = hashlib.sha256()
    h.update(str(tx_id).encode()); h.update(b":")
    h.update(from_addr.encode());  h.update(b":")
    h.update(to_addr.encode());    h.update(b":")
    h.update(str(amount).encode()); h.update(b":")
    h.update(str(timestamp).encode()); h.update(b":")
    h.update(str(nonce).encode())
    if scheme != 0:
        h.update(b":SC:"); h.update(str(scheme).encode())
    if public_key:
        h.update(b":PK:"); h.update(public_key.encode())
    if fee > 0:
        h.update(b":"); h.update(str(fee).encode())
    if locktime > 0:
        h.update(b":lt"); h.update(str(locktime).encode())
    if op_return:
        h.update(b":OP:"); h.update(op_return.encode())
    return h.digest()


def sign_tx_ecdsa(privkey_hex, tx_hash):
    pk = PrivateKey.from_hex(privkey_hex)
    sig_recoverable = pk.sign_recoverable(tx_hash)
    return sig_recoverable[:64].hex()


def get_nonce(address):
    try:
        r = rpc("getnonce", [address])
        return r.get("result", {}).get("nonce", 0)
    except Exception:
        return 0


# -- Pretty printers -----------------------------------------------------
def short(addr, n=10):
    if not addr:
        return "?"
    return addr[:6] + ".." + addr[-n:]


def print_richlist(top=10, highlight=None):
    highlight = set(highlight or [])
    try:
        r = rpc("getrichlist", [top])
    except Exception as e:
        print(f"[RICH] getrichlist failed: {e}")
        return
    if r.get("error"):
        print(f"[RICH] getrichlist error: {r['error']}")
        return
    res = r.get("result", {})
    rows = res.get("entries") or res.get("addresses") or res.get("list") or []
    if not rows and isinstance(res, list):
        rows = res
    print(f"\n  -- Top {min(top, len(rows))} from getrichlist  "
          f"(total={res.get('total','?')}  supply="
          f"{res.get('totalSupply',0)/SAT_PER_OMNI:,.4f} OMNI) --")
    print(f"  {'#':>2}  {'address':<46}  {'balance':>14}  "
          f"{'stake':>14}  {'blk':>4}  {'roles':<32}  isValidator")
    for row in rows[:top]:
        roles = row.get("roles", [])
        is_v = row.get("isValidator", False)
        bal = row.get("balance", 0) / SAT_PER_OMNI
        stake = row.get("stake", 0) / SAT_PER_OMNI
        blk = row.get("blocksMined", row.get("blocks_mined", 0))
        addr = row.get("address", "?")
        marker = " *" if addr in highlight else "  "
        roles_str = ",".join(roles) if roles else "(no roles[])"
        print(f"  {row.get('rank','?'):>2}{marker}{short(addr, 12):<48}"
              f"{bal:>14.4f}  {stake:>14.4f}  {blk:>4}  {roles_str:<32}  {is_v}")
    if rows and "roles" not in rows[0]:
        print("  [NOTE] Server response has no `roles[]` field -- role "
              "detection RPC change not yet deployed.")
    print()


# -- OPTION A -- chain wallet stakes to itself ---------------------------
def option_a():
    print("=" * 72)
    print("  OPTION A -- chain wallet self-stake (always works)")
    print("=" * 72)

    s = rpc("getstatus", [])["result"]
    chain_wallet = s["address"]
    print(f"[A] Chain wallet  : {chain_wallet}")
    print(f"[A] Block count   : {s['blockCount']:,}")
    print(f"[A] Wallet balance: {s['balance']/SAT_PER_OMNI:,.4f} OMNI\n")

    stake_plan = [
        ("100 OMNI", 100 * SAT_PER_OMNI),
        ("50 OMNI",   50 * SAT_PER_OMNI),
        ("25 OMNI",   25 * SAT_PER_OMNI),
    ]
    accepted = 0
    txids = []
    for label, amt in stake_plan:
        op_return = f"stake:{amt}"
        # Inject op_return at top level of envelope; positional params still
        # work because handleSendTx reads `to` and `amount` from array slots.
        try:
            r = rpc(
                "sendtransaction",
                [chain_wallet, amt],
                extra_top_level={"op_return": op_return},
            )
        except Exception as e:
            print(f"[A] {label}: RPC transport error: {e}")
            continue
        if r.get("error"):
            print(f"[A] {label}: ERROR {r['error']}")
            continue
        result = r.get("result", {})
        txid = result.get("txid", "?")
        txids.append(txid)
        accepted += 1
        print(f"[A] {label} OK  txid={txid[:16]}..  op_return='{op_return}'")
        time.sleep(0.5)  # don't burst

    if accepted == 0:
        print("[A] No stake TX accepted -- abort.")
        return chain_wallet, 0, []

    print(f"\n[A] {accepted}/{len(stake_plan)} stake TXs accepted; "
          f"waiting for block confirmation so getrichlist sees them...")
    pre_block = get_block_count()
    wait_for_blocks(pre_block, target_blocks=1, max_wait=120)
    return chain_wallet, accepted, txids


# -- OPTION B -- fund + signed stake from 4 pool addresses ---------------
def option_b():
    print("=" * 72)
    print("  OPTION B -- 4 pool addresses self-stake (best effort)")
    print("=" * 72)

    if not HAVE_COINCURVE:
        print("[B] coincurve not installed -- skipping Option B.")
        return [], "coincurve missing"

    pool_path = os.path.join(
        os.path.dirname(os.path.abspath(__file__)), "addresses_pool.json"
    )
    if not os.path.exists(pool_path):
        print(f"[B] {pool_path} missing -- skipping Option B.")
        return [], "pool missing"

    with open(pool_path, "r", encoding="utf-8") as f:
        pool = json.load(f)
    targets = pool["ecdsa"][:4]
    addrs = [t["address"] for t in targets]
    print(f"[B] 4 target addresses:")
    for i, t in enumerate(targets):
        print(f"    [{i}] {t['address']}")

    s = rpc("getstatus", [])["result"]
    chain_wallet = s["address"]
    chain_balance_omni = s["balance"] / SAT_PER_OMNI
    fund_each_omni = 110
    fund_each_sat = fund_each_omni * SAT_PER_OMNI
    needed = fund_each_omni * 4

    if chain_balance_omni < needed:
        print(f"[B] Chain wallet has {chain_balance_omni:,.2f} OMNI but needs "
              f"{needed} for funding. Skipping Option B.")
        return addrs, f"insufficient chain balance ({chain_balance_omni:.2f} < {needed})"

    # - Phase 1: fund each of the 4 addresses with 110 OMNI -----------
    print(f"\n[B.1] Funding 4 addresses with {fund_each_omni} OMNI each "
          f"({needed} OMNI total)...")
    funded = 0
    for i, t in enumerate(targets):
        try:
            r = rpc("sendtransaction", [t["address"], fund_each_sat])
        except Exception as e:
            print(f"[B.1] [{i}] {short(t['address'])}: transport error {e}")
            continue
        if r.get("error"):
            print(f"[B.1] [{i}] {short(t['address'])}: ERROR {r['error']}")
            continue
        funded += 1
        print(f"[B.1] [{i}] funded {short(t['address'])}  txid="
              f"{r['result']['txid'][:16]}..")
        time.sleep(0.4)

    if funded == 0:
        return addrs, "funding failed for all 4"

    pre = get_block_count()
    wait_for_blocks(pre, target_blocks=2, max_wait=180)

    # - Phase 2: each address self-signs a stake TX -------------------
    print(f"\n[B.2] Submitting 4 signed stake TXs (each from its own pool "
          f"address, op_return='stake:{VALIDATOR_MIN_STAKE}')...")
    submitted = 0
    last_err = None
    for i, t in enumerate(targets):
        sender = t
        amount = VALIDATOR_MIN_STAKE  # 100 OMNI
        fee_sat = 1
        ts = int(time.time())
        nonce = get_nonce(sender["address"])
        tx_id = int.from_bytes(os.urandom(4), "big") & 0x7FFFFFFF
        op_return = f"stake:{amount}"

        tx_hash = calculate_tx_hash(
            tx_id, sender["address"], chain_wallet, amount, ts, nonce,
            scheme=0, public_key="", fee=fee_sat, op_return=op_return,
        )
        try:
            sig_hex = sign_tx_ecdsa(sender["privkey_hex"], tx_hash)
        except Exception as e:
            print(f"[B.2] [{i}] sign error: {e}")
            continue

        params = {
            "id": tx_id,
            "from": sender["address"],
            "to": chain_wallet,
            "amount": amount,
            "fee": fee_sat,
            "timestamp": ts,
            "nonce": nonce,
            "publicKey": sender["pubkey_hex"],
            "signature": sig_hex,
            "hash": tx_hash.hex(),
            "op_return": op_return,
            "opReturn": op_return,
        }
        try:
            r = rpc("sendrawtransaction", [params])
        except Exception as e:
            print(f"[B.2] [{i}] transport error: {e}")
            last_err = str(e)
            continue
        if r.get("error"):
            err = r["error"]
            print(f"[B.2] [{i}] {short(sender['address'])}: ERROR {err}")
            last_err = err.get("message") if isinstance(err, dict) else str(err)
            continue
        submitted += 1
        txid = r.get("result", {}).get("txid", "?")
        print(f"[B.2] [{i}] {short(sender['address'])} STAKED  "
              f"txid={txid[:16]}..")
        time.sleep(0.4)

    if submitted == 0:
        return addrs, f"all signed submissions refused -- last error: {last_err}"

    pre = get_block_count()
    wait_for_blocks(pre, target_blocks=1, max_wait=120)
    return addrs, f"{submitted}/4 signed stake TXs accepted"


# -- Main ----------------------------------------------------------------
def main():
    print(f"\n[CFG] RPC URL : {RPC_URL}")
    print(f"[CFG] Token   : {'set' if TOKEN else 'MISSING'}\n")

    chain_wallet, a_accepted, a_txids = option_a()

    b_addrs, b_status = ([], "skipped (--skip-b)")
    if not SKIP_B:
        b_addrs, b_status = option_b()

    # - Final verification --------------------------------------------
    print("\n" + "=" * 72)
    print("  FINAL VERIFICATION  --  getrichlist top 10")
    print("=" * 72)
    highlight = set([chain_wallet] + b_addrs) if chain_wallet else set(b_addrs)
    print_richlist(top=10, highlight=highlight)

    # Try to find chain wallet specifically (might be outside top 10).
    # Note: server returns very large bodies for big N -- nginx may 502.
    # Step up N gradually to avoid that.
    try:
        rows = []
        for n in (10, 25, 50):
            try:
                r = rpc("getrichlist", [n])
            except Exception:
                continue
            res = r.get("result", {})
            cand = res.get("entries") or res.get("addresses") or []
            if len(cand) > len(rows):
                rows = cand
        cw_row = next((x for x in rows if x.get("address") == chain_wallet), None)
        if cw_row:
            print(f"  Chain wallet entry:")
            print(f"    address : {cw_row['address']}")
            print(f"    balance : {cw_row.get('balance',0)/SAT_PER_OMNI:,.4f} OMNI")
            print(f"    stake   : {cw_row.get('stake',0)/SAT_PER_OMNI:,.4f} OMNI")
            print(f"    roles   : {cw_row.get('roles', '(field absent)')}")
            print(f"    isValidator : {cw_row.get('isValidator', '?')}")
        for addr in b_addrs:
            row = next((x for x in rows if x.get("address") == addr), None)
            if row:
                print(f"  Pool addr {short(addr)}:")
                print(f"    balance : {row.get('balance',0)/SAT_PER_OMNI:,.4f}")
                print(f"    stake   : {row.get('stake',0)/SAT_PER_OMNI:,.4f}")
                print(f"    roles   : {row.get('roles', '(absent)')}")
                print(f"    isValid : {row.get('isValidator', '?')}")
    except Exception as e:
        print(f"  follow-up getrichlist failed: {e}")

    # - Summary --------------------------------------------------------
    print("\n" + "=" * 72)
    print("  SUMMARY")
    print("=" * 72)
    print(f"  Option A: {a_accepted}/3 stake TXs accepted "
          f"(chain wallet {short(chain_wallet)})")
    print(f"  Option B: {b_status}")
    if a_accepted == 0:
        print("\n  ! Option A failed entirely -- check token / endpoint.")
        return 1
    print()
    return 0


if __name__ == "__main__":
    sys.exit(main())
