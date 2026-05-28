// Payment-channel (Lightning-style) JSON-RPC handlers.
//
// Bitcoin-Core has no direct equivalent — Lightning lives in `lnd` /
// `c-lightning` separately. We embed a minimal off-chain channel manager
// (`payment_channel.zig`) and expose 4 lifecycle methods here:
//
//   openchannel   — open between two pubkeys with initial deposits
//   channelpay    — off-chain payment, both parties co-sign new state
//   closechannel  — cooperative close, both parties sign final state
//   getchannels   — list channels with summary + per-channel details
//
// Signatures are ECDSA over the canonical hash of the new `ChannelUpdate`.
// Channel state is only advanced if both parties' sigs verify — same
// safety property as on-chain TX signing.

const std = @import("std");
const rpc = @import("../rpc_server.zig");

const ServerCtx = rpc.ServerCtx;

/// RPC "openchannel" — open a new payment channel between two parties.
/// Usage: {"method":"openchannel","params":["party_a_hex","party_b_hex",amount_a,amount_b],"id":1}
/// party_a_hex / party_b_hex: 33-byte compressed pubkeys as 66-char hex strings (REQUIRED)
/// amount_a / amount_b: deposits in SAT
pub fn handleOpenChannel(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const mgr = ctx.channel_mgr orelse return rpc.errorJson(-32000, "Payment channels not initialized", id, alloc);

    const amount_a = rpc.extractArrayNum(body, 2);
    const amount_b = rpc.extractArrayNum(body, 3);
    if (amount_a == 0 and amount_b == 0) return rpc.errorJson(-32602, "Both amounts cannot be zero", id, alloc);

    // Pubkeys are mandatory. The placeholder fallback that filled them with
    // 0xAA/0xBB used to silently produce a channel whose verify() rejects every
    // payment — caller confusion guaranteed. Reject up-front instead.
    const hex_a = rpc.extractArrayStr(body, 0) orelse
        return rpc.errorJson(-32602, "Missing party_a: 66-char compressed pubkey hex required", id, alloc);
    if (hex_a.len != 66) return rpc.errorJson(-32602, "party_a must be 66-char hex", id, alloc);
    const pk_a = rpc.hexDecode33(hex_a) orelse return rpc.errorJson(-32602, "Invalid party_a hex", id, alloc);

    const hex_b = rpc.extractArrayStr(body, 1) orelse
        return rpc.errorJson(-32602, "Missing party_b: 66-char compressed pubkey hex required", id, alloc);
    if (hex_b.len != 66) return rpc.errorJson(-32602, "party_b must be 66-char hex", id, alloc);
    const pk_b = rpc.hexDecode33(hex_b) orelse return rpc.errorJson(-32602, "Invalid party_b hex", id, alloc);

    const ch = mgr.openChannel(pk_a, pk_b, amount_a, amount_b) catch |e| {
        return switch (e) {
            error.TooManyChannels => rpc.errorJson(-32000, "Maximum channels reached", id, alloc),
            error.ExceedsMaxAmount => rpc.errorJson(-32000, "Amount exceeds maximum", id, alloc),
            error.ZeroDeposit => rpc.errorJson(-32602, "Both amounts cannot be zero", id, alloc),
        };
    };

    var cid_hex: [64]u8 = undefined;
    const cid_str = ch.getChannelIdHex(&cid_hex);

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"channel_id\":\"{s}\",\"balance_a\":{d},\"balance_b\":{d},\"total_locked\":{d},\"state\":\"open\"}}}}",
        .{ id, cid_str, ch.balance_a, ch.balance_b, ch.total_locked });
}

