const std = @import("std");
const testing = std.testing;
const crypto_mod = @import("../core/crypto.zig");
const bip32_mod = @import("../core/bip32_wallet.zig");
const pq_mod = @import("../core/pq_crypto.zig");
const key_mgmt = @import("../core/key_encryption.zig");

test "Phase 2: Cryptographic Primitives" {
    // SHA-256
    const hash = crypto_mod.Crypto.sha256("hello");
    try testing.expect(hash.len == 32);
    std.debug.print("✓ SHA-256 hash generated: {d} bytes\n", .{hash.len});

    // HMAC-SHA256
    const hmac = crypto_mod.Crypto.hmacSha256("key", "message");
    try testing.expect(hmac.len == 32);
    std.debug.print("✓ HMAC-SHA256 generated: {d} bytes\n", .{hmac.len});

    // Password strength
    const strong = crypto_mod.Crypto.isStrongPassword("MyPass123!");
    try testing.expect(strong == true);
    std.debug.print("✓ Password strength validation working\n", .{});
}

test "Phase 2: BIP-32 HD Wallet" {
    const mnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
    var wallet = try bip32_mod.BIP32Wallet.initFromMnemonic(mnemonic, testing.allocator);

    try testing.expect(wallet.master_key.len == 32);
    std.debug.print("✓ BIP-32 wallet initialized\n", .{});

    // Derive first child
    const key0 = try wallet.deriveChildKey(0);
    try testing.expect(key0.len == 32);
    std.debug.print("✓ Child key derivation working\n", .{});
}

test "Phase 2: PQ Address Generation" {
    const mnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
    var wallet = try bip32_mod.BIP32Wallet.initFromMnemonic(mnemonic, testing.allocator);
    var pq_mgr = bip32_mod.PQDomainDerivation.init(wallet);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const addresses = try pq_mgr.deriveAllAddresses(arena.allocator());

    try testing.expectEqual(addresses.len, 5);
    std.debug.print("✓ Generated 5 PQ addresses\n", .{});

    // Verify prefixes
    try testing.expect(std.mem.startsWith(u8, addresses[0], "ob_omni_"));
    try testing.expect(std.mem.startsWith(u8, addresses[1], "ob_k1_"));
    try testing.expect(std.mem.startsWith(u8, addresses[2], "ob_f5_"));
    try testing.expect(std.mem.startsWith(u8, addresses[3], "ob_d5_"));
    try testing.expect(std.mem.startsWith(u8, addresses[4], "ob_s3_"));
    std.debug.print("✓ All 5 domain prefixes validated\n", .{});
}

test "Phase 2: Kyber-768 KEM" {
    var kyber = try pq_mod.PQCrypto.Kyber768.generateKeyPair();

    const ciphertext = try kyber.encapsulate();
    try testing.expect(ciphertext.len == pq_mod.PQCrypto.Kyber768.CIPHERTEXT_SIZE);
    std.debug.print("✓ Kyber-768 encapsulation: {d} bytes\n", .{ciphertext.len});

    const shared_secret = try kyber.decapsulate(ciphertext);
    try testing.expect(shared_secret.len == pq_mod.PQCrypto.Kyber768.SHARED_SECRET_SIZE);
    std.debug.print("✓ Kyber-768 decapsulation: {d} bytes\n", .{shared_secret.len});
}

test "Phase 2: Dilithium-5 Signatures" {
    var dilithium = try pq_mod.PQCrypto.Dilithium5.generateKeyPair();
    const message = "test message";

    const signature = try dilithium.sign(message);
    try testing.expect(signature.len == pq_mod.PQCrypto.Dilithium5.SIGNATURE_SIZE);
    std.debug.print("✓ Dilithium-5 signature: {d} bytes\n", .{signature.len});

    const verified = dilithium.verify(message, signature);
    try testing.expect(verified == true);
    std.debug.print("✓ Dilithium-5 verification successful\n", .{});
}

test "Phase 2: Falcon-512 Signatures" {
    var falcon = try pq_mod.PQCrypto.Falcon512.generateKeyPair();
    const message = "test message";

    const signature = try falcon.sign(message);
    try testing.expect(signature.len == pq_mod.PQCrypto.Falcon512.SIGNATURE_SIZE);
    std.debug.print("✓ Falcon-512 signature: {d} bytes\n", .{signature.len});
}

test "Phase 2: SPHINCS+ Signatures" {
    var sphincs = try pq_mod.PQCrypto.SPHINCSPlus.generateKeyPair();
    const message = "test message";

    const signature = try sphincs.sign(message);
    try testing.expect(signature.len == pq_mod.PQCrypto.SPHINCSPlus.SIGNATURE_SIZE);
    std.debug.print("✓ SPHINCS+ signature: {d} bytes\n", .{signature.len});
}

test "Phase 2: Key Encryption" {
    var km = try key_mgmt.KeyManager.initWithPassword("MySecurePass123!", testing.allocator);

    var private_key: [32]u8 = undefined;
    for (0..32) |i| {
        private_key[i] = @as(u8, @truncate(i * 7));
    }

    const encrypted = try km.encryptPrivateKey(private_key, "MySecurePass123!");
    defer km.allocator.free(encrypted.ciphertext);

    try testing.expect(encrypted.ciphertext.len == 32);
    std.debug.print("✓ Private key encryption: {d} bytes\n", .{encrypted.ciphertext.len});

    const recovery_code = try km.generateRecoveryCode();
    try testing.expect(recovery_code.len == 16);
    std.debug.print("✓ Recovery code generated: {d} bytes\n", .{recovery_code.len});
}

test "Phase 2: Mnemonic Validation" {
    const valid = "abandon ability about above absence absorb abuse access accident account accuse achieve";
    try testing.expect(key_mgmt.Mnemonic.validate(valid));
    std.debug.print("✓ Valid mnemonic passed validation\n", .{});

    const invalid = "not a valid mnemonic";
    try testing.expect(!key_mgmt.Mnemonic.validate(invalid));
    std.debug.print("✓ Invalid mnemonic rejected\n", .{});
}

pub fn main() void {
    std.debug.print("\n=== Phase 2: Wallet + Cryptography Tests ===\n\n", .{});
}
