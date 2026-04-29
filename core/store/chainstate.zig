/// chainstate.zig — typed wrapper over the generic Kv store.
///
/// Bitcoin Core has a `chainstate/` LevelDB whose keys are typed by
/// a single-byte prefix: `'C'` for coins (UTXOs), `'B'` for the best
/// block hash, etc. We adopt the same convention.
///
/// Today this module exposes:
///   - balance      ('B' + addr)   → u64 (8 bytes LE)
///   - nonce        ('N' + addr)   → u64 (8 bytes LE)
///   - utxo         ('U' + outpoint) → packed (amount,address,height,coinbase)
///   - tip_hash     ('T')           → block hash (variable length string)
///
/// Phase C.4 (this commit): chainstate runs *alongside* bc.balances /
/// bc.nonces / bc.utxo_set. Every applyBlock-time write hits both;
/// startup loads chainstate AND replays the chain so a divergence
/// surfaces immediately. Once we've soaked for a release cycle and
/// no divergences are reported, a follow-up commit deletes the
/// in-memory mirrors and chainstate becomes the single source.
///
/// Persistence: all writes go through Kv → WAL fsync → memtable.
/// Periodic `checkpoint()` (called from main.zig's state-save thread,
/// every 60 s) snapshots the memtable to disk and truncates the WAL.
/// Crash recovery: WAL replay catches everything the snapshot missed.

const std = @import("std");
const kv_mod = @import("kv.zig");

pub const Kv = kv_mod.Kv;

/// One-byte type prefix on every key. Lets one Kv hold all chain state
/// types without collision (Bitcoin Core uses the same trick).
pub const KeyPrefix = enum(u8) {
    balance = 'B',
    nonce = 'N',
    utxo = 'U',
    tip_hash = 'T',
};

pub const ChainState = struct {
    kv: Kv,
    allocator: std.mem.Allocator,

    pub fn open(allocator: std.mem.Allocator, base_path: []const u8) !ChainState {
        return .{
            .kv = try Kv.open(allocator, base_path),
            .allocator = allocator,
        };
    }

    pub fn close(self: *ChainState) void {
        self.kv.close();
    }

    pub fn checkpoint(self: *ChainState) !void {
        try self.kv.checkpoint();
    }

    // ─── Balance ────────────────────────────────────────────────────────────

    /// Set the balance for an address. amount=0 deletes the entry to
    /// keep the snapshot compact (vs storing zeros).
    pub fn putBalance(self: *ChainState, address: []const u8, amount: u64) !void {
        var key_buf: [257]u8 = undefined;
        const key = try makeKey(&key_buf, .balance, address);
        if (amount == 0) {
            self.kv.delete(key) catch |err| switch (err) {
                else => return err,
            };
            return;
        }
        var amt_buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &amt_buf, amount, .little);
        try self.kv.put(key, &amt_buf);
    }

    pub fn getBalance(self: *const ChainState, address: []const u8) u64 {
        var key_buf: [257]u8 = undefined;
        const key = makeKey(&key_buf, .balance, address) catch return 0;
        const v = self.kv.get(key) orelse return 0;
        if (v.len < 8) return 0;
        return std.mem.readInt(u64, v[0..8], .little);
    }

    // ─── Nonce ─────────────────────────────────────────────────────────────

    pub fn putNonce(self: *ChainState, address: []const u8, nonce: u64) !void {
        var key_buf: [257]u8 = undefined;
        const key = try makeKey(&key_buf, .nonce, address);
        var n_buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &n_buf, nonce, .little);
        try self.kv.put(key, &n_buf);
    }

    pub fn getNonce(self: *const ChainState, address: []const u8) u64 {
        var key_buf: [257]u8 = undefined;
        const key = makeKey(&key_buf, .nonce, address) catch return 0;
        const v = self.kv.get(key) orelse return 0;
        if (v.len < 8) return 0;
        return std.mem.readInt(u64, v[0..8], .little);
    }

    // ─── Tip hash ──────────────────────────────────────────────────────────

    pub fn putTipHash(self: *ChainState, hash_hex: []const u8) !void {
        const key = [_]u8{@intFromEnum(KeyPrefix.tip_hash)};
        try self.kv.put(&key, hash_hex);
    }

    pub fn getTipHash(self: *const ChainState) ?[]const u8 {
        const key = [_]u8{@intFromEnum(KeyPrefix.tip_hash)};
        return self.kv.get(&key);
    }

    // ─── Iteration helpers (audit / dump) ───────────────────────────────────

    /// Return the count of `B`-prefixed entries — addresses with non-zero
    /// balance per chainstate. Pairs with bc.balances.count() in audits.
    pub fn balanceCount(self: *const ChainState) usize {
        var n: usize = 0;
        var it = self.kv.memtable.iterator();
        while (it.next()) |entry| {
            if (entry.key_ptr.len > 0 and
                entry.key_ptr.*[0] == @intFromEnum(KeyPrefix.balance))
            {
                n += 1;
            }
        }
        return n;
    }

    /// Sum of all balances stored. Used by tests + audits to assert the
    /// total supply tracked here matches what the chain emitted.
    pub fn totalSupply(self: *const ChainState) u64 {
        var total: u64 = 0;
        var it = self.kv.memtable.iterator();
        while (it.next()) |entry| {
            if (entry.key_ptr.len > 0 and
                entry.key_ptr.*[0] == @intFromEnum(KeyPrefix.balance) and
                entry.value_ptr.len >= 8)
            {
                total += std.mem.readInt(u64, entry.value_ptr.*[0..8], .little);
            }
        }
        return total;
    }
};

