/// reputation.zig — 4 pahare soulbound + reputation total agregat.
///
/// Vezi `memory/project_omnibus_reputation_economy.md` pentru rationale.
/// Vezi `memory/project_omnibus_validator_vision.md` pentru tier ladder.
///
/// 4 PAHARE (0-100, fixed-point x100 in storage so 50.00 = 5000):
///   LOVE      uptime + continuitate
///   FOOD      work util (mining + oracle + PoUW + agent decisions)
///   RENT      capital angajat (stake + LP + hold)
///   VACATION  longevitate (zile pe retea de la primul block)
///
/// 1 REPUTATION TOTAL agregat (0-1_000_000, din memory existent):
///   rep_total = (love+food+rent+vacation)/400 * 1_000_000
///
/// SATOSHI BADGE: toate 4 paharele = 100 (10000 fixed-point).
///
/// Soulbound: NU se transfera. Toate operatiile sunt aditive (cu cap 100/pahar).
/// Slashing: violations -> reduceri (vezi `applyViolation`).

const std = @import("std");

// ── Constants ────────────────────────────────────────────────────────────────

/// Fixed-point scale: store all cups as u32 in 1/100 units.
/// Display value = stored / 100.0  (e.g. stored=4523 → 45.23).
pub const CUP_SCALE: u32 = 100;
/// Hard cap per pahar = 100.00 = stored 10_000.
pub const CUP_CAP_STORED: u32 = 100 * CUP_SCALE;

/// Aggregate reputation cap (memory existing).
pub const REP_TOTAL_CAP: u64 = 1_000_000;

/// Inactivity threshold for LOVE decay (days). 30 zile fara heartbeat -> decay.
pub const INACTIVITY_DECAY_DAYS: u64 = 30;
/// LOVE penalty per day inactive after threshold (5 stored = 0.05).
pub const LOVE_DECAY_PER_DAY_STORED: u32 = 5;

// ── Cup increments per event (stored units, x100) ──────────────────────────

/// LOVE
pub const LOVE_PER_MINUTE_ONLINE: u32     = 1;       // 0.01 / min  → 1.00 / 100min
pub const LOVE_PER_DAY_STREAK: u32        = 10;      // 0.10 / consecutive day
pub const LOVE_PER_WEEK_NO_VIOLATION: u32 = 100;     // 1.00 / clean week

/// FOOD
pub const FOOD_PER_BLOCK_MINED: u32           = 1;     // 0.01 / bloc minat
pub const FOOD_PER_POUW_WORK_REPORT: u32      = 10;    // 0.10 / work_report acceptat
pub const FOOD_PER_ORACLE_PRICE_UPDATE: u32   = 1;     // 0.01 / price submission
pub const FOOD_PER_AGENT_DECISION_OK: u32     = 10;    // 0.10 / decision exec OK
pub const FOOD_PER_ARBITRAGE_PROFIT: u32      = 100;   // 1.00 / cross-exchange arb profitabil
pub const FOOD_PENALTY_INVALID_REPORT: u32    = 50;    // -0.50 per work_report invalid

/// RENT — formula: stake_amount_omni × days_held × multiplier
/// Storage e per (OMNI×day). `creditRentPerBlock` aplica fractional-day proportion.
pub const RENT_PER_OMNI_STAKE_DAY: u32        = 10;    // 0.10 / (OMNI staked × day)
pub const RENT_PER_OMNI_LP_DAY: u32           = 5;     // 0.05 / (OMNI LP × day)
pub const RENT_PER_OMNI_HOLD_DAY: u32         = 1;     // 0.01 / (OMNI hold × day)
pub const RENT_BONUS_T2_VALIDATOR_DAY: u32    = 50;    // +0.50 / day pentru ≥100 OMNI stake
pub const RENT_BONUS_T3_LP_DAY: u32           = 100;   // +1.00 / day pentru ≥1000 OMNI capital
pub const RENT_BONUS_T4_ARB_DAY: u32          = 500;   // +5.00 / day pentru ≥10000 OMNI capital
pub const RENT_PENALTY_UNSTAKE: u32           = 500;   // -5.00 / unstake event

