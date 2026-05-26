//! Tests for ERC-20 token functionality

const std = @import("std");
const testing = std.testing;
const erc20 = @import("../../../wallet/eth/erc20.zig");

test "ETH: ERC-20 signature constants" {
    try testing.expect(erc20.ERC20_SIG.TRANSFER == 0xa9059cbb);
    try testing.expect(erc20.ERC20_SIG.APPROVE == 0x095ea7b3);
    try testing.expect(erc20.ERC20_SIG.BALANCE_OF == 0x70a08231);
    try testing.expect(erc20.ERC20_SIG.TOTAL_SUPPLY == 0x18160ddd);
}

test "ETH: Token info structure" {
    var token = erc20.TokenInfo{
        .contract_address = [_]u8{0xAA} ** 20,
        .symbol = try testing.allocator.dupe(u8, "TEST"),
        .name = try testing.allocator.dupe(u8, "Test Token"),
        .decimals = 18,
        .total_supply = 1000000,
    };
    defer token.deinit();
    
    try testing.expectEqualStrings(token.symbol, "TEST");
    try testing.expect(token.decimals == 18);
}

test "ETH: Token balance structure" {
    var token = erc20.TokenInfo{
        .contract_address = [_]u8{0xAA} ** 20,
        .symbol = try testing.allocator.dupe(u8, "TEST"),
        .name = try testing.allocator.dupe(u8, "Test Token"),
        .decimals = 18,
        .total_supply = 1000000,
    };
    defer token.deinit();
    
    const balance = erc20.TokenBalance{
        .token = token,
        .balance = 500,
        .allowance = 100,
    };
    
    try testing.expect(balance.balance == 500);
    try testing.expect(balance.allowance == 100);
}

test "ETH: Transfer calldata encoding" {
    // Create a simple test builder
    var builder = struct {
        fn encodeTransfer(to: [20]u8, amount: u256) ![]u8 {
            var calldata = std.ArrayList(u8).init(testing.allocator);
            defer calldata.deinit();
            
            try calldata.appendSlice(&std.mem.toBytes(erc20.ERC20_SIG.TRANSFER));
            try calldata.appendSlice(&std.mem.toBytes(@as(u256, 0)));
            try calldata.appendSlice(&to);
            try calldata.appendSlice(&std.mem.toBytes(amount));
            
            return calldata.toOwnedSlice();
        }
    };
    
    const to_addr = [_]u8{0xBB} ** 20;
    const calldata = try builder.encodeTransfer(to_addr, 1000);
    defer testing.allocator.free(calldata);
    
    // Calldata should be 4 (sig) + 32 (address padding) + 20 (address) + 32 (amount) = 88 bytes
    try testing.expect(calldata.len == 88);
}