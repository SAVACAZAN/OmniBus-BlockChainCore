//! id_social.zig — Social Facet for the OmniBus ID layer.
//!
//! WHY this exists separately from `core/social_graph.zig`:
//! The on-chain `social_graph` stores LIVE state (current followers, latest
//! follows) that mutates with every block — useful for runtime queries like
//! `getfollowers`, but unusable as a stable identity attestation.
//!
//! The Social Facet is the holder-anchored, point-in-time SNAPSHOT of that
//! activity, committed as a single 32-byte Merkle root inside the holder's
//! master Manifest. It lets a verifier check "user X authored post P at
//! time T" or "user X follows account Y" via selective disclosure proofs,
//! without leaking the entire graph and without trusting a live chain query.
//!
//! Field order in the inner tree is FIXED: posts -> follows -> reactions -> handle.
//! Reordering would invalidate every previously-issued proof.

const std = @import("std");
const Sha256 = std.crypto.hash.sha2.Sha256;
const merkle = @import("id_merkle.zig");

/// Reference to one social post authored by the holder.
/// Private posts commit only an opaque salted hash so existence is provable
/// but content stays hidden — useful for "I posted N times in window W" type
/// proofs without revealing the body.
pub const PostRef = struct {
    id_hash: [32]u8,
    timestamp_unix_s: u64,
    is_public: bool,
};

/// The complete Social Facet input. Empty lists are legal — they simply
/// reduce to a single zero-leaf in that section.
pub const SocialFacet = struct {
    posts: []const PostRef,
    follows: []const [20]u8,
    reactions_count: u32,
    display_handle: ?[]const u8,
};

/// Selective-disclosure proof that a single post was committed in a facet.
pub const PostProof = struct {
    post: PostRef,
    proof: []merkle.ProofStep,
};

/// Derive the leaf hash for one post. Public posts commit (id || timestamp_le);
/// private posts commit SHA-256(id || "private_post") so the verifier cannot
/// distinguish two different private posts by their leaves.
fn postLeaf(p: PostRef) [32]u8 {
    if (p.is_public) {
        var buf: [40]u8 = undefined;
        @memcpy(buf[0..32], &p.id_hash);
        std.mem.writeInt(u64, buf[32..40], p.timestamp_unix_s, .little);
        return merkle.hashLeaf(&buf);
    }
    var inner: [32 + 12]u8 = undefined;
    @memcpy(inner[0..32], &p.id_hash);
    @memcpy(inner[32..44], "private_post");
    var redacted: [32]u8 = undefined;
    Sha256.hash(&inner, &redacted, .{});
    return merkle.hashLeaf(&redacted);
}

/// Build the ordered leaf vector for one section, returning a single
/// zero-leaf when the section is empty. Caller owns the returned slice.
fn buildPostLeaves(facet: SocialFacet, allocator: std.mem.Allocator) ![]merkle.Hash {
    if (facet.posts.len == 0) {
        const out = try allocator.alloc(merkle.Hash, 1);
        const zero = [_]u8{0} ** 32;
        out[0] = merkle.hashLeaf(&zero);
        return out;
    }
    const out = try allocator.alloc(merkle.Hash, facet.posts.len);
    for (facet.posts, 0..) |p, i| out[i] = postLeaf(p);
    return out;
}

/// Hash one section into a 32-byte sub-root via the existing Merkle module.
fn sectionRoot(leaves: []const merkle.Hash, allocator: std.mem.Allocator) ![32]u8 {
    return merkle.rootOfLeafHashes(leaves, allocator);
}

/// Compute the Social Facet root. This is the value stored as `social_root`
/// in the master Manifest's tree.
pub fn computeSocialRoot(facet: SocialFacet, allocator: std.mem.Allocator) ![32]u8 {
    // Section 1: posts
    const post_leaves = try buildPostLeaves(facet, allocator);
    defer allocator.free(post_leaves);
    const posts_root = try sectionRoot(post_leaves, allocator);

    // Section 2: follows
    var follows_root: [32]u8 = undefined;
    if (facet.follows.len == 0) {
        const zero = [_]u8{0} ** 32;
        follows_root = merkle.hashLeaf(&zero);
    } else {
        const follow_leaves = try allocator.alloc(merkle.Hash, facet.follows.len);
        defer allocator.free(follow_leaves);
        for (facet.follows, 0..) |fh, i| follow_leaves[i] = merkle.hashLeaf(&fh);
        follows_root = try sectionRoot(follow_leaves, allocator);
    }

    // Section 3: reactions (single leaf, LE32 of the count)
    var rx_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &rx_buf, facet.reactions_count, .little);
    const reactions_leaf = merkle.hashLeaf(&rx_buf);

    // Section 4: display handle (single leaf; zero-leaf if absent)
    const handle_leaf = if (facet.display_handle) |h|
        merkle.hashLeaf(h)
    else
        merkle.hashLeaf(&[_]u8{0} ** 32);

    // Combine the four section roots in the FIXED order.
    const top = [_]merkle.Hash{ posts_root, follows_root, reactions_leaf, handle_leaf };
    return merkle.rootOfLeafHashes(&top, allocator);
}

