"""chain_stub_pq.py — Python port of the chain's stub PQ implementations
(core/pq_crypto.zig). Used to sign transactions FROM Quantum addresses
in a way the running chain will accept.

NOTE: These are NOT real Falcon-512 / ML-DSA-87 / SLH-DSA. They are the
SHAKE256-based simulations used by the chain. The chain will be migrated
to liboqs in a later phase, at which point this module gets replaced
by `pqcrypto` (NIST FIPS 204/205/206) calls.
"""
import hashlib
import secrets
from typing import Tuple


def shake256(input_bytes: bytes, out_len: int) -> bytes:
    return hashlib.shake_256(input_bytes).digest(out_len)


def sha3_256(input_bytes: bytes) -> bytes:
    return hashlib.sha3_256(input_bytes).digest()


# ─── ML-DSA-87 stub (chain code 5/7) ────────────────────────────────────
class MlDsa87:
    PUBLIC_KEY_SIZE = 2592
    SECRET_KEY_SIZE = 4896
    SIGNATURE_SIZE  = 4627  # SIGNATURE_MAX in zig

    @classmethod
    def generate_keypair(cls) -> Tuple[bytes, bytes]:
        seed = secrets.token_bytes(32)
        return cls.generate_keypair_from_seed(seed)

    @classmethod
    def generate_keypair_from_seed(cls, seed: bytes) -> Tuple[bytes, bytes]:
        assert len(seed) == 32
        # expandSeed = shake256(seed, PK_SIZE+SK_SIZE)
        pk_buf = shake256(seed, cls.PUBLIC_KEY_SIZE + cls.SECRET_KEY_SIZE)
        public_key = pk_buf[:cls.PUBLIC_KEY_SIZE]
        # secret_key[0..32] = seed
        # secret_key[32..64] = pk_buf[0..32]   (rho)
        # secret_key[64..]   = shake256(pk_buf[0..64], SECRET_KEY_SIZE-64)
        sk_ext = shake256(pk_buf[0:64], cls.SECRET_KEY_SIZE - 64)
        secret_key = bytearray(cls.SECRET_KEY_SIZE)
        secret_key[0:32]  = seed
        secret_key[32:64] = pk_buf[0:32]
        secret_key[64:]   = sk_ext
        return public_key, bytes(secret_key)

    @classmethod
    def sign(cls, secret_key: bytes, message: bytes, public_key: bytes = None) -> bytes:
        # In the chain stub, sign() needs `self.public_key`. Reconstruct from secret_key.
        # secret_key contains seed at [0:32] — re-derive public key.
        if public_key is None:
            seed = secret_key[0:32]
            pk_buf = shake256(seed, cls.PUBLIC_KEY_SIZE + cls.SECRET_KEY_SIZE)
            public_key = pk_buf[:cls.PUBLIC_KEY_SIZE]
        # tr = sha3_256(public_key)
        tr = sha3_256(public_key)
        # mu = shake256(tr || message, 64)
        h = hashlib.shake_256()
        h.update(tr)
        h.update(message)
        mu = h.digest(64)
        # c_tilde = shake256(mu, 32)
        c_tilde = shake256(mu, 32)
        # buf[0..32] = c_tilde
        # buf[32..SIG_SIZE] = shake256(c_tilde || secret_key[0..32], SIG_SIZE-32)
        z_seed = c_tilde + secret_key[0:32]
        rest = shake256(z_seed, cls.SIGNATURE_SIZE - 32)
        return c_tilde + rest

    @classmethod
    def verify(cls, public_key: bytes, message: bytes, signature: bytes) -> bool:
        if len(signature) < 32:
            return False
        tr = sha3_256(public_key)
        h = hashlib.shake_256()
        h.update(tr)
        h.update(message)
        mu = h.digest(64)
        c_tilde = shake256(mu, 32)
        return signature[0:32] == c_tilde


# ─── Falcon-512 stub (chain code 6) ─────────────────────────────────────
class Falcon512:
    PUBLIC_KEY_SIZE = 897
    SECRET_KEY_SIZE = 1281
    SIGNATURE_SIZE  = 752

    @classmethod
    def generate_keypair(cls) -> Tuple[bytes, bytes]:
        seed = secrets.token_bytes(48)
        return cls.generate_keypair_from_seed(seed)

    @classmethod
    def generate_keypair_from_seed(cls, seed: bytes) -> Tuple[bytes, bytes]:
        assert len(seed) == 48
        public_key = shake256(seed, cls.PUBLIC_KEY_SIZE)
        # secret_key[0..48] = shake256(seed, 48)
        sk_first = shake256(seed, 48)
        # ext_seed = seed (48) || 0xFA*16
        ext_seed = seed + b"\xFA" * 16
        sk_rest = shake256(ext_seed, cls.SECRET_KEY_SIZE - 48)
        secret_key = sk_first + sk_rest
        assert len(secret_key) == cls.SECRET_KEY_SIZE
        return public_key, secret_key

    @classmethod
    def sign(cls, secret_key: bytes, message: bytes, public_key: bytes) -> bytes:
        # Random 40-byte nonce
        nonce = secrets.token_bytes(40)
        # r = shake256(nonce || message, 32)
        h = hashlib.shake_256(); h.update(nonce); h.update(message)
        r = h.digest(32)
        # tag = shake256(r || pk, 32)
        h2 = hashlib.shake_256(); h2.update(r); h2.update(public_key)
        tag = h2.digest(32)
        # filler = shake256(r || sk[0..48], SIG_SIZE-104)
        h3 = hashlib.shake_256(); h3.update(r); h3.update(secret_key[0:48])
        fill = h3.digest(cls.SIGNATURE_SIZE - 104)
        return nonce + r + tag + fill

    @classmethod
    def verify(cls, public_key: bytes, message: bytes, signature: bytes) -> bool:
        if len(signature) < 104:
            return False
        nonce = signature[0:40]
        r_stored = signature[40:72]
        h = hashlib.shake_256(); h.update(nonce); h.update(message)
        r = h.digest(32)
        if r != r_stored:
            return False
        h2 = hashlib.shake_256(); h2.update(r); h2.update(public_key)
        expected_tag = h2.digest(32)
        return expected_tag == signature[72:104]


