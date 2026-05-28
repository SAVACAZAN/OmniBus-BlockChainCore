// Notarize JSON-RPC handlers.

const std = @import("std");
const rpc = @import("../rpc_server.zig");
const blockchain_mod = @import("../blockchain.zig");
const notarize_mod = @import("../notarize.zig");

const ServerCtx = rpc.ServerCtx;

// ── notarizedoc ───────────────────────────────────────────────────────────────
// { "from":"ob1q...", "doc_hash":"<sha256_hex_64>", "doc_type":"audit",
//   "expiry_blocks":0, "note":"Contract X", "signature":"hex", "public_key":"hex", "nonce":N }

pub fn handleNotarizeDoc(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc       = ctx.allocator;
    const from        = rpc.extractStr(body, "from")       orelse return rpc.errorJson(-32602, "Missing: from", id, alloc);
    const doc_hash    = rpc.extractStr(body, "doc_hash")   orelse return rpc.errorJson(-32602, "Missing: doc_hash", id, alloc);
    const doc_type_s  = rpc.extractStr(body, "doc_type")   orelse "other";
    const expiry      = rpc.extractParamObjectU64(body, "expiry_blocks");
    const note        = rpc.extractStr(body, "note")       orelse "";
    const sig         = rpc.extractStr(body, "signature")  orelse return rpc.errorJson(-32602, "Missing: signature", id, alloc);
    const pubkey      = rpc.extractStr(body, "public_key") orelse return rpc.errorJson(-32602, "Missing: public_key", id, alloc);
    const nonce       = rpc.extractParamObjectU64(body, "nonce");

    if (doc_hash.len != notarize_mod.HASH_LEN)
        return rpc.errorJson(-32602, "doc_hash must be 64-char SHA-256 hex", id, alloc);

    const op_return = try std.fmt.allocPrint(alloc,
        "notarize:{s}:{s}:{d}:{s}", .{ doc_hash, doc_type_s, expiry, note });
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
        .fee          = notarize_mod.NOTARIZE_FEE_SAT,
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

    // Optimistic in-memory notarize
    const parsed = notarize_mod.parsNotarize(op_return).?;
    const note_id = ctx.bc.notarize_registry.notarize(
        from, parsed, @intCast(ctx.bc.getBlockCount()), canonical,
    ) catch 0;

    ctx.bc.mutex.lock();
    ctx.bc.mempool.append(tx) catch {
        ctx.bc.mutex.unlock();
        return rpc.errorJson(-32603, "Mempool full", id, alloc);
    };
    ctx.bc.mutex.unlock();

    const ndoc_type_safe = try rpc.jsonSanitize(alloc, doc_type_s);
    defer alloc.free(ndoc_type_safe);
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{" ++
        "\"status\":\"queued\"," ++
        "\"txid\":\"{s}\"," ++
        "\"notarize_id\":{d}," ++
        "\"doc_hash\":\"{s}\"," ++
        "\"doc_type\":\"{s}\"," ++
        "\"fee_sat\":{d}" ++
        "}}}}",
        .{ id, canonical, note_id, doc_hash, ndoc_type_safe, notarize_mod.NOTARIZE_FEE_SAT });
}

// ── verifynotarize ────────────────────────────────────────────────────────────
// { "doc_hash":"<sha256_hex_64>" }  — verifica daca documentul e notarizat pe chain

