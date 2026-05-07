// core/spv_btc.zig
//
// Simplified Payment Verification (SPV) for Bitcoin.
//
// Lets an Omnibus validator confirm that a Bitcoin transaction was
// included in a block — without trusting an oracle. The validator only
// needs:
//   1. The Bitcoin block headers (kept fresh via `BtcHeaderChain`)
//   2. A Merkle inclusion proof for the transaction
//   3. (Optional) the raw transaction to inspect outputs / witness data
//
// Constraints (bare-metal-compatible):
//   * No heap allocation after init — fixed `BtcHeaderChain` ring buffer.
//   * No floating-point.
//   * All hashing through std.crypto.hash (SHA-256 double).
//
// References:
//   * Bitcoin block header format (80 bytes, little-endian):
//       version(4) | prev_block(32) | merkle_root(32) | time(4) | bits(4) | nonce(4)
//   * Merkle proofs use double-SHA-256 at each level.
//   * Compact-target ("nBits") expansion: BIP-0030 / pow.cpp.

const std = @import("std");

/// SHA-256 single round.
fn sha256(data: []const u8) [32]u8 {
    var h: [32]u8 = undefined;
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(data);
    hasher.final(&h);
    return h;
}

/// Bitcoin's double SHA-256.
fn sha256d(data: []const u8) [32]u8 {
    const a = sha256(data);
    return sha256(&a);
}

/// Hash two 32-byte halves together, producing one Merkle parent.
/// Bitcoin Merkle trees use double-SHA-256 over the concatenated halves.
fn hashPair(left: [32]u8, right: [32]u8) [32]u8 {
    var buf: [64]u8 = undefined;
    @memcpy(buf[0..32], &left);
    @memcpy(buf[32..64], &right);
    return sha256d(&buf);
}

/// Verify a Bitcoin Merkle inclusion proof.
///
/// Parameters:
///   tx_hash      — the leaf TX hash (already in internal byte order, NOT
///                  the human-readable big-endian txid).
///   merkle_path  — the sibling hashes along the path from leaf to root.
///   indices      — for each level, 0 = sibling is on the right (we are
///                  the LEFT child), 1 = sibling is on the left (we are
///                  the RIGHT child). Must be the same length as
///                  `merkle_path`.
///   merkle_root  — the expected Merkle root from the block header.
pub fn verifyMerkleProof(
    tx_hash: [32]u8,
    merkle_path: []const [32]u8,
    indices: []const u1,
    merkle_root: [32]u8,
) bool {
    if (merkle_path.len != indices.len) return false;
    var current = tx_hash;
    var i: usize = 0;
    while (i < merkle_path.len) : (i += 1) {
        const sibling = merkle_path[i];
        if (indices[i] == 0) {
            // we are the left child
            current = hashPair(current, sibling);
        } else {
            // we are the right child
            current = hashPair(sibling, current);
        }
    }
    return std.mem.eql(u8, &current, &merkle_root);
}

/// Expand Bitcoin's compact "nBits" representation into a 256-bit target.
/// Layout: 1 exponent byte + 3 mantissa bytes (big-endian).
fn expandTarget(nbits: u32) [32]u8 {
    var target: [32]u8 = [_]u8{0} ** 32;
    const exp: u32 = (nbits >> 24) & 0xff;
    const mantissa: u32 = nbits & 0x00ffffff;
    if (exp == 0 or mantissa == 0) return target;
    if (exp <= 3) {
        // mantissa is shifted right
        const shift: u5 = @intCast(8 * (3 - exp));
        const v = mantissa >> shift;
        // place into the last 4 bytes (big-endian)
        target[29] = @intCast((v >> 16) & 0xff);
        target[30] = @intCast((v >> 8) & 0xff);
        target[31] = @intCast(v & 0xff);
        return target;
    }
    // place mantissa at byte position (32 - exp)
    const start: usize = 32 - @as(usize, exp);
    if (start + 3 > 32) return target;
    target[start] = @intCast((mantissa >> 16) & 0xff);
    target[start + 1] = @intCast((mantissa >> 8) & 0xff);
    target[start + 2] = @intCast(mantissa & 0xff);
    return target;
}

/// Compare 256-bit big-endian numbers represented as [32]u8 (a < b).
fn beLess(a: [32]u8, b: [32]u8) bool {
    var i: usize = 0;
    while (i < 32) : (i += 1) {
        if (a[i] < b[i]) return true;
        if (a[i] > b[i]) return false;
    }
    return false;
}

