const std = @import("std");
const array_list = std.array_list;

/// Signature witness data (kept separate from transaction data in SegWit style)
pub const WitnessData = struct {
    tx_id: u32,                     // Transaction ID this signature belongs to
    sig_type: u8,                   // 0=Kyber, 1=Dilithium, 2=Falcon, 3=SPHINCS+
    signature: [512]u8,             // Signature bytes (max 512 for SPHINCS+)
    sig_len: u16,                   // Actual signature length
    public_key: [128]u8,            // Public key (max 128 bytes)
    pub_key_len: u16,               // Actual public key length
    timestamp: u64,                 // When signature was created
    flags: u8 = 0,                  // Flags (verified, archived, etc)

    pub fn init(tx_id: u32, sig_type: u8) WitnessData {
        return WitnessData{
            .tx_id = tx_id,
            .sig_type = sig_type,
            .signature = [_]u8{0} ** 512,
            .sig_len = 0,
            .public_key = [_]u8{0} ** 128,
            .pub_key_len = 0,
            .timestamp = @as(u64, @bitCast(std.time.timestamp())),
            .flags = 0,
        };
    }

    /// Set signature data
    pub fn setSignature(self: *WitnessData, sig: []const u8) !void {
        if (sig.len > 512) return error.SignatureTooLarge;
        std.mem.copyForwards(u8, &self.signature, sig);
        self.sig_len = @intCast(sig.len);
    }

    /// Set public key data
    pub fn setPublicKey(self: *WitnessData, pubkey: []const u8) !void {
        if (pubkey.len > 128) return error.PublicKeyTooLarge;
        std.mem.copyForwards(u8, &self.public_key, pubkey);
        self.pub_key_len = @intCast(pubkey.len);
    }

    /// Get signature slice
    pub fn getSignature(self: *const WitnessData) []const u8 {
        return self.signature[0..self.sig_len];
    }

    /// Get public key slice
    pub fn getPublicKey(self: *const WitnessData) []const u8 {
        return self.public_key[0..self.pub_key_len];
    }

    /// Serialize witness to binary
    pub fn serialize(self: *const WitnessData, allocator: std.mem.Allocator) ![]u8 {
        var buffer = try allocator.alloc(u8, 4 + 1 + 2 + self.sig_len + 2 + self.pub_key_len + 8 + 1);

        var offset: usize = 0;

        // TX ID (4 bytes)
        std.mem.writeInt(u32, buffer[offset..][0..4], self.tx_id, .little);
        offset += 4;

        // Sig type (1 byte)
        buffer[offset] = self.sig_type;
        offset += 1;

        // Signature length (2 bytes)
        std.mem.writeInt(u16, buffer[offset..][0..2], self.sig_len, .little);
        offset += 2;

        // Signature data
        std.mem.copyForwards(u8, buffer[offset .. offset + self.sig_len], self.getSignature());
        offset += self.sig_len;

        // Public key length (2 bytes)
        std.mem.writeInt(u16, buffer[offset..][0..2], self.pub_key_len, .little);
        offset += 2;

        // Public key data
        std.mem.copyForwards(u8, buffer[offset .. offset + self.pub_key_len], self.getPublicKey());
        offset += self.pub_key_len;

        // Timestamp (8 bytes)
        std.mem.writeInt(u64, buffer[offset..][0..8], self.timestamp, .little);
        offset += 8;

        // Flags (1 byte)
        buffer[offset] = self.flags;

        return buffer;
    }

    /// Deserialize witness from binary
    pub fn deserialize(data: []const u8, allocator: std.mem.Allocator) !WitnessData {
        _ = allocator;
        if (data.len < 18) return error.InsufficientData;

        var offset: usize = 0;

        var witness = WitnessData.init(0, 0);

        // Read TX ID
        witness.tx_id = std.mem.readInt(u32, data[offset..][0..4], .little);
        offset += 4;

        // Read sig type
        witness.sig_type = data[offset];
        offset += 1;

        // Read signature length
        witness.sig_len = std.mem.readInt(u16, data[offset..][0..2], .little);
        offset += 2;

        if (offset + witness.sig_len > data.len) return error.InsufficientData;

        // Read signature
        try witness.setSignature(data[offset .. offset + witness.sig_len]);
        offset += witness.sig_len;

        // Read public key length
        if (offset + 2 > data.len) return error.InsufficientData;
        witness.pub_key_len = std.mem.readInt(u16, data[offset..][0..2], .little);
        offset += 2;

        if (offset + witness.pub_key_len > data.len) return error.InsufficientData;

        // Read public key
        try witness.setPublicKey(data[offset .. offset + witness.pub_key_len]);
        offset += witness.pub_key_len;

        // Read timestamp
        if (offset + 8 > data.len) return error.InsufficientData;
        witness.timestamp = std.mem.readInt(u64, data[offset..][0..8], .little);
        offset += 8;

        // Read flags
        if (offset + 1 > data.len) return error.InsufficientData;
        witness.flags = data[offset];

        return witness;
    }

    pub fn print(self: *const WitnessData) void {
        std.debug.print(
            "[Witness] TX={d}, SigType={d}, SigLen={d}, PubKeyLen={d}\n",
            .{ self.tx_id, self.sig_type, self.sig_len, self.pub_key_len },
        );
    }
};

