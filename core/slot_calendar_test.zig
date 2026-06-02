/// slot_calendar_test.zig — Standalone test runner for slot_calendar.zig.
///
/// Zig 0.15.2: test blocks inside a file are run when that file is the
/// test root. This file imports the module under test and re-runs all the
/// tests declared in it, plus a few extra cross-module integration checks.
///
/// Run with: zig test core/slot_calendar_test.zig
/// Or via build step: zig build test-slot-calendar

const std = @import("std");
const sc = @import("slot_calendar.zig");

// Pull in all tests declared in slot_calendar.zig
comptime {
    _ = sc;
}

// ─── Extra tests (supplement, not replace, the in-module tests) ──────────────

test "getSlot returns correct entry by slot_id" {
    var cal = sc.SlotCalendar.init();
    var vs_buf: [8][20]u8 = undefined;
    var i: usize = 0;
    while (i < 3) : (i += 1) {
        var a = std.mem.zeroes([20]u8);
        a[0] = @intCast(i + 1);
        vs_buf[i] = a;
    }
    const vs = vs_buf[0..3];
    cal.recompute(50, std.mem.zeroes([32]u8), 0, vs);

    // Slots 51–110 in window.
    const e51 = cal.getSlot(51);
    try std.testing.expect(e51 != null);
    try std.testing.expectEqual(@as(u64, 51), e51.?.slot_id);

    const e110 = cal.getSlot(110);
    try std.testing.expect(e110 != null);
    try std.testing.expectEqual(@as(u64, 110), e110.?.slot_id);

    try std.testing.expect(cal.getSlot(50) == null);
    try std.testing.expect(cal.getSlot(111) == null);
}

test "recompute resets head to 0" {
    var cal = sc.SlotCalendar.init();
    const vs = [_][20]u8{std.mem.zeroes([20]u8)};
    cal.recompute(0, std.mem.zeroes([32]u8), 0, &vs);
    // Finalize first 3 slots to advance head.
    cal.finalizeSlot(1, std.mem.zeroes([32]u8));
    cal.finalizeSlot(2, std.mem.zeroes([32]u8));
    cal.finalizeSlot(3, std.mem.zeroes([32]u8));
    try std.testing.expectEqual(@as(usize, 3), cal.head);

    // A fresh recompute resets head to 0.
    cal.recompute(5, std.mem.zeroes([32]u8), 0, &vs);
    try std.testing.expectEqual(@as(usize, 0), cal.head);
}

test "pruneMissed leaves finalized entries unchanged" {
    var cal = sc.SlotCalendar.init();
    const vs = [_][20]u8{std.mem.zeroes([20]u8)};
    cal.recompute(0, std.mem.zeroes([32]u8), 0, &vs);

    // Finalize slot 1.
    var h: [32]u8 = undefined;
    @memset(&h, 0xFF);
    cal.finalizeSlot(1, h);
    try std.testing.expectEqual(sc.SlotState.finalized, cal.entries[0].state);

    // Prune far in the future — slot 1 should remain finalized.
    cal.pruneMissed(999_999_999);
    try std.testing.expectEqual(sc.SlotState.finalized, cal.entries[0].state);
}

test "leaderForSlot single validator always returns that validator" {
    var addr: [20]u8 = undefined;
    @memset(&addr, 0xAA);
    const vs = [_][20]u8{addr};
    const tip = std.mem.zeroes([32]u8);

    var slot: u64 = 0;
    while (slot < 20) : (slot += 1) {
        const l = sc.leaderForSlot(slot, tip, &vs);
        try std.testing.expectEqualSlices(u8, &addr, &l);
    }
}
