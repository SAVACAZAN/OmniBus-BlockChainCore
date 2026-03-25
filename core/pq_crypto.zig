const std = @import("std");

/// Post-Quantum Cryptography via liboqs FFI
/// liboqs static: /home/kiss/liboqs/build/lib/liboqs.a
/// Include:       /home/kiss/liboqs/build/include/
///
/// Algoritmi (NIST FIPS):
///   ML-DSA-87               FIPS 204  — OMNI_LOVE (778), OMNI_RENT (780)
///   Falcon-512              FIPS 206  — OMNI_FOOD (779)
///   SLH-DSA-SHAKE-256s      FIPS 205  — OMNI_VACATION (781)
///   ML-KEM-768              FIPS 203  — encryption

const c = @cImport({
    @cInclude("oqs/oqs.h");
    @cInclude("oqs/sig_ml_dsa.h");
    @cInclude("oqs/sig_falcon.h");
    @cInclude("oqs/sig_slh_dsa.h");
    @cInclude("oqs/kem_ml_kem.h");
});

// ─── ML-DSA-87 (Dilithium-5) — FIPS 204 ─────────────────────────────────────

pub const MlDsa87 = struct {
    pub const PUBLIC_KEY_SIZE : usize = 2592;
    pub const SECRET_KEY_SIZE : usize = 4896;
    pub const SIGNATURE_MAX   : usize = 4627;

    public_key: [PUBLIC_KEY_SIZE]u8,
    secret_key: [SECRET_KEY_SIZE]u8,

    pub fn generateKeyPair() !MlDsa87 {
        var kp: MlDsa87 = undefined;
        const rc = c.OQS_SIG_ml_dsa_87_keypair(&kp.public_key, &kp.secret_key);
        if (rc != c.OQS_SUCCESS) return error.KeyGenFailed;
        return kp;
    }

    pub fn sign(self: *const MlDsa87, message: []const u8, allocator: std.mem.Allocator) ![]u8 {
        const buf = try allocator.alloc(u8, SIGNATURE_MAX);
        errdefer allocator.free(buf);
        var sig_len: usize = SIGNATURE_MAX;
        const rc = c.OQS_SIG_ml_dsa_87_sign(buf.ptr, &sig_len, message.ptr, message.len, &self.secret_key);
        if (rc != c.OQS_SUCCESS) return error.SignFailed;
        return buf[0..sig_len];
    }

    pub fn verify(self: *const MlDsa87, message: []const u8, signature: []const u8) bool {
        const rc = c.OQS_SIG_ml_dsa_87_verify(
            message.ptr, message.len,
            signature.ptr, signature.len,
            &self.public_key,
        );
        return rc == c.OQS_SUCCESS;
    }
};

// ─── Falcon-512 — FIPS 206 ───────────────────────────────────────────────────

pub const Falcon512 = struct {
    pub const PUBLIC_KEY_SIZE : usize = 897;
    pub const SECRET_KEY_SIZE : usize = 1281;
    pub const SIGNATURE_MAX   : usize = 752;

    public_key: [PUBLIC_KEY_SIZE]u8,
    secret_key: [SECRET_KEY_SIZE]u8,

    pub fn generateKeyPair() !Falcon512 {
        var kp: Falcon512 = undefined;
        const rc = c.OQS_SIG_falcon_512_keypair(&kp.public_key, &kp.secret_key);
        if (rc != c.OQS_SUCCESS) return error.KeyGenFailed;
        return kp;
    }

    pub fn sign(self: *const Falcon512, message: []const u8, allocator: std.mem.Allocator) ![]u8 {
        const buf = try allocator.alloc(u8, SIGNATURE_MAX);
        errdefer allocator.free(buf);
        var sig_len: usize = SIGNATURE_MAX;
        const rc = c.OQS_SIG_falcon_512_sign(buf.ptr, &sig_len, message.ptr, message.len, &self.secret_key);
        if (rc != c.OQS_SUCCESS) return error.SignFailed;
        return buf[0..sig_len];
    }

    pub fn verify(self: *const Falcon512, message: []const u8, signature: []const u8) bool {
        const rc = c.OQS_SIG_falcon_512_verify(
            message.ptr, message.len,
            signature.ptr, signature.len,
            &self.public_key,
        );
        return rc == c.OQS_SUCCESS;
    }
};

// ─── SLH-DSA-SHAKE-256s (SPHINCS+) — FIPS 205 ───────────────────────────────

pub const SlhDsa256s = struct {
    pub const PUBLIC_KEY_SIZE : usize = 64;
    pub const SECRET_KEY_SIZE : usize = 128;
    pub const SIGNATURE_MAX   : usize = 29792;

    public_key: [PUBLIC_KEY_SIZE]u8,
    secret_key: [SECRET_KEY_SIZE]u8,

    pub fn generateKeyPair() !SlhDsa256s {
        var kp: SlhDsa256s = undefined;
        const rc = c.OQS_SIG_slh_dsa_pure_shake_256s_keypair(&kp.public_key, &kp.secret_key);
        if (rc != c.OQS_SUCCESS) return error.KeyGenFailed;
        return kp;
    }

    pub fn sign(self: *const SlhDsa256s, message: []const u8, allocator: std.mem.Allocator) ![]u8 {
        const buf = try allocator.alloc(u8, SIGNATURE_MAX);
        errdefer allocator.free(buf);
        var sig_len: usize = SIGNATURE_MAX;
        const rc = c.OQS_SIG_slh_dsa_pure_shake_256s_sign(
            buf.ptr, &sig_len,
            message.ptr, message.len,
            &self.secret_key,
        );
        if (rc != c.OQS_SUCCESS) return error.SignFailed;
        return buf[0..sig_len];
    }

    pub fn verify(self: *const SlhDsa256s, message: []const u8, signature: []const u8) bool {
        const rc = c.OQS_SIG_slh_dsa_pure_shake_256s_verify(
            message.ptr, message.len,
            signature.ptr, signature.len,
            &self.public_key,
        );
        return rc == c.OQS_SUCCESS;
    }
};

