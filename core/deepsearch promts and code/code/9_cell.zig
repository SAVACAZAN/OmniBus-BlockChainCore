//! TON Cell serialization (TL-B basic types)
//! Cells are the fundamental building blocks of TON blockchain

const std = @import("std");
const allocator = std.mem.Allocator;

// ============================================================
// Cell Types
// ============================================================

pub const Cell = struct {
    allocator: Allocator,
    data: []u8,           // Max 128 bytes (1023 bits)
    refs: []*Cell,        // Max 4 references
    hash: [32]u8,         // Cell hash (for caching)
    hash_dirty: bool,
    
    pub fn init(allocator: Allocator) Cell {
        return .{
            .allocator = allocator,
            .data = &[_]u8{},
            .refs = &[_]*Cell{},
            .hash = [_]u8{0} ** 32,
            .hash_dirty = true,
        };
    }
    
    pub fn deinit(self: *Cell) void {
        if (self.data.len > 0) {
            self.allocator.free(self.data);
        }
        for (self.refs) |ref| {
            ref.deinit();
            self.allocator.destroy(ref);
        }
        if (self.refs.len > 0) {
            self.allocator.free(self.refs);
        }
    }
    
    /// Create a new cell with data
    pub fn create(allocator: Allocator, data: []const u8) !*Cell {
        const cell = try allocator.create(Cell);
        errdefer allocator.destroy(cell);
        
        cell.* = Cell.init(allocator);
        cell.data = try allocator.dupe(u8, data);
        cell.hash_dirty = true;
        
        return cell;
    }
    
    /// Create a cell with data and references
    pub fn createWithRefs(allocator: Allocator, data: []const u8, refs: []*Cell) !*Cell {
        const cell = try allocator.create(Cell);
        errdefer allocator.destroy(cell);
        
        cell.* = Cell.init(allocator);
        cell.data = try allocator.dupe(u8, data);
        cell.refs = try allocator.dupe(*Cell, refs);
        cell.hash_dirty = true;
        
        return cell;
    }
    
    /// Add reference to cell
    pub fn addRef(self: *Cell, ref: *Cell) !void {
        var new_refs = try self.allocator.alloc(*Cell, self.refs.len + 1);
        for (self.refs, 0..) |r, i| {
            new_refs[i] = r;
        }
        new_refs[self.refs.len] = ref;
        self.allocator.free(self.refs);
        self.refs = new_refs;
        self.hash_dirty = true;
    }
    
    /// Compute cell hash (represents cell contents)
    pub fn computeHash(self: *Cell) ![32]u8 {
        if (!self.hash_dirty) return self.hash;
        
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        
        // Data descriptor (2 bytes)
        const bits = self.data.len * 8;
        const refs_count = self.refs.len;
        var descriptor: u16 = @as(u16, @intCast(refs_count));
        descriptor |= (@as(u16, @intCast(bits)) << 1);
        if (bits > 0) {
            const last_byte_bits = bits % 8;
            if (last_byte_bits != 0) {
                descriptor |= 0x100; // Set "has padding" flag
            }
        }
        hasher.update(&std.mem.toBytes(descriptor));
        
        // Data bytes
        hasher.update(self.data);
        
        // Padding bits (if any)
        const padding_bits = (8 - (bits % 8)) % 8;
        if (padding_bits > 0) {
            hasher.update(&[_]u8{0});
        }
        
        // References hashes
        for (self.refs) |ref| {
            const ref_hash = try ref.computeHash();
            hasher.update(&ref_hash);
        }
        
        var result: [32]u8 = undefined;
        hasher.final(&result);
        
        self.hash = result;
        self.hash_dirty = false;
        return result;
    }
    
    /// Serialize cell to binary format
    pub fn serialize(self: *Cell, alloc: Allocator) ![]u8 {
        const hash = try self.computeHash();
        const data_len = 2 + self.data.len; // descriptor + data
        const refs_len = self.refs.len * 32; // each ref hash is 32 bytes
        
        var result = try alloc.alloc(u8, data_len + refs_len);
        errdefer alloc.free(result);
        
        // Descriptor (2 bytes)
        const bits = self.data.len * 8;
        const refs_count = self.refs.len;
        var descriptor: u16 = @as(u16, @intCast(refs_count));
        descriptor |= (@as(u16, @intCast(bits)) << 1);
        const last_byte_bits = bits % 8;
        if (last_byte_bits != 0) {
            descriptor |= 0x100;
        }
        std.mem.writeInt(u16, result[0..2], descriptor, .big);
        
        // Data
        @memcpy(result[2..2 + self.data.len], self.data);
        
        // Padding
        const padding_bits = (8 - (bits % 8)) % 8;
        if (padding_bits > 0) {
            result[2 + self.data.len - 1] |= (@as(u8, @intCast((1 << padding_bits) - 1)) << (8 - padding_bits));
        }
        
        // References hashes
        var offset = 2 + self.data.len;
        for (self.refs) |ref| {
            const ref_hash = try ref.computeHash();
            @memcpy(result[offset..offset + 32], &ref_hash);
            offset += 32;
        }
        
        return result;
    }
    
    /// Convert cell to string representation (for debugging)
    pub fn toString(self: *Cell, depth: usize) ![]u8 {
        var result = std.ArrayList(u8).init(self.allocator);
        defer result.deinit();
        
        const indent = "  ";
        for (0..depth) |_| {
            try result.appendSlice(indent);
        }
        
        try result.appendSlice("Cell{ bits: ");
        try result.appendSlice(std.fmt.allocPrint(self.allocator, "{}", .{self.data.len * 8}) catch unreachable);
        try result.appendSlice(", refs: ");
        try result.appendSlice(std.fmt.allocPrint(self.allocator, "{}", .{self.refs.len}) catch unreachable);
        try result.appendSlice(" }");
        
        if (self.refs.len > 0) {
            try result.appendSlice("\n");
            for (self.refs) |ref| {
                const ref_str = try ref.toString(depth + 1);
                defer self.allocator.free(ref_str);
                try result.appendSlice(ref_str);
                try result.appendSlice("\n");
            }
        }
        
        return result.toOwnedSlice();
    }
};

