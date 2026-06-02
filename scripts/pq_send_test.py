#!/usr/bin/env python3
"""pq_send_test.py — sign and submit transactions FROM Quantum addresses.

Loads addresses_pool_v2.json (real PQ keypairs), funds 5 Quantum addresses from
the chain wallet via `sendtransaction`, waits a block, then constructs PQ-signed
TXs FROM those Quantum addresses to ECDSA destinations and submits via `pq_send`.

Tests all 4 PQ-OMNI schemes:
  obk1_ ml_dsa_87  (Dilithium-5)
  obf5_ falcon_512
  obs3_ ml_dsa_87  (chain alias for code 7)
  obd5_ sphincs_shake_256s_simple

Usage:
  set OMNIBUS_RPC_TOKEN=...
  python pq_send_test.py [duration_minutes]
"""
import os, sys, json, hashlib, time, urllib.request, urllib.error, ssl

from chain_stub_pq import MlDsa87, Falcon512, SlhDsa256s


RPC = os.environ.get("OMNIBUS_RPC_URL", "https://omnibusblockchain.cc:8443/api-testnet")
TOKEN = os.environ.get("OMNIBUS_RPC_TOKEN", "31926ece83bb8c9317ead56d60de99ed38c5d1e345055aedb0acf5db6512b8c4")
DURATION_MIN = int(sys.argv[1]) if len(sys.argv) > 1 else 3
POOL_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "addresses_pool_v2.json")
ECDSA_POOL_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "addresses_pool.json")

SCHEME_MOD = {
    "pq_omni_ml_dsa":     MlDsa87,
    "pq_omni_falcon":     Falcon512,
    "pq_omni_dilithium":  MlDsa87,
    "pq_omni_slh_dsa":    SlhDsa256s,
}

# SSL context (the VPS may use a self-signed cert) and a urllib helper.
_ssl_ctx = ssl.create_default_context()
_ssl_ctx.check_hostname = False
_ssl_ctx.verify_mode = ssl.CERT_NONE


def rpc(method, params=None, retries=3):
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method,
                       "params": params if params is not None else []}).encode()
    headers = {"Content-Type": "application/json"}
    if TOKEN:
        headers["Authorization"] = f"Bearer {TOKEN}"
    last = None
    for _ in range(retries):
        try:
            req = urllib.request.Request(RPC, method="POST", headers=headers, data=body)
            r = urllib.request.urlopen(req, timeout=15, context=_ssl_ctx)
            return json.loads(r.read().decode())
        except (urllib.error.URLError, ConnectionRefusedError, TimeoutError) as e:
            last = e
            time.sleep(2)
    raise last


def rpc_raw(method, payload, retries=3):
    """Send a method with a single object body (for pq_send which takes named params)."""
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, **payload}).encode()
    headers = {"Content-Type": "application/json"}
    if TOKEN:
        headers["Authorization"] = f"Bearer {TOKEN}"
    last = None
    for _ in range(retries):
        try:
            req = urllib.request.Request(RPC, method="POST", headers=headers, data=body)
            r = urllib.request.urlopen(req, timeout=20, context=_ssl_ctx)
            return json.loads(r.read().decode())
        except (urllib.error.URLError, ConnectionRefusedError, TimeoutError) as e:
            last = e
            time.sleep(2)
    raise last


def sha256d(data: bytes) -> bytes:
    return hashlib.sha256(hashlib.sha256(data).digest()).digest()


def calc_tx_hash(tx_id: int, scheme_code: int, from_addr: str, to_addr: str,
                 amount: int, fee: int, timestamp: int, nonce: int,
                 public_key_hex: str = "", op_return: str = "",
                 locktime: int = 0) -> bytes:
    """Replicate Transaction.calculateHash() from core/transaction.zig (line 147).

    The chain hash is TEXT-based with ':' separators (NOT binary):
      "{id}:{from}:{to}:{amount}:{timestamp}:{nonce}"
      [":SC:{scheme}"]      if scheme != 0
      [":PK:{public_key}"]  if public_key non-empty
      [":{fee}"]            if fee > 0
      [":lt{locktime}"]     if locktime > 0
      [":OP:{op_return}"]   if op_return non-empty
    Then SHA256d (sha256(sha256(...))).
    """
    parts = []
    parts.append(str(tx_id))
    parts.append(":")
    parts.append(from_addr)
    parts.append(":")
    parts.append(to_addr)
    parts.append(":")
    parts.append(str(amount))
    parts.append(":")
    parts.append(str(timestamp))
    parts.append(":")
    parts.append(str(nonce))
    if scheme_code != 0:
        parts.append(":SC:")
        parts.append(str(scheme_code))
    if public_key_hex:
        parts.append(":PK:")
        parts.append(public_key_hex)
    if fee > 0:
        parts.append(":")
        parts.append(str(fee))
    if locktime > 0:
        parts.append(":lt")
        parts.append(str(locktime))
    if op_return:
        parts.append(":OP:")
        parts.append(op_return)
    msg = "".join(parts).encode()
    h1 = hashlib.sha256(msg).digest()
    return hashlib.sha256(h1).digest()  # SHA256d


