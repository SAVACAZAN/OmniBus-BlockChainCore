// ============================================
// tests/test_segwit.zig
// ============================================
const std = @import("std");
const segwit = @import("../core/segwit.zig");

test "createP2WPKH script" {
    const hash = [_]u8{0} ** 20;
    const script = segwit.createP2WPKH(hash);
    try std.testing.expect(script.len == 22);
    try std.testing.expect(script[0] == 0x00);
    try std.testing.expect(script[1] == 0x14);
}

test "createP2TR script" {
    const pubkey = [_]u8{1} ** 32;
    const script = segwit.createP2TR(pubkey, null);
    try std.testing.expect(script.len == 34);
    try std.testing.expect(script[0] == 0x51);
    try std.testing.expect(script[1] == 0x20);
}

test "P2TR with merkle root" {
    const pubkey = [_]u8{1} ** 32;
    const merkle_root = [_]u8{2} ** 32;
    const script = segwit.createP2TR(pubkey, merkle_root);
    try std.testing.expect(script.len == 34);
}