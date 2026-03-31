const std = @import("std");
const bootstrap = @import("bootstrap.zig");
const network = @import("network.zig");
const mining_pool = @import("mining_pool.zig");
const p2p_mod = @import("p2p.zig");

/// Node operation modes
pub const NodeMode = enum {
    seed,  // Bootstrap/seed node
    miner, // Mining participant
    light, // SPV light client — headers only, no full blocks
};

/// Node launcher configuration
pub const NodeConfig = struct {
    mode: NodeMode,
    node_id: []const u8,
    host: []const u8,
    port: u16,
    is_primary: bool = false,
    max_peers: u32 = 100,
    // For miners:
    seed_host: ?[]const u8 = null,
    seed_port: ?u16 = null,
    hashrate: ?u64 = null,
    allocator: std.mem.Allocator,
};

/// Main node launcher
pub const NodeLauncher = struct {
    config: NodeConfig,
    bootstrap_node: ?bootstrap.BootstrapNode = null,
    p2p_network: ?network.P2PNetwork = null,
    mining_pool: ?mining_pool.MiningPool = null,
    p2p_node: ?*p2p_mod.P2PNode = null,  // pointer la P2PNode real (TCP)
    is_running: bool = false,

    pub fn init(config: NodeConfig) NodeLauncher {
        return NodeLauncher{
            .config = config,
        };
    }

    /// Ataseaza P2PNode real (TCP) — apelat din main.zig dupa init p2p
    /// Permite broadcast() sa trimita mesaje TCP reale in loc de print-only
    pub fn attachP2PNode(self: *NodeLauncher, node: *p2p_mod.P2PNode) void {
        self.p2p_node = node;
    }

    /// Start seed node
    pub fn startSeedNode(self: *NodeLauncher) !void {
        std.debug.print("[LAUNCHER] Starting seed node '{s}' on {s}:{d}\n", .{ self.config.node_id, self.config.host, self.config.port });

        const seed_config = bootstrap.SeedNodeConfig{
            .node_id = self.config.node_id,
            .host = self.config.host,
            .port = self.config.port,
            .is_primary = self.config.is_primary,
            .max_peers = self.config.max_peers,
            .allocator = self.config.allocator,
        };

        var node = bootstrap.BootstrapNode.init(seed_config);
        node.setStatus(bootstrap.BootstrapNode.NodeStatus.waiting_for_peers);

        self.bootstrap_node = node;
        self.is_running = true;

        std.debug.print("[LAUNCHER] Seed node ready. Waiting for peers...\n", .{});
    }

    /// Start miner node
    pub fn startMinerNode(self: *NodeLauncher) !void {
        if (self.config.seed_host == null or self.config.seed_port == null) {
            return error.SeedNodeAddressRequired;
        }

        std.debug.print("[LAUNCHER] Starting miner node '{s}'\n", .{self.config.node_id});
        std.debug.print("[LAUNCHER] Connecting to seed {s}:{d}\n", .{ self.config.seed_host.?, self.config.seed_port.? });

        // Create local network node
        const local_node = network.NetworkNode.init(
            self.config.node_id,
            self.config.host,
            self.config.port,
            "1.0.0",
            true, // is_miner
            self.config.allocator,
        );

        // Initialize P2P network
        var p2p = network.P2PNetwork.init(local_node, self.config.allocator);

        // Create seed node reference
        const seed_node = network.NetworkNode.init(
            "seed-primary",
            self.config.seed_host.?,
            self.config.seed_port.?,
            "1.0.0",
            false,
            self.config.allocator,
        );

        try p2p.addSeedNode(seed_node);
        try p2p.connectToNode(seed_node);

        self.p2p_network = p2p;
        self.is_running = true;

        std.debug.print("[LAUNCHER] Miner connected to network\n", .{});
    }

    /// Register miner with pool (for seed node)
    pub fn registerMinerWithPool(self: *NodeLauncher, miner_id: []const u8, address: []const u8, hashrate: u64) !void {
        if (self.mining_pool == null) {
            const pool = mining_pool.MiningPool.init(self.config.node_id, address, self.config.allocator);
            self.mining_pool = pool;
        }

        try self.mining_pool.?.addMiner(miner_id, address, hashrate);
        std.debug.print("[LAUNCHER] Registered miner '{s}' with {d} H/s\n", .{ miner_id, hashrate });
    }

    /// Update bootstrap node status when peer joins
    pub fn onPeerConnected(self: *NodeLauncher, peer: bootstrap.BootstrapNode.Peer) !void {
        if (self.bootstrap_node == null) return;

        try self.bootstrap_node.?.registerPeer(peer);

        // Check if network is ready for mining
        if (self.bootstrap_node.?.peers.items.len >= 2 and
            self.bootstrap_node.?.status == bootstrap.BootstrapNode.NodeStatus.waiting_for_peers)
        {
            self.bootstrap_node.?.setStatus(bootstrap.BootstrapNode.NodeStatus.syncing);
        }
    }

    /// Minimum peers/miners required before mining can start
    /// Blockchain-ul nu porneste mining fara o retea reala
    pub const MIN_PEERS_FOR_MINING: usize = 10;

    /// Transition to mining when ready (requires MIN_PEERS_FOR_MINING connected)
    pub fn readyForMining(self: *NodeLauncher) bool {
        if (self.bootstrap_node) |node| {
            return node.readyForMining();
        }

        if (self.p2p_network) |network_| {
            // +1 = self (this node counts as 1)
            return (network_.getPeerCount() + 1) >= MIN_PEERS_FOR_MINING;
        }

        return false;
    }

    /// Start mining on this node
    pub fn startMining(self: *NodeLauncher) !void {
        if (self.bootstrap_node) |*node| {
            node.setStatus(bootstrap.BootstrapNode.NodeStatus.mining);
            std.debug.print("[LAUNCHER] Seed node starting mining\n", .{});
        }

        if (self.p2p_node) |p2p| {
            // Broadcast real via TCP — anunta toti peerii ca minarea a inceput
            const height = p2p.chain_height;
            p2p.broadcastBlock(height, "mining_start", 0);
            std.debug.print("[LAUNCHER] Miner starting mining — broadcast TCP la {d} peeri\n",
                .{p2p.peers.items.len});
        } else if (self.p2p_network) |*net| {
            // Fallback: print-only (p2p_node neatasat)
            try net.broadcast("mining_start");
            std.debug.print("[LAUNCHER] Miner starting mining (no TCP node attached)\n", .{});
        }
    }

    /// Stop mining
    pub fn stopMining(self: *NodeLauncher) !void {
        if (self.bootstrap_node) |*node| {
            node.setStatus(bootstrap.BootstrapNode.NodeStatus.synchronized);
            std.debug.print("[LAUNCHER] Seed node stopped mining\n", .{});
        }

        if (self.p2p_node) |p2p| {
            // Broadcast real via TCP
            p2p.broadcastBlock(p2p.chain_height, "mining_stop", 0);
            std.debug.print("[LAUNCHER] Miner stopped mining — broadcast TCP\n", .{});
        } else if (self.p2p_network) |*net| {
            try net.broadcast("mining_stop");
            std.debug.print("[LAUNCHER] Miner stopped mining (no TCP node attached)\n", .{});
        }
    }

    /// Get network status
    pub fn getNetworkStatus(self: *const NodeLauncher) ?network.NetworkStatus {
        if (self.p2p_network) |net| {
            return net.getStatus();
        }
        return null;
    }

    /// Get bootstrap status
    pub fn getBootstrapStatus(self: *const NodeLauncher) ?bootstrap.BootstrapStats {
        if (self.bootstrap_node) |node| {
            return node.getStats();
        }
        return null;
    }

    /// Periodic maintenance (remove stale peers, etc.)
    pub fn maintenance(self: *NodeLauncher) void {
        if (self.bootstrap_node) |*node| {
            node.removeStalePeers();
        }
    }

    pub fn deinit(self: *NodeLauncher) void {
        if (self.bootstrap_node) |*node| {
            node.deinit();
        }

        if (self.p2p_network) |*net| {
            net.deinit();
        }

        if (self.mining_pool) |*pool| {
            pool.deinit();
        }
    }
};

