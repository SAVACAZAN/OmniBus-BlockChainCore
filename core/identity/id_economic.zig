//! id_economic.zig — Economic Profile facet for the OmniBus ID layer.
//!
//! WHY this facet is separate:
//!   * Regulatory commitments (MiCA in EU, plus AML/KYC attestations) must
//!     be cryptographically bound to the holder's identity at a fixed point
//!     in time, independent of the chain's live financial state.
//!   * Per-category visibility. A holder may want to publish their issuer
//!     status and AML attestation while keeping declared volumes private,
//!     or expose donation history for transparency without leaking the
//!     full list of wallet addresses.
//!   * Selective disclosure of one address / one donation. Each address and
//!     each donation is its own leaf in a sub-tree, so a verifier can be
//!     given a Merkle proof for exactly one item without learning the rest.
//!
//! The top-level layout is a 6-leaf tree:
//!   [addresses_subroot, donations_subroot, volumes_leaf, mica_leaf, aml_leaf, kyc_leaf]
//! Visibility is hashed into each *category* leaf (not as a separate leaf)
//! by including the visibility_mask in the canonical preimage of every
//! category, so the mask cannot be retroactively edited.

const std = @import("std");
const Sha256 = std.crypto.hash.sha2.Sha256;
const merkle = @import("id_merkle.zig");

pub const ChainKind = enum(u8) {
    omni = 0,
    bitcoin = 1,
    ethereum = 2,
    solana = 3,
    base = 4,
    polygon = 5,
    other = 99,
};

pub const PublicAddress = struct {
    chain: ChainKind,
    address_hash: [32]u8, // sha256 of the address string
    is_public: bool,
    added_unix_s: u64,
};

pub const PublicDonation = struct {
    tx_hash: [32]u8,
    amount_sat: u64,
    memo_hash: [32]u8,
    received_unix_s: u64,
    is_public: bool,
};

pub const MicaRiskCategory = enum(u8) {
    none = 0,
    low = 1,
    medium = 2,
    high = 3,
    asset_referenced = 4,
    emoney_token = 5,
};

pub const MicaDisclosure = struct {
    is_issuer: bool,
    white_paper_hash: [32]u8, // zero if not issuer
    risk_category: MicaRiskCategory,
    issuer_legal_entity_hash: [32]u8, // hashed legal name
};

pub const AmlAttestation = struct {
    sanctions_screened: bool,
    screening_date_unix_s: u64,
    issuer_did_hash: [32]u8, // who screened (self if all zeros)
    signature: [64]u8, // issuer signature, zeros if self-attested
};

pub const KycAttestation = struct {
    is_verified: bool,
    valid_until_unix_s: u64,
    issuer_did_hash: [32]u8, // KYC provider DID, zero if self
    signature: [64]u8,
};

pub const EconomicFacet = struct {
    public_addresses: []const PublicAddress,
    public_donations: []const PublicDonation,
    declared_volume_30d_sat: u64, // user-declared, 0 if not disclosed
    declared_volume_90d_sat: u64,
    declared_volume_1y_sat: u64,
    mica: MicaDisclosure,
    aml: AmlAttestation,
    kyc: KycAttestation,
    /// bit per category: addresses=0, donations=1, volume=2, mica=3, aml=4, kyc=5
    visibility_mask: u8,
};

pub const VIS_ADDRESSES: u8 = 1 << 0;
pub const VIS_DONATIONS: u8 = 1 << 1;
pub const VIS_VOLUME: u8 = 1 << 2;
pub const VIS_MICA: u8 = 1 << 3;
pub const VIS_AML: u8 = 1 << 4;
pub const VIS_KYC: u8 = 1 << 5;

const ZERO_LEAF: merkle.Hash = [_]u8{0} ** 32;

// ---------------------------------------------------------------------------
// Canonical leaf serializers (deterministic byte preimages).
// ---------------------------------------------------------------------------

/// 42-byte preimage: chain(1) || address_hash(32) || is_public(1) || added_unix_s(8)
fn addressLeafBytes(a: PublicAddress) [42]u8 {
    var buf: [42]u8 = undefined;
    buf[0] = @intFromEnum(a.chain);
    @memcpy(buf[1..33], &a.address_hash);
    buf[33] = if (a.is_public) 1 else 0;
    std.mem.writeInt(u64, buf[34..42], a.added_unix_s, .little);
    return buf;
}

