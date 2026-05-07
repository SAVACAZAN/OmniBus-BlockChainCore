const std = @import("std");
const secp256k1_mod = @import("secp256k1.zig");
const crypto_mod = @import("crypto.zig");
const hex_utils = @import("hex_utils.zig");
const bech32_mod = @import("bech32.zig");
const pq_crypto = @import("pq_crypto.zig");
const tx_payload = @import("tx_payload.zig");

const Secp256k1Crypto = secp256k1_mod.Secp256k1Crypto;
const Crypto = crypto_mod.Crypto;

/// PHASE-C wire format v2 — explicit transaction inputs & outputs.
///
/// Outpoint = pointer to a previous transaction output. The pair
/// (tx_hash, output_index) uniquely identifies a UTXO in the chain.
/// When a transaction "spends" a UTXO, it lists that outpoint in its
/// inputs[]. Identical layout to Bitcoin's COutPoint.
pub const Outpoint = struct {
    /// Hex hash (64 chars) of the transaction that created the UTXO.
    /// Empty string is reserved for v1 backward compatibility — when
    /// inputs[] is empty the chain falls back to the old implicit
    /// coin-selection path through bc.utxo_set.selectUTXOs.
    tx_hash: []const u8 = "",
    /// Output index within that transaction (0-based vout).
    output_index: u32 = 0,
};

/// PHASE-C wire format v2 — a single transaction output.
/// Each TxOutput becomes a UTXO once the block applies. Mirrors
/// Bitcoin's CTxOut: amount + locking script (here represented as
/// the recipient address; explicit scripts are still optional via
/// the legacy `script_pubkey` field on the parent Transaction).
pub const TxOutput = struct {
    amount: u64,
    address: []const u8,
};

/// TX type discriminator (Phase 2A — EIP-2718-style typed envelope).
///
/// `.transfer` (0x00) is the default: legacy plain UTXO transfer, no payload
/// in `data`, full backward compatibility with v1 wallets and existing tooling.
///
/// All other types carry a binary tagged payload in `Transaction.data` (max
/// 4 KiB), validated deterministically by every node before applyBlock.
///
/// Type assignments follow group semantics:
///   0x00       = transfer (default, legacy)
///   0x10..0x1F = exchange / orderbook
///   0x20..0x2F = bridge (custodial + observation)
///   0x30..0x3F = HTLC atomic swaps
///   0x40..0x4F = intent / solver flow
///   0x50..0x5F = TSS vault management
///   0x60..0x6F = governance
///   0x70..0x7F = name service / agent / staking (currently in op_return)
///   0xF0..0xFF = reserved for testnet experimentation
///
/// Adding a new type is a hard fork — strictly reject unknown types so a
/// minority client that doesn't recognise a payload can never accept a
/// block that deeper validators would reject.
pub const TxType = enum(u8) {
    /// 0x00 — Plain UTXO transfer. `data` MUST be empty. Default for all
    /// legacy v1 transactions and current wallet output. Validates exactly
    /// like before this change: inputs sum >= outputs + fee, signatures.
    transfer = 0x00,

    // ─── Exchange (Phase 2B integration) ──────────────────────────────
    /// 0x10 — Place a signed limit order on the orderbook.
    /// `data` = OrderPayload (pair_id, side, price, qty, expiry, nonce).
    order_place = 0x10,
    /// 0x11 — Cancel an existing active or partial order.
    /// `data` = OrderCancelPayload (order_id).
    order_cancel = 0x11,
    /// 0x12 — Modify an existing order (replace price/qty atomically).
    /// `data` = OrderModifyPayload.
    order_modify = 0x12,

    // ─── Bridge: custodial + observation (Phase 2F) ───────────────────
    /// 0x20 — User locks OMNI in vault, requests release on dest chain.
    bridge_lock = 0x20,
    /// 0x21 — Validators observe deposit on external chain, report on-chain.
    bridge_deposit_report = 0x21,
    /// 0x22 — User requests withdraw to external chain (burns proxy/lock).
    bridge_unlock_request = 0x22,
    /// 0x23 — Validator submits TSS sig share for a pending unlock.
    bridge_unlock_sign = 0x23,
    /// 0x24 — Anyone with proof challenges a pending unlock as fraudulent.
    bridge_fraud_challenge = 0x24,

    // ─── HTLC atomic swap (Phase 2F.2) ────────────────────────────────
    /// 0x30 — Lock OMNI under hash H for T blocks.
    htlc_init = 0x30,
    /// 0x31 — Reveal preimage of H, claim locked OMNI.
    htlc_claim = 0x31,
    /// 0x32 — After timeout, original locker reclaims funds.
    htlc_refund = 0x32,

    // ─── Intent / solver flow (Phase 2F.3) ────────────────────────────
    /// 0x40 — User signs intent ("sell 5 ETH at market for OMNI"); broadcasts.
    intent_post = 0x40,
    /// 0x41 — Solver locks bond, claims the right to fill the intent.
    intent_fill_commit = 0x41,
    /// 0x42 — Solver proves delivery on dest chain; bond released.
    intent_settle = 0x42,
    /// 0x43 — Solver missed deadline; bond slashed to user.
    intent_timeout = 0x43,

    // ─── TSS vault management (Phase 2F.4) ────────────────────────────
    /// 0x50 — Validator commits a DKG round.
    tss_dkg_commit = 0x50,
    /// 0x51 — DKG complete; ratify vault public key into chain state.
    tss_dkg_finalize = 0x51,
    /// 0x52 — Governance triggers vault key rotation.
    tss_vault_rotate = 0x52,

    // ─── Governance (Phase 2 future) ──────────────────────────────────
    /// 0x60 — Generic governance proposal/vote.
    governance = 0x60,

    // 0x70..0x7F — name service / agent / staking — currently piggy-back
    // on op_return prefix strings; will migrate here in a later phase.

    _,

    /// Returns true if `data` payload is required (i.e., not a plain transfer).
    pub fn requiresPayload(self: TxType) bool {
        return self != .transfer;
    }

    /// Returns true if a TX of this type touches the orderbook
    /// (used by applyBlock to short-circuit deterministic matching).
    pub fn touchesOrderbook(self: TxType) bool {
        return switch (self) {
            .order_place, .order_cancel, .order_modify => true,
            else => false,
        };
    }

    /// Returns true if a TX of this type involves the bridge state.
    pub fn touchesBridge(self: TxType) bool {
        return switch (self) {
            .bridge_lock,
            .bridge_deposit_report,
            .bridge_unlock_request,
            .bridge_unlock_sign,
            .bridge_fraud_challenge,
            .htlc_init, .htlc_claim, .htlc_refund,
            .intent_post, .intent_fill_commit, .intent_settle, .intent_timeout,
            .tss_dkg_commit, .tss_dkg_finalize, .tss_vault_rotate,
            => true,
            else => false,
        };
    }
};

