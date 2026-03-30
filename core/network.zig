const std = @import("std");
const array_list = std.array_list;

/// Network Node - P2P participant
pub const NetworkNode = struct {
    node_id: []const u8,
    host: []const u8,
    port: u16,
    version: []const u8,
    is_miner: bool,
    allocator: std.mem.Allocator,

    pub fn init(
        node_id: []const u8,
        host: []const u8,
        port: u16,
        version: []const u8,
        is_miner: bool,
        allocator: std.mem.Allocator,
    ) NetworkNode {
        return NetworkNode{
            .node_id = node_id,
            .host = host,
            .port = port,
            .version = version,
            .is_miner = is_miner,
            .allocator = allocator,
        };
    }

    /// Get node address string
    pub fn getAddress(self: *const NetworkNode) []const u8 {
        return self.host;
    }

    /// Get node endpoint (host:port)
    pub fn getEndpoint(self: *const NetworkNode, allocator: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator, "{s}:{d}", .{ self.host, self.port });
    }
};

/// P2P Network - Manages all connected nodes
pub const P2PNetwork = struct {
    local_node: NetworkNode,
    connected_nodes: array_list.Managed(NetworkNode),
    seed_nodes: array_list.Managed(NetworkNode),
    allocator: std.mem.Allocator,
    /// Opaque pointer to P2PNode — avoids circular import (p2p.zig imports network.zig)
    /// Cast with: @as(*p2p_mod.P2PNode, @alignCast(@ptrCast(self.p2p_node.?)))
    p2p_node_ptr: ?*anyopaque = null,
    /// Broadcast function pointer set by p2p.zig after init
    broadcast_fn: ?*const fn (node_ptr: *anyopaque, height: u64, message: []const u8, reward: u64) void = null,

    pub fn init(local_node: NetworkNode, allocator: std.mem.Allocator) P2PNetwork {
        return P2PNetwork{
            .local_node = local_node,
            .connected_nodes = array_list.Managed(NetworkNode).init(allocator),
            .seed_nodes = array_list.Managed(NetworkNode).init(allocator),
            .allocator = allocator,
            .p2p_node_ptr = null,
            .broadcast_fn = null,
        };
    }

    pub fn deinit(self: *P2PNetwork) void {
        self.connected_nodes.deinit();
        self.seed_nodes.deinit();
    }

    /// Add seed node
    pub fn addSeedNode(self: *P2PNetwork, node: NetworkNode) !void {
        try self.seed_nodes.append(node);
        std.debug.print("[NETWORK] Added seed node: {s}:{d}\n", .{ node.host, node.port });
    }

    /// Connect to a node
    pub fn connectToNode(self: *P2PNetwork, node: NetworkNode) !void {
        // Check if already connected
        for (self.connected_nodes.items) |existing| {
            if (std.mem.eql(u8, existing.node_id, node.node_id)) {
                return error.AlreadyConnected;
            }
        }

        try self.connected_nodes.append(node);
        std.debug.print("[NETWORK] Connected to {s} at {s}:{d}\n", .{ node.node_id, node.host, node.port });
    }

    /// Disconnect from a node
    pub fn disconnectFromNode(self: *P2PNetwork, node_id: []const u8) !void {
        for (self.connected_nodes.items, 0..) |node, idx| {
            if (std.mem.eql(u8, node.node_id, node_id)) {
                _ = self.connected_nodes.swapRemove(idx);
                std.debug.print("[NETWORK] Disconnected from {s}\n", .{node_id});
                return;
            }
        }
        return error.NodeNotFound;
    }

    /// Attach a P2PNode so broadcast() delegates to real TCP transport.
    /// Called from p2p.zig after P2PNode is initialized.
    pub fn attachP2PNode(
        self: *P2PNetwork,
        node_ptr: *anyopaque,
        fn_ptr: *const fn (node_ptr: *anyopaque, height: u64, message: []const u8, reward: u64) void,
    ) void {
        self.p2p_node_ptr = node_ptr;
        self.broadcast_fn = fn_ptr;
    }

    /// Broadcast message to all peers — delegates to P2PNode.broadcastBlock if attached
    pub fn broadcast(self: *const P2PNetwork, message: []const u8) !void {
        if (self.broadcast_fn) |bfn| {
            bfn(self.p2p_node_ptr.?, 0, message, 0);
        } else {
            std.debug.print("[NETWORK] Broadcasting: {s} to {d} peers\n", .{ message, self.connected_nodes.items.len });
            for (self.connected_nodes.items) |node| {
                std.debug.print("  → {s} ({s}:{d})\n", .{ node.node_id, node.host, node.port });
            }
        }
    }

    /// Get connected node count
    pub fn getPeerCount(self: *const P2PNetwork) usize {
        return self.connected_nodes.items.len;
    }

    /// Get miner count
    pub fn getMinerCount(self: *const P2PNetwork) usize {
        var count: usize = 0;
        for (self.connected_nodes.items) |node| {
            if (node.is_miner) {
                count += 1;
            }
        }
        return count;
    }

    /// Check if node is miner
    pub fn isMiner(self: *const P2PNetwork, node_id: []const u8) bool {
        for (self.connected_nodes.items) |node| {
            if (std.mem.eql(u8, node.node_id, node_id) and node.is_miner) {
                return true;
            }
        }
        return false;
    }

    /// Get all miners
    pub fn getMiners(self: *const P2PNetwork, allocator: std.mem.Allocator) ![]NetworkNode {
        var miners = array_list.Managed(NetworkNode).init(allocator);

        for (self.connected_nodes.items) |node| {
            if (node.is_miner) {
                try miners.append(node);
            }
        }

        return miners.items;
    }

    /// Get network status
    pub fn getStatus(self: *const P2PNetwork) NetworkStatus {
        return NetworkStatus{
            .total_peers = self.getPeerCount(),
            .total_miners = self.getMinerCount(),
            .seed_nodes = self.seed_nodes.items.len,
            .is_synced = self.getPeerCount() > 0,
        };
    }
};

