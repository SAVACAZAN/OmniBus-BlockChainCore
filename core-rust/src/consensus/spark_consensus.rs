//! SPARK Sub-Block Consensus — port of `core/spark_consensus.zig`.
//!
//! 10-layer parallel validation. Each layer produces an ATTEST/REJECT vote.
//! 6/10 ATTEST = high trust, 5/10 = low, <5 = rejected.
//!
//! This port covers the deterministic consensus-critical core:
//!   - Validation layer enum + vote types
//!   - BlockConsensusState with vote upsert + trust computation
//!   - Global ring buffer for RPC queries (`record_state` / `last_state` /
//!     `find_by_hash`)
//!   - `LayerValidator` trait so callers wire chain-specific validation
//!     without dragging chain types into this file (Zig used `anytype`).
//!
//! The per-layer validator implementations in Zig depend on the full Chain
//! module which has a different shape on the Rust side; the Rust node will
//! wire them by implementing `LayerValidator` for its block + state types.

use std::sync::Mutex;

// ─── Public types ────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum ValidationLayer {
    TxWellFormed = 1,
    UtxoExistence = 2,
    NoDoubleSpend = 3,
    SignatureVerify = 4,
    NonceMonotonic = 5,
    BalanceConstraint = 6,
    ContractState = 7,
    CrossShard = 8,
    Reputation = 9,
    MerkleCommit = 10,
}

impl ValidationLayer {
    pub const ALL: [ValidationLayer; 10] = [
        ValidationLayer::TxWellFormed,
        ValidationLayer::UtxoExistence,
        ValidationLayer::NoDoubleSpend,
        ValidationLayer::SignatureVerify,
        ValidationLayer::NonceMonotonic,
        ValidationLayer::BalanceConstraint,
        ValidationLayer::ContractState,
        ValidationLayer::CrossShard,
        ValidationLayer::Reputation,
        ValidationLayer::MerkleCommit,
    ];

    pub fn idx(self) -> usize {
        (self as u8 as usize) - 1
    }

    pub fn as_str(self) -> &'static str {
        match self {
            ValidationLayer::TxWellFormed => "tx_well_formed",
            ValidationLayer::UtxoExistence => "utxo_existence",
            ValidationLayer::NoDoubleSpend => "no_double_spend",
            ValidationLayer::SignatureVerify => "signature_verify",
            ValidationLayer::NonceMonotonic => "nonce_monotonic",
            ValidationLayer::BalanceConstraint => "balance_constraint",
            ValidationLayer::ContractState => "contract_state",
            ValidationLayer::CrossShard => "cross_shard",
            ValidationLayer::Reputation => "reputation",
            ValidationLayer::MerkleCommit => "merkle_commit",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum VoteKind { Attest, Reject }

impl VoteKind {
    pub fn as_str(self) -> &'static str {
        match self {
            VoteKind::Attest => "attest",
            VoteKind::Reject => "reject",
        }
    }
}

#[derive(Debug, Clone, Copy)]
pub struct ValidationVote {
    pub layer: ValidationLayer,
    pub kind: VoteKind,
    /// Validator address (first 20 bytes of OmniBus address).
    pub validator: [u8; 20],
    pub block_hash: [u8; 32],
    /// Reject reason in UTF-8, zero-padded. All zeros if kind == Attest.
    pub reason: [u8; 64],
}

impl ValidationVote {
    pub fn reason_str(&self) -> &str {
        let end = self.reason.iter().position(|&b| b == 0).unwrap_or(64);
        std::str::from_utf8(&self.reason[..end]).unwrap_or("")
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum TrustLevel {
    High,     // >= 6/10 ATTEST
    Low,      // == 5/10 ATTEST
    Rejected, // < 5/10 ATTEST
    Pending,  // votes not yet collected
}

impl TrustLevel {
    pub fn as_str(self) -> &'static str {
        match self {
            TrustLevel::High => "high",
            TrustLevel::Low => "low",
            TrustLevel::Rejected => "rejected",
            TrustLevel::Pending => "pending",
        }
    }
}

// ─── BlockConsensusState ─────────────────────────────────────────────────────

#[derive(Debug, Clone, Copy)]
pub struct BlockConsensusState {
    pub block_hash: [u8; 32],
    pub votes: [Option<ValidationVote>; 10],
    pub attest_count: u8,
    pub reject_count: u8,
    pub trust: TrustLevel,
}

impl BlockConsensusState {
    pub fn new(block_hash: [u8; 32]) -> Self {
        Self {
            block_hash,
            votes: [None; 10],
            attest_count: 0,
            reject_count: 0,
            trust: TrustLevel::Pending,
        }
    }

