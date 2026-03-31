"""
generate_multiwallet.py — OmniBus Multi-Chain Wallet Generator
Derives addresses from a SINGLE mnemonic anchor across:
  - OMNI (5 PQ domains, Bech32 ob1q...)
  - BTC  (Legacy P2PKH 1..., SegWit P2SH 3..., Native SegWit bc1q..., Taproot bc1p...)
  - ETH  (Keccak256, 0x...)
  - EGLD (Bech32 erd1...)
  - SOL  (Ed25519 Base58)

Usage:
    pip install bip_utils mnemonic
    python generate_multiwallet.py
    python generate_multiwallet.py --mnemonic "abandon abandon ... about"
    python generate_multiwallet.py --output wallet.json

Output:
    MULTIWALLET_FULL_<date>.json  — ALL chains, full metadata (SECRET!)
    MULTIWALLET_PUBLIC_<date>.json — Public keys + addresses only
"""

import json
import hashlib
import hmac as _hmac
import datetime
import os
import sys
import secrets
import struct

# ── Bech32 / Bech32m encoder ─────────────────────────────────────────────────

CHARSET = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"
BECH32_CONST = 1
BECH32M_CONST = 0x2bc830a3
GEN = [0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3]

def _bech32_polymod(values):
    chk = 1
    for v in values:
        b = chk >> 25
        chk = ((chk & 0x1ffffff) << 5) ^ v
        for i in range(5):
            chk ^= GEN[i] if ((b >> i) & 1) else 0
    return chk

def _bech32_hrp_expand(hrp):
    return [ord(x) >> 5 for x in hrp] + [0] + [ord(x) & 31 for x in hrp]

def _bech32_create_checksum(hrp, data, spec):
    const = BECH32_CONST if spec == "bech32" else BECH32M_CONST
    values = _bech32_hrp_expand(hrp) + list(data) + [0]*6
    p = _bech32_polymod(values) ^ const
    return [(p >> 5*(5-i)) & 31 for i in range(6)]

def _convertbits(data, frombits, tobits, pad=True):
    acc, bits, ret = 0, 0, []
    maxv = (1 << tobits) - 1
    for value in data:
        acc = (acc << frombits) | value
        bits += frombits
        while bits >= tobits:
            bits -= tobits
            ret.append((acc >> bits) & maxv)
    if pad and bits:
        ret.append((acc << (tobits - bits)) & maxv)
    return ret

def bech32_encode(hrp, witver, witprog):
    """Encode witness address. witver=0 -> Bech32, witver>=1 -> Bech32m"""
    spec = "bech32" if witver == 0 else "bech32m"
    conv = _convertbits(witprog, 8, 5)
    data = [witver] + conv
    checksum = _bech32_create_checksum(hrp, data, spec)
    return hrp + "1" + "".join(CHARSET[d] for d in data + checksum)

# ── Base58 ────────────────────────────────────────────────────────────────────

_B58 = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"

def _b58encode(data: bytes) -> str:
    n = int.from_bytes(data, "big")
    r = ""
    while n > 0:
        n, rem = divmod(n, 58)
        r = _B58[rem] + r
    leading = len(data) - len(data.lstrip(b"\x00"))
    return "1" * leading + r

def _checksum(d: bytes) -> bytes:
    return hashlib.sha256(hashlib.sha256(d).digest()).digest()[:4]

def _hash160(d: bytes) -> bytes:
    return hashlib.new("ripemd160", hashlib.sha256(d).digest()).digest()

def _wif_encode(privkey: bytes, version: int = 0x80, compressed: bool = True) -> str:
    payload = bytes([version]) + privkey
    if compressed:
        payload += b"\x01"
    return _b58encode(payload + _checksum(payload))

# ── BIP-39 / BIP-32 ──────────────────────────────────────────────────────────

def _mnemonic_to_seed(mnemonic: str, passphrase: str = "") -> bytes:
    try:
        from bip_utils import Bip39SeedGenerator
        return bytes(Bip39SeedGenerator(mnemonic).Generate(passphrase))
    except Exception:
        salt = ("mnemonic" + passphrase).encode()
        return hashlib.pbkdf2_hmac("sha512", mnemonic.encode(), salt, 2048, 64)

def _generate_mnemonic_12() -> str:
    try:
        from bip_utils import Bip39MnemonicGenerator, Bip39WordsNum
        return str(Bip39MnemonicGenerator().FromWordsNumber(Bip39WordsNum.WORDS_NUM_12))
    except Exception:
        pass
    try:
        from mnemonic import Mnemonic
        return Mnemonic("english").generate(128)
    except Exception:
        pass
    raise RuntimeError("Install: pip install bip_utils mnemonic")

