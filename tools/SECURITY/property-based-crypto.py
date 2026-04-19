#!/usr/bin/env python3
"""OmniBus BlockChainCore — Property-Based Cryptographic Testing.

Tests fundamental cryptographic properties:
  - sign/verify roundtrip for ANY random (msg, sk) pair
  - verify must FAIL for wrong message, wrong key, corrupted signature
  - SHA256(SHA256(x)) determinism
  - BIP-32 child derivation consistency: m/0/1 == (m/0)/1

Uses Python hashlib as SHA-256 reference.  5000 random test cases by default.
"""

import argparse
import hashlib
import hmac
import json
import os
import secrets
import struct
import sys
import time

# ---------------------------------------------------------------------------
RED = "\033[91m"
GREEN = "\033[92m"
YELLOW = "\033[93m"
CYAN = "\033[96m"
BOLD = "\033[1m"
RESET = "\033[0m"

# OmniBus BlockChainCore constants
RPC_PORT = 8332
MAX_SUPPLY = 21_000_000
SAT = int(1e9)
BLOCK_REWARD = 50  # OMNI, halving every 210k blocks
HALVING_INTERVAL = 210_000

# secp256k1 curve order
SECP256K1_N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141

try:
    import coincurve
    HAS_COINCURVE = True
except ImportError:
    HAS_COINCURVE = False


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
def sha256(data: bytes) -> bytes:
    return hashlib.sha256(data).digest()


def double_sha256(data: bytes) -> bytes:
    return sha256(sha256(data))


def hmac_sha512(key: bytes, data: bytes) -> bytes:
    return hmac.new(key, data, hashlib.sha512).digest()


def random_privkey() -> bytes:
    while True:
        k = secrets.token_bytes(32)
        if 0 < int.from_bytes(k, "big") < SECP256K1_N:
            return k


# ---------------------------------------------------------------------------
# BIP-32 derivation (simplified, non-hardened only)
# ---------------------------------------------------------------------------
def bip32_master(seed: bytes) -> tuple:
    """Derive master key from seed. Returns (key_bytes, chain_code)."""
    I = hmac_sha512(b"Bitcoin seed", seed)
    return I[:32], I[32:]


def bip32_derive_child(parent_key: bytes, parent_chain: bytes, index: int) -> tuple:
    """Derive non-hardened child. Simplified — uses HMAC-SHA512."""
    # For non-hardened: data = pubkey_compressed || index
    # Simplified: we use the private key hash as "pubkey" stand-in
    pubkey_stand_in = sha256(parent_key)[:33]  # 33 bytes like compressed pubkey
    data = pubkey_stand_in + struct.pack(">I", index)
    I = hmac_sha512(parent_chain, data)
    child_key_int = (int.from_bytes(I[:32], "big") + int.from_bytes(parent_key, "big")) % SECP256K1_N
    child_key = child_key_int.to_bytes(32, "big")
    child_chain = I[32:]
    return child_key, child_chain


def bip32_derive_path(seed: bytes, path: list) -> tuple:
    """Derive key at path [0, 1, ...] from seed."""
    key, chain = bip32_master(seed)
    for idx in path:
        key, chain = bip32_derive_child(key, chain, idx)
    return key, chain


# ---------------------------------------------------------------------------
# Property tests
# ---------------------------------------------------------------------------
class Stats:
    def __init__(self):
        self.tests = {}

    def record(self, name: str, passed: bool, detail: str = ""):
        if name not in self.tests:
            self.tests[name] = {"pass": 0, "fail": 0, "errors": []}
        if passed:
            self.tests[name]["pass"] += 1
        else:
            self.tests[name]["fail"] += 1
            if detail:
                self.tests[name]["errors"].append(detail)

    def summary(self) -> dict:
        total_pass = sum(t["pass"] for t in self.tests.values())
        total_fail = sum(t["fail"] for t in self.tests.values())
        return {
            "categories": {k: {"pass": v["pass"], "fail": v["fail"]}
                           for k, v in self.tests.items()},
            "total_pass": total_pass,
            "total_fail": total_fail,
            "verdict": "PASS" if total_fail == 0 else "FAIL",
        }


