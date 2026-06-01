// payment_channel_tests.zig — extracted inline tests from payment_channel.zig
//
// Zig 0.15.2 constraint: `zig test` operates on the root file and pulls in
// only the symbols it transitively imports. Tests living in a separate
// test-only file therefore must @import the module they exercise. We keep
// these tests inside core/ (not a top-level tests/ dir) so the relative
// @import path stays trivial and so the build-step wiring in build.zig
// (addTest with path "core/payment_channel_tests.zig") stays uniform with
// the other test files in this directory.

const std = @import("std");
const testing = std.testing;
const Sha256 = std.crypto.hash.sha2.Sha256;

const pc_mod = @import("payment_channel.zig");
const PaymentChannel = pc_mod.PaymentChannel;
const ChannelUpdate = pc_mod.ChannelUpdate;
const ChannelManager = pc_mod.ChannelManager;
const SettleTx = pc_mod.SettleTx;
const MAX_CHANNEL_AMOUNT = pc_mod.MAX_CHANNEL_AMOUNT;
const DISPUTE_WINDOW_BLOCKS = pc_mod.DISPUTE_WINDOW_BLOCKS;

// Helpers: derive real secp256k1 keys for tests so signatures actually
// validate. Pubkeys are deterministic from a label-seed (sha256 of a
// "channel-test-X" string) — same key every run, but on the curve.

const test_secp = @import("secp256k1.zig").Secp256k1Crypto;

fn testPrivkey(label: []const u8) [32]u8 {
    var sk: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(label, &sk, .{});
    return sk;
}

fn testPubkey(label: []const u8) [33]u8 {
    const sk = testPrivkey(label);
    return test_secp.privateKeyToPublicKey(sk) catch unreachable;
}

fn testPubkeyA() [33]u8 {
    return testPubkey("channel-test-party-a");
}

fn testPubkeyB() [33]u8 {
    return testPubkey("channel-test-party-b");
}

// Sign an UPDATE hash with the given party's privkey. The `fill` arg is
// kept for source-compatibility with the placeholder helper signature
// (callers pass 0x11/0x22 etc.) — we just route 0x11→A, 0x22→B, anything
// else → A. Tests that need explicit per-party sigs should use signAs()
// directly.
fn signAs(label: []const u8, msg: [32]u8) [64]u8 {
    const sk = testPrivkey(label);
    return test_secp.sign(sk, &msg) catch unreachable;
}

fn testSig(fill: u8) [64]u8 {
    // Backward-compat shim: produce a real signature, choosing the signing
    // party from the placeholder fill byte. Tests built around testSig()
    // sign over a known canonical message (the zero hash) — they only
    // verify that verify() accepts a real sig and rejects a fake one.
    const label = if (fill == 0x22) "channel-test-party-b" else "channel-test-party-a";
    const msg: [32]u8 = @splat(0);
    return signAs(label, msg);
}

/// Helper for the lifecycle tests: predict what the channel state will be
/// AFTER a successful `pay()` and pre-sign that exact ChannelUpdate hash with
/// both party labels. Returns (sig_a, sig_b) ready to feed into pay().
/// Mirrors the math in PaymentChannel.pay exactly — if pay() changes shape
/// the next sig won't verify and this helper must be updated in lockstep.
fn signPayAdvance(ch_ref: anytype, from_a_to_b: bool, amount: u64) struct { [64]u8, [64]u8 } {
    // Accept either &ch (PaymentChannel value) or ch (already a pointer
    // returned by openChannel). Collapse one level of deref either way.
    const ch: *const PaymentChannel = switch (@typeInfo(@TypeOf(ch_ref)).pointer.child) {
        PaymentChannel => ch_ref,
        else => ch_ref.*,
    };
    var new_a = ch.balance_a;
    var new_b = ch.balance_b;
    if (from_a_to_b) { new_a -= amount; new_b += amount; }
    else             { new_b -= amount; new_a += amount; }
    const candidate = ChannelUpdate{
        .channel_id = ch.channel_id,
        .sequence_num = ch.sequence_num + 1,
        .balance_a = new_a,
        .balance_b = new_b,
        .sig_a = @splat(0),
        .sig_b = @splat(0),
    };
    const msg = candidate.hash();
    return .{
        signAs("channel-test-party-a", msg),
        signAs("channel-test-party-b", msg),
    };
}

