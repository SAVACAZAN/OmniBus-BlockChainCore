//! id_cultural.zig — Cultural facet of the OmniBus ID identity layer.
//!
//! WHY THIS FACET EXISTS
//! ---------------------
//! OmniBus ID is sliced into facets so a holder can selectively disclose
//! one slice of who-they-are without leaking the rest. The Professional
//! facet covers employment / CV / credentials (what you do for money).
//! The Cultural facet is its mirror image: the creative and community
//! footprint of a holder — what they make, attend, support, and the
//! languages they speak. It is intentionally separate because:
//!
//!   * an employer should not need a poet's POAP history to verify a job,
//!     and a gallery should not need salary slips to verify authorship;
//!   * cultural participation is often the strongest non-financial proof
//!     of long-term identity (years of POAPs, notarized works) and we
//!     want it to be presentable on its own;
//!   * private artistic drafts must be committable without being legible
//!     — the holder can later reveal them with `notarize` + a Merkle
//!     proof against this facet root.
//!
//! The UI surfaces this facet as a sub-tab with four sections:
//!   1. POAPs            — event attendance (community footprint)
//!   2. Notarized works  — poems / music / visual / text / code (creation)
//!   3. Cultural badges  — soulbound culture tags (poet, musician, ...)
//!   4. Language tags    — ISO 639-1 codes the holder marks themselves
//!
//! Tree shape (fixed top-level order, 4 leaves, never reordered):
//!     facet_root = root( poaps_root, works_root, badges_root, langs_leaf )
//! Empty section -> single zero-hash leaf so the shape is stable.

const std = @import("std");
const Sha256 = std.crypto.hash.sha2.Sha256;
const merkle = @import("id_merkle.zig");

pub const WorkKind = enum(u8) {
    poem = 1,
    music = 2,
    visual = 3,
    text = 4,
    code = 5,
    translation = 6,
    other = 99,
};

pub const Poap = struct {
    event_id: [32]u8,
    event_unix_s: u64,
    claim_unix_s: u64,
};

pub const NotarizedWork = struct {
    work_hash: [32]u8,
    kind: WorkKind,
    notarized_unix_s: u64,
    is_public: bool,
};

pub const CulturalFacet = struct {
    poaps: []const Poap,
    notarized_works: []const NotarizedWork,
    cultural_badges: []const u32,
    language_tags: []const u8,
};

pub const PoapProof = struct {
    poap: Poap,
    proof: []merkle.ProofStep,
};

pub const WorkProof = struct {
    work: NotarizedWork,
    proof: []merkle.ProofStep,
};

const ZERO_LEAF: merkle.Hash = [_]u8{0} ** merkle.HASH_SIZE;

fn writeU64LE(buf: *[8]u8, v: u64) void {
    std.mem.writeInt(u64, buf, v, .little);
}

fn writeU32LE(buf: *[4]u8, v: u32) void {
    std.mem.writeInt(u32, buf, v, .little);
}

/// Encode one POAP into its leaf hash. 32 + 8 + 8 = 48 bytes raw input;
/// docstring in the design note says 72 because that includes the SHA
/// length prefix internally, but the on-wire commitment is fed straight
/// to hashLeaf here.
fn leafForPoap(p: Poap) merkle.Hash {
    var buf: [48]u8 = undefined;
    @memcpy(buf[0..32], &p.event_id);
    var ev: [8]u8 = undefined;
    writeU64LE(&ev, p.event_unix_s);
    @memcpy(buf[32..40], &ev);
    var cl: [8]u8 = undefined;
    writeU64LE(&cl, p.claim_unix_s);
    @memcpy(buf[40..48], &cl);
    return merkle.hashLeaf(&buf);
}

