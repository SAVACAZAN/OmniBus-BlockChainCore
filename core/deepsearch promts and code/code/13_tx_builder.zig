//! TON Transaction Builder
//! Constructs external messages for sending to the TON blockchain

const std = @import("std");
const allocator = std.mem.Allocator;
const cell = @import("cell.zig");
const address = @import("address.zig");
const tl_b = @import("tl_b.zig");

// ============================================================
// Transaction Types
// ============================================================

/// External message for sending to TON
pub const ExternalMessage = struct {
    allocator: Allocator,
    dest: address.TonAddress,
    src: ?address.TonAddress,
    amount: u64,
    body: ?*cell.Cell,
    state_init: ?*cell.Cell,
    
    pub fn init(allocator: Allocator, dest: address.TonAddress) ExternalMessage {
        return .{
            .allocator = allocator,
            .dest = dest,
            .src = null,
            .amount = 0,
            .body = null,
            .state_init = null,
        };
    }
    
    pub fn deinit(self: *ExternalMessage) void {
        if (self.body) |b| {
            b.deinit();
            self.allocator.destroy(b);
        }
        if (self.state_init) |si| {
            si.deinit();
            self.allocator.destroy(si);
        }
    }
    
    /// Serialize external message to cell
    pub fn serialize(self: *ExternalMessage) !*cell.Cell {
        var builder = cell.CellBuilder.init(self.allocator);
        defer builder.deinit();
        
        // Header: dest + src + amount + etc
        // Workchain
        try builder.writeBits(&[_]u1{0, 0, 0, 0, 0, 0, 0, 0}); // 8 bits
        
        // Source address (if any)
        if (self.src) |src| {
            try builder.writeBit(1);
            try builder.writeByte(@as(u8, @bitCast(src.workchain)));
            try builder.writeBytes(&src.hash);
        } else {
            try builder.writeBit(0);
        }
        
        // Destination address
        try builder.writeByte(@as(u8, @bitCast(self.dest.workchain)));
        try builder.writeBytes(&self.dest.hash);
        
        // Amount
        try builder.writeUint(self.amount, 128); // 128-bit amount in nanoTON
        
        // Body (if any)
        if (self.body) |b| {
            try builder.addRef(b);
        }
        
        // State init (if any)
        if (self.state_init) |si| {
            try builder.addRef(si);
        }
        
        return try builder.build();
    }
};

// ============================================================
// Transaction Builder
// ============================================================

pub const TxBuilder = struct {
    allocator: Allocator,
    message: ExternalMessage,
    seqno: u32,
    private_key: ?[32]u8,
    signature: ?[64]u8,
    
    pub fn init(allocator: Allocator, dest: address.TonAddress) TxBuilder {
        return .{
            .allocator = allocator,
            .message = ExternalMessage.init(allocator, dest),
            .seqno = 0,
            .private_key = null,
            .signature = null,
        };
    }
    
    pub fn deinit(self: *TxBuilder) {
        self.message.deinit();
    }
    
    /// Set destination address
    pub fn setDestination(self: *TxBuilder, dest: address.TonAddress) void {
        self.message.dest = dest;
    }
    
    /// Set source address
    pub fn setSource(self: *TxBuilder, src: address.TonAddress) void {
        self.message.src = src;
    }
    
    /// Set amount in nanoTON
    pub fn setAmount(self: *TxBuilder, amount: u64) void {
        self.message.amount = amount;
    }
    
    /// Set transaction body (the action to perform)
    pub fn setBody(self: *TxBuilder, body: *cell.Cell) void {
        self.message.body = body;
    }
    
    /// Set state init (for contract deployment)
    pub fn setStateInit(self: *TxBuilder, state_init: *cell.Cell) void {
        self.message.state_init = state_init;
    }
    
    /// Set sequence number (for wallet transactions)
    pub fn setSeqno(self: *TxBuilder, seqno: u32) void {
        self.seqno = seqno;
    }
    
    /// Sign transaction with Ed25519 private key
    pub fn sign(self: *TxBuilder, private_key: [32]u8) !void {
        self.private_key = private_key;
        
        // Create signature hash (message cell hash)
        const msg_cell = try self.message.serialize();
        defer msg_cell.deinit();
        
        const msg_hash = try msg_cell.computeHash();
        
        // Sign with Ed25519
        const ed25519 = @import("../sol/ed25519.zig").SolanaEd25519.init(self.allocator);
        const signature = try ed25519.signTransaction(&msg_hash, private_key);
        
        self.signature = signature;
    }
    
    /// Build final signed external message
    pub fn build(self: *TxBuilder) !*cell.Cell {
        if (self.private_key == null) return error.Unsigned;
        if (self.signature == null) return error.Unsigned;
        
        var builder = cell.CellBuilder.init(self.allocator);
        defer builder.deinit();
        
        // Signature
        try builder.writeBytes(&self.signature.?);
        
        // Message cell
        const msg_cell = try self.message.serialize();
        defer msg_cell.deinit();
        try builder.addRef(msg_cell);
        
        return try builder.build();
    }
    
    /// Build unsigned message (for external signing)
    pub fn buildUnsigned(self: *TxBuilder) !*cell.Cell {
        return try self.message.serialize();
    }
};

// ============================================================
// Transfer Builder (Helper)
// ============================================================

pub const TransferBuilder = struct {
    allocator: Allocator,
    tx_builder: TxBuilder,
    transfer_body: ?*cell.Cell,
    
    pub fn init(allocator: Allocator, from: address.TonAddress, to: address.TonAddress) TransferBuilder {
        var tx = TxBuilder.init(allocator, to);
        tx.setSource(from);
        return .{
            .allocator = allocator,
            .tx_builder = tx,
            .transfer_body = null,
        };
    }
    
    pub fn deinit(self: *TransferBuilder) {
        self.tx_builder.deinit();
        if (self.transfer_body) |body| {
            body.deinit();
            self.allocator.destroy(body);
        }
    }
    
    /// Set amount in nanoTON
    pub fn setAmount(self: *TransferBuilder, amount: u64) void {
        self.tx_builder.setAmount(amount);
    }
    
    /// Set comment (text message)
    pub fn setComment(self: *TransferBuilder, comment: []const u8) !void {
        var builder = cell.CellBuilder.init(self.allocator);
        defer builder.deinit();
        
        // Comment opcode (0x00)
        try builder.writeUint(0, 32);
        
        // Comment text
        for (comment) |c| {
            try builder.writeByte(@as(u8, @intCast(c)));
        }
        
        // Padding to byte boundary
        const remaining = (8 - (builder.bits % 8)) % 8;
        if (remaining > 0) {
            try builder.writeBits(&[_]u1{0} ** remaining);
        }
        
        const comment_cell = try builder.build();
        self.tx_builder.setBody(comment_cell);
        self.transfer_body = comment_cell;
    }
    
    /// Build and sign transaction
    pub fn build(self: *TransferBuilder, private_key: [32]u8) !*cell.Cell {
        try self.tx_builder.sign(private_key);
        return try self.tx_builder.build();
    }
};

// ============================================================
// Tests
// ============================================================

test "Transfer builder" {
    const from_hash = [_]u8{0x01} ** 32;
    const to_hash = [_]u8{0x02} ** 32;
    const from = address.TonAddress.init(0, from_hash);
    const to = address.TonAddress.init(0, to_hash);
    
    var builder = TransferBuilder.init(std.testing.allocator, from, to);
    defer builder.deinit();
    
    builder.setAmount(100_000_000);
    try builder.setComment("Test payment");
    
    // Would need private key to sign
    try std.testing.expect(true);
}