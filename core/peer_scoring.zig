const std = @import("std");

/// Peer Scoring & Banning System (ca Bitcoin Core)
/// Fiecare peer primeste un scor bazat pe comportament:
///   - Block invalid trimis → -100 (ban)
///   - TX invalid → -10
///   - Timeout → -5
///   - Block valid → +1
///   - Headers useful → +2
/// Peers cu scor < BAN_THRESHOLD sunt bannuiti temporar.
///
/// Bitcoin: similar cu "misbehavior score" din Bitcoin Core
/// EGLD: rating system per validator
/// ETH: peer reputation in DevP2P

/// Ban threshold — peer bannuit daca scorul scade sub aceasta valoare
pub const BAN_THRESHOLD: i32 = -100;
/// Ban duration in seconds
pub const BAN_DURATION_SEC: i64 = 86400; // 24 ore
/// Maximum tracked peers
pub const MAX_TRACKED_PEERS: usize = 256;
/// Maximum persistent ban records (survives eviction from main scoring table)
pub const MAX_BANNED_PEERS: usize = 1024;

/// Persistent ban record — kept separately from scoring table so a banned peer
/// cannot dodge the ban by getting evicted when MAX_TRACKED_PEERS fills up.
pub const BanRecord = struct {
    peer_id: [16]u8,
    ban_until: i64,
    violations: u32,
};

/// Scoring events
pub const ScoreEvent = enum {
    valid_block,
    useful_headers,
    ping_response,
    valid_tx,
    timeout,
    invalid_tx,
    invalid_block,
    malformed_data,
    double_spend_attempt,
    invalid_headers,

    pub fn delta(self: ScoreEvent) i32 {
        return switch (self) {
            .valid_block => 1,
            .useful_headers => 2,
            .ping_response => 1,
            .valid_tx => 1,
            .timeout => -5,
            .invalid_tx => -10,
            .invalid_block => -50,
            .malformed_data => -20,
            .double_spend_attempt => -100,
            .invalid_headers => -30,
        };
    }
};

/// Peer score record
pub const PeerScore = struct {
    /// Peer identifier (node_id hash)
    peer_id: [16]u8,
    /// Current score
    score: i32,
    /// Number of valid blocks relayed
    valid_blocks: u32,
    /// Number of invalid messages
    violations: u32,
    /// Is currently banned
    banned: bool,
    /// Ban expiry timestamp (0 = not banned)
    ban_until: i64,
    /// First seen timestamp
    first_seen: i64,
    /// Last activity timestamp
    last_active: i64,

    pub fn init(peer_id: [16]u8) PeerScore {
        return .{
            .peer_id = peer_id,
            .score = 0,
            .valid_blocks = 0,
            .violations = 0,
            .banned = false,
            .ban_until = 0,
            .first_seen = std.time.timestamp(),
            .last_active = std.time.timestamp(),
        };
    }

    /// Apply a scoring event
    pub fn applyEvent(self: *PeerScore, event: ScoreEvent) void {
        const d = event.delta();
        self.score += d;
        self.last_active = std.time.timestamp();

        if (d > 0) {
            self.valid_blocks += 1;
        } else {
            self.violations += 1;
        }

        // Auto-ban if score drops below threshold
        if (self.score <= BAN_THRESHOLD and !self.banned) {
            self.banned = true;
            self.ban_until = std.time.timestamp() + BAN_DURATION_SEC;
        }
    }

    /// Check if ban has expired
    pub fn isBanExpired(self: *const PeerScore) bool {
        if (!self.banned) return true;
        return std.time.timestamp() >= self.ban_until;
    }

    /// Unban if expired
    pub fn checkUnban(self: *PeerScore) void {
        if (self.banned and self.isBanExpired()) {
            self.banned = false;
            self.score = 0; // Reset score on unban
            self.violations = 0;
        }
    }

    /// Trust level (0-100)
    pub fn trustLevel(self: *const PeerScore) u8 {
        if (self.banned) return 0;
        if (self.score <= 0) return 10;
        if (self.score >= 100) return 100;
        return @intCast(@min(100, @max(0, self.score)));
    }
};

