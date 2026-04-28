/// agent_tier.zig — Tier-uri de capabilitate pentru AI Agents
///
/// Userul cere faucet (0.1 OMNI), agent-ul incepe la T1 (mining-only).
/// Pe masura ce agentul aduna capital, urca automat in tier-uri si capata
/// noi capabilitati. Userul NU alege manual — tier-ul se decide din capital.
///
/// Self-contained: nu importa staking.zig sau agent_executor.zig pentru
/// a evita dependinte circulare. Constantele MIN_STAKE/MIN_LP/MIN_ARB
/// trebuie sa coincida cu staking.zig::VALIDATOR_MIN_STAKE etc.
const std = @import("std");

/// Constante in SAT (1 OMNI = 1_000_000_000 SAT)
pub const FAUCET_GRANT_SAT: u64 = 100_000_000; // 0.1 OMNI

/// Pragurile de capital pentru fiecare tier (in SAT).
/// Capital = balance + stake + LP-locked.
pub const T2_MIN_SAT: u64 = 100_000_000_000; // 100 OMNI — devine validator
pub const T3_MIN_SAT: u64 = 1_000_000_000_000; // 1_000 OMNI — devine LP
pub const T4_MIN_SAT: u64 = 10_000_000_000_000; // 10_000 OMNI — boti arbitraj

/// Hysteresis: scade un tier doar daca pierde mai mult decat marja, ca sa
/// nu oscileze pe fluctuatii mici. Scapi din T2 doar sub 90% din T2_MIN.
pub const HYSTERESIS_BPS: u64 = 1_000; // 10% = 1000 basis points

/// Tier-ul unui agent — capabilitatile cresc monoton cu tier-ul.
/// Tag-urile incep de la 0 ca std.mem.zeroes sa poata initializa structuri
/// care contin un Tier (slot default = T1).
pub const Tier = enum(u8) {
    /// Doar minat — pana stranje 100 OMNI.
    t1_mining = 0,
    /// Mining + staking ca validator. >= 100 OMNI.
    t2_staking = 1,
    /// + Liquidity provider pe order book. >= 1_000 OMNI.
    t3_liquidity = 2,
    /// + Arbitraj cross-exchange. >= 10_000 OMNI.
    t4_arbitrage = 3,

    pub fn name(self: Tier) []const u8 {
        return switch (self) {
            .t1_mining => "T1-mining",
            .t2_staking => "T2-staking",
            .t3_liquidity => "T3-liquidity",
            .t4_arbitrage => "T4-arbitrage",
        };
    }

    /// Pragul minim pentru a INTRA in tier-ul curent (urcand).
    pub fn minCapitalSat(self: Tier) u64 {
        return switch (self) {
            .t1_mining => 0,
            .t2_staking => T2_MIN_SAT,
            .t3_liquidity => T3_MIN_SAT,
            .t4_arbitrage => T4_MIN_SAT,
        };
    }

    /// Pragul sub care agentul SCADE din tier-ul curent (cu hysteresis).
    /// Returneaza 0 pentru T1 (nu poate scadea sub T1).
    pub fn dropCapitalSat(self: Tier) u64 {
        const min_in = self.minCapitalSat();
        if (min_in == 0) return 0;
        // 90% din pragul de intrare = pragul de iesire
        return min_in - (min_in * HYSTERESIS_BPS) / 10_000;
    }

    /// Capabilitati per tier — folosite de executor sa decida ce poate face.
    pub fn canMine(_: Tier) bool {
        return true; // Toate tier-urile mineaza.
    }
    pub fn canStake(self: Tier) bool {
        return @intFromEnum(self) >= @intFromEnum(Tier.t2_staking);
    }
    pub fn canProvideLiquidity(self: Tier) bool {
        return @intFromEnum(self) >= @intFromEnum(Tier.t3_liquidity);
    }
    pub fn canArbitrage(self: Tier) bool {
        return @intFromEnum(self) >= @intFromEnum(Tier.t4_arbitrage);
    }
};

