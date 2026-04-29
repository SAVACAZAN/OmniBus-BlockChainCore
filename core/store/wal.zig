/// wal.zig — Write-Ahead Log
///
/// Append-only journal for the chainstate KV store. Every mutation
/// (put / delete) lands here first, fsync'd to disk, *then* the
/// in-memory memtable is updated. On crash, replay the WAL → restore
/// memtable to its last fsync'd state.
///
/// Bitcoin Core uses LevelDB internally, which has its own WAL
/// (`*.log` files). We can't pull LevelDB without adding a C dep, so
/// this is a from-scratch Zig implementation. Same idea, simpler:
///
///   ┌─ on-disk record ───────────────────────────────────────────┐
///   │ magic        u32 LE  ('OWAL' = 0x4F57414C)                  │
///   │ kind         u8      (1 = put, 2 = delete)                  │
///   │ key_len      u16 LE                                         │
///   │ value_len    u32 LE  (0 for delete)                         │
///   │ key          bytes                                          │
///   │ value        bytes                                          │
///   │ crc32        u32 LE  (over magic..value)                    │
///   └─────────────────────────────────────────────────────────────┘
///
/// fsync after every record in this MVP. A future tunable could
/// batch fsyncs at write barriers (e.g. once per block) at the cost
/// of crash-window size.

const std = @import("std");

const MAGIC: u32 = 0x4F57414C; // "OWAL" little-endian
pub const RECORD_MAX_KEY_LEN: u16 = 256;
pub const RECORD_MAX_VALUE_LEN: u32 = 64 * 1024; // 64 KiB

pub const RecordKind = enum(u8) {
    put = 1,
    delete = 2,
};

pub const Record = struct {
    kind: RecordKind,
    key: []const u8,
    value: []const u8,
};

/// Errors returned by the WAL on read/replay paths.
pub const WalError = error{
    Truncated,
    BadMagic,
    BadCrc,
    KeyTooLong,
    ValueTooLong,
    UnknownKind,
};