/// Peer Scoring Engine
pub const PeerScoringEngine = struct {
    peers: [MAX_TRACKED_PEERS]PeerScore,
    peer_count: usize,
    total_bans: u32,
    /// Persistent ban list — bans here survive eviction from `peers`.
    banned: [MAX_BANNED_PEERS]BanRecord,
    banned_count: usize,

    pub fn init() PeerScoringEngine {
        return .{
            .peers = undefined,
            .peer_count = 0,
            .total_bans = 0,
            .banned = undefined,
            .banned_count = 0,
        };
    }

    /// Find index of a banned peer in the persistent list, or null.
    fn findBanned(self: *PeerScoringEngine, peer_id: [16]u8) ?usize {
        for (self.banned[0..self.banned_count], 0..) |b, i| {
            if (std.mem.eql(u8, &b.peer_id, &peer_id)) return i;
        }
        return null;
    }

    /// Insert/update a peer in the persistent ban list.
    fn upsertBanned(self: *PeerScoringEngine, peer_id: [16]u8, ban_until: i64, violations: u32) void {
        if (self.findBanned(peer_id)) |idx| {
            // Refresh existing record — extend ban window.
            if (ban_until > self.banned[idx].ban_until) self.banned[idx].ban_until = ban_until;
            self.banned[idx].violations = violations;
            return;
        }
        if (self.banned_count < MAX_BANNED_PEERS) {
            self.banned[self.banned_count] = .{
                .peer_id = peer_id,
                .ban_until = ban_until,
                .violations = violations,
            };
            self.banned_count += 1;
            return;
        }
        // Persistent list full — overwrite the entry whose ban expires soonest
        // (least valuable to retain). We never silently drop an active ban for a
        // fresh one with a later expiry.
        var oldest_idx: usize = 0;
        var oldest_until: i64 = self.banned[0].ban_until;
        for (self.banned[0..self.banned_count], 0..) |b, i| {
            if (b.ban_until < oldest_until) {
                oldest_until = b.ban_until;
                oldest_idx = i;
            }
        }
        if (ban_until > self.banned[oldest_idx].ban_until) {
            self.banned[oldest_idx] = .{
                .peer_id = peer_id,
                .ban_until = ban_until,
                .violations = violations,
            };
        }
    }

    /// Drop ban records whose ban_until is in the past.
    pub fn cleanupExpiredBans(self: *PeerScoringEngine, now: i64) usize {
        var write: usize = 0;
        var dropped: usize = 0;
        var i: usize = 0;
        while (i < self.banned_count) : (i += 1) {
            if (self.banned[i].ban_until > now) {
                if (write != i) self.banned[write] = self.banned[i];
                write += 1;
            } else {
                dropped += 1;
            }
        }
        self.banned_count = write;
        return dropped;
    }

    /// Get or create peer score. A peer that is on the persistent ban list and
    /// whose ban has not expired is returned with banned=true preserved, even
    /// after being evicted from the scoring table.
    pub fn getOrCreate(self: *PeerScoringEngine, peer_id: [16]u8) *PeerScore {
        // Find existing
        for (self.peers[0..self.peer_count]) |*p| {
            if (std.mem.eql(u8, &p.peer_id, &peer_id)) return p;
        }
        // Helper to seed a slot from ban record (if any).
        const seed = struct {
            fn apply(engine: *PeerScoringEngine, slot: *PeerScore, pid: [16]u8) void {
                slot.* = PeerScore.init(pid);
                if (engine.findBanned(pid)) |bidx| {
                    const rec = engine.banned[bidx];
                    if (rec.ban_until > std.time.timestamp()) {
                        slot.banned = true;
                        slot.ban_until = rec.ban_until;
                        slot.score = BAN_THRESHOLD;
                        slot.violations = rec.violations;
                    }
                }
            }
        };
        // Create new
        if (self.peer_count < MAX_TRACKED_PEERS) {
            seed.apply(self, &self.peers[self.peer_count], peer_id);
            self.peer_count += 1;
            return &self.peers[self.peer_count - 1];
        }
        // Eviction — pick a NON-BANNED peer with lowest score. If a banned
        // peer is about to be evicted, copy its ban into the persistent list
        // first so the ban is not whitewashed.
        var lowest_idx: usize = MAX_TRACKED_PEERS; // sentinel
        var lowest_score: i32 = std.math.maxInt(i32);
        for (self.peers[0..self.peer_count], 0..) |p, i| {
            if (p.banned) continue;
            if (p.score < lowest_score) {
                lowest_score = p.score;
                lowest_idx = i;
            }
        }
        if (lowest_idx == MAX_TRACKED_PEERS) {
            // Every slot is banned. Persist all then evict the one whose ban
            // expires soonest (it is the least valuable to keep in memory).
            var oldest_idx: usize = 0;
            var oldest_until: i64 = self.peers[0].ban_until;
            for (self.peers[0..self.peer_count], 0..) |p, i| {
                self.upsertBanned(p.peer_id, p.ban_until, p.violations);
                if (p.ban_until < oldest_until) {
                    oldest_until = p.ban_until;
                    oldest_idx = i;
                }
            }
            lowest_idx = oldest_idx;
        }
        seed.apply(self, &self.peers[lowest_idx], peer_id);
        return &self.peers[lowest_idx];
    }

    /// Score an event for a peer
    pub fn scoreEvent(self: *PeerScoringEngine, peer_id: [16]u8, event: ScoreEvent) void {
        const peer = self.getOrCreate(peer_id);
        const was_banned = peer.banned;
        peer.applyEvent(event);
        if (!was_banned and peer.banned) {
            self.total_bans += 1;
            // Mirror into the persistent ban list immediately so eviction can't
            // erase the ban.
            self.upsertBanned(peer.peer_id, peer.ban_until, peer.violations);
        }
    }

    /// Check if peer is allowed to connect.
    /// Order: persistent ban list first (catches evicted-but-still-banned
    /// peers), then in-memory scoring table.
    pub fn isAllowed(self: *PeerScoringEngine, peer_id: [16]u8) bool {
        const now = std.time.timestamp();
        if (self.findBanned(peer_id)) |idx| {
            if (self.banned[idx].ban_until > now) return false;
            // Ban expired — drop from persistent list.
            _ = self.cleanupExpiredBans(now);
        }
        for (self.peers[0..self.peer_count]) |*p| {
            if (std.mem.eql(u8, &p.peer_id, &peer_id)) {
                p.checkUnban();
                return !p.banned;
            }
        }
        return true; // Unknown peer = allowed
    }

    /// Get number of currently banned peers (in scoring table).
    pub fn bannedCount(self: *const PeerScoringEngine) usize {
        var count: usize = 0;
        for (self.peers[0..self.peer_count]) |p| {
            if (p.banned) count += 1;
        }
        return count;
    }

    /// Total number of persistent ban records (survives eviction).
    pub fn persistentBanCount(self: *const PeerScoringEngine) usize {
        return self.banned_count;
    }

    /// Serialize persistent ban list into caller-provided buffer.
    /// Layout: u32 LE count, then each record: peer_id[16] | ban_until i64 LE | violations u32 LE.
    /// Returns number of bytes written. Caller persists to disk however it likes.
    pub fn serializeBans(self: *const PeerScoringEngine, out: []u8) !usize {
        const rec_size: usize = 16 + 8 + 4;
        const need = 4 + self.banned_count * rec_size;
        if (out.len < need) return error.BufferTooSmall;
        std.mem.writeInt(u32, out[0..4], @intCast(self.banned_count), .little);
        var off: usize = 4;
        for (self.banned[0..self.banned_count]) |b| {
            @memcpy(out[off..][0..16], &b.peer_id);
            std.mem.writeInt(i64, out[off + 16 ..][0..8], b.ban_until, .little);
            std.mem.writeInt(u32, out[off + 24 ..][0..4], b.violations, .little);
            off += rec_size;
        }
        return need;
    }

    /// Restore persistent ban list from a buffer produced by serializeBans.
    /// Expired bans (ban_until <= now) are dropped on load.
    pub fn deserializeBans(self: *PeerScoringEngine, buf: []const u8) !void {
        if (buf.len < 4) return error.Truncated;
        const count = std.mem.readInt(u32, buf[0..4], .little);
        const rec_size: usize = 16 + 8 + 4;
        if (buf.len < 4 + count * rec_size) return error.Truncated;
        const now = std.time.timestamp();
        self.banned_count = 0;
        var off: usize = 4;
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            if (self.banned_count >= MAX_BANNED_PEERS) break;
            var rec: BanRecord = undefined;
            @memcpy(&rec.peer_id, buf[off..][0..16]);
            rec.ban_until = std.mem.readInt(i64, buf[off + 16 ..][0..8], .little);
            rec.violations = std.mem.readInt(u32, buf[off + 24 ..][0..4], .little);
            off += rec_size;
            if (rec.ban_until > now) {
                self.banned[self.banned_count] = rec;
                self.banned_count += 1;
            }
        }
    }
};

