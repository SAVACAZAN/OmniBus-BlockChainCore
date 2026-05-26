//! Solana Wallet Demo

const std = @import("std");
const allocator = std.heap.page_allocator;
const sol_addr = @import("../wallet/sol/address.zig");

pub fn main() !void {
    std.debug.print("\n=== Solana Wallet Demo ===\n", .{});
    
    // 1. Generate a new address
    std.debug.print("\n1. Generating Solana address...\n", .{});
    const test_seed = [_]u8{0x01, 0x02, 0x03} ** 11;
    var generator = sol_addr.AddressGenerator.init(allocator);
    
    const pubkey = try generator.deriveAddress(&test_seed, 0, 0);
    const address = try sol_addr.pubkeyToAddress(pubkey);
    defer allocator.free(address);
    
    std.debug.print("   Public Key (hex): ", .{});
    for (pubkey) |b| std.debug.print("{x:0>2}", .{b});
    std.debug.print("\n", .{});
    std.debug.print("   Address (base58): {s}\n", .{address});
    
    // 2. Derive multiple addresses
    std.debug.print("\n2. Multiple addresses for account 0:\n", .{});
    for (0..5) |i| {
        const addr_pubkey = try generator.deriveAddress(&test_seed, 0, @as(u32, @intCast(i)));
        const addr_str = try sol_addr.pubkeyToAddress(addr_pubkey);
        defer allocator.free(addr_str);
        std.debug.print("   Index {}: {s}...\n", .{i, addr_str[0..8]});
    }
    
    // 3. Program-Derived Address (PDA) example
    std.debug.print("\n3. Program-Derived Address (PDA):\n", .{});
    const program_id = sol_addr.SYSTEM_PROGRAM_ID;
    const seeds = [_][]const u8{"my_seed"};
    const pda = sol_addr.findProgramAddress(&seeds, program_id);
    
    const pda_str = try sol_addr.pubkeyToAddress(pda.address);
    defer allocator.free(pda_str);
    std.debug.print("   PDA: {s}\n", .{pda_str});
    std.debug.print("   Bump seed: {}\n", .{pda.bump_seed});
    
    // 4. System Program ID
    std.debug.print("\n4. Common Program IDs:\n", .{});
    std.debug.print("   System Program: ", .{});
    for (sol_addr.SYSTEM_PROGRAM_ID) |b| std.debug.print("{x:0>2}", .{b});
    std.debug.print("\n", .{});
    
    std.debug.print("   Token Program: ", .{});
    for (sol_addr.TOKEN_PROGRAM_ID) |b| std.debug.print("{x:0>2}", .{b});
    std.debug.print("\n", .{});
    
    std.debug.print("   Associated Token Program: ", .{});
    for (sol_addr.ASSOCIATED_TOKEN_PROGRAM_ID) |b| std.debug.print("{x:0>2}", .{b});
    std.debug.print("\n", .{});
    
    // 5. Address validation
    std.debug.print("\n5. Address validation:\n", .{});
    const valid = try sol_addr.validateAddress(address);
    std.debug.print("   Address valid: {}\n", .{valid});
    
    const invalid_check = sol_addr.validateAddress("invalid_address");
    std.debug.print("   Invalid address check: {}\n", .{!invalid_check});
    
    std.debug.print("\n=== Next Steps ===\n", .{});
    std.debug.print("1. Request an airdrop on devnet\n", .{});
    std.debug.print("2. Build a transfer transaction\n", .{});
    std.debug.print("3. Sign with Ed25519 private key\n", .{});
    std.debug.print("4. Send via RPC client\n", .{});
    
    std.debug.print("\nDemo completed successfully!\n\n", .{});
}