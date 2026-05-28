// Subscription JSON-RPC handlers.

const std = @import("std");
const rpc = @import("../rpc_server.zig");
const blockchain_mod = @import("../blockchain.zig");
const sub_mod = @import("../subscription.zig");

const ServerCtx = rpc.ServerCtx;

// ── sub_create ────────────────────────────────────────────────────────────────
// { "from":"ob1q...", "to":"ob1q...", "amount":1000000, "interval":100,
//   "max_payments":12, "note":"Netflix", "signature":"hex", "public_key":"hex", "nonce":N }

pub fn handleSubCreate(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc    = ctx.allocator;
    const from     = rpc.extractStr(body, "from")    orelse return rpc.errorJson(-32602, "Missing: from", id, alloc);
    const to       = rpc.extractStr(body, "to")      orelse return rpc.errorJson(-32602, "Missing: to", id, alloc);
    const amount   = rpc.extractParamObjectU64(body, "amount");
    const interval = rpc.extractParamObjectU64(body, "interval");
    const max_pay  = rpc.extractParamObjectU64(body, "max_payments");
    const note     = rpc.extractStr(body, "note") orelse "";
    const sig      = rpc.extractStr(body, "signature")  orelse return rpc.errorJson(-32602, "Missing: signature", id, alloc);
    const pubkey   = rpc.extractStr(body, "public_key") orelse return rpc.errorJson(-32602, "Missing: public_key", id, alloc);
    const nonce    = rpc.extractParamObjectU64(body, "nonce");

    if (amount == 0)   return rpc.errorJson(-32602, "amount must be > 0", id, alloc);
    if (interval == 0) return rpc.errorJson(-32602, "interval must be > 0", id, alloc);

    // Build op_return
    const op_return = try std.fmt.allocPrint(alloc,
        "sub_create:{s}:{d}:{d}:{d}:{s}", .{ to, amount, interval, max_pay, note });
    defer alloc.free(op_return);

    const ts    = std.time.timestamp();
    const tx_id: u32 = @intCast(std.time.milliTimestamp() & 0xFFFFFFFF);
    const provisional = try std.fmt.allocPrint(alloc, "{d}{s}{d}", .{ tx_id, from, ts });
    defer alloc.free(provisional);

    var tx = blockchain_mod.Transaction{
        .id           = tx_id,
        .from_address = from,
        .to_address   = from,
        .amount       = 0,
        .fee          = sub_mod.SUB_CREATE_FEE_SAT,
        .timestamp    = ts,
        .nonce        = nonce,
        .op_return    = op_return,
        .signature    = sig,
        .public_key   = pubkey,
        .scheme       = .omni_ecdsa,
        .hash         = provisional,
    };
    const hash_bytes = tx.calculateHash();
    const canonical  = try std.fmt.allocPrint(alloc, "{s}", .{std.fmt.bytesToHex(hash_bytes, .lower)});
    tx.hash = canonical;

    // Optimistic in-memory create
    const parsed = sub_mod.parseCreate(op_return).?;
    const sub_id = ctx.bc.sub_registry.create(from, parsed, @intCast(ctx.bc.getBlockCount())) catch 0;

    ctx.bc.mutex.lock();
    ctx.bc.mempool.append(tx) catch {
        ctx.bc.mutex.unlock();
        return rpc.errorJson(-32603, "Mempool full", id, alloc);
    };
    ctx.bc.mutex.unlock();

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"status\":\"queued\",\"txid\":\"{s}\",\"sub_id\":{d},\"next_block\":{d}}}}}",
        .{ id, canonical, sub_id, ctx.bc.getBlockCount() + interval });
}

// ── sub_cancel ────────────────────────────────────────────────────────────────
// { "from":"ob1q...", "sub_id":42, "signature":"hex", "public_key":"hex", "nonce":N }

