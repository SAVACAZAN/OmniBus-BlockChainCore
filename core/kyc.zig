/// kyc.zig — on-chain KYC attestations (NO PII, just signed level proofs).
///
/// PII (real name, ID image, selfie) is processed off-chain in the user's
/// browser (face-api.js) or by an external provider (Sumsub/Onfido on
/// mainnet). What lands here is a tiny attestation:
///
///   `{address, level, issuer, issued_ms, expires_ms, sig_hex}`
///
/// where `sig` is the issuer's secp256k1 signature over the canonical
/// message. Anyone can verify it; nothing private leaks.
///
/// On testnet the only valid issuer is the founder's KYC slot wallet
/// (idx 4 in `registrar_addresses.zig`). On mainnet a third-party KYC
/// provider can be granted the same role by handing them this slot's
/// private key — the rest of the chain doesn't notice.
///
/// Persisted append-only at `data/<chain>/kyc-attestations.jsonl`.
const std = @import("std");

/// KYC tiers, mirrored from Kraken/LCX. Limits are enforced in
/// `rpc_server.zig` per-action (withdraw / large order / premium ENS).
pub const Level = enum(u8) {
    /// No KYC. Default. Limit: small. Not exposed as a badge.
    none = 0,
    /// Starter — name + DOB + country verified. Limit: $5k/24h equivalent.
    starter = 1,
    /// Verified — government ID + selfie liveness. Limit: $50k/24h.
    verified = 2,
    /// Pro — proof of address + source of funds. No volume limit.
    pro = 3,

    pub fn fromU8(v: u8) Level {
        return switch (v) {
            1 => .starter,
            2 => .verified,
            3 => .pro,
            else => .none,
        };
    }
    pub fn toU8(self: Level) u8 {
        return @intFromEnum(self);
    }
    pub fn label(self: Level) []const u8 {
        return switch (self) {
            .none => "none",
            .starter => "starter",
            .verified => "verified",
            .pro => "pro",
        };
    }
};

/// One on-chain attestation row.
pub const Attestation = struct {
    address: [64]u8 = undefined,
    address_len: u8 = 0,
    level: Level = .none,
    /// Issuer address (must be a registered KYC issuer — slot 4 on testnet).
    issuer: [64]u8 = undefined,
    issuer_len: u8 = 0,
    issued_ms: i64 = 0,
    /// 0 = never expires (rare; default is +1 year).
    expires_ms: i64 = 0,
    /// Issuer's secp256k1 signature over `KYC_ATTEST_V1\n<address>\n<level>\n<issuer>\n<issued_ms>\n<expires_ms>`.
    /// Hex (128 chars). Anyone can verify with the issuer's pubkey from
    /// `pubkey_registry`. Empty = unsigned (replay placeholder).
    sig_hex: [128]u8 = undefined,
    sig_hex_len: u8 = 0,

    pub fn isExpired(self: *const Attestation, now_ms: i64) bool {
        if (self.expires_ms == 0) return false;
        return now_ms >= self.expires_ms;
    }

    pub fn getAddress(self: *const Attestation) []const u8 {
        return self.address[0..self.address_len];
    }
    pub fn getIssuer(self: *const Attestation) []const u8 {
        return self.issuer[0..self.issuer_len];
    }
    pub fn getSig(self: *const Attestation) []const u8 {
        return self.sig_hex[0..self.sig_hex_len];
    }
};

pub const MAX_ATTESTATIONS: usize = 4096;

/// Canonical message that issuer signs. Frontend reproduces this string
/// to verify any attestation locally; backend reproduces it on every
/// `kyc_attest` to verify the issuer's signature.
pub fn buildAttestMessage(
    out: []u8,
    address: []const u8,
    level: Level,
    issuer: []const u8,
    issued_ms: i64,
    expires_ms: i64,
) ![]u8 {
    return std.fmt.bufPrint(out,
        "KYC_ATTEST_V1\n{s}\n{d}\n{s}\n{d}\n{d}",
        .{ address, level.toU8(), issuer, issued_ms, expires_ms });
}

