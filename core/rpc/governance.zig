// On-chain governance JSON-RPC handlers — propose, vote, list, execute.
//
// Bitcoin-Core has no analogue (Bitcoin has no on-chain governance). Our
// system mirrors Cosmos/MakerDAO-style voting: proposals carry a SHA-256
// title hash + free-text note + a voting window; weight comes from the
// 4 PQ-tier reputation buckets (OMNI / LOVE / FOOD / RENT / VACATION).
// `gov_execute` is a manual nudge — auto-execute also runs every block
// in `applyBlock`.

const std = @import("std");
const rpc = @import("../rpc_server.zig");
const blockchain_mod = @import("../blockchain.zig");
const gov_mod = @import("../governance_onchain.zig");

const ServerCtx = rpc.ServerCtx;

// ── gov_propose ───────────────────────────────────────────────────────────────
// { "from":"ob1q...", "title_hash":"<sha256>", "voting_blocks":1440,
//   "quorum":200, "note":"...", "signature":"hex", "public_key":"hex", "nonce":N }
pub fn handleGovPropose(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc         = ctx.allocator;
    const from          = rpc.extractStr(body, "from")         orelse return rpc.errorJson(-32602, "Missing: from", id, alloc);
    const title_hash    = rpc.extractStr(body, "title_hash")   orelse return rpc.errorJson(-32602, "Missing: title_hash", id, alloc);
    const voting_blocks = rpc.extractParamObjectU64(body, "voting_blocks");
    const quorum        = @as(u32, @intCast(@min(rpc.extractParamObjectU64(body, "quorum"), 0xFFFFFFFF)));
    const note          = rpc.extractStr(body, "note") orelse "";
    const sig           = rpc.extractStr(body, "signature")  orelse return rpc.errorJson(-32602, "Missing: signature", id, alloc);
    const pubkey        = rpc.extractStr(body, "public_key") orelse return rpc.errorJson(-32602, "Missing: public_key", id, alloc);
    const nonce         = rpc.extractParamObjectU64(body, "nonce");

    if (title_hash.len != gov_mod.TITLE_HASH_LEN)
        return rpc.errorJson(-32602, "title_hash must be 64-char SHA-256 hex", id, alloc);
    if (voting_blocks == 0) return rpc.errorJson(-32602, "voting_blocks must be > 0", id, alloc);

    const op_return = try std.fmt.allocPrint(alloc, "gov_propose:{s}:{d}:{d}:{s}",
        .{ title_hash, voting_blocks, quorum, note });
    defer alloc.free(op_return);

    const ts    = std.time.timestamp();
    const tx_id: u32 = @intCast(std.time.milliTimestamp() & 0xFFFFFFFF);
    const provisional = try std.fmt.allocPrint(alloc, "{d}{s}{d}", .{ tx_id, from, ts });
    defer alloc.free(provisional);

    var tx = blockchain_mod.Transaction{
        .id = tx_id, .from_address = from, .to_address = from,
        .amount = 0, .fee = gov_mod.GOV_PROPOSE_FEE_SAT,
        .timestamp = ts, .nonce = nonce, .op_return = op_return,
        .signature = sig, .public_key = pubkey, .scheme = .omni_ecdsa, .hash = provisional,
    };
    const canonical = try std.fmt.allocPrint(alloc, "{s}", .{std.fmt.bytesToHex(tx.calculateHash(), .lower)});
    tx.hash = canonical;

    const parsed = gov_mod.parsePropose(op_return).?;
    const prop_id = ctx.bc.gov_registry.propose(from, parsed, @intCast(ctx.bc.getBlockCount())) catch 0;

    ctx.bc.mutex.lock();
    ctx.bc.mempool.append(tx) catch { ctx.bc.mutex.unlock(); return rpc.errorJson(-32603, "Mempool full", id, alloc); };
    ctx.bc.mutex.unlock();

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{" ++
        "\"status\":\"queued\",\"txid\":\"{s}\"," ++
        "\"proposal_id\":{d},\"voting_end_block\":{d}," ++
        "\"quorum\":{d}}}}}",
        .{ id, canonical, prop_id, ctx.bc.getBlockCount() + voting_blocks, quorum });
}

