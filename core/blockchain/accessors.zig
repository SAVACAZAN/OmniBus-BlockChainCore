//! Read-only Blockchain accessors extracted from blockchain.zig to keep the
//! main file lean. These are PURE READ helpers — no state mutation (except
//! `recordBlockPrices`, which only writes into the bounded block_prices map
//! and is grouped here as a price-slot accessor pair).
//!
//! All functions are free functions taking `*Blockchain` (or `*const Blockchain`)
//! as their first argument. The Blockchain struct itself stays in blockchain.zig
//! and re-exposes them as thin method shims so external callers keep using
//! `bc.getBlock(...)` syntax.
const std = @import("std");
const blockchain_mod = @import("../blockchain.zig");
const block_mod = @import("../block.zig");
const transaction_mod = @import("../transaction.zig");
const oracle_types = @import("../oracle_types.zig");
const matching_mod = @import("../matching_engine.zig");

const Blockchain = blockchain_mod.Blockchain;
const Block = block_mod.Block;
const Transaction = transaction_mod.Transaction;
const BlockPriceEntry = oracle_types.BlockPriceEntry;
const BlockSnapshot = blockchain_mod.BlockSnapshot;
const array_list = std.array_list;

/// Record the 6 PriceFetch entries snapshot for a given block height.
/// Trims old entries (>1000 blocks behind tip) to bound memory.
pub fn recordBlockPrices(self: *Blockchain, height: u32, entries: []const BlockPriceEntry) void {
    if (!self.block_prices_initialized) return;
    if (entries.len < 6) return;
    var arr: [6]BlockPriceEntry = undefined;
    for (0..6) |i| arr[i] = entries[i];
    self.block_prices.put(height, arr) catch return;
    // Bound memory: drop entries older than 1000 blocks behind current.
    if (height > 1000) {
        const cutoff = height - 1000;
        var it = self.block_prices.iterator();
        var to_remove: [16]u32 = undefined;
        var rcount: usize = 0;
        while (it.next()) |e| {
            if (e.key_ptr.* < cutoff and rcount < to_remove.len) {
                to_remove[rcount] = e.key_ptr.*;
                rcount += 1;
            }
        }
        for (to_remove[0..rcount]) |k| _ = self.block_prices.remove(k);
    }
}

/// Return the 6 price entries snapshot for a block, or null if not recorded.
pub fn getBlockPrices(self: *const Blockchain, height: u32) ?[6]BlockPriceEntry {
    if (!self.block_prices_initialized) return null;
    return self.block_prices.get(height);
}

/// Returns the OMNI amount this address has locked in resting SELL orders
/// on the native DEX. Pure read — sums remaining_sat over the engine's
/// active asks for OMNI-base pairs (0, 4, 5, 6).
pub fn getReservedFromOrders(self: *const Blockchain, address: []const u8) u64 {
    const eng = self.exchange_engine orelse return 0;
    var total: u64 = 0;
    var i: u32 = 0;
    while (i < eng.ask_count) : (i += 1) {
        const o = &eng.asks[i];
        if (o.status != .active and o.status != .partial) continue;
        const omni_base = (o.pair_id == 0 or o.pair_id == 4 or o.pair_id == 5 or o.pair_id == 6);
        if (!omni_base) continue;
        if (!std.mem.eql(u8, o.getTraderAddress(), address)) continue;
        total +%= o.remainingSat();
    }
    return total;
}

pub fn getBlock(self: *Blockchain, index: u32) ?Block {
    if (index < self.chain.items.len) {
        return self.chain.items[index];
    }
    return null;
}

/// Deep-clone the latest block under the chain mutex. Caller MUST call
/// `freeClonedBlock(alloc, &block)` when done.
pub fn getLatestBlock(self: *Blockchain, alloc: std.mem.Allocator) !Block {
    self.mutex.lock();
    defer self.mutex.unlock();
    if (self.chain.items.len == 0) return error.EmptyChain;
    return cloneBlockOwned(alloc, &self.chain.items[self.chain.items.len - 1]);
}

/// Free a Block returned by `getLatestBlock`.
pub fn freeClonedBlock(alloc: std.mem.Allocator, block: *Block) void {
    if (block.hash.len > 0) alloc.free(block.hash);
    if (block.previous_hash.len > 0) alloc.free(block.previous_hash);
    if (block.miner_address.len > 0) alloc.free(block.miner_address);
    for (block.transactions.items) |*tx| {
        freeClonedTx(alloc, tx);
    }
    block.transactions.deinit();
    if (block.fills_heap and block.fills.len > 0) {
        alloc.free(block.fills);
    }
}

