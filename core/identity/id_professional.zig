//! id_professional.zig — Professional (LinkedIn-style) facet of OmniBus ID.
//!
//! WHY this facet is separate from the KYC facet:
//!   * Different access controls. KYC attestations are released only to
//!     regulated counterparties (exchanges, banks) after a strong
//!     out-of-band check. Professional attestations — degrees, employment,
//!     certifications, endorsements — are meant to be *discoverable* by
//!     recruiters, clients, DAO grant committees, etc. Mixing them in one
//!     Merkle subtree would force a single visibility policy.
//!   * LinkedIn-style selective disclosure. A holder can prove "I graduated
//!     from MIT in 2019" without revealing their tax ID, home address, or
//!     the rest of the CV. Each certification / work entry is its own leaf,
//!     so a Merkle proof exposes exactly one item.
//!   * Discoverability bitmask is part of the commitment. The visibility
//!     mask itself is hashed into the facet root, so a holder cannot
//!     equivocate ("I never marked X as public") after the fact.
//!
//! Cleartext attestations stay in the holder's vault; the chain only
//! stores this facet root (one 32-byte hash) inside the master Manifest.

const std = @import("std");
const Sha256 = std.crypto.hash.sha2.Sha256;
const merkle = @import("id_merkle.zig");

pub const Certification = struct {
    issuer_did_hash: [32]u8,
    subject_did_hash: [32]u8,
    credential_kind: u32, // degree=1, cert=2, license=3, ... issuer-defined
    issued_at_unix_s: u64,
    expires_at_unix_s: u64, // 0 = never expires
    hash: [32]u8, // SHA-256 of the full credential document
};

pub const WorkEntry = struct {
    employer_did_hash: [32]u8,
    started_unix_s: u64,
    ended_unix_s: u64, // 0 = current position
    role_hash: [32]u8,
};

pub const ProfessionalFacet = struct {
    certifications: []const Certification,
    work_history: []const WorkEntry,
    endorsements_count: u32,
    visibility_mask: u8,
};

pub const VIS_CERTIFICATIONS: u8 = 1 << 0;
pub const VIS_WORK_HISTORY: u8 = 1 << 1;
pub const VIS_ENDORSEMENTS: u8 = 1 << 2;

const ZERO_LEAF: merkle.Hash = [_]u8{0} ** 32;

/// Serialize one certification into its 136-byte canonical leaf preimage.
fn certLeafBytes(c: Certification) [136]u8 {
    var buf: [136]u8 = undefined;
    @memcpy(buf[0..32], &c.issuer_did_hash);
    @memcpy(buf[32..64], &c.subject_did_hash);
    std.mem.writeInt(u32, buf[64..68], c.credential_kind, .little);
    std.mem.writeInt(u64, buf[68..76], c.issued_at_unix_s, .little);
    std.mem.writeInt(u64, buf[76..84], c.expires_at_unix_s, .little);
    @memcpy(buf[84..116], &c.hash);
    // Pad the remaining 20 bytes — but we only use 116. Zero out tail.
    @memset(buf[116..136], 0);
    return buf;
}

/// Serialize one work entry into its 104-byte canonical leaf preimage.
fn workLeafBytes(w: WorkEntry) [104]u8 {
    var buf: [104]u8 = undefined;
    @memcpy(buf[0..32], &w.employer_did_hash);
    std.mem.writeInt(u64, buf[32..40], w.started_unix_s, .little);
    std.mem.writeInt(u64, buf[40..48], w.ended_unix_s, .little);
    @memcpy(buf[48..80], &w.role_hash);
    @memset(buf[80..104], 0);
    return buf;
}

fn certLeafHash(c: Certification) merkle.Hash {
    const buf = certLeafBytes(c);
    return merkle.hashLeaf(&buf);
}

fn workLeafHash(w: WorkEntry) merkle.Hash {
    const buf = workLeafBytes(w);
    return merkle.hashLeaf(&buf);
}

