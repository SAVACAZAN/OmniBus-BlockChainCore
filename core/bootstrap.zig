const std = @import("std");
const array_list = std.array_list;
const p2p_mod = @import("p2p.zig");

pub const PeerAddr = struct {
    ip:   [4]u8,
    port: u16,
};

/// Mesaj PEX: cerere lista de peeri
pub const MSG_GET_PEERS: u8 = 0x10;
/// Mesaj PEX: raspuns cu lista de peeri
pub const MSG_PEER_LIST: u8 = 0x11;

/// Trimite MSG_GET_PEERS la un peer conectat
pub fn pexRequest(conn: *p2p_mod.PeerConnection, allocator: std.mem.Allocator) void {
    _ = allocator;
    // Payload gol — doar cerem lista
    conn.send(MSG_GET_PEERS, &.{}) catch |err| {
        std.debug.print("[PEX] pexRequest send failed: {}\n", .{err});
    };
    std.debug.print("[PEX] GET_PEERS trimis la {s}\n", .{conn.node_id[0..@min(conn.node_id.len, 16)]});
}

/// Proceseaza o lista de peeri primita prin PEX si o adauga in manager
/// peer_list: slice de PeerAddr primite de la peer
pub fn pexHandle(
    manager:   *PeerManager,
    peer_list: []const PeerAddr,
    allocator: std.mem.Allocator,
) void {
    for (peer_list) |pa| {
        manager.addPeer(pa, allocator) catch |err| {
            std.debug.print("[PEX] addPeer failed: {}\n", .{err});
        };
    }
    std.debug.print("[PEX] PEX: adaugate {} peeri noi (total known: {})\n",
        .{ peer_list.len, manager.known.items.len });
}

/// Lista de seed nodes pentru bootstrap initial (DNS seeds ca Bitcoin)
/// Multiple seed-uri din diferite locatii geografice pentru diversitate
/// si rezistenta la eclipse attacks (Bitcoin are ~10 DNS seeds)
pub const SEED_PEERS = [_]PeerAddr{
    .{ .ip = .{ 127, 0, 0, 1 }, .port = 8333 },   // local test
    .{ .ip = .{ 127, 0, 0, 1 }, .port = 9000 },   // local seed 2
    .{ .ip = .{ 127, 0, 0, 1 }, .port = 9001 },   // local seed 3
    .{ .ip = .{ 10, 0, 0, 1 },  .port = 8333 },   // LAN seed 1
    .{ .ip = .{ 10, 0, 0, 2 },  .port = 8333 },   // LAN seed 2
    .{ .ip = .{ 192, 168, 1, 100 }, .port = 8333 },// LAN seed 3
};

/// Minimum diverse peers for eclipse attack resistance
/// Node should connect to peers from at least MIN_DIVERSE_PEERS different /16 subnets
pub const MIN_DIVERSE_PEERS: usize = 4;

/// Maximum peers from same /16 subnet (anti-eclipse)
pub const MAX_PEERS_PER_SUBNET: usize = 2;

/// Check if peer is from a diverse subnet (anti-eclipse attack protection)
pub fn isDiversePeer(new_peer: PeerAddr, existing_peers: []const PeerAddr) bool {
    var same_subnet_count: usize = 0;
    for (existing_peers) |peer| {
        // /16 subnet = first 2 octets match
        if (peer.ip[0] == new_peer.ip[0] and peer.ip[1] == new_peer.ip[1]) {
            same_subnet_count += 1;
        }
    }
    return same_subnet_count < MAX_PEERS_PER_SUBNET;
}

/// Conecteaza la seed peers hardcodati si salveaza peerii descoperiti in manager.
/// Best-effort: esecurile de conectare sunt loggate dar ignorate.
pub fn connectToSeedPeers(manager: *PeerManager, allocator: std.mem.Allocator) void {
    for (SEED_PEERS) |seed| {
        const host = std.fmt.allocPrint(
            allocator,
            "{d}.{d}.{d}.{d}",
            .{ seed.ip[0], seed.ip[1], seed.ip[2], seed.ip[3] },
        ) catch continue;
        defer allocator.free(host);

        std.debug.print("[BOOTSTRAP] Trying seed {s}:{d}...\n", .{ host, seed.port });

        var node = p2p_mod.P2PNode.init("bootstrap-self", host, seed.port, allocator);
        defer node.deinit();

        node.connectToPeer(host, seed.port, "seed-node") catch |err| {
            std.debug.print("[BOOTSTRAP] Seed {s}:{d} unreachable: {}\n",
                .{ host, seed.port, err });
            continue;
        };

        // Peer conectat — trimite PEX request
        if (node.peers.items.len > 0) {
            pexRequest(&node.peers.items[0], allocator);
            // Inregistreaza seed-ul in manager
            manager.addPeer(seed, allocator) catch {};
            std.debug.print("[BOOTSTRAP] Seed {s}:{d} adaugat\n", .{ host, seed.port });
        }
    }
}

