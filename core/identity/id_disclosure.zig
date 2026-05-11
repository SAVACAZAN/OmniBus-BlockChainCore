//! id_disclosure.zig — Selective Disclosure proofs.
//!
//! The holder anchors only the Merkle root on chain. When a verifier asks
//! "show me your reputation but not your KYC", the holder produces the
//! reputation field bytes + an inclusion proof. The verifier checks the
//! proof against the on-chain root — fields the holder DOESN'T disclose
//! stay opaque (the verifier only sees their sibling hashes).
//!
//! Domain separation in id_merkle.hashLeaf prevents an attacker from
//! claiming an internal node hash is a "leaf" they revealed.

const std = @import("std");
const merkle = @import("id_merkle.zig");
const types = @import("id_types.zig");
const manifest_mod = @import("id_manifest.zig");

/// One disclosed (field_index, raw_bytes, inclusion_proof) tuple. The
/// verifier hashes raw_bytes with merkle.hashLeaf and walks the proof.
pub const Disclosure = struct {
    field: types.FieldIndex,
    raw_bytes: []const u8,
    proof: []merkle.ProofStep,
};

/// Bundle returned to the verifier: the root they're checking against,
/// plus one Disclosure per requested field. Caller frees with `free`.
pub const DisclosureBundle = struct {
    root: types.ManifestRoot,
    disclosures: []Disclosure,

    pub fn free(self: *DisclosureBundle, allocator: std.mem.Allocator) void {
        for (self.disclosures) |d| {
            allocator.free(d.raw_bytes);
            allocator.free(d.proof);
        }
        allocator.free(self.disclosures);
    }
};

/// Build the canonical raw bytes for each FieldIndex. Matches the bytes
/// passed to `hashLeaf` inside `id_manifest.computeLeafHashes` — verifier
/// uses the exact same serialization to recompute the leaf hash.
fn fieldBytes(
    field: types.FieldIndex,
    manifest: manifest_mod.Manifest,
    allocator: std.mem.Allocator,
) ![]u8 {
    return switch (field) {
        .kyc_hash    => try allocator.dupe(u8, &manifest.kyc_hash),
        .assets_root => try allocator.dupe(u8, &manifest.assets_root),
        .reputation_snapshot => blk: {
            const rep = manifest_mod.serializeReputationField(manifest.reputation);
            break :blk try allocator.dupe(u8, &rep);
        },
        .pq_keys_hash => blk: {
            const h = manifest_mod.hashPqKeys(manifest.pq_pubkeys_concat);
            break :blk try allocator.dupe(u8, &h);
        },
        .obm => blk: {
            const b = [_]u8{manifest.obm};
            break :blk try allocator.dupe(u8, &b);
        },
        .timestamp => blk: {
            var b: [8]u8 = undefined;
            std.mem.writeInt(u64, &b, manifest.timestamp_unix_s, .little);
            break :blk try allocator.dupe(u8, &b);
        },
        .social_root       => try allocator.dupe(u8, &manifest.social_root),
        .professional_root => try allocator.dupe(u8, &manifest.professional_root),
        .cultural_root     => try allocator.dupe(u8, &manifest.cultural_root),
        .economic_root     => try allocator.dupe(u8, &manifest.economic_root),
    };
}