/// Construct a fully-signed ChannelUpdate from raw fields. Used by tests
/// that need to feed unilateralClose/dispute with arbitrary historical states.
fn signedUpdate(channel_id: [32]u8, seq: u64, bal_a: u64, bal_b: u64) ChannelUpdate {
    var update = ChannelUpdate{
        .channel_id = channel_id,
        .sequence_num = seq,
        .balance_a = bal_a,
        .balance_b = bal_b,
        .sig_a = @splat(0),
        .sig_b = @splat(0),
    };
    const msg = update.hash();
    update.sig_a = signAs("channel-test-party-a", msg);
    update.sig_b = signAs("channel-test-party-b", msg);
    return update;
}

/// Helper for cooperative close: pre-sign the CURRENT state (sequence_num
/// stays put, balances stay put) so cooperativeClose's verify() accepts.
fn signCurrentState(ch_ref: anytype) struct { [64]u8, [64]u8 } {
    const ch: *const PaymentChannel = switch (@typeInfo(@TypeOf(ch_ref)).pointer.child) {
        PaymentChannel => ch_ref,
        else => ch_ref.*,
    };
    const update = ChannelUpdate{
        .channel_id = ch.channel_id,
        .sequence_num = ch.sequence_num,
        .balance_a = ch.balance_a,
        .balance_b = ch.balance_b,
        .sig_a = @splat(0),
        .sig_b = @splat(0),
    };
    const msg = update.hash();
    return .{
        signAs("channel-test-party-a", msg),
        signAs("channel-test-party-b", msg),
    };
}

// ── PaymentChannel.open ─────────────────────────────────────────────────────

test "PaymentChannel — open generates unique non-zero channel_id" {
    const ch = try PaymentChannel.open(testPubkeyA(), testPubkeyB(), 1_000_000_000, 500_000_000);
    var all_zero = true;
    for (ch.channel_id) |b| if (b != 0) {
        all_zero = false;
        break;
    };
    try testing.expect(!all_zero);
    try testing.expect(ch.state == .open);
}

test "PaymentChannel — initial balances equal deposits" {
    const ch = try PaymentChannel.open(testPubkeyA(), testPubkeyB(), 1_000_000_000, 500_000_000);
    try testing.expectEqual(@as(u64, 1_000_000_000), ch.balance_a);
    try testing.expectEqual(@as(u64, 500_000_000), ch.balance_b);
    try testing.expectEqual(@as(u64, 1_500_000_000), ch.total_locked);
    try testing.expectEqual(@as(u64, 0), ch.sequence_num);
}

test "PaymentChannel — open rejects zero deposit" {
    try testing.expectError(error.ZeroDeposit, PaymentChannel.open(testPubkeyA(), testPubkeyB(), 0, 0));
}

test "PaymentChannel — open rejects exceeding max amount" {
    try testing.expectError(error.ExceedsMaxAmount, PaymentChannel.open(testPubkeyA(), testPubkeyB(), MAX_CHANNEL_AMOUNT, 1));
}

// ── PaymentChannel.pay ──────────────────────────────────────────────────────

