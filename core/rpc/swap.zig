// Atomic-swap / HTLC / cross-chain bridge JSON-RPC handlers.
//
// Three sub-domains:
//   swap_*     — multi-hop atomic swap orchestration
//   intent_*   — order intents (post → fill → settle)
//   htlc_*     — Hash-Time-Locked Contract primitives
//   bridge_*   — native Bitcoin/Ethereum bridge
//   omnibus_bridge — bridge router aggregator

const std = @import("std");
const rpc = @import("../rpc_server.zig");
const blockchain_mod = @import("../blockchain.zig");
const htlc_mod = @import("../htlc.zig");
const htlc_btc_mod = @import("../htlc_btc.zig");
const bridge_mod = @import("../bridge_native.zig");
const swap_link_mod = @import("../order_swap_link.zig");
const intent_mod = @import("../intent_registry.zig");
const transaction_mod = @import("../transaction.zig");
const tx_payload_mod = @import("../tx_payload.zig");
const chain_config = @import("../chain_config.zig");
const hex_utils = @import("../hex_utils.zig");

const ServerCtx = rpc.ServerCtx;

/// swap_open — register a SwapBinding for an existing order_place TX.
/// Params: order_id, taker_chain (1=btc,2=eth,3=base,4=liberty), taker_htlc_ref (hex up to 80 chars),
///   hash_lock (64 hex), timeout (u64 block height).
pub fn handleSwapOpen(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const order_id = rpc.extractU64Param(body, "\"order_id\"") orelse
        return rpc.errorJson(-32602, "Missing param: order_id", id, alloc);
    const taker_chain_u = rpc.extractU64Param(body, "\"taker_chain\"") orelse
        return rpc.errorJson(-32602, "Missing param: taker_chain", id, alloc);
    if (taker_chain_u > 4 or taker_chain_u == 0)
        return rpc.errorJson(-32602, "taker_chain must be 1=btc, 2=eth, 3=base, 4=liberty", id, alloc);
    const taker_chain = swap_link_mod.Chain.fromU8(@intCast(taker_chain_u)) orelse
        return rpc.errorJson(-32602, "Bad taker_chain", id, alloc);

    const ref_hex = rpc.extractStr(body, "taker_htlc_ref") orelse
        return rpc.errorJson(-32602, "Missing param: taker_htlc_ref", id, alloc);
    // max 122 hex chars = 61 bytes (full EthRef: 1 tag + 8 chain_id + 20 contract + 32 id)
    if (ref_hex.len > 122 or ref_hex.len % 2 != 0)
        return rpc.errorJson(-32602, "taker_htlc_ref bad length (max 122 hex chars)", id, alloc);
    var ref_bytes: [61]u8 = std.mem.zeroes([61]u8);
    {
        var i: usize = 0;
        while (i < ref_hex.len / 2) : (i += 1) {
            const hi = hex_utils.charToNibble(ref_hex[i * 2]) catch
                return rpc.errorJson(-32602, "Bad hex in taker_htlc_ref", id, alloc);
            const lo = hex_utils.charToNibble(ref_hex[i * 2 + 1]) catch
                return rpc.errorJson(-32602, "Bad hex in taker_htlc_ref", id, alloc);
            ref_bytes[i] = (@as(u8, hi) << 4) | @as(u8, lo);
        }
    }

    const hash_lock_hex = rpc.extractStr(body, "hash_lock") orelse
        return rpc.errorJson(-32602, "Missing param: hash_lock", id, alloc);
    const hash_lock = rpc.parseHex32(hash_lock_hex) orelse
        return rpc.errorJson(-32602, "Bad hash_lock (need 64 hex chars)", id, alloc);

    const timeout = rpc.extractU64Param(body, "\"timeout\"") orelse
        return rpc.errorJson(-32602, "Missing param: timeout", id, alloc);

    const maker_ref = swap_link_mod.HtlcRef{ .omnibus = hash_lock };
    // Decode taker_htlc_ref using HtlcRef wire format (tagged, 61B)
    const taker_ref: swap_link_mod.HtlcRef = switch (taker_chain) {
        .btc => blk: {
            var txid: [32]u8 = undefined;
            @memcpy(&txid, ref_bytes[0..32]);
            const vout = std.mem.readInt(u32, ref_bytes[32..36], .little);
            break :blk swap_link_mod.HtlcRef{ .btc = .{ .txid = txid, .vout = vout } };
        },
        .eth, .base, .liberty => blk: {
            const chain_id = std.mem.readInt(u64, ref_bytes[0..8], .little);
            var contract: [20]u8 = undefined;
            @memcpy(&contract, ref_bytes[8..28]);
            var hid: [32]u8 = std.mem.zeroes([32]u8);
            @memcpy(&hid, ref_bytes[28..60]);
            break :blk swap_link_mod.HtlcRef{ .eth = .{
                .chain_id = chain_id,
                .contract = contract,
                .id = hid,
            } };
        },
        .omnibus => unreachable,
    };

    const current_block: u64 = ctx.bc.getBlockCount();
    ctx.bc.swap_registry.open(order_id, hash_lock, .omnibus, taker_chain,
        maker_ref, taker_ref, timeout, current_block) catch |err| {
        return rpc.errorJson(-32000, @errorName(err), id, alloc);
    };

    var sid_hex_buf: [64]u8 = undefined;
    rpc.hex32(hash_lock, &sid_hex_buf);
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"swap_id\":\"{s}\",\"state\":\"pending\"}}}}",
        .{ id, sid_hex_buf[0..] });
}

/// swap_status — read state for a given swap_id.
pub fn handleSwapStatus(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const sid_hex = rpc.extractStr(body, "swap_id") orelse
        return rpc.errorJson(-32602, "Missing param: swap_id", id, alloc);
    const sid = rpc.parseHex32(sid_hex) orelse
        return rpc.errorJson(-32602, "Bad swap_id", id, alloc);
    const b = ctx.bc.swap_registry.find(sid) orelse
        return rpc.errorJson(-32004, "Binding not found", id, alloc);
    var sid_hex_buf: [64]u8 = undefined;
    rpc.hex32(b.swap_id, &sid_hex_buf);
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"swap_id\":\"{s}\",\"order_id\":{d},\"state\":\"{s}\",\"maker_chain\":\"{s}\",\"taker_chain\":\"{s}\",\"timeout_block\":{d},\"created_block\":{d}}}}}",
        .{ id, sid_hex_buf[0..], b.order_id, rpc.stateName(b.state),
           rpc.chainName(b.maker_chain), rpc.chainName(b.taker_chain),
           b.timeout_block, b.created_block });
}

