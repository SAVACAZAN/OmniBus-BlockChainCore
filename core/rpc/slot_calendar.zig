/// rpc/slot_calendar.zig — RPC handlers for the SlotCalendar module.
///
/// Exposes two JSON-RPC 2.0 methods:
///   slot_calendar  — full 60-entry calendar (no params)
///   slot_get       — single entry { "slot_id": N }
///
/// Both are read-only and access g_slot_calendar_v2 from main.zig.

const std = @import("std");
const rpc = @import("../rpc_server.zig");
const main_mod = @import("../main.zig");
const slot_calendar_mod = @import("../slot_calendar.zig");

/// `slot_calendar` — return the full pre-computed 60-slot calendar.
///
/// Response format:
///   {
///     "jsonrpc": "2.0",
///     "id": N,
///     "result": {
///       "tip_height": ...,
///       "computed_at_ms": ...,
///       "entries": [ { slot_id, leader, expected_arrival_ms,
///                       placeholder_hash, state }, ... ]
///     }
///   }
pub fn handleSlotCalendar(alloc: std.mem.Allocator, id: u64) ![]u8 {
    const calendar = &main_mod.g_slot_calendar_v2;
    const data = try calendar.toJson(alloc);
    defer alloc.free(data);

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{s}}}",
        .{ id, data },
    );
}

/// `slot_get` — return a single slot entry.
///
/// Params: `{"slot_id": N}`
///
/// Response (found):
///   { "result": { slot_id, leader, expected_arrival_ms, placeholder_hash, state } }
/// Response (not found):
///   { "result": null }
pub fn handleSlotGet(
    alloc: std.mem.Allocator,
    body: []const u8,
    id: u64,
) ![]u8 {
    // Extract "slot_id" from the params object.
    const slot_id_raw = rpc.extractParamObjectU64(body, "slot_id");
    const slot_id: u64 = slot_id_raw;

    const calendar = &main_mod.g_slot_calendar_v2;
    const entry = calendar.getSlot(slot_id);
    if (entry == null) {
        return std.fmt.allocPrint(alloc,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":null}}",
            .{id},
        );
    }

    const e = entry.?;
    const state_str: []const u8 = switch (e.state) {
        .future => "future",
        .in_flight => "in_flight",
        .finalized => "finalized",
        .missed => "missed",
    };

    var leader_hex: [40]u8 = undefined;
    _ = std.fmt.bufPrint(&leader_hex, "{s}", .{
        std.fmt.bytesToHex(e.leader_address, .lower),
    }) catch unreachable;

    var hash_hex: [64]u8 = undefined;
    _ = std.fmt.bufPrint(&hash_hex, "{s}", .{
        std.fmt.bytesToHex(e.placeholder_hash, .lower),
    }) catch unreachable;

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{" ++
        "\"slot_id\":{d}," ++
        "\"leader\":\"{s}\"," ++
        "\"expected_arrival_ms\":{d}," ++
        "\"placeholder_hash\":\"{s}\"," ++
        "\"state\":\"{s}\"}}}}",
        .{ id, e.slot_id, leader_hex, e.expected_arrival_ms, hash_hex, state_str },
    );
}
