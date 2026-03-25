const std = @import("std");
const crypto_mod = @import("crypto.zig");
const secp256k1_mod = @import("secp256k1.zig");

const Crypto = crypto_mod.Crypto;
const Secp256k1Crypto = secp256k1_mod.Secp256k1Crypto;

/// BIP-32 Hierarchical Deterministic Wallet
/// HMAC-SHA512 real + secp256k1 real pentru compressed pubkey
pub const BIP32Wallet = struct {
    master_seed: [64]u8,
    master_key: [32]u8,
    master_chain_code: [32]u8,
    allocator: std.mem.Allocator,

    const HARDENED_OFFSET: u32 = 0x80000000;

    /// Init din mnemonic — BIP-39 COMPLET
    /// PBKDF2-HMAC-SHA512(password=mnemonic, salt="mnemonic"+passphrase, c=2048, dkLen=64)
    /// Identic cu toate implementarile BIP-39 standard (Bitcoin, Ethereum, etc.)
    pub fn initFromMnemonic(mnemonic: []const u8, allocator: std.mem.Allocator) !BIP32Wallet {
        return try initFromMnemonicPassphrase(mnemonic, "", allocator);
    }

    /// BIP-39 cu passphrase optionala
    pub fn initFromMnemonicPassphrase(mnemonic: []const u8, passphrase: []const u8, allocator: std.mem.Allocator) !BIP32Wallet {
        // Salt BIP-39: "mnemonic" + passphrase (UTF-8)
        const prefix = "mnemonic";
        const salt = try allocator.alloc(u8, prefix.len + passphrase.len);
        defer allocator.free(salt);
        @memcpy(salt[0..prefix.len], prefix);
        @memcpy(salt[prefix.len..], passphrase);

        // PBKDF2-HMAC-SHA512: 2048 iteratii → 64 bytes seed
        var seed: [64]u8 = undefined;
        try std.crypto.pwhash.pbkdf2(
            &seed,
            mnemonic,
            salt,
            2048,
            std.crypto.auth.hmac.sha2.HmacSha512,
        );

        return try initFromSeed(seed, allocator);
    }

    /// Init din seed raw 64 bytes (output BIP-39 PBKDF2)
    /// BIP-32 master: IL||IR = HMAC-SHA512("Bitcoin seed", seed)
    pub fn initFromSeed(seed: [64]u8, allocator: std.mem.Allocator) !BIP32Wallet {
        const master_hmac = Crypto.hmacSha512("Bitcoin seed", &seed);

        var master_key: [32]u8 = undefined;
        @memcpy(&master_key, master_hmac[0..32]);

        var master_chain_code: [32]u8 = undefined;
        @memcpy(&master_chain_code, master_hmac[32..64]);

        return BIP32Wallet{
            .master_seed = seed,
            .master_key = master_key,
            .master_chain_code = master_chain_code,
            .allocator = allocator,
        };
    }

    /// Deriva cheie la m/44'/0'/0'/0/index
    pub fn deriveChildKey(self: *const BIP32Wallet, index: u32) ![32]u8 {
        return self.deriveChildKeyForPath(44, 0, index);
    }

    /// Deriva cheie la m/purpose'/coin_type'/0'/0/index (BIP-44)
    pub fn deriveChildKeyForPath(self: *const BIP32Wallet, purpose: u32, coin_type: u32, index: u32) ![32]u8 {
        var current_key = self.master_key;
        var current_chain_code = self.master_chain_code;

        const path = [_]u32{
            purpose + HARDENED_OFFSET,
            coin_type + HARDENED_OFFSET,
            0 + HARDENED_OFFSET,
            0,
            index,
        };

        for (path) |step| {
            const child = try deriveChildReal(current_key, current_chain_code, step);
            current_key = child[0];
            current_chain_code = child[1];
        }

        return current_key;
    }

    // secp256k1 order n (big-endian 32 bytes)
    // n = FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141
    const SECP256K1_N = [32]u8{
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFE,
        0xBA, 0xAE, 0xDC, 0xE6, 0xAF, 0x48, 0xA0, 0x3B,
        0xBF, 0xD2, 0x5E, 0x8C, 0xD0, 0x36, 0x41, 0x41,
    };

    /// Adunare scalara 256-bit: (a + b) mod n, reprezentare big-endian
    /// Fara alocare, fara FFI — pure Zig
    fn scalarAddModN(a: [32]u8, b: [32]u8) [32]u8 {
        const n = SECP256K1_N;
        var sum: [32]u8 = undefined;
        var carry: u16 = 0;
        // Adunare cu carry, de la byte LSB (index 31) spre MSB (index 0)
        var i: usize = 32;
        while (i > 0) {
            i -= 1;
            const s: u16 = @as(u16, a[i]) + @as(u16, b[i]) + carry;
            sum[i] = @truncate(s);
            carry = s >> 8;
        }
        // Detectam overflow: carry sau sum >= n
        var need_sub = carry != 0;
        if (!need_sub) {
            for (0..32) |j| {
                if (sum[j] > n[j]) { need_sub = true; break; }
                if (sum[j] < n[j]) break;
            }
        }
        // sum = sum - n daca depaseste
        if (need_sub) {
            var borrow: u16 = 0;
            var k: usize = 32;
            while (k > 0) {
                k -= 1;
                const a_val: u16 = sum[k];
                const b_val: u16 = n[k] + borrow;
                if (a_val >= b_val) {
                    sum[k] = @truncate(a_val - b_val);
                    borrow = 0;
                } else {
                    sum[k] = @truncate(a_val + 256 - b_val);
                    borrow = 1;
                }
            }
        }
        return sum;
    }

    /// BIP-32 child key derivation cu HMAC-SHA512 REAL + secp256k1 REAL
    fn deriveChildReal(parent_key: [32]u8, parent_chain_code: [32]u8, index: u32) ![2][32]u8 {
        var data: [37]u8 = undefined;

        if (index >= HARDENED_OFFSET) {
            // Hardened: 0x00 || parent_private_key || index (big-endian)
            data[0] = 0x00;
            @memcpy(data[1..33], &parent_key);
        } else {
            // Normal: compressed_pubkey(parent_key) || index
            // REAL secp256k1: private_key × G → compressed 33 bytes
            const pubkey = try Secp256k1Crypto.privateKeyToPublicKey(parent_key);
            @memcpy(data[0..33], &pubkey);
        }

        // Index big-endian 4 bytes
        data[33] = @as(u8, @truncate((index >> 24) & 0xFF));
        data[34] = @as(u8, @truncate((index >> 16) & 0xFF));
        data[35] = @as(u8, @truncate((index >> 8) & 0xFF));
        data[36] = @as(u8, @truncate(index & 0xFF));

        // HMAC-SHA512(Key=parent_chain_code, Data=data) — REAL
        const hmac_result = Crypto.hmacSha512(&parent_chain_code, &data);

        // IL = primii 32 bytes din HMAC
        var il: [32]u8 = undefined;
        @memcpy(&il, hmac_result[0..32]);

        // child_key = (IL + parent_key) mod n — REAL secp256k1 scalar addition
        const child_key = scalarAddModN(il, parent_key);

        // child_chain_code = IR (ultimii 32 bytes HMAC)
        var child_chain_code: [32]u8 = undefined;
        @memcpy(&child_chain_code, hmac_result[32..64]);

        return [2][32]u8{ child_key, child_chain_code };
    }

    /// Genereaza compressed public key din cheie derivata
    /// Acum REAL: secp256k1 point multiply
    pub fn derivePublicKey(self: *const BIP32Wallet, index: u32) ![33]u8 {
        const priv = try self.deriveChildKey(index);
        return try Secp256k1Crypto.privateKeyToPublicKey(priv);
    }

    /// Genereaza adresa din cheie derivata
    pub fn deriveAddress(self: *const BIP32Wallet, index: u32, prefix: []const u8, allocator: std.mem.Allocator) ![]u8 {
        const key = try self.deriveChildKey(index);
        // hash160: SHA256(SHA256(pubkey))[0..20] — placeholder pentru SHA256(RIPEMD160(pubkey))
        const hash160 = try Secp256k1Crypto.privateKeyToHash160(key);
        const hex = try Crypto.bytesToHex(&hash160, allocator);
        defer allocator.free(hex);
        return std.fmt.allocPrint(allocator, "{s}{s}", .{ prefix, hex[0..12] });
    }

    /// Genereaza adresa pentru domeniu PQ cu coin_type specific
    pub fn deriveAddressForDomain(self: *const BIP32Wallet, coin_type: u32, index: u32, prefix: []const u8, allocator: std.mem.Allocator) ![]u8 {
        const key = try self.deriveChildKeyForPath(44, coin_type, index);
        const hash160 = try Secp256k1Crypto.privateKeyToHash160(key);
        const hex = try Crypto.bytesToHex(&hash160, allocator);
        defer allocator.free(hex);
        return std.fmt.allocPrint(allocator, "{s}{s}", .{ prefix, hex[0..12] });
    }
};

