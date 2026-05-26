//! Solana Program Interaction (SPL Tokens, System Program, etc.)

const std = @import("std");
const allocator = std.mem.Allocator;
const address = @import("address.zig");
const instruction = @import("instruction.zig");
const tx_builder = @import("tx_builder.zig");
const rpc = @import("rpc_client.zig");

// ============================================================
// SPL Token Operations
// ============================================================

pub const SplToken = struct {
    allocator: Allocator,
    rpc_client: *rpc.SolanaRpcClient,
    token_mint: address.SolanaAddress,
    
    pub fn init(allocator: Allocator, rpc_client: *rpc.SolanaRpcClient, token_mint: address.SolanaAddress) SplToken {
        return .{
            .allocator = allocator,
            .rpc_client = rpc_client,
            .token_mint = token_mint,
        };
    }
    
    /// Get token info (supply, decimals)
    pub fn getInfo(self: *SplToken) !struct { supply: u64, decimals: u8 } {
        const supply = try self.rpc_client.getTokenSupply(self.token_mint);
        
        // Get decimals from any token account
        // Simplified - in production, query mint account directly
        const decimals: u8 = 9;
        
        return .{ .supply = supply, .decimals = decimals };
    }
    
    /// Create transfer instruction
    pub fn transfer(
        self: *SplToken,
        from: address.SolanaAddress,
        to: address.SolanaAddress,
        authority: address.SolanaAddress,
        amount: u64,
    ) instruction.Instruction {
        _ = self;
        return instruction.TokenInstruction.transfer(from, to, authority, amount);
    }
    
    /// Create mint instruction
    pub fn mintTo(
        self: *SplToken,
        destination: address.SolanaAddress,
        authority: address.SolanaAddress,
        amount: u64,
    ) instruction.Instruction {
        return instruction.TokenInstruction.mintTo(self.token_mint, destination, authority, amount);
    }
    
    /// Get token account balance
    pub fn getBalance(self: *SplToken, token_account: address.SolanaAddress) !u64 {
        const account_info = try self.rpc_client.getAccountInfo(token_account);
        defer account_info.deinit();
        
        // Parse token account data
        if (account_info.data.len >= 100) {
            // Token account layout: mint(32), owner(32), amount(8), etc.
            const amount = std.mem.readInt(u64, account_info.data[64..72], .little);
            return amount;
        }
        
        return 0;
    }
    
    /// Get associated token account address for a wallet
    pub fn getAssociatedTokenAccount(
        self: *SplToken,
        wallet: address.SolanaAddress,
    ) address.SolanaAddress {
        const seeds = [_][]const u8{
            &wallet,
            &address.TOKEN_PROGRAM_ID,
            &self.token_mint,
        };
        const pda = address.findProgramAddress(&seeds, address.ASSOCIATED_TOKEN_PROGRAM_ID);
        return pda.address;
    }
    
    /// Create associated token account instruction
    pub fn createAssociatedTokenAccount(
        self: *SplToken,
        funding_address: address.SolanaAddress,
        wallet_address: address.SolanaAddress,
    ) instruction.Instruction {
        return instruction.AssociatedTokenInstruction.create(
            funding_address,
            wallet_address,
            self.token_mint,
        );
    }
};

// ============================================================
// System Program Operations
// ============================================================

pub const SystemProgram = struct {
    allocator: Allocator,
    rpc_client: *rpc.SolanaRpcClient,
    
    pub fn init(allocator: Allocator, rpc_client: *rpc.SolanaRpcClient) SystemProgram {
        return .{
            .allocator = allocator,
            .rpc_client = rpc_client,
        };
    }
    
    /// Transfer SOL
    pub fn transfer(
        self: *SystemProgram,
        from: address.SolanaAddress,
        to: address.SolanaAddress,
        lamports: u64,
    ) instruction.Instruction {
        _ = self;
        return instruction.SystemInstruction.transfer(from, to, lamports);
    }
    
    /// Create new account
    pub fn createAccount(
        self: *SystemProgram,
        from: address.SolanaAddress,
        new_account: address.SolanaAddress,
        lamports: u64,
        space: u64,
        owner_program: address.SolanaAddress,
    ) !instruction.Instruction {
        return instruction.SystemInstruction.createAccount(
            from,
            new_account,
            lamports,
            space,
            owner_program,
        );
    }
    
    /// Create account with rent exemption
    pub fn createAccountWithRentExemption(
        self: *SystemProgram,
        from: address.SolanaAddress,
        new_account: address.SolanaAddress,
        space: u64,
        owner_program: address.SolanaAddress,
    ) !instruction.Instruction {
        const rent_exempt = try self.rpc_client.getMinimumBalanceForRentExemption(space);
        return try self.createAccount(from, new_account, rent_exempt, space, owner_program);
    }
};

