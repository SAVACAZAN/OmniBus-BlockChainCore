const std = @import("std");

/// Kademlia DHT for Decentralized Peer Discovery
///
/// Replaces static seed nodes with distributed hash table:
///   - Each node has a 160-bit ID (SHA-1 of public key)
///   - Routing table: k-buckets (k=20) organized by XOR distance
///   - Node lookup: iterative closest-node queries (alpha=3 parallel)
///   - Stores peer addresses, NOT data (unlike full DHT)
///
/// Used by:
///   - Ethereum: Discv5 (UDP-based Kademlia variant)
///   - EGLD: Kademia DHT for peer routing
///   - IPFS: full Kademlia for content routing
///   - Bitcoin: NOT used (DNS seeds + addr gossip instead)
///
/// OmniBus: Kademlia for peer discovery + fallback to seed nodes

/// Node ID size (160 bits = 20 bytes, like original Kademlia)
pub const NODE_ID_SIZE: usize = 20;
/// K-bucket size (max peers per bucket)
pub const K_BUCKET_SIZE: usize = 20;
/// Number of buckets (160 for 160-bit IDs)
pub const NUM_BUCKETS: usize = 160;
/// Alpha: parallel lookups
pub const ALPHA: usize = 3;
/// Max tracked nodes total
pub const MAX_DHT_NODES: usize = 256;
/// Refresh interval in blocks
pub const BUCKET_REFRESH_INTERVAL: u64 = 3600; // ~1 hour at 1 block/s

/// DHT Node ID
pub const NodeId = [NODE_ID_SIZE]u8;

/// Compute XOR distance between two node IDs
pub fn xorDistance(a: NodeId, b: NodeId) NodeId {
    var result: NodeId = undefined;
    for (0..NODE_ID_SIZE) |i| {
        result[i] = a[i] ^ b[i];
    }
    return result;
}

/// Find the bucket index for a given distance (leading zero bits count)
pub fn bucketIndex(distance: NodeId) u8 {
    for (0..NODE_ID_SIZE) |i| {
        if (distance[i] != 0) {
            // Count leading zeros in this byte
            var zeros: u8 = 0;
            var byte = distance[i];
            while (byte & 0x80 == 0 and zeros < 8) {
                zeros += 1;
                byte <<= 1;
            }
            return @intCast(i * 8 + zeros);
        }
    }
    return NUM_BUCKETS - 1; // Same node (distance = 0)
}

/// Generate a node ID from a public key or random bytes
pub fn generateNodeId(seed: []const u8) NodeId {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(seed);
    var full_hash: [32]u8 = undefined;
    hasher.final(&full_hash);
    var id: NodeId = undefined;
    @memcpy(&id, full_hash[0..NODE_ID_SIZE]);
    return id;
}

/// DHT Peer entry
pub const DhtPeer = struct {
    id: NodeId,
    ip: [4]u8,
    port: u16,
    last_seen: i64,
    /// Round-trip time in ms (for sorting)
    rtt_ms: u16,

    pub fn isStale(self: *const DhtPeer, current_time: i64, timeout_sec: i64) bool {
        return (current_time - self.last_seen) > timeout_sec;
    }
};

/// K-Bucket: stores up to K peers at a specific XOR distance range
pub const KBucket = struct {
    peers: [K_BUCKET_SIZE]DhtPeer,
    count: u8,
    last_refresh: i64,

    pub fn init() KBucket {
        return .{
            .peers = undefined,
            .count = 0,
            .last_refresh = 0,
        };
    }

    /// Add or update a peer in the bucket
    pub fn addPeer(self: *KBucket, peer: DhtPeer) bool {
        // Check if already exists — update last_seen
        for (self.peers[0..self.count]) |*p| {
            if (std.mem.eql(u8, &p.id, &peer.id)) {
                p.last_seen = peer.last_seen;
                p.rtt_ms = peer.rtt_ms;
                return true;
            }
        }
        // Add new if space available
        if (self.count < K_BUCKET_SIZE) {
            self.peers[self.count] = peer;
            self.count += 1;
            return true;
        }
        // Bucket full — evict stalest peer (LRU, like Kademlia spec)
        var oldest_idx: usize = 0;
        var oldest_time: i64 = self.peers[0].last_seen;
        for (self.peers[0..self.count], 0..) |p, i| {
            if (p.last_seen < oldest_time) {
                oldest_time = p.last_seen;
                oldest_idx = i;
            }
        }
        // Only evict if new peer is fresher
        if (peer.last_seen > oldest_time) {
            self.peers[oldest_idx] = peer;
            return true;
        }
        return false;
    }

    /// Find closest N peers to target ID in this bucket
    pub fn findClosest(self: *const KBucket, target: NodeId, max_results: usize) [K_BUCKET_SIZE]DhtPeer {
        // Simple: return all peers sorted by distance
        var sorted = self.peers;
        // Bubble sort by XOR distance (small K, OK performance)
        for (0..self.count) |i| {
            for (i + 1..self.count) |j| {
                const dist_i = xorDistance(sorted[i].id, target);
                const dist_j = xorDistance(sorted[j].id, target);
                if (lessThan(dist_j, dist_i)) {
                    const tmp = sorted[i];
                    sorted[i] = sorted[j];
                    sorted[j] = tmp;
                }
            }
        }
        _ = max_results;
        return sorted;
    }
};

