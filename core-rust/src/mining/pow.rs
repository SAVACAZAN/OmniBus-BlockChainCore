//! PoW primitives — SHA-256d (double-SHA-256) and nonce-grinding loop.
//!
//! OmniBus difficulty is expressed in **leading hex zeros** on the block-hash
//! hex string (same convention as Zig — see
//! `core/consensus.zig::ConsensusEngine.isBlockHashValid` and the Rust port
//! in `consensus::consensus::ConsensusEngine::is_block_hash_valid`).
//!
//! Hash formula matches `core/block.zig::Block.calculateHash`:
//!
//! ```text
//! sha256( ascii("{index}{timestamp}{previous_hash}{nonce}")
//!         || merkle_root
//!         || prices_root )
//! ```
//!
//! Bitcoin-style SHA-256d (`sha256(sha256(x))`) is also exposed for callers
//! that need it (Stratum, future BTC-merge-mine, etc.). The chain itself
//! uses single SHA-256 on the canonical header — `sha256d` is provided as
//! a helper, not the chain hash.

use sha2::{Digest, Sha256};

use crate::consensus::block::Block;
use crate::consensus::consensus::ConsensusEngine;

/// Outcome of [`mine_block_nonce`].
#[derive(Debug, Clone)]
pub struct MineOutcome {
    /// Nonce that satisfied the target.
    pub nonce: u64,
    /// Final block hash (raw 32 bytes).
    pub hash: [u8; 32],
    /// Final block hash hex (lowercase, 64 chars).
    pub hash_hex: String,
    /// Hashes attempted before success.
    pub attempts: u64,
}

/// Bitcoin-style double SHA-256.
pub fn sha256d(data: &[u8]) -> [u8; 32] {
    let mut h = Sha256::new();
    h.update(data);
    let first = h.finalize();
    let mut h2 = Sha256::new();
    h2.update(&first);
    let mut out = [0u8; 32];
    out.copy_from_slice(&h2.finalize());
    out
}

/// Single-SHA-256 header hash — same as `Block::calculate_hash`. Provided as
/// a stand-alone helper so the engine can recompute hashes inside the
/// nonce-grinding inner loop without round-tripping through `Block`.
#[inline]
pub fn hash_pow(
    index: u32,
    timestamp: i64,
    previous_hash: &str,
    nonce: u64,
    merkle_root: &[u8; 32],
    prices_root: &[u8; 32],
) -> [u8; 32] {
    let header = format!("{}{}{}{}", index, timestamp, previous_hash, nonce);
    let mut h = Sha256::new();
    h.update(header.as_bytes());
    h.update(merkle_root);
    h.update(prices_root);
    let mut out = [0u8; 32];
    out.copy_from_slice(&h.finalize());
    out
}

/// Brute-force nonce search until the block-hash hex has at least
/// `difficulty` leading '0' ASCII chars. Single-threaded — the engine
/// fans this out across worker threads via `tokio::task::spawn_blocking`.
///
/// `nonce_start` lets workers stride: thread `i` of `n` calls
/// `mine_block_nonce(block, difficulty, i, n, max_attempts)`.
pub fn mine_block_nonce(
    block: &mut Block,
    difficulty: u32,
    nonce_start: u64,
    nonce_stride: u64,
    max_attempts: u64,
) -> Option<MineOutcome> {
    let stride = nonce_stride.max(1);
    let mut nonce = nonce_start;
    let mut attempts: u64 = 0;
    while attempts < max_attempts {
        let h = hash_pow(
            block.index,
            block.timestamp,
            &block.previous_hash,
            nonce,
            &block.merkle_root,
            &block.prices_root,
        );
        let hex_hash = hex::encode(h);
        if ConsensusEngine::is_block_hash_valid(&hex_hash, difficulty) {
            block.nonce = nonce;
            block.hash = hex_hash.clone();
            return Some(MineOutcome {
                nonce,
                hash: h,
                hash_hex: hex_hash,
                attempts: attempts + 1,
            });
        }
        nonce = nonce.wrapping_add(stride);
        attempts += 1;
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn difficulty_1_easy() {
        // difficulty=1 — first hex char must be '0' (one-in-16 chance per nonce).
        let mut b = Block::new(1, "0".repeat(64), 1_700_000_000);
        let r = mine_block_nonce(&mut b, 1, 0, 1, 10_000);
        assert!(r.is_some(), "should mine difficulty=1 quickly");
        let out = r.unwrap();
        assert!(out.hash_hex.starts_with('0'));
        assert_eq!(b.hash, out.hash_hex);
        assert_eq!(b.nonce, out.nonce);
    }

    #[test]
    fn sha256d_matches_double_sha() {
        let a = sha256d(b"hello");
        // Pre-computed: sha256(sha256("hello")) =
        // 9595c9df90075148eb06860365df33584b75bff782a510c6cd4883a419833d50
        assert_eq!(
            hex::encode(a),
            "9595c9df90075148eb06860365df33584b75bff782a510c6cd4883a419833d50"
        );
    }

    #[test]
    fn stride_split_finds_same_hash() {
        // Two workers cover the same nonce space; at least one finds difficulty=1.
        let mut b1 = Block::new(2, "0".repeat(64), 1_700_000_001);
        let mut b2 = Block::new(2, "0".repeat(64), 1_700_000_001);
        let r1 = mine_block_nonce(&mut b1, 1, 0, 2, 10_000);
        let r2 = mine_block_nonce(&mut b2, 1, 1, 2, 10_000);
        assert!(r1.is_some() || r2.is_some());
    }
}