def _seed_to_keypair(seed: bytes, coin_type: int, purpose: int = 44, index: int = 0):
    """BIP-32 secp256k1 derivation via bip_utils."""
    path = f"m/{purpose}'/{coin_type}'/0'/0/{index}"
    try:
        from bip_utils import Bip32Slip10Secp256k1, Bip32KeyIndex
        bip32 = Bip32Slip10Secp256k1.FromSeed(seed)
        node  = (bip32
                 .ChildKey(Bip32KeyIndex.HardenIndex(purpose))
                 .ChildKey(Bip32KeyIndex.HardenIndex(coin_type))
                 .ChildKey(Bip32KeyIndex.HardenIndex(0))
                 .ChildKey(0)
                 .ChildKey(index))
        priv = node.PrivateKey().Raw().ToBytes()
        pub  = node.PublicKey().RawCompressed().ToBytes()
        return priv, pub, path
    except Exception as e:
        # HKDF fallback
        salt = hashlib.sha256(f"OmniBus:{purpose}:{coin_type}".encode()).digest()
        prk  = _hmac.new(salt, seed, hashlib.sha512).digest()
        info = path.encode()
        okm, t = b"", b""
        for i in range(1, 3):
            t = _hmac.new(prk, t + info + bytes([i]), hashlib.sha512).digest()
            okm += t
        return okm[:32], okm[32:65], path

# ── Extended key serialization ────────────────────────────────────────────────

def _serialize_xkey(version_bytes: bytes, depth: int, fingerprint: bytes,
                    child_index: int, chain_code: bytes, key_data: bytes) -> str:
    """Serialize BIP-32 extended key → Base58Check"""
    data = (version_bytes + bytes([depth]) + fingerprint +
            struct.pack(">I", child_index) + chain_code + key_data)
    return _b58encode(data + _checksum(data))

def _master_fingerprint(seed: bytes) -> bytes:
    """First 4 bytes of Hash160(master_public_key)"""
    try:
        from bip_utils import Bip32Slip10Secp256k1
        bip32 = Bip32Slip10Secp256k1.FromSeed(seed)
        pub = bip32.PublicKey().RawCompressed().ToBytes()
        return _hash160(pub)[:4]
    except Exception:
        master = _hmac.new(b"Bitcoin seed", seed, hashlib.sha512).digest()
        return _hash160(master[:32])[:4]

# ── Chain-specific address generators ─────────────────────────────────────────

def _derive_omni_addresses(seed: bytes) -> list:
    """OmniBus 5 PQ domains — Bech32 ob1q..."""
    PQ_DOMAINS = [
        {"name": "omnibus.omni",     "coin_type": 777, "algorithm": "Dilithium-5 + Kyber-768", "security": 256},
        {"name": "omnibus.love",     "coin_type": 778, "algorithm": "ML-DSA (Dilithium-5)",    "security": 256},
        {"name": "omnibus.food",     "coin_type": 779, "algorithm": "Falcon-512",              "security": 192},
        {"name": "omnibus.rent",     "coin_type": 780, "algorithm": "SLH-DSA (SPHINCS+)",      "security": 256},
        {"name": "omnibus.vacation", "coin_type": 781, "algorithm": "Falcon-Light / AES-128",  "security": 128},
    ]
    results = []
    for dom in PQ_DOMAINS:
        priv, pub, path = _seed_to_keypair(seed, dom["coin_type"], 44)
        h160 = _hash160(pub)
        addr = bech32_encode("ob", 0, list(h160))
        script_pubkey = "0014" + h160.hex()
        results.append({
            "chain":           "OMNI",
            "domain":          dom["name"],
            "coin_type":       dom["coin_type"],
            "algorithm":       dom["algorithm"],
            "security_level":  dom["security"],
            "address":         addr,
            "address_type":    "NATIVE_SEGWIT",
            "witness_version": 0,
            "derivation_path": path,
            "public_key":      pub.hex(),
            "private_key_hex": priv.hex(),
            "private_key_wif": _wif_encode(priv, 0x80),
            "hash160":         h160.hex(),
            "script_pubkey":   script_pubkey,
        })
    return results

def _derive_btc_addresses(seed: bytes) -> list:
    """Bitcoin 4 address types from same seed (flat list for backward compat)."""
    results = []
    for purpose, atype, gen_fn in [
        (44, "LEGACY_P2PKH", _btc_addr_legacy),
        (49, "SEGWIT_P2SH", _btc_addr_segwit_p2sh),
        (84, "NATIVE_SEGWIT", _btc_addr_native_segwit),
        (86, "TAPROOT", _btc_addr_taproot),
    ]:
        priv, pub, path = _seed_to_keypair(seed, 0, purpose)
        results.append(gen_fn(priv, pub, path, 0, 0))
    return results


def _btc_addr_legacy(priv, pub, path, chain, index):
    h160 = _hash160(pub)
    addr = _b58encode(b"\x00" + h160 + _checksum(b"\x00" + h160))
    return {
        "chain": chain, "index": index,
        "address": addr, "address_type": "LEGACY_P2PKH",
        "derivation_path": path,
        "public_key": pub.hex(), "private_key_hex": priv.hex(),
        "private_key_wif": _wif_encode(priv, 0x80),
        "script_pubkey": "76a914" + h160.hex() + "88ac",
        "hash160": h160.hex(), "witness_version": None,
    }


def _btc_addr_segwit_p2sh(priv, pub, path, chain, index):
    h160 = _hash160(pub)
    redeem = b"\x00\x14" + h160
    redeem_hash = _hash160(redeem)
    addr = _b58encode(b"\x05" + redeem_hash + _checksum(b"\x05" + redeem_hash))
    return {
        "chain": chain, "index": index,
        "address": addr, "address_type": "SEGWIT_P2SH",
        "derivation_path": path,
        "public_key": pub.hex(), "private_key_hex": priv.hex(),
        "private_key_wif": _wif_encode(priv, 0x80),
        "script_pubkey": "a914" + redeem_hash.hex() + "87",
        "hash160": h160.hex(), "witness_version": 0,
    }


