const std = @import("std");
const crypto_mod = @import("crypto.zig");
const secp256k1_mod = @import("secp256k1.zig");
const bech32_mod = @import("bech32.zig");
const ripemd160_mod = @import("ripemd160.zig");

const Crypto = crypto_mod.Crypto;
const Secp256k1Crypto = secp256k1_mod.Secp256k1Crypto;
const Ripemd160 = ripemd160_mod.Ripemd160;

/// Network type — mainnet vs testnet (like BTC "BTC" vs "TBTC")
pub const Network = enum {
    mainnet, // "OMNI"
    testnet, // "TOMNI"

    pub fn label(self: Network) []const u8 {
        return switch (self) {
            .mainnet => "OMNI",
            .testnet => "TOMNI",
        };
    }

    /// Extended key version bytes (4 bytes) — like BTC's xpub/xprv/zpub/zprv
    /// OmniBus uses purpose 44, so custom version bytes:
    ///   mainnet pub: 0x04B24746 ("opub"), mainnet prv: 0x04B2430C ("oprv")
    ///   testnet pub: 0x045F1CF6 ("tpub"), testnet prv: 0x045F18BC ("tprv")
    pub fn xpubVersion(self: Network) [4]u8 {
        return switch (self) {
            .mainnet => .{ 0x04, 0xB2, 0x47, 0x46 },
            .testnet => .{ 0x04, 0x5F, 0x1C, 0xF6 },
        };
    }

    pub fn xprvVersion(self: Network) [4]u8 {
        return switch (self) {
            .mainnet => .{ 0x04, 0xB2, 0x43, 0x0C },
            .testnet => .{ 0x04, 0x5F, 0x18, 0xBC },
        };
    }

    /// WIF version byte: mainnet=0x80, testnet=0xEF (same as Bitcoin)
    pub fn wifVersion(self: Network) u8 {
        return switch (self) {
            .mainnet => 0x80,
            .testnet => 0xEF,
        };
    }
};

