#!/usr/bin/env python3
"""circuit_10h.py — 10-hour mixed circuit for OmniBus testnet.

Generates ~100k transactions over 10 hours:
  - 70% sendtransaction to ECDSA addresses (ob1q...)
  - 25% sendtransaction to Quantum (obk1_/obf5_/obd5_/obs3_)
  - ~5% registername calls (mix ECDSA + Quantum addresses)

Pacing: ~2.8 TX/sec average (5 TX every 1.8s) = sustainable, no chain overload.

Usage:
    OMNIBUS_RPC_TOKEN=<token> python circuit_10h.py [duration_h] [tx_per_burst] [delay_s]

Defaults: 10 hours, 5 TX per burst, 1.8s delay between bursts.
"""
import json
import os
import sys
import time
import random
import secrets
import urllib.request
import urllib.error
from datetime import datetime, timedelta

RPC_URL = os.environ.get("OMNIBUS_RPC_URL", "https://omnibusblockchain.cc:8443/api-testnet")
TOKEN = os.environ.get("OMNIBUS_RPC_TOKEN", "")

DURATION_H = float(sys.argv[1]) if len(sys.argv) > 1 else 10.0
BURST_SIZE = int(sys.argv[2]) if len(sys.argv) > 2 else 5
DELAY_S = float(sys.argv[3]) if len(sys.argv) > 3 else 1.8

# Pre-generated valid bech32 ECDSA destinations (10)
ECDSA_DESTS = [
    "ob1qvetjtq3swujv0jqsmw0gq84fymtfuaz5p5cjdv",  # faucet.omnibus
    "ob1qzhrauq0xe9hg033ccup7vlgsdmj6kcxyza9zp0",  # savacazan.omnibus
    "ob1qqcmwu5txqt5m3wv6p3ugxp6a3q4jsntd0mxyxa",  # ens.omnibus
    "ob1qn2zu8y42hzk9r8klztr62tv2kjx0y39zzw7ym2",
    "ob1qk2c45cxtrlsfmhy7u2n2ms8jltsxy0d89crusl",
    "ob1q04wh0j824h854te0759239gm26l8mut52zrff7",
    "ob1qjka2uegj7arncd5pffvt7n0mr7eqfv04vcka6n",
    "ob1qsevsddh64yr0zgcnavdrnq3aun73vgg3r4mr3t",
    "ob1qdmad2zg0g9694jd4d3hr6duk4nupqrn8k3gxrz",
    "ob1q7h5mvxtdsny8hgnsnzct40k6m9upzxdy83zzus",
]

QUANTUM_PREFIXES = [
    ("obk1_", "Dilithium"),
    ("obf5_", "Falcon"),
    ("obd5_", "SLH-DSA"),
    ("obs3_", "ML-KEM"),
]

# Word pool for NS names (avoiding profanity, kept short)
NS_WORDS = [
    "alpha", "beta", "gamma", "delta", "echo", "foxtrot", "golf", "hotel",
    "india", "juliet", "kilo", "lima", "mike", "november", "oscar", "papa",
    "quebec", "romeo", "sierra", "tango", "uniform", "victor", "whiskey", "xray",
    "yankee", "zulu", "neon", "vortex", "zenith", "quasar", "nexus", "aegis",
    "blaze", "comet", "drift", "ember", "flux", "gleam", "halo", "ivory",
    "jade", "krypton", "lunar", "mirage", "nova", "onyx", "prism", "quartz",
    "raven", "spark", "tide", "umbra", "vapor", "wave", "xenon", "yarn", "zest",
]


def gen_quantum_address(prefix: str) -> str:
    return prefix + secrets.token_hex(20)


def gen_ns_name() -> str:
    """Random NS name like 'alphablaze42' (low collision risk)."""
    w1 = random.choice(NS_WORDS)
    w2 = random.choice(NS_WORDS)
    n = random.randint(10, 9999)
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


def pick_action():
    """Distribution: 70% ECDSA send, 25% Quantum send, 5% NS register."""
    r = random.random()
    if r < 0.05:
        return "ns"
    elif r < 0.30:  # 5% .. 30% = 25%
        return "quantum"
    else:
        return "ecdsa"


