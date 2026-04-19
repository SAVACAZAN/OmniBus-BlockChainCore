/// consensus_pouw.zig — Proof of Useful Work (PoUW): Consens si Recompense
///
/// In loc sa mineze hash-uri inutile, minerii fac MUNCA UTILA:
///   - Matching engine: potrivesc ordine de cumparare/vanzare
///   - Price oracle: submitera preturi de pe exchange-uri
///   - Settlement: proceseaza settlement-uri pe Liberty Chain
///   - Sync: mentin orderbook-ul sincronizat cu peer-ii
///
/// Block reward = BASE_REWARD + MATCHING_REWARD + ORACLE_REWARD
///
///   BASE_REWARD:      50 OMNI per block (halving la 210,000 blocuri, ca Bitcoin)
///   MATCHING_REWARD:  0.05% din volumul potrivit in block
///   ORACLE_REWARD:    1 OMNI per price update submiterat
///
/// Slashing:
///   - Matching gresit         → pierde tot stake-ul
///   - Pret incorect (>5% dev) → pierde 50% din stake
///   - Offline >1h             → pierde 1% din stake
///   - Double work claim       → pierde tot stake-ul
///
/// Self-contained: nu importa din staking.zig, consensus.zig, oracle.zig
/// pentru a evita dependinte circulare.

const std = @import("std");

// ─── Constante ──────────────────────────────────────────────────────────────────

pub const MAX_MINERS: usize = 128;
pub const MAX_SLASH_EVENTS: usize = 64;

// Reward constants (in SAT, 1 OMNI = 1_000_000_000 SAT)
pub const INITIAL_BLOCK_REWARD_SAT: u64 = 50_000_000_000; // 50 OMNI
pub const HALVING_INTERVAL: u64 = 210_000; // blocks
pub const MAX_HALVINGS: u8 = 32; // after 32 halvings, reward = 0

pub const MATCHING_FEE_BPS: u64 = 5; // 0.05% = 5 basis points
pub const BPS_DENOMINATOR: u64 = 10_000; // basis point denominator
pub const ORACLE_REWARD_SAT: u64 = 1_000_000_000; // 1 OMNI per price update

pub const MAX_SUPPLY_SAT: u64 = 21_000_000_000_000_000; // 21M OMNI in SAT

// Slashing percentages
pub const SLASH_INVALID_MATCHING_PCT: u64 = 100; // lose all stake
pub const SLASH_INVALID_PRICE_PCT: u64 = 50; // lose 50% stake
pub const SLASH_DOWNTIME_PCT: u64 = 1; // lose 1% stake
pub const SLASH_DOUBLE_WORK_PCT: u64 = 100; // lose all stake
pub const MIN_STAKE_SAT: u64 = 1_000_000_000_000; // 1000 OMNI minimum stake

// Activity
pub const OFFLINE_THRESHOLD_BLOCKS: u64 = 36_000; // ~1 hour at 0.1s sub-blocks

// ─── Tipuri ─────────────────────────────────────────────────────────────────────

/// Tipul de munca utila pe care miner-ul o face
pub const WorkType = enum(u8) {
    matching = 0, // ran matching engine, produced fills
    oracle = 1, // submitted price update
    settlement = 2, // submitted settlement to Liberty Chain
    sync = 3, // kept orderbook in sync with peers
};

/// Raport de munca utila de la un miner (inclus in block)
pub const WorkReport = struct {
    miner_address: [64]u8,
    miner_addr_len: u8,
    work_type: WorkType,
    block_height: u64,
    timestamp_ms: i64,
    /// For matching: number of fills produced
    fills_count: u32,
    /// For matching: total volume matched in SAT
    volume_matched_sat: u64,
    /// For oracle: number of price updates submitted
    price_updates: u32,
    /// For settlement: number of settlements submitted
    settlements_count: u32,
    /// Hash of the work output (merkle root of fills/prices/settlements)
    work_hash: [32]u8,
    /// Signature of the miner over the work report
    signature: [64]u8,

    pub fn getMinerAddress(self: *const WorkReport) []const u8 {
        return self.miner_address[0..self.miner_addr_len];
    }
};

/// Reward breakdown for a single miner in a block
pub const MinerReward = struct {
    miner_address: [64]u8,
    miner_addr_len: u8,
    base_reward_sat: u64,
    matching_reward_sat: u64,
    oracle_reward_sat: u64,
    total_reward_sat: u64,
    block_height: u64,

    pub fn getMinerAddress(self: *const MinerReward) []const u8 {
        return self.miner_address[0..self.miner_addr_len];
    }
};

