// Social-graph / reputation JSON-RPC handlers — labels, follow, POAP.
//
// Bitcoin-Core has no analogue. We layer a tiny social graph + reputation
// system on top of OmniBus TX op_returns:
//
//   applylabel / getlabels / removelabel  — semantic tags on addresses
//   follow / unfollow / getfollowers / getfollowing  — directed graph
//   poap_createevent / poap_claim / poap_close / getpoaps / getpoapevent
//
// Every mutating call writes a fee-bearing op_return TX into the mempool;
// the in-memory registry is updated optimistically so reads reflect the
// change before the block is mined.

const std = @import("std");
const rpc = @import("../rpc_server.zig");
const blockchain_mod = @import("../blockchain.zig");
const label_mod = @import("../label.zig");
const social_mod = @import("../social_graph.zig");
const poap_mod = @import("../poap.zig");

const ServerCtx = rpc.ServerCtx;

// ── applylabel ────────────────────────────────────────────────────────────────
// { "from":"ob1q...", "target":"ob1q...", "tag":"trusted",
//   "note":"optional", "tier":"FOOD", "signature":"hex", "public_key":"hex", "nonce":N }
// Fee: minimum 0.1 OMNI (LABEL_FEE_SAT). anti-spam.
pub fn handleApplyLabel(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const from    = rpc.extractStr(body, "from")    orelse return rpc.errorJson(-32602, "Missing: from", id, alloc);
    const target  = rpc.extractStr(body, "target")  orelse return rpc.errorJson(-32602, "Missing: target", id, alloc);
    const tag_str = rpc.extractStr(body, "tag")     orelse return rpc.errorJson(-32602, "Missing: tag", id, alloc);
    const note    = rpc.extractStr(body, "note")    orelse "";
    const tier    = rpc.extractStr(body, "tier")    orelse "OMNI";
    const sig     = rpc.extractStr(body, "signature")  orelse return rpc.errorJson(-32602, "Missing: signature", id, alloc);
    const pubkey  = rpc.extractStr(body, "public_key") orelse return rpc.errorJson(-32602, "Missing: public_key", id, alloc);
    const nonce   = rpc.extractParamObjectU64(body, "nonce");
    _ = tier;

    const tag = label_mod.Tag.fromStr(tag_str) orelse
        return rpc.errorJson(-32602, "Unknown tag", id, alloc);

    const op_return = try std.fmt.allocPrint(alloc, "label:{s}:{s}:{s}", .{ target, tag.toStr(), note });
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
        .fee          = label_mod.LABEL_FEE_SAT,
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

    // Also apply immediately to the in-memory registry so getlabels reflects it
    // before the block is mined (optimistic — removed if TX is dropped).
    _ = ctx.bc.label_registry.apply(
        target, from, tag, note, rpc.extractStr(body, "tier") orelse "OMNI",
        @intCast(ctx.bc.getBlockCount()),
        canonical,
    ) catch {};

    ctx.bc.mutex.lock();
    ctx.bc.mempool.append(tx) catch {
        ctx.bc.mutex.unlock();
        return rpc.errorJson(-32603, "Mempool full", id, alloc);
    };
    ctx.bc.mutex.unlock();

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"status\":\"queued\",\"txid\":\"{s}\",\"tag\":\"{s}\",\"target\":\"{s}\"}}}}",
        .{ id, canonical, tag.toStr(), target });
}

