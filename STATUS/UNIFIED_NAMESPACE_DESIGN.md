# Unified Namespace `.omnibus` — Design Document

**Status:** draft 2026-05-06.
**Owner:** Alex.
**Goal:** one human-readable name per identity that resolves to ALL of the
user's PQ-OMNI addresses (ECDSA + 4 PQ schemes), with optional institutional
category tagging.

---

## Why this exists

Today a user has 5 distinct addresses for the same wallet:

| Type | Example |
|---|---|
| ECDSA primary | `ob1qw6zhsqg29aht23fksk5w54lkgavatpgltqxlvl` |
| ML-DSA-87 | `obk1_Yygcit2hu6F42FMZQ6t3H97ZhJxZY5GFsn` |
| Falcon-512 | `obf5_Yp58GLAZ5diTGZ8i3TvRzpigp2LAJfv7Au` |
| Dilithium-5 | `obs3_Yqg7S2R39C2dQfhng13Vfwc3sS46oWS1UF` |
| SLH-DSA-256s | `obd5_YtHvZwDofASKn2oYhQ3ksgnwhHfY81UdBt` |

This is a UX disaster. Users want **one name** (`alice.omnibus`) that
means "all five of these are me". Senders want **one name** to type, with
the chain auto-routing to the right PQ scheme based on the sender's
preference or the recipient's policy.

The DNS registry already exists (`core/dns_registry.zig`, RPC
`registername` / `transfername` / `updatename` / `renewname`), but maps
`name → single_address`. We extend it to `name → 5 addresses + optional
category tag`.

---

## The model

### One name, five addresses

```
alice.omnibus  =  {
  primary: ob1qw6zhsqg29a...,    // always ECDSA — the "default" if no scheme picked
  k:       obk1_YsaJWC9JD...,    // ML-DSA-87
  f:       obf5_Yp58GLAZ5...,    // Falcon-512
  s:       obs3_Yqg7S2R39...,    // Dilithium-5
  d:       obd5_YtHvZwDof...,    // SLH-DSA-256s
}
```

When you send to `alice.omnibus`, your wallet picks the address based on:
1. **Your own scheme** — if you sign with Falcon, you target `alice.f`
2. **Recipient policy** — alice can advertise `prefer = "k"` (use ML-DSA)
3. **Default** — fall back to `alice.primary` (ECDSA)

### Sub-domain shorthands

```
alice.omnibus              → primary (ECDSA)
alice.k.omnibus            → ML-DSA-87 specifically
alice.f.omnibus            → Falcon-512 specifically
alice.s.omnibus            → Dilithium-5 specifically
alice.d.omnibus            → SLH-DSA-256s specifically
```

Wallet UI shows ONE row "alice.omnibus" with a small dropdown if the user
wants to override the scheme.

---

## Institutional categories (optional)

The owner may tag their identity with a category that hints at what kind
of entity they are. Categories are **purely informational** — they do not
change which addresses map to the name, nor change fee/policy. They help
wallets render UI hints and help institutions discover each other.

| Tag | Concept | Recommended scheme(s) | Why |
|---|---|---|---|
| `bank` | Bank, financial institution | ML-DSA-87 (k) | NIST primary, regulator-friendly |
| `gov`  | Government, prefecture, state agency | SLH-DSA-256s (d) | Hash-based, ultra-conservative, survives lattice break |
| `mil`  | Military, defense contractor | Falcon-512 (f) | Smallest signature, low-bandwidth radio links |
| `fin`  | Financial trustee, fund, pension | ML-DSA-87 (k) | NIST FIPS 204, audit-ready |
| `edu`  | University, research institute | Dilithium-5 (s) | NIST FIPS 204 alias, redundancy |
| `org`  | NGO, non-profit, charity | any | low-stakes |
| `ent`  | Enterprise, corporate | ML-DSA-87 (k) | balanced |
| `prs`  | Personal user (default) | any | user choice |
| `dev`  | Developer / open-source | Falcon-512 (f) | smallest, fastest |

The recommendations are **defaults**, not enforcement. A bank can still
sign with Falcon-512 if they want. The category is metadata for discovery
and recommended-defaults in wallet UI.

### Category encoding in the name

Two equivalent ways to express the category:

**a) prefix style** — `bank.alice.omnibus`, `gov.bucuresti.omnibus`, `mil.unit23.omnibus`
**b) flag in the registry** — store `category: "bank"` in the DNS entry,
keep the name as `alice.omnibus` but expose category via `getName` RPC

Recommend **both**: prefix is human-friendly, flag is machine-friendly.
A `bank.alice.omnibus` lookup just returns the entry for `alice.omnibus`
plus the category field.

---

## Algorithm-to-category fit (technical reasoning)

Why each PQ algorithm naturally suits some institutions:

### `bank`, `fin`, `ent` → **ML-DSA-87** (`obk1_`)
- NIST FIPS 204, primary standard since 2024-08
- Auditors and regulators expect ML-DSA in compliance reports
- Balanced size/speed (2592B pk, 4627B sig, 0.18ms verify)
- Well-tested by NSA, NIST, academic community

### `gov`, archive, long-term storage → **SLH-DSA-256s** (`obd5_`)
- NIST FIPS 205, hash-based (SPHINCS+ family)
- Survives a hypothetical lattice-cryptography break (the only one of the
  four that is NOT lattice-based)
