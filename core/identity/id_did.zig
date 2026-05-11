//! id_did.zig — DID Core resolver for `did:omnibus:<base58(sha256(pubkey))>`.
//!
//! A DID is one stable string that names an identity across services. For
//! OmniBus we hash the compressed secp256k1 pubkey with SHA-256 (already
//! used everywhere on chain — see bip32_wallet.zig) and Base58-encode it.
//! Resolution back to an on-chain ob1q… address goes through the existing
//! DNS registry — we don't add a parallel registry.

const std = @import("std");
const base58 = @import("id_base58.zig");
const wallet_mod = @import("../wallet.zig");
const bech32_mod = @import("../bech32.zig");

pub const DID_PREFIX = "did:omnibus:";

/// Errors raised by the resolver. `InvalidDid` is a user-input error;
/// `UnknownIdentifier` means the identifier doesn't map to a known address
/// (e.g. derived from a pubkey the chain has never seen).
pub const Error = error{
    InvalidDid,
    UnknownIdentifier,
    OutOfMemory,
};

/// Build the DID for a compressed (33-byte) secp256k1 public key. This is
/// the same form used for ECDSA signing on chain, so the same DID is
/// derivable from a wallet's mnemonic offline.
pub fn didFromCompressedPubkey(
    compressed_pubkey: [33]u8,
    allocator: std.mem.Allocator,
) ![]u8 {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&compressed_pubkey, &hash, .{});
    const b58 = try base58.encode(&hash, allocator);
    defer allocator.free(b58);
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ DID_PREFIX, b58 });
}

/// Build the DID for the same `pubkeyHash160` chain uses to derive ob1q.
/// Lets clients that already have an address derive a stable DID without
/// re-fetching the pubkey (useful for explorers).
pub fn didFromHash160(hash160: [20]u8, allocator: std.mem.Allocator) ![]u8 {
    // Pad to 32 bytes via SHA-256 so DID hash width matches pubkey path.
    // Same DID-Method-Identifier length regardless of origin.
    var padded: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&hash160, &padded, .{});
    const b58 = try base58.encode(&padded, allocator);
    defer allocator.free(b58);
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ DID_PREFIX, b58 });
}

/// Split a DID string into its method identifier. Returns slice into input
/// (caller doesn't free). `InvalidDid` if prefix is wrong or empty body.
pub fn parseDid(did: []const u8) ![]const u8 {
    if (!std.mem.startsWith(u8, did, DID_PREFIX)) return Error.InvalidDid;
    const body = did[DID_PREFIX.len..];
    if (body.len == 0) return Error.InvalidDid;
    return body;
}

/// Convenience: turn a compressed pubkey directly into its ob1q… address,
/// reusing wallet.zig's Hash160 + bech32. Lets ID-layer code resolve a
/// pubkey-derived DID without going through DNS — useful when the holder
/// presents both the DID and the pubkey at the same time.
pub fn addressFromCompressedPubkey(
    compressed_pubkey: [33]u8,
    allocator: std.mem.Allocator,
) ![]u8 {
    const h160 = wallet_mod.Wallet.pubkeyHash160(compressed_pubkey);
    return bech32_mod.encodeOBAddress(h160, allocator);
}

test "DID has stable prefix" {
    var pubkey: [33]u8 = undefined;
    @memset(&pubkey, 0x02);
    pubkey[1] = 0x01; // avoid all-same to exercise base58 leading-zero path

    const did = try didFromCompressedPubkey(pubkey, std.testing.allocator);
    defer std.testing.allocator.free(did);
    try std.testing.expect(std.mem.startsWith(u8, did, "did:omnibus:"));
}

test "DID is deterministic for the same pubkey" {
    var pubkey: [33]u8 = undefined;
    @memset(&pubkey, 0x03);
    pubkey[2] = 0x42;

    const a = try didFromCompressedPubkey(pubkey, std.testing.allocator);
    defer std.testing.allocator.free(a);
    const b = try didFromCompressedPubkey(pubkey, std.testing.allocator);
    defer std.testing.allocator.free(b);
    try std.testing.expectEqualStrings(a, b);
}

test "DID differs for distinct pubkeys" {
    var pk_a: [33]u8 = undefined;
    var pk_b: [33]u8 = undefined;
    @memset(&pk_a, 0x02);
    @memset(&pk_b, 0x03);

    const a = try didFromCompressedPubkey(pk_a, std.testing.allocator);
    defer std.testing.allocator.free(a);
    const b = try didFromCompressedPubkey(pk_b, std.testing.allocator);
    defer std.testing.allocator.free(b);
    try std.testing.expect(!std.mem.eql(u8, a, b));
}

test "parseDid splits prefix and body" {
    const body = try parseDid("did:omnibus:1ABCxyz");
    try std.testing.expectEqualStrings("1ABCxyz", body);
}

test "parseDid rejects wrong prefix" {
    try std.testing.expectError(Error.InvalidDid, parseDid("did:other:body"));
    try std.testing.expectError(Error.InvalidDid, parseDid("did:omnibus:"));
}
