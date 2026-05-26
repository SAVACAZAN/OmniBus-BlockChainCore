//! SIGHASH flags implementation for OmniBus transaction signing
//! Supports Bitcoin-style signature hash types for flexible transaction signing

const std = @import("std");
const crypto = std.crypto;
const sha256 = crypto.hash.sha2.Sha256;
const allocator = std.mem.Allocator;

// ============================================================
// SIGHASH Types (BIP-143 compatible)
// ============================================================

/// SIGHASH flags as defined in Bitcoin protocol
pub const SighashType = packed struct(u8) {
    /// Type of sighash (ALL, NONE, SINGLE)
    type: SighashTypeEnum,
    /// ANYONECANPAY modifier
    anyone_can_pay: bool,
    
    pub fn fromByte(byte: u8) SighashType {
        return @bitCast(byte);
    }
    
    pub fn toByte(self: SighashType) u8 {
        return @bitCast(self);
    }
};

pub const SighashTypeEnum = enum(u3) {
    ALL = 0x01,
    NONE = 0x02,
    SINGLE = 0x03,
    
    pub fn toByte(self: SighashTypeEnum) u8 {
        return @intFromEnum(self);
    }
};

// Convenience constants
pub const SIGHASH_ALL: u8 = 0x01;
pub const SIGHASH_NONE: u8 = 0x02;
pub const SIGHASH_SINGLE: u8 = 0x03;
pub const SIGHASH_ANYONECANPAY: u8 = 0x80;
pub const SIGHASH_ALL_ANYONECANPAY: u8 = SIGHASH_ALL | SIGHASH_ANYONECANPAY;
pub const SIGHASH_NONE_ANYONECANPAY: u8 = SIGHASH_NONE | SIGHASH_ANYONECANPAY;
pub const SIGHASH_SINGLE_ANYONECANPAY: u8 = SIGHASH_SINGLE | SIGHASH_ANYONECANPAY;

// ============================================================
// Hash Preimage Construction
// ============================================================

