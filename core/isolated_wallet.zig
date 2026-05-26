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
/// Soulbound (non-transferable, identity-bound — codes 1..4):
///   LOVE     = ML-DSA-87           (adresa ob_k1_...)  → mirror of obk1_
///   FOOD     = Falcon-512          (adresa ob_f5_...)  → mirror of obf5_
///   VACATION = ML-DSA-87 (Dilithium alias)
///                                  (adresa ob_s3_...)  → mirror of obs3_
///   RENT     = SLH-DSA-256s        (adresa ob_d5_...)  → mirror of obd5_
///
/// Design: the 4 soulbound prefixes mirror the 4 transferable PQ-OMNI
/// prefixes (obk1_/obf5_/obs3_/obd5_) byte-for-byte except for the leading
/// underscore. Same algorithm family on each pair so users see consistent
/// semantics; the underscore visually distinguishes "this is identity, not
/// money".
///
///   OMNI     = secp256k1 ECDSA    (adresa ob1q...)
///
/// NOTA: pentru chain-side, mnemonic-ul e stocat ca hex string de 64 chars
/// (32 bytes entropy). Conversia BIP-39 la cuvinte e responsabilitatea UI-ului.

pub const Scheme = enum(u8) {
    omni_ecdsa = 0,
    love_dilithium = 1,
    food_falcon = 2,
    rent_ml_dsa = 3,
    vacation_slh_dsa = 4,
    // PQ-OMNI — transferable OMNI wallets protected by post-quantum sigs.
    // Added 2026-04-30. Same balance semantics as omni_ecdsa (transferable,
    // any address can send/receive OMNI), only the signature verification
    // path differs. UI prefixes: ob_q1_…/q2_…/q3_…/q4_…
    pq_omni_ml_dsa = 5,    // ML-DSA-87  (NIST FIPS 204, "Dilithium-5")
    pq_omni_falcon = 6,    // Falcon-512 (NIST FIPS 206, alt PQ signature)
    pq_omni_dilithium = 7, // Dilithium-5 alias kept distinct so the
                           // chain can route to a dedicated verifier
                           // even though both 5 and 7 use ML-DSA in
                           // liboqs naming. 5 is the canonical OmniBus
                           // pick; 7 is for advanced users mixing.
    pq_omni_slh_dsa = 8,   // SLH-DSA-256s (NIST FIPS 205, hash-based)

    // Phase 2 hybrid (defense-in-depth) — verifica AMBELE semnaturi
    // (ECDSA + PQ) inainte de a accepta TX. Format semnatura combinat:
    //   "<ecdsa_hex>|<pq_hex>"   (despartite cu byte ASCII '|')
    // Daca oricare verificare esueaza, TX e respins. Schemele 5..8 raman ca
    // backward-compat (verifica doar PQ-ul). Adresele folosesc prefixul
    // "ob_h{N}_" pe acelasi tipar ca ob_q{N}_ ca sa fie usor de citit.
    hybrid_q1 = 9,    // ECDSA + ML-DSA-87 (Dilithium-5)
    hybrid_q2 = 10,   // ECDSA + Falcon-512
    hybrid_q3 = 11,   // ECDSA + Dilithium-5 (ML-DSA-87) — aligned with code 7
    hybrid_q4 = 12,   // ECDSA + SLH-DSA-256s

    pub fn prefix(self: Scheme) []const u8 {
        return switch (self) {
            .omni_ecdsa => "ob1q",
            .love_dilithium => "ob_k1_",
            .food_falcon => "ob_f5_",
            .rent_ml_dsa => "ob_d5_",
            .vacation_slh_dsa => "ob_s3_",
            // PQ-OMNI transferable (Phase 1 — verifica DOAR PQ signature):
            // prefixele dispar de underscore-ul de la inceput, sa nu se confunde
            // vizual cu cele 4 PQ soulbound (ob_k1_/ob_f5_/ob_d5_/ob_s3_).
            // User vede: obk1_... = transferable Dilithium-OMNI, ob_k1_... = soulbound LOVE.
            // Canon prefixes — must align across chain + UI + audit tools.
            // See STATUS/MASTER_RULES_PQ_OMNI.md for the single source of truth.
            .pq_omni_ml_dsa    => "obk1_",  // ML-DSA-87    (FIPS 204)
            .pq_omni_falcon    => "obf5_",  // Falcon-512   (FIPS 206)
            .pq_omni_dilithium => "obs3_",  // Dilithium-5
            .pq_omni_slh_dsa   => "obd5_",  // SLH-DSA-256s (FIPS 205)
            // Hybrid Phase 2 (verifica ECDSA AND PQ) — folosim aceleasi prefixe
            // ca PQ-OMNI; chain-ul distinge prin scheme-num din TX, nu prin prefix.
            // Asta inseamna ca o adresa obk1_... poate primi TX-uri scheme=5
            // (PQ only) SAU scheme=9 (hybrid). Walletul alege la signing.
            .hybrid_q1 => "obk1_",
            .hybrid_q2 => "obf5_",
            .hybrid_q3 => "obs3_",
            .hybrid_q4 => "obd5_",
        };
    }

    pub fn fromAddress(addr: []const u8) ?Scheme {
        // ATENTIE: ordine specifica → cele 4 PQ soulbound (cu underscore initial)
        // trebuie verificate INAINTE de PQ-OMNI transferable (fara underscore).
        // Mai stricte mai intai ca sa nu se confunde:
        //   ob_k1_... → soulbound LOVE
        //   obk1_...  → PQ-OMNI Dilithium transferable
        if (std.mem.startsWith(u8, addr, "ob1q")) return .omni_ecdsa;
        if (std.mem.startsWith(u8, addr, "ob_k1_")) return .love_dilithium;
        if (std.mem.startsWith(u8, addr, "ob_f5_")) return .food_falcon;
        if (std.mem.startsWith(u8, addr, "ob_d5_")) return .rent_ml_dsa;
        if (std.mem.startsWith(u8, addr, "ob_s3_")) return .vacation_slh_dsa;
        // PQ-OMNI / Hybrid: fara underscore initial
        // Schema = pq_omni_* (Phase 1) DAR walletul poate semna ca hybrid (Phase 2).
        // Returnam pq_omni_* aici si chain-ul distinge schema reala din TX.scheme.
        if (std.mem.startsWith(u8, addr, "obk1_")) return .pq_omni_ml_dsa;
        if (std.mem.startsWith(u8, addr, "obf5_")) return .pq_omni_falcon;
        if (std.mem.startsWith(u8, addr, "obs3_")) return .pq_omni_dilithium;
        if (std.mem.startsWith(u8, addr, "obd5_")) return .pq_omni_slh_dsa;
        return null;
    }

    /// True if this scheme allows transferable OMNI balance. The 4 reputation
    /// cup domains (LOVE/FOOD/RENT/VACATION) are soulbound — addresses exist
    /// but balance can't be sent OUT, only the chain emits drips into them.
    /// PQ-OMNI is transferable, just signed with a different algorithm.
    pub fn isTransferable(self: Scheme) bool {
        return switch (self) {
            .omni_ecdsa,
            .pq_omni_ml_dsa,
            .pq_omni_falcon,
            .pq_omni_dilithium,
            .pq_omni_slh_dsa,
            .hybrid_q1,
            .hybrid_q2,
            .hybrid_q3,
            .hybrid_q4 => true,
            .love_dilithium,
            .food_falcon,
            .rent_ml_dsa,
            .vacation_slh_dsa => false,
        };
    }

    /// True daca scheme-ul e hibrid (verifica AMBELE semnaturi: ECDSA + PQ).
    pub fn isHybrid(self: Scheme) bool {
        return switch (self) {
            .hybrid_q1, .hybrid_q2, .hybrid_q3, .hybrid_q4 => true,
            else => false,
        };
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
        wallet.rent = try generateDomain(allocator, .rent_ml_dsa);
        errdefer freeDomain(wallet.rent, allocator);

        // VACATION — ML-KEM (Kyber) — doar encapsulation, nu signing
        wallet.vacation = try generateDomain(allocator, .vacation_slh_dsa);
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
        wallet.rent = try restoreDomain(allocator, .rent_ml_dsa, rent_mnemonic);
        errdefer freeDomain(wallet.rent, allocator);
        wallet.vacation = try restoreDomain(allocator, .vacation_slh_dsa, vacation_mnemonic);
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
                var kp = try pq_crypto.MlDsa87.generateKeyPairFromSeed(seed);
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
                var kp = try pq_crypto.Falcon512.generateKeyPairFromSeed(seed);
                const h160 = hash160FromBytes(&kp.public_key);
                address = try deriveLegacyAddress(h160, scheme.prefix(), allocator);
                pq_pk = try allocator.dupe(u8, &kp.public_key);
                pq_sk = try allocator.dupe(u8, &kp.secret_key);
            },
            .rent_ml_dsa => {
                var sk_seed: [32]u8 = undefined;
                var sk_prf: [32]u8 = undefined;
                var pk_seed: [32]u8 = undefined;
                std.crypto.hash.sha2.Sha256.hash(mnemonic, &sk_seed, .{});
                std.crypto.hash.sha3.Sha3_256.hash(mnemonic, &sk_prf, .{});
                var pk_seed_input: [64]u8 = undefined;
                @memcpy(pk_seed_input[0..32], &sk_seed);
                @memcpy(pk_seed_input[32..64], &sk_prf);
                std.crypto.hash.sha2.Sha256.hash(&pk_seed_input, &pk_seed, .{});
                var kp = try pq_crypto.SlhDsa256s.generateKeyPairFromSeed(sk_seed, sk_prf, pk_seed);
                const h160 = hash160FromBytes(&kp.public_key);
                address = try deriveLegacyAddress(h160, scheme.prefix(), allocator);
                pq_pk = try allocator.dupe(u8, &kp.public_key);
                pq_sk = try allocator.dupe(u8, &kp.secret_key);
            },
            .vacation_slh_dsa => {
                // Soulbound vacation mirrors transferable obs3_ (Dilithium-5)
                // — both use ML-DSA-87 signing for design consistency. The
                // legacy enum name `vacation_slh_dsa` is kept for backwards
                // compatibility but no longer means ML-KEM. KEM remains
                // available as a separate primitive in pq_crypto for
                // encryption use cases that don't need an on-chain address.
                var seed: [32]u8 = undefined;
                std.crypto.hash.sha2.Sha256.hash(mnemonic, &seed, .{});
                var kp = try pq_crypto.MlDsa87.generateKeyPairFromSeed(seed);
                const h160 = hash160FromBytes(&kp.public_key);
                address = try deriveLegacyAddress(h160, scheme.prefix(), allocator);
                pq_pk = try allocator.dupe(u8, &kp.public_key);
                pq_sk = try allocator.dupe(u8, &kp.secret_key);
            },
            // PQ-OMNI transferable — same coin_type as the matching soulbound
            // slot (778=LOVE/Q1, 779=FOOD/Q2, 780=RENT/Q3, 781=VACATION/Q4),
            // but BIP-44 account=1 (soulbound uses account=0). Authoritative
            // mapping lives in `omnibus-crypto-core/rust/src/pq_addresses.rs`.
            // Mnemonic input here is the per-domain seed (caller derived it
            // with the correct account already).
            .pq_omni_ml_dsa, .pq_omni_dilithium => {
                var seed: [32]u8 = undefined;
                std.crypto.hash.sha2.Sha256.hash(mnemonic, &seed, .{});
                var kp = try pq_crypto.MlDsa87.generateKeyPairFromSeed(seed);
                const h160 = hash160FromBytes(&kp.public_key);
                address = try deriveLegacyAddress(h160, scheme.prefix(), allocator);
                pq_pk = try allocator.dupe(u8, &kp.public_key);
                pq_sk = try allocator.dupe(u8, &kp.secret_key);
            },
            .pq_omni_falcon => {
                var hash512: [64]u8 = undefined;
                std.crypto.hash.sha2.Sha512.hash(mnemonic, &hash512, .{});
                var seed: [48]u8 = undefined;
                @memcpy(&seed, hash512[0..48]);
                var kp = try pq_crypto.Falcon512.generateKeyPairFromSeed(seed);
                const h160 = hash160FromBytes(&kp.public_key);
                address = try deriveLegacyAddress(h160, scheme.prefix(), allocator);
                pq_pk = try allocator.dupe(u8, &kp.public_key);
                pq_sk = try allocator.dupe(u8, &kp.secret_key);
            },
            .pq_omni_slh_dsa => {
                var sk_seed: [32]u8 = undefined;
                var sk_prf: [32]u8 = undefined;
                var pk_seed: [32]u8 = undefined;
                std.crypto.hash.sha2.Sha256.hash(mnemonic, &sk_seed, .{});
                std.crypto.hash.sha3.Sha3_256.hash(mnemonic, &sk_prf, .{});
                var pk_seed_input: [64]u8 = undefined;
                @memcpy(pk_seed_input[0..32], &sk_seed);
                @memcpy(pk_seed_input[32..64], &sk_prf);
                std.crypto.hash.sha2.Sha256.hash(&pk_seed_input, &pk_seed, .{});
                var kp = try pq_crypto.SlhDsa256s.generateKeyPairFromSeed(sk_seed, sk_prf, pk_seed);
                const h160 = hash160FromBytes(&kp.public_key);
                address = try deriveLegacyAddress(h160, scheme.prefix(), allocator);
                pq_pk = try allocator.dupe(u8, &kp.public_key);
                pq_sk = try allocator.dupe(u8, &kp.secret_key);
            },
            // Hybrid schemes — derivarea cheilor se face la nivel de wallet
            // (Rust side, sign_hybrid_tx) deoarece sunt 2 cheipair (ECDSA+PQ).
            // Aici stocam doar adresa derivata din pubkey-ul PQ corespunzator;
            // chain-ul nu pastreaza secret keys pentru hybrid in IsolatedWallet.
            .hybrid_q1 => {
                var seed: [32]u8 = undefined;
                std.crypto.hash.sha2.Sha256.hash(mnemonic, &seed, .{});
                var kp = try pq_crypto.MlDsa87.generateKeyPairFromSeed(seed);
                const h160 = hash160FromBytes(&kp.public_key);
                address = try deriveLegacyAddress(h160, scheme.prefix(), allocator);
                pq_pk = try allocator.dupe(u8, &kp.public_key);
                pq_sk = try allocator.dupe(u8, &kp.secret_key);
            },
            .hybrid_q2 => {
                var hash512: [64]u8 = undefined;
                std.crypto.hash.sha2.Sha512.hash(mnemonic, &hash512, .{});
                var seed: [48]u8 = undefined;
                @memcpy(&seed, hash512[0..48]);
                var kp = try pq_crypto.Falcon512.generateKeyPairFromSeed(seed);
                const h160 = hash160FromBytes(&kp.public_key);
                address = try deriveLegacyAddress(h160, scheme.prefix(), allocator);
                pq_pk = try allocator.dupe(u8, &kp.public_key);
                pq_sk = try allocator.dupe(u8, &kp.secret_key);
            },
            .hybrid_q3 => {
                // Aligned with code 7 (pq_omni_dilithium / obs3_) — ML-DSA-87
                // signing, not ML-KEM. Hybrid path verifies ECDSA + ML-DSA.
                var seed: [32]u8 = undefined;
                std.crypto.hash.sha2.Sha256.hash(mnemonic, &seed, .{});
                var kp = try pq_crypto.MlDsa87.generateKeyPairFromSeed(seed);
                const h160 = hash160FromBytes(&kp.public_key);
                address = try deriveLegacyAddress(h160, scheme.prefix(), allocator);
                pq_pk = try allocator.dupe(u8, &kp.public_key);
                pq_sk = try allocator.dupe(u8, &kp.secret_key);
            },
            .hybrid_q4 => {
                var sk_seed: [32]u8 = undefined;
                var sk_prf: [32]u8 = undefined;
                var pk_seed: [32]u8 = undefined;
                std.crypto.hash.sha2.Sha256.hash(mnemonic, &sk_seed, .{});
                std.crypto.hash.sha3.Sha3_256.hash(mnemonic, &sk_prf, .{});
                var pk_seed_input: [64]u8 = undefined;
                @memcpy(pk_seed_input[0..32], &sk_seed);
                @memcpy(pk_seed_input[32..64], &sk_prf);
                std.crypto.hash.sha2.Sha256.hash(&pk_seed_input, &pk_seed, .{});
                var kp = try pq_crypto.SlhDsa256s.generateKeyPairFromSeed(sk_seed, sk_prf, pk_seed);
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
    if (public_key.len != pq_crypto.MlDsa87.PUBLIC_KEY_SIZE) {
        std.debug.print("[VERIFY-MLDSA-FAIL] pk_len={d} expected={d}\n",
            .{ public_key.len, pq_crypto.MlDsa87.PUBLIC_KEY_SIZE });
        return false;
    }
    var kp: pq_crypto.MlDsa87 = undefined;
    @memcpy(&kp.public_key, public_key[0..pq_crypto.MlDsa87.PUBLIC_KEY_SIZE]);
    const ok = kp.verify(message, signature);
    if (!ok) {
        var pk16: [32]u8 = undefined;
        var sig16: [32]u8 = undefined;
        var msg16: [32]u8 = undefined;
        const hex = "0123456789abcdef";
        const pkn = @min(16, public_key.len);
        for (public_key[0..pkn], 0..) |b, i| { pk16[i*2]=hex[b>>4]; pk16[i*2+1]=hex[b&0xf]; }
        const sn = @min(16, signature.len);
        for (signature[0..sn], 0..) |b, i| { sig16[i*2]=hex[b>>4]; sig16[i*2+1]=hex[b&0xf]; }
        const mn = @min(16, message.len);
        for (message[0..mn], 0..) |b, i| { msg16[i*2]=hex[b>>4]; msg16[i*2+1]=hex[b&0xf]; }
        std.debug.print("[VERIFY-MLDSA-FAIL] liboqs rejected: msg_len={d} sig_len={d} pk={s} sig={s} msg={s}\n",
            .{ message.len, signature.len, pk16[0..pkn*2], sig16[0..sn*2], msg16[0..mn*2] });
    }
    return ok;
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
        // PQ-OMNI verifiers reuse the matching reputation-slot verifier —
        // same algorithm, same key sizes, just a different address prefix.
        .pq_omni_ml_dsa => verifyLoveSignature(message, signature, public_key),
        .pq_omni_dilithium => verifyLoveSignature(message, signature, public_key),
        .pq_omni_falcon => verifyFoodSignature(message, signature, public_key),
        .pq_omni_slh_dsa => verifyRentSignature(message, signature, public_key),
        .rent_ml_dsa => verifyRentSignature(message, signature, public_key),
        // vacation_slh_dsa (legacy name) now uses ML-DSA-87 signing — same as
        // its transferable mirror obs3_. Verification reuses verifyLoveSignature
        // (also ML-DSA-87). Old TXs signed with the previous KEM-only impl
        // are not on-chain (soulbound vacation had no balance/TX path).
        .vacation_slh_dsa => verifyLoveSignature(message, signature, public_key),
        // Hybrid schemes folosesc verifyHybridSignature (2 pubkeys, sig combinata).
        // Daca cineva apeleaza verifySignature pe un scheme hybrid, returnam false —
        // single-pubkey API e insuficient pt defense-in-depth.
        .hybrid_q1, .hybrid_q2, .hybrid_q3, .hybrid_q4 => false,
    };
}

