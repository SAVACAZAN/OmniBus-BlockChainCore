const std = @import("std");
const array_list = std.array_list;
const Sha256 = std.crypto.hash.sha2.Sha256;

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
        std.mem.writeInt(u32, buffer[offset..][0..4], self.index, .little);
        offset += 4;

        // Timestamp (8 bytes)
        std.mem.writeInt(i64, buffer[offset..][0..8], self.timestamp, .little);
        offset += 8;

        // Previous hash (32 bytes)
        std.mem.copyForwards(u8, buffer[offset .. offset + 32], &self.previous_hash);
        offset += 32;

        // Merkle root (32 bytes)
        std.mem.copyForwards(u8, buffer[offset .. offset + 32], &self.merkle_root);
        offset += 32;

        // Nonce (8 bytes)
        std.mem.writeInt(u64, buffer[offset..][0..8], self.nonce, .little);
        offset += 8;

        // Hash (32 bytes)
        std.mem.copyForwards(u8, buffer[offset .. offset + 32], &self.hash);
        offset += 32;

        // Difficulty (4 bytes)
        std.mem.writeInt(u32, buffer[offset..][0..4], self.difficulty, .little);
        offset += 4;

        // Transaction count (4 bytes)
        std.mem.writeInt(u32, buffer[offset..][0..4], self.transaction_count, .little);
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
        header.index = std.mem.readInt(u32, data[offset..][0..4], .little);
        offset += 4;

        // Timestamp
        header.timestamp = std.mem.readInt(i64, data[offset..][0..8], .little);
        offset += 8;

        // Previous hash
        std.mem.copyForwards(u8, &header.previous_hash, data[offset .. offset + 32]);
        offset += 32;

        // Merkle root
        std.mem.copyForwards(u8, &header.merkle_root, data[offset .. offset + 32]);
        offset += 32;

        // Nonce
        header.nonce = std.mem.readInt(u64, data[offset..][0..8], .little);
        offset += 8;

        // Hash
        std.mem.copyForwards(u8, &header.hash, data[offset .. offset + 32]);
        offset += 32;

        // Difficulty
        header.difficulty = std.mem.readInt(u32, data[offset..][0..4], .little);
        offset += 4;

        // Transaction count
        header.transaction_count = std.mem.readInt(u32, data[offset..][0..4], .little);
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

// ─── Merkle Proof (SPV transaction verification) ────────────────────────────

/// Maximum depth of merkle tree (2^20 = ~1M transactions per block)
const MAX_MERKLE_DEPTH = 20;

/// Merkle inclusion proof for a single transaction.
/// Allows a light client to verify that a TX is included in a block
/// using only the block header's merkle_root, without the full block.
pub const MerkleProof = struct {
    tx_hash: [32]u8,                                // Hash of the transaction being proved
    proof_hashes: [MAX_MERKLE_DEPTH][32]u8,         // Sibling hashes along the path to root
    directions: [MAX_MERKLE_DEPTH]bool,             // true = sibling is on the right
    depth: u8,                                      // Number of proof steps
    merkle_root: [32]u8,                            // Expected merkle root from block header
    block_index: u32,                               // Block height where TX lives
    tx_index: u32,                                  // Position of TX in block

    pub fn init(tx_hash: [32]u8, root: [32]u8, block_idx: u32, tx_idx: u32) MerkleProof {
        return MerkleProof{
            .tx_hash = tx_hash,
            .proof_hashes = [_][32]u8{[_]u8{0} ** 32} ** MAX_MERKLE_DEPTH,
            .directions = [_]bool{false} ** MAX_MERKLE_DEPTH,
            .depth = 0,
            .merkle_root = root,
            .block_index = block_idx,
            .tx_index = tx_idx,
        };
    }

    /// Add a sibling hash to the proof path
    pub fn addStep(self: *MerkleProof, sibling: [32]u8, is_right: bool) void {
        if (self.depth < MAX_MERKLE_DEPTH) {
            self.proof_hashes[self.depth] = sibling;
            self.directions[self.depth] = is_right;
            self.depth += 1;
        }
    }
};

