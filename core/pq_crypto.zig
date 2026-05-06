/// Post-Quantum Cryptography — REAL liboqs bindings
///
/// Algoritmi (toti FIPS-compliant via liboqs):
///   ML-DSA-87  (FIPS 204)         — OMNI_LOVE (778), OMNI_RENT (780)
///   Falcon-512 (FIPS 206)         — OMNI_FOOD (779)
///   SLH-DSA-SHA2-256s (FIPS 205)  — OMNI_VACATION (781)  [match @noble]
///   ML-KEM-768 (FIPS 203)         — encryption
///
/// Determinism via OQS_randombytes_custom_algorithm + thread-local SHAKE seed.
/// Mutex global pe keygen deterministic ca sa nu se ciocneasca thread-uri.
///
/// IMPORTANT: caller-ul MUST chema pq_crypto.init() la startup (OQS_init)
/// inainte de orice operatie. Vezi core/main.zig.

const std = @import("std");
const Shake256 = std.crypto.hash.sha3.Shake256;

// ─── liboqs C bindings ───────────────────────────────────────────────────────

const c = @cImport({
    @cInclude("oqs/oqs.h");
});

// ─── Init / cleanup ──────────────────────────────────────────────────────────

/// Trebuie chemat o singura data la startup (initializeaza OQS internals,
/// CPU feature detection, etc).
pub fn init() void {
    c.OQS_init();
}

pub fn destroy() void {
    c.OQS_destroy();
}

// ─── RNG injection pentru determinism ────────────────────────────────────────

/// State-ul RNG-ului deterministic. Folosit doar in timpul generateKeyPairFromSeed.
/// Mutex global protejeaza impotriva thread-urilor concurente.
const DetState = struct {
    var mutex: std.Thread.Mutex = .{};
    var stream: ?Shake256 = null;
};

/// Callback pe care il apeleaza liboqs in loc de OS RNG cand vrem determinism.
fn deterministicRng(out: [*c]u8, out_len: usize) callconv(.c) void {
    if (DetState.stream) |*s| {
        s.squeeze(out[0..out_len]);
    } else {
        // Fallback: daca cumva apeleaza fara stream (bug), umple cu zero.
        // Acesta e o stare de eroare — n-ar trebui sa se intample niciodata.
        @memset(out[0..out_len], 0);
    }
}

/// Activeaza RNG-ul deterministic cu seed-ul dat. Tine mutex-ul deschis pana la deactivate.
fn activateDetRng(seed: []const u8) void {
    DetState.mutex.lock();
    var s = Shake256.init(.{});
    s.update(seed);
    DetState.stream = s;
    c.OQS_randombytes_custom_algorithm(deterministicRng);
}

/// Restaureaza RNG-ul OS si elibereaza mutex-ul.
fn deactivateDetRng() void {
    DetState.stream = null;
    // Switch back to system RNG (OS-provided).
    _ = c.OQS_randombytes_switch_algorithm("system");
    DetState.mutex.unlock();
}

// ─── Helper: wrapper peste OQS_SIG_new ───────────────────────────────────────

const OqsSigError = error{
    OqsAlgorithmNotEnabled,
    OqsKeypairFailed,
    OqsSignFailed,
    OqsVerifyFailed,
    InvalidKeySize,
    InvalidSignatureSize,
    OutOfMemory,
};

fn newSig(alg_name: [*:0]const u8) !*c.OQS_SIG {
    return c.OQS_SIG_new(alg_name) orelse return OqsSigError.OqsAlgorithmNotEnabled;
}

// ─── ML-DSA-87 (Dilithium-5) — FIPS 204 ───────────────────────────────────────

