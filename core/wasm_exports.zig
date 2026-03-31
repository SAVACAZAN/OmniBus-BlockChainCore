/// WASM Exports — OmniBus Wallet in Browser
/// Compilare: zig build-lib core/wasm_exports.zig -target wasm32-freestanding -OReleaseFast --export-memory
///
/// Exporta functii pentru:
///   - Generare keypair secp256k1
///   - Hash160 (SHA256 + RIPEMD160) pentru adrese
///   - SHA256 / SHA256d
///   - HMAC-SHA256 / HMAC-SHA512
///   - Semnare / Verificare ECDSA
///   - Generare adresa OmniBus Bech32 (ob1q...)

const std = @import("std");
const secp = @import("secp256k1.zig").Secp256k1Crypto;
const crypto = @import("crypto.zig").Crypto;
const ripemd = @import("ripemd160.zig").Ripemd160;
const bech32 = @import("bech32.zig");

// ── Shared memory buffer (WASM nu are allocator, folosim buffer fix) ──────
var shared_buf: [8192]u8 = undefined;

// ── Helper: hex encode into shared_buf ────────────────────────────────────
fn hexEncode(data: []const u8) [*]const u8 {
    const hex_chars = "0123456789abcdef";
    for (data, 0..) |byte, i| {
        shared_buf[i * 2] = hex_chars[byte >> 4];
        shared_buf[i * 2 + 1] = hex_chars[byte & 0x0f];
    }
    return &shared_buf;
}

// ══════════════════════════════════════════════════════════════════════════
// EXPORTED FUNCTIONS — callable from JavaScript
// ══════════════════════════════════════════════════════════════════════════

/// Returns pointer to 66-char hex pubkey in shared_buf
/// Input: 32-byte private key at ptr
export fn generatePublicKey(privkey_ptr: [*]const u8) u32 {
    const privkey: [32]u8 = privkey_ptr[0..32].*;
    const pubkey = secp.privateKeyToPublicKey(privkey) catch return 0;
    _ = hexEncode(&pubkey);
    return 66; // 33 bytes * 2 hex chars
}

/// Returns pointer to 40-char hex hash160 in shared_buf
/// Input: 32-byte private key at ptr
export fn generateHash160(privkey_ptr: [*]const u8) u32 {
    const privkey: [32]u8 = privkey_ptr[0..32].*;
    const hash160 = secp.privateKeyToHash160(privkey) catch return 0;
    _ = hexEncode(&hash160);
    return 40; // 20 bytes * 2 hex chars
}

/// Returns pointer to 64-char hex sha256 hash in shared_buf
/// Input: data at ptr, length len
export fn sha256Hash(data_ptr: [*]const u8, len: u32) u32 {
    const data = data_ptr[0..len];
    const hash = crypto.sha256(data);
    _ = hexEncode(&hash);
    return 64;
}

/// Returns pointer to 64-char hex sha256d hash in shared_buf
export fn sha256dHash(data_ptr: [*]const u8, len: u32) u32 {
    const data = data_ptr[0..len];
    const hash = crypto.sha256d(data);
    _ = hexEncode(&hash);
    return 64;
}

/// Returns pointer to 64-char hex HMAC-SHA256 in shared_buf
/// key at key_ptr (key_len), message at msg_ptr (msg_len)
export fn hmacSha256(key_ptr: [*]const u8, key_len: u32, msg_ptr: [*]const u8, msg_len: u32) u32 {
    const key = key_ptr[0..key_len];
    const msg = msg_ptr[0..msg_len];
    const mac = crypto.hmacSha256(key, msg);
    _ = hexEncode(&mac);
    return 64;
}

/// Returns pointer to 128-char hex HMAC-SHA512 in shared_buf
export fn hmacSha512(key_ptr: [*]const u8, key_len: u32, msg_ptr: [*]const u8, msg_len: u32) u32 {
    const key = key_ptr[0..key_len];
    const msg = msg_ptr[0..msg_len];
    const mac = crypto.hmacSha512(key, msg);
    _ = hexEncode(&mac);
    return 128;
}