/// Verify that a Bitcoin block header:
///   1. Matches its expected hash (sanity check from caller).
///   2. Links to the expected previous-block hash.
///   3. Satisfies the embedded PoW target (`bits` field) — i.e. the
///      header's double-SHA-256 is below the expanded target.
///
/// `expected_hash` and `prev_hash` are in INTERNAL byte order
/// (little-endian on the wire — exactly what `sha256d` emits).
/// Pass `target = [_]u8{0}**32` to skip the explicit-target comparison
/// (it will fall back to the header's own `bits`).
pub fn verifyBlockHeader(
    header: [80]u8,
    expected_hash: [32]u8,
    prev_hash: [32]u8,
    target: [32]u8,
) bool {
    // 1. prev-block link: header[4..36]
    var prev_in_header: [32]u8 = undefined;
    @memcpy(&prev_in_header, header[4..36]);
    if (!std.mem.eql(u8, &prev_in_header, &prev_hash)) return false;

    // 2. own hash
    const own_hash = sha256d(&header);
    if (!std.mem.eql(u8, &own_hash, &expected_hash)) return false;

    // 3. PoW: hash (interpreted big-endian) < target
    // Bitcoin headers store hash little-endian; target comparison is
    // against the BIG-ENDIAN representation. Reverse `own_hash`.
    var own_be: [32]u8 = undefined;
    var i: usize = 0;
    while (i < 32) : (i += 1) own_be[i] = own_hash[31 - i];

    // Pick the explicit target if non-zero, else expand from header's nBits.
    const all_zero = blk: {
        var any: bool = false;
        for (target) |b| if (b != 0) { any = true; break; };
        break :blk !any;
    };
    var effective_target: [32]u8 = target;
    if (all_zero) {
        const nbits = std.mem.readInt(u32, header[72..76], .little);
        effective_target = expandTarget(nbits);
    }
    return beLess(own_be, effective_target);
}

/// Read a Bitcoin VarInt. Returns (value, bytes_consumed).
fn readVarInt(data: []const u8) !struct { value: u64, n: usize } {
    if (data.len == 0) return error.Truncated;
    const first = data[0];
    if (first < 0xfd) return .{ .value = first, .n = 1 };
    if (first == 0xfd) {
        if (data.len < 3) return error.Truncated;
        return .{ .value = std.mem.readInt(u16, data[1..3], .little), .n = 3 };
    }
    if (first == 0xfe) {
        if (data.len < 5) return error.Truncated;
        return .{ .value = std.mem.readInt(u32, data[1..5], .little), .n = 5 };
    }
    // 0xff: 8-byte
    if (data.len < 9) return error.Truncated;
    return .{ .value = std.mem.readInt(u64, data[1..9], .little), .n = 9 };
}

pub const TxOutput = struct {
    value: u64,
    script: []const u8,
};

/// Parse a Bitcoin raw transaction and return a specific output.
/// Supports both legacy and SegWit (BIP-141) serialisations.
///
/// IMPORTANT: the returned `script` slice points into `raw_tx` —
/// caller must not free `raw_tx` while using it.
pub fn parseBitcoinTxOutput(raw_tx: []const u8, output_index: u32) !TxOutput {
    if (raw_tx.len < 10) return error.Truncated;
    var p: usize = 4; // skip version

    // SegWit marker+flag detection
    var is_segwit = false;
    if (raw_tx.len >= 6 and raw_tx[4] == 0x00 and raw_tx[5] == 0x01) {
        is_segwit = true;
        p = 6;
    }

    // input count
    const ic = try readVarInt(raw_tx[p..]);
    p += ic.n;
    var i: u64 = 0;
    while (i < ic.value) : (i += 1) {
        // 32-byte prev tx + 4-byte vout
        if (p + 36 > raw_tx.len) return error.Truncated;
        p += 36;
        const sl = try readVarInt(raw_tx[p..]);
        p += sl.n + sl.value;
        // sequence (4 bytes)
        if (p + 4 > raw_tx.len) return error.Truncated;
        p += 4;
    }

    // output count
    const oc = try readVarInt(raw_tx[p..]);
    p += oc.n;
    if (output_index >= oc.value) return error.OutputIndexOutOfRange;
    var j: u64 = 0;
    while (j < oc.value) : (j += 1) {
        if (p + 8 > raw_tx.len) return error.Truncated;
        const value = std.mem.readInt(u64, raw_tx[p..][0..8], .little);
        p += 8;
        const sl = try readVarInt(raw_tx[p..]);
        p += sl.n;
        if (p + sl.value > raw_tx.len) return error.Truncated;
        const script = raw_tx[p .. p + sl.value];
        p += sl.value;
        if (j == output_index) {
            return TxOutput{ .value = value, .script = script };
        }
    }
    unreachable;
}