// ============================================================
// Cell Builder (for constructing cells)
// ============================================================

pub const CellBuilder = struct {
    allocator: Allocator,
    data: std.ArrayList(u8),
    refs: std.ArrayList(*Cell),
    bits: u32,
    
    pub fn init(allocator: Allocator) CellBuilder {
        return .{
            .allocator = allocator,
            .data = std.ArrayList(u8).init(allocator),
            .refs = std.ArrayList(*Cell).init(allocator),
            .bits = 0,
        };
    }
    
    pub fn deinit(self: *CellBuilder) void {
        self.data.deinit();
        for (self.refs.items) |ref| {
            ref.deinit();
            self.allocator.destroy(ref);
        }
        self.refs.deinit();
    }
    
    /// Write a single bit
    pub fn writeBit(self: *CellBuilder, bit: u1) !void {
        if (self.bits % 8 == 0) {
            try self.data.append(0);
        }
        const byte_idx = self.data.items.len - 1;
        if (bit == 1) {
            self.data.items[byte_idx] |= @as(u8, @intCast(1 << (7 - (self.bits % 8))));
        }
        self.bits += 1;
    }
    
    /// Write multiple bits
    pub fn writeBits(self: *CellBuilder, bits: []const u1) !void {
        for (bits) |bit| {
            try self.writeBit(bit);
        }
    }
    
    /// Write a byte
    pub fn writeByte(self: *CellBuilder, byte: u8) !void {
        for (0..8) |i| {
            const bit = @as(u1, @intCast((byte >> (7 - i)) & 1));
            try self.writeBit(bit);
        }
    }
    
    /// Write multiple bytes
    pub fn writeBytes(self: *CellBuilder, bytes: []const u8) !void {
        for (bytes) |byte| {
            try self.writeByte(byte);
        }
    }
    
    /// Write unsigned integer (big-endian)
    pub fn writeUint(self: *CellBuilder, value: u64, bits: u8) !void {
        if (bits > 64) return error.BitsTooLarge;
        for (0..bits) |i| {
            const shift = @as(u6, @intCast(bits - 1 - i));
            const bit = @as(u1, @intCast((value >> shift) & 1));
            try self.writeBit(bit);
        }
    }
    
    /// Write signed integer (big-endian, two's complement)
    pub fn writeInt(self: *CellBuilder, value: i64, bits: u8) !void {
        if (value >= 0) {
            try self.writeUint(@as(u64, @intCast(value)), bits);
        } else {
            const unsigned = @as(u64, @bitCast(value));
            try self.writeUint(unsigned, bits);
        }
    }
    
    /// Write variable length integer
    pub fn writeVarUint(self: *CellBuilder, value: u64) !void {
        if (value < 0xFD) {
            try self.writeByte(@as(u8, @intCast(value)));
        } else if (value <= 0xFFFF) {
            try self.writeByte(0xFD);
            try self.writeUint(value, 16);
        } else if (value <= 0xFFFFFFFF) {
            try self.writeByte(0xFE);
            try self.writeUint(value, 32);
        } else {
            try self.writeByte(0xFF);
            try self.writeUint(value, 64);
        }
    }
    
    /// Add reference to another cell
    pub fn addRef(self: *CellBuilder, ref: *Cell) !void {
        if (self.refs.items.len >= 4) return error.TooManyRefs;
        try self.refs.append(ref);
    }
    
    /// Build the final cell
    pub fn build(self: *CellBuilder) !*Cell {
        const cell = try Cell.create(self.allocator, self.data.items);
        for (self.refs.items) |ref| {
            try cell.addRef(ref);
        }
        return cell;
    }
    
    /// Check if cell would be valid (max 128 bytes, max 4 refs)
    pub fn isValid(self: *CellBuilder) bool {
        if (self.data.items.len > 128) return false;
        if (self.refs.items.len > 4) return false;
        return true;
    }
};

