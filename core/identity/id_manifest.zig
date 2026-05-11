//! id_manifest.zig — Identity Manifest builder and root computation.
//!
//! The manifest is ten fields in fixed order (see id_types.FieldIndex):
//!   0: kyc_hash               (32 bytes)
//!   1: assets_root            (32 bytes; off-chain asset Merkle)
//!   2: reputation_snapshot    (16 bytes; 4 cups × u32 stored=x100)
//!   3: pq_keys_hash           (32 bytes; SHA-256 over concatenated PQ pubkeys)
//!   4: obm                    (1 byte; from id_obm.zig)
//!   5: timestamp              (8 bytes little-endian u64)
//!   6: social_root            (32 bytes; from id_social.zig)
//!   7: professional_root      (32 bytes; from id_professional.zig)
//!   8: cultural_root          (32 bytes; from id_cultural.zig)
//!   9: economic_root          (32 bytes; from id_economic.zig)
//!
//! Facets 6/7/8 are optional — pass `[_]u8{0} ** 32` when the holder
//! hasn't built that facet yet. The leaf is always present in the tree
//! so manifest shape stays constant; only its value reveals presence.
//!
//! The chain stores ONLY the Merkle root (on-chain attestation); the
//! cleartext stays in the holder's vault. Selective disclosure works by
//! revealing the original bytes for a field + a proof; hidden fields
//! contribute their hash to the root without leaking content.

const std = @import("std");
const Sha256 = std.crypto.hash.sha2.Sha256;
const merkle = @import("id_merkle.zig");
const types = @import("id_types.zig");
const reputation = @import("../reputation.zig");

pub const Manifest = struct {
    kyc_hash: types.KycHash,
    assets_root: [32]u8,
    reputation: reputation.ReputationCups,
    /// Concatenated PQ pubkeys. Sizes vary (ML-DSA-87 ~2592 B, Falcon ~897 B,
    /// SLH-DSA ~32 B per key) so we hold the raw slice and hash it once.
    pq_pubkeys_concat: []const u8,
    obm: types.Obm,
    timestamp_unix_s: u64,
    /// Facet roots — pass zero-array when the facet is empty for this holder.
    social_root: [32]u8 = [_]u8{0} ** 32,
    professional_root: [32]u8 = [_]u8{0} ** 32,
    cultural_root: [32]u8 = [_]u8{0} ** 32,
    economic_root: [32]u8 = [_]u8{0} ** 32,
};

/// Serialize the 4 reputation cups into a 16-byte little-endian field
/// (love, food, rent, vacation — each u32 stored=x100). Stable wire format.
pub fn serializeReputationField(cups: reputation.ReputationCups) [16]u8 {
    var out: [16]u8 = undefined;
    std.mem.writeInt(u32, out[0..4], cups.love_stored, .little);
    std.mem.writeInt(u32, out[4..8], cups.food_stored, .little);
    std.mem.writeInt(u32, out[8..12], cups.rent_stored, .little);
    std.mem.writeInt(u32, out[12..16], cups.vacation_stored, .little);
    return out;
}

/// SHA-256 over the concatenated PQ pubkeys. Caller passes empty slice
/// when the holder has no PQ keys registered yet — yields a fixed sentinel.
pub fn hashPqKeys(pq_pubkeys_concat: []const u8) [32]u8 {
    var out: [32]u8 = undefined;
    Sha256.hash(pq_pubkeys_concat, &out, .{});
    return out;
}

/// Compute the six leaf hashes in canonical FieldIndex order. We always
/// emit all six leaves — redaction happens at the *content* level, not by
/// dropping leaves, so the tree shape stays constant.
pub fn computeLeafHashes(manifest: Manifest) [types.FIELD_COUNT]merkle.Hash {
    const rep_bytes = serializeReputationField(manifest.reputation);
    const pq_hash = hashPqKeys(manifest.pq_pubkeys_concat);

    var ts_bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &ts_bytes, manifest.timestamp_unix_s, .little);

    const obm_byte = [_]u8{manifest.obm};

    return .{
        merkle.hashLeaf(&manifest.kyc_hash),
        merkle.hashLeaf(&manifest.assets_root),
        merkle.hashLeaf(&rep_bytes),
        merkle.hashLeaf(&pq_hash),
        merkle.hashLeaf(&obm_byte),
        merkle.hashLeaf(&ts_bytes),
        merkle.hashLeaf(&manifest.social_root),
        merkle.hashLeaf(&manifest.professional_root),
        merkle.hashLeaf(&manifest.cultural_root),
        merkle.hashLeaf(&manifest.economic_root),
    };
}

/// Compute the Merkle root for this Manifest. This is the value that may
/// be anchored on-chain via a `manifest_anchor` op_return TX (out of scope
/// here — RPC layer does that).
pub fn computeRoot(
    manifest: Manifest,
    allocator: std.mem.Allocator,
) !types.ManifestRoot {
    const leaves = computeLeafHashes(manifest);
    return merkle.rootOfLeafHashes(&leaves, allocator);
}

test "manifest root is deterministic" {
    const m = Manifest{
        .kyc_hash = [_]u8{1} ** 32,
        .assets_root = [_]u8{2} ** 32,
        .reputation = .{ .love_stored = 5000, .food_stored = 4000, .rent_stored = 3000, .vacation_stored = 2000 },
        .pq_pubkeys_concat = "",
        .obm = 0b0000_1111,
        .timestamp_unix_s = 1_780_000_000,
    };
    const a = try computeRoot(m, std.testing.allocator);
    const b = try computeRoot(m, std.testing.allocator);
    try std.testing.expectEqualSlices(u8, &a, &b);
}

test "manifest root changes when any field flips" {
    const base = Manifest{
        .kyc_hash = [_]u8{1} ** 32,
        .assets_root = [_]u8{2} ** 32,
        .reputation = .{ .love_stored = 100 },
        .pq_pubkeys_concat = "",
        .obm = 0,
        .timestamp_unix_s = 1_000,
    };
    const root_base = try computeRoot(base, std.testing.allocator);

    var tweak = base;
    tweak.obm = 1;
    const root_tweak = try computeRoot(tweak, std.testing.allocator);

    try std.testing.expect(!std.mem.eql(u8, &root_base, &root_tweak));
}

test "reputation field serialization matches little-endian layout" {
    const cups = reputation.ReputationCups{
        .love_stored = 0x11223344,
        .food_stored = 0x55667788,
        .rent_stored = 0x99AABBCC,
        .vacation_stored = 0xDDEEFF00,
    };
    const bytes = serializeReputationField(cups);
    // love=0x11223344 → LE: 44 33 22 11
    try std.testing.expectEqual(@as(u8, 0x44), bytes[0]);
    try std.testing.expectEqual(@as(u8, 0x33), bytes[1]);
    try std.testing.expectEqual(@as(u8, 0x22), bytes[2]);
    try std.testing.expectEqual(@as(u8, 0x11), bytes[3]);
    // vacation=0xDDEEFF00 → LE: 00 FF EE DD
    try std.testing.expectEqual(@as(u8, 0x00), bytes[12]);
    try std.testing.expectEqual(@as(u8, 0xFF), bytes[13]);
    try std.testing.expectEqual(@as(u8, 0xEE), bytes[14]);
    try std.testing.expectEqual(@as(u8, 0xDD), bytes[15]);
}
