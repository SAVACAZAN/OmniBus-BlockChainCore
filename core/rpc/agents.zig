// Agent registry JSON-RPC handlers — register/unregister/edit/list agents,
// agent decisions queue, execution reporting.

const std = @import("std");
const rpc = @import("../rpc_server.zig");
const blockchain_mod = @import("../blockchain.zig");
const agent_manager_mod = @import("../agent_manager.zig");
const agent_executor_mod = @import("../agent_executor.zig");
const main_mod = @import("../main.zig");

const ServerCtx = rpc.ServerCtx;

pub fn handleAgentRegister(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc      = ctx.allocator;
    const from_raw   = rpc.extractStr(body, "from") orelse return rpc.errorJson(-32602, "Missing: from", id, alloc);
    const name_raw   = rpc.extractStr(body, "name") orelse return rpc.errorJson(-32602, "Missing: name", id, alloc);
    const strategy_raw = rpc.extractStr(body, "strategy") orelse "custom";
    const fee_bps    = rpc.extractParamObjectU64(body, "fee_bps");
    const sig_raw    = rpc.extractStr(body, "signature")  orelse return rpc.errorJson(-32602, "Missing: signature", id, alloc);
    const pubkey_raw = rpc.extractStr(body, "public_key") orelse return rpc.errorJson(-32602, "Missing: public_key", id, alloc);
    const nonce      = rpc.extractParamObjectU64(body, "nonce");

    const from   = try alloc.dupe(u8, from_raw);
    const sig    = try alloc.dupe(u8, sig_raw);
    const pubkey = try alloc.dupe(u8, pubkey_raw);
    const op_return = try std.fmt.allocPrint(alloc, "agent:register:{s}:{s}:{d}", .{ name_raw, strategy_raw, fee_bps });

    const ts = std.time.timestamp();
    const tx_id: u32 = @intCast(std.time.milliTimestamp() & 0xFFFFFFFF);
    const provisional = try std.fmt.allocPrint(alloc, "{d}{s}{d}", .{ tx_id, from, ts });
    defer alloc.free(provisional);

    var tx = blockchain_mod.Transaction{
        .id = tx_id, .from_address = from, .to_address = from,
        .amount = 0, .fee = 1000, .timestamp = ts, .nonce = nonce,
        .op_return = op_return, .signature = sig, .public_key = pubkey,
        .scheme = .omni_ecdsa, .hash = provisional,
    };
    const hash_bytes = tx.calculateHash();
    const canonical = try std.fmt.allocPrint(alloc, "{s}", .{std.fmt.bytesToHex(hash_bytes, .lower)});
    tx.hash = canonical;

    ctx.bc.mutex.lock();
    ctx.bc.mempool.append(tx) catch {
        ctx.bc.mutex.unlock();
        alloc.free(from); alloc.free(sig); alloc.free(pubkey);
        alloc.free(op_return); alloc.free(canonical);
        return rpc.errorJson(-32603, "Mempool full", id, alloc);
    };
    ctx.bc.mutex.unlock();

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"status\":\"queued\",\"txid\":\"{s}\",\"agent_id\":{d}}}}}",
        .{ id, canonical, tx_id });
}

pub fn handleAgentUnregister(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc      = ctx.allocator;
    const from_raw   = rpc.extractStr(body, "from") orelse return rpc.errorJson(-32602, "Missing: from", id, alloc);
    const agent_id   = rpc.extractParamObjectU64(body, "agent_id");
    const sig_raw    = rpc.extractStr(body, "signature")  orelse return rpc.errorJson(-32602, "Missing: signature", id, alloc);
    const pubkey_raw = rpc.extractStr(body, "public_key") orelse return rpc.errorJson(-32602, "Missing: public_key", id, alloc);
    const nonce      = rpc.extractParamObjectU64(body, "nonce");

    const from   = try alloc.dupe(u8, from_raw);
    const sig    = try alloc.dupe(u8, sig_raw);
    const pubkey = try alloc.dupe(u8, pubkey_raw);
    const op_return = try std.fmt.allocPrint(alloc, "agent:unregister:{d}", .{agent_id});

    const ts = std.time.timestamp();
    const tx_id: u32 = @intCast(std.time.milliTimestamp() & 0xFFFFFFFF);
    const provisional = try std.fmt.allocPrint(alloc, "{d}{s}{d}", .{ tx_id, from, ts });
    defer alloc.free(provisional);

    var tx = blockchain_mod.Transaction{
        .id = tx_id, .from_address = from, .to_address = from,
        .amount = 0, .fee = 1000, .timestamp = ts, .nonce = nonce,
        .op_return = op_return, .signature = sig, .public_key = pubkey,
        .scheme = .omni_ecdsa, .hash = provisional,
    };
    const hash_bytes = tx.calculateHash();
    const canonical = try std.fmt.allocPrint(alloc, "{s}", .{std.fmt.bytesToHex(hash_bytes, .lower)});
    tx.hash = canonical;

    ctx.bc.mutex.lock();
    ctx.bc.mempool.append(tx) catch {
        ctx.bc.mutex.unlock();
        alloc.free(from); alloc.free(sig); alloc.free(pubkey);
        alloc.free(op_return); alloc.free(canonical);
        return rpc.errorJson(-32603, "Mempool full", id, alloc);
    };
    ctx.bc.mutex.unlock();

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"status\":\"queued\",\"txid\":\"{s}\"}}}}",
        .{ id, canonical });
}

