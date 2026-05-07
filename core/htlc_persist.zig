//! htlc_persist.zig — durable storage for `HtlcOnChainRegistry`.
//!
//! Mirrors the design of `dns_registry.zig` save/load: a small magic +
//! version header, a count, then one fixed-size record per entry, then a
//! CRC32 trailer. Atomic writes via tmp + rename. No allocator usage —
//! all buffers are stack-resident.
//!
//! File layout (little-endian):
//!   [0..8]    MAGIC  = "OMNIHTL1"
//!   [8..12]   VERSION = u32 (currently 1)
//!   [12..16]  entry_count = u32
//!   [16..]    entry_count × ENTRY_SIZE bytes
//!   [tail-4]  CRC32 of all preceding bytes (header + entries)
//!
//! ENTRY_SIZE = 32 (id) + 1 (sender_len) + 64 (sender) + 1 (rec_len) + 64 (rec)
//!             + 8 (amount_sat) + 32 (hash_lock) + 8 (timelock) + 8 (init_block)
//!             + 1 (init_tx_hash_len) + 64 (init_tx_hash)
//!             + 1 (state) + 1 (has_preimage) + 32 (preimage)
//!           = 317 bytes per entry.
//!
//! At MAX_HTLCS=4096 worst-case file = 4096 × 317 + 20 ≈ 1.27 MiB.

const std = @import("std");
const htlc_mod = @import("htlc.zig");

const HtlcOnChainRegistry = htlc_mod.HtlcOnChainRegistry;
const HtlcEntry = htlc_mod.HtlcEntry;
const HTLCState = htlc_mod.HTLCState;
const HTLC_MAX_ADDR_LEN = htlc_mod.HTLC_MAX_ADDR_LEN;

pub const MAGIC: [8]u8 = .{ 'O', 'M', 'N', 'I', 'H', 'T', 'L', '1' };
pub const VERSION: u32 = 1;
pub const HEADER_SIZE: usize = 8 + 4 + 4;
pub const ENTRY_SIZE: usize =
    32 + 1 + HTLC_MAX_ADDR_LEN + 1 + HTLC_MAX_ADDR_LEN +
    8 + 32 + 8 + 8 + 1 + 64 + 1 + 1 + 32;

const TRAILER_SIZE: usize = 4;

/// Serialize one entry into a stack record. Layout matches loadFromFile.
fn encodeEntry(e: *const HtlcEntry, rec: *[ENTRY_SIZE]u8) void {
    @memset(rec, 0);
    var off: usize = 0;
    @memcpy(rec[off .. off + 32], &e.id); off += 32;
    rec[off] = e.sender_len; off += 1;
    @memcpy(rec[off .. off + HTLC_MAX_ADDR_LEN], &e.sender); off += HTLC_MAX_ADDR_LEN;
    rec[off] = e.recipient_len; off += 1;
    @memcpy(rec[off .. off + HTLC_MAX_ADDR_LEN], &e.recipient); off += HTLC_MAX_ADDR_LEN;
    std.mem.writeInt(u64, rec[off..][0..8], e.amount_sat, .little); off += 8;
    @memcpy(rec[off .. off + 32], &e.hash_lock); off += 32;
    std.mem.writeInt(u64, rec[off..][0..8], e.timelock_block, .little); off += 8;
    std.mem.writeInt(u64, rec[off..][0..8], e.init_block, .little); off += 8;
    rec[off] = e.init_tx_hash_len; off += 1;
    @memcpy(rec[off .. off + 64], &e.init_tx_hash); off += 64;
    rec[off] = @intFromEnum(e.state); off += 1;
    rec[off] = if (e.has_preimage) 1 else 0; off += 1;
    @memcpy(rec[off .. off + 32], &e.preimage); off += 32;
    std.debug.assert(off == ENTRY_SIZE);
}

fn decodeEntry(rec: *const [ENTRY_SIZE]u8) HtlcEntry {
    var e: HtlcEntry = std.mem.zeroes(HtlcEntry);
    var off: usize = 0;
    @memcpy(&e.id, rec[off .. off + 32]); off += 32;
    e.sender_len = rec[off]; off += 1;
    @memcpy(&e.sender, rec[off .. off + HTLC_MAX_ADDR_LEN]); off += HTLC_MAX_ADDR_LEN;
    e.recipient_len = rec[off]; off += 1;
    @memcpy(&e.recipient, rec[off .. off + HTLC_MAX_ADDR_LEN]); off += HTLC_MAX_ADDR_LEN;
    e.amount_sat = std.mem.readInt(u64, rec[off..][0..8], .little); off += 8;
    @memcpy(&e.hash_lock, rec[off .. off + 32]); off += 32;
    e.timelock_block = std.mem.readInt(u64, rec[off..][0..8], .little); off += 8;
    e.init_block = std.mem.readInt(u64, rec[off..][0..8], .little); off += 8;
    e.init_tx_hash_len = rec[off]; off += 1;
    @memcpy(&e.init_tx_hash, rec[off .. off + 64]); off += 64;
    const st_byte = rec[off]; off += 1;
    e.state = std.meta.intToEnum(HTLCState, st_byte) catch .active;
    e.has_preimage = rec[off] != 0; off += 1;
    @memcpy(&e.preimage, rec[off .. off + 32]); off += 32;
    return e;
}

