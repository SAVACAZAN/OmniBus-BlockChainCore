/// slot_calendar.zig — Pre-computed Slot Calendar (Solana PoH-style)
///
/// Computes and caches the next 60 future slots so that:
///   1. Frontend can display "next leader: ob1qzhrauq0x in 2.3s"
///   2. Future-block pool can route TXs with target_slot=N
///   3. Anti-fork: validators know deterministically who delivers each slot
///
/// Design constraints:
///   - No malloc in SlotCalendar itself — all fixed-size arrays
///   - toJson() takes an allocator (for RPC output only)
///   - No coupling to validator_registry.zig — caller passes validator_set
///     as []const [20]u8 (address bytes).  Hex encoding for RPC is done in
///     toJson().
///
/// Leader election formula (per spec):
///   sha256( slot_id_le8 ++ tip_hash_32 ) → first 8 bytes as u64 → mod N
///
/// NOTE: The existing orchestrator.zig SlotCalendar uses string addresses and
/// a generics-based leaderFn. This module is the self-contained calendar that
/// the spec requested, with [20]u8 address bytes, finalizeSlot, pruneMissed,
/// and a toJson serializer. Both coexist; they serve different purposes.

const std = @import("std");

// ─── Types ──────────────────────────────────────────────────────────────────

pub const SlotState = enum(u8) {
    future = 0,
    in_flight = 1,
    finalized = 2,
    missed = 3,
};

pub const SlotEntry = struct {
    slot_id: u64,
    /// ob1q address bytes — all zeros means no leader (empty validator set).
    leader_address: [20]u8,
    /// Absolute timestamp (ms) when the block is expected to arrive.
    expected_arrival_ms: i64,
    /// SHA-256 of the block that landed — zero-filled until finalized.
    placeholder_hash: [32]u8,
    state: SlotState,
};

pub const MAX_CALENDAR_SLOTS: usize = 60;

// ─── SlotCalendar ────────────────────────────────────────────────────────────