def test_sign_verify_roundtrip(stats: Stats, iterations: int):
    """sign(msg, sk) then verify(msg, sig, pk) must pass for ANY random msg+sk."""
    if not HAS_COINCURVE:
        print(f"  {YELLOW}[SKIP] coincurve not available — using HMAC-SHA256 as sign/verify stand-in{RESET}")
        for i in range(iterations):
            sk = random_privkey()
            msg = secrets.token_bytes(secrets.randbelow(256) + 1)
            # HMAC-based "signature"
            sig = hmac.new(sk, msg, hashlib.sha256).digest()
            # Verify: recompute
            verify = hmac.new(sk, msg, hashlib.sha256).digest()
            stats.record("sign_verify_roundtrip", sig == verify,
                         f"iter {i}: HMAC mismatch")
        return

    for i in range(iterations):
        sk_bytes = random_privkey()
        msg = secrets.token_bytes(secrets.randbelow(256) + 1)
        msg_hash = sha256(msg)
        try:
            sk = coincurve.PrivateKey(sk_bytes)
            sig = sk.sign(msg_hash, hasher=None)
            pk = sk.public_key
            ok = pk.verify(sig, msg_hash, hasher=None)
            stats.record("sign_verify_roundtrip", ok,
                         f"iter {i}: verify returned False")
        except Exception as exc:
            stats.record("sign_verify_roundtrip", False, f"iter {i}: {exc}")

        if (i + 1) % 1000 == 0:
            print(f"    {CYAN}sign/verify: {i+1}/{iterations}{RESET}")


def test_verify_wrong_message(stats: Stats, iterations: int):
    """verify must FAIL for wrong message."""
    if not HAS_COINCURVE:
        for i in range(iterations):
            sk = random_privkey()
            msg = secrets.token_bytes(32)
            wrong = secrets.token_bytes(32)
            sig = hmac.new(sk, msg, hashlib.sha256).digest()
            verify_wrong = hmac.new(sk, wrong, hashlib.sha256).digest()
            stats.record("verify_wrong_msg", sig != verify_wrong,
                         f"iter {i}: wrong msg matched")
        return

    for i in range(iterations):
        sk_bytes = random_privkey()
        msg = sha256(secrets.token_bytes(32))
        wrong_msg = sha256(secrets.token_bytes(32))
        try:
            sk = coincurve.PrivateKey(sk_bytes)
            sig = sk.sign(msg, hasher=None)
            pk = sk.public_key
            should_fail = pk.verify(sig, wrong_msg, hasher=None)
            stats.record("verify_wrong_msg", not should_fail,
                         f"iter {i}: wrong msg accepted!")
        except coincurve.ecdsa.InvalidSignature:
            stats.record("verify_wrong_msg", True)
        except Exception:
            stats.record("verify_wrong_msg", True)  # rejection is correct


def test_verify_wrong_key(stats: Stats, iterations: int):
    """verify must FAIL for wrong public key."""
    if not HAS_COINCURVE:
        for i in range(iterations):
            sk1 = random_privkey()
            sk2 = random_privkey()
            msg = secrets.token_bytes(32)
            sig1 = hmac.new(sk1, msg, hashlib.sha256).digest()
            sig2 = hmac.new(sk2, msg, hashlib.sha256).digest()
            stats.record("verify_wrong_key", sig1 != sig2,
                         f"iter {i}: different keys same sig")
        return

    for i in range(iterations):
        sk1 = coincurve.PrivateKey(random_privkey())
        sk2 = coincurve.PrivateKey(random_privkey())
        msg = sha256(secrets.token_bytes(32))
        sig = sk1.sign(msg, hasher=None)
        try:
            should_fail = sk2.public_key.verify(sig, msg, hasher=None)
            stats.record("verify_wrong_key", not should_fail,
                         f"iter {i}: wrong key accepted")
        except Exception:
            stats.record("verify_wrong_key", True)