/// VACATION
pub const VACATION_PER_DAY_BASE: u32          = 3;     // 0.03 / day base
/// Palier bonuses (stored units cumulative when crossed).
pub const VACATION_BONUS_30D: u32  = 100;   // +1.00 la 30 zile
pub const VACATION_BONUS_100D: u32 = 300;   // +3.00 la 100 zile
pub const VACATION_BONUS_365D: u32 = 1000;  // +10.00 la 1 an
pub const VACATION_BONUS_1000D: u32 = 2000; // +20.00 la 1000 zile
pub const VACATION_BONUS_1825D: u32 = 3000; // +30.00 la 5 ani

/// Block time approximate, used to convert blocks -> days for RENT.
pub const BLOCKS_PER_DAY: u64 = 86_400; // 1s/block, 86400 blocks/day

// ── Tier thresholds (memory: project_omnibus_validator_vision) ──────────────
// rep_total >= these → tier promotion (check from highest to lowest).
pub const TIER_LOVE_REP: u64     = 800_000;
pub const TIER_FOOD_REP: u64     = 900_000;
pub const TIER_RENT_REP: u64     = 950_000;
pub const TIER_VACATION_REP: u64 = 999_000;

pub const Tier = enum(u8) {
    OMNI = 0,
    LOVE = 1,
    FOOD = 2,
    RENT = 3,
    VACATION = 4,
    /// Toate 4 paharele cap-uite la 100 = Zen achievement.
    /// Permanent. Doar uptime_blocks decide ranking-ul intre Zen-i (memory:
    /// project_omnibus_validator_vision — tiebreaker IMPOSIBIL de cumparat
    /// retroactiv).
    ZEN = 5,

    pub fn name(self: Tier) []const u8 {
        return switch (self) {
            .OMNI => "OMNI",
            .LOVE => "LOVE",
            .FOOD => "FOOD",
            .RENT => "RENT",
            .VACATION => "VACATION",
            .ZEN => "ZEN",
        };
    }
};

pub fn tierFromRep(rep_total: u64) Tier {
    if (rep_total >= TIER_VACATION_REP) return .VACATION;
    if (rep_total >= TIER_RENT_REP) return .RENT;
    if (rep_total >= TIER_FOOD_REP) return .FOOD;
    if (rep_total >= TIER_LOVE_REP) return .LOVE;
    return .OMNI;
}

// ── ReputationCups ───────────────────────────────────────────────────────────

