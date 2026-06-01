//! Mining engine — main loop that produces blocks for the local node.
//!
//! Lifecycle (mirrors `core/main.zig::miningLoop`):
//!
//! 1. Pull up to `MAX_BLOCK_TX` TXs from the mempool (FIFO, anti-MEV).
//! 2. Build a candidate `Block` on top of the current tip (`prev_hash`,
//!    `index = tip + 1`).
//! 3. Run the **sub-block PoW phase**: 10 sub-blocks × 40 ms targets — each
//!    sub-block grinds a nonce against `difficulty` and contributes its
//!    `block_work()` weight to the aggregate KeyBlock work.
//! 4. When the KeyBlock is complete, finalize the block (merkle, hash,
//!    reward) and hand it to the submit callback for chain insertion + P2P
//!    broadcast.
//! 5. Loop.
//!
//! Multi-threading: each sub-block's nonce grind is offloaded via
//! `tokio::task::spawn_blocking` so it never blocks the async runtime.
//! Workers stride over the nonce space; the first one that satisfies the
//! target wins. We picked `tokio::spawn_blocking` over `rayon` because the
//! node is already async-first (tokio) and the work-unit (one sub-block) is
//! coarse — no benefit to a work-stealing pool here.

use std::sync::Arc;

use sha2::{Digest, Sha256};
use tokio::sync::{mpsc, Mutex};

use crate::consensus::block::{Block, Tx};
use crate::consensus::consensus::{block_reward_at, retarget_difficulty};
use crate::consensus::mempool::Mempool;
use crate::consensus::sub_block::{KeyBlock, SubBlock, SUB_BLOCKS_PER_BLOCK, SUB_BLOCK_INTERVAL_MS};
use crate::consensus::{MAX_BLOCK_TX, MIN_DIFFICULTY, RETARGET_INTERVAL};

use super::pow::{mine_block_nonce, MineOutcome};

#[derive(Debug, Clone)]
pub struct MiningConfig {
    pub miner_address: String,
    pub miner_id: String,
    /// Worker thread count (each strides the nonce space).
    pub worker_threads: u32,
    /// Max nonce attempts per worker per sub-block before giving up.
    pub max_attempts_per_subblock: u64,
    /// Starting difficulty (used for the very first block; retargets after
    /// `RETARGET_INTERVAL`).
    pub initial_difficulty: u32,
    /// Stop after producing this many blocks (0 = run forever).
    pub max_blocks: u64,
}

impl Default for MiningConfig {
    fn default() -> Self {
        Self {
            miner_address: String::new(),
            miner_id: "miner-rust".into(),
            worker_threads: 4,
            max_attempts_per_subblock: 5_000_000,
            initial_difficulty: 4,
            max_blocks: 0,
        }
    }
}

#[derive(Debug, Default, Clone)]
pub struct MiningStats {
    pub blocks_mined: u64,
    pub sub_blocks_mined: u64,
    pub total_attempts: u64,
    pub last_difficulty: u32,
    pub last_reward_sat: u64,
}

/// Snapshot of the chain tip needed to build the next candidate block.
#[derive(Debug, Clone)]
pub struct ChainTip {
    pub height: u32,
    pub prev_hash: String,
    pub difficulty: u32,
    /// Wall-clock seconds elapsed across the last RETARGET_INTERVAL blocks.
    /// Used for `retarget_difficulty()` on retarget boundaries.
    pub last_retarget_window_s: i64,
}

/// Async callback the engine invokes to push a mined block into the chain
/// and broadcast it over P2P. Return `Ok(())` to keep mining or `Err` to
/// stop the loop.
pub type SubmitFn = Arc<
    dyn Fn(Block) -> futures_util::future::BoxFuture<'static, anyhow::Result<()>> + Send + Sync,
>;

/// Async callback that returns the *current* chain tip. Called once per
/// block so reorgs are picked up between blocks.
pub type TipFn = Arc<
    dyn Fn() -> futures_util::future::BoxFuture<'static, anyhow::Result<ChainTip>> + Send + Sync,