fn addressLeafHash(a: PublicAddress) merkle.Hash {
    if (a.is_public) {
        const buf = addressLeafBytes(a);
        return merkle.hashLeaf(&buf);
    }
    // Private address — commit only an opaque salted hash so two private
    // addresses cannot be distinguished by their leaves.
    var inner: [32 + 15]u8 = undefined;
    @memcpy(inner[0..32], &a.address_hash);
    @memcpy(inner[32..47], "private_address");
    var redacted: [32]u8 = undefined;
    Sha256.hash(&inner, &redacted, .{});
    return merkle.hashLeaf(&redacted);
}

/// 81-byte preimage: tx_hash(32) || amount_sat(8) || memo_hash(32) || received_unix_s(8) || is_public(1)
fn donationLeafBytes(d: PublicDonation) [81]u8 {
    var buf: [81]u8 = undefined;
    @memcpy(buf[0..32], &d.tx_hash);
    std.mem.writeInt(u64, buf[32..40], d.amount_sat, .little);
    @memcpy(buf[40..72], &d.memo_hash);
    std.mem.writeInt(u64, buf[72..80], d.received_unix_s, .little);
    buf[80] = if (d.is_public) 1 else 0;
    return buf;
}

fn donationLeafHash(d: PublicDonation) merkle.Hash {
    if (d.is_public) {
        const buf = donationLeafBytes(d);
        return merkle.hashLeaf(&buf);
    }
    var inner: [32 + 16]u8 = undefined;
    @memcpy(inner[0..32], &d.tx_hash);
    @memcpy(inner[32..48], "private_donation");
    var redacted: [32]u8 = undefined;
    Sha256.hash(&inner, &redacted, .{});
    return merkle.hashLeaf(&redacted);
}

/// 25-byte preimage: vol30(8) || vol90(8) || vol1y(8) || vis(1)
fn volumesLeafBytes(facet: EconomicFacet) [25]u8 {
    var buf: [25]u8 = undefined;
    std.mem.writeInt(u64, buf[0..8], facet.declared_volume_30d_sat, .little);
    std.mem.writeInt(u64, buf[8..16], facet.declared_volume_90d_sat, .little);
    std.mem.writeInt(u64, buf[16..24], facet.declared_volume_1y_sat, .little);
    buf[24] = facet.visibility_mask;
    return buf;
}

/// 66-byte preimage: is_issuer(1) || white_paper_hash(32) || risk(1) || legal_hash(32)
fn micaLeafBytes(m: MicaDisclosure) [66]u8 {
    var buf: [66]u8 = undefined;
    buf[0] = if (m.is_issuer) 1 else 0;
    @memcpy(buf[1..33], &m.white_paper_hash);
    buf[33] = @intFromEnum(m.risk_category);
    @memcpy(buf[34..66], &m.issuer_legal_entity_hash);
    return buf;
}

/// 105-byte preimage: screened(1) || date(8) || issuer_did(32) || signature(64)
fn amlLeafBytes(a: AmlAttestation) [105]u8 {
    var buf: [105]u8 = undefined;
    buf[0] = if (a.sanctions_screened) 1 else 0;
    std.mem.writeInt(u64, buf[1..9], a.screening_date_unix_s, .little);
    @memcpy(buf[9..41], &a.issuer_did_hash);
    @memcpy(buf[41..105], &a.signature);
    return buf;
}

/// 105-byte preimage: verified(1) || valid_until(8) || issuer_did(32) || signature(64)
fn kycLeafBytes(k: KycAttestation) [105]u8 {
    var buf: [105]u8 = undefined;
    buf[0] = if (k.is_verified) 1 else 0;
    std.mem.writeInt(u64, buf[1..9], k.valid_until_unix_s, .little);
    @memcpy(buf[9..41], &k.issuer_did_hash);
    @memcpy(buf[41..105], &k.signature);
    return buf;
}

// ---------------------------------------------------------------------------
// Sub-roots and top-level tree
// ---------------------------------------------------------------------------

