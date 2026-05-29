// Sync coordination — header/block sync requests + fork recovery.
//
// Extracted from core/p2p.zig. Free functions over *P2PNode for:
//   - tryForkRecovery (truncate local tip + re-sync after persistent
//     broadcast failures suggest we mined on a rejected fork)
//   - requestSync / requestSyncForced / requestSyncEx
//     (sync_request emission, optionally bypassing the peer.height gate)
//   - syncHeaders (SPV getheaders_p2p fanout)
//
// Methods on P2PNode are thin delegates calling these.

const std = @import("std");
const p2p_mod = @import("../p2p.zig");
const wire = @import("wire.zig");
const sync_mod = @import("../sync.zig");

const P2PNode = p2p_mod.P2PNode;
const MessageType = p2p_mod.MessageType;
const SPV_MAX_HEADERS_PER_MSG = wire.SPV_MAX_HEADERS_PER_MSG;
const encodeGetHeaders = wire.encodeGetHeaders;

// Mirror the fork-recovery thresholds declared on P2PNode.
const FORK_RECOVERY_THRESHOLD: u32 = 3;
const FORK_RECOVERY_MAX_TRUNC: u64 = 2;

// ─── Fork Recovery ───────────────────────────────────────────────────────────

/// Detect persistent broadcast failures → assume our tip is on a rejected
/// fork and truncate a few blocks so the next sync round can repair us.
/// Returns true if a truncation was performed.
pub fn tryForkRecovery(node: *P2PNode) bool {
    const fails = node.consecutive_bcast_fails.load(.acquire);
    if (fails < FORK_RECOVERY_THRESHOLD) return false;
    const bc = node.blockchain orelse return false;
    bc.mutex.lock();
    const local_h: u64 = bc.chain.items.len;
    bc.mutex.unlock();
    if (local_h <= 2) return false;
    const trunc_to: u64 = local_h - @min(FORK_RECOVERY_MAX_TRUNC, local_h - 1);
    std.debug.print(
        "[FORK-RECOVERY] {d} consecutive broadcast fails — trunchating local chain {d} -> {d} (drop {d}) and re-syncing\n",
        .{ fails, local_h, trunc_to, local_h - trunc_to },
    );
    bc.mutex.lock();
    while (bc.chain.items.len > trunc_to) {
        var b = bc.chain.pop() orelse break;
        node.allocator.free(b.hash);
        if (b.miner_heap and b.miner_address.len > 0) {
            node.allocator.free(b.miner_address);
        }
        b.transactions.deinit();
    }
    bc.recalculateFromHeight(@intCast(trunc_to)) catch |err| {
        std.debug.print("[FORK-RECOVERY] recalculateFromHeight failed: {}\n", .{err});
    };
    bc.mutex.unlock();
    node.consecutive_bcast_fails.store(0, .release);
    if (node.sync_mgr) |sm| sm.state.status = .downloading;
    node.is_syncing.store(false, .release);
    return true;
}

// ─── SPV Header Sync ─────────────────────────────────────────────────────────

/// SPV: Send getheaders_p2p to all connected peers.
/// Requests headers starting from our current header chain height.
pub fn syncHeaders(node: *P2PNode) void {
    const lc = node.light_client orelse return;
    const start_height = lc.getHeight();
    const count: u32 = @intCast(@min(SPV_MAX_HEADERS_PER_MSG, 500));

    var payload: [8]u8 = undefined;
    encodeGetHeaders(start_height, count, &payload);

    var sent: usize = 0;
    node.peers_mutex.lock();
    defer node.peers_mutex.unlock();
    for (node.peers.items) |*peer| {
        if (!peer.connected) continue;
        peer.send(@intFromEnum(MessageType.getheaders_p2p), &payload) catch |err| {
            std.debug.print("[SPV] getheaders_p2p send to {s} failed: {}\n",
                .{ peer.node_id[0..@min(peer.node_id.len, 16)], err });
            continue;
        };
        sent += 1;
    }
    if (sent > 0) {
        std.debug.print("[SPV] getheaders_p2p sent to {d} peers (from height {d}, max {d})\n",
            .{ sent, start_height, count });
    }
}

// ─── Sync Request Emission ───────────────────────────────────────────────────

/// Standard sync request — only sent to peers reporting higher height.
pub fn requestSync(node: *P2PNode, from_height: u64) void {
    requestSyncEx(node, from_height, false);
}

/// Forced sync request — bypasses the peer.height gate. Used in fork
/// detection where a peer may be lower but on a different branch and we
/// need its headers for heaviest-chain comparison.
pub fn requestSyncForced(node: *P2PNode, from_height: u64) void {
    requestSyncEx(node, from_height, true);
}

pub fn requestSyncEx(node: *P2PNode, from_height: u64, force_on_lower_peer: bool) void {
    const req = sync_mod.MsgGetHeaders{
        .from_height = from_height,
        .max_count   = sync_mod.SyncManager.MAX_HEADERS_PER_REQ,
    };
    const payload = req.encode(); // returns [10]u8

    node.peers_mutex.lock();
    defer node.peers_mutex.unlock();
    for (node.peers.items) |*peer| {
        if (!peer.connected) continue;
        if (!force_on_lower_peer and peer.height <= from_height) continue;
        peer.send(@intFromEnum(MessageType.sync_request), &payload) catch |err| {
            std.debug.print("[P2P] Sync request la {s} failed: {}\n",
                .{ peer.node_id[0..@min(peer.node_id.len, 16)], err });
        };
        std.debug.print("[P2P] SYNC_REQUEST trimis la {s} (from height={d}, max={d}, forced={})\n",
            .{ peer.node_id[0..@min(peer.node_id.len, 16)], from_height,
               sync_mod.SyncManager.MAX_HEADERS_PER_REQ, force_on_lower_peer });
        return; // send to first available peer
    }
}