pub fn handleAgentEdit(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    // Fix B8: was accepting any garbage and returning "ok". Now validates
    // required params so callers get -32602 for malformed requests.
    _ = rpc.extractStr(body, "from") orelse return rpc.errorJson(-32602, "Missing: from", id, alloc);
    const agent_id = rpc.extractParamObjectU64(body, "agent_id");
    if (agent_id == 0) return rpc.errorJson(-32602, "Missing or invalid: agent_id", id, alloc);
    _ = rpc.extractStr(body, "signature")  orelse return rpc.errorJson(-32602, "Missing: signature", id, alloc);
    _ = rpc.extractStr(body, "public_key") orelse return rpc.errorJson(-32602, "Missing: public_key", id, alloc);
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"status\":\"ok\",\"agent_id\":{d}}}}}", .{ id, agent_id });
}

pub fn handleAgentFollow(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    _ = rpc.extractStr(body, "from") orelse return rpc.errorJson(-32602, "Missing: from", id, alloc);
    const agent_id = rpc.extractParamObjectU64(body, "agent_id");
    if (agent_id == 0) return rpc.errorJson(-32602, "Missing or invalid: agent_id", id, alloc);
    _ = rpc.extractStr(body, "signature")  orelse return rpc.errorJson(-32602, "Missing: signature", id, alloc);
    _ = rpc.extractStr(body, "public_key") orelse return rpc.errorJson(-32602, "Missing: public_key", id, alloc);
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"status\":\"ok\",\"agent_id\":{d}}}}}", .{ id, agent_id });
}

pub fn handleGetAgents(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    _ = body;
    const alloc = ctx.allocator;

    var buf = std.array_list.Managed(u8).init(alloc);
    defer buf.deinit();
    const w = buf.writer();
    try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"agents\":[", .{id});

    var first = true;
    for (&main_mod.g_agent_manager.slots) |*slot| {
        if (!slot.used) continue;
        if (!first) try w.writeAll(",");
        first = false;
        const owner = if (slot.canSign()) slot.wallet.?.getAddress() else "";
        try w.print(
            "{{\"id\":{d},\"owner\":\"{s}\",\"name\":\"",
            .{ slot.config.wallet_index, owner },
        );
        try rpc.writeJsonSafeStr(w, slot.config.getName());
        try w.print(
            "\",\"strategy\":\"custom\",\"fee_bps\":0,\"registered_at_block\":0,\"decisions_made\":{d},\"decisions_ok\":{d},\"profit_omni_total\":{d},\"followers\":0,\"status\":\"active\",\"reputation_total\":0}}",
            .{ slot.stats.decisions_emitted, slot.stats.txs_submitted, slot.stats.total_mined_sat },
        );
    }
    try w.writeAll("]}}");
    return buf.toOwnedSlice();
}

pub fn handleGetAgent(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    _ = body;
    const alloc = ctx.allocator;
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":null}}", .{id});
}