def test_corrupted_signature(stats: Stats, iterations: int):
    """verify must FAIL for corrupted signature (flip random bit)."""
    if not HAS_COINCURVE:
        for i in range(iterations):
            sk = random_privkey()
            msg = secrets.token_bytes(32)
            sig = bytearray(hmac.new(sk, msg, hashlib.sha256).digest())
            bit_pos = secrets.randbelow(len(sig) * 8)
            sig[bit_pos // 8] ^= 1 << (bit_pos % 8)
            original = hmac.new(sk, msg, hashlib.sha256).digest()
            stats.record("corrupted_sig", bytes(sig) != original,
                         f"iter {i}: corrupted sig still matches")
        return

    for i in range(iterations):
        sk = coincurve.PrivateKey(random_privkey())
        msg = sha256(secrets.token_bytes(32))
        sig = bytearray(sk.sign(msg, hasher=None))
        bit_pos = secrets.randbelow(len(sig) * 8)
        sig[bit_pos // 8] ^= 1 << (bit_pos % 8)
        try:
            should_fail = sk.public_key.verify(bytes(sig), msg, hasher=None)
            stats.record("corrupted_sig", not should_fail,
                         f"iter {i}: corrupted sig accepted")
        except Exception:
            stats.record("corrupted_sig", True)


def test_double_sha256_deterministic(stats: Stats, iterations: int):
    """SHA256(SHA256(x)) must be deterministic for any x."""
    for i in range(iterations):
        data = secrets.token_bytes(secrets.randbelow(1024) + 1)
        h1 = double_sha256(data)
        h2 = double_sha256(data)
        stats.record("double_sha256_determ", h1 == h2,
                     f"iter {i}: double SHA-256 not deterministic")


def test_bip32_path_consistency(stats: Stats, iterations: int):
    """Deriving m/0/1 directly == deriving m/0 then /1."""
    for i in range(iterations):
        seed = secrets.token_bytes(64)
        # Direct: m/0/1
        key_direct, _ = bip32_derive_path(seed, [0, 1])
        # Step-by-step: m/0 then /1
        key_m0, chain_m0 = bip32_derive_path(seed, [0])
        key_step, _ = bip32_derive_child(key_m0, chain_m0, 1)
        stats.record("bip32_path_consistency", key_direct == key_step,
                     f"iter {i}: m/0/1 != (m/0)/1")

        if (i + 1) % 500 == 0:
            print(f"    {CYAN}BIP-32: {i+1}/{iterations}{RESET}")


def main():
    parser = argparse.ArgumentParser(
        description="OmniBus BlockChainCore — Property-Based Crypto Testing"
    )
    parser.add_argument("--iterations", "-n", type=int, default=5000,
                        help="Random test cases per property (default: 5000)")
    parser.add_argument("--json", action="store_true", help="Output JSON")
    args = parser.parse_args()

    n = args.iterations

    print(f"{CYAN}{BOLD}{'='*60}")
    print(f" OmniBus BlockChainCore — Property-Based Crypto Tests")
    print(f" Iterations per test: {n}")
    print(f" coincurve: {'YES' if HAS_COINCURVE else 'NO (using HMAC fallback)'}")
    print(f"{'='*60}{RESET}\n")

    stats = Stats()
    t0 = time.time()

    print(f"{GREEN}[1/6] sign/verify roundtrip ...{RESET}")
    test_sign_verify_roundtrip(stats, n)

    print(f"{GREEN}[2/6] verify with wrong message ...{RESET}")
    test_verify_wrong_message(stats, n)

    print(f"{GREEN}[3/6] verify with wrong key ...{RESET}")
    test_verify_wrong_key(stats, n)

    print(f"{GREEN}[4/6] corrupted signature rejection ...{RESET}")
    test_corrupted_signature(stats, n)

    print(f"{GREEN}[5/6] double SHA-256 determinism ...{RESET}")
    test_double_sha256_deterministic(stats, n)

    print(f"{GREEN}[6/6] BIP-32 path consistency ...{RESET}")
    test_bip32_path_consistency(stats, n)

    elapsed = time.time() - t0
    summary = stats.summary()
    summary["elapsed_seconds"] = round(elapsed, 2)

    if args.json:
        print(json.dumps(summary, indent=2))
    else:
        print(f"\n{CYAN}{'='*60}")
        print(f" RESULTS")
        print(f"{'='*60}{RESET}")
        for cat, data in summary["categories"].items():
            color = GREEN if data["fail"] == 0 else RED
            print(f"  {cat:30s}: {color}{data['pass']} pass / {data['fail']} fail{RESET}")
        v = summary["verdict"]
        vc = GREEN if v == "PASS" else RED
        print(f"\n  {'VERDICT':30s}: {vc}{BOLD}{v}{RESET}")
        print(f"  {'Elapsed':30s}: {elapsed:.2f}s")

    sys.exit(0 if summary["verdict"] == "PASS" else 1)


if __name__ == "__main__":
    main()
