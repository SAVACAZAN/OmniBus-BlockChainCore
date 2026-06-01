//! Stake registry — sled-persisted stake records.
//!
//! Each record is a single contiguous deposit by one staker. The same
//! address can stake multiple times; per-address total is the sum of all
//! non-unbonded records for that address. Records persist their lockup
//! and tier so the validator set can rebuild deterministically on restart.
//!
//! Storage:
//!   tree `stakes`           — key = stake_id (BE u64) → bincode-ish JSON
//!   tree `stake_by_addr`    — key = address || stake_id → empty (index)

use super::{Tier, UNBONDING_PERIOD_BLOCKS};
use serde::{Deserialize, Serialize};
use sled::{Db, Tree};

#[derive(Debug, thiserror::Error)]
pub enum StakeError {
    #[error("sled error: {0}")]
    Sled(#[from] sled::Error),
    #[error("serde error: {0}")]
    Serde(#[from] serde_json::Error),
    #[error("stake not found")]
    NotFound,
    #[error("already unbonding")]
    AlreadyUnbonding,
    #[error("unbonding not complete")]
    UnbondingNotComplete,
    #[error("below tier minimum stake")]
    BelowTierMinimum,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[repr(u8)]
pub enum StakeStatus {
    Active = 0,
    Unbonding = 1,
    Unbonded = 2,
    Slashed = 3,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StakeRecord {
    pub id: u64,
    /// 32-byte canonical address (BIP-44 derived OMNI address).
    pub address: [u8; 32],
    pub amount_sat: u64,
    /// Tier this stake unlocks for the staker — chosen at deposit time
    /// based on badges available; downgraded if a badge is revoked.
    pub tier: Tier,
    pub created_block: u64,
    pub status: StakeStatus,
    /// Block at which `start_unbonding` was called (0 if active).
    pub unbonding_block: u64,
}

impl StakeRecord {
    pub fn is_unbonding_complete(&self, current_block: u64) -> bool {
        self.status == StakeStatus::Unbonding
            && current_block >= self.unbonding_block + UNBONDING_PERIOD_BLOCKS
    }
}

/// Sled-backed stake registry. Cheap to clone (`Db` is internally `Arc`).
#[derive(Clone)]
pub struct StakeRegistry {
    stakes: Tree,
    by_addr: Tree,
    counter: Tree,
}

impl StakeRegistry {
    pub fn open(db: &Db) -> Result<Self, StakeError> {
        let stakes = db.open_tree("validator_stakes")?;
        let by_addr = db.open_tree("validator_stake_by_addr")?;
        let counter = db.open_tree("validator_stake_counter")?;
        Ok(Self { stakes, by_addr, counter })
    }

    fn next_id(&self) -> Result<u64, StakeError> {
        let key = b"next_id";
        let new = self.counter.update_and_fetch(key, |old| {
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
            StakeError::Sled(sled::Error::Unsupported("counter update returned None".into()))
        })?;
        let mut a = [0u8; 8];
        a.copy_from_slice(&bytes);
        Ok(u64::from_be_bytes(a))
    }

    /// Stake `amount_sat` from `address` at `tier`. Enforces the tier's
    /// minimum stake (caller is responsible for verifying badges).
    pub fn stake(
        &self,
        address: [u8; 32],
        amount_sat: u64,
        tier: Tier,
        current_block: u64,
    ) -> Result<StakeRecord, StakeError> {
        if amount_sat < tier.min_stake_sat() {
            return Err(StakeError::BelowTierMinimum);
        }
        let id = self.next_id()?;
        let rec = StakeRecord {
            id,
            address,
            amount_sat,
            tier,
            created_block: current_block,
            status: StakeStatus::Active,
            unbonding_block: 0,
        };
        self.put(&rec)?;
        Ok(rec)
    }

    /// Begin unbonding — funds remain locked for `UNBONDING_PERIOD_BLOCKS`.
    pub fn start_unbonding(&self, id: u64, current_block: u64) -> Result<StakeRecord, StakeError> {
        let mut rec = self.get(id)?.ok_or(StakeError::NotFound)?;
        if rec.status != StakeStatus::Active {
            return Err(StakeError::AlreadyUnbonding);
        }
        rec.status = StakeStatus::Unbonding;
        rec.unbonding_block = current_block;
        self.put(&rec)?;
        Ok(rec)
    }

    /// Complete unbonding — caller is responsible for actually returning
    /// funds to the staker. Returns the amount that becomes spendable.
    pub fn complete_unbonding(&self, id: u64, current_block: u64) -> Result<u64, StakeError> {
        let mut rec = self.get(id)?.ok_or(StakeError::NotFound)?;
        if !rec.is_unbonding_complete(current_block) {
            return Err(StakeError::UnbondingNotComplete);
        }
        let amt = rec.amount_sat;
        rec.status = StakeStatus::Unbonded;
        self.put(&rec)?;
        Ok(amt)
    }

    /// Apply a slash directly to a stake record. Used by SlashingEngine —
    /// keeps the registry as the single source of truth.
    pub fn apply_slash(&self, id: u64, slash_amount_sat: u64) -> Result<StakeRecord, StakeError> {
        let mut rec = self.get(id)?.ok_or(StakeError::NotFound)?;
        let new_amt = rec.amount_sat.saturating_sub(slash_amount_sat);
        rec.amount_sat = new_amt;
        if new_amt == 0 {
            rec.status = StakeStatus::Slashed;
        }
        self.put(&rec)?;
        Ok(rec)
    }

    pub fn get(&self, id: u64) -> Result<Option<StakeRecord>, StakeError> {
        let key = id.to_be_bytes();
        match self.stakes.get(key)? {
            Some(bytes) => Ok(Some(serde_json::from_slice(&bytes)?)),
            None => Ok(None),
        }
    }

    fn put(&self, rec: &StakeRecord) -> Result<(), StakeError> {
        let key = rec.id.to_be_bytes();
        let bytes = serde_json::to_vec(rec)?;
        self.stakes.insert(key, bytes)?;
        let mut idx = Vec::with_capacity(40);
        idx.extend_from_slice(&rec.address);
        idx.extend_from_slice(&key);
        self.by_addr.insert(idx, &[])?;
        Ok(())
    }

    /// All stake records owned by `address` (any status).
    pub fn list_by_address(&self, address: &[u8; 32]) -> Result<Vec<StakeRecord>, StakeError> {
        let mut out = Vec::new();
        let prefix = &address[..];
        for item in self.by_addr.scan_prefix(prefix) {
            let (key, _) = item?;
            if key.len() < 40 {
                continue;
            }
            let mut id_bytes = [0u8; 8];
            id_bytes.copy_from_slice(&key[32..40]);
            let id = u64::from_be_bytes(id_bytes);
            if let Some(rec) = self.get(id)? {
                out.push(rec);
            }
        }
        Ok(out)
    }

    /// Sum of all active+unbonding stake for an address (slashed and
    /// fully-unbonded records excluded).
    pub fn total_active_for(&self, address: &[u8; 32]) -> Result<u64, StakeError> {
        let mut total = 0u64;
        for rec in self.list_by_address(address)? {
            if matches!(rec.status, StakeStatus::Active | StakeStatus::Unbonding) {
                total = total.saturating_add(rec.amount_sat);
            }
        }
        Ok(total)
    }

    /// Iterate every stake record. Used by the validator set rebuild.
    pub fn iter_all(&self) -> impl Iterator<Item = Result<StakeRecord, StakeError>> + '_ {
        self.stakes.iter().map(|res| {
            let (_, bytes) = res?;
            let rec: StakeRecord = serde_json::from_slice(&bytes)?;
            Ok(rec)
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn open_registry() -> (sled::Db, StakeRegistry) {
        let db = sled::Config::new().temporary(true).open().unwrap();
        let reg = StakeRegistry::open(&db).unwrap();
        (db, reg)
    }

    #[test]
    fn stake_and_lookup() {
        let (_db, reg) = open_registry();
        let addr = [0x11; 32];
        let rec = reg
            .stake(addr, Tier::Omni.min_stake_sat(), Tier::Omni, 1)
            .unwrap();
        assert_eq!(rec.id, 1);
        let by = reg.list_by_address(&addr).unwrap();
        assert_eq!(by.len(), 1);
        assert_eq!(reg.total_active_for(&addr).unwrap(), Tier::Omni.min_stake_sat());
    }

    #[test]
    fn below_tier_min_rejected() {
        let (_db, reg) = open_registry();
        let err = reg.stake([0x22; 32], 1, Tier::Love, 1).unwrap_err();
        assert!(matches!(err, StakeError::BelowTierMinimum));
    }

    #[test]
    fn unbonding_flow() {
        let (_db, reg) = open_registry();
        let addr = [0x33; 32];
        let rec = reg
            .stake(addr, Tier::Omni.min_stake_sat(), Tier::Omni, 1)
            .unwrap();
        reg.start_unbonding(rec.id, 100).unwrap();
        let err = reg.complete_unbonding(rec.id, 200).unwrap_err();
        assert!(matches!(err, StakeError::UnbondingNotComplete));
        let returned = reg
            .complete_unbonding(rec.id, 100 + UNBONDING_PERIOD_BLOCKS + 1)
            .unwrap();
        assert_eq!(returned, Tier::Omni.min_stake_sat());
    }

    #[test]
    fn slash_reduces_amount() {
        let (_db, reg) = open_registry();
        let addr = [0x44; 32];
        let rec = reg
            .stake(addr, Tier::Omni.min_stake_sat(), Tier::Omni, 1)
            .unwrap();
        let after = reg.apply_slash(rec.id, 33_000_000_000).unwrap();
        assert!(after.amount_sat < Tier::Omni.min_stake_sat());
        assert_eq!(after.status, StakeStatus::Active);
    }
}
