# Prompt pentru DeepSeek — Refactorizare OmniBus ID

## Cum folosești promptul

1. Copiezi tot textul de mai jos (între liniile orizontale) într-o sesiune
   DeepSeek (sau Claude/Gemini — același prompt funcționează la oricare).
2. Atașezi (drag & drop) **toate fișierele din `core/OmniBus ID/code/`**
   ca attachment, plus aceste fișiere din chain core ca să aibă context:
   - `core/wallet.zig`
   - `core/bip32_wallet.zig`
   - `core/dns_registry.zig`
   - `core/reputation.zig`
   - `core/reputation_manager.zig`
   - `core/pq_crypto.zig`
   - `STATUS/MASTER_RULES_PQ_OMNI.md`
   - `STATUS/INVENTORY.md`
   - `frontend/src/api/wallet-keystore.ts`
3. Lasă-l să producă structura curată. Apoi îmi spui și o aplic.

## De ce e nevoie de refactorizare

Folder-ul `core/OmniBus ID/code/` conține un dump dintr-un transcript:
- **184 fișiere** cu prefixe numerice (`100_05_...`, `101_05_...`)
- **Versiuni duplicate** (par/impar — `113_11_omnibus_did.zig` vs
  `19_11_omnibus_did.zig` au același conținut)
- **Multe stub-uri** cu `// AICI: Implementare ...` (BAse58, Merkle tree,
  hardware keystore, JNI/Swift/WASM bridges — toate goale)
- **Fișiere fără extensie** (`133_1.0.0`, `188_9.000`, `185_block.txt`)
  care par fragmente dintr-un OpenAPI YAML / config split la lungime
- **Multe `main.zig`** identice, fără build.zig real lângă ele
- **Duplicate de tip OBM, salt_manager, did, manifest** — fiecare fișier
  apare în 2-3 variante aproape identice

Asta înseamnă că NU se compilează acum + e imposibil de menținut.

În același timp, **conceptul e bun** și se aliniază cu ce avem deja în
chain (`pq_attest`, `dns_registry`, `reputation`, 4 PQ-OMNI domains, 4
soulbound badges). Vrem să-l integrăm corect, nu să-l rescriem complet.

---

## PROMPT (copiază de aici)

---

```
You are refactoring a Zig blockchain identity layer ("OmniBus ID") that
currently exists as a messy stub dump and needs to become a working,
testable module integrated into an existing chain.

## Context: what already exists in the chain (DO NOT redesign)

The OmniBus blockchain (Zig 0.15.2) already implements, in `core/`:

- `wallet.zig` — primary OMNI wallet (secp256k1 ECDSA, bech32 ob1q...
  addresses, path m/44'/777'/0'/0/N)
- `bip32_wallet.zig` — BIP-32 HD derivation + BIP-39 mnemonic +
  passphrase (`initFromMnemonicPassphrase`)
- `pq_crypto.zig` — Post-Quantum signatures (ML-DSA-87, Falcon-512,
  Dilithium-5, SLH-DSA-256s) via liboqs C bindings
- `dns_registry.zig` — on-chain name registrar (.omnibus, .arbitraje
  TLDs), 1000-year lock, fees go to treasury
- `reputation.zig` + `reputation_manager.zig` — 4 reputation cups
  (LOVE/FOOD/RENT/VACATION), 0-100 each, total 0..1M, tiers
- 5 PQ-OMNI transferable address prefixes (`obk1_`/`obf5_`/`obs3_`/
  `obd5_`) — see `STATUS/MASTER_RULES_PQ_OMNI.md`
- 4 SOULBOUND reward-only badge addresses (`ob_k1_`/`ob_f5_`/`ob_d5_`/
  `ob_s3_`) — non-transferable, attestation-only
- `pq_attest` flow: 7-signature cross-chain identity binding
  (OMNI + 4 PQ + BTC + ETH simultaneous proof of ownership)

The frontend (`frontend/src/api/wallet-keystore.ts`) implements the
same derivation in TypeScript via @scure/bip39 + @noble/secp256k1 +
@noble/post-quantum (real implementations, no liboqs in browser).

## The mess we have

`core/OmniBus ID/code/` contains ~184 files dumped from a transcript:
- Number-prefixed duplicates (`113_11_omnibus_did.zig` vs
  `19_11_omnibus_did.zig` are identical)
- Stubs with `// AICI: ...` comments (Base58, Merkle tree, hardware
  keystore, JNI/Swift/WASM bridges all empty)
- Files with no extension that are YAML/JSON fragments cut by length
- Three different `main.zig`, no working `build.zig`
- Conflicting types: there's an `omnibus_types.zig` here that
  redefines `Manifest`, `IdentityStatus`, `SoulboundBadge` but DOES
  NOT match what the live chain has

## Your task

Produce a **single clean, compilable module tree** in Zig 0.15.2 that
implements an "OmniBus ID layer" ON TOP of the existing chain types.
The new module must:

1. **Reuse, not redefine** existing chain types:
   - Use `wallet.zig` types for ECDSA addresses
   - Use `pq_crypto.zig` for PQ signatures (link against liboqs)
   - Use `reputation.zig`'s 4 cups as the source of badge state
     (not re-invented `has_love_badge` bools)
   - Use `dns_registry.zig` for name lookups, not a parallel registry

