//! PoW engine + difficulty retarget + halving curve.
//!
//! Mirrors `core/consensus.zig` (PoW validation) and
//! `core/blockchain/consensus_params.zig` (retarget + reward schedule).
//! Formulas are byte-identical so a block accepted on Rust is accepted on
//! Zig and vice-versa.

use super::block::Block;
use super::{
    BLOCK_REWARD_SAT, HALVING_INTERVAL, MAX_DIFFICULTY, MIN_DIFFICULTY, TARGET_INTERVAL_S,
};

/// Consensus flavour. Future-proofing for PBFT swap; PoW is the live path.
#[derive(Debug, Clone, Copy)]
pub enum ConsensusType {
    ProofOfWork,
    MajorityVote,
    Pbft,
}

#[derive(Debug, Clone, Copy)]
pub struct ConsensusConfig {
    pub consensus_type: ConsensusType,
    pub total_validators: u16,
    pub round_timeout_ms: u32,
    pub min_votes: u16,
}

impl ConsensusConfig {
    pub fn new(ctype: ConsensusType, total_validators: u16) -> Self {
        let min_votes = match ctype {
            ConsensusType::ProofOfWork => 1,
            ConsensusType::MajorityVote => total_validators / 2 + 1,
            ConsensusType::Pbft => 2 * (total_validators / 3) + 1,
        };
        Self {
            consensus_type: ctype,
            total_validators,
            round_timeout_ms: 100,
            min_votes,
        }
    }

    pub fn byzantine_tolerance(&self) -> u16 {
        match self.consensus_type {
            ConsensusType::ProofOfWork => 0,
            ConsensusType::MajorityVote => (self.total_validators.saturating_sub(1)) / 2,
            ConsensusType::Pbft => (self.total_validators.saturating_sub(1)) / 3,
        }
    }
}

/// Stateless PoW validator. Difficulty is expressed in leading hex zeros on
/// the block hash hex string (same convention as Zig).
pub struct ConsensusEngine {
    pub config: ConsensusConfig,
}

impl ConsensusEngine {
    pub fn new(config: ConsensusConfig) -> Self {
        Self { config }
    }

    /// True if `hash_hex` has at least `difficulty` leading '0' ASCII chars.
    pub fn is_block_hash_valid(hash_hex: &str, difficulty: u32) -> bool {
        if hash_hex.is_empty() {
            return false;
        }
        let zeros = hash_hex.bytes().take_while(|&b| b == b'0').count() as u32;
        zeros >= difficulty
    }

    /// Validate the block's cached hash satisfies the difficulty target.
    pub fn validate_block_pow(block: &Block, difficulty: u32) -> bool {
        Self::is_block_hash_valid(&block.hash, difficulty)
    }
}

// ─── Difficulty retarget (port of consensus_params.zig::retargetDifficulty) ─

/// Bitcoin-style retarget clamped to ±4× and `[MIN_DIFFICULTY, MAX_DIFFICULTY]`.
/// `actual_time_s` is the wall-clock seconds elapsed across the last
/// `RETARGET_INTERVAL` blocks.
pub fn retarget_difficulty(old_difficulty: u32, actual_time_s: i64) -> u32 {
    if actual_time_s <= 0 {
        return old_difficulty;
    }
    // Clamp to [target/4, target*4].
    let lo = TARGET_INTERVAL_S / 4;
    let hi = TARGET_INTERVAL_S * 4;
    let clamped = actual_time_s.max(lo).min(hi);

    let old = old_difficulty as i64;
    let new_diff = (old * TARGET_INTERVAL_S) / clamped;

    if new_diff < MIN_DIFFICULTY as i64 {
        MIN_DIFFICULTY
    } else if new_diff > MAX_DIFFICULTY as i64 {
        MAX_DIFFICULTY
    } else {
        new_diff as u32
    }
}

/// Per-block PoW "work" — used by the heaviest-chain rule.
/// `work = 1 << (4 * difficulty)`, capped at the u128 ceiling.
pub fn block_work(difficulty: u32) -> u128 {
    if difficulty == 0 {
        return 1;
    }
    let shift = (difficulty.saturating_mul(4)).min(127) as u32;
    1u128 << shift
}

/// Block reward at a given height, applying the halving schedule.
/// Matches Zig `blockRewardAt`: reward = `BLOCK_REWARD_SAT >> halvings`,
/// zero after 64 halvings.
pub fn block_reward_at(height: u64) -> u64 {
    let halvings = height / HALVING_INTERVAL;
    if halvings >= 64 {
        return 0;
    }
    BLOCK_REWARD_SAT >> halvings
}
