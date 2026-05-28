// Escrow JSON-RPC handlers.

const std = @import("std");
const rpc = @import("../rpc_server.zig");
const blockchain_mod = @import("../blockchain.zig");
const escrow_mod = @import("../escrow.zig");

const ServerCtx = rpc.ServerCtx;

// ── escrow_create ─────────────────────────────────────────────────────────────
// { "from":"ob1q...", "to":"ob1q...", "amount":5000000000, "condition_hash":"<sha256>",
//   "timeout_blocks":144, "note":"proiect X", "signature":"hex", "public_key":"hex", "nonce":N }

pub fn handleEscrowCreate(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc      = ctx.allocator;
    const from       = rpc.extractStr(body, "from")       orelse return rpc.errorJson(-32602, "Missing: from", id, alloc);
    const to         = rpc.extractStr(body, "to")         orelse return rpc.errorJson(-32602, "Missing: to", id, alloc);
    const amount     = rpc.extractParamObjectU64(body, "amount");
    const cond_hash  = rpc.extractStr(body, "condition_hash") orelse return rpc.errorJson(-32602, "Missing: condition_hash", id, alloc);
    const timeout_bl = rpc.extractParamObjectU64(body, "timeout_blocks");
    const note       = rpc.extractStr(body, "note")       orelse "";
    const sig        = rpc.extractStr(body, "signature")  orelse return rpc.errorJson(-32602, "Missing: signature", id, alloc);
    const pubkey     = rpc.extractStr(body, "public_key") orelse return rpc.errorJson(-32602, "Missing: public_key", id, alloc);
    const nonce      = rpc.extractParamObjectU64(body, "nonce");

    if (amount == 0)    return rpc.errorJson(-32602, "amount must be > 0", id, alloc);
    if (timeout_bl == 0) return rpc.errorJson(-32602, "timeout_blocks must be > 0", id, alloc);
    if (cond_hash.len != escrow_mod.HASH_LEN)
        return rpc.errorJson(-32602, "condition_hash must be 64-char SHA-256 hex", id, alloc);

    const op_return = try std.fmt.allocPrint(alloc,
        "escrow_create:{s}:{d}:{s}:{d}:{s}", .{ to, amount, cond_hash, timeout_bl, note });
    defer alloc.free(op_return);

    const ts    = std.time.timestamp();
    const tx_id: u32 = @intCast(std.time.milliTimestamp() & 0xFFFFFFFF);
    const provisional = try std.fmt.allocPrint(alloc, "{d}{s}{d}", .{ tx_id, from, ts });
    defer alloc.free(provisional);

    var tx = blockchain_mod.Transaction{
        .id           = tx_id,
        .from_address = from,
        .to_address   = from,
        .amount       = amount,  // fondurile sunt debitate din balanta
        .fee          = escrow_mod.ESCROW_CREATE_FEE_SAT,
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

    const parsed = escrow_mod.parseCreate(op_return).?;
    const esc_id = ctx.bc.escrow_registry.create(
        from, parsed, @intCast(ctx.bc.getBlockCount()), canonical,
    ) catch 0;

    ctx.bc.mutex.lock();
    ctx.bc.mempool.append(tx) catch {
        ctx.bc.mutex.unlock();
        return rpc.errorJson(-32603, "Mempool full", id, alloc);
    };
    ctx.bc.mutex.unlock();

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{" ++
        "\"status\":\"queued\"," ++
        "\"txid\":\"{s}\"," ++
        "\"escrow_id\":{d}," ++
        "\"amount_sat\":{d}," ++
        "\"timeout_block\":{d}," ++
        "\"condition_hash\":\"{s}\"" ++
        "}}}}",
        .{ id, canonical, esc_id, amount,
           ctx.bc.getBlockCount() + timeout_bl, cond_hash });
}

// ── escrow_release ────────────────────────────────────────────────────────────
// { "from":"ob1q_to...", "escrow_id":1, "proof_hash":"<sha256>",
//   "signature":"hex", "public_key":"hex", "nonce":N }

pub fn handleEscrowRelease(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc      = ctx.allocator;
    const from       = rpc.extractStr(body, "from")       orelse return rpc.errorJson(-32602, "Missing: from", id, alloc);
    const escrow_id  = rpc.extractParamObjectU64(body, "escrow_id");
    const proof_hash = rpc.extractStr(body, "proof_hash") orelse return rpc.errorJson(-32602, "Missing: proof_hash", id, alloc);
    const sig        = rpc.extractStr(body, "signature")  orelse return rpc.errorJson(-32602, "Missing: signature", id, alloc);
    const pubkey     = rpc.extractStr(body, "public_key") orelse return rpc.errorJson(-32602, "Missing: public_key", id, alloc);
    const nonce      = rpc.extractParamObjectU64(body, "nonce");

    if (proof_hash.len != escrow_mod.HASH_LEN)
        return rpc.errorJson(-32602, "proof_hash must be 64-char SHA-256 hex", id, alloc);

    const op_return = try std.fmt.allocPrint(alloc,
        "escrow_release:{d}:{s}", .{ escrow_id, proof_hash });
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

    // Optimistic in-memory release
    const amount = ctx.bc.escrow_registry.tryRelease(
        escrow_id, proof_hash, from, @intCast(ctx.bc.getBlockCount()),
    );

    ctx.bc.mutex.lock();
    ctx.bc.mempool.append(tx) catch {
        ctx.bc.mutex.unlock();
        return rpc.errorJson(-32603, "Mempool full", id, alloc);
    };
    ctx.bc.mutex.unlock();

    if (amount == 0)
        return rpc.errorJson(-32001, "Release failed: proof_hash mismatch, wrong caller, or escrow not pending", id, alloc);

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"status\":\"queued\",\"txid\":\"{s}\",\"released_sat\":{d}}}}}",
        .{ id, canonical, amount });
}

