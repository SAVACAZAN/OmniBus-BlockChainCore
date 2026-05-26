//! Borsh serialization for Solana transactions
//! Binary Object Representation Serializer for Hashing

const std = @import("std");
const allocator = std.mem.Allocator;

// ============================================================
// Borsh Serialization Traits
// ============================================================

pub const BorshSerialize = struct {
    pub fn serialize(value: anytype, writer: anytype) !void {
        const T = @TypeOf(value);
        
        switch (@typeInfo(T)) {
            .int => {
                const int_info = @typeInfo(T).int;
                const bytes = @divExact(int_info.bits, 8);
                const little_endian = std.mem.nativeEndian == .little;
                
                var buf: [8]u8 = undefined;
                std.mem.writeInt(
                    @TypeOf(value),
                    &buf,
                    value,
                    if (little_endian) .little else .big,
                );
                try writer.writeAll(buf[0..bytes]);
            },
            .bool => {
                try writer.writeByte(@as(u8, if (value) 1 else 0));
            },
            .optional => {
                if (value) |v| {
                    try writer.writeByte(1);
                    try serialize(v, writer);
                } else {
                    try writer.writeByte(0);
                }
            },
            .array => {
                for (value) |item| {
                    try serialize(item, writer);
                }
            },
            .pointer => |ptr| {
                if (ptr.size == .slice) {
                    const len = @as(u32, @intCast(value.len));
                    try serialize(len, writer);
                    for (value) |item| {
                        try serialize(item, writer);
                    }
                } else {
                    try serialize(value.*, writer);
                }
            },
            .@"struct" => {
                inline for (@typeInfo(T).struct.fields) |field| {
                    try serialize(@field(value, field.name), writer);
                }
            },
            else => @compileError("Unsupported type for BorshSerialize: " ++ @typeName(T)),
        }
    }
};

pub const BorshDeserialize = struct {
    pub fn deserialize(comptime T: type, reader: anytype) !T {
        switch (@typeInfo(T)) {
            .int => {
                const int_info = @typeInfo(T).int;
                const bytes = @divExact(int_info.bits, 8);
                var buf: [8]u8 = undefined;
                try reader.readNoEof(buf[0..bytes]);
                const little_endian = std.mem.nativeEndian == .little;
                return std.mem.readInt(
                    T,
                    buf[0..bytes],
                    if (little_endian) .little else .big,
                );
            },
            .bool => {
                const byte = try reader.readByte();
                return byte != 0;
            },
            .optional => {
                const has_value = try reader.readByte();
                if (has_value != 0) {
                    return try deserialize(@typeInfo(T).optional.child, reader);
                }
                return null;
            },
            .array => {
                const array_info = @typeInfo(T).array;
                var result: T = undefined;
                for (&result, 0..) |*item, i| {
                    item.* = try deserialize(array_info.child, reader);
                }
                return result;
            },
            .pointer => |ptr| {
                if (ptr.size == .slice) {
                    const len = try deserialize(u32, reader);
                    var slice = try allocator.alloc(ptr.child, len);
                    errdefer allocator.free(slice);
                    for (0..len) |i| {
                        slice[i] = try deserialize(ptr.child, reader);
                    }
                    return slice;
                } else {
                    return @as(T, try deserialize(ptr.child, reader));
                }
            },
            .@"struct" => {
                var result: T = undefined;
                inline for (@typeInfo(T).struct.fields) |field| {
                    @field(result, field.name) = try deserialize(field.type, reader);
                }
                return result;
            },
            else => @compileError("Unsupported type for BorshDeserialize: " ++ @typeName(T)),
        }
    }
};

// ============================================================
// Solana-Specific Borsh Types
// ============================================================

/// Solana public key (32 bytes) as Borsh
pub const BorshPubkey = [32]u8;

/// Solana signature (64 bytes) as Borsh
pub const BorshSignature = [64]u8;

/// Optional public key (0 or 32 bytes)
pub const BorshOptionalPubkey = ?[32]u8;

// ============================================================
// Borsh Helpers
// ============================================================

pub const BorshWriter = struct {
    buffer: std.ArrayList(u8),
    
    pub fn init(allocator: Allocator) BorshWriter {
        return .{
            .buffer = std.ArrayList(u8).init(allocator),
        };
    }
    
    pub fn deinit(self: *BorshWriter) void {
        self.buffer.deinit();
    }
    
    pub fn writeByte(self: *BorshWriter, byte: u8) !void {
        try self.buffer.append(byte);
    }
    
    pub fn writeAll(self: *BorshWriter, bytes: []const u8) !void {
        try self.buffer.appendSlice(bytes);
    }
    
    pub fn toBytes(self: *BorshWriter) ![]u8 {
        return try self.buffer.toOwnedSlice();
    }
    
    pub fn reset(self: *BorshWriter) void {
        self.buffer.clearRetainingCapacity();
    }
};

pub const BorshReader = struct {
    data: []const u8,
    position: usize,
    
    pub fn init(data: []const u8) BorshReader {
        return .{
            .data = data,
            .position = 0,
        };
    }
    
    pub fn readByte(self: *BorshReader) !u8 {
        if (self.position >= self.data.len) return error.EndOfStream;
        const byte = self.data[self.position];
        self.position += 1;
        return byte;
    }
    
    pub fn readNoEof(self: *BorshReader, buffer: []u8) !void {
        if (self.position + buffer.len > self.data.len) return error.EndOfStream;
        @memcpy(buffer, self.data[self.position..self.position + buffer.len]);
        self.position += buffer.len;
    }
};

// ============================================================
// Tests
// ============================================================

test "Borsh serialize/deserialize u64" {
    var writer = BorshWriter.init(std.testing.allocator);
    defer writer.deinit();
    
    const value: u64 = 123456789;
    try BorshSerialize.serialize(value, writer);
    
    const bytes = try writer.toBytes();
    defer std.testing.allocator.free(bytes);
    
    var reader = BorshReader.init(bytes);
    const deserialized = try BorshDeserialize.deserialize(u64, &reader);
    
    try std.testing.expectEqual(value, deserialized);
}

test "Borsh serialize/deserialize struct" {
    const TestStruct = struct {
        a: u32,
        b: bool,
        c: [3]u8,
    };
    
    var writer = BorshWriter.init(std.testing.allocator);
    defer writer.deinit();
    
    const value = TestStruct{
        .a = 42,
        .b = true,
        .c = .{1, 2, 3},
    };
    
    try BorshSerialize.serialize(value, writer);
    
    const bytes = try writer.toBytes();
    defer std.testing.allocator.free(bytes);
    
    var reader = BorshReader.init(bytes);
    const deserialized = try BorshDeserialize.deserialize(TestStruct, &reader);
    
    try std.testing.expectEqual(value.a, deserialized.a);
    try std.testing.expectEqual(value.b, deserialized.b);
    try std.testing.expectEqualSlices(u8, &value.c, &deserialized.c);
}