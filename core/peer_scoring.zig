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

    pub fn init() PeerScoringEngine {
        return .{
            .peers = undefined,
            .peer_count = 0,
            .total_bans = 0,
        };
    }

    /// Get or create peer score
    pub fn getOrCreate(self: *PeerScoringEngine, peer_id: [16]u8) *PeerScore {
        // Find existing
        for (self.peers[0..self.peer_count]) |*p| {
            if (std.mem.eql(u8, &p.peer_id, &peer_id)) return p;
        }
        // Create new
        if (self.peer_count < MAX_TRACKED_PEERS) {
            self.peers[self.peer_count] = PeerScore.init(peer_id);
            self.peer_count += 1;
            return &self.peers[self.peer_count - 1];
        }
        // Overwrite lowest score peer
        var lowest_idx: usize = 0;
        var lowest_score: i32 = self.peers[0].score;
        for (self.peers[0..self.peer_count], 0..) |p, i| {
            if (p.score < lowest_score) {
                lowest_score = p.score;
                lowest_idx = i;
            }
        }
        self.peers[lowest_idx] = PeerScore.init(peer_id);
        return &self.peers[lowest_idx];
    }

    /// Score an event for a peer
    pub fn scoreEvent(self: *PeerScoringEngine, peer_id: [16]u8, event: ScoreEvent) void {
        const peer = self.getOrCreate(peer_id);
        const was_banned = peer.banned;
        peer.applyEvent(event);
        if (!was_banned and peer.banned) {
            self.total_bans += 1;
        }
    }

    /// Check if peer is allowed to connect
    pub fn isAllowed(self: *PeerScoringEngine, peer_id: [16]u8) bool {
        for (self.peers[0..self.peer_count]) |*p| {
            if (std.mem.eql(u8, &p.peer_id, &peer_id)) {
                p.checkUnban();
                return !p.banned;
            }
        }
        return true; // Unknown peer = allowed
    }

    /// Get number of currently banned peers
    pub fn bannedCount(self: *const PeerScoringEngine) usize {
        var count: usize = 0;
        for (self.peers[0..self.peer_count]) |p| {
            if (p.banned) count += 1;
        }
        return count;
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