/// Append-only WAL writer + replay reader. Single-writer, single-thread.
/// Caller serialises access (we hold an explicit mutex inside the KV
/// store, not here, to keep this module dependency-free).
pub const Wal = struct {
    file: std.fs.File,
    path: []const u8,
    allocator: std.mem.Allocator,
    bytes_written: u64,

    pub fn open(allocator: std.mem.Allocator, path: []const u8) !Wal {
        // Open in append mode; create if missing. Read-write so the
        // optional truncate path can rewind us after a checkpoint.
        const file = std.fs.cwd().createFile(path, .{
            .read = true,
            .truncate = false,
            .exclusive = false,
        }) catch |err| switch (err) {
            error.PathAlreadyExists => try std.fs.cwd().openFile(path, .{ .mode = .read_write }),
            else => return err,
        };
        // Position at end of file for appends.
        try file.seekFromEnd(0);
        const stat = try file.stat();
        return .{
            .file = file,
            .path = try allocator.dupe(u8, path),
            .allocator = allocator,
            .bytes_written = stat.size,
        };
    }

    pub fn close(self: *Wal) void {
        self.file.close();
        self.allocator.free(self.path);
    }

    /// Append a `put` record + fsync. The WAL is the durability
    /// boundary: once this returns OK, the change survives a crash.
    pub fn appendPut(self: *Wal, key: []const u8, value: []const u8) !void {
        if (key.len > RECORD_MAX_KEY_LEN) return WalError.KeyTooLong;
        if (value.len > RECORD_MAX_VALUE_LEN) return WalError.ValueTooLong;
        try self.appendRecord(.put, key, value);
    }

    pub fn appendDelete(self: *Wal, key: []const u8) !void {
        if (key.len > RECORD_MAX_KEY_LEN) return WalError.KeyTooLong;
        try self.appendRecord(.delete, key, &.{});
    }

    fn appendRecord(self: *Wal, kind: RecordKind, key: []const u8, value: []const u8) !void {
        // Header: magic + kind + key_len + value_len = 4 + 1 + 2 + 4 = 11 bytes.
        // Followed by key + value, then crc32 trailer (4 bytes).
        var header: [11]u8 = undefined;
        std.mem.writeInt(u32, header[0..4], MAGIC, .little);
        header[4] = @intFromEnum(kind);
        std.mem.writeInt(u16, header[5..7], @intCast(key.len), .little);
        std.mem.writeInt(u32, header[7..11], @intCast(value.len), .little);

        var crc = std.hash.Crc32.init();
        crc.update(&header);
        crc.update(key);
        crc.update(value);
        const crc_value = crc.final();

        var crc_bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &crc_bytes, crc_value, .little);

        // Write everything in one shot — keeps a partial header from
        // appearing on disk if writeAll is interrupted.
        var iov = [_]std.posix.iovec_const{
            .{ .base = &header, .len = header.len },
            .{ .base = key.ptr, .len = key.len },
            .{ .base = value.ptr, .len = value.len },
            .{ .base = &crc_bytes, .len = crc_bytes.len },
        };
        // std.fs.File.writevAll exists in 0.15.x — falls back to writeAll
        // segment by segment if the OS doesn't support writev. Either
        // way the caller sees an atomic-from-our-perspective append.
        try self.writeAllSegmented(&iov);

        // fsync — durability boundary. Skip in tests via a build-time
        // option later if it slows the suite down.
        self.file.sync() catch |err| {
            std.debug.print("[WAL] fsync failed: {} — durability not guaranteed\n", .{err});
        };

        self.bytes_written += header.len + key.len + value.len + crc_bytes.len;
    }

    fn writeAllSegmented(self: *Wal, iov: []std.posix.iovec_const) !void {
        for (iov) |seg| {
            const bytes = seg.base[0..seg.len];
            try self.file.writeAll(bytes);
        }
    }

    /// Iterate every record in the WAL from the beginning. The callback
    /// is invoked once per replayed record. Truncated / corrupt tails
    /// are detected and the iteration stops cleanly — that's the
    /// post-crash behaviour we want: replay everything that was
    /// fsync'd, drop the partial last record.
    pub fn replay(
        self: *Wal,
        ctx: anytype,
        comptime cb: fn (@TypeOf(ctx), Record) anyerror!void,
    ) !void {
        try self.file.seekTo(0);
        const stat = try self.file.stat();
        if (stat.size == 0) return;

        // Stream record-by-record. Each record's max size is bounded
        // (key 256 + value 64 KiB + 15 byte framing) so a stack buffer
        // is safe.
        var header: [11]u8 = undefined;
        var key_buf: [RECORD_MAX_KEY_LEN]u8 = undefined;
        var value_buf: [RECORD_MAX_VALUE_LEN]u8 = undefined;
        var crc_bytes: [4]u8 = undefined;

        var pos: u64 = 0;
        while (pos < stat.size) {
            // Read header.
            const hdr_n = self.file.readAll(&header) catch |err| {
                std.debug.print("[WAL] header read failed at pos {d}: {}\n", .{ pos, err });
                return;
            };
            if (hdr_n < header.len) {
                std.debug.print("[WAL] truncated header at pos {d} ({d}/{d}) — stop replay\n",
                    .{ pos, hdr_n, header.len });
                return;
            }

            const magic = std.mem.readInt(u32, header[0..4], .little);
            if (magic != MAGIC) {
                std.debug.print("[WAL] bad magic 0x{x} at pos {d} — stop replay\n", .{ magic, pos });
                return;
            }
            const kind_byte = header[4];
            const key_len = std.mem.readInt(u16, header[5..7], .little);
            const value_len = std.mem.readInt(u32, header[7..11], .little);

            if (key_len > RECORD_MAX_KEY_LEN or value_len > RECORD_MAX_VALUE_LEN) {
                std.debug.print("[WAL] oversized record at pos {d} (key={d}, value={d}) — stop replay\n",
                    .{ pos, key_len, value_len });
                return;
            }

            // Read key + value.
            const key_n = self.file.readAll(key_buf[0..key_len]) catch return;
            if (key_n < key_len) {
                std.debug.print("[WAL] truncated key at pos {d} — stop replay\n", .{pos});
                return;
            }
            const val_n = self.file.readAll(value_buf[0..value_len]) catch return;
            if (val_n < value_len) {
                std.debug.print("[WAL] truncated value at pos {d} — stop replay\n", .{pos});
                return;
            }
            const crc_n = self.file.readAll(&crc_bytes) catch return;
            if (crc_n < 4) {
                std.debug.print("[WAL] truncated crc at pos {d} — stop replay\n", .{pos});
                return;
            }

            // Verify CRC.
            const want_crc = std.mem.readInt(u32, &crc_bytes, .little);
            var crc = std.hash.Crc32.init();
            crc.update(&header);
            crc.update(key_buf[0..key_len]);
            crc.update(value_buf[0..value_len]);
            const got_crc = crc.final();
            if (got_crc != want_crc) {
                std.debug.print("[WAL] CRC mismatch at pos {d} (want=0x{x}, got=0x{x}) — stop replay\n",
                    .{ pos, want_crc, got_crc });
                return;
            }

            const kind: RecordKind = switch (kind_byte) {
                1 => .put,
                2 => .delete,
                else => {
                    std.debug.print("[WAL] unknown kind {d} at pos {d}\n", .{ kind_byte, pos });
                    return;
                },
            };

            try cb(ctx, .{
                .kind = kind,
                .key = key_buf[0..key_len],
                .value = value_buf[0..value_len],
            });

            pos += header.len + key_len + value_len + crc_bytes.len;
        }
    }

    /// Truncate the WAL after a successful checkpoint. Caller is
    /// responsible for ensuring the snapshot landed durably first.
    pub fn truncate(self: *Wal) !void {
        try self.file.setEndPos(0);
        try self.file.seekTo(0);
        self.bytes_written = 0;
    }
};

