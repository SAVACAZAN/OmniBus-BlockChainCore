# PQ-OMNI Master Rules — single source of truth

**Hand-edit this file** when the rules change. Then re-align all code with
`python tools/audit-pq-conventions.py`. Until drift is 0, no PQ change merges.

> Last verified: 2026-05-06 — `audit-pq-conventions.py` reports drift = 0.

## Why this file exists

Multiple sessions and agents kept reinventing the prefix↔scheme mapping. This
caused balances to be derived under one convention and verified under another,
creating "stuck" addresses where the chain owns a balance but the wallet can't
sign for it. We now anchor everything to **NIST FIPS** standard names and one
canonical mapping.

The chain (Zig backend) is the authority. UI, scripts, and tests align to it.

## NIST FIPS reference

| Standard | Algorithm name (in chain) | Other common names |
|---|---|---|
| [FIPS 203](https://csrc.nist.gov/pubs/fips/203/final) | **ML-KEM-768** | Kyber-768 (pre-standard name) |
| [FIPS 204](https://csrc.nist.gov/pubs/fips/204/final) | **ML-DSA-87** | Dilithium (pre-standard); CRYSTALS-Dilithium-87 |
| [FIPS 205](https://csrc.nist.gov/pubs/fips/205/final) | **SLH-DSA-SHA2-256s** | SPHINCS+ |
| [FIPS 206](https://nvlpubs.nist.gov/nistpubs/FIPS/NIST.FIPS.206.ipd.pdf) (draft) | **Falcon-512** | NTRU-based lattice signature |

Note: "Dilithium-5" inside our code is a **legacy alias** kept distinct from
`ml_dsa_87` so chain code can route to a separate scheme byte (code 7 vs 5).
Cryptographically both currently use the same liboqs `OQS_SIG_alg_ml_dsa_87`
backend; the distinction lives in the chain enum, not in the math. Treat the
two as separate "slots" with separate addresses, even if they share library.

## The four canonical PQ-OMNI slots (transferable + soulbound mirror)

The 4 transferable PQ-OMNI prefixes mirror the 4 soulbound prefixes
**byte-for-byte except for the leading underscore**. Every transferable
prefix has a soulbound twin with the **same algorithm family**; only
the underscore distinguishes "money" from "identity" visually.

| Code | Transferable | NIST | Prefix | BIP-44 | Soulbound twin (same algo) |
|---|---|---|---|---|---|
| 5 | `pq_omni_ml_dsa` (ML-DSA-87) | FIPS 204 | `obk1_` | `m/44'/777'/5'/0/0` | `ob_k1_` (love_dilithium, code 1) |
| 6 | `pq_omni_falcon` (Falcon-512) | FIPS 206 | `obf5_` | `m/44'/777'/6'/0/0` | `ob_f5_` (food_falcon, code 2) |
| 7 | `pq_omni_dilithium` (ML-DSA-87 alias) | FIPS 204 | `obs3_` | `m/44'/777'/7'/0/0` | `ob_s3_` (vacation_kem, code 4) |
| 8 | `pq_omni_slh_dsa` (SLH-DSA-256s) | FIPS 205 | `obd5_` | `m/44'/777'/8'/0/0` | `ob_d5_` (rent_slh_dsa, code 3) |

**Rules:**
- Address prefix is **3 lowercase letters + `_`** (no leading underscore for
  transferable PQ-OMNI; leading underscore = soulbound).
- Scheme codes 1..4 = soulbound (non-transferable, identity-bound).
- Scheme codes 5..8 = transferable PQ-OMNI.
- Scheme codes 9..12 = hybrid (ECDSA + PQ verify both required) — same prefixes
  as 5..8, distinguished by `tx.scheme` byte, not by address prefix.

## Soulbound prefix table (codes 1..4)

| Code | Scheme name | Concept | Prefix |
|---|---|---|---|
| 1 | `love_dilithium` | OMNI_LOVE — identity reputation | `ob_k1_` |
| 2 | `food_falcon`    | OMNI_FOOD — sustenance reputation | `ob_f5_` |
| 3 | `rent_slh_dsa`   | OMNI_RENT — housing reputation | `ob_d5_` |
| 4 | `vacation_kem` *(legacy name; now ML-DSA-87 signing)* | OMNI_VACATION — leisure | `ob_s3_` |

## Address derivation algorithm (must match across UI / chain / tests)

```
1. mnemonic → seed (BIP-39, mnemonicToSeedSync)
2. root = HDKey.fromMasterSeed(seed)                      (BIP-32)
3. child = root.derive("m/44'/777'/<account>'/0/0")        (account from table)
4. baseSeed = child.privateKey                              (32 bytes)
5. expand baseSeed to library seed length:
     ML-DSA-87 / Dilithium-5 → 32 bytes:  sha256(baseSeed)
     Falcon-512               → 48 bytes:  sha512(baseSeed).slice(0,48)
     SLH-DSA-256s             → 96 bytes:  SHA-512 counter-mode expansion
                                            (counter byte appended each round)
6. (publicKey, secretKey) = libraryKeygen(expandedSeed)
7. h160      = ripemd160(sha256(publicKey))
8. versioned = [0x4f] || h160
9. checksum  = sha256(sha256(versioned))[0..4]
10. address  = prefix + base58(versioned || checksum)
```

Reference implementation: `frontend/src/api/pq-sign.ts:pqKeypairFromSeed` +
`pqAddressFromPublicKey`. Reproduce byte-for-byte; do **not** invent your own
seed expansion.

## Files that anchor this

These are the canonical sources — they win arguments:

1. `core/transaction.zig:180-201` — prefix↔scheme via `prefix()` and `fromAddress()`
2. `core/isolated_wallet.zig:64-67` — derivation prefix per scheme
3. `frontend/src/api/wallet-keystore.ts:109` — BIP-44 accounts 5/6/7/8
4. `frontend/src/api/pq-sign.ts:111-115` — UI prefix mapping (must match #1)
5. `STATUS/MASTER_RULES_PQ_OMNI.md` — this document

Tests that lock these in (run on every PR):

- `tools/audit-pq-conventions.py` — must report `Drift: 0`
- `tools/TESTING/stress-pq-matrix.mjs --restart` — 16/16 PQ→* TXs accepted

## What changed when

| Date | Change |
|---|---|
| 2026-05-06 | Audit found `obs3_` ↔ `obd5_` swap in `pq-sign.ts` and `stress-pq-matrix.mjs`. Aligned to chain canon. Drift: 2 → 0. |
| 2026-05-06 | Stress test BIP-44 accounts fixed: 10/11/12/13 → 5/6/7/8 (matches UI). |
| 2026-05-06 | Stress test seed expansion fixed: SHA-256 round → SHA-512 (Falcon, SLH-DSA). |
| 2026-05-06 | `pq_listSchemes` RPC was returning stale prefixes (`ob_q1_`..`ob_q4_`); fixed to return canon (`obk1_`..`obd5_`) for transferable PQ-OMNI and hybrid. |
| 2026-05-06 | Soulbound `vacation_kem` (code 4, `ob_s3_`) realigned to use ML-DSA-87 signing (was ML-KEM). Now mirrors transferable `obs3_` (Dilithium-5) byte-for-byte. Hybrid `hybrid_q3` (code 11) likewise realigned to ML-DSA from ML-KEM. ML-KEM remains available as a separate primitive in `pq_crypto.zig` for encryption use cases that don't need an on-chain address. |
| 2026-05-06 | aweb3 `HybridScheme` enum reordered: `QuantumK=1, QuantumF=2, QuantumS=3, QuantumD=4` (was K/F/D/S). `QuantumS` now uses ML-DSA-87 (was ML-KEM). Frontend labels updated. |

## How to add a new PQ scheme

1. Pick the next free code (≥ 13). Pick a unique 3-letter prefix that
   does NOT collide with any existing one (`obk1_`, `obf5_`, `obs3_`,
   `obd5_`, soulbound `ob_*`).
2. Update `core/transaction.zig` (`prefix()`, `fromAddress()`, decoder switch,
   verifier switch) — **chain first**, alone.
3. Add entry in this document with:
   - NIST standard / library OID
   - BIP-44 account number
   - Seed expansion length + algorithm
4. Update `core/isolated_wallet.zig` derivation switch.
5. Update `frontend/src/api/pq-sign.ts` (prefix map + signer dispatch) and
   `wallet-keystore.ts` (account number).
6. Update `tools/audit-pq-conventions.py` `CANON` dict.
7. Run `python tools/audit-pq-conventions.py --fail-on-drift`. Must pass.
8. Run `tools/TESTING/stress-pq-matrix.mjs` against testnet. New row must
   show ACCEPTED across all destinations.

## Anti-patterns (do NOT do these)

- ❌ Adding a swap of two prefixes "for visual symmetry"
- ❌ Reinventing seed expansion ("we'll use SHA-256 instead, faster")
- ❌ Renaming a prefix without rebuilding all chain data — addresses don't
  migrate; old balances get stuck.
- ❌ Using `dilithium_5` and `ml_dsa_87` interchangeably in code — they
  are separate slots even if they share the FIPS 204 library.
- ❌ Leaving a comment that contradicts the code (e.g. `obs3_` labelled
  "ML-KEM" while the function returns Dilithium). Fix or delete the comment.
