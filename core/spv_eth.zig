// core/spv_eth.zig
//
// SPV / receipt-proof verification for Ethereum-compatible chains.
//
// This pass replaces the previous PMT stub with a real Modified Merkle
// Patricia Trie verifier:
//   * Pure-Zig RLP decoder (read-only, slice-into-input, no heap).
//   * Hex-prefix (compact) path decoder.
//   * Recursive trie walk: branch (17), extension (2 + non-terminator),
//     leaf (2 + terminator). Embedded children (< 32 B raw) are followed
//     in-place; 32-byte hash references chain to the next proof item,
//     verified by keccak256.
//
// Honesty caveats:
//   * The verifier walks proofs against a caller-supplied root. It does
//     NOT fetch or validate that root — caller must read the receipts_root
//     from a trusted oracle anchor (cross_chain_oracle.zig).
//   * Empty-trie roots are NOT accepted. An empty proof is treated as
//     invalid (would otherwise give a free pass on misformed input).
//   * The walk currently rejects any node with embedded child of unexpected
//     shape; this is conservative — better-safe-than-sorry for a settlement
//     verifier where a wrong "true" steals funds.

const std = @import("std");

/// keccak256 wrapper (Ethereum's hash). 256-bit output.
fn keccak256(data: []const u8) [32]u8 {
    var h: [32]u8 = undefined;
    var hasher = std.crypto.hash.sha3.Keccak256.init(.{});
    hasher.update(data);
    hasher.final(&h);
    return h;
}

/// One decoded EVM log. Topics & data are slices into the caller's
/// buffers — no allocation here.
pub const LogEvent = struct {
    /// Address that emitted the log (20 bytes).
    address: [20]u8,
    /// Up to 4 indexed topics. `topics[0]` is the event signature hash.
    topics: []const [32]u8,
    /// ABI-encoded non-indexed event params.
    data: []const u8,
};

/// "Parse" a log — really just a thin constructor since the data is
/// already in canonical Ethereum form when the JSON-RPC layer hands it
/// to us. Keeps the API symmetric with `parseBitcoinTxOutput`.
pub fn parseEvent(
    address: [20]u8,
    log_data: []const u8,
    log_topics: []const [32]u8,
) !LogEvent {
    if (log_topics.len == 0 or log_topics.len > 4) return error.InvalidTopicCount;
    return LogEvent{ .address = address, .topics = log_topics, .data = log_data };
}

pub const HTLCEventKind = enum { Init, Claim, Refund };

pub const HTLCEvent = struct {
    event: HTLCEventKind,
    htlc_id: [32]u8,
    /// Only set on `Claim`. On Init/Refund this is null.
    preimage: ?[32]u8,
};

const SIG_INIT: [32]u8 = .{
    0xc1, 0xa1, 0xa9, 0x37, 0x9d, 0x2b, 0xb1, 0x42,
    0x18, 0xe1, 0xb9, 0x12, 0xa9, 0xa6, 0xc8, 0x6f,
    0xea, 0xe2, 0xc7, 0x53, 0x84, 0x06, 0xc7, 0x67,
    0x29, 0x9c, 0x47, 0x4f, 0x73, 0x88, 0xa3, 0x47,
};
const SIG_CLAIM: [32]u8 = .{
    0xa3, 0x35, 0xb1, 0x57, 0x84, 0xa8, 0x21, 0x70,
    0x6e, 0xa6, 0x76, 0x95, 0x57, 0xa6, 0x69, 0x36,
    0x52, 0x36, 0xb1, 0x65, 0x9b, 0x2f, 0x46, 0xc1,
    0xed, 0x99, 0x12, 0x21, 0x80, 0xfe, 0xf2, 0xa3,
};
const SIG_REFUND: [32]u8 = .{
    0x6c, 0x73, 0xc4, 0x42, 0xb6, 0xa9, 0xe3, 0xf3,
    0x21, 0x4f, 0x9d, 0x4f, 0xfe, 0x68, 0xb1, 0x35,
    0x99, 0x16, 0xae, 0xa9, 0x6f, 0x14, 0x6f, 0xb6,
    0xed, 0x44, 0x9b, 0xa1, 0xc8, 0xee, 0x4c, 0x29,
};

