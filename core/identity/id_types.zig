//! id_types.zig — types specific to the OmniBus ID layer.
//!
//! We deliberately do NOT redefine anything that already exists in the chain:
//!   - secp256k1 keys / signatures → `core/secp256k1.zig`
//!   - ECDSA address (ob1q...)      → `core/wallet.zig` (pubkeyHash160) + `core/bech32.zig`
//!   - 4 reputation cups            → `core/reputation.zig` (ReputationCups)
//!   - PQ keys                      → `core/pq_crypto.zig`
//!   - On-chain name registry       → `core/dns_registry.zig`
//!
//! What lives here are the *new* types the identity layer introduces:
//! KYC hash + salt, the redacted manifest envelope, and the disclosure mask.

const std = @import("std");

/// SHA-256 digest of (salt || kyc_document_bytes). Stored off-chain in the
/// holder's vault; only the digest may be anchored on-chain. Same width as
/// every other hash on the chain so it slots into Merkle trees unchanged.
pub const KycHash = [32]u8;

/// Merkle root over all manifest fields. Identity verifiers see only this
/// + selective proofs — never the cleartext fields.
pub const ManifestRoot = [32]u8;

/// 32-byte salt used in KYC hashing. Stored by `SaltManager` (file or
/// future hardware). Deleting it = GDPR "right to be forgotten" because
/// the kyc_hash can no longer be re-derived from a fresh scan.
pub const Salt = [32]u8;

/// Single byte that compactly answers "what badges does this address have?"
/// Bits are derived live from chain state — see `id_obm.zig`. Never stored
/// separately; recomputed on every read so it can't go stale.
pub const Obm = u8;

/// Bit positions inside `Obm`. Order is part of the wire format — DO NOT
/// reorder once external clients (mobile apps, third-party verifiers) start
/// parsing this byte. Add new bits at higher positions only.
pub const ObmBit = enum(u3) {
    love_badge = 0,
    food_badge = 1,
    rent_badge = 2,
    vacation_badge = 3,
    has_pq_key = 4,
    has_dns_name = 5,
    is_validator = 6,
    is_zen_tier = 7,
};

/// Which fields the holder agrees to reveal in a selective disclosure flow.
/// A `false` field means the verifier sees zero bytes in that slot AND
/// cannot reconstruct it from the proof. Encoded as one byte to match Obm.
pub const DisclosureRequest = packed struct(u16) {
    wants_kyc: bool = false,
    wants_assets: bool = false,
    wants_reputation: bool = false,
    wants_pq: bool = false,
    wants_obm: bool = false,
    wants_social: bool = false,
    wants_professional: bool = false,
    wants_cultural: bool = false,
    wants_economic: bool = false,
    _padding: u7 = 0,
};

/// Field index inside the manifest Merkle tree. The order MUST be stable —
/// proofs are computed against these indices. If you add a field, append.
/// Indices 6/7/8 hold the three identity facets (Social, Professional,
/// Cultural). Each facet is itself a Merkle subtree built in its own
/// module (id_social.zig / id_professional.zig / id_cultural.zig); the
/// master Manifest holds only their roots.
pub const FieldIndex = enum(u8) {
    kyc_hash = 0,
    assets_root = 1,
    reputation_snapshot = 2,
    pq_keys_hash = 3,
    obm = 4,
    timestamp = 5,
    social_root = 6,
    professional_root = 7,
    cultural_root = 8,
    economic_root = 9,
};

pub const FIELD_COUNT: usize = 10;

test "DisclosureRequest is exactly two bytes" {
    try std.testing.expectEqual(@as(usize, 2), @sizeOf(DisclosureRequest));
}

test "ObmBit values stable" {
    try std.testing.expectEqual(@as(u3, 0), @intFromEnum(ObmBit.love_badge));
    try std.testing.expectEqual(@as(u3, 7), @intFromEnum(ObmBit.is_zen_tier));
}

test "FieldIndex count matches FIELD_COUNT" {
    try std.testing.expectEqual(@as(u8, 5), @intFromEnum(FieldIndex.timestamp));
    try std.testing.expectEqual(@as(u8, 6), @intFromEnum(FieldIndex.social_root));
    try std.testing.expectEqual(@as(u8, 7), @intFromEnum(FieldIndex.professional_root));
    try std.testing.expectEqual(@as(u8, 8), @intFromEnum(FieldIndex.cultural_root));
    try std.testing.expectEqual(@as(u8, 9), @intFromEnum(FieldIndex.economic_root));
    try std.testing.expectEqual(@as(usize, 10), FIELD_COUNT);
}
