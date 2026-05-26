//! Solana Instruction Types and Builders

const std = @import("std");
const allocator = std.mem.Allocator;
const borsh = @import("borsh.zig");
const address = @import("address.zig");

// ============================================================
// Instruction Types
// ============================================================

/// Account meta for instruction
pub const AccountMeta = struct {
    pubkey: address.SolanaAddress,
    is_signer: bool,
    is_writable: bool,
};

/// Solana instruction
pub const Instruction = struct {
    program_id: address.SolanaAddress,
    accounts: []AccountMeta,
    data: []u8,
    
    pub fn deinit(self: *Instruction) void {
        allocator.free(self.accounts);
        allocator.free(self.data);
    }
    
    /// Serialize instruction for transaction
    pub fn serialize(self: *const Instruction) ![]u8 {
        var writer = borsh.BorshWriter.init(allocator);
        defer writer.deinit();
        
        // Program ID
        try borsh.BorshSerialize.serialize(self.program_id, writer);
        
        // Accounts count and accounts
        try borsh.BorshSerialize.serialize(@as(u32, @intCast(self.accounts.len)), writer);
        for (self.accounts) |account| {
            try borsh.BorshSerialize.serialize(account.pubkey, writer);
            try borsh.BorshSerialize.serialize(account.is_signer, writer);
            try borsh.BorshSerialize.serialize(account.is_writable, writer);
        }
        
        // Data
        try borsh.BorshSerialize.serialize(@as(u32, @intCast(self.data.len)), writer);
        try writer.writeAll(self.data);
        
        return try writer.toBytes();
    }
    
    /// Deserialize instruction from bytes
    pub fn deserialize(data: []const u8) !Instruction {
        var reader = borsh.BorshReader.init(data);
        
        const program_id = try borsh.BorshDeserialize.deserialize(address.SolanaAddress, &reader);
        const accounts_len = try borsh.BorshDeserialize.deserialize(u32, &reader);
        
        var accounts = try allocator.alloc(AccountMeta, accounts_len);
        errdefer allocator.free(accounts);
        
        for (0..accounts_len) |i| {
            accounts[i] = AccountMeta{
                .pubkey = try borsh.BorshDeserialize.deserialize(address.SolanaAddress, &reader),
                .is_signer = try borsh.BorshDeserialize.deserialize(bool, &reader),
                .is_writable = try borsh.BorshDeserialize.deserialize(bool, &reader),
            };
        }
        
        const data_len = try borsh.BorshDeserialize.deserialize(u32, &reader);
        var inst_data = try allocator.alloc(u8, data_len);
        errdefer allocator.free(inst_data);
        
        try reader.readNoEof(inst_data);
        
        return Instruction{
            .program_id = program_id,
            .accounts = accounts,
            .data = inst_data,
        };
    }
};

// ============================================================
// Instruction Builders (Common Programs)
// ============================================================

/// System Program Instructions
pub const SystemInstruction = struct {
    /// Transfer lamports
    pub fn transfer(
        from_pubkey: address.SolanaAddress,
        to_pubkey: address.SolanaAddress,
        lamports: u64,
    ) Instruction {
        const accounts = allocator.alloc(AccountMeta, 2) catch unreachable;
        accounts[0] = AccountMeta{
            .pubkey = from_pubkey,
            .is_signer = true,
            .is_writable = true,
        };
        accounts[1] = AccountMeta{
            .pubkey = to_pubkey,
            .is_signer = false,
            .is_writable = true,
        };
        
        // Transfer instruction data: discriminator(4) + lamports(8)
        var data = allocator.alloc(u8, 12) catch unreachable;
        // Instruction discriminator for transfer: 2
        std.mem.writeInt(u32, data[0..4], 2, .little);
        std.mem.writeInt(u64, data[4..12], lamports, .little);
        
        return Instruction{
            .program_id = address.SYSTEM_PROGRAM_ID,
            .accounts = accounts,
            .data = data,
        };
    }
    
    /// Create account
    pub fn createAccount(
        from_pubkey: address.SolanaAddress,
        new_account_pubkey: address.SolanaAddress,
        lamports: u64,
        space: u64,
        owner_program_id: address.SolanaAddress,
    ) Instruction {
        const accounts = allocator.alloc(AccountMeta, 2) catch unreachable;
        accounts[0] = AccountMeta{
            .pubkey = from_pubkey,
            .is_signer = true,
            .is_writable = true,
        };
        accounts[1] = AccountMeta{
            .pubkey = new_account_pubkey,
            .is_signer = true,
            .is_writable = true,
        };
        
        // Create account instruction data
        var data = allocator.alloc(u8, 4 + 8 + 8 + 32) catch unreachable;
        std.mem.writeInt(u32, data[0..4], 0, .little); // discriminator
        std.mem.writeInt(u64, data[4..12], lamports, .little);
        std.mem.writeInt(u64, data[12..20], space, .little);
        @memcpy(data[20..52], &owner_program_id);
        
        return Instruction{
            .program_id = address.SYSTEM_PROGRAM_ID,
            .accounts = accounts,
            .data = data,
        };
    }
};

