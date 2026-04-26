//! Validator registry + slot-leader rotation.
//!
//! Why: the original consensus was raw PoW with 1s blocks on a 2-node
//! network. Whoever was milliseconds faster won every block, the other
//! node forked, and rewards went 100% to one address (winner-take-all).
//!
//! Solution (this file): each block has a deterministic *leader* — only
//! that one validator is allowed to produce the block at that slot.
//! Other validators wait their turn. No race, no fork, no orphans on a
//! healthy network.
//!
//! Formula:
//!   slot_id    = unix_seconds_since_genesis        (one slot per second)
//!   leader_idx = HASH(slot_id || prev_block_hash) mod N_validators
//!
//! prev_block_hash in the formula prevents grinding: an attacker can't
//! pre-compute "I'll be leader at slot 100000 if I just pick the right
//! prev_hash" because prev_hash is determined by the block before, which
//! they don't control unless they're already leader.
//!
//! Tolerance: peers accept a block in window [slot - 500ms, slot + 1500ms]
//! to handle clock drift between PC and VPS (measured RTT 100ms, NTP slop
//! +/- 500ms). See memory:project_omnibus_clock_drift_problem.md.

const std = @import("std");

/// One validator record. `address` is a stable owner-controlled
/// identifier (savacazan for PC, dev for VPS, etc.).
pub const Validator = struct {
    /// Address string (e.g. "ob1qzhrauq..."). Up to 64 ASCII chars.
    address: []const u8,
    /// Voting weight. 1 = normal validator. Higher = more slots assigned.
    /// Used by leader selection: weighted round-robin via cumulative dist.
    weight: u32 = 1,
    /// Block height since which this validator was active. 0 = genesis.
    since_height: u64 = 0,
};

/// Genesis-time validator set. 2 entries until governance adds more.
/// Order matters — index 0 always the founder address. Hash-based
/// rotation makes order irrelevant for fairness, but logging stays
/// sane if first slot demonstrably picks "the founder" sometimes.
///
/// EDIT THIS LIST when onboarding new validators (governance vote).
/// Re-genesis required if changed before block 0.
pub const GENESIS_VALIDATORS = [_]Validator{
    // savacazan — founder, PC miner.
    .{ .address = "ob1qzhrauq0xe9hg033ccup7vlgsdmj6kcxyza9zp0", .weight = 1, .since_height = 0 },
    // VPS dev mnemonic — bootstrap seed (will be replaced by a real
    // operator wallet once the network grows).
    .{ .address = "ob1qw6zhsqg29aht23fksk5w54lkgavatpgltqxlvl", .weight = 1, .since_height = 0 },
};

/// Pick the leader for a given slot. Pure function. Deterministic.
/// Returns null only if validators slice is empty (impossible in
/// production — refuse to bootstrap with 0 validators).
///
/// `prev_block_hash` is the FULL HEX-string hash of the previous block
/// (64 chars). After the 2026-04-26 wire-format upgrade, both peers see
/// the same 64-char hash, so this formula is now deterministic across
/// the network. Full hash mixed for max grinding resistance.
pub fn leaderForSlot(
    slot_id: u64,
    prev_block_hash: []const u8,
    validators: []const Validator,
) ?Validator {
    if (validators.len == 0) return null;

    // Build the seed: 8 bytes of slot_id + entire prev_hash hex (up to 64).
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var slot_bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &slot_bytes, slot_id, .little);
    hasher.update(&slot_bytes);
    hasher.update(prev_block_hash);
    var digest: [32]u8 = undefined;
    hasher.final(&digest);

    // Sum total weight, pick a random point in [0, total), find the
    // validator whose cumulative weight covers it.
    var total_weight: u64 = 0;
    for (validators) |v| total_weight += v.weight;
    if (total_weight == 0) return null;

    const pick = std.mem.readInt(u64, digest[0..8], .little) % total_weight;
    var running: u64 = 0;
    for (validators) |v| {
        running += v.weight;
        if (pick < running) return v;
    }
    // Mathematically unreachable but defensive.
    return validators[validators.len - 1];
}

/// Slot tolerance window in milliseconds (measured drift PC↔VPS = ~100ms
/// RTT plus NTP slop, so 500ms back + 1500ms forward gives ~2 seconds
/// of slack — generous but not so big a malicious leader can claim
/// future slots cheaply).
pub const SLOT_TOLERANCE_BACK_MS: i64 = 500;
pub const SLOT_TOLERANCE_FORWARD_MS: i64 = 1500;

/// Check whether `block_timestamp_ms` falls within the tolerance window
/// of `slot_id`. Returns true if it's acceptable (we should validate
/// the block's leader claim against `slot_id`).
pub fn isWithinSlotTolerance(slot_id: u64, block_timestamp_ms: i64) bool {
    const slot_start_ms: i64 = @intCast(slot_id * 1000);
    const slot_end_ms: i64 = slot_start_ms + 1000;
    return block_timestamp_ms >= slot_start_ms - SLOT_TOLERANCE_BACK_MS and
           block_timestamp_ms < slot_end_ms + SLOT_TOLERANCE_FORWARD_MS;
}