// ─── PeerManager — gestioneaza lista de peeri cunoscuti ──────────────────────

pub const PeerInfo = struct {
    addr:         PeerAddr,
    chain_height: u64,
    connected:    bool,
    last_seen:    i64,
};

pub const PeerManager = struct {
    known:     array_list.Managed(PeerInfo),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) PeerManager {
        return .{
            .known     = array_list.Managed(PeerInfo).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *PeerManager) void {
        self.known.deinit();
    }

    /// Adauga un peer nou daca nu exista deja (deduplicare dupa IP:port)
    pub fn addPeer(self: *PeerManager, addr: PeerAddr, allocator: std.mem.Allocator) !void {
        _ = allocator;
        for (self.known.items) |existing| {
            if (std.mem.eql(u8, &existing.addr.ip, &addr.ip) and
                existing.addr.port == addr.port)
            {
                return; // deja cunoscut
            }
        }
        try self.known.append(.{
            .addr         = addr,
            .chain_height = 0,
            .connected    = false,
            .last_seen    = std.time.timestamp(),
        });
        std.debug.print("[PEER_MGR] Peer adaugat {d}.{d}.{d}.{d}:{d}\n", .{
            addr.ip[0], addr.ip[1], addr.ip[2], addr.ip[3], addr.port,
        });
    }

    /// Elimina un peer dupa IP:port
    pub fn removePeer(self: *PeerManager, addr: PeerAddr) void {
        var i: usize = 0;
        while (i < self.known.items.len) {
            const p = self.known.items[i];
            if (std.mem.eql(u8, &p.addr.ip, &addr.ip) and p.addr.port == addr.port) {
                _ = self.known.swapRemove(i);
                return;
            }
            i += 1;
        }
    }

    /// Numarul de peeri conectati
    pub fn getConnectedCount(self: *const PeerManager) usize {
        var count: usize = 0;
        for (self.known.items) |p| {
            if (p.connected) count += 1;
        }
        return count;
    }

    /// Returneaza peer-ul cu cea mai mare inaltime a lantului (best peer)
    /// Returneaza null daca nu exista peeri conectati
    pub fn getBestPeer(self: *const PeerManager) ?PeerInfo {
        var best: ?PeerInfo = null;
        for (self.known.items) |p| {
            if (!p.connected) continue;
            if (best == null or p.chain_height > best.?.chain_height) {
                best = p;
            }
        }
        return best;
    }

    /// Actualizeaza inaltimea lantului pentru un peer
    pub fn updateHeight(self: *PeerManager, addr: PeerAddr, height: u64) void {
        for (self.known.items) |*p| {
            if (std.mem.eql(u8, &p.addr.ip, &addr.ip) and p.addr.port == addr.port) {
                p.chain_height = height;
                p.last_seen    = std.time.timestamp();
                return;
            }
        }
    }

    /// Marcheaza peer ca connected/disconnected
    pub fn setConnected(self: *PeerManager, addr: PeerAddr, connected: bool) void {
        for (self.known.items) |*p| {
            if (std.mem.eql(u8, &p.addr.ip, &addr.ip) and p.addr.port == addr.port) {
                p.connected = connected;
                p.last_seen = std.time.timestamp();
                return;
            }
        }
    }
};

// ─── B12: Peer Persistence — save/load peers from data/peers.dat ────────────

/// Default path for persisted peers file
pub const PEERS_DAT_PATH = "data/peers.dat";

/// Maximum peers to keep in the known list
pub const MAX_PEERS: usize = 32;

/// Periodic discovery interval in seconds (5 minutes)
pub const DISCOVERY_INTERVAL_S: i64 = 300;

/// Unresponsive peer timeout in seconds (30 minutes)
pub const PEER_TIMEOUT_S: i64 = 1800;

