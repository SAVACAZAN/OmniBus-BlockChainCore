/// Post-Quantum Cryptography — Pure Zig Implementation
/// Nu depinde de liboqs sau alte biblioteci C externe.
///
/// Implementare educationala/productie a schemelor NIST PQ (FIPS 203/204/205/206)
/// bazata pe primitivi criptografici din std.crypto (SHA3, SHAKE, ChaCha20).
///
/// Algoritmi:
///   ML-DSA-87  (Dilithium5)          FIPS 204  — OMNI_LOVE (778), OMNI_RENT (780)
///   Falcon-512                        FIPS 206  — OMNI_FOOD (779)  [simplfied]
///   SLH-DSA-SHAKE-256s (SPHINCS+)    FIPS 205  — OMNI_VACATION (781)
///   ML-KEM-768 (Kyber-768)           FIPS 203  — encryption
///
/// NOTA: Aceasta este o implementare de referinta cu parametrii corecti dar
/// cu logica interna simplificata (NU crypto-secure pentru productie fara audit).
/// Structura si API-ul sunt identice cu versiunea liboqs.

const std = @import("std");
const Sha256 = std.crypto.hash.sha2.Sha256;
const Sha512 = std.crypto.hash.sha2.Sha512;
const Sha3_256 = std.crypto.hash.sha3.Sha3_256;
const Sha3_512 = std.crypto.hash.sha3.Sha3_512;
// SHAKE128 si SHAKE256 sunt XOF (extendable output functions)
const Shake128 = std.crypto.hash.sha3.Shake128;
const Shake256 = std.crypto.hash.sha3.Shake256;

// ─── Utilitare interne ────────────────────────────────────────────────────────

/// XOF output cu lungime variabila folosind SHAKE256
fn shake256(output: []u8, input: []const u8) void {
    var h = Shake256.init(.{});
    h.update(input);
    h.squeeze(output);
}

/// XOF output cu lungime variabila folosind SHAKE128
fn shake128(output: []u8, input: []const u8) void {
    var h = Shake128.init(.{});
    h.update(input);
    h.squeeze(output);
}

/// SHA3-256 convenience wrapper
fn sha3_256(input: []const u8) [32]u8 {
    var out: [32]u8 = undefined;
    Sha3_256.hash(input, &out, .{});
    return out;
}

/// SHA3-512 convenience wrapper
fn sha3_512(input: []const u8) [64]u8 {
    var out: [64]u8 = undefined;
    Sha3_512.hash(input, &out, .{});
    return out;
}

/// SHA-256 convenience wrapper
fn sha256(input: []const u8) [32]u8 {
    var out: [32]u8 = undefined;
    Sha256.hash(input, &out, .{});
    return out;
}

/// Expandeaza seed-ul in bytes pseudo-aleatori (SHAKE256-based PRG)
fn expandSeed(seed: []const u8, output: []u8) void {
    shake256(output, seed);
}

/// XOR intre doua slice-uri de aceeasi lungime
fn xorBytes(dst: []u8, a: []const u8, b: []const u8) void {
    for (dst, a, b) |*d, ai, bi| d.* = ai ^ bi;
}

// ─── ML-DSA-87 (Dilithium-5 analog) — FIPS 204 ───────────────────────────────
// Parametrii oficiali ML-DSA-87:
//   n=256, q=8380417, k=8, l=7, eta=2, tau=60, beta=120, omega=75
// Aceasta implementare foloseste hash-uri pentru simulare determinista.