// ── escrow_refund ─────────────────────────────────────────────────────────────
// { "from":"ob1q_from...", "escrow_id":1, "signature":"hex", "public_key":"hex", "nonce":N }

pub fn handleEscrowRefund(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc     = ctx.allocator;
    const from      = rpc.extractStr(body, "from")       orelse return rpc.errorJson(-32602, "Missing: from", id, alloc);
    const escrow_id = rpc.extractParamObjectU64(body, "escrow_id");
    const sig       = rpc.extractStr(body, "signature")  orelse return rpc.errorJson(-32602, "Missing: signature", id, alloc);
    const pubkey    = rpc.extractStr(body, "public_key") orelse return rpc.errorJson(-32602, "Missing: public_key", id, alloc);
    const nonce     = rpc.extractParamObjectU64(body, "nonce");

    const op_return = try std.fmt.allocPrint(alloc, "escrow_refund:{d}", .{escrow_id});
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

    const amount = ctx.bc.escrow_registry.tryRefund(
        escrow_id, from, @intCast(ctx.bc.getBlockCount()),
    );

    ctx.bc.mutex.lock();
    ctx.bc.mempool.append(tx) catch {
        ctx.bc.mutex.unlock();
        return rpc.errorJson(-32603, "Mempool full", id, alloc);
    };
    ctx.bc.mutex.unlock();

    if (amount == 0)
        return rpc.errorJson(-32001, "Refund failed: not timed out yet, wrong caller, or escrow not pending", id, alloc);

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"status\":\"queued\",\"txid\":\"{s}\",\"refunded_sat\":{d}}}}}",
        .{ id, canonical, amount });
}

// ── escrow_dispute ────────────────────────────────────────────────────────────
// { "from":"ob1q...", "escrow_id":1, "signature":"hex", "public_key":"hex", "nonce":N }

