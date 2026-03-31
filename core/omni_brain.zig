/// omni_brain.zig — OmniBrain: coordonator central al ecosistemului
///
/// OmniBrain leaga toate componentele:
///   OmniBus (bare-metal OS)  ←→  OmniBus-BlockChainCore (Zig blockchain)
///
/// OmniBus = OS-ul de trading (54 module, <40µs, Ada SPARK)
/// BlockchainCore = L1 OMNI (sharding EGLD, Metachain, L2 channels)
///
/// OmniBrain coordoneaza:
///   - OS modes (ExecutionOS, RiskOS, etc.)
///   - Synapse scheduler (prioritati)
///   - Blockchain state (height, shards)
///   - Vault + UBI (economie)
///   - Console interactiva (status, comenzi)
const std = @import("std");
const os_mode_mod      = @import("os_mode.zig");
const synapse_mod      = @import("synapse_priority.zig");
const spark_mod        = @import("spark_invariants.zig");

pub const OsMode         = os_mode_mod.OsMode;
pub const OsModeManager  = os_mode_mod.OsModeManager;
pub const SynapseScheduler = synapse_mod.SynapseScheduler;
pub const SupplyGuard    = spark_mod.SupplyGuard;

// --- TIPURI ------------------------------------------------------------------

pub const BrainConfig = struct {
    /// Numarul de shard-uri la start
    num_shards:      u8   = 4,
    /// Modul de operare: full_node, light_node, trading_node
    node_type:       NodeType = .full_node,
    /// Activeaza trading engine (ExecutionOS)
    trading_enabled: bool = true,
    /// Activeaza blockchain (BlockchainOS)
    chain_enabled:   bool = true,
    /// Activeaza UBI distributor
    ubi_enabled:     bool = true,
};

pub const NodeType = enum(u8) {
    full_node     = 0,   // toate 7 OS-uri active
    light_node    = 1,   // doar InfraOS + BlockchainOS
    trading_node  = 2,   // ExecutionOS + RiskOS + StrategyOS + ValidationOS
    validator_node = 3,  // ValidationOS + GovernanceOS + BlockchainOS
};

pub const BrainStats = struct {
    uptime_blocks:     u64,
    total_cycles:      u64,
    blocks_mined:      u64,
    trades_executed:   u64,
    ubi_epochs:        u64,
    active_channels:   u64,
};

// --- OMNI BRAIN --------------------------------------------------------------

pub const OmniBrain = struct {
    allocator:  std.mem.Allocator,
    config:     BrainConfig,
    os_mgr:     OsModeManager,
    scheduler:  SynapseScheduler,
    supply:     SupplyGuard,
    stats:      BrainStats,
    started:    bool,

    pub fn init(allocator: std.mem.Allocator, config: BrainConfig) OmniBrain {
        return OmniBrain{
            .allocator = allocator,
            .config    = config,
            .os_mgr    = OsModeManager.init(),
            .scheduler = SynapseScheduler.init(),
            .supply    = SupplyGuard.init(),
            .stats     = std.mem.zeroes(BrainStats),
            .started   = false,
        };
    }

    /// Porneste OmniBrain: activeaza OS-urile corespunzatoare node_type
    pub fn start(self: *OmniBrain) !void {
        if (self.started) return error.AlreadyStarted;

        std.debug.print("\n[BRAIN] Starting OmniBrain | node_type={s}\n",
            .{ @tagName(self.config.node_type) });

        switch (self.config.node_type) {
            .full_node => {
                // Toate 7 OS-uri active
                inline for (0..7) |i| {
                    try self.os_mgr.activate(@enumFromInt(i));
                }
            },
            .light_node => {
                try self.os_mgr.activate(.infra);
                try self.os_mgr.activate(.blockchain);
            },
            .trading_node => {
                try self.os_mgr.activate(.execution);
                try self.os_mgr.activate(.risk);
                try self.os_mgr.activate(.strategy);
                try self.os_mgr.activate(.validation);
                if (self.config.chain_enabled) {
                    try self.os_mgr.activate(.blockchain);
                }
            },
            .validator_node => {
                try self.os_mgr.activate(.validation);
                try self.os_mgr.activate(.governance);
                try self.os_mgr.activate(.blockchain);
                try self.os_mgr.activate(.infra);
            },
        }

        self.started = true;
        std.debug.print("[BRAIN] Started | Active OS modules: {d}/7\n",
            .{ self.os_mgr.activeCount() });
    }

    /// Ruleaza N cicluri ale brain-ului
    pub fn runCycles(self: *OmniBrain, n: u64) !void {
        if (!self.started) return error.NotStarted;

        for (0..n) |_| {
            self.os_mgr.runCycle();
            self.stats.uptime_blocks += 1;
            self.stats.total_cycles  += 1;

            // Emite reward pentru bloc (prin SupplyGuard)
            const reward = spark_mod.getBlockReward(self.stats.blocks_mined);
            if (reward > 0) {
                self.supply.emit(reward) catch {};
                self.stats.blocks_mined += 1;
            }
        }
    }

    /// Inregistreaza un trade executat (din ExecutionOS)
    pub fn recordTrade(self: *OmniBrain) void {
        self.stats.trades_executed += 1;
    }

    /// Verifica invariantii Ada/SPARK
    pub fn assertInvariants(self: *const OmniBrain) void {
        self.supply.assertValid();
        // Verifica reward monoton pentru blocul curent
        if (self.stats.blocks_mined > 0) {
            spark_mod.assertRewardMonotone(self.stats.blocks_mined - 1);
        }
    }

    pub fn printStatus(self: *const OmniBrain) void {
        std.debug.print("\n╔══════════════════════════════════════╗\n", .{});
        std.debug.print("║        OMNI BRAIN STATUS             ║\n", .{});
        std.debug.print("╠══════════════════════════════════════╣\n", .{});
        std.debug.print("║ Node type:  {s:<25}║\n", .{ @tagName(self.config.node_type) });
        std.debug.print("║ Uptime:     {d:<25}║\n", .{ self.stats.uptime_blocks });
        std.debug.print("║ Blocks:     {d:<25}║\n", .{ self.stats.blocks_mined });
        std.debug.print("║ Trades:     {d:<25}║\n", .{ self.stats.trades_executed });
        std.debug.print("║ Supply:     {d:<25}║\n", .{ self.supply.emitted_sat });
        std.debug.print("║ OS active:  {d}/7{s:<22}║\n",
            .{ self.os_mgr.activeCount(), "" });
        std.debug.print("╚══════════════════════════════════════╝\n", .{});
    }
};