/// Witness pool - manages all signatures for a block
pub const WitnessPool = struct {
    allocator: std.mem.Allocator,
    witnesses: std.array_list.Managed(WitnessData),
    witness_map: std.AutoHashMap(u32, usize),  // tx_id -> index in witnesses
    total_size: u64 = 0,

    pub fn init(allocator: std.mem.Allocator) WitnessPool {
        return WitnessPool{
            .allocator = allocator,
            .witnesses = std.array_list.Managed(WitnessData).init(allocator),
            .witness_map = std.AutoHashMap(u32, usize).init(allocator),
        };
    }

    /// Add witness for a transaction
    pub fn addWitness(self: *WitnessPool, witness: WitnessData) !void {
        try self.witness_map.put(witness.tx_id, self.witnesses.items.len);
        try self.witnesses.append(witness);

        // Estimate size: 4 (tx_id) + 1 (type) + 2 (sig_len) + sig_len + 2 (key_len) + key_len + 8 (timestamp) + 1 (flags)
        self.total_size += 18 + witness.sig_len + witness.pub_key_len;
    }

    /// Get witness by transaction ID
    pub fn getWitness(self: *const WitnessPool, tx_id: u32) ?*const WitnessData {
        if (self.witness_map.get(tx_id)) |idx| {
            return &self.witnesses.items[idx];
        }
        return null;
    }

    /// Check if witness exists
    pub fn hasWitness(self: *const WitnessPool, tx_id: u32) bool {
        return self.witness_map.contains(tx_id);
    }

    /// Get all witnesses
    pub fn getAllWitnesses(self: *const WitnessPool) []const WitnessData {
        return self.witnesses.items;
    }

    /// Get witness count
    pub fn getWitnessCount(self: *const WitnessPool) usize {
        return self.witnesses.items.len;
    }

    /// Estimated storage size in bytes
    pub fn estimateSize(self: *const WitnessPool) u64 {
        return self.total_size;
    }

    /// Serialize all witnesses to binary
    pub fn serialize(self: *const WitnessPool) ![]u8 {
        var buffer = std.array_list.Managed(u8).init(self.allocator);

        // Write witness count (4 bytes)
        try buffer.appendSlice(&std.mem.toBytes(@as(u32, @intCast(self.witnesses.items.len))));

        // Write each witness
        for (self.witnesses.items) |witness| {
            const serialized = try witness.serialize(self.allocator);
            defer self.allocator.free(serialized);
            try buffer.appendSlice(serialized);
        }

        return buffer.items;
    }

    /// Clear all witnesses
    pub fn clear(self: *WitnessPool) void {
        self.witnesses.clearRetainingCapacity();
        self.witness_map.clearRetainingCapacity();
        self.total_size = 0;
    }

    /// Get compression ratio (witness data vs full signature)
    pub fn getCompressionStats(self: *const WitnessPool) CompressionStats {
        var total_sig_size: u64 = 0;
        var total_witness_size: u64 = 0;

        for (self.witnesses.items) |witness| {
            // Full signature would be 512 bytes
            total_sig_size += 512 + 128;  // signature + pubkey at full size

            // Witness only stores actual size
            total_witness_size += witness.sig_len + witness.pub_key_len + 18;
        }

        return CompressionStats{
            .full_size = total_sig_size,
            .witness_size = total_witness_size,
            .reduction_percent = if (total_sig_size > 0)
                (100 * (total_sig_size - total_witness_size)) / total_sig_size
            else
                0,
        };
    }

    pub fn printStats(self: *const WitnessPool) void {
        const stats = self.getCompressionStats();
        std.debug.print(
            "[WitnessPool] Count={d}, Size={d} bytes, Compression={d}%\n",
            .{ self.witnesses.items.len, self.total_size, stats.reduction_percent },
        );
    }

    pub fn deinit(self: *WitnessPool) void {
        self.witnesses.deinit();
        self.witness_map.deinit();
    }
};

pub const CompressionStats = struct {
    full_size: u64,
    witness_size: u64,
    reduction_percent: u64,
};