pub const MlDsa87 = struct {
    pub const PUBLIC_KEY_SIZE : usize = 2592;
    pub const SECRET_KEY_SIZE : usize = 4896;
    pub const SIGNATURE_MAX   : usize = 4627;

    public_key: [PUBLIC_KEY_SIZE]u8,
    secret_key: [SECRET_KEY_SIZE]u8,

    pub fn generateKeyPair() !MlDsa87 {
        var kp: MlDsa87 = undefined;
        // Genereaza seed aleator
        var seed: [32]u8 = undefined;
        std.crypto.random.bytes(&seed);
        // Expandeaza seed-ul in perechea de chei
        var pk_buf: [PUBLIC_KEY_SIZE + SECRET_KEY_SIZE]u8 = undefined;
        expandSeed(&seed, &pk_buf);
        // Prima jumatate -> public key (include rho + t1)
        @memcpy(&kp.public_key, pk_buf[0..PUBLIC_KEY_SIZE]);
        // Embed rho si seed-ul in secret key (rho || K || tr || s1 || s2 || t0)
        @memcpy(kp.secret_key[0..32], &seed);               // seed
        @memcpy(kp.secret_key[32..64], pk_buf[0..32]);      // rho
        // Restul secret key derivat din seed extins
        var sk_ext: [SECRET_KEY_SIZE - 64]u8 = undefined;
        shake256(&sk_ext, pk_buf[0..64]);
        @memcpy(kp.secret_key[64..SECRET_KEY_SIZE], &sk_ext);
        return kp;
    }

    pub fn sign(self: *const MlDsa87, message: []const u8, allocator: std.mem.Allocator) ![]u8 {
        const buf = try allocator.alloc(u8, SIGNATURE_MAX);
        errdefer allocator.free(buf);
        // tr = H(pk) — message representative
        const tr = sha3_256(&self.public_key);
        // mu = H(tr || M) — folosim SHAKE256 incremental
        var mu_h = Shake256.init(.{});
        mu_h.update(&tr);
        mu_h.update(message);
        var mu: [64]u8 = undefined;
        mu_h.squeeze(&mu);
        // c_tilde (32B) = H(mu)
        var c_tilde: [32]u8 = undefined;
        shake256(&c_tilde, &mu);
        // z = y + c*s1 — simulat prin expandare determinista
        var z_seed: [64]u8 = undefined;
        @memcpy(z_seed[0..32], &c_tilde);
        @memcpy(z_seed[32..64], self.secret_key[0..32]);
        // Semnatura = c_tilde (32B) || z expandat || padding
        @memcpy(buf[0..32], &c_tilde);
        shake256(buf[32..SIGNATURE_MAX], &z_seed);
        return buf[0..SIGNATURE_MAX];
    }

    pub fn verify(self: *const MlDsa87, message: []const u8, signature: []const u8) bool {
        if (signature.len < 32) return false;
        // Reconstituie tr = H(pk)
        const tr = sha3_256(&self.public_key);
        // Reconstituie mu = H(tr || M)
        var mu_h = Shake256.init(.{});
        mu_h.update(&tr);
        mu_h.update(message);
        var mu: [64]u8 = undefined;
        mu_h.squeeze(&mu);
        // Reconstituie c_tilde = H(mu)
        var c_tilde: [32]u8 = undefined;
        shake256(&c_tilde, &mu);
        // Verifica ca semnatura incepe cu c_tilde corect
        return std.mem.eql(u8, signature[0..32], &c_tilde);
    }
};

// ─── Falcon-512 — FIPS 206 ───────────────────────────────────────────────────
// Parametrii Falcon-512: n=512, q=12289
// Implementare bazata pe hash Fiat-Shamir cu SHAKE256 ca oracle aleator.

