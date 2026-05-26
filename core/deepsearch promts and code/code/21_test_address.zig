//! Tests for Solana address generation

const std = @import("std");
const testing = std.testing;
const sol_address = @import("../../../wallet/sol/address.zig");

test "SOL: Address validation" {
    // Valid Solana address (base58, 32 bytes)
    const valid_address = "11111111111111111111111111111111";
    try testing.expect(sol_address.validateAddress(valid_address));
    
    const invalid_address = "invalid";
    try testing.expect(!sol_address.validateAddress(invalid_address));
    
    const too_short = "abc";
    try testing.expect(!sol_address.validateAddress(too_short));
}

test "SOL: Public key to address conversion" {
    const pubkey = [_]u8{0x01} ** 32;
    const addr = try sol_address.pubkeyToAddress(pubkey);
    defer testing.allocator.free(addr);
    
    try testing.expect(addr.len >= 32);
    try testing.expect(addr.len <= 44);
}

test "SOL: Address to public key conversion" {
    const original = [_]u8{0x01} ** 32;
    const addr = try sol_address.pubkeyToAddress(original);
    defer testing.allocator.free(addr);
    
    const decoded = try sol_address.addressToPubkey(addr);
    
    try testing.expectEqualSlices(u8, &original, &decoded);
}

test "SOL: PDA generation" {
    const program_id = sol_address.SYSTEM_PROGRAM_ID;
    const seeds = [_][]const u8{"test"};
    
    const pda = sol_address.findProgramAddress(&seeds, program_id);
    
    try testing.expect(pda.bump_seed <= 255);
    try testing.expect(pda.address.len == 32);
}

test "SOL: Program IDs constants" {
    try testing.expect(sol_address.SYSTEM_PROGRAM_ID.len == 32);
    try testing.expect(sol_address.TOKEN_PROGRAM_ID.len == 32);
    try testing.expect(sol_address.ASSOCIATED_TOKEN_PROGRAM_ID.len == 32);
}

test "SOL: Derivation path generation" {
    const seed = [_]u8{0xAA} ** 32;
    var generator = sol_address.AddressGenerator.init(testing.allocator);
    
    const addr0 = try generator.deriveAddress(&seed, 0, 0);
    const addr1 = try generator.deriveAddress(&seed, 0, 1);
    
    // Different indices should generate different addresses
    try testing.expect(!std.mem.eql(u8, &addr0, &addr1));
}