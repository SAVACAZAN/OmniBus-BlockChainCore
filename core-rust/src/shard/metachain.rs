//! Metachain — port of `core/metachain.zig`. EGLD-style coordinator that
//! aggregates ShardBlockHeaders + cross-shard receipts into MetaBlocks.

use sha2::{Digest, Sha256};

use super::coordinator::ShardCoordinator;
use super::subchain::Subchain;

#[derive(Debug, Clone)]
pub struct ShardBlockHeader {
    pub shard_id: u8,
    pub block_height: u64,
    pub block_hash: [u8; 32],
    pub tx_count: u32,
    pub timestamp: i64,
    pub miner: String,
    pub reward_sat: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum CrossShardPhase {
    Phase1Debit = 1,
    Phase2Credit = 2,
    Finalized = 3,
}

#[derive(Debug, Clone)]
pub struct CrossShardReceipt {
    pub tx_hash: [u8; 32],
    pub from_shard: u8,
    pub to_shard: u8,
    pub from_address: String,
    pub to_address: String,
    pub amount_sat: u64,
    pub phase: CrossShardPhase,
    pub meta_height: u64,
}

#[derive(Debug, Clone)]
pub struct MetaBlock {
    pub height: u64,
    pub timestamp: i64,
    pub previous_hash: [u8; 32],
    pub hash: [u8; 32],
    pub shard_headers: Vec<ShardBlockHeader>,
    pub cross_receipts: Vec<CrossShardReceipt>,
    pub total_tx_count: u64,
    pub active_shards: u8,
}

impl MetaBlock {
    pub fn new(height: u64, prev_hash: [u8; 32], timestamp: i64) -> Self {
        Self {
            height,
            timestamp,
            previous_hash: prev_hash,
            hash: [0u8; 32],
            shard_headers: Vec::new(),
            cross_receipts: Vec::new(),
            total_tx_count: 0,
            active_shards: 0,
        }
    }

    pub fn add_shard_header(&mut self, hdr: ShardBlockHeader) {
        self.total_tx_count += hdr.tx_count as u64;
        if hdr.shard_id + 1 > self.active_shards {
            self.active_shards = hdr.shard_id + 1;
        }
        self.shard_headers.push(hdr);
    }

    pub fn add_cross_receipt(&mut self, r: CrossShardReceipt) {
        self.cross_receipts.push(r);
    }

    /// SHA-256 over the canonical layout. Mirrors the Zig hash composition
    /// (header fields + shard headers + cross receipts).
    pub fn calculate_hash(&mut self) {
        let mut h = Sha256::new();
        h.update(self.height.to_le_bytes());
        h.update(self.timestamp.to_le_bytes());
        h.update(self.previous_hash);
        for sh in &self.shard_headers {
            h.update([sh.shard_id]);
            h.update(sh.block_height.to_le_bytes());
            h.update(sh.tx_count.to_le_bytes());
            h.update(sh.block_hash);
        }
        for r in &self.cross_receipts {
            h.update([r.from_shard, r.to_shard, r.phase as u8]);
            h.update(r.amount_sat.to_le_bytes());
            h.update(r.tx_hash);
        }
        let d = h.finalize();
        self.hash.copy_from_slice(&d);
    }

    pub fn is_complete(&self, expected_shards: u8) -> bool {
        self.shard_headers.len() >= expected_shards as usize
    }
}

/// Metachain — chain of MetaBlocks plus the live shard subchains and a
/// pending-phase-2 receipt queue.
pub struct Metachain {
    pub chain: Vec<MetaBlock>,
    pub coordinator: ShardCoordinator,
    pub subchains: Vec<Subchain>,
    pub pending_receipts: Vec<CrossShardReceipt>,
}

impl Metachain {
    pub fn new(num_shards: u8) -> Result<Self, super::coordinator::ShardError> {
        let coordinator = ShardCoordinator::new(num_shards)?;
        let subchains = (0..num_shards).map(Subchain::new).collect();
        let mut genesis = MetaBlock::new(0, [0u8; 32], 0);
        genesis.calculate_hash();
        Ok(Self {
            chain: vec![genesis],
            coordinator,
            subchains,
            pending_receipts: Vec::new(),
        })
    }

    pub fn height(&self) -> u64 {
        (self.chain.len() - 1) as u64
    }

    pub fn latest_hash(&self) -> [u8; 32] {
        self.chain.last().unwrap().hash
    }