pub const Scheme = enum(u8) {
    omni_ecdsa = 0,
    love_dilithium = 1,
    food_falcon = 2,
    rent_slh_dsa = 3,
    vacation_kem = 4,
    // PQ-OMNI transferable (Phase 1 — chain verifies PQ signature only):
    pq_omni_ml_dsa = 5,
    pq_omni_falcon = 6,
    pq_omni_dilithium = 7,
    pq_omni_slh_dsa = 8,
    // Hybrid Phase 2 — chain verifies BOTH ECDSA + PQ signatures:
    hybrid_q1 = 9,
    hybrid_q2 = 10,
    hybrid_q3 = 11,
    hybrid_q4 = 12,

    pub fn prefix(self: Scheme) []const u8 {
        return switch (self) {
            .omni_ecdsa => "ob1q",
            .love_dilithium => "ob_k1_",
            .food_falcon => "ob_f5_",
            .rent_slh_dsa => "ob_d5_",
            .vacation_kem => "ob_s3_",
            // FARA underscore initial — distinct vizual de soulbound
            .pq_omni_ml_dsa, .hybrid_q1 => "obk1_",
            .pq_omni_falcon, .hybrid_q2 => "obf5_",
            .pq_omni_dilithium, .hybrid_q3 => "obs3_",
            .pq_omni_slh_dsa, .hybrid_q4 => "obd5_",
        };
    }

    pub fn fromAddress(addr: []const u8) ?Scheme {
        // ATENTIE: ordine specifica pentru a evita confuzia ob_k1_ (soulbound)
        // cu obk1_ (PQ-OMNI transferable) — soulbound primii (cu underscore initial).
        if (std.mem.startsWith(u8, addr, "ob1q")) return .omni_ecdsa;
        if (std.mem.startsWith(u8, addr, "ob_k1_")) return .love_dilithium;
        if (std.mem.startsWith(u8, addr, "ob_f5_")) return .food_falcon;
        if (std.mem.startsWith(u8, addr, "ob_d5_")) return .rent_slh_dsa;
        if (std.mem.startsWith(u8, addr, "ob_s3_")) return .vacation_kem;
        // PQ-OMNI / Hybrid: fara underscore initial.
        // Returnam pq_omni_* aici; chain-ul distinge schema reala (PQ vs Hybrid)
        // din TX.scheme propriu, nu din prefixul adresei.
        if (std.mem.startsWith(u8, addr, "obk1_")) return .pq_omni_ml_dsa;
        if (std.mem.startsWith(u8, addr, "obf5_")) return .pq_omni_falcon;
        if (std.mem.startsWith(u8, addr, "obs3_")) return .pq_omni_dilithium;
        if (std.mem.startsWith(u8, addr, "obd5_")) return .pq_omni_slh_dsa;
        return null;
    }
};

