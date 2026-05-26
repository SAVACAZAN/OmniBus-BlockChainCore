#!/usr/bin/env python3
"""Sustained load: pace 5 RPS read traffic across mainnet+testnet for N minutes.
Tracks p50/p95/p99 latency in 1-min buckets, writes sustain-timeline.csv.
"""
from __future__ import annotations
import csv, json, os, ssl, statistics, sys, threading, time
import urllib.request, urllib.error
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from pathlib import Path

OUT = Path(r"c:/Kits work/limaje de programare/1_CORE/BlockChainCore/stress-output")
TIMELINE = OUT / "sustain-timeline.csv"
LOG = OUT / "sustain.log"

CHAINS = {
    "mainnet": "https://omnibusblockchain.cc:8443/api-mainnet",
    "testnet": "https://omnibusblockchain.cc:8443/api-testnet",
}
SSL_CTX = ssl.create_default_context()

DURATION_MIN = int(os.environ.get("SUSTAIN_MIN", "30"))
RPS = float(os.environ.get("SUSTAIN_RPS", "3"))

METHODS = [
    ("getblockcount", []),
    ("getmempoolinfo", []),
    ("getrichlist", [5]),
    ("omnibus_getallprices", []),
    ("getvalidatorsv2", []),
    ("getbestblockhash", []),
    ("ns_listTlds", []),
    ("getreputation", ["ob1qw6zhsqg29aht23fksk5w54lkgavatpgltqxlvl"]),
    ("exchange_listPairs", []),
    ("getperformance", []),
]


def log(m: str):
    line = f"[{datetime.now(timezone.utc).isoformat(timespec='seconds')}] {m}"
    print(line, flush=True)
    with open(LOG, "a", encoding="utf-8") as fh:
        fh.write(line + "\n")


def call(chain, method, params, timeout=5.0):
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method,
                       "params": params or []}).encode()
    headers = {"Content-Type": "application/json"}
    t0 = time.time()
    try:
        req = urllib.request.Request(CHAINS[chain], data=body, headers=headers)
        with urllib.request.urlopen(req, timeout=timeout, context=SSL_CTX) as r:
            r.read()
        return ("PASS", (time.time()-t0)*1000)
    except urllib.error.HTTPError as e:
        return (f"HTTP_{e.code}", (time.time()-t0)*1000)
    except Exception as e:
        return (f"ERR", (time.time()-t0)*1000)


def main():
    end = time.time() + DURATION_MIN*60
    log(f"sustain start: {DURATION_MIN} min @ {RPS} rps")
    interval = 1.0 / RPS
    bucket_start = time.time()
    bucket_records = []
    method_idx = 0
    chain_idx = 0
    chains = list(CHAINS.keys())
    write_header = not TIMELINE.exists()
    with open(TIMELINE, "a", newline="", encoding="utf-8") as fh:
        w = csv.writer(fh)
        if write_header:
            w.writerow(["ts", "minute_idx", "calls", "ok", "fail",
                        "p50_ms", "p95_ms", "p99_ms", "mean_ms"])
        minute_idx = 0
        next_call = time.time()
        while time.time() < end:
            now = time.time()
            if now < next_call:
                time.sleep(min(0.05, next_call - now))
                continue
            next_call += interval
            chain = chains[chain_idx % 2]
            chain_idx += 1
            method, params = METHODS[method_idx % len(METHODS)]
            method_idx += 1
            status, lat = call(chain, method, params)
            bucket_records.append((status, lat))
            if time.time() - bucket_start >= 60:
                if bucket_records:
                    lats = [r[1] for r in bucket_records]
                    ok = sum(1 for r in bucket_records if r[0] == "PASS")
                    fail = len(bucket_records) - ok
                    sl = sorted(lats)
                    p50 = statistics.median(lats)
                    p95 = sl[int(len(sl)*0.95)] if sl else 0
                    p99 = sl[int(len(sl)*0.99)] if sl else 0
                    mean = statistics.mean(lats)
                    w.writerow([datetime.now(timezone.utc).isoformat(timespec='seconds'),
                                minute_idx, len(bucket_records), ok, fail,
                                f"{p50:.1f}", f"{p95:.1f}", f"{p99:.1f}", f"{mean:.1f}"])
                    fh.flush()
                    log(f"bucket {minute_idx}: calls={len(bucket_records)} ok={ok} fail={fail} p50={p50:.0f}ms p95={p95:.0f}ms")
                minute_idx += 1
                bucket_records = []
                bucket_start = time.time()
        # final bucket
        if bucket_records:
            lats = [r[1] for r in bucket_records]
            ok = sum(1 for r in bucket_records if r[0] == "PASS")
            fail = len(bucket_records) - ok
            sl = sorted(lats)
            p50 = statistics.median(lats)
            p95 = sl[int(len(sl)*0.95)] if sl else 0
            p99 = sl[int(len(sl)*0.99)] if sl else 0
            mean = statistics.mean(lats)
            w.writerow([datetime.now(timezone.utc).isoformat(timespec='seconds'),
                        minute_idx, len(bucket_records), ok, fail,
                        f"{p50:.1f}", f"{p95:.1f}", f"{p99:.1f}", f"{mean:.1f}"])
    log("sustain done")


if __name__ == "__main__":
    main()