pub fn handleVerifyNotarize(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc    = ctx.allocator;
    const doc_hash = rpc.extractStr(body, "doc_hash") orelse
        return rpc.errorJson(-32602, "Missing: doc_hash", id, alloc);

    if (doc_hash.len != notarize_mod.HASH_LEN)
        return rpc.errorJson(-32602, "doc_hash must be 64-char SHA-256 hex", id, alloc);

    const current_block: u64 = @intCast(ctx.bc.getBlockCount());
    const result = ctx.bc.notarize_registry.verify(doc_hash, current_block);

    if (result.entry == null) {
        return std.fmt.allocPrint(alloc,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"status\":\"{s}\",\"doc_hash\":\"{s}\"}}}}",
            .{ id, result.statusStr(), doc_hash });
    }

    const e = result.entry.?;
    {
        const vnote_safe = try rpc.jsonSanitize(alloc, e.noteSlice());
        defer alloc.free(vnote_safe);
        return std.fmt.allocPrint(alloc,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{" ++
            "\"status\":\"{s}\"," ++
            "\"notarize_id\":{d}," ++
            "\"doc_hash\":\"{s}\"," ++
            "\"doc_type\":\"{s}\"," ++
            "\"owner\":\"{s}\"," ++
            "\"block_height\":{d}," ++
            "\"tx_hash\":\"{s}\"," ++
            "\"expiry_block\":{d}," ++
            "\"note\":\"{s}\"" ++
            "}}}}",
            .{ id, result.statusStr(), e.id, e.docHashSlice(), e.doc_type.toStr(),
               e.ownerSlice(), e.block_height, e.txHashSlice(), e.expiry_block, vnote_safe });
    }
}

// ── revokenotarize ────────────────────────────────────────────────────────────
// { "from":"ob1q...", "notarize_id":42, "signature":"hex", "public_key":"hex", "nonce":N }

pub fn handleRevokeNotarize(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc       = ctx.allocator;
    const from        = rpc.extractStr(body, "from")       orelse return rpc.errorJson(-32602, "Missing: from", id, alloc);
    const notarize_id = rpc.extractParamObjectU64(body, "notarize_id");
    const sig         = rpc.extractStr(body, "signature")  orelse return rpc.errorJson(-32602, "Missing: signature", id, alloc);
    const pubkey      = rpc.extractStr(body, "public_key") orelse return rpc.errorJson(-32602, "Missing: public_key", id, alloc);
    const nonce       = rpc.extractParamObjectU64(body, "nonce");

    const op_return = try std.fmt.allocPrint(alloc, "notarize_revoke:{d}", .{notarize_id});
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
        .fee          = notarize_mod.NOTARIZE_REVOKE_FEE_SAT,
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

    const revoked = ctx.bc.notarize_registry.revoke(notarize_id, from);

    ctx.bc.mutex.lock();
    ctx.bc.mempool.append(tx) catch {
        ctx.bc.mutex.unlock();
        return rpc.errorJson(-32603, "Mempool full", id, alloc);
    };
    ctx.bc.mutex.unlock();

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"status\":\"queued\",\"txid\":\"{s}\",\"revoked\":{s}}}}}",
        .{ id, canonical, if (revoked) "true" else "false" });
}

// ── getnotarizations ──────────────────────────────────────────────────────────
// { "address":"ob1q..." }  — lista notarizarilor unui owner (newest first)

pub fn handleGetNotarizations(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc   = ctx.allocator;
    const address = rpc.extractStr(body, "address") orelse
        return rpc.errorJson(-32602, "Missing: address", id, alloc);

    var entries: [64]notarize_mod.NotarizeEntry = undefined;
    const n = ctx.bc.notarize_registry.listByOwner(address, &entries);
    const current_block: u64 = @intCast(ctx.bc.getBlockCount());

    var buf = std.array_list.Managed(u8).init(alloc);
    defer buf.deinit();
    const w = buf.writer();

    try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"notarizations\":[", .{id});
    for (entries[0..n], 0..) |e, i| {
        if (i > 0) try w.writeByte(',');
        const status = if (e.revoked) "revoked"
            else if (e.expiry_block > 0 and current_block > e.expiry_block) "expired"
            else "valid";
        const note_safe = try rpc.jsonSanitize(alloc, e.noteSlice());
        defer alloc.free(note_safe);
        try w.print(
            "{{\"id\":{d},\"doc_hash\":\"{s}\",\"doc_type\":\"{s}\"," ++
            "\"block_height\":{d},\"tx_hash\":\"{s}\"," ++
            "\"expiry_block\":{d},\"status\":\"{s}\",\"note\":\"{s}\"}}",
            .{ e.id, e.docHashSlice(), e.doc_type.toStr(),
               e.block_height, e.txHashSlice(),
               e.expiry_block, status, note_safe },
        );
    }
    try w.writeAll("]}}");
    return buf.toOwnedSlice();
}
