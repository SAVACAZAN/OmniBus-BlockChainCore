//! channel_persist.zig — durable storage for `payment_channel.ChannelManager`.
//!
//! Mirrors htlc_persist.zig / peer_persist.zig: small magic+version header,
//! payload, then a CRC32 trailer. Atomic write via tmp+rename. No allocator
//! usage — all buffers stack-resident.
//!
//! File layout (little-endian):
//!   [0..8]   MAGIC = "OMNICHN1"
//!   [8..12]  VERSION = u32 (currently 1)
//!   [12..16] payload_len = u32 (entries-only byte count, excludes header+trailer)
//!   [16..20] entry_count = u32
//!   [20..]   entry_count × ENTRY_SIZE bytes
//!   [tail-4] CRC32 of all preceding bytes (header + entries)
//!
//! Per-channel record (deterministic, fixed-size, NO per-HTLC body — htlc_count
//! is recorded as metadata only, the active HTLC cache is rebuilt on demand
//! from chain state):
//!     [0..32]   channel_id
//!     [32..65]  party_a (33B)
//!     [65..98]  party_b (33B)
//!     [98..106] capacity_sat (u64) — equals total_locked
//!     [106..114] balance_a (u64)
//!     [114..122] balance_b (u64)
//!     [122..130] sequence (u64) — equals sequence_num
//!     [130]     state (u8)
//!     [131..163] funding_tx_hash (32B)
//!     [163..171] opened_at (i64) — equals created_at
//!     [171..179] closed_at (u64) — equals close_block
//!     [179]     htlc_count (u8) — count only, htlc bodies deferred
//!     [180..188] timeout_blocks (u64) — needed to rebuild dispute window
//!   = 188 bytes per entry
//!
//! TODO(channel_persist v2): persist per-HTLC bodies and `pending_close_update`
//! once the channel HTLC routing flow is wired end-to-end. For now a node
//! restart preserves identity + balances + lifecycle state; transient
//! HTLC routing state must be re-negotiated peer-to-peer.

const std = @import("std");
const payment_mod = @import("payment_channel.zig");

const ChannelManager = payment_mod.ChannelManager;
const PaymentChannel = payment_mod.PaymentChannel;
const ChannelState = payment_mod.ChannelState;
const MAX_CHANNELS = payment_mod.MAX_CHANNELS;

pub const MAGIC: [8]u8 = .{ 'O', 'M', 'N', 'I', 'C', 'H', 'N', '1' };
pub const VERSION: u32 = 1;
pub const HEADER_SIZE: usize = 8 + 4 + 4 + 4; // magic+version+payload_len+entry_count
pub const ENTRY_SIZE: usize = 188;
const TRAILER_SIZE: usize = 4;

pub const ChannelPersistError = error{
    BadMagic,
    UnsupportedVersion,
    TooManyChannels,
    Corrupt,
    CrcMismatch,
    PathTooLong,
};

fn encodeEntry(ch: *const PaymentChannel, rec: *[ENTRY_SIZE]u8) void {
    @memset(rec, 0);
    var off: usize = 0;
    @memcpy(rec[off .. off + 32], &ch.channel_id); off += 32;
    @memcpy(rec[off .. off + 33], &ch.party_a); off += 33;
    @memcpy(rec[off .. off + 33], &ch.party_b); off += 33;
    std.mem.writeInt(u64, rec[off..][0..8], ch.total_locked, .little); off += 8;
    std.mem.writeInt(u64, rec[off..][0..8], ch.balance_a, .little); off += 8;
    std.mem.writeInt(u64, rec[off..][0..8], ch.balance_b, .little); off += 8;
    std.mem.writeInt(u64, rec[off..][0..8], ch.sequence_num, .little); off += 8;
    rec[off] = @intFromEnum(ch.state); off += 1;
    @memcpy(rec[off .. off + 32], &ch.funding_tx_hash); off += 32;
    std.mem.writeInt(i64, rec[off..][0..8], ch.created_at, .little); off += 8;
    std.mem.writeInt(u64, rec[off..][0..8], ch.close_block, .little); off += 8;
    rec[off] = ch.htlc_count; off += 1;
    std.mem.writeInt(u64, rec[off..][0..8], ch.timeout_blocks, .little); off += 8;
    std.debug.assert(off == ENTRY_SIZE);
}

