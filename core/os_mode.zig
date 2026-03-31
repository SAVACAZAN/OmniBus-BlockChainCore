/// os_mode.zig — OmniBus OS Mode Manager
///
/// OmniBus ruleaza in 7 moduri simultane (din arhitectura bare-metal):
///   Tier 1: ExecutionOS    — trade execution <40µs
///   Tier 2: ValidationOS   — seL4 + Ada SPARK formal verification
///   Tier 3: StrategyOS     — arbitraj, grid, DCA, market maker
///   Tier 4: RiskOS         — circuit breaker, position limits
///   Tier 5: InfraOS        — P2P, database, logging
///   Tier 6: GovernanceOS   — 5/7 quorum, DAO
///   Tier 7: BlockchainOS   — Metachain, sharding, L2 channels
///
/// os_mode.zig gestioneaza tranzitia intre moduri si prioritatile Synapse.
const std = @import("std");

// --- TIPURI ------------------------------------------------------------------

pub const OsMode = enum(u8) {
    /// Modul de executie ultra-low-latency (<40µs per ciclu)
    execution    = 0,
    /// Validare formala Ada SPARK + seL4
    validation   = 1,
    /// Strategii de trading: arbitraj, grid, DCA
    strategy     = 2,
    /// Risk management: circuit breaker, limits
    risk         = 3,
    /// Infrastructura: P2P, DB, logging
    infra        = 4,
    /// Guvernanta: quorum 5/7, DAO
    governance   = 5,
    /// Blockchain: Metachain, sharding, L2
    blockchain   = 6,

    pub fn name(self: OsMode) []const u8 {
        return switch (self) {
            .execution   => "ExecutionOS",
            .validation  => "ValidationOS",
            .strategy    => "StrategyOS",
            .risk        => "RiskOS",
            .infra       => "InfraOS",
            .governance  => "GovernanceOS",
            .blockchain  => "BlockchainOS",
        };
    }

    /// Prioritatea modului (mai mic = mai prioritar)
    pub fn priority(self: OsMode) u8 {
        return @intFromEnum(self);
    }
};

pub const ModeStatus = enum(u8) {
    inactive  = 0,
    starting  = 1,
    active    = 2,
    suspended = 3,
    error_state = 4,
};

/// Starea unui modul OS
pub const OsModeState = struct {
    mode:          OsMode,
    status:        ModeStatus,
    activated_block: u64,
    cycles_run:    u64,        // cate cicluri a rulat
    last_error:    ?[]const u8,

    pub fn isActive(self: *const OsModeState) bool {
        return self.status == .active;
    }
};

// --- OS MODE MANAGER ---------------------------------------------------------

pub const OsModeManager = struct {
    modes:         [7]OsModeState,
    active_mask:   u8,    // bitmask: bit i = modul i activ
    current_block: u64,

    pub fn init() OsModeManager {
        var mgr = OsModeManager{
            .modes         = undefined,
            .active_mask   = 0,
            .current_block = 0,
        };

        for (0..7) |i| {
            mgr.modes[i] = OsModeState{
                .mode            = @enumFromInt(i),
                .status          = .inactive,
                .activated_block = 0,
                .cycles_run      = 0,
                .last_error      = null,
            };
        }

        return mgr;
    }

    /// Activeaza un modul OS
    pub fn activate(self: *OsModeManager, mode: OsMode) !void {
        const i = @intFromEnum(mode);
        if (self.modes[i].status == .active) return error.AlreadyActive;
        self.modes[i].status         = .active;
        self.modes[i].activated_block = self.current_block;
        self.active_mask |= @as(u8, 1) << @intCast(i);
        std.debug.print("[OS] {s} activated at block {d}\n",
            .{ mode.name(), self.current_block });
    }

    /// Suspenda un modul OS
    pub fn pauseMode(self: *OsModeManager, mode: OsMode) !void {
        const i = @intFromEnum(mode);
        if (self.modes[i].status != .active) return error.NotActive;
        self.modes[i].status = .suspended;
        self.active_mask &= ~(@as(u8, 1) << @intCast(i));
        std.debug.print("[OS] {s} suspended\n", .{ mode.name() });
    }

    /// Ruleaza un ciclu pentru toate modurile active (in ordine de prioritate)
    pub fn runCycle(self: *OsModeManager) void {
        self.current_block += 1;
        // Tier 1 (ExecutionOS) se ruleaza primul — highest priority
        for (0..7) |i| {
            if (self.modes[i].status == .active) {
                self.modes[i].cycles_run += 1;
            }
        }
    }

    pub fn isActive(self: *const OsModeManager, mode: OsMode) bool {
        return self.active_mask & (@as(u8, 1) << @intCast(@intFromEnum(mode))) != 0;
    }

    pub fn activeCount(self: *const OsModeManager) u8 {
        return @popCount(self.active_mask);
    }

    pub fn printStatus(self: *const OsModeManager) void {
        std.debug.print("[OS_MGR] Active: {d}/7 | block: {d}\n",
            .{ self.activeCount(), self.current_block });
        for (self.modes) |m| {
            if (m.status == .active) {
                std.debug.print("  [{d}] {s} | cycles={d}\n",
                    .{ m.mode.priority(), m.mode.name(), m.cycles_run });
            }
        }
    }
};

// --- TESTE -------------------------------------------------------------------
const testing = std.testing;

test "OsMode — name si priority corecte" {
    try testing.expectEqualStrings("ExecutionOS",  OsMode.execution.name());
    try testing.expectEqualStrings("BlockchainOS", OsMode.blockchain.name());
    try testing.expectEqual(@as(u8, 0), OsMode.execution.priority());
    try testing.expectEqual(@as(u8, 6), OsMode.blockchain.priority());
}

test "OsModeManager — init toate inactive" {
    const mgr = OsModeManager.init();
    try testing.expectEqual(@as(u8, 0), mgr.activeCount());
    try testing.expect(!mgr.isActive(.execution));
}

test "OsModeManager — activate mode" {
    var mgr = OsModeManager.init();
    try mgr.activate(.execution);
    try testing.expect(mgr.isActive(.execution));
    try testing.expectEqual(@as(u8, 1), mgr.activeCount());
}

test "OsModeManager — activate twice returneaza eroare" {
    var mgr = OsModeManager.init();
    try mgr.activate(.execution);
    try testing.expectError(error.AlreadyActive, mgr.activate(.execution));
}

test "OsModeManager — suspend mode" {
    var mgr = OsModeManager.init();
    try mgr.activate(.strategy);
    try mgr.pauseMode(.strategy);
    try testing.expect(!mgr.isActive(.strategy));
}

test "OsModeManager — toate 7 moduri active" {
    var mgr = OsModeManager.init();
    inline for (0..7) |i| {
        try mgr.activate(@enumFromInt(i));
    }
    try testing.expectEqual(@as(u8, 7), mgr.activeCount());
}

test "OsModeManager — runCycle creste cycles_run" {
    var mgr = OsModeManager.init();
    try mgr.activate(.execution);
    try mgr.activate(.blockchain);
    mgr.runCycle();
    mgr.runCycle();
    mgr.runCycle();
    try testing.expectEqual(@as(u64, 3), mgr.modes[0].cycles_run);
    try testing.expectEqual(@as(u64, 3), mgr.modes[6].cycles_run);
}
