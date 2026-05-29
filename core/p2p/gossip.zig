// Gossip Protocol — TX relay + block propagation (B6)
//
// Extracted from core/p2p.zig. Provides:
//   - SeenHashes: ring-buffer dedup for relay loop prevention
//   - GossipTxPayload: wire format for transaction gossip
//   - GossipBlockPayload: alias for MsgBlockAnnounce
//   - Free functions over *P2PNode: broadcastTx, broadcastBlockGossip,
//     relayTxExcept, relayBlockExcept, gossipMaintenance, getGossipStats
//
// The structs are re-exported from p2p.zig and the methods are exposed as
// thin delegate methods on P2PNode for backward compatibility.

const std = @import("std");
const p2p_mod = @import("../p2p.zig");
const wire = @import("wire.zig");

const P2PNode = p2p_mod.P2PNode;
const MessageType = p2p_mod.MessageType;
const MsgBlockAnnounce = wire.MsgBlockAnnounce;

// ─── Dedup parameters ────────────────────────────────────────────────────────

/// Maximum number of hashes tracked for deduplication
pub const SEEN_HASHES_MAX: usize = 8192;
/// Seen hash entries older than this are evicted (10 minutes in seconds)
pub const SEEN_HASH_EXPIRY_S: i64 = 600;

/// Tracks recently seen TX/block hashes to prevent infinite relay loops.
/// Fixed-size ring buffer — no dynamic allocation after init.
pub const SeenHashes = struct {
    const Entry = struct {
        hash: [64]u8,     // hex hash (64 chars)
        hash_len: u8,
        timestamp: i64,   // when first seen
        active: bool,
    };

    entries: [SEEN_HASHES_MAX]Entry = undefined,
    count: usize = 0,
    next_slot: usize = 0,

    pub fn init() SeenHashes {
        @setEvalBranchQuota(100_000);
        var sh = SeenHashes{};
        for (&sh.entries) |*e| {
            e.active = false;
            e.hash_len = 0;
            e.timestamp = 0;
        }
        return sh;
    }

    /// Returns true if the hash was already seen (still fresh).
    pub fn contains(self: *const SeenHashes, hash: []const u8) bool {
        const now = std.time.timestamp();
        const hlen = @min(hash.len, 64);
        for (&self.entries) |*e| {
            if (!e.active) continue;
            if (e.hash_len != hlen) continue;
            if (now - e.timestamp > SEEN_HASH_EXPIRY_S) continue; // expired
            if (std.mem.eql(u8, e.hash[0..e.hash_len], hash[0..hlen])) return true;
        }
        return false;
    }

    /// Inserts a hash. Returns false if it was already present (duplicate).
    pub fn insert(self: *SeenHashes, hash: []const u8) bool {
        if (self.contains(hash)) return false;

        const hlen: u8 = @intCast(@min(hash.len, 64));
        const slot = self.next_slot;
        self.entries[slot] = .{
            .hash = undefined,
            .hash_len = hlen,
            .timestamp = std.time.timestamp(),
            .active = true,
        };
        @memcpy(self.entries[slot].hash[0..hlen], hash[0..hlen]);
        if (hlen < 64) @memset(self.entries[slot].hash[hlen..], 0);

        self.next_slot = (self.next_slot + 1) % SEEN_HASHES_MAX;
        if (self.count < SEEN_HASHES_MAX) self.count += 1;
        return true;
    }

    /// Evict entries older than SEEN_HASH_EXPIRY_S
    pub fn evictExpired(self: *SeenHashes) void {
        const now = std.time.timestamp();
        for (&self.entries) |*e| {
            if (e.active and (now - e.timestamp > SEEN_HASH_EXPIRY_S)) {
                e.active = false;
                if (self.count > 0) self.count -= 1;
            }
        }
    }
};

/// Gossip TX payload: JSON-encoded transaction for simplicity.
/// Wire format: [hash_len:1][hash:N][json_len:4LE][json:M]
pub const GossipTxPayload = struct {
    tx_hash: []const u8,   // hex hash of the TX
    tx_json: []const u8,   // JSON-encoded TX

    pub fn encode(self: GossipTxPayload, allocator: std.mem.Allocator) ![]u8 {
        const hlen: u8 = @intCast(@min(self.tx_hash.len, 255));
        const jlen: u32 = @intCast(self.tx_json.len);
        const total = @as(usize, 1) + hlen + 4 + jlen;
        var buf = try allocator.alloc(u8, total);
        buf[0] = hlen;
        @memcpy(buf[1 .. 1 + hlen], self.tx_hash[0..hlen]);
        std.mem.writeInt(u32, buf[1 + hlen ..][0..4], jlen, .little);
        @memcpy(buf[1 + hlen + 4 ..][0..jlen], self.tx_json[0..jlen]);
        return buf;
    }

    pub fn decode(data: []const u8) ?GossipTxPayload {
        if (data.len < 6) return null; // min: 1 + 1 + 4 = 6
        const hlen: usize = data[0];
        if (data.len < 1 + hlen + 4) return null;
        const jlen = std.mem.readInt(u32, data[1 + hlen ..][0..4], .little);
        if (data.len < 1 + hlen + 4 + jlen) return null;
        return .{
            .tx_hash = data[1 .. 1 + hlen],
            .tx_json = data[1 + hlen + 4 ..][0..jlen],
        };
    }
};

/// Gossip Block payload: block announce + block hash for relay.
/// Re-uses MsgBlockAnnounce format (80 bytes) — full block data via sync.
pub const GossipBlockPayload = MsgBlockAnnounce;

// ─── Free functions over *P2PNode ────────────────────────────────────────────

