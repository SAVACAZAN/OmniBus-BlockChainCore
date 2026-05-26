//! Tests for TON Cell serialization

const std = @import("std");
const testing = std.testing;
const cell = @import("../../../wallet/ton/cell.zig");

test "TON: Cell builder basics" {
    var builder = cell.CellBuilder.init(testing.allocator);
    defer builder.deinit();
    
    try builder.writeUint(42, 8);
    try builder.writeBit(1);
    try builder.writeBits(&[_]u1{1, 0, 1});
    
    const c = try builder.build();
    defer c.deinit();
    
    try testing.expect(c.data.len > 0);
}

test "TON: Cell parser" {
    var builder = cell.CellBuilder.init(testing.allocator);
    defer builder.deinit();
    
    try builder.writeUint(12345, 16);
    try builder.writeByte(0xFF);
    
    const c = try builder.build();
    defer c.deinit();
    
    var parser = cell.CellParser.init(testing.allocator, c);
    
    const value = try parser.readUint(16);
    try testing.expectEqual(value, 12345);
    
    const byte = try parser.readByte();
    try testing.expectEqual(byte, 0xFF);
}

test "TON: Cell hash computation" {
    var builder = cell.CellBuilder.init(testing.allocator);
    defer builder.deinit();
    
    try builder.writeBytes("Hello TON");
    const c = try builder.build();
    defer c.deinit();
    
    const hash = try c.computeHash();
    try testing.expect(hash.len == 32);
}

test "TON: Cell with references" {
    var builder1 = cell.CellBuilder.init(testing.allocator);
    defer builder1.deinit();
    try builder1.writeUint(42, 8);
    const child = try builder1.build();
    defer child.deinit();
    
    var builder2 = cell.CellBuilder.init(testing.allocator);
    defer builder2.deinit();
    try builder2.writeUint(100, 16);
    try builder2.addRef(child);
    
    const parent = try builder2.build();
    defer parent.deinit();
    
    try testing.expect(parent.refs.len == 1);
    try testing.expect(parent.refs[0].data[0] == 42);
}

test "TON: Cell max capacity" {
    var builder = cell.CellBuilder.init(testing.allocator);
    defer builder.deinit();
    
    // Try to write 128 bytes (max)
    const max_bytes = [_]u8{0xFF} ** 128;
    try builder.writeBytes(&max_bytes);
    
    try testing.expect(builder.isValid());
}

test "TON: Cell too large" {
    var builder = cell.CellBuilder.init(testing.allocator);
    defer builder.deinit();
    
    // Try to write 129 bytes (over limit)
    const too_many = [_]u8{0xFF} ** 129;
    try builder.writeBytes(&too_many);
    
    try testing.expect(!builder.isValid());
}

test "TON: Cell serialization" {
    var builder = cell.CellBuilder.init(testing.allocator);
    defer builder.deinit();
    
    try builder.writeUint(0x12345678, 32);
    const c = try builder.build();
    defer c.deinit();
    
    const serialized = try c.serialize(testing.allocator);
    defer testing.allocator.free(serialized);
    
    try testing.expect(serialized.len >= 4);
}