// Tests
const testing = std.testing;

test "seed node launcher" {
    var launcher = NodeLauncher.init(NodeConfig{
        .mode = NodeMode.seed,
        .node_id = "seed-1",
        .host = "127.0.0.1",
        .port = 9000,
        .is_primary = true,
        .allocator = testing.allocator,
    });
    defer launcher.deinit();

    try launcher.startSeedNode();
    try testing.expect(launcher.is_running);
}

test "miner node launcher" {
    var launcher = NodeLauncher.init(NodeConfig{
        .mode = NodeMode.miner,
        .node_id = "miner-1",
        .host = "192.168.1.100",
        .port = 9001,
        .seed_host = "127.0.0.1",
        .seed_port = 9000,
        .hashrate = 1000,
        .allocator = testing.allocator,
    });
    defer launcher.deinit();

    try launcher.startMinerNode();
    try testing.expect(launcher.is_running);
}

test "network readiness check" {
    var launcher = NodeLauncher.init(NodeConfig{
        .mode = NodeMode.seed,
        .node_id = "seed-1",
        .host = "127.0.0.1",
        .port = 9000,
        .is_primary = true,
        .allocator = testing.allocator,
    });
    defer launcher.deinit();

    try launcher.startSeedNode();

    // Register a peer
    const peer = bootstrap.BootstrapNode.Peer{
        .node_id = "miner-1",
        .host = "192.168.1.100",
        .port = 9001,
        .version = "1.0.0",
        .last_seen = std.time.timestamp(),
        .latency_ms = 25,
    };

    try launcher.onPeerConnected(peer);

    // Transition to synchronized
    if (launcher.bootstrap_node) |*node| {
        node.setStatus(bootstrap.BootstrapNode.NodeStatus.synchronized);
    }

    // Not ready yet — need MIN_MINERS_FOR_MINING (10) registered miners
    try testing.expect(!launcher.readyForMining());

    // Simulate 10 miners registered via RPC (as happens in production)
    bootstrap.BootstrapNode.registered_miner_count = 10;
    defer {
        bootstrap.BootstrapNode.registered_miner_count = 0;
    }

    try testing.expect(launcher.readyForMining());
}

