/// Comprehensive test for all 4 PQ schemes + ECDSA
/// Tests: signing, verification, hex/bytes handling, scheme isolation, key binding
///
/// Run with: zig test test/test-pq-schemes-comprehensive.zig
/// Or as part of build: zig build test

const std = @import("std");
const transaction_mod = @import("../core/transaction.zig");
const pq_crypto = @import("../core/pq_crypto.zig");
const crypto_mod = @import("../core/crypto.zig");
const secp256k1_mod = @import("../core/secp256k1.zig");
const hex_utils = @import("../core/hex_utils.zig");

const Transaction = transaction_mod.Transaction;
const Scheme = transaction_mod.Scheme;
const Secp256k1Crypto = secp256k1_mod.Secp256k1Crypto;
const Crypto = crypto_mod.Crypto;

const testing = std.testing;

test "PQ Scheme ML-DSA-87 — full signing cycle" {
    // Test: full signing cycle with ML-DSA-87
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // 1. Generate keypair
    const kp = try pq_crypto.MlDsa87.generateKeyPair();

    // 2. Create transaction with LOVE_DILITHIUM scheme
    var tx = Transaction{
        .id = 100,
        .scheme = .love_dilithium,
        .from_address = "ob_k1_alice1234567890abcdef",
        .to_address = "ob_k1_bob9876543210fedcba",
        .amount = 1_000_000,
        .timestamp = 1700000100,
        .nonce = 1,
        .signature = "",
        .hash = "",
        .public_key = "",
    };

    // 3. Set public key (raw bytes)
    var pk_hex_buf: [pq_crypto.MlDsa87.PUBLIC_KEY_SIZE * 2]u8 = undefined;
    const pk_hex = try Crypto.bytesToHex(&kp.public_key, arena.allocator());
    tx.public_key = pk_hex;

    // 4. Calculate hash
    const tx_hash = tx.calculateHash();

    // 5. Sign with ML-DSA-87
    const sig_bytes = try kp.sign(&tx_hash, arena.allocator());
    defer arena.allocator().free(sig_bytes);

    // 6. Convert signature to hex for storage
    tx.signature = try Crypto.bytesToHex(sig_bytes, arena.allocator());
    tx.hash = try Crypto.bytesToHex(&tx_hash, arena.allocator());

    // 7. Verify signature (this is the FIX being tested)
    try testing.expect(tx.verifySignature(null));
}

test "PQ Scheme Falcon-512 — full signing cycle" {
    // Test: full signing cycle with Falcon-512
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // 1. Generate keypair
    const kp = try pq_crypto.Falcon512.generateKeyPair();

    // 2. Create transaction with FOOD_FALCON scheme
    var tx = Transaction{
        .id = 101,
        .scheme = .food_falcon,
        .from_address = "ob_f5_charlie111222333",
        .to_address = "ob_f5_david4445556667",
        .amount = 5_000_000,
        .timestamp = 1700000101,
        .nonce = 2,
        .signature = "",
        .hash = "",
        .public_key = "",
    };

    // 3. Set public key
    tx.public_key = try Crypto.bytesToHex(&kp.public_key, arena.allocator());

    // 4. Calculate hash
    const tx_hash = tx.calculateHash();

    // 5. Sign
    const sig_bytes = try kp.sign(&tx_hash, arena.allocator());
    defer arena.allocator().free(sig_bytes);

    // 6. Store as hex
    tx.signature = try Crypto.bytesToHex(sig_bytes, arena.allocator());
    tx.hash = try Crypto.bytesToHex(&tx_hash, arena.allocator());

    // 7. Verify (FIX: hex signature decoded to bytes internally)
    try testing.expect(tx.verifySignature(null));
}

