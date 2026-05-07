// SPDX-License-Identifier: MIT
//
// peer_persist.zig — durable storage for the PeerScoringEngine ban list.
//
// Background: peer_scoring.zig owns the in-memory ban table and exposes
// serializeBans / deserializeBans (record-only payload). This module wraps
// those into a versioned on-disk file so bans survive node restarts and
// crashes — a banned peer can't dodge by waiting for the operator to bounce
// the process.
//
// File layout (`peer-bans.dat`, alongside `omnibus-chain.dat`):
//
//   offset  size  field
//   0       8     magic    = "OMNIPBAN"  (Omni Peer Ban)
//   8       4     version  = u32 LE, currently 1
//   12      4     payload_len = u32 LE (bytes that follow before crc)
//   16      N     payload  = peer_scoring.serializeBans output
//   16+N    4     crc32    = std.hash.crc.Crc32 over [magic..payload_end]
//
// On corruption (bad magic, bad version, payload_len > MAX_PAYLOAD, or CRC
// mismatch) we log and start with an empty ban list rather than refusing
// to boot — banned peers will simply re-earn their bans on first offense.
//
// Periodic save: caller fires saveToFile() every ~60s plus once at graceful
// shutdown. There's no tombstone / delta format — the file is small
// (≤ 28 KiB worst case at MAX_BANNED_PEERS=1024) so a full rewrite per
// save is cheap.

const std = @import("std");
const peer_scoring_mod = @import("peer_scoring.zig");

const MAGIC: [8]u8 = .{ 'O', 'M', 'N', 'I', 'P', 'B', 'A', 'N' };
const VERSION: u32 = 1;

// MAX_BANNED_PEERS=1024, record_size=28, +4 count header → 28 676.
const MAX_PAYLOAD: usize = 4 + peer_scoring_mod.MAX_BANNED_PEERS * 28;
const HEADER_SIZE: usize = 8 + 4 + 4; // magic + version + payload_len
const TRAILER_SIZE: usize = 4;        // crc32

/// Persist the engine's ban list to `path`. Atomic-ish: we write the full
/// file in one syscall via createFile (truncate=true). Cheap enough at
/// ≤28 KiB that we can call this on every shutdown + every 60s without
/// caring about partial writes.
pub fn saveToFile(engine: *const peer_scoring_mod.PeerScoringEngine, path: []const u8) !void {
    var payload_buf: [MAX_PAYLOAD]u8 = undefined;
    const payload_len = try engine.serializeBans(&payload_buf);

    var out_buf: [HEADER_SIZE + MAX_PAYLOAD + TRAILER_SIZE]u8 = undefined;
    @memcpy(out_buf[0..8], &MAGIC);
    std.mem.writeInt(u32, out_buf[8..12], VERSION, .little);
    std.mem.writeInt(u32, out_buf[12..16], @intCast(payload_len), .little);
    @memcpy(out_buf[HEADER_SIZE .. HEADER_SIZE + payload_len], payload_buf[0..payload_len]);

    // CRC32 covers magic + version + payload_len + payload.
    const Crc32 = std.hash.crc.Crc32;
    const crc = Crc32.hash(out_buf[0 .. HEADER_SIZE + payload_len]);
    std.mem.writeInt(u32, out_buf[HEADER_SIZE + payload_len ..][0..4], crc, .little);

    const total = HEADER_SIZE + payload_len + TRAILER_SIZE;
    var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(out_buf[0..total]);
}

