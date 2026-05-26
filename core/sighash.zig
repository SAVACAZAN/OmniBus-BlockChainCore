//! SIGHASH flags pentru OmniBus transaction signing.
//! BIP-143 compatible. Suporta SIGHASH_ALL/NONE/SINGLE + ANYONECANPAY modifier.
//!
//! Decuplat de core/transaction.zig prin tipuri locale (OutPoint/TxInput/TxOutput/Transaction)
//! ca sa permita signing pe orice format de TX care poate fi "mapat" la aceste struct-uri.

const std = @import("std");
const sha256 = std.crypto.hash.sha2.Sha256;
const Allocator = std.mem.Allocator;

pub const SIGHASH_ALL: u8 = 0x01;
pub const SIGHASH_NONE: u8 = 0x02;
pub const SIGHASH_SINGLE: u8 = 0x03;
pub const SIGHASH_ANYONECANPAY: u8 = 0x80;
pub const SIGHASH_ALL_ANYONECANPAY: u8 = SIGHASH_ALL | SIGHASH_ANYONECANPAY;
pub const SIGHASH_NONE_ANYONECANPAY: u8 = SIGHASH_NONE | SIGHASH_ANYONECANPAY;
pub const SIGHASH_SINGLE_ANYONECANPAY: u8 = SIGHASH_SINGLE | SIGHASH_ANYONECANPAY;

pub const SighashMode = enum(u8) {
    ALL = 0x01,
    NONE = 0x02,
    SINGLE = 0x03,
};

pub const SighashType = struct {
    mode: SighashMode,
    anyone_can_pay: bool,

    pub fn fromByte(byte: u8) !SighashType {
        const mode_byte: u8 = byte & 0x1F;
        const mode: SighashMode = switch (mode_byte) {
            0x01 => .ALL,
            0x02 => .NONE,
            0x03 => .SINGLE,
            else => return error.InvalidSighashMode,
        };
        return .{
            .mode = mode,
            .anyone_can_pay = (byte & SIGHASH_ANYONECANPAY) != 0,
        };
    }

    pub fn toByte(self: SighashType) u8 {
        var b: u8 = @intFromEnum(self.mode);
        if (self.anyone_can_pay) b |= SIGHASH_ANYONECANPAY;
        return b;
    }
};

pub const OutPoint = struct {
    txid: [32]u8,
    index: u32,
};

pub const TxInput = struct {
    previous_outpoint: OutPoint,
    script_sig: []const u8,
    sequence: u32,
    witness: ?[]const []const u8 = null,
};

pub const TxOutput = struct {
    amount: u64,
    script_pubkey: []const u8,
};

pub const Transaction = struct {
    version: i32,
    inputs: []const TxInput,
    outputs: []const TxOutput,
    locktime: u32,
};