// --- TESTE -------------------------------------------------------------------
const testing = std.testing;

test "OmniBrain — init ok" {
    const brain = OmniBrain.init(testing.allocator, .{});
    try testing.expect(!brain.started);
    try testing.expectEqual(@as(u8, 0), brain.os_mgr.activeCount());
}

test "OmniBrain — start full_node activeaza toate 7" {
    var brain = OmniBrain.init(testing.allocator, .{ .node_type = .full_node });
    try brain.start();
    try testing.expectEqual(@as(u8, 7), brain.os_mgr.activeCount());
}

test "OmniBrain — start light_node activeaza 2" {
    var brain = OmniBrain.init(testing.allocator, .{ .node_type = .light_node });
    try brain.start();
    try testing.expectEqual(@as(u8, 2), brain.os_mgr.activeCount());
    try testing.expect(brain.os_mgr.isActive(.infra));
    try testing.expect(brain.os_mgr.isActive(.blockchain));
}

test "OmniBrain — start trading_node" {
    var brain = OmniBrain.init(testing.allocator, .{ .node_type = .trading_node });
    try brain.start();
    try testing.expect(brain.os_mgr.isActive(.execution));
    try testing.expect(brain.os_mgr.isActive(.risk));
    try testing.expect(brain.os_mgr.isActive(.strategy));
}

test "OmniBrain — start validator_node" {
    var brain = OmniBrain.init(testing.allocator, .{ .node_type = .validator_node });
    try brain.start();
    try testing.expect(brain.os_mgr.isActive(.validation));
    try testing.expect(brain.os_mgr.isActive(.governance));
    try testing.expect(brain.os_mgr.isActive(.blockchain));
}

test "OmniBrain — start twice returneaza eroare" {
    var brain = OmniBrain.init(testing.allocator, .{});
    try brain.start();
    try testing.expectError(error.AlreadyStarted, brain.start());
}

test "OmniBrain — runCycles creste uptime si blocks" {
    var brain = OmniBrain.init(testing.allocator, .{ .node_type = .full_node });
    try brain.start();
    try brain.runCycles(100);
    try testing.expectEqual(@as(u64, 100), brain.stats.uptime_blocks);
    try testing.expectEqual(@as(u64, 100), brain.stats.blocks_mined);
}

test "OmniBrain — supply emis dupa cicluri" {
    var brain = OmniBrain.init(testing.allocator, .{ .node_type = .full_node });
    try brain.start();
    try brain.runCycles(10);
    // 10 blocuri × 83_333_333 SAT = 833_333_330 SAT
    try testing.expectEqual(@as(u64, 10 * spark_mod.INITIAL_REWARD_SAT),
        brain.supply.emitted_sat);
}

test "OmniBrain — assertInvariants nu panics" {
    var brain = OmniBrain.init(testing.allocator, .{ .node_type = .full_node });
    try brain.start();
    try brain.runCycles(5);
    brain.assertInvariants();  // nu trebuie sa panics
}

test "OmniBrain — recordTrade" {
    var brain = OmniBrain.init(testing.allocator, .{ .node_type = .trading_node });
    try brain.start();
    brain.recordTrade();
    brain.recordTrade();
    brain.recordTrade();
    try testing.expectEqual(@as(u64, 3), brain.stats.trades_executed);
}