// ─── Tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

test "PeerScore — init with zero score" {
    const ps = PeerScore.init([_]u8{0xAA} ** 16);
    try testing.expectEqual(@as(i32, 0), ps.score);
    try testing.expect(!ps.banned);
}

test "PeerScore — valid blocks increase score" {
    var ps = PeerScore.init([_]u8{0xBB} ** 16);
    ps.applyEvent(.valid_block);
    ps.applyEvent(.valid_block);
    ps.applyEvent(.useful_headers);
    try testing.expectEqual(@as(i32, 4), ps.score);
    try testing.expectEqual(@as(u32, 3), ps.valid_blocks);
}

test "PeerScore — invalid block decreases score" {
    var ps = PeerScore.init([_]u8{0xCC} ** 16);
    ps.applyEvent(.invalid_block);
    try testing.expectEqual(@as(i32, -50), ps.score);
    try testing.expectEqual(@as(u32, 1), ps.violations);
}

test "PeerScore — auto-ban at threshold" {
    var ps = PeerScore.init([_]u8{0xDD} ** 16);
    ps.applyEvent(.double_spend_attempt); // -100 → banned
    try testing.expect(ps.banned);
    try testing.expectEqual(@as(u8, 0), ps.trustLevel());
}

test "PeerScore — trust level" {
    var ps = PeerScore.init([_]u8{0xEE} ** 16);
    try testing.expectEqual(@as(u8, 10), ps.trustLevel()); // score 0 → 10
    ps.score = 50;
    try testing.expectEqual(@as(u8, 50), ps.trustLevel());
    ps.score = 200;
    try testing.expectEqual(@as(u8, 100), ps.trustLevel());
}