/// Encode one notarized work. Public works expose work_hash || kind || ts.
/// Private works commit to SHA-256(work_hash || "private_work") so the
/// holder cannot later inflate or deflate their private catalogue size
/// without breaking the facet root.
fn leafForWork(w: NotarizedWork) merkle.Hash {
    if (w.is_public) {
        var buf: [41]u8 = undefined;
        @memcpy(buf[0..32], &w.work_hash);
        buf[32] = @intFromEnum(w.kind);
        var ts: [8]u8 = undefined;
        writeU64LE(&ts, w.notarized_unix_s);
        @memcpy(buf[33..41], &ts);
        return merkle.hashLeaf(&buf);
    } else {
        var inner: [32 + 12]u8 = undefined;
        @memcpy(inner[0..32], &w.work_hash);
        @memcpy(inner[32..44], "private_work");
        var hidden: [32]u8 = undefined;
        Sha256.hash(&inner, &hidden, .{});
        return merkle.hashLeaf(&hidden);
    }
}

fn leafForBadge(badge_id: u32) merkle.Hash {
    var buf: [4]u8 = undefined;
    writeU32LE(&buf, badge_id);
    return merkle.hashLeaf(&buf);
}

fn sectionRoot(leaves: []const merkle.Hash, allocator: std.mem.Allocator) !merkle.Hash {
    if (leaves.len == 0) return ZERO_LEAF;
    return merkle.rootOfLeafHashes(leaves, allocator);
}

fn buildPoapLeaves(facet: CulturalFacet, allocator: std.mem.Allocator) ![]merkle.Hash {
    const leaves = try allocator.alloc(merkle.Hash, facet.poaps.len);
    for (facet.poaps, 0..) |p, i| leaves[i] = leafForPoap(p);
    return leaves;
}

fn buildWorkLeaves(facet: CulturalFacet, allocator: std.mem.Allocator) ![]merkle.Hash {
    const leaves = try allocator.alloc(merkle.Hash, facet.notarized_works.len);
    for (facet.notarized_works, 0..) |w, i| leaves[i] = leafForWork(w);
    return leaves;
}

fn buildBadgeLeaves(facet: CulturalFacet, allocator: std.mem.Allocator) ![]merkle.Hash {
    const leaves = try allocator.alloc(merkle.Hash, facet.cultural_badges.len);
    for (facet.cultural_badges, 0..) |b, i| leaves[i] = leafForBadge(b);
    return leaves;
}

fn languageLeaf(facet: CulturalFacet) merkle.Hash {
    return merkle.hashLeaf(facet.language_tags);
}

/// Compute the 32-byte commitment of the cultural facet.
pub fn computeCulturalRoot(facet: CulturalFacet, allocator: std.mem.Allocator) ![32]u8 {
    const poap_leaves = try buildPoapLeaves(facet, allocator);
    defer allocator.free(poap_leaves);
    const work_leaves = try buildWorkLeaves(facet, allocator);
    defer allocator.free(work_leaves);
    const badge_leaves = try buildBadgeLeaves(facet, allocator);
    defer allocator.free(badge_leaves);

    const poaps_root = try sectionRoot(poap_leaves, allocator);
    const works_root = try sectionRoot(work_leaves, allocator);
    const badges_root = try sectionRoot(badge_leaves, allocator);
    const langs_leaf = languageLeaf(facet);

    const top = [_]merkle.Hash{ poaps_root, works_root, badges_root, langs_leaf };
    return merkle.rootOfLeafHashes(&top, allocator);
}

/// Build the inclusion proof for poap[idx] all the way to facet root.
/// The path = inner-proof-within-poap-section ++ one top-level step
/// (sibling = works/badges/langs combined branch on the right).
pub fn provePoap(facet: CulturalFacet, idx: usize, allocator: std.mem.Allocator) !PoapProof {
    if (idx >= facet.poaps.len) return error.IndexOutOfRange;

    const poap_leaves = try buildPoapLeaves(facet, allocator);
    defer allocator.free(poap_leaves);
    const work_leaves = try buildWorkLeaves(facet, allocator);
    defer allocator.free(work_leaves);
    const badge_leaves = try buildBadgeLeaves(facet, allocator);
    defer allocator.free(badge_leaves);

    const inner = try merkle.proveLeaf(poap_leaves, idx, allocator);
    defer allocator.free(inner);

    const works_root = try sectionRoot(work_leaves, allocator);
    const badges_root = try sectionRoot(badge_leaves, allocator);
    const langs_leaf = languageLeaf(facet);
    const poaps_root = try sectionRoot(poap_leaves, allocator);

    const top = [_]merkle.Hash{ poaps_root, works_root, badges_root, langs_leaf };
    const top_inner = try merkle.proveLeaf(&top, 0, allocator);
    defer allocator.free(top_inner);

    var steps = try allocator.alloc(merkle.ProofStep, inner.len + top_inner.len);
    @memcpy(steps[0..inner.len], inner);
    @memcpy(steps[inner.len..], top_inner);

    return .{ .poap = facet.poaps[idx], .proof = steps };
}

