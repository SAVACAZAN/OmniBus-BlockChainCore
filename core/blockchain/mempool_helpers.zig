//! Mempool / reorg helpers extracted from blockchain.zig.
//!
//! All functions are free functions taking `*Blockchain` as their first
//! argument. The Blockchain struct stays in blockchain.zig and re-exposes
//! them via thin method shims so external callers keep using
//! `bc.addTransaction(...)` syntax.
//!
//! Covers:
//!   - addTransaction
//!   - collectOrphanedTxs
//!   - removeMempoolDuplicates
//!   - recalculateFromHeight (full replay from genesis)
//!   - processOrphans / processOrphansInternal
const std = @import("std");
const blockchain_mod = @import("../blockchain.zig");
const transaction_mod = @import("../transaction.zig");
const utxo_mod = @import("../utxo.zig");
const main_mod = @import("../main.zig");
const consensus_params = @import("consensus_params.zig");

const Blockchain = blockchain_mod.Blockchain;
const Transaction = transaction_mod.Transaction;
const FEE_BURN_PCT = consensus_params.FEE_BURN_PCT;

pub fn addTransaction(self: *Blockchain, tx: Transaction) !void {
    self.mutex.lock();
    defer self.mutex.unlock();
    const valid = self.validateTransaction(&tx) catch |err| {
        std.debug.print("[ADD-TX] validateTransaction errored: {} (from={s})\n",
            .{ err, tx.from_address[0..@min(tx.from_address.len, 20)] });
        return err;
    };
    if (!valid) {
        std.debug.print("[ADD-TX] InvalidTransaction (from={s} amount={d})\n",
            .{ tx.from_address[0..@min(tx.from_address.len, 20)], tx.amount });
        return error.InvalidTransaction;
    }
    try self.mempool.append(tx);
    std.debug.print("[ADD-TX] OK appended to mempool (size now={d})\n", .{self.mempool.items.len});

    // Push real-time WS event for new mempool TX. Off-thread broadcast
    // walks the connected-clients list under its own mutex; a few µs added
    // here is fine because addTransaction already holds bc.mutex (i.e. we
    // are NOT in the inner mining hot loop). Cheap inline JSON via
    // bufPrint inside ws_srv.broadcastTx — no allocations on this path.
    if (main_mod.g_ws_srv) |ws| {
        if (tx.hash.len > 0) {
            ws.broadcastTx(tx.hash, tx.from_address, tx.amount);
        }
    }
}

/// Collect transactions from blocks being removed during reorg and return them to mempool.
pub fn collectOrphanedTxs(self: *Blockchain, from_height: usize) !void {
    for (from_height..self.chain.items.len) |i| {
        const blk = &self.chain.items[i];
        for (blk.transactions.items) |tx| {
            try self.mempool.append(tx);
        }
    }
}

/// Remove mempool TXs that already exist in the current chain.
pub fn removeMempoolDuplicates(self: *Blockchain) void {
    var write: usize = 0;
    for (self.mempool.items) |tx| {
        if (self.tx_block_height.get(tx.hash) != null) continue;
        self.mempool.items[write] = tx;
        write += 1;
    }
    self.mempool.items.len = write;
}

