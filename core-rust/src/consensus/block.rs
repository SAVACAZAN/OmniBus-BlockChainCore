//! Block + transaction structs.
//!
//! Hash formula is byte-for-byte identical to `core/block.zig::Block.calculateHash`:
//!
//! ```text
//! sha256(
//!     ascii("{index}{timestamp}{previous_hash}{nonce}")  // %d %d %s %d
//!  || merkle_root      (32 bytes)
//!  || prices_root      (32 bytes)
//! )
//! ```
//!
//! `previous_hash` is the **hex string** of the parent block hash (as that's
//! what the Zig code stores in the field and what `bufPrint("{s}")` emits).
//! Genesis uses 64 ASCII '0' characters.

use sha2::{Digest, Sha256};

use super::MAX_BLOCK_TX;

/// Minimal native-chain transaction. Field layout + canonical hash will be
/// finalised by the storage agent — leave room for those bytes here so
/// callers can already build/serialize blocks.
///
/// TODO(storage-agent): replace `signature` / `payload` with the canonical
/// TX struct from `core/transaction.zig` (sender, recipient, amount, nonce,
/// fee, scheme tag, signature, optional payload). For now this is a thin
/// stand-in so `Block` compiles and Merkle-roots TXs by their pre-computed
/// 32-byte hash.
#[derive(Debug, Clone, Default)]
pub struct Tx {
    /// Canonical 32-byte TX hash. Computed by the (future) TX module.
    pub hash: [u8; 32],
    /// Sender address (bech32 ascii, e.g. "ob1q...").
    pub from_address: String,
    /// Recipient address.
    pub to_address: String,
    /// Amount in SAT.
    pub amount: u64,
    /// Fee in SAT.
    pub fee: u64,
    /// Sender nonce (monotonic per sender).
    pub nonce: u64,
    /// Unix-ms timestamp.
    pub timestamp_ms: i64,
    /// Raw signature bytes (scheme-tagged; see TODO above).
    pub signature: Vec<u8>,
}

impl Tx {
    /// Return the canonical TX hash. Until the TX module lands, callers
    /// MUST populate `self.hash` themselves (e.g. via the storage layer).
    pub fn hash(&self) -> [u8; 32] {
        self.hash
    }
}

/// Block header + body.
///
/// Mirrors `core/block.zig::Block`. Fields that don't participate in the
/// canonical hash (miner_address, reward_sat, fills, …) are kept here
/// because P2P and storage need them, but only `index`, `timestamp`,
/// `previous_hash`, `nonce`, `merkle_root`, `prices_root` enter
/// `calculate_hash`.
#[derive(Debug, Clone)]
pub struct Block {
    pub index: u32,
    pub timestamp: i64,
    pub transactions: Vec<Tx>,
    /// Parent hash as 64-char lowercase hex (same as Zig's `[]const u8`).
    pub previous_hash: String,
    pub nonce: u64,
    /// Cached SHA-256 of this block, hex-encoded (lowercase, 64 chars).
    pub hash: String,
    /// Merkle root over `transactions[*].hash()`.
    pub merkle_root: [u8; 32],

    pub miner_address: String,
    pub reward_sat: u64,

    /// Oracle price commitment (32-byte SHA-256, zero = no prices recorded).
    /// The raw 21-slot snapshot is stored elsewhere; this is the on-chain
    /// commitment that participates in the block hash.
    pub prices_root: [u8; 32],

    /// Fills commitment — see `core/block.zig::computeFillsRoot`. Does NOT
    /// enter `calculate_hash` in the Zig impl (only `merkle_root` and
    /// `prices_root` do), so we keep it for storage but don't hash it.
    pub fills_root: [u8; 32],
}

impl Block {
    /// Empty block scaffold — caller still has to set transactions, mining
    /// metadata and call `recompute_roots` + `calculate_hash`.
    pub fn new(index: u32, previous_hash: String, timestamp: i64) -> Self {
        Self {
            index,
            timestamp,
            transactions: Vec::new(),
            previous_hash,
            nonce: 0,
            hash: String::new(),
            merkle_root: [0u8; 32],
            miner_address: String::new(),
            reward_sat: 0,
            prices_root: [0u8; 32],
            fills_root: [0u8; 32],
        }
    }

    /// Canonical block hash (raw 32 bytes). Identical to Zig
    /// `Block.calculateHash` — see module-level doc.
    pub fn calculate_hash(&self) -> [u8; 32] {
        let header_str = format!(
            "{}{}{}{}",
            self.index, self.timestamp, self.previous_hash, self.nonce,
        );
        let mut hasher = Sha256::new();
        hasher.update(header_str.as_bytes());
        hasher.update(&self.merkle_root);
        hasher.update(&self.prices_root);
        let out = hasher.finalize();
        let mut h = [0u8; 32];
        h.copy_from_slice(&out);
        h
    }

    /// Hex-encoded canonical hash (lowercase, 64 chars).
    pub fn calculate_hash_hex(&self) -> String {
        hex::encode(self.calculate_hash())
    }

    /// Binary Merkle root over TX hashes (Bitcoin-style, duplicate-last on odd).
    /// Empty TX list → all-zero root (matches Zig).
    pub fn calculate_merkle_root(&self) -> [u8; 32] {
        let tx_count = self.transactions.len().min(MAX_BLOCK_TX);
        if tx_count == 0 {
            return [0u8; 32];
        }

        let mut layer: Vec<[u8; 32]> = self
            .transactions
            .iter()
            .take(tx_count)
            .map(|t| t.hash())
            .collect();

        while layer.len() > 1 {
            let next_count = (layer.len() + 1) / 2;
            let mut next: Vec<[u8; 32]> = Vec::with_capacity(next_count);
            for i in 0..next_count {
                let left = i * 2;
                let right = if left + 1 < layer.len() { left + 1 } else { left };
                let mut hasher = Sha256::new();
                hasher.update(&layer[left]);
                hasher.update(&layer[right]);
                let mut h = [0u8; 32];
                h.copy_from_slice(&hasher.finalize());
                next.push(h);
            }
            layer = next;
        }
        layer[0]
    }

    /// Recompute and store the Merkle root. Call before `calculate_hash`.
    pub fn recompute_merkle(&mut self) {
        self.merkle_root = self.calculate_merkle_root();
    }
}

// ─── SubBlock + KeyBlock (re-exports for ergonomic use) ─────────────────────

pub use super::sub_block::{KeyBlock, SubBlock, SUB_BLOCKS_PER_BLOCK, SUB_BLOCK_INTERVAL_MS};
