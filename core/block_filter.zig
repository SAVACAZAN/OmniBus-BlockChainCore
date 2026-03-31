const std = @import("std");
const block_mod = @import("block.zig");

// ─── Block Filters (BIP-157/158) ────────────────────────────────────────────
//
// Compact Block Filters allow light clients to determine if a block contains
// relevant transactions WITHOUT downloading the full block.
//
// How it works:
//   1. Full node creates a filter for each block (GCS-encoded set of addresses/scripts)
//   2. Light client downloads filter headers (tiny, like block headers)
//   3. Client tests filter against its own addresses
//   4. If filter matches, client downloads the full block
//   5. If no match, skip the block (saves bandwidth)
//
// This gives light clients PRIVACY (node doesn't know which addresses client has)
// unlike BIP-37 Bloom filters which leak address info.

/// Filter type (BIP-158)
pub const FilterType = enum(u8) {
    /// Basic filter: all scriptPubKeys + OP_RETURN data
    basic = 0,
    /// Extended filter: includes witness data (future use)
    extended = 1,
};

/// A compact block filter
pub const BlockFilter = struct {
    /// Block hash this filter is for
    block_hash: [32]u8,
    /// Block height
    block_height: u64,
    /// Filter type
    filter_type: FilterType,
    /// GCS-encoded filter data (compressed set of address hashes)
    filter_data: []u8,
    /// Filter header: SHA256d(filter_data || prev_filter_header)
    filter_header: [32]u8,
    /// Number of elements in the filter
    n_elements: u32,

    /// Test if an address might be in this block (probabilistic — false positives possible)
    pub fn mayContain(self: *const BlockFilter, address: []const u8) bool {
        // SipHash of address, then check against GCS-encoded set
        // Simplified: hash address and check if hash mod n_elements exists in filter
        if (self.n_elements == 0) return false;

        var hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(address, &hash, .{});

        // Simple probabilistic check: look for hash prefix in filter_data
        const target = std.mem.readInt(u32, hash[0..4], .big) % (self.n_elements * 784_931);
        const target_bytes = std.mem.toBytes(std.mem.nativeTo(u32, target, .big));

        // Scan filter data for matching 4-byte segment
        if (self.filter_data.len < 4) return false;
        var i: usize = 0;
        while (i + 4 <= self.filter_data.len) : (i += 4) {
            if (std.mem.eql(u8, self.filter_data[i .. i + 4], &target_bytes)) return true;
        }
        return false;
    }
};

/// Block filter builder — creates filters from block data
pub const FilterBuilder = struct {
    /// Build a basic filter for a block
    pub fn buildBasicFilter(
        block_hash: [32]u8,
        block_height: u64,
        addresses: []const []const u8,
        prev_filter_header: [32]u8,
        allocator: std.mem.Allocator,
    ) !BlockFilter {
        const n: u32 = @intCast(addresses.len);

        // Build GCS-encoded set: hash each address, sort, delta-encode
        var hashes = try allocator.alloc(u32, n);
        defer allocator.free(hashes);

        for (addresses, 0..) |addr, i| {
            var h: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(addr, &h, .{});
            hashes[i] = std.mem.readInt(u32, h[0..4], .big) % (n * 784_931);
        }

        // Sort for delta encoding
        std.mem.sort(u32, hashes, {}, std.sort.asc(u32));

        // Simple encoding: store raw u32 values as bytes
        var filter_data = try allocator.alloc(u8, n * 4);
        for (hashes, 0..) |h, i| {
            const bytes = std.mem.toBytes(std.mem.nativeTo(u32, h, .big));
            @memcpy(filter_data[i * 4 .. i * 4 + 4], &bytes);
        }

        // Filter header = SHA256d(filter_data || prev_filter_header)
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update(filter_data);
        hasher.update(&prev_filter_header);
        var first: [32]u8 = undefined;
        hasher.final(&first);
        var filter_header: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(&first, &filter_header, .{});

        return BlockFilter{
            .block_hash = block_hash,
            .block_height = block_height,
            .filter_type = .basic,
            .filter_data = filter_data,
            .filter_header = filter_header,
            .n_elements = n,
        };
    }
};

