const std = @import("std");
const secp256k1_mod = @import("secp256k1.zig");
const bip32_mod = @import("bip32_wallet.zig");
const pq_crypto = @import("pq_crypto.zig");
const bech32_mod = @import("bech32.zig");
const ripemd160_mod = @import("ripemd160.zig");
const Ripemd160 = ripemd160_mod.Ripemd160;

/// OmniBus IsolatedWallet — 5 wallet-uri complet independente, fiecare cu
/// propriul seed/mnemonic. Nici o legatura matematica intre ele.
///
/// Scop: daca un mnemonic e compromis, celelalte 4 wallet-uri raman securizate.
/// Fiecare domain foloseste algoritmul sau propriu:
///   OMNI     = secp256k1 ECDSA   (adresa ob1q...)
///   LOVE     = ML-DSA (Dilithium) (adresa ob_k1_...)
///   FOOD     = Falcon-512         (adresa ob_f5_...)
///   RENT     = SLH-DSA (SPHINCS+) (adresa ob_d5_...)
///   VACATION = ML-KEM (Kyber)     (adresa ob_s3_...)
///
/// NOTA: pentru chain-side, mnemonic-ul e stocat ca hex string de 64 chars
/// (32 bytes entropy). Conversia BIP-39 la cuvinte e responsabilitatea UI-ului.

pub const Scheme = enum(u8) {
    omni_ecdsa = 0,
    love_dilithium = 1,
    food_falcon = 2,
    rent_slh_dsa = 3,
    vacation_kem = 4,

    pub fn prefix(self: Scheme) []const u8 {
        return switch (self) {
            .omni_ecdsa => "ob1q",
            .love_dilithium => "ob_k1_",
            .food_falcon => "ob_f5_",
            .rent_slh_dsa => "ob_d5_",
            .vacation_kem => "ob_s3_",
        };
    }

    pub fn fromAddress(addr: []const u8) ?Scheme {
        if (std.mem.startsWith(u8, addr, "ob1q")) return .omni_ecdsa;
        if (std.mem.startsWith(u8, addr, "ob_k1_")) return .love_dilithium;
        if (std.mem.startsWith(u8, addr, "ob_f5_")) return .food_falcon;
        if (std.mem.startsWith(u8, addr, "ob_d5_")) return .rent_slh_dsa;
        if (std.mem.startsWith(u8, addr, "ob_s3_")) return .vacation_kem;
        return null;
    }
};

/// Deriveaza un hash160 dintr-un public key arbitrar (folosit si pentru PQ keys).
fn hash160FromBytes(pubkey: []const u8) [20]u8 {
    var sha256_hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(pubkey, &sha256_hash, .{});
    var hash160: [20]u8 = undefined;
    Ripemd160.hash(&sha256_hash, &hash160);
    return hash160;
}

/// Deriveaza adresa OmniBus (bech32) din secp256k1 compressed pubkey.
fn deriveOmniAddress(pubkey: [33]u8, allocator: std.mem.Allocator) ![]u8 {
    const h160 = secp256k1_mod.Secp256k1Crypto.privateKeyToHash160;
    _ = h160;
    // Folosim direct hash160 din pubkey (identic cu Bitcoin)
    var sha256_hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&pubkey, &sha256_hash, .{});
    var hash160: [20]u8 = undefined;
    Ripemd160.hash(&sha256_hash, &hash160);
    return bech32_mod.encodeOBAddress(hash160, allocator);
}

/// Deriveaza adresa legacy prefix+Base58Check din hash160.
fn deriveLegacyAddress(hash160: [20]u8, prefix: []const u8, allocator: std.mem.Allocator) ![]u8 {
    const b58 = try bip32_mod.base58CheckEncode(hash160, 0x4F, allocator);
    defer allocator.free(b58);
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ prefix, b58 });
}

