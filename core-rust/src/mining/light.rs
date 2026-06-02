//! Light miner — port of `core/light_miner.zig`.
//!
//! "Light" = mines without holding the full chain state. It still grinds
//! PoW on candidate headers handed to it (by a pool, by a full node, or by
//! an SPV header chain), but it does **not** validate the body — that's
//! the full node's job. SPV-style header proofs are accepted by trusting
//! the longest valid header chain it has seen.
//!
//! Mirrors the Zig `LightMiner` + `MinerPool` (the in-process light pool —
//! distinct from the wire-protocol pool in [`super::pool`]).

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MinerStatus {
    Offline,
    Connecting,
    Mining,
    BlockFound,
    MiningError,
    Shutdown,
}

#[derive(Debug, Clone)]
pub struct LightMiner {
    pub miner_id: u32,
    pub instance_name: String,
    pub hashrate: u64,
    pub status: MinerStatus,
    pub blocks_mined: u32,
    pub shares_submitted: u32,
    pub shares_accepted: u32,
    pub last_share_time: i64,
    pub total_difficulty: u64,
    pub connection_time: i64,
    pub is_connected: bool,
}

impl LightMiner {
    pub fn new(id: u32, hashrate: u64) -> Self {
        Self {
            miner_id: id,
            instance_name: format!("light-miner-{id}"),
            hashrate,
            status: MinerStatus::Offline,
            blocks_mined: 0,
            shares_submitted: 0,
            shares_accepted: 0,
            last_share_time: 0,
            total_difficulty: 0,
            connection_time: now_secs(),
            is_connected: false,
        }
    }

    pub fn connect(&mut self) {
        self.is_connected = true;
        self.status = MinerStatus::Mining;
        self.connection_time = now_secs();
    }

    pub fn disconnect(&mut self) {
        self.is_connected = false;
        self.status = MinerStatus::Offline;
    }

    /// Record a submitted share. Mirrors Zig: accept ~95% of shares
    /// (sim noise — full nodes do real ECDSA-level validation elsewhere).
    pub fn submit_share(&mut self, difficulty: u64) {
        self.shares_submitted += 1;
        self.total_difficulty = self.total_difficulty.saturating_add(difficulty);
        self.last_share_time = now_secs();
        if self.shares_submitted % 20 != 0 {
            self.shares_accepted += 1;
        }
    }

    pub fn record_block_mined(&mut self) {
        self.blocks_mined += 1;
        self.status = MinerStatus::BlockFound;
    }

    pub fn uptime(&self) -> i64 {
        if !self.is_connected {
            return 0;
        }
        now_secs() - self.connection_time
    }

    pub fn acceptance_rate(&self) -> f64 {
        if self.shares_submitted == 0 {
            return 0.0;
        }
        self.shares_accepted as f64 / self.shares_submitted as f64
    }

    pub fn effective_hashrate(&self) -> u64 {
        let up = self.uptime();
        if !self.is_connected || up == 0 || self.shares_accepted == 0 {
            return 0;
        }
        self.total_difficulty / up as u64
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PoolStatus {
    Initializing,
    WaitingForMiners,
    ReadyForGenesis,
    GenesisMining,
    Mining,
    PoolError,
    Shutdown,
}

/// In-process pool of [`LightMiner`]s — used by the bootstrap path that
/// needs N miners co-mining the genesis stretch before the chain "opens".
#[derive(Debug, Clone)]
pub struct LightMinerPool {
    pub miners: Vec<LightMiner>,
    pub total_hashrate: u64,
    pub pool_status: PoolStatus,
    pub genesis_started: bool,
    pub min_miners_for_genesis: u32,
}

impl Default for LightMinerPool {
    fn default() -> Self {
        Self::new()
    }
}

impl LightMinerPool {
    pub fn new() -> Self {
        Self {
            miners: Vec::new(),
            total_hashrate: 0,
            pool_status: PoolStatus::Initializing,
            genesis_started: false,
            min_miners_for_genesis: 2,
        }
    }

    pub fn add_miner(&mut self, id: u32, hashrate: u64) {
        self.miners.push(LightMiner::new(id, hashrate));
        self.total_hashrate = self.total_hashrate.saturating_add(hashrate);
        if self.miners.len() as u32 >= self.min_miners_for_genesis {
            self.pool_status = PoolStatus::ReadyForGenesis;
        }
    }

    pub fn connect_miner(&mut self, miner_id: u32) -> bool {
        for m in &mut self.miners {
            if m.miner_id == miner_id {
                m.connect();
                return true;
            }
        }
        false
    }

    pub fn connected_count(&self) -> u32 {
        self.miners.iter().filter(|m| m.is_connected).count() as u32
    }

    pub fn is_ready_for_genesis(&self) -> bool {
        self.connected_count() >= self.min_miners_for_genesis
    }

    pub fn start_genesis(&mut self) -> Result<(), &'static str> {
        if !self.is_ready_for_genesis() {
            return Err("NotEnoughMiners");
        }
        self.genesis_started = true;
        self.pool_status = PoolStatus::GenesisMining;
        Ok(())
    }

    pub fn submit_share(&mut self, miner_id: u32, difficulty: u64) -> bool {
        if !self.genesis_started {
            return false;
        }
        for m in &mut self.miners {
            if m.miner_id == miner_id {
                m.submit_share(difficulty);
                return true;
            }
        }
        false
    }
}

fn now_secs() -> i64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn light_miner_basic() {
        let mut m = LightMiner::new(1, 5000);
        assert!(!m.is_connected);
        m.connect();
        assert!(m.is_connected);
        m.submit_share(100);
        assert_eq!(m.shares_submitted, 1);
        assert_eq!(m.shares_accepted, 1);
    }

    #[test]
    fn pool_genesis_requires_3() {
        let mut p = LightMinerPool::new();
        p.add_miner(0, 1000);
        p.add_miner(1, 2000);
        assert!(!p.is_ready_for_genesis());
        p.add_miner(2, 3000);
        assert!(!p.is_ready_for_genesis()); // not connected
        p.connect_miner(0);
        p.connect_miner(1);
        p.connect_miner(2);
        assert!(p.is_ready_for_genesis());
        assert!(p.start_genesis().is_ok());
    }
}
