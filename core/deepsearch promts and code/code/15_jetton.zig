//! TON Jetton (Token) Support
//! Jettons are TON's native token standard (similar to ERC-20)

const std = @import("std");
const allocator = std.mem.Allocator;
const cell = @import("cell.zig");
const address = @import("address.zig");
const contract = @import("contract.zig");

// ============================================================
// Jetton Types
// ============================================================

pub const JettonMetadata = struct {
    name: []u8,
    symbol: []u8,
    decimals: u8,
    uri: ?[]u8 = null,
    
    pub fn deinit(self: *JettonMetadata) void {
        allocator.free(self.name);
        allocator.free(self.symbol);
        if (self.uri) |u| allocator.free(u);
    }
};

pub const JettonData = struct {
    total_supply: u256,
    mintable: bool,
    admin: address.TonAddress,
    metadata: JettonMetadata,
    
    pub fn deinit(self: *JettonData) void {
        self.metadata.deinit();
    }
};

pub const JettonWalletData = struct {
    balance: u256,
    owner: address.TonAddress,
    minter: address.TonAddress,
    wallet_id: u32,
};

// ============================================================
// Jetton Operation Types (TL-B schemas)
// ============================================================

const JettonOp = struct {
    pub const TRANSFER: u32 = 0x0f8a7ea5;
    pub const TRANSFER_NOTIFICATION: u32 = 0x7362d09c;
    pub const BURN: u32 = 0x595f07bc;
    pub const BURN_NOTIFICATION: u32 = 0x7bdd97de;
    pub const MINT: u32 = 0x642b7d07;
    pub const INTERNAL_TRANSFER: u32 = 0x178d4519;
};

// ============================================================
// Jetton Minter Contract
// ============================================================

pub const JettonMinter = struct {
    allocator: Allocator,
    address: address.TonAddress,
    data: JettonData,
    
    pub fn init(allocator: Allocator, address: address.TonAddress, data: JettonData) JettonMinter {
        return .{
            .allocator = allocator,
            .address = address,
            .data = data,
        };
    }
    
    pub fn deinit(self: *JettonMinter) void {
        self.data.deinit();
    }
    
    /// Create mint message (owner sends to minter to create new tokens)
    pub fn createMintMessage(
        self: *JettonMinter,
        to: address.TonAddress,
        amount: u256,
        response_address: ?address.TonAddress,
    ) !*cell.Cell {
        var builder = cell.CellBuilder.init(self.allocator);
        defer builder.deinit();
        
        // Operation: mint
        try builder.writeUint(JettonOp.MINT, 32);
        
        // Query ID (0 for now)
        try builder.writeUint(0, 64);
        
        // Amount
        try builder.writeUint(amount, 256);
        
        // Destination address
        try builder.writeByte(@as(u8, @bitCast(to.workchain)));
        try builder.writeBytes(&to.hash);
        
        // Response address (if any)
        if (response_address) |resp| {
            try builder.writeBit(1);
            try builder.writeByte(@as(u8, @bitCast(resp.workchain)));
            try builder.writeBytes(&resp.hash);
        } else {
            try builder.writeBit(0);
        }
        
        return try builder.build();
    }
    
    /// Create deploy jetton wallet message
    pub fn createDeployWalletMessage(
        self: *JettonMinter,
        owner: address.TonAddress,
    ) !*cell.Cell {
        var builder = cell.CellBuilder.init(self.allocator);
        defer builder.deinit();
        
        // Provide wallet address (not needed for deploy message)
        try builder.writeUint(0, 32); // op: deploy wallet
        
        // Owner address
        try builder.writeByte(@as(u8, @bitCast(owner.workchain)));
        try builder.writeBytes(&owner.hash);
        
        return try builder.build();
    }
    
    /// Get jetton data from on-chain (via run method)
    pub fn fetchData(self: *JettonMinter, rpc_client: anytype) !JettonData {
        const result = try rpc_client.runGetMethod(self.address, "get_jetton_data", &.{});
        defer result.deinit();
        
        if (result.stack.len >= 4) {
            const total_supply = if (result.stack[0].value == .int) result.stack[0].value.int else 0;
            const mintable = if (result.stack[1].value == .int) result.stack[1].value.int != 0 else false;
            // Parse admin address and metadata
            _ = mintable;
            
            return self.data;
        }
        
        return self.data;
    }
};

// ============================================================
// Jetton Wallet Contract
// ============================================================