pub const DomainKey = struct {
    scheme: Scheme,
    mnemonic: []u8,     // hex string de 64 chars (32 bytes entropy)
    address: []u8,
    // Pentru scheme-uri de semnatura, stocam cheile PQ
    // Pentru OMNI, derivam on-demand din mnemonic via BIP-32
    pq_public_key: ?[]u8,   // null pentru OMNI
    pq_secret_key: ?[]u8,   // null pentru OMNI (stocam doar pointer la date interne)
};

pub const IsolatedWallet = struct {
    omni: DomainKey,
    love: DomainKey,
    food: DomainKey,
    rent: DomainKey,
    vacation: DomainKey,
    allocator: std.mem.Allocator,

    /// Genereaza 5 wallet-uri complet independente.
    pub fn generate(allocator: std.mem.Allocator) !IsolatedWallet {
        var wallet: IsolatedWallet = undefined;
        wallet.allocator = allocator;

        // OMNI — secp256k1 via BIP-32
        wallet.omni = try generateDomain(allocator, .omni_ecdsa);
        errdefer freeDomain(wallet.omni, allocator);

        // LOVE — ML-DSA (Dilithium-5)
        wallet.love = try generateDomain(allocator, .love_dilithium);
        errdefer freeDomain(wallet.love, allocator);

        // FOOD — Falcon-512
        wallet.food = try generateDomain(allocator, .food_falcon);
        errdefer freeDomain(wallet.food, allocator);

        // RENT — SLH-DSA (SPHINCS+)
        wallet.rent = try generateDomain(allocator, .rent_slh_dsa);
        errdefer freeDomain(wallet.rent, allocator);

        // VACATION — ML-KEM (Kyber) — doar encapsulation, nu signing
        wallet.vacation = try generateDomain(allocator, .vacation_kem);
        errdefer freeDomain(wallet.vacation, allocator);

        return wallet;
    }

    /// Restore din 5 mnemonice hex (64 chars fiecare). Partial restore acceptat.
    pub fn fromMnemonics(
        omni_mnemonic: ?[]const u8,
        love_mnemonic: ?[]const u8,
        food_mnemonic: ?[]const u8,
        rent_mnemonic: ?[]const u8,
        vacation_mnemonic: ?[]const u8,
        allocator: std.mem.Allocator,
    ) !IsolatedWallet {
        var wallet: IsolatedWallet = undefined;
        wallet.allocator = allocator;

        wallet.omni = try restoreDomain(allocator, .omni_ecdsa, omni_mnemonic);
        errdefer freeDomain(wallet.omni, allocator);
        wallet.love = try restoreDomain(allocator, .love_dilithium, love_mnemonic);
        errdefer freeDomain(wallet.love, allocator);
        wallet.food = try restoreDomain(allocator, .food_falcon, food_mnemonic);
        errdefer freeDomain(wallet.food, allocator);
        wallet.rent = try restoreDomain(allocator, .rent_slh_dsa, rent_mnemonic);
        errdefer freeDomain(wallet.rent, allocator);
        wallet.vacation = try restoreDomain(allocator, .vacation_kem, vacation_mnemonic);
        errdefer freeDomain(wallet.vacation, allocator);

        return wallet;
    }

    pub fn deinit(self: *const IsolatedWallet) void {
        freeDomain(self.omni, self.allocator);
        freeDomain(self.love, self.allocator);
        freeDomain(self.food, self.allocator);
        freeDomain(self.rent, self.allocator);
        freeDomain(self.vacation, self.allocator);
    }

    // ─── Signers — fiecare domain semneaza independent ────────────────────────

    /// Semneaza cu OMNI ECDSA (secp256k1 + SHA256d)
    pub fn signOmni(self: *const IsolatedWallet, message: []const u8, allocator: std.mem.Allocator) ![]u8 {
        // Deriveaza secp256k1 private key din mnemonic OMNI via BIP-44 m/44'/777'/0'/0/0
        const bip32 = try bip32_mod.BIP32Wallet.initFromMnemonic(self.omni.mnemonic, allocator);
        const privkey = try bip32.deriveChildKeyForPath(44, 777, 0);
        const sig_bytes = try secp256k1_mod.Secp256k1Crypto.sign(privkey, message);
        return try hexEncode(&sig_bytes, allocator);
    }

    /// Semneaza cu LOVE ML-DSA (Dilithium-5)
    pub fn signLove(self: *const IsolatedWallet, message: []const u8, allocator: std.mem.Allocator) ![]u8 {
        if (self.love.pq_secret_key == null) return error.KeyNotAvailable;
        const sk = self.love.pq_secret_key.?;
        // Reconstruim structura MlDsa87 din bytes
        if (sk.len != pq_crypto.MlDsa87.SECRET_KEY_SIZE) return error.InvalidKeySize;
        var kp: pq_crypto.MlDsa87 = undefined;
        @memcpy(&kp.secret_key, sk[0..pq_crypto.MlDsa87.SECRET_KEY_SIZE]);
        if (self.love.pq_public_key) |pk| {
            @memcpy(&kp.public_key, pk[0..pq_crypto.MlDsa87.PUBLIC_KEY_SIZE]);
        }
        return try kp.sign(message, allocator);
    }

    /// Semneaza cu FOOD Falcon-512
    pub fn signFood(self: *const IsolatedWallet, message: []const u8, allocator: std.mem.Allocator) ![]u8 {
        if (self.food.pq_secret_key == null) return error.KeyNotAvailable;
        const sk = self.food.pq_secret_key.?;
        if (sk.len != pq_crypto.Falcon512.SECRET_KEY_SIZE) return error.InvalidKeySize;
        var kp: pq_crypto.Falcon512 = undefined;
        @memcpy(&kp.secret_key, sk[0..pq_crypto.Falcon512.SECRET_KEY_SIZE]);
        if (self.food.pq_public_key) |pk| {
            @memcpy(&kp.public_key, pk[0..pq_crypto.Falcon512.PUBLIC_KEY_SIZE]);
        }
        return try kp.sign(message, allocator);
    }

    /// Semneaza cu RENT SLH-DSA (SPHINCS+)
    pub fn signRent(self: *const IsolatedWallet, message: []const u8, allocator: std.mem.Allocator) ![]u8 {
        if (self.rent.pq_secret_key == null) return error.KeyNotAvailable;
        const sk = self.rent.pq_secret_key.?;
        if (sk.len != pq_crypto.SlhDsa256s.SECRET_KEY_SIZE) return error.InvalidKeySize;
        var kp: pq_crypto.SlhDsa256s = undefined;
        @memcpy(&kp.secret_key, sk[0..pq_crypto.SlhDsa256s.SECRET_KEY_SIZE]);
        if (self.rent.pq_public_key) |pk| {
            @memcpy(&kp.public_key, pk[0..pq_crypto.SlhDsa256s.PUBLIC_KEY_SIZE]);
        }
        return try kp.sign(message, allocator);
    }

    /// VACATION (ML-KEM) nu suporta signing — e doar encapsulation.
    pub fn signVacation(_: *const IsolatedWallet, _: []const u8, _: std.mem.Allocator) ![]u8 {
        return error.SchemeNotSignable;
    }

    // ─── Helpers interne ─────────────────────────────────────────────────────

    fn generateDomain(allocator: std.mem.Allocator, scheme: Scheme) !DomainKey {
        // Genereaza 32 bytes entropy random
        var entropy: [32]u8 = undefined;
        std.crypto.random.bytes(&entropy);
        const mnemonic = try hexEncode(&entropy, allocator);
        errdefer allocator.free(mnemonic);

        return try deriveDomainKeys(allocator, scheme, mnemonic);
    }

    fn restoreDomain(allocator: std.mem.Allocator, scheme: Scheme, mnemonic: ?[]const u8) !DomainKey {
        if (mnemonic) |m| {
            const owned = try allocator.dupe(u8, m);
            errdefer allocator.free(owned);
            return try deriveDomainKeys(allocator, scheme, owned);
        }
        // Partial restore — domain neinitializat
        return DomainKey{
            .scheme = scheme,
            .mnemonic = try allocator.dupe(u8, ""),
            .address = try allocator.dupe(u8, ""),
            .pq_public_key = null,
            .pq_secret_key = null,
        };
    }

    fn deriveDomainKeys(allocator: std.mem.Allocator, scheme: Scheme, mnemonic: []u8) !DomainKey {
        var address: []u8 = undefined;
        var pq_pk: ?[]u8 = null;
        var pq_sk: ?[]u8 = null;

        switch (scheme) {
            .omni_ecdsa => {
                // BIP-44 derivation: m/44'/777'/0'/0/0
                const bip32 = try bip32_mod.BIP32Wallet.initFromMnemonic(mnemonic, allocator);
                const privkey = try bip32.deriveChildKeyForPath(44, 777, 0);
                const pubkey = try secp256k1_mod.Secp256k1Crypto.privateKeyToPublicKey(privkey);
                address = try deriveOmniAddress(pubkey, allocator);
            },
            .love_dilithium => {
                var seed: [32]u8 = undefined;
                std.crypto.hash.sha2.Sha256.hash(mnemonic, &seed, .{});
                var kp = pq_crypto.MlDsa87.generateKeyPairFromSeed(seed);
                const h160 = hash160FromBytes(&kp.public_key);
                address = try deriveLegacyAddress(h160, scheme.prefix(), allocator);
                pq_pk = try allocator.dupe(u8, &kp.public_key);
                pq_sk = try allocator.dupe(u8, &kp.secret_key);
            },
            .food_falcon => {
                var hash512: [64]u8 = undefined;
                std.crypto.hash.sha2.Sha512.hash(mnemonic, &hash512, .{});
                var seed: [48]u8 = undefined;
                @memcpy(&seed, hash512[0..48]);
                var kp = pq_crypto.Falcon512.generateKeyPairFromSeed(seed);
                const h160 = hash160FromBytes(&kp.public_key);
                address = try deriveLegacyAddress(h160, scheme.prefix(), allocator);
                pq_pk = try allocator.dupe(u8, &kp.public_key);
                pq_sk = try allocator.dupe(u8, &kp.secret_key);
            },
            .rent_slh_dsa => {
                var sk_seed: [32]u8 = undefined;
                var sk_prf: [32]u8 = undefined;
                var pk_seed: [32]u8 = undefined;
                std.crypto.hash.sha2.Sha256.hash(mnemonic, &sk_seed, .{});
                std.crypto.hash.sha3.Sha3_256.hash(mnemonic, &sk_prf, .{});
                var pk_seed_input: [64]u8 = undefined;
                @memcpy(pk_seed_input[0..32], &sk_seed);
                @memcpy(pk_seed_input[32..64], &sk_prf);
                std.crypto.hash.sha2.Sha256.hash(&pk_seed_input, &pk_seed, .{});
                var kp = pq_crypto.SlhDsa256s.generateKeyPairFromSeed(sk_seed, sk_prf, pk_seed);
                const h160 = hash160FromBytes(&kp.public_key);
                address = try deriveLegacyAddress(h160, scheme.prefix(), allocator);
                pq_pk = try allocator.dupe(u8, &kp.public_key);
                pq_sk = try allocator.dupe(u8, &kp.secret_key);
            },
            .vacation_kem => {
                var seed: [32]u8 = undefined;
                std.crypto.hash.sha2.Sha256.hash(mnemonic, &seed, .{});
                var kp = pq_crypto.MlKem768.generateKeyPairFromSeed(seed);
                const h160 = hash160FromBytes(&kp.public_key);
                address = try deriveLegacyAddress(h160, scheme.prefix(), allocator);
                pq_pk = try allocator.dupe(u8, &kp.public_key);
                pq_sk = try allocator.dupe(u8, &kp.secret_key);
            },
        }

        return DomainKey{
            .scheme = scheme,
            .mnemonic = mnemonic,
            .address = address,
            .pq_public_key = pq_pk,
            .pq_secret_key = pq_sk,
        };
    }

    fn freeDomain(domain: DomainKey, allocator: std.mem.Allocator) void {
        allocator.free(domain.mnemonic);
        allocator.free(domain.address);
        if (domain.pq_public_key) |pk| allocator.free(pk);
        if (domain.pq_secret_key) |sk| {
            // Zero secret key bytes before free
            @memset(sk, 0);
            allocator.free(sk);
        }
    }
};

