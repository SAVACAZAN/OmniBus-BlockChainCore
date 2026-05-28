// Reorg + fork helpers for the Blockchain struct.
//
// Extracted from blockchain.zig as part of the file-size cleanup.
// Pattern: free functions taking `*Blockchain` (or `*const Blockchain` for
// read-only lookups). Thin delegating method shims stay on the struct in
// blockchain.zig so external callers keep working unchanged.

const std = @import("std");
const blockchain_mod = @import("../blockchain.zig");
const block_mod = @import("../block.zig");
const consensus_params = @import("consensus_params.zig");
const hex_utils = @import("../hex_utils.zig");

const Blockchain = blockchain_mod.Blockchain;
const Block = block_mod.Block;

const MAX_REORG_DEPTH = consensus_params.MAX_REORG_DEPTH;
const MAX_ORPHAN_POOL = consensus_params.MAX_ORPHAN_POOL;
const FEE_BURN_PCT    = consensus_params.FEE_BURN_PCT;
const blockRewardAt   = consensus_params.blockRewardAt;

pub fn addExternalBlock(self: *Blockchain, block: Block) !void {
    self.mutex.lock();
    defer self.mutex.unlock();

    const our_tip = self.chain.items[self.chain.items.len - 1];

    // Case 1: Block extends our chain tip (previous_hash matches tip hash)
    if (std.mem.eql(u8, block.previous_hash, our_tip.hash)) {
        if (!self.validateBlock(&block)) return error.InvalidBlock;
        try self.applyBlock(block);
        // After appending, try to connect orphans
        self.processOrphansInternal();
        return;
    }

    // Case 2: Check if block's parent exists somewhere in our chain (fork)
    const parent_idx = findBlockByHash(self, block.previous_hash);
    if (parent_idx) |pidx| {
        // We have the parent but it's not our tip => this is a fork.
        // new chain length from genesis = pidx + 1 (fork point inclusive) + 1 (new block)
        const new_chain_len = pidx + 2;
        const our_chain_len = self.chain.items.len;

        if (new_chain_len > our_chain_len) {
            // Single-block fork that's longer: reorg
            if (!self.validateBlockAtHeight(&block, pidx + 1)) return error.InvalidBlock;

            const reorg_depth = our_chain_len - 1 - pidx;
            if (reorg_depth > MAX_REORG_DEPTH) return error.ReorgTooDeep;

            std.debug.print("[REORG] Single-block reorg at fork={d}, depth={d}\n", .{ pidx, reorg_depth });

            // Collect TXs from blocks being removed (after fork point)
            try self.collectOrphanedTxs(pidx + 1);

            // Free removed blocks
            for (pidx + 1..self.chain.items.len) |i| {
                var old_blk = &self.chain.items[i];
                old_blk.transactions.deinit();
                if (i > 0 and old_blk.hash.len == 64) {
                    self.allocator.free(old_blk.hash);
                }
                if (old_blk.miner_heap) {
                    self.allocator.free(old_blk.miner_address);
                }
            }

            // Truncate chain to fork point + 1
            self.chain.items.len = pidx + 1;

            // Apply the new block
            try self.applyBlock(block);

            // Recalculate balances from scratch
            try self.recalculateFromHeight(pidx + 1);

            // Remove mempool TXs already in new chain
            self.removeMempoolDuplicates();

            self.processOrphansInternal();
        }
        // If new_chain_len <= our_chain_len, ignore the fork (shorter or equal)
        return;
    }

    // Case 3: Parent unknown -> orphan pool
    if (self.orphan_blocks.items.len < MAX_ORPHAN_POOL) {
        try self.orphan_blocks.append(block);
    }
}