/// swap_listOpen — list bindings whose state is .pending or .both_locked.
/// (Address filter is accepted but ignored — frontend filters client-side
/// until matching_engine cross-ref by trader is exposed.)
pub fn handleSwapListOpen(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    _ = body;
    const alloc = ctx.allocator;
    var buf = std.ArrayList(u8){};
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, "[");
    var first = true;
    var i: u32 = 0;
    while (i < ctx.bc.swap_registry.count) : (i += 1) {
        const b = &ctx.bc.swap_registry.entries[i];
        if (b.state != .pending and b.state != .both_locked) continue;
        if (!first) try buf.appendSlice(alloc, ",");
        first = false;
        var item_hex: [64]u8 = undefined;
        rpc.hex32(b.swap_id, &item_hex);
        const piece = try std.fmt.allocPrint(alloc,
            "{{\"swap_id\":\"{s}\",\"order_id\":{d},\"state\":\"{s}\",\"maker_chain\":\"{s}\",\"taker_chain\":\"{s}\",\"timeout_block\":{d}}}",
            .{ item_hex[0..], b.order_id, rpc.stateName(b.state),
               rpc.chainName(b.maker_chain), rpc.chainName(b.taker_chain), b.timeout_block });
        defer alloc.free(piece);
        try buf.appendSlice(alloc, piece);
    }
    try buf.appendSlice(alloc, "]");
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{s}}}", .{ id, buf.items });
}

/// swap_lockMaker — confirm the maker-side HTLC is funded on its chain.
/// Params: swap_id (64 hex), htlc_ref (122 hex, HtlcRef wire format).
/// Transitions: pending → pending (sets maker_htlc_ref). Both legs needed
/// before state moves to both_locked.
pub fn handleSwapLockMaker(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const sid_hex = rpc.extractStr(body, "swap_id") orelse
        return rpc.errorJson(-32602, "Missing param: swap_id", id, alloc);
    const sid = rpc.parseHex32(sid_hex) orelse
        return rpc.errorJson(-32602, "Bad swap_id (need 64 hex)", id, alloc);
    const ref_hex = rpc.extractStr(body, "htlc_ref") orelse
        return rpc.errorJson(-32602, "Missing param: htlc_ref", id, alloc);
    if (ref_hex.len > 122 or ref_hex.len % 2 != 0)
        return rpc.errorJson(-32602, "htlc_ref bad length", id, alloc);
    var rb: [61]u8 = std.mem.zeroes([61]u8);
    _ = hex_utils.hexToBytes(ref_hex, rb[0 .. ref_hex.len / 2]) catch
        return rpc.errorJson(-32602, "Bad hex in htlc_ref", id, alloc);
    const ref = swap_link_mod.HtlcRef.decode(&rb) orelse
        return rpc.errorJson(-32602, "Cannot decode htlc_ref", id, alloc);
    ctx.bc.swap_registry.lockMaker(sid, ref) catch |err|
        return rpc.errorJson(-32000, @errorName(err), id, alloc);
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"swap_id\":\"{s}\",\"leg\":\"maker\",\"locked\":true}}}}",
        .{ id, sid_hex });
}

/// swap_lockTaker — confirm the taker-side HTLC is funded. After both legs
/// locked the binding transitions to .both_locked.
/// Params: swap_id (64 hex), htlc_ref (122 hex).
pub fn handleSwapLockTaker(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const sid_hex = rpc.extractStr(body, "swap_id") orelse
        return rpc.errorJson(-32602, "Missing param: swap_id", id, alloc);
    const sid = rpc.parseHex32(sid_hex) orelse
        return rpc.errorJson(-32602, "Bad swap_id (need 64 hex)", id, alloc);
    const ref_hex = rpc.extractStr(body, "htlc_ref") orelse
        return rpc.errorJson(-32602, "Missing param: htlc_ref", id, alloc);
    if (ref_hex.len > 122 or ref_hex.len % 2 != 0)
        return rpc.errorJson(-32602, "htlc_ref bad length", id, alloc);
    var rb: [61]u8 = std.mem.zeroes([61]u8);
    _ = hex_utils.hexToBytes(ref_hex, rb[0 .. ref_hex.len / 2]) catch
        return rpc.errorJson(-32602, "Bad hex in htlc_ref", id, alloc);
    const ref = swap_link_mod.HtlcRef.decode(&rb) orelse
        return rpc.errorJson(-32602, "Cannot decode htlc_ref", id, alloc);
    ctx.bc.swap_registry.lockTaker(sid, ref) catch |err|
        return rpc.errorJson(-32000, @errorName(err), id, alloc);

    // After lockTaker the binding moves to .both_locked — check and persist.
    const b = ctx.bc.swap_registry.find(sid);
    const state_str = if (b) |binding| rpc.stateName(binding.state) else "both_locked";
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"swap_id\":\"{s}\",\"leg\":\"taker\",\"locked\":true,\"state\":\"{s}\"}}}}",
        .{ id, sid_hex, state_str });
}

/// swap_timeout — mark a binding as timed_out when current block >= timeout_block.
/// Params: swap_id (64 hex).
pub fn handleSwapTimeout(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const sid_hex = rpc.extractStr(body, "swap_id") orelse
        return rpc.errorJson(-32602, "Missing param: swap_id", id, alloc);
    const sid = rpc.parseHex32(sid_hex) orelse
        return rpc.errorJson(-32602, "Bad swap_id (need 64 hex)", id, alloc);
    const current_block: u64 = ctx.bc.getBlockCount();
    ctx.bc.swap_registry.timeout(sid, current_block) catch |err|
        return rpc.errorJson(-32000, @errorName(err), id, alloc);
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"swap_id\":\"{s}\",\"state\":\"timed_out\",\"current_block\":{d}}}}}",
        .{ id, sid_hex, current_block });
}

