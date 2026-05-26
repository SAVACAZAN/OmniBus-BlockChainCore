#!/usr/bin/env python3
"""circuit_v4_bidirectional.py — bidirectional signed-TX flow, FIXED.

This is the v3 successor.  Two things v3 got wrong (we now fix):

1.  **Hash-domain mismatch.**  Zig's `core/secp256k1.zig` is parameterised
    over `EcdsaSecp256k1Sha256oSha256` — i.e. the EC verifier internally
    SHA-256s the message *twice* before doing the curve math.  v3 signed
    `tx_hash` with coincurve's default single-SHA-256 hasher, so every
    signature failed `verifyWithHexPubkey` and the mempool refused.

    Fix: pass an explicit `hasher = sha256d` when signing.  The chain
    will then re-derive `sha256d(tx_hash)` and the EC math agrees.

2.  **PHASE-C / wire-v2 misunderstanding.**  v3 hypothesised that v2 was
    mandatory; reading `core/blockchain.zig::validateTransaction`
    proves the opposite — `tx.isV2()` only fires when `inputs[]` *or*
    `outputs[]` is non-empty.  When both are empty, the chain falls
    back to the v1 implicit balance check
    (`getAddressBalance(from) - pending >= amount + fee`).  Since the
    chain has *no* `listunspent` RPC (search of `core/rpc_server.zig`
    finds zero handler — the only `utxos` field returned by
    `getbalance` is hardcoded `[]`), client-driven v2 is impossible
    today anyway.  We stay on v1.

    `getbalance` returns the UTXO-derived balance (PHASE-B source of
    truth, see `blockchain.zig:345`), so a positive `balance` field
    means there *are* spendable UTXOs — the chain just doesn't
    expose the individual outpoints.

3.  **`"id"` collision in the JSON-RPC envelope.**  `extractArrayNumByKey`
    in `core/rpc_server.zig` is a naive `indexOf("\"id\":")` and returns
    the first match.  When the request body looks like
    `{"jsonrpc":"2.0","id":1,...,"params":[{"id":42,...}]}`
    the chain reads `tx_id = 1`, **not 42**, and the resulting
    `calculateHash()` mismatches our stored hash → "Mempool refused TX".
    Fix: hand-craft the body so the params object comes BEFORE the
    envelope id.  We avoid `json.dumps(dict)` ordering subtleties by
    string-concatenating the body in the exact field order we want.

So this script: build canonical bytes per `transaction.zig::calculateHash`,
SHA256d them locally, sign with coincurve `sign_recoverable(hash, hasher=sha256d)`,
take first 64 bytes (drop recid) as R||S hex, submit via `sendrawtransaction`
using a hand-crafted JSON body to defeat the id-extractor collision.

Usage:
    OMNIBUS_RPC_TOKEN=<token> python circuit_v4_bidirectional.py [duration_min] [burst] [delay_s]

The first 5 failures dump full request body + chain response to stderr.
"""
from __future__ import annotations
import json
import os
import sys
import time
import random
import hashlib
import urllib.request
import urllib.error
from datetime import datetime, timedelta
from coincurve import PrivateKey

RPC_URL = os.environ.get("OMNIBUS_RPC_URL", "https://omnibusblockchain.cc:8443/api-testnet")
TOKEN = os.environ.get("OMNIBUS_RPC_TOKEN", "")

DURATION_MIN = float(sys.argv[1]) if len(sys.argv) > 1 else 5.0
BURST_SIZE = int(sys.argv[2]) if len(sys.argv) > 2 else 5
DELAY_S = float(sys.argv[3]) if len(sys.argv) > 3 else 2.0

# ── HTTPS without certificate verification (self-signed VPS cert) ────────
import ssl
SSL_CTX = ssl.create_default_context()
SSL_CTX.check_hostname = False
SSL_CTX.verify_mode = ssl.CERT_NONE


def sha256d(b: bytes) -> bytes:
    """Bitcoin SHA256d — double SHA-256."""
    return hashlib.sha256(hashlib.sha256(b).digest()).digest()


