/// miner_genesis.zig — Distributie tokeni la geneza pentru mineri
/// Fiecare miner primeste un wallet generat din mnemonic seed determinist
const std        = @import("std");
const array_list = std.array_list;
const genesis_mod = @import("genesis.zig");

/// Wallet simplu pentru geneza (adresa + balance, fara cheie privata completa)
pub const MinerWallet = struct {
    miner_id:           u32,
    miner_name:         []const u8,
    address:            []const u8,   // ob_omni_... format
    balance:            u64,          // SAT
    mining_reward:      u64,
    block_contribution: u32,
    allocator:          std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, miner_id: u32, allocated_tokens: u64) !MinerWallet {
        const miner_name = try std.fmt.allocPrint(allocator, "miner-{d}", .{miner_id});

        // Adresa derivata determinist din miner_id (format ob_omni_MINER<id>)
        const address = try std.fmt.allocPrint(allocator, "ob_omni_MINER{d:0>8}", .{miner_id});

        return MinerWallet{
            .miner_id           = miner_id,
            .miner_name         = miner_name,
            .address            = address,
            .balance            = allocated_tokens,
            .mining_reward      = 0,
            .block_contribution = 0,
            .allocator          = allocator,
        };
    }

    pub fn getPrimaryAddress(self: *const MinerWallet) []const u8 {
        return self.address;
    }

    pub fn getBalance(self: *const MinerWallet) u64 {
        return self.balance;
    }

    pub fn addMiningReward(self: *MinerWallet, reward: u64) void {
        self.balance        += reward;
        self.mining_reward  += reward;
    }

    pub fn recordBlockFound(self: *MinerWallet) void {
        self.block_contribution += 1;
    }

    pub fn print(self: *const MinerWallet) void {
        std.debug.print(
            "[MinerWallet] {s} | Address={s} | Balance={d} SAT ({d:.4} OMNI) | Blocks={d}\n",
            .{
                self.miner_name,
                self.getPrimaryAddress(),
                self.getBalance(),
                @as(f64, @floatFromInt(self.getBalance())) / 1_000_000_000.0,
                self.block_contribution,
            },
        );
    }

    pub fn deinit(self: *MinerWallet) void {
        self.allocator.free(self.miner_name);
        self.allocator.free(self.address);
    }
};

/// Genesis Block Token Distribution
pub const GenesisAllocation = struct {
    allocator:            std.mem.Allocator,
    miner_wallets:        array_list.Managed(MinerWallet),
    total_supply:         u64,   // SAT
    miners_count:         u32,
    allocation_per_miner: u64,

    pub fn init(allocator: std.mem.Allocator, miners_count: u32) !GenesisAllocation {
        const total_supply_omni: u64 = 21_000_000;
        const total_supply_sat       = total_supply_omni * 1_000_000_000;
        const per_miner              = total_supply_sat / miners_count;

        return GenesisAllocation{
            .allocator            = allocator,
            .miner_wallets        = array_list.Managed(MinerWallet).init(allocator),
            .total_supply         = total_supply_sat,
            .miners_count         = miners_count,
            .allocation_per_miner = per_miner,
        };
    }

    pub fn generateMinerWallets(self: *GenesisAllocation) !void {
        std.debug.print(
            "\n[GENESIS] Allocating {d} OMNI ({d} SAT) equally among {d} miners\n",
            .{ self.total_supply / 1_000_000_000, self.total_supply, self.miners_count },
        );
        std.debug.print("[GENESIS] Per miner: {d:.4} OMNI ({d} SAT)\n\n", .{
            @as(f64, @floatFromInt(self.allocation_per_miner)) / 1_000_000_000.0,
            self.allocation_per_miner,
        });

        for (0..self.miners_count) |i| {
            const miner_wallet = try MinerWallet.init(
                self.allocator,
                @intCast(i),
                self.allocation_per_miner,
            );
            miner_wallet.print();
            try self.miner_wallets.append(miner_wallet);
        }

        std.debug.print("\n[GENESIS] {d} miner wallets generated\n\n", .{self.miners_count});
    }

    pub fn getWallet(self: *const GenesisAllocation, miner_id: u32) ?*const MinerWallet {
        for (self.miner_wallets.items) |*w| {
            if (w.miner_id == miner_id) return w;
        }
        return null;
    }

    pub fn getTotalAllocated(self: *const GenesisAllocation) u64 {
        var total: u64 = 0;
        for (self.miner_wallets.items) |w| total += w.getBalance();
        return total;
    }

    pub fn printSummary(self: *const GenesisAllocation) void {
        std.debug.print(
            \\
            \\  OMNIBUS GENESIS ALLOCATION
            \\  Total Supply:    {d} OMNI
            \\  Per Miner:       {d} SAT  ({d:.4} OMNI)
            \\  Active Miners:   {d}
            \\  Total Allocated: {d} SAT
            \\
            \\
        , .{
            self.total_supply / 1_000_000_000,
            self.allocation_per_miner,
            @as(f64, @floatFromInt(self.allocation_per_miner)) / 1_000_000_000.0,
            self.miners_count,
            self.getTotalAllocated(),
        });
    }

    pub fn deinit(self: *GenesisAllocation) void {
        for (self.miner_wallets.items) |*w| w.deinit();
        self.miner_wallets.deinit();
    }
};

// ─── Teste ────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "miner wallet creation" {
    var miner = try MinerWallet.init(testing.allocator, 1, 1_000_000_000);
    defer miner.deinit();

    try testing.expectEqual(@as(u32, 1), miner.miner_id);
    try testing.expectEqual(@as(u64, 1_000_000_000), miner.getBalance());
}

test "genesis allocation — 10 mineri" {
    var genesis = try GenesisAllocation.init(testing.allocator, 10);
    defer genesis.deinit();

    try genesis.generateMinerWallets();

    try testing.expectEqual(@as(u32, 10), genesis.miners_count);
    try testing.expect(genesis.getWallet(0) != null);
    try testing.expect(genesis.getWallet(5) != null);
    try testing.expect(genesis.getWallet(10) == null);  // out of range
}

test "total supply = 21M OMNI" {
    const genesis = try GenesisAllocation.init(testing.allocator, 1);
    try testing.expectEqual(@as(u64, 21_000_000_000_000_000), genesis.total_supply);
}

test "reward accumulation" {
    var miner = try MinerWallet.init(testing.allocator, 1, 1_000_000_000);
    defer miner.deinit();

    const initial = miner.getBalance();
    miner.addMiningReward(8_333_333);  // 1 bloc OMNI

    try testing.expectEqual(initial + 8_333_333, miner.getBalance());
    try testing.expectEqual(@as(u64, 8_333_333), miner.mining_reward);
}

test "block contribution tracking" {
    var miner = try MinerWallet.init(testing.allocator, 1, 1_000_000_000);
    defer miner.deinit();

    try testing.expectEqual(@as(u32, 0), miner.block_contribution);
    miner.recordBlockFound();
    miner.recordBlockFound();
    try testing.expectEqual(@as(u32, 2), miner.block_contribution);
}

test "allocation per miner — 21M / 10 mineri" {
    const genesis = try GenesisAllocation.init(testing.allocator, 10);
    // 21_000_000_000_000_000 SAT / 10 = 2_100_000_000_000_000 SAT = 2.1M OMNI each
    try testing.expectEqual(@as(u64, 2_100_000_000_000_000), genesis.allocation_per_miner);
}