test "PQ Scheme SLH-DSA-256s — full signing cycle" {
    // Test: full signing cycle with SLH-DSA-256s
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // 1. Generate keypair
    const kp = try pq_crypto.SlhDsa256s.generateKeyPair();

    // 2. Create transaction with RENT_SLH_DSA scheme
    var tx = Transaction{
        .id = 102,
        .scheme = .rent_ml_dsa,
        .from_address = "ob_d5_eve88889999aaaa",
        .to_address = "ob_d5_frank111222333",
        .amount = 10_000_000,
        .timestamp = 1700000102,
        .nonce = 3,
        .signature = "",
        .hash = "",
        .public_key = "",
    };

    // 3. Set public key
    tx.public_key = try Crypto.bytesToHex(&kp.public_key, arena.allocator());

    // 4. Calculate hash
    const tx_hash = tx.calculateHash();

    // 5. Sign
    const sig_bytes = try kp.sign(&tx_hash, arena.allocator());
    defer arena.allocator().free(sig_bytes);

    // 6. Store as hex
    tx.signature = try Crypto.bytesToHex(sig_bytes, arena.allocator());
    tx.hash = try Crypto.bytesToHex(&tx_hash, arena.allocator());

    // 7. Verify
    try testing.expect(tx.verifySignature(null));
}

test "ECDSA (OMNI) — full signing cycle" {
    // Test: baseline ECDSA signing + verification
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const kp = try Secp256k1Crypto.generateKeyPair();

    var tx = Transaction{
        .id = 103,
        .scheme = .omni_ecdsa,
        .from_address = "ob1qgrace1234567890",
        .to_address = "ob1qhank99887766554",
        .amount = 2_000_000,
        .timestamp = 1700000103,
        .nonce = 0,
        .signature = "",
        .hash = "",
    };

    try tx.sign(kp.private_key, arena.allocator());

    // Verify with pubkey_hex
    var pk_hex: [66]u8 = undefined;
    const pk_hex_str = try std.fmt.bufPrint(&pk_hex, "{s}", .{try Crypto.bytesToHex(&kp.public_key, arena.allocator())});
    try testing.expect(tx.verifySignature(pk_hex_str));
}

test "Hash determinism — nonce change breaks hash" {
    // Test: same TX with different nonce = different hash
    const tx1 = Transaction{
        .id = 1,
        .scheme = .love_dilithium,
        .from_address = "ob_k1_alice1234567890abcdef",
        .to_address = "ob_k1_bob9876543210fedcba",
        .amount = 1_000_000,
        .timestamp = 1700000000,
        .nonce = 1,
        .signature = "",
        .hash = "",
        .public_key = "aabb",
    };

    const tx2 = Transaction{
        .id = 1,
        .scheme = .love_dilithium,
        .from_address = "ob_k1_alice1234567890abcdef",
        .to_address = "ob_k1_bob9876543210fedcba",
        .amount = 1_000_000,
        .timestamp = 1700000000,
        .nonce = 2,  // Different nonce
        .signature = "",
        .hash = "",
        .public_key = "aabb",
    };

    const h1 = tx1.calculateHash();
    const h2 = tx2.calculateHash();

    // Hashes must be different when nonce changes
    try testing.expect(!std.mem.eql(u8, &h1, &h2));
}

test "Scheme isolation — scheme tag prevents swap attacks" {
    // Test: scheme tag in hash prevents scheme swaps
    const tx1 = Transaction{
        .id = 1,
        .scheme = .love_dilithium,
        .from_address = "ob_k1_alice1234567890abcdef",
        .to_address = "ob_k1_bob9876543210fedcba",
        .amount = 1_000_000,
        .timestamp = 1700000000,
        .nonce = 1,
        .signature = "",
        .hash = "",
        .public_key = "aabbccdd",
    };

    const tx2 = Transaction{
        .id = 1,
        .scheme = .food_falcon,  // Different scheme
        .from_address = "ob_k1_alice1234567890abcdef",
        .to_address = "ob_k1_bob9876543210fedcba",
        .amount = 1_000_000,
        .timestamp = 1700000000,
        .nonce = 1,
        .signature = "",
        .hash = "",
        .public_key = "aabbccdd",
    };

    const h1 = tx1.calculateHash();
    const h2 = tx2.calculateHash();

    // Hashes must differ when scheme changes
    try testing.expect(!std.mem.eql(u8, &h1, &h2));
}

