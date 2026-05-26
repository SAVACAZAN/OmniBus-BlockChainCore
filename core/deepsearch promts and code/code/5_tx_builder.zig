//! Solana Transaction Builder

const std = @import("std");
const allocator = std.mem.Allocator;
const borsh = @import("borsh.zig");
const address = @import("address.zig");
const instruction = @import("instruction.zig");
const ed25519 = @import("ed25519.zig");

// ============================================================
// Transaction Types
// ============================================================

/// Transaction signature (64 bytes)
pub const Signature = [64]u8;

/// Message header
pub const MessageHeader = struct {
    num_required_signatures: u8,
    num_readonly_signed_accounts: u8,
    num_readonly_unsigned_accounts: u8,
};

/// Compiled instruction
pub const CompiledInstruction = struct {
    program_id_index: u8,
    accounts: []u8,  // Indices into account list
    data: []u8,
    
    pub fn deinit(self: *CompiledInstruction) void {
        allocator.free(self.accounts);
        allocator.free(self.data);
    }
};

/// Transaction message
pub const Message = struct {
    header: MessageHeader,
    account_keys: []address.SolanaAddress,
    recent_blockhash: [32]u8,
    instructions: []CompiledInstruction,
    
    pub fn deinit(self: *Message) void {
        allocator.free(self.account_keys);
        for (self.instructions) |*inst| {
            inst.deinit();
        }
        allocator.free(self.instructions);
    }
    
    /// Serialize message for signing
    pub fn serialize(self: *const Message) ![]u8 {
        var writer = borsh.BorshWriter.init(allocator);
        defer writer.deinit();
        
        // Header
        try borsh.BorshSerialize.serialize(self.header.num_required_signatures, writer);
        try borsh.BorshSerialize.serialize(self.header.num_readonly_signed_accounts, writer);
        try borsh.BorshSerialize.serialize(self.header.num_readonly_unsigned_accounts, writer);
        
        // Account keys
        try borsh.BorshSerialize.serialize(@as(u32, @intCast(self.account_keys.len)), writer);
        for (self.account_keys) |key| {
            try borsh.BorshSerialize.serialize(key, writer);
        }
        
        // Recent blockhash
        try writer.writeAll(&self.recent_blockhash);
        
        // Instructions
        try borsh.BorshSerialize.serialize(@as(u32, @intCast(self.instructions.len)), writer);
        for (self.instructions) |inst| {
            try borsh.BorshSerialize.serialize(inst.program_id_index, writer);
            try borsh.BorshSerialize.serialize(@as(u32, @intCast(inst.accounts.len)), writer);
            try writer.writeAll(inst.accounts);
            try borsh.BorshSerialize.serialize(@as(u32, @intCast(inst.data.len)), writer);
            try writer.writeAll(inst.data);
        }
        
        return try writer.toBytes();
    }
};

/// Versioned transaction (current standard)
pub const VersionedTransaction = struct {
    signatures: []Signature,
    message: Message,
    
    pub fn deinit(self: *VersionedTransaction) void {
        allocator.free(self.signatures);
        self.message.deinit();
    }
    
    /// Serialize transaction for broadcast
    pub fn serialize(self: *const VersionedTransaction) ![]u8 {
        var writer = borsh.BorshWriter.init(allocator);
        defer writer.deinit();
        
        // Version prefix (0x80 for versioned)
        try writer.writeByte(0x80);
        
        // Signatures
        try borsh.BorshSerialize.serialize(@as(u32, @intCast(self.signatures.len)), writer);
        for (self.signatures) |sig| {
            try writer.writeAll(&sig);
        }
        
        // Message
        const message_bytes = try self.message.serialize();
        defer allocator.free(message_bytes);
        try writer.writeAll(message_bytes);
        
        return try writer.toBytes();
    }
};

// ============================================================
// Transaction Builder
// ============================================================

