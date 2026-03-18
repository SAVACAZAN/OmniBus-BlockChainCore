const std = @import("std");

/// Seed Node Configuration
pub const SeedNodeConfig = struct {
    node_id: []const u8,
    host: []const u8,
    port: u16,
    is_primary: bool,
    max_peers: u32,
    allocator: std.mem.Allocator,
};

/// Bootstrap Node - Entry point for network
pub const BootstrapNode = struct {
    config: SeedNodeConfig,
    peers: std.ArrayList(Peer),
    status: NodeStatus,
    created_at: i64,

    pub const NodeStatus = enum {
        starting,
        waiting_for_peers,
        syncing,
        synchronized,
        mining,
    };

    pub const Peer = struct {
        node_id: []const u8,
        host: []const u8,
        port: u16,
        version: []const u8,
        last_seen: i64,
        latency_ms: u32,
    };

    pub fn init(config: SeedNodeConfig) BootstrapNode {
        return BootstrapNode{
            .config = config,
            .peers = std.ArrayList(Peer).init(config.allocator),
            .status = NodeStatus.starting,
            .created_at = std.time.timestamp(),
        };
    }

    pub fn deinit(self: *BootstrapNode) void {
        self.peers.deinit();
    }

    /// Register new peer node
    pub fn registerPeer(self: *BootstrapNode, peer: Peer) !void {
        if (self.peers.items.len >= self.config.max_peers) {
            return error.MaxPeersReached;
        }

        try self.peers.append(peer);
        std.debug.print("[BOOTSTRAP] Peer registered: {s}:{d}\n", .{ peer.host, peer.port });
    }

    /// Get list of known peers for new node
    pub fn getPeerList(self: *const BootstrapNode) []const Peer {
        return self.peers.items;
    }

    /// Update peer status (heartbeat)
    pub fn updatePeerStatus(self: *BootstrapNode, node_id: []const u8, latency: u32) !void {
        for (self.peers.items) |*peer| {
            if (std.mem.eql(u8, peer.node_id, node_id)) {
                peer.last_seen = std.time.timestamp();
                peer.latency_ms = latency;
                return;
            }
        }
        return error.PeerNotFound;
    }

    /// Remove stale peers (no heartbeat for 60s)
    pub fn removeStaleP eers(self: *BootstrapNode) void {
        const now = std.time.timestamp();
        const stale_threshold: i64 = 60; // 60 seconds

        var i: usize = 0;
        while (i < self.peers.items.len) {
            if (now - self.peers.items[i].last_seen > stale_threshold) {
                _ = self.peers.swapRemove(i);
                std.debug.print("[BOOTSTRAP] Removed stale peer\n", .{});
            } else {
                i += 1;
            }
        }
    }

    /// Get node statistics
    pub fn getStats(self: *const BootstrapNode) BootstrapStats {
        var total_latency: u64 = 0;
        var avg_latency: u32 = 0;

        for (self.peers.items) |peer| {
            total_latency += peer.latency_ms;
        }

        if (self.peers.items.len > 0) {
            avg_latency = @intCast(total_latency / self.peers.items.len);
        }

        return BootstrapStats{
            .uptime_seconds = std.time.timestamp() - self.created_at,
            .peer_count = self.peers.items.len,
            .avg_latency_ms = avg_latency,
            .status = self.status,
        };
    }

    /// Update status
    pub fn setStatus(self: *BootstrapNode, status: NodeStatus) void {
        self.status = status;
        std.debug.print("[BOOTSTRAP] Status changed to: {any}\n", .{status});
    }

    /// Check if ready to start mining
    pub fn readyForMining(self: *const BootstrapNode) bool {
        return self.status == NodeStatus.synchronized and self.peers.items.len > 0;
    }
};

pub const BootstrapStats = struct {
    uptime_seconds: i64,
    peer_count: usize,
    avg_latency_ms: u32,
    status: BootstrapNode.NodeStatus,
};

