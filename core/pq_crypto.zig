/// Post-Quantum Cryptography — REAL liboqs bindings (gated by -Doqs=true)
///
/// Algoritmi (toti FIPS-compliant via liboqs):
///   ML-DSA-87  (FIPS 204)         — OMNI_LOVE (778), OMNI_RENT (780)
///   Falcon-512 (FIPS 206)         — OMNI_FOOD (779)
///   SLH-DSA-SHA2-256s (FIPS 205)  — OMNI_VACATION (781)  [match @noble]
///   ML-KEM-768 (FIPS 203)         — encryption
///
/// Cand `-Doqs=false`: @cImport este complet omis, toate functiile liboqs-
/// dependente returneaza `error.OqsDisabled`, testele liboqs sunt skip-uite.
/// Struct-urile cu constantele de dimensiune (PUBLIC_KEY_SIZE, SIGNATURE_MAX
/// etc.) raman disponibile mereu — transaction.zig si isolated_wallet.zig
/// au nevoie de ele la compile time.
///
/// Cand `-Doqs=true` (default): comportament identic cu versiunea originala.
///
/// Determinism via OQS_randombytes_custom_algorithm + thread-local SHAKE seed.
/// Mutex global pe keygen deterministic ca sa nu se ciocneasca thread-uri.
///
/// IMPORTANT: caller-ul MUST chema pq_crypto.init() la startup (OQS_init)
/// inainte de orice operatie. Vezi core/main.zig.

const std = @import("std");
const Shake256 = std.crypto.hash.sha3.Shake256;

const build_options = @import("build_options");

/// Comptime constant — true cand liboqs este linked, false altfel.
pub const has_oqs = build_options.oqs_enabled;

// ─── liboqs C bindings (only imported when liboqs is available) ──────────────
//
// The `if (comptime_bool) @cImport(...)` form is valid in Zig 0.13+.
// When has_oqs=false the entire cImport (including header resolution) is
// skipped — the build never touches oqs/oqs.h. `c` becomes an empty struct
// and nothing that references `c.*` is semantically analyzed by the compiler
// (because all such code is inside the `Oqs` comptime-namespace below, which
// is also gated on has_oqs).
const c = if (has_oqs) @cImport({
    @cInclude("oqs/oqs.h");
}) else struct {};