pub const TxBuilder = struct {
    allocator: Allocator,
    signer: ed25519.SolanaEd25519,
    fee_payer: address.SolanaAddress,
    recent_blockhash: ?[32]u8,
    instructions: std.ArrayList(instruction.Instruction),
    
    pub fn init(allocator: Allocator, fee_payer: address.SolanaAddress) TxBuilder {
        return .{
            .allocator = allocator,
            .signer = ed25519.SolanaEd25519.init(allocator),
            .fee_payer = fee_payer,
            .recent_blockhash = null,
            .instructions = std.ArrayList(instruction.Instruction).init(allocator),
        };
    }
    
    pub fn deinit(self: *TxBuilder) void {
        for (self.instructions.items) |*inst| {
            inst.deinit();
        }
        self.instructions.deinit();
    }
    
    /// Add an instruction to the transaction
    pub fn addInstruction(self: *TxBuilder, inst: instruction.Instruction) !void {
        try self.instructions.append(inst);
    }
    
    /// Add multiple instructions
    pub fn addInstructions(self: *TxBuilder, insts: []const instruction.Instruction) !void {
        for (insts) |inst| {
            try self.addInstruction(inst);
        }
    }
    
    /// Set recent blockhash (required for transaction)
    pub fn setRecentBlockhash(self: *TxBuilder, blockhash: [32]u8) void {
        self.recent_blockhash = blockhash;
    }
    
    /// Build unsigned message
    pub fn buildMessage(self: *TxBuilder) !Message {
        const recent_blockhash = self.recent_blockhash orelse return error.MissingBlockhash;
        
        // Collect all unique account keys
        var account_map = std.AutoHashMap(address.SolanaAddress, AccountInfo).init(self.allocator);
        defer account_map.deinit();
        
        // Add fee payer as signer and writable
        try account_map.put(self.fee_payer, AccountInfo{
            .is_signer = true,
            .is_writable = true,
            .index = 0,
        });
        
        // Process all instructions
        for (self.instructions.items) |inst| {
            // Add program ID
            try account_map.put(inst.program_id, AccountInfo{
                .is_signer = false,
                .is_writable = false,
                .index = 0,
            });
            
            // Add accounts
            for (inst.accounts) |acc| {
                try account_map.put(acc.pubkey, AccountInfo{
                    .is_signer = acc.is_signer,
                    .is_writable = acc.is_writable,
                    .index = 0,
                });
            }
        }
        
        // Build account list
        var accounts = std.ArrayList(address.SolanaAddress).init(self.allocator);
        defer accounts.deinit();
        
        // First: signers
        var it = account_map.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.is_signer) {
                entry.value_ptr.index = @as(u8, @intCast(accounts.items.len));
                try accounts.append(entry.key_ptr.*);
            }
        }
        
        // Then: non-signers
        it.reset();
        while (it.next()) |entry| {
            if (!entry.value_ptr.is_signer) {
                entry.value_ptr.index = @as(u8, @intCast(accounts.items.len));
                try accounts.append(entry.key_ptr.*);
            }
        }
        
        // Calculate header
        var num_signers: u8 = 0;
        var num_readonly_signers: u8 = 0;
        var num_readonly_non_signers: u8 = 0;
        
        for (accounts.items, 0..) |acc, i| {
            const info = account_map.get(acc).?;
            if (info.is_signer) {
                num_signers += 1;
                if (!info.is_writable) num_readonly_signers += 1;
            } else {
                if (!info.is_writable) num_readonly_non_signers += 1;
            }
        }
        
        // Build compiled instructions
        var compiled = std.ArrayList(CompiledInstruction).init(self.allocator);
        defer compiled.deinit();
        
        for (self.instructions.items) |inst| {
            // Find program ID index
            const program_id_index = account_map.get(inst.program_id).?.index;
            
            // Build account indices
            var account_indices = std.ArrayList(u8).init(self.allocator);
            defer account_indices.deinit();
            
            for (inst.accounts) |acc| {
                const idx = account_map.get(acc.pubkey).?.index;
                try account_indices.append(idx);
            }
            
            compiled.append(CompiledInstruction{
                .program_id_index = program_id_index,
                .accounts = try account_indices.toOwnedSlice(),
                .data = try self.allocator.dupe(u8, inst.data),
            }) catch unreachable;
        }
        
        return Message{
            .header = MessageHeader{
                .num_required_signatures = num_signers,
                .num_readonly_signed_accounts = num_readonly_signers,
                .num_readonly_unsigned_accounts = num_readonly_non_signers,
            },
            .account_keys = try accounts.toOwnedSlice(),
            .recent_blockhash = recent_blockhash,
            .instructions = try compiled.toOwnedSlice(),
        };
    }
    
    /// Build and sign transaction
    pub fn buildSigned(
        self: *TxBuilder,
        private_key: ed25519.PrivateKey,
    ) !VersionedTransaction {
        const message = try self.buildMessage();
        defer message.deinit();
        
        const message_bytes = try message.serialize();
        defer self.allocator.free(message_bytes);
        
        // Sign message
        const signature = try self.signer.signTransaction(message_bytes, private_key);
        
        var signatures = try self.allocator.alloc(Signature, 1);
        signatures[0] = signature;
        
        return VersionedTransaction{
            .signatures = signatures,
            .message = message,
        };
    }
    
    /// Build and sign transaction with multiple signers
    pub fn buildSignedMulti(
        self: *TxBuilder,
        private_keys: []const ed25519.PrivateKey,
    ) !VersionedTransaction {
        const message = try self.buildMessage();
        defer message.deinit();
        
        const message_bytes = try message.serialize();
        defer self.allocator.free(message_bytes);
        
        var signatures = try self.allocator.alloc(Signature, private_keys.len);
        
        for (private_keys, 0..) |key, i| {
            signatures[i] = try self.signer.signTransaction(message_bytes, key);
        }
        
        return VersionedTransaction{
            .signatures = signatures,
            .message = message,
        };
    }
};

const AccountInfo = struct {
    is_signer: bool,
    is_writable: bool,
    index: u8,
};

// ============================================================
// Tests
// ============================================================

test "Transaction builder" {
    var builder = TxBuilder.init(std.testing.allocator, [_]u8{0x01} ** 32);
    defer builder.deinit();
    
    const blockhash = [_]u8{0xAA} ** 32;
    builder.setRecentBlockhash(blockhash);
    
    const message = try builder.buildMessage();
    defer message.deinit();
    
    try std.testing.expect(message.account_keys.len > 0);
    try std.testing.expectEqualSlices(u8, &blockhash, &message.recent_blockhash);
}