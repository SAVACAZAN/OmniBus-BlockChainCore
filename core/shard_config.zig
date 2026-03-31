const std = @import("std");
const sub_block_mod = @import("sub_block.zig");

pub const SubBlock = sub_block_mod.SubBlock;

/// Shard configuration for distributed sub-block processing
pub const ShardConfig = struct {
    num_shards: u8 = 7,              // 7 validators/miners
    current_node_shard: u8,          // This node's shard ID (0-6)
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, current_node_shard: u8) !ShardConfig {
        if (current_node_shard >= 7) {
            return error.InvalidShardId;
        }

        return ShardConfig{
            .num_shards = 7,
            .current_node_shard = current_node_shard,
            .allocator = allocator,
        };
    }

    /// Calculate which shard should process a sub-block
    pub fn getShardForSubBlock(self: *const ShardConfig, sub_id: u8) u8 {
        return sub_id % self.num_shards;
    }

    /// Check if this node should process the sub-block
    pub fn shouldProcessSubBlock(self: *const ShardConfig, sub_id: u8) bool {
        return self.getShardForSubBlock(sub_id) == self.current_node_shard;
    }

    /// Get all sub-block IDs this shard processes
    pub fn getSubBlocksForShard(self: *const ShardConfig, allocator: std.mem.Allocator) ![]u8 {
        var sub_blocks = std.array_list.Managed(u8).init(allocator);

        for (0..10) |i| {
            const sub_id: u8 = @intCast(i);
            if (self.getShardForSubBlock(sub_id) == self.current_node_shard) {
                try sub_blocks.append(sub_id);
            }
        }

        return sub_blocks.items;
    }

    /// Get shard distribution info
    pub fn getDistribution(self: *const ShardConfig, allocator: std.mem.Allocator) ![7]ShardInfo {
        _ = allocator;
        var distribution: [7]ShardInfo = undefined;

        for (0..self.num_shards) |shard_id| {
            var count: u8 = 0;
            var sub_ids: [10]u8 = undefined;

            for (0..10) |i| {
                const sub_id: u8 = @intCast(i);
                if (self.getShardForSubBlock(sub_id) == shard_id) {
                    sub_ids[count] = sub_id;
                    count += 1;
                }
            }

            distribution[shard_id] = ShardInfo{
                .shard_id = @intCast(shard_id),
                .sub_block_count = count,
                .sub_block_ids = sub_ids[0..count],
            };
        }

        return distribution;
    }
};

/// Information about a single shard
pub const ShardInfo = struct {
    shard_id: u8,
    sub_block_count: u8,
    sub_block_ids: []u8,
};

/// Shard assignment validator
pub const ShardValidator = struct {
    config: ShardConfig,
    processed_sub_blocks: std.array_list.Managed(u8),

    pub fn init(config: ShardConfig) ShardValidator {
        return ShardValidator{
            .config = config,
            .processed_sub_blocks = std.array_list.Managed(u8).init(config.allocator),
        };
    }

    /// Validate that sub-block was processed by correct shard
    pub fn validateSubBlockShard(self: *const ShardValidator, sub: *const SubBlock) !bool {
        const expected_shard = self.config.getShardForSubBlock(sub.sub_id);
        if (sub.shard_id != expected_shard) {
            return error.IncorrectShard;
        }
        return true;
    }

    /// Track processed sub-blocks for this node's shard
    pub fn recordProcessed(self: *ShardValidator, sub_id: u8) !void {
        if (!self.config.shouldProcessSubBlock(sub_id)) {
            return error.NotMyShardSubBlock;
        }

        try self.processed_sub_blocks.append(sub_id);
    }

    /// Check if all sub-blocks for this shard in a block have been processed
    pub fn blockComplete(self: *const ShardValidator) bool {
        var count: u8 = 0;

        for (0..10) |i| {
            const sub_id: u8 = @intCast(i);
            if (self.config.shouldProcessSubBlock(sub_id)) {
                count += 1;
            }
        }

        return self.processed_sub_blocks.items.len == count;
    }

    /// Reset for next block
    pub fn reset(self: *ShardValidator) void {
        self.processed_sub_blocks.clearRetainingCapacity();
    }

    pub fn deinit(self: *ShardValidator) void {
        self.processed_sub_blocks.deinit();
    }
};

// Tests
const testing = std.testing;

test "shard assignment" {
    const config = try ShardConfig.init(testing.allocator, 0);

    // Sub-block 0 → shard 0
    try testing.expectEqual(config.getShardForSubBlock(0), 0);

    // Sub-block 1 → shard 1
    try testing.expectEqual(config.getShardForSubBlock(1), 1);

    // Sub-block 7 → shard 0 (7 % 7 = 0)
    try testing.expectEqual(config.getShardForSubBlock(7), 0);

    // Sub-block 9 → shard 2 (9 % 7 = 2)
    try testing.expectEqual(config.getShardForSubBlock(9), 2);
}

test "node processes correct shard" {
    const config = try ShardConfig.init(testing.allocator, 0);

    // Node 0 should process sub-blocks 0, 7
    try testing.expect(config.shouldProcessSubBlock(0));
    try testing.expect(config.shouldProcessSubBlock(7));

    // Node 0 should NOT process sub-blocks 1, 2, 3, etc.
    try testing.expect(!config.shouldProcessSubBlock(1));
    try testing.expect(!config.shouldProcessSubBlock(2));
}

test "distribution" {
    const config = try ShardConfig.init(testing.allocator, 0);
    const dist = try config.getDistribution(testing.allocator);

    // Total should be 10 sub-blocks distributed across 7 shards
    var total: u32 = 0;
    for (dist) |shard| {
        total += shard.sub_block_count;
    }

    try testing.expectEqual(total, 10);
}

test "shard validator" {
    const config = try ShardConfig.init(testing.allocator, 0);
    var validator = ShardValidator.init(config);
    defer validator.deinit();

    try validator.recordProcessed(0);
    try validator.recordProcessed(7);

    try testing.expectEqual(validator.processed_sub_blocks.items.len, 2);
}
