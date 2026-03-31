/// WASM Exports — OmniBus Wallet in Browser
/// Compilare: zig build-lib core/wasm_exports.zig -target wasm32-freestanding -OReleaseFast --export-memory
///
/// Exporta functii pentru:
///   - Generare keypair secp256k1
///   - Hash160 (SHA256 + RIPEMD160) pentru adrese
///   - SHA256 / SHA256d
///   - HMAC-SHA256 / HMAC-SHA512
///   - Semnare / Verificare ECDSA
///   - Generare adresa OmniBus (ob_omni_ prefix)

const std = @import("std");
const secp = @import("secp256k1.zig").Secp256k1Crypto;
const crypto = @import("crypto.zig").Crypto;
const ripemd = @import("ripemd160.zig").Ripemd160;

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

/// Generate OmniBus address from private key
/// Returns address length in shared_buf (format: ob_omni_ + 24 hex chars)
export fn generateAddress(privkey_ptr: [*]const u8) u32 {
    const privkey: [32]u8 = privkey_ptr[0..32].*;
    const hash160 = secp.privateKeyToHash160(privkey) catch return 0;

    // ob_omni_ prefix (8 chars) + first 12 bytes of hash160 as hex (24 chars) = 32 chars
    const prefix = "ob_omni_";
    @memcpy(shared_buf[0..8], prefix);

    const hex_chars = "0123456789abcdef";
    for (hash160[0..12], 0..) |byte, i| {
        shared_buf[8 + i * 2] = hex_chars[byte >> 4];
        shared_buf[8 + i * 2 + 1] = hex_chars[byte & 0x0f];
    }

    return 32; // 8 prefix + 24 hex
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