// ─── OQS-dependent implementation (only type-checked when has_oqs=true) ──────
//
// All code that references `c.OQS_*` lives inside this namespace. When
// has_oqs=false the `else struct {}` branch is chosen — the body of the `if`
// branch is NEVER semantically analyzed, so missing C symbols are invisible.
const Oqs = if (has_oqs) struct {

    const DetState = struct {
        var mutex: std.Thread.Mutex = .{};
        var stream: ?Shake256 = null;
    };

    fn deterministicRng(out: [*c]u8, out_len: usize) callconv(.c) void {
        if (DetState.stream) |*s| {
            s.squeeze(out[0..out_len]);
        } else {
            @memset(out[0..out_len], 0);
        }
    }

    fn activateDetRng(seed: []const u8) void {
        DetState.mutex.lock();
        var s = Shake256.init(.{});
        s.update(seed);
        DetState.stream = s;
        c.OQS_randombytes_custom_algorithm(deterministicRng);
    }

    fn deactivateDetRng() void {
        DetState.stream = null;
        _ = c.OQS_randombytes_switch_algorithm("system");
        DetState.mutex.unlock();
    }

    fn newSig(alg_name: [*:0]const u8) !*c.OQS_SIG {
        return c.OQS_SIG_new(alg_name) orelse return OqsSigError.OqsAlgorithmNotEnabled;
    }

    fn newKem() !*c.OQS_KEM {
        return c.OQS_KEM_new(MlKem768.ALG_NAME) orelse return OqsSigError.OqsAlgorithmNotEnabled;
    }

    // ── ML-DSA-87 implementation ───────────────────────────────────────────

    fn mlDsa87KeyPair() !MlDsa87 {
        const sig = try newSig(MlDsa87.ALG_NAME);
        defer c.OQS_SIG_free(sig);
        var kp: MlDsa87 = undefined;
        if (c.OQS_SIG_keypair(sig, &kp.public_key, &kp.secret_key) != c.OQS_SUCCESS)
            return OqsSigError.OqsKeypairFailed;
        return kp;
    }

    fn mlDsa87KeyPairFromSeed(seed: [32]u8) !MlDsa87 {
        activateDetRng(&seed);
        defer deactivateDetRng();
        const sig = c.OQS_SIG_new(MlDsa87.ALG_NAME) orelse return OqsSigError.OqsSigInitFailed;
        defer c.OQS_SIG_free(sig);
        var kp: MlDsa87 = undefined;
        if (c.OQS_SIG_keypair(sig, &kp.public_key, &kp.secret_key) != c.OQS_SUCCESS)
            return OqsSigError.PqKeyGenFailed;
        return kp;
    }

    fn mlDsa87Sign(self: *const MlDsa87, message: []const u8, allocator: std.mem.Allocator) ![]u8 {
        const sig = try newSig(MlDsa87.ALG_NAME);
        defer c.OQS_SIG_free(sig);
        const buf = try allocator.alloc(u8, MlDsa87.SIGNATURE_MAX);
        errdefer allocator.free(buf);
        var sig_len: usize = 0;
        if (c.OQS_SIG_sign(sig, buf.ptr, &sig_len, message.ptr, message.len, &self.secret_key) != c.OQS_SUCCESS)
            return OqsSigError.OqsSignFailed;
        return allocator.realloc(buf, sig_len);
    }

    fn mlDsa87Verify(self: *const MlDsa87, message: []const u8, signature: []const u8) bool {
        if (signature.len > MlDsa87.SIGNATURE_MAX) return false;
        const sig = newSig(MlDsa87.ALG_NAME) catch return false;
        defer c.OQS_SIG_free(sig);
        return c.OQS_SIG_verify(sig, message.ptr, message.len, signature.ptr, signature.len, &self.public_key) == c.OQS_SUCCESS;
    }

    // ── Falcon-512 implementation ──────────────────────────────────────────

    fn falcon512KeyPair() !Falcon512 {
        const sig = try newSig(Falcon512.ALG_NAME);
        defer c.OQS_SIG_free(sig);
        var kp: Falcon512 = undefined;
        if (c.OQS_SIG_keypair(sig, &kp.public_key, &kp.secret_key) != c.OQS_SUCCESS)
            return OqsSigError.OqsKeypairFailed;
        return kp;
    }

    fn falcon512KeyPairFromSeed(seed: [48]u8) !Falcon512 {
        activateDetRng(&seed);
        defer deactivateDetRng();
        const sig = c.OQS_SIG_new(Falcon512.ALG_NAME) orelse return OqsSigError.OqsSigInitFailed;
        defer c.OQS_SIG_free(sig);
        var kp: Falcon512 = undefined;
        if (c.OQS_SIG_keypair(sig, &kp.public_key, &kp.secret_key) != c.OQS_SUCCESS)
            return OqsSigError.PqKeyGenFailed;
        return kp;
    }

    fn falcon512Sign(self: *const Falcon512, message: []const u8, allocator: std.mem.Allocator) ![]u8 {
        const sig = try newSig(Falcon512.ALG_NAME);
        defer c.OQS_SIG_free(sig);
        const buf = try allocator.alloc(u8, Falcon512.SIGNATURE_MAX);
        errdefer allocator.free(buf);
        var sig_len: usize = 0;
        if (c.OQS_SIG_sign(sig, buf.ptr, &sig_len, message.ptr, message.len, &self.secret_key) != c.OQS_SUCCESS)
            return OqsSigError.OqsSignFailed;
        return allocator.realloc(buf, sig_len);
    }

    fn falcon512Verify(self: *const Falcon512, message: []const u8, signature: []const u8) bool {
        if (signature.len > Falcon512.SIGNATURE_MAX) return false;
        const sig = newSig(Falcon512.ALG_NAME) catch return false;
        defer c.OQS_SIG_free(sig);
        return c.OQS_SIG_verify(sig, message.ptr, message.len, signature.ptr, signature.len, &self.public_key) == c.OQS_SUCCESS;
    }

    // ── SLH-DSA-SHA2-256s implementation ──────────────────────────────────

    fn slhDsa256sKeyPair() !SlhDsa256s {
        const sig = try newSig(SlhDsa256s.ALG_NAME);
        defer c.OQS_SIG_free(sig);
        var kp: SlhDsa256s = undefined;
        if (c.OQS_SIG_keypair(sig, &kp.public_key, &kp.secret_key) != c.OQS_SUCCESS)
            return OqsSigError.OqsKeypairFailed;
        return kp;
    }

    fn slhDsa256sKeyPairFromSeed(sk_seed: [32]u8, sk_prf: [32]u8, pk_seed: [32]u8) !SlhDsa256s {
        var combined: [96]u8 = undefined;
        @memcpy(combined[0..32], &sk_seed);
        @memcpy(combined[32..64], &sk_prf);
        @memcpy(combined[64..96], &pk_seed);
        activateDetRng(&combined);
        defer deactivateDetRng();
        const sig = c.OQS_SIG_new(SlhDsa256s.ALG_NAME) orelse return OqsSigError.OqsSigInitFailed;
        defer c.OQS_SIG_free(sig);
        var kp: SlhDsa256s = undefined;
        if (c.OQS_SIG_keypair(sig, &kp.public_key, &kp.secret_key) != c.OQS_SUCCESS)
            return OqsSigError.PqKeyGenFailed;
        return kp;
    }

    fn slhDsa256sSign(self: *const SlhDsa256s, message: []const u8, allocator: std.mem.Allocator) ![]u8 {
        const sig = try newSig(SlhDsa256s.ALG_NAME);
        defer c.OQS_SIG_free(sig);
        const buf = try allocator.alloc(u8, SlhDsa256s.SIGNATURE_MAX);
        errdefer allocator.free(buf);
        var sig_len: usize = 0;
        if (c.OQS_SIG_sign(sig, buf.ptr, &sig_len, message.ptr, message.len, &self.secret_key) != c.OQS_SUCCESS)
            return OqsSigError.OqsSignFailed;
        return allocator.realloc(buf, sig_len);
    }

    fn slhDsa256sVerify(self: *const SlhDsa256s, message: []const u8, signature: []const u8) bool {
        if (signature.len > SlhDsa256s.SIGNATURE_MAX) return false;
        const sig = newSig(SlhDsa256s.ALG_NAME) catch return false;
        defer c.OQS_SIG_free(sig);
        return c.OQS_SIG_verify(sig, message.ptr, message.len, signature.ptr, signature.len, &self.public_key) == c.OQS_SUCCESS;
    }

    // ── ML-KEM-768 implementation ──────────────────────────────────────────

    fn mlKem768KeyPair() !MlKem768 {
        const kem = try newKem();
        defer c.OQS_KEM_free(kem);
        var kp: MlKem768 = undefined;
        if (c.OQS_KEM_keypair(kem, &kp.public_key, &kp.secret_key) != c.OQS_SUCCESS)
            return OqsSigError.OqsKeypairFailed;
        return kp;
    }

    fn mlKem768KeyPairFromSeed(d: [32]u8) !MlKem768 {
        activateDetRng(&d);
        defer deactivateDetRng();
        const kem = c.OQS_KEM_new(MlKem768.ALG_NAME) orelse return OqsSigError.OqsSigInitFailed;
        defer c.OQS_KEM_free(kem);
        var kp: MlKem768 = undefined;
        if (c.OQS_KEM_keypair(kem, &kp.public_key, &kp.secret_key) != c.OQS_SUCCESS)
            return OqsSigError.PqKeyGenFailed;
        return kp;
    }

    fn mlKem768Encapsulate(self: *const MlKem768, allocator: std.mem.Allocator) !struct {
        ciphertext: []u8,
        shared_secret: [MlKem768.SHARED_SECRET_SIZE]u8,
    } {
        const kem = try newKem();
        defer c.OQS_KEM_free(kem);
        const ct = try allocator.alloc(u8, MlKem768.CIPHERTEXT_SIZE);
        errdefer allocator.free(ct);
        var ss: [MlKem768.SHARED_SECRET_SIZE]u8 = undefined;
        if (c.OQS_KEM_encaps(kem, ct.ptr, &ss, &self.public_key) != c.OQS_SUCCESS)
            return OqsSigError.OqsKeypairFailed;
        return .{ .ciphertext = ct, .shared_secret = ss };
    }

    fn mlKem768Decapsulate(self: *const MlKem768, ciphertext: []const u8) ![MlKem768.SHARED_SECRET_SIZE]u8 {
        if (ciphertext.len != MlKem768.CIPHERTEXT_SIZE) return error.InvalidCiphertext;
        const kem = try newKem();
        defer c.OQS_KEM_free(kem);
        var ss: [MlKem768.SHARED_SECRET_SIZE]u8 = undefined;
        if (c.OQS_KEM_decaps(kem, &ss, ciphertext.ptr, &self.secret_key) != c.OQS_SUCCESS)
            return OqsSigError.OqsKeypairFailed;
        return ss;
    }

    // ── mldsaSign / mldsaVerify (wallet.zig compat) ────────────────────────

    fn mldsaSign(allocator: std.mem.Allocator, sk: []const u8, msg: []const u8) ![]u8 {
        if (sk.len != MlDsa87.SECRET_KEY_SIZE) return OqsSigError.InvalidKeySize;
        const sig = try newSig(MlDsa87.ALG_NAME);
        defer c.OQS_SIG_free(sig);
        const buf = try allocator.alloc(u8, MlDsa87.SIGNATURE_MAX);
        errdefer allocator.free(buf);
        var sig_len: usize = 0;
        if (c.OQS_SIG_sign(sig, buf.ptr, &sig_len, msg.ptr, msg.len, sk.ptr) != c.OQS_SUCCESS)
            return OqsSigError.OqsSignFailed;
        return allocator.realloc(buf, sig_len);
    }

    fn mldsaVerify(pk: []const u8, msg: []const u8, sig: []const u8) bool {
        if (pk.len != MlDsa87.PUBLIC_KEY_SIZE) return false;
        if (sig.len > MlDsa87.SIGNATURE_MAX) return false;
        const ctx = newSig(MlDsa87.ALG_NAME) catch return false;
        defer c.OQS_SIG_free(ctx);
        return c.OQS_SIG_verify(ctx, msg.ptr, msg.len, sig.ptr, sig.len, pk.ptr) == c.OQS_SUCCESS;
    }

} else struct {};