pub fn handleAgentList(ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    var snap_buf: [agent_manager_mod.MAX_AGENTS]agent_manager_mod.AgentSnapshotItem = undefined;
    const n = main_mod.g_agent_manager.snapshot(&snap_buf);

    var buf = std.array_list.Managed(u8).init(alloc);
    errdefer buf.deinit();
    const w = buf.writer();

    try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"count\":{d},\"agents\":[", .{ id, n });
    for (snap_buf[0..n], 0..) |a, i| {
        if (i > 0) try w.writeByte(',');
        try w.writeAll("{\"name\":\"");
        try rpc.writeJsonSafeStr(w, a.getName());
        try w.print(
            "\",\"wallet_index\":{d},\"address\":\"{s}\",\"strategy\":\"{s}\",\"tier\":\"{s}\",\"balance_sat\":{d},\"staked_sat\":{d},\"lp_locked_sat\":{d},\"pnl_session_sat\":{d},\"halted\":{},\"stats\":{{\"ticks\":{d},\"decisions_emitted\":{d},\"decisions_queued\":{d},\"exec_success\":{d},\"exec_failed\":{d},\"tier_transitions\":{d},\"total_mined_sat\":{d}}}}}",
            .{
                a.wallet_index,
                a.getAddress(),
                a.strategy.name(),
                @tagName(a.tier),
                a.balance_sat,
                a.staked_sat,
                a.lp_locked_sat,
                a.pnl_session_sat,
                a.halted,
                a.stats.ticks,
                a.stats.decisions_emitted,
                a.stats.decisions_queued,
                a.stats.exec_success,
                a.stats.exec_failed,
                a.stats.tier_transitions,
                a.stats.total_mined_sat,
            },
        );
    }
    try w.writeAll("]}}");
    return buf.toOwnedSlice();
}

/// RPC `agent_status` — detalii pentru un singur agent (filtrat dupa wallet_index).
/// Body: {"wallet_index": N}
pub fn handleAgentStatus(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const wi = extractU32Param(body, "\"wallet_index\"") orelse return rpc.errorJson(-32602, "missing wallet_index", id, alloc);
    const slot = main_mod.g_agent_manager.findByWalletIndex(wi) orelse return rpc.errorJson(-32000, "agent not found", id, alloc);

    const name_safe = try rpc.jsonSanitize(alloc, slot.config.getName());
    defer alloc.free(name_safe);
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"name\":\"{s}\",\"wallet_index\":{d},\"address\":\"{s}\",\"strategy\":\"{s}\",\"tier\":\"{s}\",\"balance_sat\":{d},\"staked_sat\":{d},\"lp_locked_sat\":{d},\"pnl_session_sat\":{d},\"halted\":{},\"stats\":{{\"ticks\":{d},\"decisions_emitted\":{d},\"decisions_queued\":{d},\"exec_success\":{d},\"exec_failed\":{d},\"tier_transitions\":{d},\"total_mined_sat\":{d}}}}}}}",
        .{
            id,
            name_safe,
            slot.config.wallet_index,
            slot.getAddress(),
            slot.config.strategy.name(),
            @tagName(slot.executor.state.tier),
            slot.executor.state.balance_sat,
            slot.executor.state.staked_sat,
            slot.executor.state.lp_locked_sat,
            slot.executor.state.pnl_session_sat,
            slot.executor.state.halted,
            slot.stats.ticks,
            slot.stats.decisions_emitted,
            slot.stats.decisions_queued,
            slot.stats.exec_success,
            slot.stats.exec_failed,
            slot.stats.tier_transitions,
            slot.stats.total_mined_sat,
        },
    );
}

/// RPC `agent_pending_decisions` — decizii non-native nesettled, pentru clientul extern.
/// Body opțional: {"wallet_index": N} pentru filtrare per agent.
/// Răspuns: { "decisions": [ {id, wallet_index, block_height, emitted_ms, venue,
///   kind, pair, amount_sat, reason}, ... ] }
pub fn handleAgentPendingDecisions(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const filter_wi = extractU32Param(body, "\"wallet_index\"");

    var pend_buf: [agent_manager_mod.MAX_PENDING_DECISIONS]agent_manager_mod.PendingDecision = undefined;
    const n = main_mod.g_agent_manager.snapshotPending(&pend_buf, filter_wi);

    var buf = std.array_list.Managed(u8).init(alloc);
    errdefer buf.deinit();
    const w = buf.writer();

    try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"count\":{d},\"decisions\":[", .{ id, n });
    for (pend_buf[0..n], 0..) |p, i| {
        if (i > 0) try w.writeByte(',');
        try w.print(
            "{{\"id\":{d},\"wallet_index\":{d},\"block_height\":{d},\"emitted_ms\":{d},\"venue\":\"{s}\",\"kind\":\"{s}\",\"pair\":\"{s}\",\"amount_sat\":{d},\"reason\":\"",
            .{
                p.id,
                p.wallet_index,
                p.block_height,
                p.emitted_ms,
                p.decision.venue.name(),
                @tagName(p.decision.kind),
                p.decision.getPair(),
                p.decision.amount_sat,
            },
        );
        try rpc.writeJsonSafeStr(w, p.decision.getReason());
        try w.writeAll("\"}");
    }
    try w.writeAll("]}}");
    return buf.toOwnedSlice();
}