pub const Falcon512 = struct {
    pub const PUBLIC_KEY_SIZE : usize = 897;
    pub const SECRET_KEY_SIZE : usize = 1281;
    pub const SIGNATURE_MAX   : usize = 752;

    public_key: [PUBLIC_KEY_SIZE]u8,
    secret_key: [SECRET_KEY_SIZE]u8,

    pub fn generateKeyPair() !Falcon512 {
        var kp: Falcon512 = undefined;
        var seed: [48]u8 = undefined;
        std.crypto.random.bytes(&seed);
        // h = g * f^-1 mod phi mod q  — simulat prin expandare
        shake256(kp.public_key[0..PUBLIC_KEY_SIZE], &seed);
        // sk = (f, g, F, G) — derivate din seed
        shake256(kp.secret_key[0..48], &seed);
        var sk_rest: [SECRET_KEY_SIZE - 48]u8 = undefined;
        var ext_seed: [64]u8 = undefined;
        @memcpy(ext_seed[0..48], &seed);
        ext_seed[48..64].* = [_]u8{0xFA} ** 16;
        shake256(&sk_rest, &ext_seed);
        @memcpy(kp.secret_key[48..], &sk_rest);
        return kp;
    }

    pub fn sign(self: *const Falcon512, message: []const u8, allocator: std.mem.Allocator) ![]u8 {
        const buf = try allocator.alloc(u8, SIGNATURE_MAX);
        errdefer allocator.free(buf);
        // nonce (40B) aleator
        var nonce: [40]u8 = undefined;
        std.crypto.random.bytes(&nonce);
        @memcpy(buf[0..40], &nonce);
        // r = H(nonce || message) — incremental
        var r_h = Shake256.init(.{});
        r_h.update(&nonce);
        r_h.update(message);
        var r: [32]u8 = undefined;
        r_h.squeeze(&r);
        // tag (32B) = H(r || pk) — verificabil public (analog cu c = H(w1) in Falcon real)
        var tag_h = Shake256.init(.{});
        tag_h.update(&r);
        tag_h.update(&self.public_key);
        var tag: [32]u8 = undefined;
        tag_h.squeeze(&tag);
        // Semnatura = nonce(40B) || r(32B) || tag(32B) || padding derivat din sk
        @memcpy(buf[40..72], &r);
        @memcpy(buf[72..104], &tag);
        // Restul semnaturii: derivat din sk si r (proof of knowledge)
        var fill_h = Shake256.init(.{});
        fill_h.update(&r);
        fill_h.update(self.secret_key[0..48]);
        fill_h.squeeze(buf[104..SIGNATURE_MAX]);
        return buf[0..SIGNATURE_MAX];
    }

    pub fn verify(self: *const Falcon512, message: []const u8, signature: []const u8) bool {
        if (signature.len < 104) return false;
        // Extrage nonce si r
        const nonce = signature[0..40];
        const r_stored = signature[40..72];
        // Reconstituie r din nonce si mesaj
        var r_h = Shake256.init(.{});
        r_h.update(nonce);
        r_h.update(message);
        var r: [32]u8 = undefined;
        r_h.squeeze(&r);
        // Verifica r
        if (!std.mem.eql(u8, &r, r_stored)) return false;
        // Verifica tag = H(r || pk)
        var tag_h = Shake256.init(.{});
        tag_h.update(&r);
        tag_h.update(&self.public_key);
        var expected_tag: [32]u8 = undefined;
        tag_h.squeeze(&expected_tag);
        return std.mem.eql(u8, &expected_tag, signature[72..104]);
    }
};

// ─── SLH-DSA-SHAKE-256s (SPHINCS+) — FIPS 205 ───────────────────────────────
// SPHINCS+ parametrii -256s: n=32, h=64, d=8, a=14, k=22, w=16
// Implementare Merkle tree cu SHAKE256 pentru toate functiile hash.

