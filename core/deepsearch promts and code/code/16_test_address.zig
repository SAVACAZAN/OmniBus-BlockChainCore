//! Tests for Bitcoin address generation

const std = @import("std");
const testing = std.testing;
const btc_address = @import("../../../wallet/btc/address.zig");

test "BTC: P2WPKH address generation" {
    const test_seed = [_]u8{0x00} ** 32;
    
    const addr = try btc_address.deriveP2WPKHAddress(&test_seed, 0, 0);
    defer testing.allocator.free(addr);
    
    // Should start with bc1
    try testing.expect(addr.len >= 42);
    try testing.expect(addr[0] == 'b');
    try testing.expect(addr[1] == 'c');
    try testing.expect(addr[2] == '1');
}

test "BTC: P2TR address generation" {
    const test_seed = [_]u8{0x00} ** 32;
    
    const addr = try btc_address.deriveP2TRAddress(&test_seed, 0, 0);
    defer testing.allocator.free(addr);
    
    // Should start with bc1p
    try testing.expect(addr.len >= 42);
    try testing.expect(addr[0] == 'b');
    try testing.expect(addr[1] == 'c');
    try testing.expect(addr[2] == '1');
    try testing.expect(addr[3] == 'p');
}

test "BTC: Testnet address generation" {
    const test_seed = [_]u8{0x00} ** 32;
    
    const addr = try btc_address.deriveTestnetP2WPKHAddress(&test_seed, 0, 0);
    defer testing.allocator.free(addr);
    
    // Should start with tb1
    try testing.expect(addr[0] == 't');
    try testing.expect(addr[1] == 'b');
}

test "BTC: Address determinism" {
    const test_seed = [_]u8{0x01, 0x02, 0x03} ** 11; // 33 bytes truncated to 32
    
    const addr1 = try btc_address.deriveP2WPKHAddress(&test_seed, 0, 0);
    defer testing.allocator.free(addr1);
    
    const addr2 = try btc_address.deriveP2WPKHAddress(&test_seed, 0, 0);
    defer testing.allocator.free(addr2);
    
    // Same seed, same account, same index -> same address
    try testing.expectEqualSlices(u8, addr1, addr2);
}

test "BTC: Different accounts generate different addresses" {
    const test_seed = [_]u8{0xAA} ** 32;
    
    const addr0 = try btc_address.deriveP2WPKHAddress(&test_seed, 0, 0);
    defer testing.allocator.free(addr0);
    
    const addr1 = try btc_address.deriveP2WPKHAddress(&test_seed, 1, 0);
    defer testing.allocator.free(addr1);
    
    // Different accounts should generate different addresses
    try testing.expect(!std.mem.eql(u8, addr0, addr1));
}

test "BTC: Different indices generate different addresses" {
    const test_seed = [_]u8{0xBB} ** 32;
    
    const addr0 = try btc_address.deriveP2WPKHAddress(&test_seed, 0, 0);
    defer testing.allocator.free(addr0);
    
    const addr1 = try btc_address.deriveP2WPKHAddress(&test_seed, 0, 1);
    defer testing.allocator.free(addr1);
    
    // Different indices should generate different addresses
    try testing.expect(!std.mem.eql(u8, addr0, addr1));
}

test "BTC: Bech32 encoding validation" {
    const hrp = "bc";
    const data = [_]u8{0, 14, 20, 15, 7, 13, 26, 0, 25, 18, 6, 11, 13, 8, 21, 17, 3, 10, 15, 26, 7};
    
    // This should not crash
    _ = btc_address.createChecksumForTest(hrp, &data, .bech32);
}

test "BTC: Hash160 works correctly" {
    const test_input = "Hello World";
    const hash = try btc_address.hash160ForTest(test_input);
    defer testing.allocator.free(hash);
    
    // Known hash160 of "Hello World"
    const expected = [_]u8{ 
        0xb7, 0x3e, 0xf1, 0x67, 0x6b, 0x0d, 0xcf, 0xa2, 
        0xe8, 0x71, 0xec, 0xd5, 0x62, 0xbe, 0x55, 0x6e, 
        0xa3, 0x1d, 0xae, 0xdd 
    };
    
    try testing.expectEqualSlices(u8, &expected, hash);
}

test "BTC: Invalid seed handling" {
    const empty_seed = [_]u8{};
    
    // Should handle empty seed gracefully
    const addr = btc_address.deriveP2WPKHAddress(&empty_seed, 0, 0);
    try testing.expectError(error.SeedTooShort, addr);
}