/// Extract the preimage that an HTLC claim transaction reveals.
///
/// Strategy:
///   * For SegWit P2WSH HTLCs the preimage is the second-to-last witness
///     element (last is the redeemScript). We return the first 32-byte
///     witness item that occurs before the redeem-script slot.
///   * For pre-SegWit HTLCs the preimage is pushed into the scriptSig of
///     the claiming input, which is more complex to parse — caller must
///     pass the input index. This minimal version only supports the
///     SegWit case (which is what `core/htlc_btc.zig` produces).
///
/// Returns a slice into `claim_tx` — do not free `claim_tx` while using.
pub fn extractClaimPreimage(claim_tx: []const u8, htlc_input_index: u32) ![]const u8 {
    if (claim_tx.len < 6) return error.Truncated;
    if (!(claim_tx[4] == 0x00 and claim_tx[5] == 0x01)) return error.NotSegWit;

    var p: usize = 6;
    const ic = try readVarInt(claim_tx[p..]);
    p += ic.n;
    if (htlc_input_index >= ic.value) return error.InputIndexOutOfRange;

    // Skip all the inputs (we only care about positions for the witness).
    var i: u64 = 0;
    while (i < ic.value) : (i += 1) {
        if (p + 36 > claim_tx.len) return error.Truncated;
        p += 36;
        const sl = try readVarInt(claim_tx[p..]);
        p += sl.n + sl.value;
        if (p + 4 > claim_tx.len) return error.Truncated;
        p += 4;
    }

    // Skip outputs.
    const oc = try readVarInt(claim_tx[p..]);
    p += oc.n;
    var j: u64 = 0;
    while (j < oc.value) : (j += 1) {
        if (p + 8 > claim_tx.len) return error.Truncated;
        p += 8;
        const sl = try readVarInt(claim_tx[p..]);
        p += sl.n + sl.value;
    }

    // Now we are at the witness section. One witness per input, in order.
    var input_idx: u64 = 0;
    while (input_idx <= htlc_input_index) : (input_idx += 1) {
        const wc = try readVarInt(claim_tx[p..]);
        p += wc.n;
        // Collect the items so we can pick the second-to-last for the target input.
        var stack_starts: [16]usize = undefined;
        var stack_lens: [16]usize = undefined;
        var stack_n: usize = 0;
        var k: u64 = 0;
        while (k < wc.value) : (k += 1) {
            const sl = try readVarInt(claim_tx[p..]);
            p += sl.n;
            const start = p;
            const len = sl.value;
            if (p + len > claim_tx.len) return error.Truncated;
            p += len;
            if (input_idx == htlc_input_index and stack_n < stack_starts.len) {
                stack_starts[stack_n] = start;
                stack_lens[stack_n] = len;
                stack_n += 1;
            }
        }
        if (input_idx == htlc_input_index) {
            if (stack_n < 2) return error.WitnessTooShort;
            // The redeemScript is the last item; the preimage is the
            // SECOND-TO-LAST item in a standard HTLC claim witness:
            //   [signature, preimage, redeemScript]
            // (For an HTLC with multiple sig branches there may be more
            // items — we still pick the slot just before the script.)
            const idx = stack_n - 2;
            return claim_tx[stack_starts[idx] .. stack_starts[idx] + stack_lens[idx]];
        }
    }
    return error.NotFound;
}

// ────────────────────────────────────────────────────────────────────────────
// BtcHeaderChain — last N headers cache
// ────────────────────────────────────────────────────────────────────────────

/// Standard Bitcoin retarget interval. Keeping exactly this many headers
/// in memory lets a node walk back to the previous retarget boundary
/// without ever hitting disk — which is what we need for SPV proof
/// validation against a moving tip.
pub const HEADER_CHAIN_CAP: usize = 2016;

pub const BtcHeader = struct {
    height: u32,
    hash: [32]u8,
    raw: [80]u8,
};