2. **Add the unique-to-ID features** that are missing from chain:
   - `did:omnibus:<base58(sha256(pubkey))>` resolver (DID Core spec)
   - Identity Manifest = BLAKE3 root over {kyc_hash, assets_root,
     reputation_snapshot, pq_pubkeys, timestamp}
   - OBM (OmniBus Binary Map) — 1-byte status field with the 8 flags
     listed in the dump's whitepaper but DERIVED from chain state, not
     stored separately
   - Selective Disclosure — given a request {wants_kyc, wants_badges,
     wants_assets, wants_pq}, return a redacted manifest where missing
     fields are zeroed out (with a Merkle proof per disclosed field)
   - Salt Manager — abstract interface that targets:
     - Android Keystore (JNI later)
     - iOS Secure Enclave (Swift later)
     - TPM 2.0 (later)
     - file-backed fallback (now — for testing)
   - GDPR "right to be forgotten" — delete-salt operation that
     invalidates ability to re-derive any KYC hash

3. **NOT include yet** (these are deferred — leave clean extension
   points but no implementation):
   - JNI / Swift / WASM bridges
   - QR generator script
   - MiCA compliance reporter
   - Audit trail (already exists in chain via `audit.zig`)

4. **Be testable** — each module has at least one Zig `test` block
   that doesn't require liboqs (so `zig build test-id` works without
   the PQ dependency). PQ-dependent tests gated behind `-Doqs=true`.

5. **Match the chain's build system** — generate a single `build.zig`
   that adds an `omnibus-id` library target and links it into the
   existing `omnibus-node` binary.

## Required structure (final, deduplicated)

```
core/identity/
  id_did.zig             # did:omnibus generator + resolver
  id_manifest.zig        # Manifest builder (BLAKE3 Merkle)
  id_obm.zig             # 8-bit status map (derived from chain)
  id_salt.zig            # Salt manager (file-backed for now)
  id_disclosure.zig      # Selective disclosure + Merkle proofs
  id_compliance.zig      # GDPR delete-salt + MiCA hook stubs
  id_types.zig           # Types specific to ID (no overlap with chain)
  id_main.zig            # Test entry / sanity check
  build_id.zig           # Library build snippet, included from main build.zig

docs/identity/
  WHITEPAPER.md          # Refined from 169_37_whitepaper.md
  OPENAPI.yaml           # Refined from 171_38_openapi.yaml
  TEST_PLAN.md           # New: list of test cases

test/identity/
  flow_test.zig          # End-to-end: gen wallet → manifest → DID →
                         # disclose subset → verify proof
  obm_test.zig           # Flag mapping correctness
  disclosure_test.zig    # Hiding fields preserves Merkle root
```

## Deliverables

For each Zig file:
- Real implementations (no `// AICI:` placeholders)
- Doc comments explaining WHY each function exists (not what — Zig is
  readable enough that the what is in the code)
- At least one `test` block per non-trivial function

For documents:
- `WHITEPAPER.md` in English (the current one mixes RO and EN)
- `OPENAPI.yaml` validated by Spectral (no errors)
- `TEST_PLAN.md` enumerating every test case with expected outcome

For the build:
- Working `zig build` invocation that produces `omnibus-id.lib` (or
  static archive on Linux)
- A 5-line snippet I can paste into the chain's main `build.zig` to
  link the new module

## Constraints

- Zig **0.15.2** (no 0.13/0.14 idioms — `std.io.getStdOut` was removed,
  use `std.fs.File.stdout`)
- No external dependencies beyond what the chain already pulls in
  (liboqs only, gated)
- Romanian or English in comments — pick one and be consistent
- No emojis in code, no AI-style filler comments
- All public functions must have at least one test
- Final file count: ~10-12 files total (vs current ~184)

## Do NOT do

- Do NOT re-invent secp256k1, BIP-32, or PQ crypto — link the chain's
  existing modules
- Do NOT add a new "OmniBus Wallet" implementation — the chain has one
- Do NOT split files just because the dump did
- Do NOT keep the `01_`, `02_` numeric prefixes — they were a hack to
  reconstruct ordering from a chat dump and have no value in real code
- Do NOT generate stub `JNI/Swift/WASM` bridges — they go in a separate
  PR once the core works
```

---

## După ce primești output de la DeepSeek

1. Verifică că:
   - **Compilează** (`zig build -Doqs=false` cel puțin pentru testele
     non-PQ)
   - **Testele trec** (`zig build test-id`)
   - **Nu redefinește** tipuri care există în chain (caută conflicte
     în `wallet.zig`, `reputation.zig`, `pq_crypto.zig`)
   - **Folosește passphrase** (link la `bip32_wallet.initFromMnemonicPassphrase`)

2. Plasează fișierele în `core/identity/` și `docs/identity/`.

3. Șterge tot din `core/OmniBus ID/code/` — păstrează folderul gol cu un
   `README.md` care zice "this is now in core/identity/" pentru audit
   trail.

4. Spune-mi când termini și fac integrare în chain main + RPC.

## Notă: ce e legitim de păstrat din dump

Conceptual, **trei idei sunt bune** și merită să rămână în refactor:

1. **OBM (1-byte status map)** — flag-uri compact codate, util pentru
   "does this address have LOVE badge?" check rapid pe chain. DAR
   trebuie derivat din `reputation.zig`, nu stocat separat.

2. **Selective Disclosure prin Merkle proofs** — userul prezintă DOAR
   reputation_snapshot fără să dezvăluie kyc_hash. Pattern standard în
   SSI, e bun pentru noi.

3. **Salt Manager abstractizat** — interfața e bună, doar
   implementările hardware sunt stub-uri (le facem ulterior).

Restul (DID resolver, manifest, GDPR delete-salt) sunt extensii necesare
peste ce avem deja.