pub const TxHasher = struct {
    allocator: Allocator,

    pub fn init(allocator: Allocator) TxHasher {
        return .{ .allocator = allocator };
    }

    pub fn generateSigHash(
        self: *TxHasher,
        tx: *const Transaction,
        input_index: usize,
        sighash_type_byte: u8,
        prevout_script: []const u8,
        amount: u64,
    ) ![32]u8 {
        if (input_index >= tx.inputs.len) return error.InputIndexOutOfRange;
        const stype = try SighashType.fromByte(sighash_type_byte);
        if (stype.anyone_can_pay) {
            return self.hashForAnyoneCanPay(tx, input_index, stype, prevout_script, amount);
        }
        return self.hashForDefault(tx, input_index, stype, prevout_script, amount);
    }

    fn hashForDefault(
        self: *TxHasher,
        tx: *const Transaction,
        input_index: usize,
        stype: SighashType,
        prevout_script: []const u8,
        amount: u64,
    ) ![32]u8 {
        var hasher = sha256.init(.{});

        hasher.update(&std.mem.toBytes(tx.version));

        switch (stype.mode) {
            .ALL => {
                const inputs_hash = self.hashInputs(tx);
                hasher.update(&inputs_hash);
                const seq_hash = self.hashSequences(tx);
                hasher.update(&seq_hash);
            },
            .NONE, .SINGLE => {
                const inputs_hash = self.hashInputsUpTo(tx, input_index);
                hasher.update(&inputs_hash);
                const seq_hash = self.hashSequencesUpTo(tx, input_index);
                hasher.update(&seq_hash);
            },
        }

        const outpoint = tx.inputs[input_index].previous_outpoint;
        hasher.update(&outpoint.txid);
        hasher.update(&std.mem.toBytes(outpoint.index));

        try writeVarInt(&hasher, prevout_script.len);
        hasher.update(prevout_script);

        hasher.update(&std.mem.toBytes(amount));
        hasher.update(&std.mem.toBytes(tx.inputs[input_index].sequence));

        switch (stype.mode) {
            .ALL => {
                const outputs_hash = self.hashOutputs(tx);
                hasher.update(&outputs_hash);
            },
            .NONE => {
                const empty_hash = [_]u8{0} ** 32;
                hasher.update(&empty_hash);
            },
            .SINGLE => {
                if (input_index < tx.outputs.len) {
                    const output_hash = self.hashSingleOutput(tx, input_index);
                    hasher.update(&output_hash);
                } else {
                    return error.InvalidSighashSingleOutputIndex;
                }
            },
        }

        hasher.update(&std.mem.toBytes(tx.locktime));
        hasher.update(&[_]u8{stype.toByte()});

        var result: [32]u8 = undefined;
        hasher.final(&result);
        return result;
    }

    fn hashForAnyoneCanPay(
        self: *TxHasher,
        tx: *const Transaction,
        input_index: usize,
        stype: SighashType,
        prevout_script: []const u8,
        amount: u64,
    ) ![32]u8 {
        var hasher = sha256.init(.{});

        hasher.update(&std.mem.toBytes(tx.version));

        const outpoint = tx.inputs[input_index].previous_outpoint;
        hasher.update(&outpoint.txid);
        hasher.update(&std.mem.toBytes(outpoint.index));

        try writeVarInt(&hasher, prevout_script.len);
        hasher.update(prevout_script);

        hasher.update(&std.mem.toBytes(amount));
        hasher.update(&std.mem.toBytes(tx.inputs[input_index].sequence));

        switch (stype.mode) {
            .ALL => {
                const outputs_hash = self.hashOutputs(tx);
                hasher.update(&outputs_hash);
            },
            .NONE => {
                const empty_hash = [_]u8{0} ** 32;
                hasher.update(&empty_hash);
            },
            .SINGLE => {
                if (input_index < tx.outputs.len) {
                    const output_hash = self.hashSingleOutput(tx, input_index);
                    hasher.update(&output_hash);
                } else {
                    return error.InvalidSighashSingleOutputIndex;
                }
            },
        }

        hasher.update(&std.mem.toBytes(tx.locktime));
        hasher.update(&[_]u8{stype.toByte()});

        var result: [32]u8 = undefined;
        hasher.final(&result);
        return result;
    }

    fn hashInputs(_: *TxHasher, tx: *const Transaction) [32]u8 {
        var hasher = sha256.init(.{});
        for (tx.inputs) |input| {
            hasher.update(&input.previous_outpoint.txid);
            hasher.update(&std.mem.toBytes(input.previous_outpoint.index));
        }
        var result: [32]u8 = undefined;
        hasher.final(&result);
        return result;
    }

    fn hashInputsUpTo(_: *TxHasher, tx: *const Transaction, up_to: usize) [32]u8 {
        var hasher = sha256.init(.{});
        var i: usize = 0;
        while (i <= up_to and i < tx.inputs.len) : (i += 1) {
            const input = tx.inputs[i];
            hasher.update(&input.previous_outpoint.txid);
            hasher.update(&std.mem.toBytes(input.previous_outpoint.index));
        }
        var result: [32]u8 = undefined;
        hasher.final(&result);
        return result;
    }

    fn hashSequences(_: *TxHasher, tx: *const Transaction) [32]u8 {
        var hasher = sha256.init(.{});
        for (tx.inputs) |input| {
            hasher.update(&std.mem.toBytes(input.sequence));
        }
        var result: [32]u8 = undefined;
        hasher.final(&result);
        return result;
    }

    fn hashSequencesUpTo(_: *TxHasher, tx: *const Transaction, up_to: usize) [32]u8 {
        var hasher = sha256.init(.{});
        var i: usize = 0;
        while (i <= up_to and i < tx.inputs.len) : (i += 1) {
            hasher.update(&std.mem.toBytes(tx.inputs[i].sequence));
        }
        var result: [32]u8 = undefined;
        hasher.final(&result);
        return result;
    }

    fn hashOutputs(self: *TxHasher, tx: *const Transaction) [32]u8 {
        var hasher = sha256.init(.{});
        for (tx.outputs) |output| {
            hasher.update(&std.mem.toBytes(output.amount));
            writeVarInt(&hasher, output.script_pubkey.len) catch {};
            hasher.update(output.script_pubkey);
        }
        var result: [32]u8 = undefined;
        hasher.final(&result);
        _ = self;
        return result;
    }

    fn hashSingleOutput(self: *TxHasher, tx: *const Transaction, index: usize) [32]u8 {
        var hasher = sha256.init(.{});
        const output = tx.outputs[index];
        hasher.update(&std.mem.toBytes(output.amount));
        writeVarInt(&hasher, output.script_pubkey.len) catch {};
        hasher.update(output.script_pubkey);
        var result: [32]u8 = undefined;
        hasher.final(&result);
        _ = self;
        return result;
    }
};