pub fn handleSwapProveSettle(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const sid_hex = rpc.extractStr(body, "swap_id") orelse
        return rpc.errorJson(-32602, "Missing param: swap_id", id, alloc);
    const sid = rpc.parseHex32(sid_hex) orelse
        return rpc.errorJson(-32602, "Bad swap_id", id, alloc);
    const pre_hex = rpc.extractStr(body, "preimage") orelse
        return rpc.errorJson(-32602, "Missing param: preimage", id, alloc);
    const preimage = rpc.parseHex32(pre_hex) orelse
        return rpc.errorJson(-32602, "Bad preimage", id, alloc);

    // Detect new (object) vs legacy (string) form for spv_proof_blob.
    if (rpc.findJsonObject(body, "spv_proof_blob")) |obj| {
        if (!rpc.verifySpvProofJson(obj)) {
            return rpc.errorJson(-32030, "SPV proof invalid", id, alloc);
        }
    } else {
        const blob = rpc.extractStr(body, "spv_proof_blob") orelse "";
        if (blob.len > 0) {
            std.debug.print(
                "[swap_proveSettle] DEPRECATED: legacy flat spv_proof_blob string accepted; clients should migrate to JSON object form.\n",
                .{},
            );
            if (!rpc.verifySpvProofBlob(blob)) {
                return rpc.errorJson(-32030, "SPV proof invalid", id, alloc);
            }
        } else {
            std.debug.print(
                "[swap_proveSettle] WARNING: dev-mode preimage-only settlement (no spv_proof_blob). DO NOT use on mainnet.\n",
                .{},
            );
        }
    }

    const cur = ctx.bc.swap_registry.find(sid) orelse
        return rpc.errorJson(-32004, "Binding not found", id, alloc);
    if (cur.state == .pending) {
        ctx.bc.swap_registry.lockTaker(sid, cur.taker_htlc_ref) catch |err| {
            return rpc.errorJson(-32000, @errorName(err), id, alloc);
        };
    }
    ctx.bc.swap_registry.settle(sid, preimage) catch |err| {
        return rpc.errorJson(-32003, @errorName(err), id, alloc);
    };
    var sid_hex_buf: [64]u8 = undefined;
    rpc.hex32(sid, &sid_hex_buf);
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"swap_id\":\"{s}\",\"state\":\"claimed\"}}}}",
        .{ id, sid_hex_buf[0..] });
}

// intent_* — build, sign, and broadcast the corresponding 0x40/0x41/0x43
// typed TXs through the mempool. State-machine effects land at applyBlock
// time via blockchain.applyIntentTx.

/// `intent_post({intent_id?, swap_id, taker_chain, expiry_block,
/// maker_amount_sat, taker_min_sat?})` — TX type 0x40. If `intent_id` is
/// omitted, derives it from sha256("intent" || swap_id || expiry || from).
pub fn handleIntentPost(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const swap_id_hex = rpc.extractStr(body, "swap_id")
        orelse return rpc.errorJson(-32602, "missing swap_id", id, alloc);
    const swap_id = rpc.parseHex32(swap_id_hex)
        orelse return rpc.errorJson(-32602, "swap_id must be 64 hex chars", id, alloc);

    const taker_chain_u = rpc.extractU64Param(body, "\"taker_chain\"")
        orelse return rpc.errorJson(-32602, "missing taker_chain", id, alloc);
    if (taker_chain_u > 3) return rpc.errorJson(-32602, "taker_chain must be 0..3", id, alloc);

    const expiry_block = rpc.extractU64Param(body, "\"expiry_block\"") orelse rpc.extractU64Param(body, "\"expiry\"")
        orelse return rpc.errorJson(-32602, "missing expiry_block", id, alloc);
    if (expiry_block == 0 or expiry_block > std.math.maxInt(u32))
        return rpc.errorJson(-32602, "expiry_block out of range", id, alloc);

    const maker_amount_sat = rpc.extractU64Param(body, "\"maker_amount_sat\"") orelse rpc.extractU64Param(body, "\"amount_sat\"")
        orelse return rpc.errorJson(-32602, "missing maker_amount_sat", id, alloc);
    const taker_min_sat = rpc.extractU64Param(body, "\"taker_min_sat\"") orelse 0;

    var intent_id: [32]u8 = undefined;
    if (rpc.extractStr(body, "intent_id")) |iid_hex| {
        intent_id = rpc.parseHex32(iid_hex)
            orelse return rpc.errorJson(-32602, "intent_id must be 64 hex chars", id, alloc);
    } else {
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update("intent");
        hasher.update(&swap_id);
        var eb: [8]u8 = undefined;
        std.mem.writeInt(u64, &eb, expiry_block, .little);
        hasher.update(&eb);
        hasher.update(ctx.wallet.address);
        hasher.final(&intent_id);
    }

    const payload = tx_payload_mod.IntentPostPayload{
        .intent_id = intent_id,
        .swap_id = swap_id,
        .expiry_block = @intCast(expiry_block),
        .taker_chain = @intCast(taker_chain_u),
        .maker_amount_sat = maker_amount_sat,
        .taker_min_sat = taker_min_sat,
    };
    payload.validate() catch return rpc.errorJson(-32602, "invalid intent_post payload", id, alloc);

    var data_buf: [tx_payload_mod.IntentPostPayload.WIRE_SIZE]u8 = undefined;
    _ = try payload.encode(&data_buf);

    const tx_hash = rpc.submitIntentTx(ctx, .intent_post, &data_buf) catch |err| {
        std.debug.print("[INTENT-POST] submit failed: {}\n", .{err});
        return rpc.errorJson(-32000, "intent_post submit failed", id, alloc);
    };
    defer alloc.free(tx_hash);

    var iid_hex: [64]u8 = undefined; rpc.writeHex32(intent_id, &iid_hex);
    var sid_hex_out: [64]u8 = undefined; rpc.writeHex32(swap_id, &sid_hex_out);
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"tx_hash\":\"{s}\",\"intent_id\":\"{s}\",\"swap_id\":\"{s}\",\"expiry_block\":{d}}}}}",
        .{ id, tx_hash, &iid_hex, &sid_hex_out, expiry_block });
}