/// Save known peers to disk as "host:port\n" lines.
/// Best-effort: errors are logged but not propagated.
pub fn savePeersToDisk(manager: *const PeerManager, path: []const u8) void {
    // Ensure parent directory exists
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |sep| {
        std.fs.cwd().makePath(path[0..sep]) catch {};
    }
    const file = std.fs.cwd().createFile(path, .{}) catch |err| {
        std.debug.print("[PEERS] savePeersToDisk open error: {}\n", .{err});
        return;
    };
    defer file.close();

    for (manager.known.items) |p| {
        var line_buf: [64]u8 = undefined;
        const line = std.fmt.bufPrint(&line_buf, "{d}.{d}.{d}.{d}:{d}\n", .{
            p.addr.ip[0], p.addr.ip[1], p.addr.ip[2], p.addr.ip[3], p.addr.port,
        }) catch continue;
        file.writeAll(line) catch continue;
    }
    std.debug.print("[PEERS] Saved {d} peers to {s}\n", .{ manager.known.items.len, path });
}

/// Load peers from disk file. One peer per line "host:port".
/// Best-effort: invalid lines are skipped silently.
pub fn loadPeersFromDisk(manager: *PeerManager, path: []const u8, allocator: std.mem.Allocator) void {
    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        std.debug.print("[PEERS] loadPeersFromDisk open: {} (normal on first run)\n", .{err});
        return;
    };
    defer file.close();

    // Read entire file (peers.dat is small — well under 64KB)
    var file_buf: [65536]u8 = undefined;
    const bytes_read = file.readAll(&file_buf) catch |err| {
        std.debug.print("[PEERS] loadPeersFromDisk read error: {}\n", .{err});
        return;
    };
    const content = file_buf[0..bytes_read];
    var loaded: usize = 0;

    // Split by newlines and parse each line
    var rest: []const u8 = content;
    while (rest.len > 0) {
        const nl_pos = std.mem.indexOfScalar(u8, rest, '\n');
        const line_raw = if (nl_pos) |pos| rest[0..pos] else rest;
        rest = if (nl_pos) |pos| rest[pos + 1 ..] else &[_]u8{};

        // Trim trailing \r (Windows line endings)
        const line = std.mem.trimRight(u8, line_raw, "\r");
        if (line.len < 3) continue; // minimum "x:y"

        // Find the last ':' to separate host from port
        const colon_pos = std.mem.lastIndexOfScalar(u8, line, ':') orelse continue;
        if (colon_pos == 0 or colon_pos >= line.len - 1) continue;

        const host_part = line[0..colon_pos];
        const port_str = line[colon_pos + 1 ..];
        const port = std.fmt.parseInt(u16, port_str, 10) catch continue;

        // Parse IPv4 octets
        const addr = parseIpv4(host_part) orelse continue;
        manager.addPeer(.{ .ip = addr, .port = port }, allocator) catch continue;
        loaded += 1;
    }
    std.debug.print("[PEERS] Loaded {d} peers from {s}\n", .{ loaded, path });
}

/// Parse "A.B.C.D" into [4]u8, returns null on failure
fn parseIpv4(s: []const u8) ?[4]u8 {
    var ip: [4]u8 = undefined;
    var octet_idx: usize = 0;
    var start: usize = 0;

    for (s, 0..) |c, i| {
        if (c == '.') {
            if (octet_idx >= 3) return null;
            ip[octet_idx] = std.fmt.parseInt(u8, s[start..i], 10) catch return null;
            octet_idx += 1;
            start = i + 1;
        }
    }
    if (octet_idx != 3) return null;
    ip[3] = std.fmt.parseInt(u8, s[start..], 10) catch return null;
    return ip;
}

