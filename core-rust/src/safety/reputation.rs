//! Address reputation: a single 0..1000 score per address.
//!
//! Default = 500 (neutral). Score is folded from positive + negative
//! signals (see [`ReputationEvent`]). Persisted in sled tree
//! `safety/reputation` as a 4-byte BE u32 (so it's easy to index).
//!
//! NOT to be confused with the 4-cup "reputation economy" in
//! BlockChainCore (LOVE/FOOD/RENT/VACATION) — this score is a *safety*
//! signal for the tx-guard, not a validator/economic standing.

use serde::{Deserialize, Serialize};
use sled::{Db, Tree};
use thiserror::Error;

pub const DEFAULT_SCORE: u32 = 500;
pub const MIN_SCORE: u32 = 0;
pub const MAX_SCORE: u32 = 1000;

#[derive(Debug, Error)]
pub enum ReputationError {
    #[error("sled error: {0}")]
    Sled(#[from] sled::Error),
}

/// Canonical reputation-affecting signals. Deltas are applied at score
/// arithmetic; callers feed these in via `bump`/`bulk_update_after_block`.
#[derive(Debug, Clone, Copy, Serialize, Deserialize)]
pub enum ReputationEvent {
    /// Sender → flagged address. -50 to sender.
    SentToFlagged,
    /// Receiver ← flagged sender. -20 to receiver.
    ReceivedFromFlagged,
    /// KYC approval (kyc_setStatus = Approved). +100 one-time.
    KycApproved,
    /// 30-day passive accumulation for held + active balance. +5/month.
    HoldingActive,
    /// Validator uptime ≥99% for a month. +10/month.
    ValidatorHighUptime,
    /// User's evidence led to a confirmed flag. +50.
    SuccessfulReport,
    /// Tier ladder upgrade (T2/T3/T4). +25 each.
    TierUpgrade,
    /// One-year inactivity decay. -1.
    InactivityDecay,
}

impl ReputationEvent {
    pub fn delta(self) -> i32 {
        match self {
            ReputationEvent::SentToFlagged => -50,
            ReputationEvent::ReceivedFromFlagged => -20,
            ReputationEvent::KycApproved => 100,
            ReputationEvent::HoldingActive => 5,
            ReputationEvent::ValidatorHighUptime => 10,
            ReputationEvent::SuccessfulReport => 50,
            ReputationEvent::TierUpgrade => 25,
            ReputationEvent::InactivityDecay => -1,
        }
    }
}

#[derive(Clone)]
pub struct ReputationStore {
    tree: Tree,
}

impl ReputationStore {
    pub fn open(db: &Db) -> Result<Self, ReputationError> {
        let tree = db.open_tree("safety/reputation")?;
        Ok(Self { tree })
    }

    pub fn score(&self, addr: &[u8; 20]) -> Result<u32, ReputationError> {
        match self.tree.get(addr)? {
            Some(b) if b.len() == 4 => {
                let mut a = [0u8; 4];
                a.copy_from_slice(&b);
                Ok(u32::from_be_bytes(a))
            }
            _ => Ok(DEFAULT_SCORE),
        }
    }

    pub fn set_score(&self, addr: &[u8; 20], score: u32) -> Result<(), ReputationError> {
        let v = score.clamp(MIN_SCORE, MAX_SCORE);
        self.tree.insert(addr, &v.to_be_bytes())?;
        Ok(())
    }

    /// Apply a signed delta to the score and persist it.
    /// Returns the new score.
    pub fn bump(
        &self,
        addr: &[u8; 20],
        delta: i32,
        _reason: ReputationEvent,
    ) -> Result<u32, ReputationError> {
        let cur = self.score(addr)? as i64;
        let new = (cur + delta as i64).clamp(MIN_SCORE as i64, MAX_SCORE as i64) as u32;
        self.set_score(addr, new)?;
        Ok(new)
    }

    /// Batch apply a per-block event list. Intended to be called from
    /// `block_exec::apply_block` after txs settle.
    pub fn bulk_update_after_block(
        &self,
        events: &[([u8; 20], ReputationEvent)],
    ) -> Result<(), ReputationError> {
        for (addr, ev) in events {
            self.bump(addr, ev.delta(), *ev)?;
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn open() -> (sled::Db, ReputationStore) {
        let db = sled::Config::new().temporary(true).open().unwrap();
        let s = ReputationStore::open(&db).unwrap();
        (db, s)
    }

    #[test]
    fn default_is_500() {
        let (_db, s) = open();
        assert_eq!(s.score(&[0u8; 20]).unwrap(), DEFAULT_SCORE);
    }

    #[test]
    fn bump_clamps() {
        let (_db, s) = open();
        let a = [0x77u8; 20];
        s.set_score(&a, 990).unwrap();
        s.bump(&a, 100, ReputationEvent::KycApproved).unwrap();
        assert_eq!(s.score(&a).unwrap(), MAX_SCORE);
        s.set_score(&a, 10).unwrap();
        s.bump(&a, -50, ReputationEvent::SentToFlagged).unwrap();
        assert_eq!(s.score(&a).unwrap(), MIN_SCORE);
    }

    #[test]
    fn bulk_applies_events() {
        let (_db, s) = open();
        let a = [1u8; 20];
        let b = [2u8; 20];
        s.bulk_update_after_block(&[
            (a, ReputationEvent::KycApproved),
            (b, ReputationEvent::SentToFlagged),
        ])
        .unwrap();
        assert_eq!(s.score(&a).unwrap(), DEFAULT_SCORE + 100);
        assert_eq!(s.score(&b).unwrap(), DEFAULT_SCORE - 50);
    }
}
