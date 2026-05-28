// Advanced-wallet JSON-RPC handlers — cold storage, timelocks, covenants,
// multi-sig treasury. These wrap dedicated modules (cold_wallet.zig,
// timelock_vault.zig, covenant.zig, treasury_multi.zig). The TX-creation
// pattern is identical to rpc/social.zig: build op_return, append to
// mempool, optimistically update in-memory registry so reads reflect the
// change before the block is mined.

const std = @import("std");
const rpc = @import("../rpc_server.zig");
const blockchain_mod = @import("../blockchain.zig");
const cold_wallet_mod = @import("../cold_wallet.zig");
const timelock_mod = @import("../timelock_vault.zig");
const covenant_mod = @import("../covenant.zig");
const treasury_multi_mod = @import("../treasury_multi.zig");

const ServerCtx = rpc.ServerCtx;

// ═══════════════════════════════════════════════════════════════════════════
// ── Cold Wallet (watch-only) handlers ─────────────────────────────────────
// ═══════════════════════════════════════════════════════════════════════════

/// coldwallet_add {"address":"ob1q...","label":"savings"}
pub fn handleColdWalletAdd(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const address = rpc.extractParamObjectField(body, "address") orelse
        return rpc.errorJson(-32602, "Missing param: address", id, alloc);
    const label = rpc.extractParamObjectField(body, "label") orelse "";
    if (address.len < 8)
        return rpc.errorJson(-32602, "Invalid address", id, alloc);
    const ok = ctx.bc.cold_wallet_store.add(address, label);
    if (!ok)
        return rpc.errorJson(-32000,
            "Add failed: address already watched, store full, or label has forbidden chars (printable ASCII only, no quotes or backslashes)",
            id, alloc);
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"address\":\"{s}\",\"label\":\"{s}\",\"status\":\"added\"}}}}",
        .{ id, address, label });
}

/// coldwallet_list {} — lists all watch-only wallets with current balances
pub fn handleColdWalletList(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    _ = body;
    const alloc = ctx.allocator;
    const buf = try alloc.alloc(cold_wallet_mod.ColdWallet, cold_wallet_mod.MAX_ENTRIES);
    defer alloc.free(buf);
    const n = ctx.bc.cold_wallet_store.listAll(buf);
    var out = std.ArrayList(u8){};
    defer out.deinit(alloc);
    try out.appendSlice(alloc, "[");
    for (buf[0..n], 0..) |w, i| {
        if (i > 0) try out.appendSlice(alloc, ",");
        const live_bal = ctx.bc.getAddressBalance(w.addressSlice());
        const entry = try std.fmt.allocPrint(alloc,
            "{{\"address\":\"{s}\",\"label\":\"{s}\",\"balance_sat\":{d},\"total_received_sat\":{d},\"created\":{d}}}",
            .{ w.addressSlice(), w.labelSlice(), live_bal, w.total_received_sat, w.created_unix_s });
        defer alloc.free(entry);
        try out.appendSlice(alloc, entry);
    }
    try out.appendSlice(alloc, "]");
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{s}}}",
        .{ id, out.items });
}

/// coldwallet_remove {"address":"ob1q..."}
pub fn handleColdWalletRemove(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const address = rpc.extractParamObjectField(body, "address") orelse
        return rpc.errorJson(-32602, "Missing param: address", id, alloc);
    const ok = ctx.bc.cold_wallet_store.remove(address);
    if (!ok)
        return rpc.errorJson(-32000, "Address not found in watch list", id, alloc);
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"address\":\"{s}\",\"status\":\"removed\"}}}}",
        .{ id, address });
}

