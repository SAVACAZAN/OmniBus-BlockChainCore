//! id_obm.zig — OmniBus Binary Map (1 byte status field).
//!
//! Derived live from chain state (reputation cups + flags caller passes
//! in). Never stored separately — the caller queries `ReputationManager`,
//! `DnsRegistry`, etc., then assembles the byte here. This guarantees the
//! byte never goes stale, since there's no copy to update.
//!
//! Bit positions are defined in `id_types.ObmBit` and are part of the
//! wire format — append new bits at higher indices, never reorder.

const std = @import("std");
const reputation = @import("../reputation.zig");
const types = @import("id_types.zig");

/// Threshold a cup must reach (stored=x100, so 5000 = 50.00) before its
/// badge bit lights up. 50 / 100 was chosen so users have to actually
/// engage before flashing the badge — not just create an account.
pub const BADGE_THRESHOLD_STORED: u32 = 50 * reputation.CUP_SCALE;

/// Inputs to `compute`. Caller pulls these from the chain (reputation
/// manager, DNS registry, validator set, PQ key registry). Keeping them
/// as a plain struct means this module is unit-testable without a chain.
pub const ObmInputs = struct {
    cups: reputation.ReputationCups,
    has_pq_key: bool,
    has_dns_name: bool,
    is_validator: bool,
};

/// Assemble the OBM byte from chain-derived flags. Pure function: same
/// inputs always produce the same byte.
pub fn compute(inputs: ObmInputs) types.Obm {
    var byte: u8 = 0;
    if (inputs.cups.love_stored     >= BADGE_THRESHOLD_STORED) byte |= bit(.love_badge);
    if (inputs.cups.food_stored     >= BADGE_THRESHOLD_STORED) byte |= bit(.food_badge);
    if (inputs.cups.rent_stored     >= BADGE_THRESHOLD_STORED) byte |= bit(.rent_badge);
    if (inputs.cups.vacation_stored >= BADGE_THRESHOLD_STORED) byte |= bit(.vacation_badge);
    if (inputs.has_pq_key)     byte |= bit(.has_pq_key);
    if (inputs.has_dns_name)   byte |= bit(.has_dns_name);
    if (inputs.is_validator)   byte |= bit(.is_validator);
    if (inputs.cups.hasSatoshiBadge()) byte |= bit(.is_zen_tier);
    return byte;
}

inline fn bit(b: types.ObmBit) u8 {
    return @as(u8, 1) << @intFromEnum(b);
}

/// Decode one bit for query convenience (e.g. "does this OBM have LOVE?").
pub fn has(obm: types.Obm, b: types.ObmBit) bool {
    return (obm & bit(b)) != 0;
}

test "compute returns 0 for fresh wallet" {
    const out = compute(.{
        .cups = .{},
        .has_pq_key = false,
        .has_dns_name = false,
        .is_validator = false,
    });
    try std.testing.expectEqual(@as(u8, 0), out);
}

test "compute lights LOVE bit at exactly 50.00" {
    const cups = reputation.ReputationCups{ .love_stored = BADGE_THRESHOLD_STORED };
    const out = compute(.{
        .cups = cups,
        .has_pq_key = false,
        .has_dns_name = false,
        .is_validator = false,
    });
    try std.testing.expect(has(out, .love_badge));
    try std.testing.expect(!has(out, .food_badge));
}

test "compute leaves LOVE dark just below threshold" {
    const cups = reputation.ReputationCups{ .love_stored = BADGE_THRESHOLD_STORED - 1 };
    const out = compute(.{
        .cups = cups,
        .has_pq_key = false,
        .has_dns_name = false,
        .is_validator = false,
    });
    try std.testing.expect(!has(out, .love_badge));
}

test "Satoshi badge sets ZEN bit" {
    const cups = reputation.ReputationCups{
        .love_stored = reputation.CUP_CAP_STORED,
        .food_stored = reputation.CUP_CAP_STORED,
        .rent_stored = reputation.CUP_CAP_STORED,
        .vacation_stored = reputation.CUP_CAP_STORED,
    };
    const out = compute(.{
        .cups = cups,
        .has_pq_key = false,
        .has_dns_name = false,
        .is_validator = false,
    });
    try std.testing.expect(has(out, .is_zen_tier));
    try std.testing.expect(has(out, .love_badge));
    try std.testing.expect(has(out, .food_badge));
    try std.testing.expect(has(out, .rent_badge));
    try std.testing.expect(has(out, .vacation_badge));
}

test "All-flags case packs into a single byte" {
    const cups = reputation.ReputationCups{
        .love_stored = reputation.CUP_CAP_STORED,
        .food_stored = reputation.CUP_CAP_STORED,
        .rent_stored = reputation.CUP_CAP_STORED,
        .vacation_stored = reputation.CUP_CAP_STORED,
    };
    const out = compute(.{
        .cups = cups,
        .has_pq_key = true,
        .has_dns_name = true,
        .is_validator = true,
    });
    try std.testing.expectEqual(@as(u8, 0xFF), out);
}