pub fn handleEscrowDispute(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc     = ctx.allocator;
    const from      = rpc.extractStr(body, "from")       orelse return rpc.errorJson(-32602, "Missing: from", id, alloc);
    const escrow_id = rpc.extractParamObjectU64(body, "escrow_id");
    const sig       = rpc.extractStr(body, "signature")  orelse return rpc.errorJson(-32602, "Missing: signature", id, alloc);
    const pubkey    = rpc.extractStr(body, "public_key") orelse return rpc.errorJson(-32602, "Missing: public_key", id, alloc);
    const nonce     = rpc.extractParamObjectU64(body, "nonce");

    const op_return = try std.fmt.allocPrint(alloc, "escrow_dispute:{d}", .{escrow_id});
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
        .fee          = escrow_mod.ESCROW_DISPUTE_FEE_SAT,
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

    const opened = ctx.bc.escrow_registry.openDispute(escrow_id, from);

    ctx.bc.mutex.lock();
    ctx.bc.mempool.append(tx) catch {
        ctx.bc.mutex.unlock();
        return rpc.errorJson(-32603, "Mempool full", id, alloc);
    };
    ctx.bc.mutex.unlock();

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"status\":\"queued\",\"txid\":\"{s}\",\"disputed\":{s}}}}}",
        .{ id, canonical, if (opened) "true" else "false" });
}

// ── getescrow ─────────────────────────────────────────────────────────────────
// { "escrow_id":1 }

pub fn handleGetEscrow(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc     = ctx.allocator;
    const escrow_id = rpc.extractParamObjectU64(body, "escrow_id");

    const e = ctx.bc.escrow_registry.get(escrow_id) orelse
        return std.fmt.allocPrint(alloc,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":null}}", .{id});

    const current_block: u64 = @intCast(ctx.bc.getBlockCount());
    const note_safe = try rpc.jsonSanitize(alloc, e.noteSlice());
    defer alloc.free(note_safe);
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{" ++
        "\"id\":{d}," ++
        "\"from\":\"{s}\"," ++
        "\"to\":\"{s}\"," ++
        "\"amount_sat\":{d}," ++
        "\"condition_hash\":\"{s}\"," ++
        "\"timeout_block\":{d}," ++
        "\"create_block\":{d}," ++
        "\"status\":\"{s}\"," ++
        "\"timed_out\":{s}," ++
        "\"note\":\"{s}\"" ++
        "}}}}",
        .{ id, e.id, e.fromSlice(), e.toSlice(),
           e.amount_sat, e.conditionSlice(),
           e.timeout_block, e.create_block, e.statusStr(),
           if (e.isTimedOut(current_block)) "true" else "false",
           note_safe });
}

// ── getescrows ────────────────────────────────────────────────────────────────
// { "address":"ob1q...", "role":"from"|"to" }

pub fn handleGetEscrows(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc   = ctx.allocator;
    const address = rpc.extractStr(body, "address") orelse
        return rpc.errorJson(-32602, "Missing: address", id, alloc);
    const role    = rpc.extractStr(body, "role") orelse "from";
    const current_block: u64 = @intCast(ctx.bc.getBlockCount());

    var entries: [64]escrow_mod.EscrowEntry = undefined;
    const n = if (std.mem.eql(u8, role, "to"))
        ctx.bc.escrow_registry.listByTo(address, &entries)
    else
        ctx.bc.escrow_registry.listByFrom(address, &entries);

    var buf = std.array_list.Managed(u8).init(alloc);
    defer buf.deinit();
    const w = buf.writer();

    try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"escrows\":[", .{id});
    for (entries[0..n], 0..) |e, i| {
        if (i > 0) try w.writeByte(',');
        try w.print(
            "{{\"id\":{d},\"from\":\"{s}\",\"to\":\"{s}\"," ++
            "\"amount_sat\":{d},\"status\":\"{s}\"," ++
            "\"timeout_block\":{d},\"timed_out\":{s}," ++
            "\"condition_hash\":\"{s}\",\"note\":\"",
            .{ e.id, e.fromSlice(), e.toSlice(),
               e.amount_sat, e.statusStr(),
               e.timeout_block,
               if (e.isTimedOut(current_block)) "true" else "false",
               e.conditionSlice() },
        );
        try rpc.writeJsonSafeStr(w, e.noteSlice());
        try w.writeAll("\"}");
    }
    try w.writeAll("]}}");
    return buf.toOwnedSlice();
}