pub const TxHasher = struct {
    allocator: Allocator,
    
    pub fn init(allocator: Allocator) TxHasher {
        return .{ .allocator = allocator };
    }
    
    /// Generate signature hash for a transaction input
    /// Supports different SIGHASH modes
    pub fn generateSigHash(
        self: *TxHasher,
        tx: *const Transaction,
        input_index: usize,
        sighash_type: u8,
        prevout_script: []const u8,
        amount: u64,
    ) ![32]u8 {
        const sighash = SighashType.fromByte(sighash_type);
        
        // ANYONECANPAY modifies the hash calculation
        if (sighash.anyone_can_pay) {
            return self.hashForAnyoneCanPay(tx, input_index, sighash.type, prevout_script, amount);
        } else {
            return self.hashForDefault(tx, input_index, sighash.type, prevout_script, amount);
        }
    }
    
    /// Standard hash (without ANYONECANPAY)
    fn hashForDefault(
        self: *TxHasher,
        tx: *const Transaction,
        input_index: usize,
        mode: SighashTypeEnum,
        prevout_script: []const u8,
        amount: u64,
    ) ![32]u8 {
        var hasher = sha256.init(.{});
        
        // Version (4 bytes)
        hasher.update(&std.mem.toBytes(tx.version));
        
        // Inputs count and inputs
        switch (mode) {
            .ALL => {
                // Hash all inputs
                const inputs_hash = self.hashInputs(tx);
                hasher.update(&inputs_hash);
            },
            .NONE, .SINGLE => {
                // For NONE/SINGLE, inputs after current are not signed
                const inputs_hash = self.hashInputsUpTo(tx, input_index);
                hasher.update(&inputs_hash);
            },
        }
        
        // Sequences
        switch (mode) {
            .ALL => {
                const sequences_hash = self.hashSequences(tx);
                hasher.update(&sequences_hash);
            },
            .NONE, .SINGLE => {
                const sequences_hash = self.hashSequencesUpTo(tx, input_index);
                hasher.update(&sequences_hash);
            },
        }
        
        // Current input's prevout (outpoint)
        const outpoint = tx.inputs[input_index].previous_outpoint;
        hasher.update(&outpoint.txid);
        hasher.update(&std.mem.toBytes(outpoint.index));
        
        // Prevout script
        const script_len = try std.leb.writeUnsignedLeb128(self.allocator, prevout_script.len);
        defer self.allocator.free(script_len);
        hasher.update(script_len);
        hasher.update(prevout_script);
        
        // Amount
        hasher.update(&std.mem.toBytes(amount));
        
        // Current input sequence
        hasher.update(&std.mem.toBytes(tx.inputs[input_index].sequence));
        
        // Outputs
        switch (mode) {
            .ALL => {
                const outputs_hash = self.hashOutputs(tx);
                hasher.update(&outputs_hash);
            },
            .NONE => {
                // No outputs signed
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
        
        // Locktime
        hasher.update(&std.mem.toBytes(tx.locktime));
        
        // SIGHASH type
        hasher.update(&[_]u8{sighash_type});
        
        var result: [32]u8 = undefined;
        hasher.final(&result);
        return result;
    }
    
    /// Hash with ANYONECANPAY modifier
    fn hashForAnyoneCanPay(
        self: *TxHasher,
        tx: *const Transaction,
        input_index: usize,
        mode: SighashTypeEnum,
        prevout_script: []const u8,
        amount: u64,
    ) ![32]u8 {
        var hasher = sha256.init(.{});
        
        // Version
        hasher.update(&std.mem.toBytes(tx.version));
        
        // ONLY the current input (ANYONECANPAY)
        const outpoint = tx.inputs[input_index].previous_outpoint;
        hasher.update(&outpoint.txid);
        hasher.update(&std.mem.toBytes(outpoint.index));
        
        // Prevout script
        const script_len = try std.leb.writeUnsignedLeb128(self.allocator, prevout_script.len);
        defer self.allocator.free(script_len);
        hasher.update(script_len);
        hasher.update(prevout_script);
        
        // Amount
        hasher.update(&std.mem.toBytes(amount));
        
        // Sequence
        hasher.update(&std.mem.toBytes(tx.inputs[input_index].sequence));
        
        // Outputs based on mode
        switch (mode) {
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
        
        // Locktime
        hasher.update(&std.mem.toBytes(tx.locktime));
        
        // SIGHASH type
        hasher.update(&[_]u8{@as(u8, @bitCast(SighashType.fromByte(mode.toByte())))});
        
        var result: [32]u8 = undefined;
        hasher.final(&result);
        return result;
    }
    
    // Helper hash functions
    fn hashInputs(self: *TxHasher, tx: *const Transaction) [32]u8 {
        var hasher = sha256.init(.{});
        for (tx.inputs) |input| {
            hasher.update(&input.previous_outpoint.txid);
            hasher.update(&std.mem.toBytes(input.previous_outpoint.index));
        }
        var result: [32]u8 = undefined;
        hasher.final(&result);
        return result;
    }
    
    fn hashInputsUpTo(self: *TxHasher, tx: *const Transaction, up_to: usize) [32]u8 {
        var hasher = sha256.init(.{});
        for (0..up_to + 1) |i| {
            const input = tx.inputs[i];
            hasher.update(&input.previous_outpoint.txid);
            hasher.update(&std.mem.toBytes(input.previous_outpoint.index));
        }
        var result: [32]u8 = undefined;
        hasher.final(&result);
        return result;
    }
    
    fn hashSequences(self: *TxHasher, tx: *const Transaction) [32]u8 {
        var hasher = sha256.init(.{});
        for (tx.inputs) |input| {
            hasher.update(&std.mem.toBytes(input.sequence));
        }
        var result: [32]u8 = undefined;
        hasher.final(&result);
        return result;
    }
    
    fn hashSequencesUpTo(self: *TxHasher, tx: *const Transaction, up_to: usize) [32]u8 {
        var hasher = sha256.init(.{});
        for (0..up_to + 1) |i| {
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
            const script_len = std.leb.writeUnsignedLeb128(self.allocator, output.script_pubkey.len) catch unreachable;
            defer self.allocator.free(script_len);
            hasher.update(script_len);
            hasher.update(output.script_pubkey);
        }
        var result: [32]u8 = undefined;
        hasher.final(&result);
        return result;
    }
    
    fn hashSingleOutput(self: *TxHasher, tx: *const Transaction, index: usize) [32]u8 {
        var hasher = sha256.init(.{});
        const output = tx.outputs[index];
        hasher.update(&std.mem.toBytes(output.amount));
        const script_len = std.leb.writeUnsignedLeb128(self.allocator, output.script_pubkey.len) catch unreachable;
        defer self.allocator.free(script_len);
        hasher.update(script_len);
        hasher.update(output.script_pubkey);
        var result: [32]u8 = undefined;
        hasher.final(&result);
        return result;
    }
};

// ============================================================
// Transaction types (simplified for sighash)
// ============================================================

pub const OutPoint = struct {
    txid: [32]u8,
    index: u32,
};

pub const TxInput = struct {
    previous_outpoint: OutPoint,
    script_sig: []u8,
    sequence: u32,
    witness: ?[][]u8,
};

pub const TxOutput = struct {
    amount: u64,
    script_pubkey: []u8,
};

pub const Transaction = struct {
    version: i32,
    inputs: []TxInput,
    outputs: []TxOutput,
    locktime: u32,
};

// ============================================================
// Tests
// ============================================================

test "SighashType from/to byte" {
    const sighash = SighashType.fromByte(SIGHASH_ALL);
    try std.testing.expect(sighash.type == .ALL);
    try std.testing.expect(!sighash.anyone_can_pay);
    try std.testing.expect(sighash.toByte() == SIGHASH_ALL);
    
    const sighash_acp = SighashType.fromByte(SIGHASH_ALL_ANYONECANPAY);
    try std.testing.expect(sighash_acp.type == .ALL);
    try std.testing.expect(sighash_acp.anyone_can_pay);
}

test "Sighash constants correct" {
    try std.testing.expect(SIGHASH_ALL == 0x01);
    try std.testing.expect(SIGHASH_NONE == 0x02);
    try std.testing.expect(SIGHASH_SINGLE == 0x03);
    try std.testing.expect(SIGHASH_ANYONECANPAY == 0x80);
    try std.testing.expect(SIGHASH_ALL_ANYONECANPAY == 0x81);
}