fn addressesSubroot(facet: EconomicFacet, allocator: std.mem.Allocator) !merkle.Hash {
    if (facet.public_addresses.len == 0) return merkle.hashLeaf(&ZERO_LEAF);
    const leaves = try allocator.alloc(merkle.Hash, facet.public_addresses.len);
    defer allocator.free(leaves);
    for (facet.public_addresses, 0..) |a, i| leaves[i] = addressLeafHash(a);
    return merkle.rootOfLeafHashes(leaves, allocator);
}

fn donationsSubroot(facet: EconomicFacet, allocator: std.mem.Allocator) !merkle.Hash {
    if (facet.public_donations.len == 0) return merkle.hashLeaf(&ZERO_LEAF);
    const leaves = try allocator.alloc(merkle.Hash, facet.public_donations.len);
    defer allocator.free(leaves);
    for (facet.public_donations, 0..) |d, i| leaves[i] = donationLeafHash(d);
    return merkle.rootOfLeafHashes(leaves, allocator);
}

/// 6-leaf top tree in canonical order:
/// [addresses, donations, volumes, mica, aml, kyc]
fn topLeaves(facet: EconomicFacet, allocator: std.mem.Allocator) ![6]merkle.Hash {
    const addr_sub = try addressesSubroot(facet, allocator);
    const don_sub = try donationsSubroot(facet, allocator);

    const vol_buf = volumesLeafBytes(facet);
    const volumes_leaf = merkle.hashLeaf(&vol_buf);

    const mica_buf = micaLeafBytes(facet.mica);
    const mica_leaf = merkle.hashLeaf(&mica_buf);

    const aml_buf = amlLeafBytes(facet.aml);
    const aml_leaf = merkle.hashLeaf(&aml_buf);

    const kyc_buf = kycLeafBytes(facet.kyc);
    const kyc_leaf = merkle.hashLeaf(&kyc_buf);

    return .{ addr_sub, don_sub, volumes_leaf, mica_leaf, aml_leaf, kyc_leaf };
}

pub fn computeEconomicRoot(facet: EconomicFacet, allocator: std.mem.Allocator) ![32]u8 {
    const tops = try topLeaves(facet, allocator);
    return merkle.rootOfLeafHashes(&tops, allocator);
}

// ---------------------------------------------------------------------------
// Per-address / per-donation proofs
// ---------------------------------------------------------------------------

pub const AddressProof = struct {
    address: PublicAddress,
    /// Combined proof: inner steps inside the addresses sub-tree, then outer
    /// steps lifting the sub-root to the facet root (sub-root is leaf 0).
    proof: []merkle.ProofStep,
};

pub const DonationProof = struct {
    donation: PublicDonation,
    /// Donations sub-root is leaf 1 in the top tree.
    proof: []merkle.ProofStep,
};

pub fn proveAddress(
    facet: EconomicFacet,
    address_index: usize,
    allocator: std.mem.Allocator,
) !AddressProof {
    if (address_index >= facet.public_addresses.len) return error.IndexOutOfRange;

    const leaves = try allocator.alloc(merkle.Hash, facet.public_addresses.len);
    defer allocator.free(leaves);
    for (facet.public_addresses, 0..) |a, i| leaves[i] = addressLeafHash(a);

    const inner = try merkle.proveLeaf(leaves, address_index, allocator);
    defer allocator.free(inner);

    const tops = try topLeaves(facet, allocator);
    const outer = try merkle.proveLeaf(&tops, 0, allocator);
    defer allocator.free(outer);

    var combined = try allocator.alloc(merkle.ProofStep, inner.len + outer.len);
    @memcpy(combined[0..inner.len], inner);
    @memcpy(combined[inner.len..], outer);

    return .{ .address = facet.public_addresses[address_index], .proof = combined };
}

pub fn verifyAddress(proof: AddressProof, facet_root: [32]u8) bool {
    const leaf = addressLeafHash(proof.address);
    return merkle.verifyProof(leaf, proof.proof, facet_root);
}

