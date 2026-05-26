//! isolated_wallet_test.zig — PQ Isolated Wallets v2 test suite.
//!
//! Mirroreaza pattern-ul din `dns_registry_test.zig` — fiecare test e
//! self-contained, foloseste `std.testing.allocator` pentru leak detection,
//! si nu depinde de fisiere/state global.
//!
//! Rulare: `zig test core/isolated_wallet_test.zig`
//! sau via build step: `zig build test-isolated`.
//!
//! Acoperire (16 teste):
//!   1.  generate produce 5 adrese distincte
//!   2.  generate prefixe corespund scheme-urilor
//!   3.  Scheme.fromAddress dispatcher
//!   4.  Scheme.prefix() round-trip
//!   5.  signOmni produce semnatura ECDSA valida (128 hex)
//!   6.  signLove produce semnatura ML-DSA valida
//!   7.  signFood produce semnatura Falcon-512 valida
//!   8.  signRent produce semnatura SLH-DSA valida
//!   9.  signVacation refuza signing (KEM)
//!   10. Cross-domain: LOVE sig nu trece OMNI verify
//!   11. Cross-domain: OMNI sig nu trece LOVE verify
//!   12. Tampered message respinge OMNI verify
//!   13. Tampered message respinge LOVE verify
//!   14. fromMnemonics — round-trip toate 5 domenii
//!   15. fromMnemonics — partial restore (doar OMNI, restul gol)
//!   16. verifySignature dispatcher — toate 4 paths semnabile

const std = @import("std");
const isolated_wallet = @import("isolated_wallet.zig");
const Scheme = isolated_wallet.Scheme;
const IsolatedWallet = isolated_wallet.IsolatedWallet;
const secp256k1_mod = @import("secp256k1.zig");
const bip32_mod = @import("bip32_wallet.zig");

const testing = std.testing;

/// Helper: deriveaza compressed pubkey hex (66 chars) din mnemonic OMNI.
fn deriveOmniPubkeyHex(mnemonic: []const u8, allocator: std.mem.Allocator) ![66]u8 {
    const bip32 = try bip32_mod.BIP32Wallet.initFromMnemonic(mnemonic, allocator);
    const privkey = try bip32.deriveChildKeyForPath(44, 777, 0);
    const pubkey = try secp256k1_mod.Secp256k1Crypto.privateKeyToPublicKey(privkey);
    var pk_hex: [66]u8 = undefined;
    const hex_chars = "0123456789abcdef";
    for (pubkey, 0..) |b, i| {
        pk_hex[i * 2] = hex_chars[b >> 4];
        pk_hex[i * 2 + 1] = hex_chars[b & 0xF];
    }
    return pk_hex;
}

// ─────────────────────────────────────────────────────────────────────────
// Test 1 — generate produce 5 adrese distincte
// ─────────────────────────────────────────────────────────────────────────
test "01 IsolatedWallet.generate yields 5 distinct addresses" {
    const wallet = try IsolatedWallet.generate(testing.allocator);
    defer wallet.deinit();

    try testing.expect(wallet.omni.address.len > 0);
    try testing.expect(wallet.love.address.len > 0);
    try testing.expect(wallet.food.address.len > 0);
    try testing.expect(wallet.rent.address.len > 0);
    try testing.expect(wallet.vacation.address.len > 0);

    try testing.expect(!std.mem.eql(u8, wallet.omni.address, wallet.love.address));
    try testing.expect(!std.mem.eql(u8, wallet.love.address, wallet.food.address));
    try testing.expect(!std.mem.eql(u8, wallet.food.address, wallet.rent.address));
    try testing.expect(!std.mem.eql(u8, wallet.rent.address, wallet.vacation.address));
    try testing.expect(!std.mem.eql(u8, wallet.omni.address, wallet.vacation.address));
}

// ─────────────────────────────────────────────────────────────────────────
// Test 2 — prefixe adrese corespund scheme-urilor
// ─────────────────────────────────────────────────────────────────────────
test "02 IsolatedWallet.generate addresses use correct scheme prefixes" {
    const wallet = try IsolatedWallet.generate(testing.allocator);
    defer wallet.deinit();

    try testing.expect(std.mem.startsWith(u8, wallet.omni.address, "ob1q"));
    try testing.expect(std.mem.startsWith(u8, wallet.love.address, "ob_k1_"));
    try testing.expect(std.mem.startsWith(u8, wallet.food.address, "ob_f5_"));
    try testing.expect(std.mem.startsWith(u8, wallet.rent.address, "ob_d5_"));
    try testing.expect(std.mem.startsWith(u8, wallet.vacation.address, "ob_s3_"));
}

