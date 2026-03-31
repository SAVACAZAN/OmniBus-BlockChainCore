const std = @import("std");
const transaction_mod = @import("transaction.zig");
const crypto_mod = @import("crypto.zig");
const secp256k1_mod = @import("secp256k1.zig");

const Transaction = transaction_mod.Transaction;
const Secp256k1Crypto = secp256k1_mod.Secp256k1Crypto;
const Crypto = crypto_mod.Crypto;

// ─── PSBT — Partially Signed Bitcoin Transactions (BIP-174) ─────────────────
//
// PSBT allows multiple parties to collaborate on signing a transaction.
// Flow: Creator -> Updater -> Signer(s) -> Combiner -> Finalizer -> Extractor
//
// OmniBus PSBT format:
//   Magic: "psbt" (4 bytes) + 0xFF separator
//   Global: unsigned TX
//   Per-input: partial signatures, pubkeys, redeem scripts
//   Per-output: (reserved for future use)

pub const PSBT_MAGIC = [4]u8{ 'p', 's', 'b', 't' };
pub const PSBT_SEPARATOR = 0xFF;

/// PSBT role in the signing workflow
pub const PSBTRole = enum {
    unsigned,        // Created, no signatures yet
    partially_signed, // Some signers have signed
    fully_signed,    // All required signatures present
    finalized,       // Ready for broadcast
};

/// A partial signature from one signer
pub const PartialSig = struct {
    /// Compressed public key of the signer (33 bytes)
    pubkey: [33]u8,
    /// ECDSA signature (64 bytes R||S)
    signature: [64]u8,
};

/// PSBT input data
pub const PSBTInput = struct {
    /// Index in the transaction
    index: u32,
    /// Partial signatures collected so far
    partial_sigs: std.ArrayList(PartialSig),
    /// Required number of signatures (1 for simple, M for multisig)
    sigs_required: u32,
    /// Is this input fully signed?
    pub fn isFullySigned(self: *const PSBTInput) bool {
        return self.partial_sigs.items.len >= self.sigs_required;
    }
};

/// Partially Signed Bitcoin Transaction
pub const PSBT_TX = struct {
    /// The unsigned transaction
    tx: Transaction,
    /// Per-input signing data
    inputs: std.ArrayList(PSBTInput),
    /// Current role/status
    role: PSBTRole,
    /// Creator info
    creator: []const u8,
    allocator: std.mem.Allocator,

    /// Create a new PSBT from an unsigned transaction
    pub fn create(tx: Transaction, num_inputs: u32, allocator: std.mem.Allocator) !PSBT_TX {
        var inputs: std.ArrayList(PSBTInput) = .empty;
        for (0..num_inputs) |i| {
            try inputs.append(allocator, PSBTInput{
                .index = @intCast(i),
                .partial_sigs = .empty,
                .sigs_required = 1, // default: single-sig
            });
        }

        return PSBT_TX{
            .tx = tx,
            .inputs = inputs,
            .role = .unsigned,
            .creator = "OmniBus PSBT",
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *PSBT_TX) void {
        for (self.inputs.items) |*input| {
            input.partial_sigs.deinit(self.allocator);
        }
        self.inputs.deinit(self.allocator);
    }

    /// Add a signature for a specific input
    pub fn addSignature(self: *PSBT_TX, input_index: u32, pubkey: [33]u8, signature: [64]u8) !void {
        if (input_index >= self.inputs.items.len) return error.InputIndexOutOfRange;

        var input = &self.inputs.items[input_index];

        // Check for duplicate pubkey
        for (input.partial_sigs.items) |existing| {
            if (std.mem.eql(u8, &existing.pubkey, &pubkey)) return error.DuplicateSignature;
        }

        try input.partial_sigs.append(self.allocator, PartialSig{
            .pubkey = pubkey,
            .signature = signature,
        });

        // Update role
        self.updateRole();
    }

    /// Sign an input with a private key
    pub fn signInput(self: *PSBT_TX, input_index: u32, private_key: [32]u8) !void {
        const tx_hash = self.tx.calculateHash();
        const sig = try Secp256k1Crypto.sign(private_key, &tx_hash);
        const pubkey = try Secp256k1Crypto.privateKeyToPublicKey(private_key);
        try self.addSignature(input_index, pubkey, sig);
    }

    /// Check if all inputs are fully signed
    pub fn isComplete(self: *const PSBT_TX) bool {
        for (self.inputs.items) |input| {
            if (!input.isFullySigned()) return false;
        }
        return true;
    }

    /// Finalize: extract the signed transaction (sets signature on TX)
    pub fn finalize(self: *PSBT_TX, allocator: std.mem.Allocator) !Transaction {
        if (!self.isComplete()) return error.IncompletePSBT;

        // For single-sig: use the first signature from input 0
        if (self.inputs.items.len > 0 and self.inputs.items[0].partial_sigs.items.len > 0) {
            const sig = self.inputs.items[0].partial_sigs.items[0].signature;
            const tx_hash = self.tx.calculateHash();
            self.tx.signature = try Crypto.bytesToHex(&sig, allocator);
            self.tx.hash = try Crypto.bytesToHex(&tx_hash, allocator);
        }

        self.role = .finalized;
        return self.tx;
    }

    /// Update the role based on signature state
    fn updateRole(self: *PSBT_TX) void {
        if (self.isComplete()) {
            self.role = .fully_signed;
        } else {
            var has_any = false;
            for (self.inputs.items) |input| {
                if (input.partial_sigs.items.len > 0) {
                    has_any = true;
                    break;
                }
            }
            self.role = if (has_any) .partially_signed else .unsigned;
        }
    }

    /// Get signing progress: (signed_count, total_required)
    pub fn getProgress(self: *const PSBT_TX) struct { signed: u32, required: u32 } {
        var signed: u32 = 0;
        var required: u32 = 0;
        for (self.inputs.items) |input| {
            required += input.sigs_required;
            signed += @intCast(@min(input.partial_sigs.items.len, input.sigs_required));
        }
        return .{ .signed = signed, .required = required };
    }

    /// Serialize to bytes (simplified format)
    pub fn serialize(self: *const PSBT_TX, allocator: std.mem.Allocator) ![]u8 {
        var buf = std.ArrayList(u8).empty;
        // Magic + separator
        try buf.appendSlice(allocator, &PSBT_MAGIC);
        try buf.append(allocator, PSBT_SEPARATOR);
        // Role byte
        try buf.append(allocator, @intFromEnum(self.role));
        // Number of inputs
        try buf.append(allocator, @intCast(self.inputs.items.len));
        // Per-input: num sigs + each sig (33+64 bytes)
        for (self.inputs.items) |input| {
            try buf.append(allocator, @intCast(input.partial_sigs.items.len));
            for (input.partial_sigs.items) |ps| {
                try buf.appendSlice(allocator, &ps.pubkey);
                try buf.appendSlice(allocator, &ps.signature);
            }
        }
        return buf.toOwnedSlice(allocator);
    }
};

// ─── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

test "PSBT — create unsigned" {
    const tx = Transaction{
        .id = 1, .from_address = "ob1qtest", .to_address = "ob1qrecv",
        .amount = 1000, .fee = 10, .timestamp = 1700000000,
        .signature = "", .hash = "",
    };
    var psbt = try PSBT_TX.create(tx, 1, testing.allocator);
    defer psbt.deinit();

    try testing.expectEqual(PSBTRole.unsigned, psbt.role);
    try testing.expect(!psbt.isComplete());
    const progress = psbt.getProgress();
    try testing.expectEqual(@as(u32, 0), progress.signed);
    try testing.expectEqual(@as(u32, 1), progress.required);
}

test "PSBT — sign and finalize" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const tx = Transaction{
        .id = 42, .from_address = "ob1qsender", .to_address = "ob1qrecv",
        .amount = 5000, .fee = 100, .timestamp = 1700000000,
        .signature = "", .hash = "",
    };
    var psbt = try PSBT_TX.create(tx, 1, testing.allocator);
    defer psbt.deinit();

    // Sign with a key
    const kp = try Secp256k1Crypto.generateKeyPair();
    try psbt.signInput(0, kp.private_key);

    try testing.expectEqual(PSBTRole.fully_signed, psbt.role);
    try testing.expect(psbt.isComplete());

    // Finalize
    const signed_tx = try psbt.finalize(arena.allocator());
    try testing.expect(signed_tx.signature.len > 0);
    try testing.expect(signed_tx.hash.len > 0);
}

