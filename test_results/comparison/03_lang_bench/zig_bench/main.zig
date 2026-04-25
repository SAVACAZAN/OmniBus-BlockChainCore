const std = @import("std");
const Sha256 = std.crypto.hash.sha2.Sha256;
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
const print = std.debug.print;

const Transaction = struct {
    from: []const u8,
    to: []const u8,
    amount: u64,
    signature: []const u8,
};

const Block = struct {
    height: u64,
    timestamp: i64,
    prev_hash: []const u8,
    merkle: []const u8,
    nonce: u64,
    txs: [3]Transaction,
};

fn toHex(buf: []const u8, out: []u8) void {
    const hex = "0123456789abcdef";
    for (buf, 0..) |b, i| {
        out[i * 2] = hex[b >> 4];
        out[i * 2 + 1] = hex[b & 0x0f];
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // ---------------- BENCH 1: SHA-256 (1M iter) ----------------
    {
        var input: [64]u8 = undefined;
        for (&input, 0..) |*b, i| b.* = @intCast(i & 0xff);
        var out: [32]u8 = undefined;
        const N: u64 = 1_000_000;

        var t = try std.time.Timer.start();
        var i: u64 = 0;
        while (i < N) : (i += 1) {
            Sha256.hash(&input, &out, .{});
            input[0] ^= out[0];
        }
        const ns = t.read();
        const ms = ns / 1_000_000;
        const avg = ns / N;
        print("SHA256: {d} ms ({d} iterations, {d} ns avg)\n", .{ ms, N, avg });
    }

    // ---------------- BENCH 2: JSON serialize/deserialize (100K) ----------------
    {
        var prev_hex: [64]u8 = undefined;
        var merkle_hex: [64]u8 = undefined;
        var raw32: [32]u8 = undefined;
        for (&raw32, 0..) |*b, i| b.* = @intCast(i);
        toHex(&raw32, &prev_hex);
        toHex(&raw32, &merkle_hex);

        var sig_raw: [64]u8 = undefined;
        for (&sig_raw, 0..) |*b, i| b.* = @intCast(i);
        var sig_hex: [128]u8 = undefined;
        toHex(&sig_raw, &sig_hex);

        const block: Block = .{
            .height = 12345,
            .timestamp = 1735689600,
            .prev_hash = &prev_hex,
            .merkle = &merkle_hex,
            .nonce = 987654321,
            .txs = .{
                .{ .from = "alice", .to = "bob", .amount = 100, .signature = &sig_hex },
                .{ .from = "carol", .to = "dave", .amount = 200, .signature = &sig_hex },
                .{ .from = "eve", .to = "frank", .amount = 300, .signature = &sig_hex },
            },
        };

        const N: u64 = 100_000;
        var t = try std.time.Timer.start();
        var i: u64 = 0;
        var sum: u64 = 0;
        while (i < N) : (i += 1) {
            // Serialize using std.Io.Writer.Allocating (0.15.x API)
            var alloc_writer = std.Io.Writer.Allocating.init(allocator);
            defer alloc_writer.deinit();
            try std.json.Stringify.value(block, .{}, &alloc_writer.writer);
            const bytes = alloc_writer.written();

            // Deserialize
            const parsed = try std.json.parseFromSlice(Block, allocator, bytes, .{});
            defer parsed.deinit();
            sum +%= parsed.value.height;
        }
        const ns = t.read();
        const ms = ns / 1_000_000;
        const avg = ns / N;
        print("JSON: {d} ms ({d} iterations, {d} ns avg) [sum={d}]\n", .{ ms, N, avg, sum });
    }

    // ---------------- BENCH 3: HMAC-SHA256 (100K) ----------------
    {
        var key: [32]u8 = undefined;
        for (&key, 0..) |*b, i| b.* = @intCast(i);
        var msg: [256]u8 = undefined;
        for (&msg, 0..) |*b, i| b.* = @intCast(i & 0xff);
        var out: [HmacSha256.mac_length]u8 = undefined;
        const N: u64 = 100_000;

        var t = try std.time.Timer.start();
        var i: u64 = 0;
        while (i < N) : (i += 1) {
            HmacSha256.create(&out, &msg, &key);
            msg[0] ^= out[0];
        }
        const ns = t.read();
        const ms = ns / 1_000_000;
        const avg = ns / N;
        print("HMAC: {d} ms ({d} iterations, {d} ns avg)\n", .{ ms, N, avg });
    }

    // ---------------- BENCH 4: Memory allocation (1M x 64-byte) ----------------
    {
        const N: u64 = 1_000_000;
        var ptrs = try allocator.alloc([]u8, N);
        defer allocator.free(ptrs);

        var t = try std.time.Timer.start();
        var i: u64 = 0;
        while (i < N) : (i += 1) {
            const buf = try allocator.alloc(u8, 64);
            buf[0] = @intCast(i & 0xff);
            ptrs[i] = buf;
        }
        i = 0;
        while (i < N) : (i += 1) {
            allocator.free(ptrs[i]);
        }
        const ns = t.read();
        const ms = ns / 1_000_000;
        const avg = ns / N;
        print("MEMALLOC: {d} ms ({d} iterations, {d} ns avg)\n", .{ ms, N, avg });
    }
}