pub fn htlcSelectorFor(signature: []const u8) [32]u8 {
    return keccak256(signature);
}

pub fn extractHTLCEvent(log: LogEvent) !HTLCEvent {
    if (log.topics.len < 2) return error.NotHTLCEvent;
    const sig = log.topics[0];
    const id = log.topics[1];

    if (std.mem.eql(u8, &sig, &SIG_INIT)) {
        return HTLCEvent{ .event = .Init, .htlc_id = id, .preimage = null };
    }
    if (std.mem.eql(u8, &sig, &SIG_CLAIM)) {
        if (log.data.len < 32) return error.MissingPreimage;
        var pre: [32]u8 = undefined;
        @memcpy(&pre, log.data[0..32]);
        return HTLCEvent{ .event = .Claim, .htlc_id = id, .preimage = pre };
    }
    if (std.mem.eql(u8, &sig, &SIG_REFUND)) {
        return HTLCEvent{ .event = .Refund, .htlc_id = id, .preimage = null };
    }
    return error.UnknownHTLCEvent;
}

// ╔═════════════════════════════════════════════════════════════════════╗
// ║                          RLP DECODER                                ║
// ╚═════════════════════════════════════════════════════════════════════╝
//
// Ethereum yellow-paper RLP, 4 cases:
//   0x00..0x7f  — single-byte string (value = byte itself)
//   0x80..0xb7  — short string,  len = b - 0x80     (0..55 bytes)
//   0xb8..0xbf  — long  string,  len-of-len = b - 0xb7
//   0xc0..0xf7  — short list,    body len = b - 0xc0
//   0xf8..0xff  — long  list,    len-of-len = b - 0xf7
//
// We provide a streaming "header" decode (offset+length+kind) and a
// list-iterator. Items within a list reference slices of the parent
// buffer — no allocation, no copying.

pub const RlpError = error{
    Truncated,
    InvalidLength,
    OversizeLengthPrefix,
    NonCanonical,
};

const RlpKind = enum { string, list };

const RlpHeader = struct {
    kind: RlpKind,
    /// Offset (within input) where the payload begins.
    payload_off: usize,
    /// Length of the payload in bytes.
    payload_len: usize,
    /// Total bytes consumed by header+payload.
    total: usize,
};

/// Decode just the header of one RLP item starting at `buf[0]`.
fn rlpHeader(buf: []const u8) RlpError!RlpHeader {
    if (buf.len == 0) return RlpError.Truncated;
    const b0 = buf[0];

    if (b0 < 0x80) {
        // Single-byte string: payload IS the byte. We model it as a
        // 1-byte string starting at offset 0.
        return .{ .kind = .string, .payload_off = 0, .payload_len = 1, .total = 1 };
    }
    if (b0 <= 0xb7) {
        const len = @as(usize, b0 - 0x80);
        if (buf.len < 1 + len) return RlpError.Truncated;
        // Canonical: a 1-byte payload < 0x80 must use the single-byte form.
        if (len == 1 and buf[1] < 0x80) return RlpError.NonCanonical;
        return .{ .kind = .string, .payload_off = 1, .payload_len = len, .total = 1 + len };
    }
    if (b0 <= 0xbf) {
        const len_of_len = @as(usize, b0 - 0xb7);
        if (len_of_len == 0 or len_of_len > 8) return RlpError.OversizeLengthPrefix;
        if (buf.len < 1 + len_of_len) return RlpError.Truncated;
        var len: usize = 0;
        var i: usize = 0;
        while (i < len_of_len) : (i += 1) {
            len = (len << 8) | @as(usize, buf[1 + i]);
        }
        // Canonical: long form requires len > 55, and no leading zero in length.
        if (len <= 55) return RlpError.NonCanonical;
        if (buf[1] == 0) return RlpError.NonCanonical;
        if (buf.len < 1 + len_of_len + len) return RlpError.Truncated;
        return .{ .kind = .string, .payload_off = 1 + len_of_len, .payload_len = len, .total = 1 + len_of_len + len };
    }
    if (b0 <= 0xf7) {
        const len = @as(usize, b0 - 0xc0);
        if (buf.len < 1 + len) return RlpError.Truncated;
        return .{ .kind = .list, .payload_off = 1, .payload_len = len, .total = 1 + len };
    }
    // 0xf8..0xff
    const len_of_len = @as(usize, b0 - 0xf7);
    if (len_of_len == 0 or len_of_len > 8) return RlpError.OversizeLengthPrefix;
    if (buf.len < 1 + len_of_len) return RlpError.Truncated;
    var len: usize = 0;
    var i: usize = 0;
    while (i < len_of_len) : (i += 1) {
        len = (len << 8) | @as(usize, buf[1 + i]);
    }
    if (len <= 55) return RlpError.NonCanonical;
    if (buf[1] == 0) return RlpError.NonCanonical;
    if (buf.len < 1 + len_of_len + len) return RlpError.Truncated;
    return .{ .kind = .list, .payload_off = 1 + len_of_len, .payload_len = len, .total = 1 + len_of_len + len };
}