test "PeerScoringEngine — track multiple peers" {
    var engine = PeerScoringEngine.init();
    engine.scoreEvent([_]u8{0x01} ** 16, .valid_block);
    engine.scoreEvent([_]u8{0x02} ** 16, .invalid_tx);
    try testing.expectEqual(@as(usize, 2), engine.peer_count);
}

test "PeerScoringEngine — ban and check allowed" {
    var engine = PeerScoringEngine.init();
    const bad_peer = [_]u8{0xFF} ** 16;
    engine.scoreEvent(bad_peer, .double_spend_attempt);
    try testing.expect(!engine.isAllowed(bad_peer));
    try testing.expectEqual(@as(usize, 1), engine.bannedCount());
}

test "PeerScoringEngine — good peer stays allowed" {
    var engine = PeerScoringEngine.init();
    const good_peer = [_]u8{0x11} ** 16;
    engine.scoreEvent(good_peer, .valid_block);
    engine.scoreEvent(good_peer, .useful_headers);
    try testing.expect(engine.isAllowed(good_peer));
}

test "PeerScoringEngine — unknown peer allowed" {
    var engine = PeerScoringEngine.init();
    try testing.expect(engine.isAllowed([_]u8{0x99} ** 16));
}

test "PeerScoringEngine — banned peer survives eviction (MEDIUM-06)" {
    var engine = PeerScoringEngine.init();
    const bad_peer: [16]u8 = .{0xAB} ** 16;

    // Ban the peer.
    engine.scoreEvent(bad_peer, .double_spend_attempt);
    try testing.expect(!engine.isAllowed(bad_peer));
    try testing.expectEqual(@as(usize, 1), engine.persistentBanCount());

    // Fill scoring table with new peers — forces eviction of the banned one
    // out of the in-memory table.
    var i: usize = 0;
    while (i < MAX_TRACKED_PEERS + 50) : (i += 1) {
        var pid: [16]u8 = undefined;
        @memset(&pid, 0);
        std.mem.writeInt(u64, pid[0..8], @as(u64, i) + 1000, .little);
        engine.scoreEvent(pid, .valid_block);
    }

    // The banned peer must still be rejected even though it likely got
    // evicted from `peers`.
    try testing.expect(!engine.isAllowed(bad_peer));
    try testing.expect(engine.persistentBanCount() >= 1);
}

