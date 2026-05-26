//! Coin Control - Manual UTXO selection for OmniBus
//! Allows users to freeze UTXOs, select specific UTXOs for spending

const std = @import("std");
const allocator = std.mem.Allocator;
const RwLock = std.Thread.RwLock;

// ============================================================
// UTXO Entry with control flags
// ============================================================

pub const UtxoStatus = enum {
    normal,      // Available for automatic selection
    frozen,      // Locked, cannot be used
    reserved,    // Reserved for pending transaction
    spent,       // Already spent (marked for cleanup)
};

pub const UtxoEntry = struct {
    txid: [32]u8,
    vout: u32,
    amount: u64,
    address: []u8,
    script_pubkey: []u8,
    status: UtxoStatus,
    created_at: u64,  // timestamp
    reserved_for: ?[]u8,  // transaction id if reserved
    
    pub fn key(self: *const UtxoEntry) [36]u8 {
        var result: [36]u8 = undefined;
        @memcpy(result[0..32], &self.txid);
        std.mem.writeInt(u32, result[32..36], self.vout, .little);
        return result;
    }
};

// ============================================================
// Coin Control Manager
// ============================================================

pub const CoinControl = struct {
    allocator: Allocator,
    utxos: std.StringHashMap(UtxoEntry),  // key: txid:vout
    lock: RwLock,
    
    pub fn init(allocator: Allocator) CoinControl {
        return .{
            .allocator = allocator,
            .utxos = std.StringHashMap(UtxoEntry).init(allocator),
            .lock = RwLock{},
        };
    }
    
    pub fn deinit(self: *CoinControl) void {
        self.lock.lock();
        defer self.lock.unlock();
        
        var it = self.utxos.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.value_ptr.address);
            self.allocator.free(entry.value_ptr.script_pubkey);
            if (entry.value_ptr.reserved_for) |res| {
                self.allocator.free(res);
            }
        }
        self.utxos.deinit();
    }
    
    /// Add a UTXO to the control set
    pub fn addUtxo(
        self: *CoinControl,
        txid: [32]u8,
        vout: u32,
        amount: u64,
        address: []const u8,
        script_pubkey: []const u8,
    ) !void {
        self.lock.lock();
        defer self.lock.unlock();
        
        const key = try self.makeKey(txid, vout);
        errdefer self.allocator.free(key);
        
        var entry = UtxoEntry{
            .txid = txid,
            .vout = vout,
            .amount = amount,
            .address = try self.allocator.dupe(u8, address),
            .script_pubkey = try self.allocator.dupe(u8, script_pubkey),
            .status = .normal,
            .created_at = @intCast(std.time.timestamp()),
            .reserved_for = null,
        };
        
        try self.utxos.put(key, entry);
    }
    
    /// Freeze a UTXO (prevents it from being used in automatic selection)
    pub fn freezeUtxo(self: *CoinControl, txid: [32]u8, vout: u32) !void {
        self.lock.lock();
        defer self.lock.unlock();
        
        const key = try self.makeKey(txid, vout);
        defer self.allocator.free(key);
        
        if (self.utxos.getPtr(key)) |entry| {
            entry.status = .frozen;
        } else {
            return error.UtxoNotFound;
        }
    }
    
    /// Unfreeze a UTXO
    pub fn unfreezeUtxo(self: *CoinControl, txid: [32]u8, vout: u32) !void {
        self.lock.lock();
        defer self.lock.unlock();
        
        const key = try self.makeKey(txid, vout);
        defer self.allocator.free(key);
        
        if (self.utxos.getPtr(key)) |entry| {
            if (entry.status == .frozen) {
                entry.status = .normal;
            }
        } else {
            return error.UtxoNotFound;
        }
    }
    
    /// Reserve UTXOs for a transaction (marks as reserved)
    pub fn reserveUtxos(
        self: *CoinControl,
        utxos: []const [36]u8,
        tx_id: []const u8,
    ) !void {
        self.lock.lock();
        defer self.lock.unlock();
        
        for (utxos) |key_bytes| {
            const key = key_bytes[0..36];
            if (self.utxos.getPtr(key)) |entry| {
                if (entry.status == .normal or entry.status == .frozen) {
                    return error.UtxoNotAvailable;
                }
                entry.status = .reserved;
                entry.reserved_for = try self.allocator.dupe(u8, tx_id);
            } else {
                return error.UtxoNotFound;
            }
        }
    }
    
    /// Release reserved UTXOs (transaction failed/cancelled)
    pub fn releaseUtxos(self: *CoinControl, tx_id: []const u8) !void {
        self.lock.lock();
        defer self.lock.unlock();
        
        var it = self.utxos.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.status == .reserved) {
                if (entry.value_ptr.reserved_for) |res| {
                    if (std.mem.eql(u8, res, tx_id)) {
                        entry.value_ptr.status = .normal;
                        self.allocator.free(res);
                        entry.value_ptr.reserved_for = null;
                    }
                }
            }
        }
    }
    
    /// Mark UTXOs as spent (remove from control set)
    pub fn markSpent(self: *CoinControl, utxos: []const [36]u8) !void {
        self.lock.lock();
        defer self.lock.unlock();
        
        for (utxos) |key_bytes| {
            const key = key_bytes[0..36];
            if (self.utxos.getPtr(key)) |entry| {
                entry.status = .spent;
            }
        }
    }
    
    /// Clean up spent UTXOs (remove from map)
    pub fn cleanupSpent(self: *CoinControl) void {
        self.lock.lock();
        defer self.lock.unlock();
        
        var to_remove = std.ArrayList([]const u8).init(self.allocator);
        defer to_remove.deinit();
        
        var it = self.utxos.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.status == .spent) {
                try to_remove.append(entry.key_ptr.*);
            }
        }
        
        for (to_remove.items) |key| {
            if (self.utxos.getPtr(key)) |entry| {
                self.allocator.free(entry.address);
                self.allocator.free(entry.script_pubkey);
                if (entry.reserved_for) |res| {
                    self.allocator.free(res);
                }
            }
            _ = self.utxos.remove(key);
        }
    }
    
    /// Manual UTXO selection (user specifies which UTXOs to use)
    pub fn selectUtxos(
        self: *CoinControl,
        utxo_keys: []const [36]u8,
    ) ![]UtxoEntry {
        self.lock.lock();
        defer self.lock.unlock();
        
        var selected = std.ArrayList(UtxoEntry).init(self.allocator);
        errdefer selected.deinit();
        
        for (utxo_keys) |key_bytes| {
            const key = key_bytes[0..36];
            if (self.utxos.get(key)) |entry| {
                if (entry.status == .normal) {
                    try selected.append(entry);
                } else {
                    return error.UtxoNotAvailable;
                }
            } else {
                return error.UtxoNotFound;
            }
        }
        
        return selected.toOwnedSlice();
    }
    
    /// Automatic UTXO selection (greedy - largest first)
    pub fn selectUtxosAuto(
        self: *CoinControl,
        target_amount: u64,
    ) !struct { utxos: []UtxoEntry, total: u64 } {
        self.lock.lock();
        defer self.lock.unlock();
        
        // Collect all normal UTXOs
        var available = std.ArrayList(UtxoEntry).init(self.allocator);
        defer available.deinit();
        
        var it = self.utxos.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.status == .normal) {
                try available.append(entry.value_ptr);
            }
        }
        
        // Sort by amount descending (greedy)
        std.mem.sort(UtxoEntry, available.items, {}, struct {
            fn lessThan(_: void, a: UtxoEntry, b: UtxoEntry) bool {
                return a.amount > b.amount;
            }
        }.lessThan);
        
        var selected = std.ArrayList(UtxoEntry).init(self.allocator);
        errdefer selected.deinit();
        
        var total: u64 = 0;
        for (available.items) |utxo| {
            if (total >= target_amount) break;
            total += utxo.amount;
            try selected.append(utxo);
        }
        
        if (total < target_amount) {
            return error.InsufficientFunds;
        }
        
        return .{
            .utxos = try selected.toOwnedSlice(),
            .total = total,
        };
    }
    
    /// Get balance (only normal UTXOs)
    pub fn getBalance(self: *CoinControl) u64 {
        self.lock.lock();
        defer self.lock.unlock();
        
        var balance: u64 = 0;
        var it = self.utxos.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.status == .normal) {
                balance += entry.value_ptr.amount;
            }
        }
        return balance;
    }
    
    /// Get frozen UTXOs list
    pub fn getFrozenUtxos(self: *CoinControl) ![]UtxoEntry {
        self.lock.lock();
        defer self.lock.unlock();
        
        var frozen = std.ArrayList(UtxoEntry).init(self.allocator);
        errdefer frozen.deinit();
        
        var it = self.utxos.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.status == .frozen) {
                try frozen.append(entry.value_ptr);
            }
        }
        
        return frozen.toOwnedSlice();
    }
    
    /// Get all UTXOs with status
    pub fn getAllUtxos(self: *CoinControl) ![]UtxoEntry {
        self.lock.lock();
        defer self.lock.unlock();
        
        var all = std.ArrayList(UtxoEntry).init(self.allocator);
        errdefer all.deinit();
        
        var it = self.utxos.iterator();
        while (it.next()) |entry| {
            try all.append(entry.value_ptr);
        }
        
        return all.toOwnedSlice();
    }
    
    // Helper: create key from txid and vout
    fn makeKey(self: *CoinControl, txid: [32]u8, vout: u32) ![]u8 {
        var key = try self.allocator.alloc(u8, 36);
        @memcpy(key[0..32], &txid);
        std.mem.writeInt(u32, key[32..36], vout, .little);
        return key;
    }
};

// ============================================================
// Tests
// ============================================================

test "CoinControl basic operations" {
    var cc = CoinControl.init(std.testing.allocator);
    defer cc.deinit();
    
    const txid = [_]u8{0x11} ** 32;
    try cc.addUtxo(txid, 0, 100000, "test_addr", "test_script");
    
    try std.testing.expectEqual(cc.getBalance(), 100000);
    
    try cc.freezeUtxo(txid, 0);
    try std.testing.expectEqual(cc.getBalance(), 0);
    
    try cc.unfreezeUtxo(txid, 0);
    try std.testing.expectEqual(cc.getBalance(), 100000);
}