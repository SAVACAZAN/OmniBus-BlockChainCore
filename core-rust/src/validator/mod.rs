//! Validator system — staking, validator set, slashing.
//!
//! Rust port of:
//!   * `core/staking.zig`           — stake/unstake + slashing engine
//!   * `core/validator_registry.zig` — slot-leader rotation
//!   * `core/slashing_evidence.zig`  — evidence collector
//!
//! The 5-tier soulbound validator ladder (memory:project_omnibus_validator_vision)
//! is enforced here. Each tier requires the previous tier's PQ soulbound badge
//! (LOVE/FOOD/RENT/VACATION) plus stake denominated in OMNI:
//!
//!   Tier 0 — OMNI         (stake only, no badge)            min   100 OMNI
//!   Tier 1 — LOVE         (requires LOVE badge)             min 1_000 OMNI
//!   Tier 2 — FOOD         (requires LOVE+FOOD)              min 10_000 OMNI
//!   Tier 3 — RENT         (requires LOVE+FOOD+RENT)         min 100_000 OMNI
//!   Tier 4 — VACATION     (requires all 4 soulbound)        min 500_000 OMNI
//!
//! Cap: 1_000_000 OMNI per validator. Uptime tiebreaker.
//! Bootstrap: first 10 nodes get 30 days of grace before tier checks apply.
//!
//! Badge ownership is reported externally (via pq_attest, see
//! `project_omnibus_pq_attest_identity`) — this module just consumes
//! the `TierBadges` snapshot.

pub mod set;
pub mod slashing;
pub mod staking;

pub use set::{ValidatorRecord, ValidatorSet, ValidatorStatus};
pub use slashing::{
    SlashError, SlashEvidence, SlashReason, SlashRecord, SlashResult, SlashingEngine,
};
pub use staking::{StakeError, StakeRegistry, StakeRecord};

use serde::{Deserialize, Serialize};

// ─── Tier ladder constants ────────────────────────────────────────────────

/// Per-validator stake cap (1_000_000 OMNI in SAT).
pub const VALIDATOR_STAKE_CAP_SAT: u64 = 1_000_000 * 1_000_000_000;

/// First N validators get a grace period — they are admitted at Tier::Omni
/// regardless of badges so the chain can bootstrap from a cold start.
pub const BOOTSTRAP_VALIDATOR_COUNT: usize = 10;

/// Grace period length, in blocks (~30 days at 1s blocks).
pub const BOOTSTRAP_GRACE_BLOCKS: u64 = 30 * 24 * 60 * 60;

/// Minimum uptime % over the rolling window to keep validator status.
pub const MIN_UPTIME_PCT: u8 = 95;

/// Unbonding window in blocks (~7 days at 1s blocks).
pub const UNBONDING_PERIOD_BLOCKS: u64 = 7 * 24 * 60 * 60;

/// Five-tier validator ladder. Tier ordering matches the discriminant —
/// higher number = higher tier = needs more badges + more stake.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[repr(u8)]
pub enum Tier {
    Omni = 0,
    Love = 1,
    Food = 2,
    Rent = 3,
    Vacation = 4,
}

impl Tier {
    /// Minimum stake (SAT) required for this tier.
    pub fn min_stake_sat(self) -> u64 {
        match self {
            Tier::Omni => 100 * 1_000_000_000,
            Tier::Love => 1_000 * 1_000_000_000,
            Tier::Food => 10_000 * 1_000_000_000,
            Tier::Rent => 100_000 * 1_000_000_000,
            Tier::Vacation => 500_000 * 1_000_000_000,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Tier::Omni => "omni",
            Tier::Love => "love",
            Tier::Food => "food",
            Tier::Rent => "rent",
            Tier::Vacation => "vacation",
        }
    }
}

/// Snapshot of which soulbound PQ badges a validator currently holds.
/// Produced by the pq_attest subsystem and passed in by the caller —
/// this module never inspects PQ keys directly.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct TierBadges {
    pub love: bool,
    pub food: bool,
    pub rent: bool,
    pub vacation: bool,
}

impl TierBadges {
    /// The highest tier the validator can occupy with the badges they have.
    /// Tiers above OMNI require ALL lower badges (ladder semantics).
    pub fn max_tier(&self) -> Tier {
        if self.vacation && self.rent && self.food && self.love {
            Tier::Vacation
        } else if self.rent && self.food && self.love {
            Tier::Rent
        } else if self.food && self.love {
            Tier::Food
        } else if self.love {
            Tier::Love
        } else {
            Tier::Omni
        }
    }

    /// Whether the given tier is reachable with the current badges.
    pub fn can_reach(&self, tier: Tier) -> bool {
        self.max_tier() >= tier
    }
}