/// Holder side: assemble proofs for every field the verifier asked for.
/// Fields not requested are simply omitted — their hash still contributes
/// to the root the verifier knows, but the verifier never sees the bytes.
pub fn discloseFields(
    manifest: manifest_mod.Manifest,
    request: types.DisclosureRequest,
    allocator: std.mem.Allocator,
) !DisclosureBundle {
    const leaves = manifest_mod.computeLeafHashes(manifest);
    const root = try merkle.rootOfLeafHashes(&leaves, allocator);

    var disclosures = std.array_list.Managed(Disclosure).init(allocator);
    errdefer {
        for (disclosures.items) |d| {
            allocator.free(d.raw_bytes);
            allocator.free(d.proof);
        }
        disclosures.deinit();
    }

    if (request.wants_kyc)          try addOne(&disclosures, .kyc_hash, manifest, &leaves, allocator);
    if (request.wants_assets)       try addOne(&disclosures, .assets_root, manifest, &leaves, allocator);
    if (request.wants_reputation)   try addOne(&disclosures, .reputation_snapshot, manifest, &leaves, allocator);
    if (request.wants_pq)           try addOne(&disclosures, .pq_keys_hash, manifest, &leaves, allocator);
    if (request.wants_obm)          try addOne(&disclosures, .obm, manifest, &leaves, allocator);
    if (request.wants_social)       try addOne(&disclosures, .social_root, manifest, &leaves, allocator);
    if (request.wants_professional) try addOne(&disclosures, .professional_root, manifest, &leaves, allocator);
    if (request.wants_cultural)     try addOne(&disclosures, .cultural_root, manifest, &leaves, allocator);
    if (request.wants_economic)     try addOne(&disclosures, .economic_root, manifest, &leaves, allocator);

    return DisclosureBundle{
        .root = root,
        .disclosures = try disclosures.toOwnedSlice(),
    };
}

fn addOne(
    list: *std.array_list.Managed(Disclosure),
    field: types.FieldIndex,
    manifest: manifest_mod.Manifest,
    leaves: *const [types.FIELD_COUNT]merkle.Hash,
    allocator: std.mem.Allocator,
) !void {
    const bytes = try fieldBytes(field, manifest, allocator);
    errdefer allocator.free(bytes);
    const proof = try merkle.proveLeaf(leaves, @intFromEnum(field), allocator);
    try list.append(.{ .field = field, .raw_bytes = bytes, .proof = proof });
}

/// Verifier side: recompute each disclosed leaf and check inclusion.
/// Returns false on the first invalid proof — verifier should abort.
pub fn verifyDisclosure(bundle: DisclosureBundle) bool {
    for (bundle.disclosures) |d| {
        const leaf = merkle.hashLeaf(d.raw_bytes);
        if (!merkle.verifyProof(leaf, d.proof, bundle.root)) return false;
    }
    return true;
}

test "verifier accepts disclosed reputation only" {
    const m = manifest_mod.Manifest{
        .kyc_hash = [_]u8{0xAA} ** 32,
        .assets_root = [_]u8{0xBB} ** 32,
        .reputation = .{ .love_stored = 7000 },
        .pq_pubkeys_concat = "",
        .obm = 0b0000_0001,
        .timestamp_unix_s = 42,
    };
    var bundle = try discloseFields(
        m,
        .{ .wants_reputation = true },
        std.testing.allocator,
    );
    defer bundle.free(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), bundle.disclosures.len);
    try std.testing.expect(verifyDisclosure(bundle));
}

test "verifier rejects tampered field bytes" {
    const m = manifest_mod.Manifest{
        .kyc_hash = [_]u8{0xAA} ** 32,
        .assets_root = [_]u8{0xBB} ** 32,
        .reputation = .{ .love_stored = 7000 },
        .pq_pubkeys_concat = "",
        .obm = 1,
        .timestamp_unix_s = 42,
    };
    var bundle = try discloseFields(
        m,
        .{ .wants_obm = true },
        std.testing.allocator,
    );
    defer bundle.free(std.testing.allocator);

    // Replace the raw_bytes in-place (same allocation, different content)
    // so cleanup paths stay unchanged.
    std.debug.assert(bundle.disclosures[0].raw_bytes.len == 1);
    @constCast(bundle.disclosures[0].raw_bytes)[0] = 0xFF;

    try std.testing.expect(!verifyDisclosure(bundle));
}

test "verifier accepts multi-field disclosure" {
    const m = manifest_mod.Manifest{
        .kyc_hash = [_]u8{1} ** 32,
        .assets_root = [_]u8{2} ** 32,
        .reputation = .{ .food_stored = 6000 },
        .pq_pubkeys_concat = "pq-blob",
        .obm = 0b0001_0010,
        .timestamp_unix_s = 999,
    };
    var bundle = try discloseFields(
        m,
        .{ .wants_reputation = true, .wants_obm = true, .wants_pq = true },
        std.testing.allocator,
    );
    defer bundle.free(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), bundle.disclosures.len);
    try std.testing.expect(verifyDisclosure(bundle));
}
