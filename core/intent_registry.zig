//! intent_registry.zig — durable bookkeeping for cross-chain intent bonds.
//!
//! Why this exists separately from `swap_registry`/`htlc_registry`:
//!   * `swap_registry` (order_swap_link.zig) tracks the maker/taker HTLC
//!     pair and a state machine for the actual atomic-swap settlement.
//!   * `htlc_registry` (htlc.zig) tracks individual HTLC contracts and
//!     their preimage reveal.
//!   * This file tracks the *bond accounting* layer: the maker's bond
//!     locked at `intent_post`, the solver's bond locked at
//!     `intent_fill_commit`, and how those bonds move on settle / timeout.
//!
//! The bonds are real OMNI sat balances debited from `bc.balances` at lock
//! time and credited back (or slashed to the counterparty) on resolution.
//! Without this registry, applyIntentTx would only emit WS events without
//! any on-chain accounting — exactly the TODO that blockchain.zig flagged.
//!
//! Constraints (bare-metal-compatible):
//!   * Fixed-size `entries` array (no heap growth).
//!   * Entries are dense (no tombstones); removal compacts in place.
//!   * Two-step persistence: save to `<path>.tmp` then rename.
//!   * Header magic `OMNIINT1`, CRC32 trailer, same shape as htlc_persist.
//!
//! Persistence layout (little-endian):
//!   [0..8]    MAGIC = "OMNIINT1"
//!   [8..12]   VERSION = u32 (currently 1)
//!   [12..16]  entry_count = u32
//!   [16..]    entry_count × ENTRY_SIZE bytes
//!   [tail-4]  CRC32 of all preceding bytes
//!
//! ENTRY_SIZE = 32 (intent_id) + 32 (swap_id)
//!            + 1 (maker_len) + 64 (maker_addr)
//!            + 1 (taker_len) + 64 (taker_addr)
//!            + 8 (maker_amount_sat) + 8 (taker_min_sat)
//!            + 8 (maker_bond_locked_sat) + 8 (taker_bond_locked_sat)
//!            + 8 (expiry_block) + 8 (commit_block)
//!            + 1 (state) + 7 (reserved/padding)
//!          = 250 bytes.
//!
//! At MAX_INTENTS=1024 worst-case file = 1024 × 250 + 20 ≈ 256 KiB.

const std = @import("std");

pub const MAX_INTENTS: usize = 1024;
pub const MAX_ADDR_LEN: usize = 64;

/// Lifecycle of a recorded intent. Drives bond accounting:
///   posted     — maker's bond locked, awaiting solver commit
///   committed  — solver's bond locked, awaiting settlement on remote chain
///   settled    — both bonds returned to their owners
///   timed_out  — solver missed deadline; their bond slashed to maker
pub const IntentState = enum(u8) {
    posted = 0,
    committed = 1,
    settled = 2,
    timed_out = 3,
    _,
};

pub const IntentEntry = struct {
    intent_id: [32]u8 = [_]u8{0} ** 32,
    swap_id: [32]u8 = [_]u8{0} ** 32,

    maker_address: [MAX_ADDR_LEN]u8 = [_]u8{0} ** MAX_ADDR_LEN,
    maker_address_len: u8 = 0,
    taker_address: [MAX_ADDR_LEN]u8 = [_]u8{0} ** MAX_ADDR_LEN,
    taker_address_len: u8 = 0,

    maker_amount_sat: u64 = 0,
    taker_min_sat: u64 = 0,

    /// Bond locked by maker at `intent_post`. Returned on settle, slashed
    /// to taker on a maker-side timeout (not currently modelled — we only
    /// implement taker-side timeout slash today).
    maker_bond_locked_sat: u64 = 0,
    /// Bond locked by taker at `intent_fill_commit`. Returned on settle,
    /// slashed to maker on `intent_timeout`.
    taker_bond_locked_sat: u64 = 0,

    expiry_block: u64 = 0,
    /// Block at which the taker's commit landed. 0 until commit.
    commit_block: u64 = 0,

    state: IntentState = .posted,

    pub fn makerSlice(self: *const IntentEntry) []const u8 {
        return self.maker_address[0..self.maker_address_len];
    }
    pub fn takerSlice(self: *const IntentEntry) []const u8 {
        return self.taker_address[0..self.taker_address_len];
    }
};