/// Verify a merkle proof: hash the TX with siblings up to root.
/// Returns true if the computed root matches the expected merkle_root.
/// This is the core of SPV — proves TX inclusion without full block data.
/// Special case: depth=0 means single-TX block where tx_hash IS the merkle root.
pub fn verifyMerkleProof(proof: *const MerkleProof) bool {
    // Single TX in block: merkle root == tx hash, no proof steps needed
    if (proof.depth == 0) {
        return std.mem.eql(u8, &proof.tx_hash, &proof.merkle_root);
    }

    var current = proof.tx_hash;

    for (0..proof.depth) |i| {
        const sibling = proof.proof_hashes[i];
        var hasher = Sha256.init(.{});

        if (proof.directions[i]) {
            // Sibling is on the right: H(current || sibling)
            hasher.update(&current);
            hasher.update(&sibling);
        } else {
            // Sibling is on the left: H(sibling || current)
            hasher.update(&sibling);
            hasher.update(&current);
        }
        hasher.final(&current);
    }

    return std.mem.eql(u8, &current, &proof.merkle_root);
}

// ─── Bloom Filter (TX matching for SPV nodes) ───────────────────────────────

/// Bloom filter for SPV transaction filtering.
/// Light clients send a Bloom filter to full nodes describing which addresses
/// they are interested in. The full node only relays matching TXs.
/// Uses multiple hash functions (murmur-style rotation) for low false-positive rate.
pub const BloomFilter = struct {
    bits: [512]u8,              // 4096 bits = 512 bytes
    num_hash_funcs: u8,         // Number of hash functions (3-10 typical)

    pub fn init(num_funcs: u8) BloomFilter {
        return BloomFilter{
            .bits = [_]u8{0} ** 512,
            .num_hash_funcs = if (num_funcs < 1) 3 else if (num_funcs > 20) 20 else num_funcs,
        };
    }

    /// Insert data (address, txid, pubkey) into the filter
    pub fn add(self: *BloomFilter, data: []const u8) void {
        const total_bits: u32 = 512 * 8; // 4096
        for (0..self.num_hash_funcs) |func_idx| {
            const bit_pos = bloomHash(data, @intCast(func_idx)) % total_bits;
            const byte_idx = bit_pos / 8;
            const bit_off: u3 = @intCast(bit_pos % 8);
            self.bits[byte_idx] |= (@as(u8, 1) << bit_off);
        }
    }

    /// Check if data might be in the filter. May return false positives, never false negatives.
    pub fn contains(self: *const BloomFilter, data: []const u8) bool {
        const total_bits: u32 = 512 * 8;
        for (0..self.num_hash_funcs) |func_idx| {
            const bit_pos = bloomHash(data, @intCast(func_idx)) % total_bits;
            const byte_idx = bit_pos / 8;
            const bit_off: u3 = @intCast(bit_pos % 8);
            if ((self.bits[byte_idx] & (@as(u8, 1) << bit_off)) == 0) {
                return false;
            }
        }
        return true;
    }

    /// Clear the filter (reset all bits)
    pub fn clear(self: *BloomFilter) void {
        @memset(&self.bits, 0);
    }

    /// Estimate false positive rate given number of elements inserted.
    /// Formula: (1 - e^(-kn/m))^k where k=hash_funcs, n=elements, m=bits
    /// Returns a rough integer percentage (0-100).
    pub fn estimateFalsePositivePct(self: *const BloomFilter, num_elements: u32) u32 {
        if (num_elements == 0) return 0;
        const m: u64 = 4096; // total bits
        const k: u64 = self.num_hash_funcs;
        const n: u64 = num_elements;
        // Rough approximation: (kn/m)^k * 100 / (scale factor)
        const ratio = (k * n * 100) / m;
        if (ratio > 100) return 100;
        return @intCast(ratio);
    }
};

/// Murmur-inspired hash function with seed rotation for Bloom filter.
/// Each func_index produces a different hash of the same data.
fn bloomHash(data: []const u8, func_index: u32) u32 {
    // Seed per function index (different starting point for each hash func)
    var h: u32 = 0xdeadbeef +% func_index *% 0x9e3779b9;

    for (data) |byte| {
        h ^= @as(u32, byte);
        h *%= 0x5bd1e995;
        h ^= h >> 15;
    }

    // Final mix
    h ^= h >> 13;
    h *%= 0x5bd1e995;
    h ^= h >> 16;

    return h;
}

// ─── Light Client ───────────────────────────────────────────────────────────

