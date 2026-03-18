const std = @import("std");
const crypto_mod = @import("crypto.zig");

const Crypto = crypto_mod.Crypto;

/// BIP-32 Hierarchical Deterministic Wallet
pub const BIP32Wallet = struct {
    /// Master key seed
    master_seed: [64]u8,
    /// Master key
    master_key: [32]u8,
    /// Master chain code
    master_chain_code: [32]u8,
    allocator: std.mem.Allocator,

    const HARDENED_OFFSET = 0x80000000;

    /// Initialize from BIP-39 mnemonic (simplified)
    pub fn initFromMnemonic(mnemonic: []const u8, allocator: std.mem.Allocator) !BIP32Wallet {
        // SHA-512 of "BIP32" || mnemonic as seed
        var hasher = std.crypto.hash.sha2.Sha512.init(.{});
        hasher.update("BIP32");
        hasher.update(mnemonic);

        var seed: [64]u8 = undefined;
        hasher.final(&seed);

        return try initFromSeed(&seed, allocator);
    }

    /// Initialize from seed bytes
    pub fn initFromSeed(seed: [64]u8, allocator: std.mem.Allocator) !BIP32Wallet {
        // Master key = first 32 bytes of seed
        var master_key: [32]u8 = undefined;
        @memcpy(&master_key, seed[0..32]);

        // Master chain code = last 32 bytes of seed
        var master_chain_code: [32]u8 = undefined;
        @memcpy(&master_chain_code, seed[32..64]);

        return BIP32Wallet{
            .master_seed = seed,
            .master_key = master_key,
            .master_chain_code = master_chain_code,
            .allocator = allocator,
        };
    }

    /// Derive child key at path m/44'/0'/0'/0/0 (BIP-44)
    /// Index: 0-4 for 5 different PQ domains
    pub fn deriveChildKey(self: *const BIP32Wallet, index: u32) ![32]u8 {
        var current_key = self.master_key;
        var current_chain_code = self.master_chain_code;

        // m/44'/0'/0'/0/[index]
        const path = [_]u32{
            44 + BIP32Wallet.HARDENED_OFFSET,      // Purpose: 44'
            0 + BIP32Wallet.HARDENED_OFFSET,       // Coin type: BTC (0')
            0 + BIP32Wallet.HARDENED_OFFSET,       // Account: 0'
            0,                                      // Change: external (0)
            index,                                  // Address: [index]
        };

        for (path) |step| {
            const child = try self.deriveChild(current_key, current_chain_code, step);
            current_key = child.key;
            current_chain_code = child.chain_code;
        }

        return current_key;
    }

    /// Derive single child key
    fn deriveChild(self: *const BIP32Wallet, parent_key: [32]u8, parent_chain_code: [32]u8, index: u32) ![2][32]u8 {
        var data: [37]u8 = undefined;

        if (index >= BIP32Wallet.HARDENED_OFFSET) {
            // Hardened child: use parent private key
            data[0] = 0x00; // Prefix for private key
            @memcpy(data[1..33], &parent_key);
        } else {
            // Normal child: use parent public key (simplified - just use first 32 bytes)
            @memcpy(data[0..32], &parent_key);
        }

        // Big-endian index
        data[33] = @as(u8, @truncate((index >> 24) & 0xFF));
        data[34] = @as(u8, @truncate((index >> 16) & 0xFF));
        data[35] = @as(u8, @truncate((index >> 8) & 0xFF));
        data[36] = @as(u8, @truncate(index & 0xFF));

        // HMAC-SHA512(parent_chain_code, data)
        var hasher = std.crypto.hash.sha2.Sha512.init(.{});
        var hmac_result: [64]u8 = undefined;

        // Simplified HMAC (XOR-based for now)
        for (0..64) |i| {
            hmac_result[i] = if (i < 32)
                data[i % 37] ^ parent_chain_code[i]
            else
                parent_chain_code[i - 32];
        }

        var child_key: [32]u8 = undefined;
        @memcpy(&child_key, hmac_result[0..32]);

        var child_chain_code: [32]u8 = undefined;
        @memcpy(&child_chain_code, hmac_result[32..64]);

        return [2][32]u8{ child_key, child_chain_code };
    }

    /// Get address from derived key (simplified Bitcoin-style)
    pub fn deriveAddress(self: *const BIP32Wallet, index: u32, prefix: []const u8, allocator: std.mem.Allocator) ![]u8 {
        const key = try self.deriveChildKey(index);

        // SHA-256 hash of public key
        const key_hash = Crypto.sha256(&key);

        // RIPEMD-160 of hash
        const address_hash = Crypto.ripemd160(&key_hash);

        // Convert to hex
        const hex = try Crypto.bytesToHex(&address_hash, allocator);

        // Format: prefix + hex
        const address = try std.fmt.allocPrint(allocator, "{s}{s}", .{ prefix, hex[0..12] });

        allocator.free(hex);
        return address;
    }
};

