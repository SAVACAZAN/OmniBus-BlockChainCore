/// kv.zig — Key-value store backed by WAL + in-memory memtable.
///
/// Design:
///   - All writes go to WAL first (durability), then memtable
///   - Reads come from memtable (in-memory hash map)
///   - On startup: replay WAL → rebuild memtable
///   - Periodic checkpoint: dump memtable to a snapshot file, truncate WAL
///
/// This is *not* LevelDB. There's no SSTable, no compaction, no bloom
/// filters. We can fit the whole memtable in RAM because the chain
/// state for OmniBus is bounded (one entry per active address —
/// today ~thousands, projected ~millions on mainnet).
///
/// When we outgrow RAM, this module gets swapped for a real LSM tree.
/// The Kv API is designed to make that transparent: callers see
/// `get` / `put` / `delete` and don't know which backend serves them.
///
/// Thread safety: the caller serialises access via an external mutex.
/// The chainstate adapter takes bc.mutex during applyBlock anyway,
/// so adding a second lock here would be redundant.

const std = @import("std");
const wal_mod = @import("wal.zig");

pub const Wal = wal_mod.Wal;
pub const RecordKind = wal_mod.RecordKind;

/// Snapshot file format (binary):
///   magic  u32 LE  ('OSNP' = 0x4F534E50)
///   version u16 LE  (= 1)
///   count  u32 LE
///   for each entry:
///     key_len   u16 LE
///     value_len u32 LE
///     key       bytes
///     value     bytes
///   crc32  u32 LE  over everything above
const SNAPSHOT_MAGIC: u32 = 0x4F534E50;
const SNAPSHOT_VERSION: u16 = 1;

pub const KvError = error{
    SnapshotBadMagic,
    SnapshotBadVersion,
    SnapshotBadCrc,
    SnapshotTruncated,
};