    /// Upsert a vote for its layer. First caller wins per layer (matches Zig).
    pub fn add_vote(&mut self, vote: ValidationVote) {
        let idx = vote.layer.idx();
        if idx >= 10 || self.votes[idx].is_some() {
            return;
        }
        self.votes[idx] = Some(vote);
        match vote.kind {
            VoteKind::Attest => self.attest_count += 1,
            VoteKind::Reject => self.reject_count += 1,
        }
    }

    /// Recompute trust from current attest counts and cache the result.
    pub fn compute_trust(&mut self) -> TrustLevel {
        self.trust = if self.attest_count >= 6 {
            TrustLevel::High
        } else if self.attest_count == 5 {
            TrustLevel::Low
        } else {
            TrustLevel::Rejected
        };
        self.trust
    }
}

// ─── Vote builders (mirror Zig `attest` / `reject` helpers) ──────────────────

pub fn attest(layer: ValidationLayer, validator: [u8; 20], block_hash: [u8; 32]) -> ValidationVote {
    ValidationVote {
        layer,
        kind: VoteKind::Attest,
        validator,
        block_hash,
        reason: [0u8; 64],
    }
}

pub fn reject(
    layer: ValidationLayer,
    validator: [u8; 20],
    block_hash: [u8; 32],
    reason: &str,
) -> ValidationVote {
    let mut r = [0u8; 64];
    let n = reason.as_bytes().len().min(64);
    r[..n].copy_from_slice(&reason.as_bytes()[..n]);
    ValidationVote {
        layer,
        kind: VoteKind::Reject,
        validator,
        block_hash,
        reason: r,
    }
}

// ─── LayerValidator trait (replaces Zig `anytype`) ───────────────────────────

/// Plug per-layer validation logic without coupling spark_consensus to the
/// Chain/Block types. Each implementation owns its block + state reference.
pub trait LayerValidator {
    fn run_layer(&self, layer: ValidationLayer, validator: [u8; 20], block_hash: [u8; 32]) -> ValidationVote;

    /// Default: run all 10 layers in order and return their votes.
    fn validate_block(&self, validator: [u8; 20], block_hash: [u8; 32]) -> [ValidationVote; 10] {
        let mut out = [attest(ValidationLayer::TxWellFormed, validator, block_hash); 10];
        for layer in ValidationLayer::ALL {
            out[layer.idx()] = self.run_layer(layer, validator, block_hash);
        }
        out
    }
}

// ─── Process-global history ring (for RPC) ───────────────────────────────────

pub const SPARK_HISTORY_DEPTH: usize = 64;

struct History {
    states: [Option<BlockConsensusState>; SPARK_HISTORY_DEPTH],
    head: usize,
    count: usize,
}

impl History {
    const fn new() -> Self {
        Self {
            states: [None; SPARK_HISTORY_DEPTH],
            head: 0,
            count: 0,
        }
    }
}

static HISTORY: Mutex<History> = Mutex::new(History::new());

/// Store a finalized BlockConsensusState for later RPC queries.
pub fn record_state(state: BlockConsensusState) {
    let mut h = HISTORY.lock().unwrap();
    let idx = h.head % SPARK_HISTORY_DEPTH;
    h.states[idx] = Some(state);
    h.head = h.head.wrapping_add(1);
    if h.count < SPARK_HISTORY_DEPTH {
        h.count += 1;
    }
}

/// Most recent recorded state, if any.
pub fn last_state() -> Option<BlockConsensusState> {
    let h = HISTORY.lock().unwrap();
    if h.count == 0 {
        return None;
    }
    let idx = (h.head + SPARK_HISTORY_DEPTH - 1) % SPARK_HISTORY_DEPTH;
    h.states[idx]
}

/// Find a stored state by block hash.
pub fn find_by_hash(block_hash: [u8; 32]) -> Option<BlockConsensusState> {
    let h = HISTORY.lock().unwrap();
    let depth = h.count.min(SPARK_HISTORY_DEPTH);
    for i in 0..depth {
        let idx = (h.head + SPARK_HISTORY_DEPTH - 1 - i) % SPARK_HISTORY_DEPTH;
        if let Some(s) = h.states[idx] {
            if s.block_hash == block_hash {
                return Some(s);
            }
        }
    }
    None
}

#[cfg(test)]
pub(crate) fn clear_history_for_test() {
    let mut h = HISTORY.lock().unwrap();
    *h = History::new();
}

// ─── Tests ───────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    fn test_validator() -> [u8; 20] {
        let mut v = [0u8; 20];
        v[0..4].copy_from_slice(&[0xDE, 0xAD, 0xBE, 0xEF]);
        v
    }

    fn test_block_hash() -> [u8; 32] {
        let mut h = [0u8; 32];
        h[0..4].copy_from_slice(&[0xCA, 0xFE, 0xBA, 0xBE]);
        h
    }

    #[test]
    fn init_pending_zero_counts() {
        let s = BlockConsensusState::new(test_block_hash());
        assert_eq!(s.trust, TrustLevel::Pending);
        assert_eq!(s.attest_count, 0);
        assert_eq!(s.reject_count, 0);
        for v in s.votes.iter() {
            assert!(v.is_none());
        }
    }