/// Build the 4-leaf top-level tree:
///   [certifications_subroot, work_subroot, endorsements_leaf, visibility_leaf]
fn topLeaves(facet: ProfessionalFacet, allocator: std.mem.Allocator) ![4]merkle.Hash {
    // Certifications subtree.
    var cert_subroot: merkle.Hash = ZERO_LEAF;
    if (facet.certifications.len > 0) {
        var cert_leaves = try allocator.alloc(merkle.Hash, facet.certifications.len);
        defer allocator.free(cert_leaves);
        for (facet.certifications, 0..) |c, i| cert_leaves[i] = certLeafHash(c);
        cert_subroot = try merkle.rootOfLeafHashes(cert_leaves, allocator);
    }

    // Work history subtree.
    var work_subroot: merkle.Hash = ZERO_LEAF;
    if (facet.work_history.len > 0) {
        var work_leaves = try allocator.alloc(merkle.Hash, facet.work_history.len);
        defer allocator.free(work_leaves);
        for (facet.work_history, 0..) |w, i| work_leaves[i] = workLeafHash(w);
        work_subroot = try merkle.rootOfLeafHashes(work_leaves, allocator);
    }

    // Endorsements leaf = hashLeaf(u32 LE).
    var endorse_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &endorse_buf, facet.endorsements_count, .little);
    const endorsements_leaf = merkle.hashLeaf(&endorse_buf);

    // Visibility leaf = hashLeaf([mask]).
    const visibility_leaf = merkle.hashLeaf(&[_]u8{facet.visibility_mask});

    return .{ cert_subroot, work_subroot, endorsements_leaf, visibility_leaf };
}

pub fn computeProfessionalRoot(
    facet: ProfessionalFacet,
    allocator: std.mem.Allocator,
) ![32]u8 {
    const tops = try topLeaves(facet, allocator);
    return merkle.rootOfLeafHashes(&tops, allocator);
}

pub const CertProof = struct {
    cert: Certification,
    /// Combined proof: first the in-subtree steps for this cert leaf, then
    /// the top-level steps lifting the cert subroot to the facet root.
    proof: []merkle.ProofStep,
};

pub fn proveCertification(
    facet: ProfessionalFacet,
    cert_index: usize,
    allocator: std.mem.Allocator,
) !CertProof {
    if (cert_index >= facet.certifications.len) return error.IndexOutOfRange;

    // Inner proof inside the certifications subtree.
    var cert_leaves = try allocator.alloc(merkle.Hash, facet.certifications.len);
    defer allocator.free(cert_leaves);
    for (facet.certifications, 0..) |c, i| cert_leaves[i] = certLeafHash(c);

    const inner = try merkle.proveLeaf(cert_leaves, cert_index, allocator);
    defer allocator.free(inner);

    // Outer proof: cert subroot is leaf 0 of the top-level 4-leaf tree.
    const tops = try topLeaves(facet, allocator);
    const outer = try merkle.proveLeaf(&tops, 0, allocator);
    defer allocator.free(outer);

    var combined = try allocator.alloc(merkle.ProofStep, inner.len + outer.len);
    @memcpy(combined[0..inner.len], inner);
    @memcpy(combined[inner.len..], outer);

    return .{ .cert = facet.certifications[cert_index], .proof = combined };
}

pub fn verifyCertification(proof: CertProof, facet_root: [32]u8) bool {
    const leaf = certLeafHash(proof.cert);
    return merkle.verifyProof(leaf, proof.proof, facet_root);
}