/// Manager pentru cele 5 domenii Post-Quantum OmniBus
pub const PQDomainDerivation = struct {
    wallet: BIP32Wallet,

    pub const Domain = struct {
        name: []const u8,
        algorithm: []const u8,
        prefix: []const u8,
        coin_type: u32,
        security_level: u32,
    };

    pub const DOMAINS = [_]Domain{
        .{ .name = "omnibus.omni",     .algorithm = "Dilithium-5 + Kyber-768", .prefix = "ob_omni_", .coin_type = 777, .security_level = 256 },
        .{ .name = "omnibus.love",     .algorithm = "ML-DSA (Dilithium-5)",    .prefix = "ob_k1_",   .coin_type = 778, .security_level = 256 },
        .{ .name = "omnibus.food",     .algorithm = "Falcon-512",              .prefix = "ob_f5_",   .coin_type = 779, .security_level = 192 },
        .{ .name = "omnibus.rent",     .algorithm = "SLH-DSA (SPHINCS+)",      .prefix = "ob_d5_",   .coin_type = 780, .security_level = 256 },
        .{ .name = "omnibus.vacation", .algorithm = "Falcon-Light / AES-128",  .prefix = "ob_s3_",   .coin_type = 781, .security_level = 128 },
    };

    pub fn init(wallet: BIP32Wallet) PQDomainDerivation {
        return PQDomainDerivation{ .wallet = wallet };
    }

    pub fn deriveAllAddresses(self: *const PQDomainDerivation, allocator: std.mem.Allocator) ![5][]u8 {
        var addresses: [5][]u8 = undefined;
        for (DOMAINS, 0..) |domain, i| {
            addresses[i] = try self.wallet.deriveAddressForDomain(domain.coin_type, 0, domain.prefix, allocator);
        }
        return addresses;
    }

    pub fn getDomain(index: u32) ?Domain {
        if (index < DOMAINS.len) return DOMAINS[index];
        return null;
    }
};