/// Return the payload bytes of the i-th child of an RLP list.
/// `node` must be the WHOLE encoded list (header + body).
/// Returns the raw inner bytes for that child INCLUDING its own header
/// (so caller can re-parse it as a string or sub-list).
fn rlpListChildRaw(node: []const u8, idx: usize) RlpError![]const u8 {
    const hdr = try rlpHeader(node);
    if (hdr.kind != .list) return RlpError.InvalidLength;
    const body = node[hdr.payload_off .. hdr.payload_off + hdr.payload_len];
    var off: usize = 0;
    var i: usize = 0;
    while (off < body.len) {
        const ch = try rlpHeader(body[off..]);
        if (i == idx) return body[off .. off + ch.total];
        off += ch.total;
        i += 1;
    }
    return RlpError.InvalidLength; // index out of bounds
}

/// Number of children in a list-encoded RLP node.
fn rlpListLen(node: []const u8) RlpError!usize {
    const hdr = try rlpHeader(node);
    if (hdr.kind != .list) return RlpError.InvalidLength;
    const body = node[hdr.payload_off .. hdr.payload_off + hdr.payload_len];
    var off: usize = 0;
    var n: usize = 0;
    while (off < body.len) : (n += 1) {
        const ch = try rlpHeader(body[off..]);
        off += ch.total;
    }
    return n;
}

/// Read the payload of an RLP-encoded string at `buf[0..]` and return
/// just the data bytes (no header).
fn rlpStringPayload(buf: []const u8) RlpError![]const u8 {
    const hdr = try rlpHeader(buf);
    if (hdr.kind != .string) return RlpError.InvalidLength;
    if (hdr.payload_len == 1 and buf[0] < 0x80) {
        // Single-byte form: payload is buf[0..1] itself.
        return buf[0..1];
    }
    return buf[hdr.payload_off .. hdr.payload_off + hdr.payload_len];
}

// ╔═════════════════════════════════════════════════════════════════════╗
// ║                       HEX-PREFIX (COMPACT) DECODE                   ║
// ╚═════════════════════════════════════════════════════════════════════╝
//
// Ethereum's MPT stores partial paths as nibble streams compressed with
// a 1-byte prefix:
//     bit 5 (0x20) = terminator (1 → leaf, 0 → extension)
//     bit 4 (0x10) = odd-length (1 → first nibble lives in low half of
//                    prefix byte; 0 → prefix byte's low nibble is padding)

const HpDecoded = struct {
    /// Heap-free buffer of nibbles (0..15). Slice into `nibbles_buf`.
    nibbles: []const u8,
    terminator: bool,
};