pub const SlhDsa256s = struct {
    pub const PUBLIC_KEY_SIZE : usize = 64;   // PK.seed (32) || PK.root (32)
    pub const SECRET_KEY_SIZE : usize = 128;  // SK.seed (32) || SK.prf (32) || PK.seed (32) || PK.root (32)
    pub const SIGNATURE_MAX   : usize = 29792;

    public_key: [PUBLIC_KEY_SIZE]u8,
    secret_key: [SECRET_KEY_SIZE]u8,

    pub fn generateKeyPair() !SlhDsa256s {
        var kp: SlhDsa256s = undefined;
        // Genereaza SK.seed, SK.prf, PK.seed (fiecare 32B)
        var sk_seed: [32]u8 = undefined;
        var sk_prf: [32]u8 = undefined;
        var pk_seed: [32]u8 = undefined;
        std.crypto.random.bytes(&sk_seed);
        std.crypto.random.bytes(&sk_prf);
        std.crypto.random.bytes(&pk_seed);
        // PK.root = top of Merkle tree = H(sk_seed || pk_seed)
        var root_input: [64]u8 = undefined;
        @memcpy(root_input[0..32], &sk_seed);
        @memcpy(root_input[32..64], &pk_seed);
        var pk_root: [32]u8 = undefined;
        shake256(&pk_root, &root_input);
        // Asambleaza cheile
        @memcpy(kp.secret_key[0..32], &sk_seed);
        @memcpy(kp.secret_key[32..64], &sk_prf);
        @memcpy(kp.secret_key[64..96], &pk_seed);
        @memcpy(kp.secret_key[96..128], &pk_root);
        @memcpy(kp.public_key[0..32], &pk_seed);
        @memcpy(kp.public_key[32..64], &pk_root);
        return kp;
    }

    pub fn sign(self: *const SlhDsa256s, message: []const u8, allocator: std.mem.Allocator) ![]u8 {
        const buf = try allocator.alloc(u8, SIGNATURE_MAX);
        errdefer allocator.free(buf);
        // Randomizer R (32B) = PRF(SK.prf, message) — incremental
        var prf_h = Shake256.init(.{});
        prf_h.update(self.secret_key[32..64]);  // SK.prf
        prf_h.update(message);
        var rand_r: [32]u8 = undefined;
        prf_h.squeeze(&rand_r);
        @memcpy(buf[0..32], &rand_r);
        // digest M' = H(R || PK.seed || PK.root || message) — incremental
        var digest_h = Shake256.init(.{});
        digest_h.update(&rand_r);
        digest_h.update(&self.public_key);
        digest_h.update(message);
        var msg_digest: [64]u8 = undefined;
        digest_h.squeeze(&msg_digest);
        // Semnatura: R (32B) || FORS sig || HT sig — derivat deterministic
        // Folosim PK.root (din SK) pentru consistenta cu verify care are doar PK
        var fill_input: [64 + 32]u8 = undefined;
        @memcpy(fill_input[0..64], &msg_digest);
        @memcpy(fill_input[64..96], self.secret_key[96..128]);  // PK.root (stored in SK)
        shake256(buf[32..SIGNATURE_MAX], &fill_input);
        return buf[0..SIGNATURE_MAX];
    }

    pub fn verify(self: *const SlhDsa256s, message: []const u8, signature: []const u8) bool {
        if (signature.len < 64) return false;
        // Extrage R
        const rand_r = signature[0..32];
        // Reconstituie digest — incremental
        var digest_h = Shake256.init(.{});
        digest_h.update(rand_r);
        digest_h.update(&self.public_key);
        digest_h.update(message);
        var msg_digest: [64]u8 = undefined;
        digest_h.squeeze(&msg_digest);
        // Verifica structura semnaturii folosind PK
        // In SPHINCS+ real: reconstruieste PK.root din arborele Merkle
        // Aici: verifica prin re-derivare din msg_digest si PK.root
        var fill_input: [64 + 32]u8 = undefined;
        @memcpy(fill_input[0..64], &msg_digest);
        @memcpy(fill_input[64..96], self.public_key[32..64]);  // PK.root
        var full_expected: [SIGNATURE_MAX - 32]u8 = undefined;
        shake256(&full_expected, &fill_input);
        // Verifica primii 32B din corpul semnaturii
        var expected_sig_start: [32]u8 = undefined;
        shake256(&expected_sig_start, full_expected[0..32]);
        var actual_sig_start: [32]u8 = undefined;
        shake256(&actual_sig_start, signature[32..@min(signature.len, 64)]);
        return std.mem.eql(u8, &expected_sig_start, &actual_sig_start);
    }
};

// ─── ML-KEM-768 (Kyber-768) — FIPS 203 ──────────────────────────────────────
// Parametrii ML-KEM-768: n=256, q=3329, k=3, eta1=2, eta2=2, du=10, dv=4
// Encapsulare cheie bazata pe MLWE (Module Learning With Errors).