def main():
    start = datetime.now()
    end = start + timedelta(hours=DURATION_H)
    target_total = int(DURATION_H * 3600 / DELAY_S * BURST_SIZE)

    try:
        s = rpc("getstatus", [])["result"]
    except Exception as e:
        print(f"FATAL: cannot reach VPS RPC: {e}")
        return

    print("=" * 70)
    print(f"  CIRCUIT 10h — OmniBus testnet")
    print(f"  Started:  {start:%Y-%m-%d %H:%M:%S}")
    print(f"  Will end: {end:%Y-%m-%d %H:%M:%S}  (in {DURATION_H}h)")
    print(f"  Pacing:   {BURST_SIZE} TX/burst  every {DELAY_S}s  ~= {BURST_SIZE/DELAY_S:.2f} TX/s")
    print(f"  Target:   ~{target_total:,} TXs total")
    print(f"  Mix:      70% ECDSA  /  25% Quantum (4 prefixes)  /  5% NS register")
    print(f"  Start:    block={s['blockCount']:,}  bal={s['balance']/1e9:.4f} OMNI")
    print(f"  RPC:      {RPC_URL}")
    print("=" * 70)
    print()

    counts = {"ecdsa_ok": 0, "ecdsa_fail": 0,
              "quantum_ok": 0, "quantum_fail": 0,
              "ns_ok": 0, "ns_fail": 0}
    quantum_by_prefix = {p: 0 for p, _ in QUANTUM_PREFIXES}
    ns_registered = []  # keep last 20 for log
    last_report = time.time()
    burst_idx = 0

    try:
        while datetime.now() < end:
            burst_idx += 1
            for _ in range(BURST_SIZE):
                action = pick_action()
                try:
                    if action == "ecdsa":
                        dst = random.choice(ECDSA_DESTS)
                        amount = random.randint(1_000, 100_000)  # 0.000001 .. 0.0001 OMNI
                        r = rpc("sendtransaction", [dst, amount])
                        if r.get("error"):
                            raise Exception(r["error"]["message"])
                        counts["ecdsa_ok"] += 1
                    elif action == "quantum":
                        prefix, _label = random.choice(QUANTUM_PREFIXES)
                        dst = gen_quantum_address(prefix)
                        amount = random.randint(1_000, 100_000)
                        r = rpc("sendtransaction", [dst, amount])
                        if r.get("error"):
                            raise Exception(r["error"]["message"])
                        counts["quantum_ok"] += 1
                        quantum_by_prefix[prefix] += 1
                    elif action == "ns":
                        # Mix NS: half register to ECDSA, half to Quantum
                        if random.random() < 0.5:
                            target_addr = random.choice(ECDSA_DESTS)
                            kind = "ecdsa"
                        else:
                            prefix, _ = random.choice(QUANTUM_PREFIXES)
                            target_addr = gen_quantum_address(prefix)
                            kind = "quantum"
                        name = gen_ns_name()
                        r = rpc("registername", [name, target_addr])
                        if r.get("error"):
                            # Name collision is non-fatal, count as failure but continue
                            raise Exception(r["error"]["message"])
                        counts["ns_ok"] += 1
                        if len(ns_registered) >= 20:
                            ns_registered.pop(0)
                        ns_registered.append((name, kind, target_addr[-12:]))
                except Exception as e:
                    if action == "ecdsa":
                        counts["ecdsa_fail"] += 1
                    elif action == "quantum":
                        counts["quantum_fail"] += 1
                    elif action == "ns":
                        counts["ns_fail"] += 1

            # Report every 5 min (300s)
            now = time.time()
            if now - last_report >= 300:
                last_report = now
                elapsed = datetime.now() - start
                total_ok = counts["ecdsa_ok"] + counts["quantum_ok"] + counts["ns_ok"]
                total_fail = counts["ecdsa_fail"] + counts["quantum_fail"] + counts["ns_fail"]
                try:
                    s = rpc("getstatus", [])["result"]
                    block = s["blockCount"]
                    mempool = s["mempoolSize"]
                    bal = s["balance"] / 1e9
                except Exception:
                    block = mempool = bal = -1
                print(f"[{datetime.now():%H:%M:%S} | +{elapsed}] "
                      f"OK={total_ok:,} FAIL={total_fail:,} | "
                      f"ECDSA={counts['ecdsa_ok']:,} Quantum={counts['quantum_ok']:,} NS={counts['ns_ok']:,} | "
                      f"block={block:,} mempool={mempool} bal={bal:.4f}")
                # Per-prefix breakdown
                qb = " ".join(f"{p[:-1]}={c}" for p, c in quantum_by_prefix.items())
                print(f"    Quantum breakdown: {qb}")
                if ns_registered:
                    last = ns_registered[-1]
                    print(f"    Last NS: {last[0]}.omnibus -> {last[1]} ...{last[2]}")
                sys.stdout.flush()

            time.sleep(DELAY_S)
    except KeyboardInterrupt:
        print("\n[INTERRUPT] Stopping early...")

    # Final report
    end_actual = datetime.now()
    elapsed = end_actual - start
    total_ok = counts["ecdsa_ok"] + counts["quantum_ok"] + counts["ns_ok"]
    total_fail = counts["ecdsa_fail"] + counts["quantum_fail"] + counts["ns_fail"]

    print()
    print("=" * 70)
    print(f"  FINAL REPORT")
    print(f"  Ran for:        {elapsed} (target {DURATION_H}h)")
    print(f"  Total accepted: {total_ok:,}")
    print(f"  Total failed:   {total_fail:,}")
    print(f"  Success rate:   {(total_ok / max(total_ok+total_fail, 1) * 100):.1f}%")
    print()
    print(f"  ECDSA sends:    {counts['ecdsa_ok']:,} ok  /  {counts['ecdsa_fail']:,} fail")
    print(f"  Quantum sends:  {counts['quantum_ok']:,} ok  /  {counts['quantum_fail']:,} fail")
    for p, c in quantum_by_prefix.items():
        print(f"     {p:<8} {c:,}")
    print(f"  NS registers:   {counts['ns_ok']:,} ok  /  {counts['ns_fail']:,} fail")
    print()
    if ns_registered:
        print(f"  Last 20 NS registrations:")
        for name, kind, addr in ns_registered:
            print(f"    {name:<24}.omnibus  ({kind:<7}) -> ...{addr}")
    try:
        s = rpc("getstatus", [])["result"]
        print(f"\n  Final chain: block={s['blockCount']:,} mempool={s['mempoolSize']} bal={s['balance']/1e9:.4f} OMNI")
    except Exception:
        pass
    print("=" * 70)


if __name__ == "__main__":
    main()