// ─────────────────────────────────────────────────────────────────────────
// Test 3 — Scheme.fromAddress dispatcher
// ─────────────────────────────────────────────────────────────────────────
test "03 Scheme.fromAddress identifies all 5 prefixes" {
    try testing.expectEqual(Scheme.omni_ecdsa, Scheme.fromAddress("ob1qxxxxxxx").?);
    try testing.expectEqual(Scheme.love_dilithium, Scheme.fromAddress("ob_k1_xxxxx").?);
    try testing.expectEqual(Scheme.food_falcon, Scheme.fromAddress("ob_f5_xxxxx").?);
    try testing.expectEqual(Scheme.rent_ml_dsa, Scheme.fromAddress("ob_d5_xxxxx").?);
    try testing.expectEqual(Scheme.vacation_slh_dsa, Scheme.fromAddress("ob_s3_xxxxx").?);
    try testing.expect(Scheme.fromAddress("invalid_addr") == null);
    try testing.expect(Scheme.fromAddress("") == null);
}

// ─────────────────────────────────────────────────────────────────────────
// Test 4 — Scheme.prefix() round-trip cu fromAddress
// ─────────────────────────────────────────────────────────────────────────
test "04 Scheme.prefix round-trips via fromAddress" {
    const schemes = [_]Scheme{ .omni_ecdsa, .love_dilithium, .food_falcon, .rent_ml_dsa, .vacation_slh_dsa };
    for (schemes) |s| {
        const pre = s.prefix();
        // Construieste o adresa minima cu prefix-ul si verifica fromAddress
        var buf: [64]u8 = undefined;
        const addr = try std.fmt.bufPrint(&buf, "{s}aaaaaa", .{pre});
        const detected = Scheme.fromAddress(addr) orelse return error.PrefixNotDetected;
        try testing.expectEqual(s, detected);
    }
}

// ─────────────────────────────────────────────────────────────────────────
// Test 5 — signOmni produce semnatura ECDSA valida (128 hex chars)
// ─────────────────────────────────────────────────────────────────────────
test "05 signOmni produces valid 128-char ECDSA signature" {
    const wallet = try IsolatedWallet.generate(testing.allocator);
    defer wallet.deinit();

    const msg = "omnibus omni-ecdsa test message";
    const sig_hex = try wallet.signOmni(msg, testing.allocator);
    defer testing.allocator.free(sig_hex);

    try testing.expectEqual(@as(usize, 128), sig_hex.len);

    const pk_hex = try deriveOmniPubkeyHex(wallet.omni.mnemonic, testing.allocator);
    try testing.expect(isolated_wallet.verifyOmniSignature(msg, sig_hex, &pk_hex));
}

// ─────────────────────────────────────────────────────────────────────────
// Test 6 — signLove produce semnatura ML-DSA valida
// ─────────────────────────────────────────────────────────────────────────
test "06 signLove produces valid ML-DSA-87 signature" {
    const wallet = try IsolatedWallet.generate(testing.allocator);
    defer wallet.deinit();

    const msg = "omnibus love ml-dsa test message";
    const sig = try wallet.signLove(msg, testing.allocator);
    defer testing.allocator.free(sig);

    try testing.expect(sig.len > 0);
    try testing.expect(wallet.love.pq_public_key != null);
    try testing.expect(isolated_wallet.verifyLoveSignature(msg, sig, wallet.love.pq_public_key.?));
}

// ─────────────────────────────────────────────────────────────────────────
// Test 7 — signFood produce semnatura Falcon-512 valida
// ─────────────────────────────────────────────────────────────────────────
test "07 signFood produces valid Falcon-512 signature" {
    const wallet = try IsolatedWallet.generate(testing.allocator);
    defer wallet.deinit();

    const msg = "omnibus food falcon test message";
    const sig = try wallet.signFood(msg, testing.allocator);
    defer testing.allocator.free(sig);

    try testing.expect(sig.len > 0);
    try testing.expect(wallet.food.pq_public_key != null);
    try testing.expect(isolated_wallet.verifyFoodSignature(msg, sig, wallet.food.pq_public_key.?));
}

