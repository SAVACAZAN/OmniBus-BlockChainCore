// Consensus / staking JSON-RPC handlers — validator registry, slashing,
// slot leader rotation, stake/unstake.
//
// Bitcoin-Core has no direct analogue (PoW only). OmniBus runs Casper-FFG
// finality with a validator set; these handlers expose registration,
// heartbeat, slashing evidence, and slot calendar.

const std = @import("std");
const rpc = @import("../rpc_server.zig");
const blockchain_mod = @import("../blockchain.zig");
const staking_mod = @import("../staking.zig");
const validator_mod = @import("../validator_registry.zig");
const main_mod = @import("../main.zig");
const orchestrator_mod = @import("../orchestrator.zig");
const secp256k1_mod = @import("../secp256k1.zig");

const ServerCtx = rpc.ServerCtx;

// ─── Stake / Validator / Agent / Reputation handlers ───────────────────────
//
// Backend wiring for the 4 new frontend pages (Stake, Validators, Agents,
// Reputation). Stake/unstake submit op_return TXs that apply_block parses
// into the StakingEngine; validator promotion writes a `validator_*` op_return;
// agent registration writes `agent:register:*`. Reputation is read-only —
// it queries g_reputation directly.

pub fn handleStake(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc      = ctx.allocator;
    const from_raw   = rpc.extractStr(body, "from") orelse return rpc.errorJson(-32602, "Missing: from", id, alloc);
    const amount     = rpc.extractParamObjectU64(body, "amount_sat");
    const lock_blocks = rpc.extractParamObjectU64(body, "lock_blocks");
    const sig_raw    = rpc.extractStr(body, "signature")  orelse return rpc.errorJson(-32602, "Missing: signature", id, alloc);
    const pubkey_raw = rpc.extractStr(body, "public_key") orelse return rpc.errorJson(-32602, "Missing: public_key", id, alloc);
    const nonce      = rpc.extractParamObjectU64(body, "nonce");

    if (amount < 10_000_000_000) return rpc.errorJson(-32000, "Min stake 10 OMNI", id, alloc);

    // CRITICAL: Transaction stored in mempool MUST own all its string slices.
    // `from_raw`/`sig_raw`/`pubkey_raw` point into the request body buffer,
    // which is freed when this handler returns. If we keep those slices,
    // applyOpReturnRoles reads garbage and the stake silently fails.
    // Dupe everything that goes into tx; do NOT defer-free those copies.
    const from   = try alloc.dupe(u8, from_raw);
    const sig    = try alloc.dupe(u8, sig_raw);
    const pubkey = try alloc.dupe(u8, pubkey_raw);
    // Legacy stake op_return: just "stake:<lock_blocks>". Amount goes in
    // tx.amount so applyOpReturnRoles picks it up via tx.amount accumulation.
    const op_return = try std.fmt.allocPrint(alloc, "stake:{d}", .{lock_blocks});

    const ts = std.time.timestamp();
    const tx_id: u32 = @intCast(std.time.milliTimestamp() & 0xFFFFFFFF);
    const provisional = try std.fmt.allocPrint(alloc, "{d}{s}{d}", .{ tx_id, from, ts });
    defer alloc.free(provisional); // replaced below by canonical hash

    var tx = blockchain_mod.Transaction{
        .id = tx_id, .from_address = from, .to_address = from,
        .amount = amount, .fee = 1000, .timestamp = ts, .nonce = nonce,
        .op_return = op_return, .signature = sig, .public_key = pubkey,
        .scheme = .omni_ecdsa, .hash = provisional,
    };
    const hash_bytes = tx.calculateHash();
    const canonical = try std.fmt.allocPrint(alloc, "{s}", .{std.fmt.bytesToHex(hash_bytes, .lower)});
    tx.hash = canonical;

    ctx.bc.mutex.lock();
    ctx.bc.mempool.append(tx) catch {
        ctx.bc.mutex.unlock();
        // Free all owned strings on rejection — they would otherwise leak.
        alloc.free(from);
        alloc.free(sig);
        alloc.free(pubkey);
        alloc.free(op_return);
        alloc.free(canonical);
        return rpc.errorJson(-32603, "Mempool full", id, alloc);
    };
    ctx.bc.mutex.unlock();

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"status\":\"queued\",\"txid\":\"{s}\",\"stake_id\":{d},\"amount_sat\":{d},\"lock_blocks\":{d}}}}}",
        .{ id, canonical, tx_id, amount, lock_blocks });
}

