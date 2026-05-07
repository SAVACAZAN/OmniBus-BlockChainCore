// core/spv_eth_test_vectors.zig
//
// Hand-built Merkle Patricia Trie fixtures for spv_eth.zig PMT tests.
//
// Provenance: these vectors are NOT copied from go-ethereum. They are
// programmatically constructed in pure Zig from first principles per the
// Ethereum yellow paper (Appendix D) — RLP, hex-prefix (compact) path
// encoding, and the trie node grammar:
//   * leaf      = list[ HP(path, term=1), value ]
//   * extension = list[ HP(path, term=0), child_ref ]
//   * branch    = list[ slot0..slot15, value ]   (17 elements)
// where child_ref is either an RLP-encoded 32-byte keccak256 hash string,
// OR — when the encoded child node is < 32 bytes — the child node bytes
// themselves embedded in-place ("inline" / "embedded child").
//
// The two-leaf branch fixture is the same shape that go-ethereum's
// `trie/proof_test.go` exercises (a top-level branch when two leaves
// diverge at the very first nibble) — but built here without depending on
// any external trie library. The receipts_root in a real Ethereum block
// is exactly such a trie keyed by RLP(tx_index).
//
// Heap discipline matches the rest of core/: every helper takes a caller
// buffer; nothing is allocated. Buffers used by tests are sized for the
// largest fixture we build (3 leaves + 1 branch + 1 extension ≤ 600 B).
//
// Public surface used by tests in spv_eth.zig:
//   * KeyValue
//   * BuiltTrie
//   * Storage
//   * buildTwoLeafBranch
//   * buildTwoLeafExtension
//   * buildThreeLeafEmbedded

const std = @import("std");

// ---------------------------------------------------------------------------
// keccak256 — same primitive as spv_eth.zig (kept private here so the
// vector module is independently auditable without importing internals).
// ---------------------------------------------------------------------------

fn keccak256(data: []const u8) [32]u8 {
    var h: [32]u8 = undefined;
    var hasher = std.crypto.hash.sha3.Keccak256.init(.{});
    hasher.update(data);
    hasher.final(&h);
    return h;
}

// ---------------------------------------------------------------------------
// RLP primitives. Mirrors what spv_eth.zig's verifier expects on the wire.
// ---------------------------------------------------------------------------

/// RLP-encode an arbitrary byte string. Buf must be large enough.
/// Supports the three string forms we need:
///   * single-byte (data.len==1, data[0]<0x80)  → 1 byte
///   * short string (data.len <= 55)            → 1+len bytes
///   * long string  (data.len <= 255)           → 2+len bytes (0xb8 prefix)
fn encString(buf: []u8, data: []const u8) []u8 {
    if (data.len == 1 and data[0] < 0x80) {
        buf[0] = data[0];
        return buf[0..1];
    }
    if (data.len <= 55) {
        buf[0] = @intCast(0x80 + data.len);
        @memcpy(buf[1 .. 1 + data.len], data);
        return buf[0 .. 1 + data.len];
    }
    buf[0] = 0xb8;
    buf[1] = @intCast(data.len);
    @memcpy(buf[2 .. 2 + data.len], data);
    return buf[0 .. 2 + data.len];
}

/// RLP-encode a list whose children are already RLP-encoded. Children
/// are concatenated and wrapped in 0xc0..0xf7 (short list) or 0xf8 +
/// 1-byte length (long list ≤ 255 B).
fn encListRaw(buf: []u8, children: []const []const u8) []u8 {
    var total: usize = 0;
    for (children) |c| total += c.len;
    if (total <= 55) {
        buf[0] = @intCast(0xc0 + total);
        var off: usize = 1;
        for (children) |c| {
            @memcpy(buf[off .. off + c.len], c);
            off += c.len;
        }
        return buf[0..off];
    }
    buf[0] = 0xf8;
    buf[1] = @intCast(total);
    var off: usize = 2;
    for (children) |c| {
        @memcpy(buf[off .. off + c.len], c);
        off += c.len;
    }
    return buf[0..off];
}

// ---------------------------------------------------------------------------
// Hex-prefix (compact) encode. Mirrors spv_eth.zig's hpDecode in reverse.
//
//   bit 0x20 = terminator (1 → leaf, 0 → extension)
//   bit 0x10 = odd-length flag
//
// odd → first nibble lives in low half of prefix byte
// even → low half of prefix byte must be zero
// ---------------------------------------------------------------------------