// ─── Init / cleanup ──────────────────────────────────────────────────────────

/// Trebuie chemat o singura data la startup (initializeaza OQS internals,
/// CPU feature detection, etc). Cand OQS e dezactivat, este no-op.
pub fn init() void {
    if (!has_oqs) return;
    c.OQS_init();
}

pub fn destroy() void {
    if (!has_oqs) return;
    c.OQS_destroy();
}

// ─── Error set ───────────────────────────────────────────────────────────────

pub const OqsSigError = error{
    OqsDisabled,
    OqsAlgorithmNotEnabled,
    OqsKeypairFailed,
    OqsSignFailed,
    OqsVerifyFailed,
    InvalidKeySize,
    InvalidSignatureSize,
    SignatureTooLarge,
    PqKeyGenFailed,
    OqsSigInitFailed,
    OutOfMemory,
};

// ─── ML-DSA-87 (Dilithium-5) — FIPS 204 ──────────────────────────────────────

pub const MlDsa87 = struct {
    pub const PUBLIC_KEY_SIZE: usize = 2592;
    pub const SECRET_KEY_SIZE: usize = 4896;
    pub const SIGNATURE_MAX:   usize = 4627;

    public_key: [PUBLIC_KEY_SIZE]u8,
    secret_key: [SECRET_KEY_SIZE]u8,

    pub const ALG_NAME: [*:0]const u8 = "ML-DSA-87";

    pub fn generateKeyPair() !MlDsa87 {
        if (!has_oqs) return OqsSigError.OqsDisabled;
        return Oqs.mlDsa87KeyPair();
    }

    /// Determinist din seed (pentru HD-wallet derivation).
    pub fn generateKeyPairFromSeed(seed: [32]u8) !MlDsa87 {
        if (!has_oqs) return OqsSigError.OqsDisabled;
        return Oqs.mlDsa87KeyPairFromSeed(seed);
    }

    pub fn sign(self: *const MlDsa87, message: []const u8, allocator: std.mem.Allocator) ![]u8 {
        if (!has_oqs) return OqsSigError.OqsDisabled;
        return Oqs.mlDsa87Sign(self, message, allocator);
    }

    pub fn verify(self: *const MlDsa87, message: []const u8, signature: []const u8) bool {
        if (!has_oqs) return false;
        return Oqs.mlDsa87Verify(self, message, signature);
    }
};

