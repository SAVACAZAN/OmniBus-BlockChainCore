#!/usr/bin/env python3
"""quantum_circuit.py — circuit de tranzacții Quantum pe VPS testnet.

Trimite OMNI la cele 4 prefixe Quantum (obk1_/obf5_/obd5_/obs3_) generând
adrese hash160 random valide. Rulează din PC către VPS RPC public.

Usage:
    OMNIBUS_RPC_TOKEN=<token> python quantum_circuit.py [count] [delay_s]
"""
import json, os, sys, time, random, secrets, urllib.request, urllib.error

RPC = os.environ.get("OMNIBUS_RPC_URL", "https://omnibusblockchain.cc:8443/api-testnet")
TOKEN = os.environ.get("OMNIBUS_RPC_TOKEN", "")
COUNT = int(sys.argv[1]) if len(sys.argv) > 1 else 20
DELAY = float(sys.argv[2]) if len(sys.argv) > 2 else 2.0

PREFIXES = [
    ("obk1_", "Quantum-k Dilithium"),
    ("obf5_", "Quantum-f Falcon"),
    ("obd5_", "Quantum-d SLH-DSA"),
    ("obs3_", "Quantum-s ML-KEM"),
]


def gen_quantum_address(prefix: str) -> str:
    """Generate a valid Quantum address: prefix + hex(hash160 random 20 bytes)."""
    return prefix + secrets.token_hex(20)


def rpc(method, params, retries=3):
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
    headers = {"Content-Type": "application/json"}
    if TOKEN:
        headers["Authorization"] = f"Bearer {TOKEN}"
    last_err = None
    for attempt in range(retries):
        try:
            req = urllib.request.Request(RPC, method="POST", headers=headers, data=body)
            return json.loads(urllib.request.urlopen(req, timeout=10).read().decode())
        except (urllib.error.URLError, ConnectionRefusedError, TimeoutError) as e:
            last_err = e
            if attempt < retries - 1:
                time.sleep(2)
    raise last_err


def main():
    s = rpc("getstatus", [])["result"]
    print(f'== Quantum circuit | block={s["blockCount"]} balance={s["balance"]/1e9:.4f} OMNI ==')
    print(f"   Sending {COUNT} TXs to 4 Quantum prefixes (obk1_/obf5_/obd5_/obs3_)")
    print(f"   {DELAY}s between TXs\n")

    ok, fail = 0, 0
    counts = {p[0]: 0 for p in PREFIXES}
    sample = []

    for i in range(COUNT):
        prefix, label = random.choice(PREFIXES)
        dst = gen_quantum_address(prefix)
        amount = random.randint(100_000, 5_000_000)
        try:
            r = rpc("sendtransaction", [dst, amount])
            if r.get("error"):
                raise Exception(r["error"]["message"])
            res = r["result"]
            ok += 1
            counts[prefix] += 1
            if len(sample) < 4 and prefix not in [s[0] for s in sample]:
                sample.append((prefix, dst, res["txid"]))
            print(f"  [{i+1:3d}/{COUNT}] {label:<22} {amount:>9} SAT  ->  ...{dst[-12:]}  txid={res['txid'][:14]}")
        except Exception as e:
            fail += 1
            print(f"  [{i+1:3d}/{COUNT}] {label:<22} FAIL: {str(e)[:60]}")
        time.sleep(DELAY)

    try:
        s2 = rpc("getstatus", [])["result"]
        print(f"\n== DONE: {ok} ok / {fail} fail ==")
        for p, lab in PREFIXES:
            print(f"   {p}: {counts[p]:>3} TXs ({lab})")
        print(f"   block={s2['blockCount']} mempool={s2['mempoolSize']} balance={s2['balance']/1e9:.4f} OMNI")
        if sample:
            print("\n  Sample Quantum addresses funded:")
            for prefix, addr, txid in sample:
                print(f"    {prefix:<8} {addr}")
                print(f"             txid={txid}")
    except Exception as e:
        print(f"\n== DONE: {ok} ok / {fail} fail (final getstatus failed: {e})==")


if __name__ == "__main__":
    main()