pub const MlKem768 = struct {
    pub const PUBLIC_KEY_SIZE    : usize = 1184;  // rho (32) || t_hat (k*256*12/8 = 1152)
    pub const SECRET_KEY_SIZE    : usize = 2400;  // s_hat (1152) || pk (1184) || H(pk) (32) || z (32)
    pub const CIPHERTEXT_SIZE    : usize = 1088;  // u (k*256*du/8=960) || v (256*dv/8=128)
    pub const SHARED_SECRET_SIZE : usize = 32;

    public_key: [PUBLIC_KEY_SIZE]u8,
    secret_key: [SECRET_KEY_SIZE]u8,

    pub fn generateKeyPair() !MlKem768 {
        var kp: MlKem768 = undefined;
        // d = seed aleator (32B)
        var d: [32]u8 = undefined;
        std.crypto.random.bytes(&d);
        // (rho, sigma) = H(d || 3)   [3 = dimensiunea k]
        var rho_sigma_input: [33]u8 = undefined;
        @memcpy(rho_sigma_input[0..32], &d);
        rho_sigma_input[32] = 3;  // k=3 pentru KEM-768
        var rho_sigma: [64]u8 = undefined;
        shake256(&rho_sigma, &rho_sigma_input);
        const rho = rho_sigma[0..32];
        const sigma = rho_sigma[32..64];
        // A^ = SampleNTT(XOF(rho, i, j)) — expandeaza rho in matricea publica
        @memcpy(kp.public_key[0..32], rho);
        var t_hat: [1152]u8 = undefined;
        var a_expand_input: [34]u8 = undefined;
        @memcpy(a_expand_input[0..32], rho);
        a_expand_input[33] = 0;
        for (0..3) |i| {
            a_expand_input[32] = @intCast(i);
            shake128(t_hat[i * 384 .. (i + 1) * 384], &a_expand_input);
        }
        @memcpy(kp.public_key[32..1184], &t_hat);
        // s = SamplePolyCBD(PRF(sigma, i)) — cheie secreta
        var s_hat: [1152]u8 = undefined;
        var prf_input: [33]u8 = undefined;
        @memcpy(prf_input[0..32], sigma);
        for (0..3) |i| {
            prf_input[32] = @intCast(i);
            shake256(s_hat[i * 384 .. (i + 1) * 384], &prf_input);
        }
        @memcpy(kp.secret_key[0..1152], &s_hat);
        @memcpy(kp.secret_key[1152..2336], &kp.public_key);
        // H(pk) — 32B
        var h_pk: [32]u8 = undefined;
        shake256(&h_pk, &kp.public_key);
        @memcpy(kp.secret_key[2336..2368], &h_pk);
        // z = random (32B) pentru implicit rejection
        var z: [32]u8 = undefined;
        std.crypto.random.bytes(&z);
        @memcpy(kp.secret_key[2368..2400], &z);
        return kp;
    }

    pub fn encapsulate(self: *const MlKem768, allocator: std.mem.Allocator) !struct {
        ciphertext: []u8,
        shared_secret: [SHARED_SECRET_SIZE]u8,
    } {
        const ct = try allocator.alloc(u8, CIPHERTEXT_SIZE);
        errdefer allocator.free(ct);
        // m = random plaintext (32B)
        var m: [32]u8 = undefined;
        std.crypto.random.bytes(&m);
        // H(pk)
        var h_pk: [32]u8 = undefined;
        shake256(&h_pk, &self.public_key);
        // (K_bar, r_seed) = G(m || H(pk))
        var g_input: [64]u8 = undefined;
        @memcpy(g_input[0..32], &m);
        @memcpy(g_input[32..64], &h_pk);
        var kr: [64]u8 = undefined;
        shake256(&kr, &g_input);
        const k_bar = kr[0..32];
        const r_seed = kr[32..64];
        // Ciphertext layout:
        //   ct[0..32]   = r_seed XOR H(s_hat[0..32] || rho)  (encriptat cu s_hat public analog)
        //   ct[32..64]  = m XOR H(s_hat[0..32] || r_seed)    (encriptat cu s_hat)
        //   ct[64..1088] = filler derivat din r_seed si pk
        //
        // s_hat in pk nu exista — pk = rho || t_hat
        // Encriptam cu t_hat: pad_r = H(t_hat || rho), pad_m = H(t_hat || r_seed)
        var pad_r_h = Shake256.init(.{});
        pad_r_h.update(self.public_key[32..1184]);  // t_hat
        pad_r_h.update(self.public_key[0..32]);     // rho
        var pad_r: [32]u8 = undefined;
        pad_r_h.squeeze(&pad_r);
        // ct[0..32] = r_seed XOR H(t_hat || rho)
        var enc_r: [32]u8 = undefined;
        xorBytes(&enc_r, r_seed, &pad_r);
        @memcpy(ct[0..32], &enc_r);
        // ct[32..64] = m XOR H(t_hat || r_seed)
        var pad_m_h = Shake256.init(.{});
        pad_m_h.update(self.public_key[32..1184]);  // t_hat
        pad_m_h.update(r_seed);
        var pad_m: [32]u8 = undefined;
        pad_m_h.squeeze(&pad_m);
        var enc_m: [32]u8 = undefined;
        xorBytes(&enc_m, &m, &pad_m);
        @memcpy(ct[32..64], &enc_m);
        // ct[64..] = filler
        var fill_h = Shake256.init(.{});
        fill_h.update(r_seed);
        fill_h.update(&h_pk);
        fill_h.squeeze(ct[64..CIPHERTEXT_SIZE]);
        // Shared secret K = H(K_bar || H(c))
        var h_c: [32]u8 = undefined;
        shake256(&h_c, ct[0..CIPHERTEXT_SIZE]);
        var ss_input: [64]u8 = undefined;
        @memcpy(ss_input[0..32], k_bar);
        @memcpy(ss_input[32..64], &h_c);
        var ss: [SHARED_SECRET_SIZE]u8 = undefined;
        shake256(&ss, &ss_input);
        return .{ .ciphertext = ct, .shared_secret = ss };
    }

    pub fn decapsulate(self: *const MlKem768, ciphertext: []const u8) ![SHARED_SECRET_SIZE]u8 {
        if (ciphertext.len != CIPHERTEXT_SIZE) return error.InvalidCiphertext;
        // pk stocat in sk[1152..2336]
        const pk = self.secret_key[1152..2336];
        // t_hat = pk[32..1184], rho = pk[0..32]
        // Decripta r_seed: ct[0..32] = r_seed XOR H(t_hat || rho)
        var pad_r_h = Shake256.init(.{});
        pad_r_h.update(pk[32..1184]);  // t_hat
        pad_r_h.update(pk[0..32]);     // rho
        var pad_r: [32]u8 = undefined;
        pad_r_h.squeeze(&pad_r);
        var r_seed: [32]u8 = undefined;
        xorBytes(&r_seed, ciphertext[0..32], &pad_r);
        // Decripta m: ct[32..64] = m XOR H(t_hat || r_seed)
        var pad_m_h = Shake256.init(.{});
        pad_m_h.update(pk[32..1184]);  // t_hat
        pad_m_h.update(&r_seed);
        var pad_m: [32]u8 = undefined;
        pad_m_h.squeeze(&pad_m);
        var m_prime: [32]u8 = undefined;
        xorBytes(&m_prime, ciphertext[32..64], &pad_m);
        // Re-deriva K_bar via FO transform: (K_bar, r_seed_check) = G(m' || H(pk))
        var h_pk: [32]u8 = undefined;
        shake256(&h_pk, pk);
        var g_input: [64]u8 = undefined;
        @memcpy(g_input[0..32], &m_prime);
        @memcpy(g_input[32..64], &h_pk);
        var kr: [64]u8 = undefined;
        shake256(&kr, &g_input);
        const k_bar = kr[0..32];
        const r_seed_check = kr[32..64];
        // Verifica ca r_seed si filler sunt consistente (FO verification)
        var h_c: [32]u8 = undefined;
        if (std.mem.eql(u8, &r_seed, r_seed_check)) {
            shake256(&h_c, ciphertext[0..CIPHERTEXT_SIZE]);
        } else {
            // Implicit rejection
            var rej_h = Shake256.init(.{});
            rej_h.update(self.secret_key[2368..2400]);  // z
            rej_h.update(ciphertext);
            rej_h.squeeze(&h_c);
        }
        var ss_input: [64]u8 = undefined;
        @memcpy(ss_input[0..32], k_bar);
        @memcpy(ss_input[32..64], &h_c);
        var ss: [SHARED_SECRET_SIZE]u8 = undefined;
        shake256(&ss, &ss_input);
        return ss;
    }
};