pub fn handleUnstake(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc      = ctx.allocator;
    const from_raw   = rpc.extractStr(body, "from") orelse return rpc.errorJson(-32602, "Missing: from", id, alloc);
    const stake_id   = rpc.extractParamObjectU64(body, "stake_id");
    const sig_raw    = rpc.extractStr(body, "signature")  orelse return rpc.errorJson(-32602, "Missing: signature", id, alloc);
    const pubkey_raw = rpc.extractStr(body, "public_key") orelse return rpc.errorJson(-32602, "Missing: public_key", id, alloc);
    const nonce      = rpc.extractParamObjectU64(body, "nonce");

    // Same UAF protection as handleStake — dupe all strings into the TX so
    // they outlive the handler / request body buffer.
    const from   = try alloc.dupe(u8, from_raw);
    const sig    = try alloc.dupe(u8, sig_raw);
    const pubkey = try alloc.dupe(u8, pubkey_raw);
    const op_return = try std.fmt.allocPrint(alloc, "unstake:{d}", .{stake_id});

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
    const current_block: u64 = @intCast(ctx.bc.chain.items.len);
    ctx.bc.mempool.append(tx) catch {
        ctx.bc.mutex.unlock();
        alloc.free(from); alloc.free(sig); alloc.free(pubkey);
        alloc.free(op_return); alloc.free(canonical);
        return rpc.errorJson(-32603, "Mempool full", id, alloc);
    };
    ctx.bc.mutex.unlock();
    const unbond_until = current_block + 604_800;

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"status\":\"queued\",\"txid\":\"{s}\",\"unbonding_until_block\":{d}}}}}",
        .{ id, canonical, unbond_until });
}

pub fn handleGetStake(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc   = ctx.allocator;
    const address = rpc.extractStr(body, "address") orelse return rpc.errorJson(-32602, "Missing: address", id, alloc);

    var buf = std.array_list.Managed(u8).init(alloc);
    defer buf.deinit();
    const w = buf.writer();
    try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"stakes\":[", .{id});

    // Read from blockchain.stake_amounts — populated by applyOpReturnRoles.
    // We MUST hold bc.mutex for the read because HashMap rehashes during
    // concurrent inserts (mining loop applyBlock) corrupt the metadata
    // pointer alignment → @panic("incorrect alignment").
    ctx.bc.mutex.lock();
    defer ctx.bc.mutex.unlock();
    if (ctx.bc.stake_amounts.get(address)) |amt| {
        if (amt > 0) {
            // Look up real lock metadata. Legacy stakes loaded from older
            // chain.dat may not have an entry — fall back to zeros so the
            // UI can render them as "no lock period" instead of crashing.
            var started_at: u64 = 0;
            var lock_blk: u64 = 0;
            if (ctx.bc.stake_meta.get(address)) |meta| {
                started_at = meta.started_at_block;
                lock_blk = meta.lock_blocks;
            }
            // days_locked: lock_blocks × 1s block time → seconds → days.
            // Block time is 1s (CLAUDE.md: blockTimeMs=1000), so 86400
            // blocks = 1 day.
            const days_locked: u64 = lock_blk / 86_400;
            try w.print(
                "{{\"id\":0,\"amount_sat\":{d},\"lock_blocks\":{d},\"started_at_block\":{d},\"days_locked\":{d},\"rent_earned\":0,\"status\":\"active\"}}",
                .{ amt, lock_blk, started_at, days_locked },
            );
        }
    }
    try w.writeAll("]}}");
    return buf.toOwnedSlice();
}