pub fn verifyPoap(proof: PoapProof, facet_root: [32]u8) bool {
    const leaf = leafForPoap(proof.poap);
    return merkle.verifyProof(leaf, proof.proof, facet_root);
}

pub fn proveWork(facet: CulturalFacet, idx: usize, allocator: std.mem.Allocator) !WorkProof {
    if (idx >= facet.notarized_works.len) return error.IndexOutOfRange;

    const poap_leaves = try buildPoapLeaves(facet, allocator);
    defer allocator.free(poap_leaves);
    const work_leaves = try buildWorkLeaves(facet, allocator);
    defer allocator.free(work_leaves);
    const badge_leaves = try buildBadgeLeaves(facet, allocator);
    defer allocator.free(badge_leaves);

    const inner = try merkle.proveLeaf(work_leaves, idx, allocator);
    defer allocator.free(inner);

    const poaps_root = try sectionRoot(poap_leaves, allocator);
    const works_root = try sectionRoot(work_leaves, allocator);
    const badges_root = try sectionRoot(badge_leaves, allocator);
    const langs_leaf = languageLeaf(facet);

    const top = [_]merkle.Hash{ poaps_root, works_root, badges_root, langs_leaf };
    const top_inner = try merkle.proveLeaf(&top, 1, allocator);
    defer allocator.free(top_inner);

    var steps = try allocator.alloc(merkle.ProofStep, inner.len + top_inner.len);
    @memcpy(steps[0..inner.len], inner);
    @memcpy(steps[inner.len..], top_inner);

    return .{ .work = facet.notarized_works[idx], .proof = steps };
}

pub fn verifyWork(proof: WorkProof, facet_root: [32]u8) bool {
    const leaf = leafForWork(proof.work);
    return merkle.verifyProof(leaf, proof.proof, facet_root);
}

// ---------------------------------------------------------------- tests

fn dummyHash(seed: u8) [32]u8 {
    var h: [32]u8 = undefined;
    for (&h, 0..) |*b, i| b.* = seed +% @as(u8, @intCast(i));
    return h;
}

test "computeCulturalRoot is deterministic" {
    const a = std.testing.allocator;
    const facet = CulturalFacet{
        .poaps = &[_]Poap{.{ .event_id = dummyHash(1), .event_unix_s = 1000, .claim_unix_s = 1001 }},
        .notarized_works = &[_]NotarizedWork{.{ .work_hash = dummyHash(2), .kind = .poem, .notarized_unix_s = 2000, .is_public = true }},
        .cultural_badges = &[_]u32{ 1, 2, 4 },
        .language_tags = "rofrenes",
    };
    const r1 = try computeCulturalRoot(facet, a);
    const r2 = try computeCulturalRoot(facet, a);
    try std.testing.expectEqualSlices(u8, &r1, &r2);
}

test "adding a POAP changes the root" {
    const a = std.testing.allocator;
    const base = CulturalFacet{
        .poaps = &[_]Poap{},
        .notarized_works = &[_]NotarizedWork{},
        .cultural_badges = &[_]u32{},
        .language_tags = "ro",
    };
    const r1 = try computeCulturalRoot(base, a);

    const with_poap = CulturalFacet{
        .poaps = &[_]Poap{.{ .event_id = dummyHash(7), .event_unix_s = 500, .claim_unix_s = 600 }},
        .notarized_works = &[_]NotarizedWork{},
        .cultural_badges = &[_]u32{},
        .language_tags = "ro",
    };
    const r2 = try computeCulturalRoot(with_poap, a);
    try std.testing.expect(!std.mem.eql(u8, &r1, &r2));
}