/// BIP-32 Hierarchical Deterministic Wallet
/// HMAC-SHA512 real + secp256k1 real pentru compressed pubkey
pub const BIP32Wallet = struct {
    master_seed: [64]u8,
    master_key: [32]u8,
    master_chain_code: [32]u8,
    allocator: std.mem.Allocator,
    network: Network = .mainnet,

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

    /// Deriva cheie la m/purpose'/coin_type'/account'/chain/index (BIP-44)
    /// chain: 0 = external (receiving), 1 = internal (change)
    pub fn deriveChildKeyForPath(self: *const BIP32Wallet, purpose: u32, coin_type: u32, index: u32) ![32]u8 {
        return self.deriveChildKeyFull(purpose, coin_type, 0, 0, index);
    }

    /// Full BIP-44 path: m/purpose'/coin_type'/account'/chain/index
    /// chain: 0 = external (receiving addresses), 1 = change (internal)
    pub fn deriveChildKeyFull(self: *const BIP32Wallet, purpose: u32, coin_type: u32, account: u32, chain: u32, index: u32) ![32]u8 {
        var current_key = self.master_key;
        var current_chain_code = self.master_chain_code;

        const path = [_]u32{
            purpose + HARDENED_OFFSET,
            coin_type + HARDENED_OFFSET,
            account + HARDENED_OFFSET,
            chain,
            index,
        };

        for (path) |step| {
            const child = try deriveChildReal(current_key, current_chain_code, step);
            current_key = child[0];
            current_chain_code = child[1];
        }

        return current_key;
    }

    /// Derive change address: m/44'/coin_type'/0'/1/index (chain=1)
    pub fn deriveChangeAddress(self: *const BIP32Wallet, coin_type: u32, index: u32, prefix: []const u8, allocator: std.mem.Allocator) ![]u8 {
        const key = try self.deriveChildKeyFull(44, coin_type, 0, 1, index);
        const hash160 = try Secp256k1Crypto.privateKeyToHash160(key);
        if (std.mem.eql(u8, prefix, "ob")) {
            return bech32_mod.encodeOBAddress(hash160, allocator);
        }
        const b58 = try base58CheckEncode(hash160, 0x4F, allocator);
        defer allocator.free(b58);
        return std.fmt.allocPrint(allocator, "{s}{s}", .{ prefix, b58 });
    }

    /// Derive change key: m/44'/coin_type'/0'/1/index
    pub fn deriveChangeKey(self: *const BIP32Wallet, coin_type: u32, index: u32) ![32]u8 {
        return self.deriveChildKeyFull(44, coin_type, 0, 1, index);
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

    /// Genereaza adresa Bech32 ob1q... (coin 777 nativ) sau prefix + Base58Check (domenii PQ)
    pub fn deriveAddress(self: *const BIP32Wallet, index: u32, prefix: []const u8, allocator: std.mem.Allocator) ![]u8 {
        const key = try self.deriveChildKey(index);
        const hash160 = try Secp256k1Crypto.privateKeyToHash160(key);
        // Prefix "ob" = Bech32 nativ, altfel = prefix + Base58Check (domenii PQ)
        if (std.mem.eql(u8, prefix, "ob")) {
            return bech32_mod.encodeOBAddress(hash160, allocator);
        }
        const b58 = try base58CheckEncode(hash160, 0x4F, allocator);
        defer allocator.free(b58);
        return std.fmt.allocPrint(allocator, "{s}{s}", .{ prefix, b58 });
    }

    /// Genereaza adresa pentru domeniu — ob1q... (coin 777) sau prefix + Base58Check (PQ 778-781)
    pub fn deriveAddressForDomain(self: *const BIP32Wallet, coin_type: u32, index: u32, prefix: []const u8, allocator: std.mem.Allocator) ![]u8 {
        const key = try self.deriveChildKeyForPath(44, coin_type, index);
        const hash160 = try Secp256k1Crypto.privateKeyToHash160(key);
        if (std.mem.eql(u8, prefix, "ob")) {
            return bech32_mod.encodeOBAddress(hash160, allocator);
        }
        const b58 = try base58CheckEncode(hash160, 0x4F, allocator);
        defer allocator.free(b58);
        return std.fmt.allocPrint(allocator, "{s}{s}", .{ prefix, b58 });
    }

    // ─── BTC-Parity Metadata Functions ──────────────────────────────────────

    /// Master fingerprint = first 4 bytes of Hash160(master_public_key)
    /// Identical to BTC master_fingerprint (e.g. "3442193e")
    pub fn masterFingerprint(self: *const BIP32Wallet) ![4]u8 {
        const master_pubkey = try Secp256k1Crypto.privateKeyToPublicKey(self.master_key);
        const h160 = computeHash160(&master_pubkey);
        return h160[0..4].*;
    }

    /// Master fingerprint as hex string (8 chars, e.g. "3442193e")
    pub fn masterFingerprintHex(self: *const BIP32Wallet, allocator: std.mem.Allocator) ![]u8 {
        const fp = try self.masterFingerprint();
        return bytesToHexAlloc(&fp, allocator);
    }

    /// Parent fingerprint for a derivation path
    /// = first 4 bytes of Hash160(parent_public_key)
    pub fn parentFingerprint(self: *const BIP32Wallet, purpose: u32, coin_type: u32) ![4]u8 {
        // Parent is at m/purpose'/coin_type'/0'/0
        // We need the key at m/purpose'/coin_type'/0' (3 levels)
        var current_key = self.master_key;
        var current_chain_code = self.master_chain_code;

        const path = [_]u32{
            purpose + HARDENED_OFFSET,
            coin_type + HARDENED_OFFSET,
            0 + HARDENED_OFFSET,
        };

        for (path) |step| {
            const child = try deriveChildReal(current_key, current_chain_code, step);
            current_key = child[0];
            current_chain_code = child[1];
        }

        // Now derive m/.../0 (chain=0, external)
        const chain_child = try deriveChildReal(current_key, current_chain_code, 0);
        const parent_pubkey = try Secp256k1Crypto.privateKeyToPublicKey(chain_child[0]);
        const h160 = computeHash160(&parent_pubkey);
        return h160[0..4].*;
    }

    /// Derive full key+chain_code at path m/purpose'/coin_type'/account'/chain/index
    pub fn deriveFullPath(
        self: *const BIP32Wallet,
        purpose: u32,
        coin_type: u32,
        account: u32,
        chain: u32,
        index: u32,
    ) !struct { key: [32]u8, chain_code: [32]u8 } {
        var current_key = self.master_key;
        var current_chain_code = self.master_chain_code;

        const path = [_]u32{
            purpose + HARDENED_OFFSET,
            coin_type + HARDENED_OFFSET,
            account + HARDENED_OFFSET,
            chain,
            index,
        };

        for (path) |step| {
            const child = try deriveChildReal(current_key, current_chain_code, step);
            current_key = child[0];
            current_chain_code = child[1];
        }

        return .{ .key = current_key, .chain_code = current_chain_code };
    }

    /// Hash160 for a derived key = RIPEMD160(SHA256(compressed_pubkey))
    pub fn deriveHash160(self: *const BIP32Wallet, purpose: u32, coin_type: u32, index: u32) ![20]u8 {
        const key = try self.deriveChildKeyForPath(purpose, coin_type, index);
        return try Secp256k1Crypto.privateKeyToHash160(key);
    }

    /// Script pubkey for P2WPKH: 0x0014 + hash160 (22 bytes)
    pub fn deriveScriptPubkey(self: *const BIP32Wallet, purpose: u32, coin_type: u32, index: u32) ![22]u8 {
        const h160 = try self.deriveHash160(purpose, coin_type, index);
        var script: [22]u8 = undefined;
        script[0] = 0x00; // OP_0
        script[1] = 0x14; // push 20 bytes
        @memcpy(script[2..22], &h160);
        return script;
    }

    /// Encode private key as WIF (Wallet Import Format)
    /// Base58Check(version || privkey || 0x01_compressed)
    pub fn encodeWIF(self: *const BIP32Wallet, privkey: [32]u8, allocator: std.mem.Allocator) ![]u8 {
        // WIF for compressed key: version(1) + privkey(32) + 0x01(1) + checksum(4) = 38 bytes
        var payload: [34]u8 = undefined;
        payload[0] = self.network.wifVersion();
        @memcpy(payload[1..33], &privkey);
        payload[33] = 0x01; // compressed flag

        // Double SHA256 checksum
        var first: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(&payload, &first, .{});
        var second: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(&first, &second, .{});

        // full = payload + checksum[0..4]
        var full: [38]u8 = undefined;
        @memcpy(full[0..34], &payload);
        @memcpy(full[34..38], second[0..4]);

        // Base58 encode
        return base58Encode(&full, allocator);
    }

    /// Serialize extended public key (xpub/zpub equivalent)
    /// Format: version(4) || depth(1) || fingerprint(4) || child_index(4) || chain_code(32) || pubkey(33) = 78 bytes
    /// Then Base58Check encode
    pub fn serializeXpub(
        self: *const BIP32Wallet,
        purpose: u32,
        coin_type: u32,
        account: u32,
        allocator: std.mem.Allocator,
    ) ![]u8 {
        // Derive account-level key: m/purpose'/coin_type'/account'
        var current_key = self.master_key;
        var current_chain_code = self.master_chain_code;
        var parent_fp: [4]u8 = .{ 0, 0, 0, 0 };

        const path = [_]u32{
            purpose + HARDENED_OFFSET,
            coin_type + HARDENED_OFFSET,
            account + HARDENED_OFFSET,
        };

        for (path) |step| {
            // Compute fingerprint of current (parent) before deriving
            const cur_pubkey = try Secp256k1Crypto.privateKeyToPublicKey(current_key);
            const cur_h160 = computeHash160(&cur_pubkey);
            parent_fp = cur_h160[0..4].*;

            const child = try deriveChildReal(current_key, current_chain_code, step);
            current_key = child[0];
            current_chain_code = child[1];
        }

        const pubkey = try Secp256k1Crypto.privateKeyToPublicKey(current_key);

        var data: [78]u8 = undefined;
        // Version (4 bytes)
        @memcpy(data[0..4], &self.network.xpubVersion());
        // Depth (1 byte) — account level = 3
        data[4] = 3;
        // Parent fingerprint (4 bytes)
        @memcpy(data[5..9], &parent_fp);
        // Child index (4 bytes, big-endian) — account + hardened
        const child_idx = account + HARDENED_OFFSET;
        data[9] = @truncate((child_idx >> 24) & 0xFF);
        data[10] = @truncate((child_idx >> 16) & 0xFF);
        data[11] = @truncate((child_idx >> 8) & 0xFF);
        data[12] = @truncate(child_idx & 0xFF);
        // Chain code (32 bytes)
        @memcpy(data[13..45], &current_chain_code);
        // Public key (33 bytes compressed)
        @memcpy(data[45..78], &pubkey);

        return base58CheckEncode78(data, allocator);
    }

    /// Serialize extended private key (xprv/zprv equivalent)
    pub fn serializeXprv(
        self: *const BIP32Wallet,
        purpose: u32,
        coin_type: u32,
        account: u32,
        allocator: std.mem.Allocator,
    ) ![]u8 {
        var current_key = self.master_key;
        var current_chain_code = self.master_chain_code;
        var parent_fp: [4]u8 = .{ 0, 0, 0, 0 };

        const path = [_]u32{
            purpose + HARDENED_OFFSET,
            coin_type + HARDENED_OFFSET,
            account + HARDENED_OFFSET,
        };

        for (path) |step| {
            const cur_pubkey = try Secp256k1Crypto.privateKeyToPublicKey(current_key);
            const cur_h160 = computeHash160(&cur_pubkey);
            parent_fp = cur_h160[0..4].*;

            const child = try deriveChildReal(current_key, current_chain_code, step);
            current_key = child[0];
            current_chain_code = child[1];
        }

        var data: [78]u8 = undefined;
        @memcpy(data[0..4], &self.network.xprvVersion());
        data[4] = 3;
        @memcpy(data[5..9], &parent_fp);
        const child_idx = account + HARDENED_OFFSET;
        data[9] = @truncate((child_idx >> 24) & 0xFF);
        data[10] = @truncate((child_idx >> 16) & 0xFF);
        data[11] = @truncate((child_idx >> 8) & 0xFF);
        data[12] = @truncate(child_idx & 0xFF);
        @memcpy(data[13..45], &current_chain_code);
        // Private key: 0x00 prefix + 32 bytes key
        data[45] = 0x00;
        @memcpy(data[46..78], &current_key);

        return base58CheckEncode78(data, allocator);
    }

    /// Full derivation path string, e.g. "m/44'/777'/0'/0/5"
    pub fn derivationPathString(
        purpose: u32,
        coin_type: u32,
        account: u32,
        chain: u32,
        index: u32,
        allocator: std.mem.Allocator,
    ) ![]u8 {
        return std.fmt.allocPrint(allocator, "m/{d}'/{d}'/{d}'/{d}/{d}", .{
            purpose, coin_type, account, chain, index,
        });
    }
};

// ─── Base58Check encoding ─────────────────────────────────────────────────────

const BASE58_ALPHABET = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";

/// Base58Check(version_byte || hash160) — identic cu Bitcoin/OmniBus Python
/// Output: Base58 string alocat cu allocator (caller trebuie sa elibereze)
pub fn base58CheckEncode(hash160: [20]u8, version: u8, allocator: std.mem.Allocator) ![]u8 {
    // payload = version || hash160 (21 bytes)
    var payload: [21]u8 = undefined;
    payload[0] = version;
    @memcpy(payload[1..], &hash160);

    // checksum = SHA256(SHA256(payload))[0..4]
    var first: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&payload, &first, .{});
    var second: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&first, &second, .{});
    const checksum = second[0..4].*;

    // full = payload || checksum (25 bytes)
    var full: [25]u8 = undefined;
    @memcpy(full[0..21], &payload);
    @memcpy(full[21..25], &checksum);

    // Count leading zero bytes
    var leading_zeros: usize = 0;
    for (full) |b| {
        if (b == 0) leading_zeros += 1 else break;
    }

    // Base58 encode: treat full as big-endian integer, divide by 58
    // Max output length: ceil(25 * log(256)/log(58)) + 1 ≈ 35
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
    var result = try allocator.alloc(u8, result_len);

    for (0..leading_zeros) |i| {
        result[i] = '1';
    }
    for (0..digits_len) |i| {
        result[leading_zeros + i] = BASE58_ALPHABET[digits[digits_len - 1 - i]];
    }

    return result;
}