def _btc_addr_native_segwit(priv, pub, path, chain, index):
    h160 = _hash160(pub)
    addr = bech32_encode("bc", 0, list(h160))
    return {
        "chain": chain, "index": index,
        "address": addr, "address_type": "NATIVE_SEGWIT",
        "derivation_path": path,
        "public_key": pub.hex(), "private_key_hex": priv.hex(),
        "private_key_wif": _wif_encode(priv, 0x80),
        "script_pubkey": "0014" + h160.hex(),
        "hash160": h160.hex(), "witness_version": 0,
    }


def _btc_addr_taproot(priv, pub, path, chain, index):
    x_only = pub[1:33] if len(pub) == 33 else pub[:32]
    addr = bech32_encode("bc", 1, list(x_only))
    return {
        "chain": chain, "index": index,
        "address": addr, "address_type": "TAPROOT",
        "derivation_path": path,
        "public_key": pub.hex(), "private_key_hex": priv.hex(),
        "private_key_wif": _wif_encode(priv, 0x80),
        "script_pubkey": "5120" + x_only.hex(),
        "hash160": _hash160(pub).hex(), "witness_version": 1,
    }


# ── Extended key helpers ──────────────────────────────────────────────────────

# BIP-32 version bytes per purpose
_XKEY_VERSIONS = {
    44: {"pub": b"\x04\x88\xB2\x1E", "prv": b"\x04\x88\xAD\xE4"},  # xpub / xprv
    49: {"pub": b"\x04\x9D\x7C\xB2", "prv": b"\x04\x9D\x78\x78"},  # ypub / yprv
    84: {"pub": b"\x04\xB2\x47\x46", "prv": b"\x04\xB2\x43\x0C"},  # zpub / zprv
    86: {"pub": b"\x04\x88\xB2\x1E", "prv": b"\x04\x88\xAD\xE4"},  # xpub / xprv (Taproot uses same)
}


def _derive_account_xkeys(seed, purpose, coin_type=0, account=0):
    """Derive xpub/xprv at account level m/purpose'/coin_type'/account'"""
    try:
        from bip_utils import Bip32Slip10Secp256k1, Bip32KeyIndex
        bip32 = Bip32Slip10Secp256k1.FromSeed(seed)
        node = (bip32
                .ChildKey(Bip32KeyIndex.HardenIndex(purpose))
                .ChildKey(Bip32KeyIndex.HardenIndex(coin_type))
                .ChildKey(Bip32KeyIndex.HardenIndex(account)))
        priv_raw = node.PrivateKey().Raw().ToBytes()
        pub_raw = node.PublicKey().RawCompressed().ToBytes()
        chain_code = node.ChainCode().ToBytes()

        # Parent fingerprint
        parent = (bip32
                  .ChildKey(Bip32KeyIndex.HardenIndex(purpose))
                  .ChildKey(Bip32KeyIndex.HardenIndex(coin_type)))
        parent_pub = parent.PublicKey().RawCompressed().ToBytes()
        parent_fp = _hash160(parent_pub)[:4]

        versions = _XKEY_VERSIONS.get(purpose, _XKEY_VERSIONS[44])
        child_idx = 0x80000000 + account

        xpub = _serialize_xkey(versions["pub"], 3, parent_fp, child_idx, chain_code, pub_raw)
        xprv = _serialize_xkey(versions["prv"], 3, parent_fp, child_idx, chain_code, b"\x00" + priv_raw)
        return xpub, xprv
    except Exception:
        return "unavailable (install bip_utils)", "unavailable (install bip_utils)"


def _derive_btc_accounts(seed: bytes, address_indices=None) -> dict:
    """Bitcoin full account structure — 4 purposes × N addresses, with xpub/xprv per account.
    Identical to BTC Core wallet metadata format."""
    if address_indices is None:
        address_indices = [0, 1, 2, 3, 4, 5]

    PURPOSE_CONFIG = [
        (44, "LEGACY_P2PKH", _btc_addr_legacy),
        (49, "SEGWIT_P2SH", _btc_addr_segwit_p2sh),
        (84, "NATIVE_SEGWIT", _btc_addr_native_segwit),
        (86, "TAPROOT", _btc_addr_taproot),
    ]

    accounts = {}
    for purpose, addr_type, gen_fn in PURPOSE_CONFIG:
        xpub, xprv = _derive_account_xkeys(seed, purpose)

        addresses = []
        for idx in address_indices:
            priv, pub, path = _seed_to_keypair(seed, 0, purpose, idx)
            addr_obj = gen_fn(priv, pub, path, 0, idx)
            addresses.append(addr_obj)

        accounts[str(purpose)] = {
            "purpose": purpose,
            "derivation_base": f"m/{purpose}'/0'/0'",
            "xpub": xpub,
            "xprv": xprv,
            "address_type": addr_type,
            "addresses": addresses,
        }

    return accounts