fn decodeEntry(rec: *const [ENTRY_SIZE]u8) PaymentChannel {
    var ch: PaymentChannel = std.mem.zeroes(PaymentChannel);
    var off: usize = 0;
    @memcpy(&ch.channel_id, rec[off .. off + 32]); off += 32;
    @memcpy(&ch.party_a, rec[off .. off + 33]); off += 33;
    @memcpy(&ch.party_b, rec[off .. off + 33]); off += 33;
    ch.total_locked = std.mem.readInt(u64, rec[off..][0..8], .little); off += 8;
    ch.balance_a = std.mem.readInt(u64, rec[off..][0..8], .little); off += 8;
    ch.balance_b = std.mem.readInt(u64, rec[off..][0..8], .little); off += 8;
    ch.sequence_num = std.mem.readInt(u64, rec[off..][0..8], .little); off += 8;
    const st_byte = rec[off]; off += 1;
    ch.state = std.meta.intToEnum(ChannelState, st_byte) catch .opening;
    @memcpy(&ch.funding_tx_hash, rec[off .. off + 32]); off += 32;
    ch.created_at = std.mem.readInt(i64, rec[off..][0..8], .little); off += 8;
    ch.close_block = std.mem.readInt(u64, rec[off..][0..8], .little); off += 8;
    ch.htlc_count = rec[off]; off += 1;
    ch.timeout_blocks = std.mem.readInt(u64, rec[off..][0..8], .little); off += 8;
    // Transient state is reset; see TODO at top of file.
    ch.pending_close_update = null;
    ch.htlc_count = 0; // bodies aren't persisted yet; reset count to keep array consistent
    return ch;
}

/// Atomic save: writes to `<path>.tmp` then renames to `<path>`.
pub fn saveToFile(mgr: *const ChannelManager, path: []const u8) !void {
    var tmp_buf: [512]u8 = undefined;
    if (path.len + 4 > tmp_buf.len) return ChannelPersistError.PathTooLong;
    const tmp_path = try std.fmt.bufPrint(&tmp_buf, "{s}.tmp", .{path});

    var file = try std.fs.cwd().createFile(tmp_path, .{ .truncate = true });
    var file_closed = false;
    defer if (!file_closed) file.close();

    var crc = std.hash.Crc32.init();

    const count: u32 = mgr.channel_count;
    const payload_len: u32 = @intCast(@as(usize, count) * ENTRY_SIZE);

    var hdr: [HEADER_SIZE]u8 = undefined;
    @memcpy(hdr[0..8], &MAGIC);
    std.mem.writeInt(u32, hdr[8..12], VERSION, .little);
    std.mem.writeInt(u32, hdr[12..16], payload_len, .little);
    std.mem.writeInt(u32, hdr[16..20], count, .little);
    try file.writeAll(&hdr);
    crc.update(&hdr);

    var rec: [ENTRY_SIZE]u8 = undefined;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        encodeEntry(&mgr.channels[i], &rec);
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

/// Load registry from disk. Missing file → empty manager (NOT an error).
/// CRC mismatch logs a warning and leaves the manager empty rather than
/// poisoning a running node.
pub fn loadFromFile(mgr: *ChannelManager, path: []const u8) !void {
    var file = std.fs.cwd().openFile(path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            mgr.channel_count = 0;
            return;
        },
        else => return err,
    };
    defer file.close();

    var crc = std.hash.Crc32.init();

    var hdr: [HEADER_SIZE]u8 = undefined;
    const n = try file.readAll(&hdr);
    if (n < HEADER_SIZE) return ChannelPersistError.Corrupt;
    if (!std.mem.eql(u8, hdr[0..8], &MAGIC)) return ChannelPersistError.BadMagic;
    const ver = std.mem.readInt(u32, hdr[8..12], .little);
    if (ver != VERSION) return ChannelPersistError.UnsupportedVersion;
    // payload_len is informational here — we trust entry_count and ENTRY_SIZE.
    _ = std.mem.readInt(u32, hdr[12..16], .little);
    const count = std.mem.readInt(u32, hdr[16..20], .little);
    if (count > MAX_CHANNELS) return ChannelPersistError.TooManyChannels;
    crc.update(&hdr);

    mgr.channel_count = 0;
    var rec: [ENTRY_SIZE]u8 = undefined;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const r = try file.readAll(&rec);
        if (r < ENTRY_SIZE) return ChannelPersistError.Corrupt;
        crc.update(&rec);
        mgr.channels[mgr.channel_count] = decodeEntry(&rec);
        mgr.channel_count += 1;
    }

    var crc_buf: [4]u8 = undefined;
    const tn = try file.readAll(&crc_buf);
    if (tn < 4) return ChannelPersistError.Corrupt;
    const stored = std.mem.readInt(u32, &crc_buf, .little);
    const computed = crc.final();
    if (stored != computed) {
        std.debug.print("[CHANNEL-PERSIST] CRC mismatch on {s} (stored=0x{x:0>8} computed=0x{x:0>8}) — discarding load\n",
            .{ path, stored, computed });
        mgr.channel_count = 0;
        return ChannelPersistError.CrcMismatch;
    }
}