/// `intent_fill_commit({intent_id, bond_locked_sat})` — TX type 0x41.
/// Solver locks bond on Omnibus, claiming the right to fill the intent.
pub fn handleIntentFillCommit(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const iid_hex = rpc.extractStr(body, "intent_id")
        orelse return rpc.errorJson(-32602, "missing intent_id", id, alloc);
    const intent_id = rpc.parseHex32(iid_hex)
        orelse return rpc.errorJson(-32602, "intent_id must be 64 hex chars", id, alloc);
    const bond = rpc.extractU64Param(body, "\"bond_locked_sat\"") orelse rpc.extractU64Param(body, "\"bond\"")
        orelse return rpc.errorJson(-32602, "missing bond_locked_sat", id, alloc);
    if (bond == 0) return rpc.errorJson(-32602, "bond_locked_sat must be > 0", id, alloc);

    const payload = tx_payload_mod.IntentFillCommitPayload{
        .intent_id = intent_id,
        .bond_locked_sat = bond,
        .commit_block = ctx.bc.getBlockCount(),
    };
    payload.validate() catch return rpc.errorJson(-32602, "invalid intent_fill_commit payload", id, alloc);

    var data_buf: [tx_payload_mod.IntentFillCommitPayload.WIRE_SIZE]u8 = undefined;
    _ = try payload.encode(&data_buf);

    const tx_hash = rpc.submitIntentTx(ctx, .intent_fill_commit, &data_buf) catch |err| {
        std.debug.print("[INTENT-FILL-COMMIT] submit failed: {}\n", .{err});
        return rpc.errorJson(-32000, "intent_fill_commit submit failed", id, alloc);
    };
    defer alloc.free(tx_hash);

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"tx_hash\":\"{s}\",\"intent_id\":\"{s}\",\"bond_locked_sat\":{d}}}}}",
        .{ id, tx_hash, iid_hex, bond });
}

/// intent_settle alias preserved — delegates to swap_proveSettle (0x42).
pub fn handleIntentSettle(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    return handleSwapProveSettle(body, ctx, id);
}

/// `intent_timeout({intent_id, slashed_bond_sat?, swap_id?})` — TX type 0x43.
/// Optionally also nudges swap_registry.timeout(swap_id) for legacy callers
/// that only knew about swap_id; the in-memory call is now redundant with
/// the on-chain effect of applyIntentTx but kept for backward compat.
pub fn handleIntentTimeout(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const iid_hex = rpc.extractStr(body, "intent_id")
        orelse return rpc.errorJson(-32602, "missing intent_id", id, alloc);
    const intent_id = rpc.parseHex32(iid_hex)
        orelse return rpc.errorJson(-32602, "intent_id must be 64 hex chars", id, alloc);
    const slashed = rpc.extractU64Param(body, "\"slashed_bond_sat\"") orelse 0;

    if (rpc.extractStr(body, "swap_id")) |sid_hex| {
        if (rpc.parseHex32(sid_hex)) |sid| {
            ctx.bc.swap_registry.timeout(sid, ctx.bc.getBlockCount()) catch {};
        }
    }

    const payload = tx_payload_mod.IntentTimeoutPayload{
        .intent_id = intent_id,
        .slashed_bond_sat = slashed,
    };
    payload.validate() catch return rpc.errorJson(-32602, "invalid intent_timeout payload", id, alloc);

    var data_buf: [tx_payload_mod.IntentTimeoutPayload.WIRE_SIZE]u8 = undefined;
    _ = try payload.encode(&data_buf);

    const tx_hash = rpc.submitIntentTx(ctx, .intent_timeout, &data_buf) catch |err| {
        std.debug.print("[INTENT-TIMEOUT] submit failed: {}\n", .{err});
        return rpc.errorJson(-32000, "intent_timeout submit failed", id, alloc);
    };
    defer alloc.free(tx_hash);

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"tx_hash\":\"{s}\",\"intent_id\":\"{s}\",\"slashed_bond_sat\":{d}}}}}",
        .{ id, tx_hash, iid_hex, slashed });
}

/// omnibus_getbridgestatus — real bridge state from BridgeState
pub fn handleOmnibusBridge(ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    ctx.bridge_mutex.lock();
    defer ctx.bridge_mutex.unlock();
    const bs = ctx.bridge orelse return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"error\":{{\"code\":-32001,\"message\":\"Bridge not initialized\"}}}}",
        .{id},
    );
    const height = ctx.bc.getBlockCount();
    const daily  = bs.dailyVolumeSat(height);
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{" ++
        "\"bridge_active\":{s}," ++
        "\"paused\":{s}," ++
        "\"paused_at_height\":{d}," ++
        "\"locked_total_sat\":{d}," ++
        "\"daily_volume_sat\":{d}," ++
        "\"lock_count\":{d}," ++
        "\"pending_unlock_count\":{d}," ++
        "\"vault_addr\":\"{s}\"" ++
        "}}}}",
        .{
            id,
            if (!bs.paused) "true" else "false",
            if (bs.paused) "true" else "false",
            bs.paused_at_height,
            bs.locked_total_sat,
            daily,
            bs.locks.items.len,
            bs.pending_unlocks.count(),
            chain_config.BRIDGE_VAULT_ADDR_HEX,
        },
    );
}

/// bridge_lock — user locks OMNI in vault to bridge to destination chain.
/// Params: {address, amount_sat, destination_chain, destination_addr}
/// Validates caps + creates LockRecord. The TX itself must be submitted
/// separately via sendtransaction with op_return memo "bridge_lock:<nonce_hex>".
/// This endpoint pre-validates and returns the nonce the user must embed.
pub fn handleBridgeLock(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    ctx.bridge_mutex.lock();
    defer ctx.bridge_mutex.unlock();
    const bs = ctx.bridge orelse return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"error\":{{\"code\":-32001,\"message\":\"Bridge not initialized\"}}}}",
        .{id},
    );

    // Parse params
    const amount_sat = rpc.extractU64Param(body, "\"amount_sat\"") orelse
        return rpc.errorJson(-32602, "Missing param: amount_sat", id, alloc);
    const dest_chain = rpc.extractStrParam(body, "\"destination_chain\"") orelse
        return rpc.errorJson(-32602, "Missing param: destination_chain", id, alloc);
    const dest_addr  = rpc.extractStrParam(body, "\"destination_addr\"") orelse
        return rpc.errorJson(-32602, "Missing param: destination_addr", id, alloc);

    const height = ctx.bc.getBlockCount();
    bs.validateLock(amount_sat, height) catch |err| {
        const msg = switch (err) {
            error.AmountExceedsPerTxCap   => "Amount exceeds per-tx cap",
            error.AmountExceedsDailyQuota => "Daily quota exceeded",
            error.AutoPauseActive         => "Bridge auto-paused (anomaly detected)",
            else                          => "Bridge lock validation failed",
        };
        return rpc.errorJson(-32003, msg, id, alloc);
    };

    // Build nonce = SHA256(dest_chain || dest_addr || amount || height)
    var nonce_input: [128]u8 = undefined;
    const ni_len = std.fmt.bufPrint(&nonce_input, "{s}{s}{d}{d}", .{ dest_chain, dest_addr, amount_sat, height }) catch
        return rpc.errorJson(-32003, "Nonce input overflow", id, alloc);
    var nonce: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(ni_len, &nonce, .{});

    const nonce_hex = std.fmt.bytesToHex(nonce, .lower);

    const cap = chain_config.BRIDGE_MAX_PER_TX_SAT;
    const daily_cap = chain_config.BRIDGE_MAX_DAILY_SAT;
    const vault = chain_config.BRIDGE_VAULT_ADDR_HEX;

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{" ++
        "\"status\":\"pre_validated\"," ++
        "\"nonce\":\"{s}\"," ++
        "\"amount_sat\":{d}," ++
        "\"destination_chain\":\"{s}\"," ++
        "\"destination_addr\":\"{s}\"," ++
        "\"vault_addr\":\"{s}\"," ++
        "\"max_per_tx_sat\":{d}," ++
        "\"max_daily_sat\":{d}," ++
        "\"instruction\":\"Send amount_sat to vault_addr with op_return memo bridge_lock:<nonce>\"" ++
        "}}}}",
        .{
            id, nonce_hex, amount_sat,
            dest_chain[0..@min(dest_chain.len, 32)],
            dest_addr[0..@min(dest_addr.len, 42)],
            vault, cap, daily_cap,
        },
    );
}