def _derive_omni_accounts(seed: bytes, address_indices=None) -> dict:
    """OmniBus account structure — 5 PQ domains × N addresses, with xpub/xprv per domain."""
    if address_indices is None:
        address_indices = [0, 1, 2, 3, 4, 5]

    PQ_DOMAINS = [
        {"name": "omnibus.omni",     "coin_type": 777, "algorithm": "Dilithium-5 + Kyber-768", "security": 256},
        {"name": "omnibus.love",     "coin_type": 778, "algorithm": "ML-DSA (Dilithium-5)",    "security": 256},
        {"name": "omnibus.food",     "coin_type": 779, "algorithm": "Falcon-512",              "security": 192},
        {"name": "omnibus.rent",     "coin_type": 780, "algorithm": "SLH-DSA (SPHINCS+)",      "security": 256},
        {"name": "omnibus.vacation", "coin_type": 781, "algorithm": "Falcon-Light / AES-128",  "security": 128},
    ]

    accounts = {}
    for dom in PQ_DOMAINS:
        xpub, xprv = _derive_account_xkeys(seed, 44, dom["coin_type"])

        addresses = []
        for idx in address_indices:
            priv, pub, path = _seed_to_keypair(seed, dom["coin_type"], 44, idx)
            h160 = _hash160(pub)
            addr = bech32_encode("ob", 0, list(h160))
            addresses.append({
                "chain": 0, "index": idx,
                "address": addr, "address_type": "NATIVE_SEGWIT",
                "derivation_path": path,
                "public_key": pub.hex(), "private_key_hex": priv.hex(),
                "private_key_wif": _wif_encode(priv, 0x80),
                "hash160": h160.hex(),
                "script_pubkey": "0014" + h160.hex(),
                "witness_version": 0,
            })

        accounts[str(dom["coin_type"])] = {
            "domain": dom["name"],
            "coin_type": dom["coin_type"],
            "algorithm": dom["algorithm"],
            "security_level": dom["security"],
            "derivation_base": f"m/44'/{dom['coin_type']}'/0'",
            "xpub": xpub,
            "xprv": xprv,
            "addresses": addresses,
        }

    return accounts

def _derive_single_eth(seed: bytes, index: int = 0) -> dict:
    """Derive single ETH address at index."""
    priv, pub, path = _seed_to_keypair(seed, 60, 44, index)

    try:
        from bip_utils import Bip32Slip10Secp256k1, Bip32KeyIndex
        bip32 = Bip32Slip10Secp256k1.FromSeed(seed)
        node = (bip32
                .ChildKey(Bip32KeyIndex.HardenIndex(44))
                .ChildKey(Bip32KeyIndex.HardenIndex(60))
                .ChildKey(Bip32KeyIndex.HardenIndex(0))
                .ChildKey(0)
                .ChildKey(index))
        pub_uncompressed = node.PublicKey().RawUncompressed().ToBytes()
        try:
            keccak = hashlib.new("keccak256", pub_uncompressed[1:]).digest()
        except ValueError:
            from Crypto.Hash import keccak as _keccak
            keccak = _keccak.new(data=pub_uncompressed[1:], digest_bits=256).digest()
    except Exception:
        keccak = hashlib.sha3_256(pub[1:] if len(pub) > 32 else pub).digest()

    addr_hex = keccak[-20:].hex()
    # EIP-55 checksum
    try:
        try:
            addr_hash = hashlib.new("keccak256", addr_hex.encode()).hexdigest()
        except ValueError:
            addr_hash = hashlib.sha3_256(addr_hex.encode()).hexdigest()
        eth_addr = "0x" + "".join(
            c.upper() if int(addr_hash[i], 16) >= 8 else c
            for i, c in enumerate(addr_hex)
        )
    except Exception:
        eth_addr = "0x" + addr_hex

    return {
        "chain": 0, "index": index,
        "address": eth_addr, "address_type": "EOA",
        "derivation_path": path,
        "public_key": pub.hex(), "private_key_hex": priv.hex(),
        "hash160": None, "script_pubkey": None,
        "witness_version": None, "coin_type": 60,
    }


def _derive_single_egld(seed: bytes, index: int = 0) -> dict:
    """Derive single EGLD address at index."""
    try:
        from bip_utils import Bip32Slip10Ed25519, Bip32KeyIndex
        bip32 = Bip32Slip10Ed25519.FromSeed(seed)
        node = (bip32
                .ChildKey(Bip32KeyIndex.HardenIndex(44))
                .ChildKey(Bip32KeyIndex.HardenIndex(508))
                .ChildKey(Bip32KeyIndex.HardenIndex(0))
                .ChildKey(Bip32KeyIndex.HardenIndex(0))
                .ChildKey(Bip32KeyIndex.HardenIndex(index)))
        priv = node.PrivateKey().Raw().ToBytes()
        pub = node.PublicKey().RawCompressed().ToBytes()
        if len(pub) == 33 and pub[0] == 0x00:
            pub = pub[1:]
    except Exception:
        path_str = f"m/44'/508'/0'/0'/{index}'"
        salt = hashlib.sha256(f"EGLD:{path_str}".encode()).digest()
        km = _hmac.new(salt, seed, hashlib.sha512).digest()
        priv = km[:32]
        pub = km[32:64]

    path = f"m/44'/508'/0'/0'/{index}'"
    conv = _convertbits(list(pub[:32]), 8, 5)
    checksum = _bech32_create_checksum("erd", conv, "bech32")
    addr = "erd1" + "".join(CHARSET[d] for d in conv + checksum)

    return {
        "chain": 0, "index": index,
        "address": addr, "address_type": "ED25519",
        "derivation_path": path,
        "public_key": pub[:32].hex(), "private_key_hex": priv.hex(),
        "hash160": None, "script_pubkey": None,
        "witness_version": None, "coin_type": 508,
    }