/// Slash reason — de ce e penalizat miner-ul
pub const SlashReason = enum(u8) {
    invalid_matching = 0, // submitted wrong matching results
    invalid_price = 1, // price >5% deviation from consensus
    downtime = 2, // offline > 1 hour
    double_work = 3, // claimed work they didn't do

    pub fn slashPercentage(self: SlashReason) u64 {
        return switch (self) {
            .invalid_matching => SLASH_INVALID_MATCHING_PCT,
            .invalid_price => SLASH_INVALID_PRICE_PCT,
            .downtime => SLASH_DOWNTIME_PCT,
            .double_work => SLASH_DOUBLE_WORK_PCT,
        };
    }
};

/// Slashing event — penalizare aplicata unui miner
pub const SlashEvent = struct {
    miner_address: [64]u8,
    miner_addr_len: u8,
    reason: SlashReason,
    slash_amount_sat: u64,
    evidence_hash: [32]u8,
    block_height: u64,
    timestamp_ms: i64,

    pub fn getMinerAddress(self: *const SlashEvent) []const u8 {
        return self.miner_address[0..self.miner_addr_len];
    }
};

/// Miner activity tracker — starea curenta a unui miner
pub const MinerActivity = struct {
    miner_address: [64]u8,
    miner_addr_len: u8,
    last_active_block: u64,
    total_blocks_mined: u64,
    total_rewards_sat: u64,
    total_slashed_sat: u64,
    stake_sat: u64, // miner's current stake
    is_active: bool,

    pub fn getMinerAddress(self: *const MinerActivity) []const u8 {
        return self.miner_address[0..self.miner_addr_len];
    }

    /// Net rewards = total earned minus total slashed (saturating)
    pub fn netRewardsSat(self: *const MinerActivity) u64 {
        if (self.total_rewards_sat > self.total_slashed_sat) {
            return self.total_rewards_sat - self.total_slashed_sat;
        }
        return 0;
    }
};

// ─── Erori ──────────────────────────────────────────────────────────────────────

pub const PoUWError = error{
    TooManyReports,
    TooManySlashEvents,
    TooManyMiners,
    MinerNotFound,
    InsufficientStake,
    SupplyCapExceeded,
    DuplicateReport,
};

// ─── Motor Principal PoUW ───────────────────────────────────────────────────────