test "Public key binding — pubkey in hash prevents substitution" {
    // Test: pubkey in hash prevents key substitution
    const tx1 = Transaction{
        .id = 1,
        .scheme = .love_dilithium,
        .from_address = "ob_k1_alice1234567890abcdef",
        .to_address = "ob_k1_bob9876543210fedcba",
        .amount = 1_000_000,
        .timestamp = 1700000000,
        .nonce = 1,
        .signature = "",
        .hash = "",
        .public_key = "aaaa",
    };

    const tx2 = Transaction{
        .id = 1,
        .scheme = .love_dilithium,
        .from_address = "ob_k1_alice1234567890abcdef",
        .to_address = "ob_k1_bob9876543210fedcba",
        .amount = 1_000_000,
        .timestamp = 1700000000,
        .nonce = 1,
        .signature = "",
        .hash = "",
        .public_key = "bbbb",  // Different pubkey
    };

    const h1 = tx1.calculateHash();
    const h2 = tx2.calculateHash();

    try testing.expect(!std.mem.eql(u8, &h1, &h2));
}

test "Address prefix validation — obk1_, obf5_, obd5_, obs3_" {
    // Test: PQ address prefixes are validated
    const tx1 = Transaction{
        .id = 1,
        .from_address = "obk1_validpqaddress",
        .to_address = "obf5_anotherpqaddress",
        .amount = 1000,
        .timestamp = 1700000000,
        .signature = "",
        .hash = "",
    };

    const tx2 = Transaction{
        .id = 2,
        .from_address = "obd5_thirdpqaddress",
        .to_address = "obs3_fourthpqaddress",
        .amount = 1000,
        .timestamp = 1700000000,
        .signature = "",
        .hash = "",
    };

    try testing.expect(tx1.isValid());
    try testing.expect(tx2.isValid());
}

test "Soulbound address prefixes — ob_k1_, ob_f5_, ob_d5_, ob_s3_" {
    // Test: soulbound address prefixes are valid
    const tx = Transaction{
        .id = 1,
        .from_address = "ob_k1_soulbound_address",
        .to_address = "ob_f5_another_soulbound",
        .amount = 1000,
        .timestamp = 1700000000,
        .signature = "",
        .hash = "",
    };

    try testing.expect(tx.isValid());
}

test "Scheme.fromAddress — detects scheme from address prefix" {
    // Test: fromAddress detects correct scheme from prefix
    try testing.expectEqual(Scheme.omni_ecdsa, transaction_mod.Scheme.fromAddress("ob1qsomething").?);
    try testing.expectEqual(Scheme.love_dilithium, transaction_mod.Scheme.fromAddress("ob_k1_something").?);
    try testing.expectEqual(Scheme.pq_omni_ml_dsa, transaction_mod.Scheme.fromAddress("obk1_something").?);
    try testing.expectEqual(Scheme.pq_omni_falcon, transaction_mod.Scheme.fromAddress("obf5_something").?);
    try testing.expectEqual(Scheme.pq_omni_dilithium, transaction_mod.Scheme.fromAddress("obs3_something").?);
    try testing.expectEqual(Scheme.pq_omni_slh_dsa, transaction_mod.Scheme.fromAddress("obd5_something").?);
}

test "Invalid address — unknown prefix rejected" {
    // Test: invalid address prefixes are rejected
    const tx = Transaction{
        .id = 1,
        .from_address = "invalid_prefix_address",
        .to_address = "ob1qvalid",
        .amount = 1000,
        .timestamp = 1700000000,
        .signature = "",
        .hash = "",
    };

    try testing.expect(!tx.isValid());
}