/// bridge_unlock_request — relayer submits a multi-sig unlock for a burn event on dest chain.
/// Params: {signer_addr (20-byte hex), recipient_addr (20-byte hex), amount_sat, nonce_hex, relayer_sig}
pub fn handleBridgeUnlockRequest(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    ctx.bridge_mutex.lock();
    defer ctx.bridge_mutex.unlock();
    const bs = ctx.bridge orelse return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"error\":{{\"code\":-32001,\"message\":\"Bridge not initialized\"}}}}",
        .{id},
    );

    const signer_hex   = rpc.extractStrParam(body, "\"signer_addr\"")   orelse return rpc.errorJson(-32602, "Missing param: signer_addr",   id, alloc);
    const recipient_hex= rpc.extractStrParam(body, "\"recipient_addr\"") orelse return rpc.errorJson(-32602, "Missing param: recipient_addr", id, alloc);
    const amount_sat   = rpc.extractU64Param(body, "\"amount_sat\"")    orelse return rpc.errorJson(-32602, "Missing param: amount_sat",     id, alloc);
    const nonce_hex_s  = rpc.extractStrParam(body, "\"nonce\"")         orelse return rpc.errorJson(-32602, "Missing param: nonce",          id, alloc);

    // Decode hex → fixed arrays
    var signer:    [20]u8 = std.mem.zeroes([20]u8);
    var recipient: [20]u8 = std.mem.zeroes([20]u8);
    var nonce:     [32]u8 = std.mem.zeroes([32]u8);

    if (signer_hex.len >= 40)    _ = std.fmt.hexToBytes(signer[0..], signer_hex[0..40])    catch {};
    if (recipient_hex.len >= 40) _ = std.fmt.hexToBytes(recipient[0..], recipient_hex[0..40]) catch {};
    if (nonce_hex_s.len >= 64)   _ = std.fmt.hexToBytes(nonce[0..], nonce_hex_s[0..64])   catch {};

    const height = ctx.bc.getBlockCount();
    bs.submitUnlockSignature(signer, recipient, amount_sat, nonce, height) catch |err| {
        const msg = switch (err) {
            error.AutoPauseActive         => "Bridge auto-paused",
            error.NonceAlreadyProcessed   => "Nonce already processed",
            error.SignerNotInRelayerSet   => "Signer not in relayer set",
            error.InsufficientVaultBalance=> "Insufficient vault balance",
            error.DuplicateSignature      => "Duplicate relayer signature",
            else                          => "Unlock request failed",
        };
        return rpc.errorJson(-32003, msg, id, alloc);
    };

    const entry = bs.pending_unlocks.get(nonce);
    const sig_count: u8 = if (entry) |e| e.sig_count else 0;
    const required   = chain_config.BRIDGE_REQUIRED_SIGS;
    const window     = chain_config.BRIDGE_CHALLENGE_WINDOW_BLOCKS;

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{" ++
        "\"status\":\"signature_recorded\"," ++
        "\"sig_count\":{d}," ++
        "\"required_sigs\":{d}," ++
        "\"threshold_reached\":{s}," ++
        "\"challenge_window_blocks\":{d}," ++
        "\"settles_after_height\":{d}" ++
        "}}}}",
        .{
            id, sig_count, required,
            if (sig_count >= required) "true" else "false",
            window, height + window,
        },
    );
}

/// bridge_fraud_challenge — anyone can void a pending unlock with a fraud proof.
/// Params: {nonce_hex, proof} (proof is logged but not cryptographically verified in V1)
pub fn handleBridgeFraudChallenge(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    ctx.bridge_mutex.lock();
    defer ctx.bridge_mutex.unlock();
    const bs = ctx.bridge orelse return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"error\":{{\"code\":-32001,\"message\":\"Bridge not initialized\"}}}}",
        .{id},
    );

    const nonce_hex_s = rpc.extractStrParam(body, "\"nonce\"") orelse
        return rpc.errorJson(-32602, "Missing param: nonce", id, alloc);

    var nonce: [32]u8 = std.mem.zeroes([32]u8);
    if (nonce_hex_s.len >= 64) _ = std.fmt.hexToBytes(nonce[0..], nonce_hex_s[0..64]) catch {};

    bs.voidUnlock(nonce) catch |err| {
        const msg = switch (err) {
            error.NonceAlreadyProcessed => "Nonce already processed or settled",
            else                        => "Fraud challenge failed",
        };
        return rpc.errorJson(-32003, msg, id, alloc);
    };

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"status\":\"voided\",\"nonce\":\"{s}\"}}}}",
        .{ id, nonce_hex_s[0..@min(nonce_hex_s.len, 64)] },
    );
}