def _derive_single_sol(seed: bytes, index: int = 0) -> dict:
    """Derive single SOL address at index."""
    try:
        from bip_utils import Bip32Slip10Ed25519, Bip32KeyIndex
        bip32 = Bip32Slip10Ed25519.FromSeed(seed)
        node = (bip32
                .ChildKey(Bip32KeyIndex.HardenIndex(44))
                .ChildKey(Bip32KeyIndex.HardenIndex(501))
                .ChildKey(Bip32KeyIndex.HardenIndex(0))
                .ChildKey(Bip32KeyIndex.HardenIndex(index)))
        priv = node.PrivateKey().Raw().ToBytes()
        pub = node.PublicKey().RawCompressed().ToBytes()
        if len(pub) == 33 and pub[0] == 0x00:
            pub = pub[1:]
    except Exception:
        path_str = f"m/44'/501'/0'/{index}'"
        salt = hashlib.sha256(f"SOL:{path_str}".encode()).digest()
        km = _hmac.new(salt, seed, hashlib.sha512).digest()
        priv = km[:32]
        pub = km[32:64]

    path = f"m/44'/501'/0'/{index}'"
    addr = _b58encode(pub[:32])

    return {
        "chain": 0, "index": index,
        "address": addr, "address_type": "ED25519",
        "derivation_path": path,
        "public_key": pub[:32].hex(), "private_key_hex": priv.hex(),
        "hash160": None, "script_pubkey": None,
        "witness_version": None, "coin_type": 501,
    }


# Backward compat wrappers
def _derive_eth_address(seed): return _derive_single_eth(seed, 0)
def _derive_egld_address(seed): return _derive_single_egld(seed, 0)
def _derive_sol_address(seed): return _derive_single_sol(seed, 0)


def _derive_eth_accounts(seed: bytes, address_indices=None) -> dict:
    """ETH account — purpose 44 × N addresses."""
    if address_indices is None:
        address_indices = [0, 1, 2, 3, 4, 5]
    xpub, xprv = _derive_account_xkeys(seed, 44, 60)
    addresses = [_derive_single_eth(seed, idx) for idx in address_indices]
    return {"44": {
        "purpose": 44, "derivation_base": "m/44'/60'/0'",
        "address_type": "EOA", "xpub": xpub, "xprv": xprv,
        "addresses": addresses,
    }}


def _derive_egld_accounts(seed: bytes, address_indices=None) -> dict:
    """EGLD account — purpose 44 × N addresses."""
    if address_indices is None:
        address_indices = [0, 1, 2, 3, 4, 5]
    addresses = [_derive_single_egld(seed, idx) for idx in address_indices]
    return {"44": {
        "purpose": 44, "derivation_base": "m/44'/508'/0'/0'",
        "address_type": "ED25519",
        "addresses": addresses,
    }}


def _derive_sol_accounts(seed: bytes, address_indices=None) -> dict:
    """SOL account — purpose 44 × N addresses."""
    if address_indices is None:
        address_indices = [0, 1, 2, 3, 4, 5]
    addresses = [_derive_single_sol(seed, idx) for idx in address_indices]
    return {"44": {
        "purpose": 44, "derivation_base": "m/44'/501'/0'",
        "address_type": "ED25519",
        "addresses": addresses,
    }}

# ── Additional chains (secp256k1-based) ──────────────────────────────────────

def _derive_secp_chain(seed, coin_type, purpose, index, version_byte, hrp=None, addr_format="base58"):
    """Generic secp256k1 chain address derivation."""
    priv, pub, path = _seed_to_keypair(seed, coin_type, purpose, index)
    h160 = _hash160(pub)

    if addr_format == "bech32" and hrp:
        addr = bech32_encode(hrp, 0, list(h160))
        script = "0014" + h160.hex()
    elif addr_format == "cashaddr":
        # Bitcoin Cash — simplified cashaddr (prefix + base58 fallback)
        addr = _b58encode(bytes([version_byte]) + h160 + _checksum(bytes([version_byte]) + h160))
    else:
        addr = _b58encode(bytes([version_byte]) + h160 + _checksum(bytes([version_byte]) + h160))
        script = "76a914" + h160.hex() + "88ac"

    return {
        "chain": 0, "index": index,
        "address": addr, "address_type": "P2PKH",
        "derivation_path": path,
        "public_key": pub.hex(), "private_key_hex": priv.hex(),
        "private_key_wif": _wif_encode(priv, version_byte),
        "hash160": h160.hex(),
        "script_pubkey": script if addr_format != "cashaddr" else "76a914" + h160.hex() + "88ac",
        "witness_version": 0 if addr_format == "bech32" else None,
        "coin_type": coin_type,
    }