/// Compare two distances (is a < b?)
fn lessThan(a: NodeId, b: NodeId) bool {
    for (0..NODE_ID_SIZE) |i| {
        if (a[i] < b[i]) return true;
        if (a[i] > b[i]) return false;
    }
    return false;
}

/// Kademlia DHT Routing Table
pub const DhtRoutingTable = struct {
    /// Local node ID
    local_id: NodeId,
    /// K-buckets indexed by XOR distance prefix length
    buckets: [NUM_BUCKETS]KBucket,
    /// Total known peers
    total_peers: usize,

    pub fn init(local_id: NodeId) DhtRoutingTable {
        var table: DhtRoutingTable = undefined;
        table.local_id = local_id;
        table.total_peers = 0;
        for (0..NUM_BUCKETS) |i| {
            table.buckets[i] = KBucket.init();
        }
        return table;
    }

    /// Add a peer to the appropriate bucket
    pub fn addPeer(self: *DhtRoutingTable, peer: DhtPeer) bool {
        const dist = xorDistance(self.local_id, peer.id);
        const idx = bucketIndex(dist);
        if (idx >= NUM_BUCKETS) return false;
        const added = self.buckets[idx].addPeer(peer);
        if (added) self.total_peers += 1;
        return added;
    }

    /// Find the K closest peers to a target ID (across all buckets)
    pub fn findClosest(self: *const DhtRoutingTable, target: NodeId, max_results: usize) [K_BUCKET_SIZE]DhtPeer {
        _ = max_results;
        // Find the target's bucket
        const dist = xorDistance(self.local_id, target);
        const idx = bucketIndex(dist);

        // Start with the target bucket, expand outward
        if (idx < NUM_BUCKETS and self.buckets[idx].count > 0) {
            return self.buckets[idx].findClosest(target, K_BUCKET_SIZE);
        }

        // Search adjacent buckets
        var best_bucket: usize = 0;
        var best_count: u8 = 0;
        for (0..NUM_BUCKETS) |i| {
            if (self.buckets[i].count > best_count) {
                best_count = self.buckets[i].count;
                best_bucket = i;
            }
        }
        return self.buckets[best_bucket].findClosest(target, K_BUCKET_SIZE);
    }

    /// Get total peer count
    pub fn peerCount(self: *const DhtRoutingTable) usize {
        var count: usize = 0;
        for (self.buckets) |b| {
            count += b.count;
        }
        return count;
    }

    /// Remove stale peers
    pub fn evictStale(self: *DhtRoutingTable, current_time: i64, timeout_sec: i64) usize {
        var evicted: usize = 0;
        for (&self.buckets) |*bucket| {
            var i: usize = 0;
            while (i < bucket.count) {
                if (bucket.peers[i].isStale(current_time, timeout_sec)) {
                    // Shift remaining peers down
                    if (i + 1 < bucket.count) {
                        bucket.peers[i] = bucket.peers[bucket.count - 1];
                    }
                    bucket.count -= 1;
                    evicted += 1;
                } else {
                    i += 1;
                }
            }
        }
        return evicted;
    }
};

// ─── Tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

test "xorDistance — same ID = zero" {
    const id = [_]u8{0xAA} ** NODE_ID_SIZE;
    const dist = xorDistance(id, id);
    for (dist) |b| try testing.expectEqual(@as(u8, 0), b);
}

test "xorDistance — different IDs = non-zero" {
    const a = [_]u8{0xFF} ** NODE_ID_SIZE;
    const b = [_]u8{0x00} ** NODE_ID_SIZE;
    const dist = xorDistance(a, b);
    for (dist) |byte| try testing.expectEqual(@as(u8, 0xFF), byte);
}