/// bridge_settle — try to settle a pending unlock after challenge window.
/// Relayers call this; if threshold sigs present and window expired, funds release.
pub fn handleBridgeSettle(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    ctx.bridge_mutex.lock();
    defer ctx.bridge_mutex.unlock();
    const bs = ctx.bridge orelse return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"error\":{{\"code\":-32001,\"message\":\"Bridge not initialized\"}}}}",
        .{id},
    );

    const nonce_hex_s = rpc.extractStrParam(body, "\"nonce\"") orelse
        return rpc.errorJson(-32602, "Missing param: nonce", id, alloc);

    var nonce: [32]u8 = std.mem.zeroes([32]u8);
    if (nonce_hex_s.len >= 64) _ = std.fmt.hexToBytes(nonce[0..], nonce_hex_s[0..64]) catch {};

    const height = ctx.bc.getBlockCount();
    const result = bs.trySettle(nonce, height) catch |err| {
        const msg = switch (err) {
            error.InsufficientSignatures     => "Not enough relayer signatures",
            error.ChallengeWindowNotExpired  => "Challenge window still open",
            error.InsufficientVaultBalance   => "Insufficient vault balance",
            error.NonceAlreadyProcessed      => "Already settled or voided",
            else                             => "Settlement failed",
        };
        return rpc.errorJson(-32003, msg, id, alloc);
    };

    if (result) |r| {
        const addr_hex = std.fmt.bytesToHex(r.recipient, .lower);
        return std.fmt.allocPrint(alloc,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"status\":\"settled\",\"recipient\":\"0x{s}\",\"amount_sat\":{d}}}}}",
            .{ id, addr_hex, r.amount_sat },
        );
    } else {
        return std.fmt.allocPrint(alloc,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"status\":\"not_ready\"}}}}",
            .{id},
        );
    }
}

/// htlc_btc_buildScript — build a Bitcoin HTLC P2WSH redeem script + bech32 address.
///
/// This is a pure off-chain helper for atomic swaps with the Omnibus chain. The
/// returned script + address let a TS client construct a funding TX (PSBT) for
/// the user's external Bitcoin wallet (Electrum / hardware) to sign and broadcast.
/// No Bitcoin network state is touched.
///
/// Params:
///   recipient_pk : 33-byte compressed pubkey (hex)  — claims with preimage
///   sender_pk    : 33-byte compressed pubkey (hex)  — refunds after timeout
///   hash_lock    : 32-byte SHA256(preimage) (hex)
///   timelock     : absolute block height (CLTV)
///   network      : "mainnet" | "testnet" | "regtest" | "signet"
///
/// Result: { redeem_script_hex, p2wsh_address, witness_program_hex, network, hrp }
pub fn handleHtlcBtcBuildScript(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;

    const recipient_hex = rpc.extractStrParam(body, "\"recipient_pk\"") orelse
        return rpc.errorJson(-32602, "Missing param: recipient_pk", id, alloc);
    const sender_hex = rpc.extractStrParam(body, "\"sender_pk\"") orelse
        return rpc.errorJson(-32602, "Missing param: sender_pk", id, alloc);
    const hash_hex = rpc.extractStrParam(body, "\"hash_lock\"") orelse
        return rpc.errorJson(-32602, "Missing param: hash_lock", id, alloc);
    const timelock = rpc.extractU64Param(body, "\"timelock\"") orelse
        return rpc.errorJson(-32602, "Missing param: timelock", id, alloc);
    const network_str = rpc.extractStrParam(body, "\"network\"") orelse "mainnet";

    if (timelock == 0 or timelock > std.math.maxInt(u32))
        return rpc.errorJson(-32602, "Invalid timelock (must be 1..u32::MAX)", id, alloc);

    const network = htlc_btc_mod.Network.fromStr(network_str) orelse
        return rpc.errorJson(-32602, "Invalid network (mainnet|testnet|regtest|signet)", id, alloc);

    if (recipient_hex.len != 66) return rpc.errorJson(-32602, "recipient_pk must be 66 hex chars (33 bytes)", id, alloc);
    if (sender_hex.len    != 66) return rpc.errorJson(-32602, "sender_pk must be 66 hex chars (33 bytes)",    id, alloc);
    if (hash_hex.len      != 64) return rpc.errorJson(-32602, "hash_lock must be 64 hex chars (32 bytes)",    id, alloc);

    var recipient_pk: [33]u8 = undefined;
    var sender_pk:    [33]u8 = undefined;
    var hash_lock:    [32]u8 = undefined;

    _ = std.fmt.hexToBytes(&recipient_pk, recipient_hex) catch
        return rpc.errorJson(-32602, "Invalid hex in recipient_pk", id, alloc);
    _ = std.fmt.hexToBytes(&sender_pk, sender_hex) catch
        return rpc.errorJson(-32602, "Invalid hex in sender_pk", id, alloc);
    _ = std.fmt.hexToBytes(&hash_lock, hash_hex) catch
        return rpc.errorJson(-32602, "Invalid hex in hash_lock", id, alloc);

    // Compressed pubkey leading byte must be 0x02 or 0x03.
    if (recipient_pk[0] != 0x02 and recipient_pk[0] != 0x03)
        return rpc.errorJson(-32602, "recipient_pk not a compressed pubkey (must start with 02/03)", id, alloc);
    if (sender_pk[0] != 0x02 and sender_pk[0] != 0x03)
        return rpc.errorJson(-32602, "sender_pk not a compressed pubkey (must start with 02/03)", id, alloc);

    const script = htlc_btc_mod.buildRedeemScript(
        recipient_pk, sender_pk, hash_lock, @intCast(timelock), alloc,
    ) catch return rpc.errorJson(-32603, "Failed to build redeem script", id, alloc);
    defer alloc.free(script);

    const wp = htlc_btc_mod.witnessProgram(script);

    const address = htlc_btc_mod.addressFromScript(script, network, alloc) catch
        return rpc.errorJson(-32603, "Failed to encode bech32 address", id, alloc);
    defer alloc.free(address);

    // Hex-encode script + witness program for the response.
    const script_hex = try alloc.alloc(u8, script.len * 2);
    defer alloc.free(script_hex);
    const HEX_CHARS = "0123456789abcdef";
    for (script, 0..) |b, i| {
        script_hex[i * 2]     = HEX_CHARS[b >> 4];
        script_hex[i * 2 + 1] = HEX_CHARS[b & 0x0f];
    }
    const wp_hex = std.fmt.bytesToHex(wp, .lower);

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{" ++
        "\"redeem_script_hex\":\"{s}\"," ++
        "\"p2wsh_address\":\"{s}\"," ++
        "\"witness_program_hex\":\"{s}\"," ++
        "\"network\":\"{s}\"," ++
        "\"hrp\":\"{s}\"," ++
        "\"timelock\":{d}" ++
        "}}}}",
        .{ id, script_hex, address, &wp_hex, network_str, network.hrp(), timelock },
    );
}

