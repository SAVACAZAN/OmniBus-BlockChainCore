const std = @import("std");
const array_list = std.array_list;

/// Minimal block header for light client (only ~200 bytes vs 35KB full block)
pub const BlockHeader = struct {
    index: u32,                     // Block number
    timestamp: i64,                 // Block creation time
    previous_hash: [32]u8,          // Hash of parent block
    merkle_root: [32]u8,            // Root of transaction tree
    nonce: u64,                     // PoW nonce
    hash: [32]u8,                   // Block hash
    difficulty: u32,                // Mining difficulty
    transaction_count: u32,         // Number of transactions (without actual data)
    sub_blocks: u8,                 // Number of sub-blocks (0-10)

    pub fn init(index: u32) BlockHeader {
        return BlockHeader{
            .index = index,
            .timestamp = std.time.timestamp(),
            .previous_hash = [_]u8{0} ** 32,
            .merkle_root = [_]u8{0} ** 32,
            .nonce = 0,
            .hash = [_]u8{0} ** 32,
            .difficulty = 4,
            .transaction_count = 0,
            .sub_blocks = 10,
        };
    }

    /// Serialize header to binary (lightweight)
    pub fn serialize(self: *const BlockHeader) [200]u8 {
        var buffer: [200]u8 = undefined;
        var offset: usize = 0;

        // Index (4 bytes)
        std.mem.writeInt(u32, buffer[offset .. offset + 4], self.index, .little);
        offset += 4;

        // Timestamp (8 bytes)
        std.mem.writeInt(i64, buffer[offset .. offset + 8], self.timestamp, .little);
        offset += 8;

        // Previous hash (32 bytes)
        std.mem.copyForwards(u8, buffer[offset .. offset + 32], &self.previous_hash);
        offset += 32;

        // Merkle root (32 bytes)
        std.mem.copyForwards(u8, buffer[offset .. offset + 32], &self.merkle_root);
        offset += 32;

        // Nonce (8 bytes)
        std.mem.writeInt(u64, buffer[offset .. offset + 8], self.nonce, .little);
        offset += 8;

        // Hash (32 bytes)
        std.mem.copyForwards(u8, buffer[offset .. offset + 32], &self.hash);
        offset += 32;

        // Difficulty (4 bytes)
        std.mem.writeInt(u32, buffer[offset .. offset + 4], self.difficulty, .little);
        offset += 4;

        // Transaction count (4 bytes)
        std.mem.writeInt(u32, buffer[offset .. offset + 4], self.transaction_count, .little);
        offset += 4;

        // Sub-blocks (1 byte)
        buffer[offset] = self.sub_blocks;

        return buffer;
    }

    /// Deserialize header from binary
    pub fn deserialize(data: [200]u8) BlockHeader {
        var header = BlockHeader.init(0);
        var offset: usize = 0;

        // Index
        header.index = std.mem.readInt(u32, data[offset .. offset + 4], .little);
        offset += 4;

        // Timestamp
        header.timestamp = std.mem.readInt(i64, data[offset .. offset + 8], .little);
        offset += 8;

        // Previous hash
        std.mem.copyForwards(u8, &header.previous_hash, data[offset .. offset + 32]);
        offset += 32;

        // Merkle root
        std.mem.copyForwards(u8, &header.merkle_root, data[offset .. offset + 32]);
        offset += 32;

        // Nonce
        header.nonce = std.mem.readInt(u64, data[offset .. offset + 8], .little);
        offset += 8;

        // Hash
        std.mem.copyForwards(u8, &header.hash, data[offset .. offset + 32]);
        offset += 32;

        // Difficulty
        header.difficulty = std.mem.readInt(u32, data[offset .. offset + 4], .little);
        offset += 4;

        // Transaction count
        header.transaction_count = std.mem.readInt(u32, data[offset .. offset + 4], .little);
        offset += 4;

        // Sub-blocks
        header.sub_blocks = data[offset];

        return header;
    }

    pub fn print(self: *const BlockHeader) void {
        std.debug.print(
            "[Header] Block={d}, TxCount={d}, Nonce={d}\n",
            .{ self.index, self.transaction_count, self.nonce },
        );
    }
};

