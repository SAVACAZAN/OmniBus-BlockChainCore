const std = @import("std");
const storage_mod = @import("storage.zig");
const blockchain_mod = @import("blockchain.zig");
const block_mod = @import("block.zig");
const array_list = std.array_list;

const KeyValueStore = storage_mod.KeyValueStore;
const BlockStore = storage_mod.BlockStore;
const TransactionIndex = storage_mod.TransactionIndex;
const AddressIndex = storage_mod.AddressIndex;
const StateCheckpoint = storage_mod.StateCheckpoint;

/// File format constants
const DB_MAGIC = [4]u8{ 'O', 'M', 'N', 'I' };
const DB_VERSION: u32 = 2;
const CRC = std.hash.crc.Crc32;

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

    pub fn findTransaction(self: *const Database, tx_hash: []const u8) ?storage_mod.TxLocation {
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

/// Compute CRC32 of a byte slice
fn computeCrc32(data: []const u8) u32 {
    return CRC.hash(data);
}

/// Write a u32 CRC32 checksum to an output buffer
fn appendCrc32(out: *array_list.Managed(u8), data_start: usize) !void {
    const section_data = out.items[data_start..];
    const crc = computeCrc32(section_data);
    var crc_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &crc_buf, crc, .little);
    try out.appendSlice(&crc_buf);
}

