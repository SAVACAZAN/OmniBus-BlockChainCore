//! id_merkle.zig — fixed-arity Merkle tree over a Manifest's 6 fields.
//!
//! We use SHA-256 (already linked everywhere on chain — block.zig, bip32,
//! etc.) instead of pulling in Blake3 just for the ID layer. The tree is
//! always padded to a power-of-two leaf count by repeating the last hash,
//! so root computation is deterministic and proofs are linear in log2(N).

const std = @import("std");
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const HASH_SIZE: usize = 32;
pub const Hash = [HASH_SIZE]u8;

/// Hash one leaf. We tag with 0x00 so leaf hashes can never collide with
/// internal node hashes (which use tag 0x01) — second-preimage hardening.
pub fn hashLeaf(data: []const u8) Hash {
    var h: Hash = undefined;
    var hasher = Sha256.init(.{});
    hasher.update(&[_]u8{0x00});
    hasher.update(data);
    hasher.final(&h);
    return h;
}

/// Hash two children into their parent.
pub fn hashNode(left: Hash, right: Hash) Hash {
    var h: Hash = undefined;
    var hasher = Sha256.init(.{});
    hasher.update(&[_]u8{0x01});
    hasher.update(&left);
    hasher.update(&right);
    hasher.final(&h);
    return h;
}

/// Compute the Merkle root over an arbitrary list of pre-hashed leaves.
/// Allocator is used for the working buffer; caller owns nothing after
/// the call (we return a stack-sized array).
pub fn rootOfLeafHashes(
    leaves: []const Hash,
    allocator: std.mem.Allocator,
) !Hash {
    if (leaves.len == 0) return [_]u8{0} ** HASH_SIZE;
    if (leaves.len == 1) return leaves[0];

    var current = try allocator.alloc(Hash, leaves.len);
    defer allocator.free(current);
    @memcpy(current, leaves);

    var level_len: usize = leaves.len;
    while (level_len > 1) {
        const next_len: usize = (level_len + 1) / 2;
        var i: usize = 0;
        while (i < next_len) : (i += 1) {
            const left = current[i * 2];
            // If we have an odd leaf at the end, duplicate it so the tree
            // stays balanced and roots remain reproducible across clients.
            const right = if (i * 2 + 1 < level_len) current[i * 2 + 1] else left;
            current[i] = hashNode(left, right);
        }
        level_len = next_len;
    }
    return current[0];
}

/// One step in a Merkle inclusion proof: the sibling hash + whether the
/// sibling is on the left of the path (path_is_right=false) or right.
pub const ProofStep = struct {
    sibling: Hash,
    sibling_is_right: bool,
};

/// Generate an inclusion proof for `leaf_index` against the same leaf
/// hash array used in `rootOfLeafHashes`. Caller frees the returned slice.
pub fn proveLeaf(
    leaves: []const Hash,
    leaf_index: usize,
    allocator: std.mem.Allocator,
) ![]ProofStep {
    if (leaf_index >= leaves.len) return error.IndexOutOfRange;
    if (leaves.len <= 1) return allocator.alloc(ProofStep, 0);

    var steps = std.array_list.Managed(ProofStep).init(allocator);
    errdefer steps.deinit();

    var current = try allocator.alloc(Hash, leaves.len);
    defer allocator.free(current);
    @memcpy(current, leaves);

    var idx: usize = leaf_index;
    var level_len: usize = leaves.len;
    while (level_len > 1) {
        const sib_index = if (idx % 2 == 0) idx + 1 else idx - 1;
        const sibling = if (sib_index < level_len) current[sib_index] else current[idx];
        try steps.append(.{
            .sibling = sibling,
            .sibling_is_right = (sib_index > idx),
        });

        // Reduce one level.
        const next_len: usize = (level_len + 1) / 2;
        var i: usize = 0;
        while (i < next_len) : (i += 1) {
            const left = current[i * 2];
            const right = if (i * 2 + 1 < level_len) current[i * 2 + 1] else left;
            current[i] = hashNode(left, right);
        }
        idx /= 2;
        level_len = next_len;
    }
    return steps.toOwnedSlice();
}

/// Verify a proof: walk the steps and check the recomputed root matches.
pub fn verifyProof(leaf: Hash, steps: []const ProofStep, expected_root: Hash) bool {
    var current = leaf;
    for (steps) |step| {
        current = if (step.sibling_is_right)
            hashNode(current, step.sibling)
        else
            hashNode(step.sibling, current);
    }
    return std.mem.eql(u8, &current, &expected_root);
}

test "merkle root for 1 leaf equals the leaf" {
    const leaf = hashLeaf("alone");
    const root = try rootOfLeafHashes(&[_]Hash{leaf}, std.testing.allocator);
    try std.testing.expectEqualSlices(u8, &leaf, &root);
}

test "merkle root for 2 leaves equals hashNode of pair" {
    const a = hashLeaf("a");
    const b = hashLeaf("b");
    const expected = hashNode(a, b);
    const got = try rootOfLeafHashes(&[_]Hash{ a, b }, std.testing.allocator);
    try std.testing.expectEqualSlices(u8, &expected, &got);
}

test "merkle proof round-trips for each leaf in a 4-leaf tree" {
    const leaves = [_]Hash{
        hashLeaf("kyc"),
        hashLeaf("assets"),
        hashLeaf("rep"),
        hashLeaf("pq"),
    };
    const root = try rootOfLeafHashes(&leaves, std.testing.allocator);
    for (0..leaves.len) |i| {
        const proof = try proveLeaf(&leaves, i, std.testing.allocator);
        defer std.testing.allocator.free(proof);
        try std.testing.expect(verifyProof(leaves[i], proof, root));
    }
}

test "merkle proof fails when leaf is tampered" {
    const leaves = [_]Hash{ hashLeaf("a"), hashLeaf("b"), hashLeaf("c") };
    const root = try rootOfLeafHashes(&leaves, std.testing.allocator);
    const proof = try proveLeaf(&leaves, 1, std.testing.allocator);
    defer std.testing.allocator.free(proof);
    const bogus = hashLeaf("not-b");
    try std.testing.expect(!verifyProof(bogus, proof, root));
}

test "merkle root differs from internal node hash (domain separation)" {
    // A 1-leaf root is just the leaf. So compare 2-leaf root vs the same
    // pair hashed without the 0x01 tag — they MUST differ thanks to tag.
    const a = hashLeaf("x");
    const b = hashLeaf("y");
    const root = try rootOfLeafHashes(&[_]Hash{ a, b }, std.testing.allocator);

    var untagged: Hash = undefined;
    var hasher = Sha256.init(.{});
    hasher.update(&a);
    hasher.update(&b);
    hasher.final(&untagged);

    try std.testing.expect(!std.mem.eql(u8, &root, &untagged));
}