/// Ring buffer of the last `HEADER_CHAIN_CAP` Bitcoin headers.
/// Validators call `appendHeader` whenever their external Bitcoin RPC
/// reports a new tip; SPV proofs are then resolved against this cache.
pub const BtcHeaderChain = struct {
    buf: [HEADER_CHAIN_CAP]BtcHeader = undefined,
    /// Index of the next slot to write (modulo cap). When `count <
    /// cap`, slots [0..count) are valid; afterwards, the ring is full
    /// and the oldest entry is at `head`.
    head: usize = 0,
    count: usize = 0,
    /// Current tip height — kept explicit to avoid scanning for max.
    tip_height: u32 = 0,
    /// Tip hash — short-circuits `latestHash()`.
    tip_hash: [32]u8 = [_]u8{0} ** 32,

    pub fn init() BtcHeaderChain {
        return .{};
    }

    /// Append a header. Caller is responsible for verifying it via
    /// `verifyBlockHeader` BEFORE calling this. We do enforce monotonic
    /// height (no rewinds, no gaps) so a malicious feeder can't poison
    /// the cache with reordered data.
    pub fn appendHeader(self: *BtcHeaderChain, h: BtcHeader) !void {
        if (self.count > 0 and h.height != self.tip_height + 1) {
            return error.NonContiguous;
        }
        self.buf[self.head] = h;
        self.head = (self.head + 1) % HEADER_CHAIN_CAP;
        if (self.count < HEADER_CHAIN_CAP) self.count += 1;
        self.tip_height = h.height;
        self.tip_hash = h.hash;
    }

    /// Look up a header by height. Returns null if it has been evicted
    /// or never seen.
    pub fn getByHeight(self: *const BtcHeaderChain, height: u32) ?BtcHeader {
        if (self.count == 0) return null;
        if (height > self.tip_height) return null;
        const oldest_height: u32 = if (self.count < HEADER_CHAIN_CAP)
            self.tip_height + 1 - @as(u32, @intCast(self.count))
        else
            self.tip_height + 1 - @as(u32, HEADER_CHAIN_CAP);
        if (height < oldest_height) return null;

        // Position in ring: relative offset from oldest.
        const offset = height - oldest_height;
        const oldest_idx: usize = if (self.count < HEADER_CHAIN_CAP)
            0
        else
            self.head; // when full, head == oldest
        const idx = (oldest_idx + offset) % HEADER_CHAIN_CAP;
        return self.buf[idx];
    }

    pub fn latestHash(self: *const BtcHeaderChain) ?[32]u8 {
        if (self.count == 0) return null;
        return self.tip_hash;
    }
};

// ────────────────────────────────────────────────────────────────────────────
// Tests
// ────────────────────────────────────────────────────────────────────────────

test "merkle proof — known good leaf with one sibling" {
    // Build a tiny tree: H(L|R) = root.
    const left: [32]u8 = [_]u8{1} ** 32;
    const right: [32]u8 = [_]u8{2} ** 32;
    const root = hashPair(left, right);

    // Prove `left` is in the tree: sibling is `right`, we are LEFT (idx=0).
    const path = [_][32]u8{right};
    const idx = [_]u1{0};
    try std.testing.expect(verifyMerkleProof(left, &path, &idx, root));

    // Prove `right` (we are RIGHT, idx=1).
    const idx_r = [_]u1{1};
    const path_r = [_][32]u8{left};
    try std.testing.expect(verifyMerkleProof(right, &path_r, &idx_r, root));
}

test "merkle proof — tampered proof rejected" {
    const left: [32]u8 = [_]u8{1} ** 32;
    const right: [32]u8 = [_]u8{2} ** 32;
    const root = hashPair(left, right);

    // Wrong sibling.
    const bad_sibling: [32]u8 = [_]u8{0xff} ** 32;
    const path = [_][32]u8{bad_sibling};
    const idx = [_]u1{0};
    try std.testing.expect(!verifyMerkleProof(left, &path, &idx, root));

    // Wrong index (claim we're right when we are left).
    const path2 = [_][32]u8{right};
    const idx2 = [_]u1{1};
    try std.testing.expect(!verifyMerkleProof(left, &path2, &idx2, root));
}

test "header chain — append + lookup + latestHash" {
    var chain = BtcHeaderChain.init();
    try std.testing.expect(chain.latestHash() == null);

    const h1: BtcHeader = .{ .height = 100, .hash = [_]u8{0xaa} ** 32, .raw = [_]u8{0} ** 80 };
    try chain.appendHeader(h1);
    try std.testing.expect(chain.tip_height == 100);

    const h2: BtcHeader = .{ .height = 101, .hash = [_]u8{0xbb} ** 32, .raw = [_]u8{0} ** 80 };
    try chain.appendHeader(h2);

    // Out-of-order rejected.
    const h_bad: BtcHeader = .{ .height = 105, .hash = [_]u8{0xcc} ** 32, .raw = [_]u8{0} ** 80 };
    try std.testing.expectError(error.NonContiguous, chain.appendHeader(h_bad));

    const got = chain.getByHeight(100) orelse return error.TestFailed;
    try std.testing.expectEqualSlices(u8, &h1.hash, &got.hash);
    try std.testing.expect(chain.getByHeight(99) == null);
    try std.testing.expect(chain.getByHeight(102) == null);
}

test "expandTarget — sanity for known nBits" {
    // nBits 0x1d00ffff => standard genesis difficulty 1 target.
    // Mantissa = 0x00ffff, exp = 0x1d (29). Place mantissa at byte (32-29)=3.
    const t = expandTarget(0x1d00ffff);
    try std.testing.expectEqual(@as(u8, 0x00), t[3]);
    try std.testing.expectEqual(@as(u8, 0xff), t[4]);
    try std.testing.expectEqual(@as(u8, 0xff), t[5]);
    try std.testing.expectEqual(@as(u8, 0x00), t[6]);
    try std.testing.expectEqual(@as(u8, 0x00), t[0]);
}
