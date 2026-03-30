const std = @import("std");
const sub_block_mod = @import("sub_block.zig");
const transaction_mod = @import("transaction.zig");

pub const SubBlock = sub_block_mod.SubBlock;
pub const Transaction = transaction_mod.Transaction;

/// Varint encoding - variable-length integers
/// Saves space: 255 needs 1 byte, not 4
pub const Varint = struct {
    /// Encode u64 as varint
    pub fn encodeU64(value: u64) ![9]u8 {
        var result: [9]u8 = undefined;
        var bytes_written: u8 = 0;
        var v = value;

        while (v >= 128) {
            result[bytes_written] = @intCast((v & 0x7F) | 0x80);
            bytes_written += 1;
            v >>= 7;
        }

        result[bytes_written] = @intCast(v & 0x7F);
        bytes_written += 1;

        return result;
    }

    /// Decode varint back to u64
    pub fn decodeU64(data: []const u8) ![2]usize {
        var result: u64 = 0;
        var shift: u6 = 0;
        var bytes_read: usize = 0;

        for (data) |byte| {
            result |= (@as(u64, byte & 0x7F)) << shift;
            bytes_read += 1;

            if (byte < 128) break;
            shift += 7;
        }

        return .{ result, bytes_read };
    }

    /// Encode u32 as varint
    pub fn encodeU32(value: u32) ![5]u8 {
        var result: [5]u8 = undefined;
        var bytes_written: u8 = 0;
        var v = value;

        while (v >= 128) {
            result[bytes_written] = @intCast((v & 0x7F) | 0x80);
            bytes_written += 1;
            v >>= 7;
        }

        result[bytes_written] = @intCast(v & 0x7F);
        bytes_written += 1;

        return result;
    }

    /// Decode varint to u32
    pub fn decodeU32(data: []const u8) ![2]usize {
        const result_pair = try decodeU64(data);
        return .{ @intCast(result_pair[0]), result_pair[1] };
    }
};