// ============================================================
// Cell Parser (for reading cells)
// ============================================================

pub const CellParser = struct {
    allocator: Allocator,
    cell: *Cell,
    position: u32,
    
    pub fn init(allocator: Allocator, cell: *Cell) CellParser {
        return .{
            .allocator = allocator,
            .cell = cell,
            .position = 0,
        };
    }
    
    /// Read a single bit
    pub fn readBit(self: *CellParser) !u1 {
        if (self.position >= self.cell.data.len * 8) return error.EndOfStream;
        const byte_idx = @as(usize, @intCast(self.position / 8));
        const bit_idx = self.position % 8;
        const bit = (self.cell.data[byte_idx] >> (7 - bit_idx)) & 1;
        self.position += 1;
        return @as(u1, @intCast(bit));
    }
    
    /// Read multiple bits
    pub fn readBits(self: *CellParser, count: u32) ![]u1 {
        var bits = try self.allocator.alloc(u1, count);
        errdefer self.allocator.free(bits);
        
        for (0..count) |i| {
            bits[i] = try self.readBit();
        }
        
        return bits;
    }
    
    /// Read a byte
    pub fn readByte(self: *CellParser) !u8 {
        var byte: u8 = 0;
        for (0..8) |i| {
            const bit = try self.readBit();
            byte |= @as(u8, @intCast(bit << (7 - i)));
        }
        return byte;
    }
    
    /// Read multiple bytes
    pub fn readBytes(self: *CellParser, count: usize) ![]u8 {
        var bytes = try self.allocator.alloc(u8, count);
        errdefer self.allocator.free(bytes);
        
        for (0..count) |i| {
            bytes[i] = try self.readByte();
        }
        
        return bytes;
    }
    
    /// Read unsigned integer
    pub fn readUint(self: *CellParser, bits: u8) !u64 {
        if (bits > 64) return error.BitsTooLarge;
        var value: u64 = 0;
        for (0..bits) |i| {
            const bit = try self.readBit();
            value |= @as(u64, @intCast(bit << @intCast(bits - 1 - i)));
        }
        return value;
    }
    
    /// Check if at end of cell
    pub fn isEnd(self: *CellParser) bool {
        return self.position >= self.cell.data.len * 8;
    }
    
    /// Get remaining bits
    pub fn remainingBits(self: *CellParser) u32 {
        return @as(u32, @intCast(self.cell.data.len * 8)) - self.position;
    }
};

// ============================================================
// Tests
// ============================================================

test "Cell builder and parser" {
    var builder = CellBuilder.init(std.testing.allocator);
    defer builder.deinit();
    
    try builder.writeUint(42, 8);
    try builder.writeBits(&[_]u1{1, 0, 1});
    
    const cell = try builder.build();
    defer cell.deinit();
    
    var parser = CellParser.init(std.testing.allocator, cell);
    const value = try parser.readUint(8);
    try std.testing.expectEqual(value, 42);
    
    const bits = try parser.readBits(3);
    defer std.testing.allocator.free(bits);
    try std.testing.expect(bits[0] == 1);
    try std.testing.expect(bits[1] == 0);
    try std.testing.expect(bits[2] == 1);
}

test "Cell hash computation" {
    var builder = CellBuilder.init(std.testing.allocator);
    defer builder.deinit();
    
    try builder.writeBytes("Hello TON");
    const cell = try builder.build();
    defer cell.deinit();
    
    const hash = try cell.computeHash();
    try std.testing.expect(hash.len == 32);
}