/// Filter header chain — for light client verification
pub const FilterHeaderChain = struct {
    headers: std.ArrayList([32]u8),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) FilterHeaderChain {
        return FilterHeaderChain{
            .headers = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *FilterHeaderChain) void {
        self.headers.deinit(self.allocator);
    }

    pub fn addHeader(self: *FilterHeaderChain, header: [32]u8) !void {
        try self.headers.append(self.allocator, header);
    }

    pub fn getHeader(self: *const FilterHeaderChain, height: u64) ?[32]u8 {
        if (height >= self.headers.items.len) return null;
        return self.headers.items[height];
    }

    pub fn chainHeight(self: *const FilterHeaderChain) u64 {
        return self.headers.items.len;
    }
};

// ─── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

test "BlockFilter — build and query" {
    const addresses = [_][]const u8{
        "ob1qalice_address_here_abc",
        "ob1qbob_address_here_xyz",
        "ob1qcarol_addr_here_123",
    };

    const block_hash = [_]u8{0xAA} ** 32;
    const prev_header = [_]u8{0x00} ** 32;

    var filter = try FilterBuilder.buildBasicFilter(
        block_hash, 100, &addresses, prev_header, testing.allocator,
    );
    defer testing.allocator.free(filter.filter_data);

    try testing.expectEqual(@as(u32, 3), filter.n_elements);
    try testing.expectEqual(@as(u64, 100), filter.block_height);
    try testing.expectEqual(FilterType.basic, filter.filter_type);

    // Should match addresses that were included
    try testing.expect(filter.mayContain("ob1qalice_address_here_abc"));
    try testing.expect(filter.mayContain("ob1qbob_address_here_xyz"));

    // Should NOT match random address (probabilistic, but unlikely)
    // False positive rate ~1/784931, so this should almost always be false
    try testing.expect(!filter.mayContain("ob1q_totally_random_never_seen"));
}

test "BlockFilter — empty block" {
    const addresses = [_][]const u8{};
    const block_hash = [_]u8{0xBB} ** 32;
    const prev_header = [_]u8{0x00} ** 32;

    var filter = try FilterBuilder.buildBasicFilter(
        block_hash, 50, &addresses, prev_header, testing.allocator,
    );
    defer testing.allocator.free(filter.filter_data);

    try testing.expectEqual(@as(u32, 0), filter.n_elements);
    try testing.expect(!filter.mayContain("ob1qany"));
}

test "BlockFilter — filter header is deterministic" {
    const addresses = [_][]const u8{ "addr1", "addr2" };
    const block_hash = [_]u8{0xCC} ** 32;
    const prev_header = [_]u8{0x11} ** 32;

    var f1 = try FilterBuilder.buildBasicFilter(block_hash, 1, &addresses, prev_header, testing.allocator);
    defer testing.allocator.free(f1.filter_data);
    var f2 = try FilterBuilder.buildBasicFilter(block_hash, 1, &addresses, prev_header, testing.allocator);
    defer testing.allocator.free(f2.filter_data);

    try testing.expectEqualSlices(u8, &f1.filter_header, &f2.filter_header);
}

test "FilterHeaderChain — add and get" {
    var chain = FilterHeaderChain.init(testing.allocator);
    defer chain.deinit();

    const h1 = [_]u8{0x01} ** 32;
    const h2 = [_]u8{0x02} ** 32;
    try chain.addHeader(h1);
    try chain.addHeader(h2);

    try testing.expectEqual(@as(u64, 2), chain.chainHeight());
    try testing.expectEqualSlices(u8, &h1, &chain.getHeader(0).?);
    try testing.expectEqualSlices(u8, &h2, &chain.getHeader(1).?);
    try testing.expectEqual(@as(?[32]u8, null), chain.getHeader(99));
}
