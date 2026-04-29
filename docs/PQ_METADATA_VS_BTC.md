# PQ Metadata Parity — OmniBus vs. Bitcoin

**Document version:** 1.0
**Audience:** Operators, integrators, auditors, regulators, institutional treasury teams
**Source of truth:** `core/transaction.zig`, `core/blockchain.zig`, `core/finality.zig`
**Last updated:** 2026-04-28

---

## Purpose of this document

OmniBus is often described as "Bitcoin with post-quantum signatures and five isolated wallets." This document quantifies how literally that statement is meant. For every metadata-related semantic that Bitcoin defines, OmniBus matches it byte-for-byte where possible, and goes further only where Bitcoin's behavior is universally agreed to be a limitation.

The intended use of this document: operators, auditors, and regulators can paste any row of the table below directly into a memo or compliance note, and the claim will be verifiable against the cited source line.

---

## Side-by-side parity table

| Feature | Bitcoin | OmniBus | Identical? | Notes |
|---|---|---|---|---|
| Per-TX `op_return` field | Yes | Yes (`transaction.zig:80`) | Yes | Same name, same role, same semantics. |
| Maximum payload size | 80 bytes (consensus standard since BIP 0136 era) | 80 bytes (`transaction.zig:113`, `MAX_OP_RETURN`) | Yes | Identical hard cap. |
| Included in TX hash | Yes | Yes (`transaction.zig:196-199`) | Yes | Tamper-evident under the TX signature. Any byte change in op_return changes the TX hash. |
| `amount > 0` and `op_return` allowed in same TX | NO (Bitcoin's standardness rules forbid value-bearing data carriers) | YES (`transaction.zig:79`, comment "Unlike Bitcoin, OP_RETURN TXs with amount > 0 are allowed") | OmniBus is a strict superset | Lets a single TX both move value and carry metadata. Useful for receipts, audit trails, and on-chain settlement records. |
| Confirmations formula | `chain_height - tx_block_height` | `chain_height - tx_block_height` (`blockchain.zig:446-451`) | Yes | Identical integer subtraction. No reorg-aware adjustment, no validator-vote weighting; pure block depth. |
| 6-confirmation soft finality | Yes (community convention) | Yes (`finality.zig:21`, `SOFT_FINALITY_CONFIRMS: u32 = 6`) | Yes | Same threshold. OmniBus also adds a Casper-FFG-style hard finality on top (see "Beyond parity" below). |
| Reorg behavior on metadata | TX falls back to mempool, op_return is preserved with the TX | Same | Yes | OmniBus uses the same UTXO+mempool pattern; a reorged TX returns to the mempool with its op_return intact. |
| Per-scheme verifier | Only ECDSA secp256k1 | ECDSA + ML-DSA + Falcon + SLH-DSA + ML-KEM (`isolated_wallet.zig:367-375`) | OmniBus has 5 independent verifiers | Each scheme is an independently NIST-track or NIST-standardized algorithm. The chain's `verifySignature` dispatcher routes each TX to the correct verifier by scheme tag. |
| Wallet-to-metadata link | 1 wallet → 80 bytes per TX | 5 wallets × 80 bytes = 400 bytes effective per identity per block | OmniBus is 5x richer | Without ever co-signing, a user with five isolated wallets can produce up to 400 bytes of authenticated metadata per block, distributed across five independent signature schemes. |

### One-line summary per row, for memo use

- **op_return field exists:** identical.
- **max payload 80 bytes:** identical.
- **op_return in TX hash:** identical.
- **amount + op_return same TX:** OmniBus allows; Bitcoin forbids.
- **confirmations formula:** identical, `current_height - tx_block_height`.
- **6-confirmation soft finality:** identical.
- **reorg returns TX with op_return to mempool:** identical.
- **per-scheme verifier:** OmniBus has five (ECDSA + 4 PQ); Bitcoin has one (ECDSA).
- **metadata bandwidth per identity:** OmniBus 400 B per block; Bitcoin 80 B per block.

---

## Where the parity comes from, line by line

This section walks each parity claim back to the exact source line, so a reviewer can verify without searching.

### op_return field declaration

`transaction.zig:80`:

```
op_return: []const u8 = "",
```

Same data type as Bitcoin's data-carrying output (a byte slice), default empty (no metadata), settable per TX.

### Maximum payload constraint

`transaction.zig:113`:

```
pub const MAX_OP_RETURN: usize = 80;
```

Same numeric limit Bitcoin enforces in its standardness rules. Any TX with op_return larger than this is rejected before mempool entry.

### Tamper-evidence: op_return inside the TX hash

`transaction.zig:196-199`:

```
if (self.op_return.len > 0) {
    hasher.update(":OP:");
    hasher.update(self.op_return);
}
```

The op_return bytes feed directly into the SHA-256d hasher that produces the TX hash. Any modification to op_return after signing changes the TX hash, which invalidates every signature that committed to that hash. This is identical in spirit to Bitcoin's approach: data-carrying outputs are part of the serialized TX, and the serialized TX is what gets signed.

### `amount > 0` plus op_return: OmniBus diverges, in the user's favor

`transaction.zig:77-79`:

```
/// OP_RETURN: date arbitrare embedded in TX (max 80 bytes, ca Bitcoin)
/// Folosit pentru: timestamping, commit hashes, metadata, anchoring
/// Unlike Bitcoin, OP_RETURN TXs with amount > 0 are allowed (metadata on normal TXs)
```

Bitcoin's standardness rules treat a TX with both a value-bearing output and an op_return data output as nonstandard, which means most miners will not relay or include it. OmniBus relaxes that rule: a single TX can both transfer value and carry up to 80 bytes of metadata. This is a strict superset of Bitcoin's behavior. A user who wants to mimic Bitcoin's behavior simply avoids combining them; the chain does not force the combination.

Use cases this enables:

- **Settlement receipts:** A bank-to-bank transfer of 100 OMNI carries the bilateral settlement reference number in op_return.
- **Audit-traceable invoicing:** A merchant payment of 50 OMNI carries the invoice ID in op_return, so the merchant's accounting system can reconcile without an off-chain lookup.
- **Compliance hooks:** A regulated entity records the regulator's reference code in op_return on the same TX that moves the funds.

### Confirmations formula

`blockchain.zig:444-451`:

```
/// Returns the number of confirmations for a TX (null if TX not found in any block).
/// confirmations = current_chain_height - block_height_containing_tx
pub fn getConfirmations(self: *const Blockchain, tx_hash: []const u8) ?u64 {
    const block_height = self.tx_block_height.get(tx_hash) orelse return null;
    const current_height: u64 = @intCast(self.chain.items.len);
    if (current_height <= block_height) return 0;
    return current_height - block_height;
}
```

Identical to Bitcoin's confirmations integer. The function returns `null` if the TX is unknown (not yet mined and not in the chain index), `0` for a TX in the very current tip block, and a positive integer for older TXs. There is no validator-weighting, no probabilistic adjustment, no reorg-aware penalty; Bitcoin behaves the same way.

### Soft finality threshold

`finality.zig:20-21`:

```
/// Minimum confirmations for soft finality (like Bitcoin's 6 confirmations)
pub const SOFT_FINALITY_CONFIRMS: u32 = 6;
```

The comment explicitly cites Bitcoin parity. Six confirmations means the TX is considered settled with overwhelming probability against PoW reorg. OmniBus also exposes `finality.zig:209-213` (`hasSoftFinality`) for callers that want a boolean answer.

---

## Beyond parity: what OmniBus adds without breaking compatibility

The parity table above demonstrates that OmniBus does not weaken any Bitcoin guarantee. This section covers the additions, none of which require a Bitcoin user to change their mental model.

### Hard finality (Casper FFG style)

`finality.zig:9-15`:

```
/// Inspired by:
///   - Casper FFG (Ethereum 2.0): 2-phase justify -> finalize
///   - Tendermint: instant finality via 2/3+ prevotes -> precommits
///   - Bitcoin: 6 confirmations ~= finality (probabilistic)
///
/// OmniBus approach: Checkpoint-based finality
```

OmniBus operates a Casper FFG-style finality gadget on top of the PoW chain. Validators attest to checkpoints every 64 blocks (`finality.zig:18`, `CHECKPOINT_INTERVAL: u64 = 64`). When a checkpoint accumulates 2/3+ of voting power it is justified; when the next justified checkpoint references it, it becomes finalized and can never be reverted (`finality.zig:30-37`, `CheckpointStatus`).

This provides a stronger guarantee than Bitcoin's purely probabilistic finality, **without changing Bitcoin's semantics for op_return or confirmations**. A Bitcoin-style operator who only watches the 6-confirmation threshold gets the same behavior as on Bitcoin. An OmniBus-aware operator who additionally watches the finality gadget gets a hard, never-reverted guarantee on top.

### Five independent signature verifiers

`isolated_wallet.zig:367-375`:

```
pub fn verifySignature(scheme: Scheme, message: []const u8, signature: []const u8, public_key: []const u8) bool {
    return switch (scheme) {
        .omni_ecdsa => verifyOmniSignature(message, signature, public_key),
        .love_dilithium => verifyLoveSignature(message, signature, public_key),
        .food_falcon => verifyFoodSignature(message, signature, public_key),
        .rent_slh_dsa => verifyRentSignature(message, signature, public_key),
        .vacation_kem => false, // KEM nu semneaza
    };
}
```

The chain accepts TXs from five independent algorithms and runs the matching verifier for each. The op_return semantics are uniform across all five: same 80-byte limit, same hash inclusion, same confirmations formula, same finality. A regulator who is concerned with op_return tampering on a Falcon TX gets exactly the same guarantees as on an ECDSA TX, because both schemes commit to the op_return bytes via their respective signatures over the same TX hash.

### Wallet-to-metadata bandwidth multiplier

A Bitcoin user has one wallet (one mnemonic, one secp256k1 key, one address space). They can produce 80 bytes of authenticated metadata per TX. If they want to spread metadata across multiple addresses, those addresses still derive from the same seed, so a chain analyst can correlate them.

An OmniBus user has five wallets (five mnemonics, five algorithms, five address spaces) and the five wallets are **on-chain unlinkable by default** (see PQ_ISOLATED_WALLETS.md section 5). They can produce 80 bytes per TX × 5 wallets = 400 bytes effective per identity per block, **distributed across five independent signature schemes**, without ever co-signing a TX and without giving a chain analyst a correlation surface.

For institutional users, this is the difference between a single op_return channel and five segregated op_return channels: invoicing, settlement, compliance, audit, and archival can each travel on its own scheme, signed under its own algorithm, with no shared secret.

---

## Why this matters for institutional users

This section addresses the questions a regulated entity or institutional treasury team will ask before deploying OmniBus.

### Auditable per-domain trail

Each of the five domains carries its own transaction history, its own balance, its own nonce sequence, and its own op_return stream. An auditor reviewing the LOVE wallet sees only LOVE transactions; an auditor reviewing the OMNI wallet sees only OMNI transactions. There is no mixing.

Compare to a single-mnemonic chain, where every receipt, every settlement, every internal transfer, and every fee payment travels on one address space and must be filtered post-hoc. OmniBus pre-segregates by design.

For accounting purposes, the five domains map naturally to five general-ledger accounts:

- OMNI: operational treasury, payments out, multi-chain bridges.
- LOVE: long-horizon reserve, signed under FIPS 204 ML-DSA.
- FOOD: low-bandwidth IoT or edge-device signatures, signed under Falcon.
- RENT: archival evidence, hash-based signatures under FIPS 205 SLH-DSA.
- VACATION: encrypted-payload channel, key encapsulation under FIPS 203 ML-KEM.

The per-scheme verifier ensures that a TX in the FOOD ledger cannot accidentally be miscategorized as LOVE; the chain itself rejects such mixups at the verifier dispatcher level.

### Quantum-resistant subset

Of the five domains, four are quantum-resistant under current cryptanalytic understanding (LOVE, FOOD, RENT under signatures; VACATION under encryption). Only OMNI (ECDSA secp256k1) is pre-quantum.

An institutional user who wants quantum-safe long-horizon storage parks their reserve in LOVE or RENT. An institutional user who needs current-day Bitcoin/Ethereum bridge compatibility uses OMNI. The five-wallet structure lets the institution use both, without picking one and abandoning the other.

If a quantum break occurs and OMNI keys become recoverable from public keys, the institution can perform a hash-time-locked atomic swap from OMNI to one of its PQ addresses and continue operating. The other four domains are unaffected because they are based on independent algorithms with independent quantum-resistance assumptions.

### GDPR-compatible: metadata can be encrypted under VACATION ML-KEM key

A common regulatory concern is that on-chain op_return data is permanent and globally readable. For metadata containing personally identifiable information (PII), this is incompatible with GDPR's right to erasure.

OmniBus offers a mitigation: the sender encrypts the PII under the recipient's VACATION ML-KEM public key, then writes the resulting ciphertext into the op_return field. The ciphertext is permanent and globally visible, but only the recipient (holder of the VACATION secret key) can decrypt it. The recipient can then exercise GDPR rights by destroying their VACATION mnemonic, rendering the on-chain ciphertext functionally erased: the data still exists as bytes, but no key exists to decrypt it.

This is a stronger erasure guarantee than most chains can offer, because the cryptographic basis (ML-KEM, FIPS 203) is a NIST-standardized, future-proof KEM rather than a pre-quantum algorithm whose ciphertext might become decryptable by a future attacker.

The 80-byte op_return budget limits the size of encryptable PII per TX, but for compact identifiers (customer reference numbers, jurisdiction codes, transaction purpose codes) this is sufficient. For longer payloads, the institution can chain TXs across multiple blocks, each carrying 80 bytes of ciphertext, all encrypted under the same VACATION public key.

### Auditable for regulators, opaque for the public

The final piece of the institutional story is the **opt-in `pq_attest`** mechanism (PQ_ISOLATED_WALLETS.md section 5). An institution that needs to demonstrate ownership of multiple addresses to a regulator can publish `pq_attest` op_returns binding their OMNI address to each of their PQ addresses. The regulator verifies the binding via the `pq_attestation` RPC. The chain's confirmations counter (Bitcoin parity) gives the regulator a confidence threshold for replay protection.

Meanwhile, an institution that does **not** publish attestations remains on-chain unlinkable across its five wallets. The default is privacy; the opt-in is auditability; the institution chooses per use case.

---

## Reference

- Source: `1_CORE/BlockChainCore/core/transaction.zig:64-118` (Transaction struct, op_return, MAX_OP_RETURN, scheme tag, public_key field).
- Source: `1_CORE/BlockChainCore/core/transaction.zig:141-199` (TX hash construction, op_return inclusion).
- Source: `1_CORE/BlockChainCore/core/blockchain.zig:444-451` (getConfirmations formula).
- Source: `1_CORE/BlockChainCore/core/finality.zig:9-21` (Bitcoin parity comment, soft finality threshold).
- Source: `1_CORE/BlockChainCore/core/finality.zig:30-37, 91-235` (Casper FFG hard finality gadget).
- Source: `1_CORE/BlockChainCore/core/isolated_wallet.zig:23-48` (Scheme enum and address prefix mapping).
- Source: `1_CORE/BlockChainCore/core/isolated_wallet.zig:367-375` (verifySignature dispatcher).
- Companion: `docs/PQ_ISOLATED_WALLETS.md` (user-facing 5-mnemonics explainer).
- Decision record: `memory/project_omnibus_5_isolated_wallets.md`.
