//! Top-level chain — ties `storage::ChainDb`, `consensus::Mempool`,
//! `consensus::ConsensusEngine`, and `consensus::FinalityEngine` together.
//!
//! Sibling of `core/blockchain.zig` (Zig). Owns the canonical in-memory tip
//! + the on-disk `chain.dat` mirror. RPC + block-production + sync all
//! poke at this through `Arc<RwLock<Chain>>` (tokio).

use std::path::PathBuf;
use std::sync::Arc;

use anyhow::Result;
use tokio::sync::RwLock;

use crate::consensus::block::{Block, Tx};
use crate::consensus::consensus::{ConsensusConfig, ConsensusEngine, ConsensusType};
use crate::consensus::genesis::{build_genesis_block, ChainConfig};
use crate::consensus::mempool::Mempool;
use crate::storage::database::{BlockRecord, ChainDb};

/// In-memory + on-disk chain state. Locked via `tokio::sync::RwLock` so
/// async tasks (block producer, sync loop, RPC) can share read access.
pub struct Chain {
    /// Persisted on disk; written through after every accepted block.
    pub db: ChainDb,
    /// All known blocks indexed by height (height 0 == genesis).
    pub blocks: Vec<Block>,
    /// Pending TX pool.
    pub mempool: Mempool,
    /// PoW validator.
    pub consensus: ConsensusEngine,
    /// Currently-active chain config (network params).
    pub cfg: ChainConfig,
    /// Difficulty target (leading hex zeros).
    pub difficulty: u32,
    /// `data/<chain>/chain.dat` path — atomic writes go here.
    pub db_path: PathBuf,
}

impl Chain {
    /// Open or initialize a chain rooted at `data_dir`. Loads `chain.dat`
    /// if present, otherwise seeds with the canonical genesis block.
    pub fn open(data_dir: &str) -> Result<Self> {
        let cfg = ChainConfig::mainnet();
        let path = PathBuf::from(data_dir).join("chain.dat");
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let mut db = ChainDb::load(&path)?;

        // Reconstruct in-memory block list from persisted records. For records
        // older than v4 the payload is a pipe-delimited header without TX
        // bodies — we keep them as opaque shells (no txs, hash from header).
        let mut blocks: Vec<Block> = Vec::with_capacity(db.blocks.len().max(1));
        for rec in &db.blocks {
            if let Some(b) = decode_block_record(rec) {
                blocks.push(b);
            }
        }

        if blocks.is_empty() {
            let genesis = build_genesis_block(&cfg);
            // Persist genesis row so subsequent saves stay incremental.
            db.blocks.push(BlockRecord {
                height: 0,
                data: encode_block_record(&genesis),
            });
            blocks.push(genesis);
        }

        let consensus = ConsensusEngine::new(ConsensusConfig::new(ConsensusType::ProofOfWork, 1));
        let chain = Self {
            db,
            blocks,
            mempool: Mempool::new(),
            consensus,
            difficulty: cfg.initial_difficulty,
            cfg,
            db_path: path,
        };
        Ok(chain)
    }

    pub fn tip(&self) -> &Block {
        self.blocks.last().expect("genesis always present")
    }

    pub fn height(&self) -> u64 {
        // `blocks.len() - 1` because genesis is height 0.
        (self.blocks.len() as u64).saturating_sub(1)
    }

    pub fn get_block_by_height(&self, h: u64) -> Option<&Block> {
        self.blocks.get(h as usize)
    }

    pub fn get_block_by_hash(&self, hash_hex: &str) -> Option<&Block> {
        self.blocks.iter().find(|b| b.hash == hash_hex)
    }