/// Broadcast a TX to all connected peers via gossip.
/// Deduplicates: if we already saw this TX hash, skip.
/// tx_hash: hex hash of the transaction (64 chars)
/// tx_json: JSON-encoded transaction payload
pub fn broadcastTx(node: *P2PNode, tx_hash: []const u8, tx_json: []const u8) void {
    // Dedup: skip if already seen
    if (!node.seen_tx_hashes.insert(tx_hash)) {
        return; // already relayed
    }
    node.gossip_tx_count += 1;

    // Encode gossip TX payload
    const payload = (GossipTxPayload{
        .tx_hash = tx_hash,
        .tx_json = tx_json,
    }).encode(node.allocator) catch |err| {
        std.debug.print("[GOSSIP] TX encode failed: {}\n", .{err});
        return;
    };
    defer node.allocator.free(payload);

    var sent: usize = 0;
    {
        node.peers_mutex.lock();
        defer node.peers_mutex.unlock();
        for (node.peers.items) |*peer| {
            if (!peer.connected) continue;
            peer.send(@intFromEnum(MessageType.tx_gossip), payload) catch |err| {
                std.debug.print("[GOSSIP] TX send to {s} failed: {}\n",
                    .{ peer.node_id[0..@min(peer.node_id.len, 16)], err });
                continue;
            };
            sent += 1;
        }
    }
    if (sent > 0) {
        std.debug.print("[GOSSIP] TX {s}.. relayed to {d} peers\n",
            .{ tx_hash[0..@min(tx_hash.len, 12)], sent });
    }
}

/// Broadcast a newly mined/received block to all peers via gossip.
/// Deduplicates: if we already saw this block hash, skip.
/// Uses the block_gossip message type for gossip-aware relay.
pub fn broadcastBlockGossip(
    node:       *P2PNode,
    height:     u64,
    hash_hex:   []const u8,
    reward_sat: u64,
) void {
    // Dedup: skip if already seen
    if (!node.seen_block_hashes.insert(hash_hex)) {
        return; // already relayed
    }
    node.gossip_block_count += 1;
    node.chain_height = height;

    // Use MsgBlockAnnounce as gossip payload. block_hash = 32 raw
    // bytes (V2 wire format), miner_id = up to 42 chars wallet addr.
    const claimed = if (node.miner_address.len > 0) node.miner_address else node.local_id;
    var bh: [32]u8 = @splat(0);
    if (hash_hex.len >= 64) {
        for (0..32) |i| {
            const hi = std.fmt.charToDigit(hash_hex[i * 2], 16) catch break;
            const lo = std.fmt.charToDigit(hash_hex[i * 2 + 1], 16) catch break;
            bh[i] = (@as(u8, hi) << 4) | @as(u8, lo);
        }
    }
    var mi: [42]u8 = @splat(0);
    const mlen = @min(claimed.len, 42);
    @memcpy(mi[0..mlen], claimed[0..mlen]);

    const ann = MsgBlockAnnounce{
        .block_height = height,
        .block_hash   = bh,
        .miner_id     = mi,
        .reward_sat   = reward_sat,
    };
    const payload = ann.encode(node.allocator) catch |err| {
        std.debug.print("[GOSSIP] Block encode failed: {}\n", .{err});
        return;
    };
    defer node.allocator.free(payload);

    var sent: usize = 0;
    {
        node.peers_mutex.lock();
        defer node.peers_mutex.unlock();
        for (node.peers.items) |*peer| {
            if (!peer.connected) continue;
            peer.send(@intFromEnum(MessageType.block_gossip), payload) catch |err| {
                std.debug.print("[GOSSIP] Block send to {s} failed: {} — marking disconnected\n",
                    .{ peer.node_id[0..@min(peer.node_id.len, 16)], err });
                peer.connected = false;
                peer.close();
                node.addReconnect(peer.host, peer.port, peer.node_id[0..@min(peer.node_id.len, 32)]);
                continue;
            };
            sent += 1;
        }
    }
    if (sent > 0) {
        std.debug.print("[GOSSIP] Block #{d} relayed to {d} peers\n", .{ height, sent });
    }
}

/// Relay a received TX to all peers except the sender.
/// Called from dispatchMessage when we receive a tx_gossip message.
pub fn relayTxExcept(node: *P2PNode, except_peer: []const u8, payload: []const u8) void {
    node.peers_mutex.lock();
    defer node.peers_mutex.unlock();
    for (node.peers.items) |*peer| {
        if (!peer.connected) continue;
        // Don't relay back to sender
        if (std.mem.eql(u8, peer.node_id, except_peer)) continue;
        peer.send(@intFromEnum(MessageType.tx_gossip), payload) catch {};
    }
}

/// Relay a received block to all peers except the sender.
pub fn relayBlockExcept(node: *P2PNode, except_peer: []const u8, payload: []const u8) void {
    node.peers_mutex.lock();
    defer node.peers_mutex.unlock();
    for (node.peers.items) |*peer| {
        if (!peer.connected) continue;
        if (std.mem.eql(u8, peer.node_id, except_peer)) continue;
        peer.send(@intFromEnum(MessageType.block_gossip), payload) catch {};
    }
}

/// Periodic maintenance: evict expired seen hashes
pub fn gossipMaintenance(node: *P2PNode) void {
    node.seen_tx_hashes.evictExpired();
    node.seen_block_hashes.evictExpired();
}

pub const GossipStats = struct {
    tx_relayed: u64,
    blocks_relayed: u64,
    seen_tx: usize,
    seen_blocks: usize,
};

/// Returns gossip statistics for logging
pub fn getGossipStats(node: *const P2PNode) GossipStats {
    return .{
        .tx_relayed = node.gossip_tx_count,
        .blocks_relayed = node.gossip_block_count,
        .seen_tx = node.seen_tx_hashes.count,
        .seen_blocks = node.seen_block_hashes.count,
    };
}