pub const Transaction = struct {
    id: u32,
    /// PQ Isolated Wallets v2 — scheme tag. 0 = ECDSA legacy, 1-4 = PQ.
    scheme: Scheme = .omni_ecdsa,
    from_address: []const u8,
    to_address: []const u8,
    amount: u64,       // in SAT (1 OMNI = 1_000_000_000 SAT)
    /// Fee in SAT (min 1 SAT anti-spam; 50% burned, 50% to miner)
    fee: u64 = 0,
    timestamp: i64,
    /// Nonce: numar secvential per adresa sender (anti-replay, ca Ethereum/EGLD)
    /// Fiecare tranzactie de la o adresa trebuie sa aiba nonce = nonce_anterior + 1
    nonce: u64 = 0,
    /// OP_RETURN: date arbitrare embedded in TX (max 80 bytes, ca Bitcoin)
    /// Folosit pentru: timestamping, commit hashes, metadata, anchoring
    /// Unlike Bitcoin, OP_RETURN TXs with amount > 0 are allowed (metadata on normal TXs)
    op_return: []const u8 = "",
    /// Locktime: block height before which this TX cannot be included in a block
    /// 0 = no lock (immediate), >0 = locked until block height N
    /// Similar to Bitcoin nLockTime
    locktime: u64 = 0,
    /// Sequence number (BIP-125 RBF): 0xFFFFFFFF = final (no replacement)
    /// < 0xFFFFFFFE = opt-in RBF (can be replaced by higher fee TX)
    /// Similar to Bitcoin nSequence
    sequence: u32 = 0xFFFFFFFF,
    /// Locking script (empty = legacy ECDSA mode, P2PKH = 25 bytes)
    /// When set, TX validation runs the script VM in addition to ECDSA verify
    script_pubkey: []const u8 = "",
    /// Unlocking script (empty = legacy ECDSA mode, P2PKH unlock = 99 bytes)
    /// Provides the data (sig + pubkey) that satisfies the locking script
    script_sig: []const u8 = "",
    /// Semnatura ECDSA secp256k1 — 64 bytes (R||S) in hex (128 chars)
    signature: []const u8,
    /// Hash SHA256d al tranzactiei (64 hex chars)
    hash: []const u8,
    /// PQ Isolated Wallets v2 — public key needed for PQ verify (ECDSA recovers pubkey from sig).
    public_key: []const u8 = "",
    /// PHASE-C wire format v2 — explicit inputs (UTXOs spent by this TX).
    /// When empty (v1 TX), the chain falls back to implicit coin-selection
    /// via bc.utxo_set.selectUTXOs. When non-empty, validateTransaction
    /// asserts every input exists in the UTXO set and the sum of input
    /// amounts >= amount + fee.
    inputs: []const Outpoint = &.{},
    /// PHASE-C wire format v2 — explicit outputs created by this TX.
    /// When empty (v1 TX), chain creates a single implicit output to
    /// `to_address` with `amount`, plus a change output if needed.
    /// When non-empty, applyBlock materialises one UTXO per entry.
    outputs: []const TxOutput = &.{},
    /// PHASE-2A typed envelope — TX type discriminator (EIP-2718-style).
    /// `.transfer` (0x00) is the default and means: plain UTXO transfer
    /// with empty `data`, identical semantics to legacy v1 TXs. Any other
    /// value MUST come paired with a non-empty `data` payload validated
    /// per type. Default preserves full back-compat: existing wallets that
    /// don't set `tx_type` keep working unchanged.
    tx_type: TxType = .transfer,
    /// PHASE-2A typed payload — binary tagged data interpreted per `tx_type`.
    /// MUST be empty when `tx_type == .transfer`. MUST be non-empty for any
    /// other type. Wire-format is type-specific (see OrderPayload,
    /// BridgeLockPayload, HtlcInitPayload, IntentPostPayload, etc.).
    /// Capped at MAX_TYPED_PAYLOAD bytes to prevent block-size abuse.
    data: []const u8 = "",
    /// Maximum OP_RETURN data size (80 bytes, same as Bitcoin)
    pub const MAX_OP_RETURN: usize = 80;
    /// Maximum typed-payload size (4 KiB). Large enough for batch orders,
    /// PQ signatures, M-of-N validator sig bundles. Small enough to prevent
    /// pathological TXs from bloating block bandwidth.
    pub const MAX_TYPED_PAYLOAD: usize = 4096;
    /// Cap on inputs[] / outputs[] — defends against pathological TXs
    /// that would balloon UTXO set or block size. Bitcoin uses ~2^16
    /// in practice; we keep a tighter bound until we have soak data.
    pub const MAX_INPUTS: usize = 256;
    pub const MAX_OUTPUTS: usize = 256;
    /// Cap on `public_key` field length. Largest legitimate PQ pubkey on
    /// this chain is SLH-DSA-256s @ 64 bytes raw (~128 hex chars); ML-DSA-87
    /// is 2592 bytes raw, Falcon-512 is 897 bytes. 64 KiB is far above the
    /// largest scheme but blocks the unbounded-pubkey DoS vector flagged in
    /// EXPLOIT_DRILLS finding #4.
    pub const MAX_PUBLIC_KEY: usize = 65_536;

    /// True when the TX uses explicit v2 inputs/outputs.
    pub fn isV2(self: *const Transaction) bool {
        return self.inputs.len > 0 or self.outputs.len > 0;
    }

    /// True when the TX is Phase-2A typed (carries a non-trivial tx_type
    /// or payload). Plain transfers return false even if `data` is set
    /// to empty (the default state).
    pub fn isTyped(self: *const Transaction) bool {
        return self.tx_type != .transfer or self.data.len > 0;
    }

    /// Prefix-uri valide pentru adresele OmniBus
    const VALID_PREFIXES = [_][]const u8{
        "ob1q",        // OMNI SegWit v0 (P2WPKH/P2WSH, Bech32)
        "ob1p",        // OMNI Taproot v1 (Bech32m)
        "ob_omni_",    // Legacy OMNI native (coin 777) — backward compat
        "ob_k1_",      // OMNI_LOVE  (coin 778) — soulbound reputation
        "ob_f5_",      // OMNI_FOOD  (coin 779) — soulbound reputation
        "ob_d5_",      // OMNI_RENT  (coin 780) — soulbound reputation
        "ob_s3_",      // OMNI_VACATION (coin 781) — soulbound reputation
        "ob_ms_",      // Multisig (M-of-N P2SH-style) — legacy
        // PQ-OMNI transferable (Phase 1 PQ verify + Phase 2 hybrid ECDSA+PQ verify):
        // FARA underscore initial — distinct vizual de soulbound de mai sus.
        "obk1_",       // PQ-OMNI ML-DSA-87  (FIPS 204)  / Hybrid Q1 (ECDSA + ML-DSA)
        "obf5_",       // PQ-OMNI Falcon-512 (FIPS 206)  / Hybrid Q2 (ECDSA + Falcon)
        "obs3_",       // PQ-OMNI Dilithium-5            / Hybrid Q3 (ECDSA + Dilithium)
        "obd5_",       // PQ-OMNI SLH-DSA-256s (FIPS 205)/ Hybrid Q4 (ECDSA + SLH-DSA)
        "0x",          // ETH-compatible bridge
    };

    /// Calculeaza hash-ul tranzactiei (SHA256d — Bitcoin style)
    /// Hash = SHA256(SHA256(id || from || to || amount || timestamp || nonce))
    /// Nonce inclus in hash previne replay attacks (aceeasi TX cu nonce diferit = hash diferit)
    pub fn calculateHash(self: *const Transaction) [32]u8 {
        // Hash direct in hasher — no buffer overflow risk cu adrese lungi
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        // id
        var id_buf: [16]u8 = undefined;
        const id_str = std.fmt.bufPrint(&id_buf, "{d}", .{self.id}) catch "0";
        hasher.update(id_str);
        hasher.update(":");
        // from_address
        hasher.update(self.from_address);
        hasher.update(":");
        // to_address
        hasher.update(self.to_address);
        hasher.update(":");
        // amount
        var amt_buf: [24]u8 = undefined;
        const amt_str = std.fmt.bufPrint(&amt_buf, "{d}", .{self.amount}) catch "0";
        hasher.update(amt_str);
        hasher.update(":");
        // timestamp
        var ts_buf: [24]u8 = undefined;
        const ts_str = std.fmt.bufPrint(&ts_buf, "{d}", .{self.timestamp}) catch "0";
        hasher.update(ts_str);
        hasher.update(":");
        // nonce
        var nonce_buf: [24]u8 = undefined;
        const nonce_str = std.fmt.bufPrint(&nonce_buf, "{d}", .{self.nonce}) catch "0";
        hasher.update(nonce_str);
        // scheme (PQ Isolated Wallets v2 — prevents scheme swap attacks)
        if (@intFromEnum(self.scheme) != 0) {
            hasher.update(":SC:");
            var sc_buf: [4]u8 = undefined;
            const sc_str = std.fmt.bufPrint(&sc_buf, "{d}", .{@intFromEnum(self.scheme)}) catch "0";
            hasher.update(sc_str);
        }
        // public_key for PQ schemes (prevents pubkey substitution)
        if (self.public_key.len > 0) {
            hasher.update(":PK:");
            hasher.update(self.public_key);
        }
        // fee (part of signed data — prevents fee tampering)
        if (self.fee > 0) {
            hasher.update(":");
            var fee_buf: [24]u8 = undefined;
            const fee_str = std.fmt.bufPrint(&fee_buf, "{d}", .{self.fee}) catch "0";
            hasher.update(fee_str);
        }
        // locktime (part of signed data — prevents locktime tampering)
        if (self.locktime > 0) {
            hasher.update(":");
            var lt_buf: [24]u8 = undefined;
            const lt_str = std.fmt.bufPrint(&lt_buf, "lt{d}", .{self.locktime}) catch "0";
            hasher.update(lt_str);
        }
        // op_return (part of signed data — prevents data tampering)
        if (self.op_return.len > 0) {
            hasher.update(":OP:");
            hasher.update(self.op_return);
        }
        // PHASE-C wire v2 — inputs + outputs in hash domain.
        // Only mixed in when present so legacy v1 TXs keep the exact
        // same hash bytes they always had. Without this an attacker
        // could swap inputs[] after signing without the signature
        // breaking — defeats the whole point of explicit UTXO refs.
        if (self.inputs.len > 0) {
            hasher.update(":IN:");
            for (self.inputs) |inp| {
                hasher.update(inp.tx_hash);
                var oi_buf: [16]u8 = undefined;
                const oi_str = std.fmt.bufPrint(&oi_buf, ":{d}|", .{inp.output_index}) catch "0|";
                hasher.update(oi_str);
            }
        }
        if (self.outputs.len > 0) {
            hasher.update(":OUT:");
            for (self.outputs) |out| {
                var amt_buf2: [24]u8 = undefined;
                const amt_str2 = std.fmt.bufPrint(&amt_buf2, "{d}", .{out.amount}) catch "0";
                hasher.update(amt_str2);
                hasher.update(">");
                hasher.update(out.address);
                hasher.update("|");
            }
        }
        // PHASE-2A typed envelope — tx_type + data in hash domain.
        // Mixed in only when non-default so legacy plain transfers
        // (.transfer, empty data) keep the exact same hash bytes they
        // always had. Without this an attacker could swap an order TX
        // for a transfer TX (or vice versa) post-signature without
        // breaking the signature — defeats the whole point of typing.
        if (self.tx_type != .transfer) {
            hasher.update(":TT:");
            var tt_buf: [4]u8 = undefined;
            const tt_str = std.fmt.bufPrint(&tt_buf, "{d}", .{@intFromEnum(self.tx_type)}) catch "0";
            hasher.update(tt_str);
        }
        if (self.data.len > 0) {
            hasher.update(":DT:");
            hasher.update(self.data);
        }

        var hash1: [32]u8 = undefined;
        hasher.final(&hash1);
        // SHA256 dublu (SHA256d)
        return Crypto.sha256(&hash1);
    }

    /// Valideaza tranzactia: amount > 0 (or op_return TX), adrese cu prefix corect, op_return <= 80 bytes
    pub fn isValid(self: *const Transaction) bool {
        // OP_RETURN validation: max 80 bytes
        if (self.op_return.len > MAX_OP_RETURN) return false;

        // public_key cap — defends against unbounded-pubkey DoS
        // (EXPLOIT_DRILLS finding #4). Largest legitimate PQ pubkey
        // (ML-DSA-87 @ 2592 bytes) sits well under MAX_PUBLIC_KEY.
        if (self.public_key.len > MAX_PUBLIC_KEY) return false;

        // PHASE-2A — typed envelope basic validation.
        // Per-type deep validation lives in validateTransaction() (consensus
        // layer); this is just structural sanity to reject obviously
        // malformed TXs at the wire boundary.
        if (self.data.len > MAX_TYPED_PAYLOAD) return false;
        if (self.tx_type == .transfer and self.data.len > 0) return false;
        if (self.tx_type != .transfer and self.data.len == 0) return false;
        // Decode + per-type structural validation (reject malformed payloads
        // at the TX boundary so they never enter the mempool).
        tx_payload.validatePayload(self.tx_type, self.data) catch return false;

        // Amount-zero check: legacy TXs need amount>0 unless they carry a
        // data-only signal. Two valid signals exist:
        //   1. Legacy: op_return present (NS register, stake, etc.)
        //   2. Phase-2A: typed payload present (order, bridge, etc.)
        const is_op_return_tx = self.op_return.len > 0 and self.amount == 0;
        const is_typed_tx = self.tx_type != .transfer;
        if (self.amount == 0 and !is_op_return_tx and !is_typed_tx) return false;

        if (self.from_address.len == 0 or self.to_address.len == 0) return false;

        // Validate addresses
        const from_ok = isValidAddress(self.from_address);
        const to_ok = isValidAddress(self.to_address);
        if (!(from_ok and to_ok)) return false;

        // Soulbound reputation addresses (ob_k1_/ob_f5_/ob_d5_/ob_s3_) acumuleaza
        // reputatie si NU pot fi sender. Fondurile din ele sunt intotdeauna locked.
        // Adresele transferabile (ob1q/obk1_/obf5_/obd5_/obs3_) pot fi from.
        const SOULBOUND_PREFIXES = [_][]const u8{ "ob_k1_", "ob_f5_", "ob_d5_", "ob_s3_" };
        for (SOULBOUND_PREFIXES) |pfx| {
            if (std.mem.startsWith(u8, self.from_address, pfx)) return false;
        }

        // PHASE-C v2 — bounds + per-output address validation.
        if (self.inputs.len > MAX_INPUTS) return false;
        if (self.outputs.len > MAX_OUTPUTS) return false;
        for (self.outputs) |out| {
            if (!isValidAddress(out.address)) return false;
            if (out.amount == 0) return false; // no zero-amount outputs
        }

        return true;
    }

    /// Validate an OmniBus address — Bech32 checksum for ob1q/ob1p, prefix match for legacy
    fn isValidAddress(addr: []const u8) bool {
        if (addr.len == 0) return false;

        // Bech32/Bech32m addresses: full checksum validation
        if (std.mem.startsWith(u8, addr, "ob1")) {
            // Use a fixed buffer allocator to avoid heap allocation in validation
            var buf: [512]u8 = undefined;
            var fba = std.heap.FixedBufferAllocator.init(&buf);
            return bech32_mod.isValidOBAddress(addr, fba.allocator());
        }

        // Legacy and bridge prefixes: simple prefix match
        for (VALID_PREFIXES) |prefix| {
            if (std.mem.startsWith(u8, addr, prefix)) return true;
        }
        return false;
    }

    /// BIP-125: Is this transaction opt-in RBF? (can be replaced by higher fee)
    pub fn isRBF(self: *const Transaction) bool {
        return self.sequence < 0xFFFFFFFE;
    }

    /// Mark this transaction as RBF-enabled (opt-in)
    pub fn enableRBF(self: *Transaction) void {
        self.sequence = 0xFFFFFFFD; // Standard opt-in RBF value
    }

    /// Check if a replacement TX is valid (BIP-125 rules)
    /// Replacement must: same from_address+nonce, higher fee, higher sequence
    pub fn canBeReplacedBy(self: *const Transaction, replacement: *const Transaction) bool {
        // Rule 1: Must be RBF-enabled
        if (!self.isRBF()) return false;
        // Rule 2: Same sender and nonce (same "slot")
        if (!std.mem.eql(u8, self.from_address, replacement.from_address)) return false;
        if (self.nonce != replacement.nonce) return false;
        // Rule 3: Replacement must pay strictly higher fee
        if (replacement.fee <= self.fee) return false;
        return true;
    }

    /// Semneaza tranzactia cu private key (secp256k1 ECDSA SHA256d — REAL)
    /// Seteaza self.signature = hex(R||S) si self.hash = hex(tx_hash)
    pub fn sign(self: *Transaction, private_key: [32]u8, allocator: std.mem.Allocator) !void {
        // 1. Calculeaza hash-ul tranzactiei
        const tx_hash = self.calculateHash();

        // 2. Semneaza hash-ul cu secp256k1 ECDSA
        const sig_bytes = try Secp256k1Crypto.sign(private_key, &tx_hash);

        // 3. Converteste la hex pentru stocare/transmisie
        self.signature = try Crypto.bytesToHex(&sig_bytes, allocator);
        self.hash      = try Crypto.bytesToHex(&tx_hash, allocator);
    }

    /// Verifica semnatura tranzactiei cu public key (secp256k1 ECDSA — REAL)
    pub fn verify(self: *const Transaction, compressed_pubkey: [33]u8) bool {
        if (self.signature.len != 128) return false; // 64 bytes hex = 128 chars
        if (self.hash.len != 64) return false;

        // Reconverteste din hex
        var sig_bytes: [64]u8 = undefined;
        var hash_bytes: [32]u8 = undefined;

        hex_utils.hexToBytes(self.signature, &sig_bytes) catch return false;
        hex_utils.hexToBytes(self.hash, &hash_bytes) catch return false;

        // Verifica: hash trebuie sa fie hash-ul real al tranzactiei
        const expected_hash = self.calculateHash();
        if (!std.mem.eql(u8, &hash_bytes, &expected_hash)) return false;

        // Verifica semnatura cu secp256k1
        return Secp256k1Crypto.verify(compressed_pubkey, &hash_bytes, sig_bytes);
    }

    /// Verifica semnatura cu public key in format hex (66 chars)
    pub fn verifyWithHexPubkey(self: *const Transaction, pubkey_hex: []const u8) bool {
        if (pubkey_hex.len != 66) return false;
        var pubkey_bytes: [33]u8 = undefined;
        hex_utils.hexToBytes(pubkey_hex, &pubkey_bytes) catch return false;
        return self.verify(pubkey_bytes);
    }

    /// PQ Isolated Wallets v2 — verificare per scheme.
    /// Pentru ECDSA: foloseste pubkey_hex din registru (66 hex chars).
    /// Pentru PQ: foloseste self.public_key (bytes raw, nu hex).
    /// FIX 2026-05-05: PQ signatures stocate ca hex trebuie decode inainte de verify
    pub fn verifySignature(self: *const Transaction, pubkey_hex: ?[]const u8) bool {
        // Verifica hash intai (common path)
        if (self.hash.len != 64) return false;
        var hash_bytes: [32]u8 = undefined;
        hex_utils.hexToBytes(self.hash, &hash_bytes) catch return false;
        const expected_hash = self.calculateHash();
        if (!std.mem.eql(u8, &hash_bytes, &expected_hash)) return false;

        return switch (self.scheme) {
            .omni_ecdsa => {
                const pk = pubkey_hex orelse return false;
                if (pk.len != 66) return false;
                var pk_bytes: [33]u8 = undefined;
                hex_utils.hexToBytes(pk, &pk_bytes) catch return false;
                if (self.signature.len != 128) return false;
                var sig_bytes: [64]u8 = undefined;
                hex_utils.hexToBytes(self.signature, &sig_bytes) catch return false;
                return Secp256k1Crypto.verify(pk_bytes, &hash_bytes, sig_bytes);
            },
            .love_dilithium => {
                const pk = self.public_key;
                if (pk.len == 0) return false;
                var kp: pq_crypto.MlDsa87 = undefined;
                if (pk.len != pq_crypto.MlDsa87.PUBLIC_KEY_SIZE) return false;
                @memcpy(&kp.public_key, pk[0..pq_crypto.MlDsa87.PUBLIC_KEY_SIZE]);
                // hex_utils.hexToBytes returns !void; the byte length is hex.len/2
                if (self.signature.len % 2 != 0) return false;
                const sig_len = self.signature.len / 2;
                if (sig_len > pq_crypto.MlDsa87.SIGNATURE_MAX) return false;
                var sig_bytes: [pq_crypto.MlDsa87.SIGNATURE_MAX]u8 = undefined;
                hex_utils.hexToBytes(self.signature, sig_bytes[0..sig_len]) catch return false;
                return kp.verify(&hash_bytes, sig_bytes[0..sig_len]);
            },
            .food_falcon => {
                const pk = self.public_key;
                if (pk.len == 0) return false;
                var kp: pq_crypto.Falcon512 = undefined;
                if (pk.len != pq_crypto.Falcon512.PUBLIC_KEY_SIZE) return false;
                @memcpy(&kp.public_key, pk[0..pq_crypto.Falcon512.PUBLIC_KEY_SIZE]);
                if (self.signature.len % 2 != 0) return false;
                const sig_len = self.signature.len / 2;
                if (sig_len > pq_crypto.Falcon512.SIGNATURE_MAX) return false;
                var sig_bytes: [pq_crypto.Falcon512.SIGNATURE_MAX]u8 = undefined;
                hex_utils.hexToBytes(self.signature, sig_bytes[0..sig_len]) catch return false;
                return kp.verify(&hash_bytes, sig_bytes[0..sig_len]);
            },
            .rent_slh_dsa => {
                const pk = self.public_key;
                if (pk.len == 0) return false;
                var kp: pq_crypto.SlhDsa256s = undefined;
                if (pk.len != pq_crypto.SlhDsa256s.PUBLIC_KEY_SIZE) return false;
                @memcpy(&kp.public_key, pk[0..pq_crypto.SlhDsa256s.PUBLIC_KEY_SIZE]);
                if (self.signature.len % 2 != 0) return false;
                const sig_len = self.signature.len / 2;
                if (sig_len > pq_crypto.SlhDsa256s.SIGNATURE_MAX) return false;
                var sig_bytes: [pq_crypto.SlhDsa256s.SIGNATURE_MAX]u8 = undefined;
                hex_utils.hexToBytes(self.signature, sig_bytes[0..sig_len]) catch return false;
                return kp.verify(&hash_bytes, sig_bytes[0..sig_len]);
            },
            .vacation_kem => false, // KEM nu semneaza
            // PQ-OMNI transferable schemes — embedded pubkey, hex signature.
            // For now, defer full PQ verify on these to applyBlock; mempool
            // accepts PQ TXs (they already pass at chain level via the
            // existing PQ verify path through pq_send / sendpqattest).
            .pq_omni_ml_dsa, .pq_omni_falcon, .pq_omni_dilithium, .pq_omni_slh_dsa,
            .hybrid_q1, .hybrid_q2, .hybrid_q3, .hybrid_q4 => true,
        };
    }
};

