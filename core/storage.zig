const std = @import("std");

/// Locatia unei tranzactii in blockchain
pub const TxLocation = struct { block_height: u64, tx_index: u32 };

/// Key-Value Storage Interface
/// Abstracts RocksDB, SQLite, or file-based storage
pub const KeyValueStore = struct {
    allocator: std.mem.Allocator,
    data: std.StringHashMap([]u8),

    pub fn init(allocator: std.mem.Allocator) KeyValueStore {
        return KeyValueStore{
            .allocator = allocator,
            .data = std.StringHashMap([]u8).init(allocator),
        };
    }

    pub fn deinit(self: *KeyValueStore) void {
        var iter = self.data.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.data.deinit();
    }

    /// Put key-value pair
    pub fn put(self: *KeyValueStore, key: []const u8, value: []const u8) !void {
        const key_copy = try self.allocator.dupe(u8, key);
        const value_copy = try self.allocator.dupe(u8, value);

        if (self.data.get(key_copy)) |old_value| {
            self.allocator.free(old_value);
        }

        try self.data.put(key_copy, value_copy);
    }

    /// Get value by key
    pub fn get(self: *const KeyValueStore, key: []const u8) ?[]u8 {
        return self.data.get(key);
    }

    /// Delete key-value pair
    pub fn delete(self: *KeyValueStore, key: []const u8) !void {
        if (self.data.fetchRemove(key)) |entry| {
            self.allocator.free(entry.key);
            self.allocator.free(entry.value);
        }
    }

    /// Check if key exists
    pub fn contains(self: *const KeyValueStore, key: []const u8) bool {
        return self.data.contains(key);
    }

    /// Get total entries
    pub fn count(self: *const KeyValueStore) usize {
        return self.data.count();
    }

    /// Clear all entries
    pub fn clear(self: *KeyValueStore) void {
        var iter = self.data.keyIterator();
        while (iter.next()) |key| {
            if (self.data.get(key.*)) |value| {
                self.allocator.free(value);
            }
            self.allocator.free(key.*);
        }
        self.data.clearRetainingCapacity();
    }
};

/// Block Storage
pub const BlockStore = struct {
    store: KeyValueStore,
    next_block_id: u64,

    pub fn init(allocator: std.mem.Allocator) BlockStore {
        return BlockStore{
            .store = KeyValueStore.init(allocator),
            .next_block_id = 0,
        };
    }

    pub fn deinit(self: *BlockStore) void {
        self.store.deinit();
    }

    /// Store block with key "block:[height]"
    pub fn storeBlock(self: *BlockStore, block_height: u64, block_data: []const u8) !void {
        var key_buf: [32]u8 = undefined;
        const key = try std.fmt.bufPrint(&key_buf, "block:{d}", .{block_height});
        try self.store.put(key, block_data);

        if (block_height >= self.next_block_id) {
            self.next_block_id = block_height + 1;
        }
    }

    /// Retrieve block by height
    pub fn getBlock(self: *const BlockStore, block_height: u64) ?[]u8 {
        var key_buf: [32]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "block:{d}", .{block_height}) catch return null;
        return self.store.get(key);
    }

    /// Get total blocks stored
    pub fn blockCount(self: *const BlockStore) u64 {
        return self.next_block_id;
    }

    /// Delete block
    pub fn deleteBlock(self: *BlockStore, block_height: u64) !void {
        var key_buf: [32]u8 = undefined;
        const key = try std.fmt.bufPrint(&key_buf, "block:{d}", .{block_height});
        try self.store.delete(key);
    }
};

/// Transaction Index
pub const TransactionIndex = struct {
    store: KeyValueStore,
    tx_count: u64,

    pub fn init(allocator: std.mem.Allocator) TransactionIndex {
        return TransactionIndex{
            .store = KeyValueStore.init(allocator),
            .tx_count = 0,
        };
    }

    pub fn deinit(self: *TransactionIndex) void {
        self.store.deinit();
    }

    /// Index transaction: "tx:[hash]" → "block_height:tx_index"
    pub fn indexTransaction(self: *TransactionIndex, tx_hash: []const u8, block_height: u64, tx_index: u32) !void {
        var key_buf: [128]u8 = undefined;
        const key = try std.fmt.bufPrint(&key_buf, "tx:{s}", .{tx_hash});

        var value_buf: [32]u8 = undefined;
        const value = try std.fmt.bufPrint(&value_buf, "{d}:{d}", .{ block_height, tx_index });

        try self.store.put(key, value);
        self.tx_count += 1;
    }

    /// Find transaction location
    pub fn findTransaction(self: *const TransactionIndex, tx_hash: []const u8) ?TxLocation {
        var key_buf: [128]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "tx:{s}", .{tx_hash}) catch return null;

        if (self.store.get(key)) |value| {
            var iter = std.mem.splitSequence(u8, value, ":");
            const block_str = iter.next() orelse return null;
            const index_str = iter.next() orelse return null;

            const block_height = std.fmt.parseInt(u64, block_str, 10) catch return null;
            const tx_index = std.fmt.parseInt(u32, index_str, 10) catch return null;

            return .{ .block_height = block_height, .tx_index = tx_index };
        }

        return null;
    }

    /// Get total indexed transactions
    pub fn transactionCount(self: *const TransactionIndex) u64 {
        return self.tx_count;
    }
};