test "NodeLauncher — seed fara bootstrap_node: readyForMining=false" {
    var launcher = NodeLauncher.init(NodeConfig{
        .mode = NodeMode.seed,
        .node_id = "seed-x",
        .host = "127.0.0.1",
        .port = 9000,
        .allocator = testing.allocator,
    });
    defer launcher.deinit();
    // Nu am pornit nodul — readyForMining trebuie false
    try testing.expect(!launcher.readyForMining());
}

test "NodeLauncher — miner fara seed_host returneaza SeedNodeAddressRequired" {
    var launcher = NodeLauncher.init(NodeConfig{
        .mode = NodeMode.miner,
        .node_id = "miner-x",
        .host = "127.0.0.1",
        .port = 9001,
        .allocator = testing.allocator,
    });
    defer launcher.deinit();
    try testing.expectError(error.SeedNodeAddressRequired, launcher.startMinerNode());
}

test "NodeLauncher — getBootstrapStatus null inainte de startSeedNode" {
    var launcher = NodeLauncher.init(NodeConfig{
        .mode = NodeMode.seed,
        .node_id = "seed-x",
        .host = "127.0.0.1",
        .port = 9000,
        .allocator = testing.allocator,
    });
    defer launcher.deinit();
    try testing.expect(launcher.getBootstrapStatus() == null);
}

test "NodeLauncher — getNetworkStatus null inainte de startMinerNode" {
    var launcher = NodeLauncher.init(NodeConfig{
        .mode = NodeMode.seed,
        .node_id = "seed-x",
        .host = "127.0.0.1",
        .port = 9000,
        .allocator = testing.allocator,
    });
    defer launcher.deinit();
    try testing.expect(launcher.getNetworkStatus() == null);
}

test "NodeLauncher — is_running false inainte de start" {
    var launcher = NodeLauncher.init(NodeConfig{
        .mode = NodeMode.seed,
        .node_id = "seed-x",
        .host = "127.0.0.1",
        .port = 9000,
        .allocator = testing.allocator,
    });
    defer launcher.deinit();
    try testing.expect(!launcher.is_running);
}

test "NodeLauncher — is_running true dupa startSeedNode" {
    var launcher = NodeLauncher.init(NodeConfig{
        .mode = NodeMode.seed,
        .node_id = "seed-x",
        .host = "127.0.0.1",
        .port = 9000,
        .allocator = testing.allocator,
    });
    defer launcher.deinit();
    try launcher.startSeedNode();
    try testing.expect(launcher.is_running);
}

test "NodeLauncher — registerMinerWithPool creeaza pool" {
    var launcher = NodeLauncher.init(NodeConfig{
        .mode = NodeMode.seed,
        .node_id = "seed-pool",
        .host = "127.0.0.1",
        .port = 9000,
        .allocator = testing.allocator,
    });
    defer launcher.deinit();
    try launcher.startSeedNode();
    try launcher.registerMinerWithPool("miner-1", "ob_omni_miner1", 1000);
    try testing.expect(launcher.mining_pool != null);
}