/// Save the entire registry atomically. Writes to `<path>.tmp` then renames.
pub fn saveToFile(reg: *const HtlcOnChainRegistry, path: []const u8) !void {
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
    std.mem.writeInt(u32, hdr[12..16], reg.entry_count, .little);
    try file.writeAll(&hdr);
    crc.update(&hdr);

    var rec: [ENTRY_SIZE]u8 = undefined;
    var i: u32 = 0;
    while (i < reg.entry_count) : (i += 1) {
        encodeEntry(&reg.entries[i], &rec);
        try file.writeAll(&rec);
        crc.update(&rec);
    }

    var crc_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &crc_buf, crc.final(), .little);
    try file.writeAll(&crc_buf);
    file.close();
    file_closed = true;

    // Replace the live file atomically.
    try std.fs.cwd().rename(tmp_path, path);
}

/// Load the registry from disk. Missing file → empty registry (not an error).
pub fn loadFromFile(reg: *HtlcOnChainRegistry, path: []const u8) !void {
    var file = std.fs.cwd().openFile(path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            reg.entry_count = 0;
            return;
        },
        else => return err,
    };
    defer file.close();

    var crc = std.hash.Crc32.init();

    var hdr: [HEADER_SIZE]u8 = undefined;
    const n = try file.readAll(&hdr);
    if (n < HEADER_SIZE) return error.CorruptHtlcFile;
    if (!std.mem.eql(u8, hdr[0..8], &MAGIC)) return error.BadHtlcMagic;
    const ver = std.mem.readInt(u32, hdr[8..12], .little);
    if (ver != VERSION) return error.UnsupportedHtlcVersion;
    const count = std.mem.readInt(u32, hdr[12..16], .little);
    if (count > htlc_mod.MAX_HTLCS) return error.TooManyHtlcs;
    crc.update(&hdr);

    reg.entry_count = 0;
    var rec: [ENTRY_SIZE]u8 = undefined;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const r = try file.readAll(&rec);
        if (r < ENTRY_SIZE) return error.CorruptHtlcFile;
        crc.update(&rec);
        reg.entries[reg.entry_count] = decodeEntry(&rec);
        reg.entry_count += 1;
    }

    var crc_buf: [4]u8 = undefined;
    const tn = try file.readAll(&crc_buf);
    if (tn < 4) return error.CorruptHtlcFile;
    const stored = std.mem.readInt(u32, &crc_buf, .little);
    const computed = crc.final();
    if (stored != computed) return error.HtlcCrcMismatch;
}

// ─── Tests ───────────────────────────────────────────────────────────────

const testing = std.testing;

test "htlc_persist — round-trip empty registry" {
    var reg = HtlcOnChainRegistry.init();
    const path = "test-htlc-empty.bin";
    defer std.fs.cwd().deleteFile(path) catch {};
    try saveToFile(&reg, path);
    var reg2 = HtlcOnChainRegistry.init();
    try loadFromFile(&reg2, path);
    try testing.expectEqual(@as(u32, 0), reg2.entry_count);
}

test "htlc_persist — round-trip with entries preserves state" {
    var reg = HtlcOnChainRegistry.init();
    const pair = htlc_mod.HTLC.generatePreimage();
    const id = htlc_mod.computeHtlcId("11" ** 32);
    var e = HtlcEntry{
        .id = id,
        .amount_sat = 99,
        .hash_lock = pair.hash,
        .timelock_block = 500,
        .init_block = 10,
    };
    const a = "ob1qsender_addr_for_persist_test_xx";
    const b = "ob1qrecipient_addr_for_persist_test";
    @memcpy(e.sender[0..a.len], a); e.sender_len = @intCast(a.len);
    @memcpy(e.recipient[0..b.len], b); e.recipient_len = @intCast(b.len);
    try reg.addEntry(e);
    try reg.applyClaim(id, pair.preimage);

    const path = "test-htlc-rt.bin";
    defer std.fs.cwd().deleteFile(path) catch {};
    try saveToFile(&reg, path);

    var reg2 = HtlcOnChainRegistry.init();
    try loadFromFile(&reg2, path);
    try testing.expectEqual(@as(u32, 1), reg2.entry_count);
    const e2 = reg2.get(id).?;
    try testing.expectEqual(HTLCState.claimed, e2.state);
    try testing.expect(e2.has_preimage);
    try testing.expectEqualSlices(u8, &pair.preimage, &e2.preimage);
    try testing.expectEqualSlices(u8, a, e2.senderSlice());
    try testing.expectEqualSlices(u8, b, e2.recipientSlice());
}

test "htlc_persist — missing file → empty registry, not an error" {
    var reg = HtlcOnChainRegistry.init();
    try loadFromFile(&reg, "this-file-does-not-exist-xxxxxxx.bin");
    try testing.expectEqual(@as(u32, 0), reg.entry_count);
}