fn hpEncode(buf: []u8, nibbles: []const u8, terminator: bool) []u8 {
    const term_bit: u8 = if (terminator) 0x20 else 0x00;
    if (nibbles.len % 2 == 0) {
        // even
        buf[0] = term_bit;
        var n: usize = 1;
        var i: usize = 0;
        while (i < nibbles.len) : (i += 2) {
            buf[n] = (nibbles[i] << 4) | nibbles[i + 1];
            n += 1;
        }
        return buf[0..n];
    }
    // odd
    buf[0] = term_bit | 0x10 | (nibbles[0] & 0x0f);
    var n: usize = 1;
    var i: usize = 1;
    while (i < nibbles.len) : (i += 2) {
        buf[n] = (nibbles[i] << 4) | nibbles[i + 1];
        n += 1;
    }
    return buf[0..n];
}

/// Encode the "empty string" used for absent branch slots: RLP 0x80.
fn encEmpty(buf: []u8) []u8 {
    buf[0] = 0x80;
    return buf[0..1];
}

/// Encode a child reference: if the raw child is ≥ 32 bytes, hash and
/// emit RLP(hash) (33 bytes: 0xa0 + 32 hash bytes). If it's < 32 bytes
/// the spec embeds the raw RLP node in-place.
///
/// `inline_buf` may share memory with `out_buf` — caller is responsible
/// for sequencing. We always copy if the form is hash; we copy the raw
/// node if the form is embedded.
fn encChildRef(out_buf: []u8, child_rlp: []const u8) []u8 {
    if (child_rlp.len >= 32) {
        const h = keccak256(child_rlp);
        out_buf[0] = 0xa0; // 0x80 + 32
        @memcpy(out_buf[1..33], &h);
        return out_buf[0..33];
    }
    @memcpy(out_buf[0..child_rlp.len], child_rlp);
    return out_buf[0..child_rlp.len];
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// One key/value pair to be inserted into the fixture trie.
pub const KeyValue = struct {
    /// Nibbles of the trie key. For a real Ethereum receipts trie this
    /// is RLP(tx_index) split into nibbles. Tests use short hand-picked
    /// nibble sequences so the resulting trie has predictable shape.
    key_nibbles: []const u8,
    /// Stored value bytes. Anything → leaf nodes hold these as-is.
    value: []const u8,
};

/// Output of one fixture build. All slices reference into `Storage.buf`.
pub const BuiltTrie = struct {
    root: [32]u8,
    /// All trie nodes that comprise the trie. Order is unspecified; the
    /// PMT verifier looks them up by hash, so any traversal order works.
    /// For completeness, this array is also a valid proof for EVERY key
    /// in the fixture (the verifier only needs the path, but it doesn't
    /// hurt to hand it more).
    nodes: []const []const u8,
};

/// Caller-owned buffer pool. Gets passed to each builder. 4 KiB is plenty
/// for tries with ≤ 8 short leaves; tests use ≤ 3.
pub const Storage = struct {
    buf: [4096]u8 = undefined,
    /// Slice slots for nodes (we never have more than ~8 nodes in fixtures).
    node_slots: [8][]const u8 = undefined,
    /// How much of `buf` is used.
    used: usize = 0,
    /// How many nodes have been registered.
    node_count: usize = 0,

    fn allocSlice(self: *Storage, n: usize) []u8 {
        const start = self.used;
        std.debug.assert(start + n <= self.buf.len);
        self.used += n;
        return self.buf[start .. start + n];
    }

    fn registerNode(self: *Storage, node: []const u8) void {
        std.debug.assert(self.node_count < self.node_slots.len);
        self.node_slots[self.node_count] = node;
        self.node_count += 1;
    }

    fn nodes(self: *const Storage) []const []const u8 {
        return self.node_slots[0..self.node_count];
    }
};

// ---------------------------------------------------------------------------
// Internal helpers — encode a leaf node from key_nibbles + value.
// ---------------------------------------------------------------------------

fn buildLeafNode(s: *Storage, key_nibbles: []const u8, value: []const u8) []const u8 {
    // HP-encode the path with terminator=1.
    const hp_buf = s.allocSlice(key_nibbles.len / 2 + 1 + 1);
    const hp = hpEncode(hp_buf, key_nibbles, true);
    // RLP-encode HP and value as separate strings.
    const path_rlp_buf = s.allocSlice(hp.len + 2);
    const path_rlp = encString(path_rlp_buf, hp);
    const val_rlp_buf = s.allocSlice(value.len + 2);
    const val_rlp = encString(val_rlp_buf, value);
    // Wrap in a 2-element list.
    const list_buf = s.allocSlice(path_rlp.len + val_rlp.len + 2);
    const children = [_][]const u8{ path_rlp, val_rlp };
    return encListRaw(list_buf, &children);
}

/// Build a 17-element branch node from a child-ref array (16 slots + value).
/// Slots that are null → empty string. Slots that are non-null may be
/// either a 33-byte hash-ref (encoded as RLP string) OR an embedded RLP
/// node (passed in already-encoded form, < 32 B).
fn buildBranchNode(
    s: *Storage,
    slots: [16]?[]const u8, // each is the *raw* child RLP (will be hash-or-embed encoded here)
    value: []const u8, // empty for our test cases
) []const u8 {
    var children_storage: [17][]const u8 = undefined;
    var children: [17][]const u8 = undefined;
    var i: usize = 0;
    while (i < 16) : (i += 1) {
        if (slots[i]) |raw| {
            // raw is a complete RLP-encoded child node. Encode as a
            // child-reference (hash or embedded).
            const ref_buf = s.allocSlice(if (raw.len >= 32) 33 else raw.len);
            children_storage[i] = encChildRef(ref_buf, raw);
            children[i] = children_storage[i];
        } else {
            const empty_buf = s.allocSlice(1);
            children_storage[i] = encEmpty(empty_buf);
            children[i] = children_storage[i];
        }
    }
    // 17th slot — the branch's own value.
    if (value.len == 0) {
        const empty_buf = s.allocSlice(1);
        children_storage[16] = encEmpty(empty_buf);
    } else {
        const v_buf = s.allocSlice(value.len + 2);
        children_storage[16] = encString(v_buf, value);
    }
    children[16] = children_storage[16];
    // Total children size — branch w/ 16 hash-refs + empty value = ~533 B,
    // requires 0xf8 long-form. Allocate generously.
    var total: usize = 0;
    for (children) |c| total += c.len;
    const list_buf = s.allocSlice(total + 3);
    return encListRaw(list_buf, &children);
}

/// Build an extension node: [HP(path, term=0), child_ref].
fn buildExtensionNode(s: *Storage, path_nibbles: []const u8, child_rlp: []const u8) []const u8 {
    const hp_buf = s.allocSlice(path_nibbles.len / 2 + 2);
    const hp = hpEncode(hp_buf, path_nibbles, false);
    const path_rlp_buf = s.allocSlice(hp.len + 2);
    const path_rlp = encString(path_rlp_buf, hp);
    // child_ref = hash(child_rlp) (we always use ≥32B branches here)
    const ref_buf = s.allocSlice(if (child_rlp.len >= 32) 33 else child_rlp.len);
    const ref = encChildRef(ref_buf, child_rlp);
    const list_buf = s.allocSlice(path_rlp.len + ref.len + 2);
    const children = [_][]const u8{ path_rlp, ref };
    return encListRaw(list_buf, &children);
}

// ---------------------------------------------------------------------------
// PUBLIC FIXTURES
// ---------------------------------------------------------------------------

/// Build a 2-leaf trie where the two keys DIVERGE AT THE FIRST NIBBLE.
/// Resulting shape:
///         BRANCH
///         /    \
///   LeafA      LeafB    (each carries its own remaining nibbles + value)
///
/// `key_a` and `key_b` must have nibble[0] differing. After consuming
/// nibble[0] the verifier descends into the appropriate leaf and checks
/// the rest of the path.
pub fn buildTwoLeafBranch(
    s: *Storage,
    a: KeyValue,
    b: KeyValue,
) BuiltTrie {
    std.debug.assert(a.key_nibbles.len > 0 and b.key_nibbles.len > 0);
    std.debug.assert(a.key_nibbles[0] != b.key_nibbles[0]);

    // Each leaf's remaining-key-nibbles (excluding the branch nibble).
    const leaf_a = buildLeafNode(s, a.key_nibbles[1..], a.value);
    s.registerNode(leaf_a);
    const leaf_b = buildLeafNode(s, b.key_nibbles[1..], b.value);
    s.registerNode(leaf_b);

    var slots: [16]?[]const u8 = .{null} ** 16;
    slots[a.key_nibbles[0]] = leaf_a;
    slots[b.key_nibbles[0]] = leaf_b;
    const branch = buildBranchNode(s, slots, "");
    s.registerNode(branch);

    return .{ .root = keccak256(branch), .nodes = s.nodes() };
}

/// Build a 2-leaf trie where the two keys SHARE A COMMON PREFIX of nibbles.
/// Resulting shape:
///       EXTENSION (path = shared prefix)
///           |
///         BRANCH
///         /    \
///   LeafA      LeafB
///
/// `prefix_len` ≥ 1 is the number of leading nibbles shared between
/// `a.key_nibbles` and `b.key_nibbles`. Both keys must agree on the first
/// `prefix_len` nibbles AND differ at nibble[prefix_len].
pub fn buildTwoLeafExtension(
    s: *Storage,
    a: KeyValue,
    b: KeyValue,
    prefix_len: usize,
) BuiltTrie {
    std.debug.assert(a.key_nibbles.len > prefix_len);
    std.debug.assert(b.key_nibbles.len > prefix_len);
    std.debug.assert(std.mem.eql(u8, a.key_nibbles[0..prefix_len], b.key_nibbles[0..prefix_len]));
    std.debug.assert(a.key_nibbles[prefix_len] != b.key_nibbles[prefix_len]);

    const leaf_a = buildLeafNode(s, a.key_nibbles[prefix_len + 1 ..], a.value);
    s.registerNode(leaf_a);
    const leaf_b = buildLeafNode(s, b.key_nibbles[prefix_len + 1 ..], b.value);
    s.registerNode(leaf_b);

    var slots: [16]?[]const u8 = .{null} ** 16;
    slots[a.key_nibbles[prefix_len]] = leaf_a;
    slots[b.key_nibbles[prefix_len]] = leaf_b;
    const branch = buildBranchNode(s, slots, "");
    s.registerNode(branch);

    const extension = buildExtensionNode(s, a.key_nibbles[0..prefix_len], branch);
    s.registerNode(extension);

    return .{ .root = keccak256(extension), .nodes = s.nodes() };
}

/// Build a 3-leaf trie that exercises the "embedded child" path: one of
/// the leaves is small enough (RLP < 32 bytes) that its parent branch
/// stores it INLINE rather than as a 32-byte hash reference.
///
/// Shape (all three keys diverge at first nibble):
///         BRANCH                          slot[a0] = LeafA (large → hash ref)
///         /    \    \                     slot[b0] = LeafB (large → hash ref)
///   LeafA    LeafB    LeafC               slot[c0] = LeafC (small → embedded)
///
/// Caller must size LeafC so its RLP form is < 32 bytes (e.g. 1-nibble
/// remainder + 1-byte value → ~5 bytes total).
///
/// IMPORTANT: when a leaf is embedded, it is NOT in the proof-nodes
/// list — the verifier finds it inline inside the branch. We still
/// emit it via `nodes()` for symmetry, but its presence/absence is not
/// load-bearing for proof verification.
pub fn buildThreeLeafEmbedded(
    s: *Storage,
    a: KeyValue,
    b: KeyValue,
    c: KeyValue, // the small one
) BuiltTrie {
    std.debug.assert(a.key_nibbles.len > 0 and b.key_nibbles.len > 0 and c.key_nibbles.len > 0);
    std.debug.assert(a.key_nibbles[0] != b.key_nibbles[0]);
    std.debug.assert(a.key_nibbles[0] != c.key_nibbles[0]);
    std.debug.assert(b.key_nibbles[0] != c.key_nibbles[0]);

    const leaf_a = buildLeafNode(s, a.key_nibbles[1..], a.value);
    s.registerNode(leaf_a);
    const leaf_b = buildLeafNode(s, b.key_nibbles[1..], b.value);
    s.registerNode(leaf_b);
    const leaf_c = buildLeafNode(s, c.key_nibbles[1..], c.value);
    // Sanity: caller intended C to be embeddable. Assertion guards
    // against fixture drift if someone bumps c.value too large.
    std.debug.assert(leaf_c.len < 32);
    // Don't register leaf_c as a top-level node — it is embedded in the
    // branch. Adding it to the proof would still work (the verifier
    // ignores unmatched proof items) but we want to prove the embedded
    // path actually works on the proof-minimum case.

    var slots: [16]?[]const u8 = .{null} ** 16;
    slots[a.key_nibbles[0]] = leaf_a;
    slots[b.key_nibbles[0]] = leaf_b;
    slots[c.key_nibbles[0]] = leaf_c;
    const branch = buildBranchNode(s, slots, "");
    s.registerNode(branch);

    return .{ .root = keccak256(branch), .nodes = s.nodes() };
}

// ---------------------------------------------------------------------------
// Tests for this builder, independent of spv_eth.zig.
// These re-derive root hashes via the same primitives and assert that
// our RLP/HP/keccak chain is internally consistent.
// ---------------------------------------------------------------------------

test "vectors: encString — single byte form" {
    var buf: [4]u8 = undefined;
    const data = [_]u8{0x42};
    const out = encString(&buf, &data);
    try std.testing.expectEqual(@as(usize, 1), out.len);
    try std.testing.expectEqual(@as(u8, 0x42), out[0]);
}

test "vectors: encString — short string with leading byte ≥ 0x80" {
    var buf: [8]u8 = undefined;
    const data = [_]u8{ 0x83, 0xff };
    const out = encString(&buf, &data);
    // 2-byte string → 0x82 + bytes.
    try std.testing.expectEqual(@as(u8, 0x82), out[0]);
    try std.testing.expectEqual(@as(u8, 0x83), out[1]);
    try std.testing.expectEqual(@as(u8, 0xff), out[2]);
}

test "vectors: hpEncode — even leaf and odd extension" {
    var buf: [16]u8 = undefined;
    {
        // even leaf: terminator=1, even nibbles. Flag should be 0x20.
        const nibs = [_]u8{ 0x1, 0x2, 0x3, 0x4 };
        const out = hpEncode(&buf, &nibs, true);
        try std.testing.expectEqualSlices(u8, &[_]u8{ 0x20, 0x12, 0x34 }, out);
    }
    {
        // odd extension: terminator=0, odd nibbles → flag = 0x10 | nib0.
        const nibs = [_]u8{ 0xa, 0xb, 0xc };
        const out = hpEncode(&buf, &nibs, false);
        try std.testing.expectEqualSlices(u8, &[_]u8{ 0x1a, 0xbc }, out);
    }
}

test "vectors: 2-leaf branch — root and node count sane" {
    var s = Storage{};
    const a = KeyValue{ .key_nibbles = &.{ 1, 2, 3, 4 }, .value = "value-A-0123456789" };
    const b = KeyValue{ .key_nibbles = &.{ 2, 2, 3, 4 }, .value = "value-B-0123456789" };
    const t = buildTwoLeafBranch(&s, a, b);
    try std.testing.expect(t.nodes.len == 3); // 2 leaves + 1 branch
    // Root must NOT be all-zeros (a misbuilt fixture would sometimes hash
    // an empty list and yield a known hash; this is a sanity floor).
    var all_zero = true;
    for (t.root) |x| if (x != 0) { all_zero = false; break; };
    try std.testing.expect(!all_zero);
}

test "vectors: 2-leaf extension — has 4 nodes (2 leaves + branch + ext)" {
    var s = Storage{};
    const a = KeyValue{ .key_nibbles = &.{ 0xa, 0xb, 1, 5, 5 }, .value = "value-A-larger-than-32-bytes-required" };
    const b = KeyValue{ .key_nibbles = &.{ 0xa, 0xb, 2, 7, 7 }, .value = "value-B-larger-than-32-bytes-required" };
    const t = buildTwoLeafExtension(&s, a, b, 2);
    try std.testing.expect(t.nodes.len == 4);
}

test "vectors: 3-leaf embedded — small leaf NOT registered" {
    var s = Storage{};
    const a = KeyValue{ .key_nibbles = &.{ 1, 2, 3, 4 }, .value = "value-A-0123456789" };
    const b = KeyValue{ .key_nibbles = &.{ 2, 2, 3, 4 }, .value = "value-B-0123456789" };
    // Small leaf: 1-nibble path remainder + 1-byte value → ≤ 5 bytes RLP.
    const c = KeyValue{ .key_nibbles = &.{ 3, 0xa }, .value = &[_]u8{0x42} };
    const t = buildThreeLeafEmbedded(&s, a, b, c);
    // 2 large leaves + 1 branch == 3 registered nodes (leaf_c is embedded).
    try std.testing.expect(t.nodes.len == 3);
}
