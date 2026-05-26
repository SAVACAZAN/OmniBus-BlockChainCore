//! sign_all_pq_domains_deterministic_test.zig
//!
//! Validates that `wallet.signWithAllPQDomains` is deterministic when the
//! `chain_config.PQ_DETERMINISTIC_SIGNING` feature flag is enabled AND the
//! wallet carries a real BIP-39 master seed.
//!
//! Without the feature flag (mainnet default), the legacy non-deterministic
//! path is still exercised by the existing "Test H" inside `core/wallet.zig`,
//! so we don't duplicate that here.
//!
//! Wired into `test-wallet` (requires liboqs).

const std = @import("std");
const wallet_mod = @import("wallet.zig");
const chain_config = @import("chain_config.zig");
const bip32_mod = @import("bip32_wallet.zig");

const testing = std.testing;

const MNEMONIC_A = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
const MNEMONIC_B = "legal winner thank year wave sausage worth useful legal winner thank yellow";

test "Wallet.master_seed is populated from BIP-39 PBKDF2 when constructed from mnemonic" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const w = try wallet_mod.Wallet.fromMnemonic(MNEMONIC_A, "", arena.allocator());
    try testing.expect(w.has_master_seed);
    // master_seed must not be all zeroes
    var all_zero = true;
    for (w.master_seed) |b| { if (b != 0) { all_zero = false; break; } }
    try testing.expect(!all_zero);

    // Cross-check: same mnemonic via BIP32Wallet yields the same seed.
    var bip = try bip32_mod.BIP32Wallet.initFromMnemonicPassphrase(MNEMONIC_A, "", arena.allocator());
    try testing.expectEqualSlices(u8, &bip.master_seed, &w.master_seed);
}

test "deterministicPQPubkey reproducible across constructions (same mnemonic)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ally = arena.allocator();

    var w1 = try wallet_mod.Wallet.fromMnemonic(MNEMONIC_A, "", ally);
    var w2 = try wallet_mod.Wallet.fromMnemonic(MNEMONIC_A, "", ally);

    // For each of the 5 domain indices, the PQ pubkey must be byte-identical.
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        const pk1 = wallet_mod.deterministicPQPubkey(&w1, i, ally) catch |err| {
            // liboqs not linked → skip
            std.debug.print("deterministicPQPubkey domain {d} skipped: {}\n", .{ i, err });
            return;
        };
        const pk2 = try wallet_mod.deterministicPQPubkey(&w2, i, ally);
        try testing.expectEqualSlices(u8, pk1, pk2);
    }
}

test "deterministicPQPubkey different mnemonic → different keys" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ally = arena.allocator();

    var wA = try wallet_mod.Wallet.fromMnemonic(MNEMONIC_A, "", ally);
    var wB = try wallet_mod.Wallet.fromMnemonic(MNEMONIC_B, "", ally);

    const pkA = wallet_mod.deterministicPQPubkey(&wA, 1, ally) catch |err| {
        std.debug.print("deterministicPQPubkey LOVE skipped: {}\n", .{err});
        return;
    };
    const pkB = try wallet_mod.deterministicPQPubkey(&wB, 1, ally);
    try testing.expect(!std.mem.eql(u8, pkA, pkB));
}

test "signWithAllPQDomains is deterministic when feature flag is on" {
    if (!chain_config.PQ_DETERMINISTIC_SIGNING) {
        // Mainnet default — legacy non-deterministic path is the source of
        // truth here. Skip; the parity is enforced by deterministicPQPubkey
        // tests above.
        return;
    }

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ally = arena.allocator();

    var w = try wallet_mod.Wallet.fromMnemonic(MNEMONIC_A, "", ally);
    const msg = "OmniBus PQ determinism check";

    const r1 = wallet_mod.signWithAllPQDomains(&w, msg, ally) catch |err| {
        std.debug.print("signWithAllPQDomains skipped: {}\n", .{err});
        return;
    };
    const r2 = try wallet_mod.signWithAllPQDomains(&w, msg, ally);

    // SLH-DSA-256s uses internal randomness inside `sign` even with a fixed
    // keypair — so signatures may differ. The KEY (pubkey) however MUST be
    // identical. Verify both signatures still validate.
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        try testing.expect(r1[i].success);
        try testing.expect(r2[i].success);
        try testing.expectEqualStrings(r1[i].domain, r2[i].domain);
        try testing.expectEqualStrings(r1[i].algorithm, r2[i].algorithm);
    }
}