/// coldwallet_history {"address":"ob1q...","limit":50}
pub fn handleColdWalletHistory(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const address = rpc.extractParamObjectField(body, "address") orelse
        return rpc.errorJson(-32602, "Missing param: address", id, alloc);
    const limit_raw = rpc.extractParamObjectU64(body, "limit");
    const limit: usize = if (limit_raw > 0 and limit_raw <= 500) @intCast(limit_raw) else 50;
    // Reuse address TX index
    const tx_hashes = ctx.bc.address_tx_index.get(address) orelse {
        return std.fmt.allocPrint(alloc,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":[]}}",
            .{id});
    };
    var out = std.ArrayList(u8){};
    defer out.deinit(alloc);
    try out.appendSlice(alloc, "[");
    const start: usize = if (tx_hashes.items.len > limit) tx_hashes.items.len - limit else 0;
    var first = true;
    for (tx_hashes.items[start..]) |tx_hash| {
        // Find TX in chain (scan blocks — lightweight for watch-only auditing)
        for (ctx.bc.chain.items) |*blk| {
            for (blk.transactions.items) |tx| {
                if (!std.mem.eql(u8, tx.hash, tx_hash)) continue;
                if (!std.mem.eql(u8, tx.to_address, address)) continue; // only incoming
                if (!first) try out.appendSlice(alloc, ",");
                first = false;
                const entry = try std.fmt.allocPrint(alloc,
                    "{{\"tx_hash\":\"{s}\",\"from\":\"{s}\",\"amount_sat\":{d},\"block\":{d}}}",
                    .{ tx.hash, tx.from_address, tx.amount,
                       ctx.bc.tx_block_height.get(tx.hash) orelse 0 });
                defer alloc.free(entry);
                try out.appendSlice(alloc, entry);
                break;
            }
        }
    }
    try out.appendSlice(alloc, "]");
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{s}}}",
        .{ id, out.items });
}

// ═══════════════════════════════════════════════════════════════════════════
// ── Timelock Vault (CLTV) handlers ────────────────────────────────────────
// ═══════════════════════════════════════════════════════════════════════════

/// timelock_create {"owner":"ob1q...","dest":"ob1q...","amount_sat":N,"unlock_block":B}
pub fn handleTimelockCreate(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const owner = rpc.extractParamObjectField(body, "owner") orelse
        return rpc.errorJson(-32602, "Missing param: owner", id, alloc);
    const dest = rpc.extractParamObjectField(body, "dest") orelse
        return rpc.errorJson(-32602, "Missing param: dest", id, alloc);
    const amount_sat = rpc.extractParamObjectU64(body, "amount_sat");
    if (amount_sat == 0) return rpc.errorJson(-32602, "Missing/zero param: amount_sat", id, alloc);
    const unlock_block = rpc.extractParamObjectU64(body, "unlock_block");
    if (unlock_block == 0) return rpc.errorJson(-32602, "Missing/zero param: unlock_block", id, alloc);

    const current_block: u64 = @intCast(ctx.bc.getBlockCount());
    if (unlock_block <= current_block)
        return rpc.errorJson(-32602, "unlock_block must be in the future", id, alloc);

    const owner_bal = ctx.bc.getAddressBalance(owner);
    if (owner_bal < amount_sat)
        return rpc.errorJson(-32000, "Insufficient balance to lock", id, alloc);

    // Debit owner balance (funds held in vault)
    ctx.bc.mutex.lock();
    const cur_bal = ctx.bc.balances.get(owner) orelse 0;
    if (cur_bal >= amount_sat) {
        ctx.bc.balances.put(owner, cur_bal - amount_sat) catch {};
    }
    ctx.bc.mutex.unlock();

    const id_hex = ctx.bc.timelock_store.create(
        owner, dest, amount_sat, unlock_block, current_block, "",
    ) catch {
        // Restore balance on failure
        ctx.bc.mutex.lock();
        const b2 = ctx.bc.balances.get(owner) orelse 0;
        ctx.bc.balances.put(owner, b2 + amount_sat) catch {};
        ctx.bc.mutex.unlock();
        return rpc.errorJson(-32000, "Failed to create timelock vault", id, alloc);
    };

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"vault_id\":\"{s}\",\"owner\":\"{s}\",\"dest\":\"{s}\",\"amount_sat\":{d},\"unlock_block\":{d},\"state\":\"locked\"}}}}",
        .{ id, id_hex, owner, dest, amount_sat, unlock_block });
}

/// timelock_list {"owner":"ob1q..."}
pub fn handleTimelockList(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const owner = rpc.extractParamObjectField(body, "owner") orelse
        return rpc.errorJson(-32602, "Missing param: owner", id, alloc);
    const current_block: u64 = @intCast(ctx.bc.getBlockCount());
    var vaults: [256]timelock_mod.TimelockVault = undefined;
    const n = ctx.bc.timelock_store.listByOwner(owner, &vaults);
    var out = std.ArrayList(u8){};
    defer out.deinit(alloc);
    try out.appendSlice(alloc, "[");
    for (vaults[0..n], 0..) |v, i| {
        if (i > 0) try out.appendSlice(alloc, ",");
        const remaining = v.blocksRemaining(current_block);
        const entry = try std.fmt.allocPrint(alloc,
            "{{\"vault_id\":\"{s}\",\"dest\":\"{s}\",\"amount_sat\":{d},\"unlock_block\":{d},\"state\":\"{s}\",\"blocks_remaining\":{d}}}",
            .{ v.idSlice(), v.destSlice(), v.amount_sat, v.unlock_block, v.state.str(), remaining });
        defer alloc.free(entry);
        try out.appendSlice(alloc, entry);
    }
    try out.appendSlice(alloc, "]");
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{s}}}",
        .{ id, out.items });
}

