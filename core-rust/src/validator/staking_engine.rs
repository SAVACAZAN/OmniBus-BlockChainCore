//! In-memory StakingEngine — port of `core/staking.zig`.
//!
//! This is the pure-logic, no-sled counterpart to [`crate::validator::staking::StakeRegistry`].
//! Use this for:
//!   - genesis / bootstrap (before the DB is available)
//!   - unit tests that don't need persistence
//!   - consensus-layer validator set rebuild (scan all records → populate engine)
//!
//! Key differences from the Zig original:
//!   - Uses `Vec<Validator>` instead of fixed-size arrays.
//!   - `address` is `[u8; 32]` (canonical byte form) not a bech32 slice.
//!   - Evidence-based slashing mirrors `staking.zig::submitSlashEvidence`.
//!
//! For production persistent staking, see `validator::staking::StakeRegistry` (sled-backed).

use super::UNBONDING_PERIOD_BLOCKS;
use serde::{Deserialize, Serialize};

// ── Constants ─────────────────────────────────────────────────────────────────

/// Minimum stake to become a validator (100 OMNI = 100 × 10^9 SAT).
pub const VALIDATOR_MIN_STAKE_SAT: u64 = 100_000_000_000;

/// Maximum validators in the active set.
pub const MAX_VALIDATORS: usize = 128;

/// Slash: 33% for double-sign.
pub const SLASH_DOUBLE_SIGN_PCT: u64 = 33;
/// Slash: 10% for invalid block.
pub const SLASH_INVALID_BLOCK_PCT: u64 = 10;
/// Penalty: 1% for extended downtime.
pub const DOWNTIME_PENALTY_PCT: u64 = 1;
/// Minimum slash amount (0.001 OMNI = 1_000_000 SAT).
pub const MIN_SLASH_AMOUNT_SAT: u64 = 1_000_000;
/// Reporter receives 10% of the slashed amount.
pub const REPORTER_REWARD_PCT: u64 = 10;

// ── Types ─────────────────────────────────────────────────────────────────────

/// Validator lifecycle state — mirrors Zig `ValidatorStatus`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[repr(u8)]
pub enum ValidatorStatusEngine {
    Pending = 0,
    Active = 1,
    Unbonding = 2,
    Unbonded = 3,
    Slashed = 4,
    Jailed = 5,
}

/// Slash reason — matches `staking.zig::SlashReason`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[repr(u8)]
pub enum SlashReasonEngine {
    DoubleSign = 0,
    InvalidBlock = 1,
    Downtime = 2,
}

impl SlashReasonEngine {
    pub fn pct(self) -> u64 {
        match self {
            SlashReasonEngine::DoubleSign => SLASH_DOUBLE_SIGN_PCT,
            SlashReasonEngine::InvalidBlock => SLASH_INVALID_BLOCK_PCT,
            SlashReasonEngine::Downtime => DOWNTIME_PENALTY_PCT,
        }
    }
}

/// A single validator's record in the engine.
#[derive(Debug, Clone)]
pub struct ValidatorEntry {
    /// 32-byte canonical address (BIP-44 OMNI path).
    pub address: [u8; 32],
    /// Total stake (own + delegated) in SAT.
    pub total_stake_sat: u64,
    /// Own (self-bonded) stake in SAT.
    pub self_stake_sat: u64,
    pub status: ValidatorStatusEngine,
    pub registered_block: u64,
    /// Set when unbonding begins (0 if active).
    pub unbonding_block: u64,
    pub blocks_produced: u32,
    pub blocks_missed: u32,
    pub total_rewards_sat: u64,
    /// Commission rate 0–100%.
    pub commission_pct: u8,
    pub slash_count: u8,
}

impl ValidatorEntry {
    pub fn new(address: [u8; 32], stake_sat: u64, block: u64) -> Self {
        Self {
            address,
            total_stake_sat: stake_sat,
            self_stake_sat: stake_sat,
            status: ValidatorStatusEngine::Pending,
            registered_block: block,
            unbonding_block: 0,
            blocks_produced: 0,
            blocks_missed: 0,
            total_rewards_sat: 0,
            commission_pct: 10,
            slash_count: 0,
        }
    }

    /// Uptime percentage (0–100).
    pub fn uptime_pct(&self) -> u8 {
        let total = self.blocks_produced + self.blocks_missed;
        if total == 0 {
            return 100;
        }
        ((self.blocks_produced as u64 * 100) / total as u64) as u8
    }