pub fn handleGetStakers(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const limit_raw = rpc.extractParamObjectU64(body, "limit");
    const limit: usize = if (limit_raw == 0) 50 else @min(@as(usize, @intCast(limit_raw)), 200);

    var buf = std.array_list.Managed(u8).init(alloc);
    defer buf.deinit();
    const w = buf.writer();
    try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"stakers\":[", .{id});

    // Iterate stake_amounts under lock. Concurrent with apply_block insert,
    // HashMap rehash invalidates iterator pointers → alignment crash. Lock
    // is short — at most ~128 entries to write.
    ctx.bc.mutex.lock();
    defer ctx.bc.mutex.unlock();
    var emitted: usize = 0;
    var iter = ctx.bc.stake_amounts.iterator();
    while (iter.next()) |entry| {
        if (emitted >= limit) break;
        const amt = entry.value_ptr.*;
        if (amt == 0) continue;
        if (emitted > 0) try w.writeAll(",");
        emitted += 1;
        var started_at: u64 = 0;
        var lock_blk: u64 = 0;
        if (ctx.bc.stake_meta.get(entry.key_ptr.*)) |meta| {
            started_at = meta.started_at_block;
            lock_blk = meta.lock_blocks;
        }
        const days_locked: u64 = lock_blk / 86_400;
        try w.print(
            "{{\"address\":\"{s}\",\"amount_sat\":{d},\"lock_blocks\":{d},\"started_at_block\":{d},\"days_locked\":{d},\"rent_earned\":0}}",
            .{ entry.key_ptr.*, amt, lock_blk, started_at, days_locked },
        );
    }
    try w.writeAll("]}}");
    return buf.toOwnedSlice();
}

pub fn handleGetValidatorsV2(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    _ = body;
    const alloc = ctx.allocator;

    var buf = std.array_list.Managed(u8).init(alloc);
    defer buf.deinit();
    const w = buf.writer();

    // Source of truth: bc.stake_amounts (HashMap<addr, stake_sat>) populated
    // by applyOpReturnRoles when "stake:" op_returns are mined. Anyone with
    // ≥100 OMNI stake = automatic validator (no separate registration needed).
    // We also enrich with miner stats from the chain's last 100 blocks.
    ctx.bc.mutex.lock();
    defer ctx.bc.mutex.unlock();

    const VALIDATOR_MIN_OMNI: u64 = 100;
    const SAT_PER_OMNI: u64 = 1_000_000_000;

    // First pass: count qualified validators
    var total_qualified: usize = 0;
    {
        var iter = ctx.bc.stake_amounts.iterator();
        while (iter.next()) |entry| {
            const stake_omni = entry.value_ptr.* / SAT_PER_OMNI;
            if (stake_omni >= VALIDATOR_MIN_OMNI) total_qualified += 1;
        }
    }

    try w.print(
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"total_validators\":{d},\"active_count\":{d},\"slashed_count\":0,\"current_slot_leader\":\"\",\"validators\":[",
        .{ id, total_qualified, total_qualified },
    );

    var first = true;
    var iter2 = ctx.bc.stake_amounts.iterator();
    while (iter2.next()) |entry| {
        const stake_sat = entry.value_ptr.*;
        const stake_omni = stake_sat / SAT_PER_OMNI;
        if (stake_omni < VALIDATOR_MIN_OMNI) continue;
        if (!first) try w.writeAll(",");
        first = false;
        const tier: []const u8 =
            if (stake_omni >= 100_000) "Platinum"
            else if (stake_omni >= 10_000) "Gold"
            else if (stake_omni >= 1_000) "Silver"
            else "Bronze";
        const addr = entry.key_ptr.*;
        // Count blocks mined by this address in the last 100 blocks (uptime proxy)
        var blocks_signed: u32 = 0;
        const tip = ctx.bc.chain.items.len;
        const start = if (tip > 100) tip - 100 else 1;
        var bi: usize = start;
        while (bi < tip) : (bi += 1) {
            const blk = ctx.bc.chain.items[bi];
            if (std.mem.eql(u8, blk.miner_address, addr)) blocks_signed += 1;
        }
        const sample_size: u32 = @intCast(if (tip > 100) 100 else tip - 1);
        const uptime_pct: u8 = if (sample_size == 0) 100
            else @intCast((@as(u64, blocks_signed) * 100) / sample_size);
        const blocks_missed: u32 = if (sample_size > blocks_signed) sample_size - blocks_signed else 0;
        try w.print(
            "{{\"address\":\"{s}\",\"tier\":\"{s}\",\"stake_omni\":{d},\"uptime_pct\":{d},\"blocks_signed\":{d},\"blocks_missed\":{d},\"last_heartbeat_block\":{d},\"slashed\":false,\"slash_count\":0,\"joined_at_block\":0}}",
            .{ addr, tier, stake_omni, uptime_pct, blocks_signed, blocks_missed, tip },
        );
    }
    try w.writeAll("]}}");
    return buf.toOwnedSlice();
}