/// getbridgestatus — returns live BridgeState summary (locked, volume, paused).
pub fn handleBridgeStatus(ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    ctx.bridge_mutex.lock();
    defer ctx.bridge_mutex.unlock();
    if (ctx.bridge) |bs| {
        const height = ctx.bc.getBlockCount();
        const lock_count: u32 = @intCast(bs.locks.items.len);
        const pending_count: u32 = @intCast(bs.pending_unlocks.count());
        const daily_vol = bs.dailyVolumeSat(height);
        return std.fmt.allocPrint(alloc,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{" ++
            "\"locked_total_sat\":{d}," ++
            "\"lock_count\":{d}," ++
            "\"pending_unlock_count\":{d}," ++
            "\"daily_volume_sat\":{d}," ++
            "\"paused\":{s}," ++
            "\"required_sigs\":{d}," ++
            "\"challenge_window_blocks\":{d}," ++
            "\"max_per_tx_sat\":{d}," ++
            "\"max_daily_sat\":{d}" ++
            "}}}}",
            .{
                id,
                bs.locked_total_sat,
                lock_count,
                pending_count,
                daily_vol,
                if (bs.paused) "true" else "false",
                chain_config.BRIDGE_REQUIRED_SIGS,
                chain_config.BRIDGE_CHALLENGE_WINDOW_BLOCKS,
                chain_config.BRIDGE_MAX_PER_TX_SAT,
                chain_config.BRIDGE_MAX_DAILY_SAT,
            },
        );
    }
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"status\":\"not_initialized\"}}}}",
        .{id},
    );
}

/// `htlc_init({receiver, amount_sat, hash_lock, timelock_block, [swap_id]})`
/// Builds and submits a TX type 0x30. `swap_id` is currently optional
/// metadata reserved for atomic-swap correlation across chains.
pub fn handleHtlcInit(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const receiver = rpc.extractStr(body, "receiver") orelse rpc.extractStr(body, "to")
        orelse return rpc.errorJson(-32602, "missing receiver", id, ctx.allocator);
    const amount_sat = rpc.extractU64Param(body, "\"amount_sat\"") orelse rpc.extractU64Param(body, "\"amount\"")
        orelse return rpc.errorJson(-32602, "missing amount_sat", id, ctx.allocator);
    const hash_lock_hex = rpc.extractStr(body, "hash_lock")
        orelse return rpc.errorJson(-32602, "missing hash_lock", id, ctx.allocator);
    const timelock_block = rpc.extractU64Param(body, "\"timelock_block\"") orelse rpc.extractU64Param(body, "\"timelock\"")
        orelse return rpc.errorJson(-32602, "missing timelock_block", id, ctx.allocator);

    const hash_lock = rpc.parseHex32(hash_lock_hex)
        orelse return rpc.errorJson(-32602, "hash_lock must be 64 hex chars", id, ctx.allocator);

    if (timelock_block > std.math.maxInt(u32))
        return rpc.errorJson(-32602, "timelock_block out of range (max u32)", id, ctx.allocator);

    const payload = tx_payload_mod.HtlcInitPayload{
        .hash_lock = hash_lock,
        .timelock_block = @intCast(timelock_block),
        .amount_sat = amount_sat,
    };
    payload.validate() catch return rpc.errorJson(-32602, "invalid htlc_init payload", id, ctx.allocator);

    var data_buf: [tx_payload_mod.HtlcInitPayload.WIRE_SIZE]u8 = undefined;
    _ = try payload.encode(&data_buf);

    const tx_hash = rpc.submitHtlcTx(ctx, .htlc_init, ctx.wallet.address, receiver, &data_buf)
        catch |err| {
            std.debug.print("[HTLC-INIT] submit failed: {}\n", .{err});
            return rpc.errorJson(-32000, "htlc_init submit failed", id, ctx.allocator);
        };
    defer ctx.allocator.free(tx_hash);

    const id_bytes = htlc_mod.computeHtlcId(tx_hash);
    var id_hex: [64]u8 = undefined;
    rpc.writeHex32(id_bytes, &id_hex);

    return std.fmt.allocPrint(ctx.allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"tx_hash\":\"{s}\",\"htlc_id\":\"{s}\",\"amount_sat\":{d},\"timelock_block\":{d}}}}}",
        .{ id, tx_hash, &id_hex, amount_sat, timelock_block });
}

/// `htlc_claim({htlc_id, preimage})` — TX type 0x31.
pub fn handleHtlcClaim(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const htlc_id_hex = rpc.extractStr(body, "htlc_id")
        orelse return rpc.errorJson(-32602, "missing htlc_id", id, ctx.allocator);
    const preimage_hex = rpc.extractStr(body, "preimage")
        orelse return rpc.errorJson(-32602, "missing preimage", id, ctx.allocator);

    const htlc_id = rpc.parseHex32(htlc_id_hex)
        orelse return rpc.errorJson(-32602, "htlc_id must be 64 hex chars", id, ctx.allocator);
    const preimage = rpc.parseHex32(preimage_hex)
        orelse return rpc.errorJson(-32602, "preimage must be 64 hex chars", id, ctx.allocator);

    const entry = ctx.bc.htlc_registry.get(htlc_id)
        orelse return rpc.errorJson(-32004, "htlc not found", id, ctx.allocator);
    if (entry.state != .active)
        return rpc.errorJson(-32005, "htlc not active", id, ctx.allocator);

    const payload = tx_payload_mod.HtlcClaimPayload{ .htlc_id = htlc_id, .preimage = preimage };
    var data_buf: [tx_payload_mod.HtlcClaimPayload.WIRE_SIZE]u8 = undefined;
    _ = try payload.encode(&data_buf);

    // applyBlock enforces (entry.recipient == tx.from_address); a mismatched
    // caller will surface as HtlcUnauthorizedClaim downstream.
    const tx_hash = rpc.submitHtlcTx(ctx, .htlc_claim, ctx.wallet.address, entry.senderSlice(), &data_buf)
        catch |err| {
            std.debug.print("[HTLC-CLAIM] submit failed: {}\n", .{err});
            return rpc.errorJson(-32000, "htlc_claim submit failed", id, ctx.allocator);
        };
    defer ctx.allocator.free(tx_hash);

    return std.fmt.allocPrint(ctx.allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"tx_hash\":\"{s}\",\"htlc_id\":\"{s}\"}}}}",
        .{ id, tx_hash, htlc_id_hex });
}