    /// Open a new MetaBlock at height = chain.len(). Returned mut ref is
    /// the in-place block — fill its shard headers, then call
    /// [`Metachain::finalize_meta_block`].
    pub fn begin_meta_block(&mut self, timestamp: i64) -> &mut MetaBlock {
        let height = self.chain.len() as u64;
        let prev = self.latest_hash();
        self.chain.push(MetaBlock::new(height, prev, timestamp));
        self.chain.last_mut().unwrap()
    }

    /// Finalize the current MetaBlock: drain phase-2 pending receipts into
    /// it, compute hash, run adaptive sharding hooks.
    pub fn finalize_meta_block(&mut self) {
        if self.chain.len() < 2 { return; } // genesis is never re-finalized

        let mb = self.chain.last_mut().unwrap();
        let drained: Vec<CrossShardReceipt> = std::mem::take(&mut self.pending_receipts);
        for mut r in drained {
            r.phase = CrossShardPhase::Phase2Credit;
            r.meta_height = mb.height;
            mb.add_cross_receipt(r);
        }
        mb.calculate_hash();

        // Adaptive sharding hooks (best-effort).
        if let Some(id) = self.coordinator.needs_split() {
            let _ = self.coordinator.split_shard(id);
        } else if let Some((a, b)) = self.coordinator.needs_merge() {
            let _ = self.coordinator.merge_shards(a, b);
        }
    }

    /// Phase-1 register: debit recorded into the current MetaBlock,
    /// matching phase-2 credit queued into pending_receipts (processed on
    /// next finalize).
    pub fn register_cross_shard_tx(
        &mut self,
        tx_hash: [u8; 32],
        from_addr: &str,
        to_addr: &str,
        amount_sat: u64,
    ) {
        let from_shard = self.coordinator.shard_for_address(from_addr.as_bytes());
        let to_shard = self.coordinator.shard_for_address(to_addr.as_bytes());
        let height = self.height();
        let phase1 = CrossShardReceipt {
            tx_hash,
            from_shard,
            to_shard,
            from_address: from_addr.to_string(),
            to_address: to_addr.to_string(),
            amount_sat,
            phase: CrossShardPhase::Phase1Debit,
            meta_height: height,
        };
        if let Some(mb) = self.chain.last_mut() {
            mb.add_cross_receipt(phase1.clone());
        }
        let mut phase2 = phase1;
        phase2.phase = CrossShardPhase::Phase2Credit;
        self.pending_receipts.push(phase2);
    }

    pub fn subchain(&self, shard_id: u8) -> Option<&Subchain> {
        self.subchains.get(shard_id as usize)
    }
    pub fn subchain_mut(&mut self, shard_id: u8) -> Option<&mut Subchain> {
        self.subchains.get_mut(shard_id as usize)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn genesis_height_zero() {
        let mc = Metachain::new(4).unwrap();
        assert_eq!(mc.height(), 0);
        assert_eq!(mc.subchains.len(), 4);
    }

    #[test]
    fn begin_then_finalize_changes_hash() {
        let mut mc = Metachain::new(4).unwrap();
        let h0 = mc.latest_hash();
        mc.begin_meta_block(1);
        mc.finalize_meta_block();
        let h1 = mc.latest_hash();
        assert_ne!(h0, h1);
    }

    #[test]
    fn cross_shard_phase2_drains_on_next_finalize() {
        let mut mc = Metachain::new(4).unwrap();
        mc.begin_meta_block(1);
        mc.register_cross_shard_tx(
            [0u8; 32],
            "ob1q0avux3lts0az4we2c8p7yuuuqw2qp2luxt2mtg",
            "ob_k1_bob0000000",
            500,
        );
        mc.finalize_meta_block();
        let pending_after = mc.pending_receipts.len();

        mc.begin_meta_block(2);
        mc.finalize_meta_block();
        assert!(mc.pending_receipts.len() <= pending_after);
    }

    #[test]
    fn consecutive_blocks_have_distinct_hashes() {
        let mut mc = Metachain::new(2).unwrap();
        mc.begin_meta_block(1); mc.finalize_meta_block();
        let h1 = mc.latest_hash();
        mc.begin_meta_block(2); mc.finalize_meta_block();
        let h2 = mc.latest_hash();
        assert_ne!(h1, h2);
    }
}