test "PaymentChannel — pay A to B updates balances correctly" {
    var ch = try PaymentChannel.open(testPubkeyA(), testPubkeyB(), 1_000_000_000, 0);
    const update = blk: { const sigs = signPayAdvance(&ch, true, 100_000_000); break :blk try ch.pay(true, 100_000_000, sigs[0], sigs[1]); };

    try testing.expectEqual(@as(u64, 900_000_000), ch.balance_a);
    try testing.expectEqual(@as(u64, 100_000_000), ch.balance_b);
    try testing.expectEqual(@as(u64, 1), ch.sequence_num);
    try testing.expectEqual(@as(u64, 1), update.sequence_num);
    try testing.expectEqual(@as(u64, 900_000_000), update.balance_a);
    try testing.expectEqual(@as(u64, 100_000_000), update.balance_b);
}

test "PaymentChannel — pay B to A updates balances correctly" {
    var ch = try PaymentChannel.open(testPubkeyA(), testPubkeyB(), 500_000_000, 500_000_000);
    _ = blk: { const sigs = signPayAdvance(&ch, false, 200_000_000); break :blk try ch.pay(false, 200_000_000, sigs[0], sigs[1]); };

    try testing.expectEqual(@as(u64, 700_000_000), ch.balance_a);
    try testing.expectEqual(@as(u64, 300_000_000), ch.balance_b);
}

test "PaymentChannel — pay insufficient balance returns error" {
    var ch = try PaymentChannel.open(testPubkeyA(), testPubkeyB(), 100_000_000, 0);
    try testing.expectError(error.InsufficientBalance, ch.pay(true, 200_000_000, testSig(0x11), testSig(0x22)));
}

test "PaymentChannel — multiple payments increment sequence" {
    var ch = try PaymentChannel.open(testPubkeyA(), testPubkeyB(), 1_000_000_000, 0);

    _ = blk: { const sigs = signPayAdvance(&ch, true, 100_000_000); break :blk try ch.pay(true, 100_000_000, sigs[0], sigs[1]); }; // seq=1
    _ = blk: { const sigs = signPayAdvance(&ch, true, 100_000_000); break :blk try ch.pay(true, 100_000_000, sigs[0], sigs[1]); }; // seq=2
    _ = blk: { const sigs = signPayAdvance(&ch, false, 50_000_000); break :blk try ch.pay(false, 50_000_000, sigs[0], sigs[1]); }; // seq=3

    try testing.expectEqual(@as(u64, 3), ch.sequence_num);
    try testing.expectEqual(@as(u64, 850_000_000), ch.balance_a);
    try testing.expectEqual(@as(u64, 150_000_000), ch.balance_b);
    // Total conserved
    try testing.expectEqual(@as(u64, 1_000_000_000), ch.balance_a + ch.balance_b);
}

test "PaymentChannel — pay on closed channel returns error" {
    var ch = try PaymentChannel.open(testPubkeyA(), testPubkeyB(), 1_000_000_000, 0);
    _ = try blk: { const coop_sigs = signCurrentState(&ch); break :blk ch.cooperativeClose(coop_sigs[0], coop_sigs[1]); };
    try testing.expectError(error.ChannelNotOpen, ch.pay(true, 100_000_000, testSig(0x11), testSig(0x22)));
}

// ── Cooperative Close ───────────────────────────────────────────────────────

test "PaymentChannel — cooperative close returns correct settle TX" {
    var ch = try PaymentChannel.open(testPubkeyA(), testPubkeyB(), 1_000_000_000, 500_000_000);
    _ = blk: { const sigs = signPayAdvance(&ch, true, 300_000_000); break :blk try ch.pay(true, 300_000_000, sigs[0], sigs[1]); };

    const settle = try blk: { const coop_sigs = signCurrentState(&ch); break :blk ch.cooperativeClose(coop_sigs[0], coop_sigs[1]); };
    try testing.expect(ch.state == .settled);
    try testing.expectEqual(@as(u64, 700_000_000), settle.final_balance_a);
    try testing.expectEqual(@as(u64, 800_000_000), settle.final_balance_b);
}

// ── Unilateral Close + Dispute + Settle ─────────────────────────────────────