/// Main PoUW Engine — calculeaza recompense pe baza muncii utile
pub const PoUWEngine = struct {
    // Work reports for current block
    work_reports: [MAX_MINERS]WorkReport,
    report_count: u32,
    report_valid: [MAX_MINERS]bool,

    // Rewards calculated
    rewards: [MAX_MINERS]MinerReward,
    reward_count: u32,

    // Slashing events
    slash_events: [MAX_SLASH_EVENTS]SlashEvent,
    slash_count: u32,

    // Miner activity tracking (last seen block per miner)
    miner_last_active: [MAX_MINERS]MinerActivity,
    active_miner_count: u32,

    // Chain state
    current_block: u64,

    // Total supply minted so far (tracked to enforce cap)
    total_minted_sat: u64,

    /// Initializeaza un engine PoUW gol
    pub fn init() PoUWEngine {
        return PoUWEngine{
            .work_reports = std.mem.zeroes([MAX_MINERS]WorkReport),
            .report_count = 0,
            .report_valid = [_]bool{false} ** MAX_MINERS,
            .rewards = std.mem.zeroes([MAX_MINERS]MinerReward),
            .reward_count = 0,
            .slash_events = std.mem.zeroes([MAX_SLASH_EVENTS]SlashEvent),
            .slash_count = 0,
            .miner_last_active = std.mem.zeroes([MAX_MINERS]MinerActivity),
            .active_miner_count = 0,
            .current_block = 0,
            .total_minted_sat = 0,
        };
    }

    /// Submit a work report from a miner
    pub fn submitWorkReport(self: *PoUWEngine, report: WorkReport) PoUWError!void {
        if (self.report_count >= MAX_MINERS) {
            return PoUWError.TooManyReports;
        }

        // Check for duplicate reports from same miner in same block
        const new_addr = report.miner_address[0..report.miner_addr_len];
        for (0..self.report_count) |i| {
            const existing = &self.work_reports[i];
            const existing_addr = existing.miner_address[0..existing.miner_addr_len];
            if (std.mem.eql(u8, new_addr, existing_addr) and
                existing.work_type == report.work_type)
            {
                return PoUWError.DuplicateReport;
            }
        }

        self.work_reports[self.report_count] = report;
        self.report_valid[self.report_count] = true;
        self.report_count += 1;

        // Update miner activity
        self.updateMinerActivity(report.miner_address, report.miner_addr_len, report.block_height);
    }

    /// Calculate the base block reward with halving schedule
    pub fn getBlockReward(block_height: u64) u64 {
        const halvings = block_height / HALVING_INTERVAL;
        if (halvings >= MAX_HALVINGS) {
            return 0;
        }
        // Shift right by number of halvings (integer division by powers of 2)
        return INITIAL_BLOCK_REWARD_SAT >> @as(u6, @intCast(halvings));
    }

    /// Calculate matching reward: 0.05% (5 bps) of volume matched
    pub fn getMatchingReward(volume_sat: u64) u64 {
        // volume_sat * 5 / 10000
        // To avoid overflow with large volumes, divide first if needed
        if (volume_sat > std.math.maxInt(u64) / MATCHING_FEE_BPS) {
            // Large volume: divide first, then multiply (slight precision loss)
            return (volume_sat / BPS_DENOMINATOR) * MATCHING_FEE_BPS;
        }
        return (volume_sat * MATCHING_FEE_BPS) / BPS_DENOMINATOR;
    }

    /// Calculate oracle reward: 1 OMNI per price update
    pub fn getOracleReward(updates: u32) u64 {
        return @as(u64, updates) * ORACLE_REWARD_SAT;
    }

    /// Calculate all rewards for a block, splitting base reward among active miners
    pub fn calculateRewards(self: *PoUWEngine, block_height: u64) void {
        self.current_block = block_height;
        self.reward_count = 0;

        if (self.report_count == 0) return;

        const base_reward = getBlockReward(block_height);

        // Count valid, online miners
        var valid_count: u32 = 0;
        for (0..self.report_count) |i| {
            if (self.report_valid[i]) {
                const addr = self.work_reports[i].miner_address[0..self.work_reports[i].miner_addr_len];
                if (self.isOnline(addr, block_height)) {
                    valid_count += 1;
                }
            }
        }

        if (valid_count == 0) return;

        // Split base reward evenly among valid miners + add work-specific rewards
        const base_per_miner = base_reward / @as(u64, valid_count);

        for (0..self.report_count) |i| {
            if (!self.report_valid[i]) continue;

            const report = &self.work_reports[i];
            const addr = report.miner_address[0..report.miner_addr_len];
            if (!self.isOnline(addr, block_height)) continue;

            var reward = MinerReward{
                .miner_address = report.miner_address,
                .miner_addr_len = report.miner_addr_len,
                .base_reward_sat = base_per_miner,
                .matching_reward_sat = 0,
                .oracle_reward_sat = 0,
                .total_reward_sat = base_per_miner,
                .block_height = block_height,
            };

            // Add work-specific rewards
            switch (report.work_type) {
                .matching => {
                    reward.matching_reward_sat = getMatchingReward(report.volume_matched_sat);
                    reward.total_reward_sat += reward.matching_reward_sat;
                },
                .oracle => {
                    reward.oracle_reward_sat = getOracleReward(report.price_updates);
                    reward.total_reward_sat += reward.oracle_reward_sat;
                },
                .settlement, .sync => {
                    // base reward only for settlement and sync work
                },
            }

            // Enforce supply cap
            if (self.total_minted_sat + reward.total_reward_sat > MAX_SUPPLY_SAT) {
                const remaining = MAX_SUPPLY_SAT - self.total_minted_sat;
                if (remaining == 0) {
                    reward.total_reward_sat = 0;
                    reward.base_reward_sat = 0;
                    reward.matching_reward_sat = 0;
                    reward.oracle_reward_sat = 0;
                } else {
                    reward.total_reward_sat = remaining;
                    // Scale down proportionally
                    reward.base_reward_sat = @min(reward.base_reward_sat, remaining);
                    const left = remaining -| reward.base_reward_sat;
                    reward.matching_reward_sat = @min(reward.matching_reward_sat, left);
                    reward.oracle_reward_sat = @min(reward.oracle_reward_sat, left -| reward.matching_reward_sat);
                }
            }

            self.total_minted_sat += reward.total_reward_sat;

            // Update miner activity totals
            self.creditMinerReward(addr, reward.total_reward_sat);

            if (self.reward_count < MAX_MINERS) {
                self.rewards[self.reward_count] = reward;
                self.reward_count += 1;
            }
        }
    }

    /// Report a slashing event against a miner
    pub fn reportSlash(self: *PoUWEngine, event: SlashEvent) PoUWError!void {
        if (self.slash_count >= MAX_SLASH_EVENTS) {
            return PoUWError.TooManySlashEvents;
        }

        // Apply slash to miner activity
        const addr = event.miner_address[0..event.miner_addr_len];
        if (self.findMinerIndex(addr)) |idx| {
            const activity = &self.miner_last_active[idx];
            activity.total_slashed_sat += event.slash_amount_sat;
            // Reduce stake
            if (activity.stake_sat > event.slash_amount_sat) {
                activity.stake_sat -= event.slash_amount_sat;
            } else {
                activity.stake_sat = 0;
                activity.is_active = false;
            }
        }

        self.slash_events[self.slash_count] = event;
        self.slash_count += 1;
    }

    /// Calculate slash amount for a miner based on their stake and the offense
    pub fn calculateSlashAmount(stake_sat: u64, reason: SlashReason) u64 {
        const pct = reason.slashPercentage();
        return (stake_sat * pct) / 100;
    }

    /// Check if miner is considered online (active within OFFLINE_THRESHOLD_BLOCKS)
    pub fn isOnline(self: *const PoUWEngine, miner_addr: []const u8, current_block: u64) bool {
        if (self.findMinerIndexConst(miner_addr)) |idx| {
            const activity = &self.miner_last_active[idx];
            if (!activity.is_active) return false;
            if (current_block <= activity.last_active_block) return true;
            return (current_block - activity.last_active_block) < OFFLINE_THRESHOLD_BLOCKS;
        }
        // New miner (not yet tracked) is considered online for their first report
        return true;
    }

    /// Compute a deterministic merkle root over all rewards in this block
    pub fn rewardsMerkleRoot(self: *const PoUWEngine) [32]u8 {
        if (self.reward_count == 0) {
            return std.mem.zeroes([32]u8);
        }

        // Build leaf hashes from rewards
        var hashes: [MAX_MINERS][32]u8 = undefined;
        for (0..self.reward_count) |i| {
            var hasher = std.crypto.hash.sha2.Sha256.init(.{});
            const r = &self.rewards[i];
            hasher.update(r.miner_address[0..r.miner_addr_len]);
            hasher.update(&std.mem.toBytes(r.base_reward_sat));
            hasher.update(&std.mem.toBytes(r.matching_reward_sat));
            hasher.update(&std.mem.toBytes(r.oracle_reward_sat));
            hasher.update(&std.mem.toBytes(r.total_reward_sat));
            hasher.update(&std.mem.toBytes(r.block_height));
            hashes[i] = hasher.finalResult();
        }

        // Iteratively hash pairs until we have a single root
        var count: usize = self.reward_count;
        while (count > 1) {
            var new_count: usize = 0;
            var j: usize = 0;
            while (j < count) : (j += 2) {
                var hasher = std.crypto.hash.sha2.Sha256.init(.{});
                hasher.update(&hashes[j]);
                if (j + 1 < count) {
                    hasher.update(&hashes[j + 1]);
                } else {
                    // Odd node: hash with itself
                    hasher.update(&hashes[j]);
                }
                hashes[new_count] = hasher.finalResult();
                new_count += 1;
            }
            count = new_count;
        }

        return hashes[0];
    }

    /// Reset block state for next block (keep miner activity)
    pub fn resetBlock(self: *PoUWEngine) void {
        self.work_reports = std.mem.zeroes([MAX_MINERS]WorkReport);
        self.report_count = 0;
        self.report_valid = [_]bool{false} ** MAX_MINERS;
        self.rewards = std.mem.zeroes([MAX_MINERS]MinerReward);
        self.reward_count = 0;
        self.slash_events = std.mem.zeroes([MAX_SLASH_EVENTS]SlashEvent);
        self.slash_count = 0;
    }

    /// Calculate total supply mined up to a given block height
    /// Uses geometric series: sum = R * (1 - (1/2)^n) / (1 - 1/2) per era
    pub fn totalSupplyMined(block_height: u64) u64 {
        var total: u64 = 0;
        var remaining_blocks = block_height;
        var era: u64 = 0;

        while (remaining_blocks > 0 and era < MAX_HALVINGS) {
            const blocks_in_era = @min(remaining_blocks, HALVING_INTERVAL);
            const reward = INITIAL_BLOCK_REWARD_SAT >> @as(u6, @intCast(era));
            if (reward == 0) break;

            // Check for overflow before adding
            const era_total = blocks_in_era * reward;
            if (total + era_total > MAX_SUPPLY_SAT) {
                return MAX_SUPPLY_SAT;
            }
            total += era_total;
            remaining_blocks -= blocks_in_era;
            era += 1;
        }

        return @min(total, MAX_SUPPLY_SAT);
    }

    // ─── Functii interne ────────────────────────────────────────────────────

    /// Update miner activity tracking (register activity at block)
    fn updateMinerActivity(self: *PoUWEngine, addr: [64]u8, addr_len: u8, block_height: u64) void {
        const slice = addr[0..addr_len];
        if (self.findMinerIndex(slice)) |idx| {
            self.miner_last_active[idx].last_active_block = block_height;
            self.miner_last_active[idx].total_blocks_mined += 1;
            self.miner_last_active[idx].is_active = true;
        } else {
            // New miner
            if (self.active_miner_count < MAX_MINERS) {
                var activity = std.mem.zeroes(MinerActivity);
                activity.miner_address = addr;
                activity.miner_addr_len = addr_len;
                activity.last_active_block = block_height;
                activity.total_blocks_mined = 1;
                activity.is_active = true;
                activity.stake_sat = MIN_STAKE_SAT; // default minimum stake
                self.miner_last_active[self.active_miner_count] = activity;
                self.active_miner_count += 1;
            }
        }
    }

    /// Credit reward to miner's activity record
    fn creditMinerReward(self: *PoUWEngine, addr: []const u8, amount_sat: u64) void {
        if (self.findMinerIndex(addr)) |idx| {
            self.miner_last_active[idx].total_rewards_sat += amount_sat;
        }
    }

    /// Find miner index in activity array (mutable)
    fn findMinerIndex(self: *PoUWEngine, addr: []const u8) ?usize {
        for (0..self.active_miner_count) |i| {
            const a = &self.miner_last_active[i];
            if (a.miner_addr_len == addr.len and
                std.mem.eql(u8, a.miner_address[0..a.miner_addr_len], addr))
            {
                return i;
            }
        }
        return null;
    }

    /// Find miner index in activity array (const)
    fn findMinerIndexConst(self: *const PoUWEngine, addr: []const u8) ?usize {
        for (0..self.active_miner_count) |i| {
            const a = &self.miner_last_active[i];
            if (a.miner_addr_len == addr.len and
                std.mem.eql(u8, a.miner_address[0..a.miner_addr_len], addr))
            {
                return i;
            }
        }
        return null;
    }
};