/// Address Balance Index
pub const AddressIndex = struct {
    store: KeyValueStore,

    pub fn init(allocator: std.mem.Allocator) AddressIndex {
        return AddressIndex{
            .store = KeyValueStore.init(allocator),
        };
    }

    pub fn deinit(self: *AddressIndex) void {
        self.store.deinit();
    }

    /// Update address balance: "addr:[address]" → "balance"
    pub fn updateBalance(self: *AddressIndex, address: []const u8, balance: u64) !void {
        var key_buf: [256]u8 = undefined;
        const key = try std.fmt.bufPrint(&key_buf, "addr:{s}", .{address});

        var value_buf: [32]u8 = undefined;
        const value = try std.fmt.bufPrint(&value_buf, "{d}", .{balance});

        try self.store.put(key, value);
    }

    /// Get address balance
    pub fn getBalance(self: *const AddressIndex, address: []const u8) ?u64 {
        var key_buf: [256]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "addr:{s}", .{address}) catch return null;

        if (self.store.get(key)) |value| {
            return std.fmt.parseInt(u64, value, 10) catch null;
        }

        return null;
    }

    /// Get all addresses
    pub fn addressCount(self: *const AddressIndex) usize {
        return self.store.count();
    }
};

/// State Checkpoint for Recovery
pub const StateCheckpoint = struct {
    store: KeyValueStore,
    checkpoint_count: u32,

    pub fn init(allocator: std.mem.Allocator) StateCheckpoint {
        return StateCheckpoint{
            .store = KeyValueStore.init(allocator),
            .checkpoint_count = 0,
        };
    }

    pub fn deinit(self: *StateCheckpoint) void {
        self.store.deinit();
    }

    /// Save checkpoint: "checkpoint:[number]" → state_data
    pub fn save(self: *StateCheckpoint, state_data: []const u8) !u32 {
        var key_buf: [32]u8 = undefined;
        const key = try std.fmt.bufPrint(&key_buf, "checkpoint:{d}", .{self.checkpoint_count});

        try self.store.put(key, state_data);

        const checkpoint_number = self.checkpoint_count;
        self.checkpoint_count += 1;

        // Keep only last 10 checkpoints
        if (self.checkpoint_count > 10) {
            const old_checkpoint = self.checkpoint_count - 11;
            var old_key_buf: [32]u8 = undefined;
            const old_key = try std.fmt.bufPrint(&old_key_buf, "checkpoint:{d}", .{old_checkpoint});
            try self.store.delete(old_key);
        }

        return checkpoint_number;
    }

    /// Load checkpoint
    pub fn load(self: *const StateCheckpoint, checkpoint_number: u32) ?[]u8 {
        var key_buf: [32]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "checkpoint:{d}", .{checkpoint_number}) catch return null;
        return self.store.get(key);
    }

    /// Get latest checkpoint
    pub fn latest(self: *const StateCheckpoint) ?[]u8 {
        if (self.checkpoint_count == 0) return null;
        return self.load(self.checkpoint_count - 1);
    }
};

// Tests
const testing = std.testing;

test "key-value store put/get" {
    var store = KeyValueStore.init(testing.allocator);
    defer store.deinit();

    try store.put("key1", "value1");
    const value = store.get("key1");
    try testing.expect(value != null);
    try testing.expectEqualStrings(value.?, "value1");
}

test "key-value store delete" {
    var store = KeyValueStore.init(testing.allocator);
    defer store.deinit();

    try store.put("key1", "value1");
    try store.delete("key1");
    try testing.expect(store.get("key1") == null);
}

test "block store" {
    var blocks = BlockStore.init(testing.allocator);
    defer blocks.deinit();

    try blocks.storeBlock(0, "genesis_block_data");
    const block = blocks.getBlock(0);
    try testing.expect(block != null);
    try testing.expectEqualStrings(block.?, "genesis_block_data");
}

test "transaction index" {
    var index = TransactionIndex.init(testing.allocator);
    defer index.deinit();

    try index.indexTransaction("tx_hash_123", 5, 0);
    const result = index.findTransaction("tx_hash_123");
    try testing.expect(result != null);
    try testing.expectEqual(result.?.block_height, 5);
}

test "address index" {
    var index = AddressIndex.init(testing.allocator);
    defer index.deinit();

    try index.updateBalance("ob_omni_abc", 1000000);
    const balance = index.getBalance("ob_omni_abc");
    try testing.expect(balance != null);
    try testing.expectEqual(balance.?, 1000000);
}

test "state checkpoint" {
    var checkpoints = StateCheckpoint.init(testing.allocator);
    defer checkpoints.deinit();

    const num = try checkpoints.save("state_data_1");
    const loaded = checkpoints.load(num);
    try testing.expect(loaded != null);
    try testing.expectEqualStrings(loaded.?, "state_data_1");
}
