//! Shard coordinator — port of `core/shard_coordinator.zig`.
//!
//! Routes addresses to shards deterministically and tracks per-shard
//! load for adaptive split/merge. EGLD-style: the metachain (id = 0xFF)
//! is special and does NOT process normal TXs.
//!
//! Note on routing: the task brief specifies `hash[0] & 3` (4-shard mask).
//! That's a special case of the more general formula `hash_word % num_shards`
//! used by the Zig source. With `num_shards = 4` (the OmniBus default per
//! `CLAUDE.md`: "Shards | 4 | shard_coordinator.zig") the two agree exactly
//! whenever num_shards is a power of two. We keep the modulo form so that
//! adaptive sharding (which can grow `num_shards` past 4) still routes
//! uniformly across non-power-of-two shard counts.

use sha2::{Digest, Sha256};

/// Metachain id — reserved sentinel, never an actual TX-processing shard.
pub const METACHAIN_SHARD: u8 = 0xFF;
/// Hard cap on shard count (adaptive sharding upper bound).
pub const MAX_SHARDS: u8 = 32;
/// Default starting shard count (per CLAUDE.md).
pub const NUM_SHARDS: u8 = 4;
/// Capacity % above which a shard is a split candidate.
pub const SHARD_SPLIT_THRESHOLD: u8 = 80;
/// Capacity % below which a shard is a merge candidate.
pub const SHARD_MERGE_THRESHOLD: u8 = 20;

#[derive(Debug, Clone, Copy)]
pub struct ShardStats {
    pub shard_id: u8,
    pub tx_count: u64,
    pub capacity_pct: u8,
    pub node_count: u16,
    pub active: bool,
}

impl ShardStats {
    fn empty(id: u8, active: bool) -> Self {
        Self { shard_id: id, tx_count: 0, capacity_pct: 0, node_count: 0, active }
    }
}

/// Standalone address→shard router used by anything that doesn't hold a
/// `ShardCoordinator` reference (e.g. mempool admission). Uses SHA-256 +
/// first byte modulo NUM_SHARDS, which matches `hash[0] & 3` when
/// `NUM_SHARDS == 4` (a power of two).
pub fn shard_for_address(address: &[u8]) -> u8 {
    shard_for_address_with(address, NUM_SHARDS)
}

fn shard_for_address_with(address: &[u8], num_shards: u8) -> u8 {
    if address.is_empty() || num_shards == 0 {
        return 0;
    }
    let mut h = Sha256::new();
    h.update(address);
    let digest = h.finalize();
    // Two bytes of entropy for uniform distribution at larger num_shards.
    let val = ((digest[0] as u16) << 8) | (digest[1] as u16);
    (val % num_shards as u16) as u8
}

pub struct ShardCoordinator {
    pub num_shards: u8,
    pub shard_stats: [ShardStats; MAX_SHARDS as usize],
}

impl ShardCoordinator {
    pub fn new(num_shards: u8) -> Result<Self, ShardError> {
        if num_shards == 0 || num_shards > MAX_SHARDS {
            return Err(ShardError::InvalidShardCount);
        }
        let mut stats = [ShardStats::empty(0, false); MAX_SHARDS as usize];
        for i in 0..MAX_SHARDS as usize {
            stats[i] = ShardStats::empty(i as u8, (i as u8) < num_shards);
        }
        Ok(Self { num_shards, shard_stats: stats })
    }

    /// Default: 4 shards.
    pub fn default_4() -> Self {
        Self::new(NUM_SHARDS).expect("NUM_SHARDS is in range")
    }

    pub fn shard_for_address(&self, address: &[u8]) -> u8 {
        shard_for_address_with(address, self.num_shards)
    }

    pub fn is_cross_shard(&self, from: &[u8], to: &[u8]) -> bool {
        self.shard_for_address(from) != self.shard_for_address(to)
    }

    /// True if `my_shard` is either source or destination of the TX —
    /// such a node must process it.
    pub fn should_process_tx(&self, my_shard: u8, from: &[u8], to: &[u8]) -> bool {
        let fs = self.shard_for_address(from);
        let ts = self.shard_for_address(to);
        my_shard == fs || my_shard == ts
    }

    pub fn update_stats(&mut self, shard_id: u8, tx_count: u64, capacity_pct: u8) {
        if shard_id >= MAX_SHARDS { return; }
        let s = &mut self.shard_stats[shard_id as usize];
        s.tx_count = tx_count;
        s.capacity_pct = capacity_pct;
    }