pub const MlDsa87 = struct {
    pub const PUBLIC_KEY_SIZE: usize = 2592;
    pub const SECRET_KEY_SIZE: usize = 4896;
    pub const SIGNATURE_MAX:   usize = 4627;

    public_key: [PUBLIC_KEY_SIZE]u8,
    secret_key: [SECRET_KEY_SIZE]u8,

    pub const ALG_NAME: [*:0]const u8 = "ML-DSA-87";

    pub fn generateKeyPair() !MlDsa87 {
        const sig = try newSig(ALG_NAME);
        defer c.OQS_SIG_free(sig);

        var kp: MlDsa87 = undefined;
        const rc = c.OQS_SIG_keypair(sig, &kp.public_key, &kp.secret_key);
        if (rc != c.OQS_SUCCESS) return OqsSigError.OqsKeypairFailed;
        return kp;
    }

    /// Determinist din seed (pentru HD-wallet derivation).
    pub fn generateKeyPairFromSeed(seed: [32]u8) MlDsa87 {
        activateDetRng(&seed);
        defer deactivateDetRng();

        const sig = c.OQS_SIG_new(ALG_NAME) orelse {
            // Fallback la zeroed key — caller ar trebui sa detecteze.
            return std.mem.zeroes(MlDsa87);
        };
        defer c.OQS_SIG_free(sig);

        var kp: MlDsa87 = undefined;
        const rc = c.OQS_SIG_keypair(sig, &kp.public_key, &kp.secret_key);
        if (rc != c.OQS_SUCCESS) return std.mem.zeroes(MlDsa87);
        return kp;
    }

    pub fn sign(self: *const MlDsa87, message: []const u8, allocator: std.mem.Allocator) ![]u8 {
        const sig = try newSig(ALG_NAME);
        defer c.OQS_SIG_free(sig);

        const buf = try allocator.alloc(u8, SIGNATURE_MAX);
        errdefer allocator.free(buf);

        var sig_len: usize = 0;
        const rc = c.OQS_SIG_sign(
            sig,
            buf.ptr, &sig_len,
            message.ptr, message.len,
            &self.secret_key,
        );
        if (rc != c.OQS_SUCCESS) return OqsSigError.OqsSignFailed;

        return allocator.realloc(buf, sig_len);
    }

    pub fn verify(self: *const MlDsa87, message: []const u8, signature: []const u8) bool {
        const sig = newSig(ALG_NAME) catch return false;
        defer c.OQS_SIG_free(sig);

        return c.OQS_SIG_verify(
            sig,
            message.ptr, message.len,
            signature.ptr, signature.len,
            &self.public_key,
        ) == c.OQS_SUCCESS;
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
        const sig = try newSig(ALG_NAME);
        defer c.OQS_SIG_free(sig);

        var kp: Falcon512 = undefined;
        const rc = c.OQS_SIG_keypair(sig, &kp.public_key, &kp.secret_key);
        if (rc != c.OQS_SUCCESS) return OqsSigError.OqsKeypairFailed;
        return kp;
    }

    pub fn generateKeyPairFromSeed(seed: [48]u8) Falcon512 {
        activateDetRng(&seed);
        defer deactivateDetRng();

        const sig = c.OQS_SIG_new(ALG_NAME) orelse return std.mem.zeroes(Falcon512);
        defer c.OQS_SIG_free(sig);

        var kp: Falcon512 = undefined;
        const rc = c.OQS_SIG_keypair(sig, &kp.public_key, &kp.secret_key);
        if (rc != c.OQS_SUCCESS) return std.mem.zeroes(Falcon512);
        return kp;
    }

    pub fn sign(self: *const Falcon512, message: []const u8, allocator: std.mem.Allocator) ![]u8 {
        const sig = try newSig(ALG_NAME);
        defer c.OQS_SIG_free(sig);

        const buf = try allocator.alloc(u8, SIGNATURE_MAX);
        errdefer allocator.free(buf);

        var sig_len: usize = 0;
        const rc = c.OQS_SIG_sign(
            sig,
            buf.ptr, &sig_len,
            message.ptr, message.len,
            &self.secret_key,
        );
        if (rc != c.OQS_SUCCESS) return OqsSigError.OqsSignFailed;

        // Falcon are signatures variabile (~600-752B) — realloc la real
        return allocator.realloc(buf, sig_len);
    }

    pub fn verify(self: *const Falcon512, message: []const u8, signature: []const u8) bool {
        const sig = newSig(ALG_NAME) catch return false;
        defer c.OQS_SIG_free(sig);

        return c.OQS_SIG_verify(
            sig,
            message.ptr, message.len,
            signature.ptr, signature.len,
            &self.public_key,
        ) == c.OQS_SUCCESS;
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
        const sig = try newSig(ALG_NAME);
        defer c.OQS_SIG_free(sig);

        var kp: SlhDsa256s = undefined;
        const rc = c.OQS_SIG_keypair(sig, &kp.public_key, &kp.secret_key);
        if (rc != c.OQS_SUCCESS) return OqsSigError.OqsKeypairFailed;
        return kp;
    }

    /// API-compatibility cu vechiul cod care lua 3 seed-uri (sk_seed, sk_prf, pk_seed).
    /// Le concatenam intr-un singur seed de 96 bytes pentru SHAKE stream.
    pub fn generateKeyPairFromSeed(sk_seed: [32]u8, sk_prf: [32]u8, pk_seed: [32]u8) SlhDsa256s {
        var combined: [96]u8 = undefined;
        @memcpy(combined[0..32], &sk_seed);
        @memcpy(combined[32..64], &sk_prf);
        @memcpy(combined[64..96], &pk_seed);

        activateDetRng(&combined);
        defer deactivateDetRng();

        const sig = c.OQS_SIG_new(ALG_NAME) orelse return std.mem.zeroes(SlhDsa256s);
        defer c.OQS_SIG_free(sig);

        var kp: SlhDsa256s = undefined;
        const rc = c.OQS_SIG_keypair(sig, &kp.public_key, &kp.secret_key);
        if (rc != c.OQS_SUCCESS) return std.mem.zeroes(SlhDsa256s);
        return kp;
    }

    pub fn sign(self: *const SlhDsa256s, message: []const u8, allocator: std.mem.Allocator) ![]u8 {
        const sig = try newSig(ALG_NAME);
        defer c.OQS_SIG_free(sig);

        // ATENTIE: 29792 bytes, NU pe stack — heap allocation obligatorie
        const buf = try allocator.alloc(u8, SIGNATURE_MAX);
        errdefer allocator.free(buf);

        var sig_len: usize = 0;
        const rc = c.OQS_SIG_sign(
            sig,
            buf.ptr, &sig_len,
            message.ptr, message.len,
            &self.secret_key,
        );
        if (rc != c.OQS_SUCCESS) return OqsSigError.OqsSignFailed;

        return allocator.realloc(buf, sig_len);
    }

    pub fn verify(self: *const SlhDsa256s, message: []const u8, signature: []const u8) bool {
        const sig = newSig(ALG_NAME) catch return false;
        defer c.OQS_SIG_free(sig);

        return c.OQS_SIG_verify(
            sig,
            message.ptr, message.len,
            signature.ptr, signature.len,
            &self.public_key,
        ) == c.OQS_SUCCESS;
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

    fn newKem() !*c.OQS_KEM {
        return c.OQS_KEM_new(ALG_NAME) orelse return OqsSigError.OqsAlgorithmNotEnabled;
    }

    pub fn generateKeyPair() !MlKem768 {
        const kem = try newKem();
        defer c.OQS_KEM_free(kem);

        var kp: MlKem768 = undefined;
        const rc = c.OQS_KEM_keypair(kem, &kp.public_key, &kp.secret_key);
        if (rc != c.OQS_SUCCESS) return OqsSigError.OqsKeypairFailed;
        return kp;
    }

    pub fn generateKeyPairFromSeed(d: [32]u8) MlKem768 {
        activateDetRng(&d);
        defer deactivateDetRng();

        const kem = c.OQS_KEM_new(ALG_NAME) orelse return std.mem.zeroes(MlKem768);
        defer c.OQS_KEM_free(kem);

        var kp: MlKem768 = undefined;
        const rc = c.OQS_KEM_keypair(kem, &kp.public_key, &kp.secret_key);
        if (rc != c.OQS_SUCCESS) return std.mem.zeroes(MlKem768);
        return kp;
    }

    pub fn encapsulate(self: *const MlKem768, allocator: std.mem.Allocator) !struct {
        ciphertext: []u8,
        shared_secret: [SHARED_SECRET_SIZE]u8,
    } {
        const kem = try newKem();
        defer c.OQS_KEM_free(kem);

        const ct = try allocator.alloc(u8, CIPHERTEXT_SIZE);
        errdefer allocator.free(ct);

        var ss: [SHARED_SECRET_SIZE]u8 = undefined;
        const rc = c.OQS_KEM_encaps(kem, ct.ptr, &ss, &self.public_key);
        if (rc != c.OQS_SUCCESS) return OqsSigError.OqsKeypairFailed;

        return .{ .ciphertext = ct, .shared_secret = ss };
    }

    pub fn decapsulate(self: *const MlKem768, ciphertext: []const u8) ![SHARED_SECRET_SIZE]u8 {
        if (ciphertext.len != CIPHERTEXT_SIZE) return error.InvalidCiphertext;

        const kem = try newKem();
        defer c.OQS_KEM_free(kem);

        var ss: [SHARED_SECRET_SIZE]u8 = undefined;
        const rc = c.OQS_KEM_decaps(kem, &ss, ciphertext.ptr, &self.secret_key);
        if (rc != c.OQS_SUCCESS) return OqsSigError.OqsKeypairFailed;
        return ss;
    }
};

// ─── Functii exported pentru wallet.zig (compat cu vechiul API) ──────────────

pub fn mldsaSign(
    allocator: std.mem.Allocator,
    sk:        []const u8,
    msg:       []const u8,
) ![]u8 {
    if (sk.len != MlDsa87.SECRET_KEY_SIZE) return OqsSigError.InvalidKeySize;

    const sig = try newSig(MlDsa87.ALG_NAME);
    defer c.OQS_SIG_free(sig);

    const buf = try allocator.alloc(u8, MlDsa87.SIGNATURE_MAX);
    errdefer allocator.free(buf);

    var sig_len: usize = 0;
    const rc = c.OQS_SIG_sign(
        sig,
        buf.ptr, &sig_len,
        msg.ptr, msg.len,
        sk.ptr,
    );
    if (rc != c.OQS_SUCCESS) return OqsSigError.OqsSignFailed;

    return allocator.realloc(buf, sig_len);
}

pub fn mldsaVerify(
    pk:  []const u8,
    msg: []const u8,
    sig: []const u8,
) bool {
    if (pk.len != MlDsa87.PUBLIC_KEY_SIZE) return false;

    const ctx = newSig(MlDsa87.ALG_NAME) catch return false;
    defer c.OQS_SIG_free(ctx);

    return c.OQS_SIG_verify(
        ctx,
        msg.ptr, msg.len,
        sig.ptr, sig.len,
        pk.ptr,
    ) == c.OQS_SUCCESS;
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

test "ML-DSA-87 — keypair generation (real liboqs)" {
    init();
    const kp = try MlDsa87.generateKeyPair();
    var all_zero = true;
    for (kp.public_key) |b| if (b != 0) { all_zero = false; break; };
    try testing.expect(!all_zero);
}

test "ML-DSA-87 — sign + verify roundtrip (real)" {
    init();
    const kp = try MlDsa87.generateKeyPair();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const msg = "OmniBus OMNI_LOVE transaction";
    const sig = try kp.sign(msg, arena.allocator());
    try testing.expect(kp.verify(msg, sig));
}

test "ML-DSA-87 — verify fails on tampered message" {
    init();
    const kp = try MlDsa87.generateKeyPair();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const msg = "OmniBus OMNI_LOVE transaction";
    const sig = try kp.sign(msg, arena.allocator());
    try testing.expect(!kp.verify("tampered", sig));
}

test "ML-DSA-87 — verify fails on tampered signature" {
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
    init();
    const seed: [32]u8 = .{1} ** 32;
    const kp1 = MlDsa87.generateKeyPairFromSeed(seed);
    const kp2 = MlDsa87.generateKeyPairFromSeed(seed);
    try testing.expectEqualSlices(u8, &kp1.public_key, &kp2.public_key);
    try testing.expectEqualSlices(u8, &kp1.secret_key, &kp2.secret_key);
}

test "Falcon-512 — sign + verify" {
    init();
    const kp = try Falcon512.generateKeyPair();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const msg = "OmniBus OMNI_FOOD transaction";
    const sig = try kp.sign(msg, arena.allocator());
    try testing.expect(kp.verify(msg, sig));
}

test "Falcon-512 — cross-key verify fails" {
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
    init();
    const kp = try SlhDsa256s.generateKeyPair();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const msg = "OmniBus OMNI_VACATION transaction";
    const sig = try kp.sign(msg, arena.allocator());
    try testing.expect(kp.verify(msg, sig));
}

test "ML-KEM-768 — encaps + decaps shared secret matches" {
    init();
    const kp = try MlKem768.generateKeyPair();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const enc = try kp.encapsulate(arena.allocator());
    const dec = try kp.decapsulate(enc.ciphertext);
    try testing.expectEqualSlices(u8, &enc.shared_secret, &dec);
}

test "algorithmForCoinType dispatch" {
    try testing.expectEqual(DomainAlgorithm.MlDsa87,    algorithmForCoinType(778).?);
    try testing.expectEqual(DomainAlgorithm.Falcon512,  algorithmForCoinType(779).?);
    try testing.expectEqual(DomainAlgorithm.MlDsa87,    algorithmForCoinType(780).?);
    try testing.expectEqual(DomainAlgorithm.SlhDsa256s, algorithmForCoinType(781).?);
    try testing.expect(algorithmForCoinType(999) == null);
}
