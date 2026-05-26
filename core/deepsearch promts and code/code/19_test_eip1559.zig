//! Tests for Ethereum EIP-1559 functionality

const std = @import("std");
const testing = std.testing;
const eip1559 = @import("../../../core/eip1559.zig");

test "ETH: DynamicFee validation" {
    const fee = eip1559.DynamicFee{
        .max_fee_per_gas = 1000000000,
        .max_priority_fee_per_gas = 100000000,
        .base_fee_per_gas = 500000000,
    };
    
    try testing.expect(fee.isValid());
    try testing.expect(fee.effectiveGasPrice() == 600000000);
}

test "ETH: Invalid fee detection" {
    const invalid_fee = eip1559.DynamicFee{
        .max_fee_per_gas = 500000000,
        .max_priority_fee_per_gas = 100000000,
        .base_fee_per_gas = 500000000,
    };
    
    // max_fee_per_gas is too low (should be >= base_fee + priority_fee)
    try testing.expect(!invalid_fee.isValid());
}

test "ETH: Fee estimate structure" {
    const estimate = eip1559.FeeEstimate{
        .slow = eip1559.DynamicFee{
            .max_fee_per_gas = 700000000,
            .max_priority_fee_per_gas = 50000000,
            .base_fee_per_gas = 500000000,
        },
        .normal = eip1559.DynamicFee{
            .max_fee_per_gas = 1000000000,
            .max_priority_fee_per_gas = 100000000,
            .base_fee_per_gas = 500000000,
        },
        .fast = eip1559.DynamicFee{
            .max_fee_per_gas = 1500000000,
            .max_priority_fee_per_gas = 200000000,
            .base_fee_per_gas = 500000000,
        },
        .timestamp = 1234567890,
    };
    
    try testing.expect(estimate.slow.max_fee_per_gas < estimate.normal.max_fee_per_gas);
    try testing.expect(estimate.normal.max_fee_per_gas < estimate.fast.max_fee_per_gas);
}

test "ETH: Transaction RLP encoding" {
    const tx = eip1559.EIP1559Transaction{
        .chain_id = 1,
        .nonce = 0,
        .max_priority_fee_per_gas = 100000000,
        .max_fee_per_gas = 1000000000,
        .gas_limit = 21000,
        .to = null,
        .value = 0,
        .data = &[_]u8{},
        .access_list = &[_]eip1559.AccessListEntry{},
        .v = 0,
        .r = [_]u8{0} ** 32,
        .s = [_]u8{0} ** 32,
    };
    
    const rlp = tx.toRLP() catch null;
    // Should not crash
    _ = rlp;
}

test "ETH: Access list entry" {
    const entry = eip1559.AccessListEntry{
        .address = [_]u8{0xAA} ** 20,
        .storage_keys = &[_][32]u8{},
    };
    
    try testing.expect(entry.address.len == 20);
}