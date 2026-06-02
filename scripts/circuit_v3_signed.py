#!/usr/bin/env python3
"""circuit_v3_signed.py — bidirectional flow using sendrawtransaction.

Each of the 100 ECDSA addresses can SIGN its own TX with its private key
(loaded from addresses_pool.json) and submit via `sendrawtransaction` RPC.
No more single-sender — real wallet-to-wallet transfers between all 100.

Flow:
  1. Optional FUND phase: chain wallet seeds each address with 0.5-2 OMNI
     so they have balance to spend.
  2. Main loop: pick random sender from pool, pick random recipient (could be
     ECDSA or Quantum), construct + sign TX locally, submit via sendrawtransaction.
  3. Mix in NS register + small chain-wallet sends to keep variety.

Pacing: same ~2.78 TX/s for ~100k TXs in 10h.

Usage:
    OMNIBUS_RPC_TOKEN=<token> python circuit_v3_signed.py [duration_h] [burst] [delay_s]
"""
import json, os, sys, time, random, hashlib, threading
import urllib.request, urllib.error
from datetime import datetime, timedelta
from coincurve import PrivateKey

RPC_URL = os.environ.get("OMNIBUS_RPC_URL", "https://omnibusblockchain.cc:8443/api-testnet")
TOKEN = os.environ.get("OMNIBUS_RPC_TOKEN", "")

DURATION_H = float(sys.argv[1]) if len(sys.argv) > 1 else 10.0
BURST_SIZE = int(sys.argv[2]) if len(sys.argv) > 2 else 5
DELAY_S = float(sys.argv[3]) if len(sys.argv) > 3 else 1.8

NS_WORDS = [
    "alpha","beta","gamma","delta","echo","foxtrot","golf","hotel",
    "india","juliet","kilo","lima","mike","november","oscar","papa",
    "quebec","romeo","sierra","tango","uniform","victor","whiskey","xray",
    "yankee","zulu","neon","vortex","zenith","quasar","nexus","aegis",
    "blaze","comet","drift","ember","flux","gleam","halo","ivory",
    "jade","krypton","lunar","mirage","nova","onyx","prism","quartz",
    "raven","spark","tide","umbra","vapor","wave","xenon","yarn","zest",
]


def gen_ns_name():
    w1 = random.choice(NS_WORDS)
    w2 = random.choice(NS_WORDS)
    n = random.randint(10, 99999)
    return f"{w1}{w2}{n}"


def rpc(method, params, retries=3, timeout=10):
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
    headers = {"Content-Type": "application/json"}
    if TOKEN:
        headers["Authorization"] = f"Bearer {TOKEN}"
    last_err = None
    for attempt in range(retries):
        try:
            req = urllib.request.Request(RPC_URL, method="POST", headers=headers, data=body)
            return json.loads(urllib.request.urlopen(req, timeout=timeout).read().decode())
        except (urllib.error.URLError, ConnectionRefusedError, TimeoutError) as e:
            last_err = e
            if attempt < retries - 1:
                time.sleep(3)
    raise last_err


# ── Transaction.calculateHash mirror (transaction.zig:147) ─────────────
def calculate_tx_hash(tx_id, from_addr, to_addr, amount, timestamp, nonce,
                     scheme=0, public_key="", fee=0, locktime=0, op_return=""):
    """SHA-256 of canonical TX bytes — matches Zig calculateHash exactly.
    Then SHA-256 again? No — chain calls calculateHash() once = SHA-256.
    But verifyOmniSignature does ecdsa.verify(msg=hash_bytes, sig). So we sign hash_bytes."""
    h = hashlib.sha256()
    h.update(str(tx_id).encode())
    h.update(b":")
    h.update(from_addr.encode())
    h.update(b":")
    h.update(to_addr.encode())
    h.update(b":")
    h.update(str(amount).encode())
    h.update(b":")
    h.update(str(timestamp).encode())
    h.update(b":")
    h.update(str(nonce).encode())
    if scheme != 0:
        h.update(b":SC:")
        h.update(str(scheme).encode())
    if public_key:
        h.update(b":PK:")
        h.update(public_key.encode())
    if fee > 0:
        h.update(b":")
        h.update(str(fee).encode())
    if locktime > 0:
        h.update(b":lt")
        h.update(str(locktime).encode())
    if op_return:
        h.update(b":OP:")
        h.update(op_return.encode())
    return h.digest()