// ─── Helper: creeaza un WorkReport de test ──────────────────────────────────────

fn makeTestAddress(comptime name: []const u8) struct { addr: [64]u8, len: u8 } {
    var addr: [64]u8 = std.mem.zeroes([64]u8);
    @memcpy(addr[0..name.len], name);
    return .{ .addr = addr, .len = @intCast(name.len) };
}

fn makeWorkReport(
    comptime miner_name: []const u8,
    work_type: WorkType,
    block_height: u64,
    volume_sat: u64,
    fills: u32,
    price_updates: u32,
    settlements: u32,
) WorkReport {
    const a = makeTestAddress(miner_name);
    return WorkReport{
        .miner_address = a.addr,
        .miner_addr_len = a.len,
        .work_type = work_type,
        .block_height = block_height,
        .timestamp_ms = @as(i64, @intCast(block_height)) * 100,
        .fills_count = fills,
        .volume_matched_sat = volume_sat,
        .price_updates = price_updates,
        .settlements_count = settlements,
        .work_hash = std.mem.zeroes([32]u8),
        .signature = std.mem.zeroes([64]u8),
    };
}

// ─── Teste ──────────────────────────────────────────────────────────────────────

test "init PoUW engine" {
    const engine = PoUWEngine.init();
    try std.testing.expectEqual(@as(u32, 0), engine.report_count);
    try std.testing.expectEqual(@as(u32, 0), engine.reward_count);
    try std.testing.expectEqual(@as(u32, 0), engine.slash_count);
    try std.testing.expectEqual(@as(u32, 0), engine.active_miner_count);
    try std.testing.expectEqual(@as(u64, 0), engine.current_block);
    try std.testing.expectEqual(@as(u64, 0), engine.total_minted_sat);
}