// ── getlabels — { "address":"ob1q..." } returns address report + active labels.
pub fn handleGetLabels(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc   = ctx.allocator;
    const address = rpc.extractStr(body, "address") orelse
        return rpc.errorJson(-32602, "Missing: address", id, alloc);

    const rep = ctx.bc.label_registry.report(address);

    var buf = std.array_list.Managed(u8).init(alloc);
    defer buf.deinit();
    const w = buf.writer();

    try w.print(
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{" ++
        "\"verdict\":\"{s}\"," ++
        "\"positive_score\":{d}," ++
        "\"negative_score\":{d}," ++
        "\"label_count\":{d}," ++
        "\"top_tag\":\"{s}\"," ++
        "\"labels\":[",
        .{
            id,
            rep.verdictStr(),
            rep.positive_score,
            rep.negative_score,
            rep.label_count,
            if (rep.top_tag) |t| t.toStr() else "none",
        },
    );

    var entries: [label_mod.MAX_LABELS_PER_ADDRESS]label_mod.LabelEntry = undefined;
    const n = ctx.bc.label_registry.listActive(address, &entries);
    for (entries[0..n], 0..) |e, i| {
        if (i > 0) try w.writeByte(',');
        const label_note = try rpc.jsonSanitize(alloc, e.noteSlice());
        defer alloc.free(label_note);
        try w.print(
            "{{\"id\":{d},\"reporter\":\"{s}\",\"tag\":\"{s}\",\"note\":\"{s}\"," ++
            "\"weight\":{d},\"block\":{d}}}",
            .{ e.id, e.reporterSlice(), e.tag.toStr(), label_note, e.weight, e.block_height },
        );
    }

    try w.writeAll("]}}");
    return buf.toOwnedSlice();
}

// ── removelabel — only original reporter can remove.
pub fn handleRemoveLabel(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc    = ctx.allocator;
    const from     = rpc.extractStr(body, "from")    orelse return rpc.errorJson(-32602, "Missing: from", id, alloc);
    const label_id = rpc.extractParamObjectU64(body, "label_id");
    const sig      = rpc.extractStr(body, "signature")  orelse return rpc.errorJson(-32602, "Missing: signature", id, alloc);
    const pubkey   = rpc.extractStr(body, "public_key") orelse return rpc.errorJson(-32602, "Missing: public_key", id, alloc);
    const nonce    = rpc.extractParamObjectU64(body, "nonce");

    const op_return = try std.fmt.allocPrint(alloc, "label_remove:{d}", .{label_id});
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

    const removed = ctx.bc.label_registry.remove(label_id, from);

    ctx.bc.mutex.lock();
    ctx.bc.mempool.append(tx) catch {
        ctx.bc.mutex.unlock();
        return rpc.errorJson(-32603, "Mempool full", id, alloc);
    };
    ctx.bc.mutex.unlock();

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"status\":\"queued\",\"txid\":\"{s}\",\"removed\":{s}}}}}",
        .{ id, canonical, if (removed) "true" else "false" });
}

// ── follow ────────────────────────────────────────────────────────────────────
pub fn handleFollow(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc  = ctx.allocator;
    const from   = rpc.extractStr(body, "from")   orelse return rpc.errorJson(-32602, "Missing: from", id, alloc);
    const target = rpc.extractStr(body, "target") orelse return rpc.errorJson(-32602, "Missing: target", id, alloc);
    const sig    = rpc.extractStr(body, "signature")  orelse return rpc.errorJson(-32602, "Missing: signature", id, alloc);
    const pubkey = rpc.extractStr(body, "public_key") orelse return rpc.errorJson(-32602, "Missing: public_key", id, alloc);
    const nonce  = rpc.extractParamObjectU64(body, "nonce");

    if (std.mem.eql(u8, from, target)) return rpc.errorJson(-32602, "Cannot follow yourself", id, alloc);

    const op_return = try std.fmt.allocPrint(alloc, "follow:{s}", .{target});
    defer alloc.free(op_return);

    const ts    = std.time.timestamp();
    const tx_id: u32 = @intCast(std.time.milliTimestamp() & 0xFFFFFFFF);
    const provisional = try std.fmt.allocPrint(alloc, "{d}{s}{d}", .{ tx_id, from, ts });
    defer alloc.free(provisional);

    var tx = blockchain_mod.Transaction{
        .id = tx_id, .from_address = from, .to_address = from,
        .amount = 0, .fee = social_mod.FOLLOW_FEE_SAT,
        .timestamp = ts, .nonce = nonce, .op_return = op_return,
        .signature = sig, .public_key = pubkey, .scheme = .omni_ecdsa, .hash = provisional,
    };
    const canonical = try std.fmt.allocPrint(alloc, "{s}", .{std.fmt.bytesToHex(tx.calculateHash(), .lower)});
    tx.hash = canonical;

    ctx.bc.social_graph.follow(from, target, @intCast(ctx.bc.getBlockCount())) catch {};

    ctx.bc.mutex.lock();
    ctx.bc.mempool.append(tx) catch { ctx.bc.mutex.unlock(); return rpc.errorJson(-32603, "Mempool full", id, alloc); };
    ctx.bc.mutex.unlock();

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"status\":\"queued\",\"txid\":\"{s}\",\"following\":\"{s}\"}}}}",
        .{ id, canonical, target });
}