/// Recalculate balances, nonces, and tx_block_height by replaying all blocks from genesis.
/// Made `pub` so p2p.zig can call after a truncate (reorg) to keep state coherent
/// — without this, the balances HashMap retains entries for now-discarded blocks
/// whose dupe()'d address keys may have been freed → segfault on next getOrPut.
pub fn recalculateFromHeight(self: *Blockchain, from_height: usize) !void {
    // PHASE C.3 — full chain replay is a legitimate write window.
    self.in_apply_block = true;
    defer self.in_apply_block = false;

    _ = from_height;
    // Clear all balance/nonce/tx state and replay from genesis
    self.balances.clearRetainingCapacity();
    self.nonces.clearRetainingCapacity();
    self.tx_block_height.clearRetainingCapacity();
    self.stake_amounts.clearRetainingCapacity();
    // Free meta keys before clearing — same pattern as deinit().
    var meta_it_clear = self.stake_meta.iterator();
    while (meta_it_clear.next()) |entry| {
        self.allocator.free(entry.key_ptr.*);
    }
    self.stake_meta.clearRetainingCapacity();
    self.registered_agents.clearRetainingCapacity();
    // Clear and rebuild UTXO set from chain
    self.utxo_set.deinit();
    self.utxo_set = utxo_mod.UTXOSet.init(self.allocator);

    for (1..self.chain.items.len) |i| {
        const blk = &self.chain.items[i];
        var blk_total_fees: u64 = 0;
        for (blk.transactions.items) |tx| {
            const total_needed = tx.amount + tx.fee;
            // FIX (2026-05-03): la replay nu sarim TX-urile cu selectUTXOs failed.
            // Aceeasi logica ca in mineBlockForMiner — fallback pe balance check.
            var selection_opt: ?utxo_mod.UTXOSet.Selection = null;
            if (self.utxo_set.selectUTXOs(tx.from_address, total_needed, @intCast(blk.index), self.allocator)) |sel| {
                selection_opt = sel;
            } else |err| {
                std.debug.print("[RECALC] selectUTXOs failed for {s}: {} — fallback la balance check\n",
                    .{tx.from_address[0..@min(20, tx.from_address.len)], err});
            }
            if (selection_opt) |*selection| {
                defer selection.utxos.deinit(self.allocator);
                for (selection.utxos.items) |utxo| {
                    _ = self.utxo_set.spendUTXO(utxo.tx_hash, utxo.output_index) catch |err| {
                        std.debug.print("[RECALC] spendUTXO failed: {}\n", .{err});
                    };
                }
                if (selection.total > total_needed) {
                    const change = selection.total - total_needed;
                    self.utxo_set.addUTXO(tx.hash, 1, tx.from_address, change, @intCast(blk.index), "", false) catch {};
                }
            }

            self.debitBalanceLocked(tx.from_address, tx.amount + tx.fee) catch {};
            self.creditBalanceLocked(tx.to_address, tx.amount) catch {};
            blk_total_fees += tx.fee;
            const current_nonce = self.nonces.get(tx.from_address) orelse 0;
            self.nonces.put(tx.from_address, current_nonce + 1) catch {};
            self.tx_block_height.put(tx.hash, @intCast(blk.index)) catch {};
            self.applyOpReturnRoles(tx);
            // Rebuild address_tx_index from persisted TXs (DB v4) so that
            // getaddresshistory returns history through restarts.
            self.indexAddressTx(tx.from_address, tx.hash);
            if (!std.mem.eql(u8, tx.from_address, tx.to_address)) {
                self.indexAddressTx(tx.to_address, tx.hash);
            }
            self.utxo_set.addUTXO(tx.hash, 0, tx.to_address, tx.amount, @intCast(blk.index), "", false) catch {};
        }
        const fees_burned = blk_total_fees * FEE_BURN_PCT / 100;
        const fees_to_miner = blk_total_fees - fees_burned;
        if (blk.miner_address.len > 0 and (blk.reward_sat > 0 or fees_to_miner > 0)) {
            self.creditBalanceLocked(blk.miner_address, blk.reward_sat + fees_to_miner) catch {};
            self.utxo_set.addUTXO(blk.hash, 0, blk.miner_address, blk.reward_sat + fees_to_miner, @intCast(blk.index), "", true) catch {};
        }
    }
}

/// Process orphan blocks: check if any now connect to our chain tip.
/// Keeps trying until no more orphans connect (cascading resolution).
pub fn processOrphans(self: *Blockchain) void {
    self.mutex.lock();
    defer self.mutex.unlock();
    processOrphansInternal(self);
}

/// Internal processOrphans (no mutex, called from methods that already hold it).
pub fn processOrphansInternal(self: *Blockchain) void {
    var progress = true;
    while (progress) {
        progress = false;
        const tip_hash = self.chain.items[self.chain.items.len - 1].hash;
        var i: usize = 0;
        while (i < self.orphan_blocks.items.len) {
            const orphan = self.orphan_blocks.items[i];
            if (std.mem.eql(u8, orphan.previous_hash, tip_hash)) {
                if (self.validateBlock(&orphan)) {
                    self.applyBlock(orphan) catch {
                        i += 1;
                        continue;
                    };
                    _ = self.orphan_blocks.swapRemove(i);
                    progress = true;
                    continue;
                }
            }
            i += 1;
        }
    }
}