test "block reward — initial" {
    const reward = PoUWEngine.getBlockReward(0);
    try std.testing.expectEqual(INITIAL_BLOCK_REWARD_SAT, reward);
    // Also check block 1
    try std.testing.expectEqual(INITIAL_BLOCK_REWARD_SAT, PoUWEngine.getBlockReward(1));
    // Last block before first halving
    try std.testing.expectEqual(INITIAL_BLOCK_REWARD_SAT, PoUWEngine.getBlockReward(HALVING_INTERVAL - 1));
}

test "block reward — after 1 halving" {
    const reward = PoUWEngine.getBlockReward(HALVING_INTERVAL);
    try std.testing.expectEqual(INITIAL_BLOCK_REWARD_SAT / 2, reward); // 25 OMNI
    try std.testing.expectEqual(@as(u64, 25_000_000_000), reward);
}

test "block reward — after 10 halvings" {
    const reward = PoUWEngine.getBlockReward(HALVING_INTERVAL * 10);
    // 50 OMNI >> 10 = 50 / 1024 OMNI
    const expected = INITIAL_BLOCK_REWARD_SAT >> 10;
    try std.testing.expectEqual(expected, reward);
    try std.testing.expect(reward > 0);
    // After 32 halvings, reward should be 0
    try std.testing.expectEqual(@as(u64, 0), PoUWEngine.getBlockReward(HALVING_INTERVAL * 32));
}