// ── unfollow ──────────────────────────────────────────────────────────────────
pub fn handleUnfollow(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc  = ctx.allocator;
    const from   = rpc.extractStr(body, "from")   orelse return rpc.errorJson(-32602, "Missing: from", id, alloc);
    const target = rpc.extractStr(body, "target") orelse return rpc.errorJson(-32602, "Missing: target", id, alloc);
    const sig    = rpc.extractStr(body, "signature")  orelse return rpc.errorJson(-32602, "Missing: signature", id, alloc);
    const pubkey = rpc.extractStr(body, "public_key") orelse return rpc.errorJson(-32602, "Missing: public_key", id, alloc);
    const nonce  = rpc.extractParamObjectU64(body, "nonce");

    const op_return = try std.fmt.allocPrint(alloc, "unfollow:{s}", .{target});
    defer alloc.free(op_return);

    const ts    = std.time.timestamp();
    const tx_id: u32 = @intCast(std.time.milliTimestamp() & 0xFFFFFFFF);
    const provisional = try std.fmt.allocPrint(alloc, "{d}{s}{d}", .{ tx_id, from, ts });
    defer alloc.free(provisional);

    var tx = blockchain_mod.Transaction{
        .id = tx_id, .from_address = from, .to_address = from,
        .amount = 0, .fee = social_mod.FOLLOW_FEE_SAT,
        .timestamp = ts, .nonce = nonce, .op_return = op_return,
        .signature = sig, .public_key = pubkey, .scheme = .omni_ecdsa, .hash = provisional,
    };
    const canonical = try std.fmt.allocPrint(alloc, "{s}", .{std.fmt.bytesToHex(tx.calculateHash(), .lower)});
    tx.hash = canonical;

    ctx.bc.social_graph.unfollow(from, target);

    ctx.bc.mutex.lock();
    ctx.bc.mempool.append(tx) catch { ctx.bc.mutex.unlock(); return rpc.errorJson(-32603, "Mempool full", id, alloc); };
    ctx.bc.mutex.unlock();

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"status\":\"queued\",\"txid\":\"{s}\"}}}}",
        .{ id, canonical });
}

// ── getfollowers ──────────────────────────────────────────────────────────────
pub fn handleGetFollowers(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc   = ctx.allocator;
    const address = rpc.extractStr(body, "address") orelse return rpc.errorJson(-32602, "Missing: address", id, alloc);

    var addrs: [social_mod.MAX_LIST][]const u8 = undefined;
    const n     = ctx.bc.social_graph.getFollowers(address, &addrs);
    const count = ctx.bc.social_graph.followerCount(address);

    var buf = std.array_list.Managed(u8).init(alloc);
    defer buf.deinit();
    const w = buf.writer();
    try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"count\":{d},\"followers\":[", .{ id, count });
    for (addrs[0..n], 0..) |a, i| {
        if (i > 0) try w.writeByte(',');
        try w.print("\"{s}\"", .{a});
    }
    try w.writeAll("]}}");
    return buf.toOwnedSlice();
}

// ── getfollowing ──────────────────────────────────────────────────────────────
pub fn handleGetFollowing(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc   = ctx.allocator;
    const address = rpc.extractStr(body, "address") orelse return rpc.errorJson(-32602, "Missing: address", id, alloc);

    var addrs: [social_mod.MAX_LIST][]const u8 = undefined;
    const n     = ctx.bc.social_graph.getFollowing(address, &addrs);
    const count = ctx.bc.social_graph.followingCount(address);

    var buf = std.array_list.Managed(u8).init(alloc);
    defer buf.deinit();
    const w = buf.writer();
    try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"count\":{d},\"following\":[", .{ id, count });
    for (addrs[0..n], 0..) |a, i| {
        if (i > 0) try w.writeByte(',');
        try w.print("\"{s}\"", .{a});
    }
    try w.writeAll("]}}");
    return buf.toOwnedSlice();
}