fn hexEncode(bytes: []const u8, allocator: std.mem.Allocator) ![]u8 {
    const hex_chars = "0123456789abcdef";
    const out = try allocator.alloc(u8, bytes.len * 2);
    for (bytes, 0..) |b, i| {
        out[i * 2] = hex_chars[b >> 4];
        out[i * 2 + 1] = hex_chars[b & 0xF];
    }
    return out;
}

// ─── Verificare PQ signatures (chain-side) ─────────────────────────────────

pub fn verifyOmniSignature(message: []const u8, signature_hex: []const u8, pubkey_hex: []const u8) bool {
    if (signature_hex.len != 128 or pubkey_hex.len != 66) return false;
    var sig_bytes: [64]u8 = undefined;
    var pk_bytes: [33]u8 = undefined;
    const hex_utils = @import("hex_utils.zig");
    _ = hex_utils.hexToBytes(signature_hex, &sig_bytes) catch return false;
    _ = hex_utils.hexToBytes(pubkey_hex, &pk_bytes) catch return false;
    return secp256k1_mod.Secp256k1Crypto.verify(pk_bytes, message, sig_bytes);
}

pub fn verifyLoveSignature(message: []const u8, signature: []const u8, public_key: []const u8) bool {
    if (public_key.len != pq_crypto.MlDsa87.PUBLIC_KEY_SIZE) return false;
    var kp: pq_crypto.MlDsa87 = undefined;
    @memcpy(&kp.public_key, public_key[0..pq_crypto.MlDsa87.PUBLIC_KEY_SIZE]);
    return kp.verify(message, signature);
}