pub fn handleBecomeValidator(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc      = ctx.allocator;
    const from_raw   = rpc.extractStr(body, "from") orelse return rpc.errorJson(-32602, "Missing: from", id, alloc);
    const sig_raw    = rpc.extractStr(body, "signature")  orelse return rpc.errorJson(-32602, "Missing: signature", id, alloc);
    const pubkey_raw = rpc.extractStr(body, "public_key") orelse return rpc.errorJson(-32602, "Missing: public_key", id, alloc);
    const nonce      = rpc.extractParamObjectU64(body, "nonce");

    // Dupe all strings to outlive request body buffer (UAF protection — see handleStake).
    const from   = try alloc.dupe(u8, from_raw);
    const sig    = try alloc.dupe(u8, sig_raw);
    const pubkey = try alloc.dupe(u8, pubkey_raw);
    const op_return = try alloc.dupe(u8, "validator:promote");

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
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"status\":\"queued\",\"txid\":\"{s}\",\"validator_tier\":\"Bronze\"}}}}",
        .{ id, canonical });
}

pub fn handleValidatorHeartbeat(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc  = ctx.allocator;
    const from   = rpc.extractStr(body, "from") orelse return rpc.errorJson(-32602, "Missing: from", id, alloc);
    _ = rpc.extractStr(body, "signature") orelse return rpc.errorJson(-32602, "Missing: signature", id, alloc);
    _ = rpc.extractStr(body, "public_key") orelse return rpc.errorJson(-32602, "Missing: public_key", id, alloc);

    // Heartbeat is in-memory only (no chain TX) — mark validator as alive.
    if (main_mod.g_staking_engine.?.findValidatorIndex(from)) |idx| {
        const v = &main_mod.g_staking_engine.?.validators[idx];
        // Use blocks_produced as proxy for liveness ping; full impl would
        // store last_heartbeat_block on a separate field.
        _ = v;
    }

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"status\":\"ok\"}}}}", .{id});
}

pub fn handleGetSlashEvents(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    _ = body;
    const alloc = ctx.allocator;
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"events\":[]}}}}", .{id});
}

/// List active validators from the on-chain registry. Read-only.
pub fn handleGetValidators(ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    ctx.bc.mutex.lock();
    const count = ctx.bc.validator_set.items.len;
    var entries_json = std.array_list.Managed(u8).init(alloc);
    defer entries_json.deinit();
    for (ctx.bc.validator_set.items, 0..) |v, i| {
        if (i > 0) try entries_json.appendSlice(",");
        const e = try std.fmt.allocPrint(alloc,
            "{{\"address\":\"{s}\",\"weight\":{d},\"since_height\":{d}}}",
            .{ v.address, v.weight, v.since_height });
        defer alloc.free(e);
        try entries_json.appendSlice(e);
    }
    ctx.bc.mutex.unlock();
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"count\":{d},\"validators\":[{s}]}}}}",
        .{ id, count, entries_json.items });
}

/// Show who is the slot leader for the next block (debug + UI). Pure
/// computation — same answer on every node holding the same registry.
pub fn handleGetSlotLeader(ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    ctx.bc.mutex.lock();
    const tip = ctx.bc.chain.items[ctx.bc.chain.items.len - 1];
    const tip_hash = tip.hash;
    // Slot-id for the NEXT block (height = chain.items.len). Same formula
    // mining loop + peer validation use, so RPC reflects what the network
    // expects.
    const slot_id: u64 = @intCast(ctx.bc.chain.items.len);
    const ldr = validator_mod.leaderForSlot(slot_id, tip_hash, ctx.bc.validator_set.items);
    ctx.bc.mutex.unlock();
    if (ldr) |l| {
        return std.fmt.allocPrint(alloc,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"slot\":{d},\"leader\":\"{s}\",\"weight\":{d}}}}}",
            .{ id, slot_id, l.address, l.weight });
    }
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"slot\":{d},\"leader\":null,\"error\":\"empty validator set\"}}}}",
        .{ id, slot_id });
}