    /// Voting power (only active validators have power).
    pub fn voting_power(&self) -> u64 {
        if self.status == ValidatorStatusEngine::Active {
            self.total_stake_sat
        } else {
            0
        }
    }

    /// True if downtime slashing criteria are met.
    pub fn should_slash_downtime(&self) -> bool {
        let total = self.blocks_produced + self.blocks_missed;
        total > 100 && self.uptime_pct() < 95
    }
}

/// Slash evidence (structural proof only — cryptographic verification is the
/// responsibility of the consensus / P2P layer before reaching here).
#[derive(Debug, Clone)]
pub struct SlashEvidenceEngine {
    pub validator_address: [u8; 32],
    pub reason: SlashReasonEngine,
    pub block_hash_1: [u8; 32],
    pub block_hash_2: [u8; 32],
    pub block_height: u64,
    pub signature_1: [u8; 64],
    pub signature_2: [u8; 64],
    pub reporter_address: [u8; 32],
    pub timestamp: i64,
}

/// Result of processing a slash evidence submission.
#[derive(Debug, Clone)]
pub struct SlashResultEngine {
    pub valid: bool,
    pub slashed_amount_sat: u64,
    pub reporter_reward_sat: u64,
    pub new_stake_sat: u64,
    pub reason: String,
}

impl SlashResultEngine {
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

/// Persisted record of an executed slash.
#[derive(Debug, Clone)]
pub struct SlashRecordEngine {
    pub validator: [u8; 32],
    pub reason: SlashReasonEngine,
    pub amount_slashed_sat: u64,
    pub block_height: u64,
    pub timestamp: i64,
    pub reporter: [u8; 32],
    pub reporter_reward_sat: u64,
}

// ── Errors ────────────────────────────────────────────────────────────────────

#[derive(Debug, thiserror::Error)]
pub enum StakingEngineError {
    #[error("insufficient stake (min {VALIDATOR_MIN_STAKE_SAT} SAT)")]
    InsufficientStake,
    #[error("validator set full ({MAX_VALIDATORS} max)")]
    ValidatorSetFull,
    #[error("validator already registered")]
    AlreadyRegistered,
    #[error("invalid validator index")]
    InvalidIndex,
    #[error("validator not in expected state")]
    WrongStatus,
    #[error("unbonding not complete yet")]
    UnbondingNotComplete,
    #[error("uptime sufficient — downtime slash not warranted")]
    UptimeSufficient,
}

// ── StakingEngine ─────────────────────────────────────────────────────────────

/// In-memory staking engine — pure Zig port, no sled dependency.
///
/// A `Vec`-based alternative to the sled-backed `StakeRegistry` for use in
/// tests and genesis bootstrapping.
pub struct StakingEngine {
    pub validators: Vec<ValidatorEntry>,
    /// Total SAT staked across all validators.
    pub total_staked_sat: u64,
    /// Monotonic epoch counter (bumped on every `distribute_rewards` call).
    pub current_epoch: u64,
    pub total_slashes: u32,
    pub slash_records: Vec<SlashRecordEngine>,
    pub total_slashed_sat: u64,
    pub total_reporter_rewards_sat: u64,
}

impl StakingEngine {
    pub fn new() -> Self {
        Self {
            validators: Vec::new(),
            total_staked_sat: 0,
            current_epoch: 0,
            total_slashes: 0,
            slash_records: Vec::new(),
            total_slashed_sat: 0,
            total_reporter_rewards_sat: 0,
        }
    }

    // ── Registration / lifecycle ──────────────────────────────────────────

    /// Register a new validator with initial self-stake.
    /// Returns the index in `self.validators`.
    pub fn register(
        &mut self,
        address: [u8; 32],
        stake_sat: u64,
        current_block: u64,
    ) -> Result<usize, StakingEngineError> {
        if stake_sat < VALIDATOR_MIN_STAKE_SAT {
            return Err(StakingEngineError::InsufficientStake);
        }
        if self.validators.len() >= MAX_VALIDATORS {
            return Err(StakingEngineError::ValidatorSetFull);
        }
        if self.find_index(&address).is_some() {
            return Err(StakingEngineError::AlreadyRegistered);
        }
        let entry = ValidatorEntry::new(address, stake_sat, current_block);
        self.validators.push(entry);
        self.total_staked_sat = self.total_staked_sat.saturating_add(stake_sat);
        Ok(self.validators.len() - 1)
    }

