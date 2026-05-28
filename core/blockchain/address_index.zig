//! Address → TX history index and TX → block-height lookup helpers,
//! extracted from blockchain.zig to keep the main file lean.
//!
//! All functions are free functions taking `*Blockchain` (or `*const Blockchain`)
//! as their first argument. The Blockchain struct itself stays in blockchain.zig
//! and re-exposes them as thin method shims so external callers keep using
//! `bc.indexAddressTx(...)` syntax.
const std = @import("std");
const blockchain_mod = @import("../blockchain.zig");

const Blockchain = blockchain_mod.Blockchain;

/// Returns the number of confirmations for a TX (null if TX not found in any block).
/// confirmations = current_chain_height - block_height_containing_tx
pub fn getConfirmations(self: *const Blockchain, tx_hash: []const u8) ?u64 {
    const block_height = self.tx_block_height.get(tx_hash) orelse return null;
    const current_height: u64 = @intCast(self.chain.items.len);
    if (current_height <= block_height) return 0;
    return current_height - block_height;
}

/// Returns the block height that contains a given TX (null if not found)
pub fn getTxBlockHeight(self: *const Blockchain, tx_hash: []const u8) ?u64 {
    return self.tx_block_height.get(tx_hash);
}

/// Index a TX hash for a given address in address_tx_index.
/// Creates the list if address not yet tracked.
pub fn indexAddressTx(self: *Blockchain, address: []const u8, tx_hash: []const u8) void {
    if (address.len == 0) return;
    const list = self.address_tx_index.getPtr(address);
    if (list) |l| {
        l.append(self.allocator, tx_hash) catch {};
    } else {
        var new_list: std.ArrayList([]const u8) = .empty;
        new_list.append(self.allocator, tx_hash) catch {};
        self.address_tx_index.put(address, new_list) catch {};
    }
}

/// Returns the list of TX hashes associated with an address (both sent and received).
/// Returns null if address has no history.
/// CALLER must hold self.mutex — this is the unlocked read path used by
/// applyBlock + RPC handlers that already hold the lock.
pub fn getAddressHistory(self: *const Blockchain, address: []const u8) ?[]const []const u8 {
    const list = self.address_tx_index.get(address) orelse return null;
    if (list.items.len == 0) return null;
    return list.items;
}

/// Thread-safe version of getAddressHistory: takes the chain mutex
/// briefly, returns an allocator-owned COPY of the hash list. Caller
/// must `allocator.free` the returned slice.
/// Fix B4: RPC handlers calling the unlocked variant concurrently with
/// applyBlock's writes triggered hashmap rehash → "incorrect alignment"
/// panic. This wrapper eliminates the race by returning a snapshot.
pub fn getAddressHistoryLocked(
    self: *Blockchain,
    allocator: std.mem.Allocator,
    address: []const u8,
) !?[][]const u8 {
    self.mutex.lock();
    defer self.mutex.unlock();
    const list = self.address_tx_index.get(address) orelse return null;
    if (list.items.len == 0) return null;
    const copy = try allocator.alloc([]const u8, list.items.len);
    for (list.items, 0..) |hash, i| {
        copy[i] = try allocator.dupe(u8, hash);
    }
    return copy;
}