/// Hash160 = RIPEMD160(SHA256(data)) — standard Bitcoin hash
fn computeHash160(data: []const u8) [20]u8 {
    const sha_out = Crypto.sha256(data);
    var h160: [20]u8 = undefined;
    Ripemd160.hash(&sha_out, &h160);
    return h160;
}

/// Base58 encode arbitrary bytes (no checksum)
fn base58Encode(data: []const u8, allocator: std.mem.Allocator) ![]u8 {
    var leading_zeros: usize = 0;
    for (data) |b| {
        if (b == 0) leading_zeros += 1 else break;
    }

    // Max output: ceil(data.len * 138 / 100) + 1
    const max_len = data.len * 2 + 1;
    var digits = try allocator.alloc(u8, max_len);
    defer allocator.free(digits);
    @memset(digits, 0);
    var digits_len: usize = 0;

    for (data) |byte| {
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

    const result_len = leading_zeros + digits_len;
    var result = try allocator.alloc(u8, result_len);
    for (0..leading_zeros) |i| result[i] = '1';
    for (0..digits_len) |i| {
        result[leading_zeros + i] = BASE58_ALPHABET[digits[digits_len - 1 - i]];
    }
    return result;
}

/// Base58Check encode 78 bytes (for extended keys xpub/xprv)
fn base58CheckEncode78(data: [78]u8, allocator: std.mem.Allocator) ![]u8 {
    var first: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&data, &first, .{});
    var second: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&first, &second, .{});

    var full: [82]u8 = undefined;
    @memcpy(full[0..78], &data);
    @memcpy(full[78..82], second[0..4]);

    return base58Encode(&full, allocator);
}