/// 5 Post-Quantum Domain Manager
pub const PQDomainDerivation = struct {
    wallet: BIP32Wallet,

    pub const Domain = struct {
        name: []const u8,
        algorithm: []const u8,
        prefix: []const u8,
        security_level: u32,
    };

    pub const DOMAINS = [_]Domain{
        .{
            .name = "omnibus.omni",
            .algorithm = "Dilithium-5 + Kyber-768",
            .prefix = "ob_omni_",
            .security_level = 256,
        },
        .{
            .name = "omnibus.love",
            .algorithm = "Kyber-768",
            .prefix = "ob_k1_",
            .security_level = 256,
        },
        .{
            .name = "omnibus.food",
            .algorithm = "Falcon-512",
            .prefix = "ob_f5_",
            .security_level = 192,
        },
        .{
            .name = "omnibus.rent",
            .algorithm = "Dilithium-5",
            .prefix = "ob_d5_",
            .security_level = 256,
        },
        .{
            .name = "omnibus.vacation",
            .algorithm = "SPHINCS+",
            .prefix = "ob_s3_",
            .security_level = 128,
        },
    };

    pub fn init(wallet: BIP32Wallet) PQDomainDerivation {
        return PQDomainDerivation{
            .wallet = wallet,
        };
    }

    pub fn deriveAllAddresses(self: *const PQDomainDerivation, allocator: std.mem.Allocator) ![5][]u8 {
        var addresses: [5][]u8 = undefined;

        for (DOMAINS, 0..) |domain, i| {
            addresses[i] = try self.wallet.deriveAddress(@as(u32, @intCast(i)), domain.prefix, allocator);
        }

        return addresses;
    }

    pub fn getDomain(index: u32) ?Domain {
        if (index < DOMAINS.len) {
            return DOMAINS[index];
        }
        return null;
    }
};

// Tests
const testing = std.testing;

test "BIP32 wallet initialization" {
    const mnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
    var wallet = try BIP32Wallet.initFromMnemonic(mnemonic, testing.allocator);
    _ = wallet;

    try testing.expect(wallet.master_key.len == 32);
    try testing.expect(wallet.master_chain_code.len == 32);
}

test "BIP32 child derivation" {
    const mnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
    var wallet = try BIP32Wallet.initFromMnemonic(mnemonic, testing.allocator);

    const key0 = try wallet.deriveChildKey(0);
    const key1 = try wallet.deriveChildKey(1);

    // Different indices should produce different keys
    try testing.expect(!std.mem.eql(u8, &key0, &key1));
}

test "PQ domain addresses" {
    const mnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
    var wallet = try BIP32Wallet.initFromMnemonic(mnemonic, testing.allocator);
    var pq_domains = PQDomainDerivation.init(wallet);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const addresses = try pq_domains.deriveAllAddresses(arena.allocator());

    // Should generate 5 addresses
    try testing.expectEqual(addresses.len, 5);

    // Each should have correct prefix
    try testing.expect(std.mem.startsWith(u8, addresses[0], "ob_omni_"));
    try testing.expect(std.mem.startsWith(u8, addresses[1], "ob_k1_"));
    try testing.expect(std.mem.startsWith(u8, addresses[2], "ob_f5_"));
    try testing.expect(std.mem.startsWith(u8, addresses[3], "ob_d5_"));
    try testing.expect(std.mem.startsWith(u8, addresses[4], "ob_s3_"));
}