pub const IntentRegistry = struct {
    entries: [MAX_INTENTS]IntentEntry = [_]IntentEntry{.{}} ** MAX_INTENTS,
    count: u32 = 0,
    /// Serialises mutators across RPC threads. Read-only helpers
    /// (find/get) can lock too — contention is negligible.
    mutex: std.Thread.Mutex = .{},

    pub fn init() IntentRegistry {
        return .{};
    }

    pub fn indexOf(self: *const IntentRegistry, intent_id: [32]u8) ?u32 {
        var i: u32 = 0;
        while (i < self.count) : (i += 1) {
            if (std.mem.eql(u8, &self.entries[i].intent_id, &intent_id)) return i;
        }
        return null;
    }

    pub fn findById(self: *const IntentRegistry, intent_id: [32]u8) ?IntentEntry {
        const idx = self.indexOf(intent_id) orelse return null;
        return self.entries[idx];
    }

    pub fn getPtr(self: *IntentRegistry, intent_id: [32]u8) ?*IntentEntry {
        const idx = self.indexOf(intent_id) orelse return null;
        return &self.entries[idx];
    }

    /// Insert a new entry. Caller has already debited the maker's bond
    /// from bc.balances; this function only records the bookkeeping.
    /// Rejects duplicates so a replayed `intent_post` doesn't create a
    /// second entry for the same id.
    pub fn addEntry(self: *IntentRegistry, e: IntentEntry) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.indexOf(e.intent_id) != null) return error.DuplicateIntent;
        if (self.count >= MAX_INTENTS) return error.RegistryFull;
        self.entries[self.count] = e;
        self.count += 1;
    }

    /// Apply `intent_fill_commit`: solver locks bond. The caller has
    /// already debited the taker's balance; this function records the
    /// commit and transitions the entry to `.committed`.
    pub fn commitFill(
        self: *IntentRegistry,
        intent_id: [32]u8,
        taker_address: []const u8,
        taker_bond_locked_sat: u64,
        commit_block: u64,
    ) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const ptr = self.getPtrLocked(intent_id) orelse return error.IntentNotFound;
        if (ptr.state != .posted) return error.InvalidIntentState;
        if (taker_address.len > MAX_ADDR_LEN) return error.AddressTooLong;
        @memcpy(ptr.taker_address[0..taker_address.len], taker_address);
        ptr.taker_address_len = @intCast(taker_address.len);
        ptr.taker_bond_locked_sat = taker_bond_locked_sat;
        ptr.commit_block = commit_block;
        ptr.state = .committed;
    }

    pub fn markSettled(self: *IntentRegistry, intent_id: [32]u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const ptr = self.getPtrLocked(intent_id) orelse return error.IntentNotFound;
        if (ptr.state != .posted and ptr.state != .committed)
            return error.InvalidIntentState;
        ptr.state = .settled;
    }

    pub fn markTimedOut(self: *IntentRegistry, intent_id: [32]u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const ptr = self.getPtrLocked(intent_id) orelse return error.IntentNotFound;
        if (ptr.state != .posted and ptr.state != .committed)
            return error.InvalidIntentState;
        ptr.state = .timed_out;
    }

    /// Internal helper — caller must hold `self.mutex`.
    fn getPtrLocked(self: *IntentRegistry, intent_id: [32]u8) ?*IntentEntry {
        var i: u32 = 0;
        while (i < self.count) : (i += 1) {
            if (std.mem.eql(u8, &self.entries[i].intent_id, &intent_id))
                return &self.entries[i];
        }
        return null;
    }

    // ─── Persistence ────────────────────────────────────────────────────

    pub const MAGIC: [8]u8 = .{ 'O', 'M', 'N', 'I', 'I', 'N', 'T', '1' };
    pub const VERSION: u32 = 1;
    pub const HEADER_SIZE: usize = 8 + 4 + 4;
    pub const ENTRY_SIZE: usize =
        32 + 32 + 1 + MAX_ADDR_LEN + 1 + MAX_ADDR_LEN +
        8 + 8 + 8 + 8 + 8 + 8 + 1 + 7;

    fn encodeEntry(e: *const IntentEntry, rec: *[ENTRY_SIZE]u8) void {
        @memset(rec, 0);
        var off: usize = 0;
        @memcpy(rec[off .. off + 32], &e.intent_id); off += 32;
        @memcpy(rec[off .. off + 32], &e.swap_id); off += 32;
        rec[off] = e.maker_address_len; off += 1;
        @memcpy(rec[off .. off + MAX_ADDR_LEN], &e.maker_address); off += MAX_ADDR_LEN;
        rec[off] = e.taker_address_len; off += 1;
        @memcpy(rec[off .. off + MAX_ADDR_LEN], &e.taker_address); off += MAX_ADDR_LEN;
        std.mem.writeInt(u64, rec[off..][0..8], e.maker_amount_sat, .little); off += 8;
        std.mem.writeInt(u64, rec[off..][0..8], e.taker_min_sat, .little); off += 8;
        std.mem.writeInt(u64, rec[off..][0..8], e.maker_bond_locked_sat, .little); off += 8;
        std.mem.writeInt(u64, rec[off..][0..8], e.taker_bond_locked_sat, .little); off += 8;
        std.mem.writeInt(u64, rec[off..][0..8], e.expiry_block, .little); off += 8;
        std.mem.writeInt(u64, rec[off..][0..8], e.commit_block, .little); off += 8;
        rec[off] = @intFromEnum(e.state); off += 1;
        // 7 reserved bytes already zeroed by @memset.
        off += 7;
        std.debug.assert(off == ENTRY_SIZE);
    }

    fn decodeEntry(rec: *const [ENTRY_SIZE]u8) IntentEntry {
        var e: IntentEntry = .{};
        var off: usize = 0;
        @memcpy(&e.intent_id, rec[off .. off + 32]); off += 32;
        @memcpy(&e.swap_id, rec[off .. off + 32]); off += 32;
        e.maker_address_len = rec[off]; off += 1;
        @memcpy(&e.maker_address, rec[off .. off + MAX_ADDR_LEN]); off += MAX_ADDR_LEN;
        e.taker_address_len = rec[off]; off += 1;
        @memcpy(&e.taker_address, rec[off .. off + MAX_ADDR_LEN]); off += MAX_ADDR_LEN;
        e.maker_amount_sat = std.mem.readInt(u64, rec[off..][0..8], .little); off += 8;
        e.taker_min_sat = std.mem.readInt(u64, rec[off..][0..8], .little); off += 8;
        e.maker_bond_locked_sat = std.mem.readInt(u64, rec[off..][0..8], .little); off += 8;
        e.taker_bond_locked_sat = std.mem.readInt(u64, rec[off..][0..8], .little); off += 8;
        e.expiry_block = std.mem.readInt(u64, rec[off..][0..8], .little); off += 8;
        e.commit_block = std.mem.readInt(u64, rec[off..][0..8], .little); off += 8;
        e.state = std.meta.intToEnum(IntentState, rec[off]) catch .posted;
        return e;
    }

    pub fn saveToFile(self: *const IntentRegistry, path: []const u8) !void {
        var tmp_buf: [512]u8 = undefined;
        if (path.len + 4 > tmp_buf.len) return error.PathTooLong;
        const tmp_path = try std.fmt.bufPrint(&tmp_buf, "{s}.tmp", .{path});

        var file = try std.fs.cwd().createFile(tmp_path, .{ .truncate = true });
        var file_closed = false;
        defer if (!file_closed) file.close();

        var crc = std.hash.Crc32.init();
        var hdr: [HEADER_SIZE]u8 = undefined;
        @memcpy(hdr[0..8], &MAGIC);
        std.mem.writeInt(u32, hdr[8..12], VERSION, .little);
        std.mem.writeInt(u32, hdr[12..16], self.count, .little);
        try file.writeAll(&hdr);
        crc.update(&hdr);

        var rec: [ENTRY_SIZE]u8 = undefined;
        var i: u32 = 0;
        while (i < self.count) : (i += 1) {
            encodeEntry(&self.entries[i], &rec);
            try file.writeAll(&rec);
            crc.update(&rec);
        }

        var crc_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &crc_buf, crc.final(), .little);
        try file.writeAll(&crc_buf);
        file.close();
        file_closed = true;

        try std.fs.cwd().rename(tmp_path, path);
    }

    pub fn loadFromFile(self: *IntentRegistry, path: []const u8) !void {
        var file = std.fs.cwd().openFile(path, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                self.count = 0;
                return;
            },
            else => return err,
        };
        defer file.close();

        var crc = std.hash.Crc32.init();
        var hdr: [HEADER_SIZE]u8 = undefined;
        const n = try file.readAll(&hdr);
        if (n < HEADER_SIZE) return error.CorruptIntentFile;
        if (!std.mem.eql(u8, hdr[0..8], &MAGIC)) return error.BadIntentMagic;
        const ver = std.mem.readInt(u32, hdr[8..12], .little);
        if (ver != VERSION) return error.UnsupportedIntentVersion;
        const count = std.mem.readInt(u32, hdr[12..16], .little);
        if (count > MAX_INTENTS) return error.TooManyIntents;
        crc.update(&hdr);

        self.count = 0;
        var rec: [ENTRY_SIZE]u8 = undefined;
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            const r = try file.readAll(&rec);
            if (r < ENTRY_SIZE) return error.CorruptIntentFile;
            crc.update(&rec);
            self.entries[self.count] = decodeEntry(&rec);
            self.count += 1;
        }

        var crc_buf: [4]u8 = undefined;
        const tn = try file.readAll(&crc_buf);
        if (tn < 4) return error.CorruptIntentFile;
        const stored = std.mem.readInt(u32, &crc_buf, .little);
        const computed = crc.final();
        if (stored != computed) return error.IntentCrcMismatch;
    }
};

