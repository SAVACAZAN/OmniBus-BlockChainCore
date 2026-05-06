const std = @import("std");
const ripemd160_mod = @import("ripemd160.zig");
const Ripemd160 = ripemd160_mod.Ripemd160;

/// secp256k1 — curba eliptica Bitcoin/OMNI
/// Foloseste std.crypto.sign.ecdsa (Zig 0.15 stdlib, zero dependente externe)
pub const Secp256k1Crypto = struct {
    const Ecdsa = std.crypto.sign.ecdsa.EcdsaSecp256k1Sha256oSha256; // Bitcoin: SHA256(SHA256(msg))

    /// Compressed public key (33 bytes): 0x02/0x03 + X
    pub const CompressedPubkey = [33]u8;
    /// Private key (32 bytes)
    pub const PrivateKey = [32]u8;
    /// ECDSA signature (64 bytes: R || S)
    pub const Signature = [64]u8;

    /// secp256k1 curve order n (big-endian, 32 bytes)
    pub const CURVE_ORDER_N: [32]u8 = .{
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFE,
        0xBA, 0xAE, 0xDC, 0xE6, 0xAF, 0x48, 0xA0, 0x3B,
        0xBF, 0xD2, 0x5E, 0x8C, 0xD0, 0x36, 0x41, 0x41,
    };

    /// n / 2 — big-endian. Used for low-S canonical form (BIP-146).
    /// Values of S strictly greater than this constitute the "high-S" half
    /// of the signature space; rejecting them removes ECDSA malleability.
    pub const HALF_N: [32]u8 = .{
        0x7F, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        0x5D, 0x57, 0x6E, 0x73, 0x57, 0xA4, 0x50, 0x1D,
        0xDF, 0xE9, 0x2F, 0x46, 0x68, 0x1B, 0x20, 0xA0,
    };

    /// Big-endian compare a vs b. Returns -1 / 0 / +1.
    pub fn cmpBE(a: []const u8, b: []const u8) i8 {
        std.debug.assert(a.len == b.len);
        for (a, b) |x, y| {
            if (x < y) return -1;
            if (x > y) return 1;
        }
        return 0;
    }

    /// Returns true iff S half of the signature is in canonical low form
    /// (1 <= S <= n/2). Rejects S == 0 and high-S.
    fn isLowS(signature: Signature) bool {
        const s = signature[32..64];
        // Reject S == 0
        var nz: u8 = 0;
        for (s) |b| nz |= b;
        if (nz == 0) return false;
        return cmpBE(s, &HALF_N) <= 0;
    }

    /// Normalize signature to low-S canonical form in-place.
    /// If S > n/2, replace S with n - S. Idempotent.
    fn normalizeLowS(signature: *Signature) void {
        const s = signature[32..64];
        if (cmpBE(s, &HALF_N) <= 0) return;
        // s = n - s (256-bit big-endian subtract, MSB at index 0 -> walk LSB→MSB)
        var borrow: i32 = 0;
        var i: usize = 32;
        while (i > 0) {
            i -= 1;
            const diff: i32 = @as(i32, CURVE_ORDER_N[i]) - @as(i32, s[i]) - borrow;
            if (diff < 0) {
                s[i] = @intCast(diff + 256);
                borrow = 1;
            } else {
                s[i] = @intCast(diff);
                borrow = 0;
            }
        }
    }

    /// Genereaza compressed public key din private key
    pub fn privateKeyToPublicKey(private_key: PrivateKey) !CompressedPubkey {
        const sk = try Ecdsa.SecretKey.fromBytes(private_key);
        const kp = try Ecdsa.KeyPair.fromSecretKey(sk);
        return kp.public_key.toCompressedSec1();
    }

    /// Genereaza adresa Bitcoin-style din private key
    /// privkey → pubkey → SHA256 → SHA256[0..20]
    /// (SHA256[0..20] ca aproximare pentru RIPEMD-160 — see ripemd160.zig for full impl)
    pub fn privateKeyToHash160(private_key: PrivateKey) ![20]u8 {
        const pubkey = try privateKeyToPublicKey(private_key);

        // SHA256(compressed_pubkey)
        var sha256: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(&pubkey, &sha256, .{});

        // RIPEMD160(SHA256(pubkey)) — Hash160 real, identic cu Bitcoin
        var hash160: [20]u8 = undefined;
        Ripemd160.hash(&sha256, &hash160);
        return hash160;
    }

    /// Semneaza un mesaj cu private key (ECDSA secp256k1 + SHA256d)
    pub fn sign(private_key: PrivateKey, message: []const u8) !Signature {
        const sk = try Ecdsa.SecretKey.fromBytes(private_key);
        const kp = try Ecdsa.KeyPair.fromSecretKey(sk);
        const sig = try kp.sign(message, null);
        var bytes = sig.toBytes();
        // Canonical low-S (BIP-146): if S > n/2, replace with n - S.
        // Prevents this codepath from ever emitting a malleable signature
        // even if the underlying stdlib changes.
        normalizeLowS(&bytes);
        return bytes;
    }

    /// Verifica semnatura unui mesaj cu public key
    /// Rejects non-canonical (high-S) and zero-R / zero-S signatures to
    /// eliminate ECDSA malleability (BIP-146 strict).
    pub fn verify(compressed_pubkey: CompressedPubkey, message: []const u8, signature: Signature) bool {
        // Reject R == 0
        var r_nz: u8 = 0;
        for (signature[0..32]) |b| r_nz |= b;
        if (r_nz == 0) return false;
        // Reject S == 0 and high-S (S > n/2)
        if (!isLowS(signature)) return false;

        const pk = Ecdsa.PublicKey.fromSec1(&compressed_pubkey) catch return false;
        const sig = Ecdsa.Signature.fromBytes(signature);
        sig.verify(message, pk) catch return false;
        return true;
    }

    /// Verifica daca o cheie privata e valida (in range [1, n-1]).
    /// Constant-time: ruleaza in timp independent de continutul cheii.
    pub fn isValidPrivateKey(private_key: PrivateKey) bool {
        // Constant-time "is non-zero": OR all bytes; result == 0 iff all zero.
        var nz_acc: u8 = 0;
        for (private_key) |b| nz_acc |= b;
        const non_zero: u1 = @intFromBool(nz_acc != 0);

        const n = [_]u8{
            0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
            0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFE,
            0xBA, 0xAE, 0xDC, 0xE6, 0xAF, 0x48, 0xA0, 0x3B,
            0xBF, 0xD2, 0x5E, 0x8C, 0xD0, 0x36, 0x41, 0x41,
        };

        // Constant-time "private_key < n": compute n - private_key as a
        // 256-bit big-int subtraction, walking LSB→MSB. If a borrow propagates
        // out of the top byte, then private_key > n; otherwise private_key <= n.
        var borrow: u16 = 0;
        var i: usize = 32;
        while (i > 0) {
            i -= 1;
            const diff: u16 = @as(u16, n[i]) -% @as(u16, private_key[i]) -% borrow;
            borrow = (diff >> 15) & 1; // sign bit on underflow
        }
        // borrow == 0 means private_key <= n. We need strict less-than.
        // Detect equality (private_key == n) in constant time.
        var eq_acc: u8 = 0;
        for (private_key, n) |a, b| eq_acc |= a ^ b;
        const not_equal: u1 = @intFromBool(eq_acc != 0);
        const less_or_equal: u1 = @intFromBool(borrow == 0);
        const strictly_less: u1 = less_or_equal & not_equal;

        return (non_zero & strictly_less) == 1;
    }

    /// Genereaza o pereche de chei random (pentru teste/debug)
    pub fn generateKeyPair() !struct { private_key: PrivateKey, public_key: CompressedPubkey } {
        const kp = Ecdsa.KeyPair.generate();
        const sk_bytes = kp.secret_key.toBytes();
        const pk_bytes = kp.public_key.toCompressedSec1();
        return .{ .private_key = sk_bytes, .public_key = pk_bytes };
    }
};

