// Networking / peer JSON-RPC handlers.
//
// Bitcoin-Core analogues live in `src/rpc/net.cpp`. These methods expose
// the live P2P peer set, sync progress, and node identity. They never
// mutate peer state — peer management goes through `p2p.zig` (connect /
// disconnect / scoring). Output formatting holds `p2p.peers_mutex` while
// walking the peer list because peer struct slices (`node_id`, `host`)
// would UAF if `acceptLoop` reallocates the backing array mid-iteration.

const std = @import("std");
const rpc = @import("../rpc_server.zig");
const blockchain_mod = @import("../blockchain.zig");
const p2p_mod = @import("../p2p.zig");

const ServerCtx = rpc.ServerCtx;

// SEGFAULT-FIX [scan-2026-04-25]: hold p2p.peers_mutex for entire iteration.
// peer.node_id / peer.host are slices into PeerConnection; if acceptLoop appends
// concurrently and reallocs backing storage we'd UAF on items.ptr. We allocPrint
// inside the lock — slow but correct; for high-throughput callers, snapshot first.
pub fn handlePeers(ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const p2p = ctx.p2p orelse return std.fmt.allocPrint(alloc, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"count\":0,\"height\":0,\"peers\":[]}}}}", .{id});
    var pj: []u8 = try alloc.dupe(u8, "");
    var pc: usize = 0;
    {
        p2p.peers_mutex.lock();
        defer p2p.peers_mutex.unlock();
        for (p2p.peers.items) |peer| {
            const sep: []const u8 = if (pc == 0) "" else ",";
            const e = try std.fmt.allocPrint(alloc, "{s}{{\"id\":\"{s}\",\"host\":\"{s}\",\"port\":{d},\"alive\":{s}}}", .{ sep, peer.node_id, peer.host, peer.port, if (peer.connected) "true" else "false" });
            const m = try std.fmt.allocPrint(alloc, "{s}{s}", .{ pj, e });
            alloc.free(pj); alloc.free(e); pj = m; pc += 1;
        }
    }
    defer alloc.free(pj);
    return std.fmt.allocPrint(alloc, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"count\":{d},\"height\":{d},\"peers\":[{s}]}}}}", .{ id, pc, p2p.chain_height, pj });
}

pub fn handleSyncSt(ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;

    // IBD truth comes from p2p.is_syncing + best_peer_height (set in
    // p2p.zig WELCOME / sync_response handlers). This is the same flag the
    // mining loop checks — UI must agree with it, otherwise users see
    // "synced" while the miner is still gated.
    const ibd_active: bool = if (ctx.p2p) |p| p.is_syncing.load(.acquire) else false;
    const best_peer_h: u64 = if (ctx.p2p) |p| p.best_peer_height.load(.acquire) else 0;

    if (ctx.sync_mgr) |s| {
        const local_h = s.state.local_height;
        const peer_h  = if (best_peer_h > s.state.peer_height) best_peer_h else s.state.peer_height;
        const behind: u64 = if (peer_h > local_h) peer_h - local_h else 0;
        const pct: u64 = if (peer_h == 0) 100 else @min(@as(u64, 100), (local_h * 100) / peer_h);
        return std.fmt.allocPrint(alloc, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"status\":\"{s}\",\"localHeight\":{d},\"peerHeight\":{d},\"behind\":{d},\"progress\":{d},\"synced\":{s},\"stalled\":{s},\"ibd\":{s}}}}}", .{ id, @tagName(s.state.status), local_h, peer_h, behind, pct, if (s.isSynced() and !ibd_active) "true" else "false", if (s.isStalled()) "true" else "false", if (ibd_active) "true" else "false" });
    }
    const h = ctx.bc.getBlockCount();
    const peer_h = if (best_peer_h > h) best_peer_h else h;
    const behind: u64 = if (peer_h > h) peer_h - h else 0;
    const pct: u64 = if (peer_h == 0) 100 else @min(@as(u64, 100), (h * 100) / peer_h);
    return std.fmt.allocPrint(alloc, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"status\":\"{s}\",\"localHeight\":{d},\"peerHeight\":{d},\"behind\":{d},\"progress\":{d},\"synced\":{s},\"stalled\":false,\"ibd\":{s}}}}}", .{ id, if (ibd_active) "syncing" else "synced", h, peer_h, behind, pct, if (ibd_active) "false" else "true", if (ibd_active) "true" else "false" });
}