// ─── Tests ─────────────────────────────────────────────────────────────

const testing = std.testing;

test "intent_registry — add + lookup + state transitions" {
    var reg = IntentRegistry.init();

    const id_a: [32]u8 = [_]u8{0xa1} ** 32;
    const sid_a: [32]u8 = [_]u8{0xb2} ** 32;
    var entry: IntentEntry = .{
        .intent_id = id_a,
        .swap_id = sid_a,
        .maker_amount_sat = 100_000,
        .taker_min_sat = 95_000,
        .maker_bond_locked_sat = 5_000,
        .expiry_block = 1_000_000,
    };
    const maker_addr = "ob1qmaker_aaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    @memcpy(entry.maker_address[0..maker_addr.len], maker_addr);
    entry.maker_address_len = @intCast(maker_addr.len);

    try reg.addEntry(entry);
    try testing.expectEqual(@as(u32, 1), reg.count);

    // Duplicate rejected.
    try testing.expectError(error.DuplicateIntent, reg.addEntry(entry));

    // Commit a fill.
    const taker_addr = "ob1qtaker_yyyyyyyyyyyyyyyyyyyyyyyyy";
    try reg.commitFill(id_a, taker_addr, 7_500, 1_234);
    const after_commit = reg.findById(id_a).?;
    try testing.expectEqual(IntentState.committed, after_commit.state);
    try testing.expectEqual(@as(u64, 7_500), after_commit.taker_bond_locked_sat);
    try testing.expectEqual(@as(u64, 1_234), after_commit.commit_block);
    try testing.expectEqualSlices(u8, taker_addr, after_commit.takerSlice());

    // Settle.
    try reg.markSettled(id_a);
    try testing.expectEqual(IntentState.settled, reg.findById(id_a).?.state);

    // Re-settle is rejected (state machine is one-way after terminal state).
    try testing.expectError(error.InvalidIntentState, reg.markSettled(id_a));
}