/// Auto-discovery on startup: load saved peers → try seeds → PEX from connected.
/// Called once from main.zig after P2P node is initialized.
pub fn autoDiscover(
    manager:  *PeerManager,
    p2p_node: *p2p_mod.P2PNode,
    allocator: std.mem.Allocator,
) void {
    // Step 1: Load persisted peers
    loadPeersFromDisk(manager, PEERS_DAT_PATH, allocator);

    // Step 2: Add seed nodes to manager (dedup handles overlap with loaded peers)
    for (SEED_PEERS) |seed| {
        manager.addPeer(seed, allocator) catch {};
    }

    // Step 3: Try connecting to known peers up to MAX_PEERS
    var connected: usize = p2p_node.peerCount();
    for (manager.known.items) |*peer_info| {
        if (connected >= MAX_PEERS) break;
        if (peer_info.connected) continue;

        const host = std.fmt.allocPrint(
            allocator,
            "{d}.{d}.{d}.{d}",
            .{ peer_info.addr.ip[0], peer_info.addr.ip[1],
               peer_info.addr.ip[2], peer_info.addr.ip[3] },
        ) catch continue;
        defer allocator.free(host);

        p2p_node.connectToPeer(host, peer_info.addr.port, "discovered") catch {
            continue;
        };
        peer_info.connected = true;
        peer_info.last_seen = std.time.timestamp();
        connected += 1;
    }

    // Step 4: Request peer lists via PEX from connected peers
    p2p_node.requestPeersFromAll();

    std.debug.print("[DISCOVERY] Auto-discover done: {d} known, {d} connected\n",
        .{ manager.known.items.len, connected });
}