# ─── SLH-DSA-256s stub (chain code 8) ───────────────────────────────────
class SlhDsa256s:
    PUBLIC_KEY_SIZE = 64
    SECRET_KEY_SIZE = 128
    SIGNATURE_SIZE  = 29792

    @classmethod
    def generate_keypair(cls) -> Tuple[bytes, bytes]:
        sk_seed = secrets.token_bytes(32)
        sk_prf  = secrets.token_bytes(32)
        pk_seed = secrets.token_bytes(32)
        return cls.generate_keypair_from_seed(sk_seed, sk_prf, pk_seed)

    @classmethod
    def generate_keypair_from_seed(cls, sk_seed: bytes, sk_prf: bytes, pk_seed: bytes) -> Tuple[bytes, bytes]:
        # pk_root = shake256(sk_seed || pk_seed, 32)
        pk_root = shake256(sk_seed + pk_seed, 32)
        secret_key = sk_seed + sk_prf + pk_seed + pk_root
        public_key = pk_seed + pk_root
        assert len(secret_key) == cls.SECRET_KEY_SIZE
        assert len(public_key) == cls.PUBLIC_KEY_SIZE
        return public_key, secret_key

    @classmethod
    def sign(cls, secret_key: bytes, message: bytes, public_key: bytes = None) -> bytes:
        # public_key = sk[64:96] || sk[96:128]   (pk_seed || pk_root)
        if public_key is None:
            public_key = secret_key[64:128]
        # rand_r = shake256(SK.prf || message, 32)
        h = hashlib.shake_256(); h.update(secret_key[32:64]); h.update(message)
        rand_r = h.digest(32)
        # msg_digest = shake256(R || PK || M, 64)
        h2 = hashlib.shake_256()
        h2.update(rand_r); h2.update(public_key); h2.update(message)
        msg_digest = h2.digest(64)
        # fill = shake256(msg_digest || sk.pk_root (sk[96:128]), SIG_SIZE-32)
        fill_input = msg_digest + secret_key[96:128]
        fill = shake256(fill_input, cls.SIGNATURE_SIZE - 32)
        return rand_r + fill

    @classmethod
    def verify(cls, public_key: bytes, message: bytes, signature: bytes) -> bool:
        if len(signature) < 64:
            return False
        rand_r = signature[0:32]
        h = hashlib.shake_256()
        h.update(rand_r); h.update(public_key); h.update(message)
        msg_digest = h.digest(64)
        # expected fill = shake256(msg_digest || pk_root, SIG_SIZE-32)
        fill_input = msg_digest + public_key[32:64]
        full_expected = shake256(fill_input, cls.SIGNATURE_SIZE - 32)
        # expected_sig_start = shake256(full_expected[0:32], 32)
        expected_sig_start = shake256(full_expected[0:32], 32)
        # actual_sig_start  = shake256(signature[32:min(len, 64)], 32)
        actual_sig_start  = shake256(signature[32:min(len(signature), 64)], 32)
        return expected_sig_start == actual_sig_start


SCHEMES = {
    "pq_omni_ml_dsa":     {"code": 5, "prefix": "obk1_", "cls": MlDsa87},
    "pq_omni_falcon":     {"code": 6, "prefix": "obf5_", "cls": Falcon512},
    "pq_omni_dilithium":  {"code": 7, "prefix": "obs3_", "cls": MlDsa87},
    "pq_omni_slh_dsa":    {"code": 8, "prefix": "obd5_", "cls": SlhDsa256s},
}


# ─── Self-test ──────────────────────────────────────────────────────────
if __name__ == "__main__":
    msg = b"hello chain"
    for name, info in SCHEMES.items():
        cls = info["cls"]
        pk, sk = cls.generate_keypair()
        assert len(pk) == cls.PUBLIC_KEY_SIZE
        assert len(sk) == cls.SECRET_KEY_SIZE
        sig = cls.sign(sk, msg, pk) if name == "pq_omni_falcon" else cls.sign(sk, msg)
        ok = cls.verify(pk, msg, sig)
        print(f"  {name:<20} keys OK ({len(pk)}/{len(sk)}B) sig={len(sig)}B verify={'PASS' if ok else 'FAIL'}")
        # Negative test
        bad_msg = b"hello chain modified"
        ok_neg = cls.verify(pk, bad_msg, sig)
        print(f"    negative (mod msg): {'PASS' if not ok_neg else 'FAIL — bug!'}")
