//! Bitcoin Wallet Demo - Complete example

const std = @import("std");
const allocator = std.heap.page_allocator;
const btc_addr = @import("../wallet/btc/address.zig");
const btc_tx = @import("../wallet/btc/tx_builder.zig");
const btc_rpc = @import("../wallet/btc/rpc_client.zig");

pub fn main() !void {
    std.debug.print("\n=== Bitcoin Wallet Demo ===\n", .{});
    
    // 1. Generate a new address
    std.debug.print("\n1. Generating new Bitcoin address...\n", .{});
    const test_seed = [_]u8{0x01, 0x02, 0x03} ** 11; // Demo seed
    
    const address = try btc_addr.deriveP2WPKHAddress(&test_seed, 0, 0);
    defer allocator.free(address);
    std.debug.print("   P2WPKH Address: {s}\n", .{address});
    
    const taproot_addr = try btc_addr.deriveP2TRAddress(&test_seed, 0, 0);
    defer allocator.free(taproot_addr);
    std.debug.print("   Taproot Address: {s}\n", .{taproot_addr});
    
    // 2. Generate testnet address
    std.debug.print("\n2. Testnet address:\n", .{});
    const testnet_addr = try btc_addr.deriveTestnetP2WPKHAddress(&test_seed, 0, 0);
    defer allocator.free(testnet_addr);
    std.debug.print("   Testnet: {s}\n", .{testnet_addr});
    
    // 3. Configure RPC client (example)
    std.debug.print("\n3. RPC Configuration:\n", .{});
    const config = btc_rpc.RpcConfig{
        .url = "http://localhost:8332",
        .username = "your_username",
        .password = "your_password",
        .network = .testnet,
    };
    std.debug.print("   RPC URL: {s}\n", .{config.url});
    std.debug.print("   Network: {s}\n", .{@tagName(config.network)});
    
    // 4. Fee estimation example
    std.debug.print("\n4. Fee recommendations:\n", .{});
    std.debug.print("   Slow (30+ blocks): ~2 sat/vbyte\n", .{});
    std.debug.print("   Normal (10 blocks): ~5 sat/vbyte\n", .{});
    std.debug.print("   Fast (2 blocks): ~10 sat/vbyte\n", .{});
    std.debug.print("   Urgent (next block): ~20 sat/vbyte\n", .{});
    
    // 5. Transaction size estimation
    std.debug.print("\n5. Transaction size estimates:\n", .{});
    std.debug.print("   P2WPKH (2 inputs, 1 output): ~140 vbytes\n", .{});
    std.debug.print("   P2TR (2 inputs, 1 output): ~130 vbytes\n", .{});
    std.debug.print("   Legacy (2 inputs, 1 output): ~370 bytes\n", .{});
    
    // 6. Usage instructions
    std.debug.print("\n=== Usage Instructions ===\n", .{});
    std.debug.print("1. Fund your address with testnet BTC from a faucet\n", .{});
    std.debug.print("2. Use RPC client to check balance\n", .{});
    std.debug.print("3. Build and sign transactions\n", .{});
    std.debug.print("4. Broadcast using sendTransaction\n", .{});
    
    std.debug.print("\nDemo completed successfully!\n\n", .{});
}