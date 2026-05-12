/// reputation_manager.zig — global manager pentru ReputationCups per address.
///
/// Hashmap address(string) → ReputationCups. Backed by allocator owned by
/// main.zig. Thread-safety: mutex protejeaza access concurrent (mining loop +
/// RPC handlers).

const std = @import("std");
const rep_mod = @import("reputation.zig");

pub const ReputationCups = rep_mod.ReputationCups;
pub const Tier = rep_mod.Tier;

pub const ReputationManager = struct {
    allocator: std.mem.Allocator,
    map: std.StringHashMap(ReputationCups),
    mutex: std.Thread.Mutex,

    /// Block height when manager was first started — used to compute "days inactive".
    started_at_block: u64,

    pub fn init(allocator: std.mem.Allocator) ReputationManager {
        return .{
            .allocator = allocator,
            .map = std.StringHashMap(ReputationCups).init(allocator),
            .mutex = .{},
            .started_at_block = 0,
        };
    }

    pub fn deinit(self: *ReputationManager) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        var it = self.map.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.map.deinit();
    }

    /// Get or create cups for an address. Returns pointer (caller holds mutex
    /// implicitly via wrapper functions; do NOT use this directly).
    fn getOrCreatePtr(self: *ReputationManager, address: []const u8) !*ReputationCups {
        const gop = try self.map.getOrPut(address);
        if (!gop.found_existing) {
            // Dupe key (HashMap nu deține string-ul de altfel).
            gop.key_ptr.* = try self.allocator.dupe(u8, address);
            gop.value_ptr.* = ReputationCups{};
        }
        return gop.value_ptr;
    }

    /// Public read — copy snapshot pentru RPC.
    pub fn snapshot(self: *ReputationManager, address: []const u8) ?ReputationCups {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.map.get(address);
    }

    /// Numar adrese cu reputation > 0.
    pub fn count(self: *ReputationManager) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.map.count();
    }

    // ── Credit wrappers — toate apelate din mining loop / RPC handlers ──────

    pub fn creditMinedBlock(self: *ReputationManager, address: []const u8, block_height: u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const cups = self.getOrCreatePtr(address) catch return;
        cups.creditMinedBlock(block_height);
    }

    pub fn creditPoUWReport(self: *ReputationManager, address: []const u8, block_height: u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const cups = self.getOrCreatePtr(address) catch return;
        cups.creditPoUWReport(block_height);
    }

    pub fn creditOraclePush(self: *ReputationManager, address: []const u8, block_height: u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const cups = self.getOrCreatePtr(address) catch return;
        cups.creditOraclePush(block_height);
    }

    pub fn creditAgentDecision(self: *ReputationManager, address: []const u8, block_height: u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const cups = self.getOrCreatePtr(address) catch return;
        cups.creditAgentDecision(block_height);
    }

    pub fn creditStakePerBlock(self: *ReputationManager, address: []const u8, omni_staked: u64, block_height: u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const cups = self.getOrCreatePtr(address) catch return;
        cups.creditStakePerBlock(omni_staked, block_height);
    }

    pub fn creditHoldPerBlock(self: *ReputationManager, address: []const u8, omni_held: u64, block_height: u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const cups = self.getOrCreatePtr(address) catch return;
        cups.creditHoldPerBlock(omni_held, block_height);
    }

    /// Crediteaza o zi de VACATION daca trecere zi-block. Caller decide cand.
    pub fn creditVacationDay(self: *ReputationManager, address: []const u8, total_days_active: u64, block_height: u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const cups = self.getOrCreatePtr(address) catch return;
        cups.creditVacationDay(total_days_active, block_height);
    }

    /// LOVE credit — uptime in minute (called from mining loop every 6 blocks).
    pub fn creditUptimeMinutes(self: *ReputationManager, address: []const u8, minutes: u32, block_height: u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const cups = self.getOrCreatePtr(address) catch return;
        cups.creditUptimeMinutes(minutes, block_height);
    }

    /// LOVE bonus pentru o zi consecutiva online (called daily).
    pub fn creditDailyStreak(self: *ReputationManager, address: []const u8, block_height: u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const cups = self.getOrCreatePtr(address) catch return;
        cups.creditDailyStreak(block_height);
    }

    pub fn applyViolation(self: *ReputationManager, address: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const cups = self.getOrCreatePtr(address) catch return;
        cups.applyViolation();
    }

    /// Backfill o adresa cu istoric (pentru retro la deploy).
    pub fn backfill(
        self: *ReputationManager,
        address: []const u8,
        n_blocks_mined: u64,
        first_block_seen: u64,
        current_block: u64,
    ) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const cups = self.getOrCreatePtr(address) catch return;
        cups.backfillFromHistory(n_blocks_mined, first_block_seen, current_block);
    }

    /// Iterare pentru export (rich list reputation).
    pub fn iterate(self: *ReputationManager) std.StringHashMap(ReputationCups).Iterator {
        return self.map.iterator();
    }

    pub fn lock(self: *ReputationManager) void {
        self.mutex.lock();
    }
    pub fn unlock(self: *ReputationManager) void {
        self.mutex.unlock();
    }
};

// ── Tests ────────────────────────────────────────────────────────────────────
const testing = std.testing;

test "manager: get-or-create + credit + snapshot" {
    var mgr = ReputationManager.init(testing.allocator);
    defer mgr.deinit();
    mgr.creditMinedBlock("ob1q_test_addr", 100);
    mgr.creditMinedBlock("ob1q_test_addr", 101);
    mgr.creditMinedBlock("ob1q_test_addr", 102);
    const snap = mgr.snapshot("ob1q_test_addr").?;
    try testing.expectEqual(@as(u64, 3), snap.total_blocks_mined);
    try testing.expectEqual(@as(u32, 3), snap.food_stored); // 3 × 1
}

test "manager: backfill" {
    var mgr = ReputationManager.init(testing.allocator);
    defer mgr.deinit();
    mgr.backfill("ob1q_kimi", 2090, 1, 32850);
    const snap = mgr.snapshot("ob1q_kimi").?;
    try testing.expectEqual(@as(u64, 2090), snap.total_blocks_mined);
    try testing.expectEqual(@as(u32, 2090), snap.food_stored);
}

test "manager: count + iterate" {
    var mgr = ReputationManager.init(testing.allocator);
    defer mgr.deinit();
    mgr.creditMinedBlock("addr_a", 1);
    mgr.creditMinedBlock("addr_b", 2);
    mgr.creditMinedBlock("addr_c", 3);
    try testing.expectEqual(@as(usize, 3), mgr.count());
}