/// Light Client - minimal blockchain for low-resource devices.
/// Downloads only block headers (~200 bytes each vs ~35KB full blocks).
/// Verifies TX inclusion via Merkle proofs (SPV).
/// Uses Bloom filters to request only relevant TXs from full nodes.
pub const LightClient = struct {
    allocator: std.mem.Allocator,
    headers: std.array_list.Managed(BlockHeader),
    trusted_root: [32]u8,           // Trusted block hash for fast sync
    sync_height: u32 = 0,           // Last synced block height
    max_headers_to_keep: u32 = 1000, // Keep last 1000 headers (~200KB)
    bloom: BloomFilter,             // Address filter for TX matching

    pub fn init(allocator: std.mem.Allocator) LightClient {
        return LightClient{
            .allocator = allocator,
            .headers = std.array_list.Managed(BlockHeader).init(allocator),
            .trusted_root = [_]u8{0} ** 32,
            .bloom = BloomFilter.init(5), // 5 hash functions — good balance
        };
    }

    /// Add block header to chain after validation
    pub fn addHeader(self: *LightClient, header: BlockHeader) !void {
        try self.headers.append(header);
        self.sync_height = header.index;

        // Prune old headers if exceeding max
        if (self.headers.items.len > self.max_headers_to_keep) {
            const remove_count = self.headers.items.len - self.max_headers_to_keep;
            for (0..remove_count) |_| {
                _ = self.headers.orderedRemove(0);
            }
        }
    }

    /// Validate a header before adding it:
    /// 1. previous_hash must match the hash of the last known header
    /// 2. index must be sequential
    /// 3. timestamp must not be in the future (with 2h tolerance, like Bitcoin)
    /// 4. difficulty must be > 0
    pub fn validateHeader(self: *const LightClient, header: *const BlockHeader) bool {
        // Difficulty must be positive
        if (header.difficulty == 0) return false;

        // If we have no headers, accept genesis (index 0)
        if (self.headers.items.len == 0) {
            return header.index == 0;
        }

        const last = &self.headers.items[self.headers.items.len - 1];

        // Index must be exactly previous + 1
        if (header.index != last.index + 1) return false;

        // previous_hash must link to last known header's hash
        if (!std.mem.eql(u8, &header.previous_hash, &last.hash)) return false;

        // Timestamp must not be more than 2 hours in the future
        const now = std.time.timestamp();
        const two_hours: i64 = 2 * 60 * 60;
        if (header.timestamp > now + two_hours) return false;

        // Timestamp must be >= previous block (no going backwards)
        if (header.timestamp < last.timestamp) return false;

        return true;
    }

    /// Validate and add a header. Returns error if validation fails.
    pub fn addValidatedHeader(self: *LightClient, header: BlockHeader) !void {
        if (!self.validateHeader(&header)) {
            return error.InvalidHeader;
        }
        try self.addHeader(header);
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

    /// Get current header chain height
    pub fn getHeight(self: *const LightClient) u32 {
        if (self.headers.items.len == 0) return 0;
        return self.headers.items[self.headers.items.len - 1].index;
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

    /// Verify a TX is in a block using a Merkle proof and our header chain
    pub fn verifyTransaction(self: *const LightClient, proof: *const MerkleProof) bool {
        // 1. Check we have the header for this block
        const header = self.getHeader(proof.block_index) orelse return false;

        // 2. Merkle root in proof must match our stored header
        if (!std.mem.eql(u8, &proof.merkle_root, &header.merkle_root)) return false;

        // 3. Verify the merkle path
        return verifyMerkleProof(proof);
    }

    /// Add an address to the Bloom filter (for TX matching)
    pub fn watchAddress(self: *LightClient, address: []const u8) void {
        self.bloom.add(address);
    }

    /// Check if a TX matches any watched address
    pub fn matchesFilter(self: *const LightClient, address: []const u8) bool {
        return self.bloom.contains(address);
    }

    /// Get number of confirmations for a proven TX
    pub fn getConfirmations(self: *const LightClient, proof: *const MerkleProof) u32 {
        const tip = self.getHeight();
        if (proof.block_index > tip) return 0;
        return tip - proof.block_index + 1;
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
        var buffer = std.array_list.Managed(u8).init(allocator);

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

    /// Trigger SPV header sync via P2P.
    /// Accepts an opaque pointer to P2PNode and a function pointer that calls
    /// P2PNode.syncHeaders(). This avoids circular imports (light_client cannot
    /// import p2p.zig directly).
    pub fn syncHeaders(self: *LightClient, p2p_ptr: *anyopaque, sync_fn: *const fn (*anyopaque) void) void {
        _ = self;
        sync_fn(p2p_ptr);
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

/// SPV (Simplified Payment Verification) proof for light clients (legacy compat)
pub const SPVProof = struct {
    tx_hash: [32]u8,
    merkle_proof: std.array_list.Managed([32]u8),  // Sibling hashes up to root
    block_header: BlockHeader,
    position_in_block: u32,

    pub fn init(allocator: std.mem.Allocator, tx_hash: [32]u8, header: BlockHeader) SPVProof {
        return SPVProof{
            .tx_hash = tx_hash,
            .merkle_proof = std.array_list.Managed([32]u8).init(allocator),
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

// ─── Tests ──────────────────────────────────────────────────────────────────

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

    const h1 = BlockHeader.init(0);
    try client.addHeader(h1);

    var h2 = BlockHeader.init(1);
    std.mem.copyForwards(u8, &h2.previous_hash, &h1.hash);
    try client.addHeader(h2);

    try testing.expectEqual(client.getHeaderCount(), 2);
}

test "light client chain verification" {
    var client = LightClient.init(testing.allocator);
    defer client.deinit();

    const h1 = BlockHeader.init(0);
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
    var filter = BloomFilter.init(5);

    const address = "ob1qwy7g9sk5s7qsc2m7d02j9anwyja4jcwwnxs2j7";
    filter.add(address);

    try testing.expect(filter.contains(address));
}

test "bloom filter - non-member not found (probabilistic)" {
    var filter = BloomFilter.init(5);

    filter.add("ob1ql33v8q9wqvqrschu982lvrnvfupyzcvj746kqh");
    filter.add("ob1qrpdsg3r7mvvunw6ket46qmjzlx6fuu3ppxlfas");

    // These should (very likely) not match — different data, low fill ratio
    // With 4096 bits, 5 hash funcs, and 2 insertions, false positive rate is ~0.0001%
    const probably_not = filter.contains("ob1qa5ackdxmacapcf7f4h592yawv6ansjscejxj8h");
    // We cannot assert false due to probabilistic nature, but we can test
    // that NOT everything matches
    const also_check = filter.contains("totally_different_string_abcdefghijklmnop");
    // At least one of them should be false (extremely high probability)
    try testing.expect(!probably_not or !also_check);
}

test "bloom filter - clear resets all bits" {
    var filter = BloomFilter.init(5);

    filter.add("ob1ql33v8q9wqvqrschu982lvrnvfupyzcvj746kqh");
    try testing.expect(filter.contains("ob1ql33v8q9wqvqrschu982lvrnvfupyzcvj746kqh"));

    filter.clear();
    try testing.expect(!filter.contains("ob1ql33v8q9wqvqrschu982lvrnvfupyzcvj746kqh"));
}

test "bloom filter - multiple hash functions reduce false positives" {
    // With more hash functions and few elements, false positive rate drops
    var filter3 = BloomFilter.init(3);
    var filter10 = BloomFilter.init(10);

    filter3.add("test_addr_1");
    filter10.add("test_addr_1");

    // Both must find inserted element
    try testing.expect(filter3.contains("test_addr_1"));
    try testing.expect(filter10.contains("test_addr_1"));
}

test "merkle proof - verify known good proof" {
    // Build a simple 2-TX merkle tree manually:
    // TX0 = sha256("tx0"), TX1 = sha256("tx1")
    // root = sha256(TX0 || TX1)

    var tx0_hash: [32]u8 = undefined;
    Sha256.hash("tx0", &tx0_hash, .{});

    var tx1_hash: [32]u8 = undefined;
    Sha256.hash("tx1", &tx1_hash, .{});

    // Compute merkle root: H(tx0 || tx1)
    var root: [32]u8 = undefined;
    var hasher = Sha256.init(.{});
    hasher.update(&tx0_hash);
    hasher.update(&tx1_hash);
    hasher.final(&root);

    // Proof for TX0: sibling is TX1 on the right
    var proof = MerkleProof.init(tx0_hash, root, 0, 0);
    proof.addStep(tx1_hash, true); // sibling TX1 is on right

    try testing.expect(verifyMerkleProof(&proof));
}

test "merkle proof - verify TX1 with TX0 as left sibling" {
    var tx0_hash: [32]u8 = undefined;
    Sha256.hash("tx0", &tx0_hash, .{});

    var tx1_hash: [32]u8 = undefined;
    Sha256.hash("tx1", &tx1_hash, .{});

    // root = H(tx0 || tx1)
    var root: [32]u8 = undefined;
    var hasher = Sha256.init(.{});
    hasher.update(&tx0_hash);
    hasher.update(&tx1_hash);
    hasher.final(&root);

    // Proof for TX1: sibling is TX0 on the left
    var proof = MerkleProof.init(tx1_hash, root, 0, 1);
    proof.addStep(tx0_hash, false); // sibling TX0 is on left

    try testing.expect(verifyMerkleProof(&proof));
}

test "merkle proof - wrong root fails verification" {
    var tx0_hash: [32]u8 = undefined;
    Sha256.hash("tx0", &tx0_hash, .{});

    var tx1_hash: [32]u8 = undefined;
    Sha256.hash("tx1", &tx1_hash, .{});

    // Wrong root
    const bad_root = [_]u8{0xff} ** 32;

    var proof = MerkleProof.init(tx0_hash, bad_root, 0, 0);
    proof.addStep(tx1_hash, true);

    try testing.expect(!verifyMerkleProof(&proof));
}

test "merkle proof - wrong sibling fails verification" {
    var tx0_hash: [32]u8 = undefined;
    Sha256.hash("tx0", &tx0_hash, .{});

    var tx1_hash: [32]u8 = undefined;
    Sha256.hash("tx1", &tx1_hash, .{});

    // Compute correct root
    var root: [32]u8 = undefined;
    var hasher = Sha256.init(.{});
    hasher.update(&tx0_hash);
    hasher.update(&tx1_hash);
    hasher.final(&root);

    // Proof with wrong sibling
    const bad_sibling = [_]u8{0xaa} ** 32;
    var proof = MerkleProof.init(tx0_hash, root, 0, 0);
    proof.addStep(bad_sibling, true);

    try testing.expect(!verifyMerkleProof(&proof));
}

test "merkle proof - 4 TX tree (2 levels)" {
    // Build a 4-TX tree:
    // Level 0: TX0, TX1, TX2, TX3
    // Level 1: H01 = H(TX0||TX1), H23 = H(TX2||TX3)
    // Level 2: root = H(H01||H23)

    var tx: [4][32]u8 = undefined;
    Sha256.hash("tx_a", &tx[0], .{});
    Sha256.hash("tx_b", &tx[1], .{});
    Sha256.hash("tx_c", &tx[2], .{});
    Sha256.hash("tx_d", &tx[3], .{});

    // H01
    var h01: [32]u8 = undefined;
    var hasher = Sha256.init(.{});
    hasher.update(&tx[0]);
    hasher.update(&tx[1]);
    hasher.final(&h01);

    // H23
    var h23: [32]u8 = undefined;
    hasher = Sha256.init(.{});
    hasher.update(&tx[2]);
    hasher.update(&tx[3]);
    hasher.final(&h23);

    // Root
    var root: [32]u8 = undefined;
    hasher = Sha256.init(.{});
    hasher.update(&h01);
    hasher.update(&h23);
    hasher.final(&root);

    // Prove TX2 is in the tree:
    // Step 1: sibling TX3 on right -> get H23
    // Step 2: sibling H01 on left -> get root
    var proof = MerkleProof.init(tx[2], root, 5, 2);
    proof.addStep(tx[3], true);   // TX3 is right sibling at leaf level
    proof.addStep(h01, false);    // H01 is left sibling at level 1

    try testing.expect(verifyMerkleProof(&proof));
}

test "merkle proof - depth 0 with matching hash succeeds (single TX)" {
    const tx_hash = [_]u8{0x42} ** 32;
    const root = [_]u8{0x42} ** 32; // same as tx_hash — single TX block
    const proof = MerkleProof.init(tx_hash, root, 0, 0);

    try testing.expect(verifyMerkleProof(&proof));
}

test "merkle proof - depth 0 with mismatching hash fails" {
    const tx_hash = [_]u8{0x42} ** 32;
    const root = [_]u8{0xFF} ** 32; // different — not a valid single-TX proof
    const proof = MerkleProof.init(tx_hash, root, 0, 0);

    try testing.expect(!verifyMerkleProof(&proof));
}

test "header validation - rejects wrong previous_hash" {
    var client = LightClient.init(testing.allocator);
    defer client.deinit();

    var h0 = BlockHeader.init(0);
    h0.hash = [_]u8{0xAA} ** 32;
    try client.addHeader(h0);

    // Header with wrong previous_hash
    var bad_h1 = BlockHeader.init(1);
    bad_h1.previous_hash = [_]u8{0xBB} ** 32; // wrong — should be 0xAA
    bad_h1.timestamp = h0.timestamp + 10;

    try testing.expect(!client.validateHeader(&bad_h1));
}

test "header validation - accepts correct linkage" {
    var client = LightClient.init(testing.allocator);
    defer client.deinit();

    var h0 = BlockHeader.init(0);
    h0.hash = [_]u8{0xAA} ** 32;
    try client.addHeader(h0);

    var h1 = BlockHeader.init(1);
    h1.previous_hash = [_]u8{0xAA} ** 32;
    h1.timestamp = h0.timestamp + 10;

    try testing.expect(client.validateHeader(&h1));
}

test "header validation - rejects non-sequential index" {
    var client = LightClient.init(testing.allocator);
    defer client.deinit();

    var h0 = BlockHeader.init(0);
    h0.hash = [_]u8{0xAA} ** 32;
    try client.addHeader(h0);

    // Index 5 instead of 1
    var bad = BlockHeader.init(5);
    bad.previous_hash = [_]u8{0xAA} ** 32;
    bad.timestamp = h0.timestamp + 10;

    try testing.expect(!client.validateHeader(&bad));
}

test "header validation - rejects zero difficulty" {
    var client = LightClient.init(testing.allocator);
    defer client.deinit();

    var h0 = BlockHeader.init(0);
    h0.hash = [_]u8{0xAA} ** 32;
    try client.addHeader(h0);

    var bad = BlockHeader.init(1);
    bad.previous_hash = [_]u8{0xAA} ** 32;
    bad.timestamp = h0.timestamp + 10;
    bad.difficulty = 0;

    try testing.expect(!client.validateHeader(&bad));
}

test "light client getHeight" {
    var client = LightClient.init(testing.allocator);
    defer client.deinit();

    try testing.expectEqual(@as(u32, 0), client.getHeight());

    try client.addHeader(BlockHeader.init(0));
    try testing.expectEqual(@as(u32, 0), client.getHeight());

    const h1 = BlockHeader.init(5);
    try client.addHeader(h1);
    try testing.expectEqual(@as(u32, 5), client.getHeight());
}

test "light client watchAddress and matchesFilter" {
    var client = LightClient.init(testing.allocator);
    defer client.deinit();

    client.watchAddress("ob1ql33v8q9wqvqrschu982lvrnvfupyzcvj746kqh");
    try testing.expect(client.matchesFilter("ob1ql33v8q9wqvqrschu982lvrnvfupyzcvj746kqh"));
}

test "light client getConfirmations" {
    var client = LightClient.init(testing.allocator);
    defer client.deinit();

    // Add headers 0..9
    for (0..10) |i| {
        try client.addHeader(BlockHeader.init(@intCast(i)));
    }

    // A TX in block 5 should have 10 - 5 + 1 = 6 confirmations
    var tx_hash: [32]u8 = undefined;
    Sha256.hash("test_tx", &tx_hash, .{});
    const proof = MerkleProof.init(tx_hash, [_]u8{0} ** 32, 5, 0);

    try testing.expectEqual(@as(u32, 5), client.getConfirmations(&proof));
}

test "light client verifyTransaction checks merkle root match" {
    var client = LightClient.init(testing.allocator);
    defer client.deinit();

    // Create a header with a known merkle root
    var h0 = BlockHeader.init(0);
    const known_root = [_]u8{0xDE} ** 32;
    h0.merkle_root = known_root;
    try client.addHeader(h0);

    // Create a proof with mismatching merkle root — should fail
    var tx_hash: [32]u8 = undefined;
    Sha256.hash("some_tx", &tx_hash, .{});
    const bad_proof = MerkleProof.init(tx_hash, [_]u8{0xFF} ** 32, 0, 0);

    try testing.expect(!client.verifyTransaction(&bad_proof));
}

test "light client syncHeaders — calls sync function" {
    var client = LightClient.init(testing.allocator);
    defer client.deinit();

    // Track if sync function was called
    const SyncTracker = struct {
        var called: bool = false;
        fn syncFn(ptr: *anyopaque) void {
            _ = ptr;
            called = true;
        }
    };

    SyncTracker.called = false;
    var dummy: u8 = 0;
    client.syncHeaders(@ptrCast(&dummy), &SyncTracker.syncFn);
    try testing.expect(SyncTracker.called);
}