test "PaymentChannel — unilateral close with timeout" {
    var ch = try PaymentChannel.open(testPubkeyA(), testPubkeyB(), 1_000_000_000, 0);
    _ = blk: { const sigs = signPayAdvance(&ch, true, 200_000_000); break :blk try ch.pay(true, 200_000_000, sigs[0], sigs[1]); };

    // Party submits current state at block 1000 (must be signed)
    const submitted = signedUpdate(ch.channel_id, ch.sequence_num, ch.balance_a, ch.balance_b);
    _ = try ch.unilateralClose(submitted, 1000);

    try testing.expect(ch.state == .closing);
    try testing.expectEqual(@as(u64, 1000), ch.close_block);

    // Cannot settle before timeout
    try testing.expectError(error.DisputeWindowActive, ch.settle(1100));

    // Can settle after timeout
    const settle = try ch.settle(1000 + DISPUTE_WINDOW_BLOCKS);
    try testing.expect(ch.state == .settled);
    try testing.expectEqual(@as(u64, 800_000_000), settle.final_balance_a);
    try testing.expectEqual(@as(u64, 200_000_000), settle.final_balance_b);
}

test "PaymentChannel — dispute with newer state wins" {
    var ch = try PaymentChannel.openWithId(
        @as([32]u8, @splat(0x01)),
        testPubkeyA(),
        testPubkeyB(),
        1_000_000_000,
        0,
    );

    // Make several payments: seq goes to 3
    _ = blk: { const sigs = signPayAdvance(&ch, true, 100_000_000); break :blk try ch.pay(true, 100_000_000, sigs[0], sigs[1]); }; // seq=1, A=900M B=100M
    _ = blk: { const sigs = signPayAdvance(&ch, true, 100_000_000); break :blk try ch.pay(true, 100_000_000, sigs[0], sigs[1]); }; // seq=2, A=800M B=200M
    const latest_update = blk: { const sigs = signPayAdvance(&ch, true, 100_000_000); break :blk try ch.pay(true, 100_000_000, sigs[0], sigs[1]); }; // seq=3, A=700M B=300M

    // Attacker submits OLD state (seq=1) for unilateral close
    const old_state = signedUpdate(ch.channel_id, 1, 900_000_000, 100_000_000);
    _ = try ch.unilateralClose(old_state, 5000);
    try testing.expect(ch.state == .closing);
    try testing.expectEqual(@as(u64, 1), ch.sequence_num); // old state

    // Honest party disputes with seq=3 (newer)
    const won = try ch.dispute(latest_update);
    try testing.expect(won);
    try testing.expect(ch.state == .disputed);
    try testing.expectEqual(@as(u64, 3), ch.sequence_num);
    try testing.expectEqual(@as(u64, 700_000_000), ch.balance_a);
    try testing.expectEqual(@as(u64, 300_000_000), ch.balance_b);
}

test "PaymentChannel — dispute with old state fails" {
    var ch = try PaymentChannel.openWithId(
        @as([32]u8, @splat(0x02)),
        testPubkeyA(),
        testPubkeyB(),
        1_000_000_000,
        0,
    );

    _ = blk: { const sigs = signPayAdvance(&ch, true, 100_000_000); break :blk try ch.pay(true, 100_000_000, sigs[0], sigs[1]); }; // seq=1
    _ = blk: { const sigs = signPayAdvance(&ch, true, 100_000_000); break :blk try ch.pay(true, 100_000_000, sigs[0], sigs[1]); }; // seq=2

    // Close with seq=2 (latest, signed)
    const current = signedUpdate(ch.channel_id, ch.sequence_num, ch.balance_a, ch.balance_b);
    _ = try ch.unilateralClose(current, 5000);

    // Try to dispute with seq=1 (older) — should fail
    const old_state = signedUpdate(ch.channel_id, 1, 900_000_000, 100_000_000);
    try testing.expectError(error.StateNotNewer, ch.dispute(old_state));
}

