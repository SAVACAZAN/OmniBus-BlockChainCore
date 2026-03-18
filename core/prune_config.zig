const std = @import("std");

/// Pruning configuration for blockchain size management
pub const PruneConfig = struct {
    /// Maximum number of blocks to keep in memory/disk
    max_blocks_to_keep: u32 = 10000,

    /// Enable automatic pruning on each block
    auto_prune_enabled: bool = true,

    /// Prune when chain reaches this threshold
    prune_threshold: u32 = 11000,

    /// Keep last N days of blocks
    keep_days: u32 = 30,

    /// Enable archival of pruned blocks
    archive_enabled: bool = false,

    /// Archive destination (S3 bucket, IPFS, etc)
    archive_path: []const u8 = "",

    /// Compress archived blocks
    compress_archived: bool = true,

    /// Keep full transaction data or just state
    keep_full_history: bool = false,

    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) PruneConfig {
        return PruneConfig{
            .allocator = allocator,
        };
    }

    /// Custom configuration
    pub fn initCustom(
        allocator: std.mem.Allocator,
        max_blocks: u32,
        keep_days: u32,
        archive_enabled: bool,
    ) PruneConfig {
        return PruneConfig{
            .max_blocks_to_keep = max_blocks,
            .keep_days = keep_days,
            .archive_enabled = archive_enabled,
            .auto_prune_enabled = true,
            .allocator = allocator,
        };
    }

    /// Get estimated storage size based on config
    pub fn estimateStorageSize(self: *const PruneConfig) u64 {
        // Rough estimate: ~5 MB per 100 blocks with compression
        return (self.max_blocks_to_keep / 100) * 5 * 1024 * 1024;
    }

    /// Validate configuration
    pub fn validate(self: *const PruneConfig) !void {
        if (self.max_blocks_to_keep == 0) {
            return error.InvalidMaxBlocks;
        }

        if (self.prune_threshold < self.max_blocks_to_keep) {
            return error.InvalidThreshold;
        }

        if (self.archive_enabled and self.archive_path.len == 0) {
            return error.MissingArchivePath;
        }
    }
};

/// Pruning statistics
pub const PruneStats = struct {
    blocks_pruned: u32 = 0,
    blocks_archived: u32 = 0,
    blocks_remaining: u32 = 0,
    space_freed: u64 = 0,
    archive_size: u64 = 0,
    prune_count: u32 = 0,

    pub fn print(self: *const PruneStats) void {
        std.debug.print(
            \\[PRUNE] Statistics:
            \\  - Blocks pruned: {d}
            \\  - Blocks archived: {d}
            \\  - Blocks remaining: {d}
            \\  - Space freed: {d} MB
            \\  - Archive size: {d} MB
            \\  - Total prune operations: {d}
            \\
        , .{
            self.blocks_pruned,
            self.blocks_archived,
            self.blocks_remaining,
            self.space_freed / (1024 * 1024),
            self.archive_size / (1024 * 1024),
            self.prune_count,
        });
    }
};

/// Pruning strategy enum
pub const PruneStrategy = enum {
    /// Keep last N blocks (FIFO)
    keep_recent,

    /// Keep blocks from last N days
    keep_recent_days,

    /// Keep blocks after checkpoint
    keep_after_checkpoint,

    /// Custom predicate (advanced)
    custom,
};

/// Block retention policy
pub const RetentionPolicy = struct {
    strategy: PruneStrategy,
    keep_count: u32 = 10000,
    keep_days: u32 = 30,
    checkpoint_height: u32 = 0,

    pub fn init() RetentionPolicy {
        return RetentionPolicy{
            .strategy = PruneStrategy.keep_recent,
            .keep_count = 10000,
        };
    }

    pub fn initByDays(days: u32) RetentionPolicy {
        return RetentionPolicy{
            .strategy = PruneStrategy.keep_recent_days,
            .keep_days = days,
        };
    }

    pub fn initByCheckpoint(height: u32) RetentionPolicy {
        return RetentionPolicy{
            .strategy = PruneStrategy.keep_after_checkpoint,
            .checkpoint_height = height,
        };
    }

    pub fn shouldKeepBlock(self: *const RetentionPolicy, block_height: u32, total_blocks: u32) bool {
        return switch (self.strategy) {
            PruneStrategy.keep_recent => {
                // Keep last N blocks
                block_height > (total_blocks - self.keep_count)
            },
            PruneStrategy.keep_recent_days => {
                // TODO: Implement time-based retention
                true  // Placeholder
            },
            PruneStrategy.keep_after_checkpoint => {
                // Keep blocks after checkpoint
                block_height >= self.checkpoint_height
            },
            PruneStrategy.custom => {
                // Custom logic
                true
            },
        };
    }
};

// Tests
const testing = std.testing;

test "prune config initialization" {
    var config = PruneConfig.init(testing.allocator);

    try testing.expectEqual(config.max_blocks_to_keep, 10000);
    try testing.expect(config.auto_prune_enabled);
}

test "prune config custom" {
    var config = PruneConfig.initCustom(testing.allocator, 5000, 14, true);

    try testing.expectEqual(config.max_blocks_to_keep, 5000);
    try testing.expectEqual(config.keep_days, 14);
    try testing.expect(config.archive_enabled);
}

test "estimate storage size" {
    var config = PruneConfig.init(testing.allocator);
    const size = config.estimateStorageSize();

    // 10000 blocks = ~500 MB
    try testing.expect(size > 0);
}

test "retention policy keep recent" {
    var policy = RetentionPolicy.init();

    // Last block should be kept
    try testing.expect(policy.shouldKeepBlock(9999, 10000));

    // Old block should not be kept
    try testing.expect(!policy.shouldKeepBlock(0, 10000));
}

test "retention policy by checkpoint" {
    var policy = RetentionPolicy.initByCheckpoint(5000);

    // Blocks after checkpoint should be kept
    try testing.expect(policy.shouldKeepBlock(5001, 10000));

    // Blocks before checkpoint should not be kept
    try testing.expect(!policy.shouldKeepBlock(4999, 10000));
}

test "prune stats" {
    var stats = PruneStats{
        .blocks_pruned = 1000,
        .blocks_archived = 800,
        .blocks_remaining = 9000,
        .space_freed = 500 * 1024 * 1024,  // 500 MB
    };

    try testing.expectEqual(stats.blocks_pruned, 1000);
    try testing.expectEqual(stats.blocks_remaining, 9000);
}
