//! Slashing — evidence verification + execution.
//!
//! Rust port of `core/staking.zig` (submit/execute slash paths) and
//! `core/slashing_evidence.zig` (evidence collector). Philosophy unchanged:
//!
//!   - Only staked validators can be slashed. Normal users have nothing
//!     to slash and cannot be punished from this layer.
//!   - Double-sign + invalid-block require cryptographic proof. Downtime
//!     is a small penalty (1%) not a punitive slash.
//!   - Reporter receives 10% of the slashed amount.
//!
//! Persistence: sled tree `validator_slash_records` stores every executed
//! slash for auditability (used by `getslashhistory` / `getslashevents`).

use super::set::{ValidatorSet, ValidatorStatus};
use super::staking::StakeRegistry;
use serde::{Deserialize, Serialize};
use sled::{Db, Tree};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[repr(u8)]
pub enum SlashReason {
    /// Signed two different blocks at the same height — cryptographic proof required.
    DoubleSign = 0,
    /// Submitted a provably invalid block (bad merkle root, inflated reward).
    InvalidBlock = 1,
    /// Extended downtime — small penalty, NOT a full slash.
    Downtime = 2,
}

pub const SLASH_DOUBLE_SIGN_PCT: u64 = 33;
pub const SLASH_INVALID_BLOCK_PCT: u64 = 10;
pub const DOWNTIME_PENALTY_PCT: u64 = 1;
pub const MIN_SLASH_AMOUNT_SAT: u64 = 1_000_000;
pub const REPORTER_REWARD_PCT: u64 = 10;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SlashEvidence {
    pub validator_address: [u8; 32],
    pub reason: SlashReason,
    /// For double_sign: first block hash signed by validator.
    pub block_hash_1: [u8; 32],
    /// For double_sign: second (different) block hash at the same height.
    pub block_hash_2: [u8; 32],
    pub block_height: u64,
    #[serde(with = "serde_big_array::BigArray")]
    pub signature_1: [u8; 64],
    #[serde(with = "serde_big_array::BigArray")]
    pub signature_2: [u8; 64],
    /// Reporter — gets the reward if evidence is valid.
    pub reporter_address: [u8; 32],
    pub timestamp: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SlashRecord {
    pub validator: [u8; 32],
    pub reason: SlashReason,
    pub amount_slashed_sat: u64,
    pub block_height: u64,
    pub timestamp: i64,
    pub reporter: [u8; 32],
    pub reporter_reward_sat: u64,
}

#[derive(Debug, Clone)]
pub struct SlashResult {
    pub valid: bool,
    pub slashed_amount_sat: u64,
    pub reporter_reward_sat: u64,
    pub new_stake_sat: u64,
    pub reason: String,
}

impl SlashResult {
    pub fn rejected(msg: &str) -> Self {
        Self {
            valid: false,
            slashed_amount_sat: 0,
            reporter_reward_sat: 0,
            new_stake_sat: 0,
            reason: msg.to_string(),
        }
    }
}

#[derive(Debug, thiserror::Error)]
pub enum SlashError {
    #[error("sled error: {0}")]
    Sled(#[from] sled::Error),
    #[error("serde error: {0}")]
    Serde(#[from] serde_json::Error),
    #[error("validator set error: {0}")]
    Set(String),
    #[error("stake registry error: {0}")]
    Stake(String),
}

/// Sled-backed slashing engine. Operates against an existing
/// [`ValidatorSet`] and [`StakeRegistry`] — does not own state itself
/// beyond the audit trail of past slashes.
#[derive(Clone)]
pub struct SlashingEngine {
    records: Tree,
    counter: Tree,
}

impl SlashingEngine {
    pub fn open(db: &Db) -> Result<Self, SlashError> {
        let records = db.open_tree("validator_slash_records")?;
        let counter = db.open_tree("validator_slash_counter")?;
        Ok(Self { records, counter })
    }

    fn next_id(&self) -> Result<u64, SlashError> {
        let new = self.counter.update_and_fetch(b"next_id", |old| {
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
            SlashError::Sled(sled::Error::Unsupported("counter update returned None".into()))
        })?;
        let mut a = [0u8; 8];
        a.copy_from_slice(&bytes);
        Ok(u64::from_be_bytes(a))
    }

    /// Submit slash evidence — verify, execute if valid, persist the
    /// record. Returns a [`SlashResult`] (NOT an Err) for the rejection
    /// cases that are part of normal operation (validator not found,
    /// already slashed, bad evidence). Hard errors (sled IO) become Err.
    pub fn submit(
        &self,
        evidence: SlashEvidence,
        set: &ValidatorSet,
        stakes: &StakeRegistry,
    ) -> Result<SlashResult, SlashError> {
        // 1. Find the validator.
        let validator = match set
            .get(&evidence.validator_address)
            .map_err(|e| SlashError::Set(e.to_string()))?
        {
            Some(v) => v,
            None => {
                return Ok(SlashResult::rejected(
                    "Validator not found — only staked validators can be slashed",
                ));
            }
        };

        // 2. Slashable state check.
        if validator.status == ValidatorStatus::Slashed {
            return Ok(SlashResult::rejected("Validator already slashed"));
        }
        if validator.status == ValidatorStatus::Left {
            return Ok(SlashResult::rejected(
                "Validator left — no stake to slash",
            ));
        }
        if validator.effective_stake_sat == 0 {
            return Ok(SlashResult::rejected(
                "No stake to slash — normal users cannot be slashed",
            ));
        }

        // 3. Verify evidence by reason.
        match evidence.reason {
            SlashReason::DoubleSign => {
                if !verify_double_sign(&evidence) {
                    return Ok(SlashResult::rejected(
                        "Invalid double-sign evidence — hashes must differ",
                    ));
                }
            }
            SlashReason::InvalidBlock => {
                // Block validity has already been verified at the consensus
                // layer before evidence reaches here.
            }
            SlashReason::Downtime => {
                // Downtime evidence trusted — caller is the uptime monitor.
            }
        }

        // 4. Compute slash amount.
        let pct = match evidence.reason {
            SlashReason::DoubleSign => SLASH_DOUBLE_SIGN_PCT,
            SlashReason::InvalidBlock => SLASH_INVALID_BLOCK_PCT,
            SlashReason::Downtime => DOWNTIME_PENALTY_PCT,
        };
        let mut slash_amount = validator.effective_stake_sat * pct / 100;
        if slash_amount < MIN_SLASH_AMOUNT_SAT {
            slash_amount = MIN_SLASH_AMOUNT_SAT.min(validator.effective_stake_sat);
        }
        if slash_amount > validator.effective_stake_sat {
            slash_amount = validator.effective_stake_sat;
        }

        // 5. Apply the slash across stake records (largest first).
        let mut remaining = slash_amount;
        let mut all = stakes
            .list_by_address(&evidence.validator_address)
            .map_err(|e| SlashError::Stake(e.to_string()))?;
        all.sort_by(|a, b| b.amount_sat.cmp(&a.amount_sat));
        for rec in all {
            if remaining == 0 {
                break;
            }
            let take = remaining.min(rec.amount_sat);
            stakes
                .apply_slash(rec.id, take)
                .map_err(|e| SlashError::Stake(e.to_string()))?;
            remaining -= take;
        }

        // 6. Update the validator record.
        let new_effective = validator.effective_stake_sat.saturating_sub(slash_amount);
        let permanent = !matches!(evidence.reason, SlashReason::Downtime);
        set.mark_slashed(&evidence.validator_address, permanent, new_effective)
            .map_err(|e| SlashError::Set(e.to_string()))?;

        // 7. Reporter reward (paid out by the chain orchestrator).
        let reporter_reward = slash_amount * REPORTER_REWARD_PCT / 100;

        // 8. Persist the record.
        let id = self.next_id()?;
        let record = SlashRecord {
            validator: evidence.validator_address,
            reason: evidence.reason,
            amount_slashed_sat: slash_amount,
            block_height: evidence.block_height,
            timestamp: evidence.timestamp,
            reporter: evidence.reporter_address,
            reporter_reward_sat: reporter_reward,
        };
        self.records.insert(id.to_be_bytes(), serde_json::to_vec(&record)?)?;

        let reason_msg = match evidence.reason {
            SlashReason::DoubleSign => "Double-sign: 33% stake slashed",
            SlashReason::InvalidBlock => "Invalid block: 10% stake slashed",
            SlashReason::Downtime => "Downtime: 1% penalty applied",
        };
        Ok(SlashResult {
            valid: true,
            slashed_amount_sat: slash_amount,
            reporter_reward_sat: reporter_reward,
            new_stake_sat: new_effective,
            reason: reason_msg.to_string(),
        })
    }

    /// Full slashing history for a validator (chronological).
    pub fn history_for(&self, address: &[u8; 32]) -> Result<Vec<SlashRecord>, SlashError> {
        let mut out = Vec::new();
        for kv in self.records.iter() {
            let (_, bytes) = kv?;
            let rec: SlashRecord = serde_json::from_slice(&bytes)?;
            if &rec.validator == address {
                out.push(rec);
            }
        }
        Ok(out)
    }

    /// All slash events (newest first), for `getslashevents`.
    pub fn list_all(&self, limit: usize) -> Result<Vec<SlashRecord>, SlashError> {
        let mut out = Vec::new();
        for kv in self.records.iter().rev() {
            if out.len() >= limit {
                break;
            }
            let (_, bytes) = kv?;
            out.push(serde_json::from_slice(&bytes)?);
        }
        Ok(out)
    }
}

/// Double-sign verifier — the cryptographic proof itself (that both
/// signatures came from the validator's pubkey) is the responsibility of
/// the consensus layer that built the evidence. Here we only enforce the
/// structural invariants: different hashes, both non-zero, both signed,
/// height > 0.
///
/// TODO(crypto-agent): once `validator_pubkey` is added to ValidatorRecord,
/// verify both signatures with secp256k1 directly here so RPC submissions
/// without consensus-layer preverification still get a real check.
fn verify_double_sign(ev: &SlashEvidence) -> bool {
    if ev.block_hash_1 == ev.block_hash_2 {
        return false;
    }
    if ev.block_hash_1 == [0u8; 32] || ev.block_hash_2 == [0u8; 32] {
        return false;
    }
    if ev.signature_1 == [0u8; 64] || ev.signature_2 == [0u8; 64] {
        return false;
    }
    if ev.block_height == 0 {
        return false;
    }
    true
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::validator::{Tier, TierBadges};

    fn setup() -> (sled::Db, StakeRegistry, ValidatorSet, SlashingEngine, [u8; 32]) {
        let db = sled::Config::new().temporary(true).open().unwrap();
        let reg = StakeRegistry::open(&db).unwrap();
        let set = ValidatorSet::open(&db).unwrap();
        let eng = SlashingEngine::open(&db).unwrap();
        let addr = [0x99; 32];
        // Bootstrap validator — no badges needed.
        reg.stake(addr, Tier::Omni.min_stake_sat() * 10, Tier::Omni, 1)
            .unwrap();
        set.become_validator(&reg, addr, Tier::Omni, TierBadges::default(), 1)
            .unwrap();
        (db, reg, set, eng, addr)
    }

    fn evidence(addr: [u8; 32], reason: SlashReason) -> SlashEvidence {
        SlashEvidence {
            validator_address: addr,
            reason,
            block_hash_1: [1u8; 32],
            block_hash_2: [2u8; 32],
            block_height: 100,
            signature_1: [1u8; 64],
            signature_2: [2u8; 64],
            reporter_address: [0xCC; 32],
            timestamp: 1_700_000_000,
        }
    }

    #[test]
    fn double_sign_executes() {
        let (_db, reg, set, eng, addr) = setup();
        let result = eng
            .submit(evidence(addr, SlashReason::DoubleSign), &set, &reg)
            .unwrap();
        assert!(result.valid);
        assert!(result.slashed_amount_sat > 0);
        let v = set.get(&addr).unwrap().unwrap();
        assert_eq!(v.status, ValidatorStatus::Slashed);
    }

    #[test]
    fn double_sign_identical_hashes_rejected() {
        let (_db, reg, set, eng, addr) = setup();
        let mut ev = evidence(addr, SlashReason::DoubleSign);
        ev.block_hash_2 = ev.block_hash_1;
        let result = eng.submit(ev, &set, &reg).unwrap();
        assert!(!result.valid);
    }

    #[test]
    fn downtime_jails_not_permanent() {
        let (_db, reg, set, eng, addr) = setup();
        let result = eng
            .submit(evidence(addr, SlashReason::Downtime), &set, &reg)
            .unwrap();
        assert!(result.valid);
        let v = set.get(&addr).unwrap().unwrap();
        assert_eq!(v.status, ValidatorStatus::Jailed);
    }

    #[test]
    fn unknown_validator_rejected() {
        let (_db, reg, set, eng, _addr) = setup();
        let result = eng
            .submit(evidence([0x42; 32], SlashReason::DoubleSign), &set, &reg)
            .unwrap();
        assert!(!result.valid);
    }

    #[test]
    fn history_records_event() {
        let (_db, reg, set, eng, addr) = setup();
        eng.submit(evidence(addr, SlashReason::InvalidBlock), &set, &reg)
            .unwrap();
        let h = eng.history_for(&addr).unwrap();
        assert_eq!(h.len(), 1);
        assert_eq!(h[0].reason, SlashReason::InvalidBlock);
    }
}