// ── poap_createevent ──────────────────────────────────────────────────────────
// { "from":"ob1q...", "event_id":"conf2026", "name":"OmniBus Conf 2026",
//   "max_claims":500, "note":"...", "signature":"hex", "public_key":"hex", "nonce":N }
pub fn handlePoapCreateEvent(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc      = ctx.allocator;
    const from       = rpc.extractStr(body, "from")       orelse return rpc.errorJson(-32602, "Missing: from", id, alloc);
    const event_id   = rpc.extractStr(body, "event_id")   orelse return rpc.errorJson(-32602, "Missing: event_id", id, alloc);
    const name       = rpc.extractStr(body, "name")       orelse return rpc.errorJson(-32602, "Missing: name", id, alloc);
    const max_claims = rpc.extractParamObjectU64(body, "max_claims");
    const note       = rpc.extractStr(body, "note") orelse "";
    const sig        = rpc.extractStr(body, "signature")  orelse return rpc.errorJson(-32602, "Missing: signature", id, alloc);
    const pubkey     = rpc.extractStr(body, "public_key") orelse return rpc.errorJson(-32602, "Missing: public_key", id, alloc);
    const nonce      = rpc.extractParamObjectU64(body, "nonce");

    const op_return = try std.fmt.allocPrint(alloc, "poap_event:{s}:{s}:{d}:{s}", .{ event_id, name, max_claims, note });
    defer alloc.free(op_return);

    const ts    = std.time.timestamp();
    const tx_id: u32 = @intCast(std.time.milliTimestamp() & 0xFFFFFFFF);
    const provisional = try std.fmt.allocPrint(alloc, "{d}{s}{d}", .{ tx_id, from, ts });
    defer alloc.free(provisional);

    var tx = blockchain_mod.Transaction{
        .id = tx_id, .from_address = from, .to_address = from,
        .amount = 0, .fee = poap_mod.POAP_EVENT_FEE_SAT,
        .timestamp = ts, .nonce = nonce, .op_return = op_return,
        .signature = sig, .public_key = pubkey, .scheme = .omni_ecdsa, .hash = provisional,
    };
    const canonical = try std.fmt.allocPrint(alloc, "{s}", .{std.fmt.bytesToHex(tx.calculateHash(), .lower)});
    tx.hash = canonical;

    const parsed = poap_mod.parseEvent(op_return).?;
    ctx.bc.poap_registry.createEvent(from, parsed, @intCast(ctx.bc.getBlockCount())) catch {};

    ctx.bc.mutex.lock();
    ctx.bc.mempool.append(tx) catch { ctx.bc.mutex.unlock(); return rpc.errorJson(-32603, "Mempool full", id, alloc); };
    ctx.bc.mutex.unlock();

    const eid_safe = try rpc.jsonSanitize(alloc, event_id);
    defer alloc.free(eid_safe);
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"status\":\"queued\",\"txid\":\"{s}\",\"event_id\":\"{s}\",\"fee_sat\":{d}}}}}",
        .{ id, canonical, eid_safe, poap_mod.POAP_EVENT_FEE_SAT });
}

// ── poap_claim ────────────────────────────────────────────────────────────────
pub fn handlePoapClaim(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc    = ctx.allocator;
    const from     = rpc.extractStr(body, "from")     orelse return rpc.errorJson(-32602, "Missing: from", id, alloc);
    const event_id = rpc.extractStr(body, "event_id") orelse return rpc.errorJson(-32602, "Missing: event_id", id, alloc);
    const sig      = rpc.extractStr(body, "signature")  orelse return rpc.errorJson(-32602, "Missing: signature", id, alloc);
    const pubkey   = rpc.extractStr(body, "public_key") orelse return rpc.errorJson(-32602, "Missing: public_key", id, alloc);
    const nonce    = rpc.extractParamObjectU64(body, "nonce");

    const op_return = try std.fmt.allocPrint(alloc, "poap_claim:{s}", .{event_id});
    defer alloc.free(op_return);

    const ts    = std.time.timestamp();
    const tx_id: u32 = @intCast(std.time.milliTimestamp() & 0xFFFFFFFF);
    const provisional = try std.fmt.allocPrint(alloc, "{d}{s}{d}", .{ tx_id, from, ts });
    defer alloc.free(provisional);

    var tx = blockchain_mod.Transaction{
        .id = tx_id, .from_address = from, .to_address = from,
        .amount = 0, .fee = poap_mod.POAP_CLAIM_FEE_SAT,
        .timestamp = ts, .nonce = nonce, .op_return = op_return,
        .signature = sig, .public_key = pubkey, .scheme = .omni_ecdsa, .hash = provisional,
    };
    const canonical = try std.fmt.allocPrint(alloc, "{s}", .{std.fmt.bytesToHex(tx.calculateHash(), .lower)});
    tx.hash = canonical;

    ctx.bc.poap_registry.claimPoap(from, event_id, @intCast(ctx.bc.getBlockCount()), canonical) catch |err| {
        const msg = switch (err) {
            error.EventNotFound  => "Event not found",
            error.EventClosed    => "Event is closed or max claims reached",
            error.AlreadyClaimed => "Already claimed this POAP",
            else                 => "Claim failed",
        };
        return rpc.errorJson(-32001, msg, id, alloc);
    };

    ctx.bc.mutex.lock();
    ctx.bc.mempool.append(tx) catch { ctx.bc.mutex.unlock(); return rpc.errorJson(-32603, "Mempool full", id, alloc); };
    ctx.bc.mutex.unlock();

    const eid2_safe = try rpc.jsonSanitize(alloc, event_id);
    defer alloc.free(eid2_safe);
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"status\":\"queued\",\"txid\":\"{s}\",\"event_id\":\"{s}\"}}}}",
        .{ id, canonical, eid2_safe });
}

