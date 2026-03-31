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

    /// HMAC-SHA512 (BIP32 standard)
    pub fn hmacSha512(key: []const u8, message: []const u8) [64]u8 {
        var result: [64]u8 = undefined;
        const hmac = std.crypto.auth.hmac.Hmac(std.crypto.hash.sha2.Sha512);
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
        std.crypto.random.bytes(buffer);
    }

    /// AES-256-GCM encryption — real AEAD, nu XOR
    /// Output: [nonce:12][tag:16][ciphertext:plaintext.len] — max plaintext 32 bytes
    /// Returneaza buffer de 12+16+32 = 60 bytes (plaintext padding 0 la 32 daca mai scurt)
    pub fn encryptAES256(plaintext: []const u8, key: [32]u8) ![60]u8 {
        const Aes256Gcm = std.crypto.aead.aes_gcm.Aes256Gcm;
        const NONCE_LEN = Aes256Gcm.nonce_length; // 12
        const TAG_LEN   = Aes256Gcm.tag_length;   // 16
        const PT_LEN    = 32;

        var padded: [PT_LEN]u8 = @splat(0);
        const copy_len = @min(plaintext.len, PT_LEN);
        @memcpy(padded[0..copy_len], plaintext[0..copy_len]);

        var nonce: [NONCE_LEN]u8 = undefined;
        std.crypto.random.bytes(&nonce);

        var ct: [PT_LEN]u8 = undefined;
        var tag: [TAG_LEN]u8 = undefined;
        Aes256Gcm.encrypt(&ct, &tag, &padded, "", nonce, key);

        var out: [60]u8 = undefined;
        @memcpy(out[0..NONCE_LEN], &nonce);
        @memcpy(out[NONCE_LEN..][0..TAG_LEN], &tag);
        @memcpy(out[NONCE_LEN + TAG_LEN..], &ct);
        return out;
    }

    /// AES-256-GCM decryption — returneaza [32]u8 plaintext sau error.AuthenticationFailed
    pub fn decryptAES256(ciphertext: [60]u8, key: [32]u8) ![32]u8 {
        const Aes256Gcm = std.crypto.aead.aes_gcm.Aes256Gcm;
        const NONCE_LEN = Aes256Gcm.nonce_length;
        const TAG_LEN   = Aes256Gcm.tag_length;

        const nonce = ciphertext[0..NONCE_LEN].*;
        const tag   = ciphertext[NONCE_LEN..][0..TAG_LEN].*;
        const ct    = ciphertext[NONCE_LEN + TAG_LEN..].*;

        var plaintext: [32]u8 = undefined;
        try Aes256Gcm.decrypt(&plaintext, &ct, tag, "", nonce, key);
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

test "AES-256-GCM round-trip" {
    const key: [32]u8 = @splat(0x42);
    const plaintext = "Hello OmniBus!";
    const encrypted = try Crypto.encryptAES256(plaintext, key);
    const decrypted = try Crypto.decryptAES256(encrypted, key);
    try testing.expectEqualSlices(u8, plaintext, decrypted[0..plaintext.len]);
}

test "AES-256-GCM wrong key fails" {
    const key: [32]u8 = @splat(0x42);
    const bad_key: [32]u8 = @splat(0x99);
    const encrypted = try Crypto.encryptAES256("secret data!!", key);
    try testing.expectError(error.AuthenticationFailed, Crypto.decryptAES256(encrypted, bad_key));
}

test "password strength" {
    try testing.expect(Crypto.isStrongPassword("MyStrongPass123!") == true);
    try testing.expect(Crypto.isStrongPassword("weak") == false);
}