/// timelock_spend {"vault_id":"hex..."}
pub fn handleTimelockSpend(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const vault_id = rpc.extractParamObjectField(body, "vault_id") orelse
        return rpc.errorJson(-32602, "Missing param: vault_id", id, alloc);
    const current_block: u64 = @intCast(ctx.bc.getBlockCount());
    const vault = ctx.bc.timelock_store.getById(vault_id) orelse
        return rpc.errorJson(-32000, "Vault not found", id, alloc);
    if (vault.state == .spent)
        return rpc.errorJson(-32000, "Vault already spent", id, alloc);
    if (current_block < vault.unlock_block)
        return rpc.errorJson(-32000, "Vault still locked — too early", id, alloc);

    // Mark spent and credit destination
    const ok = ctx.bc.timelock_store.markSpent(vault_id, "manual_spend", current_block);
    if (!ok) return rpc.errorJson(-32000, "Failed to mark vault spent", id, alloc);

    ctx.bc.mutex.lock();
    const dest_bal = ctx.bc.balances.get(vault.destSlice()) orelse 0;
    ctx.bc.balances.put(vault.destSlice(), dest_bal + vault.amount_sat) catch {};
    ctx.bc.mutex.unlock();

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"vault_id\":\"{s}\",\"dest\":\"{s}\",\"amount_sat\":{d},\"state\":\"spent\"}}}}",
        .{ id, vault_id, vault.destSlice(), vault.amount_sat });
}

/// timelock_status {"vault_id":"hex..."}
pub fn handleTimelockStatus(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const vault_id = rpc.extractParamObjectField(body, "vault_id") orelse
        return rpc.errorJson(-32602, "Missing param: vault_id", id, alloc);
    const current_block: u64 = @intCast(ctx.bc.getBlockCount());
    const vault = ctx.bc.timelock_store.getById(vault_id) orelse
        return rpc.errorJson(-32000, "Vault not found", id, alloc);
    const remaining = vault.blocksRemaining(current_block);
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"vault_id\":\"{s}\",\"owner\":\"{s}\",\"dest\":\"{s}\",\"amount_sat\":{d},\"unlock_block\":{d},\"state\":\"{s}\",\"blocks_remaining\":{d},\"created_block\":{d}}}}}",
        .{ id, vault.idSlice(), vault.ownerSlice(), vault.destSlice(),
           vault.amount_sat, vault.unlock_block, vault.state.str(), remaining, vault.created_block });
}

// ═══════════════════════════════════════════════════════════════════════════
// ── Covenant (destination whitelist) handlers ─────────────────────────────
// ═══════════════════════════════════════════════════════════════════════════

