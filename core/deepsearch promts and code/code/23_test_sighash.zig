//! Tests for SIGHASH implementation

const std = @import("std");
const testing = std.testing;
const sighash = @import("../../core/sighash.zig");

test "SIGHASH: Type conversion" {
    const all = sighash.SighashType.fromByte(sighash.SIGHASH_ALL);
    try testing.expect(all.type == .ALL);
    try testing.expect(!all.anyone_can_pay);
    
    const all_acp = sighash.SighashType.fromByte(sighash.SIGHASH_ALL_ANYONECANPAY);
    try testing.expect(all_acp.type == .ALL);
    try testing.expect(all_acp.anyone_can_pay);
}

test "SIGHASH: Constants correctness" {
    try testing.expect(sighash.SIGHASH_ALL == 0x01);
    try testing.expect(sighash.SIGHASH_NONE == 0x02);
    try testing.expect(sighash.SIGHASH_SINGLE == 0x03);
    try testing.expect(sighash.SIGHASH_ANYONECANPAY == 0x80);
}

test "SIGHASH: To byte conversion" {
    const all = sighash.SighashType.fromByte(sighash.SIGHASH_ALL);
    try testing.expect(all.toByte() == sighash.SIGHASH_ALL);
    
    const all_acp = sighash.SighashType.fromByte(sighash.SIGHASH_ALL_ANYONECANPAY);
    try testing.expect(all_acp.toByte() == sighash.SIGHASH_ALL_ANYONECANPAY);
}

test "SIGHASH: TxHasher initialization" {
    const hasher = sighash.TxHasher.init(testing.allocator);
    _ = hasher;
}

test "SIGHASH: OutPoint structure" {
    const outpoint = sighash.OutPoint{
        .txid = [_]u8{0x01} ** 32,
        .index = 0,
    };
    
    try testing.expect(outpoint.index == 0);
    try testing.expect(outpoint.txid.len == 32);
}

test "SIGHASH: Transaction input structure" {
    const input = sighash.TxInput{
        .previous_outpoint = sighash.OutPoint{
            .txid = [_]u8{0x01} ** 32,
            .index = 0,
        },
        .script_sig = &[_]u8{},
        .sequence = 0xFFFFFFFF,
        .witness = null,
    };
    
    try testing.expect(input.sequence == 0xFFFFFFFF);
}