/// RPC `agent_report_execution` — clientul extern raportează rezultatul.
/// Body: {"decision_id": N, "status": "success|rejected|network_error|timeout|cancelled",
///        "external_id": "LCX-12345", "filled_amount_sat": 1000, "fill_price_micro_usd": 65000000000,
///        "error_msg": "..." }
pub fn handleAgentReportExecution(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const decision_id = extractU64Param(body, "\"decision_id\"") orelse return rpc.errorJson(-32602, "missing decision_id", id, alloc);
    const status_str = extractStrParam(body, "\"status\"") orelse return rpc.errorJson(-32602, "missing status", id, alloc);

    const status: agent_manager_mod.ExecStatus = blk: {
        if (std.mem.eql(u8, status_str, "success")) break :blk .success;
        if (std.mem.eql(u8, status_str, "rejected")) break :blk .rejected;
        if (std.mem.eql(u8, status_str, "network_error")) break :blk .network_error;
        if (std.mem.eql(u8, status_str, "timeout")) break :blk .timeout;
        if (std.mem.eql(u8, status_str, "cancelled")) break :blk .cancelled;
        return rpc.errorJson(-32602, "invalid status", id, alloc);
    };

    var receipt = agent_manager_mod.ExecReceipt{
        .decision_id = decision_id,
        .status = status,
        .filled_amount_sat = extractU64Param(body, "\"filled_amount_sat\"") orelse 0,
        .fill_price_micro_usd = extractU64Param(body, "\"fill_price_micro_usd\"") orelse 0,
        .reported_ms = std.time.milliTimestamp(),
    };
    if (extractStrParam(body, "\"external_id\"")) |eid| receipt.setExternalId(eid);
    if (extractStrParam(body, "\"error_msg\"")) |msg| receipt.setErrorMsg(msg);

    const ok = main_mod.g_agent_manager.applyReceipt(receipt);
    if (!ok) return rpc.errorJson(-32000, "decision not found or already settled", id, alloc);

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"decision_id\":{d},\"applied\":true,\"status\":\"{s}\"}}}}",
        .{ id, decision_id, status_str },
    );
}

// ─── File-private helpers — duplicated from rpc_server.zig (not exported there).
// TODO: promote to pub in rpc_server.zig and use rpc.extractU32Param etc.

fn extractU32Param(body: []const u8, key_with_quotes: []const u8) ?u32 {
    const at = std.mem.indexOf(u8, body, key_with_quotes) orelse return null;
    var i: usize = at + key_with_quotes.len;
    // Sari peste : si whitespace.
    while (i < body.len and (body[i] == ':' or body[i] == ' ' or body[i] == '\t')) : (i += 1) {}
    const start = i;
    while (i < body.len and body[i] >= '0' and body[i] <= '9') : (i += 1) {}
    if (i == start) return null;
    return std.fmt.parseInt(u32, body[start..i], 10) catch null;
}

fn extractU64Param(body: []const u8, key_with_quotes: []const u8) ?u64 {
    const at = std.mem.indexOf(u8, body, key_with_quotes) orelse return null;
    var i: usize = at + key_with_quotes.len;
    while (i < body.len and (body[i] == ':' or body[i] == ' ' or body[i] == '\t')) : (i += 1) {}
    const start = i;
    while (i < body.len and body[i] >= '0' and body[i] <= '9') : (i += 1) {}
    if (i == start) return null;
    return std.fmt.parseInt(u64, body[start..i], 10) catch null;
}

/// Extrage un parametru string. Returneaza slice peste body (nu copiaza).
fn extractStrParam(body: []const u8, key_with_quotes: []const u8) ?[]const u8 {
    const at = std.mem.indexOf(u8, body, key_with_quotes) orelse return null;
    var i: usize = at + key_with_quotes.len;
    while (i < body.len and (body[i] == ':' or body[i] == ' ' or body[i] == '\t')) : (i += 1) {}
    if (i >= body.len or body[i] != '"') return null;
    i += 1;
    const start = i;
    while (i < body.len and body[i] != '"') : (i += 1) {}
    if (i >= body.len) return null;
    return body[start..i];
}
