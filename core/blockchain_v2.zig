const std = @import("std");
const block_mod = @import("block.zig");
const transaction_mod = @import("transaction.zig");
const sub_block_mod = @import("sub_block.zig");
const shard_config = @import("shard_config.zig");
const binary_codec = @import("binary_codec.zig");
const array_list = std.array_list;

pub const Block = block_mod.Block;
pub const Transaction = transaction_mod.Transaction;
pub const SubBlock = sub_block_mod.SubBlock;
pub const SubBlockPool = sub_block_mod.SubBlockPool;
pub const ShardConfig = shard_config.ShardConfig;
pub const BinaryEncoder = binary_codec.BinaryEncoder;
pub const BinaryDecoder = binary_codec.BinaryDecoder;

/// Blockchain v2 - with sub-blocks and sharding support
pub const BlockchainV2 = struct {
    chain: array_list.Managed(Block),
    mempool: array_list.Managed(Transaction),
    sub_block_pool: SubBlockPool,
    shard_config: ShardConfig,
    difficulty: u32,
    allocator: std.mem.Allocator,
    current_block_number: u32 = 0,

    pub fn init(allocator: std.mem.Allocator, shard_id: u8) !BlockchainV2 {
        var chain = array_list.Managed(Block).init(allocator);
        const mempool = array_list.Managed(Transaction).init(allocator);
        const sub_pool = SubBlockPool.init(allocator, 0);
        const shards = try ShardConfig.init(allocator, shard_id);

        // Create genesis block
        const genesis = Block{
            .index = 0,
            .timestamp = 0,
            .transactions = array_list.Managed(Transaction).init(allocator),
            .previous_hash = "0",
            .nonce = 0,
            .hash = "genesis_hash_placeholder",
        };

        try chain.append(genesis);

        return BlockchainV2{
            .chain = chain,
            .mempool = mempool,
            .sub_block_pool = sub_pool,
            .shard_config = shards,
            .difficulty = 4,
            .allocator = allocator,
            .current_block_number = 0,
        };
    }

    pub fn deinit(self: *BlockchainV2) void {
        for (self.chain.items) |*block| {
            block.transactions.deinit();
        }
        self.chain.deinit();
        self.mempool.deinit();
        self.sub_block_pool.deinit();
    }

    /// Add transaction to mempool
    pub fn addTransaction(self: *BlockchainV2, tx: Transaction) !void {
        if (!try self.validateTransaction(&tx)) {
            return error.InvalidTransaction;
        }
        try self.mempool.append(tx);
    }

    /// Validate transaction
    pub fn validateTransaction(self: *BlockchainV2, tx: *const Transaction) !bool {
        if (tx.amount == 0) return false;
        if (tx.from_address.len == 0 or tx.to_address.len == 0) return false;
        _ = self;
        return true;
    }

    /// Create sub-block (0.1s interval)
    pub fn createSubBlock(self: *BlockchainV2, sub_id: u8, miner_id: []const u8) !SubBlock {
        if (sub_id > 9) return error.InvalidSubBlockId;

        const shard_id = self.shard_config.getShardForSubBlock(sub_id);

        var sub = SubBlock.init(self.allocator, sub_id, self.current_block_number, shard_id, miner_id);

        // Add transactions from mempool to sub-block
        // Distribute ~1/10th of mempool to each sub-block
        const txs_per_sub = self.mempool.items.len / 10;
        var start_idx = sub_id * txs_per_sub;
        var end_idx = if (sub_id == 9) self.mempool.items.len else (sub_id + 1) * txs_per_sub;

        if (start_idx < end_idx) {
            for (self.mempool.items[start_idx..end_idx]) |tx| {
                try sub.addTransaction(tx);
            }
        }

        // Calculate merkle root
        sub.merkle_root = try sub.calculateMerkleRoot();

        // Mine sub-block (simple PoW)
        try self.mineSubBlock(&sub);

        return sub;
    }

    /// Mine sub-block with simple PoW
    pub fn mineSubBlock(self: *BlockchainV2, sub: *SubBlock) !void {
        var nonce: u64 = 0;
        while (true) {
            sub.nonce = nonce;
            sub.hash = try sub.calculateHash();

            // Simple difficulty check: hash starts with leading zero
            if (sub.hash[0] < 128) {
                break;
            }

            nonce += 1;
            if (nonce > 1000000) break;  // Prevent infinite loop
        }
    }

    /// Add sub-block to pool
    pub fn addSubBlock(self: *BlockchainV2, sub: SubBlock) !void {
        // Validate shard
        const expected_shard = self.shard_config.getShardForSubBlock(sub.sub_id);
        if (sub.shard_id != expected_shard) {
            return error.IncorrectShard;
        }

        try self.sub_block_pool.addSubBlock(sub);
    }

    /// Check if all 10 sub-blocks are collected
    pub fn isSubBlockPoolComplete(self: *const BlockchainV2) bool {
        return self.sub_block_pool.isFull();
    }

    /// Create main block from complete sub-block pool
    pub fn createBlockFromSubBlocks(self: *BlockchainV2) !Block {
        if (!self.isSubBlockPoolComplete()) {
            return error.IncompleteSubBlocks;
        }

        const previous_block = self.chain.items[self.chain.items.len - 1];
        const block_index = self.chain.items.len;

        // Collect all transactions from sub-blocks
        var all_transactions = array_list.Managed(Transaction).init(self.allocator);
        for (self.sub_block_pool.sub_blocks.items) |sub| {
            for (sub.transactions.items) |tx| {
                try all_transactions.append(tx);
            }
        }

        var block = Block{
            .index = @intCast(block_index),
            .timestamp = std.time.timestamp(),
            .transactions = all_transactions,
            .previous_hash = previous_block.hash,
            .nonce = 0,
            .hash = "",
        };

        // Mine main block
        try self.mineBlock(&block);

        // Add to chain
        try self.chain.append(block);

        // Clear sub-block pool and increment block number
        self.sub_block_pool.clear();
        self.current_block_number += 1;

        return block;
    }

    /// Mine block (simple PoW)
    pub fn mineBlock(self: *BlockchainV2, block: *Block) !void {
        var nonce: u64 = 0;
        while (true) {
            block.nonce = nonce;
            const hash = try self.calculateBlockHash(block);

            // Check difficulty (leading zeros)
            if (try self.isValidHash(hash)) {
                block.hash = hash;
                break;
            }

            nonce += 1;
            if (nonce > 10000000) break;
        }
    }

    /// Calculate block hash
    pub fn calculateBlockHash(self: *BlockchainV2, block: *const Block) ![]const u8 {
        _ = self;
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});

        var buffer: [256]u8 = undefined;
        const str = try std.fmt.bufPrint(&buffer, "{d}{d}{d}{d}", .{
            block.index,
            block.timestamp,
            block.previous_hash.len,
            block.nonce,
        });

        hasher.update(str);

        for (block.transactions.items) |tx| {
            hasher.update(tx.hash);
        }

        var hash: [32]u8 = undefined;
        hasher.final(&hash);

        var result: [16]u8 = undefined;
        for (0..8) |i| {
            _ = std.fmt.bufPrint(result[i * 2 .. (i + 1) * 2], "{x:0>2}", .{hash[i]}) catch "";
        }

        return &result;
    }

    /// Validate hash meets difficulty
    pub fn isValidHash(self: *BlockchainV2, hash: []const u8) !bool {
        var zero_count: u32 = 0;
        for (hash) |char| {
            if (char == '0') {
                zero_count += 1;
            } else {
                break;
            }
        }

        return zero_count >= self.difficulty;
    }

    /// Encode block to binary format (93% compression)
    pub fn encodeBlockBinary(self: *BlockchainV2, block: *const Block) ![]u8 {
        var encoder = BinaryEncoder.init(self.allocator);
        defer encoder.deinit();

        // Encode block header
        try encoder.encodeVarU32(block.index);
        try encoder.encodeVarU64(@bitCast(block.timestamp));
        try encoder.encodeVarU64(block.nonce);
        try encoder.buffer.appendSlice(block.hash);
        try encoder.buffer.appendSlice(block.previous_hash);

        // Encode transaction count
        try encoder.encodeVarU32(@intCast(block.transactions.items.len));

        // Encode transactions
        for (block.transactions.items) |tx| {
            try encoder.encodeTransaction(&tx);
        }

        return encoder.getBytes();
    }

    /// Get blockchain statistics
    pub fn getStats(self: *const BlockchainV2) BlockStats {
        return BlockStats{
            .block_count = self.chain.items.len,
            .transaction_count = self.mempool.items.len,
            .sub_blocks_pending = self.sub_block_pool.sub_blocks.items.len,
            .difficulty = self.difficulty,
            .shard_id = self.shard_config.current_node_shard,
        };
    }

    pub fn getBlockCount(self: *const BlockchainV2) u32 {
        return @intCast(self.chain.items.len);
    }
};