test "intent_registry — timeout path" {
    var reg = IntentRegistry.init();
    const id: [32]u8 = [_]u8{0x11} ** 32;
    const e: IntentEntry = .{ .intent_id = id, .maker_amount_sat = 1, .maker_bond_locked_sat = 2 };
    try reg.addEntry(e);

    try reg.commitFill(id, "ob1qtaker", 99, 100);
    try reg.markTimedOut(id);
    try testing.expectEqual(IntentState.timed_out, reg.findById(id).?.state);

    // Cannot settle after timeout.
    try testing.expectError(error.InvalidIntentState, reg.markSettled(id));
}

test "intent_registry — persistence round-trip" {
    var reg = IntentRegistry.init();
    const id: [32]u8 = [_]u8{0x42} ** 32;
    const sid: [32]u8 = [_]u8{0x43} ** 32;
    var e: IntentEntry = .{
        .intent_id = id,
        .swap_id = sid,
        .maker_amount_sat = 1_000_000,
        .taker_min_sat = 950_000,
        .maker_bond_locked_sat = 50_000,
        .expiry_block = 2_000_000,
    };
    const m = "ob1qmaker_persist_test_xxxxxxxxxxxxxxxx";
    @memcpy(e.maker_address[0..m.len], m); e.maker_address_len = @intCast(m.len);
    try reg.addEntry(e);
    try reg.commitFill(id, "ob1qtaker_persist_test_yyyyyyyyyyy", 25_000, 999);

    const path = "test-intent-registry-rt.bin";
    defer std.fs.cwd().deleteFile(path) catch {};
    try reg.saveToFile(path);

    var reg2 = IntentRegistry.init();
    try reg2.loadFromFile(path);
    try testing.expectEqual(@as(u32, 1), reg2.count);
    const loaded = reg2.findById(id).?;
    try testing.expectEqual(IntentState.committed, loaded.state);
    try testing.expectEqual(@as(u64, 25_000), loaded.taker_bond_locked_sat);
    try testing.expectEqual(@as(u64, 999), loaded.commit_block);
    try testing.expectEqual(@as(u64, 50_000), loaded.maker_bond_locked_sat);
    try testing.expectEqualSlices(u8, m, loaded.makerSlice());
    try testing.expectEqualSlices(u8, &sid, &loaded.swap_id);
}

test "intent_registry — missing file → empty" {
    var reg = IntentRegistry.init();
    try reg.loadFromFile("definitely-does-not-exist-intent.bin");
    try testing.expectEqual(@as(u32, 0), reg.count);
}

test "intent_registry — CRC mismatch detected" {
    var reg = IntentRegistry.init();
    const id: [32]u8 = [_]u8{0x77} ** 32;
    try reg.addEntry(.{ .intent_id = id, .maker_bond_locked_sat = 1 });
    const path = "test-intent-registry-crc.bin";
    defer std.fs.cwd().deleteFile(path) catch {};
    try reg.saveToFile(path);

    // Corrupt one byte in the body.
    {
        var f = try std.fs.cwd().openFile(path, .{ .mode = .read_write });
        defer f.close();
        try f.seekTo(IntentRegistry.HEADER_SIZE + 5);
        try f.writeAll(&[_]u8{0xff});
    }

    var reg2 = IntentRegistry.init();
    try testing.expectError(error.IntentCrcMismatch, reg2.loadFromFile(path));
}
