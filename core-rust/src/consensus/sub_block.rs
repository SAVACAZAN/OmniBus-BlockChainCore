//! SubBlock + KeyBlock — 10 × 0.1s sub-blocks aggregate into one chain block.
//! Port of `core/sub_block.zig`.

use sha2::{Digest, Sha256};

use super::block::Tx;

/// Number of sub-blocks per key (chain) block.
pub const SUB_BLOCKS_PER_BLOCK: u8 = 10;

/// Sub-block interval in milliseconds (kept identical to Zig's
/// 40 ms VPS-friendly midpoint).
pub const SUB_BLOCK_INTERVAL_MS: u64 = 40;

/// Soft confirmation at ~0.1 s granularity.
#[derive(Debug, Clone)]
pub struct SubBlock {
    pub sub_id: u8,
    pub block_number: u32,
    pub timestamp_ms: i64,
    pub merkle_root: [u8; 32],
    pub shard_id: u8,
    pub miner_id: String,
    pub nonce: u64,
    pub hash: [u8; 32],
    pub tx_count: u32,
    pub transactions: Vec<Tx>,
}

impl SubBlock {
    pub fn new(sub_id: u8, block_number: u32, shard_id: u8, miner_id: String) -> Self {
        Self {
            sub_id,
            block_number,
            timestamp_ms: 0,
            merkle_root: [0u8; 32],
            shard_id,
            miner_id,
            nonce: 0,
            hash: [0u8; 32],
            tx_count: 0,
            transactions: Vec::new(),
        }
    }

    pub fn add_tx(&mut self, tx: Tx) {
        self.transactions.push(tx);
        self.tx_count += 1;
    }

    /// Re-compute `merkle_root` and `hash`. Mirrors Zig `finalize`.
    pub fn finalize(&mut self) {
        self.merkle_root = self.calc_merkle_root();
        self.hash = self.calc_hash();
    }

    fn calc_merkle_root(&self) -> [u8; 32] {
        let mut hasher = Sha256::new();
        for tx in &self.transactions {
            hasher.update(&tx.hash);
        }
        let mut out = [0u8; 32];
        out.copy_from_slice(&hasher.finalize());
        out
    }

    /// Zig formula: `sha256("sb:{sub}:{blk}:{ts}:{shard}:{nonce}" || merkle_root)`.
    fn calc_hash(&self) -> [u8; 32] {
        let header = format!(
            "sb:{}:{}:{}:{}:{}",
            self.sub_id, self.block_number, self.timestamp_ms, self.shard_id, self.nonce,
        );
        let mut hasher = Sha256::new();
        hasher.update(header.as_bytes());
        hasher.update(&self.merkle_root);
        let mut out = [0u8; 32];
        out.copy_from_slice(&hasher.finalize());
        out
    }

    pub fn is_valid(&self) -> bool {
        self.sub_id < SUB_BLOCKS_PER_BLOCK
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum KeyBlockState {
    Collecting,
    Complete,
    Finalized,
}

/// Aggregates 10 sub-blocks into a single key (chain) block.
#[derive(Debug, Clone)]
pub struct KeyBlock {
    pub block_number: u32,
    pub sub_blocks: [Option<SubBlock>; SUB_BLOCKS_PER_BLOCK as usize],
    pub received: u8,
    pub state: KeyBlockState,
    pub started_at_ms: i64,
    pub finalized_at_ms: i64,
    pub sub_merkle_root: [u8; 32],
    pub key_hash: [u8; 32],
    pub total_reward_sat: u64,
}

impl KeyBlock {
    pub fn new(block_number: u32) -> Self {
        const NONE: Option<SubBlock> = None;
        Self {
            block_number,
            sub_blocks: [NONE; SUB_BLOCKS_PER_BLOCK as usize],
            received: 0,
            state: KeyBlockState::Collecting,
            started_at_ms: 0,
            finalized_at_ms: 0,
            sub_merkle_root: [0u8; 32],
            key_hash: [0u8; 32],
            total_reward_sat: 0,
        }
    }

    /// Returns `Ok(true)` when the 10th sub-block lands.
    pub fn add_sub_block(&mut self, sb: SubBlock) -> Result<bool, &'static str> {
        if self.state != KeyBlockState::Collecting {
            return Err("KeyBlockClosed");
        }
        if sb.sub_id >= SUB_BLOCKS_PER_BLOCK {
            return Err("InvalidSubId");
        }
        if self.sub_blocks[sb.sub_id as usize].is_some() {
            return Err("DuplicateSubBlock");
        }
        if !sb.is_valid() {
            return Err("InvalidSubBlock");
        }
        let idx = sb.sub_id as usize;
        self.sub_blocks[idx] = Some(sb);
        self.received += 1;
        if self.received == SUB_BLOCKS_PER_BLOCK {
            self.state = KeyBlockState::Complete;
            return Ok(true);
        }
        Ok(false)
    }

    pub fn finalize(&mut self, reward_sat: u64) {
        self.total_reward_sat = reward_sat;
        self.sub_merkle_root = self.calc_sub_merkle_root();
        self.key_hash = self.calc_key_hash();
        self.state = KeyBlockState::Finalized;
    }

    pub fn total_tx_count(&self) -> u32 {
        self.sub_blocks
            .iter()
            .filter_map(|s| s.as_ref())
            .map(|s| s.tx_count)
            .sum()
    }

    fn calc_sub_merkle_root(&self) -> [u8; 32] {
        let mut hasher = Sha256::new();
        let zeros = [0u8; 32];
        for slot in &self.sub_blocks {
            match slot {
                Some(sb) => hasher.update(&sb.hash),
                None => hasher.update(&zeros),
            }
        }
        let mut out = [0u8; 32];
        out.copy_from_slice(&hasher.finalize());
        out
    }

    /// Zig formula: `sha256("kb:{block_number}:{reward}" || sub_merkle_root)`.
    fn calc_key_hash(&self) -> [u8; 32] {
        let s = format!("kb:{}:{}", self.block_number, self.total_reward_sat);
        let mut hasher = Sha256::new();
        hasher.update(s.as_bytes());
        hasher.update(&self.sub_merkle_root);
        let mut out = [0u8; 32];
        out.copy_from_slice(&hasher.finalize());
        out
    }
}