/// covenant_create {"address":"ob1q...","whitelist":["ob1q..."],"max_per_tx_sat":0,"expires_block":0,"label":"..."}
pub fn handleCovenantCreate(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const address = rpc.extractParamObjectField(body, "address") orelse
        return rpc.errorJson(-32602, "Missing param: address", id, alloc);
    const max_per_tx = rpc.extractParamObjectU64(body, "max_per_tx_sat");
    const expires_block = rpc.extractParamObjectU64(body, "expires_block");
    const label = rpc.extractParamObjectField(body, "label") orelse "";

    // Parse whitelist array from JSON: look for [...] after "whitelist"
    const wl_needle = "\"whitelist\"";
    const wl_pos = std.mem.indexOf(u8, body, wl_needle) orelse
        return rpc.errorJson(-32602, "Missing param: whitelist", id, alloc);
    const bracket = std.mem.indexOfScalarPos(u8, body, wl_pos, '[') orelse
        return rpc.errorJson(-32602, "whitelist must be a JSON array", id, alloc);

    var whitelist_strs: [covenant_mod.MAX_WHITELIST][]const u8 = undefined;
    var wl_count: usize = 0;
    var parse_pos: usize = bracket + 1;
    while (parse_pos < body.len and wl_count < covenant_mod.MAX_WHITELIST) {
        while (parse_pos < body.len and (body[parse_pos] == ' ' or body[parse_pos] == '\t' or body[parse_pos] == '\n')) parse_pos += 1;
        if (parse_pos >= body.len or body[parse_pos] == ']') break;
        if (body[parse_pos] == '"') {
            parse_pos += 1;
            const start = parse_pos;
            while (parse_pos < body.len and body[parse_pos] != '"') parse_pos += 1;
            whitelist_strs[wl_count] = body[start..parse_pos];
            wl_count += 1;
            if (parse_pos < body.len) parse_pos += 1;
        } else {
            while (parse_pos < body.len and body[parse_pos] != ',' and body[parse_pos] != ']') parse_pos += 1;
        }
        if (parse_pos < body.len and body[parse_pos] == ',') parse_pos += 1;
    }

    if (wl_count == 0)
        return rpc.errorJson(-32602, "whitelist must contain at least one address", id, alloc);

    ctx.bc.covenant_store.create(
        address, whitelist_strs[0..wl_count], max_per_tx, expires_block, label,
    ) catch {
        return rpc.errorJson(-32000, "Failed to create covenant", id, alloc);
    };

    const cov_label = try rpc.jsonSanitize(alloc, label);
    defer alloc.free(cov_label);
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"address\":\"{s}\",\"whitelist_count\":{d},\"max_per_tx_sat\":{d},\"expires_block\":{d},\"label\":\"{s}\",\"status\":\"created\"}}}}",
        .{ id, address, wl_count, max_per_tx, expires_block, cov_label });
}

/// covenant_list {} — lists all active covenants
pub fn handleCovenantList(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    _ = body;
    const alloc = ctx.allocator;
    const current_block: u64 = @intCast(ctx.bc.getBlockCount());
    const buf = try alloc.alloc(covenant_mod.Covenant, covenant_mod.MAX_COVENANTS);
    defer alloc.free(buf);
    const n = ctx.bc.covenant_store.listAll(current_block, buf);
    var out = std.ArrayList(u8){};
    defer out.deinit(alloc);
    try out.appendSlice(alloc, "[");
    for (buf[0..n], 0..) |c, i| {
        if (i > 0) try out.appendSlice(alloc, ",");
        const cl_safe = try rpc.jsonSanitize(alloc, c.labelSlice());
        defer alloc.free(cl_safe);
        const entry = try std.fmt.allocPrint(alloc,
            "{{\"address\":\"{s}\",\"whitelist_count\":{d},\"max_per_tx_sat\":{d},\"expires_block\":{d},\"label\":\"{s}\"}}",
            .{ c.addressSlice(), c.whitelist_count, c.max_amount_per_tx_sat, c.expires_block, cl_safe });
        defer alloc.free(entry);
        try out.appendSlice(alloc, entry);
    }
    try out.appendSlice(alloc, "]");
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{s}}}",
        .{ id, out.items });
}

/// covenant_get {"address":"ob1q..."}
pub fn handleCovenantGet(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const address = rpc.extractParamObjectField(body, "address") orelse
        return rpc.errorJson(-32602, "Missing param: address", id, alloc);
    const current_block: u64 = @intCast(ctx.bc.getBlockCount());
    const cov = ctx.bc.covenant_store.getActive(address, current_block) orelse
        return rpc.errorJson(-32000, "No active covenant for address", id, alloc);

    var wl_json = std.ArrayList(u8){};
    defer wl_json.deinit(alloc);
    try wl_json.appendSlice(alloc, "[");
    var wi: usize = 0;
    while (wi < cov.whitelist_count) : (wi += 1) {
        if (wi > 0) try wl_json.appendSlice(alloc, ",");
        const wentry = try std.fmt.allocPrint(alloc, "\"{s}\"", .{cov.whitelistEntry(wi)});
        defer alloc.free(wentry);
        try wl_json.appendSlice(alloc, wentry);
    }
    try wl_json.appendSlice(alloc, "]");

    const cget_label = try rpc.jsonSanitize(alloc, cov.labelSlice());
    defer alloc.free(cget_label);
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"address\":\"{s}\",\"whitelist\":{s},\"max_per_tx_sat\":{d},\"expires_block\":{d},\"label\":\"{s}\"}}}}",
        .{ id, cov.addressSlice(), wl_json.items, cov.max_amount_per_tx_sat, cov.expires_block, cget_label });
}