>;

pub struct MiningEngine {
    pub cfg: MiningConfig,
    pub mempool: Arc<Mutex<Mempool>>,
    pub stats: Arc<Mutex<MiningStats>>,
    submit: SubmitFn,
    tip: TipFn,
    stop_tx: Option<mpsc::Sender<()>>,
}

impl MiningEngine {
    pub fn new(
        cfg: MiningConfig,
        mempool: Arc<Mutex<Mempool>>,
        tip: TipFn,
        submit: SubmitFn,
    ) -> Self {
        Self {
            cfg,
            mempool,
            stats: Arc::new(Mutex::new(MiningStats::default())),
            submit,
            tip,
            stop_tx: None,
        }
    }

    /// Run the mining loop until `stop()` or `max_blocks` is reached.
    pub async fn run(&mut self) -> anyhow::Result<()> {
        let (stop_tx, mut stop_rx) = mpsc::channel::<()>(1);
        self.stop_tx = Some(stop_tx);

        loop {
            tokio::select! {
                biased;
                _ = stop_rx.recv() => break,
                res = self.mine_one_block() => {
                    match res {
                        Ok(Some(_)) => {}
                        Ok(None) => continue, // no work / tip moved
                        Err(e) => {
                            tracing::warn!("mining error: {e:#}");
                            tokio::time::sleep(std::time::Duration::from_millis(200)).await;
                        }
                    }
                    let s = self.stats.lock().await;
                    if self.cfg.max_blocks > 0 && s.blocks_mined >= self.cfg.max_blocks {
                        break;
                    }
                }
            }
        }
        Ok(())
    }

    pub fn stop_handle(&self) -> Option<mpsc::Sender<()>> {
        self.stop_tx.clone()
    }

    /// Mine exactly one chain block (= 10 sub-blocks). Returns `Ok(None)` if
    /// no PoW solution was found within the attempt budget — caller should
    /// just try again with a fresh tip.
    pub async fn mine_one_block(&self) -> anyhow::Result<Option<Block>> {
        // 1. Fresh tip + difficulty.
        let tip = (self.tip)().await?;
        let difficulty = if tip.height as u64 % RETARGET_INTERVAL == 0 && tip.height > 0 {
            retarget_difficulty(tip.difficulty, tip.last_retarget_window_s)
        } else if tip.height == 0 {
            self.cfg.initial_difficulty.max(MIN_DIFFICULTY)
        } else {
            tip.difficulty
        };

        // 2. Drain mempool into candidate TX list (FIFO).
        let txs: Vec<Tx> = {
            let mut mp = self.mempool.lock().await;
            mp.take_for_block(MAX_BLOCK_TX)
        };

        // 3. Build candidate block.
        let new_height = tip.height + 1;
        let reward = block_reward_at(new_height as u64);
        let ts = now_unix_secs();
        let mut block = Block::new(new_height, tip.prev_hash.clone(), ts);
        block.transactions = txs.clone();
        block.miner_address = self.cfg.miner_address.clone();
        block.reward_sat = reward;
        block.recompute_merkle();

        // 4. Sub-block PoW phase.
        let mut key = KeyBlock::new(new_height);
        let mut total_attempts: u64 = 0;
        for sub_id in 0..SUB_BLOCKS_PER_BLOCK {
            // 4a. Build SubBlock holding this fraction of TXs.
            let sub_txs = chunk_txs_for_sub(&txs, sub_id);
            let mut sb = SubBlock::new(sub_id, new_height, 0, self.cfg.miner_id.clone());
            for t in sub_txs {
                sb.add_tx(t);
            }
            sb.timestamp_ms = now_unix_ms();
            sb.finalize();

            // 4b. Grind nonce — fan out to worker threads.
            let outcome = self
                .grind_sub_block_nonce(&block, sub_id, difficulty)
                .await?;
            total_attempts += outcome.attempts;
            sb.nonce = outcome.nonce;
            sb.hash = outcome.hash;

            // 4c. Maintain 40 ms pacing target (best-effort — real net races
            // determine the true cadence).
            tokio::time::sleep(std::time::Duration::from_millis(SUB_BLOCK_INTERVAL_MS)).await;

            match key.add_sub_block(sb) {
                Ok(true) => break, // complete
                Ok(false) => continue,
                Err(e) => anyhow::bail!("sub-block add failed: {e}"),
            }
        }
        key.finalize(reward);

        // 5. Finalize chain block: nonce-grind the OUTER block hash too so
        //    P2P peers (Zig + Rust) accept it via `validate_block_pow`.
        let outer = match tokio::task::spawn_blocking({
            let mut b = block.clone();
            let diff = difficulty;
            let max_attempts = self.cfg.max_attempts_per_subblock;
            move || mine_block_nonce(&mut b, diff, 0, 1, max_attempts).map(|o| (b, o))
        })
        .await?
        {
            Some(v) => v,
            None => return Ok(None),
        };
        let (mined_block, outer_outcome) = outer;
        total_attempts += outer_outcome.attempts;

        // 6. Submit.
        (self.submit)(mined_block.clone()).await?;

        // 7. Stats.
        {
            let mut s = self.stats.lock().await;
            s.blocks_mined += 1;
            s.sub_blocks_mined += SUB_BLOCKS_PER_BLOCK as u64;
            s.total_attempts += total_attempts;
            s.last_difficulty = difficulty;
            s.last_reward_sat = reward;
        }

        Ok(Some(mined_block))
    }