test "PaymentChannel — sequence number prevents old state fraud" {
    var ch = try PaymentChannel.openWithId(
        @as([32]u8, @splat(0x03)),
        testPubkeyA(),
        testPubkeyB(),
        1_000_000_000,
        0,
    );

    _ = blk: { const sigs = signPayAdvance(&ch, true, 500_000_000); break :blk try ch.pay(true, 500_000_000, sigs[0], sigs[1]); }; // seq=1: A=500M B=500M
    _ = blk: { const sigs = signPayAdvance(&ch, false, 300_000_000); break :blk try ch.pay(false, 300_000_000, sigs[0], sigs[1]); }; // seq=2: A=800M B=200M

    // B tries unilateral close with seq=1 (favorable to B: B=500M)
    const old_state = signedUpdate(ch.channel_id, 1, 500_000_000, 500_000_000);
    _ = try ch.unilateralClose(old_state, 10000);

    // A disputes with seq=2 (A=800M B=200M — the true latest state)
    const real_state = signedUpdate(ch.channel_id, 2, 800_000_000, 200_000_000);
    const won = try ch.dispute(real_state);
    try testing.expect(won);

    // After dispute window, settle with correct balances
    const settle = try ch.settle(10000 + DISPUTE_WINDOW_BLOCKS);
    try testing.expectEqual(@as(u64, 800_000_000), settle.final_balance_a);
    try testing.expectEqual(@as(u64, 200_000_000), settle.final_balance_b);
}

// ── HTLC tests ──────────────────────────────────────────────────────────────

test "PaymentChannel — HTLC reveal with correct preimage" {
    var ch = try PaymentChannel.open(testPubkeyA(), testPubkeyB(), 1_000_000_000, 0);

    const preimage: [32]u8 = @splat(0x42);
    var hasher = Sha256.init(.{});
    hasher.update(&preimage);
    var hash_lock: [32]u8 = undefined;
    hasher.final(&hash_lock);

    const htlc_id = try ch.addHTLC(hash_lock, 100_000_000, 200);
    try ch.revealHTLC(htlc_id, preimage);
    try testing.expect(ch.htlcs[htlc_id].revealed);
}

test "PaymentChannel — HTLC reveal with wrong preimage returns error" {
    var ch = try PaymentChannel.open(testPubkeyA(), testPubkeyB(), 1_000_000_000, 0);

    const preimage: [32]u8 = @splat(0x42);
    var hasher = Sha256.init(.{});
    hasher.update(&preimage);
    var hash_lock: [32]u8 = undefined;
    hasher.final(&hash_lock);

    const htlc_id = try ch.addHTLC(hash_lock, 100_000_000, 200);
    const bad_preimage: [32]u8 = @splat(0x99);
    try testing.expectError(error.InvalidPreimage, ch.revealHTLC(htlc_id, bad_preimage));
}

test "PaymentChannel — HTLC expired check" {
    var ch = try PaymentChannel.open(testPubkeyA(), testPubkeyB(), 1_000_000_000, 0);

    _ = try ch.addHTLC(std.mem.zeroes([32]u8), 100_000_000, 200);
    try testing.expect(!ch.htlcs[0].isExpired(100));
    try testing.expect(ch.htlcs[0].isExpired(200));
    try testing.expect(ch.htlcs[0].isExpired(300));
}

// ── ChannelUpdate tests ─────────────────────────────────────────────────────

test "ChannelUpdate — hash is deterministic" {
    const upd_a = ChannelUpdate{
        .channel_id = @as([32]u8, @splat(0x01)),
        .sequence_num = 5,
        .balance_a = 700_000_000,
        .balance_b = 300_000_000,
        .sig_a = testSig(0xAA),
        .sig_b = testSig(0xBB),
    };
    const upd_b = upd_a; // copy
    try testing.expect(std.mem.eql(u8, &upd_a.hash(), &upd_b.hash()));
}

