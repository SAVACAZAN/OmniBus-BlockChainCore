const std = @import("std");
const secp256k1_mod = @import("secp256k1.zig");
const crypto_mod = @import("crypto.zig");
const hex_utils = @import("hex_utils.zig");

const Secp256k1Crypto = secp256k1_mod.Secp256k1Crypto;
const Crypto = crypto_mod.Crypto;

pub const Transaction = struct {
    id: u32,
    from_address: []const u8,
    to_address: []const u8,
    amount: u64,       // in SAT (1 OMNI = 1_000_000_000 SAT)
    timestamp: i64,
    /// Nonce: numar secvential per adresa sender (anti-replay, ca Ethereum/EGLD)
    /// Fiecare tranzactie de la o adresa trebuie sa aiba nonce = nonce_anterior + 1
    nonce: u64 = 0,
    /// OP_RETURN: date arbitrare embedded in TX (max 80 bytes, ca Bitcoin)
    /// Folosit pentru: timestamping, commit hashes, metadata, anchoring
    /// Amount trebuie sa fie 0 daca op_return e setat (datele nu au valoare monetara)
    op_return: []const u8 = "",
    /// Semnatura ECDSA secp256k1 — 64 bytes (R||S) in hex (128 chars)
    signature: []const u8,
    /// Hash SHA256d al tranzactiei (64 hex chars)
    hash: []const u8,
    /// Maximum OP_RETURN data size (80 bytes, same as Bitcoin)
    pub const MAX_OP_RETURN: usize = 80;

    /// Prefix-uri valide pentru adresele OmniBus
    const VALID_PREFIXES = [_][]const u8{
        "ob_omni_",    // OMNI native (coin 777)
        "ob_k1_",      // OMNI_LOVE  (coin 778)
        "ob_f5_",      // OMNI_FOOD  (coin 779)
        "ob_d5_",      // OMNI_RENT  (coin 780)
        "ob_s3_",      // OMNI_VACATION (coin 781)
        "ob1q",        // OMNI SegWit
        "0x",          // ETH-compatible bridge
    };

    /// Calculeaza hash-ul tranzactiei (SHA256d — Bitcoin style)
    /// Hash = SHA256(SHA256(id || from || to || amount || timestamp || nonce))
    /// Nonce inclus in hash previne replay attacks (aceeasi TX cu nonce diferit = hash diferit)
    pub fn calculateHash(self: *const Transaction) [32]u8 {
        // Hash direct in hasher — no buffer overflow risk cu adrese lungi
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        // id
        var id_buf: [16]u8 = undefined;
        const id_str = std.fmt.bufPrint(&id_buf, "{d}", .{self.id}) catch "0";
        hasher.update(id_str);
        hasher.update(":");
        // from_address
        hasher.update(self.from_address);
        hasher.update(":");
        // to_address
        hasher.update(self.to_address);
        hasher.update(":");
        // amount
        var amt_buf: [24]u8 = undefined;
        const amt_str = std.fmt.bufPrint(&amt_buf, "{d}", .{self.amount}) catch "0";
        hasher.update(amt_str);
        hasher.update(":");
        // timestamp
        var ts_buf: [24]u8 = undefined;
        const ts_str = std.fmt.bufPrint(&ts_buf, "{d}", .{self.timestamp}) catch "0";
        hasher.update(ts_str);
        hasher.update(":");
        // nonce
        var nonce_buf: [24]u8 = undefined;
        const nonce_str = std.fmt.bufPrint(&nonce_buf, "{d}", .{self.nonce}) catch "0";
        hasher.update(nonce_str);

        var hash1: [32]u8 = undefined;
        hasher.final(&hash1);
        // SHA256 dublu (SHA256d)
        return Crypto.sha256(&hash1);
    }

    /// Valideaza tranzactia: amount > 0, adrese cu prefix corect
    pub fn isValid(self: *const Transaction) bool {
        if (self.amount == 0) return false;
        if (self.from_address.len == 0 or self.to_address.len == 0) return false;

        // from si to trebuie sa aiba prefix valid
        var from_ok = false;
        var to_ok = false;
        for (VALID_PREFIXES) |prefix| {
            if (std.mem.startsWith(u8, self.from_address, prefix)) from_ok = true;
            if (std.mem.startsWith(u8, self.to_address, prefix)) to_ok = true;
        }

        return from_ok and to_ok;
    }

    /// Semneaza tranzactia cu private key (secp256k1 ECDSA SHA256d — REAL)
    /// Seteaza self.signature = hex(R||S) si self.hash = hex(tx_hash)
    pub fn sign(self: *Transaction, private_key: [32]u8, allocator: std.mem.Allocator) !void {
        // 1. Calculeaza hash-ul tranzactiei
        const tx_hash = self.calculateHash();

        // 2. Semneaza hash-ul cu secp256k1 ECDSA
        const sig_bytes = try Secp256k1Crypto.sign(private_key, &tx_hash);

        // 3. Converteste la hex pentru stocare/transmisie
        self.signature = try Crypto.bytesToHex(&sig_bytes, allocator);
        self.hash      = try Crypto.bytesToHex(&tx_hash, allocator);
    }

    /// Verifica semnatura tranzactiei cu public key (secp256k1 ECDSA — REAL)
    pub fn verify(self: *const Transaction, compressed_pubkey: [33]u8) bool {
        if (self.signature.len != 128) return false; // 64 bytes hex = 128 chars
        if (self.hash.len != 64) return false;

        // Reconverteste din hex
        var sig_bytes: [64]u8 = undefined;
        var hash_bytes: [32]u8 = undefined;

        hex_utils.hexToBytes(self.signature, &sig_bytes) catch return false;
        hex_utils.hexToBytes(self.hash, &hash_bytes) catch return false;

        // Verifica: hash trebuie sa fie hash-ul real al tranzactiei
        const expected_hash = self.calculateHash();
        if (!std.mem.eql(u8, &hash_bytes, &expected_hash)) return false;

        // Verifica semnatura cu secp256k1
        return Secp256k1Crypto.verify(compressed_pubkey, &hash_bytes, sig_bytes);
    }

    /// Verifica semnatura cu public key in format hex (66 chars)
    pub fn verifyWithHexPubkey(self: *const Transaction, pubkey_hex: []const u8) bool {
        if (pubkey_hex.len != 66) return false;
        var pubkey_bytes: [33]u8 = undefined;
        hex_utils.hexToBytes(pubkey_hex, &pubkey_bytes) catch return false;
        return self.verify(pubkey_bytes);
    }
};