test "matching reward calculation" {
    // 0.05% of 1,000,000,000,000 SAT (1000 OMNI)
    const volume: u64 = 1_000_000_000_000;
    const reward = PoUWEngine.getMatchingReward(volume);
    // 1000 OMNI * 0.0005 = 0.5 OMNI = 500,000,000 SAT
    try std.testing.expectEqual(@as(u64, 500_000_000), reward);

    // Zero volume = zero reward
    try std.testing.expectEqual(@as(u64, 0), PoUWEngine.getMatchingReward(0));

    // Small volume: 100 OMNI matched
    const small_vol: u64 = 100_000_000_000;
    const small_reward = PoUWEngine.getMatchingReward(small_vol);
    try std.testing.expectEqual(@as(u64, 50_000_000), small_reward); // 0.05 OMNI
}

test "oracle reward calculation" {
    // 1 update = 1 OMNI
    try std.testing.expectEqual(ORACLE_REWARD_SAT, PoUWEngine.getOracleReward(1));
    // 5 updates = 5 OMNI
    try std.testing.expectEqual(@as(u64, 5_000_000_000), PoUWEngine.getOracleReward(5));
    // 0 updates = 0
    try std.testing.expectEqual(@as(u64, 0), PoUWEngine.getOracleReward(0));
}

test "total supply never exceeds 21M" {
    // At some very large block height, total supply should cap at MAX_SUPPLY
    const supply = PoUWEngine.totalSupplyMined(HALVING_INTERVAL * 40);
    try std.testing.expect(supply <= MAX_SUPPLY_SAT);

    // At a moderate height, supply should be positive and under cap
    const mid_supply = PoUWEngine.totalSupplyMined(HALVING_INTERVAL * 5);
    try std.testing.expect(mid_supply > 0);
    try std.testing.expect(mid_supply <= MAX_SUPPLY_SAT);

    // First era: 210,000 blocks * 50 OMNI = 10,500,000 OMNI
    const first_era = PoUWEngine.totalSupplyMined(HALVING_INTERVAL);
    try std.testing.expectEqual(@as(u64, HALVING_INTERVAL * INITIAL_BLOCK_REWARD_SAT), first_era);
}