/// Light Client - minimal blockchain for low-resource devices
pub const LightClient = struct {
    allocator: std.mem.Allocator,
    headers: std.ArrayList(BlockHeader),
    trusted_root: [32]u8,           // Trusted block hash for fast sync
    sync_height: u32 = 0,           // Last synced block height
    max_headers_to_keep: u32 = 1000, // Keep last 1000 headers (~200KB)

    pub fn init(allocator: std.mem.Allocator) LightClient {
        return LightClient{
            .allocator = allocator,
            .headers = std.ArrayList(BlockHeader).init(allocator),
            .trusted_root = [_]u8{0} ** 32,
        };
    }

    /// Add block header to chain
    pub fn addHeader(self: *LightClient, header: BlockHeader) !void {
        try self.headers.append(header);
        self.sync_height = header.index;

        // Prune old headers if exceeding max
        if (self.headers.items.len > self.max_headers_to_keep) {
            const remove_count = self.headers.items.len - self.max_headers_to_keep;
            _ = self.headers.orderedRemoveRange(0, remove_count);
        }
    }

    /// Verify header chain (check previous_hash links)
    pub fn verifyChain(self: *const LightClient) bool {
        if (self.headers.items.len < 2) return true;

        for (1..self.headers.items.len) |i| {
            const prev_header = &self.headers.items[i - 1];
            const curr_header = &self.headers.items[i];

            // Check that current header references previous hash
            if (!std.mem.eql(u8, &curr_header.previous_hash, &prev_header.hash)) {
                return false;
            }

            // Check that index is sequential
            if (curr_header.index != prev_header.index + 1) {
                return false;
            }
        }

        return true;
    }

    /// Get header by block height
    pub fn getHeader(self: *const LightClient, height: u32) ?*const BlockHeader {
        for (self.headers.items) |*header| {
            if (header.index == height) {
                return header;
            }
        }
        return null;
    }

    /// Get latest header
    pub fn getLatestHeader(self: *const LightClient) ?*const BlockHeader {
        if (self.headers.items.len == 0) return null;
        return &self.headers.items[self.headers.items.len - 1];
    }

    /// Get header count
    pub fn getHeaderCount(self: *const LightClient) usize {
        return self.headers.items.len;
    }

    /// Estimate storage used (headers only)
    pub fn estimateStorageSize(self: *const LightClient) u64 {
        // ~200 bytes per header
        return @as(u64, @intCast(self.headers.items.len)) * 200;
    }

    /// Fast sync from trusted checkpoint
    pub fn fastSyncFromCheckpoint(self: *LightClient, trusted_header: BlockHeader, new_headers: []const BlockHeader) !void {
        // Verify first new header links to trusted
        if (new_headers.len > 0) {
            const first = new_headers[0];
            if (!std.mem.eql(u8, &first.previous_hash, &trusted_header.hash)) {
                return error.InvalidCheckpoint;
            }
        }

        // Add all new headers
        for (new_headers) |header| {
            try self.addHeader(header);
        }
    }

    /// Get proof-of-work difficulty at height
    pub fn getDifficulty(self: *const LightClient, height: u32) u32 {
        if (self.getHeader(height)) |header| {
            return header.difficulty;
        }
        return 4;  // Default
    }

    /// Serialize headers to file format
    pub fn serializeToFile(self: *const LightClient, allocator: std.mem.Allocator) ![]u8 {
        var buffer = std.ArrayList(u8).init(allocator);

        // Write header count (4 bytes)
        try buffer.appendSlice(&std.mem.toBytes(@as(u32, @intCast(self.headers.items.len))));

        // Write each header (200 bytes each)
        for (self.headers.items) |header| {
            const serialized = header.serialize();
            try buffer.appendSlice(&serialized);
        }

        return buffer.items;
    }

    /// Deserialize headers from file format
    pub fn deserializeFromFile(self: *LightClient, data: []const u8) !void {
        if (data.len < 4) return error.InsufficientData;

        var offset: usize = 0;

        // Read header count
        const header_count = std.mem.readInt(u32, data[offset .. offset + 4], .little);
        offset += 4;

        // Read each header
        for (0..header_count) |_| {
            if (offset + 200 > data.len) return error.InsufficientData;

            var header_data: [200]u8 = undefined;
            std.mem.copyForwards(u8, &header_data, data[offset .. offset + 200]);
            offset += 200;

            const header = BlockHeader.deserialize(header_data);
            try self.addHeader(header);
        }
    }

    /// Statistics about light client
    pub fn printStats(self: *const LightClient) void {
        const size = self.estimateStorageSize();
        const latest = self.getLatestHeader();

        std.debug.print(
            \\[LightClient] Stats:
            \\  - Headers: {d}
            \\  - Storage: {d} KB
            \\  - Latest block: {d}
            \\  - Chain valid: {}
            \\
        , .{
            self.headers.items.len,
            size / 1024,
            if (latest) |h| h.index else 0,
            self.verifyChain(),
        });
    }

    pub fn deinit(self: *LightClient) void {
        self.headers.deinit();
    }
};

/// SPV (Simplified Payment Verification) proof for light clients
pub const SPVProof = struct {
    tx_hash: [32]u8,
    merkle_proof: std.ArrayList([32]u8),  // Sibling hashes up to root
    block_header: BlockHeader,
    position_in_block: u32,

    pub fn init(allocator: std.mem.Allocator, tx_hash: [32]u8, header: BlockHeader) SPVProof {
        return SPVProof{
            .tx_hash = tx_hash,
            .merkle_proof = std.ArrayList([32]u8).init(allocator),
            .block_header = header,
            .position_in_block = 0,
        };
    }

    /// Verify SPV proof against block header
    pub fn verifyProof(self: *const SPVProof) bool {
        // Simplified: just verify that block header is valid
        // Full implementation would verify merkle path to root
        return self.block_header.hash[0] != 0;  // Basic check
    }

    pub fn deinit(self: *SPVProof) void {
        self.merkle_proof.deinit();
    }
};

