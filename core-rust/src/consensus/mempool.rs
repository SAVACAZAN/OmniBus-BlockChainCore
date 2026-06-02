//! FIFO mempool — first-in-first-out anti-MEV ordering with size, byte,
//! fee, duplicate, and BIP-125 RBF gates. Port of `core/mempool.zig`.
//!
//! TODO(storage-agent): swap the canonical TX bytes/size estimator once
//! `Tx` gets its real serialization. The current estimator is a coarse
//! upper bound (text fields + signature length) so anti-spam still works.

use std::collections::HashMap;

use super::block::Tx;

pub const MEMPOOL_MAX_TX: usize = 10_000;
pub const MEMPOOL_MAX_BYTES: usize = 1_048_576; // 1 MB worth per block
pub const MEMPOOL_MAX_MEMORY: usize = 314_572_800; // 300 MB
pub const TX_MAX_BYTES: usize = 100_000;
pub const TX_MIN_FEE_SAT: u64 = 1;
/// Bitcoin Core: 14 days = 336 hours.
pub const MEMPOOL_EXPIRY_SEC: i64 = 14 * 24 * 3600;

#[derive(Debug, thiserror::Error)]
pub enum MempoolError {
    #[error("mempool full")]
    Full,
    #[error("tx too large")]
    TxTooLarge,
    #[error("tx invalid")]
    TxInvalid,
    #[error("tx duplicate")]
    TxDuplicate,
    #[error("fee too low")]
    FeeTooLow,
    #[error("bad signature")]
    BadSignature,
}

#[derive(Debug, Clone)]
pub struct MempoolEntry {
    pub tx: Tx,
    pub received_at: i64,
    pub fee_sat: u64,
    pub size_bytes: usize,
}

/// Optional verifier callback — RBF/HIGH-05 fix from Zig: signature is
/// re-verified on every `add`, including on the RBF replacement branch.
pub type TxVerifier = Box<dyn Fn(&Tx) -> bool + Send + Sync>;

pub struct Mempool {
    pub entries: Vec<MempoolEntry>,
    pub tx_hashes: HashMap<[u8; 32], ()>,
    pub total_bytes: usize,
    /// Pending TX count per sender (for nonce-gap detection).
    pub pending_count: HashMap<String, u64>,
    pub verifier: Option<TxVerifier>,
}

impl Mempool {
    pub fn new() -> Self {
        Self {
            entries: Vec::new(),
            tx_hashes: HashMap::new(),
            total_bytes: 0,
            pending_count: HashMap::new(),
            verifier: None,
        }
    }

    pub fn set_verifier(&mut self, v: TxVerifier) {
        self.verifier = Some(v);
    }

    pub fn len(&self) -> usize {
        self.entries.len()
    }

    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    /// Append a TX (FIFO). Mirrors `Mempool.add` in Zig.
    pub fn add(&mut self, tx: Tx) -> Result<(), MempoolError> {
        if self.entries.len() >= MEMPOOL_MAX_TX {
            return Err(MempoolError::Full);
        }
        let size = estimate_tx_size(&tx);
        if size > TX_MAX_BYTES {
            return Err(MempoolError::TxTooLarge);
        }
        if self.total_bytes + size > MEMPOOL_MAX_BYTES {
            return Err(MempoolError::Full);
        }
        if !is_tx_valid(&tx) {
            return Err(MempoolError::TxInvalid);
        }
        if tx.fee < TX_MIN_FEE_SAT {
            return Err(MempoolError::FeeTooLow);
        }
        if self.tx_hashes.contains_key(&tx.hash) {
            return Err(MempoolError::TxDuplicate);
        }
        if let Some(v) = &self.verifier {
            if !v(&tx) {
                return Err(MempoolError::BadSignature);
            }
        }

        // BIP-125 RBF: same (sender, nonce) slot — replace if new fee is strictly higher.
        let mut rbf_idx: Option<usize> = None;
        for (i, entry) in self.entries.iter().enumerate() {
            if entry.tx.from_address == tx.from_address && entry.tx.nonce == tx.nonce {
                if tx.fee > entry.tx.fee {
                    rbf_idx = Some(i);
                    break;
                } else {
                    return Err(MempoolError::FeeTooLow);
                }
            }
        }
        if let Some(i) = rbf_idx {
            let removed = self.entries.remove(i);
            self.total_bytes = self.total_bytes.saturating_sub(removed.size_bytes);
            self.tx_hashes.remove(&removed.tx.hash);
        }

        self.tx_hashes.insert(tx.hash, ());
        let count = self.pending_count.entry(tx.from_address.clone()).or_insert(0);
        *count += 1;
        self.total_bytes += size;
        self.entries.push(MempoolEntry {
            tx,
            received_at: now_unix_secs(),
            fee_sat: 0,
            size_bytes: size,
        });
        // Snapshot fee_sat after move.
        let last = self.entries.last_mut().unwrap();
        last.fee_sat = last.tx.fee;

        // WS event — NewTx into mempool. No-op if no broadcaster installed
        // (unit tests, `--mode evm`).
        crate::ws::try_broadcast(crate::ws::Event::NewTx {
            txid: hex::encode(last.tx.hash),
            from: last.tx.from_address.clone(),
            amount_sat: last.tx.amount,
        });
        Ok(())
    }

    /// Drop expired entries. Returns the number removed.
    pub fn expire(&mut self, now_secs: i64) -> usize {
        let before = self.entries.len();
        let cutoff = now_secs - MEMPOOL_EXPIRY_SEC;
        let mut kept = Vec::with_capacity(before);
        let mut new_bytes = 0usize;
        let mut new_hashes: HashMap<[u8; 32], ()> = HashMap::with_capacity(before);
        let mut new_counts: HashMap<String, u64> = HashMap::new();
        for e in self.entries.drain(..) {
            if e.received_at >= cutoff {
                new_bytes += e.size_bytes;
                new_hashes.insert(e.tx.hash, ());
                *new_counts.entry(e.tx.from_address.clone()).or_insert(0) += 1;
                kept.push(e);
            }
        }
        self.entries = kept;
        self.total_bytes = new_bytes;
        self.tx_hashes = new_hashes;
        self.pending_count = new_counts;
        before - self.entries.len()
    }

    /// Pop the first `n` entries in FIFO order. Used by the block producer.
    pub fn take_for_block(&mut self, n: usize) -> Vec<Tx> {
        let take = n.min(self.entries.len());
        let drained: Vec<_> = self.entries.drain(..take).collect();
        for e in &drained {
            self.total_bytes = self.total_bytes.saturating_sub(e.size_bytes);
            self.tx_hashes.remove(&e.tx.hash);
            if let Some(c) = self.pending_count.get_mut(&e.tx.from_address) {
                *c = c.saturating_sub(1);
            }
        }
        drained.into_iter().map(|e| e.tx).collect()
    }
}

impl Default for Mempool {
    fn default() -> Self {
        Self::new()
    }
}

fn estimate_tx_size(tx: &Tx) -> usize {
    // Coarse upper bound until the canonical encoder lands.
    // Sized to keep TX_MAX_BYTES meaningful as an anti-spam guard.
    tx.from_address.len()
        + tx.to_address.len()
        + tx.signature.len()
        + 8 * 4  // amount + fee + nonce + timestamp
        + 32      // hash
        + 16      // overhead
}

fn is_tx_valid(tx: &Tx) -> bool {
    !tx.from_address.is_empty()
        && !tx.to_address.is_empty()
        && tx.hash != [0u8; 32]
}

fn now_unix_secs() -> i64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}