test "submit work report" {
    var engine = PoUWEngine.init();

    const report = makeWorkReport("miner_alice", .matching, 100, 1_000_000_000_000, 42, 0, 0);
    try engine.submitWorkReport(report);

    try std.testing.expectEqual(@as(u32, 1), engine.report_count);
    try std.testing.expect(engine.report_valid[0]);
    try std.testing.expectEqual(@as(u32, 1), engine.active_miner_count);

    // Duplicate same work type from same miner should fail
    const dup = makeWorkReport("miner_alice", .matching, 100, 500_000_000_000, 10, 0, 0);
    try std.testing.expectError(PoUWError.DuplicateReport, engine.submitWorkReport(dup));

    // Different work type from same miner should succeed
    const oracle_report = makeWorkReport("miner_alice", .oracle, 100, 0, 0, 3, 0);
    try engine.submitWorkReport(oracle_report);
    try std.testing.expectEqual(@as(u32, 2), engine.report_count);
}

test "calculate rewards for block" {
    var engine = PoUWEngine.init();

    // Single miner doing matching work with 1000 OMNI volume
    const report = makeWorkReport("miner_bob", .matching, 1, 1_000_000_000_000, 50, 0, 0);
    try engine.submitWorkReport(report);
    engine.calculateRewards(1);

    try std.testing.expectEqual(@as(u32, 1), engine.reward_count);

    const reward = &engine.rewards[0];
    // Base reward: 50 OMNI (only miner, gets full base)
    try std.testing.expectEqual(INITIAL_BLOCK_REWARD_SAT, reward.base_reward_sat);
    // Matching reward: 0.05% of 1000 OMNI = 0.5 OMNI
    try std.testing.expectEqual(@as(u64, 500_000_000), reward.matching_reward_sat);
    // Total = 50 + 0.5 = 50.5 OMNI
    try std.testing.expectEqual(INITIAL_BLOCK_REWARD_SAT + 500_000_000, reward.total_reward_sat);
}

test "slash invalid matching — lose all stake" {
    var engine = PoUWEngine.init();

    // Register miner
    const report = makeWorkReport("miner_evil", .matching, 1, 100_000_000_000, 10, 0, 0);
    try engine.submitWorkReport(report);

    // Set a known stake
    const idx = engine.findMinerIndex("miner_evil").?;
    engine.miner_last_active[idx].stake_sat = 5_000_000_000_000; // 5000 OMNI

    // Slash for invalid matching (100% of stake)
    const stake = engine.miner_last_active[idx].stake_sat;
    const slash_amount = PoUWEngine.calculateSlashAmount(stake, .invalid_matching);
    try std.testing.expectEqual(stake, slash_amount); // 100%

    const a = makeTestAddress("miner_evil");
    const slash = SlashEvent{
        .miner_address = a.addr,
        .miner_addr_len = a.len,
        .reason = .invalid_matching,
        .slash_amount_sat = slash_amount,
        .evidence_hash = std.mem.zeroes([32]u8),
        .block_height = 2,
        .timestamp_ms = 200,
    };
    try engine.reportSlash(slash);

    // Miner should have 0 stake and be inactive
    try std.testing.expectEqual(@as(u64, 0), engine.miner_last_active[idx].stake_sat);
    try std.testing.expect(!engine.miner_last_active[idx].is_active);
}

test "slash invalid price — lose 50%" {
    var engine = PoUWEngine.init();

    const report = makeWorkReport("oracle_bad", .oracle, 1, 0, 0, 5, 0);
    try engine.submitWorkReport(report);

    const idx = engine.findMinerIndex("oracle_bad").?;
    engine.miner_last_active[idx].stake_sat = 2_000_000_000_000; // 2000 OMNI

    const slash_amount = PoUWEngine.calculateSlashAmount(2_000_000_000_000, .invalid_price);
    try std.testing.expectEqual(@as(u64, 1_000_000_000_000), slash_amount); // 50%

    const a = makeTestAddress("oracle_bad");
    const slash = SlashEvent{
        .miner_address = a.addr,
        .miner_addr_len = a.len,
        .reason = .invalid_price,
        .slash_amount_sat = slash_amount,
        .evidence_hash = std.mem.zeroes([32]u8),
        .block_height = 2,
        .timestamp_ms = 200,
    };
    try engine.reportSlash(slash);

    try std.testing.expectEqual(@as(u64, 1_000_000_000_000), engine.miner_last_active[idx].stake_sat);
    try std.testing.expect(engine.miner_last_active[idx].is_active);
}