def fund_address(target: str, amount_sat: int) -> str:
    """sendtransaction from chain wallet (server-side ECDSA wallet)."""
    r = rpc("sendtransaction", [target, amount_sat])
    if r.get("error"):
        raise RuntimeError(f"fund failed: {r['error']}")
    return r["result"]["txid"]


def get_balance(addr: str) -> int:
    r = rpc("getbalance", [addr])
    if r.get("error"):
        return 0
    res = r["result"]
    if isinstance(res, dict):
        return res.get("balance", 0)
    return int(res)


def pick_destination_from_ecdsa_pool() -> str:
    if not os.path.exists(ECDSA_POOL_PATH):
        return "ob1qzhrauq0xe9hg033ccup7vlgsdmj6kcxyza9zp0"  # alex #0
    with open(ECDSA_POOL_PATH, "r", encoding="utf-8") as f:
        d = json.load(f)
    return d["ecdsa"][1]["address"]  # arbitrary destination, not the wallet itself


def pq_send(entry, dest_addr, amount_sat, fee_sat=10):
    """Sign a TX with the entry's PQ secret key and submit via pq_send RPC."""
    scheme_name = entry["scheme_name"]
    scheme_code = entry["scheme_code"]
    mod = SCHEME_MOD[scheme_name]
    sk = bytes.fromhex(entry["pq_secret_key_hex"])
    pk = bytes.fromhex(entry["pq_public_key_hex"])

    # Get next nonce from chain
    n_resp = rpc("getnonce", [entry["address"]])
    nonce = 0
    if not n_resp.get("error"):
        nonce = int(n_resp["result"].get("nonce", 0)) if isinstance(n_resp["result"], dict) else int(n_resp["result"])

    # Build canonical TX hash (same as chain's calculateHash)
    ts = int(time.time())
    tx_id = (ts & 0xFFFFFFFF)  # any u32
    op_return = ""
    h = calc_tx_hash(tx_id, scheme_code, entry["address"], dest_addr,
                     amount_sat, fee_sat, ts, nonce,
                     public_key_hex=pk.hex(), op_return=op_return)

    # Sign hash with PQ secret key (chain-stub PQ algos)
    if scheme_name == "pq_omni_falcon":
        sig = mod.sign(sk, h, pk)
    else:
        # ml_dsa / slh_dsa derive pk from sk; pass anyway for safety
        sig = mod.sign(sk, h, pk)

    payload = {
        "params": [],
        "scheme":     scheme_name,
        "from":       entry["address"],
        "to":         dest_addr,
        "amount":     amount_sat,
        "fee":        fee_sat,
        "id":         tx_id,
        "timestamp":  ts,
        "nonce":      nonce,
        "op_return":  op_return,
        "signature":  sig.hex(),
        "public_key": pk.hex(),
    }
    return rpc_raw("pq_send", payload), payload


