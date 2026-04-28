// Test minimalist: reproduce path-ul real al sendtransaction (sign +
// addTransaction → validateTransaction → verifyWithHexPubkey) ca să prind
// unde se rupe ECDSA verification. Nu e parte din build-ul principal —
// rulează cu `zig test test_ecdsa_path.zig`.

const std = @import("std");
const wallet_mod = @import("core/wallet.zig");
const transaction_mod = @import("core/transaction.zig");
const Secp256k1Crypto = @import("core/secp256k1.zig").Secp256k1Crypto;

test "ECDSA path: wallet sign tx, validate with registered pubkey" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // 1. Build wallet from a known mnemonic — exact same as production seeds.
    const mnemonic = "flush live wheel sun govern atom describe canyon hotel quality broccoli smart";
    var wallet = try wallet_mod.Wallet.fromMnemonic(mnemonic, "", allocator);

    std.debug.print("\n=== Wallet ===\n", .{});
    std.debug.print("address: {s}\n", .{wallet.address});
    std.debug.print("private_key_bytes (first 8): ", .{});
    for (wallet.private_key_bytes[0..8]) |b| std.debug.print("{x:0>2}", .{b});
    std.debug.print("\n", .{});
    std.debug.print("public_key_bytes (first 16): ", .{});
    for (wallet.public_key_bytes[0..16]) |b| std.debug.print("{x:0>2}", .{b});
    std.debug.print("\n", .{});
    std.debug.print("addresses[0].public_key_hex: {s}\n", .{wallet.addresses[0].public_key_hex});

    // 2. Build a TX exactly like sendtransaction RPC does.
    var tx = transaction_mod.Transaction{
        .id           = 42,
        .from_address = wallet.address,
        .to_address   = "ob1q5stczt5xxxphedadlqej09f5hww22qhvrj2nln",
        .amount       = 10_000_000,
        .fee          = 1,
        .timestamp    = 1700000000,
        .nonce        = 0,
        .signature    = "",
        .hash         = "",
    };

    // 3. Sign the TX (sets tx.signature + tx.hash hex).
    try tx.sign(wallet.private_key_bytes, allocator);

    std.debug.print("\n=== TX signed ===\n", .{});
    std.debug.print("hash: {s}\n", .{tx.hash});
    std.debug.print("signature (first 32): {s}..\n", .{tx.signature[0..@min(32, tx.signature.len)]});

    // 4. Verify with the address registry's public_key_hex (same path
    //    that validateTransaction uses).
    const pubkey_hex = wallet.addresses[0].public_key_hex;
    std.debug.print("\n=== Verify path ===\n", .{});
    std.debug.print("pubkey_hex.len = {d}\n", .{pubkey_hex.len});
    std.debug.print("pubkey_hex = {s}\n", .{pubkey_hex});

    // Manual conversion: hex → 33 bytes
    if (pubkey_hex.len != 66) {
        std.debug.print("FAIL: pubkey_hex is not 66 chars\n", .{});
        return error.WrongPubkeyLength;
    }

    const ok = tx.verifyWithHexPubkey(pubkey_hex);
    std.debug.print("verifyWithHexPubkey: {}\n", .{ok});

    if (!ok) {
        // Compare wallet.public_key_bytes (used implicitly by sign) vs
        // the parsed pubkey_hex (used by verify). If they differ, that's
        // the bug — the registry holds a DIFFERENT pubkey than the one
        // that the privkey actually generates.
        var parsed_pubkey: [33]u8 = undefined;
        const hex = @import("core/hex_utils.zig");
        hex.hexToBytes(pubkey_hex, &parsed_pubkey) catch |err| {
            std.debug.print("hex parse error: {}\n", .{err});
            return err;
        };
        std.debug.print("\nparsed_pubkey  : ", .{});
        for (parsed_pubkey) |b| std.debug.print("{x:0>2}", .{b});
        std.debug.print("\nwallet.public_key_bytes: ", .{});
        for (wallet.public_key_bytes) |b| std.debug.print("{x:0>2}", .{b});
        std.debug.print("\n", .{});

        const eq = std.mem.eql(u8, &parsed_pubkey, &wallet.public_key_bytes);
        std.debug.print("parsed == wallet.public_key_bytes: {}\n", .{eq});

        // Also: re-derive pubkey from private key directly.
        const fresh_pubkey = try Secp256k1Crypto.privateKeyToPublicKey(wallet.private_key_bytes);
        std.debug.print("fresh from privkey     : ", .{});
        for (fresh_pubkey) |b| std.debug.print("{x:0>2}", .{b});
        std.debug.print("\n", .{});
        const fresh_eq = std.mem.eql(u8, &fresh_pubkey, &wallet.public_key_bytes);
        std.debug.print("fresh == wallet.public_key_bytes: {}\n", .{fresh_eq});
    }

    try std.testing.expect(ok);
}
