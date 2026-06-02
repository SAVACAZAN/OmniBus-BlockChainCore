# AUDIT — PQ keys deterministic (FAZA 4)

Date: 2026-05-17
Author: Claude Opus 4.7

## Executive summary

The task prompt assumed `pq_crypto.zig` is a Pure-Zig MOCK (per memory note
`project_pq_crypto_mock_blocker_2026-05-06.md`) and PQ keys are generated
non-deterministically. **Reality on disk is different**:

| Component | Prompt assumed | Actual state |
|---|---|---|
| `core/pq_crypto.zig` | MOCK (checks only c_tilde[0..32]) | **REAL liboqs** with `OQS_SIG_new`/`OQS_SIG_keypair`/`OQS_SIG_sign`/`OQS_SIG_verify` (lines 39–275). Gated by `build_options.oqs_enabled` (default `true`). |
| Deterministic RNG | Not implemented | **Implemented** via SHAKE256 stream + `OQS_randombytes_custom_algorithm` callback + global mutex (lines 50–75). `activateDetRng(seed)` / `deactivateDetRng()` already in place. |
| `generateKeyPairFromSeed` for ML-DSA-87 / Falcon-512 / SLH-DSA-256s / ML-KEM-768 | Missing | **Present** (lines 96, 136, 176, 220). |
| `isolated_wallet.zig` PQ derivation | Calls non-deterministic `generateKeyPair()` | Already calls **`generateKeyPairFromSeed(seed)`** for all 4 soulbound + 4 PQ-OMNI + 4 hybrid_qN schemes (lines 350, 361, 377, 392, 405, 416, 432, 445, 456, 467, 483). Seeds derived via SHA-256/SHA-512 of mnemonic. |
| `liboqs` availability | Unknown | **Available**: `1_CORE/liboqs-src/build/lib/liboqs.a` (and `liboqs-internal.a`). Build defaults to `-Doqs=true`. |

The actual non-deterministic site is **`core/wallet.zig` `signWithAllPQDomains`
lines 754–809** — it calls `generateKeyPair()` (random) for all 5 domains,
discards the secret keys, and returns only signatures. This means every call
to that function produces fresh keys and the resulting signatures are not
verifiable against any stored public key.

## Files audited (file:line)

- `core/pq_crypto.zig:1-600` — already real liboqs, deterministic RNG already wired.
- `core/bip32_wallet.zig:1-882` — BIP-39 PBKDF2-HMAC-SHA512 (line 79) + BIP-32 HMAC-SHA512 master (line 93); `master_seed: [64]u8` exposed (line 53).
- `core/isolated_wallet.zig:300-510` — all PQ schemes already use `generateKeyPairFromSeed` with deterministic per-scheme seed (mnemonic-derived SHA-256/SHA-512).
- `core/wallet.zig:754-809` — `signWithAllPQDomains` uses non-deterministic `generateKeyPair()`. This is the real defect.
- `tests/` — only Python integration helpers; Zig tests are embedded per-file.
- `build.zig:95-107` — `-Doqs=true` default, `oqs_enabled` exposed via `build_options`.

## Design decision (ADR)

Even though `isolated_wallet.zig` already gets deterministic seeds via raw
SHA-256(mnemonic), the seeds are NOT bound to `(coin_type, scheme, index)` in
a clean keyed-KDF way. If we ever rotate domains, add new sub-addresses, or
share material across schemes, raw SHA-256 has no domain separation.

**Adopted**: HKDF-SHA512 with versioned salt as the single canonical PQ-seed
derivation function. Added as `bip32_wallet.derivePQSeed(mnemonic_seed,
coin_type, scheme_id, index) -> [64]u8`.

```
salt = "OMNIBUS-PQ-v1"
ikm  = mnemonic_seed (64 B from BIP-39 PBKDF2)
info = coin_type (LE 4) || scheme_id (1) || index (LE 4) = 9 bytes
prk  = HKDF-Extract(salt, ikm)
okm  = HKDF-Expand(prk, info, 64 B)
```

The versioned salt (`-v1`) lets us migrate to a different KDF later without
breaking existing wallets — old keys remain reachable via the v1 path while
new keys derive from `-v2`.

## What was implemented in this session