pub const SlotCalendar = struct {
    entries: [MAX_CALENDAR_SLOTS]SlotEntry,
    /// Ring buffer head index — index of the oldest / lowest slot_id entry.
    head: usize,
    /// Chain height at last recompute.
    tip_height: u64,
    /// Chain tip hash (32 bytes) at last recompute.
    tip_hash: [32]u8,
    /// Wall-clock ms when the calendar was last computed.
    computed_at_ms: i64,

    // ─── init ──────────────────────────────────────────────────────────────

    pub fn init() SlotCalendar {
        var cal = SlotCalendar{
            .entries = undefined,
            .head = 0,
            .tip_height = 0,
            .tip_hash = std.mem.zeroes([32]u8),
            .computed_at_ms = 0,
        };
        // Zero all entries so any uncomputed slot is well-defined.
        var i: usize = 0;
        while (i < MAX_CALENDAR_SLOTS) : (i += 1) {
            cal.entries[i] = SlotEntry{
                .slot_id = 0,
                .leader_address = std.mem.zeroes([20]u8),
                .expected_arrival_ms = 0,
                .placeholder_hash = std.mem.zeroes([32]u8),
                .state = .future,
            };
        }
        return cal;
    }

    // ─── recompute ─────────────────────────────────────────────────────────

    /// Recompute all 60 future slots from the current chain tip.
    /// Called: at startup, after each finalized block, after governance TX.
    ///
    /// validator_set: slice of 20-byte address arrays. May be empty —
    /// in that case leader_address is all zeros.
    pub fn recompute(
        self: *SlotCalendar,
        tip_height: u64,
        tip_hash: [32]u8,
        now_ms: i64,
        validator_set: []const [20]u8,
    ) void {
        self.tip_height = tip_height;
        self.tip_hash = tip_hash;
        self.computed_at_ms = now_ms;
        self.head = 0; // ring buffer always starts at index 0 after full recompute

        var i: usize = 0;
        while (i < MAX_CALENDAR_SLOTS) : (i += 1) {
            const slot_id: u64 = tip_height + 1 + i;
            const arrival_ms: i64 = now_ms + @as(i64, @intCast(i + 1)) * 1000;
            const leader = leaderForSlot(slot_id, tip_hash, validator_set);
            self.entries[i] = SlotEntry{
                .slot_id = slot_id,
                .leader_address = leader,
                .expected_arrival_ms = arrival_ms,
                .placeholder_hash = std.mem.zeroes([32]u8),
                .state = .future,
            };
        }
    }

    // ─── getSlot ───────────────────────────────────────────────────────────

    /// Get the entry for a given slot_id. Returns null if not in window.
    pub fn getSlot(self: *const SlotCalendar, slot_id: u64) ?*const SlotEntry {
        // Linear scan — only 60 entries, negligible cost.
        var i: usize = 0;
        while (i < MAX_CALENDAR_SLOTS) : (i += 1) {
            if (self.entries[i].slot_id == slot_id) return &self.entries[i];
        }
        return null;
    }

    // ─── finalizeSlot ──────────────────────────────────────────────────────

    /// Mark a slot as finalized when its block arrives.
    /// Advances the ring buffer head if the slot was at head.
    pub fn finalizeSlot(self: *SlotCalendar, slot_id: u64, block_hash: [32]u8) void {
        var i: usize = 0;
        while (i < MAX_CALENDAR_SLOTS) : (i += 1) {
            if (self.entries[i].slot_id == slot_id) {
                self.entries[i].placeholder_hash = block_hash;
                self.entries[i].state = .finalized;
                // Advance head past consecutive finalized entries.
                while (self.head < MAX_CALENDAR_SLOTS and
                    self.entries[self.head].state == .finalized)
                {
                    self.head += 1;
                    if (self.head >= MAX_CALENDAR_SLOTS) self.head = 0;
                }
                return;
            }
        }
    }

    // ─── pruneMissed ───────────────────────────────────────────────────────

    /// Mark expired slots as missed (called every tick / per block).
    /// A slot is missed when now_ms > expected_arrival_ms + 2× slot interval.
    pub fn pruneMissed(self: *SlotCalendar, now_ms: i64) void {
        const SLOT_INTERVAL_MS: i64 = 1000;
        var i: usize = 0;
        while (i < MAX_CALENDAR_SLOTS) : (i += 1) {
            const e = &self.entries[i];
            if (e.state == .future or e.state == .in_flight) {
                const overdue = now_ms - e.expected_arrival_ms;
                if (overdue >= SLOT_INTERVAL_MS * 2) {
                    e.state = .missed;
                } else if (overdue >= 0) {
                    e.state = .in_flight;
                }
            }
        }
    }

    // ─── toJson ────────────────────────────────────────────────────────────

    /// Serialize the full calendar to JSON for RPC output.
    /// Returns a heap-allocated slice owned by the caller.
    pub fn toJson(self: *const SlotCalendar, alloc: std.mem.Allocator) ![]u8 {
        var buf = std.array_list.Managed(u8).init(alloc);
        errdefer buf.deinit();
        const w = buf.writer();

        try w.writeAll("{\"tip_height\":");
        try w.print("{d}", .{self.tip_height});
        try w.writeAll(",\"computed_at_ms\":");
        try w.print("{d}", .{self.computed_at_ms});
        try w.writeAll(",\"entries\":[");

        var i: usize = 0;
        while (i < MAX_CALENDAR_SLOTS) : (i += 1) {
            if (i > 0) try w.writeAll(",");
            const e = &self.entries[i];
            const state_str: []const u8 = switch (e.state) {
                .future => "future",
                .in_flight => "in_flight",
                .finalized => "finalized",
                .missed => "missed",
            };
            // Encode leader_address as lowercase hex.
            var leader_hex: [40]u8 = undefined;
            _ = std.fmt.bufPrint(&leader_hex, "{s}", .{
                std.fmt.bytesToHex(e.leader_address, .lower),
            }) catch unreachable;
            // Encode placeholder_hash as lowercase hex.
            var hash_hex: [64]u8 = undefined;
            _ = std.fmt.bufPrint(&hash_hex, "{s}", .{
                std.fmt.bytesToHex(e.placeholder_hash, .lower),
            }) catch unreachable;

            try w.print(
                "{{\"slot_id\":{d},\"leader\":\"{s}\",\"expected_arrival_ms\":{d},\"placeholder_hash\":\"{s}\",\"state\":\"{s}\"}}",
                .{ e.slot_id, leader_hex, e.expected_arrival_ms, hash_hex, state_str },
            );
        }

        try w.writeAll("]}");
        return buf.toOwnedSlice();
    }
};

// ─── leaderForSlot ──────────────────────────────────────────────────────────