// ─── Tests ───────────────────────────────────────────────────────────────

const testing = std.testing;

fn tPubA() [33]u8 {
    var pk: [33]u8 = undefined;
    pk[0] = 0x02;
    for (pk[1..]) |*b| b.* = 0xAA;
    return pk;
}
fn tPubB() [33]u8 {
    var pk: [33]u8 = undefined;
    pk[0] = 0x03;
    for (pk[1..]) |*b| b.* = 0xBB;
    return pk;
}

test "channel_persist — round-trip preserves balances and state" {
    var mgr = ChannelManager.init();
    const ch1 = try mgr.openChannel(tPubA(), tPubB(), 1_000_000_000, 500_000_000);
    _ = try ch1.pay(true, 100_000_000, [_]u8{0x11} ** 64, [_]u8{0x22} ** 64);
    _ = try mgr.openChannel(tPubA(), tPubB(), 250_000_000, 250_000_000);

    const path = "test-channels-rt.bin";
    defer std.fs.cwd().deleteFile(path) catch {};
    try saveToFile(&mgr, path);

    var mgr2 = ChannelManager.init();
    try loadFromFile(&mgr2, path);

    try testing.expectEqual(@as(u8, 2), mgr2.channel_count);
    const restored1 = mgr2.findChannel(ch1.channel_id) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u64, 900_000_000), restored1.balance_a);
    try testing.expectEqual(@as(u64, 600_000_000), restored1.balance_b);
    try testing.expectEqual(@as(u64, 1), restored1.sequence_num);
    try testing.expectEqual(@as(u64, 1_500_000_000), restored1.total_locked);
    try testing.expectEqual(ChannelState.open, restored1.state);
    try testing.expectEqualSlices(u8, &ch1.party_a, &restored1.party_a);
    try testing.expectEqualSlices(u8, &ch1.party_b, &restored1.party_b);
    try testing.expectEqualSlices(u8, &ch1.funding_tx_hash, &restored1.funding_tx_hash);
}

test "channel_persist — missing file is not an error" {
    var mgr = ChannelManager.init();
    try loadFromFile(&mgr, "this-channel-file-does-not-exist-xyz123.bin");
    try testing.expectEqual(@as(u8, 0), mgr.channel_count);
}

test "channel_persist — corrupt magic returns BadMagic" {
    const path = "test-channels-bad-magic.bin";
    defer std.fs.cwd().deleteFile(path) catch {};
    {
        var f = try std.fs.cwd().createFile(path, .{ .truncate = true });
        defer f.close();
        // Write bogus 8B magic then enough bytes to satisfy header read.
        try f.writeAll("XXXXXXXX");
        try f.writeAll(&[_]u8{ 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 });
    }
    var mgr = ChannelManager.init();
    try testing.expectError(ChannelPersistError.BadMagic, loadFromFile(&mgr, path));
}