pub fn handleSubCancel(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc   = ctx.allocator;
    const from    = rpc.extractStr(body, "from")    orelse return rpc.errorJson(-32602, "Missing: from", id, alloc);
    const sub_id  = rpc.extractParamObjectU64(body, "sub_id");
    const sig     = rpc.extractStr(body, "signature")  orelse return rpc.errorJson(-32602, "Missing: signature", id, alloc);
    const pubkey  = rpc.extractStr(body, "public_key") orelse return rpc.errorJson(-32602, "Missing: public_key", id, alloc);
    const nonce   = rpc.extractParamObjectU64(body, "nonce");

    const op_return = try std.fmt.allocPrint(alloc, "sub_cancel:{d}", .{sub_id});
    defer alloc.free(op_return);

    const ts    = std.time.timestamp();
    const tx_id: u32 = @intCast(std.time.milliTimestamp() & 0xFFFFFFFF);
    const provisional = try std.fmt.allocPrint(alloc, "{d}{s}{d}", .{ tx_id, from, ts });
    defer alloc.free(provisional);

    var tx = blockchain_mod.Transaction{
        .id           = tx_id,
        .from_address = from,
        .to_address   = from,
        .amount       = 0,
        .fee          = 1000,
        .timestamp    = ts,
        .nonce        = nonce,
        .op_return    = op_return,
        .signature    = sig,
        .public_key   = pubkey,
        .scheme       = .omni_ecdsa,
        .hash         = provisional,
    };
    const hash_bytes = tx.calculateHash();
    const canonical  = try std.fmt.allocPrint(alloc, "{s}", .{std.fmt.bytesToHex(hash_bytes, .lower)});
    tx.hash = canonical;

    const cancelled = ctx.bc.sub_registry.cancel(sub_id, from);

    ctx.bc.mutex.lock();
    ctx.bc.mempool.append(tx) catch {
        ctx.bc.mutex.unlock();
        return rpc.errorJson(-32603, "Mempool full", id, alloc);
    };
    ctx.bc.mutex.unlock();

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"status\":\"queued\",\"txid\":\"{s}\",\"cancelled\":{s}}}}}",
        .{ id, canonical, if (cancelled) "true" else "false" });
}

// ── getsubscriptions ──────────────────────────────────────────────────────────
// { "address":"ob1q..." }  — returnează toate subscripțiile (emise și primite)

pub fn handleGetSubscriptions(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc   = ctx.allocator;
    const address = rpc.extractStr(body, "address") orelse
        return rpc.errorJson(-32602, "Missing: address", id, alloc);

    var entries: [sub_mod.MAX_SUBS_PER_ADDRESS]sub_mod.Subscription = undefined;
    const n = ctx.bc.sub_registry.listByFrom(address, &entries);

    var buf = std.array_list.Managed(u8).init(alloc);
    defer buf.deinit();
    const w = buf.writer();

    try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"subscriptions\":[", .{id});
    for (entries[0..n], 0..) |sub, i| {
        if (i > 0) try w.writeByte(',');
        const status_str: []const u8 = switch (sub.status) {
            .active    => "active",
            .cancelled => "cancelled",
            .completed => "completed",
        };
        const sub_note = try rpc.jsonSanitize(alloc, sub.noteSlice());
        defer alloc.free(sub_note);
        try w.print(
            "{{\"id\":{d},\"from\":\"{s}\",\"to\":\"{s}\"," ++
            "\"amount_sat\":{d},\"interval_blocks\":{d}," ++
            "\"max_payments\":{d},\"payments_done\":{d}," ++
            "\"next_block\":{d},\"status\":\"{s}\",\"note\":\"{s}\"}}",
            .{ sub.id, sub.fromSlice(), sub.toSlice(),
               sub.amount_sat, sub.interval_blocks,
               sub.max_payments, sub.payments_done,
               sub.next_block, status_str, sub_note },
        );
    }
    try w.writeAll("]}}");
    return buf.toOwnedSlice();
}
