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

// ─── On-chain HTLC entry (Phase 2F.2 — TX 0x30/0x31/0x32) ───────────────────
//
// Mirrors the `HTLC` struct above but is keyed by a 32-byte deterministic
// id (sha256 of the htlc_init tx hash) and owns its address strings so it
// survives across mempool / restart. Used by:
//   - blockchain.applyBlock for state transitions on .htlc_init/.htlc_claim/.htlc_refund
//   - htlc_persist.zig for save/load to data/<chain>/htlc_registry.bin
//   - rpc_server.zig for htlc_get / htlc_listByAddress / htlc_listPending

/// Maximum address length stored in an HtlcEntry (matches DnsRegistry MAX_ADDR_LEN).
pub const HTLC_MAX_ADDR_LEN: usize = 64;

/// On-chain HTLC entry — fixed-size, no heap allocation, persistable.
pub const HtlcEntry = struct {
    /// Deterministic 32-byte id = sha256(init_tx_hash_bytes).
    id: [32]u8,
    /// Sender address (the party who locked funds).
    sender: [HTLC_MAX_ADDR_LEN]u8 = [_]u8{0} ** HTLC_MAX_ADDR_LEN,
    sender_len: u8 = 0,
    /// Recipient address (the only one who can claim with the preimage).
    recipient: [HTLC_MAX_ADDR_LEN]u8 = [_]u8{0} ** HTLC_MAX_ADDR_LEN,
    recipient_len: u8 = 0,
    /// Amount locked (SAT).
    amount_sat: u64,
    /// SHA256 of the preimage. Recipient must reveal preimage P with
    /// sha256(P) == hash_lock to claim.
    hash_lock: [32]u8,
    /// Block height after which the sender can refund.
    timelock_block: u64,
    /// Block height at which this HTLC was registered (for indexing).
    init_block: u64 = 0,
    /// Tx hash (hex, 64 chars) of the htlc_init TX. Stored as fixed-size
    /// so the entry remains POD.
    init_tx_hash: [64]u8 = [_]u8{0} ** 64,
    init_tx_hash_len: u8 = 0,
    /// Lifecycle state.
    state: HTLCState = .active,
    /// Revealed preimage when state == .claimed; zero otherwise.
    preimage: [32]u8 = [_]u8{0} ** 32,
    /// True iff `preimage` holds a valid value.
    has_preimage: bool = false,

    pub fn senderSlice(self: *const HtlcEntry) []const u8 {
        return self.sender[0..self.sender_len];
    }
    pub fn recipientSlice(self: *const HtlcEntry) []const u8 {
        return self.recipient[0..self.recipient_len];
    }
    pub fn initTxHashSlice(self: *const HtlcEntry) []const u8 {
        return self.init_tx_hash[0..self.init_tx_hash_len];
    }
};

/// Compute the deterministic 32-byte HTLC id from the init TX hash.
/// Accepts the canonical hex representation (64 chars) used everywhere
/// in the chain layer; falls back to raw bytes if the input is 32 bytes.
pub fn computeHtlcId(init_tx_hash_hex: []const u8) [32]u8 {
    var out: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(init_tx_hash_hex, &out, .{});
    return out;
}

/// On-chain HTLC registry — fixed-capacity ring of entries keyed by 32-byte id.
///
/// Capacity is `MAX_HTLCS`. Beyond that, `addEntry` returns `error.RegistryFull`.
/// Entries are never deleted in-place: claim/refund flips `state` so the full
/// history is preserved (audit trail, restart replay, RPC listing).
pub const MAX_HTLCS: usize = 4096;