pub fn verifyFoodSignature(message: []const u8, signature: []const u8, public_key: []const u8) bool {
    if (public_key.len != pq_crypto.Falcon512.PUBLIC_KEY_SIZE) return false;
    var kp: pq_crypto.Falcon512 = undefined;
    @memcpy(&kp.public_key, public_key[0..pq_crypto.Falcon512.PUBLIC_KEY_SIZE]);
    return kp.verify(message, signature);
}

pub fn verifyRentSignature(message: []const u8, signature: []const u8, public_key: []const u8) bool {
    if (public_key.len != pq_crypto.SlhDsa256s.PUBLIC_KEY_SIZE) return false;
    var kp: pq_crypto.SlhDsa256s = undefined;
    @memcpy(&kp.public_key, public_key[0..pq_crypto.SlhDsa256s.PUBLIC_KEY_SIZE]);
    return kp.verify(message, signature);
}

/// Dispatcher chain-side pentru verificarea semnaturilor per scheme.
pub fn verifySignature(scheme: Scheme, message: []const u8, signature: []const u8, public_key: []const u8) bool {
    return switch (scheme) {
        .omni_ecdsa => verifyOmniSignature(message, signature, public_key),
        .love_dilithium => verifyLoveSignature(message, signature, public_key),
        .food_falcon => verifyFoodSignature(message, signature, public_key),
        .rent_slh_dsa => verifyRentSignature(message, signature, public_key),
        .vacation_kem => false, // KEM nu semneaza
    };
}