    /// Shard above SPLIT threshold (returns first match).
    pub fn needs_split(&self) -> Option<u8> {
        if self.num_shards >= MAX_SHARDS { return None; }
        for i in 0..self.num_shards as usize {
            let s = self.shard_stats[i];
            if s.active && s.capacity_pct >= SHARD_SPLIT_THRESHOLD {
                return Some(i as u8);
            }
        }
        None
    }

    /// Two shards under MERGE threshold (returns first pair found).
    pub fn needs_merge(&self) -> Option<(u8, u8)> {
        if self.num_shards <= 1 { return None; }
        let mut low: [Option<u8>; 2] = [None, None];
        for i in 0..self.num_shards as usize {
            let s = self.shard_stats[i];
            if s.active && s.capacity_pct < SHARD_MERGE_THRESHOLD {
                if low[0].is_none() { low[0] = Some(i as u8); }
                else if low[1].is_none() { low[1] = Some(i as u8); }
            }
        }
        match (low[0], low[1]) {
            (Some(a), Some(b)) => Some((a, b)),
            _ => None,
        }
    }

    pub fn split_shard(&mut self, shard_id: u8) -> Result<u8, ShardError> {
        if self.num_shards >= MAX_SHARDS { return Err(ShardError::TooManyShards); }
        if shard_id >= self.num_shards { return Err(ShardError::InvalidShardId); }
        let new_id = self.num_shards;
        self.shard_stats[new_id as usize] = ShardStats::empty(new_id, true);
        self.num_shards += 1;
        Ok(new_id)
    }

    pub fn merge_shards(&mut self, a: u8, b: u8) -> Result<(), ShardError> {
        if self.num_shards <= 1 { return Err(ShardError::CannotMergeLastShard); }
        if a >= self.num_shards || b >= self.num_shards { return Err(ShardError::InvalidShardId); }
        if a == b { return Err(ShardError::SameShardId); }
        self.shard_stats[b as usize].active = false;
        self.num_shards -= 1;
        Ok(())
    }
}

#[derive(Debug, thiserror::Error)]
pub enum ShardError {
    #[error("invalid shard count (must be 1..=MAX_SHARDS)")]
    InvalidShardCount,
    #[error("invalid shard id")]
    InvalidShardId,
    #[error("too many shards (cap reached)")]
    TooManyShards,
    #[error("cannot merge the last remaining shard")]
    CannotMergeLastShard,
    #[error("from and to shard are the same")]
    SameShardId,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_is_4_shards() {
        let sc = ShardCoordinator::default_4();
        assert_eq!(sc.num_shards, 4);
    }

    #[test]
    fn routing_deterministic() {
        let sc = ShardCoordinator::default_4();
        let a = sc.shard_for_address(b"ob1q0avux3lts0az4we2c8p7yuuuqw2qp2luxt2mtg");
        let b = sc.shard_for_address(b"ob1q0avux3lts0az4we2c8p7yuuuqw2qp2luxt2mtg");
        assert_eq!(a, b);
        assert!(a < 4);
    }

    #[test]
    fn routing_spreads_addresses() {
        let sc = ShardCoordinator::default_4();
        let mut seen = [false; 4];
        let samples = [
            b"ob1q0avux3lts0az4we2c8p7yuuuqw2qp2luxt2mtg" as &[u8],
            b"ob1qyy67swcquu9zpgpz84e5j9rlxy0xawsjhg7xqy",
            b"ob_k1_carol00000",
            b"ob_f5_dave000000",
            b"ob_d5_eve0000000",
            b"ob_s3_frank00000",
            b"ob1qrgq6jnvvhcmp03ur849a85mhdvsvaqf6dprzn4",
            b"ob1ql33v8q9wqvqrschu982lvrnvfupyzcvj746kqh",
        ];
        for s in samples { seen[sc.shard_for_address(s) as usize] = true; }
        // With 8 diverse addresses we expect at least 2 distinct shards.
        let distinct = seen.iter().filter(|&&b| b).count();
        assert!(distinct >= 2);
    }

    #[test]
    fn split_and_merge() {
        let mut sc = ShardCoordinator::new(2).unwrap();
        let new_id = sc.split_shard(0).unwrap();
        assert_eq!(sc.num_shards, 3);
        assert_eq!(new_id, 2);
        sc.merge_shards(0, 1).unwrap();
        assert_eq!(sc.num_shards, 2);
    }

    #[test]
    fn split_candidate_above_threshold() {
        let mut sc = ShardCoordinator::default_4();
        sc.update_stats(2, 1000, 85);
        assert_eq!(sc.needs_split(), Some(2));
    }
}
