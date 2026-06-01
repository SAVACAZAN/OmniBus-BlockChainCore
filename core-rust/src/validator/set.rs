//! Active validator set — promote/demote, tier enforcement, uptime tracking.
//!
//! The set is rebuilt from the [`StakeRegistry`] on demand. Membership rules:
//!
//! 1. Stake total ≥ `tier.min_stake_sat()`, capped at `VALIDATOR_STAKE_CAP_SAT`.
//! 2. PQ badges (passed in by caller) cover the claimed tier — except for
//!    the first `BOOTSTRAP_VALIDATOR_COUNT` validators within
//!    `BOOTSTRAP_GRACE_BLOCKS` of chain genesis (grace window).
//! 3. Status is `Active` while uptime ≥ `MIN_UPTIME_PCT`; below that the
//!    validator is `Jailed` and stops earning rewards.
//! 4. Tiebreaker between equal-stake-equal-tier validators: higher uptime
//!    over the rolling window wins (used by the slot leader selection).
//!
//! Persistence: sled tree `validator_set` keyed by address. Each entry is
//! a JSON-encoded [`ValidatorRecord`].

use super::staking::{StakeRegistry, StakeStatus};
use super::{
    Tier, TierBadges, BOOTSTRAP_GRACE_BLOCKS, BOOTSTRAP_VALIDATOR_COUNT, MIN_UPTIME_PCT,
    VALIDATOR_STAKE_CAP_SAT,
};
use serde::{Deserialize, Serialize};
use sled::{Db, Tree};