// ─────────────────────────────────────────────────────────────────────────
// Test 8 — signRent produce semnatura SLH-DSA valida
// ─────────────────────────────────────────────────────────────────────────
test "08 signRent produces valid SLH-DSA-256s signature" {
    const wallet = try IsolatedWallet.generate(testing.allocator);
    defer wallet.deinit();

    const msg = "omnibus rent slh-dsa test message";
    const sig = try wallet.signRent(msg, testing.allocator);
    defer testing.allocator.free(sig);

    try testing.expect(sig.len > 0);
    try testing.expect(wallet.rent.pq_public_key != null);
    try testing.expect(isolated_wallet.verifyRentSignature(msg, sig, wallet.rent.pq_public_key.?));
}

// ─────────────────────────────────────────────────────────────────────────
// Test 9 — signVacation refuza signing (KEM nu suporta semnaturi)
// ─────────────────────────────────────────────────────────────────────────
test "09 signVacation rejects signing (KEM is encapsulation-only)" {
    const wallet = try IsolatedWallet.generate(testing.allocator);
    defer wallet.deinit();

    const msg = "vacation kem cannot sign";
    const result = wallet.signVacation(msg, testing.allocator);
    try testing.expectError(error.SchemeNotSignable, result);
}

// ─────────────────────────────────────────────────────────────────────────
// Test 10 — Cross-domain: LOVE sig nu trece OMNI verify
// ─────────────────────────────────────────────────────────────────────────
test "10 Cross-domain: LOVE signature fails OMNI verify" {
    const wallet = try IsolatedWallet.generate(testing.allocator);
    defer wallet.deinit();

    const msg = "cross-domain rejection test";
    const love_sig = try wallet.signLove(msg, testing.allocator);
    defer testing.allocator.free(love_sig);

    const pk_hex = try deriveOmniPubkeyHex(wallet.omni.mnemonic, testing.allocator);
    // OMNI verifier asteapta 128 chars hex; LOVE sig e mult mai lung — fail garantat.
    try testing.expect(!isolated_wallet.verifyOmniSignature(msg, love_sig, &pk_hex));
}

// ─────────────────────────────────────────────────────────────────────────
// Test 11 — Cross-domain: OMNI sig nu trece LOVE verify
// ─────────────────────────────────────────────────────────────────────────
test "11 Cross-domain: OMNI signature fails LOVE verify" {
    const wallet = try IsolatedWallet.generate(testing.allocator);
    defer wallet.deinit();

    const msg = "cross-domain rejection test 2";
    const omni_sig_hex = try wallet.signOmni(msg, testing.allocator);
    defer testing.allocator.free(omni_sig_hex);

    // LOVE verify asteapta pubkey bytes raw; trecem OMNI sig hex ca raw bytes — fail.
    try testing.expect(!isolated_wallet.verifyLoveSignature(msg, omni_sig_hex, wallet.love.pq_public_key.?));
}

// ─────────────────────────────────────────────────────────────────────────
// Test 12 — Tampered message respinge OMNI verify
// ─────────────────────────────────────────────────────────────────────────
test "12 Tampered message rejected by OMNI verify" {
    const wallet = try IsolatedWallet.generate(testing.allocator);
    defer wallet.deinit();

    const msg_orig = "original omni message";
    const sig_hex = try wallet.signOmni(msg_orig, testing.allocator);
    defer testing.allocator.free(sig_hex);

    const pk_hex = try deriveOmniPubkeyHex(wallet.omni.mnemonic, testing.allocator);
    // Sanity: original verifies
    try testing.expect(isolated_wallet.verifyOmniSignature(msg_orig, sig_hex, &pk_hex));
    // Tampered fails
    const msg_tampered = "tampered omni message";
    try testing.expect(!isolated_wallet.verifyOmniSignature(msg_tampered, sig_hex, &pk_hex));
}

// ─────────────────────────────────────────────────────────────────────────
// Test 13 — Tampered message respinge LOVE verify
// ─────────────────────────────────────────────────────────────────────────
test "13 Tampered message rejected by LOVE verify" {
    const wallet = try IsolatedWallet.generate(testing.allocator);
    defer wallet.deinit();

    const msg_orig = "original love message";
    const sig = try wallet.signLove(msg_orig, testing.allocator);
    defer testing.allocator.free(sig);

    // Sanity: original verifies
    try testing.expect(isolated_wallet.verifyLoveSignature(msg_orig, sig, wallet.love.pq_public_key.?));
    // Tampered fails
    const msg_tampered = "tampered love message";
    try testing.expect(!isolated_wallet.verifyLoveSignature(msg_tampered, sig, wallet.love.pq_public_key.?));
}

