/// identity.zig — public on-chain identity (nickname + ENS preference + visibility).
///
/// This is the OPT-IN public face of an address. Separate from KYC (which
/// is private + attested). Anyone with the address's private key can:
///
///   - Set a `nickname` (display name). 1..32 ASCII printable chars.
///   - Mark a `.omnibus` ENS as their primary (display preference).
///   - Choose `visibility`: public (everyone sees), private (no one — even
///     the row exists only to let *you* read it back), or ens_only (we
///     show your `.omnibus` ENS but not your raw `ob1q...` or nickname).
///
/// Persisted as append-only JSONL at `data/<chain>/identities.jsonl`,
/// replayed on startup. Same pattern as faucet/orders/exchange-users.
///
/// Rich List + BlockExplorer call `identityFor(addr)` and decide what
/// to render — they get back `null` for private addresses.
const std = @import("std");

pub const NICKNAME_MAX: usize = 32;
pub const ENS_MAX: usize = 64;

pub const Visibility = enum(u8) {
    /// Show nickname + ENS to everyone. Default for new identities.
    public = 0,
    /// Hide everything. Address is still on-chain; we just don't
    /// render any extras for it.
    private = 1,
    /// Show only the user's primary `.omnibus` ENS, not the nickname
    /// or raw `ob1q...` address (still leaks address under the ENS,
    /// but a partial-anonymity option people often want).
    ens_only = 2,

    pub fn fromStr(s: []const u8) Visibility {
        if (std.mem.eql(u8, s, "public")) return .public;
        if (std.mem.eql(u8, s, "private")) return .private;
        if (std.mem.eql(u8, s, "ens_only")) return .ens_only;
        return .public;
    }
    pub fn toStr(self: Visibility) []const u8 {
        return switch (self) {
            .public => "public",
            .private => "private",
            .ens_only => "ens_only",
        };
    }
};

pub const Identity = struct {
    address: [64]u8 = undefined,
    address_len: u8 = 0,
    nickname: [NICKNAME_MAX]u8 = undefined,
    nickname_len: u8 = 0,
    ens_primary: [ENS_MAX]u8 = undefined,
    ens_primary_len: u8 = 0,
    visibility: Visibility = .public,
    /// Last update timestamp (ms). Used to choose latest when replaying
    /// a journal that has multiple entries for the same address.
    updated_ms: i64 = 0,

    pub fn getAddress(self: *const Identity) []const u8 {
        return self.address[0..self.address_len];
    }
    pub fn getNickname(self: *const Identity) []const u8 {
        return self.nickname[0..self.nickname_len];
    }
    pub fn getEns(self: *const Identity) []const u8 {
        return self.ens_primary[0..self.ens_primary_len];
    }
};

/// Bounded in-memory store. Like the rest of the chain we keep this
/// flat + linear-scanned — testnet has < 1000 named users, lookup
/// cost is irrelevant. Move to a HashMap on demand.
pub const MAX_IDENTITIES: usize = 4096;

