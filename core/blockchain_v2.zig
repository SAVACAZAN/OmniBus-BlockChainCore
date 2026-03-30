const std = @import("std");
const block_mod = @import("block.zig");
const transaction_mod = @import("transaction.zig");
const sub_block_mod = @import("sub_block.zig");
const shard_config = @import("shard_config.zig");
const binary_codec = @import("binary_codec.zig");
const prune_config = @import("prune_config.zig");
const archive_manager_mod = @import("archive_manager.zig");
const hex_utils = @import("hex_utils.zig");
const array_list = std.array_list;

pub const Block = block_mod.Block;
pub const Transaction = transaction_mod.Transaction;
pub const SubBlock = sub_block_mod.SubBlock;
pub const SubBlockEngine = sub_block_mod.SubBlockEngine;
pub const ShardConfig = shard_config.ShardConfig;
pub const BinaryEncoder = binary_codec.BinaryEncoder;
pub const BinaryDecoder = binary_codec.BinaryDecoder;
pub const PruneConfig = prune_config.PruneConfig;
pub const PruneStats = prune_config.PruneStats;
pub const ArchiveManager = archive_manager_mod.ArchiveManager;

/// Blockchain v2 - with sub-blocks, sharding, and pruning support
pub const BlockchainV2 = struct {
    chain: array_list.Managed(Block),
    mempool: array_list.Managed(Transaction),
    sub_block_engine: SubBlockEngine,
    shard_config: ShardConfig,
    prune_config: PruneConfig,
    archive_mgr: ?ArchiveManager = null,
    prune_stats: PruneStats = .{},
    difficulty: u32,
    allocator: std.mem.Allocator,
    current_block_number: u32 = 0,

    pub fn init(allocator: std.mem.Allocator, shard_id: u8) !BlockchainV2 {
        return try BlockchainV2.initWithPruning(allocator, shard_id, PruneConfig.init(allocator));
    }

    pub fn initWithPruning(allocator: std.mem.Allocator, shard_id: u8, prune_cfg: PruneConfig) !BlockchainV2 {
        var chain = array_list.Managed(Block).init(allocator);
        const mempool = array_list.Managed(Transaction).init(allocator);
        const sub_eng = SubBlockEngine.init("miner-local", shard_id, allocator);
        const shards = try ShardConfig.init(allocator, shard_id);
        var cfg = prune_cfg;
        cfg.allocator = allocator;

        // Validate pruning config
        try cfg.validate();

        // Create genesis block
        const genesis = Block{
            .index = 0,
            .timestamp = 0,
            .transactions = array_list.Managed(Transaction).init(allocator),
            .previous_hash = "0",
            .nonce = 0,
            .hash = "genesis_hash_omnibus_v2",
        };

        try chain.append(genesis);

        var archive: ?ArchiveManager = null;
        if (cfg.archive_enabled) {
            archive = ArchiveManager.init(allocator, cfg.archive_path, cfg.compress_archived);
        }

        return BlockchainV2{
            .chain = chain,
            .mempool = mempool,
            .sub_block_engine = sub_eng,
            .shard_config = shards,
            .prune_config = cfg,
            .archive_mgr = archive,
            .difficulty = 4,
            .allocator = allocator,
            .current_block_number = 0,
        };
    }

    pub fn deinit(self: *BlockchainV2) void {
        for (self.chain.items, 0..) |*block, i| {
            block.transactions.deinit();
            // Blocurile minate (index > 0) au hash alocat pe heap (64 chars)
            if (i > 0 and block.hash.len == 64) {
                self.allocator.free(block.hash);
            }
        }
        self.chain.deinit();
        self.mempool.deinit();
    }

    /// Add transaction to mempool
    pub fn addTransaction(self: *BlockchainV2, tx: Transaction) !void {
        if (!try self.validateTransaction(&tx)) {
            return error.InvalidTransaction;
        }
        try self.mempool.append(tx);
    }

    /// Validate transaction (delegates to Transaction.isValid + hash integrity)
    pub fn validateTransaction(self: *BlockchainV2, tx: *const Transaction) !bool {
        _ = self;
        if (!tx.isValid()) return false;
        // Hash integrity check (if signed)
        if (tx.signature.len == 128 and tx.hash.len == 64) {
            const expected = tx.calculateHash();
            var stored: [32]u8 = undefined;
            hex_utils.hexToBytes(tx.hash, &stored) catch return false;
            if (!std.mem.eql(u8, &stored, &expected)) return false;
        }
        return true;
    }

    /// Create sub-block (0.1s interval)
    pub fn createSubBlock(self: *BlockchainV2, sub_id: u8, miner_id: []const u8) !SubBlock {
        if (sub_id > 9) return error.InvalidSubBlockId;

        const shard_id = self.shard_config.getShardForSubBlock(sub_id);
        var sub = SubBlock.init(self.allocator, sub_id, self.current_block_number, shard_id, miner_id);

        // Distribute 1/10 din mempool per sub-bloc
        const txs_per_sub = self.mempool.items.len / 10;
        const start_idx = sub_id * txs_per_sub;
        const end_idx = if (sub_id == 9) self.mempool.items.len else (sub_id + 1) * txs_per_sub;

        if (start_idx < end_idx) {
            for (self.mempool.items[start_idx..end_idx]) |tx| {
                try sub.addTransaction(tx);
            }
        }

        sub.finalize();
        return sub;
    }

    /// Add sub-block via engine
    pub fn addSubBlock(self: *BlockchainV2, sub: SubBlock) !void {
        const expected_shard = self.shard_config.getShardForSubBlock(sub.sub_id);
        if (sub.shard_id != expected_shard) return error.IncorrectShard;
        _ = try self.sub_block_engine.current_key_block.addSubBlock(sub);
    }

    /// Check if all 10 sub-blocks are collected
    pub fn isSubBlockPoolComplete(self: *const BlockchainV2) bool {
        return self.sub_block_engine.current_key_block.received == sub_block_mod.SUB_BLOCKS_PER_BLOCK;
    }

    /// Create main block from complete sub-block pool
    pub fn createBlockFromSubBlocks(self: *BlockchainV2) !Block {
        if (!self.isSubBlockPoolComplete()) return error.IncompleteSubBlocks;

        const previous_block = self.chain.items[self.chain.items.len - 1];
        const block_index = self.chain.items.len;

        var all_transactions = array_list.Managed(Transaction).init(self.allocator);
        for (self.sub_block_engine.current_key_block.sub_blocks) |maybe_sb| {
            if (maybe_sb) |sb| {
                for (sb.transactions.items) |tx| {
                    try all_transactions.append(tx);
                }
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

        try self.mineBlock(&block);
        try self.chain.append(block);

        self.sub_block_engine.block_number += 1;
        self.sub_block_engine.sub_counter = 0;
        self.sub_block_engine.current_key_block = sub_block_mod.KeyBlock.init(self.sub_block_engine.block_number);
        self.current_block_number += 1;

        return block;
    }

    /// Mine block (simple PoW)
    pub fn mineBlock(self: *BlockchainV2, block: *Block) !void {
        var nonce: u64 = 0;
        const MAX_NONCE: u64 = 4_294_967_296;
        while (nonce < MAX_NONCE) {
            block.nonce = nonce;
            const hash = try self.calculateBlockHash(block);

            if (try self.isValidHash(hash)) {
                block.hash = hash;
                break;
            }

            self.allocator.free(hash);
            nonce += 1;
            if (nonce > 10000000) break;
        }
    }

    /// Calculate block hash (shared implementation in hex_utils)
    pub fn calculateBlockHash(self: *BlockchainV2, block: *const Block) ![]const u8 {
        return hex_utils.hashBlock(block.*, self.allocator);
    }

    /// Validate hash meets difficulty (delegates to shared hex_utils)
    pub fn isValidHash(self: *BlockchainV2, hash: []const u8) !bool {
        return hex_utils.isValidHashDifficulty(hash, self.difficulty);
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
            .sub_blocks_pending = self.sub_block_engine.current_key_block.received,
            .difficulty = self.difficulty,
            .shard_id = self.shard_config.current_node_shard,
        };
    }

    pub fn getBlockCount(self: *const BlockchainV2) u32 {
        return @intCast(self.chain.items.len);
    }

    /// Prune old blocks based on configuration
    pub fn pruneOldBlocks(self: *BlockchainV2) !void {
        if (!self.prune_config.auto_prune_enabled) return;

        if (self.chain.items.len <= self.prune_config.prune_threshold) {
            return;  // No need to prune yet
        }

        const blocks_to_keep = self.prune_config.max_blocks_to_keep;
        const blocks_to_remove = self.chain.items.len - blocks_to_keep;

        std.debug.print("[PRUNE] Starting pruning: removing {d} blocks\n", .{blocks_to_remove});

        // Archive old blocks if enabled
        if (self.archive_mgr) |*archive| {
            var encoded_blocks = array_list.Managed(u8).init(self.allocator);
            defer encoded_blocks.deinit();

            // Encode blocks to be removed
            for (0..blocks_to_remove) |i| {
                const encoded = try self.encodeBlockBinary(&self.chain.items[i]);
                try encoded_blocks.appendSlice(encoded);
            }

            try archive.archiveBlocks(0, @intCast(blocks_to_remove - 1), encoded_blocks.items);
        }

        // Remove old blocks from chain
        for (0..blocks_to_remove) |_| {
            if (self.chain.items.len > 0) {
                const removed = self.chain.orderedRemove(0);
                removed.transactions.deinit();

                self.prune_stats.blocks_pruned += 1;
                self.prune_stats.space_freed += 50000;  // Estimate ~50KB per block
            }
        }

        self.prune_stats.blocks_remaining = @intCast(self.chain.items.len);
        self.prune_stats.prune_count += 1;

        std.debug.print("[PRUNE] Completed: {d} blocks remaining\n", .{self.prune_stats.blocks_remaining});
    }

    /// Check if pruning is needed
    pub fn needsPruning(self: *const BlockchainV2) bool {
        return self.chain.items.len >= self.prune_config.prune_threshold;
    }

    /// Get pruning statistics
    pub fn getPruneStats(self: *const BlockchainV2) PruneStats {
        return self.prune_stats;
    }

    /// Get estimated storage size
    pub fn getEstimatedStorageSize(self: *const BlockchainV2) u64 {
        // ~50KB per block (after compression)
        return @as(u64, @intCast(self.chain.items.len)) * 50 * 1024;
    }

    /// Print blockchain info including pruning stats
    pub fn printInfo(self: *const BlockchainV2) void {
        const size = self.getEstimatedStorageSize();
        const size_mb = size / (1024 * 1024);

        std.debug.print(
            \\[BLOCKCHAIN] Info:
            \\  - Blocks: {d}
            \\  - Transactions: {d}
            \\  - Estimated size: {d} MB
            \\  - Shard: {d}
            \\  - Pruning enabled: {}
            \\  - Blocks pruned total: {d}
            \\
        , .{
            self.chain.items.len,
            self.mempool.items.len,
            size_mb,
            self.shard_config.current_node_shard,
            self.prune_config.auto_prune_enabled,
            self.prune_stats.blocks_pruned,
        });
    }
};

pub const BlockStats = struct {
    block_count: usize,
    transaction_count: usize,
    sub_blocks_pending: u8,
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
}

test "block creation from sub-blocks" {
    var bc = try BlockchainV2.init(testing.allocator, 0);
    defer bc.deinit();

    // Create 10 sub-blocks
    for (0..10) |i| {
        const sub = try bc.createSubBlock(@intCast(i), "miner-1");
        try bc.addSubBlock(sub);
    }

    // Create main block
    const block = try bc.createBlockFromSubBlocks();

    try testing.expectEqual(block.index, 1);
    try testing.expectEqual(bc.sub_block_engine.current_key_block.received, 0);  // Pool cleared
}

test "BlockchainV2 — difficulty default = 4" {
    var bc = try BlockchainV2.init(testing.allocator, 0);
    defer bc.deinit();
    try testing.expectEqual(@as(u32, 4), bc.difficulty);
}

test "BlockchainV2 — genesis index = 0" {
    var bc = try BlockchainV2.init(testing.allocator, 0);
    defer bc.deinit();
    try testing.expectEqual(@as(u32, 0), bc.chain.items[0].index);
}

test "BlockchainV2 — validateTransaction amount 0 = false" {
    var bc = try BlockchainV2.init(testing.allocator, 0);
    defer bc.deinit();
    const tx = Transaction{
        .id = 1, .from_address = "ob_omni_a", .to_address = "ob_omni_b",
        .amount = 0, .timestamp = 0, .signature = "", .hash = "",
    };
    try testing.expect(!try bc.validateTransaction(&tx));
}

test "BlockchainV2 — validateTransaction adresa goala = false" {
    var bc = try BlockchainV2.init(testing.allocator, 0);
    defer bc.deinit();
    const tx = Transaction{
        .id = 1, .from_address = "", .to_address = "ob_omni_b",
        .amount = 100, .timestamp = 0, .signature = "", .hash = "",
    };
    try testing.expect(!try bc.validateTransaction(&tx));
}

test "BlockchainV2 — addTransaction valid merge in mempool" {
    var bc = try BlockchainV2.init(testing.allocator, 0);
    defer bc.deinit();
    const tx = Transaction{
        .id = 1, .from_address = "ob_omni_alice", .to_address = "ob_omni_bob",
        .amount = 1000, .timestamp = 0, .signature = "", .hash = "",
    };
    try bc.addTransaction(tx);
    try testing.expectEqual(@as(usize, 1), bc.mempool.items.len);
}

test "BlockchainV2 — addTransaction invalid returneaza eroare" {
    var bc = try BlockchainV2.init(testing.allocator, 0);
    defer bc.deinit();
    const tx = Transaction{
        .id = 1, .from_address = "ob_omni_a", .to_address = "ob_omni_b",
        .amount = 0, .timestamp = 0, .signature = "", .hash = "",
    };
    try testing.expectError(error.InvalidTransaction, bc.addTransaction(tx));
}

test "BlockchainV2 — isSubBlockPoolComplete false initial" {
    var bc = try BlockchainV2.init(testing.allocator, 0);
    defer bc.deinit();
    try testing.expect(!bc.isSubBlockPoolComplete());
}

test "BlockchainV2 — createSubBlock id invalid returneaza eroare" {
    var bc = try BlockchainV2.init(testing.allocator, 0);
    defer bc.deinit();
    try testing.expectError(error.InvalidSubBlockId, bc.createSubBlock(10, "miner-1"));
}

test "BlockchainV2 — createBlockFromSubBlocks fara sub-blocuri complete = eroare" {
    var bc = try BlockchainV2.init(testing.allocator, 0);
    defer bc.deinit();
    try testing.expectError(error.IncompleteSubBlocks, bc.createBlockFromSubBlocks());
}

test "BlockchainV2 — chain creste dupa createBlockFromSubBlocks" {
    var bc = try BlockchainV2.init(testing.allocator, 0);
    defer bc.deinit();
    for (0..10) |i| {
        const sub = try bc.createSubBlock(@intCast(i), "miner-1");
        try bc.addSubBlock(sub);
    }
    _ = try bc.createBlockFromSubBlocks();
    try testing.expectEqual(@as(u32, 2), bc.getBlockCount());
}

test "BlockchainV2 — calculateBlockHash produce 64 chars" {
    var bc = try BlockchainV2.init(testing.allocator, 0);
    defer bc.deinit();
    const genesis = bc.chain.items[0];
    const h = try bc.calculateBlockHash(&genesis);
    defer bc.allocator.free(h);
    try testing.expectEqual(@as(usize, 64), h.len);
}

test "BlockchainV2 — calculateBlockHash determinist" {
    var bc = try BlockchainV2.init(testing.allocator, 0);
    defer bc.deinit();
    const genesis = bc.chain.items[0];
    const h1 = try bc.calculateBlockHash(&genesis);
    defer bc.allocator.free(h1);
    const h2 = try bc.calculateBlockHash(&genesis);
    defer bc.allocator.free(h2);
    try testing.expectEqualSlices(u8, h1, h2);
}

test "BlockchainV2 — isValidHash 4 zerouri leading = valid" {
    var bc = try BlockchainV2.init(testing.allocator, 0);
    defer bc.deinit();
    try testing.expect(try bc.isValidHash("0000abcdef123456789012345678901234567890123456789012345678901234"));
}

test "BlockchainV2 — isValidHash 3 zerouri leading = invalid" {
    var bc = try BlockchainV2.init(testing.allocator, 0);
    defer bc.deinit();
    try testing.expect(!try bc.isValidHash("000abcdef1234567890123456789012345678901234567890123456789012345"));
}

test "BlockchainV2 — getStats reflecta starea curenta" {
    var bc = try BlockchainV2.init(testing.allocator, 0);
    defer bc.deinit();
    const stats = bc.getStats();
    try testing.expectEqual(@as(usize, 1), stats.block_count);
    try testing.expectEqual(@as(u8, 0), stats.sub_blocks_pending);
    try testing.expectEqual(@as(u32, 4), stats.difficulty);
}

test "BlockchainV2 — needsPruning false la init" {
    var bc = try BlockchainV2.init(testing.allocator, 0);
    defer bc.deinit();
    try testing.expect(!bc.needsPruning());
}

test "BlockchainV2 — getEstimatedStorageSize = 1 bloc × 50KB" {
    var bc = try BlockchainV2.init(testing.allocator, 0);
    defer bc.deinit();
    try testing.expectEqual(@as(u64, 50 * 1024), bc.getEstimatedStorageSize());
}

test "BlockchainV2 — current_block_number creste dupa mining" {
    var bc = try BlockchainV2.init(testing.allocator, 0);
    defer bc.deinit();
    for (0..10) |i| {
        const sub = try bc.createSubBlock(@intCast(i), "miner-1");
        try bc.addSubBlock(sub);
    }
    _ = try bc.createBlockFromSubBlocks();
    try testing.expectEqual(@as(u32, 1), bc.current_block_number);
}

test "BlockchainV2 — sub_block pool resetat dupa createBlockFromSubBlocks" {
    var bc = try BlockchainV2.init(testing.allocator, 0);
    defer bc.deinit();
    for (0..10) |i| {
        const sub = try bc.createSubBlock(@intCast(i), "miner-1");
        try bc.addSubBlock(sub);
    }
    _ = try bc.createBlockFromSubBlocks();
    try testing.expect(!bc.isSubBlockPoolComplete());
    try testing.expectEqual(@as(u8, 0), bc.sub_block_engine.current_key_block.received);
}