// ── gov_vote ──────────────────────────────────────────────────────────────────
// { "from":"ob1q...", "proposal_id":1, "vote":"yes"|"no",
//   "tier":"FOOD", "signature":"hex", "public_key":"hex", "nonce":N }
pub fn handleGovVote(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc       = ctx.allocator;
    const from        = rpc.extractStr(body, "from")        orelse return rpc.errorJson(-32602, "Missing: from", id, alloc);
    const proposal_id = rpc.extractParamObjectU64(body, "proposal_id");
    const vote_str    = rpc.extractStr(body, "vote")        orelse return rpc.errorJson(-32602, "Missing: vote (yes|no)", id, alloc);
    const tier        = rpc.extractStr(body, "tier")        orelse "OMNI";
    const sig         = rpc.extractStr(body, "signature")   orelse return rpc.errorJson(-32602, "Missing: signature", id, alloc);
    const pubkey      = rpc.extractStr(body, "public_key")  orelse return rpc.errorJson(-32602, "Missing: public_key", id, alloc);
    const nonce       = rpc.extractParamObjectU64(body, "nonce");

    const yes = std.mem.eql(u8, vote_str, "yes");

    const op_return = try std.fmt.allocPrint(alloc, "gov_vote:{d}:{s}", .{ proposal_id, vote_str });
    defer alloc.free(op_return);

    const ts    = std.time.timestamp();
    const tx_id: u32 = @intCast(std.time.milliTimestamp() & 0xFFFFFFFF);
    const provisional = try std.fmt.allocPrint(alloc, "{d}{s}{d}", .{ tx_id, from, ts });
    defer alloc.free(provisional);

    var tx = blockchain_mod.Transaction{
        .id = tx_id, .from_address = from, .to_address = from,
        .amount = 0, .fee = gov_mod.GOV_VOTE_FEE_SAT,
        .timestamp = ts, .nonce = nonce, .op_return = op_return,
        .signature = sig, .public_key = pubkey, .scheme = .omni_ecdsa, .hash = provisional,
    };
    const canonical = try std.fmt.allocPrint(alloc, "{s}", .{std.fmt.bytesToHex(tx.calculateHash(), .lower)});
    tx.hash = canonical;

    ctx.bc.gov_registry.vote(proposal_id, from, yes, tier, @intCast(ctx.bc.getBlockCount())) catch |err| {
        const msg = switch (err) {
            error.ProposalNotFound => "Proposal not found",
            error.VotingEnded      => "Voting period has ended",
            error.AlreadyVoted     => "Already voted on this proposal",
            else                   => "Vote failed",
        };
        return rpc.errorJson(-32001, msg, id, alloc);
    };

    ctx.bc.mutex.lock();
    ctx.bc.mempool.append(tx) catch { ctx.bc.mutex.unlock(); return rpc.errorJson(-32603, "Mempool full", id, alloc); };
    ctx.bc.mutex.unlock();

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"status\":\"queued\",\"txid\":\"{s}\",\"vote\":\"{s}\"}}}}",
        .{ id, canonical, vote_str });
}