    /// Activate a pending validator.
    pub fn activate(&mut self, idx: usize) -> Result<(), StakingEngineError> {
        let v = self.validators.get_mut(idx).ok_or(StakingEngineError::InvalidIndex)?;
        if v.status != ValidatorStatusEngine::Pending {
            return Err(StakingEngineError::WrongStatus);
        }
        v.status = ValidatorStatusEngine::Active;
        Ok(())
    }

    /// Begin unbonding period for an active validator.
    pub fn start_unbonding(&mut self, idx: usize, current_block: u64) -> Result<(), StakingEngineError> {
        let v = self.validators.get_mut(idx).ok_or(StakingEngineError::InvalidIndex)?;
        if v.status != ValidatorStatusEngine::Active {
            return Err(StakingEngineError::WrongStatus);
        }
        v.status = ValidatorStatusEngine::Unbonding;
        v.unbonding_block = current_block;
        Ok(())
    }

    /// Complete unbonding. Returns the amount to return to the validator.
    pub fn complete_unbonding(&mut self, idx: usize, current_block: u64) -> Result<u64, StakingEngineError> {
        let v = self.validators.get_mut(idx).ok_or(StakingEngineError::InvalidIndex)?;
        if v.status != ValidatorStatusEngine::Unbonding {
            return Err(StakingEngineError::WrongStatus);
        }
        if current_block < v.unbonding_block + UNBONDING_PERIOD_BLOCKS {
            return Err(StakingEngineError::UnbondingNotComplete);
        }
        let returned = v.self_stake_sat;
        v.status = ValidatorStatusEngine::Unbonded;
        self.total_staked_sat = self.total_staked_sat.saturating_sub(v.total_stake_sat);
        v.total_stake_sat = 0;
        v.self_stake_sat = 0;
        Ok(returned)
    }

    // ── Proposer selection ────────────────────────────────────────────────

    /// Stake-weighted random proposer selection.
    /// Uses the first 8 bytes of `block_hash` as a pseudorandom u64.
    pub fn select_proposer(&self, block_hash: [u8; 32]) -> Option<usize> {
        if self.active_count() == 0 {
            return None;
        }
        let tvp = self.total_voting_power();
        if tvp == 0 {
            return None;
        }
        let mut seed = [0u8; 8];
        seed.copy_from_slice(&block_hash[..8]);
        let rand = u64::from_le_bytes(seed);
        let target = rand % tvp;

        let mut cumulative: u64 = 0;
        for (i, v) in self.validators.iter().enumerate() {
            if v.status != ValidatorStatusEngine::Active {
                continue;
            }
            cumulative = cumulative.saturating_add(v.total_stake_sat);
            if cumulative > target {
                return Some(i);
            }
        }
        None
    }

    // ── Queries ───────────────────────────────────────────────────────────

    pub fn active_count(&self) -> usize {
        self.validators
            .iter()
            .filter(|v| v.status == ValidatorStatusEngine::Active)
            .count()
    }

    pub fn total_voting_power(&self) -> u64 {
        self.validators.iter().map(|v| v.voting_power()).sum()
    }

    pub fn find_index(&self, address: &[u8; 32]) -> Option<usize> {
        self.validators
            .iter()
            .position(|v| &v.address == address)
    }

    // ── Reward distribution ───────────────────────────────────────────────

    /// Distribute `total_reward_sat` proportionally among active validators.
    pub fn distribute_rewards(&mut self, total_reward_sat: u64) {
        let tvp = self.total_voting_power();
        if tvp == 0 {
            return;
        }
        for v in &mut self.validators {
            if v.status != ValidatorStatusEngine::Active {
                continue;
            }
            let share = ((total_reward_sat as u128 * v.total_stake_sat as u128) / tvp as u128) as u64;
            v.total_rewards_sat = v.total_rewards_sat.saturating_add(share);
        }
        self.current_epoch += 1;
    }

    // ── Evidence-based slashing ───────────────────────────────────────────

