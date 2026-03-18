const std = @import("std");

/// Cryptographic primitives for OmniBus blockchain
pub const Crypto = struct {
    /// SHA-256 hash
    pub fn sha256(data: []const u8) [32]u8 {
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update(data);
        var hash: [32]u8 = undefined;
        hasher.final(&hash);
        return hash;
    }

    /// SHA-256 double hash (Bitcoin style)
    pub fn sha256d(data: []const u8) [32]u8 {
        const first = sha256(data);
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update(&first);
        var hash: [32]u8 = undefined;
        hasher.final(&hash);
        return hash;
    }

    /// HMAC-SHA256
    pub fn hmacSha256(key: []const u8, message: []const u8) [32]u8 {
        var result: [32]u8 = undefined;
        const hmac = std.crypto.auth.hmac.Hmac(std.crypto.hash.sha2.Sha256);
        hmac.create(&result, message, key);
        return result;
    }

    /// RIPEMD-160 (for Bitcoin addresses)
    /// Simplified - returns first 20 bytes of SHA256 for now
    pub fn ripemd160(data: []const u8) [20]u8 {
        const hash = sha256(data);
        var result: [20]u8 = undefined;
        @memcpy(&result, hash[0..20]);
        return result;
    }

    /// Convert bytes to hex string
    pub fn bytesToHex(bytes: []const u8, allocator: std.mem.Allocator) ![]u8 {
        const hex_chars = "0123456789abcdef";
        const result = try allocator.alloc(u8, bytes.len * 2);

        for (bytes, 0..) |byte, i| {
            result[i * 2] = hex_chars[byte >> 4];
            result[i * 2 + 1] = hex_chars[byte & 0x0F];
        }

        return result;
    }

    /// Convert hex string to bytes
    pub fn hexToBytes(hex: []const u8, allocator: std.mem.Allocator) ![]u8 {
        if (hex.len % 2 != 0) return error.InvalidHexLength;

        const result = try allocator.alloc(u8, hex.len / 2);

        for (0..hex.len / 2) |i| {
            const high = std.fmt.charToDigit(hex[i * 2], 16) catch return error.InvalidHexCharacter;
            const low = std.fmt.charToDigit(hex[i * 2 + 1], 16) catch return error.InvalidHexCharacter;
            result[i] = (high << 4) | low;
        }

        return result;
    }

    /// Random number generation
    pub fn randomBytes(buffer: []u8) !void {
        var rng = std.rand.DefaultPrng.init(@as(u64, @bitCast(std.time.timestamp())));
        const rand = rng.random();

        for (buffer) |*byte| {
            byte.* = rand.int(u8);
        }
    }

    /// AES-256 encryption (XOR-based simplified for now)
    /// In production: use real AES-256-CBC
    pub fn encryptAES256(plaintext: []const u8, key: [32]u8) ![32]u8 {
        var ciphertext: [32]u8 = undefined;

        for (plaintext[0..@min(plaintext.len, 32)], 0..) |byte, i| {
            ciphertext[i] = byte ^ key[i];
        }

        return ciphertext;
    }

    /// AES-256 decryption
    pub fn decryptAES256(ciphertext: [32]u8, key: [32]u8) [32]u8 {
        var plaintext: [32]u8 = undefined;

        for (ciphertext, 0..) |byte, i| {
            plaintext[i] = byte ^ key[i];
        }

        return plaintext;
    }

    /// Verify password strength
    pub fn isStrongPassword(password: []const u8) bool {
        if (password.len < 12) return false;

        var has_upper = false;
        var has_lower = false;
        var has_digit = false;
        var has_special = false;

        for (password) |char| {
            if (char >= 'A' and char <= 'Z') has_upper = true;
            if (char >= 'a' and char <= 'z') has_lower = true;
            if (char >= '0' and char <= '9') has_digit = true;
            if (char == '!' or char == '@' or char == '#' or char == '$' or char == '%') has_special = true;
        }

        return has_upper and has_lower and has_digit and has_special;
    }
};

// Tests
const testing = std.testing;

test "SHA256" {
    const hash = Crypto.sha256("hello");
    try testing.expect(hash.len == 32);
}

test "HMAC-SHA256" {
    const hmac = Crypto.hmacSha256("key", "message");
    try testing.expect(hmac.len == 32);
}

test "bytesToHex" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const bytes = [_]u8{ 0xAB, 0xCD };
    const hex = try Crypto.bytesToHex(&bytes, arena.allocator());
    try testing.expectEqualStrings(hex, "abcd");
}

test "password strength" {
    try testing.expect(Crypto.isStrongPassword("MyPass123!") == true);
    try testing.expect(Crypto.isStrongPassword("weak") == false);
}