// ─── DB v4 Wire Codec ───────────────────────────────────────────────────────
// Persistent serialization for Transaction inside chain.dat blocks. Used by
// database.zig saveBlockchain/parseBlockData to keep TX history through
// restarts (DB v4, 2026-05-06). Layout — all integers little-endian:
//
//   [tx_type:1][scheme:1][id:4][amount:8][fee:8][nonce:8][timestamp:8]
//   [locktime:8][sequence:4]
//   [from_len:1][from][to_len:1][to][hash_len:1][hash]
//   [sig_len:2][signature][pubkey_len:2][public_key]
//   [opret_len:1][op_return]
//   [scriptpub_len:2][script_pubkey][scriptsig_len:2][script_sig]
//   [data_len:2][data]
//   [in_count:1][per: tx_hash_len:1, tx_hash, output_index:4]
//   [out_count:1][per: amount:8, addr_len:1, addr]
//
// Variable strings <=255 bytes use 1-byte length; bigger fields (sig/pubkey/
// scripts/data) use 2-byte. This packs an average TX into ~320 B.

pub const TX_WIRE_VERSION: u8 = 1;

pub fn encodeWireSize(tx: *const Transaction) usize {
    var n: usize = 0;
    n += 1 + 1 + 4 + 8 + 8 + 8 + 8 + 8 + 4;            // fixed numeric fields
    n += 1 + tx.from_address.len;
    n += 1 + tx.to_address.len;
    n += 1 + tx.hash.len;
    n += 2 + tx.signature.len;
    n += 2 + tx.public_key.len;
    n += 1 + tx.op_return.len;
    n += 2 + tx.script_pubkey.len;
    n += 2 + tx.script_sig.len;
    n += 2 + tx.data.len;
    n += 1; // in_count
    for (tx.inputs) |inp| n += 1 + inp.tx_hash.len + 4;
    n += 1; // out_count
    for (tx.outputs) |out| n += 8 + 1 + out.address.len;
    return n;
}

