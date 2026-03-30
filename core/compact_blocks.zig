const std = @import("std");

/// Compact Block Relay (BIP-152 style)
///
/// In loc de a trimite blocuri complete (~35KB), trimitem:
///   1. Block header (88 bytes)
///   2. Short TX IDs (6 bytes per TX) — din primele 6 bytes ale TX hash
///   3. Prefilled TX (TX-urile pe care receiver probabil nu le are)
///
/// Receiver-ul reconstruieste blocul din mempool-ul propriu:
///   - Matcheaza short TX IDs cu TX-urile din mempool
///   - Cere doar TX-urile lipsa (getblocktxn)
///
/// Reduce bandwidth cu ~90% pentru noduri cu mempool sincronizat.
///
/// Bitcoin BIP-152: https://github.com/bitcoin/bips/blob/master/bip-0152.mediawiki
/// OmniBus: adaptat pentru 1s blocks si sub-block engine

/// Short TX ID size (6 bytes = 48 bits, collision prob ~1/2^48)
pub const SHORT_TXID_SIZE: usize = 6;
/// Maximum TX IDs in a compact block
pub const MAX_COMPACT_TX: usize = 10_000;
/// Maximum prefilled TX in a compact block
pub const MAX_PREFILLED: usize = 100;
/// SipHash key size (used for short TX ID derivation)
pub const SIPHASH_KEY_SIZE: usize = 16;

/// Short TX ID: first 6 bytes of SipHash(TX hash, nonce)
pub const ShortTxId = [SHORT_TXID_SIZE]u8;

/// Compute short TX ID from full TX hash
/// Uses block header hash as SipHash key for domain separation
pub fn computeShortTxId(tx_hash: [32]u8, block_nonce: u64) ShortTxId {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(&tx_hash);
    var nonce_bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &nonce_bytes, block_nonce, .little);
    hasher.update(&nonce_bytes);
    var full_hash: [32]u8 = undefined;
    hasher.final(&full_hash);

    var short_id: ShortTxId = undefined;
    @memcpy(&short_id, full_hash[0..SHORT_TXID_SIZE]);
    return short_id;
}

/// Prefilled transaction (TX that receiver likely doesn't have)
pub const PrefilledTx = struct {
    /// Index in the block's transaction list
    index: u16,
    /// Full TX hash (32 bytes)
    tx_hash: [32]u8,
    /// TX data size
    tx_size: u32,
};

/// Compact Block message
/// Sent instead of full block — ~90% bandwidth reduction
pub const CompactBlock = struct {
    /// Block header (88 bytes)
    header_height: u64,
    header_timestamp: i64,
    header_prev_hash: [32]u8,
    header_merkle_root: [32]u8,
    header_nonce: u64,
    /// Nonce for short TX ID computation (random per compact block)
    short_id_nonce: u64,
    /// Short TX IDs (6 bytes each)
    short_ids: [MAX_COMPACT_TX]ShortTxId,
    short_id_count: u16,
    /// Prefilled TX (coinbase + new TX not in mempool)
    prefilled: [MAX_PREFILLED]PrefilledTx,
    prefilled_count: u8,

    /// Total compact block size in bytes (header + short IDs + prefilled)
    pub fn compactSize(self: *const CompactBlock) usize {
        const header_size: usize = 88; // standard header
        const nonce_size: usize = 8;
        const short_ids_size = @as(usize, self.short_id_count) * SHORT_TXID_SIZE;
        const prefilled_size = @as(usize, self.prefilled_count) * 36; // index(2) + hash(32) + size(4)
        return header_size + nonce_size + 2 + short_ids_size + 1 + prefilled_size;
    }

    /// Estimated full block size
    pub fn estimatedFullSize(self: *const CompactBlock) usize {
        // Assume ~250 bytes per TX average
        return 88 + @as(usize, self.short_id_count) * 250;
    }

    /// Bandwidth savings percentage
    pub fn savingsPercent(self: *const CompactBlock) u8 {
        const full = self.estimatedFullSize();
        const compact = self.compactSize();
        if (full == 0) return 0;
        return @intCast(100 - (compact * 100 / full));
    }
};

/// Result of compact block reconstruction
pub const ReconstructResult = struct {
    /// Successfully reconstructed
    success: bool,
    /// Number of TX found in local mempool
    found_in_mempool: u16,
    /// Number of TX missing (need to request)
    missing_count: u16,
    /// Indices of missing TX (for getblocktxn request)
    missing_indices: [MAX_COMPACT_TX]u16,
};

/// Try to reconstruct a full block from compact block + local mempool
/// Returns: which TX we have and which we need to request
pub fn reconstructFromMempool(
    compact: *const CompactBlock,
    mempool_tx_hashes: []const [32]u8,
) ReconstructResult {
    var result = ReconstructResult{
        .success = false,
        .found_in_mempool = 0,
        .missing_count = 0,
        .missing_indices = undefined,
    };

    // For each short TX ID in compact block, try to find it in mempool
    for (0..compact.short_id_count) |i| {
        const short_id = compact.short_ids[i];
        var found = false;

        // Check prefilled first
        for (compact.prefilled[0..compact.prefilled_count]) |pf| {
            if (pf.index == i) {
                found = true;
                break;
            }
        }

        if (!found) {
            // Search mempool by short TX ID
            for (mempool_tx_hashes) |tx_hash| {
                const mempool_short = computeShortTxId(tx_hash, compact.short_id_nonce);
                if (std.mem.eql(u8, &short_id, &mempool_short)) {
                    found = true;
                    result.found_in_mempool += 1;
                    break;
                }
            }
        }

        if (!found) {
            result.missing_indices[result.missing_count] = @intCast(i);
            result.missing_count += 1;
        }
    }

    result.success = (result.missing_count == 0);
    return result;
}