pub const JettonWallet = struct {
    allocator: Allocator,
    address: address.TonAddress,
    data: JettonWalletData,
    
    pub fn init(allocator: Allocator, address: address.TonAddress, data: JettonWalletData) JettonWallet {
        return .{
            .allocator = allocator,
            .address = address,
            .data = data,
        };
    }
    
    /// Create transfer message
    pub fn createTransferMessage(
        self: *JettonWallet,
        dest: address.TonAddress,
        amount: u256,
        response_address: ?address.TonAddress,
        custom_payload: ?*cell.Cell,
    ) !*cell.Cell {
        var builder = cell.CellBuilder.init(self.allocator);
        defer builder.deinit();
        
        // Operation: transfer
        try builder.writeUint(JettonOp.TRANSFER, 32);
        
        // Query ID
        try builder.writeUint(0, 64);
        
        // Amount
        try builder.writeUint(amount, 256);
        
        // Destination address
        try builder.writeByte(@as(u8, @bitCast(dest.workchain)));
        try builder.writeBytes(&dest.hash);
        
        // Response destination
        if (response_address) |resp| {
            try builder.writeBit(1);
            try builder.writeByte(@as(u8, @bitCast(resp.workchain)));
            try builder.writeBytes(&resp.hash);
        } else {
            try builder.writeBit(0);
        }
        
        // Custom payload
        if (custom_payload) |payload| {
            try builder.writeBit(1);
            try builder.addRef(payload);
        } else {
            try builder.writeBit(0);
        }
        
        // Forward amount (for messages with value)
        try builder.writeUint(0, 128);
        
        // Forward payload (none)
        try builder.writeBit(0);
        
        return try builder.build();
    }
    
    /// Create burn message
    pub fn createBurnMessage(
        self: *JettonWallet,
        amount: u256,
        response_address: ?address.TonAddress,
    ) !*cell.Cell {
        var builder = cell.CellBuilder.init(self.allocator);
        defer builder.deinit();
        
        // Operation: burn
        try builder.writeUint(JettonOp.BURN, 32);
        
        // Query ID
        try builder.writeUint(0, 64);
        
        // Amount
        try builder.writeUint(amount, 256);
        
        // Response address
        if (response_address) |resp| {
            try builder.writeBit(1);
            try builder.writeByte(@as(u8, @bitCast(resp.workchain)));
            try builder.writeBytes(&resp.hash);
        } else {
            try builder.writeBit(0);
        }
        
        return try builder.build();
    }
    
    /// Get jetton wallet data from on-chain
    pub fn fetchData(self: *JettonWallet, rpc_client: anytype) !JettonWalletData {
        const result = try rpc_client.runGetMethod(self.address, "get_wallet_data", &.{});
        defer result.deinit();
        
        if (result.stack.len >= 4) {
            const balance = if (result.stack[0].value == .int) result.stack[0].value.int else 0;
            // Parse owner and minter addresses
            _ = balance;
            
            return self.data;
        }
        
        return self.data;
    }
    
    /// Get balance
    pub fn getBalance(self: *JettonWallet, rpc_client: anytype) !u256 {
        const data = try self.fetchData(rpc_client);
        return data.balance;
    }
};

// ============================================================
// Jetton Address Helper
// ============================================================

pub const JettonAddressHelper = struct {
    allocator: Allocator,
    
    pub fn init(allocator: Allocator) JettonAddressHelper {
        return .{ .allocator = allocator };
    }
    
    /// Compute jetton wallet address from owner and minter
    pub fn computeWalletAddress(
        self: *JettonAddressHelper,
        owner: address.TonAddress,
        minter: address.TonAddress,
    ) !address.TonAddress {
        _ = self;
        _ = owner;
        _ = minter;
        // Compute from state init
        var hash: [32]u8 = undefined;
        @memset(&hash, 0);
        return address.TonAddress.init(0, hash);
    }
    
    /// Validate jetton wallet address
    pub fn validateWalletAddress(
        self: *JettonAddressHelper,
        wallet: address.TonAddress,
        owner: address.TonAddress,
        minter: address.TonAddress,
    ) bool {
        const computed = self.computeWalletAddress(owner, minter) catch return false;
        return std.mem.eql(u8, &wallet.hash, &computed.hash) and wallet.workchain == computed.workchain;
    }
};

// ============================================================
// Tests
// ============================================================

test "Jetton transfer message creation" {
    const owner_hash = [_]u8{0x01} ** 32;
    const minter_hash = [_]u8{0x02} ** 32;
    const dest_hash = [_]u8{0x03} ** 32;
    
    const owner = address.TonAddress.init(0, owner_hash);
    const minter = address.TonAddress.init(0, minter_hash);
    const dest = address.TonAddress.init(0, dest_hash);
    
    const wallet_data = JettonWalletData{
        .balance = 1000,
        .owner = owner,
        .minter = minter,
        .wallet_id = 1,
    };
    
    const wallet = JettonWallet.init(std.testing.allocator, owner, wallet_data);
    
    const transfer_msg = try wallet.createTransferMessage(dest, 100, null, null);
    defer transfer_msg.deinit();
    
    try std.testing.expect(transfer_msg.data.len > 0);
}