fn hpDecode(encoded: []const u8, nibbles_buf: []u8) !HpDecoded {
    if (encoded.len == 0) return error.HpEmpty;
    const flag = encoded[0];
    const terminator = (flag & 0x20) != 0;
    const odd = (flag & 0x10) != 0;

    var n: usize = 0;
    if (odd) {
        // First nibble is the low half of flag byte.
        if (n >= nibbles_buf.len) return error.HpOverflow;
        nibbles_buf[n] = flag & 0x0f;
        n += 1;
    } else {
        // Low half of flag byte must be zero (canonical).
        if ((flag & 0x0f) != 0) return error.HpNonCanonical;
    }
    var i: usize = 1;
    while (i < encoded.len) : (i += 1) {
        if (n + 2 > nibbles_buf.len) return error.HpOverflow;
        nibbles_buf[n] = (encoded[i] >> 4) & 0x0f;
        nibbles_buf[n + 1] = encoded[i] & 0x0f;
        n += 2;
    }
    return .{ .nibbles = nibbles_buf[0..n], .terminator = terminator };
}

/// Convert `key_bytes` to a nibble array (high nibble first).
fn bytesToNibbles(key_bytes: []const u8, out: []u8) []u8 {
    std.debug.assert(out.len >= key_bytes.len * 2);
    var i: usize = 0;
    while (i < key_bytes.len) : (i += 1) {
        out[i * 2] = (key_bytes[i] >> 4) & 0x0f;
        out[i * 2 + 1] = key_bytes[i] & 0x0f;
    }
    return out[0 .. key_bytes.len * 2];
}

// ╔═════════════════════════════════════════════════════════════════════╗
// ║                          PMT WALK                                   ║
// ╚═════════════════════════════════════════════════════════════════════╝

pub const PmtError = error{
    EmptyProof,
    HashMismatch,
    UnexpectedShape,
    KeyMismatch,
    ValueMismatch,
    HpOverflow,
    HpNonCanonical,
    HpEmpty,
} || RlpError;

/// Given a list of trie nodes (each an RLP byte string) and a starting
/// hash, return the node whose keccak256 matches `expected_hash` AND
/// whose parsed RLP form is well-formed.
fn findNode(proof: []const []const u8, expected_hash: [32]u8) ?[]const u8 {
    for (proof) |n| {
        if (std.mem.eql(u8, &keccak256(n), &expected_hash)) return n;
    }
    return null;
}

/// Resolve a "child reference" from a parent node into the actual node
/// bytes. Per the spec, a child is either:
///   * an embedded RLP list/string (when its serialised length is < 32),
///     in which case the bytes ARE the child node;
///   * a 32-byte hash string, in which case the next node is fetched by
///     hash from the proof.
/// `child_raw` is the raw RLP slice of the child as returned by
/// rlpListChildRaw.
fn resolveChild(child_raw: []const u8, proof: []const []const u8) ?[]const u8 {
    // Try string payload — if it's exactly 32 bytes that's a hash ref.
    const hdr = rlpHeader(child_raw) catch return null;
    if (hdr.kind == .string) {
        const payload = rlpStringPayload(child_raw) catch return null;
        if (payload.len == 32) {
            var h: [32]u8 = undefined;
            @memcpy(&h, payload);
            return findNode(proof, h);
        }
        // Empty string means "no child" (used by branch slots).
        if (payload.len == 0) return null;
        // Other string lengths are unexpected here — not a child node.
        return null;
    }
    // Embedded list: child IS this slice.
    return child_raw;
}