// ── getproposals ──────────────────────────────────────────────────────────────
// { "filter":"active"|"all" }
pub fn handleGetProposals(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc  = ctx.allocator;
    const filter = rpc.extractStr(body, "filter") orelse "active";

    var props: [gov_mod.MAX_PROPOSALS]gov_mod.Proposal = undefined;
    const n = if (std.mem.eql(u8, filter, "all"))
        ctx.bc.gov_registry.listAll(&props)
    else
        ctx.bc.gov_registry.listActive(&props);

    var buf = std.array_list.Managed(u8).init(alloc);
    defer buf.deinit();
    const w = buf.writer();
    try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"proposals\":[", .{id});
    for (props[0..n], 0..) |p, i| {
        if (i > 0) try w.writeByte(',');
        try w.print(
            "{{\"id\":{d},\"proposer\":\"{s}\",\"title_hash\":\"{s}\"," ++
            "\"status\":\"{s}\",\"yes_weight\":{d},\"no_weight\":{d}," ++
            "\"quorum\":{d},\"voting_end_block\":{d},\"vote_count\":{d}}}",
            .{ p.id, p.getProposer(), p.getTitleHash(), p.statusStr(),
               p.yes_weight, p.no_weight, p.quorum_weight,
               p.voting_end_block, p.vote_count });
    }
    // Close: array (]) + result object (}) + outer envelope (}). Three braces total.
    try w.writeAll("]}}");
    return buf.toOwnedSlice();
}

// ── getproposal ───────────────────────────────────────────────────────────────
// { "proposal_id":1 }
pub fn handleGetProposal(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc       = ctx.allocator;
    const proposal_id = rpc.extractParamObjectU64(body, "proposal_id");

    const p = ctx.bc.gov_registry.getProposal(proposal_id) orelse
        return std.fmt.allocPrint(alloc, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":null}}", .{id});

    const note_safe = try rpc.jsonSanitize(alloc, p.getNote());
    defer alloc.free(note_safe);
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{" ++
        "\"id\":{d},\"proposer\":\"{s}\",\"title_hash\":\"{s}\"," ++
        "\"note\":\"{s}\",\"status\":\"{s}\"," ++
        "\"yes_weight\":{d},\"no_weight\":{d}," ++
        "\"quorum\":{d},\"voting_end_block\":{d}," ++
        "\"create_block\":{d},\"vote_count\":{d}," ++
        "\"executed\":{},\"executed_block\":{d}," ++
        "\"action_kind\":{d},\"action_u64\":{d},\"action_bool\":{}}}}}",
        .{ id, p.id, p.getProposer(), p.getTitleHash(), note_safe,
           p.statusStr(), p.yes_weight, p.no_weight,
           p.quorum_weight, p.voting_end_block, p.create_block, p.vote_count,
           p.executed, p.executed_block,
           @intFromEnum(p.action.kind), p.action.u64_value, p.action.bool_value });
}

// ── gov_execute ───────────────────────────────────────────────────────────────
// Manually trigger execution of a passed-but-unexecuted proposal. Auto-exec
// runs every block via applyBlock, so this RPC is a fallback for nodes that
// have route_fees_to_miner=false governance scenarios where a stuck proposal
// needs an explicit nudge.
//
// { "proposal_id": <u64> }
// → result.success / result.applied / result.error
pub fn handleGovExecute(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc       = ctx.allocator;
    const proposal_id = rpc.extractParamObjectU64(body, "proposal_id");
    if (proposal_id == 0) return rpc.errorJson(-32602, "Missing or invalid proposal_id", id, alloc);

    const current_block = ctx.bc.getBlockCount();
    ctx.bc.executeProposal(proposal_id, @intCast(current_block)) catch |err| {
        const msg = switch (err) {
            error.ProposalNotFound  => "Proposal not found",
            error.ProposalNotPassed => "Proposal status is not 'passed' (still voting, rejected, expired, or already executed)",
            error.AlreadyExecuted   => "Proposal already executed",
        };
        return rpc.errorJson(-32001, msg, id, alloc);
    };

    const p = ctx.bc.gov_registry.getProposal(proposal_id) orelse
        return rpc.errorJson(-32603, "Proposal vanished mid-execute", id, alloc);

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{" ++
        "\"proposal_id\":{d},\"executed_block\":{d}," ++
        "\"action_kind\":{d},\"action_u64\":{d},\"action_bool\":{}," ++
        "\"status\":\"{s}\"}}}}",
        .{
            id,
            p.id,
            p.executed_block,
            @intFromEnum(p.action.kind),
            p.action.u64_value,
            p.action.bool_value,
            p.statusStr(),
        });
}