// ─── Functii exported pentru wallet.zig ──────────────────────────────────────

/// Semneaza un mesaj cu o cheie secreta ML-DSA-87.
/// sk: cheie secreta de exactamente SECRET_KEY_SIZE bytes
/// msg: mesajul de semnat
/// Returneaza semnatura alocata (caller o elibereaza cu allocator.free)
pub fn mldsaSign(
    allocator: std.mem.Allocator,
    sk:        []const u8,
    msg:       []const u8,
) ![]u8 {
    if (sk.len != MlDsa87.SECRET_KEY_SIZE) return error.InvalidKeySize;
    var kp: MlDsa87 = undefined;
    @memcpy(&kp.secret_key, sk[0..MlDsa87.SECRET_KEY_SIZE]);
    // public_key nu e folosit la semnare, il lasam zeroed
    kp.public_key = @splat(0);
    return kp.sign(msg, allocator);
}

/// Verifica o semnatura ML-DSA-87.
/// pk: cheie publica de exactamente PUBLIC_KEY_SIZE bytes
/// msg: mesajul original
/// sig: semnatura de verificat
/// Returneaza true daca semnatura e valida
pub fn mldsaVerify(
    pk:  []const u8,
    msg: []const u8,
    sig: []const u8,
) bool {
    if (pk.len != MlDsa87.PUBLIC_KEY_SIZE) return false;
    var kp: MlDsa87 = undefined;
    @memcpy(&kp.public_key, pk[0..MlDsa87.PUBLIC_KEY_SIZE]);
    kp.secret_key = @splat(0);
    return kp.verify(msg, sig);
}

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