def sign_tx_ecdsa(privkey_hex, tx_hash):
    """Sign tx_hash with secp256k1 ECDSA, return 64-byte (R||S) hex.

    Chain-side flow (Zig EcdsaSecp256k1Sha256):
      - chain receives our 32-byte tx_hash as `message`
      - calls sig.verify(message, pubkey) which internally SHA-256s `message`
        again before doing the EC math
      - so the EC signature is over SHA-256(tx_hash)
    Therefore we sign tx_hash with default coincurve hashing (which IS sha256).
    """
    pk = PrivateKey.from_hex(privkey_hex)
    # Default hasher in coincurve is sha256 — matches Zig stdlib behavior.
    sig_recoverable = pk.sign_recoverable(tx_hash)
    # 65 bytes: R(32) || S(32) || recovery_id(1) — drop the last byte
    return sig_recoverable[:64].hex()


def get_nonce(address):
    try:
        r = rpc("getnonce", [address])
        return r["result"]["nonce"]
    except Exception:
        return 0


def main():
    pool_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "addresses_pool.json")
    with open(pool_path, "r", encoding="utf-8") as f:
        pool = json.load(f)

    ECDSA = pool["ecdsa"]  # list of {index, address, pubkey_hex, privkey_hex}
    QUANTUM_ADDRS = [a["address"] for a in pool["quantum"]]
    print(f"[POOL] {len(ECDSA)} ECDSA + {len(QUANTUM_ADDRS)} Quantum loaded")

    s = rpc("getstatus", [])["result"]
    chain_wallet = s["address"]

    start = datetime.now()
    end = start + timedelta(hours=DURATION_H)

    print()
    print("=" * 70)
    print(f"  CIRCUIT v3 SIGNED — bidirectional ECDSA flow")
    print(f"  Started:    {start:%Y-%m-%d %H:%M:%S}")
    print(f"  Will end:   {end:%Y-%m-%d %H:%M:%S}  (in {DURATION_H}h)")
    print(f"  Pacing:     {BURST_SIZE} TX/burst  every {DELAY_S}s")
    print(f"  Mix:        25% chain-wallet send (fund)  /  60% signed TX from pool /")
    print(f"              10% Quantum dest  /  5% NS register")
    print(f"  Start:      block={s['blockCount']:,}  bal={s['balance']/1e9:.4f} OMNI")
    print(f"  Chain wallet: {chain_wallet}")
    print("=" * 70)
    print()

    counts = {"fund_ok":0,"fund_fail":0,"signed_ok":0,"signed_fail":0,
              "quantum_ok":0,"quantum_fail":0,"ns_ok":0,"ns_fail":0}
    funded_addrs = set()
    last_report = time.time()
    nonce_cache = {}  # local nonce tracker per address

    try:
        while datetime.now() < end:
            for _ in range(BURST_SIZE):
                r_action = random.random()
                try:
                    if r_action < 0.25:
                        # Phase 1: Fund pool addresses from chain wallet (sendtransaction)
                        sender = ECDSA[random.randint(0, len(ECDSA)-1)]
                        amount = random.randint(50_000_000, 500_000_000)  # 0.05 - 0.5 OMNI
                        r = rpc("sendtransaction", [sender["address"], amount])
                        if r.get("error"):
                            raise Exception(r["error"]["message"])
                        counts["fund_ok"] += 1
                        funded_addrs.add(sender["address"])

                    elif r_action < 0.85:
                        # Phase 2: Signed TX from random pool address -> another pool address
                        sender = random.choice(ECDSA)
                        recipient = random.choice(ECDSA)
                        if recipient["address"] == sender["address"]:
                            recipient = ECDSA[(ECDSA.index(sender) + 1) % len(ECDSA)]
                        amount = random.randint(100_000, 10_000_000)  # small amounts
                        fee_sat = 1
                        ts = int(time.time())
                        nonce = nonce_cache.get(sender["address"], 0)
                        if nonce == 0:
                            nonce = get_nonce(sender["address"])
                        tx_id = random.randint(1, 2**31)

                        tx_hash = calculate_tx_hash(
                            tx_id, sender["address"], recipient["address"],
                            amount, ts, nonce, scheme=0,
                            public_key="", fee=fee_sat,
                        )
                        sig_hex = sign_tx_ecdsa(sender["privkey_hex"], tx_hash)

                        params = {
                            "id": tx_id,
                            "from": sender["address"],
                            "to": recipient["address"],
                            "amount": amount,
                            "fee": fee_sat,
                            "timestamp": ts,
                            "nonce": nonce,
                            "publicKey": sender["pubkey_hex"],
                            "signature": sig_hex,
                            "hash": tx_hash.hex(),
                        }
                        r = rpc("sendrawtransaction", [params])
                        if r.get("error"):
                            raise Exception(r["error"]["message"])
                        counts["signed_ok"] += 1
                        nonce_cache[sender["address"]] = nonce + 1

                    elif r_action < 0.95:
                        # Phase 3: chain wallet -> Quantum address
                        dst = random.choice(QUANTUM_ADDRS)
                        amount = random.randint(1_000_000, 100_000_000)
                        r = rpc("sendtransaction", [dst, amount])
                        if r.get("error"):
                            raise Exception(r["error"]["message"])
                        counts["quantum_ok"] += 1

                    else:
                        # Phase 4: NS register
                        target = random.choice(ECDSA + [{"address": q} for q in QUANTUM_ADDRS])
                        name = gen_ns_name()
                        r = rpc("registername", [name, target["address"]])
                        if r.get("error"):
                            raise Exception(r["error"]["message"])
                        counts["ns_ok"] += 1
                except Exception as e:
                    if r_action < 0.25: counts["fund_fail"] += 1
                    elif r_action < 0.85: counts["signed_fail"] += 1
                    elif r_action < 0.95: counts["quantum_fail"] += 1
                    else: counts["ns_fail"] += 1

            now = time.time()
            if now - last_report >= 300:
                last_report = now
                elapsed = datetime.now() - start
                total_ok = sum(v for k,v in counts.items() if k.endswith("_ok"))
                total_fail = sum(v for k,v in counts.items() if k.endswith("_fail"))
                try:
                    s = rpc("getstatus", [])["result"]
                    block, mempool, bal = s["blockCount"], s["mempoolSize"], s["balance"]/1e9
                except Exception:
                    block = mempool = -1; bal = -1
                print(f"[{datetime.now():%H:%M:%S} | +{elapsed}] "
                      f"OK={total_ok:,} FAIL={total_fail} | "
                      f"fund={counts['fund_ok']:,} signed={counts['signed_ok']:,} "
                      f"quantum={counts['quantum_ok']} ns={counts['ns_ok']} | "
                      f"funded={len(funded_addrs)}/{len(ECDSA)} | "
                      f"block={block:,} mempool={mempool}")
                sys.stdout.flush()

            time.sleep(DELAY_S)
    except KeyboardInterrupt:
        print("\n[INTERRUPT] Stopping...")

    # Final report
    elapsed = datetime.now() - start
    total_ok = sum(v for k,v in counts.items() if k.endswith("_ok"))
    total_fail = sum(v for k,v in counts.items() if k.endswith("_fail"))
    print()
    print("=" * 70)
    print(f"  FINAL — {elapsed} (target {DURATION_H}h)")
    print(f"  Total OK: {total_ok:,}  /  FAIL: {total_fail:,}")
    print(f"  Fund:    {counts['fund_ok']:,} ok / {counts['fund_fail']} fail")
    print(f"  Signed:  {counts['signed_ok']:,} ok / {counts['signed_fail']} fail   ← REAL wallet-to-wallet")
    print(f"  Quantum: {counts['quantum_ok']:,} ok / {counts['quantum_fail']} fail")
    print(f"  NS:      {counts['ns_ok']:,} ok / {counts['ns_fail']} fail")
    print("=" * 70)


if __name__ == "__main__":
    main()
