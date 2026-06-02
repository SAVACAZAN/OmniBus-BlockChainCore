# PQ Key Migration Plan (FAZA 6)

Date: 2026-05-17
Status: **stage 1 shipped** (deterministic signing + consensus TX schema + tests).
Stage 2 (mempool/blockchain/RPC/CLI wiring + hard-fork height) is **TBD** —
deliberately staged so a running testnet pair (PC ⇄ VPS, see
`project_omnibus_dual_testnet_synced_2026-05-16`) does not desync mid-session.

## Problem statement

`wallet.signWithAllPQDomains` historically called
`pq_crypto.MlDsa87.generateKeyPair()` (random) for every domain on every call,
returned the signatures, and dropped the secret keys. Net effect:

- PQ signatures are not verifiable against any *stored* public key.
- Restoring a wallet from mnemonic does **not** recover the same PQ keys.
- Soulbound badges (LOVE/FOOD/RENT/VACATION) — which depend on a stable PQ
  identity — silently break across restarts.

## Fix shipped in stage 1

| File | Change |
|---|---|
| `core/wallet.zig:90-100` | Added `master_seed: [64]u8` + `has_master_seed: bool` to the `Wallet` struct. |
| `core/wallet.zig:392-396` | `fromMnemonicFull` copies `bip32.master_seed` into the wallet. |
| `core/wallet.zig:419-421` | `deinit` zeroes `master_seed`. |
| `core/wallet.zig:754-910` | `signWithAllPQDomains` rewritten with feature flag + `derivePQSeed`. New helper `deterministicPQPubkey` exposes the migration target. |
| `core/chain_config.zig` | New `pub const PQ_DETERMINISTIC_SIGNING: bool = false;` (mainnet default = legacy). |
| `core/pq_migrate_consensus.zig` | NEW. `PQMigrateV1` struct + serialize/deserialize/validate/apply + 5 unit tests. |
| `core/pq_migrate_test.zig` | NEW. 3 end-to-end tests (round-trip + apply + replay). |
| `core/sign_all_pq_domains_deterministic_test.zig` | NEW. 4 determinism tests. |
| `build.zig` | Wires the new test files into `test-pq` / `test-wallet` steps. |

### KDF spec

`bip32_wallet.derivePQSeed` (already present from prior session):

```
salt = "OMNIBUS-PQ-v1"
ikm  = mnemonic_seed (64 B BIP-39 PBKDF2)
info = coin_type (LE 4) || scheme_id (1) || index (LE 4)
okm  = HKDF-SHA512(ikm, salt, info, 64 B)
```

Per-scheme seed slicing inside `signWithAllPQDomains` / `deterministicPQPubkey`:

| scheme_id | Algorithm        | Seed bytes used                                              |
|----------|------------------|---------------------------------------------------------------|
| 0x01     | ML-DSA-87        | `okm(idx=0)[0..32]` → `generateKeyPairFromSeed`               |
| 0x02     | Falcon-512       | `okm(idx=0)[0..48]` → `generateKeyPairFromSeed`               |
| 0x03     | SLH-DSA-256s     | `sk_seed=okm(0)[0..32]`, `sk_prf=okm(0)[32..64]`, `pk_seed=okm(1)[0..32]` |

Domain mapping follows `pq_crypto.algorithmForCoinType` (source of truth):
777 OMNI / 778 LOVE / 780 RENT → ML-DSA-87 ; 779 FOOD → Falcon-512 ; 781
VACATION → SLH-DSA-256s. (The CLAUDE prompt's mapping for 780/781 was swapped;
we follow the code.)

## Why we kept the default `false` on mainnet

Per `feedback_dont_modify_working_code.md` and the bridge-DDoS lessons, flipping
the flag silently would:

1. Change the PQ pubkey of every existing wallet → breaks soulbound state on
   the chain.
2. Cause minority clients (not recompiled) to reject any TX that references a
   new (HKDF-derived) PQ key → consensus split.

The flag MUST flip in lockstep with a hard-fork activation height. Stage 2
(below) implements that.

## Consensus TX — `pq_migrate_v1`

Defined in `core/pq_migrate_consensus.zig`. Wire format (little-endian):

```
[version:u8=0x01][scheme:u8][coin_type:u32][timestamp:i64]
[old_pk_size:u16][new_pk_size:u16][proof_size:u16]
[old_pubkey][new_pubkey][proof_of_ownership]
```