// ─── Teste ──────────────────────────────────────────────────────────────────

const testing = std.testing;

test "IsolatedWallet.generate produces 5 distinct addresses" {
    const wallet = try IsolatedWallet.generate(testing.allocator);
    defer wallet.deinit();

    try testing.expect(wallet.omni.address.len > 0);
    try testing.expect(wallet.love.address.len > 0);
    try testing.expect(wallet.food.address.len > 0);
    try testing.expect(wallet.rent.address.len > 0);
    try testing.expect(wallet.vacation.address.len > 0);

    // Toate adresele trebuie sa fie distincte
    try testing.expect(!std.mem.eql(u8, wallet.omni.address, wallet.love.address));
    try testing.expect(!std.mem.eql(u8, wallet.love.address, wallet.food.address));
    try testing.expect(!std.mem.eql(u8, wallet.food.address, wallet.rent.address));
    try testing.expect(!std.mem.eql(u8, wallet.rent.address, wallet.vacation.address));
}

test "IsolatedWallet.generate prefixes match scheme" {
    const wallet = try IsolatedWallet.generate(testing.allocator);
    defer wallet.deinit();

    try testing.expect(std.mem.startsWith(u8, wallet.omni.address, "ob1q"));
    try testing.expect(std.mem.startsWith(u8, wallet.love.address, "ob_k1_"));
    try testing.expect(std.mem.startsWith(u8, wallet.food.address, "ob_f5_"));
    try testing.expect(std.mem.startsWith(u8, wallet.rent.address, "ob_d5_"));
    try testing.expect(std.mem.startsWith(u8, wallet.vacation.address, "ob_s3_"));
}

