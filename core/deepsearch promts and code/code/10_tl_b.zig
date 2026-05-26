//! TL-B (Type Language - Binary) serialization for TON

const std = @import("std");
const allocator = std.mem.Allocator;
const cell = @import("cell.zig");

// ============================================================
// TL-B Type Definitions
// ============================================================

pub const TypeTag = enum(u8) {
    uint = 0x80,
    int = 0x81,
    varuint = 0x82,
    varint = 0x83,
    bits = 0x84,
    cell = 0x85,
    dict = 0x86,
    maybe = 0x87,
    anything = 0x88,
};

pub const Field = struct {
    name: []const u8,
    type: Type,
    optional: bool = false,
};

pub const Type = union(enum) {
    uint: u8,           // bit length
    int: u8,            // bit length
    varuint: u8,        // max bytes
    varint: u8,         // max bytes
    bits: u8,           // bit length
    cell: void,
    dict: *Type,        // key-value type
    maybe: *Type,       // optional type
    anything: void,
    struct: []Field,    // struct definition
    array: *Type,       // array of type
};

// ============================================================
// TL-B Serializer
// ============================================================

pub const TlBWriter = struct {
    allocator: Allocator,
    builder: cell.CellBuilder,
    
    pub fn init(allocator: Allocator) TlBWriter {
        return .{
            .allocator = allocator,
            .builder = cell.CellBuilder.init(allocator),
        };
    }
    
    pub fn deinit(self: *TlBWriter) void {
        self.builder.deinit();
    }
    
    /// Write a value based on TL-B type
    pub fn write(self: *TlBWriter, typ: Type, value: anytype) !void {
        const T = @TypeOf(value);
        
        switch (typ) {
            .uint => |bits| {
                try self.writeUint(value, bits);
            },
            .int => |bits| {
                try self.writeInt(value, bits);
            },
            .varuint => |max_bytes| {
                try self.writeVarUint(value, max_bytes);
            },
            .varint => |max_bytes| {
                try self.writeVarInt(value, max_bytes);
            },
            .bits => |bits| {
                try self.writeBits(value, bits);
            },
            .cell => {
                if (T == *cell.Cell) {
                    try self.builder.addRef(value);
                } else {
                    @compileError("Expected *cell.Cell for cell type");
                }
            },
            .maybe => |inner| {
                if (value) |v| {
                    try self.builder.writeBit(1);
                    try self.write(inner.*, v);
                } else {
                    try self.builder.writeBit(0);
                }
            },
            .struct => |fields| {
                inline for (fields) |field| {
                    const field_value = @field(value, field.name);
                    if (field.optional and field_value == null) {
                        // Skip optional field
                        continue;
                    }
                    try self.write(field.type, field_value);
                }
            },
            else => @compileError("Unsupported TL-B type"),
        }
    }
    
    fn writeUint(self: *TlBWriter, value: anytype, bits: u8) !void {
        const T = @TypeOf(value);
        if (@typeInfo(T) != .int) {
            @compileError("Expected integer for uint");
        }
        try self.builder.writeUint(@as(u64, @intCast(value)), bits);
    }
    
    fn writeInt(self: *TlBWriter, value: anytype, bits: u8) !void {
        const T = @TypeOf(value);
        if (@typeInfo(T) != .int) {
            @compileError("Expected integer for int");
        }
        try self.builder.writeInt(@as(i64, @intCast(value)), bits);
    }
    
    fn writeVarUint(self: *TlBWriter, value: anytype, max_bytes: u8) !void {
        const T = @TypeOf(value);
        if (@typeInfo(T) != .int) {
            @compileError("Expected integer for varuint");
        }
        _ = max_bytes;
        try self.builder.writeVarUint(@as(u64, @intCast(value)));
    }
    
    fn writeVarInt(self: *TlBWriter, value: anytype, max_bytes: u8) !void {
        const T = @TypeOf(value);
        if (@typeInfo(T) != .int) {
            @compileError("Expected integer for varint");
        }
        _ = max_bytes;
        if (value >= 0) {
            try self.builder.writeVarUint(@as(u64, @intCast(value)));
        } else {
            // Negative varint encoding
            @compileError("Negative varint not implemented");
        }
    }
    
    fn writeBits(self: *TlBWriter, value: anytype, bits: u8) !void {
        _ = self;
        _ = value;
        _ = bits;
        @compileError("Bits type not implemented");
    }
    
    /// Build final cell
    pub fn build(self: *TlBWriter) !*cell.Cell {
        return try self.builder.build();
    }
};

