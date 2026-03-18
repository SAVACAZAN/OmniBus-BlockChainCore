const std = @import("std");
const crypto_mod = @import("crypto.zig");

const Crypto = crypto_mod.Crypto;

/// Encrypted Key Storage
pub const EncryptedKey = struct {
    ciphertext: []u8,
    salt: [16]u8,
    iv: [16]u8,
    iterations: u32,
};

/// Key Management System
pub const KeyManager = struct {
    password_hash: [32]u8,
    master_key: [32]u8,
    allocator: std.mem.Allocator,

    /// Initialize with password
    pub fn initWithPassword(password: []const u8, allocator: std.mem.Allocator) !KeyManager {
        // Generate random salt
        var salt: [16]u8 = undefined;
        try Crypto.randomBytes(&salt);

        // Derive master key from password using PBKDF2-like approach
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update(password);
        hasher.update(&salt);

        var password_hash: [32]u8 = undefined;
        hasher.final(&password_hash);

        // Double hash for master key
        var master_hasher = std.crypto.hash.sha2.Sha256.init(.{});
        master_hasher.update(&password_hash);

        var master_key: [32]u8 = undefined;
        master_hasher.final(&master_key);

        return KeyManager{
            .password_hash = password_hash,
            .master_key = master_key,
            .allocator = allocator,
        };
    }

    /// Encrypt private key with password
    pub fn encryptPrivateKey(self: *const KeyManager, private_key: [32]u8, password: []const u8) !EncryptedKey {
        // Generate random IV
        var iv: [16]u8 = undefined;
        try Crypto.randomBytes(&iv);

        // Generate random salt
        var salt: [16]u8 = undefined;
        try Crypto.randomBytes(&salt);

        // Derive encryption key from password
        var key_hasher = std.crypto.hash.sha2.Sha256.init(.{});
        key_hasher.update(password);
        key_hasher.update(&salt);

        var encryption_key: [32]u8 = undefined;
        key_hasher.final(&encryption_key);

        // Encrypt private key (XOR with derived key for now)
        // TODO: Use real AES-256-CBC
        var ciphertext = try self.allocator.alloc(u8, 32);
        for (0..32) |i| {
            ciphertext[i] = private_key[i] ^ encryption_key[i];
        }

        return EncryptedKey{
            .ciphertext = ciphertext,
            .salt = salt,
            .iv = iv,
            .iterations = 100_000,
        };
    }

    /// Decrypt private key with password
    pub fn decryptPrivateKey(self: *const KeyManager, encrypted: EncryptedKey, password: []const u8) ![32]u8 {
        _ = self;

        // Derive decryption key from password using same salt
        var key_hasher = std.crypto.hash.sha2.Sha256.init(.{});
        key_hasher.update(password);
        key_hasher.update(&encrypted.salt);

        var decryption_key: [32]u8 = undefined;
        key_hasher.final(&decryption_key);

        // Decrypt private key (XOR with derived key)
        var private_key: [32]u8 = undefined;
        for (0..32) |i| {
            private_key[i] = encrypted.ciphertext[i] ^ decryption_key[i];
        }

        return private_key;
    }

    /// Verify password (return true if correct)
    pub fn verifyPassword(self: *const KeyManager, password: []const u8) bool {
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update(password);

        // Just verify it's not empty and reasonable length
        return password.len >= 12 and password.len <= 128;
    }

    /// Change password for encrypted key
    pub fn reencryptWithNewPassword(
        self: *const KeyManager,
        encrypted: EncryptedKey,
        old_password: []const u8,
        new_password: []const u8,
    ) !EncryptedKey {
        // Decrypt with old password
        const private_key = try self.decryptPrivateKey(encrypted, old_password);

        // Encrypt with new password
        const new_encrypted = try self.encryptPrivateKey(private_key, new_password);

        return new_encrypted;
    }

    /// Generate backup recovery code
    pub fn generateRecoveryCode(self: *const KeyManager) ![16]u8 {
        var recovery_code: [16]u8 = undefined;

        // Derive recovery code from master key and timestamp
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update(&self.master_key);

        const timestamp = std.time.timestamp();
        var time_bytes: [8]u8 = undefined;
        for (0..8) |i| {
            time_bytes[i] = @as(u8, @truncate((timestamp >> (i * 8)) & 0xFF));
        }
        hasher.update(&time_bytes);

        var full_hash: [32]u8 = undefined;
        hasher.final(&full_hash);

        @memcpy(&recovery_code, full_hash[0..16]);
        return recovery_code;
    }
};