- Slowest but safest "Plan B" — sign once, verify decades later
- Government archives, land registry, court records, identity records

### `mil`, `edge`, `iot`, `satellite` → **Falcon-512** (`obf5_`)
- NIST FIPS 206 (draft → final)
- Smallest signature: 666 bytes vs 4627 (ML-DSA) vs 29792 (SLH-DSA)
- Best for radio links, satellite uplinks, embedded systems where
  every byte costs power/bandwidth
- Fastest verification too (0.12ms)

### `edu`, `dev`, redundancy → **Dilithium-5** (`obs3_`)
- Same algorithm family as ML-DSA-87 (FIPS 204) but a separate "slot"
  on chain (scheme code 7 vs 5)
- Useful as a redundancy / migration path
- For research, academic projects, dev/test deployments

---

## Discovery & defaults

When a wallet looks up `alice.omnibus`:

```json
GET /api/name?name=alice.omnibus

{
  "name": "alice",
  "tld":  "omnibus",
  "category": "bank",
  "addresses": {
    "primary": "ob1qw6zhsqg29a...",
    "k": "obk1_Ysa...",
    "f": "obf5_Yp5...",
    "s": "obs3_Yqg...",
    "d": "obd5_YtH..."
  },
  "preferred_scheme": "k",           // hint set by owner
  "recommended_scheme": "k",         // derived from category=bank → k
  "expires_block": 12345678,
  "owner_signature": "..."           // owner-attested integrity
}
```

Wallet UX:
- User types `alice.omnibus` in "send to" field
- Wallet shows: "alice (bank) — preferred: ML-DSA-87"
- User can override with dropdown: ECDSA / k / f / s / d
- Sends to the corresponding address; signs with sender's chosen scheme

---

## Migration plan from current single-address DNS

Chain currently stores: `name → (address [64]u8, owner [64]u8, ...)`.

**Step 1 (backward compat):** keep the single `address` field as the
**primary** address. Add 4 optional fields `addr_k / addr_f / addr_s / addr_d`
+ `category`.

**Step 2 (RPC extension):**
- `registername` accepts optional `addresses` object: `{primary, k, f, s, d, category}`
- Old single-address calls keep working — chain stores only `primary`,
  the 4 PQ slots are null.

**Step 3 (UI integration):**
- Wallet auto-fills all 5 from the same mnemonic when registering a name
- Category dropdown in registration form

**Step 4 (validation):**
- Each of the 5 addresses must be derivable from the **same mnemonic**
  (proven by signing the registration TX with each scheme — defense
  against squatting cross-scheme)

---

## Fee schedule (proposal)

Keep current fee for `.omnibus` (5 OMNI) but add multi-address surcharge:

| Action | Cost |
|---|---|
| Register name with primary only (ECDSA) | 5 OMNI (current) |
| Register name with primary + 4 PQ | 7 OMNI (+2 for the extra slots) |
| Add a category tag | free |
| Update PQ slot (replace one) | 1 OMNI |
| Renew (yearly) | 5 OMNI |

Premium short-name multipliers (`feeForName` in `dns_registry.zig`) apply
on top.

---

## What this unblocks

- **One identity, many algorithms** — user has 1 name, can send/receive
  on any scheme without giving out 5 hex addresses
- **Institutional discovery** — `getNamesByCategory(bank)` returns the
  list of all banks on the chain
- **Migration story** — when a PQ algorithm becomes weak, owners rotate
  that ONE slot in their entry without losing the name
- **Cleaner wallet UX** — Send dialog has 1 row per contact, not 5

---

## Open questions

1. **Storage cost** — adding 4 × 64 bytes per entry = +256B/entry. With
   10k registered names = +2.5MB. Acceptable.
2. **Cross-scheme validation** — do we require all 5 to be derived from
   the same mnemonic? If yes, registration TX needs 5 signatures (or 1
   ECDSA + a Merkle proof linking the 4 PQ pubkeys to the same seed).
3. **Renewal** — if a name expires, do we release ALL 5 addresses or
   just the name → addresses mapping (the addresses themselves keep
   their balances regardless of name expiry).
4. **Reserve list** — categories like `bank`/`gov` could be gated by
   on-chain attestation (only registered banks can use `bank.*.omnibus`).
   Phase 2.

---

## Implementation tracker

- [ ] Schema change in `core/dns_registry.zig` — add 4 PQ slots + category field
- [ ] RPC `registername` accept structured addresses object
- [ ] RPC `getName` return all 5 addresses + category
- [ ] `feeForName` extension for multi-slot pricing
- [ ] Wallet UI — auto-derive all 5 on registration
- [ ] Wallet UI — show category badge on name lookup
- [ ] Audit tool — drift check for category tag consistency
- [ ] Chain migration — load existing single-address entries, treat
      `address` as `primary`, leave PQ slots null until owner updates

---

## See also

- `STATUS/MASTER_RULES_PQ_OMNI.md` — canonical PQ scheme/prefix/code mapping
- `core/dns_registry.zig` — current single-address implementation
- `core/registrar_addresses.zig` — reserved name slots
- `core/domain_minter.zig` — separate (PQ domain *derivation*, not name registry)