    /// Submit slash evidence. Verifies structural proof, executes the slash
    /// if valid, and records the event. Returns `SlashResultEngine` (not Err)
    /// for the common rejection cases.
    pub fn submit_slash_evidence(&mut self, evidence: SlashEvidenceEngine) -> SlashResultEngine {
        let idx = match self.find_index(&evidence.validator_address) {
            Some(i) => i,
            None => {
                return SlashResultEngine::rejected(
                    "Validator not found — only staked validators can be slashed",
                );
            }
        };

        {
            let v = &self.validators[idx];
            if v.status == ValidatorStatusEngine::Slashed {
                return SlashResultEngine::rejected("Validator already slashed");
            }
            if v.status == ValidatorStatusEngine::Unbonded {
                return SlashResultEngine::rejected("Validator fully unbonded — no stake to slash");
            }
            if v.total_stake_sat == 0 {
                return SlashResultEngine::rejected(
                    "No stake to slash — normal users cannot be slashed",
                );
            }
        }

        // Structural evidence check.
        if let SlashReasonEngine::DoubleSign = evidence.reason {
            if !verify_double_sign_engine(&evidence) {
                return SlashResultEngine::rejected(
                    "Invalid double-sign evidence — hashes must differ",
                );
            }
        }

        self.execute_slash(idx, evidence)
    }

    fn execute_slash(
        &mut self,
        idx: usize,
        evidence: SlashEvidenceEngine,
    ) -> SlashResultEngine {
        let pct = evidence.reason.pct();
        let v = &self.validators[idx];
        let mut slash_amount = v.total_stake_sat * pct / 100;
        // Enforce minimum.
        if slash_amount < MIN_SLASH_AMOUNT_SAT {
            slash_amount = MIN_SLASH_AMOUNT_SAT.min(v.total_stake_sat);
        }
        slash_amount = slash_amount.min(v.total_stake_sat);

        let v = &mut self.validators[idx];
        v.total_stake_sat = v.total_stake_sat.saturating_sub(slash_amount);
        v.self_stake_sat = v.self_stake_sat.saturating_sub(slash_amount);
        v.slash_count = v.slash_count.saturating_add(1);
        // Downtime → jail; everything else → slashed permanently.
        if let SlashReasonEngine::Downtime = evidence.reason {
            v.status = ValidatorStatusEngine::Jailed;
        } else {
            v.status = ValidatorStatusEngine::Slashed;
        }
        let new_stake = v.total_stake_sat;

        self.total_staked_sat = self.total_staked_sat.saturating_sub(slash_amount);
        self.total_slashes += 1;
        self.total_slashed_sat = self.total_slashed_sat.saturating_add(slash_amount);

        let reporter_reward = slash_amount * REPORTER_REWARD_PCT / 100;
        self.total_reporter_rewards_sat =
            self.total_reporter_rewards_sat.saturating_add(reporter_reward);

        let reason_msg = match evidence.reason {
            SlashReasonEngine::DoubleSign => "Double-sign: 33% stake slashed",
            SlashReasonEngine::InvalidBlock => "Invalid block: 10% stake slashed",
            SlashReasonEngine::Downtime => "Downtime: 1% penalty applied",
        };

        self.slash_records.push(SlashRecordEngine {
            validator: evidence.validator_address,
            reason: evidence.reason,
            amount_slashed_sat: slash_amount,
            block_height: evidence.block_height,
            timestamp: evidence.timestamp,
            reporter: evidence.reporter_address,
            reporter_reward_sat: reporter_reward,
        });

        SlashResultEngine {
            valid: true,
            slashed_amount_sat: slash_amount,
            reporter_reward_sat: reporter_reward,
            new_stake_sat: new_stake,
            reason: reason_msg.to_string(),
        }
    }

    /// Slash history for a specific validator address.
    pub fn slash_history(&self, address: &[u8; 32]) -> Vec<&SlashRecordEngine> {
        self.slash_records
            .iter()
            .filter(|r| &r.validator == address)
            .collect()
    }
}

impl Default for StakingEngine {
    fn default() -> Self {
        Self::new()
    }
}

// ── Helpers ───────────────────────────────────────────────────────────────────

fn verify_double_sign_engine(ev: &SlashEvidenceEngine) -> bool {
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

// ── Tests ─────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    fn addr(byte: u8) -> [u8; 32] {
        [byte; 32]
    }