test "adding a notarized work changes the root" {
    const a = std.testing.allocator;
    const base = CulturalFacet{
        .poaps = &[_]Poap{},
        .notarized_works = &[_]NotarizedWork{},
        .cultural_badges = &[_]u32{},
        .language_tags = "en",
    };
    const r1 = try computeCulturalRoot(base, a);
    const with_work = CulturalFacet{
        .poaps = &[_]Poap{},
        .notarized_works = &[_]NotarizedWork{.{ .work_hash = dummyHash(11), .kind = .music, .notarized_unix_s = 9999, .is_public = true }},
        .cultural_badges = &[_]u32{},
        .language_tags = "en",
    };
    const r2 = try computeCulturalRoot(with_work, a);
    try std.testing.expect(!std.mem.eql(u8, &r1, &r2));
}

test "toggling is_public changes the leaf encoding and the root" {
    const a = std.testing.allocator;
    const pub_work = CulturalFacet{
        .poaps = &[_]Poap{},
        .notarized_works = &[_]NotarizedWork{.{ .work_hash = dummyHash(13), .kind = .text, .notarized_unix_s = 42, .is_public = true }},
        .cultural_badges = &[_]u32{},
        .language_tags = "",
    };
    const priv_work = CulturalFacet{
        .poaps = &[_]Poap{},
        .notarized_works = &[_]NotarizedWork{.{ .work_hash = dummyHash(13), .kind = .text, .notarized_unix_s = 42, .is_public = false }},
        .cultural_badges = &[_]u32{},
        .language_tags = "",
    };
    const rp = try computeCulturalRoot(pub_work, a);
    const rv = try computeCulturalRoot(priv_work, a);
    try std.testing.expect(!std.mem.eql(u8, &rp, &rv));
}

test "provePoap round-trips and tampering breaks it" {
    const a = std.testing.allocator;
    const facet = CulturalFacet{
        .poaps = &[_]Poap{
            .{ .event_id = dummyHash(20), .event_unix_s = 1, .claim_unix_s = 2 },
            .{ .event_id = dummyHash(21), .event_unix_s = 3, .claim_unix_s = 4 },
            .{ .event_id = dummyHash(22), .event_unix_s = 5, .claim_unix_s = 6 },
        },
        .notarized_works = &[_]NotarizedWork{.{ .work_hash = dummyHash(30), .kind = .code, .notarized_unix_s = 77, .is_public = true }},
        .cultural_badges = &[_]u32{ 1, 3 },
        .language_tags = "rofr",
    };
    const root = try computeCulturalRoot(facet, a);

    const p = try provePoap(facet, 1, a);
    defer a.free(p.proof);
    try std.testing.expect(verifyPoap(p, root));

    var tampered = p;
    tampered.poap.claim_unix_s = 9999;
    try std.testing.expect(!verifyPoap(tampered, root));
}

test "proveWork round-trips for public and private works" {
    const a = std.testing.allocator;
    const facet = CulturalFacet{
        .poaps = &[_]Poap{.{ .event_id = dummyHash(40), .event_unix_s = 100, .claim_unix_s = 101 }},
        .notarized_works = &[_]NotarizedWork{
            .{ .work_hash = dummyHash(50), .kind = .poem, .notarized_unix_s = 1, .is_public = true },
            .{ .work_hash = dummyHash(51), .kind = .visual, .notarized_unix_s = 2, .is_public = false },
            .{ .work_hash = dummyHash(52), .kind = .translation, .notarized_unix_s = 3, .is_public = true },
        },
        .cultural_badges = &[_]u32{ 2, 4 },
        .language_tags = "endeit",
    };
    const root = try computeCulturalRoot(facet, a);
    for (0..3) |i| {
        const w = try proveWork(facet, i, a);
        defer a.free(w.proof);
        try std.testing.expect(verifyWork(w, root));
    }
}

test "empty facet produces a non-zero root" {
    const a = std.testing.allocator;
    const empty = CulturalFacet{
        .poaps = &[_]Poap{},
        .notarized_works = &[_]NotarizedWork{},
        .cultural_badges = &[_]u32{},
        .language_tags = "",
    };
    const r = try computeCulturalRoot(empty, a);
    try std.testing.expect(!std.mem.eql(u8, &r, &ZERO_LEAF));
}