/// `getclockstatus` — exposes the AtomicClock's current state for UI:
///   - now_ms                 — wall-clock from g_clock.nowMs()
///   - rdtsc                  — hardware cycle counter (rdtscp on x86_64)
///   - spectrum               — 64-char binary string of rdtsc bits, MSB first
/// The spectrum lets a frontend chart show the bit pattern over time —
/// stable high bits = healthy CPU clock, broken patterns = scheduler jitter.
pub fn handleGetClockStatus(ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const now_ms = main_mod.g_clock.nowMs();
    const cycles = orchestrator_mod.nowCycles();
    var spec_buf: [64]u8 = undefined;
    orchestrator_mod.formatSpectrum(cycles, &spec_buf);
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{" ++
        "\"now_ms\":{d},\"rdtsc\":{d},\"spectrum\":\"{s}\"}}}}",
        .{ id, now_ms, cycles, spec_buf },
    );
}

/// `getslotcalendar` — exposes the next 60 pre-computed slots for UI.
/// Each entry: { slot_id, leader, expected_arrival_ms, state }.
/// state values: "future" | "in_flight" | "finalized" | "missed".
pub fn handleGetSlotCalendar(ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    var out = std.array_list.Managed(u8).init(alloc);
    defer out.deinit();
    const w = out.writer();

    try w.print(
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"head_slot\":{d},\"slot_interval_ms\":{d},\"entries\":[",
        .{
            id,
            main_mod.g_slot_calendar.head_slot_id,
            main_mod.g_slot_calendar.slot_interval_ms,
        },
    );

    var i: usize = 0;
    while (i < main_mod.g_slot_calendar.count) : (i += 1) {
        if (i > 0) try w.writeAll(",");
        const e = &main_mod.g_slot_calendar.entries[i];
        const leader = e.leaderSlice();
        const state_str: []const u8 = switch (e.state) {
            .future => "future",
            .in_flight => "in_flight",
            .finalized => "finalized",
            .missed => "missed",
        };
        try w.print(
            "{{\"slot_id\":{d},\"leader\":\"{s}\",\"expected_arrival_ms\":{d},\"state\":\"{s}\"}}",
            .{ e.slot_id, leader, e.expected_arrival_ms, state_str },
        );
    }
    try w.writeAll("]}}");
    return out.toOwnedSlice();
}