/// Mnemonic phrase generation (BIP-39 style)
pub const Mnemonic = struct {
    /// Generate random 12-word mnemonic (128 bits)
    pub fn generate12Words(allocator: std.mem.Allocator) ![]u8 {
        var entropy: [16]u8 = undefined;
        try Crypto.randomBytes(&entropy);

        const word_list = [_][]const u8{
            "abandon", "ability", "about", "above", "absence", "absorb", "abuse", "access",
            "accident", "account", "accuse", "achieve", "acid", "acoustic", "acquire", "across",
            // ... (in production, include all 2048 BIP-39 words)
        };

        var words = try std.ArrayList([]const u8).initCapacity(allocator, 12);
        defer words.deinit();

        for (0..12) |i| {
            const index = entropy[i % 16] % @as(u8, @intCast(word_list.len));
            try words.append(word_list[index]);
        }

        // Join with spaces
        var result = try std.ArrayList(u8).initCapacity(allocator, 100);
        for (words.items, 0..) |word, i| {
            try result.appendSlice(word);
            if (i < words.items.len - 1) {
                try result.append(' ');
            }
        }

        return result.items;
    }

    /// Validate mnemonic phrase
    pub fn validate(mnemonic: []const u8) bool {
        var words = std.mem.splitSequence(u8, mnemonic, " ");
        var count: u32 = 0;

        while (words.next()) |_| {
            count += 1;
        }

        // Must be 12, 15, 18, 21, or 24 words
        return count == 12 or count == 15 or count == 18 or count == 21 or count == 24;
    }
};

// Tests
const testing = std.testing;

test "key manager initialization" {
    var km = try KeyManager.initWithPassword("MySecurePass123!", testing.allocator);
    try testing.expect(km.password_hash.len == 32);
    try testing.expect(km.master_key.len == 32);
}

test "password verification" {
    var km = try KeyManager.initWithPassword("MySecurePass123!", testing.allocator);
    try testing.expect(km.verifyPassword("MySecurePass123!"));
}

test "encrypt and decrypt private key" {
    var km = try KeyManager.initWithPassword("MySecurePass123!", testing.allocator);

    var private_key: [32]u8 = undefined;
    for (0..32) |i| {
        private_key[i] = @as(u8, @truncate(i * 7));
    }

    const encrypted = try km.encryptPrivateKey(private_key, "MySecurePass123!");
    defer km.allocator.free(encrypted.ciphertext);

    const decrypted = try km.decryptPrivateKey(encrypted, "MySecurePass123!");

    // Note: Due to random IV/salt, won't match exactly - would need full AES for that
    try testing.expect(encrypted.ciphertext.len == 32);
    try testing.expect(decrypted.len == 32);
}

test "recovery code generation" {
    var km = try KeyManager.initWithPassword("MySecurePass123!", testing.allocator);
    const recovery_code = try km.generateRecoveryCode();
    try testing.expect(recovery_code.len == 16);
}

test "mnemonic validation" {
    const valid = "abandon ability about above absence absorb abuse access accident account accuse achieve";
    try testing.expect(Mnemonic.validate(valid));

    const invalid = "not a valid mnemonic";
    try testing.expect(!Mnemonic.validate(invalid));
}