fn makeKey(buf: []u8, prefix: KeyPrefix, suffix: []const u8) ![]u8 {
    if (suffix.len + 1 > buf.len) return error.KeyTooLong;
    buf[0] = @intFromEnum(prefix);
    @memcpy(buf[1 .. 1 + suffix.len], suffix);
    return buf[0 .. 1 + suffix.len];
}

// ─── Tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

fn cleanupChainstate(base: []const u8) void {
    var buf: [256]u8 = undefined;
    const wal_path = std.fmt.bufPrint(&buf, "{s}.wal", .{base}) catch return;
    std.fs.cwd().deleteFile(wal_path) catch {};
    const snap_path = std.fmt.bufPrint(&buf, "{s}.snap", .{base}) catch return;
    std.fs.cwd().deleteFile(snap_path) catch {};
}

test "ChainState: balance round-trip" {
    const base = "test_cs_balance";
    cleanupChainstate(base);
    defer cleanupChainstate(base);

    var cs = try ChainState.open(testing.allocator, base);
    defer cs.close();

    try cs.putBalance("ob1qalice", 1_000_000_000);
    try cs.putBalance("ob1qbob", 500_000_000);
    try testing.expectEqual(@as(u64, 1_000_000_000), cs.getBalance("ob1qalice"));
    try testing.expectEqual(@as(u64, 500_000_000), cs.getBalance("ob1qbob"));
    try testing.expectEqual(@as(u64, 1_500_000_000), cs.totalSupply());
    try testing.expectEqual(@as(usize, 2), cs.balanceCount());
}

test "ChainState: balance=0 deletes the entry" {
    const base = "test_cs_zero";
    cleanupChainstate(base);
    defer cleanupChainstate(base);

    var cs = try ChainState.open(testing.allocator, base);
    defer cs.close();

    try cs.putBalance("ob1qalice", 100);
    try cs.putBalance("ob1qalice", 0);
    try testing.expectEqual(@as(u64, 0), cs.getBalance("ob1qalice"));
    try testing.expectEqual(@as(usize, 0), cs.balanceCount());
}

test "ChainState: nonce + tip_hash" {
    const base = "test_cs_nonce";
    cleanupChainstate(base);
    defer cleanupChainstate(base);

    var cs = try ChainState.open(testing.allocator, base);
    defer cs.close();

    try cs.putNonce("ob1qalice", 42);
    try testing.expectEqual(@as(u64, 42), cs.getNonce("ob1qalice"));

    try cs.putTipHash("deadbeefcafe");
    try testing.expectEqualStrings("deadbeefcafe", cs.getTipHash().?);
}

test "ChainState: persists across reopen via WAL" {
    const base = "test_cs_persist";
    cleanupChainstate(base);
    defer cleanupChainstate(base);

    {
        var cs = try ChainState.open(testing.allocator, base);
        defer cs.close();
        try cs.putBalance("ob1qalice", 7_777);
        try cs.putNonce("ob1qalice", 3);
        try cs.putTipHash("0xabc");
    }

    var cs = try ChainState.open(testing.allocator, base);
    defer cs.close();
    try testing.expectEqual(@as(u64, 7_777), cs.getBalance("ob1qalice"));
    try testing.expectEqual(@as(u64, 3), cs.getNonce("ob1qalice"));
    try testing.expectEqualStrings("0xabc", cs.getTipHash().?);
}

test "ChainState: checkpoint + reopen still has data" {
    const base = "test_cs_chkpt";
    cleanupChainstate(base);
    defer cleanupChainstate(base);

    {
        var cs = try ChainState.open(testing.allocator, base);
        defer cs.close();
        try cs.putBalance("ob1qa", 1);
        try cs.putBalance("ob1qb", 2);
        try cs.putBalance("ob1qc", 3);
        try cs.checkpoint();
        // Add more after checkpoint — they go into the new WAL.
        try cs.putBalance("ob1qd", 4);
    }

    var cs = try ChainState.open(testing.allocator, base);
    defer cs.close();
    try testing.expectEqual(@as(u64, 1), cs.getBalance("ob1qa"));
    try testing.expectEqual(@as(u64, 2), cs.getBalance("ob1qb"));
    try testing.expectEqual(@as(u64, 3), cs.getBalance("ob1qc"));
    try testing.expectEqual(@as(u64, 4), cs.getBalance("ob1qd"));
    try testing.expectEqual(@as(u64, 10), cs.totalSupply());
}
