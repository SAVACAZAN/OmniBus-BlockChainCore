const std = @import("std");
const storage_mod = @import("storage.zig");

const KeyValueStore = storage_mod.KeyValueStore;
const BlockStore = storage_mod.BlockStore;
const TransactionIndex = storage_mod.TransactionIndex;
const AddressIndex = storage_mod.AddressIndex;
const StateCheckpoint = storage_mod.StateCheckpoint;

/// Database: Unified storage layer
/// Combines block, transaction, address, and checkpoint storage
pub const Database = struct {
    blocks: BlockStore,
    transactions: TransactionIndex,
    addresses: AddressIndex,
    checkpoints: StateCheckpoint,
    metadata: KeyValueStore,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Database {
        return Database{
            .blocks = BlockStore.init(allocator),
            .transactions = TransactionIndex.init(allocator),
            .addresses = AddressIndex.init(allocator),
            .checkpoints = StateCheckpoint.init(allocator),
            .metadata = KeyValueStore.init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Database) void {
        self.blocks.deinit();
        self.transactions.deinit();
        self.addresses.deinit();
        self.checkpoints.deinit();
        self.metadata.deinit();
    }

    // Block operations
    pub fn storeBlock(self: *Database, height: u64, block_data: []const u8) !void {
        try self.blocks.storeBlock(height, block_data);
    }

    pub fn getBlock(self: *const Database, height: u64) ?[]u8 {
        return self.blocks.getBlock(height);
    }

    pub fn getBlockCount(self: *const Database) u64 {
        return self.blocks.blockCount();
    }

    // Transaction operations
    pub fn indexTransaction(self: *Database, tx_hash: []const u8, block_height: u64, tx_index: u32) !void {
        try self.transactions.indexTransaction(tx_hash, block_height, tx_index);
    }

    pub fn findTransaction(self: *const Database, tx_hash: []const u8) ?struct { block_height: u64, tx_index: u32 } {
        return self.transactions.findTransaction(tx_hash);
    }

    pub fn getTransactionCount(self: *const Database) u64 {
        return self.transactions.transactionCount();
    }

    // Address operations
    pub fn updateBalance(self: *Database, address: []const u8, balance: u64) !void {
        try self.addresses.updateBalance(address, balance);
    }

    pub fn getBalance(self: *const Database, address: []const u8) ?u64 {
        return self.addresses.getBalance(address);
    }

    pub fn getAddressCount(self: *const Database) usize {
        return self.addresses.addressCount();
    }

    // Checkpoint operations
    pub fn saveCheckpoint(self: *Database, state_data: []const u8) !u32 {
        return try self.checkpoints.save(state_data);
    }

    pub fn loadCheckpoint(self: *const Database, checkpoint_num: u32) ?[]u8 {
        return self.checkpoints.load(checkpoint_num);
    }

    pub fn loadLatestCheckpoint(self: *const Database) ?[]u8 {
        return self.checkpoints.latest();
    }

    // Metadata operations
    pub fn setMetadata(self: *Database, key: []const u8, value: []const u8) !void {
        try self.metadata.put(key, value);
    }

    pub fn getMetadata(self: *const Database, key: []const u8) ?[]u8 {
        return self.metadata.get(key);
    }

    // Database statistics
    pub fn getStats(self: *const Database) DatabaseStats {
        return DatabaseStats{
            .total_blocks = self.blocks.blockCount(),
            .total_transactions = self.transactions.transactionCount(),
            .total_addresses = self.addresses.addressCount(),
            .total_checkpoints = self.checkpoints.checkpoint_count,
        };
    }
};

pub const DatabaseStats = struct {
    total_blocks: u64,
    total_transactions: u64,
    total_addresses: usize,
    total_checkpoints: u32,
};

/// Persistent Blockchain: Database + Blockchain combined
pub const PersistentBlockchain = struct {
    db: Database,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) PersistentBlockchain {
        return PersistentBlockchain{
            .db = Database.init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *PersistentBlockchain) void {
        self.db.deinit();
    }

    /// Initialize database from file (future: RocksDB)
    pub fn loadFromDisk(allocator: std.mem.Allocator, _path: []const u8) !PersistentBlockchain {
        // TODO: Implement file I/O for RocksDB-compatible format
        _ = _path;

        return PersistentBlockchain.init(allocator);
    }

    /// Save database to disk (future: RocksDB)
    pub fn saveToDisk(self: *PersistentBlockchain, _path: []const u8) !void {
        // TODO: Implement file I/O for RocksDB-compatible format
        _ = _path;
    }

    /// Compact database (future: RocksDB Compact)
    pub fn compact(self: *PersistentBlockchain) !void {
        // TODO: Implement RocksDB-compatible compaction
        _ = self;
    }

    /// Checkpoint entire blockchain state
    pub fn checkpoint(self: *PersistentBlockchain) !u32 {
        var state_buf: [1024]u8 = undefined;
        const stats = self.db.getStats();

        const state_str = try std.fmt.bufPrint(&state_buf, "blocks:{d},txs:{d},addrs:{d}", .{
            stats.total_blocks,
            stats.total_transactions,
            stats.total_addresses,
        });

        return try self.db.saveCheckpoint(state_str);
    }

    /// Recover from checkpoint
    pub fn recoverFromCheckpoint(self: *PersistentBlockchain, checkpoint_num: u32) bool {
        const state = self.db.loadCheckpoint(checkpoint_num);
        return state != null;
    }

    /// Get database statistics
    pub fn getStats(self: *const PersistentBlockchain) DatabaseStats {
        return self.db.getStats();
    }
};

// Tests
const testing = std.testing;

test "database initialization" {
    var db = Database.init(testing.allocator);
    defer db.deinit();

    try testing.expectEqual(db.getBlockCount(), 0);
    try testing.expectEqual(db.getTransactionCount(), 0);
}

test "database block operations" {
    var db = Database.init(testing.allocator);
    defer db.deinit();

    try db.storeBlock(0, "block_0_data");
    try db.storeBlock(1, "block_1_data");

    const block0 = db.getBlock(0);
    try testing.expect(block0 != null);
    try testing.expectEqualStrings(block0.?, "block_0_data");

    try testing.expectEqual(db.getBlockCount(), 2);
}

test "database transaction index" {
    var db = Database.init(testing.allocator);
    defer db.deinit();

    try db.indexTransaction("tx_001", 0, 0);
    try db.indexTransaction("tx_002", 0, 1);
    try db.indexTransaction("tx_003", 1, 0);

    const result = db.findTransaction("tx_002");
    try testing.expect(result != null);
    try testing.expectEqual(result.?.block_height, 0);
    try testing.expectEqual(result.?.tx_index, 1);

    try testing.expectEqual(db.getTransactionCount(), 3);
}

test "database address balances" {
    var db = Database.init(testing.allocator);
    defer db.deinit();

    try db.updateBalance("ob_omni_addr1", 1000000);
    try db.updateBalance("ob_k1_addr2", 2000000);

    const balance1 = db.getBalance("ob_omni_addr1");
    try testing.expect(balance1 != null);
    try testing.expectEqual(balance1.?, 1000000);

    try testing.expectEqual(db.getAddressCount(), 2);
}

test "database checkpoints" {
    var db = Database.init(testing.allocator);
    defer db.deinit();

    const cp1 = try db.saveCheckpoint("state_v1");
    const cp2 = try db.saveCheckpoint("state_v2");

    const loaded1 = db.loadCheckpoint(cp1);
    try testing.expect(loaded1 != null);
    try testing.expectEqualStrings(loaded1.?, "state_v1");

    const latest = db.loadLatestCheckpoint();
    try testing.expect(latest != null);
    try testing.expectEqualStrings(latest.?, "state_v2");
}

test "persistent blockchain" {
    var pbc = PersistentBlockchain.init(testing.allocator);
    defer pbc.deinit();

    try pbc.db.storeBlock(0, "genesis");
    try pbc.db.updateBalance("ob_omni_test", 5000000);

    const cp = try pbc.checkpoint();
    try testing.expect(cp == 0);

    const stats = pbc.getStats();
    try testing.expectEqual(stats.total_blocks, 1);
    try testing.expectEqual(stats.total_addresses, 1);
}