test "ChannelUpdate — different sequence produces different hash" {
    const upd_a = ChannelUpdate{
        .channel_id = @as([32]u8, @splat(0x01)),
        .sequence_num = 1,
        .balance_a = 700_000_000,
        .balance_b = 300_000_000,
        .sig_a = testSig(0xAA),
        .sig_b = testSig(0xBB),
    };
    var upd_b = upd_a;
    upd_b.sequence_num = 2;
    try testing.expect(!std.mem.eql(u8, &upd_a.hash(), &upd_b.hash()));
}

test "ChannelUpdate — verify accepts real sigs over the update hash" {
    // Build the update WITHOUT signatures, derive its canonical hash,
    // then have each party sign that hash with their real privkey.
    var update = ChannelUpdate{
        .channel_id = @as([32]u8, @splat(0x01)),
        .sequence_num = 1,
        .balance_a = 500_000_000,
        .balance_b = 500_000_000,
        .sig_a = @splat(0),
        .sig_b = @splat(0),
    };
    const msg = update.hash();
    update.sig_a = signAs("channel-test-party-a", msg);
    update.sig_b = signAs("channel-test-party-b", msg);
    try testing.expect(update.verify(testPubkeyA(), testPubkeyB()));

    // Mutating any field invalidates the hash → sigs no longer verify.
    var tampered = update;
    tampered.balance_a += 1;
    try testing.expect(!tampered.verify(testPubkeyA(), testPubkeyB()));

    // Zeroed sig_a fails (ECDSA verify rejects R == 0).
    var bad = update;
    bad.sig_a = @splat(0);
    try testing.expect(!bad.verify(testPubkeyA(), testPubkeyB()));

    // Swapped pubkeys also fail (sig_a was signed by A, not B).
    try testing.expect(!update.verify(testPubkeyB(), testPubkeyA()));
}

// ── SettleTx tests ──────────────────────────────────────────────────────────

test "SettleTx — fromUpdate produces deterministic hashes" {
    const update = ChannelUpdate{
        .channel_id = @as([32]u8, @splat(0x01)),
        .sequence_num = 5,
        .balance_a = 700_000_000,
        .balance_b = 300_000_000,
        .sig_a = testSig(0xAA),
        .sig_b = testSig(0xBB),
    };
    const s1 = SettleTx.fromUpdate(&update, 1000);
    const s2 = SettleTx.fromUpdate(&update, 1000);
    try testing.expect(std.mem.eql(u8, &s1.tx_hash_a, &s2.tx_hash_a));
    try testing.expect(std.mem.eql(u8, &s1.tx_hash_b, &s2.tx_hash_b));
    // tx_hash_a != tx_hash_b (different settle sides)
    try testing.expect(!std.mem.eql(u8, &s1.tx_hash_a, &s1.tx_hash_b));
}

// ── ChannelManager tests ────────────────────────────────────────────────────

test "ChannelManager — openChannel and findChannel" {
    var mgr = ChannelManager.init();
    const ch = try mgr.openChannel(testPubkeyA(), testPubkeyB(), 1_000_000_000, 0);
    try testing.expect(ch.state == .open);

    const found = mgr.findChannel(ch.channel_id);
    try testing.expect(found != null);
    try testing.expectEqual(@as(u64, 1_000_000_000), found.?.balance_a);
}

test "ChannelManager — countByState tracks states" {
    var mgr = ChannelManager.init();
    _ = try mgr.openChannel(testPubkeyA(), testPubkeyB(), 1_000_000_000, 0);
    _ = try mgr.openChannel(testPubkeyA(), testPubkeyB(), 500_000_000, 500_000_000);

    try testing.expectEqual(@as(u8, 2), mgr.countByState(.open));
    try testing.expectEqual(@as(u8, 0), mgr.countByState(.settled));
}