/// Witness archive for old blocks
pub const WitnessArchive = struct {
    allocator: std.mem.Allocator,
    block_witnesses: std.array_list.Managed(WitnessPool),
    block_heights: std.array_list.Managed(u32),

    pub fn init(allocator: std.mem.Allocator) WitnessArchive {
        return WitnessArchive{
            .allocator = allocator,
            .block_witnesses = std.array_list.Managed(WitnessPool).init(allocator),
            .block_heights = std.array_list.Managed(u32).init(allocator),
        };
    }

    /// Archive witnesses for a block height
    pub fn archiveBlock(self: *WitnessArchive, block_height: u32, pool: WitnessPool) !void {
        try self.block_witnesses.append(pool);
        try self.block_heights.append(block_height);
    }

    /// Get witnesses for a block
    pub fn getBlockWitnesses(self: *const WitnessArchive, block_height: u32) ?*const WitnessPool {
        for (self.block_heights.items, 0..) |height, idx| {
            if (height == block_height) {
                return &self.block_witnesses.items[idx];
            }
        }
        return null;
    }

    /// Get total archived size
    pub fn getTotalSize(self: *const WitnessArchive) u64 {
        var total: u64 = 0;
        for (self.block_witnesses.items) |pool| {
            total += pool.estimateSize();
        }
        return total;
    }

    pub fn deinit(self: *WitnessArchive) void {
        for (self.block_witnesses.items) |*pool| {
            pool.deinit();
        }
        self.block_witnesses.deinit();
        self.block_heights.deinit();
    }
};

// Tests
const testing = std.testing;

test "witness data creation" {
    const witness = WitnessData.init(42, 0);

    try testing.expectEqual(witness.tx_id, 42);
    try testing.expectEqual(witness.sig_type, 0);
    try testing.expectEqual(witness.sig_len, 0);
}

test "witness signature storage" {
    var witness = WitnessData.init(1, 1);

    const sig = "test_signature_data";
    try witness.setSignature(sig);

    try testing.expectEqual(witness.sig_len, sig.len);
    try testing.expectEqualStrings(witness.getSignature(), sig);
}

test "witness public key storage" {
    var witness = WitnessData.init(1, 1);

    const pubkey = "test_public_key";
    try witness.setPublicKey(pubkey);

    try testing.expectEqual(witness.pub_key_len, pubkey.len);
    try testing.expectEqualStrings(witness.getPublicKey(), pubkey);
}

test "witness serialization" {
    var witness = WitnessData.init(42, 0);
    try witness.setSignature("signature");
    try witness.setPublicKey("pubkey");

    const serialized = try witness.serialize(testing.allocator);
    defer testing.allocator.free(serialized);

    try testing.expect(serialized.len > 18);  // At least header size
}

test "witness deserialization" {
    var original = WitnessData.init(42, 1);
    try original.setSignature("test_sig_data");
    try original.setPublicKey("test_pubkey_data");

    const serialized = try original.serialize(testing.allocator);
    defer testing.allocator.free(serialized);

    const deserialized = try WitnessData.deserialize(serialized, testing.allocator);

    try testing.expectEqual(deserialized.tx_id, 42);
    try testing.expectEqual(deserialized.sig_type, 1);
    try testing.expectEqualStrings(deserialized.getSignature(), "test_sig_data");
    try testing.expectEqualStrings(deserialized.getPublicKey(), "test_pubkey_data");
}

test "witness pool operations" {
    var pool = WitnessPool.init(testing.allocator);
    defer pool.deinit();

    var w1 = WitnessData.init(1, 0);
    try w1.setSignature("sig1");
    try pool.addWitness(w1);

    var w2 = WitnessData.init(2, 1);
    try w2.setSignature("sig2");
    try pool.addWitness(w2);

    try testing.expectEqual(pool.getWitnessCount(), 2);
    try testing.expect(pool.hasWitness(1));
    try testing.expect(pool.hasWitness(2));
    try testing.expect(!pool.hasWitness(3));
}

test "witness pool lookup" {
    var pool = WitnessPool.init(testing.allocator);
    defer pool.deinit();

    var witness = WitnessData.init(99, 2);
    try witness.setSignature("important_signature");
    try pool.addWitness(witness);

    const found = pool.getWitness(99);
    try testing.expect(found != null);
    try testing.expectEqual(found.?.tx_id, 99);
}

test "witness compression stats" {
    var pool = WitnessPool.init(testing.allocator);
    defer pool.deinit();

    var w1 = WitnessData.init(1, 0);
    try w1.setSignature("short");  // 5 bytes instead of 512
    try pool.addWitness(w1);

    const stats = pool.getCompressionStats();
    try testing.expect(stats.reduction_percent > 50);  // Should have significant compression
}