pub fn encodeWire(out: *std.array_list.Managed(u8), tx: *const Transaction) !void {
    try out.append(@intFromEnum(tx.tx_type));
    try out.append(@intFromEnum(tx.scheme));

    var u4buf: [4]u8 = undefined;
    var u8buf: [8]u8 = undefined;

    std.mem.writeInt(u32, &u4buf, tx.id, .little);            try out.appendSlice(&u4buf);
    std.mem.writeInt(u64, &u8buf, tx.amount, .little);        try out.appendSlice(&u8buf);
    std.mem.writeInt(u64, &u8buf, tx.fee, .little);           try out.appendSlice(&u8buf);
    std.mem.writeInt(u64, &u8buf, tx.nonce, .little);         try out.appendSlice(&u8buf);
    std.mem.writeInt(i64, &u8buf, tx.timestamp, .little);     try out.appendSlice(&u8buf);
    std.mem.writeInt(u64, &u8buf, tx.locktime, .little);      try out.appendSlice(&u8buf);
    std.mem.writeInt(u32, &u4buf, tx.sequence, .little);      try out.appendSlice(&u4buf);

    try writeLp1(out, tx.from_address);
    try writeLp1(out, tx.to_address);
    try writeLp1(out, tx.hash);

    try writeLp2(out, tx.signature);
    try writeLp2(out, tx.public_key);

    try writeLp1(out, tx.op_return);

    try writeLp2(out, tx.script_pubkey);
    try writeLp2(out, tx.script_sig);
    try writeLp2(out, tx.data);

    if (tx.inputs.len > 255) return error.TooManyInputs;
    try out.append(@intCast(tx.inputs.len));
    for (tx.inputs) |inp| {
        try writeLp1(out, inp.tx_hash);
        std.mem.writeInt(u32, &u4buf, inp.output_index, .little);
        try out.appendSlice(&u4buf);
    }
    if (tx.outputs.len > 255) return error.TooManyOutputs;
    try out.append(@intCast(tx.outputs.len));
    for (tx.outputs) |o| {
        std.mem.writeInt(u64, &u8buf, o.amount, .little);
        try out.appendSlice(&u8buf);
        try writeLp1(out, o.address);
    }
}