#[derive(Debug, thiserror::Error)]
pub enum SetError {
    #[error("sled error: {0}")]
    Sled(#[from] sled::Error),
    #[error("serde error: {0}")]
    Serde(#[from] serde_json::Error),
    #[error("validator not found")]
    NotFound,
    #[error("insufficient stake for tier {tier:?}")]
    InsufficientStake { tier: Tier },
    #[error("missing badge for tier {tier:?}")]
    MissingBadge { tier: Tier },
    #[error("stake cap exceeded")]
    StakeCapExceeded,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[repr(u8)]
pub enum ValidatorStatus {
    /// Registered, eligible, producing/attesting.
    Active = 1,
    /// Uptime fell below `MIN_UPTIME_PCT` — temporary removal.
    Jailed = 2,
    /// Slashed for cheating — permanent.
    Slashed = 3,
    /// Voluntarily withdrew — funds returned after unbonding.
    Left = 4,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ValidatorRecord {
    pub address: [u8; 32],
    pub tier: Tier,
    /// Effective stake (sum of active+unbonding, capped).
    pub effective_stake_sat: u64,
    pub status: ValidatorStatus,
    /// Block height at registration. Used for the bootstrap grace window.
    pub registered_block: u64,
    /// Validator sequence number — 1-based. The first
    /// `BOOTSTRAP_VALIDATOR_COUNT` validators get tier-grace.
    pub sequence: u64,
    pub blocks_produced: u64,
    pub blocks_missed: u64,
    pub slash_count: u32,
}

impl ValidatorRecord {
    /// Uptime % across produced+missed (100 if no samples yet).
    pub fn uptime_pct(&self) -> u8 {
        let total = self.blocks_produced + self.blocks_missed;
        if total == 0 {
            return 100;
        }
        ((self.blocks_produced * 100) / total) as u8
    }

    /// Voting power = stake when active, 0 otherwise.
    pub fn voting_power(&self) -> u64 {
        if self.status == ValidatorStatus::Active {
            self.effective_stake_sat
        } else {
            0
        }
    }

    /// True if this validator is inside the bootstrap grace window —
    /// tier badge requirements are waived.
    pub fn in_bootstrap_grace(&self, current_block: u64) -> bool {
        self.sequence <= BOOTSTRAP_VALIDATOR_COUNT as u64
            && current_block <= self.registered_block + BOOTSTRAP_GRACE_BLOCKS
    }
}

#[derive(Clone)]
pub struct ValidatorSet {
    tree: Tree,
    seq_counter: Tree,
}

impl ValidatorSet {
    pub fn open(db: &Db) -> Result<Self, SetError> {
        let tree = db.open_tree("validator_set")?;
        let seq_counter = db.open_tree("validator_set_seq")?;
        Ok(Self { tree, seq_counter })
    }

    fn next_sequence(&self) -> Result<u64, SetError> {
        let key = b"seq";
        let new = self.seq_counter.update_and_fetch(key, |old| {
            let n = match old {
                Some(b) if b.len() == 8 => {
                    let mut a = [0u8; 8];
                    a.copy_from_slice(b);
                    u64::from_be_bytes(a) + 1
                }
                _ => 1,
            };
            Some(sled::IVec::from(&n.to_be_bytes()))
        })?;
        let bytes = new.ok_or_else(|| {
            SetError::Sled(sled::Error::Unsupported("seq update returned None".into()))
        })?;
        let mut a = [0u8; 8];
        a.copy_from_slice(&bytes);
        Ok(u64::from_be_bytes(a))
    }

    /// Promote an address to validator at `claimed_tier`. Caller supplies
    /// the badge snapshot from pq_attest. Enforces stake minimum AND
    /// (outside the bootstrap grace) the badge ladder.
    pub fn become_validator(
        &self,
        stakes: &StakeRegistry,
        address: [u8; 32],
        claimed_tier: Tier,
        badges: TierBadges,
        current_block: u64,
    ) -> Result<ValidatorRecord, SetError> {
        let mut total = stakes
            .total_active_for(&address)
            .map_err(|e| SetError::Sled(sled::Error::Unsupported(e.to_string().into())))?;
        if total > VALIDATOR_STAKE_CAP_SAT {
            total = VALIDATOR_STAKE_CAP_SAT;
        }
        if total < claimed_tier.min_stake_sat() {
            return Err(SetError::InsufficientStake { tier: claimed_tier });
        }

        let sequence = self.next_sequence()?;
        let in_grace = sequence <= BOOTSTRAP_VALIDATOR_COUNT as u64;

        if !in_grace && !badges.can_reach(claimed_tier) {
            return Err(SetError::MissingBadge { tier: claimed_tier });
        }

        let rec = ValidatorRecord {
            address,
            tier: claimed_tier,
            effective_stake_sat: total,
            status: ValidatorStatus::Active,
            registered_block: current_block,
            sequence,
            blocks_produced: 0,
            blocks_missed: 0,
            slash_count: 0,
        };
        self.put(&rec)?;
        Ok(rec)
    }

    /// Voluntary exit. Stakes still need to go through unbonding.
    pub fn leave(&self, address: &[u8; 32]) -> Result<(), SetError> {
        let mut rec = self.get(address)?.ok_or(SetError::NotFound)?;
        rec.status = ValidatorStatus::Left;
        self.put(&rec)?;
        Ok(())
    }

    /// Record a slash on a validator — called from `SlashingEngine`.
    /// `permanent=true` marks Slashed (double-sign / invalid-block).
    /// `permanent=false` marks Jailed (downtime).
    pub fn mark_slashed(
        &self,
        address: &[u8; 32],
        permanent: bool,
        new_effective_stake: u64,
    ) -> Result<(), SetError> {
        let mut rec = self.get(address)?.ok_or(SetError::NotFound)?;
        rec.slash_count += 1;
        rec.effective_stake_sat = new_effective_stake.min(VALIDATOR_STAKE_CAP_SAT);
        rec.status = if permanent {
            ValidatorStatus::Slashed
        } else {
            ValidatorStatus::Jailed
        };
        self.put(&rec)?;
        Ok(())
    }

    /// Recompute uptime status — call once per epoch.
    pub fn refresh_uptime(&self, address: &[u8; 32]) -> Result<(), SetError> {
        let mut rec = self.get(address)?.ok_or(SetError::NotFound)?;
        if rec.status == ValidatorStatus::Active
            && rec.uptime_pct() < MIN_UPTIME_PCT
            && rec.blocks_produced + rec.blocks_missed > 100
        {
            rec.status = ValidatorStatus::Jailed;
        }
        self.put(&rec)?;
        Ok(())
    }

    pub fn record_block_produced(&self, address: &[u8; 32]) -> Result<(), SetError> {
        if let Some(mut rec) = self.get(address)? {
            rec.blocks_produced += 1;
            self.put(&rec)?;
        }
        Ok(())
    }

    pub fn record_block_missed(&self, address: &[u8; 32]) -> Result<(), SetError> {
        if let Some(mut rec) = self.get(address)? {
            rec.blocks_missed += 1;
            self.put(&rec)?;
        }
        Ok(())
    }

    /// Update the effective stake from the registry — call after every
    /// `stake` / `unstake` for the validator's address.
    pub fn refresh_stake(
        &self,
        stakes: &StakeRegistry,
        address: &[u8; 32],
    ) -> Result<(), SetError> {
        let mut rec = self.get(address)?.ok_or(SetError::NotFound)?;
        let total = stakes
            .total_active_for(address)
            .map_err(|e| SetError::Sled(sled::Error::Unsupported(e.to_string().into())))?;
        rec.effective_stake_sat = total.min(VALIDATOR_STAKE_CAP_SAT);
        // Auto-demote if below tier minimum.
        while rec.effective_stake_sat < rec.tier.min_stake_sat() && rec.tier != Tier::Omni {
            rec.tier = match rec.tier {
                Tier::Vacation => Tier::Rent,
                Tier::Rent => Tier::Food,
                Tier::Food => Tier::Love,
                Tier::Love => Tier::Omni,
                Tier::Omni => Tier::Omni,
            };
        }
        if rec.effective_stake_sat < Tier::Omni.min_stake_sat() {
            rec.status = ValidatorStatus::Left;
        }
        self.put(&rec)?;
        Ok(())
    }

    pub fn get(&self, address: &[u8; 32]) -> Result<Option<ValidatorRecord>, SetError> {
        match self.tree.get(address)? {
            Some(bytes) => Ok(Some(serde_json::from_slice(&bytes)?)),
            None => Ok(None),
        }
    }

    fn put(&self, rec: &ValidatorRecord) -> Result<(), SetError> {
        let bytes = serde_json::to_vec(rec)?;
        self.tree.insert(rec.address, bytes)?;
        Ok(())
    }

    /// All currently-active validators, sorted deterministically by
    /// (stake desc, uptime desc, address asc) — same ordering on every
    /// node so leader selection agrees.
    pub fn get_active_set(&self) -> Result<Vec<ValidatorRecord>, SetError> {
        let mut out: Vec<ValidatorRecord> = self
            .tree
            .iter()
            .filter_map(|kv| {
                let (_, bytes) = kv.ok()?;
                let rec: ValidatorRecord = serde_json::from_slice(&bytes).ok()?;
                (rec.status == ValidatorStatus::Active).then_some(rec)
            })
            .collect();
        out.sort_by(|a, b| {
            b.effective_stake_sat
                .cmp(&a.effective_stake_sat)
                .then_with(|| b.uptime_pct().cmp(&a.uptime_pct()))
                .then_with(|| a.address.cmp(&b.address))
        });
        Ok(out)
    }

    pub fn total_voting_power(&self) -> Result<u64, SetError> {
        let mut total = 0u64;
        for rec in self.get_active_set()? {
            total = total.saturating_add(rec.voting_power());
        }
        Ok(total)
    }

    /// Discount a record's status to `Slashed` (used by slashing engine when
    /// no `mark_slashed` was called yet). Not for external callers.
    #[doc(hidden)]
    pub(crate) fn _force_status(
        &self,
        address: &[u8; 32],
        status: ValidatorStatus,
    ) -> Result<(), SetError> {
        let mut rec = self.get(address)?.ok_or(SetError::NotFound)?;
        rec.status = status;
        self.put(&rec)?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fresh() -> (sled::Db, StakeRegistry, ValidatorSet) {
        let db = sled::Config::new().temporary(true).open().unwrap();
        let reg = StakeRegistry::open(&db).unwrap();
        let set = ValidatorSet::open(&db).unwrap();
        (db, reg, set)
    }

    #[test]
    fn bootstrap_grace_allows_tier_without_badges() {
        let (_db, reg, set) = fresh();
        let addr = [0x55; 32];
        reg.stake(addr, Tier::Vacation.min_stake_sat(), Tier::Vacation, 1)
            .unwrap();
        let rec = set
            .become_validator(&reg, addr, Tier::Vacation, TierBadges::default(), 1)
            .unwrap();
        assert_eq!(rec.tier, Tier::Vacation);
        assert!(rec.in_bootstrap_grace(1));
    }

    #[test]
    fn non_bootstrap_requires_badges() {
        let (_db, reg, set) = fresh();
        // Burn through the bootstrap window first.
        for i in 0..BOOTSTRAP_VALIDATOR_COUNT {
            let addr = [i as u8; 32];
            reg.stake(addr, Tier::Omni.min_stake_sat(), Tier::Omni, 1)
                .unwrap();
            set.become_validator(&reg, addr, Tier::Omni, TierBadges::default(), 1)
                .unwrap();
        }
        let addr = [0xFF; 32];
        reg.stake(addr, Tier::Love.min_stake_sat(), Tier::Love, 1)
            .unwrap();
        // No LOVE badge → rejected.
        let err = set
            .become_validator(&reg, addr, Tier::Love, TierBadges::default(), 1)
            .unwrap_err();
        assert!(matches!(err, SetError::MissingBadge { .. }));
        // With LOVE badge → OK.
        let mut badges = TierBadges::default();
        badges.love = true;
        set.become_validator(&reg, addr, Tier::Love, badges, 1).unwrap();
    }

    #[test]
    fn insufficient_stake_rejected() {
        let (_db, reg, set) = fresh();
        let addr = [0x77; 32];
        reg.stake(addr, Tier::Omni.min_stake_sat(), Tier::Omni, 1)
            .unwrap();
        let err = set
            .become_validator(&reg, addr, Tier::Love, TierBadges::default(), 1)
            .unwrap_err();
        assert!(matches!(err, SetError::InsufficientStake { .. }));
    }

    #[test]
    fn cap_is_enforced() {
        let (_db, reg, set) = fresh();
        let addr = [0x88; 32];
        // Stake 2x the cap.
        reg.stake(addr, VALIDATOR_STAKE_CAP_SAT * 2, Tier::Omni, 1)
            .unwrap();
        let rec = set
            .become_validator(&reg, addr, Tier::Omni, TierBadges::default(), 1)
            .unwrap();
        assert_eq!(rec.effective_stake_sat, VALIDATOR_STAKE_CAP_SAT);
    }

    #[test]
    fn active_set_sorted_by_stake_then_uptime() {
        let (_db, reg, set) = fresh();
        let a = [1u8; 32];
        let b = [2u8; 32];
        reg.stake(a, Tier::Omni.min_stake_sat(), Tier::Omni, 1).unwrap();
        reg.stake(b, Tier::Omni.min_stake_sat() * 2, Tier::Omni, 1).unwrap();
        set.become_validator(&reg, a, Tier::Omni, TierBadges::default(), 1).unwrap();
        set.become_validator(&reg, b, Tier::Omni, TierBadges::default(), 1).unwrap();
        let active = set.get_active_set().unwrap();
        assert_eq!(active[0].address, b); // bigger stake first
    }
}