/// Verifica o semnatura combinata "ecdsa_hex|pq_hex" pentru schemele hybrid (9..12).
/// Defense-in-depth: AMBELE semnaturi (clasica + post-quantum) trebuie sa fie valide.
/// Daca formatul e invalid sau oricare jumatate esueaza, returneaza false.
///
/// signature_combined: ASCII bytes "<ecdsa_hex>|<pq_hex>"
/// ecdsa_public_key:   compressed secp256k1 pubkey hex (66 chars) sau bytes (33)
/// pq_public_key:      raw bytes ai cheii PQ (lungime per scheme)
pub fn verifyHybridSignature(
    scheme: Scheme,
    message: []const u8,
    signature_combined: []const u8,
    ecdsa_public_key: []const u8,
    pq_public_key: []const u8,
) bool {
    // 1. Gaseste delimitatorul '|'
    const sep = std.mem.indexOfScalar(u8, signature_combined, '|') orelse return false;
    if (sep == 0 or sep >= signature_combined.len - 1) return false;

    const ecdsa_sig_hex = signature_combined[0..sep];
    const pq_sig_hex = signature_combined[sep + 1 ..];

    // 2. ECDSA verifica primul (mai ieftin computational decat PQ).
    //    verifyOmniSignature accepta hex (sig 128 chars + pk 66 chars).
    //    Acceptam si pubkey-ul ECDSA in format raw (33 bytes) — il convertim la hex.
    var ecdsa_pk_hex_buf: [66]u8 = undefined;
    const ecdsa_pk_hex: []const u8 = if (ecdsa_public_key.len == 66)
        ecdsa_public_key
    else if (ecdsa_public_key.len == 33) blk: {
        const hex_chars = "0123456789abcdef";
        for (ecdsa_public_key, 0..) |b, i| {
            ecdsa_pk_hex_buf[i * 2] = hex_chars[b >> 4];
            ecdsa_pk_hex_buf[i * 2 + 1] = hex_chars[b & 0xF];
        }
        break :blk ecdsa_pk_hex_buf[0..66];
    } else return false;

    if (!verifyOmniSignature(message, ecdsa_sig_hex, ecdsa_pk_hex)) return false;

    // 3. Decode jumatatea PQ din hex la bytes (lungime variabila per scheme).
    if (pq_sig_hex.len % 2 != 0) return false;
    var pq_sig_buf: [64 * 1024]u8 = undefined; // suficient pt Falcon/Dilithium/SLH-DSA
    if (pq_sig_hex.len / 2 > pq_sig_buf.len) return false;
    const pq_sig_bytes = pq_sig_buf[0 .. pq_sig_hex.len / 2];
    const hex_utils = @import("hex_utils.zig");
    hex_utils.hexToBytes(pq_sig_hex, pq_sig_bytes) catch return false;

    // 4. Verifica jumatatea PQ in functie de scheme
    return switch (scheme) {
        .hybrid_q1 => verifyLoveSignature(message, pq_sig_bytes, pq_public_key),
        .hybrid_q2 => verifyFoodSignature(message, pq_sig_bytes, pq_public_key),
        // hybrid_q3 mirrors pq_omni_dilithium (code 7) — ECDSA + ML-DSA-87.
        // Same verify path as hybrid_q1 (love_dilithium also uses ML-DSA).
        .hybrid_q3 => verifyLoveSignature(message, pq_sig_bytes, pq_public_key),
        .hybrid_q4 => verifyRentSignature(message, pq_sig_bytes, pq_public_key),
        else => false,
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
    try testing.expectEqual(Scheme.rent_ml_dsa, Scheme.fromAddress("ob_d5_xxx").?);
    try testing.expectEqual(Scheme.vacation_slh_dsa, Scheme.fromAddress("ob_s3_xxx").?);
    try testing.expectEqual(Scheme.hybrid_q1, Scheme.fromAddress("ob_h1_xxx").?);
    try testing.expectEqual(Scheme.hybrid_q2, Scheme.fromAddress("ob_h2_xxx").?);
    try testing.expectEqual(Scheme.hybrid_q3, Scheme.fromAddress("ob_h3_xxx").?);
    try testing.expectEqual(Scheme.hybrid_q4, Scheme.fromAddress("ob_h4_xxx").?);
    try testing.expect(Scheme.fromAddress("invalid") == null);
}

// ─── Phase 2 hybrid verification tests ─────────────────────────────────────
// Helper: build "ecdsa_hex|pq_hex" combinat dintr-un ECDSA sig (raw 64B) si
// un PQ sig (raw bytes). Allocator-ul e responsabil pentru memorie.
fn buildHybridSig(
    ecdsa_sig_raw: [64]u8,
    pq_sig_raw: []const u8,
    allocator: std.mem.Allocator,
) ![]u8 {
    const ecdsa_hex_len = ecdsa_sig_raw.len * 2;
    const pq_hex_len = pq_sig_raw.len * 2;
    var out = try allocator.alloc(u8, ecdsa_hex_len + 1 + pq_hex_len);
    const hex_chars = "0123456789abcdef";
    for (ecdsa_sig_raw, 0..) |b, i| {
        out[i * 2] = hex_chars[b >> 4];
        out[i * 2 + 1] = hex_chars[b & 0xF];
    }
    out[ecdsa_hex_len] = '|';
    for (pq_sig_raw, 0..) |b, i| {
        out[ecdsa_hex_len + 1 + i * 2] = hex_chars[b >> 4];
        out[ecdsa_hex_len + 1 + i * 2 + 1] = hex_chars[b & 0xF];
    }
    return out;
}

test "verifyHybridSignature accepts valid combined sig (hybrid_q1)" {
    const wallet = try IsolatedWallet.generate(testing.allocator);
    defer wallet.deinit();

    const msg: []const u8 = "test hybrid msg q1";

    // 1. ECDSA half — semneaza cu OMNI keypair
    const bip32 = try bip32_mod.BIP32Wallet.initFromMnemonic(wallet.omni.mnemonic, testing.allocator);
    const privkey = try bip32.deriveChildKeyForPath(44, 777, 0);
    const ecdsa_pubkey = try secp256k1_mod.Secp256k1Crypto.privateKeyToPublicKey(privkey);
    const ecdsa_sig = try secp256k1_mod.Secp256k1Crypto.sign(privkey, msg);

    // 2. PQ half — Dilithium (LOVE)
    const pq_sig = try wallet.signLove(msg, testing.allocator);
    defer testing.allocator.free(pq_sig);

    // 3. Construieste combined sig
    const combined = try buildHybridSig(ecdsa_sig, pq_sig, testing.allocator);
    defer testing.allocator.free(combined);

    // 4. Verifica — trebuie sa treaca
    try testing.expect(isolated_wallet_verifyHybrid(
        .hybrid_q1,
        msg,
        combined,
        &ecdsa_pubkey,
        wallet.love.pq_public_key.?,
    ));
}

test "verifyHybridSignature rejects when only ECDSA half is valid" {
    const wallet = try IsolatedWallet.generate(testing.allocator);
    defer wallet.deinit();

    const msg: []const u8 = "test hybrid mixed half";

    // Valid ECDSA
    const bip32 = try bip32_mod.BIP32Wallet.initFromMnemonic(wallet.omni.mnemonic, testing.allocator);
    const privkey = try bip32.deriveChildKeyForPath(44, 777, 0);
    const ecdsa_pubkey = try secp256k1_mod.Secp256k1Crypto.privateKeyToPublicKey(privkey);
    const ecdsa_sig = try secp256k1_mod.Secp256k1Crypto.sign(privkey, msg);

    // Invalid PQ — fake bytes (wrong length / garbage)
    var fake_pq: [64]u8 = undefined;
    @memset(&fake_pq, 0xAA);

    const combined = try buildHybridSig(ecdsa_sig, &fake_pq, testing.allocator);
    defer testing.allocator.free(combined);

    try testing.expect(!isolated_wallet_verifyHybrid(
        .hybrid_q1,
        msg,
        combined,
        &ecdsa_pubkey,
        wallet.love.pq_public_key.?,
    ));
}

test "verifyHybridSignature rejects when only PQ half is valid" {
    const wallet = try IsolatedWallet.generate(testing.allocator);
    defer wallet.deinit();

    const msg: []const u8 = "test hybrid pq-only";

    // Invalid ECDSA — random bytes that don't form a valid sig pe pubkey-ul nostru
    const bip32 = try bip32_mod.BIP32Wallet.initFromMnemonic(wallet.omni.mnemonic, testing.allocator);
    const privkey = try bip32.deriveChildKeyForPath(44, 777, 0);
    const ecdsa_pubkey = try secp256k1_mod.Secp256k1Crypto.privateKeyToPublicKey(privkey);
    var fake_ecdsa_sig: [64]u8 = undefined;
    @memset(&fake_ecdsa_sig, 0x33);

    // Valid PQ
    const pq_sig = try wallet.signLove(msg, testing.allocator);
    defer testing.allocator.free(pq_sig);

    const combined = try buildHybridSig(fake_ecdsa_sig, pq_sig, testing.allocator);
    defer testing.allocator.free(combined);

    try testing.expect(!isolated_wallet_verifyHybrid(
        .hybrid_q1,
        msg,
        combined,
        &ecdsa_pubkey,
        wallet.love.pq_public_key.?,
    ));
}

test "verifyHybridSignature rejects malformed signature without |" {
    const wallet = try IsolatedWallet.generate(testing.allocator);
    defer wallet.deinit();

    const bip32 = try bip32_mod.BIP32Wallet.initFromMnemonic(wallet.omni.mnemonic, testing.allocator);
    const privkey = try bip32.deriveChildKeyForPath(44, 777, 0);
    const ecdsa_pubkey = try secp256k1_mod.Secp256k1Crypto.privateKeyToPublicKey(privkey);

    const malformed = "deadbeefnopipehere0123456789abcdef";
    try testing.expect(!isolated_wallet_verifyHybrid(
        .hybrid_q1,
        "msg",
        malformed,
        &ecdsa_pubkey,
        wallet.love.pq_public_key.?,
    ));

    // Si test pentru | la inceput / final (degenerate)
    try testing.expect(!isolated_wallet_verifyHybrid(
        .hybrid_q1,
        "msg",
        "|abcdef",
        &ecdsa_pubkey,
        wallet.love.pq_public_key.?,
    ));
    try testing.expect(!isolated_wallet_verifyHybrid(
        .hybrid_q1,
        "msg",
        "abcdef|",
        &ecdsa_pubkey,
        wallet.love.pq_public_key.?,
    ));
}

// Wrapper local pentru a folosi verifyHybridSignature in teste fara a depinde
// de import "self" — functia e top-level publicata in acelasi fisier.
fn isolated_wallet_verifyHybrid(
    scheme: Scheme,
    message: []const u8,
    signature_combined: []const u8,
    ecdsa_public_key: []const u8,
    pq_public_key: []const u8,
) bool {
    return verifyHybridSignature(scheme, message, signature_combined, ecdsa_public_key, pq_public_key);
}