pub const IdentityStore = struct {
    items: [MAX_IDENTITIES]Identity = undefined,
    count: u16 = 0,
    /// Append-only journal path. Empty = in-memory only.
    journal_path_buf: [256]u8 = undefined,
    journal_path_len: usize = 0,

    pub fn init() IdentityStore {
        var s = IdentityStore{};
        @memset(std.mem.asBytes(&s), 0);
        return s;
    }

    pub fn setJournalPath(self: *IdentityStore, path: []const u8) void {
        const n = @min(path.len, self.journal_path_buf.len);
        @memcpy(self.journal_path_buf[0..n], path[0..n]);
        self.journal_path_len = n;
    }

    fn journalPath(self: *const IdentityStore) ?[]const u8 {
        if (self.journal_path_len == 0) return null;
        return self.journal_path_buf[0..self.journal_path_len];
    }

    /// Look up by address. Returns null if not found OR if the
    /// identity is `private` AND `respect_visibility` is true (so
    /// callers that *need* the row, e.g. for "is this my own?",
    /// pass false; UI callers pass true).
    pub fn lookup(self: *IdentityStore, address: []const u8, respect_visibility: bool) ?*Identity {
        var i: u16 = 0;
        while (i < self.count) : (i += 1) {
            const it = &self.items[i];
            if (it.address_len != address.len) continue;
            if (!std.mem.eql(u8, it.address[0..it.address_len], address)) continue;
            if (respect_visibility and it.visibility == .private) return null;
            return it;
        }
        return null;
    }

    /// Insert or update. The journal is appended ONLY when caller
    /// asks for it (so replay doesn't re-write existing lines).
    pub fn upsert(
        self: *IdentityStore,
        address: []const u8,
        nickname: []const u8,
        ens_primary: []const u8,
        visibility: Visibility,
        updated_ms: i64,
        write_journal: bool,
    ) !void {
        if (address.len == 0 or address.len > 64) return error.BadAddress;
        if (nickname.len > NICKNAME_MAX) return error.NicknameTooLong;
        if (ens_primary.len > ENS_MAX) return error.EnsTooLong;
        if (!isPrintableAscii(nickname)) return error.NicknameNotPrintable;

        // Find existing row OR claim a new slot.
        var slot: *Identity = blk: {
            if (self.lookup(address, false)) |existing| break :blk existing;
            if (self.count >= self.items.len) return error.StoreFull;
            const fresh = &self.items[self.count];
            fresh.* = .{};
            const an = @min(address.len, fresh.address.len);
            @memcpy(fresh.address[0..an], address[0..an]);
            fresh.address_len = @intCast(an);
            self.count += 1;
            break :blk fresh;
        };

        const nn = @min(nickname.len, slot.nickname.len);
        @memcpy(slot.nickname[0..nn], nickname[0..nn]);
        slot.nickname_len = @intCast(nn);
        const en = @min(ens_primary.len, slot.ens_primary.len);
        @memcpy(slot.ens_primary[0..en], ens_primary[0..en]);
        slot.ens_primary_len = @intCast(en);
        slot.visibility = visibility;
        slot.updated_ms = updated_ms;

        if (write_journal) self.appendJournal(slot.*);
    }

    fn appendJournal(self: *IdentityStore, it: Identity) void {
        const path = self.journalPath() orelse return;
        const f = std.fs.cwd().createFile(path, .{ .truncate = false, .read = false }) catch |err| {
            std.debug.print("[IDENTITY] cannot open {s}: {}\n", .{ path, err });
            return;
        };
        defer f.close();
        f.seekFromEnd(0) catch return;
        var buf: [512]u8 = undefined;
        const line = std.fmt.bufPrint(&buf,
            "{{\"address\":\"{s}\",\"nickname\":\"{s}\",\"ens\":\"{s}\",\"visibility\":\"{s}\",\"ts\":{d}}}\n",
            .{ it.getAddress(), it.getNickname(), it.getEns(), it.visibility.toStr(), it.updated_ms },
        ) catch return;
        _ = f.writeAll(line) catch {};
    }

    /// Replay journal at startup. Each line is parsed minimally
    /// (no full JSON parser — we control the format).
    pub fn replay(self: *IdentityStore) !void {
        const path = self.journalPath() orelse return;
        const f = std.fs.cwd().openFile(path, .{}) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer f.close();
        const stat = try f.stat();
        if (stat.size == 0) return;

        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const buf = try arena.allocator().alloc(u8, @intCast(stat.size));
        _ = try f.readAll(buf);

        var lines = std.mem.splitScalar(u8, buf, '\n');
        var n: usize = 0;
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            const addr = extractField(line, "address") orelse continue;
            const nick = extractField(line, "nickname") orelse "";
            const ens = extractField(line, "ens") orelse "";
            const vis = extractField(line, "visibility") orelse "public";
            const ts = extractInt(line, "ts") orelse 0;
            self.upsert(addr, nick, ens, Visibility.fromStr(vis), ts, false) catch continue;
            n += 1;
        }
        std.debug.print("[IDENTITY] replayed {d} identity event(s) from {s}\n", .{ n, path });
    }
};

