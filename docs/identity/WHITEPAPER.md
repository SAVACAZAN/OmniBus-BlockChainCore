# OmniBus ID — Decentralized Identity Layer

OmniBus ID adds a thin identity layer on top of the OmniBus blockchain. It
reuses every primitive the chain already has — ECDSA wallets, post-quantum
keys, reputation cups, on-chain DNS registry — and adds:

- A **DID** resolver (`did:omnibus:…`) so an identity can be referenced
  from outside the chain.
- An **Identity Manifest** (off-chain) whose Merkle root may be anchored
  on chain. Holders keep cleartext fields private; verifiers see only a
  root + selective proofs.
- An **OmniBus Binary Map (OBM)** — a single byte that compactly answers
  "what badges and flags does this address carry?", derived live from
  chain state so it cannot go stale.
- A **Selective Disclosure** protocol so the holder can prove individual
  manifest fields (e.g. "I have RENT badge") without revealing the rest.
- A **Salt Manager** for KYC-hash derivation, with a file-backed default
  and an interface ready for hardware keystores (TPM, iOS Secure Enclave,
  Android Keystore).
- A **GDPR right-to-be-forgotten** operation: deleting the salt makes any
  past KYC hash unverifiable from a fresh document scan.

## Non-goals

The identity layer **does not**:
- introduce a new wallet or signing scheme,
- duplicate the DNS registry,
- store reputation or badge state separately from `core/reputation.zig`,
- gate access to chain operations (a wallet without a manifest signs txs
  exactly as before).

## Manifest

The Manifest has **9 fields** in a fixed order. Fields 6/7/8 are the Merkle
roots of three identity facets, each a subtree built in its own module.

| Index | Field                | Bytes | Privacy default   | Source                                          |
|------:|----------------------|-------|-------------------|-------------------------------------------------|
| 0     | `kyc_hash`           | 32    | 🔒 private        | SHA-256(salt ‖ kyc_document)                    |
| 1     | `assets_root`        | 32    | 🔒 private        | off-chain asset Merkle root                     |
| 2     | `reputation`         | 16    | 🌍 public         | 4 × u32 little-endian (cups, x100)              |
| 3     | `pq_keys_hash`       | 32    | 🌍 public         | SHA-256 over concatenated PQ pubkeys            |
| 4     | `obm`                | 1     | 🌍 public         | derived live (see below)                        |
| 5     | `timestamp`          | 8     | 🌍 public         | u64 little-endian, unix seconds                 |
| 6     | `social_root`        | 32    | per-post flag     | root of Social facet subtree (`id_social.zig`)  |
| 7     | `professional_root`  | 32    | 🔒 private        | root of Professional facet subtree              |
| 8     | `cultural_root`      | 32    | per-item flag     | root of Cultural facet subtree                  |

Leaves are hashed with a 0x00 prefix and internal nodes with 0x01 — the
classic Merkle domain-separation pattern that blocks second-preimage
attacks. The tree is padded to a power of two by repeating the last hash.

## OBM bit layout

| Bit | Meaning                                                      |
|----:|--------------------------------------------------------------|
| 0   | LOVE cup ≥ 50.00                                              |
| 1   | FOOD cup ≥ 50.00                                              |
| 2   | RENT cup ≥ 50.00                                              |
| 3   | VACATION cup ≥ 50.00                                          |
| 4   | At least one PQ key registered                                |
| 5   | Holder owns at least one active `.omnibus` / `.arbitraje` name |
| 6   | Holder is a validator (stake ≥ 100 OMNI)                      |
| 7   | Zen tier (all four cups at 100.00 — Satoshi badge)            |

OBM is **never stored** on chain; clients ask the node to compute it and
the node walks `ReputationManager.snapshot`, the DNS registry, the
validator set, etc.

## Identity Facets — Real-world analogies

Each of the three facets (fields 6/7/8) maps to a familiar web2 platform,
but without a central server — the holder owns all data and chooses what
to reveal to whom.

---

### Social Facet ≈ Twitter / X  (`id_social.zig`)

**What it stores:**
- Posts (only their content-hash + timestamp; private posts commit existence without revealing content)
- Follows (list of addresses you follow, as 20-byte pubkey hashes)
- Reaction count (aggregated — like/repost/quote)
- Display handle (optional, resolves via DNS registry to your `ob1q…`)

**Privacy model:**
- Each post has an `is_public` flag — public posts are visible to anyone who asks for a proof
- Private posts prove they exist (for spam-resistance, timestamping) but content stays encrypted
- The facet root changes whenever you post — verifiers can detect activity without seeing content