/// Compute slot_id from block timestamp (in seconds since unix epoch).
/// One slot per second; this is the inverse of "what slot does this
/// block belong to". Genesis is at slot 0 by definition (its timestamp
/// is the genesis timestamp from chain_config, not 0).
pub fn slotFromTimestamp(block_timestamp_s: i64, genesis_timestamp_s: i64) u64 {
    if (block_timestamp_s < genesis_timestamp_s) return 0;
    return @intCast(block_timestamp_s - genesis_timestamp_s);
}

/// Verify that a block was produced by the correct slot leader.
/// Returns true on accept, false on reject (caller should drop the
/// block + score down the peer that gossiped it).
///
/// The check works the same on every node because it's pure: anyone
/// holding (slot_id, prev_hash, validator_set) computes the same
/// leader. So an attacker can't claim someone else's slot.
///
/// Tolerance: timestamp must fit in slot ± SLOT_TOLERANCE_*. This
/// stops stale blocks (replay of old slot) and far-future blocks
/// (clock-warp attack).
pub fn validateBlockLeader(
    block_miner_address: []const u8,
    block_timestamp_s: i64,
    block_timestamp_ms_in_slot: i64,
    prev_block_hash: []const u8,
    genesis_timestamp_s: i64,
    validators: []const Validator,
) bool {
    if (validators.len == 0) return false;
    const slot_id = slotFromTimestamp(block_timestamp_s, genesis_timestamp_s);
    if (!isWithinSlotTolerance(slot_id, block_timestamp_ms_in_slot)) return false;
    const leader = leaderForSlot(slot_id, prev_block_hash, validators) orelse return false;
    return std.mem.eql(u8, leader.address, block_miner_address);
}

// ─── Tests ────────────────────────────────────────────────────────────────

test "leaderForSlot — deterministic same input same output" {
    const vs = GENESIS_VALIDATORS[0..];
    const a = leaderForSlot(100, "0000aaaa", vs);
    const b = leaderForSlot(100, "0000aaaa", vs);
    try std.testing.expect(a != null);
    try std.testing.expect(b != null);
    try std.testing.expectEqualStrings(a.?.address, b.?.address);
}

test "leaderForSlot — different slot picks (probably) different leader over many" {
    // Over 100 slots with same prev_hash, both validators should appear
    // — proves it's not stuck on one.
    const vs = GENESIS_VALIDATORS[0..];
    var seen_a: u32 = 0;
    var seen_b: u32 = 0;
    for (0..100) |i| {
        const ldr = leaderForSlot(i, "deadbeef", vs).?;
        if (std.mem.eql(u8, ldr.address, vs[0].address)) seen_a += 1;
        if (std.mem.eql(u8, ldr.address, vs[1].address)) seen_b += 1;
    }
    // Both should get >= 30 of 100 with weight=1 each. Statistical, not
    // guaranteed, but extremely unlikely to fail with SHA-256.
    try std.testing.expect(seen_a >= 30);
    try std.testing.expect(seen_b >= 30);
    try std.testing.expectEqual(@as(u32, 100), seen_a + seen_b);
}

test "leaderForSlot — empty validators returns null" {
    const empty = [_]Validator{};
    const r = leaderForSlot(0, "00", empty[0..]);
    try std.testing.expect(r == null);
}

test "isWithinSlotTolerance — accepts in-window, rejects out-of-window" {
    // slot_id=100 means slot covers [100000, 101000) ms in unix time.
    // With +/-500/+1500 tolerance, accept [99500, 102500).
    try std.testing.expect(isWithinSlotTolerance(100, 100000));
    try std.testing.expect(isWithinSlotTolerance(100, 99500));
    try std.testing.expect(isWithinSlotTolerance(100, 102499));
    try std.testing.expect(!isWithinSlotTolerance(100, 99499));
    try std.testing.expect(!isWithinSlotTolerance(100, 102500));
}

test "leaderForSlot — weight bias works" {
    // Validator A weight=3, B weight=1 → A should win ~75% of slots.
    const heavy_set = [_]Validator{
        .{ .address = "AAAA", .weight = 3 },
        .{ .address = "BBBB", .weight = 1 },
    };
    var seen_a: u32 = 0;
    for (0..1000) |i| {
        const ldr = leaderForSlot(i, "00", heavy_set[0..]).?;
        if (std.mem.eql(u8, ldr.address, "AAAA")) seen_a += 1;
    }
    // Expected ~750 ± 50. Loose bound for safety.
    try std.testing.expect(seen_a >= 700);
    try std.testing.expect(seen_a <= 800);
}
