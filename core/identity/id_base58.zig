//! id_base58.zig — Bitcoin-style Base58 encoder.
//!
//! Self-contained: chain already has `bech32.zig` for ob1q… addresses, but
//! DIDs are conventionally Base58 (Solana / IPFS / DID-Key). We need it
//! ONLY here, so we don't pollute `core/` with another generic codec.

const std = @import("std");

const ALPHABET = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";

/// Encode `data` to Base58. Caller owns the returned slice.
/// Algorithm: big-integer divide-by-58, preserving leading zero bytes
/// as leading '1' characters (Bitcoin convention).
pub fn encode(data: []const u8, allocator: std.mem.Allocator) ![]u8 {
    if (data.len == 0) return allocator.alloc(u8, 0);

    // Count leading zeros — each one becomes a leading '1'.
    var zeros: usize = 0;
    while (zeros < data.len and data[zeros] == 0) : (zeros += 1) {}

    // Worst-case size: ceil(log(256) / log(58)) ≈ 1.37 bytes out per byte in.
    // Add the zero prefix length.
    const max_out = data.len * 138 / 100 + 1;
    var buf = try allocator.alloc(u8, max_out);
    defer allocator.free(buf);
    @memset(buf, 0);

    var work = try allocator.dupe(u8, data);
    defer allocator.free(work);

    var out_len: usize = 0;
    var start: usize = zeros;
    while (start < work.len) {
        // Divide work[start..] by 58, in place. Quotient stays in work,
        // remainder becomes the next Base58 digit.
        var remainder: u32 = 0;
        var i: usize = start;
        while (i < work.len) : (i += 1) {
            const acc = (remainder << 8) | @as(u32, work[i]);
            work[i] = @intCast(acc / 58);
            remainder = acc % 58;
        }
        buf[out_len] = ALPHABET[@intCast(remainder)];
        out_len += 1;
        // Skip leading zero bytes that appeared after the division.
        while (start < work.len and work[start] == 0) : (start += 1) {}
    }

    // Result is reversed; allocate exact-size output with zero prefix.
    const final = try allocator.alloc(u8, zeros + out_len);
    for (0..zeros) |k| final[k] = '1';
    for (0..out_len) |k| final[zeros + k] = buf[out_len - 1 - k];
    return final;
}

test "Base58 known vector — all-zero input → all '1' output" {
    const out = try encode(&[_]u8{ 0, 0, 0, 0 }, std.testing.allocator);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("1111", out);
}

test "Base58 known vector — bytes {0,1,2,3} → '11Ldp'" {
    // Hand-verified: leading 0 = '1'. Then number 0x010203 = 66051 decimal.
    // 66051 = 19*58^2 + 37*58 + 49 → indices [19,37,49] → 'L','d','p'.
    // Encoded MSB-first: 'Ldp'. Final: "1Ldp".
    const out = try encode(&[_]u8{ 0, 1, 2, 3 }, std.testing.allocator);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("1Ldp", out);
}

test "Base58 round-trip distinct for distinct input" {
    const a = try encode(&[_]u8{ 0xde, 0xad, 0xbe, 0xef }, std.testing.allocator);
    defer std.testing.allocator.free(a);
    const b = try encode(&[_]u8{ 0xca, 0xfe, 0xba, 0xbe }, std.testing.allocator);
    defer std.testing.allocator.free(b);
    try std.testing.expect(!std.mem.eql(u8, a, b));
}
