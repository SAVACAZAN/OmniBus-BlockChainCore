//! Ethereum EIP-1559 Demo

const std = @import("std");
const allocator = std.heap.page_allocator;
const eip1559 = @import("../core/eip1559.zig");

pub fn main() !void {
    std.debug.print("\n=== Ethereum EIP-1559 Demo ===\n", .{});
    
    // 1. Create dynamic fee
    std.debug.print("\n1. Creating dynamic fee:\n", .{});
    const fee = eip1559.DynamicFee{
        .max_fee_per_gas = 100_000_000_000, // 100 Gwei
        .max_priority_fee_per_gas = 2_000_000_000, // 2 Gwei tip
        .base_fee_per_gas = 50_000_000_000, // 50 Gwei
    };
    
    std.debug.print("   Max fee per gas: {} wei\n", .{fee.max_fee_per_gas});
    std.debug.print("   Priority fee: {} wei\n", .{fee.max_priority_fee_per_gas});
    std.debug.print("   Base fee: {} wei\n", .{fee.base_fee_per_gas});
    std.debug.print("   Effective gas price: {} wei\n", .{fee.effectiveGasPrice()});
    std.debug.print("   Valid: {}\n", .{fee.isValid()});
    
    // 2. Fee estimates for different priorities
    std.debug.print("\n2. Fee estimates by priority:\n", .{});
    
    const slow = eip1559.DynamicFee{
        .max_fee_per_gas = 70_000_000_000,
        .max_priority_fee_per_gas = 500_000_000,
        .base_fee_per_gas = 50_000_000_000,
    };
    
    const normal = eip1559.DynamicFee{
        .max_fee_per_gas = 100_000_000_000,
        .max_priority_fee_per_gas = 1_000_000_000,
        .base_fee_per_gas = 50_000_000_000,
    };
    
    const fast = eip1559.DynamicFee{
        .max_fee_per_gas = 150_000_000_000,
        .max_priority_fee_per_gas = 2_000_000_000,
        .base_fee_per_gas = 50_000_000_000,
    };
    
    std.debug.print("   Slow: {} Gwei (effective: {} Gwei)\n", .{
        slow.max_fee_per_gas / 1_000_000_000,
        slow.effectiveGasPrice() / 1_000_000_000,
    });
    
    std.debug.print("   Normal: {} Gwei (effective: {} Gwei)\n", .{
        normal.max_fee_per_gas / 1_000_000_000,
        normal.effectiveGasPrice() / 1_000_000_000,
    });
    
    std.debug.print("   Fast: {} Gwei (effective: {} Gwei)\n", .{
        fast.max_fee_per_gas / 1_000_000_000,
        fast.effectiveGasPrice() / 1_000_000_000,
    });
    
    // 3. Transaction cost calculation
    std.debug.print("\n3. Transaction cost example (21000 gas):\n", .{});
    const gas_limit: u64 = 21000;
    const total_cost = fee.max_fee_per_gas * gas_limit;
    const total_priority = fee.max_priority_fee_per_gas * gas_limit;
    
    std.debug.print("   Gas limit: {}\n", .{gas_limit});
    std.debug.print("   Max total cost: {} ETH\n", .{@as(f64, @floatFromInt(total_cost)) / 1e18});
    std.debug.print("   Max priority cost: {} ETH\n", .{@as(f64, @floatFromInt(total_priority)) / 1e18});
    
    // 4. Access list example
    std.debug.print("\n4. Access list (for contract interactions):\n", .{});
    const access_list = [_]eip1559.AccessListEntry{
        .{
            .address = [_]u8{0xAA} ** 20,
            .storage_keys = &[_][32]u8{},
        },
    };
    std.debug.print("   Access list size: {}\n", .{access_list.len});
    
    std.debug.print("\n=== Usage Notes ===\n", .{});
    std.debug.print("1. Use FeeEstimator to get current base fee\n", .{});
    std.debug.print("2. Add 10-20% buffer to max_fee for safety\n", .{});
    std.debug.print("3. Priority fee determines miner incentive\n", .{});
    std.debug.print("4. Base fee is burned, priority fee goes to miner\n", .{});
    
    std.debug.print("\nDemo completed successfully!\n\n", .{});
}