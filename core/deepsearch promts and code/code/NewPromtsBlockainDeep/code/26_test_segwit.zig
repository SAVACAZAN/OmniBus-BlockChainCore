// ============================================
// tests/test_eip1559.zig
// ============================================
const std = @import("std");
const evm = @import("../core/evm_signer.zig");

test "EIP-1559 transaction encoding" {
    const tx = evm.Eip1559Tx{
        .chain_id = 1,
        .nonce = 0,
        .max_priority_fee_per_gas = 1000000000,
        .max_fee_per_gas = 2000000000,
        .gas_limit = 21000,
        .to = null,
        .value = 0,
        .data = &[_]u8{},
        .access_list = &[_]evm.AccessListEntry{},
    };
    const encoded = try evm.rlpEncodeEip1559(&tx, std.testing.allocator);
    defer std.testing.allocator.free(encoded);
    try std.testing.expect(encoded.len > 0);
    try std.testing.expect(encoded[0] == 0x02);
}

test "EIP-1559 signing" {
    const tx = evm.Eip1559Tx{
        .chain_id = 1,
        .nonce = 0,
        .max_priority_fee_per_gas = 1000000000,
        .max_fee_per_gas = 2000000000,
        .gas_limit = 21000,
        .to = null,
        .value = 0,
        .data = &[_]u8{},
        .access_list = &[_]evm.AccessListEntry{},
    };
    const private_key = [_]u8{1} ** 32;
    const signed = try evm.signEip1559(tx, private_key, std.testing.allocator);
    try std.testing.expect(signed.r.len == 32);
    try std.testing.expect(signed.s.len == 32);
}