/// Sign message with private key. Returns 128-char hex signature in shared_buf
export fn signMessage(privkey_ptr: [*]const u8, msg_ptr: [*]const u8, msg_len: u32) u32 {
    const privkey: [32]u8 = privkey_ptr[0..32].*;
    const msg = msg_ptr[0..msg_len];
    const sig = secp.sign(privkey, msg) catch return 0;
    _ = hexEncode(&sig);
    return 128; // 64 bytes * 2
}

/// Verify signature. Returns 1 if valid, 0 if invalid
export fn verifySignature(pubkey_ptr: [*]const u8, msg_ptr: [*]const u8, msg_len: u32, sig_ptr: [*]const u8) u32 {
    const pubkey: [33]u8 = pubkey_ptr[0..33].*;
    const msg = msg_ptr[0..msg_len];
    const sig: [64]u8 = sig_ptr[0..64].*;
    return if (secp.verify(pubkey, msg, sig)) 1 else 0;
}

/// RIPEMD-160 hash. Returns 40-char hex in shared_buf
export fn ripemd160Hash(data_ptr: [*]const u8, len: u32) u32 {
    const data = data_ptr[0..len];
    var hash: [20]u8 = undefined;
    ripemd.hash(data, &hash);
    _ = hexEncode(&hash);
    return 40;
}

// ── Base58Check encoding (no allocator, fixed buffer) ─────────────────────
const BASE58_ALPHABET = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";
const Sha256 = std.crypto.hash.sha2.Sha256;

/// Base58Check(version_byte || hash160) into out_buf. Returns length written.
fn base58CheckEncodeFixed(hash160: [20]u8, version: u8, out_buf: []u8) u32 {
    // payload = version || hash160 (21 bytes)
    var payload: [21]u8 = undefined;
    payload[0] = version;
    @memcpy(payload[1..21], &hash160);

    // checksum = SHA256(SHA256(payload))[0..4]
    var first: [32]u8 = undefined;
    Sha256.hash(&payload, &first, .{});
    var second: [32]u8 = undefined;
    Sha256.hash(&first, &second, .{});

    // full = payload || checksum (25 bytes)
    var full: [25]u8 = undefined;
    @memcpy(full[0..21], &payload);
    @memcpy(full[21..25], second[0..4]);

    // Count leading zero bytes
    var leading_zeros: usize = 0;
    for (full) |b| {
        if (b == 0) leading_zeros += 1 else break;
    }

    // Base58 encode: treat full as big-endian integer, divide by 58
    var digits: [40]u8 = @splat(0);
    var digits_len: usize = 0;

    for (full) |byte| {
        var carry: u32 = byte;
        var j: usize = 0;
        while (j < digits_len or carry != 0) {
            if (j < digits_len) {
                carry += @as(u32, digits[j]) << 8;
            }
            digits[j] = @truncate(carry % 58);
            carry /= 58;
            j += 1;
        }
        digits_len = j;
    }

    // Build result: leading '1's + digits reversed
    const result_len = leading_zeros + digits_len;
    for (0..leading_zeros) |i| {
        out_buf[i] = '1';
    }
    for (0..digits_len) |i| {
        out_buf[leading_zeros + i] = BASE58_ALPHABET[digits[digits_len - 1 - i]];
    }

    return @intCast(result_len);
}

/// Generate OmniBus Bech32 address from private key
/// Format: ob1q... (42 chars, identical to Bitcoin bc1q format)
/// Returns address length in shared_buf (always 42 chars)
export fn generateAddress(privkey_ptr: [*]const u8) u32 {
    const privkey: [32]u8 = privkey_ptr[0..32].*;
    const hash160 = secp.privateKeyToHash160(privkey) catch return 0;

    // Bech32 encode with fixed buffer allocator
    var fba_buf: [256]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&fba_buf);
    const addr = bech32.encodeOBAddress(hash160, fba.allocator()) catch return 0;

    // Copy to shared buffer
    const len: u32 = @intCast(addr.len);
    @memcpy(shared_buf[0..len], addr);
    return len;
}

/// Returns 1 if private key is valid for secp256k1, 0 otherwise
export fn isValidPrivateKey(privkey_ptr: [*]const u8) u32 {
    const privkey: [32]u8 = privkey_ptr[0..32].*;
    return if (secp.isValidPrivateKey(privkey)) 1 else 0;
}

/// Get pointer to shared buffer (JS needs this to read results)
export fn getSharedBuffer() [*]u8 {
    return &shared_buf;
}