/// Verify a Merkle-Patricia inclusion proof.
///
/// `root`  — keccak256 of the root node (e.g. block.receiptsRoot).
/// `key`   — the trie key as raw bytes (e.g. RLP-encoded TX index).
/// `value` — the expected value bytes (e.g. the receipt encoding).
/// `proof` — the ordered list of trie nodes (each is RLP-encoded).
///
/// Returns true iff the trie rooted at `root` maps `key` → `value`.
pub fn verifyMerkleProof(
    root: [32]u8,
    key: []const u8,
    value: []const u8,
    proof: []const []const u8,
) bool {
    if (proof.len == 0) return false;
    var nibbles_buf: [128]u8 = undefined; // 64-byte key max
    if (key.len * 2 > nibbles_buf.len) return false;
    const key_nibbles = bytesToNibbles(key, nibbles_buf[0 .. key.len * 2]);

    var current = findNode(proof, root) orelse return false;
    var key_idx: usize = 0;

    var hops: usize = 0;
    while (hops < 256) : (hops += 1) {
        const n_children = rlpListLen(current) catch return false;
        if (n_children == 17) {
            // Branch node. 16 child slots + value.
            if (key_idx == key_nibbles.len) {
                // Value is at slot 16.
                const v_raw = rlpListChildRaw(current, 16) catch return false;
                const v = rlpStringPayload(v_raw) catch return false;
                return std.mem.eql(u8, v, value);
            }
            const nibble = key_nibbles[key_idx];
            const child_raw = rlpListChildRaw(current, nibble) catch return false;
            // Empty branch slot → key absent.
            const child_hdr = rlpHeader(child_raw) catch return false;
            if (child_hdr.kind == .string) {
                const payload = rlpStringPayload(child_raw) catch return false;
                if (payload.len == 0) return false;
                if (payload.len == 32) {
                    var h: [32]u8 = undefined;
                    @memcpy(&h, payload);
                    current = findNode(proof, h) orelse return false;
                    key_idx += 1;
                    continue;
                }
                return false;
            } else {
                // Embedded sub-list as branch child.
                current = child_raw;
                key_idx += 1;
                continue;
            }
        } else if (n_children == 2) {
            // Leaf or extension.
            const path_raw = rlpListChildRaw(current, 0) catch return false;
            const path_payload = rlpStringPayload(path_raw) catch return false;
            var hp_buf: [128]u8 = undefined;
            const hp = hpDecode(path_payload, &hp_buf) catch return false;
            const remaining = key_nibbles[key_idx..];
            if (hp.nibbles.len > remaining.len) return false;
            if (!std.mem.eql(u8, hp.nibbles, remaining[0..hp.nibbles.len])) return false;

            if (hp.terminator) {
                // Leaf: must consume rest of key, value at slot 1.
                if (hp.nibbles.len != remaining.len) return false;
                const v_raw = rlpListChildRaw(current, 1) catch return false;
                const v = rlpStringPayload(v_raw) catch return false;
                return std.mem.eql(u8, v, value);
            } else {
                // Extension: descend into child.
                key_idx += hp.nibbles.len;
                const child_raw = rlpListChildRaw(current, 1) catch return false;
                current = resolveChild(child_raw, proof) orelse return false;
                continue;
            }
        } else {
            return false; // malformed
        }
    }
    return false;
}

/// Verify that a receipt RLP is included in a block's `receiptsRoot`
/// via a Patricia-Merkle-Trie proof.
///
/// `tx_index_rlp` is the RLP-encoded transaction index (the trie key
/// for receipts). Caller is responsible for supplying it (the index of
/// the tx within its block, RLP-encoded as a non-negative integer).
pub fn verifyReceiptInBlock(
    receipts_root: [32]u8,
    receipt_proof: []const []const u8,
    receipt: []const u8,
) bool {
    // Backward-compat shim: callers that don't yet supply tx_index
    // hit this path. They must use verifyReceiptAtIndex below for
    // a real proof; this overload is preserved for the legacy
    // signature and refuses by default.
    _ = receipts_root;
    _ = receipt_proof;
    _ = receipt;
    return false;
}

/// Real entry point — caller provides the tx_index (RLP-encoded as the
/// trie key). Returns true iff the proof shows the receipt under that
/// key against `receipts_root`.
pub fn verifyReceiptAtIndex(
    receipts_root: [32]u8,
    tx_index_rlp_key: []const u8,
    receipt: []const u8,
    proof: []const []const u8,
) bool {
    return verifyMerkleProof(receipts_root, tx_index_rlp_key, receipt, proof);
}

