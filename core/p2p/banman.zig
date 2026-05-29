// Peer ban management + reconnect queue for the P2P layer.
//
// Extracted from core/p2p.zig. The P2PNode struct itself stays in p2p.zig
// (intentional — too many cross-cutting fields). This file owns:
//   * BannedPeer / ReconnectInfo data types
//   * isBanned / banPeer / disconnectPeerByHost / evictExpiredBans
//   * addReconnect / clearReconnect / processReconnects
//
// Free functions take `*P2PNode` (or `*const P2PNode`) so the call sites
// in p2p.zig become one-line delegations.

const std = @import("std");
const p2p_mod = @import("../p2p.zig");
const P2PNode = p2p_mod.P2PNode;
const scoring_mod = @import("../peer_scoring.zig");

/// Banned peer entry — tracks host:port + ban expiry
pub const BannedPeer = struct {
    host: [64]u8,
    host_len: u8,
    port: u16,
    banned_until: i64, // Unix timestamp
    reason: [64]u8,
    reason_len: u8,
    active: bool,

    pub fn init(host: []const u8, port: u16, duration_sec: i64, reason: []const u8) BannedPeer {
        var bp: BannedPeer = .{
            .host = @splat(0),
            .host_len = @intCast(@min(host.len, 64)),
            .port = port,
            .banned_until = std.time.timestamp() + duration_sec,
            .reason = @splat(0),
            .reason_len = @intCast(@min(reason.len, 64)),
            .active = true,
        };
        @memcpy(bp.host[0..bp.host_len], host[0..bp.host_len]);
        @memcpy(bp.reason[0..bp.reason_len], reason[0..bp.reason_len]);
        return bp;
    }

    pub fn isExpired(self: *const BannedPeer) bool {
        return std.time.timestamp() >= self.banned_until;
    }

    pub fn matchesHost(self: *const BannedPeer, host: []const u8, port: u16) bool {
        if (!self.active) return false;
        if (self.port != port) return false;
        if (self.host_len != host.len) return false;
        return std.mem.eql(u8, self.host[0..self.host_len], host);
    }
};

/// Per-peer reconnect tracking
pub const ReconnectInfo = struct {
    host: [64]u8,
    host_len: u8,
    port: u16,
    node_id: [64]u8,
    node_id_len: u8,
    attempts: u8,
    last_disconnect: i64,
    active: bool,

    pub fn init(host: []const u8, port: u16, node_id: []const u8) ReconnectInfo {
        var ri: ReconnectInfo = .{
            .host = @splat(0),
            .host_len = @intCast(@min(host.len, 64)),
            .port = port,
            .node_id = @splat(0),
            .node_id_len = @intCast(@min(node_id.len, 64)),
            .attempts = 0,
            .last_disconnect = std.time.timestamp(),
            .active = true,
        };
        @memcpy(ri.host[0..ri.host_len], host[0..ri.host_len]);
        @memcpy(ri.node_id[0..ri.node_id_len], node_id[0..ri.node_id_len]);
        return ri;
    }
};

// ─── Ban management ─────────────────────────────────────────────────────────

/// Check if a host:port is currently banned
pub fn isBanned(self: *const P2PNode, host: []const u8, port: u16) bool {
    for (&self.banned_peers) |*bp| {
        if (!bp.active) continue;
        if (bp.matchesHost(host, port)) {
            return !bp.isExpired();
        }
    }
    return false;
}

/// Ban a peer by host:port for the configured duration
pub fn banPeer(self: *P2PNode, host: []const u8, port: u16, reason: []const u8) void {
    // Check if already banned — update expiry
    for (&self.banned_peers) |*bp| {
        if (bp.active and bp.matchesHost(host, port)) {
            bp.banned_until = std.time.timestamp() + scoring_mod.BAN_DURATION_SEC;
            @memcpy(bp.reason[0..@min(reason.len, 64)], reason[0..@min(reason.len, 64)]);
            bp.reason_len = @intCast(@min(reason.len, 64));
            return;
        }
    }
    // Find empty slot or oldest entry
    var slot: usize = 0;
    var found_empty = false;
    var oldest_time: i64 = std.math.maxInt(i64);
    for (&self.banned_peers, 0..) |*bp, i| {
        if (!bp.active) {
            slot = i;
            found_empty = true;
            break;
        }
        if (bp.banned_until < oldest_time) {
            oldest_time = bp.banned_until;
            slot = i;
        }
    }
    self.banned_peers[slot] = BannedPeer.init(host, port, scoring_mod.BAN_DURATION_SEC, reason);
    if (!found_empty) {
        // Overwritten an existing entry
    } else {
        if (self.banned_count < p2p_mod.MAX_BANNED_PEERS) self.banned_count += 1;
    }
    std.debug.print("[P2P] Banned {s}:{d} reason: {s}\n", .{ host, port, reason });

    // Disconnect the peer if currently connected
    disconnectPeerByHost(self, host, port);
}