def rpc(method: str, params, retries: int = 4, timeout: int = 15):
    """Generic JSON-RPC call.  Retries on URLError + 502/503 from the
    nginx fronting the chain (the blockchain process pauses briefly
    during heavy mempool / mining bursts and the proxy returns 502)."""
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
    headers = {"Content-Type": "application/json"}
    if TOKEN:
        headers["Authorization"] = f"Bearer {TOKEN}"
    last_err: Exception | None = None
    for attempt in range(retries):
        try:
            req = urllib.request.Request(RPC_URL, method="POST", headers=headers, data=body)
            with urllib.request.urlopen(req, timeout=timeout, context=SSL_CTX) as r:
                return json.loads(r.read().decode())
        except urllib.error.HTTPError as e:
            last_err = e
            if e.code in (502, 503, 504) and attempt < retries - 1:
                time.sleep(1.5 + attempt * 1.5)
                continue
            raise
        except (urllib.error.URLError, ConnectionRefusedError, TimeoutError) as e:
            last_err = e
            if attempt < retries - 1:
                time.sleep(2 + attempt)
    raise last_err  # type: ignore[misc]


def post_raw_body(body_str: str, retries: int = 4, timeout: int = 15):
    """Submit a hand-crafted JSON body (we control the field order so
    `extractArrayNumByKey("id",...)` finds tx-params id BEFORE the
    envelope id — that handler currently picks the first match).
    Retries 502/503/504 from nginx like rpc() does."""
    headers = {"Content-Type": "application/json"}
    if TOKEN:
        headers["Authorization"] = f"Bearer {TOKEN}"
    last_err: Exception | None = None
    for attempt in range(retries):
        try:
            req = urllib.request.Request(RPC_URL, method="POST", headers=headers,
                                          data=body_str.encode())
            with urllib.request.urlopen(req, timeout=timeout, context=SSL_CTX) as r:
                return json.loads(r.read().decode())
        except urllib.error.HTTPError as e:
            last_err = e
            if e.code in (502, 503, 504) and attempt < retries - 1:
                time.sleep(1.5 + attempt * 1.5)
                continue
            raise
        except (urllib.error.URLError, ConnectionRefusedError, TimeoutError) as e:
            last_err = e
            if attempt < retries - 1:
                time.sleep(2 + attempt)
    raise last_err  # type: ignore[misc]


# ── Mirrors transaction.zig::calculateHash exactly ──────────────────────
def build_canonical(tx_id, from_addr, to_addr, amount, timestamp, nonce,
                    scheme=0, public_key="", fee=0, locktime=0, op_return=""):
    """Concatenate the canonical pre-hash bytes per transaction.zig:147."""
    h = hashlib.sha256()  # we'll feed the same bytes to a fresh hash twice for sha256d
    parts: list[bytes] = []
    parts.append(str(tx_id).encode()); parts.append(b":")
    parts.append(from_addr.encode());  parts.append(b":")
    parts.append(to_addr.encode());    parts.append(b":")
    parts.append(str(amount).encode()); parts.append(b":")
    parts.append(str(timestamp).encode()); parts.append(b":")
    parts.append(str(nonce).encode())
    if scheme != 0:
        parts.append(b":SC:"); parts.append(str(scheme).encode())
    if public_key:
        parts.append(b":PK:"); parts.append(public_key.encode())
    if fee > 0:
        parts.append(b":"); parts.append(str(fee).encode())
    if locktime > 0:
        parts.append(b":"); parts.append(f"lt{locktime}".encode())
    if op_return:
        parts.append(b":OP:"); parts.append(op_return.encode())
    # NOTE: :IN: / :OUT: sections deliberately omitted (v1 path).
    return b"".join(parts)


def calculate_tx_hash(*args, **kw) -> bytes:
    """SHA256d(canonical) — matches Transaction.calculateHash."""
    canonical = build_canonical(*args, **kw)
    return sha256d(canonical)


def sign_tx_ecdsa(privkey_hex: str, tx_hash: bytes) -> str:
    """Sign tx_hash so chain verify passes.

    Chain uses `EcdsaSecp256k1Sha256oSha256` — internally `sha256d(message)`
    before EC verify.  So we must instruct coincurve to apply sha256d on
    the message we hand it.  Then the signature is over the same digest
    the chain will compute.

    Returns 64-byte R||S as 128 hex chars (drop the recid byte).
    """
    pk = PrivateKey.from_hex(privkey_hex)
    sig65 = pk.sign_recoverable(tx_hash, hasher=sha256d)  # 65 bytes: R||S||recid
    return sig65[:64].hex()