test "miner offline detection" {
    var engine = PoUWEngine.init();

    // Register miner at block 100
    const report = makeWorkReport("miner_lazy", .sync, 100, 0, 0, 0, 0);
    try engine.submitWorkReport(report);

    // Just after: still online
    try std.testing.expect(engine.isOnline("miner_lazy", 100));
    try std.testing.expect(engine.isOnline("miner_lazy", 100 + OFFLINE_THRESHOLD_BLOCKS - 1));

    // Exactly at threshold: still online (< not <=)
    // At threshold + 1: offline
    try std.testing.expect(!engine.isOnline("miner_lazy", 100 + OFFLINE_THRESHOLD_BLOCKS));
    try std.testing.expect(!engine.isOnline("miner_lazy", 100 + OFFLINE_THRESHOLD_BLOCKS + 10_000));
}

test "rewards merkle root deterministic" {
    // Two identical engines with same reports should produce same merkle root
    var engine1 = PoUWEngine.init();
    var engine2 = PoUWEngine.init();

    const r1 = makeWorkReport("miner_x", .matching, 5, 500_000_000_000, 20, 0, 0);
    const r2 = makeWorkReport("miner_y", .oracle, 5, 0, 0, 3, 0);

    try engine1.submitWorkReport(r1);
    try engine1.submitWorkReport(r2);
    engine1.calculateRewards(5);

    try engine2.submitWorkReport(r1);
    try engine2.submitWorkReport(r2);
    engine2.calculateRewards(5);

    const root1 = engine1.rewardsMerkleRoot();
    const root2 = engine2.rewardsMerkleRoot();

    try std.testing.expectEqualSlices(u8, &root1, &root2);
    // Root should not be all zeros (we have rewards)
    try std.testing.expect(!std.mem.eql(u8, &root1, &std.mem.zeroes([32]u8)));
}

test "reset block preserves miner activity" {
    var engine = PoUWEngine.init();

    const report = makeWorkReport("miner_persist", .matching, 10, 100_000_000_000, 5, 0, 0);
    try engine.submitWorkReport(report);
    engine.calculateRewards(10);

    try std.testing.expectEqual(@as(u32, 1), engine.active_miner_count);
    const rewards_before = engine.miner_last_active[0].total_rewards_sat;
    try std.testing.expect(rewards_before > 0);

    // Reset block
    engine.resetBlock();

    // Reports and rewards cleared
    try std.testing.expectEqual(@as(u32, 0), engine.report_count);
    try std.testing.expectEqual(@as(u32, 0), engine.reward_count);
    // But miner activity persists
    try std.testing.expectEqual(@as(u32, 1), engine.active_miner_count);
    try std.testing.expectEqual(rewards_before, engine.miner_last_active[0].total_rewards_sat);
}

test "multiple miners split base reward" {
    var engine = PoUWEngine.init();

    // 3 miners submit work
    try engine.submitWorkReport(makeWorkReport("alice", .matching, 1, 100_000_000_000, 5, 0, 0));
    try engine.submitWorkReport(makeWorkReport("bob", .oracle, 1, 0, 0, 2, 0));
    try engine.submitWorkReport(makeWorkReport("carol", .sync, 1, 0, 0, 0, 0));

    engine.calculateRewards(1);

    try std.testing.expectEqual(@as(u32, 3), engine.reward_count);

    // Each gets 50/3 = 16.666... OMNI base (integer division: 16_666_666_666)
    const expected_base = INITIAL_BLOCK_REWARD_SAT / 3;
    for (0..engine.reward_count) |i| {
        try std.testing.expectEqual(expected_base, engine.rewards[i].base_reward_sat);
    }

    // Alice also gets matching reward
    try std.testing.expect(engine.rewards[0].matching_reward_sat > 0);
    // Bob also gets oracle reward
    try std.testing.expectEqual(@as(u64, 2_000_000_000), engine.rewards[1].oracle_reward_sat);
    // Carol gets only base
    try std.testing.expectEqual(expected_base, engine.rewards[2].total_reward_sat);
}

test "MinerActivity net rewards" {
    var activity = std.mem.zeroes(MinerActivity);
    activity.total_rewards_sat = 10_000_000_000; // 10 OMNI earned
    activity.total_slashed_sat = 3_000_000_000; // 3 OMNI slashed
    try std.testing.expectEqual(@as(u64, 7_000_000_000), activity.netRewardsSat());

    // More slashed than earned: returns 0
    activity.total_slashed_sat = 15_000_000_000;
    try std.testing.expectEqual(@as(u64, 0), activity.netRewardsSat());
}