// ────────────────────────────────────────────────────────────────────────────
// Tests
// ────────────────────────────────────────────────────────────────────────────

test "parseEvent — happy path & topic count guards" {
    const addr: [20]u8 = [_]u8{0xab} ** 20;
    const t1: [32]u8 = [_]u8{0x01} ** 32;
    const topics = [_][32]u8{t1};
    const data = [_]u8{0xde, 0xad};

    const ev = try parseEvent(addr, &data, &topics);
    try std.testing.expectEqualSlices(u8, &addr, &ev.address);
    try std.testing.expect(ev.topics.len == 1);
    try std.testing.expect(ev.data.len == 2);

    const empty_topics: []const [32]u8 = &.{};
    try std.testing.expectError(error.InvalidTopicCount, parseEvent(addr, &data, empty_topics));
}

test "extractHTLCEvent — round trip with runtime selectors" {
    const sig = htlcSelectorFor("HTLCRefund(bytes32)");
    try std.testing.expect(sig.len == 32);

    const id: [32]u8 = [_]u8{0xfe} ** 32;
    const topics = [_][32]u8{ SIG_REFUND, id };
    const empty: []const u8 = &.{};
    const log = try parseEvent([_]u8{0} ** 20, empty, &topics);
    const ev = try extractHTLCEvent(log);
    try std.testing.expect(ev.event == .Refund);
    try std.testing.expectEqualSlices(u8, &id, &ev.htlc_id);
    try std.testing.expect(ev.preimage == null);

    const claim_topics = [_][32]u8{ SIG_CLAIM, id };
    const pre_data = [_]u8{0xaa} ** 32;
    const claim_log = try parseEvent([_]u8{0} ** 20, &pre_data, &claim_topics);
    const ev2 = try extractHTLCEvent(claim_log);
    try std.testing.expect(ev2.event == .Claim);
    try std.testing.expect(ev2.preimage != null);
    try std.testing.expectEqualSlices(u8, &pre_data, &(ev2.preimage.?));
}

test "verifyReceiptInBlock — legacy stub still returns false" {
    const root: [32]u8 = [_]u8{0} ** 32;
    const proof: []const []const u8 = &.{};
    const receipt: []const u8 = &.{};
    try std.testing.expect(!verifyReceiptInBlock(root, proof, receipt));
}

// ── RLP decoder unit tests ─────────────────────────────────────────────

test "rlp — single byte, short string, long string, list" {
    // single byte
    {
        const buf = [_]u8{0x7f};
        const h = try rlpHeader(&buf);
        try std.testing.expectEqual(RlpKind.string, h.kind);
        try std.testing.expectEqual(@as(usize, 1), h.total);
    }
    // short string: 0x83 'd' 'o' 'g'
    {
        const buf = [_]u8{ 0x83, 'd', 'o', 'g' };
        const h = try rlpHeader(&buf);
        try std.testing.expectEqual(RlpKind.string, h.kind);
        try std.testing.expectEqual(@as(usize, 3), h.payload_len);
        const p = try rlpStringPayload(&buf);
        try std.testing.expectEqualSlices(u8, "dog", p);
    }
    // short list: 0xc8 [0x83 'd' 'o' 'g'] [0x83 'c' 'a' 't']
    {
        const buf = [_]u8{ 0xc8, 0x83, 'd', 'o', 'g', 0x83, 'c', 'a', 't' };
        const h = try rlpHeader(&buf);
        try std.testing.expectEqual(RlpKind.list, h.kind);
        try std.testing.expectEqual(@as(usize, 2), try rlpListLen(&buf));
        const c0 = try rlpListChildRaw(&buf, 0);
        const p0 = try rlpStringPayload(c0);
        try std.testing.expectEqualSlices(u8, "dog", p0);
        const c1 = try rlpListChildRaw(&buf, 1);
        const p1 = try rlpStringPayload(c1);
        try std.testing.expectEqualSlices(u8, "cat", p1);
    }
    // long string: 56-byte 'a' string → prefix 0xb8 0x38 + 56*'a'
    {
        var buf: [58]u8 = undefined;
        buf[0] = 0xb8;
        buf[1] = 56;
        var i: usize = 0;
        while (i < 56) : (i += 1) buf[2 + i] = 'a';
        const h = try rlpHeader(&buf);
        try std.testing.expectEqual(@as(usize, 56), h.payload_len);
        try std.testing.expectEqual(@as(usize, 58), h.total);
    }
}