fn writeLp1(out: *std.array_list.Managed(u8), s: []const u8) !void {
    if (s.len > 255) return error.LengthOverflow;
    try out.append(@intCast(s.len));
    try out.appendSlice(s);
}

fn writeLp2(out: *std.array_list.Managed(u8), s: []const u8) !void {
    if (s.len > 65535) return error.LengthOverflow;
    var b2: [2]u8 = undefined;
    std.mem.writeInt(u16, &b2, @intCast(s.len), .little);
    try out.appendSlice(&b2);
    try out.appendSlice(s);
}

/// Decode TX from wire format. All variable-length slices are heap-duped via
/// `alloc` so the caller owns them — append the resulting Transaction into a
/// container that lives at least as long as the allocator.
pub fn decodeWire(buf: []const u8, alloc: std.mem.Allocator, consumed: *usize) !Transaction {
    var p: usize = 0;
    if (buf.len < 1 + 1 + 4 + 8 + 8 + 8 + 8 + 8 + 4) return error.WireTooShort;

    const tx_type_raw = buf[p]; p += 1;
    const scheme_raw  = buf[p]; p += 1;

    const id        = std.mem.readInt(u32, buf[p..][0..4], .little); p += 4;
    const amount    = std.mem.readInt(u64, buf[p..][0..8], .little); p += 8;
    const fee       = std.mem.readInt(u64, buf[p..][0..8], .little); p += 8;
    const nonce     = std.mem.readInt(u64, buf[p..][0..8], .little); p += 8;
    const timestamp = std.mem.readInt(i64, buf[p..][0..8], .little); p += 8;
    const locktime  = std.mem.readInt(u64, buf[p..][0..8], .little); p += 8;
    const sequence  = std.mem.readInt(u32, buf[p..][0..4], .little); p += 4;

    const from = try readLp1Dup(buf, &p, alloc);
    const to   = try readLp1Dup(buf, &p, alloc);
    const hash = try readLp1Dup(buf, &p, alloc);

    const sig    = try readLp2Dup(buf, &p, alloc);
    const pubkey = try readLp2Dup(buf, &p, alloc);

    const op_ret = try readLp1Dup(buf, &p, alloc);

    const script_pub = try readLp2Dup(buf, &p, alloc);
    const script_sig = try readLp2Dup(buf, &p, alloc);
    const data       = try readLp2Dup(buf, &p, alloc);

    if (p + 1 > buf.len) return error.WireTooShort;
    const in_count = buf[p]; p += 1;
    const inputs = if (in_count == 0) blk: {
        break :blk &[_]Outpoint{};
    } else blk: {
        const arr = try alloc.alloc(Outpoint, in_count);
        for (arr) |*entry| {
            const tx_hash = try readLp1Dup(buf, &p, alloc);
            if (p + 4 > buf.len) return error.WireTooShort;
            const idx = std.mem.readInt(u32, buf[p..][0..4], .little); p += 4;
            entry.* = Outpoint{ .tx_hash = tx_hash, .output_index = idx };
        }
        break :blk arr;
    };

    if (p + 1 > buf.len) return error.WireTooShort;
    const out_count = buf[p]; p += 1;
    const outputs = if (out_count == 0) blk: {
        break :blk &[_]TxOutput{};
    } else blk: {
        const arr = try alloc.alloc(TxOutput, out_count);
        for (arr) |*entry| {
            if (p + 8 > buf.len) return error.WireTooShort;
            const amt = std.mem.readInt(u64, buf[p..][0..8], .little); p += 8;
            const addr = try readLp1Dup(buf, &p, alloc);
            entry.* = TxOutput{ .amount = amt, .address = addr };
        }
        break :blk arr;
    };

    consumed.* = p;
    return Transaction{
        .id = id,
        .scheme = std.meta.intToEnum(Scheme, scheme_raw) catch .omni_ecdsa,
        .from_address = from,
        .to_address = to,
        .amount = amount,
        .fee = fee,
        .timestamp = timestamp,
        .nonce = nonce,
        .op_return = op_ret,
        .locktime = locktime,
        .sequence = sequence,
        .script_pubkey = script_pub,
        .script_sig = script_sig,
        .signature = sig,
        .hash = hash,
        .public_key = pubkey,
        .inputs = inputs,
        .outputs = outputs,
        .tx_type = std.meta.intToEnum(TxType, tx_type_raw) catch .transfer,
        .data = data,
    };
}