// ── poap_close ────────────────────────────────────────────────────────────────
pub fn handlePoapClose(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc    = ctx.allocator;
    const from     = rpc.extractStr(body, "from")     orelse return rpc.errorJson(-32602, "Missing: from", id, alloc);
    const event_id = rpc.extractStr(body, "event_id") orelse return rpc.errorJson(-32602, "Missing: event_id", id, alloc);
    const sig      = rpc.extractStr(body, "signature")  orelse return rpc.errorJson(-32602, "Missing: signature", id, alloc);
    const pubkey   = rpc.extractStr(body, "public_key") orelse return rpc.errorJson(-32602, "Missing: public_key", id, alloc);
    const nonce    = rpc.extractParamObjectU64(body, "nonce");

    const op_return = try std.fmt.allocPrint(alloc, "poap_close:{s}", .{event_id});
    defer alloc.free(op_return);

    const ts    = std.time.timestamp();
    const tx_id: u32 = @intCast(std.time.milliTimestamp() & 0xFFFFFFFF);
    const provisional = try std.fmt.allocPrint(alloc, "{d}{s}{d}", .{ tx_id, from, ts });
    defer alloc.free(provisional);

    var tx = blockchain_mod.Transaction{
        .id = tx_id, .from_address = from, .to_address = from,
        .amount = 0, .fee = 1000,
        .timestamp = ts, .nonce = nonce, .op_return = op_return,
        .signature = sig, .public_key = pubkey, .scheme = .omni_ecdsa, .hash = provisional,
    };
    const canonical = try std.fmt.allocPrint(alloc, "{s}", .{std.fmt.bytesToHex(tx.calculateHash(), .lower)});
    tx.hash = canonical;

    const closed = ctx.bc.poap_registry.closeEvent(event_id, from);

    ctx.bc.mutex.lock();
    ctx.bc.mempool.append(tx) catch { ctx.bc.mutex.unlock(); return rpc.errorJson(-32603, "Mempool full", id, alloc); };
    ctx.bc.mutex.unlock();

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"status\":\"queued\",\"txid\":\"{s}\",\"closed\":{s}}}}}",
        .{ id, canonical, if (closed) "true" else "false" });
}

// ── getpoaps — { "address":"ob1q..." } returns lista POAP-urilor unui wallet.
pub fn handleGetPoaps(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc   = ctx.allocator;
    const address = rpc.extractStr(body, "address") orelse return rpc.errorJson(-32602, "Missing: address", id, alloc);

    var claims: [64]poap_mod.PoapClaim = undefined;
    const n = ctx.bc.poap_registry.listClaims(address, &claims);

    var buf = std.array_list.Managed(u8).init(alloc);
    defer buf.deinit();
    const w = buf.writer();
    try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"poaps\":[", .{id});
    for (claims[0..n], 0..) |c, i| {
        if (i > 0) try w.writeByte(',');
        try w.writeAll("{\"event_id\":\"");
        try rpc.writeJsonSafeStr(w, c.eventIdSlice());
        try w.print("\",\"claim_block\":{d},\"tx_hash\":\"{s}\"}}", .{ c.claim_block, c.txHashSlice() });
    }
    try w.writeAll("]}}");
    return buf.toOwnedSlice();
}

// ── getpoapevent — { "event_id":"conf2026" }
pub fn handleGetPoapEvent(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc    = ctx.allocator;
    const event_id = rpc.extractStr(body, "event_id") orelse return rpc.errorJson(-32602, "Missing: event_id", id, alloc);

    const ev = ctx.bc.poap_registry.getEvent(event_id) orelse
        return std.fmt.allocPrint(alloc, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":null}}", .{id});

    const pev_id   = try rpc.jsonSanitize(alloc, ev.eventIdSlice());
    defer alloc.free(pev_id);
    const pev_name = try rpc.jsonSanitize(alloc, ev.nameSlice());
    defer alloc.free(pev_name);
    const pev_note = try rpc.jsonSanitize(alloc, ev.noteSlice());
    defer alloc.free(pev_note);
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{" ++
        "\"event_id\":\"{s}\",\"name\":\"{s}\"," ++
        "\"organizer\":\"{s}\",\"max_claims\":{d}," ++
        "\"claims_count\":{d},\"create_block\":{d}," ++
        "\"closed\":{s},\"note\":\"{s}\"}}}}",
        .{ id, pev_id, pev_name, ev.organizerSlice(),
           ev.max_claims, ev.claims_count, ev.create_block,
           if (ev.closed) "true" else "false", pev_note });
}