// ─── Teste ───────────────────────────────────────────────────────────────────

const testing = std.testing;

test "secp256k1 — private key la public key" {
    const privkey = [_]u8{
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
    };
    const pubkey = try Secp256k1Crypto.privateKeyToPublicKey(privkey);
    try testing.expectEqual(@as(usize, 33), pubkey.len);
    try testing.expect(pubkey[0] == 0x02 or pubkey[0] == 0x03);
}

test "secp256k1 — aceeasi cheie privata → aceeasi cheie publica" {
    const privkey = [_]u8{0x42} ** 32;
    const pk1 = try Secp256k1Crypto.privateKeyToPublicKey(privkey);
    const pk2 = try Secp256k1Crypto.privateKeyToPublicKey(privkey);
    try testing.expectEqualSlices(u8, &pk1, &pk2);
}

test "secp256k1 — chei private diferite → chei publice diferite" {
    const priv1 = [_]u8{0x01} ** 32;
    const priv2 = [_]u8{0x02} ** 32;
    const pub1 = try Secp256k1Crypto.privateKeyToPublicKey(priv1);
    const pub2 = try Secp256k1Crypto.privateKeyToPublicKey(priv2);
    try testing.expect(!std.mem.eql(u8, &pub1, &pub2));
}

test "secp256k1 — sign si verify" {
    const kp = try Secp256k1Crypto.generateKeyPair();
    const message = "OmniBus OMNI transaction v1";
    const sig = try Secp256k1Crypto.sign(kp.private_key, message);
    const valid = Secp256k1Crypto.verify(kp.public_key, message, sig);
    try testing.expect(valid);
}