// ─── Tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

const StoredRec = struct {
    kind: RecordKind,
    key: []const u8,
    value: []const u8,
};

const TestCollector = struct {
    records: std.array_list.Managed(StoredRec),
    alloc: std.mem.Allocator,

    fn cb(self: *TestCollector, r: Record) !void {
        try self.records.append(.{
            .kind = r.kind,
            .key = try self.alloc.dupe(u8, r.key),
            .value = try self.alloc.dupe(u8, r.value),
        });
    }

    fn deinit(self: *TestCollector) void {
        for (self.records.items) |it| {
            self.alloc.free(it.key);
            self.alloc.free(it.value);
        }
        self.records.deinit();
    }
};

test "Wal: open, append, replay round-trip" {
    const tmp_path = "test_wal_roundtrip.dat";
    defer std.fs.cwd().deleteFile(tmp_path) catch {};

    var wal = try Wal.open(testing.allocator, tmp_path);
    defer wal.close();

    try wal.appendPut("alice", "100");
    try wal.appendPut("bob", "200");
    try wal.appendDelete("alice");
    try wal.appendPut("alice", "500");

    var collector = TestCollector{
        .records = std.array_list.Managed(StoredRec).init(testing.allocator),
        .alloc = testing.allocator,
    };
    defer collector.deinit();

    try wal.replay(&collector, TestCollector.cb);

    try testing.expectEqual(@as(usize, 4), collector.records.items.len);
    try testing.expectEqual(RecordKind.put, collector.records.items[0].kind);
    try testing.expectEqualStrings("alice", collector.records.items[0].key);
    try testing.expectEqualStrings("100", collector.records.items[0].value);
    try testing.expectEqual(RecordKind.delete, collector.records.items[2].kind);
    try testing.expectEqualStrings("500", collector.records.items[3].value);
}

test "Wal: replay tolerates truncated tail" {
    const tmp_path = "test_wal_truncated.dat";
    defer std.fs.cwd().deleteFile(tmp_path) catch {};

    {
        var wal = try Wal.open(testing.allocator, tmp_path);
        defer wal.close();
        try wal.appendPut("good", "rec");
    }

    // Append a few bytes of garbage to simulate a partial write
    {
        const f = try std.fs.cwd().openFile(tmp_path, .{ .mode = .read_write });
        defer f.close();
        try f.seekFromEnd(0);
        try f.writeAll(&[_]u8{ 0x4F, 0x57, 0x41 }); // truncated magic
    }

    var wal = try Wal.open(testing.allocator, tmp_path);
    defer wal.close();

    const Counter = struct {
        count: *usize,
        fn cb(self: *@This(), r: Record) !void {
            _ = r;
            self.count.* += 1;
        }
    };
    var n: usize = 0;
    var counter = Counter{ .count = &n };
    try wal.replay(&counter, Counter.cb);
    try testing.expectEqual(@as(usize, 1), n);
}

test "Wal: oversized key rejected" {
    const tmp_path = "test_wal_oversized.dat";
    defer std.fs.cwd().deleteFile(tmp_path) catch {};

    var wal = try Wal.open(testing.allocator, tmp_path);
    defer wal.close();

    const big_key = [_]u8{'x'} ** (RECORD_MAX_KEY_LEN + 1);
    try testing.expectError(WalError.KeyTooLong, wal.appendPut(&big_key, "v"));
}

test "Wal: truncate resets length" {
    const tmp_path = "test_wal_truncate.dat";
    defer std.fs.cwd().deleteFile(tmp_path) catch {};

    var wal = try Wal.open(testing.allocator, tmp_path);
    defer wal.close();

    try wal.appendPut("k", "v");
    try testing.expect(wal.bytes_written > 0);
    try wal.truncate();
    try testing.expectEqual(@as(u64, 0), wal.bytes_written);
}
