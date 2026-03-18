const std = @import("std");

/// Mining Pool - Coordinates multiple miners
pub const MiningPool = struct {
    pool_id: []const u8,
    miners: std.ArrayList(Miner),
    total_hashrate: u64,
    blocks_found: u64,
    pool_reward_address: []const u8,
    allocator: std.mem.Allocator,

    pub const Miner = struct {
        miner_id: []const u8,
        address: []const u8,
        hashrate: u64,
        shares: u64,
        last_share_time: i64,
        status: MinerStatus,
    };

    pub const MinerStatus = enum {
        offline,
        idle,
        mining,
        submitted_share,
    };

    pub fn init(pool_id: []const u8, reward_address: []const u8, allocator: std.mem.Allocator) MiningPool {
        return MiningPool{
            .pool_id = pool_id,
            .miners = std.ArrayList(Miner).init(allocator),
            .total_hashrate = 0,
            .blocks_found = 0,
            .pool_reward_address = reward_address,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *MiningPool) void {
        self.miners.deinit();
    }

    /// Add miner to pool
    pub fn addMiner(self: *MiningPool, miner_id: []const u8, address: []const u8, hashrate: u64) !void {
        const miner = Miner{
            .miner_id = miner_id,
            .address = address,
            .hashrate = hashrate,
            .shares = 0,
            .last_share_time = std.time.timestamp(),
            .status = MinerStatus.idle,
        };

        try self.miners.append(miner);
        self.total_hashrate += hashrate;

        std.debug.print("[POOL] Miner {s} joined pool. Hashrate: {d} H/s\n", .{ miner_id, hashrate });
    }

    /// Update miner status
    pub fn updateMinerStatus(self: *MiningPool, miner_id: []const u8, status: MinerStatus) !void {
        for (self.miners.items) |*miner| {
            if (std.mem.eql(u8, miner.miner_id, miner_id)) {
                miner.status = status;
                miner.last_share_time = std.time.timestamp();
                return;
            }
        }
        return error.MinerNotFound;
    }

    /// Record share from miner
    pub fn recordShare(self: *MiningPool, miner_id: []const u8) !void {
        for (self.miners.items) |*miner| {
            if (std.mem.eql(u8, miner.miner_id, miner_id)) {
                miner.shares += 1;
                miner.status = MinerStatus.submitted_share;
                miner.last_share_time = std.time.timestamp();
                return;
            }
        }
        return error.MinerNotFound;
    }

    /// Record block found
    pub fn recordBlockFound(self: *MiningPool) void {
        self.blocks_found += 1;
        std.debug.print("[POOL] Block found! Total: {d}\n", .{self.blocks_found});
    }

    /// Get miner count
    pub fn getMinerCount(self: *const MiningPool) usize {
        return self.miners.items.len;
    }

    /// Get total hashrate
    pub fn getTotalHashrate(self: *const MiningPool) u64 {
        return self.total_hashrate;
    }

    /// Get pool statistics
    pub fn getStats(self: *const MiningPool) PoolStats {
        var active_miners: u32 = 0;

        for (self.miners.items) |miner| {
            if (miner.status != MinerStatus.offline) {
                active_miners += 1;
            }
        }

        return PoolStats{
            .total_miners = self.miners.items.len,
            .active_miners = active_miners,
            .total_hashrate = self.total_hashrate,
            .blocks_found = self.blocks_found,
        };
    }

    /// Remove inactive miners (no share for 300s)
    pub fn removeInactiveMiners(self: *MiningPool) void {
        const now = std.time.timestamp();
        const timeout: i64 = 300; // 5 minutes

        var i: usize = 0;
        while (i < self.miners.items.len) {
            if (now - self.miners.items[i].last_share_time > timeout) {
                const removed = self.miners.swapRemove(i);
                self.total_hashrate -|= removed.hashrate;
                std.debug.print("[POOL] Removed inactive miner: {s}\n", .{removed.miner_id});
            } else {
                i += 1;
            }
        }
    }

    /// Get miner reward share (proportional to hashrate)
    pub fn getMinerRewardShare(self: *const MiningPool, miner_id: []const u8, block_reward: u64) !u64 {
        for (self.miners.items) |miner| {
            if (std.mem.eql(u8, miner.miner_id, miner_id)) {
                if (self.total_hashrate == 0) return 0;
                return (miner.hashrate * block_reward) / self.total_hashrate;
            }
        }
        return error.MinerNotFound;
    }
};

pub const PoolStats = struct {
    total_miners: usize,
    active_miners: u32,
    total_hashrate: u64,
    blocks_found: u64,
};

// Tests
const testing = std.testing;

test "mining pool initialization" {
    var pool = MiningPool.init("omnibus-pool", "ob_omni_pool123", testing.allocator);
    defer pool.deinit();

    try testing.expectEqual(pool.getMinerCount(), 0);
}

test "add miners to pool" {
    var pool = MiningPool.init("omnibus-pool", "ob_omni_pool123", testing.allocator);
    defer pool.deinit();

    try pool.addMiner("miner-1", "ob_omni_1", 1000);
    try pool.addMiner("miner-2", "ob_k1_2", 1500);
    try pool.addMiner("miner-3", "ob_f5_3", 2000);

    try testing.expectEqual(pool.getMinerCount(), 3);
    try testing.expectEqual(pool.getTotalHashrate(), 4500);
}

test "record shares" {
    var pool = MiningPool.init("omnibus-pool", "ob_omni_pool123", testing.allocator);
    defer pool.deinit();

    try pool.addMiner("miner-1", "ob_omni_1", 1000);
    try pool.recordShare("miner-1");
    try pool.recordShare("miner-1");

    try testing.expectEqual(pool.miners.items[0].shares, 2);
}

test "pool statistics" {
    var pool = MiningPool.init("omnibus-pool", "ob_omni_pool123", testing.allocator);
    defer pool.deinit();

    try pool.addMiner("miner-1", "ob_omni_1", 1000);
    try pool.addMiner("miner-2", "ob_k1_2", 1500);

    const stats = pool.getStats();
    try testing.expectEqual(stats.total_miners, 2);
    try testing.expectEqual(stats.total_hashrate, 2500);
}

test "reward distribution" {
    var pool = MiningPool.init("omnibus-pool", "ob_omni_pool123", testing.allocator);
    defer pool.deinit();

    try pool.addMiner("miner-1", "ob_omni_1", 1000);
    try pool.addMiner("miner-2", "ob_k1_2", 1000);

    const block_reward = 50_000_000_000; // 50 OMNI in SAT
    const reward1 = try pool.getMinerRewardShare("miner-1", block_reward);
    const reward2 = try pool.getMinerRewardShare("miner-2", block_reward);

    try testing.expectEqual(reward1, block_reward / 2);
    try testing.expectEqual(reward2, block_reward / 2);
}