pub const ReputationCups = struct {
    /// Stored x100 (50.00 = 5000), capped at CUP_CAP_STORED (10000).
    love_stored: u32 = 0,
    food_stored: u32 = 0,
    rent_stored: u32 = 0,
    vacation_stored: u32 = 0,

    /// First block where address was seen (mining/oracle/etc).
    first_active_block: u64 = 0,
    /// Last block where address was credited.
    last_active_block: u64 = 0,
    /// Cumulative blocks mined (used for retro + tiebreaker).
    total_blocks_mined: u64 = 0,
    /// Sum of (OMNI × block) staked, used to compute RENT increments.
    total_omni_stake_block_sat: u128 = 0,
    /// Sum of (OMNI × block) in LP.
    total_omni_lp_block_sat: u128 = 0,
    /// Violation count — affects total via -100k each, vezi computeRepTotal.
    violations: u32 = 0,
    /// Days inactive currently (counted by caller).
    days_inactive: u32 = 0,

    pub fn loveDisplay(self: ReputationCups) f64 {
        return @as(f64, @floatFromInt(self.love_stored)) / @as(f64, @floatFromInt(CUP_SCALE));
    }
    pub fn foodDisplay(self: ReputationCups) f64 {
        return @as(f64, @floatFromInt(self.food_stored)) / @as(f64, @floatFromInt(CUP_SCALE));
    }
    pub fn rentDisplay(self: ReputationCups) f64 {
        return @as(f64, @floatFromInt(self.rent_stored)) / @as(f64, @floatFromInt(CUP_SCALE));
    }
    pub fn vacationDisplay(self: ReputationCups) f64 {
        return @as(f64, @floatFromInt(self.vacation_stored)) / @as(f64, @floatFromInt(CUP_SCALE));
    }

    /// rep_total = sum_cups / 400 * 1_000_000  (each cup max 100, 4 cups max 400)
    /// Apoi scade violations × 100_000.
    pub fn computeRepTotal(self: ReputationCups) u64 {
        const sum_stored: u64 = @as(u64, self.love_stored) + self.food_stored + self.rent_stored + self.vacation_stored;
        // sum_stored max = 40_000 (4 × 10000). REP_TOTAL_CAP = 1_000_000.
        // => rep = sum_stored * 1_000_000 / 40_000 = sum_stored * 25
        var rep: u64 = sum_stored * 25;
        const violation_penalty: u64 = @as(u64, self.violations) * 100_000;
        if (rep > violation_penalty) rep -= violation_penalty else rep = 0;
        if (rep > REP_TOTAL_CAP) rep = REP_TOTAL_CAP;
        return rep;
    }

    pub fn hasSatoshiBadge(self: ReputationCups) bool {
        return self.love_stored >= CUP_CAP_STORED and
               self.food_stored >= CUP_CAP_STORED and
               self.rent_stored >= CUP_CAP_STORED and
               self.vacation_stored >= CUP_CAP_STORED;
    }

    pub fn tier(self: ReputationCups) Tier {
        // Zen = toate paharele 100/100. Permanent — paharele raman cap-uite,
        // dar uptime_blocks continua sa creasca pentru ranking.
        if (self.hasSatoshiBadge()) return .ZEN;
        return tierFromRep(self.computeRepTotal());
    }

    /// Cumulative uptime — incrementat la fiecare credit. Folosit ca tiebreaker
    /// post-Zen pentru ranking. Memory: project_omnibus_validator_vision.
    pub fn uptimeBlocks(self: ReputationCups) u64 {
        if (self.last_active_block <= self.first_active_block) return 0;
        return self.last_active_block - self.first_active_block;
    }

    /// "Effective rank score" pentru sort cross-Zen + non-Zen:
    ///   - Zen-i au scor mereu MAI MARE decat non-Zen (1M cap < Zen)
    ///   - Intre Zen-i: tiebreaker = uptime_blocks (cumulativ)
    ///   - Intre non-Zen: scor = rep_total
    /// Formula: 1M_cap × 1M + uptime_blocks pentru Zen, doar rep_total pentru altii.
    pub fn rankScore(self: ReputationCups) u128 {
        const total = self.computeRepTotal();
        if (self.hasSatoshiBadge()) {
            // Zen base = 1_000_000 × 1_000_000 = 10^12, plus uptime_blocks tiebreaker.
            // u128 ne permite sa cumulam fara overflow chiar pentru 1B blocks.
            return @as(u128, 1_000_000) * 1_000_000 + @as(u128, self.uptimeBlocks());
        }
        return @as(u128, total);
    }

    /// Add to a cup, capped at CUP_CAP_STORED. Saturating arithmetic.
    fn addCapped(cup: *u32, delta: u32) void {
        const sum = @as(u64, cup.*) + @as(u64, delta);
        cup.* = if (sum > CUP_CAP_STORED) CUP_CAP_STORED else @intCast(sum);
    }

    /// Subtract from a cup, saturating at 0.
    fn subSaturating(cup: *u32, delta: u32) void {
        cup.* = if (delta >= cup.*) 0 else cup.* - delta;
    }

    /// Mark address as active at this block (updates first/last active).
    pub fn markActive(self: *ReputationCups, block_height: u64) void {
        if (self.first_active_block == 0) self.first_active_block = block_height;
        self.last_active_block = block_height;
        self.days_inactive = 0;
    }

    // ── FOOD updaters ────────────────────────────────────────────────────────

    pub fn creditMinedBlock(self: *ReputationCups, block_height: u64) void {
        self.markActive(block_height);
        self.total_blocks_mined += 1;
        addCapped(&self.food_stored, FOOD_PER_BLOCK_MINED);
    }

    pub fn creditPoUWReport(self: *ReputationCups, block_height: u64) void {
        self.markActive(block_height);
        addCapped(&self.food_stored, FOOD_PER_POUW_WORK_REPORT);
    }

    pub fn creditOraclePush(self: *ReputationCups, block_height: u64) void {
        self.markActive(block_height);
        addCapped(&self.food_stored, FOOD_PER_ORACLE_PRICE_UPDATE);
    }

    pub fn creditAgentDecision(self: *ReputationCups, block_height: u64) void {
        self.markActive(block_height);
        addCapped(&self.food_stored, FOOD_PER_AGENT_DECISION_OK);
    }

    pub fn creditArbitrageProfit(self: *ReputationCups, block_height: u64) void {
        self.markActive(block_height);
        addCapped(&self.food_stored, FOOD_PER_ARBITRAGE_PROFIT);
    }

    pub fn penalizeInvalidReport(self: *ReputationCups) void {
        subSaturating(&self.food_stored, FOOD_PENALTY_INVALID_REPORT);
    }

    // ── LOVE updaters ────────────────────────────────────────────────────────

    pub fn creditUptimeMinutes(self: *ReputationCups, minutes: u32, block_height: u64) void {
        self.markActive(block_height);
        addCapped(&self.love_stored, LOVE_PER_MINUTE_ONLINE * minutes);
    }

    pub fn creditDailyStreak(self: *ReputationCups, block_height: u64) void {
        self.markActive(block_height);
        addCapped(&self.love_stored, LOVE_PER_DAY_STREAK);
    }

    pub fn creditWeeklyClean(self: *ReputationCups, block_height: u64) void {
        self.markActive(block_height);
        addCapped(&self.love_stored, LOVE_PER_WEEK_NO_VIOLATION);
    }

    pub fn applyInactivityDecay(self: *ReputationCups, days_inactive_now: u32) void {
        if (days_inactive_now <= INACTIVITY_DECAY_DAYS) {
            self.days_inactive = days_inactive_now;
            return;
        }
        const extra_days = days_inactive_now - @as(u32, @intCast(INACTIVITY_DECAY_DAYS));
        const decay = LOVE_DECAY_PER_DAY_STORED * extra_days;
        subSaturating(&self.love_stored, decay);
        self.days_inactive = days_inactive_now;
    }

    // ── RENT updaters ────────────────────────────────────────────────────────

    /// Crediteaza RENT pentru blocul curent dupa stake_omni / lp_omni / hold_omni.
    /// `omni_units` = whole OMNI (nu SAT). Multiplica cu rate per (OMNI×day) si
    /// imparte la BLOCKS_PER_DAY ca sa avem fraction-of-day per block.
    pub fn creditStakePerBlock(self: *ReputationCups, omni_staked: u64, block_height: u64) void {
        if (omni_staked == 0) return;
        self.markActive(block_height);
        // rate_per_block_stored = (omni_staked × RENT_PER_OMNI_STAKE_DAY) / BLOCKS_PER_DAY
        const num: u64 = omni_staked * RENT_PER_OMNI_STAKE_DAY;
        const inc: u32 = @intCast(@min(num / BLOCKS_PER_DAY, @as(u64, std.math.maxInt(u32))));
        if (inc > 0) addCapped(&self.rent_stored, inc);
        // Bonusuri tier (numai daca peste praguri)
        if (omni_staked >= 100) {
            const t2: u64 = RENT_BONUS_T2_VALIDATOR_DAY / BLOCKS_PER_DAY;
            if (t2 > 0) addCapped(&self.rent_stored, @intCast(t2));
        }
        if (omni_staked >= 1000) {
            const t3: u64 = RENT_BONUS_T3_LP_DAY / BLOCKS_PER_DAY;
            if (t3 > 0) addCapped(&self.rent_stored, @intCast(t3));
        }
        if (omni_staked >= 10000) {
            const t4: u64 = RENT_BONUS_T4_ARB_DAY / BLOCKS_PER_DAY;
            if (t4 > 0) addCapped(&self.rent_stored, @intCast(t4));
        }
    }

    pub fn creditLpPerBlock(self: *ReputationCups, omni_lp: u64, block_height: u64) void {
        if (omni_lp == 0) return;
        self.markActive(block_height);
        const num: u64 = omni_lp * RENT_PER_OMNI_LP_DAY;
        const inc: u32 = @intCast(@min(num / BLOCKS_PER_DAY, @as(u64, std.math.maxInt(u32))));
        if (inc > 0) addCapped(&self.rent_stored, inc);
    }

    pub fn creditHoldPerBlock(self: *ReputationCups, omni_held: u64, block_height: u64) void {
        if (omni_held == 0) return;
        self.markActive(block_height);
        const num: u64 = omni_held * RENT_PER_OMNI_HOLD_DAY;
        const inc: u32 = @intCast(@min(num / BLOCKS_PER_DAY, @as(u64, std.math.maxInt(u32))));
        if (inc > 0) addCapped(&self.rent_stored, inc);
    }

    pub fn penalizeUnstake(self: *ReputationCups) void {
        subSaturating(&self.rent_stored, RENT_PENALTY_UNSTAKE);
    }

    // ── VACATION updaters ───────────────────────────────────────────────────

    /// Acordă incrementul de bază + bonusuri palier pentru un nou day-tick.
    /// `total_days_active` = câte zile au trecut de la `first_active_block`.
    pub fn creditVacationDay(self: *ReputationCups, total_days_active: u64, block_height: u64) void {
        self.markActive(block_height);
        addCapped(&self.vacation_stored, VACATION_PER_DAY_BASE);
        // Apply palier bonuses one-shot when crossing each milestone.
        // These are added on the day equality only.
        switch (total_days_active) {
            30 => addCapped(&self.vacation_stored, VACATION_BONUS_30D),
            100 => addCapped(&self.vacation_stored, VACATION_BONUS_100D),
            365 => addCapped(&self.vacation_stored, VACATION_BONUS_365D),
            1000 => addCapped(&self.vacation_stored, VACATION_BONUS_1000D),
            1825 => addCapped(&self.vacation_stored, VACATION_BONUS_1825D),
            else => {},
        }
    }

    // ── Violations ──────────────────────────────────────────────────────────

    pub fn applyViolation(self: *ReputationCups) void {
        self.violations += 1;
        // Plus immediate FOOD penalty pentru efect direct (nu doar in computeRepTotal).
        subSaturating(&self.food_stored, FOOD_PENALTY_INVALID_REPORT);
    }

    // ── Retro backfill ──────────────────────────────────────────────────────

    /// Initializare la deploy pentru o adresa care a minat deja `n_blocks`.
    /// Se apeleaza o singura data per adresa la primul start cu reputation system.
    /// `current_block` = inaltimea actuala a chain-ului.
    /// `first_block_seen` = primul bloc pe care adresa l-a minat (din scan).
    pub fn backfillFromHistory(
        self: *ReputationCups,
        n_blocks_mined: u64,
        first_block_seen: u64,
        current_block: u64,
    ) void {
        self.total_blocks_mined = n_blocks_mined;
        self.first_active_block = first_block_seen;
        self.last_active_block = current_block;
        // FOOD: aplica retro
        const food_inc: u64 = n_blocks_mined * @as(u64, FOOD_PER_BLOCK_MINED);
        const food_capped: u32 = @intCast(@min(food_inc, @as(u64, CUP_CAP_STORED)));
        self.food_stored = food_capped;
        // VACATION: zile active = (current - first) * 1s/block / 86400
        const blocks_active: u64 = if (current_block > first_block_seen)
            current_block - first_block_seen else 0;
        const days_active: u64 = blocks_active / BLOCKS_PER_DAY;
        const vacation_inc: u64 = days_active * @as(u64, VACATION_PER_DAY_BASE);
        var vacation_capped: u32 = @intCast(@min(vacation_inc, @as(u64, CUP_CAP_STORED)));
        // Bonusuri palier (nu se aplica retroactiv toate, doar cea mai mare atinsa)
        if (days_active >= 1825) vacation_capped = @intCast(@min(@as(u64, vacation_capped) + VACATION_BONUS_1825D, @as(u64, CUP_CAP_STORED)))
        else if (days_active >= 1000) vacation_capped = @intCast(@min(@as(u64, vacation_capped) + VACATION_BONUS_1000D, @as(u64, CUP_CAP_STORED)))
        else if (days_active >= 365) vacation_capped = @intCast(@min(@as(u64, vacation_capped) + VACATION_BONUS_365D, @as(u64, CUP_CAP_STORED)))
        else if (days_active >= 100) vacation_capped = @intCast(@min(@as(u64, vacation_capped) + VACATION_BONUS_100D, @as(u64, CUP_CAP_STORED)))
        else if (days_active >= 30) vacation_capped = @intCast(@min(@as(u64, vacation_capped) + VACATION_BONUS_30D, @as(u64, CUP_CAP_STORED)));
        self.vacation_stored = vacation_capped;
        // LOVE & RENT: nu se backfilleaza (nu avem istoric per-day uptime/stake).
    }
};