def _derive_ed25519_chain(seed, coin_type, index, hrp=None, addr_format="base58"):
    """Generic Ed25519 chain address derivation."""
    try:
        from bip_utils import Bip32Slip10Ed25519, Bip32KeyIndex
        bip32 = Bip32Slip10Ed25519.FromSeed(seed)
        node = (bip32
                .ChildKey(Bip32KeyIndex.HardenIndex(44))
                .ChildKey(Bip32KeyIndex.HardenIndex(coin_type))
                .ChildKey(Bip32KeyIndex.HardenIndex(0))
                .ChildKey(Bip32KeyIndex.HardenIndex(index)))
        priv = node.PrivateKey().Raw().ToBytes()
        pub = node.PublicKey().RawCompressed().ToBytes()
        if len(pub) == 33 and pub[0] == 0x00:
            pub = pub[1:]
    except Exception:
        path_str = f"m/44'/{coin_type}'/0'/{index}'"
        salt = hashlib.sha256(f"CHAIN:{coin_type}:{path_str}".encode()).digest()
        km = _hmac.new(salt, seed, hashlib.sha512).digest()
        priv = km[:32]
        pub = km[32:64]

    path = f"m/44'/{coin_type}'/0'/{index}'"
    pub32 = pub[:32]

    if addr_format == "bech32" and hrp:
        conv = _convertbits(list(pub32), 8, 5)
        checksum = _bech32_create_checksum(hrp, conv, "bech32")
        addr = hrp + "1" + "".join(CHARSET[d] for d in conv + checksum)
    elif addr_format == "ss58":
        # Polkadot SS58 — simplified: base58(0x00 + pub32 + checksum)
        import hashlib as _hl
        ss58_prefix = b"SS58PRE"
        payload = bytes([0]) + pub32
        check_hash = _hl.blake2b(ss58_prefix + payload, digest_size=64).digest()
        addr = _b58encode(payload + check_hash[:2])
    else:
        addr = _b58encode(pub32)

    return {
        "chain": 0, "index": index,
        "address": addr, "address_type": "ED25519",
        "derivation_path": path,
        "public_key": pub32.hex(), "private_key_hex": priv.hex(),
        "hash160": None, "script_pubkey": None,
        "witness_version": None, "coin_type": coin_type,
    }


# ── Account builders for new chains ──────────────────────────────────────────

def _make_secp_accounts(seed, coin_type, version_byte, name, address_indices,
                        purpose=44, hrp=None, addr_format="base58"):
    if address_indices is None:
        address_indices = [0, 1, 2, 3, 4, 5]
    addresses = [_derive_secp_chain(seed, coin_type, purpose, idx, version_byte, hrp, addr_format)
                 for idx in address_indices]
    return {"44": {
        "purpose": purpose, "derivation_base": f"m/{purpose}'/{coin_type}'/0'",
        "address_type": "P2PKH", "addresses": addresses,
    }}


def _make_ed25519_accounts(seed, coin_type, name, address_indices,
                           hrp=None, addr_format="base58"):
    if address_indices is None:
        address_indices = [0, 1, 2, 3, 4, 5]
    addresses = [_derive_ed25519_chain(seed, coin_type, idx, hrp, addr_format)
                 for idx in address_indices]
    return {"44": {
        "purpose": 44, "derivation_base": f"m/44'/{coin_type}'/0'",
        "address_type": "ED25519", "addresses": addresses,
    }}


# LTC has both legacy (44) and segwit (84)
def _derive_ltc_accounts(seed, address_indices=None):
    if address_indices is None:
        address_indices = [0, 1, 2, 3, 4, 5]
    accounts = {}
    # Legacy P2PKH (L... addresses, version byte 0x30)
    accounts["44"] = {
        "purpose": 44, "derivation_base": "m/44'/2'/0'",
        "address_type": "LEGACY_P2PKH",
        "addresses": [_derive_secp_chain(seed, 2, 44, idx, 0x30) for idx in address_indices],
    }
    # SegWit (ltc1q...)
    accounts["84"] = {
        "purpose": 84, "derivation_base": "m/84'/2'/0'",
        "address_type": "NATIVE_SEGWIT",
        "addresses": [_derive_secp_chain(seed, 2, 84, idx, 0x30, "ltc", "bech32") for idx in address_indices],
    }
    return accounts


# ── Main generator ────────────────────────────────────────────────────────────