pub const KycStore = struct {
    items: [MAX_ATTESTATIONS]Attestation = undefined,
    count: u16 = 0,
    journal_path_buf: [256]u8 = undefined,
    journal_path_len: usize = 0,

    pub fn init() KycStore {
        var s = KycStore{};
        @memset(std.mem.asBytes(&s), 0);
        return s;
    }

    pub fn setJournalPath(self: *KycStore, path: []const u8) void {
        const n = @min(path.len, self.journal_path_buf.len);
        @memcpy(self.journal_path_buf[0..n], path[0..n]);
        self.journal_path_len = n;
    }

    fn journalPath(self: *const KycStore) ?[]const u8 {
        if (self.journal_path_len == 0) return null;
        return self.journal_path_buf[0..self.journal_path_len];
    }

    /// Look up the latest non-expired attestation for `address`.
    /// Multiple issuers can attest the same address; we return the one
    /// with the highest level (and within that, the most recent).
    pub fn highest(self: *KycStore, address: []const u8, now_ms: i64) ?*Attestation {
        var best: ?*Attestation = null;
        var i: u16 = 0;
        while (i < self.count) : (i += 1) {
            const it = &self.items[i];
            if (it.address_len != address.len) continue;
            if (!std.mem.eql(u8, it.address[0..it.address_len], address)) continue;
            if (it.isExpired(now_ms)) continue;
            if (best == null or
                it.level.toU8() > best.?.level.toU8() or
                (it.level.toU8() == best.?.level.toU8() and it.issued_ms > best.?.issued_ms))
            {
                best = it;
            }
        }
        return best;
    }

    /// Insert a new attestation. Caller must have verified the issuer's
    /// signature already — this store only persists, doesn't crypto-check.
    pub fn append(
        self: *KycStore,
        address: []const u8,
        level: Level,
        issuer: []const u8,
        issued_ms: i64,
        expires_ms: i64,
        sig_hex: []const u8,
        write_journal: bool,
    ) !void {
        if (address.len == 0 or address.len > 64) return error.BadAddress;
        if (issuer.len == 0 or issuer.len > 64) return error.BadIssuer;
        if (sig_hex.len > 128) return error.BadSignature;
        if (self.count >= self.items.len) return error.StoreFull;

        const slot = &self.items[self.count];
        slot.* = .{};
        const an = @min(address.len, slot.address.len);
        @memcpy(slot.address[0..an], address[0..an]);
        slot.address_len = @intCast(an);
        slot.level = level;
        const in = @min(issuer.len, slot.issuer.len);
        @memcpy(slot.issuer[0..in], issuer[0..in]);
        slot.issuer_len = @intCast(in);
        slot.issued_ms = issued_ms;
        slot.expires_ms = expires_ms;
        const sn = @min(sig_hex.len, slot.sig_hex.len);
        @memcpy(slot.sig_hex[0..sn], sig_hex[0..sn]);
        slot.sig_hex_len = @intCast(sn);
        self.count += 1;

        if (write_journal) self.appendJournal(slot.*);
    }

    fn appendJournal(self: *KycStore, it: Attestation) void {
        const path = self.journalPath() orelse return;
        const f = std.fs.cwd().createFile(path, .{ .truncate = false, .read = false }) catch |err| {
            std.debug.print("[KYC] cannot open {s}: {}\n", .{ path, err });
            return;
        };
        defer f.close();
        f.seekFromEnd(0) catch return;
        var buf: [768]u8 = undefined;
        const line = std.fmt.bufPrint(&buf,
            "{{\"address\":\"{s}\",\"level\":{d},\"issuer\":\"{s}\",\"issued\":{d},\"expires\":{d},\"sig\":\"{s}\"}}\n",
            .{ it.getAddress(), it.level.toU8(), it.getIssuer(),
               it.issued_ms, it.expires_ms, it.getSig() },
        ) catch return;
        _ = f.writeAll(line) catch {};
    }

    pub fn replay(self: *KycStore) !void {
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
            const issuer = extractField(line, "issuer") orelse continue;
            const sig = extractField(line, "sig") orelse "";
            const lvl_u = extractInt(line, "level") orelse 0;
            const issued = extractInt(line, "issued") orelse 0;
            const expires = extractInt(line, "expires") orelse 0;
            self.append(addr, Level.fromU8(@intCast(@max(lvl_u, 0))), issuer, issued, expires, sig, false) catch continue;
            n += 1;
        }
        std.debug.print("[KYC] replayed {d} attestation(s) from {s}\n", .{ n, path });
    }
};

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

test "append + highest returns latest non-expired" {
    var s = KycStore.init();
    try s.append("ob1qalice", .starter, "ob1qkyc", 100, 0, "deadbeef", false);
    try s.append("ob1qalice", .verified, "ob1qkyc", 200, 0, "cafebabe", false);
    const got = s.highest("ob1qalice", 300).?;
    try std.testing.expectEqual(Level.verified, got.level);
}

test "expired attestation is skipped" {
    var s = KycStore.init();
    try s.append("ob1qbob", .verified, "ob1qkyc", 100, 200, "abc", false);
    try std.testing.expect(s.highest("ob1qbob", 150) != null);
    try std.testing.expect(s.highest("ob1qbob", 250) == null);
}

test "buildAttestMessage round-trips fields" {
    var buf: [256]u8 = undefined;
    const m = try buildAttestMessage(&buf, "ob1qalice", .verified, "ob1qkyc", 100, 200);
    try std.testing.expect(std.mem.indexOf(u8, m, "KYC_ATTEST_V1") != null);
    try std.testing.expect(std.mem.indexOf(u8, m, "ob1qalice") != null);
    try std.testing.expect(std.mem.indexOf(u8, m, "\n2\n") != null); // level=2
}