// ─────────────────────────────────────────────────────────────────────────
// Test 14 — fromMnemonics — round-trip toate 5 domenii
// ─────────────────────────────────────────────────────────────────────────
test "14 fromMnemonics full round-trip preserves all 5 addresses" {
    const w1 = try IsolatedWallet.generate(testing.allocator);
    defer w1.deinit();

    const w2 = try IsolatedWallet.fromMnemonics(
        w1.omni.mnemonic,
        w1.love.mnemonic,
        w1.food.mnemonic,
        w1.rent.mnemonic,
        w1.vacation.mnemonic,
        testing.allocator,
    );
    defer w2.deinit();

    try testing.expectEqualStrings(w1.omni.address, w2.omni.address);
    try testing.expectEqualStrings(w1.love.address, w2.love.address);
    try testing.expectEqualStrings(w1.food.address, w2.food.address);
    try testing.expectEqualStrings(w1.rent.address, w2.rent.address);
    try testing.expectEqualStrings(w1.vacation.address, w2.vacation.address);
}

// ─────────────────────────────────────────────────────────────────────────
// Test 15 — fromMnemonics — partial restore (doar OMNI)
// ─────────────────────────────────────────────────────────────────────────
test "15 fromMnemonics partial restore: only OMNI populated" {
    const w1 = try IsolatedWallet.generate(testing.allocator);
    defer w1.deinit();

    const w2 = try IsolatedWallet.fromMnemonics(
        w1.omni.mnemonic,
        null, null, null, null,
        testing.allocator,
    );
    defer w2.deinit();

    // OMNI matches w1
    try testing.expectEqualStrings(w1.omni.address, w2.omni.address);
    // Restul sunt empty (partial restore convention)
    try testing.expectEqualStrings("", w2.love.address);
    try testing.expectEqualStrings("", w2.food.address);
    try testing.expectEqualStrings("", w2.rent.address);
    try testing.expectEqualStrings("", w2.vacation.address);
    // PQ keys nu sunt initializate pentru domenii goale
    try testing.expect(w2.love.pq_public_key == null);
    try testing.expect(w2.food.pq_public_key == null);
    try testing.expect(w2.rent.pq_public_key == null);
    try testing.expect(w2.vacation.pq_public_key == null);
}

// ─────────────────────────────────────────────────────────────────────────
// Test 16 — verifySignature dispatcher — toate 4 paths semnabile + KEM refuz
// ─────────────────────────────────────────────────────────────────────────
test "16 verifySignature dispatcher routes correctly per scheme" {
    const wallet = try IsolatedWallet.generate(testing.allocator);
    defer wallet.deinit();

    const msg = "dispatcher routing test";

    // OMNI path
    const omni_sig = try wallet.signOmni(msg, testing.allocator);
    defer testing.allocator.free(omni_sig);
    const omni_pk = try deriveOmniPubkeyHex(wallet.omni.mnemonic, testing.allocator);
    try testing.expect(isolated_wallet.verifySignature(.omni_ecdsa, msg, omni_sig, &omni_pk));

    // LOVE path
    const love_sig = try wallet.signLove(msg, testing.allocator);
    defer testing.allocator.free(love_sig);
    try testing.expect(isolated_wallet.verifySignature(.love_dilithium, msg, love_sig, wallet.love.pq_public_key.?));

    // FOOD path
    const food_sig = try wallet.signFood(msg, testing.allocator);
    defer testing.allocator.free(food_sig);
    try testing.expect(isolated_wallet.verifySignature(.food_falcon, msg, food_sig, wallet.food.pq_public_key.?));

    // RENT path
    const rent_sig = try wallet.signRent(msg, testing.allocator);
    defer testing.allocator.free(rent_sig);
    try testing.expect(isolated_wallet.verifySignature(.rent_ml_dsa, msg, rent_sig, wallet.rent.pq_public_key.?));

    // VACATION path — KEM nu poate semna; verifySignature returneaza false
    try testing.expect(!isolated_wallet.verifySignature(.vacation_slh_dsa, msg, omni_sig, wallet.vacation.pq_public_key.?));
}