/// Multiple Seed Nodes for redundancy
pub const SeedNodePool = struct {
    primary: BootstrapNode,
    secondary: std.ArrayList(BootstrapNode),
    allocator: std.mem.Allocator,

    pub fn init(primary_config: SeedNodeConfig, allocator: std.mem.Allocator) SeedNodePool {
        const primary = BootstrapNode.init(primary_config);

        return SeedNodePool{
            .primary = primary,
            .secondary = std.ArrayList(BootstrapNode).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *SeedNodePool) void {
        self.primary.deinit();
        for (self.secondary.items) |*node| {
            node.deinit();
        }
        self.secondary.deinit();
    }

    /// Add secondary seed node
    pub fn addSecondaryNode(self: *SeedNodePool, config: SeedNodeConfig) !void {
        const node = BootstrapNode.init(config);
        try self.secondary.append(node);
    }

    /// Get all nodes (primary + secondary)
    pub fn getAllNodes(self: *SeedNodePool) usize {
        return 1 + self.secondary.items.len;
    }

    /// Get total peer count across all nodes
    pub fn getTotalPeers(self: *const SeedNodePool) usize {
        var total: usize = self.primary.peers.items.len;

        for (self.secondary.items) |node| {
            total += node.peers.items.len;
        }

        return total;
    }

    /// Check if network is ready (all nodes synchronized)
    pub fn isNetworkReady(self: *const SeedNodePool) bool {
        if (self.primary.status != BootstrapNode.NodeStatus.synchronized) {
            return false;
        }

        for (self.secondary.items) |node| {
            if (node.status != BootstrapNode.NodeStatus.synchronized) {
                return false;
            }
        }

        return true;
    }

    /// Start mining on all nodes
    pub fn startMining(self: *SeedNodePool) void {
        self.primary.setStatus(BootstrapNode.NodeStatus.mining);

        for (self.secondary.items) |*node| {
            node.setStatus(BootstrapNode.NodeStatus.mining);
        }

        std.debug.print("[NETWORK] Mining started on all seed nodes!\n", .{});
    }
};

// Tests
const testing = std.testing;

test "bootstrap node initialization" {
    const config = SeedNodeConfig{
        .node_id = "seed-1",
        .host = "127.0.0.1",
        .port = 9000,
        .is_primary = true,
        .max_peers = 100,
        .allocator = testing.allocator,
    };

    var node = BootstrapNode.init(config);
    defer node.deinit();

    try testing.expectEqual(node.status, BootstrapNode.NodeStatus.starting);
}

test "register peer" {
    const config = SeedNodeConfig{
        .node_id = "seed-1",
        .host = "127.0.0.1",
        .port = 9000,
        .is_primary = true,
        .max_peers = 100,
        .allocator = testing.allocator,
    };

    var node = BootstrapNode.init(config);
    defer node.deinit();

    const peer = BootstrapNode.Peer{
        .node_id = "miner-1",
        .host = "192.168.1.100",
        .port = 9001,
        .version = "1.0.0",
        .last_seen = std.time.timestamp(),
        .latency_ms = 25,
    };

    try node.registerPeer(peer);
    try testing.expectEqual(node.peers.items.len, 1);
}

test "seed node pool" {
    const primary_config = SeedNodeConfig{
        .node_id = "seed-primary",
        .host = "10.0.0.1",
        .port = 9000,
        .is_primary = true,
        .max_peers = 100,
        .allocator = testing.allocator,
    };

    var pool = SeedNodePool.init(primary_config, testing.allocator);
    defer pool.deinit();

    try testing.expectEqual(pool.getAllNodes(), 1);
}

test "network ready check" {
    const config = SeedNodeConfig{
        .node_id = "seed-1",
        .host = "127.0.0.1",
        .port = 9000,
        .is_primary = true,
        .max_peers = 100,
        .allocator = testing.allocator,
    };

    var pool = SeedNodePool.init(config, testing.allocator);
    defer pool.deinit();

    // Not ready yet
    try testing.expect(!pool.isNetworkReady());

    // Update status
    pool.primary.setStatus(BootstrapNode.NodeStatus.synchronized);

    // Now ready
    try testing.expect(pool.isNetworkReady());
}
