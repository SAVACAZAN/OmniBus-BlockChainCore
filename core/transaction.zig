const std = @import("std");
const secp256k1_mod = @import("secp256k1.zig");
const crypto_mod = @import("crypto.zig");
const hex_utils = @import("hex_utils.zig");
const bech32_mod = @import("bech32.zig");
const pq_crypto = @import("pq_crypto.zig");

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

pub const Scheme = enum(u8) {
    omni_ecdsa = 0,
    love_dilithium = 1,
    food_falcon = 2,
    rent_slh_dsa = 3,
    vacation_kem = 4,

    pub fn prefix(self: Scheme) []const u8 {
        return switch (self) {
            .omni_ecdsa => "ob1q",
            .love_dilithium => "ob_k1_",
            .food_falcon => "ob_f5_",
            .rent_slh_dsa => "ob_d5_",
            .vacation_kem => "ob_s3_",
        };
    }

    pub fn fromAddress(addr: []const u8) ?Scheme {
        if (std.mem.startsWith(u8, addr, "ob1q")) return .omni_ecdsa;
        if (std.mem.startsWith(u8, addr, "ob_k1_")) return .love_dilithium;
        if (std.mem.startsWith(u8, addr, "ob_f5_")) return .food_falcon;
        if (std.mem.startsWith(u8, addr, "ob_d5_")) return .rent_slh_dsa;
        if (std.mem.startsWith(u8, addr, "ob_s3_")) return .vacation_kem;
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
    /// Maximum OP_RETURN data size (80 bytes, same as Bitcoin)
    pub const MAX_OP_RETURN: usize = 80;
    /// Cap on inputs[] / outputs[] — defends against pathological TXs
    /// that would balloon UTXO set or block size. Bitcoin uses ~2^16
    /// in practice; we keep a tighter bound until we have soak data.
    pub const MAX_INPUTS: usize = 256;
    pub const MAX_OUTPUTS: usize = 256;

    /// True when the TX uses explicit v2 inputs/outputs.
    pub fn isV2(self: *const Transaction) bool {
        return self.inputs.len > 0 or self.outputs.len > 0;
    }

    /// Prefix-uri valide pentru adresele OmniBus
    const VALID_PREFIXES = [_][]const u8{
        "ob1q",        // OMNI SegWit v0 (P2WPKH/P2WSH, Bech32)
        "ob1p",        // OMNI Taproot v1 (Bech32m)
        "ob_omni_",    // Legacy OMNI native (coin 777) — backward compat
        "ob_k1_",      // OMNI_LOVE  (coin 778) — legacy
        "ob_f5_",      // OMNI_FOOD  (coin 779) — legacy
        "ob_d5_",      // OMNI_RENT  (coin 780) — legacy
        "ob_s3_",      // OMNI_VACATION (coin 781) — legacy
        "ob_ms_",      // Multisig (M-of-N P2SH-style) — legacy
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

        var hash1: [32]u8 = undefined;
        hasher.final(&hash1);
        // SHA256 dublu (SHA256d)
        return Crypto.sha256(&hash1);
    }

    /// Valideaza tranzactia: amount > 0 (or op_return TX), adrese cu prefix corect, op_return <= 80 bytes
    pub fn isValid(self: *const Transaction) bool {
        // OP_RETURN validation: max 80 bytes
        if (self.op_return.len > MAX_OP_RETURN) return false;

        // Amount must be > 0 unless this is an OP_RETURN data-only TX
        const is_op_return_tx = self.op_return.len > 0 and self.amount == 0;
        if (self.amount == 0 and !is_op_return_tx) return false;

        if (self.from_address.len == 0 or self.to_address.len == 0) return false;

        // Validate addresses
        const from_ok = isValidAddress(self.from_address);
        const to_ok = isValidAddress(self.to_address);
        if (!(from_ok and to_ok)) return false;

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
                return kp.verify(&hash_bytes, self.signature);
            },
            .food_falcon => {
                const pk = self.public_key;
                if (pk.len == 0) return false;
                var kp: pq_crypto.Falcon512 = undefined;
                if (pk.len != pq_crypto.Falcon512.PUBLIC_KEY_SIZE) return false;
                @memcpy(&kp.public_key, pk[0..pq_crypto.Falcon512.PUBLIC_KEY_SIZE]);
                return kp.verify(&hash_bytes, self.signature);
            },
            .rent_slh_dsa => {
                const pk = self.public_key;
                if (pk.len == 0) return false;
                var kp: pq_crypto.SlhDsa256s = undefined;
                if (pk.len != pq_crypto.SlhDsa256s.PUBLIC_KEY_SIZE) return false;
                @memcpy(&kp.public_key, pk[0..pq_crypto.SlhDsa256s.PUBLIC_KEY_SIZE]);
                return kp.verify(&hash_bytes, self.signature);
            },
            .vacation_kem => false, // KEM nu semneaza
        };
    }
};

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
