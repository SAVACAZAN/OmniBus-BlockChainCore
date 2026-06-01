//! Guardian — block validation gate.
//!
//! Two-layer port of the Zig `core/guardian.zig`:
//!
//! 1. **BlockGuardian** — gates incoming blocks before consensus. Cheap
//!    structural checks (size, tx count, header sanity) so we drop garbage
//!    before paying the cost of full verification. This is the layer the
//!    task brief asks for ("validates incoming blocks before consensus").
//!
//! 2. **AccountGuardian** — on-chain 2FA registry (EGLD-style). Each account
//!    can set a co-signer required for state-changing TXs. Mirrors the
//!    Zig `GuardianEngine` — kept here so the consensus layer can wire it
//!    into TX validation alongside the block-level gate.

use std::collections::HashMap;
use thiserror::Error;

use crate::consensus::{MAX_BLOCK_SIZE, MAX_BLOCK_TX};

// ──────────────────────────────────────────────────────────────────────────
// Layer 1 — BlockGuardian (pre-consensus structural gate)
// ──────────────────────────────────────────────────────────────────────────

#[derive(Debug, Error)]
pub enum BlockRejection {
    #[error("block byte size {got} exceeds MAX_BLOCK_SIZE ({MAX_BLOCK_SIZE})")]
    TooLarge { got: usize },
    #[error("block tx count {got} exceeds MAX_BLOCK_TX ({MAX_BLOCK_TX})")]
    TooManyTx { got: usize },
    #[error("block has no transactions (not even coinbase)")]
    NoTransactions,
    #[error("block hash is empty / malformed")]
    InvalidHash,
    #[error("previous_hash is empty / malformed")]
    InvalidPrevHash,
    #[error("block timestamp {ts} is more than {skew_s}s ahead of local clock")]
    TimestampInFuture { ts: i64, skew_s: i64 },
}

/// Maximum tolerated clock skew between peers, in seconds. Matches the
/// Zig node's 2-minute window (relaxed compared to Bitcoin's 2h to keep
/// 1s block time meaningful).
pub const MAX_FUTURE_SKEW_S: i64 = 120;

/// Minimal block view the guardian inspects. The consensus layer adapts its
/// real `Block` into this; we deliberately keep it small so the guardian is
/// reusable across block-formats (compact, full, witness).
#[derive(Debug, Clone, Copy)]
pub struct BlockView<'a> {
    pub index: u64,
    pub timestamp: i64,
    pub previous_hash: &'a str,
    pub hash: &'a str,
    pub tx_count: usize,
    pub byte_size: usize,
}

pub struct BlockGuardian;

impl BlockGuardian {
    /// Validate a block before consensus. Cheap checks only.
    pub fn validate(view: &BlockView<'_>, now_s: i64) -> Result<(), BlockRejection> {
        if view.byte_size > MAX_BLOCK_SIZE {
            return Err(BlockRejection::TooLarge { got: view.byte_size });
        }
        if view.tx_count > MAX_BLOCK_TX {
            return Err(BlockRejection::TooManyTx { got: view.tx_count });
        }
        // Genesis is index 0 with no txs; everything else must have ≥1 (coinbase).
        if view.index != 0 && view.tx_count == 0 {
            return Err(BlockRejection::NoTransactions);
        }
        if view.hash.is_empty() {
            return Err(BlockRejection::InvalidHash);
        }
        if view.index != 0 && view.previous_hash.is_empty() {
            return Err(BlockRejection::InvalidPrevHash);
        }
        if view.timestamp > now_s + MAX_FUTURE_SKEW_S {
            return Err(BlockRejection::TimestampInFuture {
                ts: view.timestamp,
                skew_s: MAX_FUTURE_SKEW_S,
            });
        }
        Ok(())
    }
}

// ──────────────────────────────────────────────────────────────────────────
// Layer 2 — AccountGuardian (on-chain 2FA, ported from Zig GuardianEngine)
// ──────────────────────────────────────────────────────────────────────────

/// Activation delay in blocks (~5.5h @ 1s blocks). Prevents instant hijack
/// of an account that just had its key leaked.
pub const GUARDIAN_ACTIVATION_DELAY: u64 = 20_000;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum GuardianStatus {
    Pending,
    Active,
    Removing,
    Removed,
}

#[derive(Debug, Clone)]
pub struct GuardianRecord {
    pub account: [u8; 32],
    /// Compressed secp256k1 pubkey (33 bytes).
    pub guardian_pubkey: [u8; 33],
    pub set_block: u64,
    pub active_block: u64,
    pub status: GuardianStatus,
}

impl GuardianRecord {
    pub fn is_active(&self, current_block: u64) -> bool {
        self.status == GuardianStatus::Active && current_block >= self.active_block
    }
}