/// Calculeaza tier-ul corespunzator unui capital, plecand de la tier-ul curent.
/// Hysteresis: pentru a urca, capital >= min_in al tier-ului tinta.
/// Pentru a scadea, capital < drop_out al tier-ului curent.
pub fn computeTier(current: Tier, capital_sat: u64) Tier {
    // Incearca sa urce cat mai sus
    if (capital_sat >= Tier.t4_arbitrage.minCapitalSat()) return .t4_arbitrage;
    if (capital_sat >= Tier.t3_liquidity.minCapitalSat()) {
        // Daca era T4 si a scazut sub drop_out al T4 -> T3, altfel ramane T4
        if (current == .t4_arbitrage and capital_sat >= Tier.t4_arbitrage.dropCapitalSat()) {
            return .t4_arbitrage;
        }
        return .t3_liquidity;
    }
    if (capital_sat >= Tier.t2_staking.minCapitalSat()) {
        if (current == .t3_liquidity and capital_sat >= Tier.t3_liquidity.dropCapitalSat()) {
            return .t3_liquidity;
        }
        return .t2_staking;
    }
    // Mai putin de T2 — tot T1, dar daca era T2 si scade sub drop_out, scade
    if (current == .t2_staking and capital_sat >= Tier.t2_staking.dropCapitalSat()) {
        return .t2_staking;
    }
    return .t1_mining;
}

/// Tranzitie de tier — descrie schimbarea pentru log + RPC events.
pub const TierTransition = struct {
    from: Tier,
    to: Tier,
    capital_sat: u64,
    block_height: u64,

    pub fn isUpgrade(self: TierTransition) bool {
        return @intFromEnum(self.to) > @intFromEnum(self.from);
    }
    pub fn isDowngrade(self: TierTransition) bool {
        return @intFromEnum(self.to) < @intFromEnum(self.from);
    }
};

// ─── Teste ────────────────────────────────────────────────────────────────────
const testing = std.testing;

test "tier thresholds monotone" {
    try testing.expect(Tier.t1_mining.minCapitalSat() < Tier.t2_staking.minCapitalSat());
    try testing.expect(Tier.t2_staking.minCapitalSat() < Tier.t3_liquidity.minCapitalSat());
    try testing.expect(Tier.t3_liquidity.minCapitalSat() < Tier.t4_arbitrage.minCapitalSat());
}

test "capabilities monotone with tier" {
    try testing.expect(!Tier.t1_mining.canStake());
    try testing.expect(Tier.t2_staking.canStake());
    try testing.expect(!Tier.t2_staking.canProvideLiquidity());
    try testing.expect(Tier.t3_liquidity.canProvideLiquidity());
    try testing.expect(!Tier.t3_liquidity.canArbitrage());
    try testing.expect(Tier.t4_arbitrage.canArbitrage());
    try testing.expect(Tier.t1_mining.canMine());
    try testing.expect(Tier.t4_arbitrage.canMine());
}

test "computeTier — fresh agent at faucet grant stays T1" {
    const tier = computeTier(.t1_mining, FAUCET_GRANT_SAT);
    try testing.expectEqual(Tier.t1_mining, tier);
}

test "computeTier — upgrade path" {
    try testing.expectEqual(Tier.t1_mining, computeTier(.t1_mining, 0));
    try testing.expectEqual(Tier.t2_staking, computeTier(.t1_mining, T2_MIN_SAT));
    try testing.expectEqual(Tier.t3_liquidity, computeTier(.t2_staking, T3_MIN_SAT));
    try testing.expectEqual(Tier.t4_arbitrage, computeTier(.t3_liquidity, T4_MIN_SAT));
}

test "computeTier — hysteresis prevents oscillation" {
    // Era T2 (stake-uit), scade la 95 OMNI (sub T2_MIN dar peste 90 OMNI drop)
    const just_below = T2_MIN_SAT - (T2_MIN_SAT / 100); // 99 OMNI
    try testing.expectEqual(Tier.t2_staking, computeTier(.t2_staking, just_below));

    // Scade sub drop_out al T2 (90% din 100 = 90 OMNI) -> T1
    const way_below = (T2_MIN_SAT * 89) / 100; // 89 OMNI
    try testing.expectEqual(Tier.t1_mining, computeTier(.t2_staking, way_below));
}

test "TierTransition upgrade/downgrade" {
    const up = TierTransition{ .from = .t1_mining, .to = .t2_staking, .capital_sat = T2_MIN_SAT, .block_height = 100 };
    try testing.expect(up.isUpgrade());
    try testing.expect(!up.isDowngrade());

    const down = TierTransition{ .from = .t3_liquidity, .to = .t2_staking, .capital_sat = 50_000_000_000, .block_height = 200 };
    try testing.expect(!down.isUpgrade());
    try testing.expect(down.isDowngrade());
}
