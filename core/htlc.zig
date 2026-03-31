const std = @import("std");
const crypto_mod = @import("crypto.zig");

// ─── HTLC — Hash Time-Locked Contracts ──────────────────────────────────────
//
// Core building block for Lightning Network and atomic swaps.
//
// How it works:
//   1. Alice wants to pay Bob through intermediary Carol
//   2. Bob generates secret R, gives H(R) to Alice
//   3. Alice locks funds: "Pay Bob if he reveals R before block N"
//   4. If Bob reveals R before timeout → he gets the funds
//   5. If timeout expires → Alice gets refund
//
// Two spending paths:
//   SUCCESS: recipient reveals preimage R where SHA256(R) = hash
//   TIMEOUT: sender reclaims after timeout block height

/// HTLC state machine
pub const HTLCState = enum {
    /// Created but not yet funded
    pending,
    /// Funded on-chain, waiting for claim or timeout
    active,
    /// Recipient claimed by revealing preimage
    claimed,
    /// Sender reclaimed after timeout
    refunded,
    /// Expired (timeout passed, not yet refunded)
    expired,
};

/// Hash Time-Locked Contract
pub const HTLC = struct {
    /// Unique identifier
    id: u64,
    /// Sender address
    sender: []const u8,
    /// Recipient address
    recipient: []const u8,
    /// Amount locked in SAT
    amount: u64,
    /// SHA256 hash of the preimage (payment hash)
    payment_hash: [32]u8,
    /// Timeout: block height after which sender can reclaim
    timeout_height: u64,
    /// Current state
    state: HTLCState,
    /// Creation timestamp
    created_at: i64,
    /// The revealed preimage (set when claimed)
    preimage: ?[32]u8,

    /// Create a new HTLC
    pub fn create(
        id: u64,
        sender: []const u8,
        recipient: []const u8,
        amount: u64,
        payment_hash: [32]u8,
        timeout_height: u64,
    ) HTLC {
        return HTLC{
            .id = id,
            .sender = sender,
            .recipient = recipient,
            .amount = amount,
            .payment_hash = payment_hash,
            .timeout_height = timeout_height,
            .state = .pending,
            .created_at = std.time.timestamp(),
            .preimage = null,
        };
    }

    /// Activate the HTLC (funds locked on-chain)
    pub fn activate(self: *HTLC) !void {
        if (self.state != .pending) return error.InvalidHTLCState;
        self.state = .active;
    }

    /// Claim the HTLC by revealing the preimage
    /// Verifies SHA256(preimage) == payment_hash
    pub fn claim(self: *HTLC, preimage: [32]u8) !void {
        if (self.state != .active) return error.InvalidHTLCState;

        // Verify preimage
        var hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(&preimage, &hash, .{});
        if (!std.mem.eql(u8, &hash, &self.payment_hash)) return error.InvalidPreimage;

        self.preimage = preimage;
        self.state = .claimed;
    }

    /// Refund the HTLC after timeout (sender reclaims)
    pub fn refund(self: *HTLC, current_height: u64) !void {
        if (self.state != .active and self.state != .expired) return error.InvalidHTLCState;
        if (current_height < self.timeout_height) return error.HTLCNotExpired;
        self.state = .refunded;
    }

    /// Check if the HTLC has expired (timeout reached)
    pub fn checkExpiry(self: *HTLC, current_height: u64) void {
        if (self.state == .active and current_height >= self.timeout_height) {
            self.state = .expired;
        }
    }

    /// Can the recipient claim? (active and has valid preimage)
    pub fn canClaim(self: *const HTLC) bool {
        return self.state == .active;
    }

    /// Can the sender refund? (expired or past timeout)
    pub fn canRefund(self: *const HTLC, current_height: u64) bool {
        return (self.state == .active or self.state == .expired) and
            current_height >= self.timeout_height;
    }

    /// Generate a random preimage and its hash
    pub fn generatePreimage() struct { preimage: [32]u8, hash: [32]u8 } {
        var preimage: [32]u8 = undefined;
        std.crypto.random.bytes(&preimage);
        var hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(&preimage, &hash, .{});
        return .{ .preimage = preimage, .hash = hash };
    }
};

