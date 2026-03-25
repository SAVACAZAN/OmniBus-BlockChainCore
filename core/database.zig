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

    /// Incarca database din fisier (format binar simplu, fara dependente externe)
    /// Format fisier: [magic:4][version:1][block_count:4]
    ///   per bloc: [height:8][data_len:4][data...]
    ///   [addr_count:4]
    ///   per adresa: [addr_len:1][addr...][balance:8]
    pub fn loadFromDisk(allocator: std.mem.Allocator, path: []const u8) !PersistentBlockchain {
        var pbc = PersistentBlockchain.init(allocator);

        const file = std.fs.cwd().openFile(path, .{}) catch |err| {
            if (err == error.FileNotFound) return pbc; // fisier nou — ok
            return err;
        };
        defer file.close();

        // Read entire file into memory
        const stat = file.stat() catch return pbc;
        if (stat.size == 0) return pbc;
        const buf = allocator.alloc(u8, stat.size) catch return pbc;
        defer allocator.free(buf);
        const read_len = file.readAll(buf) catch return pbc;
        if (read_len < 9) return pbc; // magic(4) + version(1) + block_count(4)

        var pos: usize = 0;

        // Magic + version
        if (!std.mem.eql(u8, buf[0..4], "OMNI")) return pbc;
        pos = 4;
        if (buf[pos] != 1) return pbc;
        pos += 1;

        // Block count
        if (pos + 4 > read_len) return pbc;
        const block_count = std.mem.readInt(u32, buf[pos..][0..4], .little);
        pos += 4;

        var i: u32 = 0;
        while (i < block_count) : (i += 1) {
            if (pos + 12 > read_len) break; // height(8) + data_len(4)
            const height = std.mem.readInt(u64, buf[pos..][0..8], .little);
            pos += 8;
            const data_len = std.mem.readInt(u32, buf[pos..][0..4], .little);
            pos += 4;
            if (pos + data_len > read_len) break;
            const data = buf[pos .. pos + data_len];
            pos += data_len;
            pbc.db.storeBlock(height, data) catch break;
        }

        // Address balances
        if (pos + 4 > read_len) {
            std.debug.print("[DB] Loaded from {s}: {d} blocks, 0 addresses\n",
                .{ path, block_count });
            return pbc;
        }
        const addr_count = std.mem.readInt(u32, buf[pos..][0..4], .little);
        pos += 4;

        var j: u32 = 0;
        while (j < addr_count) : (j += 1) {
            if (pos + 1 > read_len) break;
            const addr_len = buf[pos];
            pos += 1;
            if (pos + addr_len + 8 > read_len) break;
            const addr = buf[pos .. pos + addr_len];
            pos += addr_len;
            const balance = std.mem.readInt(u64, buf[pos..][0..8], .little);
            pos += 8;
            pbc.db.updateBalance(addr, balance) catch break;
        }

        std.debug.print("[DB] Loaded from {s}: {d} blocks, {d} addresses\n",
            .{ path, block_count, addr_count });
        return pbc;
    }

    /// Salveaza database pe disc (format binar simplu, atomic via tmp+rename)
    pub fn saveToDisk(self: *PersistentBlockchain, path: []const u8) !void {
        const tmp_path = try std.fmt.allocPrint(self.allocator, "{s}.tmp", .{path});
        defer self.allocator.free(tmp_path);

        // Build output buffer in memory
        var out = std.array_list.Managed(u8).init(self.allocator);
        defer out.deinit();

        // Magic + version
        try out.appendSlice("OMNI");
        try out.append(1);

        // Block count + blocks
        const stats = self.db.getStats();
        var hdr4: [4]u8 = undefined;
        std.mem.writeInt(u32, &hdr4, @intCast(stats.total_blocks), .little);
        try out.appendSlice(&hdr4);

        var height: u64 = 0;
        while (height < stats.total_blocks) : (height += 1) {
            if (self.db.getBlock(height)) |data| {
                var h8: [8]u8 = undefined;
                var l4: [4]u8 = undefined;
                std.mem.writeInt(u64, &h8, height, .little);
                std.mem.writeInt(u32, &l4, @intCast(data.len), .little);
                try out.appendSlice(&h8);
                try out.appendSlice(&l4);
                try out.appendSlice(data);
            }
        }

        // Address balances
        const addr_store = &self.db.addresses.store.data;
        var cnt4: [4]u8 = undefined;
        std.mem.writeInt(u32, &cnt4, @intCast(addr_store.count()), .little);
        try out.appendSlice(&cnt4);
        var it = addr_store.iterator();
        while (it.next()) |entry| {
            const key = entry.key_ptr.*;
            const val_str = entry.value_ptr.*;
            if (key.len <= 5) continue;
            const addr = key[5..]; // strip "addr:" prefix
            const balance = std.fmt.parseInt(u64, val_str, 10) catch 0;
            try out.append(@intCast(addr.len));
            try out.appendSlice(addr);
            var b8: [8]u8 = undefined;
            std.mem.writeInt(u64, &b8, balance, .little);
            try out.appendSlice(&b8);
        }

        // Write atomically: tmp file then rename
        const file = try std.fs.cwd().createFile(tmp_path, .{});
        try file.writeAll(out.items);
        file.close();
        try std.fs.cwd().rename(tmp_path, path);

        std.debug.print("[DB] Saved to {s}: {d} blocks, {d} addresses\n",
            .{ path, stats.total_blocks, addr_store.count() });
    }

    /// Compact — sterge blocuri vechi pastrand ultimele N (viitor RocksDB)
    pub fn compact(self: *PersistentBlockchain) !void {
        _ = self; // TODO: RocksDB compaction
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
    _ = try db.saveCheckpoint("state_v2");

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