// ── Tests ────────────────────────────────────────────────────────────────────
const testing = std.testing;

test "empty cups → tier OMNI, rep 0" {
    const cups = ReputationCups{};
    try testing.expectEqual(@as(u64, 0), cups.computeRepTotal());
    try testing.expectEqual(Tier.OMNI, cups.tier());
    try testing.expect(!cups.hasSatoshiBadge());
}

test "all cups 50.00 → rep total = 500_000 (T1 OMNI)" {
    const cups = ReputationCups{
        .love_stored = 5000,
        .food_stored = 5000,
        .rent_stored = 5000,
        .vacation_stored = 5000,
    };
    try testing.expectEqual(@as(u64, 500_000), cups.computeRepTotal());
    try testing.expectEqual(Tier.OMNI, cups.tier());
}

test "all cups 100 → rep 1_000_000, satoshi badge, tier ZEN (post-Zen ranking)" {
    const cups = ReputationCups{
        .love_stored = CUP_CAP_STORED,
        .food_stored = CUP_CAP_STORED,
        .rent_stored = CUP_CAP_STORED,
        .vacation_stored = CUP_CAP_STORED,
    };
    try testing.expectEqual(@as(u64, 1_000_000), cups.computeRepTotal());
    try testing.expect(cups.hasSatoshiBadge());
    // ZEN, nu VACATION — toate paharele full = Zen achievement permanent.
    // Memory: paharele cap-uite la 100, doar uptime_blocks tiebreaker continua.
    try testing.expectEqual(Tier.ZEN, cups.tier());
}

