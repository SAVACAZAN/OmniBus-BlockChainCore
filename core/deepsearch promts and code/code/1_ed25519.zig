//! Ed25519 wrapper for Solana (re-export from core with Solana-specific utilities)

const std = @import("std");
const allocator = std.mem.Allocator;
const ed25519 = @import("../../core/ed25519_wrapper.zig");

// Re-export core Ed25519 types
pub const PrivateKey = ed25519.PrivateKey;
pub const PublicKey = ed25519.PublicKey;
pub const Signature = ed25519.Signature;
pub const KeyPair = ed25519.KeyPair;
pub const Ed25519Ops = ed25519.Ed25519Ops;

// ============================================================
// Solana-Specific Ed25519
// ============================================================

/// Solana message prefix for signed messages
const SOLANA_MESSAGE_PREFIX = "Solana Signed Message:\n";

pub const SolanaEd25519 = struct {
    ops: Ed25519Ops,
    
    pub fn init(allocator: Allocator) SolanaEd25519 {
        return .{
            .ops = Ed25519Ops.init(allocator),
        };
    }
    
    /// Sign a Solana transaction message
    pub fn signTransaction(
        self: *SolanaEd25519,
        message: []const u8,
        private_key: PrivateKey,
    ) !Signature {
        // Solana transaction signing doesn't use prefix
        return try self.ops.sign(message, private_key);
    }
    
    /// Sign a Solana message (with prefix for off-chain signing)
    pub fn signMessage(
        self: *SolanaEd25519,
        message: []const u8,
        private_key: PrivateKey,
    ) !Signature {
        // Add Solana message prefix
        var full_message = std.ArrayList(u8).init(self.ops.allocator);
        defer full_message.deinit();
        
        try full_message.appendSlice(SOLANA_MESSAGE_PREFIX);
        try full_message.appendSlice(&std.mem.toBytes(@as(u32, @intCast(message.len))));
        try full_message.appendSlice(message);
        
        return try self.ops.sign(full_message.items, private_key);
    }
    
    /// Verify a Solana signed message
    pub fn verifyMessage(
        self: *SolanaEd25519,
        message: []const u8,
        signature: Signature,
        public_key: PublicKey,
    ) bool {
        var full_message = std.ArrayList(u8).init(self.ops.allocator);
        defer full_message.deinit();
        
        full_message.appendSlice(SOLANA_MESSAGE_PREFIX) catch return false;
        full_message.appendSlice(&std.mem.toBytes(@as(u32, @intCast(message.len)))) catch return false;
        full_message.appendSlice(message) catch return false;
        
        return self.ops.verify(full_message.items, signature, public_key);
    }
    
    /// Generate a new Solana keypair
    pub fn generateKeypair(self: *SolanaEd25519) !KeyPair {
        return try self.ops.generateKeypair();
    }
    
    /// Derive public key from private key
    pub fn derivePublicKey(self: *SolanaEd25519, private_key: PrivateKey) PublicKey {
        return self.ops.derivePublicKey(private_key);
    }
    
    /// Validate a public key (checks if it's on the curve)
    pub fn validatePublicKey(self: *SolanaEd25519, public_key: PublicKey) bool {
        return self.ops.validatePublicKey(public_key);
    }
};

// ============================================================
// Solana Key Derivation (BIP-44)
// ============================================================

pub const SolanaDerivation = struct {
    allocator: Allocator,
    derivation_ops: ed25519.DerivationOps,
    
    pub fn init(allocator: Allocator) SolanaDerivation {
        return .{
            .allocator = allocator,
            .derivation_ops = ed25519.DerivationOps.init(allocator),
        };
    }
    
    /// Derive Solana keypair from seed using BIP-44 path: m/44'/501'/account'/0/index
    pub fn deriveKeypair(
        self: *SolanaDerivation,
        seed: []const u8,
        account: u32,
        index: u32,
    ) !KeyPair {
        return try self.derivation_ops.deriveSolanaKeypair(seed, account, index);
    }
    
    /// Derive multiple keypairs for an account
    pub fn deriveKeypairs(
        self: *SolanaDerivation,
        seed: []const u8,
        account: u32,
        start_index: u32,
        count: u32,
    ) ![]KeyPair {
        var keypairs = try self.allocator.alloc(KeyPair, count);
        errdefer self.allocator.free(keypairs);
        
        for (0..count) |i| {
            keypairs[i] = try self.deriveKeypair(seed, account, start_index + @as(u32, @intCast(i)));
        }
        
        return keypairs;
    }
    
    /// Derive public key only (without private key)
    pub fn derivePublicKeyOnly(
        self: *SolanaDerivation,
        seed: []const u8,
        account: u32,
        index: u32,
    ) !PublicKey {
        const keypair = try self.deriveKeypair(seed, account, index);
        return keypair.public;
    }
};

// ============================================================
// Tests
// ============================================================

test "Solana Ed25519 sign/verify" {
    var sol_ed25519 = SolanaEd25519.init(std.testing.allocator);
    const keypair = try sol_ed25519.generateKeypair();
    
    const message = "Hello Solana!";
    const signature = try sol_ed25519.signMessage(message, keypair.private);
    
    try std.testing.expect(sol_ed25519.verifyMessage(message, signature, keypair.public));
}

test "Solana derivation" {
    var derivation = SolanaDerivation.init(std.testing.allocator);
    const seed = [_]u8{0x01} ** 32;
    
    const keypair = try derivation.deriveKeypair(&seed, 0, 0);
    
    try std.testing.expect(keypair.public.len == 32);
}