/// Deterministic leader election (pure function, no state).
///
/// Algorithm (per spec):
///   sha256( slot_id_le8 ++ tip_hash_32 )[0..8] as u64 → mod validator_set.len
///
/// Returns all-zeros if validator_set is empty.
pub fn leaderForSlot(
    slot_id: u64,
    tip_hash: [32]u8,
    validator_set: []const [20]u8,
) [20]u8 {
    if (validator_set.len == 0) return std.mem.zeroes([20]u8);

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var slot_bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &slot_bytes, slot_id, .little);
    hasher.update(&slot_bytes);
    hasher.update(&tip_hash);
    var digest: [32]u8 = undefined;
    hasher.final(&digest);

    const idx_u64 = std.mem.readInt(u64, digest[0..8], .little);
    const idx: usize = @intCast(idx_u64 % @as(u64, @intCast(validator_set.len)));
    return validator_set[idx];
}

// ─── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

// ── helper: build a small validator set ──────────────────────────────────────
fn makeValidatorSet(n: usize, out: *[8][20]u8) []const [20]u8 {
    var i: usize = 0;
    while (i < n and i < 8) : (i += 1) {
        var addr = std.mem.zeroes([20]u8);
        addr[0] = @intCast(i + 1); // distinct addresses
        out[i] = addr;
    }
    return out[0..n];
}

test "1. init() produces 60 entries all with state=future" {
    const cal = SlotCalendar.init();
    try testing.expectEqual(@as(usize, 0), cal.head);
    var i: usize = 0;
    while (i < MAX_CALENDAR_SLOTS) : (i += 1) {
        try testing.expectEqual(SlotState.future, cal.entries[i].state);
    }
}

test "2. recompute() sets expected_arrival_ms correctly" {
    var cal = SlotCalendar.init();
    var vs_buf: [8][20]u8 = undefined;
    const vs = makeValidatorSet(2, &vs_buf);
    const tip_hash = std.mem.zeroes([32]u8);
    const now_ms: i64 = 10_000_000;

    cal.recompute(100, tip_hash, now_ms, vs);

    try testing.expectEqual(@as(usize, 60), MAX_CALENDAR_SLOTS);
    // slot N+1 = now + 1000
    try testing.expectEqual(@as(i64, now_ms + 1000), cal.entries[0].expected_arrival_ms);
    // slot N+2 = now + 2000
    try testing.expectEqual(@as(i64, now_ms + 2000), cal.entries[1].expected_arrival_ms);
    // slot N+60 = now + 60000
    try testing.expectEqual(@as(i64, now_ms + 60_000), cal.entries[59].expected_arrival_ms);
    // slot ids
    try testing.expectEqual(@as(u64, 101), cal.entries[0].slot_id);
    try testing.expectEqual(@as(u64, 160), cal.entries[59].slot_id);
}

test "3. leaderForSlot is deterministic" {
    var vs_buf: [8][20]u8 = undefined;
    const vs = makeValidatorSet(3, &vs_buf);
    const tip_hash = [32]u8{ 0xde, 0xad, 0xbe, 0xef, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };

    const r1 = leaderForSlot(42, tip_hash, vs);
    const r2 = leaderForSlot(42, tip_hash, vs);
    try testing.expectEqualSlices(u8, &r1, &r2);
}

test "4. leaderForSlot distributes across validator set" {
    var vs_buf: [8][20]u8 = undefined;
    const vs = makeValidatorSet(4, &vs_buf);
    const tip_hash = std.mem.zeroes([32]u8);

    // Count how many of the 60 slots go to each validator.
    var counts = [4]u32{ 0, 0, 0, 0 };
    var slot: u64 = 1;
    while (slot <= 60) : (slot += 1) {
        const leader = leaderForSlot(slot, tip_hash, vs);
        var vi: usize = 0;
        while (vi < 4) : (vi += 1) {
            if (std.mem.eql(u8, &leader, &vs[vi])) {
                counts[vi] += 1;
                break;
            }
        }
    }
    // With SHA256 distribution each validator should get roughly 15 slots.
    // Allow generous margin (5–35) to avoid flakiness without being useless.
    for (counts) |c| {
        try testing.expect(c >= 5);
        try testing.expect(c <= 35);
    }
}

test "5. finalizeSlot changes state to finalized and stores hash" {
    var cal = SlotCalendar.init();
    var vs_buf: [8][20]u8 = undefined;
    const vs = makeValidatorSet(1, &vs_buf);
    cal.recompute(10, std.mem.zeroes([32]u8), 0, vs);

    var block_hash: [32]u8 = undefined;
    @memset(&block_hash, 0xAB);
    cal.finalizeSlot(11, block_hash); // slot_id = tip+1

    try testing.expectEqual(SlotState.finalized, cal.entries[0].state);
    try testing.expectEqualSlices(u8, &block_hash, &cal.entries[0].placeholder_hash);
}

