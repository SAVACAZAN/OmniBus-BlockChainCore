//! TON Wallet Demo

const std = @import("std");
const allocator = std.heap.page_allocator;
const ton_addr = @import("../wallet/ton/address.zig");

pub fn main() !void {
    std.debug.print("\n=== TON Wallet Demo ===\n", .{});
    
    // 1. Create a TON address
    std.debug.print("\n1. Creating TON address...\n", .{});
    const hash = [_]u8{0x01, 0x02, 0x03, 0x04} ++ [_]u8{0xAA} ** 28;
    const addr = ton_addr.TonAddress.init(0, hash);
    
    // 2. Get different address formats
    std.debug.print("\n2. Address formats:\n", .{});
    const bounceable = try addr.toBounceable();
    defer allocator.free(bounceable);
    std.debug.print("   Bounceable (EQ...): {s}\n", .{bounceable});
    
    const non_bounceable = try addr.toNonBounceable();
    defer allocator.free(non_bounceable);
    std.debug.print("   Non-bounceable (UQ...): {s}\n", .{non_bounceable});
    
    const hex_addr = addr.toHex();
    defer allocator.free(hex_addr);
    std.debug.print("   Raw hex: {s}\n", .{hex_addr});
    
    // 3. Parse an address from string
    std.debug.print("\n3. Parsing address from string:\n", .{});
    const parsed = try ton_addr.TonAddress.fromString(bounceable);
    std.debug.print("   Parsed workchain: {}\n", .{parsed.workchain});
    std.debug.print("   Parsed hash: ", .{});
    for (parsed.hash) |b| std.debug.print("{x:0>2}", .{b});
    std.debug.print("\n", .{});
    
    // 4. Workchain types
    std.debug.print("\n4. Workchain types:\n", .{});
    const masterchain = ton_addr.TonAddress.init(-1, hash);
    const masterchain_str = try masterchain.toBounceable();
    defer allocator.free(masterchain_str);
    std.debug.print("   Masterchain address: {s}\n", .{masterchain_str});
    
    const basechain = ton_addr.TonAddress.init(0, hash);
    const basechain_str = try basechain.toBounceable();
    defer allocator.free(basechain_str);
    std.debug.print("   Basechain address: {s}\n", .{basechain_str});
    
    // 5. Address validation
    std.debug.print("\n5. Validation:\n", .{});
    const is_valid = ton_addr.TonAddress.fromString(bounceable);
    std.debug.print("   Valid bounceable address: {any}\n", .{is_valid});
    
    const invalid = ton_addr.TonAddress.fromString("invalid");
    std.debug.print("   Invalid address: {any}\n", .{invalid});
    
    std.debug.print("\n=== TON Address Info ===\n", .{});
    std.debug.print("Bounceable addresses start with EQ or UQ\n", .{});
    std.debug.print("  - EQ: bounceable (tokens can be returned)\n", .{});
    std.debug.print("  - UQ: non-bounceable (tokens lost if contract missing)\n", .{});
    std.debug.print("Workchain -1: Masterchain (validators)\n", .{});
    std.debug.print("Workchain 0: Basechain (user accounts)\n", .{});
    
    std.debug.print("\nDemo completed successfully!\n\n", .{});
}