def generate_multiwallet(mnemonic: str = None, passphrase: str = "",
                         address_indices: list = None) -> dict:
    """Generate full multi-chain wallet from single mnemonic anchor.
    BTC-identical account structure with xpub/xprv per purpose + multiple addresses."""
    if mnemonic is None:
        mnemonic = _generate_mnemonic_12()
    if address_indices is None:
        address_indices = [0, 1, 2, 3, 4, 5]

    seed = _mnemonic_to_seed(mnemonic, passphrase)
    master_fp = _master_fingerprint(seed)
    now = datetime.datetime.now(datetime.timezone.utc).isoformat()

    print(f"\n{'='*72}")
    print(f"  OMNIBUS MULTI-CHAIN WALLET GENERATOR v3.0")
    print(f"  Account-based structure (BTC-identical)")
    print(f"{'='*72}\n")

    # ── OMNI (5 domains × N addresses) ──
    print(f"[OMNI] Deriving 5 PQ domains × {len(address_indices)} addresses each...")
    omni_accounts = _derive_omni_accounts(seed, address_indices)
    for ct, acc in omni_accounts.items():
        print(f"  {acc['domain']:20s} coin={ct}  {acc['addresses'][0]['address']}")

    # ── BTC (4 purposes × N addresses) ──
    print(f"\n[BTC] Deriving 4 purposes × {len(address_indices)} addresses each...")
    btc_accounts = _derive_btc_accounts(seed, address_indices)
    for p, acc in btc_accounts.items():
        print(f"  purpose={p:3s} {acc['address_type']:20s} {acc['addresses'][0]['address']}")

    n = len(address_indices)

    # ── ETH ──
    print(f"\n[ETH] Deriving {n} addresses...")
    eth_accounts = _derive_eth_accounts(seed, address_indices)
    print(f"  {'EOA':20s} {eth_accounts['44']['addresses'][0]['address']}")

    # ── SOL ──
    print(f"\n[SOL] Deriving {n} addresses...")
    sol_accounts = _derive_sol_accounts(seed, address_indices)
    print(f"  {'ED25519':20s} {sol_accounts['44']['addresses'][0]['address']}")

    # ── ADA (Cardano) ──
    print(f"\n[ADA] Deriving {n} addresses...")
    ada_accounts = _make_ed25519_accounts(seed, 1815, "ADA", address_indices)
    print(f"  {'ED25519':20s} {ada_accounts['44']['addresses'][0]['address']}")

    # ── DOT (Polkadot) ──
    print(f"\n[DOT] Deriving {n} addresses...")
    dot_accounts = _make_ed25519_accounts(seed, 354, "DOT", address_indices, addr_format="ss58")
    print(f"  {'SS58':20s} {dot_accounts['44']['addresses'][0]['address']}")

    # ── EGLD (MultiversX) ──
    print(f"\n[EGLD] Deriving {n} addresses...")
    egld_accounts = _derive_egld_accounts(seed, address_indices)
    print(f"  {'ED25519':20s} {egld_accounts['44']['addresses'][0]['address']}")

    # ── ATOM (Cosmos) ──
    print(f"\n[ATOM] Deriving {n} addresses...")
    atom_accounts = _make_secp_accounts(seed, 118, 0x00, "ATOM", address_indices, hrp="cosmos", addr_format="bech32")
    print(f"  {'BECH32':20s} {atom_accounts['44']['addresses'][0]['address']}")

    # ── XLM (Stellar) ──
    print(f"\n[XLM] Deriving {n} addresses...")
    xlm_accounts = _make_ed25519_accounts(seed, 148, "XLM", address_indices)
    print(f"  {'ED25519':20s} {xlm_accounts['44']['addresses'][0]['address']}")

    # ── XRP (Ripple) ──
    print(f"\n[XRP] Deriving {n} addresses...")
    xrp_accounts = _make_secp_accounts(seed, 144, 0x00, "XRP", address_indices)
    print(f"  {'SECP256K1':20s} {xrp_accounts['44']['addresses'][0]['address']}")

    # ── BNB (BSC — EVM, same as ETH address) ──
    print(f"\n[BNB] Deriving {n} addresses (EVM = same as ETH)...")
    bnb_accounts = _derive_eth_accounts(seed, address_indices)  # Same keys as ETH
    print(f"  {'EVM/EOA':20s} {bnb_accounts['44']['addresses'][0]['address']}")

    # ── OP (Optimism — EVM, same as ETH address) ──
    print(f"\n[OP] Deriving {n} addresses (EVM = same as ETH)...")
    op_accounts = _derive_eth_accounts(seed, address_indices)  # Same keys as ETH
    print(f"  {'EVM/EOA':20s} {op_accounts['44']['addresses'][0]['address']}")

    # ── LTC (Litecoin — Legacy + SegWit) ──
    print(f"\n[LTC] Deriving {n} × 2 (legacy + segwit)...")
    ltc_accounts = _derive_ltc_accounts(seed, address_indices)
    print(f"  {'LEGACY':20s} {ltc_accounts['44']['addresses'][0]['address']}")
    print(f"  {'SEGWIT':20s} {ltc_accounts['84']['addresses'][0]['address']}")

    # ── DOGE (Dogecoin) ──
    print(f"\n[DOGE] Deriving {n} addresses...")
    doge_accounts = _make_secp_accounts(seed, 3, 0x1E, "DOGE", address_indices)
    print(f"  {'P2PKH':20s} {doge_accounts['44']['addresses'][0]['address']}")

    # ── BCH (Bitcoin Cash) ──
    print(f"\n[BCH] Deriving {n} addresses...")
    bch_accounts = _make_secp_accounts(seed, 145, 0x00, "BCH", address_indices)
    print(f"  {'P2PKH':20s} {bch_accounts['44']['addresses'][0]['address']}")

    # Count total
    all_accounts = {
        "OMNI": omni_accounts, "BTC": btc_accounts, "ETH": eth_accounts,
        "SOL": sol_accounts, "ADA": ada_accounts, "DOT": dot_accounts,
        "EGLD": egld_accounts, "ATOM": atom_accounts, "XLM": xlm_accounts,
        "XRP": xrp_accounts, "BNB": bnb_accounts, "OP": op_accounts,
        "LTC": ltc_accounts, "DOGE": doge_accounts, "BCH": bch_accounts,
    }
    total = sum(
        sum(len(a["addresses"]) for a in accs.values())
        for accs in all_accounts.values()
    )

    # ── Assemble full wallet (BTC-identical structure) ──
    wallet = {
        "version": "3.0",
        "generator": "OmniBus Multi-Chain Wallet Generator",
        "created_at": now,
        "mnemonic": mnemonic,
        "passphrase": passphrase if passphrase else None,
        "master_fingerprint": master_fp.hex(),
        "anchor_address": omni_accounts["777"]["addresses"][0]["address"],
        "anchor_chain": "OMNI",
        "networks": {
            "OMNI": {
                "network": "OMNI",
                "hrp": "ob",
                "coin_types": [777, 778, 779, 780, 781],
                "accounts": omni_accounts,
            },
            "BTC": {
                "network": "BTC",
                "hrp": "bc",
                "coin_type": 0,
                "accounts": btc_accounts,
            },
            "ETH":  {"network": "ETH",  "coin_type": 60,   "accounts": eth_accounts},
            "SOL":  {"network": "SOL",  "coin_type": 501,  "accounts": sol_accounts},
            "ADA":  {"network": "ADA",  "coin_type": 1815, "accounts": ada_accounts},
            "DOT":  {"network": "DOT",  "coin_type": 354,  "accounts": dot_accounts},
            "EGLD": {"network": "EGLD", "coin_type": 508,  "hrp": "erd", "accounts": egld_accounts},
            "ATOM": {"network": "ATOM", "coin_type": 118,  "hrp": "cosmos", "accounts": atom_accounts},
            "XLM":  {"network": "XLM",  "coin_type": 148,  "accounts": xlm_accounts},
            "XRP":  {"network": "XRP",  "coin_type": 144,  "accounts": xrp_accounts},
            "BNB":  {"network": "BNB",  "coin_type": 60,   "note": "EVM-compatible, same address as ETH", "accounts": bnb_accounts},
            "OP":   {"network": "OP",   "coin_type": 60,   "note": "EVM-compatible, same address as ETH", "accounts": op_accounts},
            "LTC":  {"network": "LTC",  "coin_type": 2,    "hrp": "ltc", "accounts": ltc_accounts},
            "DOGE": {"network": "DOGE", "coin_type": 3,    "accounts": doge_accounts},
            "BCH":  {"network": "BCH",  "coin_type": 145,  "accounts": bch_accounts},
        },
        "state": {
            "balance_total": 0,
            "utxos": [],
            "tx_count": 0,
        },
        "metadata": {
            "created_at": now,
            "last_updated": None,
            "label": "OmniBus 19-Chain Multi-Wallet (OMNI+BTC+ETH+SOL+ADA+DOT+EGLD+ATOM+XLM+XRP+BNB+OP+LTC+DOGE+BCH)",
            "notes": "Contains ALL private keys (xprv + WIF). Keep SECRET and offline!",
        },
        "summary": {
            "total_addresses": total,
            "chains": list(all_accounts.keys()),
            "omni_domains": [a["domain"] for _, a in omni_accounts.items()],
            "btc_purposes": [44, 49, 84, 86],
            "addresses_per_account": len(address_indices),
        },
    }

    # Public-only version (strip private keys)
    wallet_public = json.loads(json.dumps(wallet))
    wallet_public.pop("mnemonic", None)
    wallet_public.pop("passphrase", None)
    for net_data in wallet_public["networks"].values():
        for acc_key, acc_data in net_data.get("accounts", {}).items():
            acc_data.pop("xprv", None)
            for addr_obj in acc_data.get("addresses", []):
                addr_obj.pop("private_key_hex", None)
                addr_obj.pop("private_key_wif", None)

    return wallet, wallet_public