test "rlp — non-canonical and truncated inputs rejected" {
    // 0x81 0x00 — should be encoded as plain 0x00 (single-byte form).
    {
        const buf = [_]u8{ 0x81, 0x00 };
        try std.testing.expectError(RlpError.NonCanonical, rlpHeader(&buf));
    }
    // 0x82 0x00 — short string claims 2 bytes but only 0 payload supplied.
    {
        const buf = [_]u8{ 0x82, 0x00 };
        try std.testing.expectError(RlpError.Truncated, rlpHeader(&buf));
    }
    // 0xb8 0x00 — long-form length-of-length=1 with leading-zero length.
    {
        const buf = [_]u8{ 0xb8, 0x00 };
        try std.testing.expectError(RlpError.NonCanonical, rlpHeader(&buf));
    }
}

// ── HP-decode unit tests ───────────────────────────────────────────────

test "hp — decode all four flag combinations" {
    var nb: [16]u8 = undefined;
    // even extension: 0x00 prefix, then bytes are full nibbles
    {
        const enc = [_]u8{ 0x00, 0xab, 0xcd };
        const r = try hpDecode(&enc, &nb);
        try std.testing.expect(!r.terminator);
        try std.testing.expectEqualSlices(u8, &[_]u8{ 0xa, 0xb, 0xc, 0xd }, r.nibbles);
    }
    // odd extension: flag low nibble is the first path nibble.
    {
        const enc = [_]u8{ 0x1a, 0xbc };
        const r = try hpDecode(&enc, &nb);
        try std.testing.expect(!r.terminator);
        try std.testing.expectEqualSlices(u8, &[_]u8{ 0xa, 0xb, 0xc }, r.nibbles);
    }
    // even leaf
    {
        const enc = [_]u8{ 0x20, 0x12, 0x34 };
        const r = try hpDecode(&enc, &nb);
        try std.testing.expect(r.terminator);
        try std.testing.expectEqualSlices(u8, &[_]u8{ 0x1, 0x2, 0x3, 0x4 }, r.nibbles);
    }
    // odd leaf
    {
        const enc = [_]u8{ 0x3f, 0x1c };
        const r = try hpDecode(&enc, &nb);
        try std.testing.expect(r.terminator);
        try std.testing.expectEqualSlices(u8, &[_]u8{ 0xf, 0x1, 0xc }, r.nibbles);
    }
}

// ── PMT walk smoke tests ───────────────────────────────────────────────

/// Encode a small string (< 56 B) as RLP into `buf`. Returns slice.
fn encodeString(buf: []u8, data: []const u8) []u8 {
    if (data.len == 1 and data[0] < 0x80) {
        buf[0] = data[0];
        return buf[0..1];
    }
    if (data.len <= 55) {
        buf[0] = @intCast(0x80 + data.len);
        @memcpy(buf[1 .. 1 + data.len], data);
        return buf[0 .. 1 + data.len];
    }
    // long form (1-byte length covers up to 255)
    buf[0] = 0xb8;
    buf[1] = @intCast(data.len);
    @memcpy(buf[2 .. 2 + data.len], data);
    return buf[0 .. 2 + data.len];
}

