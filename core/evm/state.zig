// core/evm/state.zig — EVM world state for OmniBus
// Provides EvmState: accounts + storage + chain metadata.
// No sled/db dependency — uses HashMap (suitable for in-process use).

const std = @import("std");
const types = @import("types.zig");

pub const Address = types.Address;
pub const CHAIN_ID: u64 = 7771;

// ---------------------------------------------------------------------------
// Account
// ---------------------------------------------------------------------------
pub const Account = struct {
    balance: u64,
    nonce: u64,
    /// Deployed bytecode
    code: []u8,
    /// SHA-256 of code (stub; real keccak256 in production)
    code_hash: [32]u8,

    pub fn deinit(self: *Account, alloc: std.mem.Allocator) void {
        if (self.code.len > 0) alloc.free(self.code);
    }

    pub fn clone(self: Account, alloc: std.mem.Allocator) !Account {
        // For empty code, use an empty slice without allocating (avoids aliasing
        // when self.code is a static constant like &.{}).
        const new_code: []u8 = if (self.code.len == 0)
            &.{}
        else
            try alloc.dupe(u8, self.code);
        return Account{
            .balance = self.balance,
            .nonce = self.nonce,
            .code = new_code,
            .code_hash = self.code_hash,
        };
    }
};

// ---------------------------------------------------------------------------
// Storage key helpers
// ---------------------------------------------------------------------------
/// Hex-encode an address to a 40-char key string
fn addr_to_key(buf: *[40]u8, addr: Address) []u8 {
    const hex = "0123456789abcdef";
    for (addr, 0..) |b, i| {
        buf[i * 2] = hex[b >> 4];
        buf[i * 2 + 1] = hex[b & 0xF];
    }
    return buf[0..40];
}

/// Hex-encode a 32-byte slot to a 64-char key string
fn slot_to_key(buf: *[64]u8, slot: [32]u8) []u8 {
    const hex = "0123456789abcdef";
    for (slot, 0..) |b, i| {
        buf[i * 2] = hex[b >> 4];
        buf[i * 2 + 1] = hex[b & 0xF];
    }
    return buf[0..64];
}