/// Periodic discovery: request PEX, drop unresponsive peers, save to disk.
/// Called every DISCOVERY_INTERVAL_S (5 min) from the main loop.
pub fn periodicDiscovery(
    manager:  *PeerManager,
    p2p_node: *p2p_mod.P2PNode,
    allocator: std.mem.Allocator,
) void {
    const now = std.time.timestamp();

    // 1. Drop unresponsive peers (no activity for 30 min)
    var i: usize = 0;
    while (i < manager.known.items.len) {
        const p = manager.known.items[i];
        if (now - p.last_seen > PEER_TIMEOUT_S) {
            std.debug.print("[DISCOVERY] Dropping unresponsive peer {d}.{d}.{d}.{d}:{d}\n", .{
                p.addr.ip[0], p.addr.ip[1], p.addr.ip[2], p.addr.ip[3], p.addr.port,
            });
            _ = manager.known.swapRemove(i);
        } else {
            i += 1;
        }
    }

    // 2. Request peer lists from connected peers
    p2p_node.requestPeersFromAll();

    // 3. Try connecting to new peers if below MAX_PEERS
    var connected = p2p_node.peerCount();
    for (manager.known.items) |*peer_info| {
        if (connected >= MAX_PEERS) break;
        if (peer_info.connected) continue;

        const host = std.fmt.allocPrint(
            allocator,
            "{d}.{d}.{d}.{d}",
            .{ peer_info.addr.ip[0], peer_info.addr.ip[1],
               peer_info.addr.ip[2], peer_info.addr.ip[3] },
        ) catch continue;
        defer allocator.free(host);

        p2p_node.connectToPeer(host, peer_info.addr.port, "periodic") catch {
            continue;
        };
        peer_info.connected = true;
        peer_info.last_seen = now;
        connected += 1;
    }

    // 4. Clean dead P2P connections
    p2p_node.cleanDeadPeers();

    // 5. Save updated peer list to disk
    savePeersToDisk(manager, PEERS_DAT_PATH);

    std.debug.print("[DISCOVERY] Periodic: {d} known, {d} connected\n",
        .{ manager.known.items.len, connected });
}

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
    peers: array_list.Managed(Peer),
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
            .peers = array_list.Managed(Peer).init(config.allocator),
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
    pub fn removeStalePeers(self: *BootstrapNode) void {
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
    /// Minimum miners required before mining starts (need real network)
    pub const MIN_MINERS_FOR_MINING: usize = 10;

    /// Extern: set by RPC server when miners register
    pub var registered_miner_count: u16 = 0;

    pub fn readyForMining(self: *const BootstrapNode) bool {
        _ = self;
        // Use registered miner count (from RPC registerminer) instead of P2P peers
        // P2P inbound recv is broken on Windows — miners register via RPC instead
        return (registered_miner_count + 1) >= MIN_MINERS_FOR_MINING;
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
    secondary: array_list.Managed(BootstrapNode),
    allocator: std.mem.Allocator,

    pub fn init(primary_config: SeedNodeConfig, allocator: std.mem.Allocator) SeedNodePool {
        const primary = BootstrapNode.init(primary_config);

        return SeedNodePool{
            .primary = primary,
            .secondary = array_list.Managed(BootstrapNode).init(allocator),
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

// ─── B12: Network Discovery Tests ──────────────────────────────────────────

test "B12: SEED_PEERS list is non-empty" {
    try testing.expect(SEED_PEERS.len > 0);
    // Should include at least one localhost seed for testnet
    var has_localhost = false;
    for (SEED_PEERS) |seed| {
        if (seed.ip[0] == 127 and seed.ip[1] == 0 and seed.ip[2] == 0 and seed.ip[3] == 1) {
            has_localhost = true;
            break;
        }
    }
    try testing.expect(has_localhost);
}

test "B12: PeerManager deduplication" {
    var mgr = PeerManager.init(testing.allocator);
    defer mgr.deinit();

    const addr1 = PeerAddr{ .ip = .{ 10, 0, 0, 1 }, .port = 9000 };
    const addr2 = PeerAddr{ .ip = .{ 10, 0, 0, 2 }, .port = 9000 };

    // Add first peer
    try mgr.addPeer(addr1, testing.allocator);
    try testing.expectEqual(@as(usize, 1), mgr.known.items.len);

    // Add duplicate — should not increase count
    try mgr.addPeer(addr1, testing.allocator);
    try testing.expectEqual(@as(usize, 1), mgr.known.items.len);

    // Add different peer — should increase count
    try mgr.addPeer(addr2, testing.allocator);
    try testing.expectEqual(@as(usize, 2), mgr.known.items.len);
}

test "B12: parseIpv4 valid" {
    const ip = parseIpv4("192.168.1.100").?;
    try testing.expectEqual(@as(u8, 192), ip[0]);
    try testing.expectEqual(@as(u8, 168), ip[1]);
    try testing.expectEqual(@as(u8, 1), ip[2]);
    try testing.expectEqual(@as(u8, 100), ip[3]);
}

test "B12: parseIpv4 invalid" {
    try testing.expect(parseIpv4("not.an.ip") == null);
    try testing.expect(parseIpv4("256.0.0.1") == null);
    try testing.expect(parseIpv4("1.2.3") == null);
    try testing.expect(parseIpv4("") == null);
}

test "B12: isDiversePeer — anti-eclipse" {
    const existing = [_]PeerAddr{
        .{ .ip = .{ 10, 0, 1, 1 }, .port = 9000 },
        .{ .ip = .{ 10, 0, 1, 2 }, .port = 9001 },
    };
    // Same /16 subnet (10.0.x.x) — should be rejected (already 2 from same subnet)
    const same_subnet = PeerAddr{ .ip = .{ 10, 0, 2, 1 }, .port = 9002 };
    try testing.expect(!isDiversePeer(same_subnet, &existing));

    // Different /16 subnet — should be accepted
    const diff_subnet = PeerAddr{ .ip = .{ 192, 168, 1, 1 }, .port = 9003 };
    try testing.expect(isDiversePeer(diff_subnet, &existing));
}

test "B12: peer persistence save and load roundtrip" {
    // Use a temp file for test
    const test_path = "data/test_peers.dat";

    // Ensure data/ directory exists
    std.fs.cwd().makePath("data") catch {};

    // Create manager with some peers
    var mgr = PeerManager.init(testing.allocator);
    defer mgr.deinit();

    try mgr.addPeer(.{ .ip = .{ 10, 0, 0, 1 }, .port = 9000 }, testing.allocator);
    try mgr.addPeer(.{ .ip = .{ 192, 168, 1, 50 }, .port = 8333 }, testing.allocator);
    try mgr.addPeer(.{ .ip = .{ 127, 0, 0, 1 }, .port = 9001 }, testing.allocator);

    // Save to disk
    savePeersToDisk(&mgr, test_path);

    // Load into a fresh manager
    var mgr2 = PeerManager.init(testing.allocator);
    defer mgr2.deinit();

    loadPeersFromDisk(&mgr2, test_path, testing.allocator);

    // Verify same count
    try testing.expectEqual(mgr.known.items.len, mgr2.known.items.len);

    // Verify first peer matches
    try testing.expectEqual(mgr.known.items[0].addr.ip, mgr2.known.items[0].addr.ip);
    try testing.expectEqual(mgr.known.items[0].addr.port, mgr2.known.items[0].addr.port);

    // Cleanup test file
    std.fs.cwd().deleteFile(test_path) catch {};
}

test "B12: MAX_PEERS and DISCOVERY_INTERVAL constants" {
    try testing.expectEqual(@as(usize, 32), MAX_PEERS);
    try testing.expectEqual(@as(i64, 300), DISCOVERY_INTERVAL_S);
    try testing.expectEqual(@as(i64, 1800), PEER_TIMEOUT_S);
}