test "secp256k1 — verify cu mesaj gresit → false" {
    const kp = try Secp256k1Crypto.generateKeyPair();
    const sig = try Secp256k1Crypto.sign(kp.private_key, "mesaj original");
    const invalid = Secp256k1Crypto.verify(kp.public_key, "mesaj alterat", sig);
    try testing.expect(!invalid);
}

test "secp256k1 — validare cheie privata" {
    try testing.expect(!Secp256k1Crypto.isValidPrivateKey([_]u8{0} ** 32));
    try testing.expect(Secp256k1Crypto.isValidPrivateKey([_]u8{0x42} ** 32));
}

test "secp256k1 — low-S canonical sign output" {
    // Sign should always emit S <= n/2.
    const kp = try Secp256k1Crypto.generateKeyPair();
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        var msg_buf: [16]u8 = undefined;
        std.mem.writeInt(u64, msg_buf[0..8], @intCast(i), .little);
        std.mem.writeInt(u64, msg_buf[8..16], 0xDEADBEEF, .little);
        const sig = try Secp256k1Crypto.sign(kp.private_key, &msg_buf);
        // S half (bytes 32..64) must be <= HALF_N
        try testing.expect(Secp256k1Crypto.cmpBE(sig[32..64], &Secp256k1Crypto.HALF_N) <= 0);
    }
}

test "secp256k1 — verify rejects high-S (malleated) signature" {
    const kp = try Secp256k1Crypto.generateKeyPair();
    const message = "OmniBus malleability test";
    const sig = try Secp256k1Crypto.sign(kp.private_key, message);
    try testing.expect(Secp256k1Crypto.verify(kp.public_key, message, sig));

    // Build the malleated counterpart: S' = n - S. Since our sign() produces
    // low-S, S' is necessarily high-S. The stdlib's bare ECDSA verify would
    // accept it; our wrapper must reject it.
    var malleated = sig;
    // Compute n - S into bytes 32..64.
    var borrow: i32 = 0;
    var idx: usize = 32;
    const n = Secp256k1Crypto.CURVE_ORDER_N;
    while (idx > 0) {
        idx -= 1;
        const diff: i32 = @as(i32, n[idx]) - @as(i32, sig[32 + idx]) - borrow;
        if (diff < 0) {
            malleated[32 + idx] = @intCast(diff + 256);
            borrow = 1;
        } else {
            malleated[32 + idx] = @intCast(diff);
            borrow = 0;
        }
    }
    // Sanity: bytes 0..32 (R) unchanged, bytes 32..64 differ.
    try testing.expect(!std.mem.eql(u8, sig[32..64], malleated[32..64]));
    // Our verify must reject the high-S form.
    try testing.expect(!Secp256k1Crypto.verify(kp.public_key, message, malleated));
}

test "secp256k1 — verify rejects zero-R and zero-S signatures" {
    const kp = try Secp256k1Crypto.generateKeyPair();
    var sig_zero_r: [64]u8 = [_]u8{0} ** 64;
    sig_zero_r[63] = 1; // S = 1 (low-S OK), R = 0
    try testing.expect(!Secp256k1Crypto.verify(kp.public_key, "msg", sig_zero_r));

    var sig_zero_s: [64]u8 = [_]u8{0} ** 64;
    sig_zero_s[31] = 1; // R = 1, S = 0
    try testing.expect(!Secp256k1Crypto.verify(kp.public_key, "msg", sig_zero_s));
}

test "secp256k1 — hash160 din private key (20 bytes)" {
    const privkey = [_]u8{0x42} ** 32;
    const hash = try Secp256k1Crypto.privateKeyToHash160(privkey);
    try testing.expectEqual(@as(usize, 20), hash.len);
}