/// GetBlockTxn message — request missing TX by index
pub const MsgGetBlockTxn = struct {
    block_hash: [32]u8,
    indices: [MAX_COMPACT_TX]u16,
    count: u16,

    pub fn encode(self: *const MsgGetBlockTxn) [32 + 2 + MAX_COMPACT_TX * 2]u8 {
        var buf = [_]u8{0} ** (32 + 2 + MAX_COMPACT_TX * 2);
        @memcpy(buf[0..32], &self.block_hash);
        std.mem.writeInt(u16, buf[32..34], self.count, .little);
        for (0..self.count) |i| {
            const offset = 34 + i * 2;
            std.mem.writeInt(u16, buf[offset..][0..2], self.indices[i], .little);
        }
        return buf;
    }
};

// ─── Tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

test "computeShortTxId — deterministic" {
    const tx_hash = [_]u8{0xAA} ** 32;
    const id1 = computeShortTxId(tx_hash, 42);
    const id2 = computeShortTxId(tx_hash, 42);
    try testing.expectEqualSlices(u8, &id1, &id2);
}

test "computeShortTxId — different nonce -> different ID" {
    const tx_hash = [_]u8{0xBB} ** 32;
    const id1 = computeShortTxId(tx_hash, 1);
    const id2 = computeShortTxId(tx_hash, 2);
    try testing.expect(!std.mem.eql(u8, &id1, &id2));
}

test "computeShortTxId — different TX hash -> different ID" {
    const id1 = computeShortTxId([_]u8{0x11} ** 32, 0);
    const id2 = computeShortTxId([_]u8{0x22} ** 32, 0);
    try testing.expect(!std.mem.eql(u8, &id1, &id2));
}

test "CompactBlock — size calculation" {
    var cb: CompactBlock = std.mem.zeroes(CompactBlock);
    cb.short_id_count = 100;
    cb.prefilled_count = 1;

    const compact_sz = cb.compactSize();
    const full_sz = cb.estimatedFullSize();
    // Compact should be much smaller than full
    try testing.expect(compact_sz < full_sz);
    // Savings should be >80%
    try testing.expect(cb.savingsPercent() >= 80);
}

test "CompactBlock — empty block" {
    var cb: CompactBlock = std.mem.zeroes(CompactBlock);
    cb.short_id_count = 0;
    try testing.expectEqual(@as(usize, 99), cb.compactSize()); // header(88) + nonce(8) + count(2) + pfcount(1)
}

test "reconstructFromMempool — all TX in mempool" {
    const nonce: u64 = 12345;
    const tx1 = [_]u8{0xAA} ** 32;
    const tx2 = [_]u8{0xBB} ** 32;

    var cb: CompactBlock = std.mem.zeroes(CompactBlock);
    cb.short_id_nonce = nonce;
    cb.short_ids[0] = computeShortTxId(tx1, nonce);
    cb.short_ids[1] = computeShortTxId(tx2, nonce);
    cb.short_id_count = 2;

    const mempool = [_][32]u8{ tx1, tx2 };
    const result = reconstructFromMempool(&cb, &mempool);

    try testing.expect(result.success);
    try testing.expectEqual(@as(u16, 2), result.found_in_mempool);
    try testing.expectEqual(@as(u16, 0), result.missing_count);
}

test "reconstructFromMempool — missing TX" {
    const nonce: u64 = 99;
    const tx1 = [_]u8{0xCC} ** 32;
    const tx2 = [_]u8{0xDD} ** 32;

    var cb: CompactBlock = std.mem.zeroes(CompactBlock);
    cb.short_id_nonce = nonce;
    cb.short_ids[0] = computeShortTxId(tx1, nonce);
    cb.short_ids[1] = computeShortTxId(tx2, nonce);
    cb.short_id_count = 2;

    // Only tx1 in mempool, tx2 missing
    const mempool = [_][32]u8{tx1};
    const result = reconstructFromMempool(&cb, &mempool);

    try testing.expect(!result.success);
    try testing.expectEqual(@as(u16, 1), result.found_in_mempool);
    try testing.expectEqual(@as(u16, 1), result.missing_count);
}

test "reconstructFromMempool — prefilled TX skipped" {
    const nonce: u64 = 0;
    const tx1 = [_]u8{0xEE} ** 32;

    var cb: CompactBlock = std.mem.zeroes(CompactBlock);
    cb.short_id_nonce = nonce;
    cb.short_ids[0] = computeShortTxId(tx1, nonce);
    cb.short_id_count = 1;
    // TX is prefilled (e.g., coinbase)
    cb.prefilled[0] = .{ .index = 0, .tx_hash = tx1, .tx_size = 100 };
    cb.prefilled_count = 1;

    // Empty mempool — but TX is prefilled, so should succeed
    const mempool = [_][32]u8{};
    const result = reconstructFromMempool(&cb, &mempool);

    try testing.expect(result.success);
    try testing.expectEqual(@as(u16, 0), result.missing_count);
}

test "bandwidth savings 1000 TX block" {
    var cb: CompactBlock = std.mem.zeroes(CompactBlock);
    cb.short_id_count = 1000;
    cb.prefilled_count = 1; // coinbase

    // Full block: ~250KB. Compact: ~6KB + header
    try testing.expect(cb.savingsPercent() >= 95);
}