    /// Add a candidate block to the tip. Validates linkage + PoW. Persists
    /// to `chain.dat` on success. Returns the new height.
    pub fn add_block(&mut self, mut block: Block) -> Result<u64> {
        // Linkage: parent must be current tip.
        {
            let tip = self.tip();
            if block.index as u64 != tip.index as u64 + 1 {
                anyhow::bail!(
                    "block height mismatch: got {}, expected {}",
                    block.index,
                    tip.index + 1
                );
            }
            if block.previous_hash != tip.hash {
                anyhow::bail!("previous_hash mismatch");
            }
        }

        // PoW: recompute hash + verify difficulty.
        block.recompute_merkle();
        let recomputed = block.calculate_hash_hex();
        if !block.hash.is_empty() && block.hash != recomputed {
            anyhow::bail!("block hash field doesn't match recomputation");
        }
        block.hash = recomputed;
        if !ConsensusEngine::is_block_hash_valid(&block.hash, self.difficulty) {
            anyhow::bail!("PoW invalid: hash {} difficulty {}", block.hash, self.difficulty);
        }

        // Persist.
        self.db.blocks.push(BlockRecord {
            height: block.index as u64,
            data: encode_block_record(&block),
        });
        if let Err(e) = self.db.save(&self.db_path) {
            tracing::warn!(error = %e, "chain.dat save failed");
        }

        // Remove included TXs from mempool (FIFO mempool already gives us
        // those via take_for_block; nothing to do here unless a TX arrived
        // via P2P that we hadn't queued ourselves).
        for tx in &block.transactions {
            self.mempool.tx_hashes.remove(&tx.hash);
        }

        let h = block.index as u64;

        // WS events — NewBlock + per-TX TxConfirmed. No-op if no
        // broadcaster installed (unit tests, --mode evm).
        let block_hash = block.hash.clone();
        crate::ws::try_broadcast(crate::ws::Event::NewBlock {
            height: h,
            hash: block_hash.clone(),
            reward_sat: block.reward_sat,
            difficulty: self.difficulty as u64,
            mempool_size: self.mempool.entries.len(),
            timestamp: block.timestamp,
        });
        crate::ws::try_broadcast(crate::ws::Event::ChainHead {
            height: h,
            hash: block_hash.clone(),
            timestamp: block.timestamp,
        });
        for tx in &block.transactions {
            crate::ws::try_broadcast(crate::ws::Event::TxConfirmed {
                hash: hex::encode(tx.hash),
                block_height: h,
                block_hash: block_hash.clone(),
            });
        }

        self.blocks.push(block);
        Ok(h)
    }

    pub fn add_tx(&mut self, tx: Tx) -> Result<()> {
        self.mempool
            .add(tx)
            .map_err(|e| anyhow::anyhow!("mempool reject: {e}"))?;
        Ok(())
    }
}

/// Shared, async-friendly handle.
pub type SharedChain = Arc<RwLock<Chain>>;

// ── Block record encoding (pipe-delimited v4 header) ────────────────────────
//
// Matches what Zig writes in `database.zig` v4: ASCII header
// "{idx}|{ts}|{nonce}|{prev}|{hash}|{miner}|{reward}" followed by a binary
// section `[tx_count:u32 LE][tx_wire:N]...`. We only emit the header for now
// (tx_count = 0 binary tail) — the TX wire format is being finalised by the
// storage agent. Once it lands, just write `block.transactions` here.

fn encode_block_record(b: &Block) -> Vec<u8> {
    let header = format!(
        "{}|{}|{}|{}|{}|{}|{}",
        b.index, b.timestamp, b.nonce, b.previous_hash, b.hash, b.miner_address, b.reward_sat,
    );
    let mut out = header.into_bytes();
    // Empty TX section: u32 LE count = 0.
    out.extend_from_slice(&0u32.to_le_bytes());
    out
}

fn decode_block_record(rec: &BlockRecord) -> Option<Block> {
    // Find ASCII header (up to the binary [tx_count] suffix).
    let text_end = rec.data.iter().rposition(|&b| b == b'|')?;
    // Walk forward from text_end to find the end of the last numeric field.
    let mut end = text_end + 1;
    while end < rec.data.len() && rec.data[end].is_ascii_digit() {
        end += 1;
    }
    let header = std::str::from_utf8(&rec.data[..end]).ok()?;
    let parts: Vec<&str> = header.split('|').collect();
    if parts.len() < 7 {
        return None;
    }
    let mut b = Block::new(
        parts[0].parse().ok()?,
        parts[3].to_string(),
        parts[1].parse().ok()?,
    );
    b.nonce = parts[2].parse().ok()?;
    b.hash = parts[4].to_string();
    b.miner_address = parts[5].to_string();
    b.reward_sat = parts[6].parse().ok()?;
    Some(b)
}