/// `htlc_refund({htlc_id})` — TX type 0x32. Caller must be original sender;
/// chain enforces current_block >= timelock_block at apply time.
pub fn handleHtlcRefund(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const htlc_id_hex = rpc.extractStr(body, "htlc_id")
        orelse return rpc.errorJson(-32602, "missing htlc_id", id, ctx.allocator);
    const htlc_id = rpc.parseHex32(htlc_id_hex)
        orelse return rpc.errorJson(-32602, "htlc_id must be 64 hex chars", id, ctx.allocator);

    const entry = ctx.bc.htlc_registry.get(htlc_id)
        orelse return rpc.errorJson(-32004, "htlc not found", id, ctx.allocator);
    if (entry.state != .active and entry.state != .expired)
        return rpc.errorJson(-32005, "htlc not refundable", id, ctx.allocator);

    const payload = tx_payload_mod.HtlcRefundPayload{ .htlc_id = htlc_id };
    var data_buf: [tx_payload_mod.HtlcRefundPayload.WIRE_SIZE]u8 = undefined;
    _ = try payload.encode(&data_buf);

    const tx_hash = rpc.submitHtlcTx(ctx, .htlc_refund, ctx.wallet.address, entry.recipientSlice(), &data_buf)
        catch |err| {
            std.debug.print("[HTLC-REFUND] submit failed: {}\n", .{err});
            return rpc.errorJson(-32000, "htlc_refund submit failed", id, ctx.allocator);
        };
    defer ctx.allocator.free(tx_hash);

    return std.fmt.allocPrint(ctx.allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"tx_hash\":\"{s}\",\"htlc_id\":\"{s}\"}}}}",
        .{ id, tx_hash, htlc_id_hex });
}

/// Render an HTLC entry as a JSON object into `out`.
fn appendHtlcEntryJson(
    out: *std.array_list.Managed(u8),
    e: *const htlc_mod.HtlcEntry,
) !void {
    var id_hex: [64]u8 = undefined;
    rpc.writeHex32(e.id, &id_hex);
    var hash_hex: [64]u8 = undefined;
    rpc.writeHex32(e.hash_lock, &hash_hex);
    const state_name: []const u8 = switch (e.state) {
        .pending => "pending",
        .active => "active",
        .claimed => "claimed",
        .refunded => "refunded",
        .expired => "expired",
    };
    var pre_hex: [64]u8 = undefined;
    if (e.has_preimage) rpc.writeHex32(e.preimage, &pre_hex);
    const writer = out.writer();
    if (e.has_preimage) {
        try writer.print(
            "{{\"htlc_id\":\"{s}\",\"sender\":\"{s}\",\"recipient\":\"{s}\",\"amount_sat\":{d},\"hash_lock\":\"{s}\",\"timelock_block\":{d},\"init_block\":{d},\"init_tx_hash\":\"{s}\",\"state\":\"{s}\",\"preimage\":\"{s}\"}}",
            .{ &id_hex, e.senderSlice(), e.recipientSlice(), e.amount_sat,
               &hash_hex, e.timelock_block, e.init_block, e.initTxHashSlice(),
               state_name, &pre_hex },
        );
    } else {
        try writer.print(
            "{{\"htlc_id\":\"{s}\",\"sender\":\"{s}\",\"recipient\":\"{s}\",\"amount_sat\":{d},\"hash_lock\":\"{s}\",\"timelock_block\":{d},\"init_block\":{d},\"init_tx_hash\":\"{s}\",\"state\":\"{s}\"}}",
            .{ &id_hex, e.senderSlice(), e.recipientSlice(), e.amount_sat,
               &hash_hex, e.timelock_block, e.init_block, e.initTxHashSlice(),
               state_name },
        );
    }
}

/// `htlc_get({htlc_id})` — read-only registry lookup.
pub fn handleHtlcGet(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const htlc_id_hex = rpc.extractStr(body, "htlc_id")
        orelse return rpc.errorJson(-32602, "missing htlc_id", id, ctx.allocator);
    const htlc_id = rpc.parseHex32(htlc_id_hex)
        orelse return rpc.errorJson(-32602, "htlc_id must be 64 hex chars", id, ctx.allocator);

    const entry = ctx.bc.htlc_registry.get(htlc_id)
        orelse return rpc.errorJson(-32004, "htlc not found", id, ctx.allocator);

    var buf = std.array_list.Managed(u8).init(ctx.allocator);
    defer buf.deinit();
    try buf.writer().print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":", .{id});
    try appendHtlcEntryJson(&buf, &entry);
    try buf.appendSlice("}");
    return buf.toOwnedSlice();
}

/// `htlc_listByAddress({address})` — every HTLC where `address` is sender or recipient.
pub fn handleHtlcListByAddress(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const addr = rpc.extractStr(body, "address")
        orelse return rpc.errorJson(-32602, "missing address", id, ctx.allocator);

    var buf = std.array_list.Managed(u8).init(ctx.allocator);
    defer buf.deinit();
    try buf.writer().print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":[", .{id});

    var first = true;
    var i: u32 = 0;
    while (i < ctx.bc.htlc_registry.entry_count) : (i += 1) {
        const e = &ctx.bc.htlc_registry.entries[i];
        if (!std.mem.eql(u8, e.senderSlice(), addr) and
            !std.mem.eql(u8, e.recipientSlice(), addr)) continue;
        if (!first) try buf.appendSlice(",");
        first = false;
        try appendHtlcEntryJson(&buf, e);
    }
    try buf.appendSlice("]}");
    return buf.toOwnedSlice();
}

/// `htlc_listPending()` — every active HTLC on the chain (admin/debug).
pub fn handleHtlcListPending(ctx: *ServerCtx, id: u64) ![]u8 {
    var buf = std.array_list.Managed(u8).init(ctx.allocator);
    defer buf.deinit();
    try buf.writer().print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":[", .{id});

    var first = true;
    var i: u32 = 0;
    while (i < ctx.bc.htlc_registry.entry_count) : (i += 1) {
        const e = &ctx.bc.htlc_registry.entries[i];
        if (e.state != .active) continue;
        if (!first) try buf.appendSlice(",");
        first = false;
        try appendHtlcEntryJson(&buf, e);
    }
    try buf.appendSlice("]}");
    return buf.toOwnedSlice();
}
