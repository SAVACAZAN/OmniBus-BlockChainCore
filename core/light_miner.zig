const std = @import("std");
const array_list = std.array_list;

/// Lightweight miner instance (can run multiple on one machine)
pub const LightMiner = struct {
    miner_id: u32,                  // Unique miner ID (0-9 for 10 instances)
    instance_name: []const u8,      // "miner-1", "miner-2", etc
    hashrate: u64,                  // Hashes per second
    status: MinerStatus = .offline,
    blocks_mined: u32 = 0,
    shares_submitted: u32 = 0,
    shares_accepted: u32 = 0,
    last_share_time: i64 = 0,
    total_difficulty: u64 = 0,
    connection_time: i64 = 0,
    is_connected: bool = false,

    pub fn init(allocator: std.mem.Allocator, id: u32, hashrate: u64) !LightMiner {
        const name = try std.fmt.allocPrint(allocator, "light-miner-{d}", .{id});

        return LightMiner{
            .miner_id = id,
            .instance_name = name,
            .hashrate = hashrate,
            .status = .offline,
            .connection_time = std.time.timestamp(),
        };
    }

    pub fn deinit(self: *LightMiner, allocator: std.mem.Allocator) void {
        allocator.free(self.instance_name);
    }

    pub fn connect(self: *LightMiner) void {
        self.is_connected = true;
        self.status = .mining;
        self.connection_time = std.time.timestamp();
    }

    pub fn disconnect(self: *LightMiner) void {
        self.is_connected = false;
        self.status = .offline;
    }

    pub fn submitShare(self: *LightMiner, difficulty: u64) void {
        self.shares_submitted += 1;
        self.total_difficulty += difficulty;
        self.last_share_time = std.time.timestamp();

        // Accept share with 95% rate (simulate some rejects)
        if (self.shares_submitted % 20 != 0) {
            self.shares_accepted += 1;
        }
    }

    pub fn recordBlockMined(self: *LightMiner) void {
        self.blocks_mined += 1;
        self.status = .block_found;
    }

    pub fn getUptime(self: *const LightMiner) i64 {
        if (!self.is_connected) return 0;
        return std.time.timestamp() - self.connection_time;
    }

    pub fn getAcceptanceRate(self: *const LightMiner) f64 {
        if (self.shares_submitted == 0) return 0.0;
        return @as(f64, @floatFromInt(self.shares_accepted)) / @as(f64, @floatFromInt(self.shares_submitted));
    }

    pub fn getEffectiveHashrate(self: *const LightMiner) u64 {
        if (!self.is_connected) return 0;
        const uptime = self.getUptime();
        if (uptime == 0) return 0;

        // Effective rate = accepted shares * difficulty / time
        return if (self.shares_accepted > 0)
            (self.total_difficulty / @as(u64, @intCast(uptime)))
        else
            0;
    }

    pub fn print(self: *const LightMiner) void {
        std.debug.print(
            "[Miner {d}] {s} Status={s} Blocks={d} Shares={d}/{d} Uptime={d}s\n",
            .{
                self.miner_id,
                self.instance_name,
                @tagName(self.status),
                self.blocks_mined,
                self.shares_accepted,
                self.shares_submitted,
                self.getUptime(),
            },
        );
    }
};

pub const MinerStatus = enum {
    offline,
    connecting,
    mining,
    block_found,
    mining_error,
    shutdown,
};

