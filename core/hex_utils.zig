const std = @import("std");

/// Shared hex/hash utilities used by transaction.zig, blockchain.zig, blockchain_v2.zig
/// Extracted to eliminate code duplication (was duplicated in 3 files)

/// Convert hex character to 4-bit nibble value
pub fn charToNibble(c: u8) !u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => error.InvalidChar,
    };
}

/// Convert hex string to bytes
pub fn hexToBytes(hex: []const u8, out: []u8) !void {
    if (hex.len != out.len * 2) return error.InvalidLength;
    for (0..out.len) |i| {
        const hi = charToNibble(hex[i * 2]) catch return error.InvalidHex;
        const lo = charToNibble(hex[i * 2 + 1]) catch return error.InvalidHex;
        out[i] = (hi << 4) | lo;
    }
}

/// Calculate block hash as 64-char hex string (allocated on heap)
/// Used by blockchain.zig and blockchain_v2.zig
pub fn calculateBlockHashHex(
    index: u32,
    timestamp: i64,
    prev_hash_len: usize,
    nonce: u64,
    tx_hashes: []const []const u8,
    allocator: std.mem.Allocator,
) ![]const u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});

    var buffer: [256]u8 = undefined;
    const str = try std.fmt.bufPrint(&buffer, "{d}{d}{d}{d}", .{
        index, timestamp, prev_hash_len, nonce,
    });
    hasher.update(str);

    for (tx_hashes) |th| {
        hasher.update(th);
    }

    var hash: [32]u8 = undefined;
    hasher.final(&hash);

    // Hex string (64 chars = 32 bytes) — heap allocated
    const result = try allocator.alloc(u8, 64);
    for (0..32) |i| {
        _ = try std.fmt.bufPrint(result[i * 2 .. (i + 1) * 2], "{x:0>2}", .{hash[i]});
    }
    return result;
}

/// Calculate block hash from a block struct (convenience wrapper)
/// Eliminates duplicate code between blockchain.zig and blockchain_v2.zig
pub fn hashBlock(block: anytype, allocator: std.mem.Allocator) ![]const u8 {
    var tx_hashes_buf: [10000][]const u8 = undefined;
    const tx_count = @min(block.transactions.items.len, 10000);
    for (0..tx_count) |i| {
        tx_hashes_buf[i] = block.transactions.items[i].hash;
    }
    return calculateBlockHashHex(
        block.index, block.timestamp, block.previous_hash.len,
        block.nonce, tx_hashes_buf[0..tx_count], allocator,
    );
}

/// Maximum nonce for PoW mining (2^32, shared constant)
pub const MAX_NONCE: u64 = 4_294_967_296;

/// Check if a hex hash meets difficulty (leading zeros count)
pub fn isValidHashDifficulty(hash: []const u8, difficulty: u32) bool {
    var zero_count: u32 = 0;
    for (hash) |char| {
        if (char == '0') {
            zero_count += 1;
        } else {
            break;
        }
    }
    return zero_count >= difficulty;
}

// ─── Tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

test "charToNibble — digits" {
    try testing.expectEqual(@as(u8, 0), try charToNibble('0'));
    try testing.expectEqual(@as(u8, 9), try charToNibble('9'));
}

test "charToNibble — lowercase hex" {
    try testing.expectEqual(@as(u8, 10), try charToNibble('a'));
    try testing.expectEqual(@as(u8, 15), try charToNibble('f'));
}

test "charToNibble — uppercase hex" {
    try testing.expectEqual(@as(u8, 10), try charToNibble('A'));
    try testing.expectEqual(@as(u8, 15), try charToNibble('F'));
}

test "charToNibble — invalid char" {
    try testing.expectError(error.InvalidChar, charToNibble('g'));
    try testing.expectError(error.InvalidChar, charToNibble('Z'));
    try testing.expectError(error.InvalidChar, charToNibble(' '));
}

test "hexToBytes — valid" {
    var out: [3]u8 = undefined;
    try hexToBytes("abcdef", &out);
    try testing.expectEqual(@as(u8, 0xab), out[0]);
    try testing.expectEqual(@as(u8, 0xcd), out[1]);
    try testing.expectEqual(@as(u8, 0xef), out[2]);
}

test "hexToBytes — wrong length" {
    var out: [2]u8 = undefined;
    try testing.expectError(error.InvalidLength, hexToBytes("abc", &out));
}

test "isValidHashDifficulty — 4 zeros" {
    try testing.expect(isValidHashDifficulty("0000abcdef", 4));
    try testing.expect(!isValidHashDifficulty("000abcdef1", 4));
}

test "isValidHashDifficulty — zero difficulty" {
    try testing.expect(isValidHashDifficulty("anything", 0));
}

test "calculateBlockHashHex — produces 64 chars" {
    const hashes = [_][]const u8{"deadbeef"};
    const result = try calculateBlockHashHex(0, 1000, 32, 42, &hashes, testing.allocator);
    defer testing.allocator.free(result);
    try testing.expectEqual(@as(usize, 64), result.len);
}

test "calculateBlockHashHex — deterministic" {
    const hashes = [_][]const u8{"aabb"};
    const h1 = try calculateBlockHashHex(1, 2000, 64, 99, &hashes, testing.allocator);
    defer testing.allocator.free(h1);
    const h2 = try calculateBlockHashHex(1, 2000, 64, 99, &hashes, testing.allocator);
    defer testing.allocator.free(h2);
    try testing.expectEqualSlices(u8, h1, h2);
}