/// Verify CRC32 checksum at the end of a section
/// Returns true if valid, false if mismatch
fn verifyCrc32(buf: []const u8, section_start: usize, section_end: usize) bool {
    if (section_end + 4 > buf.len) return false;
    const section_data = buf[section_start..section_end];
    const expected = computeCrc32(section_data);
    const stored = std.mem.readInt(u32, buf[section_end..][0..4], .little);
    return expected == stored;
}

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

    /// Write the v2 file header: [magic:4][version:4]
    fn writeV2Header(out: *array_list.Managed(u8)) !void {
        try out.appendSlice(&DB_MAGIC);
        var ver_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &ver_buf, DB_VERSION, .little);
        try out.appendSlice(&ver_buf);
    }

    /// Salveaza blockchain-ul activ (bc) pe disc
    /// Format v2: [magic:4][version:4]
    ///   [block_count:4] per bloc: [height:8][data_len:4][data...] [crc32:4]
    ///   [addr_count:4]  per adresa: [addr_len:1][addr...][balance:8] [crc32:4]
    ///   [nonce_count:4] per nonce: [addr_len:1][addr...][nonce:8] [crc32:4]
    ///   [tx_count:4]    per tx: [hash_len:1][hash...][height:8] [crc32:4]
    pub fn saveBlockchain(self: *PersistentBlockchain, bc: *const blockchain_mod.Blockchain, path: []const u8) !void {
        const tmp_path = try std.fmt.allocPrint(self.allocator, "{s}.tmp", .{path});
        defer self.allocator.free(tmp_path);

        var out = array_list.Managed(u8).init(self.allocator);
        defer out.deinit();

        // V2 header: magic(4) + version(4) = 8 bytes
        try writeV2Header(&out);

        // === Blocks section ===
        const section_blocks_start = out.items.len;

        const chain = bc.chain.items;
        const save_count: u32 = if (chain.len > 1) @intCast(chain.len - 1) else 0;
        var hdr4: [4]u8 = undefined;
        std.mem.writeInt(u32, &hdr4, save_count, .little);
        try out.appendSlice(&hdr4);

        // Blocks (index 1..N — skip genesis)
        for (chain[1..]) |blk| {
            var data_buf: [512]u8 = undefined;
            const data = try std.fmt.bufPrint(&data_buf, "{d}|{d}|{d}|{s}|{s}|{s}|{d}", .{
                blk.index, blk.timestamp, blk.nonce,
                blk.previous_hash, blk.hash,
                blk.miner_address, blk.reward_sat,
            });
            var h8: [8]u8 = undefined;
            var l4: [4]u8 = undefined;
            std.mem.writeInt(u64, &h8, blk.index, .little);
            std.mem.writeInt(u32, &l4, @intCast(data.len), .little);
            try out.appendSlice(&h8);
            try out.appendSlice(&l4);
            try out.appendSlice(data);
        }

        try appendCrc32(&out, section_blocks_start);

        // === Balances section ===
        const section_bal_start = out.items.len;

        var cnt4: [4]u8 = undefined;
        std.mem.writeInt(u32, &cnt4, @intCast(bc.balances.count()), .little);
        try out.appendSlice(&cnt4);
        var it = bc.balances.iterator();
        while (it.next()) |entry| {
            const addr = entry.key_ptr.*;
            const bal = entry.value_ptr.*;
            if (addr.len > 255) continue;
            try out.append(@intCast(addr.len));
            try out.appendSlice(addr);
            var b8: [8]u8 = undefined;
            std.mem.writeInt(u64, &b8, bal, .little);
            try out.appendSlice(&b8);
        }

        try appendCrc32(&out, section_bal_start);

        // === Nonces section ===
        const section_nonce_start = out.items.len;

        var ncnt4: [4]u8 = undefined;
        std.mem.writeInt(u32, &ncnt4, @intCast(bc.nonces.count()), .little);
        try out.appendSlice(&ncnt4);
        var nit = bc.nonces.iterator();
        while (nit.next()) |entry| {
            const addr = entry.key_ptr.*;
            const nonce_val = entry.value_ptr.*;
            if (addr.len > 255) continue;
            try out.append(@intCast(addr.len));
            try out.appendSlice(addr);
            var n8: [8]u8 = undefined;
            std.mem.writeInt(u64, &n8, nonce_val, .little);
            try out.appendSlice(&n8);
        }

        try appendCrc32(&out, section_nonce_start);

        // === TX confirmation section ===
        const section_tx_start = out.items.len;

        var tcnt4: [4]u8 = undefined;
        std.mem.writeInt(u32, &tcnt4, @intCast(bc.tx_block_height.count()), .little);
        try out.appendSlice(&tcnt4);
        var tit = bc.tx_block_height.iterator();
        while (tit.next()) |entry| {
            const tx_hash = entry.key_ptr.*;
            const height = entry.value_ptr.*;
            if (tx_hash.len > 255) continue;
            try out.append(@intCast(tx_hash.len));
            try out.appendSlice(tx_hash);
            var th8: [8]u8 = undefined;
            std.mem.writeInt(u64, &th8, height, .little);
            try out.appendSlice(&th8);
        }

        try appendCrc32(&out, section_tx_start);

        // Atomic write: tmp file then rename
        const file = try std.fs.cwd().createFile(tmp_path, .{});
        try file.writeAll(out.items);
        file.close();
        try std.fs.cwd().rename(tmp_path, path);

        std.debug.print("[DB] Saved v2 {d} blocks + {d} balances + {d} nonces + {d} tx_confirms → {s}\n",
            .{ save_count, bc.balances.count(), bc.nonces.count(), bc.tx_block_height.count(), path });
    }

    /// Create a backup of the database file before loading (.dat → .dat.bak)
    fn backupOnStartup(path: []const u8, allocator: std.mem.Allocator) void {
        const bak_path = std.fmt.allocPrint(allocator, "{s}.bak", .{path}) catch return;
        defer allocator.free(bak_path);

        const cwd = std.fs.cwd();
        // Copy path → path.bak (overwrite previous backup)
        cwd.copyFile(path, cwd, bak_path, .{}) catch |err| {
            if (err != error.FileNotFound) {
                std.debug.print("[DB] Warning: could not create backup {s}: {any}\n", .{ bak_path, err });
            }
            return;
        };
        std.debug.print("[DB] Backup created: {s}\n", .{bak_path});
    }

    /// Detect file version: returns 1 for v1 format, 2 for v2, 0 for invalid/unknown
    fn detectVersion(buf: []const u8) u32 {
        if (buf.len < 8) return 0;
        // Check magic bytes
        if (!std.mem.eql(u8, buf[0..4], &DB_MAGIC)) return 0;
        // V1: byte at offset 4 == 1, followed by block_count as u32
        // V2: u32 at offset 4 == 2
        // Distinguish: v1 has buf[4]==1 and buf[5..8] is block_count (could be anything)
        //              v2 has le32 at offset 4 == 2, meaning buf[4]==2, buf[5]==0, buf[6]==0, buf[7]==0
        const ver_u32 = std.mem.readInt(u32, buf[4..8], .little);
        if (ver_u32 == DB_VERSION) return DB_VERSION;
        // V1: single byte version == 1
        if (buf[4] == 1) return 1;
        return 0;
    }

    /// Validate chain integrity: genesis hash and prev_hash linkage
    fn validateChainIntegrity(bc: *const blockchain_mod.Blockchain) void {
        const chain = bc.chain.items;
        if (chain.len == 0) return;

        // Log genesis hash
        std.debug.print("[DB] Integrity: genesis hash = {s}\n", .{chain[0].hash});

        // Check prev_hash linkage
        var broken: u32 = 0;
        var i: usize = 1;
        while (i < chain.len) : (i += 1) {
            if (!std.mem.eql(u8, chain[i].previous_hash, chain[i - 1].hash)) {
                if (broken < 5) { // limit spam
                    std.debug.print("[DB] Integrity WARNING: block {d} prev_hash mismatch (expected {s}, got {s})\n",
                        .{ chain[i].index, chain[i - 1].hash, chain[i].previous_hash });
                }
                broken += 1;
            }
        }
        if (broken == 0) {
            std.debug.print("[DB] Integrity OK: {d} blocks, prev_hash chain verified\n", .{chain.len});
        } else {
            std.debug.print("[DB] Integrity: {d} prev_hash linkage errors in {d} blocks\n", .{ broken, chain.len });
        }
    }

    /// Reincarca blockchain-ul din disc in bc (apelat dupa buildBlockchain/genesis)
    /// Supports both v1 and v2 file formats. V2 adds CRC32 checksums per section.
    /// Creates .bak backup before loading. Falls back to .bak if .dat is corrupt.
    pub fn restoreInto(self: *PersistentBlockchain, bc: *blockchain_mod.Blockchain, path: []const u8) !void {
        // Backup on startup
        backupOnStartup(path, self.allocator);

        // Try loading from primary file
        const result = self.restoreFromFile(bc, path);
        if (result) |_| {
            // Success — validate chain integrity
            validateChainIntegrity(bc);
            return;
        } else |_| {
            // Primary file failed — try backup
            const bak_path = try std.fmt.allocPrint(self.allocator, "{s}.bak", .{path});
            defer self.allocator.free(bak_path);
            std.debug.print("[DB] Primary file {s} corrupt/unreadable — trying backup {s}\n", .{ path, bak_path });
            self.restoreFromFile(bc, bak_path) catch |err2| {
                std.debug.print("[DB] Backup also failed: {any} — starting from genesis\n", .{err2});
                return;
            };
            validateChainIntegrity(bc);
        }
    }

    /// Core restore logic from a specific file path
    fn restoreFromFile(self: *PersistentBlockchain, bc: *blockchain_mod.Blockchain, path: []const u8) !void {
        const file = std.fs.cwd().openFile(path, .{}) catch |err| {
            if (err == error.FileNotFound) {
                std.debug.print("[DB] Fisier nou {s} — pornire de la genesis\n", .{path});
                return;
            }
            return err;
        };
        defer file.close();

        const stat = try file.stat();
        if (stat.size == 0) return;
        const buf = try self.allocator.alloc(u8, stat.size);
        defer self.allocator.free(buf);
        const read_len = try file.readAll(buf);
        if (read_len < 8) return;

        const version = detectVersion(buf[0..read_len]);
        if (version == 0) {
            std.debug.print("[DB] Invalid magic bytes in {s} — file corrupt\n", .{path});
            return error.InvalidMagic;
        }

        if (version == 1) {
            std.debug.print("[DB] Detected v1 format in {s} — loading with backward compat\n", .{path});
            return self.restoreV1(bc, buf[0..read_len], path);
        }

        // V2 format
        return self.restoreV2(bc, buf[0..read_len], path);
    }

    /// Restore from v1 format (backward compatibility)
    fn restoreV1(self: *PersistentBlockchain, bc: *blockchain_mod.Blockchain, buf: []const u8, path: []const u8) !void {
        const read_len = buf.len;
        if (read_len < 9) return;

        var pos: usize = 5; // skip magic(4) + version(1)

        const block_count = std.mem.readInt(u32, buf[pos..][0..4], .little);
        pos += 4;

        try bc.chain.ensureTotalCapacity(bc.chain.items.len + block_count);

        var loaded_blocks: u32 = 0;
        var i: u32 = 0;
        while (i < block_count) : (i += 1) {
            if (pos + 12 > read_len) break;
            const height = std.mem.readInt(u64, buf[pos..][0..8], .little);
            pos += 8;
            const data_len = std.mem.readInt(u32, buf[pos..][0..4], .little);
            pos += 4;
            if (pos + data_len > read_len) break;
            const data = buf[pos .. pos + data_len];
            pos += data_len;

            const blk = try self.parseBlockData(bc, data, height);
            bc.chain.appendAssumeCapacity(blk);
            loaded_blocks += 1;
        }

        // Balances
        var addr_count: u32 = 0;
        if (pos + 4 <= read_len) {
            addr_count = std.mem.readInt(u32, buf[pos..][0..4], .little);
            pos += 4;
            pos = try restoreAddressSection(bc, buf, pos, read_len, addr_count);
        }

        // Nonces (optional in v1)
        var nonce_count: u32 = 0;
        if (pos + 4 <= read_len) {
            nonce_count = std.mem.readInt(u32, buf[pos..][0..4], .little);
            pos += 4;
            pos = try restoreNonceSection(bc, buf, pos, read_len, nonce_count);
        }

        // TX confirms (optional in v1)
        var tx_confirm_count: u32 = 0;
        if (pos + 4 <= read_len) {
            tx_confirm_count = std.mem.readInt(u32, buf[pos..][0..4], .little);
            pos += 4;
            pos = try restoreTxConfirmSection(bc, buf, pos, read_len, tx_confirm_count);
        }

        logRestoreSummary(bc, loaded_blocks, addr_count, nonce_count, tx_confirm_count, path);
    }

    /// Restore from v2 format (with CRC32 checksums)
    fn restoreV2(self: *PersistentBlockchain, bc: *blockchain_mod.Blockchain, buf: []const u8, path: []const u8) !void {
        const read_len = buf.len;
        if (read_len < 12) return; // header(8) + block_count(4) minimum

        var pos: usize = 8; // skip magic(4) + version(4)

        // === Blocks section ===
        const section_blocks_start = pos;
        if (pos + 4 > read_len) return;
        const block_count = std.mem.readInt(u32, buf[pos..][0..4], .little);
        pos += 4;

        try bc.chain.ensureTotalCapacity(bc.chain.items.len + block_count);

        var loaded_blocks: u32 = 0;
        var i: u32 = 0;
        while (i < block_count) : (i += 1) {
            if (pos + 12 > read_len) break;
            const height = std.mem.readInt(u64, buf[pos..][0..8], .little);
            pos += 8;
            const data_len = std.mem.readInt(u32, buf[pos..][0..4], .little);
            pos += 4;
            if (pos + data_len > read_len) break;
            const data = buf[pos .. pos + data_len];
            pos += data_len;

            const blk = try self.parseBlockData(bc, data, height);
            bc.chain.appendAssumeCapacity(blk);
            loaded_blocks += 1;
        }

        // Verify blocks section CRC
        if (pos + 4 <= read_len) {
            if (!verifyCrc32(buf, section_blocks_start, pos)) {
                std.debug.print("[DB] WARNING: blocks section CRC32 mismatch in {s}\n", .{path});
            }
            pos += 4; // skip CRC
        }

        // === Balances section ===
        var addr_count: u32 = 0;
        if (pos + 4 <= read_len) {
            const section_bal_start = pos;
            addr_count = std.mem.readInt(u32, buf[pos..][0..4], .little);
            pos += 4;
            pos = try restoreAddressSection(bc, buf, pos, read_len, addr_count);

            // Verify balances CRC
            if (pos + 4 <= read_len) {
                if (!verifyCrc32(buf, section_bal_start, pos)) {
                    std.debug.print("[DB] WARNING: balances section CRC32 mismatch in {s}\n", .{path});
                }
                pos += 4;
            }
        }

        // === Nonces section ===
        var nonce_count: u32 = 0;
        if (pos + 4 <= read_len) {
            const section_nonce_start = pos;
            nonce_count = std.mem.readInt(u32, buf[pos..][0..4], .little);
            pos += 4;
            pos = try restoreNonceSection(bc, buf, pos, read_len, nonce_count);

            if (pos + 4 <= read_len) {
                if (!verifyCrc32(buf, section_nonce_start, pos)) {
                    std.debug.print("[DB] WARNING: nonces section CRC32 mismatch in {s}\n", .{path});
                }
                pos += 4;
            }
        }

        // === TX confirms section ===
        var tx_confirm_count: u32 = 0;
        if (pos + 4 <= read_len) {
            const section_tx_start = pos;
            tx_confirm_count = std.mem.readInt(u32, buf[pos..][0..4], .little);
            pos += 4;
            pos = try restoreTxConfirmSection(bc, buf, pos, read_len, tx_confirm_count);

            if (pos + 4 <= read_len) {
                if (!verifyCrc32(buf, section_tx_start, pos)) {
                    std.debug.print("[DB] WARNING: tx_confirms section CRC32 mismatch in {s}\n", .{path});
                }
                pos += 4;
            }
        }

        logRestoreSummary(bc, loaded_blocks, addr_count, nonce_count, tx_confirm_count, path);
    }

    /// Parse a single block's pipe-delimited data and return a Block struct
    fn parseBlockData(self: *PersistentBlockchain, bc: *blockchain_mod.Blockchain, data: []const u8, height: u64) !block_mod.Block {
        var parts = std.mem.splitScalar(u8, data, '|');
        const p_index = parts.next() orelse return error.InvalidBlockData;
        const p_ts = parts.next() orelse return error.InvalidBlockData;
        const p_nonce = parts.next() orelse return error.InvalidBlockData;
        const p_prev = parts.next() orelse return error.InvalidBlockData;
        const p_hash = parts.next() orelse return error.InvalidBlockData;
        const p_miner = parts.next() orelse "";
        const p_reward = parts.next() orelse "0";

        const blk_index = std.fmt.parseInt(u32, p_index, 10) catch return error.InvalidBlockData;
        const blk_ts = std.fmt.parseInt(i64, p_ts, 10) catch return error.InvalidBlockData;
        const blk_nonce = std.fmt.parseInt(u64, p_nonce, 10) catch return error.InvalidBlockData;
        const blk_reward = std.fmt.parseInt(u64, p_reward, 10) catch 0;

        _ = height; // height == blk_index
        _ = p_prev; // previous_hash taken from chain, not from file

        const hash_copy = try self.allocator.dupe(u8, p_hash);
        const miner_copy = try self.allocator.dupe(u8, p_miner);
        const prev_block_hash = bc.chain.items[bc.chain.items.len - 1].hash;

        return block_mod.Block{
            .index = blk_index,
            .timestamp = blk_ts,
            .transactions = array_list.Managed(block_mod.Transaction).init(self.allocator),
            .previous_hash = prev_block_hash,
            .nonce = blk_nonce,
            .hash = hash_copy,
            .miner_address = miner_copy,
            .reward_sat = blk_reward,
            .miner_heap = true,
        };
    }

    /// Restore address balances from buffer, returns new pos
    fn restoreAddressSection(bc: *blockchain_mod.Blockchain, buf: []const u8, start_pos: usize, read_len: usize, addr_count: u32) !usize {
        var pos = start_pos;
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
            try bc.balances.put(addr, balance);
        }
        return pos;
    }

    /// Restore nonces from buffer, returns new pos
    fn restoreNonceSection(bc: *blockchain_mod.Blockchain, buf: []const u8, start_pos: usize, read_len: usize, nonce_count: u32) !usize {
        var pos = start_pos;
        var k: u32 = 0;
        while (k < nonce_count) : (k += 1) {
            if (pos + 1 > read_len) break;
            const n_addr_len = buf[pos];
            pos += 1;
            if (pos + n_addr_len + 8 > read_len) break;
            const n_addr = buf[pos .. pos + n_addr_len];
            pos += n_addr_len;
            const nonce_val = std.mem.readInt(u64, buf[pos..][0..8], .little);
            pos += 8;
            try bc.nonces.put(n_addr, nonce_val);
        }
        return pos;
    }

    /// Restore tx confirmation index from buffer, returns new pos
    fn restoreTxConfirmSection(bc: *blockchain_mod.Blockchain, buf: []const u8, start_pos: usize, read_len: usize, tx_count: u32) !usize {
        var pos = start_pos;
        var t: u32 = 0;
        while (t < tx_count) : (t += 1) {
            if (pos + 1 > read_len) break;
            const th_len = buf[pos];
            pos += 1;
            if (pos + th_len + 8 > read_len) break;
            const th_hash = buf[pos .. pos + th_len];
            pos += th_len;
            const th_height = std.mem.readInt(u64, buf[pos..][0..8], .little);
            pos += 8;
            try bc.tx_block_height.put(th_hash, th_height);
        }
        return pos;
    }

    /// Log restore summary with offline gap
    fn logRestoreSummary(bc: *const blockchain_mod.Blockchain, loaded_blocks: u32, addr_count: u32, nonce_count: u32, tx_confirm_count: u32, path: []const u8) void {
        const now = std.time.timestamp();
        const last_ts = bc.chain.items[bc.chain.items.len - 1].timestamp;
        const gap_sec = if (now > last_ts) @as(u64, @intCast(now - last_ts)) else 0;
        const gap_h = gap_sec / 3600;
        const gap_m = (gap_sec % 3600) / 60;
        const gap_s = gap_sec % 60;

        std.debug.print("[DB] Restored {d} blocks + {d} balances + {d} nonces + {d} tx_confirms from {s}\n",
            .{ loaded_blocks, addr_count, nonce_count, tx_confirm_count, path });
        std.debug.print("[DB] Last block: timestamp {d} | Chain height: {d}\n",
            .{ last_ts, bc.chain.items.len - 1 });
        if (gap_h > 0) {
            std.debug.print("[DB] Node offline gap: {d}h {d}m {d}s — no blocks mined during this time\n",
                .{ gap_h, gap_m, gap_s });
        } else if (gap_m > 0) {
            std.debug.print("[DB] Node offline gap: {d}m {d}s — no blocks mined during this time\n",
                .{ gap_m, gap_s });
        } else {
            std.debug.print("[DB] Node offline gap: {d}s — resuming immediately\n",
                .{gap_s});
        }
        std.debug.print("[DB] Resuming from block {d} →\n\n", .{bc.chain.items.len - 1});
    }

    /// Append un singur bloc nou la sfarsitul fisierului — for v1 compat.
    /// For v2, falls back to full saveBlockchain since sections have CRC32 trailers.
    pub fn appendBlock(self: *PersistentBlockchain, bc: *const blockchain_mod.Blockchain, path: []const u8) !void {
        // Blocul tocmai adaugat e ultimul din chain
        const chain = bc.chain.items;
        if (chain.len < 2) return; // nimic de salvat (doar genesis)

        // Check file version — if v2, always do full save (CRC sections need rewriting)
        const file_check = std.fs.cwd().openFile(path, .{}) catch |err| {
            if (err == error.FileNotFound) return self.saveBlockchain(bc, path);
            return err;
        };

        var hdr_buf: [8]u8 = undefined;
        const hdr_read = file_check.readAll(&hdr_buf) catch {
            file_check.close();
            return self.saveBlockchain(bc, path);
        };
        file_check.close();

        if (hdr_read >= 8) {
            const ver = detectVersion(&hdr_buf);
            if (ver == DB_VERSION) {
                // V2: full rewrite needed for CRC consistency
                return self.saveBlockchain(bc, path);
            }
        }

        // V1 append path (legacy)
        return self.appendBlockV1(bc, path);
    }

    /// V1 append logic (kept for backward compat with v1 files)
    fn appendBlockV1(self: *PersistentBlockchain, bc: *const blockchain_mod.Blockchain, path: []const u8) !void {
        const chain = bc.chain.items;
        const blk = chain[chain.len - 1];

        // Serializeaza blocul
        var data_buf: [512]u8 = undefined;
        const data = try std.fmt.bufPrint(&data_buf, "{d}|{d}|{d}|{s}|{s}|{s}|{d}", .{
            blk.index, blk.timestamp, blk.nonce,
            blk.previous_hash, blk.hash,
            blk.miner_address, blk.reward_sat,
        });

        const file = std.fs.cwd().openFile(path, .{ .mode = .read_write }) catch |err| {
            if (err == error.FileNotFound) return self.saveBlockchain(bc, path);
            return err;
        };

        const stat = file.stat() catch {
            file.close();
            return self.saveBlockchain(bc, path);
        };
        if (stat.size < 9) {
            file.close();
            return self.saveBlockchain(bc, path);
        }

        var hdr: [9]u8 = undefined;
        _ = file.readAll(&hdr) catch {
            file.close();
            return self.saveBlockchain(bc, path);
        };
        if (!std.mem.eql(u8, hdr[0..4], "OMNI")) {
            file.close();
            return self.saveBlockchain(bc, path);
        }

        const old_count = std.mem.readInt(u32, hdr[5..9], .little);

        const expected_height = old_count;
        if (blk.index != expected_height + 1 and old_count > 0) {
            std.debug.print("[DB] appendBlock gap (expected {d}, got {d}) — full save\n",
                .{ expected_height + 1, blk.index });
            file.close();
            return self.saveBlockchain(bc, path);
        }

        errdefer file.close();

        file.seekTo(9) catch { file.close(); return self.saveBlockchain(bc, path); };
        var pos: u64 = 9;
        var i: u32 = 0;
        while (i < old_count) : (i += 1) {
            var hdr8: [8]u8 = undefined;
            var hdr4_: [4]u8 = undefined;
            const rh = try file.readAll(&hdr8);
            if (rh < 8) break;
            const rn = try file.readAll(&hdr4_);
            if (rn < 4) break;
            const dlen = std.mem.readInt(u32, &hdr4_, .little);
            pos += 12 + dlen;
            try file.seekTo(pos);
        }

        var h8: [8]u8 = undefined;
        var l4: [4]u8 = undefined;
        std.mem.writeInt(u64, &h8, blk.index, .little);
        std.mem.writeInt(u32, &l4, @intCast(data.len), .little);
        try file.writeAll(&h8);
        try file.writeAll(&l4);
        try file.writeAll(data);

        // Write balances, nonces, tx_confirms
        var bal_buf = array_list.Managed(u8).init(self.allocator);
        defer bal_buf.deinit();

        var cnt4: [4]u8 = undefined;
        std.mem.writeInt(u32, &cnt4, @intCast(bc.balances.count()), .little);
        try bal_buf.appendSlice(&cnt4);

        var bit = bc.balances.iterator();
        while (bit.next()) |entry| {
            const addr = entry.key_ptr.*;
            const bal = entry.value_ptr.*;
            if (addr.len > 255) continue;
            try bal_buf.append(@intCast(addr.len));
            try bal_buf.appendSlice(addr);
            var b8: [8]u8 = undefined;
            std.mem.writeInt(u64, &b8, bal, .little);
            try bal_buf.appendSlice(&b8);
        }

        var ncnt4: [4]u8 = undefined;
        std.mem.writeInt(u32, &ncnt4, @intCast(bc.nonces.count()), .little);
        try bal_buf.appendSlice(&ncnt4);
        var nit = bc.nonces.iterator();
        while (nit.next()) |nentry| {
            const naddr = nentry.key_ptr.*;
            const nonce_val = nentry.value_ptr.*;
            if (naddr.len > 255) continue;
            try bal_buf.append(@intCast(naddr.len));
            try bal_buf.appendSlice(naddr);
            var n8: [8]u8 = undefined;
            std.mem.writeInt(u64, &n8, nonce_val, .little);
            try bal_buf.appendSlice(&n8);
        }

        var tcnt4: [4]u8 = undefined;
        std.mem.writeInt(u32, &tcnt4, @intCast(bc.tx_block_height.count()), .little);
        try bal_buf.appendSlice(&tcnt4);
        var tit = bc.tx_block_height.iterator();
        while (tit.next()) |tentry| {
            const tx_hash = tentry.key_ptr.*;
            const height = tentry.value_ptr.*;
            if (tx_hash.len > 255) continue;
            try bal_buf.append(@intCast(tx_hash.len));
            try bal_buf.appendSlice(tx_hash);
            var th8: [8]u8 = undefined;
            std.mem.writeInt(u64, &th8, height, .little);
            try bal_buf.appendSlice(&th8);
        }

        try file.writeAll(bal_buf.items);

        const new_size = pos + 12 + data.len + bal_buf.items.len;
        try file.setEndPos(new_size);

        const new_count = old_count + 1;
        var new_cnt4: [4]u8 = undefined;
        std.mem.writeInt(u32, &new_cnt4, new_count, .little);
        try file.seekTo(5);
        try file.writeAll(&new_cnt4);

        file.close();

        std.debug.print("[DB] appendBlock #{d} → {s} (total {d} blocks)\n",
            .{ blk.index, path, new_count });
    }

    /// Compact — sterge blocuri vechi pastrand ultimele N
    pub fn compact(self: *PersistentBlockchain) !void {
        _ = self; // File-based compaction — no-op in current implementation
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

test "v2 file header magic and version" {
    // Build a v2 header + empty sections
    var out = array_list.Managed(u8).init(testing.allocator);
    defer out.deinit();

    try PersistentBlockchain.writeV2Header(&out);

    // Verify magic bytes
    try testing.expectEqualSlices(u8, &DB_MAGIC, out.items[0..4]);

    // Verify version
    const ver = std.mem.readInt(u32, out.items[4..8], .little);
    try testing.expectEqual(DB_VERSION, ver);

    // detectVersion should return 2
    const detected = PersistentBlockchain.detectVersion(out.items);
    try testing.expectEqual(@as(u32, 2), detected);
}

test "corrupt magic detected" {
    // Build buffer with wrong magic
    var buf = [_]u8{ 'B', 'A', 'D', '!', 2, 0, 0, 0 };
    const detected = PersistentBlockchain.detectVersion(&buf);
    try testing.expectEqual(@as(u32, 0), detected);
}

test "v1 version detection backward compat" {
    // V1 format: "OMNI" + byte(1) + block_count(4)
    var buf: [9]u8 = undefined;
    @memcpy(buf[0..4], "OMNI");
    buf[4] = 1;
    std.mem.writeInt(u32, buf[5..9], 0, .little);
    const detected = PersistentBlockchain.detectVersion(&buf);
    try testing.expectEqual(@as(u32, 1), detected);
}

test "CRC32 checksum write and verify" {
    var out = array_list.Managed(u8).init(testing.allocator);
    defer out.deinit();

    // Write some section data
    const section_start: usize = 0;
    try out.appendSlice("hello world section data");

    // Append CRC
    try appendCrc32(&out, section_start);

    // Verify: section is from 0 to len-4, CRC is last 4 bytes
    const section_end = out.items.len - 4;
    try testing.expect(verifyCrc32(out.items, section_start, section_end));

    // Corrupt one byte and verify CRC fails
    out.items[5] ^= 0xFF;
    try testing.expect(!verifyCrc32(out.items, section_start, section_end));
}

test "CRC32 mismatch detected on tampered section" {
    var out = array_list.Managed(u8).init(testing.allocator);
    defer out.deinit();

    // Simulate a section: [count:4][data...]
    var cnt: [4]u8 = undefined;
    std.mem.writeInt(u32, &cnt, 42, .little);
    try out.appendSlice(&cnt);
    try out.appendSlice("some balance data here");

    const section_start: usize = 0;
    try appendCrc32(&out, section_start);

    const section_end = out.items.len - 4;

    // Valid CRC
    try testing.expect(verifyCrc32(out.items, section_start, section_end));

    // Tamper with the count field
    out.items[0] = 0xFF;
    try testing.expect(!verifyCrc32(out.items, section_start, section_end));
}