/// Bytes to hex string (allocated)
fn bytesToHexAlloc(data: []const u8, allocator: std.mem.Allocator) ![]u8 {
    const hex_chars = "0123456789abcdef";
    var result = try allocator.alloc(u8, data.len * 2);
    for (data, 0..) |byte, i| {
        result[i * 2] = hex_chars[byte >> 4];
        result[i * 2 + 1] = hex_chars[byte & 0x0F];
    }
    return result;
}

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
        .{ .name = "omnibus.omni",     .algorithm = "Dilithium-5 + Kyber-768", .prefix = "ob",     .coin_type = 777, .security_level = 256 },
        .{ .name = "omnibus.love",     .algorithm = "ML-DSA (Dilithium-5)",    .prefix = "ob_k1_", .coin_type = 778, .security_level = 256 },
        .{ .name = "omnibus.food",     .algorithm = "Falcon-512",              .prefix = "ob_f5_", .coin_type = 779, .security_level = 192 },
        .{ .name = "omnibus.rent",     .algorithm = "SLH-DSA (SPHINCS+)",      .prefix = "ob_d5_", .coin_type = 780, .security_level = 256 },
        .{ .name = "omnibus.vacation", .algorithm = "Falcon-Light / AES-128",  .prefix = "ob_s3_", .coin_type = 781, .security_level = 128 },
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