#[derive(Debug, Error)]
pub enum GuardianError {
    #[error("account already has an active guardian")]
    AlreadyGuarded,
    #[error("no pending guardian for account")]
    NoPendingGuardian,
    #[error("activation delay not yet elapsed")]
    ActivationDelayNotMet,
    #[error("no guardian found for account")]
    NoGuardianFound,
}

#[derive(Default)]
pub struct AccountGuardian {
    records: HashMap<[u8; 32], GuardianRecord>,
}

impl AccountGuardian {
    pub fn new() -> Self { Self::default() }

    pub fn set_guardian(
        &mut self,
        account: [u8; 32],
        guardian_pubkey: [u8; 33],
        current_block: u64,
    ) -> Result<(), GuardianError> {
        if let Some(r) = self.records.get(&account) {
            if r.is_active(current_block) {
                return Err(GuardianError::AlreadyGuarded);
            }
        }
        let rec = GuardianRecord {
            account,
            guardian_pubkey,
            set_block: current_block,
            active_block: current_block + GUARDIAN_ACTIVATION_DELAY,
            status: GuardianStatus::Pending,
        };
        self.records.insert(account, rec);
        Ok(())
    }

    pub fn activate(&mut self, account: [u8; 32], current_block: u64) -> Result<(), GuardianError> {
        let r = self.records.get_mut(&account).ok_or(GuardianError::NoPendingGuardian)?;
        if r.status != GuardianStatus::Pending {
            return Err(GuardianError::NoPendingGuardian);
        }
        if current_block < r.active_block {
            return Err(GuardianError::ActivationDelayNotMet);
        }
        r.status = GuardianStatus::Active;
        Ok(())
    }

    pub fn remove(&mut self, account: [u8; 32]) -> Result<(), GuardianError> {
        let r = self.records.get_mut(&account).ok_or(GuardianError::NoGuardianFound)?;
        if r.status == GuardianStatus::Removed {
            return Err(GuardianError::NoGuardianFound);
        }
        r.status = GuardianStatus::Removed;
        Ok(())
    }

    pub fn active_guardian(&self, account: [u8; 32], current_block: u64) -> Option<[u8; 33]> {
        self.records
            .get(&account)
            .filter(|r| r.is_active(current_block))
            .map(|r| r.guardian_pubkey)
    }

    pub fn requires_guardian(&self, account: [u8; 32], current_block: u64) -> bool {
        self.active_guardian(account, current_block).is_some()
    }

    pub fn guarded_count(&self, current_block: u64) -> usize {
        self.records.values().filter(|r| r.is_active(current_block)).count()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn block_too_large_rejected() {
        let v = BlockView {
            index: 1, timestamp: 100, previous_hash: "prev", hash: "h",
            tx_count: 1, byte_size: MAX_BLOCK_SIZE + 1,
        };
        assert!(matches!(BlockGuardian::validate(&v, 1000), Err(BlockRejection::TooLarge { .. })));
    }

    #[test]
    fn block_too_many_tx_rejected() {
        let v = BlockView {
            index: 1, timestamp: 100, previous_hash: "prev", hash: "h",
            tx_count: MAX_BLOCK_TX + 1, byte_size: 1024,
        };
        assert!(matches!(BlockGuardian::validate(&v, 1000), Err(BlockRejection::TooManyTx { .. })));
    }

    #[test]
    fn block_future_timestamp_rejected() {
        let v = BlockView {
            index: 1, timestamp: 10_000, previous_hash: "prev", hash: "h",
            tx_count: 1, byte_size: 1024,
        };
        assert!(matches!(BlockGuardian::validate(&v, 100), Err(BlockRejection::TimestampInFuture { .. })));
    }

    #[test]
    fn block_genesis_no_tx_ok() {
        let v = BlockView {
            index: 0, timestamp: 0, previous_hash: "", hash: "genesis",
            tx_count: 0, byte_size: 256,
        };
        assert!(BlockGuardian::validate(&v, 1000).is_ok());
    }

    #[test]
    fn guardian_lifecycle() {
        let mut g = AccountGuardian::new();
        let acct = [0xAA_u8; 32];
        let mut pk = [0u8; 33];
        pk[0] = 0x02;
        g.set_guardian(acct, pk, 1000).unwrap();
        // before delay
        assert!(!g.requires_guardian(acct, 1000));
        // activate fails too early
        assert!(g.activate(acct, 1000).is_err());
        // activate after delay
        g.activate(acct, 1000 + GUARDIAN_ACTIVATION_DELAY).unwrap();
        assert!(g.requires_guardian(acct, 1000 + GUARDIAN_ACTIVATION_DELAY));
        // duplicate while active rejected
        assert!(g.set_guardian(acct, pk, 1000 + GUARDIAN_ACTIVATION_DELAY + 1).is_err());
        // remove
        g.remove(acct).unwrap();
        assert!(!g.requires_guardian(acct, 1000 + GUARDIAN_ACTIVATION_DELAY + 2));
    }
}
