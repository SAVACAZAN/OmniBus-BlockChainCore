const std = @import("std");
const wallet_mod = @import("wallet.zig");
const array_list = std.array_list;

pub const Wallet = wallet_mod.Wallet;

/// Miner Wallet with genesis token allocation
pub const MinerWallet = struct {
    miner_id: u32,
    miner_name: []const u8,
    wallet: Wallet,
    allocated_tokens: u64,        // SAT (1 OMNI = 100M SAT)
    mining_reward: u64,           // Accumulated rewards
    block_contribution: u32,      // Blocks this miner found

    pub fn init(allocator: std.mem.Allocator, miner_id: u32, allocated_tokens: u64) !MinerWallet {
        var wallet = try Wallet.init(allocator);
        wallet.balance = allocated_tokens;

        const miner_name = try std.fmt.allocPrint(
            allocator,
            "miner-{d}",
            .{miner_id},
        );

        return MinerWallet{
            .miner_id = miner_id,
            .miner_name = miner_name,
            .wallet = wallet,
            .allocated_tokens = allocated_tokens,
            .mining_reward = 0,
            .block_contribution = 0,
        };
    }

    pub fn getPrimaryAddress(self: *const MinerWallet) []const u8 {
        return self.wallet.address;
    }

    pub fn getBalance(self: *const MinerWallet) u64 {
        return self.wallet.balance;
    }

    pub fn addMiningReward(self: *MinerWallet, reward: u64) void {
        self.wallet.balance += reward;
        self.mining_reward += reward;
    }

    pub fn recordBlockFound(self: *MinerWallet) void {
        self.block_contribution += 1;
    }

    pub fn print(self: *const MinerWallet) void {
        std.debug.print(
            "[MinerWallet] {s} | Address={s} | Balance={d} SAT ({d:.2} OMNI) | Blocks={d}\n",
            .{
                self.miner_name,
                self.getPrimaryAddress(),
                self.getBalance(),
                @as(f64, @floatFromInt(self.getBalance())) / 100_000_000.0,
                self.block_contribution,
            },
        );
    }

    pub fn deinit(self: *MinerWallet) void {
        // Wallet cleanup handled by allocator
        _ = self;
    }
};