/// covenant_remove {"address":"ob1q..."}
pub fn handleCovenantRemove(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const address = rpc.extractParamObjectField(body, "address") orelse
        return rpc.errorJson(-32602, "Missing param: address", id, alloc);
    const ok = ctx.bc.covenant_store.remove(address);
    if (!ok) return rpc.errorJson(-32000, "No active covenant found for address", id, alloc);
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"address\":\"{s}\",\"status\":\"removed\"}}}}",
        .{ id, address });
}

// ═══════════════════════════════════════════════════════════════════════════
// ── Treasury auto-distribute handlers ────────────────────────────────────
// ═══════════════════════════════════════════════════════════════════════════

/// treasury_create {"address":"ob1q...","destinations":[{"address":"ob1q...","share_bps":5000,"label":"x"}],"trigger_amount_sat":100000000,"label":"..."}
pub fn handleTreasuryCreate(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const treasury_addr = rpc.extractParamObjectField(body, "address") orelse
        return rpc.errorJson(-32602, "Missing param: address", id, alloc);
    const trigger = rpc.extractParamObjectU64(body, "trigger_amount_sat");
    const label = rpc.extractParamObjectField(body, "label") orelse "";

    // Parse destinations array
    const dest_needle = "\"destinations\"";
    const dest_pos = std.mem.indexOf(u8, body, dest_needle) orelse
        return rpc.errorJson(-32602, "Missing param: destinations", id, alloc);
    const bracket = std.mem.indexOfScalarPos(u8, body, dest_pos, '[') orelse
        return rpc.errorJson(-32602, "destinations must be a JSON array", id, alloc);

    var dests: [treasury_multi_mod.MAX_DESTS]treasury_multi_mod.TreasuryDest = undefined;
    var dest_count: usize = 0;
    var pp: usize = bracket + 1;
    while (pp < body.len and dest_count < treasury_multi_mod.MAX_DESTS) {
        while (pp < body.len and (body[pp] == ' ' or body[pp] == '\t' or body[pp] == '\n' or body[pp] == ',')) pp += 1;
        if (pp >= body.len or body[pp] == ']') break;
        if (body[pp] != '{') { pp += 1; continue; }
        // Find end of object
        var depth: i32 = 0;
        const obj_start = pp;
        var obj_end = pp;
        while (pp < body.len) : (pp += 1) {
            if (body[pp] == '{') depth += 1
            else if (body[pp] == '}') {
                depth -= 1;
                if (depth == 0) { obj_end = pp + 1; pp += 1; break; }
            }
        }
        const obj = body[obj_start..obj_end];
        const d_addr = rpc.extractStr(obj, "address") orelse continue;
        const d_bps_raw = rpc.extractParamObjectU64(obj, "share_bps");
        const d_label = rpc.extractStr(obj, "label") orelse "";
        var d = treasury_multi_mod.TreasuryDest{ .share_bps = @intCast(@min(d_bps_raw, 10000)) };
        const ac = @min(d_addr.len, treasury_multi_mod.ADDR_MAX - 1);
        @memcpy(d.address[0..ac], d_addr[0..ac]);
        d.addr_len = @intCast(ac);
        const lc = @min(d_label.len, treasury_multi_mod.LABEL_MAX - 1);
        @memcpy(d.label[0..lc], d_label[0..lc]);
        d.label_len = @intCast(lc);
        dests[dest_count] = d;
        dest_count += 1;
    }

    if (dest_count == 0)
        return rpc.errorJson(-32602, "destinations must have at least one entry", id, alloc);

    const id_hex = ctx.bc.treasury_multi_store.create(
        treasury_addr, dests[0..dest_count], trigger, label,
    ) catch {
        return rpc.errorJson(-32000, "Failed to create treasury (check share_bps sum = 10000)", id, alloc);
    };

    const treas_label = try rpc.jsonSanitize(alloc, label);
    defer alloc.free(treas_label);
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"treasury_id\":\"{s}\",\"address\":\"{s}\",\"dest_count\":{d},\"trigger_amount_sat\":{d},\"label\":\"{s}\",\"status\":\"created\"}}}}",
        .{ id, id_hex, treasury_addr, dest_count, trigger, treas_label });
}