pub const Kv = struct {
    allocator: std.mem.Allocator,
    /// Owned WAL. Writes append here; replay rebuilds memtable.
    wal: Wal,
    /// In-memory key-value map. Keys + values are owned by this struct.
    memtable: std.StringHashMap([]u8),
    /// Path of the snapshot file (no extension; we add `.snap` and `.snap.tmp`).
    base_path: []const u8,

    pub fn open(allocator: std.mem.Allocator, base_path: []const u8) !Kv {
        // Open WAL alongside the snapshot file.
        const wal_path = try std.fmt.allocPrint(allocator, "{s}.wal", .{base_path});
        defer allocator.free(wal_path);
        var wal = try Wal.open(allocator, wal_path);
        errdefer wal.close();

        var kv = Kv{
            .allocator = allocator,
            .wal = wal,
            .memtable = std.StringHashMap([]u8).init(allocator),
            .base_path = try allocator.dupe(u8, base_path),
        };

        // 1) Load snapshot if present.
        kv.loadSnapshot() catch |err| {
            // Missing snapshot is OK — fresh chain. Other errors are logged
            // and treated as missing (we'll rebuild from WAL).
            if (err != error.FileNotFound) {
                std.debug.print("[KV] snapshot load failed: {} — rebuilding from WAL only\n", .{err});
            }
        };

        // 2) Replay WAL on top of the snapshot.
        try kv.wal.replay(&kv, Kv.applyWalRecord);

        return kv;
    }

    pub fn close(self: *Kv) void {
        // Free memtable entries before closing.
        var it = self.memtable.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.memtable.deinit();
        self.wal.close();
        self.allocator.free(self.base_path);
    }

    /// WAL replay callback: re-apply each record to the memtable.
    /// Note: we don't append back to the WAL during replay — that would
    /// double the on-disk record count.
    fn applyWalRecord(self: *Kv, r: wal_mod.Record) !void {
        switch (r.kind) {
            .put => {
                try self.putMemtableOnly(r.key, r.value);
            },
            .delete => {
                try self.deleteMemtableOnly(r.key);
            },
        }
    }

    /// Public write. Appends to WAL (durable) then updates memtable.
    /// On a crash between WAL fsync and memtable update, the next
    /// startup replays the WAL and gets the right answer.
    pub fn put(self: *Kv, key: []const u8, value: []const u8) !void {
        try self.wal.appendPut(key, value);
        try self.putMemtableOnly(key, value);
    }

    pub fn delete(self: *Kv, key: []const u8) !void {
        try self.wal.appendDelete(key);
        try self.deleteMemtableOnly(key);
    }

    /// Read-side. Returns a slice into the memtable; caller must NOT
    /// hold the slice across put/delete calls (the underlying buffer
    /// may be freed). Returns null when the key isn't present (or was
    /// deleted).
    pub fn get(self: *const Kv, key: []const u8) ?[]const u8 {
        return self.memtable.get(key);
    }

    pub fn count(self: *const Kv) usize {
        return self.memtable.count();
    }

    fn putMemtableOnly(self: *Kv, key: []const u8, value: []const u8) !void {
        const owned_key = try self.allocator.dupe(u8, key);
        const owned_val = try self.allocator.dupe(u8, value);
        const gop = self.memtable.getOrPut(owned_key) catch |err| {
            self.allocator.free(owned_key);
            self.allocator.free(owned_val);
            return err;
        };
        if (gop.found_existing) {
            // Replace existing value; key already owned by memtable.
            self.allocator.free(owned_key);
            self.allocator.free(gop.value_ptr.*);
        }
        gop.value_ptr.* = owned_val;
    }

    fn deleteMemtableOnly(self: *Kv, key: []const u8) !void {
        if (self.memtable.fetchRemove(key)) |kv| {
            self.allocator.free(kv.key);
            self.allocator.free(kv.value);
        }
    }

    /// Persist current memtable to disk as a snapshot, then truncate
    /// the WAL. After this returns, all WAL records older than the
    /// snapshot are no longer needed.
    ///
    /// Atomicity: writes to `<base>.snap.tmp`, fsyncs, then renames to
    /// `<base>.snap` — the rename is atomic on POSIX. WAL is truncated
    /// only after the rename succeeds, so a crash mid-checkpoint
    /// leaves the old snapshot + full WAL intact.
    pub fn checkpoint(self: *Kv) !void {
        const tmp_path = try std.fmt.allocPrint(self.allocator, "{s}.snap.tmp", .{self.base_path});
        defer self.allocator.free(tmp_path);
        const final_path = try std.fmt.allocPrint(self.allocator, "{s}.snap", .{self.base_path});
        defer self.allocator.free(final_path);

        // Build the snapshot in memory first so we can compute its CRC
        // and write the whole thing in one go. Snapshot size is bounded
        // by chainstate size (KB-MB territory in the foreseeable future);
        // future LSM impl will stream.
        var buf = std.array_list.Managed(u8).init(self.allocator);
        defer buf.deinit();

        var hdr: [10]u8 = undefined;
        std.mem.writeInt(u32, hdr[0..4], SNAPSHOT_MAGIC, .little);
        std.mem.writeInt(u16, hdr[4..6], SNAPSHOT_VERSION, .little);
        std.mem.writeInt(u32, hdr[6..10], @intCast(self.memtable.count()), .little);
        try buf.appendSlice(&hdr);

        var it = self.memtable.iterator();
        while (it.next()) |entry| {
            var len_buf: [6]u8 = undefined;
            std.mem.writeInt(u16, len_buf[0..2], @intCast(entry.key_ptr.len), .little);
            std.mem.writeInt(u32, len_buf[2..6], @intCast(entry.value_ptr.len), .little);
            try buf.appendSlice(&len_buf);
            try buf.appendSlice(entry.key_ptr.*);
            try buf.appendSlice(entry.value_ptr.*);
        }

        var crc = std.hash.Crc32.init();
        crc.update(buf.items);
        const crc_value = crc.final();
        var crc_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &crc_buf, crc_value, .little);
        try buf.appendSlice(&crc_buf);

        // Write tmp + fsync + rename.
        {
            const f = try std.fs.cwd().createFile(tmp_path, .{ .truncate = true });
            defer f.close();
            try f.writeAll(buf.items);
            f.sync() catch {};
        }
        std.fs.cwd().rename(tmp_path, final_path) catch |err| {
            std.debug.print("[KV] rename {s} -> {s} failed: {}\n", .{ tmp_path, final_path, err });
            return err;
        };

        // Snapshot is durable. Truncate WAL.
        try self.wal.truncate();
    }

    fn loadSnapshot(self: *Kv) !void {
        const snap_path = try std.fmt.allocPrint(self.allocator, "{s}.snap", .{self.base_path});
        defer self.allocator.free(snap_path);

        const f = std.fs.cwd().openFile(snap_path, .{}) catch |err| return err;
        defer f.close();

        const stat = try f.stat();
        if (stat.size < 14) return KvError.SnapshotTruncated; // header (10) + crc (4)

        const data = try self.allocator.alloc(u8, stat.size);
        defer self.allocator.free(data);
        const n = try f.readAll(data);
        if (n < stat.size) return KvError.SnapshotTruncated;

        // Verify CRC.
        const payload = data[0 .. data.len - 4];
        const trailer = data[data.len - 4 ..];
        const want_crc = std.mem.readInt(u32, trailer[0..4], .little);
        var crc = std.hash.Crc32.init();
        crc.update(payload);
        if (crc.final() != want_crc) return KvError.SnapshotBadCrc;

        // Parse.
        const magic = std.mem.readInt(u32, payload[0..4], .little);
        if (magic != SNAPSHOT_MAGIC) return KvError.SnapshotBadMagic;
        const version = std.mem.readInt(u16, payload[4..6], .little);
        if (version != SNAPSHOT_VERSION) return KvError.SnapshotBadVersion;
        const cnt = std.mem.readInt(u32, payload[6..10], .little);

        var pos: usize = 10;
        var loaded: u32 = 0;
        while (loaded < cnt and pos + 6 <= payload.len) : (loaded += 1) {
            const key_len = std.mem.readInt(u16, payload[pos..][0..2], .little);
            const value_len = std.mem.readInt(u32, payload[pos + 2 ..][0..4], .little);
            pos += 6;
            if (pos + key_len + value_len > payload.len) return KvError.SnapshotTruncated;
            try self.putMemtableOnly(payload[pos .. pos + key_len], payload[pos + key_len .. pos + key_len + value_len]);
            pos += key_len + value_len;
        }
    }
};