pub const NetworkStatus = struct {
    total_peers: usize,
    total_miners: usize,
    seed_nodes: usize,
    is_synced: bool,
};

/// Network Message Types
pub const MessageType = enum {
    ping,
    pong,
    block,
    transaction,
    sync_request,
    sync_response,
    peer_list,
    mining_start,
    mining_stop,
    // ── Gossip protocol (B6) ──────────────────────────────────────
    inv,            // "I have these items" (hashes)
    getdata,        // "Send me these items"
    tx_gossip,      // Full TX payload (gossip relay)
    block_gossip,   // Full block payload (gossip relay)
    getblocks,      // "What blocks do you have after hash X?"
    // ── Peer Exchange protocol (B12) ────────────────────────────────
    get_peers,      // Request peer list from connected node
    // ── SPV Light Client protocol ────────────────────────────────────
    getheaders_p2p,      // Light client requests headers from start_height
    headers_p2p,         // Full node responds with serialized headers
    getmerkleproof_p2p,  // Light client requests Merkle proof for a TX hash
    merkleproof_p2p,     // Full node responds with Merkle inclusion proof
    filterload,          // Light client sends Bloom filter to full node
};

/// P2P Message
pub const Message = struct {
    message_type: MessageType,
    sender_id: []const u8,
    payload: []const u8,
    timestamp: i64,
};

// Tests
const testing = std.testing;

test "network node initialization" {
    const node = NetworkNode.init(
        "miner-1",
        "192.168.1.100",
        9001,
        "1.0.0",
        true,
        testing.allocator,
    );

    try testing.expectEqualStrings(node.node_id, "miner-1");
    try testing.expect(node.is_miner);
}

test "p2p network basics" {
    const local_node = NetworkNode.init(
        "seed-1",
        "10.0.0.1",
        9000,
        "1.0.0",
        false,
        testing.allocator,
    );

    var network = P2PNetwork.init(local_node, testing.allocator);
    defer network.deinit();

    const miner_node = NetworkNode.init(
        "miner-1",
        "192.168.1.100",
        9001,
        "1.0.0",
        true,
        testing.allocator,
    );

    try network.connectToNode(miner_node);
    try testing.expectEqual(network.getPeerCount(), 1);
    try testing.expectEqual(network.getMinerCount(), 1);
}

test "network broadcast" {
    const local_node = NetworkNode.init(
        "seed-1",
        "10.0.0.1",
        9000,
        "1.0.0",
        false,
        testing.allocator,
    );

    var network = P2PNetwork.init(local_node, testing.allocator);
    defer network.deinit();

    const miner = NetworkNode.init(
        "miner-1",
        "192.168.1.100",
        9001,
        "1.0.0",
        true,
        testing.allocator,
    );

    try network.connectToNode(miner);
    try network.broadcast("Mining started!");
}

test "network status" {
    const local_node = NetworkNode.init(
        "seed-1",
        "10.0.0.1",
        9000,
        "1.0.0",
        false,
        testing.allocator,
    );

    var network = P2PNetwork.init(local_node, testing.allocator);
    defer network.deinit();

    const ids = [_][]const u8{ "miner-0", "miner-1", "miner-2", "miner-3", "miner-4" };
    for (ids) |id| {
        const miner = NetworkNode.init(
            id,
            "192.168.1.100",
            9001,
            "1.0.0",
            true,
            testing.allocator,
        );
        try network.connectToNode(miner);
    }

    const status = network.getStatus();
    try testing.expectEqual(status.total_peers, 5);
    try testing.expectEqual(status.total_miners, 5);
}