/// RPC "channelpay" — off-chain payment within a channel.
/// Usage: {"method":"channelpay","params":["channel_id_hex","a_to_b",amount,"sig_a_hex","sig_b_hex"],"id":1}
/// direction: "a_to_b" or "b_to_a"
/// sig_a_hex / sig_b_hex: 128-char hex (64-byte secp256k1 ECDSA sigs over the
///                       canonical hash of the new ChannelUpdate). REQUIRED —
///                       channel state is only advanced if both verify.
pub fn handleChannelPay(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const mgr = ctx.channel_mgr orelse return rpc.errorJson(-32000, "Payment channels not initialized", id, alloc);

    const cid_hex = rpc.extractArrayStr(body, 0) orelse return rpc.errorJson(-32602, "Missing channel_id", id, alloc);
    if (cid_hex.len != 64) return rpc.errorJson(-32602, "channel_id must be 64-char hex", id, alloc);
    const channel_id = rpc.hexDecode32(cid_hex) orelse return rpc.errorJson(-32602, "Invalid channel_id hex", id, alloc);

    const dir_str = rpc.extractArrayStr(body, 1) orelse "a_to_b";
    const from_a = std.mem.eql(u8, dir_str, "a_to_b");

    const amount = rpc.extractArrayNum(body, 2);
    if (amount == 0) return rpc.errorJson(-32602, "Amount must be > 0", id, alloc);

    // Mandatory ECDSA signatures from both parties over the NEW state hash.
    const sig_a_hex = rpc.extractArrayStr(body, 3) orelse
        return rpc.errorJson(-32602, "Missing sig_a: 128-char hex ECDSA signature required", id, alloc);
    const sig_b_hex = rpc.extractArrayStr(body, 4) orelse
        return rpc.errorJson(-32602, "Missing sig_b: 128-char hex ECDSA signature required", id, alloc);
    if (sig_a_hex.len != 128) return rpc.errorJson(-32602, "sig_a must be 128-char hex", id, alloc);
    if (sig_b_hex.len != 128) return rpc.errorJson(-32602, "sig_b must be 128-char hex", id, alloc);
    const sig_a = rpc.hexDecode64(sig_a_hex) orelse return rpc.errorJson(-32602, "Invalid sig_a hex", id, alloc);
    const sig_b = rpc.hexDecode64(sig_b_hex) orelse return rpc.errorJson(-32602, "Invalid sig_b hex", id, alloc);

    const ch = mgr.findChannel(channel_id) orelse return rpc.errorJson(-32000, "Channel not found", id, alloc);

    _ = ch.pay(from_a, amount, sig_a, sig_b) catch |e| {
        return switch (e) {
            error.ChannelNotOpen => rpc.errorJson(-32000, "Channel not open", id, alloc),
            error.InsufficientBalance => rpc.errorJson(-32000, "Insufficient balance", id, alloc),
            error.BalanceMismatch => rpc.errorJson(-32000, "Balance mismatch", id, alloc),
            error.InvalidSignature => rpc.errorJson(-32000, "Invalid signature — sig_a or sig_b does not verify", id, alloc),
        };
    };

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"sequence_num\":{d},\"balance_a\":{d},\"balance_b\":{d}}}}}",
        .{ id, ch.sequence_num, ch.balance_a, ch.balance_b });
}

/// RPC "closechannel" — cooperative close of a payment channel.
/// Usage: {"method":"closechannel","params":["channel_id_hex"],"id":1}
pub fn handleCloseChannel(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const mgr = ctx.channel_mgr orelse return rpc.errorJson(-32000, "Payment channels not initialized", id, alloc);

    const cid_hex = rpc.extractArrayStr(body, 0) orelse return rpc.errorJson(-32602, "Missing channel_id", id, alloc);
    if (cid_hex.len != 64) return rpc.errorJson(-32602, "channel_id must be 64-char hex", id, alloc);
    const channel_id = rpc.hexDecode32(cid_hex) orelse return rpc.errorJson(-32602, "Invalid channel_id hex", id, alloc);

    // Both parties must sign the final state. Sigs are ECDSA over the
    // canonical hash of the final ChannelUpdate (see ChannelUpdate.hash).
    const sig_a_hex = rpc.extractArrayStr(body, 1) orelse
        return rpc.errorJson(-32602, "Missing sig_a: 128-char hex ECDSA signature required", id, alloc);
    const sig_b_hex = rpc.extractArrayStr(body, 2) orelse
        return rpc.errorJson(-32602, "Missing sig_b: 128-char hex ECDSA signature required", id, alloc);
    if (sig_a_hex.len != 128) return rpc.errorJson(-32602, "sig_a must be 128-char hex", id, alloc);
    if (sig_b_hex.len != 128) return rpc.errorJson(-32602, "sig_b must be 128-char hex", id, alloc);
    const sig_a = rpc.hexDecode64(sig_a_hex) orelse return rpc.errorJson(-32602, "Invalid sig_a hex", id, alloc);
    const sig_b = rpc.hexDecode64(sig_b_hex) orelse return rpc.errorJson(-32602, "Invalid sig_b hex", id, alloc);

    const settle = mgr.closeChannel(channel_id, sig_a, sig_b) catch |e| {
        return switch (e) {
            error.ChannelNotFound => rpc.errorJson(-32000, "Channel not found", id, alloc),
            error.ChannelNotOpen => rpc.errorJson(-32000, "Channel not open", id, alloc),
            error.InvalidSignature => rpc.errorJson(-32000, "Invalid signature — sig_a or sig_b does not verify", id, alloc),
        };
    };

    const tx_a_hex = std.fmt.bytesToHex(settle.tx_hash_a, .lower);
    const tx_b_hex = std.fmt.bytesToHex(settle.tx_hash_b, .lower);

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"state\":\"settled\",\"final_balance_a\":{d},\"final_balance_b\":{d},\"tx_hash_a\":\"{s}\",\"tx_hash_b\":\"{s}\"}}}}",
        .{ id, settle.final_balance_a, settle.final_balance_b, &tx_a_hex, &tx_b_hex });
}