test "IsolatedWallet.signOmni produces valid ECDSA signature" {
    const wallet = try IsolatedWallet.generate(testing.allocator);
    defer wallet.deinit();

    const msg = "test message omni";
    const sig_hex = try wallet.signOmni(msg, testing.allocator);
    defer testing.allocator.free(sig_hex);

    try testing.expectEqual(@as(usize, 128), sig_hex.len);

    // Verify cu pubkey derivat din mnemonic
    const bip32 = try bip32_mod.BIP32Wallet.initFromMnemonic(wallet.omni.mnemonic, testing.allocator);
    const privkey = try bip32.deriveChildKeyForPath(44, 777, 0);
    const pubkey = try secp256k1_mod.Secp256k1Crypto.privateKeyToPublicKey(privkey);
    var pk_hex: [66]u8 = undefined;
    const hex_chars = "0123456789abcdef";
    for (pubkey, 0..) |b, i| {
        pk_hex[i * 2] = hex_chars[b >> 4];
        pk_hex[i * 2 + 1] = hex_chars[b & 0xF];
    }
    try testing.expect(verifyOmniSignature(msg, sig_hex, &pk_hex));
}

test "IsolatedWallet.signLove produces valid Dilithium signature" {
    const wallet = try IsolatedWallet.generate(testing.allocator);
    defer wallet.deinit();

    const msg = "test message love";
    const sig = try wallet.signLove(msg, testing.allocator);
    defer testing.allocator.free(sig);

    try testing.expect(sig.len > 0);
    try testing.expect(wallet.love.pq_public_key != null);
    try testing.expect(verifyLoveSignature(msg, sig, wallet.love.pq_public_key.?));
}

