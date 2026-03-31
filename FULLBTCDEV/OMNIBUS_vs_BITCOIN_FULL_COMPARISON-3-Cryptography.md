# 3. Cryptography

> OmniBus vs Bitcoin — Category 3/10
> Generated: 2026-03-31 19:42

| # | Component | BTC | OMNI | File | Notes |
|:-:|-----------|:---:|:----:|------|-------|
| 41 | SHA-256 | Y | Y | crypto.zig | std.crypto.hash.sha2 |
| 42 | Double SHA-256 (SHA256d) | Y | Y | transaction.zig | TX hash, block hash |
| 43 | RIPEMD-160 | Y | Y | ripemd160.zig | Pure Zig implementation |
| 44 | ECDSA (secp256k1) | Y | Y | secp256k1.zig | Pure Zig, no FFI |
| 45 | Schnorr Signatures | Y | Y | schnorr.zig | BIP-340 compatible |
| 46 | BLS Signatures | N | + | bls_signatures.zig | Aggregate sigs [EXTRA] |
| 47 | Multisig (M-of-N) | Y | Y | multisig.zig | Script-based multisig |
| 48 | Hash160 | Y | Y | secp256k1.zig | RIPEMD160(SHA256(x)) |
| 49 | Base58Check | Y | Y | bip32_wallet.zig | Full encoder/decoder |
| 50 | Bech32 (BIP-173) | Y | Y | bech32.zig | SegWit v0 addresses |
| 51 | Bech32m (BIP-350) | Y | Y | bech32.zig | Taproot v1 addresses |
| 52 | HMAC-SHA256 | Y | Y | crypto.zig | Key derivation |
| 53 | HMAC-SHA512 | Y | Y | crypto.zig | BIP-32 master key |
| 54 | PBKDF2-HMAC-SHA512 | Y | Y | bip32_wallet.zig | BIP-39 seed, 2048 iter |
| 55 | AES-256-GCM | N | + | crypto.zig | Key encryption [EXTRA] |
| 56 | ML-DSA-87 (Dilithium) | N | + | pq_crypto.zig | Post-quantum sig [EXTRA] |
| 57 | Falcon-512 | N | + | pq_crypto.zig | Compact PQ sig [EXTRA] |
| 58 | SLH-DSA (SPHINCS+) | N | + | pq_crypto.zig | Hash-based PQ [EXTRA] |
| 59 | ML-KEM-768 (Kyber) | N | + | pq_crypto.zig | PQ key encapsulation [EXTRA] |
| 60 | Key Compression | Y | Y | secp256k1.zig | 33-byte compressed pubkeys |

---

**BTC has: 14 items**
**OmniBus: 20 implemented, 0 partial, 0 missing, 6 extras**
**Score: 142%** (20/14 BTC features + 6 unique extras)

### Extras (OmniBus-only):
- BLS Signatures — Aggregate sigs [EXTRA]
- AES-256-GCM — Key encryption [EXTRA]
- ML-DSA-87 (Dilithium) — Post-quantum sig [EXTRA]
- Falcon-512 — Compact PQ sig [EXTRA]
- SLH-DSA (SPHINCS+) — Hash-based PQ [EXTRA]
- ML-KEM-768 (Kyber) — PQ key encapsulation [EXTRA]