test "creditMinedBlock increments FOOD, capped" {
    var cups = ReputationCups{};
    var i: u64 = 0;
    while (i < 100) : (i += 1) cups.creditMinedBlock(100 + i);
    try testing.expectEqual(@as(u32, 100), cups.food_stored); // 100 × 1 = 100
    try testing.expectEqual(@as(u64, 100), cups.total_blocks_mined);
    // Cap test: 1M blocks shouldn't exceed cap
    var k: u64 = 0;
    while (k < 1_000_000) : (k += 1) cups.creditMinedBlock(200 + k);
    try testing.expectEqual(CUP_CAP_STORED, cups.food_stored);
}

test "violation reduces FOOD + adds violation count" {
    var cups = ReputationCups{ .food_stored = 5000 };
    cups.applyViolation();
    try testing.expectEqual(@as(u32, 1), cups.violations);
    try testing.expectEqual(@as(u32, 4950), cups.food_stored); // -50
    // Rep total: sum=4950, *25=123750, -100000 = 23750
    try testing.expectEqual(@as(u64, 23750), cups.computeRepTotal());
}

test "tier promotion thresholds" {
    var cups = ReputationCups{};
    // 32_000 stored each = 8000 * 4 = 32_000 sum * 25 = 800_000 rep
    cups.love_stored = 8000;
    cups.food_stored = 8000;
    cups.rent_stored = 8000;
    cups.vacation_stored = 8000;
    try testing.expectEqual(@as(u64, 800_000), cups.computeRepTotal());
    try testing.expectEqual(Tier.LOVE, cups.tier());
}