/// Produce a Merkle proof that `post_index` is committed inside the facet.
/// The returned proof verifies against the POSTS sub-root, NOT directly
/// against the facet root — the verifier walks up by re-hashing the other
/// three section roots, which are reproducible from the facet.
pub fn provePost(facet: SocialFacet, post_index: usize, allocator: std.mem.Allocator) !PostProof {
    if (post_index >= facet.posts.len) return error.IndexOutOfRange;
    const leaves = try buildPostLeaves(facet, allocator);
    defer allocator.free(leaves);
    const steps = try merkle.proveLeaf(leaves, post_index, allocator);
    return .{ .post = facet.posts[post_index], .proof = steps };
}

/// Verify a `PostProof` recomputes to the posts sub-root. Note: this checks
/// the sub-root, which is the natural anchor for a stand-alone proof bundle.
/// The full facet root binding is the caller's responsibility (they re-feed
/// the proven sub-root into the top-level tree along with the other three).
pub fn verifyPost(proof: PostProof, facet_root: [32]u8) bool {
    const leaf = postLeaf(proof.post);
    return merkle.verifyProof(leaf, proof.proof, facet_root);
}

// ===========================================================================
// Tests
// ===========================================================================

fn samplePost(seed: u8, public: bool) PostRef {
    var id: [32]u8 = undefined;
    for (&id, 0..) |*b, i| b.* = seed ^ @as(u8, @intCast(i & 0xFF));
    return .{ .id_hash = id, .timestamp_unix_s = 1_700_000_000 + @as(u64, seed), .is_public = public };
}

test "computeSocialRoot is deterministic" {
    const posts = [_]PostRef{ samplePost(1, true), samplePost(2, false) };
    const follows = [_][20]u8{ [_]u8{0xAA} ** 20, [_]u8{0xBB} ** 20 };
    const facet = SocialFacet{
        .posts = &posts,
        .follows = &follows,
        .reactions_count = 42,
        .display_handle = "alice",
    };
    const r1 = try computeSocialRoot(facet, std.testing.allocator);
    const r2 = try computeSocialRoot(facet, std.testing.allocator);
    try std.testing.expectEqualSlices(u8, &r1, &r2);
}

test "adding a post changes the root" {
    const base_posts = [_]PostRef{samplePost(1, true)};
    const more_posts = [_]PostRef{ samplePost(1, true), samplePost(2, true) };
    const a = SocialFacet{ .posts = &base_posts, .follows = &.{}, .reactions_count = 0, .display_handle = null };
    const b = SocialFacet{ .posts = &more_posts, .follows = &.{}, .reactions_count = 0, .display_handle = null };
    const ra = try computeSocialRoot(a, std.testing.allocator);
    const rb = try computeSocialRoot(b, std.testing.allocator);
    try std.testing.expect(!std.mem.eql(u8, &ra, &rb));
}

test "adding a follow changes the root" {
    const f1 = [_][20]u8{[_]u8{0x11} ** 20};
    const f2 = [_][20]u8{ [_]u8{0x11} ** 20, [_]u8{0x22} ** 20 };
    const a = SocialFacet{ .posts = &.{}, .follows = &f1, .reactions_count = 0, .display_handle = null };
    const b = SocialFacet{ .posts = &.{}, .follows = &f2, .reactions_count = 0, .display_handle = null };
    const ra = try computeSocialRoot(a, std.testing.allocator);
    const rb = try computeSocialRoot(b, std.testing.allocator);
    try std.testing.expect(!std.mem.eql(u8, &ra, &rb));
}

test "changing reactions_count changes the root" {
    const a = SocialFacet{ .posts = &.{}, .follows = &.{}, .reactions_count = 5, .display_handle = null };
    const b = SocialFacet{ .posts = &.{}, .follows = &.{}, .reactions_count = 6, .display_handle = null };
    const ra = try computeSocialRoot(a, std.testing.allocator);
    const rb = try computeSocialRoot(b, std.testing.allocator);
    try std.testing.expect(!std.mem.eql(u8, &ra, &rb));
}

test "provePost round-trips and tampering fails" {
    const posts = [_]PostRef{ samplePost(1, true), samplePost(2, false), samplePost(3, true), samplePost(4, true) };
    const facet = SocialFacet{ .posts = &posts, .follows = &.{}, .reactions_count = 0, .display_handle = null };

    // The proof verifies against the posts sub-root.
    const post_leaves = try buildPostLeaves(facet, std.testing.allocator);
    defer std.testing.allocator.free(post_leaves);
    const posts_root = try sectionRoot(post_leaves, std.testing.allocator);

    const proof = try provePost(facet, 2, std.testing.allocator);
    defer std.testing.allocator.free(proof.proof);
    try std.testing.expect(verifyPost(proof, posts_root));

    var tampered = proof;
    tampered.post.timestamp_unix_s ^= 1;
    try std.testing.expect(!verifyPost(tampered, posts_root));
}

test "empty facet produces a non-zero root" {
    const facet = SocialFacet{ .posts = &.{}, .follows = &.{}, .reactions_count = 0, .display_handle = null };
    const root = try computeSocialRoot(facet, std.testing.allocator);
    const zero = [_]u8{0} ** 32;
    try std.testing.expect(!std.mem.eql(u8, &root, &zero));
}