test "PSBT — multisig 2-of-2" {
    const tx = Transaction{
        .id = 99, .from_address = "ob1qmulti", .to_address = "ob1qrecv",
        .amount = 10000, .fee = 50, .timestamp = 1700000000,
        .signature = "", .hash = "",
    };
    var psbt = try PSBT_TX.create(tx, 1, testing.allocator);
    defer psbt.deinit();

    // Set 2-of-2 requirement
    psbt.inputs.items[0].sigs_required = 2;

    const kp1 = try Secp256k1Crypto.generateKeyPair();
    const kp2 = try Secp256k1Crypto.generateKeyPair();

    // First signer
    try psbt.signInput(0, kp1.private_key);
    try testing.expectEqual(PSBTRole.partially_signed, psbt.role);
    try testing.expect(!psbt.isComplete());

    // Second signer
    try psbt.signInput(0, kp2.private_key);
    try testing.expectEqual(PSBTRole.fully_signed, psbt.role);
    try testing.expect(psbt.isComplete());

    const progress = psbt.getProgress();
    try testing.expectEqual(@as(u32, 2), progress.signed);
    try testing.expectEqual(@as(u32, 2), progress.required);
}

test "PSBT — duplicate signature rejected" {
    const tx = Transaction{
        .id = 1, .from_address = "ob1qtest", .to_address = "ob1qrecv",
        .amount = 1000, .fee = 10, .timestamp = 1700000000,
        .signature = "", .hash = "",
    };
    var psbt = try PSBT_TX.create(tx, 1, testing.allocator);
    defer psbt.deinit();

    const kp = try Secp256k1Crypto.generateKeyPair();
    try psbt.signInput(0, kp.private_key);
    // Same key again = error
    try testing.expectError(error.DuplicateSignature, psbt.signInput(0, kp.private_key));
}

test "PSBT — serialize produces valid header" {
    const tx = Transaction{
        .id = 1, .from_address = "ob1qtest", .to_address = "ob1qrecv",
        .amount = 1000, .fee = 10, .timestamp = 1700000000,
        .signature = "", .hash = "",
    };
    var psbt = try PSBT_TX.create(tx, 1, testing.allocator);
    defer psbt.deinit();

    const data = try psbt.serialize(testing.allocator);
    defer testing.allocator.free(data);

    try testing.expectEqualSlices(u8, &PSBT_MAGIC, data[0..4]);
    try testing.expectEqual(PSBT_SEPARATOR, data[4]);
}