// ============================================================
// TL-B Parser
// ============================================================

pub const TlBReader = struct {
    allocator: Allocator,
    parser: cell.CellParser,
    
    pub fn init(allocator: Allocator, c: *cell.Cell) TlBReader {
        return .{
            .allocator = allocator,
            .parser = cell.CellParser.init(allocator, c),
        };
    }
    
    /// Read a value based on TL-B type
    pub fn read(self: *TlBReader, comptime T: type, typ: Type) !T {
        var result: T = undefined;
        
        switch (typ) {
            .uint => |bits| {
                const value = try self.parser.readUint(bits);
                return @as(T, @intCast(value));
            },
            .int => |bits| {
                const value = try self.parser.readUint(bits);
                // Sign extend
                const sign_mask = @as(u64, @intCast(1 << (bits - 1)));
                const extended = if ((value & sign_mask) != 0)
                    value | (@as(u64, @intCast(~((@as(u64, 1) << bits) - 1))))
                else
                    value;
                return @as(T, @intCast(@as(i64, @bitCast(extended))));
            },
            .varuint => |_| {
                // Read varuint
                const first = try self.parser.readByte();
                if (first < 0xFD) {
                    return @as(T, @intCast(first));
                } else if (first == 0xFD) {
                    const value = try self.parser.readUint(16);
                    return @as(T, @intCast(value));
                } else if (first == 0xFE) {
                    const value = try self.parser.readUint(32);
                    return @as(T, @intCast(value));
                } else {
                    const value = try self.parser.readUint(64);
                    return @as(T, @intCast(value));
                }
            },
            .cell => {
                // Read cell reference
                @compileError("Cell reference reading not implemented");
            },
            .maybe => |inner| {
                const has_value = try self.parser.readBit();
                if (has_value == 1) {
                    return try self.read(T, inner.*);
                } else {
                    return null;
                }
            },
            .struct => |fields| {
                inline for (fields) |field| {
                    const field_value = try self.read(@TypeOf(@field(result, field.name)), field.type);
                    @field(result, field.name) = field_value;
                }
                return result;
            },
            else => @compileError("Unsupported TL-B type"),
        }
    }
};

// ============================================================
// Common TL-B Types for TON
// ============================================================

/// TON Message structure
pub const Message = struct {
    info: MessageInfo,
    init: ?StateInit,
    body: *cell.Cell,
};

/// Message info header
pub const MessageInfo = struct {
    src: ?[32]u8,      // Source address
    dest: ?[32]u8,     // Destination address
    value: u64,         // Amount in nanoTON
    bounce: bool,       // Whether to bounce on error
    bounced: bool,      // Whether this is a bounced message
    ihr_disabled: bool,
    ihr_fee: u64,
    fwd_fee: u64,
    created_lt: u64,
    created_at: u32,
};

/// State Init (contract code and data)
pub const StateInit = struct {
    split_depth: ?u32,
    special: ?u32,
    code: *cell.Cell,
    data: *cell.Cell,
    library: ?*cell.Cell,
};

// ============================================================
// Tests
// ============================================================

test "TL-B uint serialization" {
    var writer = TlBWriter.init(std.testing.allocator);
    defer writer.deinit();
    
    try writer.write(.{ .uint = 8 }, @as(u8, 42));
    
    const c = try writer.build();
    defer c.deinit();
    
    var reader = TlBReader.init(std.testing.allocator, c);
    const value = try reader.read(u8, .{ .uint = 8 });
    
    try std.testing.expectEqual(value, 42);
}