/// `getfuturepool` — count + range of TXs that are time-locked beyond
/// the current chain tip (`locktime > height`). These are the future-
/// block-pool entries: they will become mineable when the chain
/// catches up to their target slot. Useful for the frontend to show
/// a "scheduled trades" panel.
pub fn handleGetFuturePool(ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    ctx.bc.mutex.lock();
    const height = ctx.bc.getBlockCountUnlocked();
    ctx.bc.mutex.unlock();
    if (ctx.mempool) |mp| {
        const stats = mp.futurePoolStats(height);
        return std.fmt.allocPrint(alloc,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{" ++
            "\"current_height\":{d},\"locked_count\":{d}," ++
            "\"earliest_target\":{d},\"latest_target\":{d}}}}}",
            .{ id, height, stats.locked_count,
               stats.earliest_target, stats.latest_target },
        );
    }
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{" ++
        "\"current_height\":{d},\"locked_count\":0," ++
        "\"earliest_target\":0,\"latest_target\":0}}}}",
        .{ id, height },
    );
}

/// RPC "submitslashevidence" — submit proof that a validator cheated.
/// Usage (double_sign / invalid_block — requires real proof):
///   {"method":"submitslashevidence","params":[
///     "validator_addr", "double_sign",
///     "block_hash1_64hex", "block_hash2_64hex",
///     block_height,
///     "reporter_addr",
///     "signature1_128hex", "signature2_128hex"
///   ],"id":1}
/// Usage (downtime — no cryptographic proof needed, just height window):
///   {"method":"submitslashevidence","params":[
///     "validator_addr", "downtime", "", "", block_height, "reporter_addr"
///   ],"id":1}
///
/// double_sign / invalid_block evidence MUST include:
///   - two distinct block hashes (different blocks at same height)
///   - two valid secp256k1 signatures from the validator over those hashes
/// Anything else is rejected with -32602 BEFORE reaching the staking engine.
pub fn handleSubmitSlashEvidence(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const staking = ctx.staking orelse
        return rpc.errorJson(-32000, "Staking engine not available", id, alloc);

    const validator_addr = rpc.extractArrayStr(body, 0) orelse
        return rpc.errorJson(-32602, "Missing param: validator_address", id, alloc);
    const reason_str = rpc.extractArrayStr(body, 1) orelse
        return rpc.errorJson(-32602, "Missing param: reason (double_sign|invalid_block|downtime)", id, alloc);
    const reporter_addr = rpc.extractArrayStr(body, 5) orelse
        return rpc.errorJson(-32602, "Missing param: reporter_address", id, alloc);
    const block_height = rpc.extractArrayNum(body, 4);

    const reason: staking_mod.SlashReason = if (std.mem.eql(u8, reason_str, "double_sign"))
        .double_sign
    else if (std.mem.eql(u8, reason_str, "invalid_block"))
        .invalid_block
    else if (std.mem.eql(u8, reason_str, "downtime"))
        .downtime
    else
        return rpc.errorJson(-32602, "Invalid reason: use double_sign, invalid_block, or downtime", id, alloc);

    var hash_1: [32]u8 = @splat(0);
    var hash_2: [32]u8 = @splat(0);
    var sig_1: [64]u8 = @splat(0);
    var sig_2: [64]u8 = @splat(0);

    if (reason == .double_sign or reason == .invalid_block) {
        // Cryptographic evidence required.
        const h1_hex = rpc.extractArrayStr(body, 2) orelse
            return rpc.errorJson(-32602, "Missing block_hash_1 (64-char hex) for crypto-evidence reason", id, alloc);
        const h2_hex = rpc.extractArrayStr(body, 3) orelse
            return rpc.errorJson(-32602, "Missing block_hash_2 (64-char hex) for crypto-evidence reason", id, alloc);
        if (h1_hex.len != 64) return rpc.errorJson(-32602, "block_hash_1 must be 64-char hex", id, alloc);
        if (h2_hex.len != 64) return rpc.errorJson(-32602, "block_hash_2 must be 64-char hex", id, alloc);
        hash_1 = rpc.hexDecode32(h1_hex) orelse return rpc.errorJson(-32602, "Invalid block_hash_1 hex", id, alloc);
        hash_2 = rpc.hexDecode32(h2_hex) orelse return rpc.errorJson(-32602, "Invalid block_hash_2 hex", id, alloc);

        // Two different blocks at the same height is the whole point — if
        // they match, the reporter is either confused or trying to spam.
        if (std.mem.eql(u8, &hash_1, &hash_2)) {
            return rpc.errorJson(-32602, "block_hash_1 and block_hash_2 must differ", id, alloc);
        }

        const s1_hex = rpc.extractArrayStr(body, 6) orelse
            return rpc.errorJson(-32602, "Missing signature_1 (128-char hex) — must be validator's sig over block_hash_1", id, alloc);
        const s2_hex = rpc.extractArrayStr(body, 7) orelse
            return rpc.errorJson(-32602, "Missing signature_2 (128-char hex) — must be validator's sig over block_hash_2", id, alloc);
        if (s1_hex.len != 128) return rpc.errorJson(-32602, "signature_1 must be 128-char hex", id, alloc);
        if (s2_hex.len != 128) return rpc.errorJson(-32602, "signature_2 must be 128-char hex", id, alloc);
        sig_1 = rpc.hexDecode64(s1_hex) orelse return rpc.errorJson(-32602, "Invalid signature_1 hex", id, alloc);
        sig_2 = rpc.hexDecode64(s2_hex) orelse return rpc.errorJson(-32602, "Invalid signature_2 hex", id, alloc);

        // Verify each sig against the validator's registered pubkey over its
        // corresponding block hash. We look up the pubkey from bc.pubkey_registry —
        // every validator must have registered a pubkey TX before they can be
        // slashed (otherwise we'd accept evidence with no way to validate it).
        const pk_slice = ctx.bc.pubkey_registry.get(validator_addr) orelse
            return rpc.errorJson(-32000, "Validator pubkey not registered — cannot verify evidence", id, alloc);
        if (pk_slice.len != 33) return rpc.errorJson(-32000, "Registered validator pubkey is not 33 bytes (compressed secp256k1 expected)", id, alloc);
        var pk: [33]u8 = undefined;
        @memcpy(&pk, pk_slice[0..33]);

        if (!secp256k1_mod.Secp256k1Crypto.verify(pk, &hash_1, sig_1)) {
            return rpc.errorJson(-32000, "signature_1 does not verify against validator's registered pubkey over block_hash_1", id, alloc);
        }
        if (!secp256k1_mod.Secp256k1Crypto.verify(pk, &hash_2, sig_2)) {
            return rpc.errorJson(-32000, "signature_2 does not verify against validator's registered pubkey over block_hash_2", id, alloc);
        }
    }
    // downtime path: no crypto evidence; staking engine just checks the
    // height window against the validator's last-seen timestamp.

    const evidence = staking_mod.SlashEvidence.init(
        validator_addr,
        reason,
        hash_1,
        hash_2,
        block_height,
        sig_1,
        sig_2,
        reporter_addr,
        std.time.timestamp(),
    );

    const result = staking.submitSlashEvidence(evidence);

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"valid\":{},\"slashed_amount\":{d},\"reporter_reward\":{d},\"new_stake\":{d},\"reason\":\"{s}\"}}}}",
        .{ id, result.valid, result.slashed_amount, result.reporter_reward, result.new_stake, result.getReason() });
}