**Decentralized advantage vs Twitter/X:**
- No central server can delete your post or suspend your account
- No advertiser reads your private posts
- Your identity is your key — same ob1q address you use for payments

---

### Professional Facet ≈ LinkedIn  (`id_professional.zig`)

**What it stores:**
- Certifications (issuer DID + subject DID + credential kind + validity window + hash)
- Work history (employer DID + role hash + start/end timestamps)
- Endorsement count
- Visibility mask (1 byte — per-section control: certs bit 0, work history bit 1, endorsements bit 2)

**Privacy model:**
- Private by default — `visibility_mask = 0x00` hides everything
- A recruiter/employer can ask you to disclose specific sections; you produce a Merkle proof for that section only
- Certifications are signed by the issuer's DID — a university or certification body anchors their attestation on-chain via `pq_attest`
- Expired certifications are still provable (you can prove you *had* a cert at some point)

**Decentralized advantage vs LinkedIn:**
- LinkedIn can remove your profile or hold it hostage; here the credential is signed by the issuer, not by LinkedIn
- Selective disclosure: you show your cert to an employer without showing your entire work history
- Cross-chain: the issuer can be on any chain that supports DID; the subject is ob1q

---

### Cultural Facet ≈ Patreon + Itch.io + ResearchGate  (`id_cultural.zig`)

**What it stores:**
- POAPs (Proof of Attendance Protocol — event_id + timestamp; equivalent to "I was at ETHDenver 2026")
- Notarized works (content hash + WorkKind + notarization timestamp + `is_public` flag)
  - WorkKind: poem, music, visual, text, code, translation, other
- Cultural badges (arbitrary u32 IDs — game achievements, hackathon wins, reading clubs…)
- Language tags (ISO 639-1 codes packed as bytes)

**Privacy model:**
- POAPs are public-by-default (attendance at a public event is not sensitive)
- Notarized works toggle public/private per item — a poem you're proud of is public; a draft stays private but its existence (and priority timestamp) is proven
- Cultural badges are public

**Decentralized advantage:**
- A notarized work proves you created something *before* a certain block — timestamped proof of authorship without a notary
- Nobody can take away your POAP — it's a Merkle leaf in your identity, not a server-side record
- Language skills are self-attested; institutions can add signed attestations on top

---

## Selective Disclosure

A verifier requests one or more of
`{kyc, assets, reputation, pq, obm, social, professional, cultural}`.
The holder produces:
- the on-chain (or shared) Manifest root,
- for each requested field: its raw bytes + a Merkle inclusion proof.

The verifier hashes each disclosed field with the leaf-prefix scheme and
walks the proof. Fields not requested contribute their leaf hash to the
root but never appear in cleartext to the verifier.

Example flows:
- **Job application**: disclose `professional_root` (visibility_mask = certs|work) → employer sees certs + history, nothing else
- **Event entry**: disclose `obm` (LOVE badge set) → bouncer verifies badge, never sees KYC
- **Copyright dispute**: disclose `cultural_root` proof of specific notarized_work → proves timestamp, not the work content

## GDPR — right to be forgotten

KYC linkage relies on a 32-byte salt the holder controls. Deleting the
salt (via `SaltManager.delete`) means that even with the same KYC
document on file, no party can re-derive the same `kyc_hash`. The
Manifest root remains anchored as immutable history but loses verifiable
KYC.

## Summary table — facets at a glance

| | OmniBus Social | OmniBus Professional | OmniBus Cultural |
|--|--|--|--|
| **Analogy** | Twitter / X | LinkedIn | Patreon + Itch.io + ResearchGate |
| **Key data** | posts, follows, reactions, handle | certifications, work history, endorsements | POAPs, notarized works, badges, languages |
| **Privacy default** | public per post | private (visibility_mask) | public badges + POAPs; per-item for works |
| **Who issues** | self (holder) | self + issuer DID (university, employer) | self + event organizer for POAPs |
| **Killer feature** | uncensorable posting | verifiable CV without LinkedIn middleman | proof-of-authorship timestamp |
| **Module** | `identity/id_social.zig` | `identity/id_professional.zig` | `identity/id_cultural.zig` |
| **Manifest index** | 6 (`social_root`) | 7 (`professional_root`) | 8 (`cultural_root`) |

## What we deferred

These were in the original dump and remain out of scope until needed:
- JNI / Swift / WASM bridges
- QR-code generator (use any standard tool over the DID string)
- MiCA full reporting pipeline (stub returns "deferred")
- Hardware-keystore implementations of `SaltManager` (interface ready;
  only file and memory backends exist today)