/// Binary encoder for sub-blocks
pub const BinaryEncoder = struct {
    buffer: std.array_list.Managed(u8),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) BinaryEncoder {
        return BinaryEncoder{
            .buffer = std.array_list.Managed(u8).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn encodeSubBlock(self: *BinaryEncoder, sub: *const SubBlock) !void {
        // Sub-block header
        try self.buffer.append(sub.sub_id);
        try self.encodeVarU32(sub.block_number);
        try self.encodeVarU64(@bitCast(sub.timestamp));
        try self.buffer.append(sub.shard_id);
        try self.encodeVarU64(sub.nonce);

        // Merkle root (32 bytes)
        try self.buffer.appendSlice(&sub.merkle_root);

        // Hash (32 bytes)
        try self.buffer.appendSlice(&sub.hash);

        // Transaction count
        try self.encodeVarU32(@intCast(sub.transactions.items.len));

        // Transactions
        for (sub.transactions.items) |tx| {
            try self.encodeTransaction(&tx);
        }
    }

    pub fn encodeTransaction(self: *BinaryEncoder, tx: *const Transaction) !void {
        // Compact transaction encoding
        try self.encodeVarU32(@intCast(tx.id));
        try self.buffer.appendSlice(tx.from_address);
        try self.buffer.appendSlice(tx.to_address);
        try self.encodeVarU64(tx.amount);
        try self.encodeVarU64(@bitCast(tx.timestamp));

        // Signature (256 bytes max, usually smaller)
        try self.encodeVarU32(@intCast(tx.signature.len));
        try self.buffer.appendSlice(tx.signature);

        // Hash
        try self.buffer.appendSlice(tx.hash);
    }

    pub fn encodeVarU32(self: *BinaryEncoder, value: u32) !void {
        const encoded = try Varint.encodeU32(value);
        const len = try self.getVarIntLength(encoded);
        try self.buffer.appendSlice(encoded[0..len]);
    }

    pub fn encodeVarU64(self: *BinaryEncoder, value: u64) !void {
        const encoded = try Varint.encodeU64(value);
        const len = try self.getVarIntLength(encoded);
        try self.buffer.appendSlice(encoded[0..len]);
    }

    fn getVarIntLength(self: *BinaryEncoder, encoded: anytype) !usize {
        _ = self;
        for (0..encoded.len) |i| {
            if (encoded[i] < 128) return i + 1;
        }
        return encoded.len;
    }

    pub fn getBytes(self: *const BinaryEncoder) []const u8 {
        return self.buffer.items;
    }

    pub fn getSize(self: *const BinaryEncoder) usize {
        return self.buffer.items.len;
    }

    pub fn deinit(self: *BinaryEncoder) void {
        self.buffer.deinit();
    }
};

/// Binary decoder for sub-blocks
pub const BinaryDecoder = struct {
    data: []const u8,
    offset: usize = 0,

    pub fn init(data: []const u8) BinaryDecoder {
        return BinaryDecoder{
            .data = data,
            .offset = 0,
        };
    }

    pub fn readU8(self: *BinaryDecoder) !u8 {
        if (self.offset >= self.data.len) return error.EndOfData;
        const value = self.data[self.offset];
        self.offset += 1;
        return value;
    }

    pub fn readBytes(self: *BinaryDecoder, comptime len: usize) ![len]u8 {
        if (self.offset + len > self.data.len) return error.EndOfData;
        var result: [len]u8 = undefined;
        std.mem.copyForwards(u8, &result, self.data[self.offset .. self.offset + len]);
        self.offset += len;
        return result;
    }

    pub fn readVarU32(self: *BinaryDecoder) !u32 {
        const result_pair = try Varint.decodeU32(self.data[self.offset..]);
        self.offset += result_pair[1];
        return @intCast(result_pair[0]);
    }

    pub fn readVarU64(self: *BinaryDecoder) !u64 {
        const result_pair = try Varint.decodeU64(self.data[self.offset..]);
        self.offset += result_pair[1];
        return result_pair[0];
    }

    pub fn isEndOfData(self: *const BinaryDecoder) bool {
        return self.offset >= self.data.len;
    }
};

// Tests
const testing = std.testing;

test "varint encoding u32" {
    // Small number (1 byte)
    var encoded = try Varint.encodeU32(127);
    try testing.expectEqual(encoded[0], 127);

    // Larger number (2 bytes)
    encoded = try Varint.encodeU32(128);
    try testing.expectEqual(encoded[0], 0x80);
    try testing.expectEqual(encoded[1], 0x01);
}

test "varint encoding u64" {
    const encoded = try Varint.encodeU64(1234567890);
    try testing.expect(encoded[0] >= 128);  // Multi-byte
}

test "varint roundtrip" {
    const original: u32 = 50000;
    var encoded = try Varint.encodeU32(original);
    const decoded_pair = try Varint.decodeU32(&encoded);
    const decoded = @as(u32, @intCast(decoded_pair[0]));

    try testing.expectEqual(original, decoded);
}

test "binary encoder/decoder" {
    var encoder = BinaryEncoder.init(testing.allocator);
    defer encoder.deinit();

    try encoder.encodeVarU32(100);
    try encoder.encodeVarU64(200);

    const encoded_bytes = encoder.getBytes();

    var decoder = BinaryDecoder.init(encoded_bytes);
    const value1 = try decoder.readVarU32();
    const value2 = try decoder.readVarU64();

    try testing.expectEqual(value1, 100);
    try testing.expectEqual(value2, 200);
}

test "compression ratio" {
    var encoder = BinaryEncoder.init(testing.allocator);
    defer encoder.deinit();

    // Encode 1000 numbers
    for (0..1000) |i| {
        try encoder.encodeVarU32(@intCast(i % 65536));
    }

    const size = encoder.getSize();
    // Each number ~2 bytes with varint, so ~2000 bytes
    // vs 4000 bytes with direct u32
    try testing.expect(size < 3000);  // Should be compressed
}