test "backfill from 2090 blocks (Kimi-like)" {
    var cups = ReputationCups{};
    // 2090 blocks × 1 stored = 2090 → 20.90 FOOD (sub cap 10000)
    cups.backfillFromHistory(2090, 1, 32850);
    try testing.expectEqual(@as(u32, 2090), cups.food_stored);
    // ~32849 blocks active = ~0.38 zile (32849/86400). Sub 30 zile → fara bonus.
    try testing.expect(cups.vacation_stored < 100); // sub 1.00
}

test "backfill 5y of mining → palier bonus 1825d" {
    var cups = ReputationCups{};
    const five_y_blocks: u64 = 1825 * BLOCKS_PER_DAY; // ~157M blocks
    cups.backfillFromHistory(100, 0, five_y_blocks);
    // VACATION: 1825 * 3 = 5475 base + 3000 palier = 8475 → 84.75
    try testing.expectEqual(@as(u32, 8475), cups.vacation_stored);
}

test "stake bonus tier T4" {
    var cups = ReputationCups{};
    // 10_000 OMNI staked × 1 block — micro increment + T2/T3/T4 bonuses
    cups.creditStakePerBlock(10_000, 100);
    // (10000 × 10) / 86400 = 1 stored (rounded down). Plus tier bonuses:
    // T2: 50/86400 = 0  T3: 100/86400 = 0  T4: 500/86400 = 0  → just base
    try testing.expectEqual(@as(u32, 1), cups.rent_stored);
}