    #[test]
    fn six_attest_yields_high_trust() {
        let bh = test_block_hash();
        let val = test_validator();
        let mut s = BlockConsensusState::new(bh);
        for &layer in &[
            ValidationLayer::TxWellFormed,
            ValidationLayer::UtxoExistence,
            ValidationLayer::NoDoubleSpend,
            ValidationLayer::SignatureVerify,
            ValidationLayer::NonceMonotonic,
            ValidationLayer::BalanceConstraint,
        ] {
            s.add_vote(attest(layer, val, bh));
        }
        assert_eq!(s.attest_count, 6);
        assert_eq!(s.compute_trust(), TrustLevel::High);
    }

    #[test]
    fn five_attest_yields_low_trust() {
        let bh = test_block_hash();
        let val = test_validator();
        let mut s = BlockConsensusState::new(bh);
        for &layer in &[
            ValidationLayer::TxWellFormed,
            ValidationLayer::UtxoExistence,
            ValidationLayer::NoDoubleSpend,
            ValidationLayer::SignatureVerify,
            ValidationLayer::NonceMonotonic,
        ] {
            s.add_vote(attest(layer, val, bh));
        }
        assert_eq!(s.attest_count, 5);
        assert_eq!(s.compute_trust(), TrustLevel::Low);
    }

    #[test]
    fn four_attest_yields_rejected() {
        let bh = test_block_hash();
        let val = test_validator();
        let mut s = BlockConsensusState::new(bh);
        for &layer in &[
            ValidationLayer::TxWellFormed,
            ValidationLayer::UtxoExistence,
            ValidationLayer::NoDoubleSpend,
            ValidationLayer::SignatureVerify,
        ] {
            s.add_vote(attest(layer, val, bh));
        }
        assert_eq!(s.attest_count, 4);
        assert_eq!(s.compute_trust(), TrustLevel::Rejected);
    }

    #[test]
    fn vote_first_caller_wins() {
        let bh = test_block_hash();
        let val = test_validator();
        let mut s = BlockConsensusState::new(bh);
        s.add_vote(attest(ValidationLayer::TxWellFormed, val, bh));
        s.add_vote(reject(ValidationLayer::TxWellFormed, val, bh, "late vote"));
        assert_eq!(s.attest_count, 1);
        assert_eq!(s.reject_count, 0);
    }

    #[test]
    fn reject_reason_is_stored() {
        let val = test_validator();
        let bh = test_block_hash();
        let v = reject(ValidationLayer::SignatureVerify, val, bh, "bad sig");
        assert_eq!(v.reason_str(), "bad sig");
    }

    // The history ring is process-global. Tests below use unique hashes
    // and assert find_by_hash rather than counts, so they're safe to run
    // in parallel without locking the entire history map.

    #[test]
    fn history_record_and_last_for_unique_hash() {
        let mut bh = [0u8; 32];
        bh[0..8].copy_from_slice(&[0xA1, 0xA2, 0xA3, 0xA4, 0xA5, 0xA6, 0xA7, 0xA8]);
        let s = BlockConsensusState::new(bh);
        record_state(s);
        // last_state may have been overwritten by a parallel test, but
        // find_by_hash with our unique key must still locate ours.
        let got = find_by_hash(bh).expect("must find recorded state");
        assert_eq!(got.block_hash, bh);
    }

    #[test]
    fn history_find_by_hash_distinct_keys() {
        let mut h1 = [0u8; 32];
        h1[0..8].copy_from_slice(&[0xB1, 0xB2, 0xB3, 0xB4, 0xB5, 0xB6, 0xB7, 0xB8]);
        let mut h2 = [0u8; 32];
        h2[0..8].copy_from_slice(&[0xC1, 0xC2, 0xC3, 0xC4, 0xC5, 0xC6, 0xC7, 0xC8]);
        record_state(BlockConsensusState::new(h1));
        record_state(BlockConsensusState::new(h2));
        assert_eq!(find_by_hash(h1).unwrap().block_hash, h1);
        assert_eq!(find_by_hash(h2).unwrap().block_hash, h2);
    }

    struct AlwaysAttest;
    impl LayerValidator for AlwaysAttest {
        fn run_layer(&self, layer: ValidationLayer, val: [u8; 20], bh: [u8; 32]) -> ValidationVote {
            attest(layer, val, bh)
        }
    }

    #[test]
    fn layer_validator_runs_all_ten() {
        let v = AlwaysAttest;
        let votes = v.validate_block(test_validator(), test_block_hash());
        let mut s = BlockConsensusState::new(test_block_hash());
        for vote in votes {
            s.add_vote(vote);
        }
        assert_eq!(s.attest_count, 10);
        assert_eq!(s.compute_trust(), TrustLevel::High);
    }
}