// ─── ML-KEM-768 (Kyber-768) — FIPS 203 ──────────────────────────────────────

pub const MlKem768 = struct {
    pub const PUBLIC_KEY_SIZE    : usize = 1184;
    pub const SECRET_KEY_SIZE    : usize = 2400;
    pub const CIPHERTEXT_SIZE    : usize = 1088;
    pub const SHARED_SECRET_SIZE : usize = 32;

    public_key: [PUBLIC_KEY_SIZE]u8,
    secret_key: [SECRET_KEY_SIZE]u8,

    pub fn generateKeyPair() !MlKem768 {
        var kp: MlKem768 = undefined;
        const rc = c.OQS_KEM_ml_kem_768_keypair(&kp.public_key, &kp.secret_key);
        if (rc != c.OQS_SUCCESS) return error.KeyGenFailed;
        return kp;
    }

    pub fn encapsulate(self: *const MlKem768, allocator: std.mem.Allocator) !struct {
        ciphertext: []u8,
        shared_secret: [SHARED_SECRET_SIZE]u8,
    } {
        const ct = try allocator.alloc(u8, CIPHERTEXT_SIZE);
        errdefer allocator.free(ct);
        var ss: [SHARED_SECRET_SIZE]u8 = undefined;
        const rc = c.OQS_KEM_ml_kem_768_encaps(ct.ptr, &ss, &self.public_key);
        if (rc != c.OQS_SUCCESS) return error.EncapsFailed;
        return .{ .ciphertext = ct, .shared_secret = ss };
    }

    pub fn decapsulate(self: *const MlKem768, ciphertext: []const u8) ![SHARED_SECRET_SIZE]u8 {
        var ss: [SHARED_SECRET_SIZE]u8 = undefined;
        const rc = c.OQS_KEM_ml_kem_768_decaps(&ss, ciphertext.ptr, &self.secret_key);
        if (rc != c.OQS_SUCCESS) return error.DecapsFailed;
        return ss;
    }
};

// ─── Alias-uri compatibile cu codul existent ─────────────────────────────────

pub const PQCrypto = struct {
    pub const Dilithium5 = MlDsa87;
    pub const SPHINCSPlus = SlhDsa256s;
    pub const Kyber768 = MlKem768;
};

pub const DomainAlgorithm = enum { MlDsa87, Falcon512, SlhDsa256s };

pub fn algorithmForCoinType(coin_type: u32) ?DomainAlgorithm {
    return switch (coin_type) {
        778 => .MlDsa87,
        779 => .Falcon512,
        780 => .MlDsa87,
        781 => .SlhDsa256s,
        else => null,
    };
}

// ─── Teste ───────────────────────────────────────────────────────────────────

const testing = std.testing;

test "ML-DSA-87 — keypair + sign + verify" {
    const kp = try MlDsa87.generateKeyPair();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const msg = "OmniBus OMNI_LOVE transaction";
    const sig = try kp.sign(msg, arena.allocator());
    try testing.expect(kp.verify(msg, sig));
    try testing.expect(!kp.verify("alterat", sig));
}

test "Falcon-512 — keypair + sign + verify" {
    const kp = try Falcon512.generateKeyPair();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const msg = "OmniBus OMNI_FOOD transaction";
    const sig = try kp.sign(msg, arena.allocator());
    try testing.expect(kp.verify(msg, sig));
    try testing.expect(!kp.verify("mesaj gresit", sig));
}

test "SLH-DSA-256s — keypair + sign + verify" {
    const kp = try SlhDsa256s.generateKeyPair();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const msg = "OmniBus OMNI_VACATION transaction";
    const sig = try kp.sign(msg, arena.allocator());
    try testing.expect(kp.verify(msg, sig));
    try testing.expect(!kp.verify("alterat", sig));
}

test "ML-KEM-768 — encaps + decaps shared secret identic" {
    const kp = try MlKem768.generateKeyPair();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const enc = try kp.encapsulate(arena.allocator());
    const dec = try kp.decapsulate(enc.ciphertext);
    try testing.expectEqualSlices(u8, &enc.shared_secret, &dec);
}

test "algorithmForCoinType — dispatch" {
    try testing.expectEqual(DomainAlgorithm.MlDsa87,    algorithmForCoinType(778).?);
    try testing.expectEqual(DomainAlgorithm.Falcon512,  algorithmForCoinType(779).?);
    try testing.expectEqual(DomainAlgorithm.MlDsa87,    algorithmForCoinType(780).?);
    try testing.expectEqual(DomainAlgorithm.SlhDsa256s, algorithmForCoinType(781).?);
    try testing.expect(algorithmForCoinType(999) == null);
}