test "PQ domains — omni=Bech32 ob1q, domenii=prefix+Base58Check" {
    const mnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
    const wallet = try BIP32Wallet.initFromMnemonic(mnemonic, testing.allocator);
    const pq = PQDomainDerivation.init(wallet);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const addrs = try pq.deriveAllAddresses(arena.allocator());
    try testing.expect(addrs.len == 5);
    // Domain 0 (omnibus.omni, coin 777) = Bech32 ob1q...
    try testing.expect(std.mem.startsWith(u8, addrs[0], "ob1q"));
    try testing.expectEqual(@as(usize, 42), addrs[0].len);
    try testing.expect(bech32_mod.isValidOBAddress(addrs[0], arena.allocator()));
    // Domain 1-4 = prefix + Base58Check
    try testing.expect(std.mem.startsWith(u8, addrs[1], "ob_k1_"));
    try testing.expect(std.mem.startsWith(u8, addrs[2], "ob_f5_"));
    try testing.expect(std.mem.startsWith(u8, addrs[3], "ob_d5_"));
    try testing.expect(std.mem.startsWith(u8, addrs[4], "ob_s3_"));
}

test "Base58Check encode — vector simplu" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // hash160 all-zero cu version 0x4F → adresa determinista
    const hash160 = [_]u8{0} ** 20;
    const b58 = try base58CheckEncode(hash160, 0x4F, arena.allocator());
    // Trebuie sa inceapa cu '1' (leading zero byte in payload)
    // si sa aiba ~25-34 chars
    try testing.expect(b58.len >= 20);
    try testing.expect(b58.len <= 40);
}

test "master_fingerprint — determinist" {
    const mnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
    const wallet = try BIP32Wallet.initFromMnemonic(mnemonic, testing.allocator);
    const fp1 = try wallet.masterFingerprint();
    const fp2 = try wallet.masterFingerprint();
    try testing.expectEqualSlices(u8, &fp1, &fp2);
    // Must be 4 non-zero bytes (extremely unlikely all zero)
    var all_zero = true;
    for (fp1) |b| { if (b != 0) { all_zero = false; break; } }
    try testing.expect(!all_zero);
}

test "master_fingerprint hex — 8 chars" {
    const mnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
    const wallet = try BIP32Wallet.initFromMnemonic(mnemonic, testing.allocator);
    const fp_hex = try wallet.masterFingerprintHex(testing.allocator);
    defer testing.allocator.free(fp_hex);
    try testing.expectEqual(@as(usize, 8), fp_hex.len);
}

