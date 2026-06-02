#!/usr/bin/env python3
"""regenerate_quantum_pool.py — generate REAL PQ keypairs for 100 Quantum addresses.

Unlike the original generate_addresses_pool.py (which used hash160(ecdsa_pubkey || tag)
without a real PQ secret key), this writes addresses_pool_v2.json where:

  address = prefix + hex(hash160(real_pq_pubkey))

and stores the matching pq_secret_key_hex so we can SIGN outgoing TXs.

Schemes per prefix:
  obk1_ → ml_dsa_87       (chain code 5, pq_omni_ml_dsa)       — 25 addresses
  obf5_ → falcon_512      (chain code 6, pq_omni_falcon)       — 25 addresses
  obs3_ → ml_dsa_87       (chain code 7, pq_omni_dilithium)    — 25 addresses
                          (chain dispatcher routes 7 → verifyLove == ML-DSA-87)
  obd5_ → sphincs_shake_256s_simple (chain code 8, pq_omni_slh_dsa) — 25 addresses

Note: ml_kem_768 is a KEM and CANNOT sign — chain rejects scheme 4 (vacation_kem).
PQ-OMNI dilithium (code 7) reuses ml_dsa_87 in the chain verifier (see
isolated_wallet.zig verifySignature dispatch — pq_omni_dilithium → verifyLoveSignature).

Usage:
  python regenerate_quantum_pool.py [seed_for_determinism]

Output: addresses_pool_v2.json next to this script.
"""
import os, json, hashlib, sys, time

from chain_stub_pq import MlDsa87, Falcon512, SlhDsa256s


# ── HASH160 ─────────────────────────────────────────────────────────────
def hash160(data: bytes) -> bytes:
    h = hashlib.sha256(data).digest()
    r = hashlib.new("ripemd160"); r.update(h)
    return r.digest()


# ── Scheme map ──────────────────────────────────────────────────────────
# (prefix, scheme_name_for_RPC, scheme_code, sign_module)
SCHEMES = [
    ("obk1_", "pq_omni_ml_dsa",     5, MlDsa87),
    ("obf5_", "pq_omni_falcon",     6, Falcon512),
    ("obs3_", "pq_omni_dilithium",  7, MlDsa87),    # chain alias -> ML-DSA-87
    ("obd5_", "pq_omni_slh_dsa",    8, SlhDsa256s),
]


def generate_pq_keypair(sign_cls):
    """chain_stub_pq generate_keypair() returns (public_key, secret_key) bytes."""
    pk, sk = sign_cls.generate_keypair()
    return pk, sk


def derive_quantum_address(prefix: str, pq_pubkey: bytes) -> str:
    """address = prefix + hex(hash160(pq_pubkey))"""
    return prefix + hash160(pq_pubkey).hex()


def main():
    print("[INFO] Regenerating Quantum address pool with REAL PQ keypairs.")
    print("[INFO] Using chain-stub PQ (SHAKE256-based, matches core/pq_crypto.zig).\n")

    pool = []
    started = time.time()
    for prefix, scheme_name, code, cls in SCHEMES:
        print(f"  Generating 25 keypairs for {prefix} ({scheme_name}, code={code})...")
        pk_size = cls.PUBLIC_KEY_SIZE
        sk_size = cls.SECRET_KEY_SIZE
        sig_size = cls.SIGNATURE_SIZE
        print(f"    PK={pk_size}B  SK={sk_size}B  SIG_SIZE={sig_size}B")
        t0 = time.time()
        for i in range(25):
            pk, sk = generate_pq_keypair(cls)
            assert len(pk) == pk_size, f"pubkey size mismatch: {len(pk)} != {pk_size}"
            assert len(sk) == sk_size, f"secret size mismatch: {len(sk)} != {sk_size}"
            addr = derive_quantum_address(prefix, pk)
            pool.append({
                "prefix": prefix,
                "scheme_name": scheme_name,
                "scheme_code": code,
                "index": i,
                "address": addr,
                "pq_public_key_hex": pk.hex(),
                "pq_secret_key_hex": sk.hex(),
                "pq_pubkey_size": pk_size,
                "pq_seckey_size": sk_size,
            })
        dt = time.time() - t0
        first = next(p for p in pool if p["prefix"] == prefix)
        print(f"    OK generated in {dt:.1f}s -- sample: {first['address']}\n")

    out = {
        "version": 2,
        "generated_at": int(time.time()),
        "quantum_count": len(pool),
        "schemes": [{"prefix": p, "name": n, "code": c} for p, n, c, _ in SCHEMES],
        "note": "PQ keypairs are CHAIN-STUB algorithms (SHAKE256-based simulation, NOT real Falcon/ML-DSA/SLH-DSA). Compatible with current core/pq_crypto.zig stubs.",
        "quantum": pool,
    }
    out_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "addresses_pool_v2.json")
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(out, f, indent=2)
    print(f"[OK] Wrote {len(pool)} Quantum addresses (4 schemes x 25 each) -> {out_path}")
    print(f"[OK] Total time: {time.time()-started:.1f}s")


if __name__ == "__main__":
    main()