1. `core/bip32_wallet.zig`
   - Added `pub const PQ_HKDF_SALT = "OMNIBUS-PQ-v1"`.
   - Added `pub fn derivePQSeed(mnemonic_seed: [64]u8, coin_type: u32, scheme_id: u8, index: u32) [64]u8` using `std.crypto.kdf.hkdf.HkdfSha512`.
   - Added 7 unit tests:
     - length is exactly 64 bytes
     - deterministic across 100 iterations
     - different coin_type → different output
     - different scheme_id → different output
     - different index → different output
     - different mnemonic seed → different output
     - end-to-end with the official BIP-39 `abandon×11 about` vector through all 4 soulbound coin_types (cross-independence).

2. **Not implemented this session** (intentional — already present):
   - Real liboqs wiring (already done).
   - Deterministic RNG callback (already done).
   - `generateKeyPairFromSeed` per-scheme (already done).
   - Per-call deterministic seeding in `isolated_wallet.zig` (already done — though using raw SHA-256/SHA-512 rather than HKDF; see "Next step" below).

## Next step (separate change set — out of scope for this session)

Replace the raw SHA-256/SHA-512 seed derivation in
`core/isolated_wallet.zig:347-488` with `bip32_wallet.derivePQSeed`, mapping:

| Scheme enum | coin_type | scheme_id |
|---|---|---|
| `love_dilithium` | 778 | 0x01 |
| `food_falcon` | 779 | 0x02 |
| `rent_slh_dsa` | 780 | 0x03 |
| `vacation_kem` (ML-DSA variant) | 781 | 0x01 |
| `pq_omni_ml_dsa` / `pq_omni_dilithium` | 777 | 0x05 / 0x07 |
| `pq_omni_falcon` | 777 | 0x06 |
| `pq_omni_slh_dsa` | 777 | 0x08 |
| `hybrid_q1..q4` | 777 | 0x05..0x08 |

For SLH-DSA which needs 3 × 32-byte seeds (sk_seed, sk_prf, pk_seed), slice
the HKDF 64-byte output and feed the missing 32 bytes via a second
`derivePQSeed(..., index=1)` call.

**This change WILL break existing soulbound badges and PQ-OMNI addresses
once shipped** — every PQ address will move. A migration RPC
`wallet_pq_migrate` is needed:
1. Compute new addresses from HKDF.
2. For each old address with a balance/reputation, generate a self-signed
   `pq_migrate_v1` transaction binding old_pubkey → new_pubkey.
3. Chain consensus accepts the binding and re-maps state.

Until migration logic is designed (consensus-level — not just CLI), do NOT
flip `isolated_wallet.zig` to use HKDF on mainnet. The HKDF function shipped
in this session is the building block; the migration is a separate epic.

## Build status

- `zig build test-crypto` → **336/336 tests passed** (includes the 7 new
  `derivePQSeed` tests).
- 1 pre-existing transitive compile failure in a non-crypto step
  (`core/pq_crypto.zig:39 @cImport` cannot resolve `oqs/oqs.h` in a test
  binary that doesn't link the liboqs C headers). This is independent of
  the changes in this session — same failure reproduces without them.
- liboqs: **available** at `1_CORE/liboqs-src/build/lib/liboqs.a`.

## Files changed

- `core/bip32_wallet.zig` — added `PQ_HKDF_SALT`, `derivePQSeed`, 7 tests (lines ~680 region inserted before "Teste" section + appended tests at file end).

## Files NOT changed (intentional — see rationale above)

- `core/pq_crypto.zig` — already real liboqs.
- `core/isolated_wallet.zig` — already deterministic; switching to HKDF requires consensus-level migration.
- `core/wallet.zig` — `signWithAllPQDomains` is broken (non-deterministic) but fixing it requires architectural decision (does the wallet hold persistent PQ keys, or derive on every call from mnemonic? if derive, where does it get the mnemonic — the function currently takes `*const Wallet` which does not expose mnemonic).
- `core/cli.zig` — no `pq-migrate-check` added; migration design is unfinished.
- No new `core/pq_deterministic_rng.zig` file — the equivalent already lives inside `core/pq_crypto.zig` (`Oqs.activateDetRng`/`deactivateDetRng`).
