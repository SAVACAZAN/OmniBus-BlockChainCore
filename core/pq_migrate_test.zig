//! pq_migrate_test.zig — extra tests for `core/pq_migrate_consensus.zig`
//!
//! Most unit tests live inside the module itself (round-trip, truncation,
//! version/scheme rejection, replay guard). This file adds end-to-end
//! coverage that exercises serialize + deserialize + apply together.
//!
//! Wired into the `test-pq` build step.

const std = @import("std");
const migrate = @import("pq_migrate_consensus.zig");

const testing = std.testing;

test "PQMigrateV1 end-to-end: build → serialize → wire → deserialize → apply" {
    const ally = testing.allocator;

    const old_pk = [_]u8{0x11} ** 32;
    const new_pk = [_]u8{0x22} ** 32;
    const proof  = [_]u8{0x33} ** 64;

    const tx = migrate.PQMigrateV1{
        .scheme = 0x01,
        .coin_type = 779,
        .timestamp = 1_700_001_000,
        .old_pubkey = &old_pk,
        .new_pubkey = &new_pk,
        .proof_of_ownership = &proof,
    };

    const wire = try tx.serialize(ally);
    defer ally.free(wire);

    // Round-trip via the wire bytes (do NOT reuse `tx` slices — exercise the
    // alias-back-to-bytes behavior of deserialize).
    const parsed = try migrate.PQMigrateV1.deserialize(wire);
    try testing.expectEqual(tx.scheme, parsed.scheme);
    try testing.expectEqual(tx.coin_type, parsed.coin_type);
    try testing.expectEqualSlices(u8, &old_pk, parsed.old_pubkey);
    try testing.expectEqualSlices(u8, &new_pk, parsed.new_pubkey);
    try testing.expectEqualSlices(u8, &proof, parsed.proof_of_ownership);

    // Apply to a fresh state — should succeed exactly once.
    var state = migrate.PQMigrationState.init(ally);
    defer state.deinit();
    try migrate.apply(&state, parsed);
    try testing.expectEqual(@as(usize, 1), state.map.count());

    // Second apply with same old_pubkey is rejected as replay.
    try testing.expectError(error.AlreadyMigrated, migrate.apply(&state, parsed));
}

test "PQMigrateV1 serialized size matches advertised" {
    const ally = testing.allocator;
    const old_pk = [_]u8{0xA0} ** 100;
    const new_pk = [_]u8{0xA1} ** 200;
    const proof  = [_]u8{0xA2} ** 300;

    const tx = migrate.PQMigrateV1{
        .scheme = 0x02,
        .coin_type = 779,
        .timestamp = 0,
        .old_pubkey = &old_pk,
        .new_pubkey = &new_pk,
        .proof_of_ownership = &proof,
    };
    try testing.expectEqual(20 + 100 + 200 + 300, tx.serializedSize());

    const wire = try tx.serialize(ally);
    defer ally.free(wire);
    try testing.expectEqual(tx.serializedSize(), wire.len);
}

test "PQMigrationState distinct old_pubkeys both apply" {
    const ally = testing.allocator;
    var state = migrate.PQMigrationState.init(ally);
    defer state.deinit();

    const old_a = [_]u8{0xAA} ** 8;
    const new_a = [_]u8{0xBB} ** 8;
    const old_b = [_]u8{0xCC} ** 8;
    const new_b = [_]u8{0xDD} ** 8;
    const proof = [_]u8{0xEE} ** 8;

    try migrate.apply(&state, .{
        .scheme = 0x01, .coin_type = 778, .timestamp = 0,
        .old_pubkey = &old_a, .new_pubkey = &new_a, .proof_of_ownership = &proof,
    });
    try migrate.apply(&state, .{
        .scheme = 0x01, .coin_type = 780, .timestamp = 0,
        .old_pubkey = &old_b, .new_pubkey = &new_b, .proof_of_ownership = &proof,
    });
    try testing.expectEqual(@as(usize, 2), state.map.count());
}