// ─── Tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

fn cleanupKvFiles(base: []const u8) void {
    var buf: [256]u8 = undefined;
    const wal_path = std.fmt.bufPrint(&buf, "{s}.wal", .{base}) catch return;
    std.fs.cwd().deleteFile(wal_path) catch {};
    const snap_path = std.fmt.bufPrint(&buf, "{s}.snap", .{base}) catch return;
    std.fs.cwd().deleteFile(snap_path) catch {};
    const tmp_path = std.fmt.bufPrint(&buf, "{s}.snap.tmp", .{base}) catch return;
    std.fs.cwd().deleteFile(tmp_path) catch {};
}

test "Kv: put / get / delete" {
    const base = "test_kv_basic";
    cleanupKvFiles(base);
    defer cleanupKvFiles(base);

    var kv = try Kv.open(testing.allocator, base);
    defer kv.close();

    try kv.put("alice", "1000");
    try kv.put("bob", "2000");
    try testing.expectEqualStrings("1000", kv.get("alice").?);
    try testing.expectEqualStrings("2000", kv.get("bob").?);
    try testing.expectEqual(@as(usize, 2), kv.count());

    try kv.delete("alice");
    try testing.expect(kv.get("alice") == null);
    try testing.expectEqual(@as(usize, 1), kv.count());
}

test "Kv: WAL replay restores state after reopen" {
    const base = "test_kv_replay";
    cleanupKvFiles(base);
    defer cleanupKvFiles(base);

    {
        var kv = try Kv.open(testing.allocator, base);
        defer kv.close();
        try kv.put("a", "1");
        try kv.put("b", "2");
        try kv.put("a", "10"); // overwrite
        try kv.delete("b");
        try kv.put("c", "3");
    }

    var kv = try Kv.open(testing.allocator, base);
    defer kv.close();
    try testing.expectEqualStrings("10", kv.get("a").?);
    try testing.expect(kv.get("b") == null);
    try testing.expectEqualStrings("3", kv.get("c").?);
    try testing.expectEqual(@as(usize, 2), kv.count());
}

test "Kv: checkpoint persists snapshot + truncates WAL" {
    const base = "test_kv_checkpoint";
    cleanupKvFiles(base);
    defer cleanupKvFiles(base);

    {
        var kv = try Kv.open(testing.allocator, base);
        defer kv.close();
        try kv.put("k1", "v1");
        try kv.put("k2", "v2");
        try kv.checkpoint();
        try testing.expectEqual(@as(u64, 0), kv.wal.bytes_written);
    }

    // Reopen — should load from snapshot, no WAL needed.
    var kv = try Kv.open(testing.allocator, base);
    defer kv.close();
    try testing.expectEqualStrings("v1", kv.get("k1").?);
    try testing.expectEqualStrings("v2", kv.get("k2").?);
    try testing.expectEqual(@as(usize, 2), kv.count());
}

test "Kv: snapshot + new WAL records compose correctly" {
    const base = "test_kv_compose";
    cleanupKvFiles(base);
    defer cleanupKvFiles(base);

    {
        var kv = try Kv.open(testing.allocator, base);
        defer kv.close();
        try kv.put("snap_only", "old");
        try kv.put("both", "in_snap");
        try kv.checkpoint();
        // Now write more; these go to a fresh WAL.
        try kv.put("wal_only", "new");
        try kv.put("both", "in_wal"); // overwrite the snapshotted entry
        try kv.delete("snap_only");
    }

    // Reopen: snapshot first, then WAL replay should overwrite "both"
    // and remove "snap_only".
    var kv = try Kv.open(testing.allocator, base);
    defer kv.close();
    try testing.expect(kv.get("snap_only") == null);
    try testing.expectEqualStrings("in_wal", kv.get("both").?);
    try testing.expectEqualStrings("new", kv.get("wal_only").?);
}