/// Internal: deep-clone a Block. Every heap-borrowed slice gets a fresh
/// allocation from `alloc`. The returned Block shares no memory with `src`.
pub fn cloneBlockOwned(alloc: std.mem.Allocator, src: *const Block) !Block {
    var out = Block{
        .index = src.index,
        .timestamp = src.timestamp,
        .transactions = array_list.Managed(Transaction).init(alloc),
        .previous_hash = "",
        .nonce = src.nonce,
        .hash = "",
        .merkle_root = src.merkle_root,
        .miner_address = "",
        .reward_sat = src.reward_sat,
        .miner_heap = true,
        .prices = src.prices,
        .prices_root = src.prices_root,
        .fills = &.{},
        .fills_root = src.fills_root,
        .fills_heap = false,
    };
    errdefer freeClonedBlock(alloc, &out);

    if (src.hash.len > 0) {
        out.hash = try alloc.dupe(u8, src.hash);
    }
    if (src.previous_hash.len > 0) {
        out.previous_hash = try alloc.dupe(u8, src.previous_hash);
    }
    if (src.miner_address.len > 0) {
        out.miner_address = try alloc.dupe(u8, src.miner_address);
    }
    try out.transactions.ensureTotalCapacity(src.transactions.items.len);
    for (src.transactions.items) |*src_tx| {
        const cloned_tx = try cloneTxOwned(alloc, src_tx);
        try out.transactions.append(cloned_tx);
    }
    if (src.fills.len > 0) {
        const Fill = matching_mod.Fill;
        const fills_buf = try alloc.alloc(Fill, src.fills.len);
        @memcpy(fills_buf, src.fills);
        out.fills = fills_buf;
        out.fills_heap = true;
    }
    return out;
}

pub fn cloneTxOwned(alloc: std.mem.Allocator, src: *const Transaction) !Transaction {
    var out: Transaction = src.*;
    out.from_address = "";
    out.to_address = "";
    out.op_return = "";
    out.script_pubkey = "";
    out.script_sig = "";
    out.signature = "";
    out.hash = "";
    out.public_key = "";
    out.inputs = &.{};
    out.outputs = &.{};
    out.data = "";
    errdefer freeClonedTx(alloc, &out);

    if (src.from_address.len > 0)  out.from_address  = try alloc.dupe(u8, src.from_address);
    if (src.to_address.len > 0)    out.to_address    = try alloc.dupe(u8, src.to_address);
    if (src.op_return.len > 0)     out.op_return     = try alloc.dupe(u8, src.op_return);
    if (src.script_pubkey.len > 0) out.script_pubkey = try alloc.dupe(u8, src.script_pubkey);
    if (src.script_sig.len > 0)    out.script_sig    = try alloc.dupe(u8, src.script_sig);
    if (src.signature.len > 0)     out.signature     = try alloc.dupe(u8, src.signature);
    if (src.hash.len > 0)          out.hash          = try alloc.dupe(u8, src.hash);
    if (src.public_key.len > 0)    out.public_key    = try alloc.dupe(u8, src.public_key);
    if (src.inputs.len > 0) {
        const InT = @TypeOf(src.inputs[0]);
        const buf = try alloc.alloc(InT, src.inputs.len);
        @memcpy(buf, src.inputs);
        out.inputs = buf;
    }
    if (src.outputs.len > 0) {
        const OutT = @TypeOf(src.outputs[0]);
        const buf = try alloc.alloc(OutT, src.outputs.len);
        @memcpy(buf, src.outputs);
        out.outputs = buf;
    }
    if (src.data.len > 0)          out.data          = try alloc.dupe(u8, src.data);
    return out;
}

pub fn freeClonedTx(alloc: std.mem.Allocator, tx: *Transaction) void {
    if (tx.from_address.len > 0)  alloc.free(tx.from_address);
    if (tx.to_address.len > 0)    alloc.free(tx.to_address);
    if (tx.op_return.len > 0)     alloc.free(tx.op_return);
    if (tx.script_pubkey.len > 0) alloc.free(tx.script_pubkey);
    if (tx.script_sig.len > 0)    alloc.free(tx.script_sig);
    if (tx.signature.len > 0)     alloc.free(tx.signature);
    if (tx.hash.len > 0)          alloc.free(tx.hash);
    if (tx.public_key.len > 0)    alloc.free(tx.public_key);
    if (tx.inputs.len > 0)        alloc.free(tx.inputs);
    if (tx.outputs.len > 0)       alloc.free(tx.outputs);
    if (tx.data.len > 0)          alloc.free(tx.data);
}

/// Locked read of chain length. See blockchain.zig SEGFAULT-FIX note.
pub fn getBlockCount(self: *Blockchain) u32 {
    self.mutex.lock();
    defer self.mutex.unlock();
    return @intCast(self.chain.items.len);
}

/// Lock-free length read for callers already holding self.mutex.
pub fn getBlockCountUnlocked(self: *const Blockchain) u32 {
    return @intCast(self.chain.items.len);
}

/// Self-contained snapshot of the latest block — no slice-into-chain pointers,
/// safe to use after releasing bc.mutex.
pub fn getLatestBlockSnapshot(self: *Blockchain) BlockSnapshot {
    self.mutex.lock();
    defer self.mutex.unlock();
    const last = &self.chain.items[self.chain.items.len - 1];
    var snap = BlockSnapshot{
        .height       = last.index,
        .timestamp    = last.timestamp,
        .nonce        = last.nonce,
        .difficulty   = self.difficulty,
        .tx_count     = last.transactions.items.len,
        .hash_buf     = [_]u8{0} ** 96,
        .hash_len     = 0,
        .prev_hash_buf= [_]u8{0} ** 96,
        .prev_hash_len= 0,
        .merkle_root  = last.merkle_root,
    };
    const hl = @min(last.hash.len, snap.hash_buf.len);
    @memcpy(snap.hash_buf[0..hl], last.hash[0..hl]);
    snap.hash_len = hl;
    const pl = @min(last.previous_hash.len, snap.prev_hash_buf.len);
    @memcpy(snap.prev_hash_buf[0..pl], last.previous_hash[0..pl]);
    snap.prev_hash_len = pl;
    return snap;
}
