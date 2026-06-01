//! Per-shard blockchain — stripped-down sibling of `core/blockchain_v2.zig`.
//!
//! One Subchain instance per shard, owned by [`super::metachain::Metachain`].
//! Each Subchain holds an independent chain of [`SubchainBlock`]s plus a
//! local mempool of opaque TX payloads. Hash format here is intentionally a
//! placeholder SHA-256 — when the full P2P/consensus layer adopts this
//! module, it should plug in the canonical `consensus::block` hash routine
//! so subchain hashes feed the metachain identically to the Zig node.

use sha2::{Digest, Sha256};

/// A block on one shard's chain.
#[derive(Debug, Clone)]
pub struct SubchainBlock {
    pub shard_id: u8,
    pub index: u64,
    pub timestamp: i64,
    pub previous_hash: [u8; 32],
    pub hash: [u8; 32],
    /// Opaque encoded TXs — the per-shard ledger logic is the same as the
    /// Zig `blockchain_v2.zig`; we keep payloads opaque here so this file
    /// stays consensus-protocol-agnostic.
    pub tx_blobs: Vec<Vec<u8>>,
    pub tx_count: u32,
}

impl SubchainBlock {
    pub fn genesis(shard_id: u8) -> Self {
        // Same convention as Zig BlockchainV2: genesis is index 0, prev = 0×32.
        let mut g = Self {
            shard_id,
            index: 0,
            timestamp: 0,
            previous_hash: [0u8; 32],
            hash: [0u8; 32],
            tx_blobs: Vec::new(),
            tx_count: 0,
        };
        g.hash = g.compute_hash();
        g
    }

    pub fn compute_hash(&self) -> [u8; 32] {
        let mut h = Sha256::new();
        h.update([self.shard_id]);
        h.update(self.index.to_le_bytes());
        h.update(self.timestamp.to_le_bytes());
        h.update(self.previous_hash);
        h.update(self.tx_count.to_le_bytes());
        for blob in &self.tx_blobs {
            h.update(blob);
        }
        let d = h.finalize();
        let mut out = [0u8; 32];
        out.copy_from_slice(&d);
        out
    }
}

pub struct Subchain {
    pub shard_id: u8,
    pub chain: Vec<SubchainBlock>,
    pub mempool: Vec<Vec<u8>>,
}

impl Subchain {
    pub fn new(shard_id: u8) -> Self {
        let genesis = SubchainBlock::genesis(shard_id);
        Self { shard_id, chain: vec![genesis], mempool: Vec::new() }
    }

    pub fn height(&self) -> u64 {
        (self.chain.len() - 1) as u64
    }

    pub fn latest_hash(&self) -> [u8; 32] {
        self.chain.last().expect("genesis always present").hash
    }

    /// Push a TX blob into the mempool. Validation lives at the
    /// consensus layer — this is a thin local pool.
    pub fn submit_tx(&mut self, blob: Vec<u8>) {
        self.mempool.push(blob);
    }

    /// Produce the next block from the current mempool. `now_s` is provided
    /// by the caller (deterministic during replay).
    pub fn produce_block(&mut self, now_s: i64) -> &SubchainBlock {
        let prev = self.latest_hash();
        let index = self.chain.len() as u64;
        let txs: Vec<Vec<u8>> = std::mem::take(&mut self.mempool);
        let tx_count = txs.len() as u32;
        let mut blk = SubchainBlock {
            shard_id: self.shard_id,
            index,
            timestamp: now_s,
            previous_hash: prev,
            hash: [0u8; 32],
            tx_blobs: txs,
            tx_count,
        };
        blk.hash = blk.compute_hash();
        self.chain.push(blk);
        self.chain.last().unwrap()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn subchain_starts_at_genesis() {
        let sc = Subchain::new(2);
        assert_eq!(sc.height(), 0);
        assert_eq!(sc.chain[0].shard_id, 2);
    }

    #[test]
    fn produce_block_advances_height() {
        let mut sc = Subchain::new(0);
        sc.submit_tx(b"hello".to_vec());
        let blk = sc.produce_block(100).clone();
        assert_eq!(sc.height(), 1);
        assert_eq!(blk.tx_count, 1);
        assert_ne!(blk.hash, [0u8; 32]);
    }

    #[test]
    fn hashes_chain_correctly() {
        let mut sc = Subchain::new(1);
        let g_hash = sc.chain[0].hash;
        sc.produce_block(1);
        assert_eq!(sc.chain[1].previous_hash, g_hash);
    }
}