/// HTLC Registry — manages active HTLCs
pub const HTLCRegistry = struct {
    htlcs: std.AutoHashMap(u64, HTLC),
    next_id: u64,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) HTLCRegistry {
        return HTLCRegistry{
            .htlcs = std.AutoHashMap(u64, HTLC).init(allocator),
            .next_id = 1,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *HTLCRegistry) void {
        self.htlcs.deinit();
    }

    /// Create and register a new HTLC
    pub fn createHTLC(
        self: *HTLCRegistry,
        sender: []const u8,
        recipient: []const u8,
        amount: u64,
        payment_hash: [32]u8,
        timeout_height: u64,
    ) !u64 {
        const id = self.next_id;
        self.next_id += 1;

        const htlc = HTLC.create(id, sender, recipient, amount, payment_hash, timeout_height);
        try self.htlcs.put(id, htlc);
        return id;
    }

    /// Get an HTLC by ID
    pub fn getHTLC(self: *const HTLCRegistry, id: u64) ?HTLC {
        return self.htlcs.get(id);
    }

    /// Activate an HTLC
    pub fn activateHTLC(self: *HTLCRegistry, id: u64) !void {
        if (self.htlcs.getPtr(id)) |htlc| {
            try htlc.activate();
        } else return error.HTLCNotFound;
    }

    /// Claim an HTLC with preimage
    pub fn claimHTLC(self: *HTLCRegistry, id: u64, preimage: [32]u8) !void {
        if (self.htlcs.getPtr(id)) |htlc| {
            try htlc.claim(preimage);
        } else return error.HTLCNotFound;
    }

    /// Refund an expired HTLC
    pub fn refundHTLC(self: *HTLCRegistry, id: u64, current_height: u64) !void {
        if (self.htlcs.getPtr(id)) |htlc| {
            try htlc.refund(current_height);
        } else return error.HTLCNotFound;
    }

    /// Expire all HTLCs past their timeout
    pub fn expireAll(self: *HTLCRegistry, current_height: u64) u32 {
        var count: u32 = 0;
        var it = self.htlcs.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.state == .active and current_height >= entry.value_ptr.timeout_height) {
                entry.value_ptr.state = .expired;
                count += 1;
            }
        }
        return count;
    }

    /// Get count of active HTLCs
    pub fn activeCount(self: *const HTLCRegistry) u32 {
        var count: u32 = 0;
        var it = self.htlcs.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.state == .active) count += 1;
        }
        return count;
    }
};

// ─── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

test "HTLC — create, activate, claim with preimage" {
    const pair = HTLC.generatePreimage();

    var htlc = HTLC.create(1, "ob1qsender", "ob1qrecipient", 50000, pair.hash, 1000);
    try testing.expectEqual(HTLCState.pending, htlc.state);

    try htlc.activate();
    try testing.expectEqual(HTLCState.active, htlc.state);

    try htlc.claim(pair.preimage);
    try testing.expectEqual(HTLCState.claimed, htlc.state);
    try testing.expect(htlc.preimage != null);
}

test "HTLC — wrong preimage rejected" {
    const pair = HTLC.generatePreimage();
    var htlc = HTLC.create(2, "ob1qa", "ob1qb", 1000, pair.hash, 500);
    try htlc.activate();

    var bad_preimage: [32]u8 = pair.preimage;
    bad_preimage[0] ^= 0xFF; // corrupt
    try testing.expectError(error.InvalidPreimage, htlc.claim(bad_preimage));
}

test "HTLC — refund after timeout" {
    const pair = HTLC.generatePreimage();
    var htlc = HTLC.create(3, "ob1qa", "ob1qb", 2000, pair.hash, 100);
    try htlc.activate();

    // Too early
    try testing.expectError(error.HTLCNotExpired, htlc.refund(50));
    // At timeout
    try htlc.refund(100);
    try testing.expectEqual(HTLCState.refunded, htlc.state);
}

test "HTLC — expiry detection" {
    const pair = HTLC.generatePreimage();
    var htlc = HTLC.create(4, "ob1qa", "ob1qb", 3000, pair.hash, 200);
    try htlc.activate();

    htlc.checkExpiry(150); // not yet
    try testing.expectEqual(HTLCState.active, htlc.state);

    htlc.checkExpiry(200); // now expired
    try testing.expectEqual(HTLCState.expired, htlc.state);
}

test "HTLCRegistry — full lifecycle" {
    var reg = HTLCRegistry.init(testing.allocator);
    defer reg.deinit();

    const pair = HTLC.generatePreimage();
    const id = try reg.createHTLC("ob1qalice", "ob1qbob", 10000, pair.hash, 500);

    try reg.activateHTLC(id);
    try testing.expectEqual(@as(u32, 1), reg.activeCount());

    try reg.claimHTLC(id, pair.preimage);
    try testing.expectEqual(@as(u32, 0), reg.activeCount());

    const htlc = reg.getHTLC(id).?;
    try testing.expectEqual(HTLCState.claimed, htlc.state);
}

test "HTLCRegistry — expire all" {
    var reg = HTLCRegistry.init(testing.allocator);
    defer reg.deinit();

    const p1 = HTLC.generatePreimage();
    const p2 = HTLC.generatePreimage();
    const id1 = try reg.createHTLC("ob1qa", "ob1qb", 1000, p1.hash, 100);
    const id2 = try reg.createHTLC("ob1qa", "ob1qc", 2000, p2.hash, 200);

    try reg.activateHTLC(id1);
    try reg.activateHTLC(id2);
    try testing.expectEqual(@as(u32, 2), reg.activeCount());

    // Expire at height 150 — only id1 expires
    const expired = reg.expireAll(150);
    try testing.expectEqual(@as(u32, 1), expired);
    try testing.expectEqual(@as(u32, 1), reg.activeCount());
}