/// treasury_list {} — list all active treasuries
pub fn handleTreasuryList(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    _ = body;
    const alloc = ctx.allocator;
    const buf = try alloc.alloc(treasury_multi_mod.Treasury, treasury_multi_mod.MAX_TREASURY);
    defer alloc.free(buf);
    const n = ctx.bc.treasury_multi_store.listAll(buf);
    var out = std.ArrayList(u8){};
    defer out.deinit(alloc);
    try out.appendSlice(alloc, "[");
    for (buf[0..n], 0..) |t, i| {
        if (i > 0) try out.appendSlice(alloc, ",");
        const live_bal = ctx.bc.getAddressBalance(t.treasurySlice());
        const tl_safe = try rpc.jsonSanitize(alloc, t.labelSlice());
        defer alloc.free(tl_safe);
        const entry = try std.fmt.allocPrint(alloc,
            "{{\"treasury_id\":\"{s}\",\"address\":\"{s}\",\"balance_sat\":{d},\"trigger_amount_sat\":{d},\"last_distribute_block\":{d},\"total_distributed_sat\":{d},\"dest_count\":{d},\"label\":\"{s}\"}}",
            .{ t.idSlice(), t.treasurySlice(), live_bal, t.trigger_amount_sat,
               t.last_distribute_block, t.total_distributed_sat, t.dest_count, tl_safe });
        defer alloc.free(entry);
        try out.appendSlice(alloc, entry);
    }
    try out.appendSlice(alloc, "]");
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{s}}}",
        .{ id, out.items });
}

/// treasury_distribute {"treasury_id":"hex..."}
pub fn handleTreasuryDistribute(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const treasury_id = rpc.extractParamObjectField(body, "treasury_id") orelse
        return rpc.errorJson(-32602, "Missing param: treasury_id", id, alloc);
    const treas = ctx.bc.treasury_multi_store.getById(treasury_id) orelse
        return rpc.errorJson(-32000, "Treasury not found", id, alloc);
    const current_block: u64 = @intCast(ctx.bc.getBlockCount());
    const bal = ctx.bc.getAddressBalance(treas.treasurySlice());
    if (bal == 0) return rpc.errorJson(-32000, "Treasury balance is zero", id, alloc);

    var distributed: u64 = 0;
    ctx.bc.mutex.lock();
    var di: usize = 0;
    while (di < treas.dest_count) : (di += 1) {
        const dest_amt = treas.destAmount(di, bal);
        if (dest_amt == 0) continue;
        if (bal < distributed + dest_amt) break;
        distributed += dest_amt;
        const to_bal = ctx.bc.balances.get(treas.destinations[di].addressSlice()) orelse 0;
        ctx.bc.balances.put(treas.destinations[di].addressSlice(), to_bal + dest_amt) catch {};
    }
    if (distributed > 0) {
        const from_bal = ctx.bc.balances.get(treas.treasurySlice()) orelse 0;
        ctx.bc.balances.put(treas.treasurySlice(), from_bal -| distributed) catch {};
    }
    ctx.bc.mutex.unlock();

    ctx.bc.treasury_multi_store.recordDistribute(treasury_id, distributed, current_block);

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"treasury_id\":\"{s}\",\"distributed_sat\":{d},\"block\":{d}}}}}",
        .{ id, treasury_id, distributed, current_block });
}

/// treasury_status {"treasury_id":"hex..."}
pub fn handleTreasuryStatus(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const treasury_id = rpc.extractParamObjectField(body, "treasury_id") orelse
        return rpc.errorJson(-32602, "Missing param: treasury_id", id, alloc);
    const treas = ctx.bc.treasury_multi_store.getById(treasury_id) orelse
        return rpc.errorJson(-32000, "Treasury not found", id, alloc);
    const live_bal = ctx.bc.getAddressBalance(treas.treasurySlice());
    const pending: u64 = if (live_bal >= treas.trigger_amount_sat and treas.trigger_amount_sat > 0) live_bal else 0;
    const ts_label = try rpc.jsonSanitize(alloc, treas.labelSlice());
    defer alloc.free(ts_label);
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"treasury_id\":\"{s}\",\"address\":\"{s}\",\"balance_sat\":{d},\"pending_distribute_sat\":{d},\"trigger_amount_sat\":{d},\"last_distribute_block\":{d},\"total_distributed_sat\":{d},\"label\":\"{s}\"}}}}",
        .{ id, treas.idSlice(), treas.treasurySlice(), live_bal, pending,
           treas.trigger_amount_sat, treas.last_distribute_block, treas.total_distributed_sat, ts_label });
}