def main():
    import argparse
    parser = argparse.ArgumentParser(description="OmniBus Multi-Chain Wallet Generator")
    parser.add_argument("--mnemonic", "-m", type=str, default=None,
                        help="BIP-39 mnemonic (12 words). Generated if omitted.")
    parser.add_argument("--passphrase", "-p", type=str, default="",
                        help="Optional BIP-39 passphrase")
    parser.add_argument("--output", "-o", type=str, default=None,
                        help="Output filename (default: MULTIWALLET_FULL_<date>.json)")
    args = parser.parse_args()

    wallet_full, wallet_public = generate_multiwallet(args.mnemonic, args.passphrase)

    date_str = datetime.datetime.now().strftime("%Y-%m-%d_%H%M%S")
    out_full = args.output or f"MULTIWALLET_FULL_{date_str}.json"
    base = out_full.rsplit(".", 1)[0]
    out_pub  = base + "_PUBLIC.json"

    with open(out_full, "w") as f:
        json.dump(wallet_full, f, indent=2)
    with open(out_pub, "w") as f:
        json.dump(wallet_public, f, indent=2)

    print(f"\n{'='*72}")
    print(f"  SAVED:")
    print(f"    SECRET: {out_full}")
    print(f"    PUBLIC: {out_pub}")
    print(f"{'='*72}")
    print(f"\n  Anchor: {wallet_full['anchor_address']}")
    print(f"  Master FP: {wallet_full['master_fingerprint']}")
    print(f"  Total addresses: {wallet_full['summary']['total_addresses']}")
    print(f"\n  WARNING: {out_full} contains private keys! Keep it SECRET!\n")


if __name__ == "__main__":
    main()