/// Token Program Instructions (SPL Token)
pub const TokenInstruction = struct {
    /// Transfer tokens
    pub fn transfer(
        source: address.SolanaAddress,
        destination: address.SolanaAddress,
        authority: address.SolanaAddress,
        amount: u64,
    ) Instruction {
        const accounts = allocator.alloc(AccountMeta, 3) catch unreachable;
        accounts[0] = AccountMeta{
            .pubkey = source,
            .is_signer = false,
            .is_writable = true,
        };
        accounts[1] = AccountMeta{
            .pubkey = destination,
            .is_signer = false,
            .is_writable = true,
        };
        accounts[2] = AccountMeta{
            .pubkey = authority,
            .is_signer = true,
            .is_writable = false,
        };
        
        var data = allocator.alloc(u8, 12) catch unreachable;
        std.mem.writeInt(u32, data[0..4], 3, .little); // Transfer discriminator
        std.mem.writeInt(u64, data[4..12], amount, .little);
        
        return Instruction{
            .program_id = address.TOKEN_PROGRAM_ID,
            .accounts = accounts,
            .data = data,
        };
    }
    
    /// Mint tokens
    pub fn mintTo(
        mint: address.SolanaAddress,
        destination: address.SolanaAddress,
        authority: address.SolanaAddress,
        amount: u64,
    ) Instruction {
        const accounts = allocator.alloc(AccountMeta, 3) catch unreachable;
        accounts[0] = AccountMeta{
            .pubkey = mint,
            .is_signer = false,
            .is_writable = true,
        };
        accounts[1] = AccountMeta{
            .pubkey = destination,
            .is_signer = false,
            .is_writable = true,
        };
        accounts[2] = AccountMeta{
            .pubkey = authority,
            .is_signer = true,
            .is_writable = false,
        };
        
        var data = allocator.alloc(u8, 12) catch unreachable;
        std.mem.writeInt(u32, data[0..4], 7, .little); // MintTo discriminator
        std.mem.writeInt(u64, data[4..12], amount, .little);
        
        return Instruction{
            .program_id = address.TOKEN_PROGRAM_ID,
            .accounts = accounts,
            .data = data,
        };
    }
};

/// Associated Token Account Program
pub const AssociatedTokenInstruction = struct {
    /// Create associated token account
    pub fn create(
        funding_address: address.SolanaAddress,
        wallet_address: address.SolanaAddress,
        token_mint: address.SolanaAddress,
    ) Instruction {
        const accounts = allocator.alloc(AccountMeta, 6) catch unreachable;
        accounts[0] = AccountMeta{
            .pubkey = funding_address,
            .is_signer = true,
            .is_writable = true,
        };
        accounts[1] = AccountMeta{
            .pubkey = wallet_address,
            .is_signer = false,
            .is_writable = false,
        };
        accounts[2] = AccountMeta{
            .pubkey = token_mint,
            .is_signer = false,
            .is_writable = false,
        };
        
        // Associated token account address (PDA)
        const ata = address.findProgramAddress(
            &.{ &wallet_address, &address.TOKEN_PROGRAM_ID, &token_mint },
            address.ASSOCIATED_TOKEN_PROGRAM_ID,
        );
        accounts[3] = AccountMeta{
            .pubkey = ata.address,
            .is_signer = false,
            .is_writable = true,
        };
        
        accounts[4] = AccountMeta{
            .pubkey = address.SYSTEM_PROGRAM_ID,
            .is_signer = false,
            .is_writable = false,
        };
        accounts[5] = AccountMeta{
            .pubkey = address.TOKEN_PROGRAM_ID,
            .is_signer = false,
            .is_writable = false,
        };
        
        var data = allocator.alloc(u8, 4) catch unreachable;
        std.mem.writeInt(u32, data[0..4], 0, .little); // Create discriminator
        
        return Instruction{
            .program_id = address.ASSOCIATED_TOKEN_PROGRAM_ID,
            .accounts = accounts,
            .data = data,
        };
    }
};

// ============================================================
// Tests
// ============================================================

test "Instruction serialization" {
    const from = [_]u8{0x01} ** 32;
    const to = [_]u8{0x02} ** 32;
    
    const transfer_inst = SystemInstruction.transfer(from, to, 1000);
    defer transfer_inst.deinit();
    
    const serialized = try transfer_inst.serialize();
    defer allocator.free(serialized);
    
    const deserialized = try Instruction.deserialize(serialized);
    defer deserialized.deinit();
    
    try std.testing.expectEqualSlices(u8, &transfer_inst.program_id, &deserialized.program_id);
    try std.testing.expectEqual(transfer_inst.accounts.len, deserialized.accounts.len);
}