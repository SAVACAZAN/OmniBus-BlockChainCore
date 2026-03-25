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

    /// Genereaza compressed public key din private key
    pub fn privateKeyToPublicKey(private_key: PrivateKey) !CompressedPubkey {
        const sk = try Ecdsa.SecretKey.fromBytes(private_key);
        const kp = try Ecdsa.KeyPair.fromSecretKey(sk);
        return kp.public_key.toCompressedSec1();
    }

    /// Genereaza adresa Bitcoin-style din private key
    /// privkey → pubkey → SHA256 → SHA256[0..20]
    /// (SHA256[0..20] ca aproximare pentru RIPEMD-160 — TODO fix 3)
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
        return sig.toBytes();
    }

    /// Verifica semnatura unui mesaj cu public key
    pub fn verify(compressed_pubkey: CompressedPubkey, message: []const u8, signature: Signature) bool {
        const pk = Ecdsa.PublicKey.fromSec1(&compressed_pubkey) catch return false;
        const sig = Ecdsa.Signature.fromBytes(signature);
        sig.verify(message, pk) catch return false;
        return true;
    }

    /// Verifica daca o cheie privata e valida (in range [1, n-1])
    pub fn isValidPrivateKey(private_key: PrivateKey) bool {
        var all_zero = true;
        for (private_key) |b| {
            if (b != 0) { all_zero = false; break; }
        }
        if (all_zero) return false;

        const n = [_]u8{
            0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
            0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFE,
            0xBA, 0xAE, 0xDC, 0xE6, 0xAF, 0x48, 0xA0, 0x3B,
            0xBF, 0xD2, 0x5E, 0x8C, 0xD0, 0x36, 0x41, 0x41,
        };
        for (private_key, n) |pk_byte, n_byte| {
            if (pk_byte < n_byte) return true;
            if (pk_byte > n_byte) return false;
        }
        return false;
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

test "secp256k1 — hash160 din private key (20 bytes)" {
    const privkey = [_]u8{0x42} ** 32;
    const hash = try Secp256k1Crypto.privateKeyToHash160(privkey);
    try testing.expectEqual(@as(usize, 20), hash.len);
}
