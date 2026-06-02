/// rpc/spark.zig — SPARK Sub-Block Consensus RPC handlers
///
/// spark_status  — returns consensus state for the last block
/// spark_votes   — returns votes array for a given block_hash
const std = @import("std");
const rpc = @import("../rpc_server.zig");
const spark = @import("../spark_consensus.zig");
const hex_utils = @import("../hex_utils.zig");

const ServerCtx = rpc.ServerCtx;

// ─── spark_status ────────────────────────────────────────────────────────────

/// Returns consensus state for the last finalized block:
///   { block_hash, attest_count, reject_count, trust, votes: [{layer,kind,reason}…] }
pub fn handleSparkStatus(alloc: std.mem.Allocator, ctx: *ServerCtx, id: u64) ![]u8 {
    _ = ctx; // state is read from global ring buffer
    const maybe_state = spark.lastState();
    if (maybe_state == null) {
        return std.fmt.allocPrint(alloc,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"status\":\"no_data\",\"message\":\"No SPARK state recorded yet\"}}}}",
            .{id});
    }
    const state = maybe_state.?;
    return fmtConsensusState(alloc, id, &state);
}

// ─── spark_votes ─────────────────────────────────────────────────────────────

/// Returns votes for a specific block_hash.
/// Params (JSON-RPC body): {"method":"spark_votes","params":{"block_hash":"<64 hex>"}}
pub fn handleSparkVotes(alloc: std.mem.Allocator, body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    _ = ctx;
    // Extract block_hash using the same extractStr helper used by all other handlers
    const block_hash_hex = rpc.extractStr(body, "block_hash") orelse
        return rpc.errorJson(-32602, "Missing param: block_hash", id, alloc);

    if (block_hash_hex.len != 64)
        return rpc.errorJson(-32602, "block_hash must be 64 hex chars", id, alloc);

    var hash_bytes: [32]u8 = undefined;
    hex_utils.hexToBytes(block_hash_hex, &hash_bytes) catch
        return rpc.errorJson(-32602, "block_hash: invalid hex", id, alloc);

    const maybe_state = spark.findByHash(hash_bytes);
    if (maybe_state == null) {
        return std.fmt.allocPrint(alloc,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"error\":{{\"code\":-32000,\"message\":\"Block hash not in SPARK history\"}}}}",
            .{id});
    }
    return fmtConsensusState(alloc, id, &maybe_state.?);
}

// ─── JSON formatting helper ───────────────────────────────────────────────────

fn fmtConsensusState(alloc: std.mem.Allocator, id: u64, state: *const spark.BlockConsensusState) ![]u8 {
    // Encode block_hash as hex string
    const bh_hex = std.fmt.bytesToHex(state.block_hash, .lower);
    const trust_str = @tagName(state.trust);

    // Build votes JSON array
    var votes_buf = std.array_list.Managed(u8).init(alloc);
    defer votes_buf.deinit();
    try votes_buf.appendSlice("[");
    var first = true;
    for (state.votes) |maybe_vote| {
        const vote = maybe_vote orelse continue;
        if (!first) try votes_buf.appendSlice(",");
        first = false;
        const kind_str = @tagName(vote.kind);
        const layer_str = @tagName(vote.layer);
        // Extract reason (trim trailing zeros)
        var reason_len: usize = 0;
        for (vote.reason) |b| {
            if (b == 0) break;
            reason_len += 1;
        }
        const reason = vote.reason[0..reason_len];
        try votes_buf.appendSlice(try std.fmt.allocPrint(alloc,
            "{{\"layer\":\"{s}\",\"kind\":\"{s}\",\"reason\":\"{s}\"}}",
            .{ layer_str, kind_str, reason }));
    }
    try votes_buf.appendSlice("]");

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{" ++
        "\"block_hash\":\"{s}\"," ++
        "\"attest_count\":{d}," ++
        "\"reject_count\":{d}," ++
        "\"trust\":\"{s}\"," ++
        "\"votes\":{s}" ++
        "}}}}",
        .{
            id,
            bh_hex,
            state.attest_count,
            state.reject_count,
            trust_str,
            votes_buf.items,
        });
}