// SEGFAULT-FIX [scan-2026-04-25]: snapshot bc fields under bc.mutex; format
// outside both locks. Same root cause as handlePeers (p2p).
pub fn handleNetInfo(ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    ctx.bc.mutex.lock();
    const h = ctx.bc.getBlockCountUnlocked();
    const diff = ctx.bc.difficulty;
    const bc_mp_len = ctx.bc.mempool.items.len;
    ctx.bc.mutex.unlock();
    const pc: usize = if (ctx.p2p) |p| blk: {
        p.peers_mutex.lock();
        const len = p.peers.items.len;
        p.peers_mutex.unlock();
        break :blk len;
    } else 0;
    const ms: usize = if (ctx.mempool) |m| m.size() else bc_mp_len;
    const r = blockchain_mod.blockRewardAt(h);
    // Derive chain label from chain_id instead of hardcoding "omnibus-mainnet"
    // (was misleading on testnet/regtest nodes — Network page showed
    // "omnibus-mainnet" while user was browsing testnet).
    const chain_label: []const u8 = switch (ctx.chain_id) {
        1    => "omnibus-mainnet",
        2    => "omnibus-testnet",
        3    => "omnibus-devnet",
        4    => "omnibus-regtest",
        else => "omnibus-unknown",
    };
    return std.fmt.allocPrint(alloc, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"chain\":\"{s}\",\"version\":\"1.0.0\",\"blockHeight\":{d},\"blockRewardSAT\":{d},\"difficulty\":{d},\"mempoolSize\":{d},\"peerCount\":{d},\"nodeAddress\":\"{s}\",\"nodeBalance\":{d},\"halvingInterval\":126144000,\"maxSupply\":21000000000000000,\"blockTimeMs\":1000,\"subBlocksPerBlock\":10}}}}", .{ id, chain_label, h, r, diff, ms, pc, ctx.wallet.address, ctx.wallet.getBalance() });
}

pub fn handleNodeList(ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const h = ctx.bc.getBlockCount();
    // +1 = include self (this node is both a node AND a miner)
    const remote_peers: usize = if (ctx.p2p) |p| p.peers.items.len else 0;
    const total_nodes: usize = remote_peers + 1; // self = always 1 node
    const ms: usize = if (ctx.mempool) |m| m.size() else ctx.bc.mempool.items.len;

    // Count unique miners from chain + self (always 1 miner = this node)
    var miner_count: u32 = 1; // self = always counted as miner
    var last_miner: []const u8 = "";
    for (ctx.bc.chain.items) |blk| {
        if (blk.miner_address.len > 0 and !std.mem.eql(u8, blk.miner_address, last_miner)) {
            miner_count += 1;
            last_miner = blk.miner_address;
        }
    }

    // Build peer list
    var peers_json: []u8 = try alloc.dupe(u8, "");
    var peer_n: usize = 0;
    if (ctx.p2p) |p2p| {
        for (p2p.peers.items) |peer| {
            const sep: []const u8 = if (peer_n == 0) "" else ",";
            const e = try std.fmt.allocPrint(alloc, "{s}{{\"id\":\"{s}\",\"host\":\"{s}\",\"port\":{d},\"connected\":{s},\"height\":{d}}}", .{ sep, peer.node_id, peer.host, peer.port, if (peer.connected) "true" else "false", p2p.chain_height });
            const m = try std.fmt.allocPrint(alloc, "{s}{s}", .{ peers_json, e });
            alloc.free(peers_json);
            alloc.free(e);
            peers_json = m;
            peer_n += 1;
        }
    }
    defer alloc.free(peers_json);

    return std.fmt.allocPrint(alloc, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"localNode\":{{\"id\":\"{s}\",\"address\":\"{s}\",\"height\":{d},\"difficulty\":{d},\"mempool\":{d}}},\"network\":{{\"totalPeers\":{d},\"totalMiners\":{d},\"chainHeight\":{d}}},\"peers\":[{s}]}}}}", .{ id, ctx.wallet.address[0..@min(20, ctx.wallet.address.len)], ctx.wallet.address, h, ctx.bc.difficulty, ms, total_nodes, miner_count, h, peers_json });
}

/// getconnectioncount — returns peer count as integer.
pub fn handleGetConnectionCount(ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const pc: u64 = if (ctx.p2p) |p| @intCast(p.peers.items.len) else 0;
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{d}}}",
        .{ id, pc },
    );
}

/// getpeerinfo — returns array of peer details (addr, height, version, alive).
/// Note: PeerConnection has no `last_seen` field; emit 0 with comment.
pub fn handleGetPeerInfo(ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    // Empty array fallback if p2p not attached
    const p2p = ctx.p2p orelse return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":[]}}", .{id});

    var entries: []u8 = try alloc.dupe(u8, "");
    var n: usize = 0;
    {
        p2p.peers_mutex.lock();
        defer p2p.peers_mutex.unlock();
        for (p2p.peers.items) |peer| {
            const sep: []const u8 = if (n == 0) "" else ",";
            const e = try std.fmt.allocPrint(alloc,
                "{s}{{\"id\":\"{s}\",\"addr\":\"{s}:{d}\",\"host\":\"{s}\",\"port\":{d},\"height\":{d},\"version\":{d},\"alive\":{s},\"last_seen\":0}}",
                .{ sep, peer.node_id, peer.host, peer.port, peer.host, peer.port, peer.height, p2p_mod.P2P_VERSION, if (peer.connected) "true" else "false" });
            const m = try std.fmt.allocPrint(alloc, "{s}{s}", .{ entries, e });
            alloc.free(entries);
            alloc.free(e);
            entries = m;
            n += 1;
        }
    }
    defer alloc.free(entries);
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":[{s}]}}",
        .{ id, entries });
}