// ─── Falcon-512 — FIPS 206 ────────────────────────────────────────────────────

pub const Falcon512 = struct {
    pub const PUBLIC_KEY_SIZE: usize = 897;
    pub const SECRET_KEY_SIZE: usize = 1281;
    pub const SIGNATURE_MAX:   usize = 752;

    public_key: [PUBLIC_KEY_SIZE]u8,
    secret_key: [SECRET_KEY_SIZE]u8,

    pub const ALG_NAME: [*:0]const u8 = "Falcon-512";

    pub fn generateKeyPair() !Falcon512 {
        if (!has_oqs) return OqsSigError.OqsDisabled;
        return Oqs.falcon512KeyPair();
    }

    pub fn generateKeyPairFromSeed(seed: [48]u8) !Falcon512 {
        if (!has_oqs) return OqsSigError.OqsDisabled;
        return Oqs.falcon512KeyPairFromSeed(seed);
    }

    pub fn sign(self: *const Falcon512, message: []const u8, allocator: std.mem.Allocator) ![]u8 {
        if (!has_oqs) return OqsSigError.OqsDisabled;
        return Oqs.falcon512Sign(self, message, allocator);
    }

    pub fn verify(self: *const Falcon512, message: []const u8, signature: []const u8) bool {
        if (!has_oqs) return false;
        return Oqs.falcon512Verify(self, message, signature);
    }
};