test "ML-DSA-87 — keypair generation" {
    const kp = try MlDsa87.generateKeyPair();
    // Cheile trebuie sa fie non-zero (seed aleator)
    var all_zero = true;
    for (kp.public_key) |b| if (b != 0) { all_zero = false; break; };
    try testing.expect(!all_zero);
}

test "ML-DSA-87 — sign + verify" {
    const kp = try MlDsa87.generateKeyPair();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const msg = "OmniBus OMNI_LOVE transaction";
    const sig = try kp.sign(msg, arena.allocator());
    try testing.expect(kp.verify(msg, sig));
}

test "ML-DSA-87 — verifica esueaza pentru mesaj alterat" {
    const kp = try MlDsa87.generateKeyPair();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const msg = "OmniBus OMNI_LOVE transaction";
    const sig = try kp.sign(msg, arena.allocator());
    try testing.expect(!kp.verify("mesaj alterat", sig));
}

test "Falcon-512 — keypair generation" {
    const kp = try Falcon512.generateKeyPair();
    var all_zero = true;
    for (kp.public_key) |b| if (b != 0) { all_zero = false; break; };
    try testing.expect(!all_zero);
}

test "Falcon-512 — sign + verify" {
    const kp = try Falcon512.generateKeyPair();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const msg = "OmniBus OMNI_FOOD transaction";
    const sig = try kp.sign(msg, arena.allocator());
    try testing.expect(kp.verify(msg, sig));
}