/// Manager for multiple light miner instances
pub const MinerPool = struct {
    allocator: std.mem.Allocator,
    miners: std.array_list.Managed(LightMiner),
    total_hashrate: u64 = 0,
    pool_status: PoolStatus = .initializing,
    genesis_started: bool = false,
    min_miners_for_genesis: u32 = 3,  // Need at least 3 miners to start

    pub fn init(allocator: std.mem.Allocator) MinerPool {
        return MinerPool{
            .allocator = allocator,
            .miners = std.array_list.Managed(LightMiner).init(allocator),
        };
    }

    /// Add new miner to pool
    pub fn addMiner(self: *MinerPool, id: u32, hashrate: u64) !void {
        const miner = try LightMiner.init(self.allocator, id, hashrate);
        try self.miners.append(miner);
        self.total_hashrate += hashrate;

        // Update pool status when miners added
        if (self.miners.items.len >= self.min_miners_for_genesis) {
            self.pool_status = .ready_for_genesis;
        }
    }

    /// Connect miner by ID
    pub fn connectMiner(self: *MinerPool, miner_id: u32) bool {
        for (self.miners.items) |*miner| {
            if (miner.miner_id == miner_id) {
                miner.connect();
                return true;
            }
        }
        return false;
    }

    /// Get miner by ID
    pub fn getMiner(self: *const MinerPool, miner_id: u32) ?*const LightMiner {
        for (self.miners.items) |*miner| {
            if (miner.miner_id == miner_id) {
                return miner;
            }
        }
        return null;
    }

    /// Get connected miners count
    pub fn getConnectedCount(self: *const MinerPool) u32 {
        var count: u32 = 0;
        for (self.miners.items) |miner| {
            if (miner.is_connected) count += 1;
        }
        return count;
    }

    /// Check if ready for genesis
    pub fn isReadyForGenesis(self: *const MinerPool) bool {
        return self.getConnectedCount() >= self.min_miners_for_genesis;
    }

    /// Start genesis mining
    pub fn startGenesis(self: *MinerPool) !void {
        if (!self.isReadyForGenesis()) {
            return error.NotEnoughMiners;
        }

        self.genesis_started = true;
        self.pool_status = .genesis_mining;

        std.debug.print(
            "[GENESIS] Starting with {d} miners, {d} H/s total hashrate\n",
            .{ self.getConnectedCount(), self.total_hashrate },
        );
    }

    /// Submit share from miner
    pub fn submitShare(self: *MinerPool, miner_id: u32, difficulty: u64) bool {
        if (!self.genesis_started) return false;

        for (self.miners.items) |*miner| {
            if (miner.miner_id == miner_id) {
                miner.submitShare(difficulty);
                return true;
            }
        }
        return false;
    }

    /// Get pool statistics
    pub fn getStats(self: *const MinerPool) MinerPoolStats {
        var total_shares: u64 = 0;
        var total_accepted: u64 = 0;
        var total_blocks: u32 = 0;

        for (self.miners.items) |miner| {
            total_shares += miner.shares_submitted;
            total_accepted += miner.shares_accepted;
            total_blocks += miner.blocks_mined;
        }

        return MinerPoolStats{
            .connected_miners = self.getConnectedCount(),
            .total_miners = @intCast(self.miners.items.len),
            .total_hashrate = self.total_hashrate,
            .total_shares = total_shares,
            .total_accepted = total_accepted,
            .total_blocks = total_blocks,
            .status = self.pool_status,
            .genesis_started = self.genesis_started,
            .ready_for_genesis = self.isReadyForGenesis(),
        };
    }

    /// Print pool status
    pub fn printStatus(self: *const MinerPool) void {
        const stats = self.getStats();

        std.debug.print(
            \\[MINER POOL] Status:
            \\  - Miners: {d}/{d} connected
            \\  - Total hashrate: {d} H/s
            \\  - Status: {s}
            \\  - Genesis ready: {}
            \\
        , .{
            stats.connected_miners,
            stats.total_miners,
            stats.total_hashrate,
            @tagName(self.pool_status),
            stats.ready_for_genesis,
        });

        // Print each miner
        for (self.miners.items) |miner| {
            miner.print();
        }
    }

    pub fn deinit(self: *MinerPool) void {
        for (self.miners.items) |*m| m.deinit(self.allocator);
        self.miners.deinit();
    }
};

pub const PoolStatus = enum {
    initializing,
    waiting_for_miners,
    ready_for_genesis,
    genesis_mining,
    mining,
    pool_error,
    shutdown,
};

pub const MinerPoolStats = struct {
    connected_miners: u32,
    total_miners: u32,
    total_hashrate: u64,
    total_shares: u64,
    total_accepted: u64,
    total_blocks: u32,
    status: PoolStatus,
    genesis_started: bool,
    ready_for_genesis: bool,
};

// Tests
const testing = std.testing;

test "light miner creation" {
    const miner = try LightMiner.init(testing.allocator, 1, 5000);
    defer testing.allocator.free(miner.instance_name);

    try testing.expectEqual(miner.miner_id, 1);
    try testing.expectEqual(miner.hashrate, 5000);
    try testing.expect(!miner.is_connected);
}

test "light miner connect" {
    var miner = try LightMiner.init(testing.allocator, 1, 5000);
    defer testing.allocator.free(miner.instance_name);

    miner.connect();
    try testing.expect(miner.is_connected);
}

test "light miner share submission" {
    var miner = try LightMiner.init(testing.allocator, 1, 5000);
    defer testing.allocator.free(miner.instance_name);

    miner.submitShare(100);
    try testing.expectEqual(miner.shares_submitted, 1);
}

test "miner pool add miners" {
    var pool = MinerPool.init(testing.allocator);
    defer pool.deinit();

    try pool.addMiner(0, 1000);
    try pool.addMiner(1, 2000);
    try pool.addMiner(2, 3000);

    try testing.expectEqual(pool.miners.items.len, 3);
    try testing.expectEqual(pool.total_hashrate, 6000);
}

test "miner pool genesis ready" {
    var pool = MinerPool.init(testing.allocator);
    defer pool.deinit();

    try pool.addMiner(0, 1000);
    try pool.addMiner(1, 2000);

    try testing.expect(!pool.isReadyForGenesis());  // Need 3 min

    try pool.addMiner(2, 3000);
    try testing.expect(!pool.isReadyForGenesis());  // Not connected yet

    _ = pool.connectMiner(0);
    _ = pool.connectMiner(1);
    _ = pool.connectMiner(2);

    try testing.expect(pool.isReadyForGenesis());  // All connected
}

test "miner pool start genesis" {
    var pool = MinerPool.init(testing.allocator);
    defer pool.deinit();

    try pool.addMiner(0, 1000);
    try pool.addMiner(1, 2000);
    try pool.addMiner(2, 3000);

    _ = pool.connectMiner(0);
    _ = pool.connectMiner(1);
    _ = pool.connectMiner(2);

    try pool.startGenesis();
    try testing.expect(pool.genesis_started);
}