// ─── SLH-DSA-SHA2-256s (SPHINCS+ standard) — FIPS 205 ────────────────────────
// Match cu @noble/post-quantum slh_dsa_sha2_256s (SHA2_SIMPLE variant)

pub const SlhDsa256s = struct {
    pub const PUBLIC_KEY_SIZE: usize = 64;
    pub const SECRET_KEY_SIZE: usize = 128;
    pub const SIGNATURE_MAX:   usize = 29792;

    public_key: [PUBLIC_KEY_SIZE]u8,
    secret_key: [SECRET_KEY_SIZE]u8,

    pub const ALG_NAME: [*:0]const u8 = "SLH_DSA_PURE_SHA2_256S";

    pub fn generateKeyPair() !SlhDsa256s {
        if (!has_oqs) return OqsSigError.OqsDisabled;
        return Oqs.slhDsa256sKeyPair();
    }

    /// API-compatibility cu vechiul cod care lua 3 seed-uri (sk_seed, sk_prf, pk_seed).
    pub fn generateKeyPairFromSeed(sk_seed: [32]u8, sk_prf: [32]u8, pk_seed: [32]u8) !SlhDsa256s {
        if (!has_oqs) return OqsSigError.OqsDisabled;
        return Oqs.slhDsa256sKeyPairFromSeed(sk_seed, sk_prf, pk_seed);
    }

    pub fn sign(self: *const SlhDsa256s, message: []const u8, allocator: std.mem.Allocator) ![]u8 {
        if (!has_oqs) return OqsSigError.OqsDisabled;
        return Oqs.slhDsa256sSign(self, message, allocator);
    }

    pub fn verify(self: *const SlhDsa256s, message: []const u8, signature: []const u8) bool {
        if (!has_oqs) return false;
        return Oqs.slhDsa256sVerify(self, message, signature);
    }
};

// ─── ML-KEM-768 (Kyber-768) — FIPS 203 ───────────────────────────────────────

pub const MlKem768 = struct {
    pub const PUBLIC_KEY_SIZE:    usize = 1184;
    pub const SECRET_KEY_SIZE:    usize = 2400;
    pub const CIPHERTEXT_SIZE:    usize = 1088;
    pub const SHARED_SECRET_SIZE: usize = 32;

    public_key: [PUBLIC_KEY_SIZE]u8,
    secret_key: [SECRET_KEY_SIZE]u8,

    pub const ALG_NAME: [*:0]const u8 = "ML-KEM-768";

    pub fn generateKeyPair() !MlKem768 {
        if (!has_oqs) return OqsSigError.OqsDisabled;
        return Oqs.mlKem768KeyPair();
    }

    pub fn generateKeyPairFromSeed(d: [32]u8) !MlKem768 {
        if (!has_oqs) return OqsSigError.OqsDisabled;
        return Oqs.mlKem768KeyPairFromSeed(d);
    }

    pub fn encapsulate(self: *const MlKem768, allocator: std.mem.Allocator) !struct {
        ciphertext: []u8,
        shared_secret: [SHARED_SECRET_SIZE]u8,
    } {
        if (!has_oqs) return OqsSigError.OqsDisabled;
        return Oqs.mlKem768Encapsulate(self, allocator);
    }

    pub fn decapsulate(self: *const MlKem768, ciphertext: []const u8) ![SHARED_SECRET_SIZE]u8 {
        if (!has_oqs) return OqsSigError.OqsDisabled;
        return Oqs.mlKem768Decapsulate(self, ciphertext);
    }
};

// ─── Functii exported pentru wallet.zig (compat cu vechiul API) ──────────────

pub fn mldsaSign(
    allocator: std.mem.Allocator,
    sk:        []const u8,
    msg:       []const u8,
) ![]u8 {
    if (!has_oqs) return OqsSigError.OqsDisabled;
    return Oqs.mldsaSign(allocator, sk, msg);
}