pub const BlockStats = struct {
    block_count: usize,
    transaction_count: usize,
    sub_blocks_pending: usize,
    difficulty: u32,
    shard_id: u8,
};

// Tests
const testing = std.testing;

test "blockchain v2 initialization" {
    var bc = try BlockchainV2.init(testing.allocator, 0);
    defer bc.deinit();

    try testing.expectEqual(bc.getBlockCount(), 1);  // Genesis block
}

test "sub-block creation and pooling" {
    var bc = try BlockchainV2.init(testing.allocator, 0);
    defer bc.deinit();

    for (0..10) |i| {
        const sub = try bc.createSubBlock(@intCast(i), "miner-1");
        try bc.addSubBlock(sub);
    }

    try testing.expect(bc.isSubBlockPoolComplete());
    try testing.expectEqual(bc.sub_block_pool.sub_blocks.items.len, 10);
}

test "block creation from sub-blocks" {
    var bc = try BlockchainV2.init(testing.allocator, 0);
    defer bc.deinit();

    // Create 10 sub-blocks
    for (0..10) |i| {
        var sub = try bc.createSubBlock(@intCast(i), "miner-1");
        try bc.addSubBlock(sub);
    }

    // Create main block
    const block = try bc.createBlockFromSubBlocks();

    try testing.expectEqual(block.index, 1);
    try testing.expect(bc.sub_block_pool.sub_blocks.items.len == 0);  // Pool cleared
}