/// Disconnect a peer by host:port
pub fn disconnectPeerByHost(self: *P2PNode, host: []const u8, port: u16) void {
    self.peers_mutex.lock();
    defer self.peers_mutex.unlock();
    for (self.peers.items) |*peer| {
        if (peer.connected and peer.port == port and std.mem.eql(u8, peer.host, host)) {
            peer.connected = false;
            peer.close();
            return;
        }
    }
}

/// Evict expired bans
pub fn evictExpiredBans(self: *P2PNode) void {
    for (&self.banned_peers) |*bp| {
        if (bp.active and bp.isExpired()) {
            bp.active = false;
            if (self.banned_count > 0) self.banned_count -= 1;
        }
    }
}

// ─── Reconnect management ───────────────────────────────────────────────────

/// Add a disconnected peer to the reconnect queue
pub fn addReconnect(self: *P2PNode, host: []const u8, port: u16, node_id: []const u8) void {
    // Check if already in queue — increment attempts
    for (&self.reconnect_queue) |*ri| {
        if (!ri.active) continue;
        if (ri.port == port and ri.host_len == host.len and
            std.mem.eql(u8, ri.host[0..ri.host_len], host))
        {
            ri.attempts += 1;
            ri.last_disconnect = std.time.timestamp();
            if (ri.attempts >= p2p_mod.MAX_RECONNECT_ATTEMPTS) {
                std.debug.print("[P2P] Reconnect limit reached for {s}:{d} — removing\n",
                    .{ host, port });
                ri.active = false;
                if (self.reconnect_count > 0) self.reconnect_count -= 1;
            }
            return;
        }
    }
    // Add new entry
    if (self.reconnect_count >= p2p_mod.MAX_PEERS) return;
    for (&self.reconnect_queue) |*ri| {
        if (!ri.active) {
            ri.* = ReconnectInfo.init(host, port, node_id);
            self.reconnect_count += 1;
            return;
        }
    }
}

/// Clear reconnect entry on successful connection
pub fn clearReconnect(self: *P2PNode, host: []const u8, port: u16) void {
    for (&self.reconnect_queue) |*ri| {
        if (!ri.active) continue;
        if (ri.port == port and ri.host_len == host.len and
            std.mem.eql(u8, ri.host[0..ri.host_len], host))
        {
            ri.active = false;
            if (self.reconnect_count > 0) self.reconnect_count -= 1;
            return;
        }
    }
}

/// Process reconnect queue — attempt reconnects for peers past the delay
pub fn processReconnects(self: *P2PNode) void {
    const now = std.time.timestamp();
    for (&self.reconnect_queue) |*ri| {
        if (!ri.active) continue;
        if (ri.attempts >= p2p_mod.MAX_RECONNECT_ATTEMPTS) {
            ri.active = false;
            if (self.reconnect_count > 0) self.reconnect_count -= 1;
            continue;
        }
        if (now - ri.last_disconnect < p2p_mod.RECONNECT_DELAY_SEC) continue;

        // Attempt reconnect
        const host = ri.host[0..ri.host_len];
        const node_id = ri.node_id[0..ri.node_id_len];
        std.debug.print("[P2P] Reconnect attempt {d}/{d} to {s}:{d}\n",
            .{ ri.attempts + 1, p2p_mod.MAX_RECONNECT_ATTEMPTS, host, ri.port });

        self.connectToPeer(host, ri.port, node_id) catch {
            ri.attempts += 1;
            ri.last_disconnect = now;
            if (ri.attempts >= p2p_mod.MAX_RECONNECT_ATTEMPTS) {
                std.debug.print("[P2P] Reconnect failed permanently for {s}:{d}\n",
                    .{ host, ri.port });
                ri.active = false;
                if (self.reconnect_count > 0) self.reconnect_count -= 1;
            }
            continue;
        };
        // Success — clearReconnect is called inside connectToPeer
    }
}