// ============================================================
// Memo Program
// ============================================================

pub const MemoProgram = struct {
    pub const PROGRAM_ID: address.SolanaAddress = [32]u8{
        0x4d,0x65,0x6d,0x6f,0x31,0x32,0x33,0x34,
        0x35,0x36,0x37,0x38,0x39,0x30,0x61,0x62,
        0x63,0x64,0x65,0x66,0x67,0x68,0x69,0x6a,
        0x6b,0x6c,0x6d,0x6e,0x6f,0x70,0x71,0x72,
    };
    
    /// Create memo instruction (simple)
    pub fn memo(memo_text: []const u8) instruction.Instruction {
        const accounts = &[_]instruction.AccountMeta{};
        const data = allocator.dupe(u8, memo_text) catch unreachable;
        
        return instruction.Instruction{
            .program_id = PROGRAM_ID,
            .accounts = &[_]instruction.AccountMeta{},
            .data = data,
        };
    }
    
    /// Create memo instruction with signer
    pub fn memoWithSigner(
        signer: address.SolanaAddress,
        memo_text: []const u8,
    ) instruction.Instruction {
        const accounts = allocator.alloc(instruction.AccountMeta, 1) catch unreachable;
        accounts[0] = instruction.AccountMeta{
            .pubkey = signer,
            .is_signer = true,
            .is_writable = false,
        };
        
        const data = allocator.dupe(u8, memo_text) catch unreachable;
        
        return instruction.Instruction{
            .program_id = PROGRAM_ID,
            .accounts = accounts,
            .data = data,
        };
    }
};

// ============================================================
// Compute Budget Program
// ============================================================

pub const ComputeBudgetProgram = struct {
    pub const PROGRAM_ID: address.SolanaAddress = [32]u8{
        0x43,0x6f,0x6d,0x70,0x75,0x74,0x65,0x42,
        0x75,0x64,0x67,0x65,0x74,0x31,0x31,0x31,
        0x31,0x31,0x31,0x31,0x31,0x31,0x31,0x31,
        0x31,0x31,0x31,0x31,0x31,0x31,0x31,0x31,
    };
    
    /// Set compute unit limit
    pub fn setComputeUnitLimit(units: u32) instruction.Instruction {
        var data = allocator.alloc(u8, 8) catch unreachable;
        std.mem.writeInt(u32, data[0..4], 2, .little); // discriminator
        std.mem.writeInt(u32, data[4..8], units, .little);
        
        return instruction.Instruction{
            .program_id = PROGRAM_ID,
            .accounts = &[_]instruction.AccountMeta{},
            .data = data,
        };
    }
    
    /// Set compute unit price (micro-lamports per CU)
    pub fn setComputeUnitPrice(micro_lamports: u64) instruction.Instruction {
        var data = allocator.alloc(u8, 12) catch unreachable;
        std.mem.writeInt(u32, data[0..4], 3, .little); // discriminator
        std.mem.writeInt(u64, data[4..12], micro_lamports, .little);
        
        return instruction.Instruction{
            .program_id = PROGRAM_ID,
            .accounts = &[_]instruction.AccountMeta{},
            .data = data,
        };
    }
};

// ============================================================
// Tests
// ============================================================

test "SPL token ATA derivation" {
    const wallet = [_]u8{0x01} ** 32;
    const mint = [_]u8{0x02} ** 32;
    
    var token = SplToken.init(std.testing.allocator, undefined, mint);
    const ata = token.getAssociatedTokenAccount(wallet);
    
    try std.testing.expect(ata.len == 32);
}