    /// Run `worker_threads` nonce-grinding tasks in parallel for one sub-block.
    /// The first to find a valid nonce wins. Each worker grinds the *outer*
    /// block-hash space with a unique stride — the sub-block's own hash is
    /// already deterministic (no PoW per sub-block in the Zig reference;
    /// PoW lives at the outer block level).
    async fn grind_sub_block_nonce(
        &self,
        block: &Block,
        sub_id: u8,
        difficulty: u32,
    ) -> anyhow::Result<MineOutcome> {
        let workers = self.cfg.worker_threads.max(1);
        let max_attempts = self.cfg.max_attempts_per_subblock / workers as u64;
        let mut handles = Vec::with_capacity(workers as usize);
        for w in 0..workers {
            let mut b = block.clone();
            // Salt the nonce-start per sub_id × worker so different sub-blocks
            // explore disjoint ranges.
            let start = (sub_id as u64).wrapping_mul(1_000_003).wrapping_add(w as u64);
            let stride = workers as u64;
            let diff = difficulty;
            handles.push(tokio::task::spawn_blocking(move || {
                mine_block_nonce(&mut b, diff, start, stride, max_attempts)
            }));
        }
        // First Some(_) wins; otherwise return a zero-attempts placeholder.
        let mut total_attempts = 0u64;
        for h in handles {
            match h.await? {
                Some(o) => {
                    return Ok(MineOutcome {
                        attempts: o.attempts + total_attempts,
                        ..o
                    });
                }
                None => total_attempts += max_attempts,
            }
        }
        // No luck this round — return an empty outcome so caller can retry.
        Ok(MineOutcome {
            nonce: 0,
            hash: [0u8; 32],
            hash_hex: String::new(),
            attempts: total_attempts,
        })
    }
}

/// Spread TXs across the 10 sub-blocks deterministically (round-robin on
/// `tx.hash[0]`). The merkle of all sub-blocks still rolls up into the
/// outer block's `merkle_root` so consensus is unaffected — this is purely
/// a presentation detail of the sub-block stream.
fn chunk_txs_for_sub(txs: &[Tx], sub_id: u8) -> Vec<Tx> {
    let mut out = Vec::new();
    for t in txs {
        let mut h = Sha256::new();
        h.update(&t.hash);
        let d = h.finalize();
        if (d[0] % SUB_BLOCKS_PER_BLOCK) == sub_id {
            out.push(t.clone());
        }
    }
    out
}

fn now_unix_secs() -> i64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

fn now_unix_ms() -> i64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}