/// Genesis Block Token Distribution
pub const GenesisAllocation = struct {
    allocator: std.mem.Allocator,
    miner_wallets: std.ArrayList(MinerWallet),
    total_supply: u64,           // Total OMNI in SAT
    miners_count: u32,
    allocation_per_miner: u64,

    pub fn init(allocator: std.mem.Allocator, miners_count: u32) !GenesisAllocation {
        // Total supply: 21M OMNI
        const total_supply_omni: u64 = 21_000_000;
        const total_supply_sat = total_supply_omni * 100_000_000;  // Convert to SAT

        // Allocate equally to all miners
        const per_miner = total_supply_sat / miners_count;

        return GenesisAllocation{
            .allocator = allocator,
            .miner_wallets = std.ArrayList(MinerWallet).init(allocator),
            .total_supply = total_supply_sat,
            .miners_count = miners_count,
            .allocation_per_miner = per_miner,
        };
    }

    /// Generate wallet for each miner and allocate tokens
    pub fn generateMinerWallets(self: *GenesisAllocation) !void {
        std.debug.print(
            "\n[GENESIS] Allocating {d} OMNI ({d} SAT) equally among {d} miners\n",
            .{ self.total_supply / 100_000_000, self.total_supply, self.miners_count },
        );
        std.debug.print("[GENESIS] Per miner: {d:.4} OMNI ({d} SAT)\n\n", .{
            @as(f64, @floatFromInt(self.allocation_per_miner)) / 100_000_000.0,
            self.allocation_per_miner,
        });

        for (0..self.miners_count) |i| {
            var miner_wallet = try MinerWallet.init(
                self.allocator,
                @intCast(i),
                self.allocation_per_miner,
            );

            try self.miner_wallets.append(miner_wallet);

            // Print allocation
            miner_wallet.print();
        }

        std.debug.print("\n[GENESIS] ✅ {d} miner wallets generated\n\n", .{self.miners_count});
    }

    /// Get wallet by miner ID
    pub fn getWallet(self: *const GenesisAllocation, miner_id: u32) ?*const MinerWallet {
        for (self.miner_wallets.items) |*wallet| {
            if (wallet.miner_id == miner_id) {
                return wallet;
            }
        }
        return null;
    }

    /// Get miner by name
    pub fn getWalletByName(self: *const GenesisAllocation, miner_name: []const u8) ?*const MinerWallet {
        for (self.miner_wallets.items) |*wallet| {
            if (std.mem.eql(u8, wallet.miner_name, miner_name)) {
                return wallet;
            }
        }
        return null;
    }

    /// Total allocated to miners
    pub fn getTotalAllocated(self: *const GenesisAllocation) u64 {
        var total: u64 = 0;
        for (self.miner_wallets.items) |wallet| {
            total += wallet.getBalance();
        }
        return total;
    }

    /// Create genesis data for initialization
    pub fn getGenesisData(self: *const GenesisAllocation, allocator: std.mem.Allocator) ![]const u8 {
        var data = std.ArrayList(u8).init(allocator);

        // Write header
        const header = try std.fmt.allocPrint(
            allocator,
            "GENESIS_ALLOCATION\nTotal Supply: {d} OMNI\nMiners: {d}\n\n",
            .{ self.total_supply / 100_000_000, self.miners_count },
        );
        try data.appendSlice(header);

        // Write each miner's allocation
        for (self.miner_wallets.items) |wallet| {
            const miner_data = try std.fmt.allocPrint(
                allocator,
                "{s}|{s}|{d}\n",
                .{ wallet.miner_name, wallet.getPrimaryAddress(), wallet.getBalance() },
            );
            try data.appendSlice(miner_data);
        }

        return data.items;
    }

    /// Print genesis summary
    pub fn printSummary(self: *const GenesisAllocation) void {
        std.debug.print(
            \\
            \\╔════════════════════════════════════════════════╗
            \\║        OMNIBUS GENESIS ALLOCATION SUMMARY       ║
            \\╚════════════════════════════════════════════════╝
            \\
            \\Total Supply:         {d:>20} OMNI
            \\Per Miner:            {d:>20} SAT ({d:.4} OMNI)
            \\Active Miners:        {d:>20}
            \\Total Allocated:      {d:>20} SAT
            \\
            \\
        , .{
            self.total_supply / 100_000_000,
            self.allocation_per_miner,
            @as(f64, @floatFromInt(self.allocation_per_miner)) / 100_000_000.0,
            self.miners_count,
            self.getTotalAllocated(),
        });
    }

    pub fn deinit(self: *GenesisAllocation) void {
        self.miner_wallets.deinit();
    }
};

// Tests
const testing = std.testing;

test "miner wallet creation" {
    var miner = try MinerWallet.init(testing.allocator, 1, 1_000_000_000);
    defer miner.deinit();

    try testing.expectEqual(miner.miner_id, 1);
    try testing.expectEqual(miner.getBalance(), 1_000_000_000);
}

test "genesis allocation" {
    var genesis = try GenesisAllocation.init(testing.allocator, 10);
    defer genesis.deinit();

    try genesis.generateMinerWallets();

    try testing.expectEqual(genesis.miners_count, 10);
    try testing.expect(genesis.getWallet(0) != null);
    try testing.expect(genesis.getWallet(5) != null);
}

test "miner reward accumulation" {
    var miner = try MinerWallet.init(testing.allocator, 1, 1_000_000_000);
    defer miner.deinit();

    const initial = miner.getBalance();
    miner.addMiningReward(50_000_000);  // 0.5 OMNI reward

    try testing.expectEqual(miner.getBalance(), initial + 50_000_000);
}

test "block contribution tracking" {
    var miner = try MinerWallet.init(testing.allocator, 1, 1_000_000_000);
    defer miner.deinit();

    try testing.expectEqual(miner.block_contribution, 0);

    miner.recordBlockFound();
    miner.recordBlockFound();

    try testing.expectEqual(miner.block_contribution, 2);
}