`validate(tx)` requires `pq_crypto.verify(old_pubkey, new_pubkey, proof)` to
succeed under `scheme`. `apply(state, tx)` records `old_pubkey → new_pubkey`
in `PQMigrationState.map` and refuses to apply twice (replay guard).

`PQ_MIGRATE_V1_VERSION = 0x01`. Bump to `0x02` for future schema changes.

## Stage 2 — TBD wiring (NOT in this PR)

These are deliberately deferred. Each is a separate, reviewable change:

### 2.1 Transaction type registration (`core/transaction.zig`)

Add to the `TxType` enum (next free slot, e.g. `pq_migrate = 0x80`). Update
`requiresPayload`, write a `touchesPQState` predicate.

### 2.2 Mempool acceptance (`core/mempool.zig`)

```zig
// Pseudo-code
.pq_migrate => {
    const m = try migrate.PQMigrateV1.deserialize(tx.data);
    if (!m.validate()) return error.InvalidPQMigrateProof;
    // mempool admission: one pending migration per old_pubkey
}
```

### 2.3 Block application (`core/blockchain.zig`)

Inside `applyBlock`, for each `pq_migrate` TX call `migrate.apply(&state.pq_migration_state, m)`. Surface `error.AlreadyMigrated` as block-invalid only if the
state pre-image already exists from a *prior* block (intra-block duplicates
should fail the block too).

### 2.4 RPC endpoint (`core/rpc_server.zig`)

```
pq_migrate { mnemonic_or_privkey, coin_type, passphrase? }
  → derive new_key via wallet.deterministicPQPubkey
  → sign new_pubkey with the OLD private key (caller-supplied)
  → submit pq_migrate_v1 TX
  → return { tx_hash, old_pubkey, new_pubkey }
```

### 2.5 CLI command (`core/cli.zig`)

```
omnibus-cli pq-migrate-execute --mnemonic-file path [--coin-type 778]
```

Iterate coin_types 778..781. For each, derive old + new pubkey, build proof,
submit. Print JSON summary.

### 2.6 Hard-fork height

Pick block height H. Mainnet nodes >= release `vX.Y` enforce:

- After H: `chain_config.PQ_DETERMINISTIC_SIGNING == true` is consensus.
- After H: `pq_migrate_v1` TXs accepted.
- Before H: legacy random behavior (the audit-known broken-but-shipped state).

The clean way is to make `PQ_DETERMINISTIC_SIGNING` no longer a `const` but a
`fn(block_height) bool` once the fork height is decided.

## Migration UX (post-Stage 2)

For Alex / any wallet holder:

```
# 1. Stop node, back up omnibus-chain.dat.
# 2. Build & install the v6.x binary (deterministic flag baked in).
# 3. Run one CLI command per wallet:
omnibus-cli pq-migrate-execute --mnemonic-file ~/wallet.mnemonic
# Output:
# { "love":     { "tx_hash": "...", "old": "...", "new": "..." },
#   "food":     { ... },
#   "rent":     { ... },
#   "vacation": { ... } }
# 4. Wait for inclusion (1-2 blocks). Soulbound state now bound to the
#    HKDF-derived keys forever — restore-from-mnemonic recovers them.
```

If the user skips the migration window: their *old* PQ pubkeys remain pinned
in state forever, but no new soulbound activity can flow (signatures from
random keys will mismatch the on-chain pubkey post-fork). They can run the
migration after the fact — old_pubkey is still on file, proof is still valid.

## Test status

Tests added in stage 1 (per file):

- `core/pq_migrate_consensus.zig` — 5 unit tests
- `tests/pq_migrate_test.zig` — 3 end-to-end tests
- `tests/sign_all_pq_domains_deterministic_test.zig` — 4 determinism tests

Total new: **12 tests**.

Run with:
```
zig build test-pq        # migration TLV + apply
zig build test-wallet    # deterministic signing (requires liboqs)
```

## Out-of-scope (separate epics)

- `isolated_wallet.zig` switching from raw SHA-256 seeds to `derivePQSeed`
  (covered by next sprint — same migration shape, more domains).
- `pq_attest` (cross-chain identity binding) interaction with migration —
  attestation MAY need re-signing under new keys.
- VPS rolling restart playbook (depends on Stage 2 RPC).