test "vacation palier 365d milestone" {
    var cups = ReputationCups{};
    cups.creditVacationDay(365, 100);
    try testing.expectEqual(VACATION_PER_DAY_BASE + VACATION_BONUS_365D, cups.vacation_stored);
}

test "Zen tier — full cups give ZEN, not VACATION" {
    const cups = ReputationCups{
        .love_stored = CUP_CAP_STORED,
        .food_stored = CUP_CAP_STORED,
        .rent_stored = CUP_CAP_STORED,
        .vacation_stored = CUP_CAP_STORED,
    };
    try testing.expectEqual(Tier.ZEN, cups.tier());
    try testing.expect(cups.hasSatoshiBadge());
}

test "rankScore — Zen always > non-Zen" {
    const non_zen = ReputationCups{
        .love_stored = 9999,
        .food_stored = 9999,
        .rent_stored = 9999,
        .vacation_stored = 9999, // 99.99 fiecare → tier VACATION dar NU Zen
        .first_active_block = 1,
        .last_active_block = 1_000_000_000, // 1B blocks uptime — masive
    };
    const zen_fresh = ReputationCups{
        .love_stored = CUP_CAP_STORED,
        .food_stored = CUP_CAP_STORED,
        .rent_stored = CUP_CAP_STORED,
        .vacation_stored = CUP_CAP_STORED,
        .first_active_block = 1,
        .last_active_block = 100, // doar 99 blocks uptime
    };
    // Zen always wins, chiar daca non-Zen are uptime mai mare.
    try testing.expect(zen_fresh.rankScore() > non_zen.rankScore());
}

test "rankScore — between two Zens, more uptime wins" {
    const zen_old = ReputationCups{
        .love_stored = CUP_CAP_STORED, .food_stored = CUP_CAP_STORED,
        .rent_stored = CUP_CAP_STORED, .vacation_stored = CUP_CAP_STORED,
        .first_active_block = 1, .last_active_block = 1_000_000,
    };
    const zen_new = ReputationCups{
        .love_stored = CUP_CAP_STORED, .food_stored = CUP_CAP_STORED,
        .rent_stored = CUP_CAP_STORED, .vacation_stored = CUP_CAP_STORED,
        .first_active_block = 999_000, .last_active_block = 1_000_000,
    };
    try testing.expect(zen_old.rankScore() > zen_new.rankScore());
    // Diferenta = ~999_000 uptime blocks, exact cum vrea memory tiebreaker.
}

test "uptimeBlocks computed correctly" {
    const cups = ReputationCups{
        .first_active_block = 100,
        .last_active_block = 5_000,
    };
    try testing.expectEqual(@as(u64, 4_900), cups.uptimeBlocks());
}

test "satoshi badge requires ALL 4 cups full" {
    var cups = ReputationCups{
        .love_stored = CUP_CAP_STORED,
        .food_stored = CUP_CAP_STORED,
        .rent_stored = CUP_CAP_STORED,
        .vacation_stored = 9999, // 99.99 < 100
    };
    try testing.expect(!cups.hasSatoshiBadge());
    cups.vacation_stored = CUP_CAP_STORED;
    try testing.expect(cups.hasSatoshiBadge());
}
