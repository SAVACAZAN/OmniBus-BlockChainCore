#!/usr/bin/env python3
"""generate_addresses_pool.py — derive 100 ECDSA + 100 Quantum from session mnemonic.

Output: addresses_pool.json with 200 addresses split:
  - 100 ECDSA  (ob1q...)  via BIP-44 m/44'/777'/0'/0/0..99
  - 100 Quantum: 25 x obk1_ / 25 x obf5_ / 25 x obd5_ / 25 x obs3_
                 (Quantum addresses are deterministic from mnemonic + index too,
                  using the same BIP-44 ECDSA pubkey + scheme tag — chain-side
                  hash160(ecdsa_pubkey || scheme_byte) gives a stable address.)

Loads mnemonic from latest session file in:
  %LOCALAPPDATA%/lcx-liberty-suite/sessions/*.json
"""
import os, json, hashlib, glob, sys
from bip_utils import Bip39SeedGenerator, Bip32Slip10Secp256k1

# ── Bech32 encoder (no external dep) ────────────────────────────────────
CHARSET = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"
GEN = [0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3]

def _polymod(values):
    chk = 1
    for v in values:
        b = chk >> 25
        chk = ((chk & 0x1ffffff) << 5) ^ v
        for i in range(5):
            chk ^= GEN[i] if ((b >> i) & 1) else 0
    return chk

def _hrp_expand(hrp):
    return [ord(c) >> 5 for c in hrp] + [0] + [ord(c) & 31 for c in hrp]

def _create_checksum(hrp, data, spec="bech32"):
    const = 1 if spec == "bech32" else 0x2bc830a3
    values = _hrp_expand(hrp) + data
    pm = _polymod(values + [0,0,0,0,0,0]) ^ const
    return [(pm >> 5*(5-i)) & 31 for i in range(6)]

def _convertbits(data, frombits, tobits, pad=True):
    acc = 0; bits = 0; out = []; maxv = (1 << tobits) - 1
    for v in data:
        if v < 0 or (v >> frombits): return None
        acc = (acc << frombits) | v; bits += frombits
        while bits >= tobits:
            bits -= tobits
            out.append((acc >> bits) & maxv)
    if pad and bits: out.append((acc << (tobits-bits)) & maxv)
    return out

def bech32_encode_witness(hrp, version, witprog):
    data = [version] + _convertbits(list(witprog), 8, 5)
    spec = "bech32" if version == 0 else "bech32m"
    combined = data + _create_checksum(hrp, data, spec)
    return hrp + "1" + "".join(CHARSET[d] for d in combined)


# ── HASH160 helpers ─────────────────────────────────────────────────────
def hash160(data: bytes) -> bytes:
    h = hashlib.sha256(data).digest()
    r = hashlib.new("ripemd160"); r.update(h)
    return r.digest()


# ── Load mnemonic from latest session ───────────────────────────────────
def load_mnemonic() -> str:
    if len(sys.argv) > 1:
        p = sys.argv[1]
    else:
        sess_dir = os.path.expandvars(r"%LOCALAPPDATA%\lcx-liberty-suite\sessions")
        files = sorted(glob.glob(os.path.join(sess_dir, "*.json")))
        if not files:
            raise SystemExit(f"No session files in {sess_dir}")
        p = files[-1]
    print(f"[INFO] Loading mnemonic from: {p}")
    with open(p, "r", encoding="utf-8") as f:
        d = json.load(f)
    return d["mnemonic"]


# ── Derive ECDSA at BIP-44 path m/44'/777'/0'/0/idx ─────────────────────
def derive_ecdsa(seed: bytes, idx: int):
    bip32 = Bip32Slip10Secp256k1.FromSeed(seed)
    path = f"m/44'/777'/0'/0/{idx}"
    child = bip32.DerivePath(path)
    privkey = child.PrivateKey().Raw().ToBytes()
    pubkey = child.PublicKey().RawCompressed().ToBytes()
    h160 = hash160(pubkey)
    address = bech32_encode_witness("ob", 0, h160)
    return address, privkey.hex(), pubkey.hex()


# ── Quantum address: hash160(ecdsa_pubkey || scheme_tag) ────────────────
SCHEME_TAGS = {
    "obk1_": b"\x05",  # pq_omni_ml_dsa = code 5
    "obf5_": b"\x06",  # pq_omni_falcon = code 6
    "obs3_": b"\x07",  # pq_omni_dilithium = code 7
    "obd5_": b"\x08",  # pq_omni_slh_dsa = code 8
}

def quantum_address(prefix: str, ecdsa_pubkey_hex: str) -> str:
    pk = bytes.fromhex(ecdsa_pubkey_hex)
    tag = SCHEME_TAGS[prefix]
    h = hash160(pk + tag)
    return prefix + h.hex()


def main():
    mnemonic = load_mnemonic()
    print(f"[INFO] Mnemonic: {mnemonic.split()[0]} ... {mnemonic.split()[-1]} ({len(mnemonic.split())} words)")
    seed = Bip39SeedGenerator(mnemonic).Generate()
    print(f"[INFO] Seed: {seed.hex()[:16]}...")

    # 100 ECDSA addresses
    ecdsa_pool = []
    for i in range(100):
        addr, priv, pub = derive_ecdsa(seed, i)
        ecdsa_pool.append({"index": i, "address": addr, "pubkey_hex": pub, "privkey_hex": priv})
        if i < 3 or i == 99:
            print(f"  ECDSA #{i:3d}: {addr}")

    # 100 Quantum addresses: 25 per prefix, derived from ECDSA pubkey + scheme tag
    quantum_pool = []
    prefixes = ["obk1_", "obf5_", "obd5_", "obs3_"]
    for prefix in prefixes:
        for i in range(25):
            ecdsa_idx = i + 100  # use indexes 100..199 for Quantum derivation
            _, _, pub = derive_ecdsa(seed, ecdsa_idx)
            qaddr = quantum_address(prefix, pub)
            quantum_pool.append({
                "prefix": prefix,
                "ecdsa_index": ecdsa_idx,
                "address": qaddr,
                "underlying_pubkey_hex": pub,
            })
        first = next(q for q in quantum_pool if q["prefix"] == prefix)
        print(f"  {prefix}: {first['address']} (and 24 more)")

    out = {
        "generated_from_mnemonic_first_word": mnemonic.split()[0],
        "ecdsa_count": len(ecdsa_pool),
        "quantum_count": len(quantum_pool),
        "ecdsa": ecdsa_pool,
        "quantum": quantum_pool,
    }
    out_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "addresses_pool.json")
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(out, f, indent=2)
    print(f"\n[OK] Wrote {len(ecdsa_pool)} ECDSA + {len(quantum_pool)} Quantum -> {out_path}")


if __name__ == "__main__":
    main()