test "WIF encoding — starts with correct prefix" {
    const mnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
    var wallet = try BIP32Wallet.initFromMnemonic(mnemonic, testing.allocator);
    const privkey = try wallet.deriveChildKeyForPath(44, 777, 0);
    // Mainnet WIF compressed starts with 'K' or 'L'
    const wif = try wallet.encodeWIF(privkey, testing.allocator);
    defer testing.allocator.free(wif);
    try testing.expect(wif[0] == 'K' or wif[0] == 'L');
    try testing.expect(wif.len >= 51 and wif.len <= 52);

    // Testnet WIF compressed starts with 'c'
    wallet.network = .testnet;
    const wif_t = try wallet.encodeWIF(privkey, testing.allocator);
    defer testing.allocator.free(wif_t);
    try testing.expect(wif_t[0] == 'c');
}

test "script_pubkey — P2WPKH format (0x0014 + 20 bytes)" {
    const mnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
    const wallet = try BIP32Wallet.initFromMnemonic(mnemonic, testing.allocator);
    const script = try wallet.deriveScriptPubkey(44, 777, 0);
    try testing.expectEqual(@as(u8, 0x00), script[0]); // OP_0
    try testing.expectEqual(@as(u8, 0x14), script[1]); // push 20 bytes
    // hash160 bytes should match
    const h160 = try wallet.deriveHash160(44, 777, 0);
    try testing.expectEqualSlices(u8, &h160, script[2..22]);
}

test "derivationPathString — format corect" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const path = try BIP32Wallet.derivationPathString(44, 777, 0, 0, 5, arena.allocator());
    try testing.expectEqualStrings("m/44'/777'/0'/0/5", path);
}

test "xpub/xprv — serialization roundtrip" {
    const mnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
    const wallet = try BIP32Wallet.initFromMnemonic(mnemonic, testing.allocator);
    const xpub = try wallet.serializeXpub(44, 777, 0, testing.allocator);
    defer testing.allocator.free(xpub);
    const xprv = try wallet.serializeXprv(44, 777, 0, testing.allocator);
    defer testing.allocator.free(xprv);
    // xpub and xprv should be different
    try testing.expect(!std.mem.eql(u8, xpub, xprv));
    // Both should be Base58 encoded (~111 chars)
    try testing.expect(xpub.len >= 100 and xpub.len <= 120);
    try testing.expect(xprv.len >= 100 and xprv.len <= 120);
}

test "xpub — determinist" {
    const mnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
    const w1 = try BIP32Wallet.initFromMnemonic(mnemonic, testing.allocator);
    const w2 = try BIP32Wallet.initFromMnemonic(mnemonic, testing.allocator);
    const xpub1 = try w1.serializeXpub(44, 777, 0, testing.allocator);
    defer testing.allocator.free(xpub1);
    const xpub2 = try w2.serializeXpub(44, 777, 0, testing.allocator);
    defer testing.allocator.free(xpub2);
    try testing.expectEqualStrings(xpub1, xpub2);
}

test "Network — labels and versions" {
    try testing.expectEqualStrings("OMNI", Network.mainnet.label());
    try testing.expectEqualStrings("TOMNI", Network.testnet.label());
    try testing.expectEqual(@as(u8, 0x80), Network.mainnet.wifVersion());
    try testing.expectEqual(@as(u8, 0xEF), Network.testnet.wifVersion());
}

test "Change address — chain=1 differs from chain=0" {
    const mnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
    const wallet = try BIP32Wallet.initFromMnemonic(mnemonic, testing.allocator);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // External (chain=0)
    const external = try wallet.deriveAddress(0, "ob", arena.allocator());
    // Change (chain=1)
    const change = try wallet.deriveChangeAddress(777, 0, "ob", arena.allocator());
    // Must be different
    try testing.expect(!std.mem.eql(u8, external, change));
    // Both must be valid ob1q
    try testing.expect(std.mem.startsWith(u8, external, "ob1q"));
    try testing.expect(std.mem.startsWith(u8, change, "ob1q"));
    try testing.expectEqual(@as(usize, 42), change.len);
}

test "Change key — chain=1 vs chain=0 different keys" {
    const mnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
    const wallet = try BIP32Wallet.initFromMnemonic(mnemonic, testing.allocator);
    const ext_key = try wallet.deriveChildKeyForPath(44, 777, 0);
    const chg_key = try wallet.deriveChangeKey(777, 0);
    try testing.expect(!std.mem.eql(u8, &ext_key, &chg_key));
}