/// A certification is currently valid if its expiry is 0 (never) or is
/// strictly in the future relative to `now_unix_s`.
pub fn isCertCurrentlyValid(cert: Certification, now_unix_s: u64) bool {
    if (cert.expires_at_unix_s == 0) return true;
    return cert.expires_at_unix_s > now_unix_s;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn dummyCert(seed: u8) Certification {
    const c: Certification = .{
        .issuer_did_hash = [_]u8{seed} ** 32,
        .subject_did_hash = [_]u8{seed +% 1} ** 32,
        .credential_kind = @as(u32, seed),
        .issued_at_unix_s = 1_700_000_000,
        .expires_at_unix_s = 1_900_000_000,
        .hash = [_]u8{seed +% 2} ** 32,
    };
    return c;
}

fn dummyWork(seed: u8) WorkEntry {
    return .{
        .employer_did_hash = [_]u8{seed +% 10} ** 32,
        .started_unix_s = 1_600_000_000,
        .ended_unix_s = 0,
        .role_hash = [_]u8{seed +% 11} ** 32,
    };
}

test "computeProfessionalRoot is deterministic" {
    const certs = [_]Certification{ dummyCert(1), dummyCert(2) };
    const works = [_]WorkEntry{dummyWork(1)};
    const f: ProfessionalFacet = .{
        .certifications = &certs,
        .work_history = &works,
        .endorsements_count = 42,
        .visibility_mask = VIS_CERTIFICATIONS,
    };
    const r1 = try computeProfessionalRoot(f, std.testing.allocator);
    const r2 = try computeProfessionalRoot(f, std.testing.allocator);
    try std.testing.expectEqualSlices(u8, &r1, &r2);
}

test "adding a certification changes the root" {
    const certs_a = [_]Certification{dummyCert(1)};
    const certs_b = [_]Certification{ dummyCert(1), dummyCert(2) };
    const works = [_]WorkEntry{};
    const fa: ProfessionalFacet = .{ .certifications = &certs_a, .work_history = &works, .endorsements_count = 0, .visibility_mask = 0 };
    const fb: ProfessionalFacet = .{ .certifications = &certs_b, .work_history = &works, .endorsements_count = 0, .visibility_mask = 0 };
    const ra = try computeProfessionalRoot(fa, std.testing.allocator);
    const rb = try computeProfessionalRoot(fb, std.testing.allocator);
    try std.testing.expect(!std.mem.eql(u8, &ra, &rb));
}

test "adding a work entry changes the root" {
    const certs = [_]Certification{dummyCert(1)};
    const works_a = [_]WorkEntry{};
    const works_b = [_]WorkEntry{dummyWork(3)};
    const fa: ProfessionalFacet = .{ .certifications = &certs, .work_history = &works_a, .endorsements_count = 0, .visibility_mask = 0 };
    const fb: ProfessionalFacet = .{ .certifications = &certs, .work_history = &works_b, .endorsements_count = 0, .visibility_mask = 0 };
    const ra = try computeProfessionalRoot(fa, std.testing.allocator);
    const rb = try computeProfessionalRoot(fb, std.testing.allocator);
    try std.testing.expect(!std.mem.eql(u8, &ra, &rb));
}

test "changing visibility_mask changes the root" {
    const certs = [_]Certification{dummyCert(1)};
    const works = [_]WorkEntry{dummyWork(1)};
    const fa: ProfessionalFacet = .{ .certifications = &certs, .work_history = &works, .endorsements_count = 5, .visibility_mask = 0 };
    const fb: ProfessionalFacet = .{ .certifications = &certs, .work_history = &works, .endorsements_count = 5, .visibility_mask = VIS_CERTIFICATIONS | VIS_WORK_HISTORY };
    const ra = try computeProfessionalRoot(fa, std.testing.allocator);
    const rb = try computeProfessionalRoot(fb, std.testing.allocator);
    try std.testing.expect(!std.mem.eql(u8, &ra, &rb));
}

test "proveCertification + verifyCertification round-trip and tamper detection" {
    const certs = [_]Certification{ dummyCert(1), dummyCert(2), dummyCert(3) };
    const works = [_]WorkEntry{dummyWork(7)};
    const f: ProfessionalFacet = .{
        .certifications = &certs,
        .work_history = &works,
        .endorsements_count = 11,
        .visibility_mask = VIS_CERTIFICATIONS,
    };
    const root = try computeProfessionalRoot(f, std.testing.allocator);

    for (0..certs.len) |i| {
        const proof = try proveCertification(f, i, std.testing.allocator);
        defer std.testing.allocator.free(proof.proof);
        try std.testing.expect(verifyCertification(proof, root));

        // Tamper with the cert payload — verification must fail.
        var bad = proof;
        bad.cert.credential_kind = proof.cert.credential_kind +% 1;
        try std.testing.expect(!verifyCertification(bad, root));
    }
}

test "isCertCurrentlyValid handles valid, expired, and never-expires" {
    var c = dummyCert(5);
    c.expires_at_unix_s = 2_000_000_000;
    try std.testing.expect(isCertCurrentlyValid(c, 1_800_000_000));
    try std.testing.expect(!isCertCurrentlyValid(c, 2_100_000_000));

    c.expires_at_unix_s = 0;
    try std.testing.expect(isCertCurrentlyValid(c, 9_999_999_999));
}

test "empty facet still produces a non-zero root" {
    const certs = [_]Certification{};
    const works = [_]WorkEntry{};
    const f: ProfessionalFacet = .{
        .certifications = &certs,
        .work_history = &works,
        .endorsements_count = 0,
        .visibility_mask = 0,
    };
    const r = try computeProfessionalRoot(f, std.testing.allocator);
    try std.testing.expect(!std.mem.eql(u8, &r, &([_]u8{0} ** 32)));
}