pub fn proveDonation(
    facet: EconomicFacet,
    donation_index: usize,
    allocator: std.mem.Allocator,
) !DonationProof {
    if (donation_index >= facet.public_donations.len) return error.IndexOutOfRange;

    const leaves = try allocator.alloc(merkle.Hash, facet.public_donations.len);
    defer allocator.free(leaves);
    for (facet.public_donations, 0..) |d, i| leaves[i] = donationLeafHash(d);

    const inner = try merkle.proveLeaf(leaves, donation_index, allocator);
    defer allocator.free(inner);

    const tops = try topLeaves(facet, allocator);
    const outer = try merkle.proveLeaf(&tops, 1, allocator);
    defer allocator.free(outer);

    var combined = try allocator.alloc(merkle.ProofStep, inner.len + outer.len);
    @memcpy(combined[0..inner.len], inner);
    @memcpy(combined[inner.len..], outer);

    return .{ .donation = facet.public_donations[donation_index], .proof = combined };
}

pub fn verifyDonation(proof: DonationProof, facet_root: [32]u8) bool {
    const leaf = donationLeafHash(proof.donation);
    return merkle.verifyProof(leaf, proof.proof, facet_root);
}

/// A KYC attestation is currently valid if `is_verified` and `valid_until`
/// is either 0 (never expires) or strictly greater than `now_unix_s`.
pub fn isKycCurrentlyValid(kyc: KycAttestation, now_unix_s: u64) bool {
    if (!kyc.is_verified) return false;
    if (kyc.valid_until_unix_s == 0) return true;
    return kyc.valid_until_unix_s > now_unix_s;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn dummyAddress(seed: u8, public: bool) PublicAddress {
    return .{
        .chain = .omni,
        .address_hash = [_]u8{seed} ** 32,
        .is_public = public,
        .added_unix_s = 1_700_000_000 + @as(u64, seed),
    };
}

fn dummyDonation(seed: u8, public: bool) PublicDonation {
    return .{
        .tx_hash = [_]u8{seed +% 1} ** 32,
        .amount_sat = @as(u64, seed) * 1_000_000,
        .memo_hash = [_]u8{seed +% 2} ** 32,
        .received_unix_s = 1_700_000_000 + @as(u64, seed),
        .is_public = public,
    };
}

fn dummyMica(issuer: bool) MicaDisclosure {
    return .{
        .is_issuer = issuer,
        .white_paper_hash = if (issuer) [_]u8{0xAB} ** 32 else [_]u8{0} ** 32,
        .risk_category = if (issuer) MicaRiskCategory.medium else MicaRiskCategory.none,
        .issuer_legal_entity_hash = if (issuer) [_]u8{0xCD} ** 32 else [_]u8{0} ** 32,
    };
}

fn dummyAml(screened: bool) AmlAttestation {
    return .{
        .sanctions_screened = screened,
        .screening_date_unix_s = if (screened) 1_750_000_000 else 0,
        .issuer_did_hash = [_]u8{0} ** 32,
        .signature = [_]u8{0} ** 64,
    };
}

fn dummyKyc(verified: bool, valid_until: u64) KycAttestation {
    return .{
        .is_verified = verified,
        .valid_until_unix_s = valid_until,
        .issuer_did_hash = [_]u8{0} ** 32,
        .signature = [_]u8{0} ** 64,
    };
}

fn emptyFacet() EconomicFacet {
    return .{
        .public_addresses = &.{},
        .public_donations = &.{},
        .declared_volume_30d_sat = 0,
        .declared_volume_90d_sat = 0,
        .declared_volume_1y_sat = 0,
        .mica = dummyMica(false),
        .aml = dummyAml(false),
        .kyc = dummyKyc(false, 0),
        .visibility_mask = 0,
    };
}

test "empty economic facet has deterministic non-zero root" {
    const f = emptyFacet();
    const r1 = try computeEconomicRoot(f, std.testing.allocator);
    const r2 = try computeEconomicRoot(f, std.testing.allocator);
    try std.testing.expectEqualSlices(u8, &r1, &r2);
    try std.testing.expect(!std.mem.eql(u8, &r1, &([_]u8{0} ** 32)));
}

test "single public address proof round-trips and tamper fails" {
    const addrs = [_]PublicAddress{ dummyAddress(1, true), dummyAddress(2, true), dummyAddress(3, false) };
    var f = emptyFacet();
    f.public_addresses = &addrs;
    f.visibility_mask = VIS_ADDRESSES;

    const root = try computeEconomicRoot(f, std.testing.allocator);

    const proof = try proveAddress(f, 1, std.testing.allocator);
    defer std.testing.allocator.free(proof.proof);
    try std.testing.expect(verifyAddress(proof, root));

    var bad = proof;
    bad.address.added_unix_s ^= 1;
    try std.testing.expect(!verifyAddress(bad, root));
}

test "MiCA disclosure is bound into the facet root" {
    var fa = emptyFacet();
    var fb = emptyFacet();
    fa.mica = dummyMica(false);
    fb.mica = dummyMica(true);
    fb.visibility_mask = VIS_MICA;

    const ra = try computeEconomicRoot(fa, std.testing.allocator);
    const rb = try computeEconomicRoot(fb, std.testing.allocator);
    try std.testing.expect(!std.mem.eql(u8, &ra, &rb));
}

test "isKycCurrentlyValid handles verified, unverified, never-expires and expired" {
    try std.testing.expect(!isKycCurrentlyValid(dummyKyc(false, 9_999_999_999), 1_000));
    try std.testing.expect(isKycCurrentlyValid(dummyKyc(true, 0), 9_999_999_999));
    try std.testing.expect(isKycCurrentlyValid(dummyKyc(true, 2_000_000_000), 1_900_000_000));
    try std.testing.expect(!isKycCurrentlyValid(dummyKyc(true, 1_500_000_000), 1_900_000_000));
}

test "tampered donation amount fails verification" {
    const dons = [_]PublicDonation{ dummyDonation(1, true), dummyDonation(2, true) };
    var f = emptyFacet();
    f.public_donations = &dons;
    f.visibility_mask = VIS_DONATIONS;
    const root = try computeEconomicRoot(f, std.testing.allocator);

    const proof = try proveDonation(f, 0, std.testing.allocator);
    defer std.testing.allocator.free(proof.proof);
    try std.testing.expect(verifyDonation(proof, root));

    var bad = proof;
    bad.donation.amount_sat +%= 1;
    try std.testing.expect(!verifyDonation(bad, root));
}

test "visibility_mask changes the root (anti-equivocation)" {
    var fa = emptyFacet();
    var fb = emptyFacet();
    fa.declared_volume_30d_sat = 1_000_000;
    fb.declared_volume_30d_sat = 1_000_000;
    fa.visibility_mask = 0;
    fb.visibility_mask = VIS_VOLUME | VIS_KYC;

    const ra = try computeEconomicRoot(fa, std.testing.allocator);
    const rb = try computeEconomicRoot(fb, std.testing.allocator);
    try std.testing.expect(!std.mem.eql(u8, &ra, &rb));
}

test "multi-category root differs from empty" {
    const addrs = [_]PublicAddress{dummyAddress(7, true)};
    const dons = [_]PublicDonation{dummyDonation(8, true)};
    var f = emptyFacet();
    f.public_addresses = &addrs;
    f.public_donations = &dons;
    f.declared_volume_1y_sat = 42_000_000_000;
    f.mica = dummyMica(true);
    f.aml = dummyAml(true);
    f.kyc = dummyKyc(true, 2_000_000_000);
    f.visibility_mask = VIS_ADDRESSES | VIS_DONATIONS | VIS_VOLUME | VIS_MICA | VIS_AML | VIS_KYC;

    const r_full = try computeEconomicRoot(f, std.testing.allocator);
    const r_empty = try computeEconomicRoot(emptyFacet(), std.testing.allocator);
    try std.testing.expect(!std.mem.eql(u8, &r_full, &r_empty));
}

test "two public addresses: each proves independently against the same root" {
    const addrs = [_]PublicAddress{ dummyAddress(11, true), dummyAddress(12, true), dummyAddress(13, true), dummyAddress(14, true) };
    var f = emptyFacet();
    f.public_addresses = &addrs;
    f.visibility_mask = VIS_ADDRESSES;
    const root = try computeEconomicRoot(f, std.testing.allocator);

    for (0..addrs.len) |i| {
        const proof = try proveAddress(f, i, std.testing.allocator);
        defer std.testing.allocator.free(proof.proof);
        try std.testing.expect(verifyAddress(proof, root));
    }
}