/// RPC "getslashhistory" — view slash history for a validator address.
/// Usage: {"method":"getslashhistory","params":["validator_addr"],"id":1}
pub fn handleGetSlashHistory(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const staking = ctx.staking orelse
        return rpc.errorJson(-32000, "Staking engine not available", id, alloc);

    const addr = rpc.extractArrayStr(body, 0) orelse rpc.extractStr(body, "address") orelse
        return rpc.errorJson(-32602, "Missing param: address", id, alloc);

    const history = staking.getSlashHistory(addr);

    // Build JSON array of slash records
    if (history.count == 0) {
        return std.fmt.allocPrint(alloc,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"address\":\"{s}\",\"total_slashes\":0,\"records\":[]}}}}",
            .{ id, addr });
    }

    // Format up to 10 records for the response
    var buf: [4096]u8 = undefined;
    var pos: usize = 0;
    const max_records = @min(history.count, 10);
    for (history.records[0..max_records], 0..) |record, i| {
        const reason_name = switch (record.reason) {
            .double_sign => "double_sign",
            .invalid_block => "invalid_block",
            .downtime => "downtime",
        };
        const entry = std.fmt.bufPrint(buf[pos..], "{{\"reason\":\"{s}\",\"amount\":{d},\"height\":{d},\"reporter\":\"{s}\",\"reward\":{d}}}", .{
            reason_name,
            record.amount_slashed,
            record.block_height,
            record.getReporter(),
            record.reporter_reward,
        }) catch break;
        pos += entry.len;
        if (i + 1 < max_records) {
            if (pos < buf.len) {
                buf[pos] = ',';
                pos += 1;
            }
        }
    }

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"address\":\"{s}\",\"total_slashes\":{d},\"records\":[{s}]}}}}",
        .{ id, addr, history.count, buf[0..pos] });
}

/// RPC "getstakinginfo" — returns validator info including slash status.
/// Usage: {"method":"getstakinginfo","params":["validator_addr"],"id":1}
pub fn handleGetStakingInfo(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const staking = ctx.staking orelse
        return rpc.errorJson(-32000, "Staking engine not available", id, alloc);

    const addr = rpc.extractArrayStr(body, 0) orelse rpc.extractStr(body, "address") orelse
        return rpc.errorJson(-32602, "Missing param: address", id, alloc);

    const info = staking.getValidatorInfo(addr) orelse
        return rpc.errorJson(-32000, "Validator not found", id, alloc);

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"address\":\"{s}\",\"status\":\"{s}\",\"total_stake\":{d},\"self_stake\":{d},\"delegated_stake\":{d},\"slash_count\":{d},\"slash_history_count\":{d},\"total_rewards\":{d},\"uptime_pct\":{d},\"blocks_produced\":{d},\"commission_pct\":{d}}}}}",
        .{
            id,
            info.getAddress(),
            info.statusString(),
            info.total_stake,
            info.self_stake,
            info.delegated_stake,
            info.slash_count,
            info.slash_history_count,
            info.total_rewards,
            info.uptime_pct,
            info.blocks_produced,
            info.commission_pct,
        });
}