pub const HtlcOnChainRegistry = struct {
    entries: [MAX_HTLCS]HtlcEntry = undefined,
    entry_count: u32 = 0,

    pub fn init() HtlcOnChainRegistry {
        return HtlcOnChainRegistry{};
    }

    /// Find the index of an entry by its 32-byte id, or null if absent.
    pub fn indexOf(self: *const HtlcOnChainRegistry, id: [32]u8) ?u32 {
        var i: u32 = 0;
        while (i < self.entry_count) : (i += 1) {
            if (std.mem.eql(u8, &self.entries[i].id, &id)) return i;
        }
        return null;
    }

    pub fn get(self: *const HtlcOnChainRegistry, id: [32]u8) ?HtlcEntry {
        const idx = self.indexOf(id) orelse return null;
        return self.entries[idx];
    }

    pub fn getPtr(self: *HtlcOnChainRegistry, id: [32]u8) ?*HtlcEntry {
        const idx = self.indexOf(id) orelse return null;
        return &self.entries[idx];
    }

    /// Register a new HTLC (state .active) on htlc_init.
    /// Returns error.RegistryFull if at capacity, error.DuplicateHtlc if id already known.
    pub fn addEntry(self: *HtlcOnChainRegistry, e: HtlcEntry) !void {
        if (self.indexOf(e.id) != null) return error.DuplicateHtlc;
        if (self.entry_count >= MAX_HTLCS) return error.RegistryFull;
        self.entries[self.entry_count] = e;
        self.entry_count += 1;
    }

    /// Mark an HTLC as claimed and stash the preimage. Verifies sha256(preimage)==hash_lock.
    pub fn applyClaim(self: *HtlcOnChainRegistry, id: [32]u8, preimage: [32]u8) !void {
        const idx = self.indexOf(id) orelse return error.HtlcNotFound;
        const e = &self.entries[idx];
        if (e.state != .active) return error.HtlcNotActive;
        var h: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(&preimage, &h, .{});
        if (!std.mem.eql(u8, &h, &e.hash_lock)) return error.InvalidPreimage;
        e.preimage = preimage;
        e.has_preimage = true;
        e.state = .claimed;
    }

    /// Mark an HTLC as refunded. Caller has already verified current_height >= timelock.
    pub fn applyRefund(self: *HtlcOnChainRegistry, id: [32]u8, current_height: u64) !void {
        const idx = self.indexOf(id) orelse return error.HtlcNotFound;
        const e = &self.entries[idx];
        if (e.state != .active and e.state != .expired) return error.HtlcNotRefundable;
        if (current_height < e.timelock_block) return error.HtlcNotExpired;
        e.state = .refunded;
    }

    /// Walk all entries that involve `address` as sender OR recipient.
    /// Calls `cb(entry)` for each match. Caller decides ordering.
    pub fn forEachByAddress(
        self: *const HtlcOnChainRegistry,
        address: []const u8,
        ctx: anytype,
        comptime cb: fn (@TypeOf(ctx), *const HtlcEntry) void,
    ) void {
        var i: u32 = 0;
        while (i < self.entry_count) : (i += 1) {
            const e = &self.entries[i];
            if (std.mem.eql(u8, e.senderSlice(), address) or
                std.mem.eql(u8, e.recipientSlice(), address))
            {
                cb(ctx, e);
            }
        }
    }

    /// Count active HTLCs (state == .active).
    pub fn activeCount(self: *const HtlcOnChainRegistry) u32 {
        var n: u32 = 0;
        var i: u32 = 0;
        while (i < self.entry_count) : (i += 1) {
            if (self.entries[i].state == .active) n += 1;
        }
        return n;
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

test "HtlcOnChainRegistry — happy path roundtrip (init → claim)" {
    var reg = HtlcOnChainRegistry.init();
    const pair = HTLC.generatePreimage();
    const id = computeHtlcId("deadbeef" ** 8); // 64-char hex

    var e = HtlcEntry{
        .id = id,
        .amount_sat = 50_000,
        .hash_lock = pair.hash,
        .timelock_block = 200,
        .init_block = 10,
    };
    const sender = "ob1qsender0000000000000000000000000000000";
    const recipient = "ob1qrecipient00000000000000000000000000000";
    @memcpy(e.sender[0..sender.len], sender);
    e.sender_len = @intCast(sender.len);
    @memcpy(e.recipient[0..recipient.len], recipient);
    e.recipient_len = @intCast(recipient.len);
    try reg.addEntry(e);
    try testing.expectEqual(@as(u32, 1), reg.activeCount());

    // Wrong preimage rejected
    var bad = pair.preimage;
    bad[0] ^= 0xFF;
    try testing.expectError(error.InvalidPreimage, reg.applyClaim(id, bad));

    // Correct preimage claims
    try reg.applyClaim(id, pair.preimage);
    try testing.expectEqual(@as(u32, 0), reg.activeCount());
    const after = reg.get(id).?;
    try testing.expectEqual(HTLCState.claimed, after.state);
    try testing.expect(after.has_preimage);

    // Double-claim rejected
    try testing.expectError(error.HtlcNotActive, reg.applyClaim(id, pair.preimage));
}

test "HtlcOnChainRegistry — refund path requires timeout" {
    var reg = HtlcOnChainRegistry.init();
    const pair = HTLC.generatePreimage();
    const id = computeHtlcId("cafe" ** 16);
    var e = HtlcEntry{
        .id = id,
        .amount_sat = 1000,
        .hash_lock = pair.hash,
        .timelock_block = 100,
    };
    const a = "ob1qa00000000000000000000000000000000000";
    const b = "ob1qb00000000000000000000000000000000000";
    @memcpy(e.sender[0..a.len], a); e.sender_len = @intCast(a.len);
    @memcpy(e.recipient[0..b.len], b); e.recipient_len = @intCast(b.len);
    try reg.addEntry(e);

    try testing.expectError(error.HtlcNotExpired, reg.applyRefund(id, 50));
    try reg.applyRefund(id, 100);
    try testing.expectEqual(HTLCState.refunded, reg.get(id).?.state);
    // Double-refund rejected
    try testing.expectError(error.HtlcNotRefundable, reg.applyRefund(id, 200));
}

test "HtlcOnChainRegistry — duplicate id rejected" {
    var reg = HtlcOnChainRegistry.init();
    const pair = HTLC.generatePreimage();
    const id = computeHtlcId("11" ** 32);
    const e = HtlcEntry{
        .id = id, .amount_sat = 1, .hash_lock = pair.hash, .timelock_block = 1,
    };
    try reg.addEntry(e);
    try testing.expectError(error.DuplicateHtlc, reg.addEntry(e));
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