/// Bloom filter for transaction filtering (reduce data transfer)
pub const BloomFilter = struct {
    allocator: std.mem.Allocator,
    bits: std.ArrayList(u8),
    size_bytes: u32 = 1024,  // 8192 bits = 1KB

    pub fn init(allocator: std.mem.Allocator) BloomFilter {
        return BloomFilter{
            .allocator = allocator,
            .bits = std.ArrayList(u8).init(allocator),
        };
    }

    /// Insert address into filter
    pub fn add(self: *BloomFilter, address: []const u8) !void {
        if (self.bits.items.len == 0) {
            try self.bits.appendNTimes(0, self.size_bytes);
        }

        // Simple hash: sum of bytes mod (size * 8)
        var hash: u32 = 0;
        for (address) |byte| {
            hash = (hash *| 31) + byte;
        }

        const bit_index = hash % (self.size_bytes * 8);
        const byte_index = bit_index / 8;
        const bit_offset = @as(u3, @intCast(bit_index % 8));

        if (byte_index < self.bits.items.len) {
            self.bits.items[byte_index] |= (@as(u8, 1) << bit_offset);
        }
    }

    /// Check if address might be in filter (has false positives)
    pub fn contains(self: *const BloomFilter, address: []const u8) bool {
        if (self.bits.items.len == 0) return false;

        var hash: u32 = 0;
        for (address) |byte| {
            hash = (hash *| 31) + byte;
        }

        const bit_index = hash % (self.size_bytes * 8);
        const byte_index = bit_index / 8;
        const bit_offset = @as(u3, @intCast(bit_index % 8));

        if (byte_index < self.bits.items.len) {
            return (self.bits.items[byte_index] & (@as(u8, 1) << bit_offset)) != 0;
        }

        return false;
    }

    pub fn deinit(self: *BloomFilter) void {
        self.bits.deinit();
    }
};

// Tests
const testing = std.testing;

test "block header creation" {
    const header = BlockHeader.init(100);

    try testing.expectEqual(header.index, 100);
    try testing.expectEqual(header.sub_blocks, 10);
}

test "block header serialization" {
    var header = BlockHeader.init(42);
    header.transaction_count = 50;

    const serialized = header.serialize();
    const deserialized = BlockHeader.deserialize(serialized);

    try testing.expectEqual(deserialized.index, 42);
    try testing.expectEqual(deserialized.transaction_count, 50);
}

test "light client header storage" {
    var client = LightClient.init(testing.allocator);
    defer client.deinit();

    var h1 = BlockHeader.init(0);
    try client.addHeader(h1);

    var h2 = BlockHeader.init(1);
    std.mem.copyForwards(u8, &h2.previous_hash, &h1.hash);
    try client.addHeader(h2);

    try testing.expectEqual(client.getHeaderCount(), 2);
}

test "light client chain verification" {
    var client = LightClient.init(testing.allocator);
    defer client.deinit();

    var h1 = BlockHeader.init(0);
    try client.addHeader(h1);

    var h2 = BlockHeader.init(1);
    std.mem.copyForwards(u8, &h2.previous_hash, &h1.hash);
    try client.addHeader(h2);

    try testing.expect(client.verifyChain());
}

test "light client storage estimate" {
    var client = LightClient.init(testing.allocator);
    defer client.deinit();

    for (0..10) |i| {
        const header = BlockHeader.init(@intCast(i));
        try client.addHeader(header);
    }

    const size = client.estimateStorageSize();
    // 10 headers * ~200 bytes = ~2000 bytes
    try testing.expect(size >= 2000 and size <= 3000);
}

test "light client header pruning" {
    var client = LightClient.init(testing.allocator);
    client.max_headers_to_keep = 5;
    defer client.deinit();

    // Add 10 headers
    for (0..10) |i| {
        const header = BlockHeader.init(@intCast(i));
        try client.addHeader(header);
    }

    // Should only keep last 5
    try testing.expectEqual(client.getHeaderCount(), 5);
}

test "spv proof creation" {
    var proof = SPVProof.init(testing.allocator, [_]u8{1} ** 32, BlockHeader.init(100));
    defer proof.deinit();

    try testing.expectEqual(proof.position_in_block, 0);
}

test "bloom filter add and check" {
    var filter = BloomFilter.init(testing.allocator);
    defer filter.deinit();

    const address = "test_address_123";
    try filter.add(address);

    try testing.expect(filter.contains(address));
}