test "PeerScoringEngine — ban serialization round-trip" {
    var engine = PeerScoringEngine.init();
    engine.scoreEvent([_]u8{0xAA} ** 16, .double_spend_attempt);
    engine.scoreEvent([_]u8{0xBB} ** 16, .double_spend_attempt);
    var buf: [4096]u8 = undefined;
    const n = try engine.serializeBans(&buf);
    try testing.expect(n > 4);

    var engine2 = PeerScoringEngine.init();
    try engine2.deserializeBans(buf[0..n]);
    try testing.expect(!engine2.isAllowed([_]u8{0xAA} ** 16));
    try testing.expect(!engine2.isAllowed([_]u8{0xBB} ** 16));
}

test "PeerScoringEngine — cleanupExpiredBans drops stale records" {
    var engine = PeerScoringEngine.init();
    engine.banned[0] = .{ .peer_id = [_]u8{0x01} ** 16, .ban_until = 1, .violations = 1 };
    engine.banned[1] = .{ .peer_id = [_]u8{0x02} ** 16, .ban_until = std.math.maxInt(i64), .violations = 1 };
    engine.banned_count = 2;
    const dropped = engine.cleanupExpiredBans(std.time.timestamp());
    try testing.expectEqual(@as(usize, 1), dropped);
    try testing.expectEqual(@as(usize, 1), engine.banned_count);
}

test "isDiversePeer — anti-eclipse" {
    const bootstrap = @import("bootstrap.zig");
    const peers = [_]bootstrap.PeerAddr{
        .{ .ip = .{ 10, 0, 1, 1 }, .port = 8333 },
        .{ .ip = .{ 10, 0, 1, 2 }, .port = 8333 },
    };
    // Same /16 subnet (10.0.x.x) — already 2, should reject
    const same_subnet = bootstrap.PeerAddr{ .ip = .{ 10, 0, 2, 1 }, .port = 8333 };
    try testing.expect(!bootstrap.isDiversePeer(same_subnet, &peers));

    // Different /16 subnet — should accept
    const diff_subnet = bootstrap.PeerAddr{ .ip = .{ 192, 168, 1, 1 }, .port = 8333 };
    try testing.expect(bootstrap.isDiversePeer(diff_subnet, &peers));
}