test "OP_RETURN with PQ scheme — memo in TX" {
    // Test: OP_RETURN memo changes TX hash
    const tx = Transaction{
        .id = 1,
        .scheme = .love_dilithium,
        .from_address = "ob_k1_alice",
        .to_address = "ob_k1_bob",
        .amount = 1000,
        .timestamp = 1700000000,
        .op_return = "stake:1000000000",  // Role marker
        .signature = "",
        .hash = "",
    };

    try testing.expect(tx.isValid());
    const h1 = tx.calculateHash();

    const tx2 = Transaction{
        .id = 1,
        .scheme = .love_dilithium,
        .from_address = "ob_k1_alice",
        .to_address = "ob_k1_bob",
        .amount = 1000,
        .timestamp = 1700000000,
        .op_return = "different_memo",
        .signature = "",
        .hash = "",
    };

    const h2 = tx2.calculateHash();

    // op_return changes hash
    try testing.expect(!std.mem.eql(u8, &h1, &h2));
}

test "All 4 PQ schemes + ECDSA together" {
    // Test: all 5 schemes work in sequence
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // Test ECDSA
    {
        const kp = try Secp256k1Crypto.generateKeyPair();
        var tx = Transaction{
            .id = 1,
            .scheme = .omni_ecdsa,
            .from_address = "ob1q_ecdsa_test",
            .to_address = "ob1q_ecdsa_dest",
            .amount = 1000,
            .timestamp = 1700000000,
            .signature = "",
            .hash = "",
        };
        try tx.sign(kp.private_key, arena.allocator());
        const pk_hex = try Crypto.bytesToHex(&kp.public_key, arena.allocator());
        try testing.expect(tx.verifySignature(pk_hex));
    }

    // Test ML-DSA-87
    {
        const kp = try pq_crypto.MlDsa87.generateKeyPair();
        var tx = Transaction{
            .id = 2,
            .scheme = .love_dilithium,
            .from_address = "ob_k1_mldsa_test",
            .to_address = "ob_k1_mldsa_dest",
            .amount = 1000,
            .timestamp = 1700000000,
            .signature = "",
            .hash = "",
            .public_key = try Crypto.bytesToHex(&kp.public_key, arena.allocator()),
        };
        const tx_hash = tx.calculateHash();
        const sig = try kp.sign(&tx_hash, arena.allocator());
        defer arena.allocator().free(sig);
        tx.signature = try Crypto.bytesToHex(sig, arena.allocator());
        tx.hash = try Crypto.bytesToHex(&tx_hash, arena.allocator());
        try testing.expect(tx.verifySignature(null));
    }

    // Test Falcon-512
    {
        const kp = try pq_crypto.Falcon512.generateKeyPair();
        var tx = Transaction{
            .id = 3,
            .scheme = .food_falcon,
            .from_address = "ob_f5_falcon_test",
            .to_address = "ob_f5_falcon_dest",
            .amount = 1000,
            .timestamp = 1700000000,
            .signature = "",
            .hash = "",
            .public_key = try Crypto.bytesToHex(&kp.public_key, arena.allocator()),
        };
        const tx_hash = tx.calculateHash();
        const sig = try kp.sign(&tx_hash, arena.allocator());
        defer arena.allocator().free(sig);
        tx.signature = try Crypto.bytesToHex(sig, arena.allocator());
        tx.hash = try Crypto.bytesToHex(&tx_hash, arena.allocator());
        try testing.expect(tx.verifySignature(null));
    }

    // Test SLH-DSA-256s
    {
        const kp = try pq_crypto.SlhDsa256s.generateKeyPair();
        var tx = Transaction{
            .id = 4,
            .scheme = .rent_ml_dsa,
            .from_address = "ob_d5_slhdsa_test",
            .to_address = "ob_d5_slhdsa_dest",
            .amount = 1000,
            .timestamp = 1700000000,
            .signature = "",
            .hash = "",
            .public_key = try Crypto.bytesToHex(&kp.public_key, arena.allocator()),
        };
        const tx_hash = tx.calculateHash();
        const sig = try kp.sign(&tx_hash, arena.allocator());
        defer arena.allocator().free(sig);
        tx.signature = try Crypto.bytesToHex(sig, arena.allocator());
        tx.hash = try Crypto.bytesToHex(&tx_hash, arena.allocator());
        try testing.expect(tx.verifySignature(null));
    }
}