/// Restore the ban list from `path`. Missing file = first run (empty bans,
/// not an error). Corruption = log + start empty (returns CorruptFile).
/// Caller decides whether to surface or swallow.
pub fn loadFromFile(engine: *peer_scoring_mod.PeerScoringEngine, path: []const u8) !void {
    var file = std.fs.cwd().openFile(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer file.close();

    var buf: [HEADER_SIZE + MAX_PAYLOAD + TRAILER_SIZE]u8 = undefined;
    const n = try file.readAll(&buf);
    if (n < HEADER_SIZE + TRAILER_SIZE) return error.CorruptFile;
    if (!std.mem.eql(u8, buf[0..8], &MAGIC)) return error.BadMagic;
    const ver = std.mem.readInt(u32, buf[8..12], .little);
    if (ver != VERSION) return error.UnsupportedVersion;
    const payload_len = std.mem.readInt(u32, buf[12..16], .little);
    if (payload_len > MAX_PAYLOAD) return error.CorruptFile;
    if (n < HEADER_SIZE + payload_len + TRAILER_SIZE) return error.CorruptFile;

    const Crc32 = std.hash.crc.Crc32;
    const expected = Crc32.hash(buf[0 .. HEADER_SIZE + payload_len]);
    const got = std.mem.readInt(u32, buf[HEADER_SIZE + payload_len ..][0..4], .little);
    if (got != expected) return error.CrcMismatch;

    try engine.deserializeBans(buf[HEADER_SIZE .. HEADER_SIZE + payload_len]);
}

// ─── Tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

test "peer_persist — round-trip preserves bans" {
    const tmp_path = "test_peer_persist_roundtrip.dat";
    defer std.fs.cwd().deleteFile(tmp_path) catch {};

    var engine = peer_scoring_mod.PeerScoringEngine.init();
    engine.scoreEvent([_]u8{0xAA} ** 16, .double_spend_attempt);
    engine.scoreEvent([_]u8{0xBB} ** 16, .double_spend_attempt);
    try testing.expectEqual(@as(usize, 2), engine.persistentBanCount());

    try saveToFile(&engine, tmp_path);

    var engine2 = peer_scoring_mod.PeerScoringEngine.init();
    try loadFromFile(&engine2, tmp_path);
    try testing.expectEqual(@as(usize, 2), engine2.persistentBanCount());
    try testing.expect(!engine2.isAllowed([_]u8{0xAA} ** 16));
    try testing.expect(!engine2.isAllowed([_]u8{0xBB} ** 16));
}

test "peer_persist — missing file is not an error" {
    var engine = peer_scoring_mod.PeerScoringEngine.init();
    try loadFromFile(&engine, "definitely_does_not_exist_peer_bans_xyz.dat");
    try testing.expectEqual(@as(usize, 0), engine.persistentBanCount());
}

test "peer_persist — corrupt magic rejected" {
    const tmp_path = "test_peer_persist_corrupt.dat";
    defer std.fs.cwd().deleteFile(tmp_path) catch {};

    var engine = peer_scoring_mod.PeerScoringEngine.init();
    engine.scoreEvent([_]u8{0xCC} ** 16, .double_spend_attempt);
    try saveToFile(&engine, tmp_path);

    // Stomp the magic.
    var f = try std.fs.cwd().openFile(tmp_path, .{ .mode = .read_write });
    defer f.close();
    try f.seekTo(0);
    try f.writeAll("XXXXXXXX");

    var engine2 = peer_scoring_mod.PeerScoringEngine.init();
    try testing.expectError(error.BadMagic, loadFromFile(&engine2, tmp_path));
}

test "peer_persist — CRC mismatch rejected" {
    const tmp_path = "test_peer_persist_crc.dat";
    defer std.fs.cwd().deleteFile(tmp_path) catch {};

    var engine = peer_scoring_mod.PeerScoringEngine.init();
    engine.scoreEvent([_]u8{0xDD} ** 16, .double_spend_attempt);
    try saveToFile(&engine, tmp_path);

    // Flip a byte inside the payload (after header, before CRC).
    var f = try std.fs.cwd().openFile(tmp_path, .{ .mode = .read_write });
    defer f.close();
    try f.seekTo(HEADER_SIZE + 4); // first peer_id byte
    try f.writeAll("\xFF");

    var engine2 = peer_scoring_mod.PeerScoringEngine.init();
    try testing.expectError(error.CrcMismatch, loadFromFile(&engine2, tmp_path));
}