def main():
    print(f"== pq_send_test | duration={DURATION_MIN}min ==")
    print(f"   RPC = {RPC}")

    # 0. Load v2 pool
    if not os.path.exists(POOL_PATH):
        sys.exit(f"Missing {POOL_PATH} — run regenerate_quantum_pool.py first.")
    with open(POOL_PATH, "r", encoding="utf-8") as f:
        pool = json.load(f)
    quantum = pool["quantum"]
    print(f"   loaded {len(quantum)} Quantum addresses with PQ keypairs")

    # 1. Pick 1 address per scheme (4 senders).
    #    The VPS chain currently does NOT recognize schemes 5..8 (pq_omni_*) —
    #    submitting them returns 502 from nginx because the Zig switch panics
    #    on the unknown enum case. We log them anyway so the test surfaces
    #    the deployment gap.
    senders = []
    for scheme in ["pq_omni_ml_dsa", "pq_omni_falcon", "pq_omni_dilithium", "pq_omni_slh_dsa"]:
        e = next(q for q in quantum if q["scheme_name"] == scheme)
        senders.append(e)
    print("   senders:")
    for s in senders:
        print(f"     {s['scheme_name']:<20} {s['address']}")

    # 2. Pick destination
    dest = pick_destination_from_ecdsa_pool()
    print(f"   destination = {dest}\n")

    # 3. Fund each sender with 0.5 OMNI
    FUND_AMOUNT = 50_000_000  # 0.5 OMNI in sat
    print("[1] Funding senders from chain wallet...")
    fund_txids = []
    for s in senders:
        try:
            txid = fund_address(s["address"], FUND_AMOUNT)
            fund_txids.append((s["address"], txid))
            print(f"   funded {s['address'][:20]}... txid={txid[:16]}")
        except Exception as e:
            print(f"   FUND-FAIL {s['address'][:20]}: {e}")
        time.sleep(1)

    # 4. Wait a block (~1 second nominal block time, give margin)
    print("\n[2] Waiting 30s for funding to confirm...")
    time.sleep(30)

    # 5. Check balances
    print("\n[3] Balances after funding:")
    funded_senders = []
    for s in senders:
        b = get_balance(s["address"])
        print(f"   {s['scheme_name']:<22} {s['address']}  bal={b}")
        if b >= 1_000_000:
            funded_senders.append(s)

    if not funded_senders:
        print("\n[FATAL] No Quantum addresses got funded. Cannot test signing.")
        return

    # 6. Sign + submit TXs from each funded sender
    print(f"\n[4] Signing & submitting from {len(funded_senders)} funded senders...")
    results_per_scheme = {}  # scheme_name -> { ok, fail, last_err, sample_txid }
    end_at = time.time() + DURATION_MIN * 60
    iteration = 0
    while time.time() < end_at:
        iteration += 1
        for s in funded_senders:
            sn = s["scheme_name"]
            stats = results_per_scheme.setdefault(sn, {"ok": 0, "fail": 0, "last_err": "", "sample_txid": None})
            try:
                resp, payload = pq_send(s, dest, amount_sat=10_000, fee_sat=10)
                if resp.get("error"):
                    stats["fail"] += 1
                    stats["last_err"] = str(resp["error"])
                    print(f"  [iter {iteration}] {sn:<20} FAIL: {resp['error']}")
                else:
                    stats["ok"] += 1
                    txid = resp["result"].get("txid", "?")
                    if stats["sample_txid"] is None:
                        stats["sample_txid"] = txid
                    print(f"  [iter {iteration}] {sn:<20} OK txid={txid[:18]}")
            except Exception as e:
                stats["fail"] += 1
                stats["last_err"] = str(e)
                print(f"  [iter {iteration}] {sn:<20} EXC: {str(e)[:80]}")
            time.sleep(2)
        # Small pause between iteration sweeps
        time.sleep(3)

    # 7. Summary
    print("\n== Summary ==")
    for sn, stats in results_per_scheme.items():
        print(f"  {sn:<22} ok={stats['ok']:>3}  fail={stats['fail']:>3}  sample_txid={stats['sample_txid']}")
        if stats["last_err"]:
            print(f"     last_err: {stats['last_err'][:200]}")
    print()

    # 8. Bonus: prove the SIGNING ALGORITHM works by hitting `food_falcon`
    #    (scheme code 2 — soulbound, REGISTERED in deployed VPS binary). The TX
    #    will fail post-signature with "Transaction validation failed" because
    #    soulbound addresses can't transfer OMNI out, but the signature itself
    #    passes verifyFoodSignature on chain.
    print("\n[5] BONUS: Prove signing works via soulbound `food_falcon` (scheme 2)")
    pk_b, sk_b = Falcon512.generate_keypair()
    soulbound_addr = "ob_f5_" + hashlib.new("ripemd160", hashlib.sha256(pk_b).digest()).hexdigest()
    ts = int(time.time())
    tx_id = ts & 0xFFFFFFFF
    h = calc_tx_hash(tx_id, 2, soulbound_addr, dest, 1000, 10, ts, 0, public_key_hex=pk_b.hex())
    sig_b = Falcon512.sign(sk_b, h, pk_b)
    payload = {
        "params": [], "scheme": "food_falcon",
        "from": soulbound_addr, "to": dest,
        "amount": 1000, "fee": 10,
        "id": tx_id, "timestamp": ts, "nonce": 0, "op_return": "",
        "signature": sig_b.hex(), "public_key": pk_b.hex(),
    }
    try:
        resp = rpc_raw("pq_send", payload)
        if resp.get("error"):
            msg = str(resp["error"])
            if "Transaction validation failed" in msg:
                print(f"   PROOF OK: signature verified (chain reached tx-validation, "
                      f"failed there because food_falcon is soulbound). resp={msg}")
            elif "Signature verification failed" in msg:
                print(f"   PROOF FAIL: chain rejected the signature. resp={msg}")
            else:
                print(f"   chain resp: {msg}")
        else:
            print(f"   PROOF OK accepted: txid={resp['result'].get('txid')}")
    except Exception as e:
        print(f"   bonus exception: {e}")


if __name__ == "__main__":
    main()