test "Cross-domain signature rejection — LOVE sig fails OMNI verify" {
    const wallet = try IsolatedWallet.generate(testing.allocator);
    defer wallet.deinit();

    const msg = "test cross domain";
    const love_sig = try wallet.signLove(msg, testing.allocator);
    defer testing.allocator.free(love_sig);

    // OMNI verifier pe o semnatura LOVE trebuie sa esueze
    const bip32 = try bip32_mod.BIP32Wallet.initFromMnemonic(wallet.omni.mnemonic, testing.allocator);
    const privkey = try bip32.deriveChildKeyForPath(44, 777, 0);
    const pubkey = try secp256k1_mod.Secp256k1Crypto.privateKeyToPublicKey(privkey);
    var pk_hex: [66]u8 = undefined;
    const hex_chars = "0123456789abcdef";
    for (pubkey, 0..) |b, i| {
        pk_hex[i * 2] = hex_chars[b >> 4];
        pk_hex[i * 2 + 1] = hex_chars[b & 0xF];
    }
    try testing.expect(!verifyOmniSignature(msg, love_sig, &pk_hex));
}

test "IsolatedWallet.fromMnemonics round-trip" {
    const wallet1 = try IsolatedWallet.generate(testing.allocator);
    defer wallet1.deinit();

    const wallet2 = try IsolatedWallet.fromMnemonics(
        wallet1.omni.mnemonic,
        wallet1.love.mnemonic,
        wallet1.food.mnemonic,
        wallet1.rent.mnemonic,
        wallet1.vacation.mnemonic,
        testing.allocator,
    );
    defer wallet2.deinit();

    try testing.expectEqualStrings(wallet1.omni.address, wallet2.omni.address);
    try testing.expectEqualStrings(wallet1.love.address, wallet2.love.address);
    try testing.expectEqualStrings(wallet1.food.address, wallet2.food.address);
    try testing.expectEqualStrings(wallet1.rent.address, wallet2.rent.address);
    try testing.expectEqualStrings(wallet1.vacation.address, wallet2.vacation.address);
}

test "IsolatedWallet.fromMnemonics partial restore" {
    const wallet1 = try IsolatedWallet.generate(testing.allocator);
    defer wallet1.deinit();

    const wallet2 = try IsolatedWallet.fromMnemonics(
        wallet1.omni.mnemonic,
        null, null, null, null,
        testing.allocator,
    );
    defer wallet2.deinit();

    try testing.expectEqualStrings(wallet1.omni.address, wallet2.omni.address);
    try testing.expectEqualStrings("", wallet2.love.address);
}

test "verifySignature dispatcher omni path" {
    const wallet = try IsolatedWallet.generate(testing.allocator);
    defer wallet.deinit();

    const msg = "dispatcher test";
    const sig_hex = try wallet.signOmni(msg, testing.allocator);
    defer testing.allocator.free(sig_hex);

    const bip32 = try bip32_mod.BIP32Wallet.initFromMnemonic(wallet.omni.mnemonic, testing.allocator);
    const privkey = try bip32.deriveChildKeyForPath(44, 777, 0);
    const pubkey = try secp256k1_mod.Secp256k1Crypto.privateKeyToPublicKey(privkey);
    var pk_hex: [66]u8 = undefined;
    const hex_chars = "0123456789abcdef";
    for (pubkey, 0..) |b, i| {
        pk_hex[i * 2] = hex_chars[b >> 4];
        pk_hex[i * 2 + 1] = hex_chars[b & 0xF];
    }
    try testing.expect(verifySignature(.omni_ecdsa, msg, sig_hex, &pk_hex));
}

test "Scheme.fromAddress round-trip" {
    try testing.expectEqual(Scheme.omni_ecdsa, Scheme.fromAddress("ob1qxxx").?);
    try testing.expectEqual(Scheme.love_dilithium, Scheme.fromAddress("ob_k1_xxx").?);
    try testing.expectEqual(Scheme.food_falcon, Scheme.fromAddress("ob_f5_xxx").?);
    try testing.expectEqual(Scheme.rent_slh_dsa, Scheme.fromAddress("ob_d5_xxx").?);
    try testing.expectEqual(Scheme.vacation_kem, Scheme.fromAddress("ob_s3_xxx").?);
    try testing.expect(Scheme.fromAddress("invalid") == null);
}