/// Bitcoin CompactSize / VarInt encoding scris direct in hasher.
fn writeVarInt(hasher: *sha256, n: usize) !void {
    if (n < 0xFD) {
        hasher.update(&[_]u8{@intCast(n)});
    } else if (n <= 0xFFFF) {
        hasher.update(&[_]u8{0xFD});
        hasher.update(&std.mem.toBytes(@as(u16, @intCast(n))));
    } else if (n <= 0xFFFFFFFF) {
        hasher.update(&[_]u8{0xFE});
        hasher.update(&std.mem.toBytes(@as(u32, @intCast(n))));
    } else {
        hasher.update(&[_]u8{0xFF});
        hasher.update(&std.mem.toBytes(@as(u64, @intCast(n))));
    }
}

// ============================================================
// Tests
// ============================================================

test "SighashType from/to byte" {
    const s = try SighashType.fromByte(SIGHASH_ALL);
    try std.testing.expect(s.mode == .ALL);
    try std.testing.expect(!s.anyone_can_pay);
    try std.testing.expect(s.toByte() == SIGHASH_ALL);

    const s_acp = try SighashType.fromByte(SIGHASH_ALL_ANYONECANPAY);
    try std.testing.expect(s_acp.mode == .ALL);
    try std.testing.expect(s_acp.anyone_can_pay);
    try std.testing.expect(s_acp.toByte() == SIGHASH_ALL_ANYONECANPAY);
}

test "Sighash constants" {
    try std.testing.expect(SIGHASH_ALL == 0x01);
    try std.testing.expect(SIGHASH_NONE == 0x02);
    try std.testing.expect(SIGHASH_SINGLE == 0x03);
    try std.testing.expect(SIGHASH_ANYONECANPAY == 0x80);
    try std.testing.expect(SIGHASH_ALL_ANYONECANPAY == 0x81);
    try std.testing.expect(SIGHASH_NONE_ANYONECANPAY == 0x82);
    try std.testing.expect(SIGHASH_SINGLE_ANYONECANPAY == 0x83);
}

test "Sighash invalid mode byte" {
    try std.testing.expectError(error.InvalidSighashMode, SighashType.fromByte(0x00));
    try std.testing.expectError(error.InvalidSighashMode, SighashType.fromByte(0x04));
}

test "Sighash generates hash for ALL" {
    const allocator = std.testing.allocator;
    var hasher = TxHasher.init(allocator);

    const inputs = [_]TxInput{
        .{
            .previous_outpoint = .{ .txid = [_]u8{0x01} ** 32, .index = 0 },
            .script_sig = &[_]u8{},
            .sequence = 0xFFFFFFFF,
        },
    };
    const outputs = [_]TxOutput{
        .{ .amount = 50_000_000, .script_pubkey = &[_]u8{ 0x76, 0xA9 } },
    };
    const tx = Transaction{
        .version = 2,
        .inputs = &inputs,
        .outputs = &outputs,
        .locktime = 0,
    };

    const prevout_script = [_]u8{ 0x76, 0xA9, 0x14 };
    const h = try hasher.generateSigHash(&tx, 0, SIGHASH_ALL, &prevout_script, 100_000_000);
    try std.testing.expect(h.len == 32);
}

test "Sighash SINGLE rejects when output index out of range" {
    const allocator = std.testing.allocator;
    var hasher = TxHasher.init(allocator);

    const inputs = [_]TxInput{
        .{ .previous_outpoint = .{ .txid = [_]u8{0} ** 32, .index = 0 }, .script_sig = &[_]u8{}, .sequence = 0 },
        .{ .previous_outpoint = .{ .txid = [_]u8{0} ** 32, .index = 1 }, .script_sig = &[_]u8{}, .sequence = 0 },
    };
    const outputs = [_]TxOutput{
        .{ .amount = 1, .script_pubkey = &[_]u8{} },
    }; // only 1 output, but 2 inputs → SINGLE on input 1 must fail
    const tx = Transaction{ .version = 2, .inputs = &inputs, .outputs = &outputs, .locktime = 0 };

    try std.testing.expectError(
        error.InvalidSighashSingleOutputIndex,
        hasher.generateSigHash(&tx, 1, SIGHASH_SINGLE, &[_]u8{}, 100),
    );
}