pub fn mldsaVerify(
    pk:  []const u8,
    msg: []const u8,
    sig: []const u8,
) bool {
    if (!has_oqs) return false;
    return Oqs.mldsaVerify(pk, msg, sig);
}

// ─── Alias-uri compatibile ───────────────────────────────────────────────────

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

test "init OQS" {
    init();
}

test "algorithmForCoinType dispatch" {
    try testing.expectEqual(DomainAlgorithm.MlDsa87,    algorithmForCoinType(778).?);
    try testing.expectEqual(DomainAlgorithm.Falcon512,  algorithmForCoinType(779).?);
    try testing.expectEqual(DomainAlgorithm.MlDsa87,    algorithmForCoinType(780).?);
    try testing.expectEqual(DomainAlgorithm.SlhDsa256s, algorithmForCoinType(781).?);
    try testing.expect(algorithmForCoinType(999) == null);
}

test "ML-DSA-87 — keypair generation (real liboqs)" {
    if (!has_oqs) return error.SkipZigTest;
    init();
    const kp = try MlDsa87.generateKeyPair();
    var all_zero = true;
    for (kp.public_key) |b| if (b != 0) { all_zero = false; break; };
    try testing.expect(!all_zero);
}

test "ML-DSA-87 — sign + verify roundtrip (real)" {
    if (!has_oqs) return error.SkipZigTest;
    init();
    const kp = try MlDsa87.generateKeyPair();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const msg = "OmniBus OMNI_LOVE transaction";
    const sig = try kp.sign(msg, arena.allocator());
    try testing.expect(kp.verify(msg, sig));
}

test "ML-DSA-87 — verify fails on tampered message" {
    if (!has_oqs) return error.SkipZigTest;
    init();
    const kp = try MlDsa87.generateKeyPair();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const msg = "OmniBus OMNI_LOVE transaction";
    const sig = try kp.sign(msg, arena.allocator());
    try testing.expect(!kp.verify("tampered", sig));
}

test "ML-DSA-87 — verify fails on tampered signature" {
    if (!has_oqs) return error.SkipZigTest;
    init();
    const kp = try MlDsa87.generateKeyPair();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const msg = "OmniBus OMNI_LOVE transaction";
    const sig = try kp.sign(msg, arena.allocator());
    sig[10] ^= 0xFF;
    try testing.expect(!kp.verify(msg, sig));
}

test "ML-DSA-87 — deterministic from seed" {
    if (!has_oqs) return error.SkipZigTest;
    init();
    const seed: [32]u8 = .{1} ** 32;
    const kp1 = try MlDsa87.generateKeyPairFromSeed(seed);
    const kp2 = try MlDsa87.generateKeyPairFromSeed(seed);
    try testing.expectEqualSlices(u8, &kp1.public_key, &kp2.public_key);
    try testing.expectEqualSlices(u8, &kp1.secret_key, &kp2.secret_key);
}

test "Falcon-512 — sign + verify" {
    if (!has_oqs) return error.SkipZigTest;
    init();
    const kp = try Falcon512.generateKeyPair();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const msg = "OmniBus OMNI_FOOD transaction";
    const sig = try kp.sign(msg, arena.allocator());
    try testing.expect(kp.verify(msg, sig));
}

test "Falcon-512 — cross-key verify fails" {
    if (!has_oqs) return error.SkipZigTest;
    init();
    const kp1 = try Falcon512.generateKeyPair();
    const kp2 = try Falcon512.generateKeyPair();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const msg = "test";
    const sig1 = try kp1.sign(msg, arena.allocator());
    try testing.expect(!kp2.verify(msg, sig1));
}

test "SLH-DSA-SHA2-256s — sign + verify" {
    if (!has_oqs) return error.SkipZigTest;
    init();
    const kp = try SlhDsa256s.generateKeyPair();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const msg = "OmniBus OMNI_VACATION transaction";
    const sig = try kp.sign(msg, arena.allocator());
    try testing.expect(kp.verify(msg, sig));
}

test "ML-KEM-768 — encaps + decaps shared secret matches" {
    if (!has_oqs) return error.SkipZigTest;
    init();
    const kp = try MlKem768.generateKeyPair();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const enc = try kp.encapsulate(arena.allocator());
    const dec = try kp.decapsulate(enc.ciphertext);
    try testing.expectEqualSlices(u8, &enc.shared_secret, &dec);
}
