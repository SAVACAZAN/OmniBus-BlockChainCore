const std = @import("std");
const transaction_mod = @import("transaction.zig");

pub const Transaction = transaction_mod.Transaction;

/// Sub-block - arrives every 0.1 seconds
/// 10 sub-blocks = 1 main block (1 second)
pub const SubBlock = struct {
    sub_id: u8,                    // 0-9 (position within main block)
    block_number: u32,             // Parent block number
    timestamp: i64,                // Unix timestamp (0.1s precision)
    transactions: std.ArrayList(Transaction),
    merkle_root: [32]u8,           // SHA-256 hash of transactions
    shard_id: u8,                  // 0-6 (which validator/miner processes)
    miner_id: []const u8,          // Which miner created this sub-block
    nonce: u64,                    // Proof-of-work nonce
    hash: [32]u8,                  // Sub-block hash

    pub fn init(allocator: std.mem.Allocator, sub_id: u8, block_number: u32, shard_id: u8, miner_id: []const u8) SubBlock {
        return SubBlock{
            .sub_id = sub_id,
            .block_number = block_number,
            .timestamp = std.time.timestamp(),
            .transactions = std.ArrayList(Transaction).init(allocator),
            .merkle_root = undefined,
            .shard_id = shard_id,
            .miner_id = miner_id,
            .nonce = 0,
            .hash = undefined,
        };
    }

    pub fn addTransaction(self: *SubBlock, tx: Transaction) !void {
        try self.transactions.append(tx);
    }

    pub fn calculateMerkleRoot(self: *SubBlock) ![32]u8 {
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});

        for (self.transactions.items) |tx| {
            hasher.update(tx.hash);
        }

        var root: [32]u8 = undefined;
        hasher.final(&root);
        return root;
    }

    pub fn calculateHash(self: *SubBlock) ![32]u8 {
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});

        // Hash sub-block header
        var buffer: [512]u8 = undefined;
        const str = try std.fmt.bufPrint(&buffer, "{d}:{d}:{d}:{d}:{d}", .{
            self.sub_id,
            self.block_number,
            self.timestamp,
            self.shard_id,
            self.nonce,
        });

        hasher.update(str);
        hasher.update(&self.merkle_root);

        var hash: [32]u8 = undefined;
        hasher.final(&hash);
        return hash;
    }

    pub fn isValid(self: *const SubBlock) bool {
        // Validate sub-block
        if (self.sub_id > 9) return false;  // 0-9 only
        if (self.transactions.items.len == 0) return true;  // Empty sub-blocks ok

        // All transactions must be valid
        for (self.transactions.items) |tx| {
            if (!tx.isValid()) return false;
        }

        return true;
    }

    pub fn getTransactionCount(self: *const SubBlock) u32 {
        return @intCast(self.transactions.items.len);
    }

    pub fn deinit(self: *SubBlock) void {
        self.transactions.deinit();
    }
};

/// Sub-block pool - pending sub-blocks waiting to form main block
pub const SubBlockPool = struct {
    allocator: std.mem.Allocator,
    sub_blocks: std.ArrayList(SubBlock),
    block_number: u32,

    pub fn init(allocator: std.mem.Allocator, block_number: u32) SubBlockPool {
        return SubBlockPool{
            .allocator = allocator,
            .sub_blocks = std.ArrayList(SubBlock).init(allocator),
            .block_number = block_number,
        };
    }

    pub fn addSubBlock(self: *SubBlockPool, sub_block: SubBlock) !void {
        if (self.sub_blocks.items.len >= 10) {
            return error.PoolFull;
        }

        try self.sub_blocks.append(sub_block);
    }

    pub fn isFull(self: *const SubBlockPool) bool {
        return self.sub_blocks.items.len == 10;
    }

    pub fn getSubBlocks(self: *SubBlockPool) []SubBlock {
        return self.sub_blocks.items;
    }

    pub fn clear(self: *SubBlockPool) void {
        for (self.sub_blocks.items) |*sub| {
            sub.deinit();
        }
        self.sub_blocks.clearRetainingCapacity();
    }

    pub fn deinit(self: *SubBlockPool) void {
        self.clear();
        self.sub_blocks.deinit();
    }
};

// Tests
const testing = std.testing;

test "sub-block initialization" {
    var sub = SubBlock.init(testing.allocator, 0, 100, 0, "miner-1");
    defer sub.deinit();

    try testing.expectEqual(sub.sub_id, 0);
    try testing.expectEqual(sub.block_number, 100);
    try testing.expectEqual(sub.shard_id, 0);
    try testing.expect(sub.isValid());
}

test "sub-block pool" {
    var pool = SubBlockPool.init(testing.allocator, 100);
    defer pool.deinit();

    var sub1 = SubBlock.init(testing.allocator, 0, 100, 0, "miner-1");
    try pool.addSubBlock(sub1);

    try testing.expectEqual(pool.sub_blocks.items.len, 1);
    try testing.expect(!pool.isFull());

    // Add 9 more
    for (1..10) |i| {
        var sub = SubBlock.init(testing.allocator, @intCast(i), 100, @intCast(i % 7), "miner-1");
        try pool.addSubBlock(sub);
    }

    try testing.expect(pool.isFull());
}