// ── tiny JSON helpers (we control the format, parsing is minimal) ──

fn extractField(line: []const u8, key: []const u8) ?[]const u8 {
    var key_buf: [48]u8 = undefined;
    if (key.len + 4 > key_buf.len) return null;
    const wrapped = std.fmt.bufPrint(&key_buf, "\"{s}\":\"", .{key}) catch return null;
    const start = std.mem.indexOf(u8, line, wrapped) orelse return null;
    const from = start + wrapped.len;
    const end = std.mem.indexOfScalarPos(u8, line, from, '"') orelse return null;
    return line[from..end];
}

fn extractInt(line: []const u8, key: []const u8) ?i64 {
    var key_buf: [48]u8 = undefined;
    if (key.len + 3 > key_buf.len) return null;
    const wrapped = std.fmt.bufPrint(&key_buf, "\"{s}\":", .{key}) catch return null;
    const start = std.mem.indexOf(u8, line, wrapped) orelse return null;
    var from = start + wrapped.len;
    while (from < line.len and (line[from] == ' ' or line[from] == '\t')) from += 1;
    var end = from;
    while (end < line.len and (std.ascii.isDigit(line[end]) or line[end] == '-')) end += 1;
    if (end == from) return null;
    return std.fmt.parseInt(i64, line[from..end], 10) catch null;
}

/// Nickname must be printable ASCII (no control chars, no quote).
/// Rejects emoji and unicode for now — keeps Rich List rendering predictable
/// in any terminal/font, and avoids homograph attacks (`Аlice` vs `Alice`).
fn isPrintableAscii(s: []const u8) bool {
    for (s) |c| {
        if (c < 0x20 or c >= 0x7F) return false;
        if (c == '"' or c == '\\') return false;
    }
    return true;
}

test "Visibility round-trip" {
    try std.testing.expectEqual(Visibility.public, Visibility.fromStr("public"));
    try std.testing.expectEqual(Visibility.private, Visibility.fromStr("private"));
    try std.testing.expectEqual(Visibility.ens_only, Visibility.fromStr("ens_only"));
    try std.testing.expectEqualStrings("public", Visibility.public.toStr());
    try std.testing.expectEqualStrings("private", Visibility.private.toStr());
}

test "upsert + lookup" {
    var s = IdentityStore.init();
    try s.upsert("ob1qabc", "alice", "alice.omnibus", .public, 100, false);
    const got = s.lookup("ob1qabc", true).?;
    try std.testing.expectEqualStrings("alice", got.getNickname());
    try std.testing.expectEqualStrings("alice.omnibus", got.getEns());
    try std.testing.expectEqual(Visibility.public, got.visibility);
    try std.testing.expectEqual(@as(i64, 100), got.updated_ms);

    // Update — same address, new nickname
    try s.upsert("ob1qabc", "alice2", "", .private, 200, false);
    try std.testing.expectEqual(@as(u16, 1), s.count);
    const got2 = s.lookup("ob1qabc", false).?;
    try std.testing.expectEqualStrings("alice2", got2.getNickname());

    // Visibility=private + respect_visibility=true → null for outsiders
    try std.testing.expect(s.lookup("ob1qabc", true) == null);
}

test "isPrintableAscii rejects control + quote + non-ascii" {
    try std.testing.expect(isPrintableAscii("alice"));
    try std.testing.expect(isPrintableAscii("alice42"));
    try std.testing.expect(!isPrintableAscii("alice\"quote"));
    try std.testing.expect(!isPrintableAscii("alice\nnewline"));
    try std.testing.expect(!isPrintableAscii("\xc4\x83")); // ă
}