    fn evidence(validator: [u8; 32], reason: SlashReasonEngine) -> SlashEvidenceEngine {
        SlashEvidenceEngine {
            validator_address: validator,
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

    fn activated_engine() -> (StakingEngine, usize) {
        let mut e = StakingEngine::new();
        let idx = e.register(addr(0xAA), VALIDATOR_MIN_STAKE_SAT * 10, 1).unwrap();
        e.activate(idx).unwrap();
        (e, idx)
    }

    #[test]
    fn register_and_activate() {
        let (e, idx) = activated_engine();
        assert_eq!(e.validators[idx].status, ValidatorStatusEngine::Active);
        assert_eq!(e.active_count(), 1);
    }

    #[test]
    fn below_minimum_stake_rejected() {
        let mut e = StakingEngine::new();
        let err = e.register(addr(0x01), 1, 1).unwrap_err();
        assert!(matches!(err, StakingEngineError::InsufficientStake));
    }

    #[test]
    fn duplicate_registration_rejected() {
        let mut e = StakingEngine::new();
        e.register(addr(0x02), VALIDATOR_MIN_STAKE_SAT, 1).unwrap();
        let err = e.register(addr(0x02), VALIDATOR_MIN_STAKE_SAT, 2).unwrap_err();
        assert!(matches!(err, StakingEngineError::AlreadyRegistered));
    }

    #[test]
    fn unbonding_lifecycle() {
        let (mut e, idx) = activated_engine();
        e.start_unbonding(idx, 100).unwrap();
        assert_eq!(e.validators[idx].status, ValidatorStatusEngine::Unbonding);

        // Too early.
        let err = e.complete_unbonding(idx, 200).unwrap_err();
        assert!(matches!(err, StakingEngineError::UnbondingNotComplete));

        // After unbonding period.
        let returned = e.complete_unbonding(idx, 100 + UNBONDING_PERIOD_BLOCKS + 1).unwrap();
        assert_eq!(returned, VALIDATOR_MIN_STAKE_SAT * 10);
        assert_eq!(e.validators[idx].status, ValidatorStatusEngine::Unbonded);
    }

    #[test]
    fn proposer_selection_single_validator() {
        let (e, idx) = activated_engine();
        let proposer = e.select_proposer([0u8; 32]).unwrap();
        assert_eq!(proposer, idx);
    }

    #[test]
    fn distribute_rewards() {
        let (mut e, idx) = activated_engine();
        let reward = 1_000_000_000u64; // 1 OMNI
        e.distribute_rewards(reward);
        assert_eq!(e.validators[idx].total_rewards_sat, reward);
        assert_eq!(e.current_epoch, 1);
    }

    #[test]
    fn double_sign_slash() {
        let (mut e, idx) = activated_engine();
        let result = e.submit_slash_evidence(evidence(addr(0xAA), SlashReasonEngine::DoubleSign));
        assert!(result.valid);
        assert!(result.slashed_amount_sat > 0);
        assert_eq!(e.validators[idx].status, ValidatorStatusEngine::Slashed);
    }

    #[test]
    fn downtime_jails_not_perma_slashed() {
        let (mut e, idx) = activated_engine();
        let result = e.submit_slash_evidence(evidence(addr(0xAA), SlashReasonEngine::Downtime));
        assert!(result.valid);
        assert_eq!(e.validators[idx].status, ValidatorStatusEngine::Jailed);
    }

    #[test]
    fn double_sign_identical_hashes_rejected() {
        let (mut e, _) = activated_engine();
        let mut ev = evidence(addr(0xAA), SlashReasonEngine::DoubleSign);
        ev.block_hash_2 = ev.block_hash_1; // same hashes → not equivocation
        let result = e.submit_slash_evidence(ev);
        assert!(!result.valid);
    }

    #[test]
    fn slash_unknown_validator_rejected() {
        let (mut e, _) = activated_engine();
        let result = e.submit_slash_evidence(evidence(addr(0xFF), SlashReasonEngine::DoubleSign));
        assert!(!result.valid);
    }

    #[test]
    fn slash_history_records_event() {
        let (mut e, _) = activated_engine();
        e.submit_slash_evidence(evidence(addr(0xAA), SlashReasonEngine::InvalidBlock));
        let history = e.slash_history(&addr(0xAA));
        assert_eq!(history.len(), 1);
        assert_eq!(history[0].reason, SlashReasonEngine::InvalidBlock);
    }

    #[test]
    fn reporter_reward_10pct() {
        let (mut e, _) = activated_engine();
        let stake = e.validators[0].total_stake_sat;
        let result = e.submit_slash_evidence(evidence(addr(0xAA), SlashReasonEngine::DoubleSign));
        let expected_slash = stake * SLASH_DOUBLE_SIGN_PCT / 100;
        let expected_reward = expected_slash * REPORTER_REWARD_PCT / 100;
        assert_eq!(result.reporter_reward_sat, expected_reward);
    }

    #[test]
    fn uptime_pct_correct() {
        let mut v = ValidatorEntry::new([0; 32], VALIDATOR_MIN_STAKE_SAT, 1);
        v.blocks_produced = 95;
        v.blocks_missed = 5;
        assert_eq!(v.uptime_pct(), 95);
    }
}