/// RPC "getchannels" — list payment channels with full per-channel details.
/// Usage: {"method":"getchannels","params":[],"id":1}
///        {"method":"getchannels","params":["<pubkey_hex_33>"],"id":1}  // filter by participant
/// Returns: { summary: {...}, channels: [ {id, party_a, party_b, capacity_sat, balance_a, balance_b,
///                                         sequence_num, state, funding_tx_hash}, ... ] }
pub fn handleGetChannels(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const mgr = ctx.channel_mgr orelse return rpc.errorJson(-32000, "Payment channels not initialized", id, alloc);

    // Optional pubkey filter (66-char hex compressed pubkey).
    // NOTE: Filter is by raw pubkey hex, NOT by bech32 address. Address-based lookup
    // would require a pubkey→address map; deferred to a follow-up since channels
    // currently store [33]u8 pubkeys, not bech32 strings.
    var filter_pk: ?[33]u8 = null;
    if (rpc.extractArrayStr(body, 0)) |hex| {
        if (hex.len == 66) {
            filter_pk = rpc.hexDecode33(hex);
        }
    }

    const open_count = mgr.countByState(.open);
    const closing_count = mgr.countByState(.closing);
    const settled_count = mgr.countByState(.settled);
    const disputed_count = mgr.countByState(.disputed);
    const total_locked = mgr.getTotalLockedSat();

    // Build the channels array. Use a heap-backed growable buffer because the
    // count is variable (up to MAX_CHANNELS = 64) and per-channel JSON is ~600B.
    var out = std.ArrayList(u8){};
    defer out.deinit(alloc);

    {
        const hdr = try std.fmt.allocPrint(alloc,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{" ++
            "\"summary\":{{\"total_channels\":{d},\"open\":{d},\"closing\":{d},\"settled\":{d},\"disputed\":{d},\"total_locked_sat\":{d}}}," ++
            "\"channels\":[",
            .{ id, mgr.channel_count, open_count, closing_count, settled_count, disputed_count, total_locked },
        );
        defer alloc.free(hdr);
        try out.appendSlice(alloc, hdr);
    }

    var first: bool = true;
    var i: u8 = 0;
    while (i < mgr.channel_count) : (i += 1) {
        const ch = &mgr.channels[i];

        // Apply filter if set: include only if filter_pk == party_a or party_b.
        if (filter_pk) |pk| {
            const match_a = std.mem.eql(u8, &ch.party_a, &pk);
            const match_b = std.mem.eql(u8, &ch.party_b, &pk);
            if (!match_a and !match_b) continue;
        }

        if (!first) try out.append(alloc, ',');
        first = false;

        const state_str: []const u8 = switch (ch.state) {
            .opening => "opening",
            .open => "open",
            .closing => "closing",
            .settled => "settled",
            .disputed => "disputed",
        };

        const cid_hex = std.fmt.bytesToHex(ch.channel_id, .lower);
        const pa_hex = std.fmt.bytesToHex(ch.party_a, .lower);
        const pb_hex = std.fmt.bytesToHex(ch.party_b, .lower);
        const ftx_hex = std.fmt.bytesToHex(ch.funding_tx_hash, .lower);

        const entry = try std.fmt.allocPrint(alloc,
            "{{\"channel_id\":\"{s}\",\"party_a\":\"{s}\",\"party_b\":\"{s}\"," ++
            "\"capacity_sat\":{d},\"balance_a\":{d},\"balance_b\":{d}," ++
            "\"sequence_num\":{d},\"state\":\"{s}\",\"funding_tx_hash\":\"{s}\"," ++
            "\"close_block\":{d},\"htlc_count\":{d}}}",
            .{
                &cid_hex, &pa_hex, &pb_hex,
                ch.total_locked, ch.balance_a, ch.balance_b,
                ch.sequence_num, state_str, &ftx_hex,
                ch.close_block,
                ch.htlc_count,
            },
        );
        defer alloc.free(entry);
        try out.appendSlice(alloc, entry);
    }

    try out.appendSlice(alloc, "]}}");
    return alloc.dupe(u8, out.items);
}