def get_chain_nonce(address: str) -> int:
    try:
        r = rpc("getnonce", [address])
        return int(r["result"]["nonce"])
    except Exception:
        return 0


def get_balance(address: str) -> int:
    try:
        r = rpc("getbalance", [address])
        return int(r["result"]["balance"])
    except Exception:
        return 0


def get_pubkey_hex(privkey_hex: str) -> str:
    """Compressed secp256k1 pubkey, 33 bytes / 66 hex chars."""
    return PrivateKey.from_hex(privkey_hex).public_key.format(compressed=True).hex()


def main():
    pool_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "addresses_pool.json")
    with open(pool_path, "r", encoding="utf-8") as f:
        pool = json.load(f)
    ECDSA = pool["ecdsa"]
    print(f"[POOL] {len(ECDSA)} ECDSA addresses loaded")

    # Pre-compute pubkey hex for any entry missing it (defensive — most have it)
    for e in ECDSA:
        if not e.get("pubkey_hex"):
            e["pubkey_hex"] = get_pubkey_hex(e["privkey_hex"])

    s = rpc("getstatus", [])["result"]
    print(f"[CHAIN] block={s['blockCount']} mempool={s['mempoolSize']} chainAddr={s['address']}")

    # Filter to addresses with positive balance — those are the ones that can spend
    funded = []
    print("[SCAN] checking balances of pool addresses ...")
    for e in ECDSA:
        bal = get_balance(e["address"])
        if bal > 0:
            funded.append((e, bal))
    print(f"[SCAN] {len(funded)}/{len(ECDSA)} pool addresses have balance")
    if not funded:
        print("[FATAL] no pool address has any balance — fund them first via "
              "circuit_v3 phase-1 or `sendtransaction`. Aborting.", file=sys.stderr)
        sys.exit(2)

    funded_sorted = sorted(funded, key=lambda kv: kv[1], reverse=True)
    print("  Top-5 funded:")
    for e, bal in funded_sorted[:5]:
        print(f"    {e['address']}  {bal/1e9:.4f} OMNI")

    start = datetime.now()
    end = start + timedelta(minutes=DURATION_MIN)
    print()
    print("=" * 72)
    print(f"  CIRCUIT v4 — bidirectional ECDSA flow (FIXED hash-domain)")
    print(f"  Duration:   {DURATION_MIN} min   ({BURST_SIZE} TX / burst, {DELAY_S}s sleep)")
    print(f"  Funded:     {len(funded)} addresses")
    print("=" * 72)
    print()

    # Per-address sequential nonce tracker (chain rejects gaps)
    nonce_cache: dict[str, int] = {}
    counts = {"signed_ok": 0, "signed_fail": 0, "skipped": 0}
    debug_dumps = 0  # dump first 5 failures fully
    MAX_DEBUG = 5

    senders_pool = [e for e, _ in funded_sorted]
    recipients_pool = ECDSA  # any pool address can be a recipient

    try:
        while datetime.now() < end:
            for _ in range(BURST_SIZE):
                sender = random.choice(senders_pool)
                recipient = random.choice(recipients_pool)
                if recipient["address"] == sender["address"]:
                    recipient = recipients_pool[(recipients_pool.index(sender) + 1)
                                                 % len(recipients_pool)]
                amount_sat = random.randint(100_000, 1_000_000)  # smaller — survive drains
                fee_sat = 1
                ts = int(time.time())
                # Always re-fetch nonce on each TX — the background `circuit_v2`
                # is also pumping TXs, so any cached nonce can be stale within
                # one block (1 s).  Cost: extra RPC, but it's cheap (~5 ms).
                try:
                    non = rpc("getnonce", [sender["address"]])["result"]
                    nonce = int(non["chainNonce"]) + int(non["pendingCount"])
                    nonce_cache[sender["address"]] = nonce
                except Exception:
                    nonce = nonce_cache.get(sender["address"], 0)
                tx_id = random.randint(1, 2**31 - 1)

                # Skip when the sender has no funds left — circuit_v2 is
                # actively draining, so balances flip to 0 several times
                # per minute.  Better to pay the RPC cost than burn a slot.
                bal = get_balance(sender["address"])
                if bal < amount_sat + fee_sat:
                    counts["skipped"] += 1
                    continue

                tx_hash = calculate_tx_hash(
                    tx_id, sender["address"], recipient["address"],
                    amount_sat, ts, nonce, scheme=0,
                    public_key="", fee=fee_sat,
                )
                sig_hex = sign_tx_ecdsa(sender["privkey_hex"], tx_hash)
                # Hand-craft body so tx-params `"id"` appears BEFORE the
                # envelope `"id"`.  `core/rpc_server.zig::extractArrayNumByKey`
                # does a naive `indexOf("\"id\":")` and returns the first
                # match — using a `dict` and json.dumps would put the
                # envelope id first and the chain would parse the wrong
                # tx_id, breaking the integrity check.
                body_str = (
                    '{"params":[{"id":' + str(tx_id)
                    + ',"from":"' + sender["address"]
                    + '","to":"' + recipient["address"]
                    + '","amount":' + str(amount_sat)
                    + ',"fee":' + str(fee_sat)
                    + ',"timestamp":' + str(ts)
                    + ',"nonce":' + str(nonce)
                    + ',"publicKey":"' + sender["pubkey_hex"]
                    + '","signature":"' + sig_hex
                    + '","hash":"' + tx_hash.hex()
                    + '"}],"method":"sendrawtransaction","jsonrpc":"2.0","id":'
                    + str(tx_id) + '}'
                )
                params = {  # only used for the failure dump
                    "id": tx_id, "from": sender["address"], "to": recipient["address"],
                    "amount": amount_sat, "fee": fee_sat, "timestamp": ts,
                    "nonce": nonce, "publicKey": sender["pubkey_hex"],
                    "signature": sig_hex, "hash": tx_hash.hex(),
                }
                try:
                    r = post_raw_body(body_str)
                    if r.get("error"):
                        raise Exception(r["error"]["message"])
                    counts["signed_ok"] += 1
                    nonce_cache[sender["address"]] = nonce + 1
                    if counts["signed_ok"] <= 5:
                        print(f"  [OK] {sender['address'][:18]}.. -> "
                              f"{recipient['address'][:18]}.. {amount_sat:>10} sat "
                              f"nonce={nonce} txid={tx_hash.hex()[:16]}..")
                except Exception as exc:
                    counts["signed_fail"] += 1
                    if debug_dumps < MAX_DEBUG:
                        debug_dumps += 1
                        print(f"\n  [FAIL #{debug_dumps}] {exc}", file=sys.stderr)
                        print("    request body:", body_str, file=sys.stderr)
                        # Probe live state of the sender — most refusals are
                        # because circuit_v2 (background) drained the address
                        # between our balance check and the submit
                        try:
                            bal_now = get_balance(sender["address"])
                            non_now = rpc("getnonce", [sender["address"]])["result"]
                            print(f"    sender state: bal={bal_now}  "
                                  f"chainNonce={non_now['chainNonce']}  "
                                  f"pending={non_now['pendingCount']}",
                                  file=sys.stderr)
                        except Exception:
                            pass
                        canonical = build_canonical(
                            tx_id, sender["address"], recipient["address"],
                            amount_sat, ts, nonce, scheme=0,
                            public_key="", fee=fee_sat,
                        )
                        print(f"    canonical : {canonical!r}", file=sys.stderr)
                        print(f"    sha256d   : {tx_hash.hex()}", file=sys.stderr)
                        print(f"    pubkey    : {sender['pubkey_hex']}",
                              file=sys.stderr)
                        print(f"    sig (R||S): {sig_hex}", file=sys.stderr)
                        # Bust the local nonce cache — chain may have shifted
                        nonce_cache.pop(sender["address"], None)
                        sys.stderr.flush()

            time.sleep(DELAY_S)
    except KeyboardInterrupt:
        print("\n[INTERRUPT]")

    elapsed = datetime.now() - start
    print()
    print("=" * 72)
    print(f"  FINAL after {elapsed}")
    print(f"    OK     : {counts['signed_ok']}")
    print(f"    FAIL   : {counts['signed_fail']}")
    print(f"    skipped: {counts['skipped']}")
    print("=" * 72)


if __name__ == "__main__":
    main()