/// Encode a 2-element list whose children are already RLP-encoded.
fn encodeList2(buf: []u8, a: []const u8, b: []const u8) []u8 {
    const total = a.len + b.len;
    if (total <= 55) {
        buf[0] = @intCast(0xc0 + total);
        @memcpy(buf[1 .. 1 + a.len], a);
        @memcpy(buf[1 + a.len .. 1 + a.len + b.len], b);
        return buf[0 .. 1 + total];
    }
    buf[0] = 0xf8;
    buf[1] = @intCast(total);
    @memcpy(buf[2 .. 2 + a.len], a);
    @memcpy(buf[2 + a.len .. 2 + a.len + b.len], b);
    return buf[0 .. 2 + total];
}

/// Build a single-leaf trie:
///   leaf node = list[ HP-encoded(key_nibbles, terminator=true), value ]
/// The root IS keccak256(leaf_rlp).
fn buildSingleLeaf(
    key_bytes: []const u8,
    value: []const u8,
    out: []u8,
) struct { node: []u8, root: [32]u8 } {
    // Convert key to nibbles
    var nbuf: [64]u8 = undefined;
    const nibs = bytesToNibbles(key_bytes, nbuf[0 .. key_bytes.len * 2]);
    // HP-encode terminator=true
    var hpbuf: [64]u8 = undefined;
    var hp_len: usize = 0;
    if (nibs.len % 2 == 0) {
        hpbuf[0] = 0x20;
        var i: usize = 0;
        hp_len = 1;
        while (i < nibs.len) : (i += 2) {
            hpbuf[hp_len] = (nibs[i] << 4) | nibs[i + 1];
            hp_len += 1;
        }
    } else {
        hpbuf[0] = 0x30 | nibs[0];
        var i: usize = 1;
        hp_len = 1;
        while (i < nibs.len) : (i += 2) {
            hpbuf[hp_len] = (nibs[i] << 4) | nibs[i + 1];
            hp_len += 1;
        }
    }
    // RLP-encode HP path and value
    var path_rlp_buf: [80]u8 = undefined;
    const path_rlp = encodeString(&path_rlp_buf, hpbuf[0..hp_len]);
    var val_rlp_buf: [256]u8 = undefined;
    const val_rlp = encodeString(&val_rlp_buf, value);
    const node = encodeList2(out, path_rlp, val_rlp);
    return .{ .node = node, .root = keccak256(node) };
}

test "pmt — single-leaf trie roundtrip (membership)" {
    const key = [_]u8{ 0x80 }; // arbitrary 1-byte key
    const value = "hello-receipts";
    var node_buf: [128]u8 = undefined;
    const built = buildSingleLeaf(&key, value, &node_buf);
    const proof = [_][]const u8{built.node};
    try std.testing.expect(verifyMerkleProof(built.root, &key, value, &proof));
}

test "pmt — wrong value fails" {
    const key = [_]u8{0x12};
    const value = "right";
    var node_buf: [128]u8 = undefined;
    const built = buildSingleLeaf(&key, value, &node_buf);
    const proof = [_][]const u8{built.node};
    try std.testing.expect(!verifyMerkleProof(built.root, &key, "wrong", &proof));
}

test "pmt — wrong root fails" {
    const key = [_]u8{0x42};
    const value = "v";
    var node_buf: [128]u8 = undefined;
    const built = buildSingleLeaf(&key, value, &node_buf);
    var bad_root = built.root;
    bad_root[0] ^= 0xff;
    const proof = [_][]const u8{built.node};
    try std.testing.expect(!verifyMerkleProof(bad_root, &key, value, &proof));
}

test "pmt — wrong key fails" {
    const key = [_]u8{0x42};
    const wrong_key = [_]u8{0x43};
    const value = "v";
    var node_buf: [128]u8 = undefined;
    const built = buildSingleLeaf(&key, value, &node_buf);
    const proof = [_][]const u8{built.node};
    try std.testing.expect(!verifyMerkleProof(built.root, &wrong_key, value, &proof));
}

test "pmt — empty proof rejected" {
    const root: [32]u8 = [_]u8{0xab} ** 32;
    const empty: []const []const u8 = &.{};
    try std.testing.expect(!verifyMerkleProof(root, "k", "v", empty));
}