test "6. pruneMissed marks expired slots as missed" {
    var cal = SlotCalendar.init();
    var vs_buf: [8][20]u8 = undefined;
    const vs = makeValidatorSet(1, &vs_buf);
    const now_ms: i64 = 1_000_000;
    cal.recompute(0, std.mem.zeroes([32]u8), now_ms, vs);

    // entry[0] expected at now+1000=1_001_000
    // entry[1] expected at now+2000=1_002_000
    // Jump to now+5000 → entry[0] is overdue by 4s (4× interval) → missed
    //                     entry[1] is overdue by 3s (3× interval) → missed
    //                     entry[2] expected at 1_003_000, overdue 2s (2× interval) → missed
    //                     entry[3] expected at 1_004_000, overdue 1s (< 2×) → in_flight
    cal.pruneMissed(now_ms + 5_000);

    try testing.expectEqual(SlotState.missed, cal.entries[0].state);
    try testing.expectEqual(SlotState.missed, cal.entries[1].state);
    try testing.expectEqual(SlotState.missed, cal.entries[2].state);
    try testing.expectEqual(SlotState.in_flight, cal.entries[3].state);
    // entry[4] expected at 1_005_000 — not yet overdue (now == expected) → in_flight
    try testing.expectEqual(SlotState.in_flight, cal.entries[4].state);
    // entry[5] expected at 1_006_000 — still in the future
    try testing.expectEqual(SlotState.future, cal.entries[5].state);
}

test "7. getSlot returns null for slot outside window" {
    var cal = SlotCalendar.init();
    var vs_buf: [8][20]u8 = undefined;
    const vs = makeValidatorSet(1, &vs_buf);
    cal.recompute(100, std.mem.zeroes([32]u8), 0, vs);

    // Slots 101–160 are in window.
    try testing.expect(cal.getSlot(101) != null);
    try testing.expect(cal.getSlot(160) != null);
    // Slot 100 (tip) and 161 (outside) should not be found.
    try testing.expect(cal.getSlot(100) == null);
    try testing.expect(cal.getSlot(161) == null);
    // Slot 0 is definitely not in window.
    try testing.expect(cal.getSlot(0) == null);
}

test "8. recompute with empty validator_set gives zero leader_address" {
    var cal = SlotCalendar.init();
    const vs: []const [20]u8 = &[_][20]u8{};
    cal.recompute(0, std.mem.zeroes([32]u8), 0, vs);

    const zero_addr = std.mem.zeroes([20]u8);
    var i: usize = 0;
    while (i < MAX_CALENDAR_SLOTS) : (i += 1) {
        try testing.expectEqualSlices(u8, &zero_addr, &cal.entries[i].leader_address);
    }
}

test "9. ring buffer head advances past consecutive finalized entries" {
    var cal = SlotCalendar.init();
    var vs_buf: [8][20]u8 = undefined;
    const vs = makeValidatorSet(1, &vs_buf);
    cal.recompute(0, std.mem.zeroes([32]u8), 0, vs);

    try testing.expectEqual(@as(usize, 0), cal.head);

    // Finalize slots 1, 2, 3 in order.
    var hash: [32]u8 = undefined;
    @memset(&hash, 0x01);
    cal.finalizeSlot(1, hash);
    // head should advance past slot_id=1 (entries[0])
    try testing.expectEqual(@as(usize, 1), cal.head);

    @memset(&hash, 0x02);
    cal.finalizeSlot(2, hash);
    try testing.expectEqual(@as(usize, 2), cal.head);

    // Finalizing slot 4 (not consecutive with head=2 → entry[2] is slot 3)
    // shouldn't advance head because entries[2] (slot 3) is still future.
    @memset(&hash, 0x04);
    cal.finalizeSlot(4, hash);
    // head remains at 2 because entries[2] (slot 3) is not yet finalized.
    try testing.expectEqual(@as(usize, 2), cal.head);
}

test "10. toJson produces valid parsable JSON" {
    var cal = SlotCalendar.init();
    var vs_buf: [8][20]u8 = undefined;
    const vs = makeValidatorSet(2, &vs_buf);
    cal.recompute(5, std.mem.zeroes([32]u8), 12345, vs);

    const json = try cal.toJson(testing.allocator);
    defer testing.allocator.free(json);

    // Must contain key fields.
    try testing.expect(std.mem.indexOf(u8, json, "\"entries\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"slot_id\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"state\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"future\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"tip_height\":5") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"computed_at_ms\":12345") != null);
    // Must be parseable by std.json.
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expect(obj.contains("entries"));
}