// ─── Teste ───────────────────────────────────────────────────────────────────

const testing = std.testing;

test "Transaction.isValid — adrese corecte" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const tx = Transaction{
        .id           = 1,
        .from_address = "ob_omni_abc123",
        .to_address   = "ob_k1_def456",
        .amount       = 1_000_000_000,
        .timestamp    = 1700000000,
        .signature    = "",
        .hash         = "",
    };
    try testing.expect(tx.isValid());
}

test "Transaction.isValid — amount zero → invalid" {
    const tx = Transaction{
        .id           = 2,
        .from_address = "ob_omni_abc123",
        .to_address   = "ob_omni_def456",
        .amount       = 0,
        .timestamp    = 1700000000,
        .signature    = "",
        .hash         = "",
    };
    try testing.expect(!tx.isValid());
}

test "Transaction.isValid — prefix invalid → false" {
    const tx = Transaction{
        .id           = 3,
        .from_address = "INVALID_addr",
        .to_address   = "ob_omni_abc123",
        .amount       = 1000,
        .timestamp    = 1700000000,
        .signature    = "",
        .hash         = "",
    };
    try testing.expect(!tx.isValid());
}

test "Transaction.calculateHash — determinist" {
    const tx = Transaction{
        .id           = 1,
        .from_address = "ob_omni_abc",
        .to_address   = "ob_omni_xyz",
        .amount       = 5_000_000_000,
        .timestamp    = 1700000000,
        .signature    = "",
        .hash         = "",
    };
    const h1 = tx.calculateHash();
    const h2 = tx.calculateHash();
    try testing.expectEqualSlices(u8, &h1, &h2);
}

test "Transaction sign si verify — ECDSA secp256k1 REAL" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // Genereaza pereche de chei
    const kp = try Secp256k1Crypto.generateKeyPair();

    var tx = Transaction{
        .id           = 42,
        .from_address = "ob_omni_test_sender",
        .to_address   = "ob_omni_test_receiver",
        .amount       = 10_000_000_000, // 10 OMNI
        .timestamp    = 1700000042,
        .signature    = "",
        .hash         = "",
    };

    // Semneaza
    try tx.sign(kp.private_key, arena.allocator());

    // Semnatura si hash-ul sunt acum setate (hex)
    try testing.expectEqual(@as(usize, 128), tx.signature.len);
    try testing.expectEqual(@as(usize, 64), tx.hash.len);

    // Verifica cu public key corect → true
    try testing.expect(tx.verify(kp.public_key));
}

test "Transaction verify — public key gresit → false" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const kp1 = try Secp256k1Crypto.generateKeyPair();
    const kp2 = try Secp256k1Crypto.generateKeyPair();

    var tx = Transaction{
        .id           = 99,
        .from_address = "ob_omni_sender",
        .to_address   = "ob_omni_receiver",
        .amount       = 1_000_000_000,
        .timestamp    = 1700000099,
        .signature    = "",
        .hash         = "",
    };

    try tx.sign(kp1.private_key, arena.allocator());

    // Verifica cu alt public key → false
    try testing.expect(!tx.verify(kp2.public_key));
}