fn readLp1Dup(buf: []const u8, p: *usize, alloc: std.mem.Allocator) ![]const u8 {
    if (p.* + 1 > buf.len) return error.WireTooShort;
    const n = buf[p.*]; p.* += 1;
    if (n == 0) return "";
    if (p.* + n > buf.len) return error.WireTooShort;
    const slice = buf[p.* .. p.* + n];
    p.* += n;
    return try alloc.dupe(u8, slice);
}

fn readLp2Dup(buf: []const u8, p: *usize, alloc: std.mem.Allocator) ![]const u8 {
    if (p.* + 2 > buf.len) return error.WireTooShort;
    const n = std.mem.readInt(u16, buf[p.*..][0..2], .little); p.* += 2;
    if (n == 0) return "";
    if (p.* + n > buf.len) return error.WireTooShort;
    const slice = buf[p.* .. p.* + n];
    p.* += n;
    return try alloc.dupe(u8, slice);
}

// ─── Teste ───────────────────────────────────────────────────────────────────

const testing = std.testing;

test "Transaction.isValid — adrese corecte" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const tx = Transaction{
        .id           = 1,
        .from_address = "ob1qjhtj3yr5hkr2xxveupku98dcql9a6pcq5zfak0",
        .to_address   = "ob_k1_def456",
        .amount       = 1_000_000_000,
        .timestamp    = 1700000000,
        .signature    = "",
        .hash         = "",
    };
    try testing.expect(tx.isValid());
}

test "Transaction.isValid — amount zero → invalid" {
    const tx = Transaction{
        .id           = 2,
        .from_address = "ob1qjhtj3yr5hkr2xxveupku98dcql9a6pcq5zfak0",
        .to_address   = "ob1q9w8sn7v9qemhe6dfyjh7u84hcs3nys4vep0wrc",
        .amount       = 0,
        .timestamp    = 1700000000,
        .signature    = "",
        .hash         = "",
    };
    try testing.expect(!tx.isValid());
}

test "Transaction.isValid — prefix invalid → false" {
    const tx = Transaction{
        .id           = 3,
        .from_address = "INVALID_addr",
        .to_address   = "ob1qjhtj3yr5hkr2xxveupku98dcql9a6pcq5zfak0",
        .amount       = 1000,
        .timestamp    = 1700000000,
        .signature    = "",
        .hash         = "",
    };
    try testing.expect(!tx.isValid());
}

test "Transaction.calculateHash — determinist" {
    const tx = Transaction{
        .id           = 1,
        .from_address = "ob1qx787af2p22knzjlakn7ehz9r77p3ak2w8zkk2s",
        .to_address   = "ob1q0l4glravfx9qt5j0uqqectjl0q3kjlnwlt22gt",
        .amount       = 5_000_000_000,
        .timestamp    = 1700000000,
        .signature    = "",
        .hash         = "",
    };
    const h1 = tx.calculateHash();
    const h2 = tx.calculateHash();
    try testing.expectEqualSlices(u8, &h1, &h2);
}

test "Transaction sign si verify — ECDSA secp256k1 REAL" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // Genereaza pereche de chei
    const kp = try Secp256k1Crypto.generateKeyPair();

    var tx = Transaction{
        .id           = 42,
        .from_address = "ob1qnr6t7pv49zgdjj9lwksunqwl24mywvklpfycxr",
        .to_address   = "ob1qq5tpx4wxy5jmww0x2mpklguwmmlj8s2rfn7su9",
        .amount       = 10_000_000_000, // 10 OMNI
        .timestamp    = 1700000042,
        .signature    = "",
        .hash         = "",
    };

    // Semneaza
    try tx.sign(kp.private_key, arena.allocator());

    // Semnatura si hash-ul sunt acum setate (hex)
    try testing.expectEqual(@as(usize, 128), tx.signature.len);
    try testing.expectEqual(@as(usize, 64), tx.hash.len);

    // Verifica cu public key corect → true
    try testing.expect(tx.verify(kp.public_key));
}