test "xorDistance — symmetric" {
    const a = [_]u8{0xAA} ** NODE_ID_SIZE;
    const b = [_]u8{0x55} ** NODE_ID_SIZE;
    try testing.expectEqualSlices(u8, &xorDistance(a, b), &xorDistance(b, a));
}

test "bucketIndex — max distance = bucket 0" {
    const dist = [_]u8{0xFF} ** NODE_ID_SIZE;
    try testing.expectEqual(@as(u8, 0), bucketIndex(dist));
}

test "bucketIndex — small distance = high bucket" {
    var dist = [_]u8{0} ** NODE_ID_SIZE;
    dist[19] = 1; // Only last bit set = distance 2^0
    try testing.expectEqual(@as(u8, 159), bucketIndex(dist));
}

test "generateNodeId — deterministic" {
    const id1 = generateNodeId("test_node_1");
    const id2 = generateNodeId("test_node_1");
    try testing.expectEqualSlices(u8, &id1, &id2);
}

test "generateNodeId — different seeds = different IDs" {
    const id1 = generateNodeId("node_A");
    const id2 = generateNodeId("node_B");
    try testing.expect(!std.mem.eql(u8, &id1, &id2));
}

test "KBucket — add and count" {
    var bucket = KBucket.init();
    const peer = DhtPeer{
        .id = generateNodeId("peer1"), .ip = .{ 10, 0, 0, 1 }, .port = 8333,
        .last_seen = 1000, .rtt_ms = 50,
    };
    try testing.expect(bucket.addPeer(peer));
    try testing.expectEqual(@as(u8, 1), bucket.count);
}

test "KBucket — update existing peer" {
    var bucket = KBucket.init();
    const id = generateNodeId("peer_upd");
    const peer1 = DhtPeer{ .id = id, .ip = .{ 10, 0, 0, 1 }, .port = 8333, .last_seen = 1000, .rtt_ms = 50 };
    const peer2 = DhtPeer{ .id = id, .ip = .{ 10, 0, 0, 1 }, .port = 8333, .last_seen = 2000, .rtt_ms = 30 };
    _ = bucket.addPeer(peer1);
    _ = bucket.addPeer(peer2);
    // Should still be 1 peer (updated, not duplicated)
    try testing.expectEqual(@as(u8, 1), bucket.count);
    try testing.expectEqual(@as(i64, 2000), bucket.peers[0].last_seen);
}

test "DhtRoutingTable — add peers to different buckets" {
    const local_id = generateNodeId("local_node");
    var table = DhtRoutingTable.init(local_id);

    const p1 = DhtPeer{ .id = generateNodeId("remote_1"), .ip = .{ 10, 0, 0, 1 }, .port = 8333, .last_seen = 1000, .rtt_ms = 50 };
    const p2 = DhtPeer{ .id = generateNodeId("remote_2"), .ip = .{ 10, 0, 0, 2 }, .port = 8333, .last_seen = 1000, .rtt_ms = 60 };

    try testing.expect(table.addPeer(p1));
    try testing.expect(table.addPeer(p2));
    try testing.expect(table.peerCount() >= 2);
}

test "DhtRoutingTable — evict stale peers" {
    const local_id = generateNodeId("evictor");
    var table = DhtRoutingTable.init(local_id);

    const old_peer = DhtPeer{ .id = generateNodeId("stale"), .ip = .{ 1, 1, 1, 1 }, .port = 8333, .last_seen = 100, .rtt_ms = 999 };
    _ = table.addPeer(old_peer);

    // Evict peers older than 500 seconds at time=1000
    const evicted = table.evictStale(1000, 500);
    try testing.expect(evicted >= 1);
}

test "DhtPeer — stale detection" {
    const peer = DhtPeer{ .id = [_]u8{0} ** NODE_ID_SIZE, .ip = .{ 0, 0, 0, 0 }, .port = 0, .last_seen = 100, .rtt_ms = 0 };
    try testing.expect(peer.isStale(1000, 500));  // 900s > 500s timeout
    try testing.expect(!peer.isStale(400, 500));   // 300s < 500s timeout
}

test "lessThan — distance comparison" {
    const a = [_]u8{0x00} ** NODE_ID_SIZE;
    const b = [_]u8{0xFF} ** NODE_ID_SIZE;
    try testing.expect(lessThan(a, b));
    try testing.expect(!lessThan(b, a));
    try testing.expect(!lessThan(a, a)); // equal = not less than
}