// ─── Teste ───────────────────────────────────────────────────────────────────

const testing = std.testing;

test "BIP32 init din mnemonic" {
    const mnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
    const wallet = try BIP32Wallet.initFromMnemonic(mnemonic, testing.allocator);
    var all_zero = true;
    for (wallet.master_key) |b| { if (b != 0) { all_zero = false; break; } }
    try testing.expect(!all_zero);
}

test "BIP32 + secp256k1 — public key real din cheie derivata" {
    const mnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
    const wallet = try BIP32Wallet.initFromMnemonic(mnemonic, testing.allocator);
    const pubkey = try wallet.derivePublicKey(0);
    // Compressed: 33 bytes, prefix 0x02 sau 0x03
    try testing.expectEqual(@as(usize, 33), pubkey.len);
    try testing.expect(pubkey[0] == 0x02 or pubkey[0] == 0x03);
}

test "BIP32 determinist — acelasi seed → aceeasi cheie publica" {
    const mnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
    const w1 = try BIP32Wallet.initFromMnemonic(mnemonic, testing.allocator);
    const w2 = try BIP32Wallet.initFromMnemonic(mnemonic, testing.allocator);
    const pk1 = try w1.derivePublicKey(0);
    const pk2 = try w2.derivePublicKey(0);
    try testing.expectEqualSlices(u8, &pk1, &pk2);
}

test "BIP32 — indici diferiti → chei publice diferite" {
    const mnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
    const wallet = try BIP32Wallet.initFromMnemonic(mnemonic, testing.allocator);
    const pk0 = try wallet.derivePublicKey(0);
    const pk1 = try wallet.derivePublicKey(1);
    try testing.expect(!std.mem.eql(u8, &pk0, &pk1));
}

test "BIP32 — coin_type diferit → chei diferite" {
    const mnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
    const wallet = try BIP32Wallet.initFromMnemonic(mnemonic, testing.allocator);
    const k777 = try wallet.deriveChildKeyForPath(44, 777, 0);
    const k778 = try wallet.deriveChildKeyForPath(44, 778, 0);
    try testing.expect(!std.mem.eql(u8, &k777, &k778));
}

test "BIP-39 PBKDF2 — vector oficial (abandon x11 + about, passphrase TREZOR)" {
    // Vector oficial din BIP-39 spec / Trezor test vectors
    // https://github.com/trezor/python-mnemonic/blob/master/vectors.json
    const mnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
    const wallet = try BIP32Wallet.initFromMnemonicPassphrase(mnemonic, "TREZOR", testing.allocator);
    // Primii 32 bytes din seed trebuie sa fie exact:
    // c55257c360c07c72029aebc1b53c05ed0362ada38ead3e3e9efa3708e5349553
    const expected_seed_prefix = [32]u8{
        0xc5, 0x52, 0x57, 0xc3, 0x60, 0xc0, 0x7c, 0x72,
        0x02, 0x9a, 0xeb, 0xc1, 0xb5, 0x3c, 0x05, 0xed,
        0x03, 0x62, 0xad, 0xa3, 0x8e, 0xad, 0x3e, 0x3e,
        0x9e, 0xfa, 0x37, 0x08, 0xe5, 0x34, 0x95, 0x53,
    };
    try testing.expectEqualSlices(u8, &expected_seed_prefix, wallet.master_seed[0..32]);
}

test "PQ domains — prefixe corecte cu secp256k1 real" {
    const mnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
    const wallet = try BIP32Wallet.initFromMnemonic(mnemonic, testing.allocator);
    const pq = PQDomainDerivation.init(wallet);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const addrs = try pq.deriveAllAddresses(arena.allocator());
    try testing.expect(addrs.len == 5);
    try testing.expect(std.mem.startsWith(u8, addrs[0], "ob_omni_"));
    try testing.expect(std.mem.startsWith(u8, addrs[1], "ob_k1_"));
    try testing.expect(std.mem.startsWith(u8, addrs[2], "ob_f5_"));
    try testing.expect(std.mem.startsWith(u8, addrs[3], "ob_d5_"));
    try testing.expect(std.mem.startsWith(u8, addrs[4], "ob_s3_"));
}