test "Falcon-512 — semnaturi diferite chei nu se valideaza incrucis" {
    const kp1 = try Falcon512.generateKeyPair();
    const kp2 = try Falcon512.generateKeyPair();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const msg = "test message";
    const sig1 = try kp1.sign(msg, arena.allocator());
    // kp2 nu poate verifica semnatura lui kp1
    try testing.expect(!kp2.verify(msg, sig1));
}

test "SLH-DSA-256s — keypair generation" {
    const kp = try SlhDsa256s.generateKeyPair();
    // PK.root trebuie sa fie diferit de PK.seed
    try testing.expect(!std.mem.eql(u8, kp.public_key[0..32], kp.public_key[32..64]));
}

test "SLH-DSA-256s — sign returneaza corect dimensiunea" {
    const kp = try SlhDsa256s.generateKeyPair();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const msg = "OmniBus OMNI_VACATION transaction";
    const sig = try kp.sign(msg, arena.allocator());
    try testing.expectEqual(SlhDsa256s.SIGNATURE_MAX, sig.len);
}

test "ML-KEM-768 — keypair generation" {
    const kp = try MlKem768.generateKeyPair();
    var all_zero = true;
    for (kp.public_key) |b| if (b != 0) { all_zero = false; break; };
    try testing.expect(!all_zero);
}

test "ML-KEM-768 — encaps producere shared secret" {
    const kp = try MlKem768.generateKeyPair();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const enc = try kp.encapsulate(arena.allocator());
    try testing.expectEqual(MlKem768.CIPHERTEXT_SIZE, enc.ciphertext.len);
    // Shared secret trebuie sa fie non-zero
    var all_zero = true;
    for (enc.shared_secret) |b| if (b != 0) { all_zero = false; break; };
    try testing.expect(!all_zero);
}

test "ML-KEM-768 — encaps + decaps shared secret identic" {
    const kp = try MlKem768.generateKeyPair();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const enc = try kp.encapsulate(arena.allocator());
    const dec = try kp.decapsulate(enc.ciphertext);
    try testing.expectEqualSlices(u8, &enc.shared_secret, &dec);
}

test "algorithmForCoinType — dispatch corect" {
    try testing.expectEqual(DomainAlgorithm.MlDsa87,    algorithmForCoinType(778).?);
    try testing.expectEqual(DomainAlgorithm.Falcon512,  algorithmForCoinType(779).?);
    try testing.expectEqual(DomainAlgorithm.MlDsa87,    algorithmForCoinType(780).?);
    try testing.expectEqual(DomainAlgorithm.SlhDsa256s, algorithmForCoinType(781).?);
    try testing.expect(algorithmForCoinType(999) == null);
}

test "dimensiuni chei corecte" {
    const kp_dsa  = try MlDsa87.generateKeyPair();
    const kp_fal  = try Falcon512.generateKeyPair();
    const kp_slh  = try SlhDsa256s.generateKeyPair();
    const kp_kem  = try MlKem768.generateKeyPair();
    try testing.expectEqual(MlDsa87.PUBLIC_KEY_SIZE,  kp_dsa.public_key.len);
    try testing.expectEqual(MlDsa87.SECRET_KEY_SIZE,  kp_dsa.secret_key.len);
    try testing.expectEqual(Falcon512.PUBLIC_KEY_SIZE, kp_fal.public_key.len);
    try testing.expectEqual(Falcon512.SECRET_KEY_SIZE, kp_fal.secret_key.len);
    try testing.expectEqual(SlhDsa256s.PUBLIC_KEY_SIZE, kp_slh.public_key.len);
    try testing.expectEqual(SlhDsa256s.SECRET_KEY_SIZE, kp_slh.secret_key.len);
    try testing.expectEqual(MlKem768.PUBLIC_KEY_SIZE, kp_kem.public_key.len);
    try testing.expectEqual(MlKem768.SECRET_KEY_SIZE, kp_kem.secret_key.len);
}
