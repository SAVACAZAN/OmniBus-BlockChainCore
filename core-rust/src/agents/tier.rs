//! tier.rs — Capability tiers for AI Agents.
//!
//! Port of `core/agent_tier.zig`. Constants are byte-identical so a Rust
//! agent and a Zig agent draw the same tier from the same capital.
//!
//! Tier = function of capital (balance + stake + LP-locked). Hysteresis
//! prevents flapping at threshold boundaries.

/// 1 OMNI = 1_000_000_000 SAT.
#[allow(dead_code)]
pub const SAT_PER_OMNI: u64 = 1_000_000_000;

/// Faucet drop for a fresh agent — 0.1 OMNI.
pub const FAUCET_GRANT_SAT: u64 = 100_000_000;

/// Capital thresholds (SAT) for each tier.
pub const T2_MIN_SAT: u64 = 100_000_000_000; //    100 OMNI — validator
pub const T3_MIN_SAT: u64 = 1_000_000_000_000; //  1_000 OMNI — LP
pub const T4_MIN_SAT: u64 = 10_000_000_000_000; // 10_000 OMNI — arbitrage

/// Hysteresis margin in basis points (1000 bps = 10%). Drop a tier only
/// when capital falls below 90% of the entry threshold.
pub const HYSTERESIS_BPS: u64 = 1_000;

/// Agent capability tier. Capabilities grow monotonically with the tier.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, serde::Serialize, serde::Deserialize)]
#[repr(u8)]
pub enum Tier {
    /// Mining only — until 100 OMNI accumulated.
    T1Mining = 0,
    /// Mining + staking as validator. >= 100 OMNI.
    T2Staking = 1,
    /// + Liquidity provider on the order book. >= 1_000 OMNI.
    T3Liquidity = 2,
    /// + Cross-exchange arbitrage. >= 10_000 OMNI.
    T4Arbitrage = 3,
}

impl Default for Tier {
    fn default() -> Self {
        Tier::T1Mining
    }
}

impl Tier {
    pub fn name(self) -> &'static str {
        match self {
            Tier::T1Mining => "T1-mining",
            Tier::T2Staking => "T2-staking",
            Tier::T3Liquidity => "T3-liquidity",
            Tier::T4Arbitrage => "T4-arbitrage",
        }
    }

    /// Minimum capital required to enter (going up into) this tier.
    pub fn min_capital_sat(self) -> u64 {
        match self {
            Tier::T1Mining => 0,
            Tier::T2Staking => T2_MIN_SAT,
            Tier::T3Liquidity => T3_MIN_SAT,
            Tier::T4Arbitrage => T4_MIN_SAT,
        }
    }

    /// Threshold below which the agent drops out of this tier (hysteresis).
    pub fn drop_capital_sat(self) -> u64 {
        let min_in = self.min_capital_sat();
        if min_in == 0 {
            return 0;
        }
        min_in - (min_in * HYSTERESIS_BPS) / 10_000
    }

    pub fn can_mine(self) -> bool {
        true
    }
    pub fn can_stake(self) -> bool {
        self >= Tier::T2Staking
    }
    pub fn can_provide_liquidity(self) -> bool {
        self >= Tier::T3Liquidity
    }
    pub fn can_arbitrage(self) -> bool {
        self >= Tier::T4Arbitrage
    }
}

/// Compute the tier corresponding to a given capital, starting from the
/// current tier. Applies hysteresis on the way down.
pub fn compute_tier(current: Tier, capital_sat: u64) -> Tier {
    if capital_sat >= Tier::T4Arbitrage.min_capital_sat() {
        return Tier::T4Arbitrage;
    }
    if capital_sat >= Tier::T3Liquidity.min_capital_sat() {
        if current == Tier::T4Arbitrage && capital_sat >= Tier::T4Arbitrage.drop_capital_sat() {
            return Tier::T4Arbitrage;
        }
        return Tier::T3Liquidity;
    }
    if capital_sat >= Tier::T2Staking.min_capital_sat() {
        if current == Tier::T3Liquidity && capital_sat >= Tier::T3Liquidity.drop_capital_sat() {
            return Tier::T3Liquidity;
        }
        return Tier::T2Staking;
    }
    if current == Tier::T2Staking && capital_sat >= Tier::T2Staking.drop_capital_sat() {
        return Tier::T2Staking;
    }
    Tier::T1Mining
}

/// Tier transition record for logs / RPC events.
#[derive(Debug, Clone, Copy)]
pub struct TierTransition {
    pub from: Tier,
    pub to: Tier,
    pub capital_sat: u64,
    pub block_height: u64,
}

impl TierTransition {
    pub fn is_upgrade(&self) -> bool {
        self.to > self.from
    }
    pub fn is_downgrade(&self) -> bool {
        self.to < self.from
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn thresholds_monotone() {
        assert!(Tier::T1Mining.min_capital_sat() < Tier::T2Staking.min_capital_sat());
        assert!(Tier::T2Staking.min_capital_sat() < Tier::T3Liquidity.min_capital_sat());
        assert!(Tier::T3Liquidity.min_capital_sat() < Tier::T4Arbitrage.min_capital_sat());
    }

    #[test]
    fn capabilities_monotone() {
        assert!(!Tier::T1Mining.can_stake());
        assert!(Tier::T2Staking.can_stake());
        assert!(!Tier::T2Staking.can_provide_liquidity());
        assert!(Tier::T3Liquidity.can_provide_liquidity());
        assert!(!Tier::T3Liquidity.can_arbitrage());
        assert!(Tier::T4Arbitrage.can_arbitrage());
    }

    #[test]
    fn upgrade_path() {
        assert_eq!(compute_tier(Tier::T1Mining, 0), Tier::T1Mining);
        assert_eq!(compute_tier(Tier::T1Mining, T2_MIN_SAT), Tier::T2Staking);
        assert_eq!(compute_tier(Tier::T2Staking, T3_MIN_SAT), Tier::T3Liquidity);
        assert_eq!(
            compute_tier(Tier::T3Liquidity, T4_MIN_SAT),
            Tier::T4Arbitrage
        );
    }

    #[test]
    fn hysteresis_prevents_oscillation() {
        // 99 OMNI — was T2, stays T2 (drop_out = 90 OMNI).
        let just_below = T2_MIN_SAT - (T2_MIN_SAT / 100);
        assert_eq!(compute_tier(Tier::T2Staking, just_below), Tier::T2Staking);
        // 89 OMNI — falls below drop_out -> T1.
        let way_below = (T2_MIN_SAT * 89) / 100;
        assert_eq!(compute_tier(Tier::T2Staking, way_below), Tier::T1Mining);
    }
}