// ---------------------------------------------------------------------------
// EvmState
// ---------------------------------------------------------------------------
pub const EvmState = struct {
    alloc: std.mem.Allocator,
    accounts: std.StringHashMap(Account),
    /// storage[address_hex][slot_hex] = value_bytes32
    storage: std.StringHashMap(std.StringHashMap([32]u8)),
    block_number: u64,
    chain_id: u64,
    timestamp: u64,

    pub fn init(alloc: std.mem.Allocator) EvmState {
        return EvmState{
            .alloc = alloc,
            .accounts = std.StringHashMap(Account).init(alloc),
            .storage = std.StringHashMap(std.StringHashMap([32]u8)).init(alloc),
            .block_number = 0,
            .chain_id = CHAIN_ID,
            .timestamp = 0,
        };
    }

    pub fn deinit(self: *EvmState) void {
        // Free accounts
        var acc_iter = self.accounts.iterator();
        while (acc_iter.next()) |entry| {
            var acc = entry.value_ptr.*;
            acc.deinit(self.alloc);
            self.alloc.free(entry.key_ptr.*);
        }
        self.accounts.deinit();

        // Free storage inner maps and keys
        var stor_iter = self.storage.iterator();
        while (stor_iter.next()) |entry| {
            var inner = entry.value_ptr.*;
            var inner_iter = inner.iterator();
            while (inner_iter.next()) |inner_entry| {
                self.alloc.free(inner_entry.key_ptr.*);
            }
            inner.deinit();
            self.alloc.free(entry.key_ptr.*);
        }
        self.storage.deinit();
    }

    /// Deep-clone the entire state (for execute_call read-only semantics)
    pub fn clone(self: *const EvmState) !EvmState {
        var new_state = EvmState.init(self.alloc);
        new_state.block_number = self.block_number;
        new_state.chain_id = self.chain_id;
        new_state.timestamp = self.timestamp;

        var acc_iter = self.accounts.iterator();
        while (acc_iter.next()) |entry| {
            const key_copy = try self.alloc.dupe(u8, entry.key_ptr.*);
            const acc_copy = try entry.value_ptr.clone(self.alloc);
            try new_state.accounts.put(key_copy, acc_copy);
        }

        var stor_iter = self.storage.iterator();
        while (stor_iter.next()) |entry| {
            const outer_key = try self.alloc.dupe(u8, entry.key_ptr.*);
            var new_inner = std.StringHashMap([32]u8).init(self.alloc);
            var inner_iter = entry.value_ptr.iterator();
            while (inner_iter.next()) |inner_entry| {
                const slot_key = try self.alloc.dupe(u8, inner_entry.key_ptr.*);
                try new_inner.put(slot_key, inner_entry.value_ptr.*);
            }
            try new_state.storage.put(outer_key, new_inner);
        }

        return new_state;
    }

    /// Get account by address (returns null if not found)
    pub fn getAccount(self: *EvmState, addr: Address) ?Account {
        var buf: [40]u8 = undefined;
        const key = addr_to_key(&buf, addr);
        return self.accounts.get(key);
    }

    /// Get account by address (const version)
    pub fn getAccountConst(self: *const EvmState, addr: Address) ?Account {
        var buf: [40]u8 = undefined;
        const hex = "0123456789abcdef";
        for (addr, 0..) |b, i| {
            buf[i * 2] = hex[b >> 4];
            buf[i * 2 + 1] = hex[b & 0xF];
        }
        return self.accounts.get(buf[0..40]);
    }

    /// Set (or upsert) an account. Frees old code if present.
    pub fn setAccount(self: *EvmState, addr: Address, acc: Account) !void {
        var buf: [40]u8 = undefined;
        const key = addr_to_key(&buf, addr);

        // Clone the incoming account BEFORE removing the old one.
        // This avoids use-after-free: if the caller obtained `acc` from
        // getAccount(), acc.code points into the old slot. Freeing the old
        // slot then duping would alias freed memory.
        const key_owned = try self.alloc.dupe(u8, key);
        errdefer self.alloc.free(key_owned);
        const acc_copy = try acc.clone(self.alloc);
        errdefer {
            var tmp = acc_copy;
            tmp.deinit(self.alloc);
        }

        // Now it is safe to remove (and free) the old entry.
        if (self.accounts.fetchRemove(key)) |old| {
            var old_acc = old.value;
            old_acc.deinit(self.alloc);
            self.alloc.free(old.key);
        }

        try self.accounts.put(key_owned, acc_copy);
    }

    /// Read storage slot. Returns [0;32] if not set.
    pub fn readStorage(self: *const EvmState, addr: Address, slot: [32]u8) [32]u8 {
        var abuf: [40]u8 = undefined;
        const hex = "0123456789abcdef";
        for (addr, 0..) |b, i| {
            abuf[i * 2] = hex[b >> 4];
            abuf[i * 2 + 1] = hex[b & 0xF];
        }
        const akey = abuf[0..40];
        const inner = self.storage.get(akey) orelse return [_]u8{0} ** 32;

        var sbuf: [64]u8 = undefined;
        for (slot, 0..) |b, i| {
            sbuf[i * 2] = hex[b >> 4];
            sbuf[i * 2 + 1] = hex[b & 0xF];
        }
        const skey = sbuf[0..64];
        return inner.get(skey) orelse [_]u8{0} ** 32;
    }

    /// Write storage slot.
    pub fn writeStorage(self: *EvmState, addr: Address, slot: [32]u8, val: [32]u8) !void {
        var abuf: [40]u8 = undefined;
        var sbuf: [64]u8 = undefined;
        const akey = addr_to_key(&abuf, addr);
        const skey = slot_to_key(&sbuf, slot);

        // Get or create inner map for address
        const gop = try self.storage.getOrPut(try self.alloc.dupe(u8, akey));
        if (!gop.found_existing) {
            gop.value_ptr.* = std.StringHashMap([32]u8).init(self.alloc);
        }

        // Insert slot (duplicate key if new)
        const inner = gop.value_ptr;
        if (inner.contains(skey)) {
            inner.getPtr(skey).?.* = val;
        } else {
            const slot_key_owned = try self.alloc.dupe(u8, skey);
            try inner.put(slot_key_owned, val);
        }
    }

    /// Get balance of an address
    pub fn getBalance(self: *const EvmState, addr: Address) u64 {
        return if (self.getAccountConst(addr)) |a| a.balance else 0;
    }

    /// Get nonce of an address
    pub fn getNonce(self: *const EvmState, addr: Address) u64 {
        return if (self.getAccountConst(addr)) |a| a.nonce else 0;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
const testing = std.testing;

test "EvmState get/set account" {
    var state = EvmState.init(testing.allocator);
    defer state.deinit();

    const addr = [_]u8{0x01} ** 20;
    const acc = Account{
        .balance = 1000,
        .nonce = 1,
        .code = &.{},
        .code_hash = [_]u8{0} ** 32,
    };
    try state.setAccount(addr, acc);
    const got = state.getAccount(addr);
    try testing.expect(got != null);
    try testing.expectEqual(@as(u64, 1000), got.?.balance);
}

test "EvmState storage round-trip" {
    var state = EvmState.init(testing.allocator);
    defer state.deinit();

    const addr = [_]u8{0x02} ** 20;
    const slot = [_]u8{0x01} ** 32;
    const val = [_]u8{0xFF} ** 32;

    const zero = state.readStorage(addr, slot);
    try testing.expectEqual([_]u8{0} ** 32, zero);

    try state.writeStorage(addr, slot, val);
    const got = state.readStorage(addr, slot);
    try testing.expectEqual(val, got);
}

test "EvmState clone" {
    var state = EvmState.init(testing.allocator);
    defer state.deinit();

    const addr = [_]u8{0x03} ** 20;
    const acc = Account{
        .balance = 500,
        .nonce = 2,
        .code = &.{},
        .code_hash = [_]u8{0} ** 32,
    };
    try state.setAccount(addr, acc);

    var cloned = try state.clone();
    defer cloned.deinit();

    const got = cloned.getAccount(addr);
    try testing.expect(got != null);
    try testing.expectEqual(@as(u64, 500), got.?.balance);

    // Mutate original, clone unaffected
    var acc2 = acc;
    acc2.balance = 999;
    try state.setAccount(addr, acc2);
    const still_500 = cloned.getAccount(addr);
    try testing.expectEqual(@as(u64, 500), still_500.?.balance);
}