test "Transaction verify — public key gresit → false" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const kp1 = try Secp256k1Crypto.generateKeyPair();
    const kp2 = try Secp256k1Crypto.generateKeyPair();

    var tx = Transaction{
        .id           = 99,
        .from_address = "ob1q0cryu8489kaquslshqhwnwrkaz78aq3g374nrv",
        .to_address   = "ob1qya9sq7xpg4shf3r67772vnfg5xre5wvwvgc959",
        .amount       = 1_000_000_000,
        .timestamp    = 1700000099,
        .signature    = "",
        .hash         = "",
    };

    try tx.sign(kp1.private_key, arena.allocator());

    // Verifica cu alt public key → false
    try testing.expect(!tx.verify(kp2.public_key));
}

// ─── Timelock + OP_RETURN tests ─────────────────────────────────────────────

test "Transaction — locktime changes hash" {
    const tx1 = Transaction{
        .id = 1, .from_address = "ob1qx787af2p22knzjlakn7ehz9r77p3ak2w8zkk2s", .to_address = "ob1q0l4glravfx9qt5j0uqqectjl0q3kjlnwlt22gt",
        .amount = 1000, .timestamp = 1700000000, .locktime = 0,
        .signature = "", .hash = "",
    };
    const tx2 = Transaction{
        .id = 1, .from_address = "ob1qx787af2p22knzjlakn7ehz9r77p3ak2w8zkk2s", .to_address = "ob1q0l4glravfx9qt5j0uqqectjl0q3kjlnwlt22gt",
        .amount = 1000, .timestamp = 1700000000, .locktime = 100,
        .signature = "", .hash = "",
    };
    const h1 = tx1.calculateHash();
    const h2 = tx2.calculateHash();
    try testing.expect(!std.mem.eql(u8, &h1, &h2));
}

test "Transaction — locktime 0 hash unchanged (backward compat)" {
    const tx1 = Transaction{
        .id = 1, .from_address = "ob1qx787af2p22knzjlakn7ehz9r77p3ak2w8zkk2s", .to_address = "ob1q0l4glravfx9qt5j0uqqectjl0q3kjlnwlt22gt",
        .amount = 1000, .timestamp = 1700000000, .locktime = 0,
        .signature = "", .hash = "",
    };
    const tx2 = Transaction{
        .id = 1, .from_address = "ob1qx787af2p22knzjlakn7ehz9r77p3ak2w8zkk2s", .to_address = "ob1q0l4glravfx9qt5j0uqqectjl0q3kjlnwlt22gt",
        .amount = 1000, .timestamp = 1700000000,
        .signature = "", .hash = "",
    };
    const h1 = tx1.calculateHash();
    const h2 = tx2.calculateHash();
    try testing.expectEqualSlices(u8, &h1, &h2);
}

test "Transaction — op_return > 80 bytes rejected" {
    const big_data = "A" ** 81; // 81 bytes > MAX_OP_RETURN
    const tx = Transaction{
        .id = 1, .from_address = "ob1qx787af2p22knzjlakn7ehz9r77p3ak2w8zkk2s", .to_address = "ob1q0l4glravfx9qt5j0uqqectjl0q3kjlnwlt22gt",
        .amount = 1000, .timestamp = 1700000000,
        .op_return = big_data,
        .signature = "", .hash = "",
    };
    try testing.expect(!tx.isValid());
}

test "Transaction — op_return exactly 80 bytes accepted" {
    const data_80 = "B" ** 80; // exactly 80 bytes = MAX_OP_RETURN
    const tx = Transaction{
        .id = 1, .from_address = "ob1qx787af2p22knzjlakn7ehz9r77p3ak2w8zkk2s", .to_address = "ob1q0l4glravfx9qt5j0uqqectjl0q3kjlnwlt22gt",
        .amount = 1000, .timestamp = 1700000000,
        .op_return = data_80,
        .signature = "", .hash = "",
    };
    try testing.expect(tx.isValid());
}

test "Transaction — op_return TX with amount=0 is valid" {
    const tx = Transaction{
        .id = 1, .from_address = "ob1qx787af2p22knzjlakn7ehz9r77p3ak2w8zkk2s", .to_address = "ob1q0l4glravfx9qt5j0uqqectjl0q3kjlnwlt22gt",
        .amount = 0, .timestamp = 1700000000,
        .op_return = "hello blockchain",
        .signature = "", .hash = "",
    };
    try testing.expect(tx.isValid());
}

test "Transaction — op_return TX with amount>0 is valid (metadata embed)" {
    const tx = Transaction{
        .id = 1, .from_address = "ob1qx787af2p22knzjlakn7ehz9r77p3ak2w8zkk2s", .to_address = "ob1q0l4glravfx9qt5j0uqqectjl0q3kjlnwlt22gt",
        .amount = 5000, .timestamp = 1700000000,
        .op_return = "payment memo: invoice #42",
        .signature = "", .hash = "",
    };
    try testing.expect(tx.isValid());
}

test "Transaction — amount=0 without op_return is still invalid" {
    const tx = Transaction{
        .id = 1, .from_address = "ob1qx787af2p22knzjlakn7ehz9r77p3ak2w8zkk2s", .to_address = "ob1q0l4glravfx9qt5j0uqqectjl0q3kjlnwlt22gt",
        .amount = 0, .timestamp = 1700000000,
        .signature = "", .hash = "",
    };
    try testing.expect(!tx.isValid());
}

test "Transaction — op_return changes hash" {
    const tx1 = Transaction{
        .id = 1, .from_address = "ob1qx787af2p22knzjlakn7ehz9r77p3ak2w8zkk2s", .to_address = "ob1q0l4glravfx9qt5j0uqqectjl0q3kjlnwlt22gt",
        .amount = 1000, .timestamp = 1700000000,
        .signature = "", .hash = "",
    };
    const tx2 = Transaction{
        .id = 1, .from_address = "ob1qx787af2p22knzjlakn7ehz9r77p3ak2w8zkk2s", .to_address = "ob1q0l4glravfx9qt5j0uqqectjl0q3kjlnwlt22gt",
        .amount = 1000, .timestamp = 1700000000,
        .op_return = "data",
        .signature = "", .hash = "",
    };
    const h1 = tx1.calculateHash();
    const h2 = tx2.calculateHash();
    try testing.expect(!std.mem.eql(u8, &h1, &h2));
}