/// Accept a full chain from a peer and reorg if it's longer.
/// Validates all blocks in the new chain from the fork point.
/// Returns orphaned TXs to mempool for re-mining.
pub fn reorg(self: *Blockchain, new_chain: []const Block) !void {
    self.mutex.lock();
    defer self.mutex.unlock();

    if (new_chain.len == 0) return error.EmptyChain;

    // New chain must be strictly longer than ours
    if (new_chain.len <= self.chain.items.len) return error.ShorterChain;

    // Find the fork point (common ancestor)
    const fork_point = findForkPointInternal(self, new_chain) orelse return error.NoCommonAncestor;

    // Safety: reject reorgs deeper than MAX_REORG_DEPTH
    const reorg_depth = self.chain.items.len - 1 - fork_point;
    if (reorg_depth > MAX_REORG_DEPTH) return error.ReorgTooDeep;

    // Validate all new blocks from fork point onward
    for (fork_point + 1..new_chain.len) |i| {
        const blk = &new_chain[i];
        // Check basic block validity: merkle root, transactions
        if (!blk.validateTransactions()) return error.InvalidBlock;
        const expected_merkle = blk.calculateMerkleRoot();
        if (!std.mem.eql(u8, &expected_merkle, &blk.merkle_root)) return error.InvalidBlock;

        // Verify chain linkage: previous_hash must match prior block
        if (i > 0) {
            if (!std.mem.eql(u8, blk.previous_hash, new_chain[i - 1].hash)) return error.InvalidBlock;
        }

        // Verify block hash meets difficulty
        if (blk.index > 0) {
            if (!hex_utils.isValidHashDifficulty(blk.hash, self.difficulty)) return error.InvalidBlock;
        }

        // Verify reward is not inflated
        var blk_total_fees: u64 = 0;
        for (blk.transactions.items) |tx| {
            blk_total_fees += tx.fee;
        }
        const max_reward = blockRewardAt(@intCast(blk.index));
        const blk_fees_to_miner = blk_total_fees - (blk_total_fees * FEE_BURN_PCT / 100);
        if (blk.reward_sat > max_reward + blk_fees_to_miner) return error.InvalidBlock;
    }

    std.debug.print("[REORG] Full chain reorg at fork={d}, our_len={d} -> new_len={d}, depth={d}\n", .{ fork_point, self.chain.items.len, new_chain.len, reorg_depth });

    // Collect TXs from old blocks being removed (after fork point) -> return to mempool
    try self.collectOrphanedTxs(fork_point + 1);

    // Truncate chain to fork point (free removed blocks)
    for (fork_point + 1..self.chain.items.len) |i| {
        var old_blk = &self.chain.items[i];
        old_blk.transactions.deinit();
        if (i > 0 and old_blk.hash.len == 64) {
            self.allocator.free(old_blk.hash);
        }
        if (old_blk.miner_heap) {
            self.allocator.free(old_blk.miner_address);
        }
    }
    self.chain.items.len = fork_point + 1;

    // Append new blocks from fork point onward
    for (fork_point + 1..new_chain.len) |i| {
        try self.chain.append(new_chain[i]);
    }

    // Recalculate all balances, nonces, tx_block_height from scratch
    try self.recalculateFromHeight(fork_point + 1);

    // Remove from mempool any TXs that are now in the new chain
    self.removeMempoolDuplicates();

    self.processOrphansInternal();

    // Reorg is a critical event — force save to disc
    self.saveToDisc() catch |err| {
        std.debug.print("[DB] Reorg save failed: {}\n", .{err});
    };
}

/// Find the highest block index where both chains have the same hash.
/// Returns null if no common ancestor found (completely divergent chains).
pub fn findForkPoint(self: *const Blockchain, other_chain: []const Block) ?usize {
    return findForkPointInternal(self, other_chain);
}

/// Internal fork point finder (no mutex, called from methods that already hold it).
pub fn findForkPointInternal(self: *const Blockchain, other_chain: []const Block) ?usize {
    const max_idx = @min(self.chain.items.len, other_chain.len);
    if (max_idx == 0) return null;

    var i: usize = max_idx;
    while (i > 0) {
        i -= 1;
        if (std.mem.eql(u8, self.chain.items[i].hash, other_chain[i].hash)) {
            return i;
        }
    }
    return null;
}

/// Find a block in our chain by its hash. Returns the index or null.
pub fn findBlockByHash(self: *const Blockchain, hash: []const u8) ?usize {
    var i: usize = self.chain.items.len;
    while (i > 0) {
        i -= 1;
        if (std.mem.eql(u8, self.chain.items[i].hash, hash)) {
            return i;
        }
    }
    return null;
}