test "ChannelManager — getTotalLockedSat sums correctly" {
    var mgr = ChannelManager.init();
    _ = try mgr.openChannel(testPubkeyA(), testPubkeyB(), 1_000_000_000, 0);
    _ = try mgr.openChannel(testPubkeyA(), testPubkeyB(), 500_000_000, 500_000_000);

    try testing.expectEqual(@as(u64, 2_000_000_000), mgr.getTotalLockedSat());
}

test "ChannelManager — closeChannel settles correctly" {
    var mgr = ChannelManager.init();
    const ch = try mgr.openChannel(testPubkeyA(), testPubkeyB(), 1_000_000_000, 500_000_000);
    const cid = ch.channel_id;

    const sigs = signCurrentState(ch);
    const settle = try mgr.closeChannel(cid, sigs[0], sigs[1]);
    try testing.expectEqual(@as(u64, 1_000_000_000), settle.final_balance_a);
    try testing.expectEqual(@as(u64, 500_000_000), settle.final_balance_b);

    const found = mgr.findChannel(cid);
    try testing.expect(found != null);
    try testing.expect(found.?.state == .settled);
}

// ── Full lifecycle: open -> pay -> close -> balances correct ─────────────────

test "Full lifecycle — open pay close cooperative" {
    var mgr = ChannelManager.init();
    const ch = try mgr.openChannel(testPubkeyA(), testPubkeyB(), 2_000_000_000, 1_000_000_000);

    // A pays B 500M sat
    _ = blk: { const sigs = signPayAdvance(&ch, true, 500_000_000); break :blk try ch.pay(true, 500_000_000, sigs[0], sigs[1]); };
    // B pays A 200M sat
    _ = blk: { const sigs = signPayAdvance(&ch, false, 200_000_000); break :blk try ch.pay(false, 200_000_000, sigs[0], sigs[1]); };

    // Final: A=1700M, B=1300M (total=3000M conserved)
    try testing.expectEqual(@as(u64, 1_700_000_000), ch.balance_a);
    try testing.expectEqual(@as(u64, 1_300_000_000), ch.balance_b);

    const settle = try blk: { const coop_sigs = signCurrentState(&ch); break :blk ch.cooperativeClose(coop_sigs[0], coop_sigs[1]); };
    try testing.expectEqual(@as(u64, 1_700_000_000), settle.final_balance_a);
    try testing.expectEqual(@as(u64, 1_300_000_000), settle.final_balance_b);
    try testing.expect(ch.state == .settled);
}

test "Full lifecycle — open pay unilateral close dispute settle" {
    var ch = try PaymentChannel.openWithId(
        @as([32]u8, @splat(0x05)),
        testPubkeyA(),
        testPubkeyB(),
        1_000_000_000,
        0,
    );

    // Several payments
    _ = blk: { const sigs = signPayAdvance(&ch, true, 100_000_000); break :blk try ch.pay(true, 100_000_000, sigs[0], sigs[1]); }; // seq=1
    _ = blk: { const sigs = signPayAdvance(&ch, true, 200_000_000); break :blk try ch.pay(true, 200_000_000, sigs[0], sigs[1]); }; // seq=2
    const latest = blk: { const sigs = signPayAdvance(&ch, true, 50_000_000); break :blk try ch.pay(true, 50_000_000, sigs[0], sigs[1]); }; // seq=3: A=650M B=350M

    // Malicious party submits old state (seq=1)
    const fraud_state = signedUpdate(ch.channel_id, 1, 900_000_000, 100_000_000);
    _ = try ch.unilateralClose(fraud_state, 20000);

    // Honest party disputes with seq=3
    _ = try ch.dispute(latest);

    // Settle after timeout
    const settle = try ch.settle(20000 + DISPUTE_WINDOW_BLOCKS);
    try testing.expectEqual(@as(u64, 650_000_000), settle.final_balance_a);
    try testing.expectEqual(@as(u64, 350_000_000), settle.final_balance_b);
    try testing.expect(ch.state == .settled);
}
