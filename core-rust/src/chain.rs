//! Top-level chain — ties `storage::ChainDb`, `consensus::Mempool`,
//! `consensus::ConsensusEngine`, and `consensus::FinalityEngine` together.
//!
//! Sibling of `core/blockchain.zig` (Zig). Owns the canonical in-memory tip
//! + the on-disk `chain.dat` mirror. RPC + block-production + sync all
//! poke at this through `Arc<RwLock<Chain>>` (tokio).

use std::collections::HashSet;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

use anyhow::Result;
use tokio::sync::RwLock;

use crate::consensus::block::{Block, Tx};
use crate::consensus::consensus::{ConsensusConfig, ConsensusEngine, ConsensusType};
use crate::consensus::genesis::{build_genesis_block, ChainConfig};
use crate::consensus::mempool::Mempool;
use crate::storage::database::{BlockRecord, ChainDb};
use crate::wallet::utxo::UtxoSet;

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
    /// UTXO set — tracks unspent outputs. Populated via `apply_block`.
    pub utxo_set: UtxoSet,
    /// Max clock drift (seconds) allowed in block timestamps (2h, like Bitcoin).
    pub max_future_secs: i64,
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
            utxo_set: UtxoSet::default(),
            max_future_secs: 7_200, // 2h — Bitcoin Core value
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

        // Update UTXO set for this block.
        self.apply_block(&block);

        self.blocks.push(block);
        Ok(h)
    }

    pub fn add_tx(&mut self, tx: Tx) -> Result<()> {
        self.mempool
            .add(tx)
            .map_err(|e| anyhow::anyhow!("mempool reject: {e}"))?;
        Ok(())
    }

    // ─── validate_block ───────────────────────────────────────────────────────
    //
    // Port of `blockchain.zig::validateBlock`. Checks (in order):
    //   1. Height linkage — block.index == tip.index + 1
    //   2. Previous-hash linkage — block.previous_hash == tip.hash
    //   3. Timestamp not too far in the future (max_future_secs)
    //   4. Merkle root consistency
    //   5. Hash recomputation matches block.hash field
    //   6. PoW difficulty satisfied
    //   7. TX uniqueness within the block (no duplicate hashes)
    //
    // Returns `Ok(())` on pass; `Err(reason)` on any failure.
    //
    // Note: full signature-level TX validation is out of scope here
    // (the Zig impl delegates that to `validateTransaction` which requires
    // the full UTXO set lookup — port that separately once UTXO persistence
    // is wired end-to-end). Structural checks are equivalent.

    /// Full block validation: linkage, timestamp, merkle, PoW, TX dedup.
    ///
    /// Returns `Ok(())` if all checks pass. Returns `Err(msg)` with a
    /// human-readable reason on any failure. Does NOT mutate state.
    pub fn validate_block(&self, block: &Block) -> Result<()> {
        let tip = self.tip();

        // 1. Height linkage.
        let expected_index = tip.index as u64 + 1;
        if block.index as u64 != expected_index {
            anyhow::bail!(
                "validate_block: height mismatch — got {}, expected {}",
                block.index,
                expected_index
            );
        }

        // 2. Previous-hash linkage.
        if block.previous_hash != tip.hash {
            anyhow::bail!(
                "validate_block: previous_hash mismatch — block has '{}', tip is '{}'",
                &block.previous_hash[..block.previous_hash.len().min(16)],
                &tip.hash[..tip.hash.len().min(16)]
            );
        }

        // 3. Timestamp — must not be too far in the future.
        let now_secs = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_secs() as i64)
            .unwrap_or(0);
        if block.timestamp > now_secs + self.max_future_secs {
            anyhow::bail!(
                "validate_block: timestamp {} too far in the future (now={}, drift_limit={})",
                block.timestamp,
                now_secs,
                self.max_future_secs
            );
        }

        // 4. Merkle root consistency.
        let expected_merkle = block.calculate_merkle_root();
        if block.merkle_root != expected_merkle {
            anyhow::bail!(
                "validate_block: merkle root mismatch — stored={}, computed={}",
                hex::encode(block.merkle_root),
                hex::encode(expected_merkle)
            );
        }

        // 5. Hash field matches recomputation.
        let expected_hash = block.calculate_hash_hex();
        if !block.hash.is_empty() && block.hash != expected_hash {
            anyhow::bail!(
                "validate_block: hash field '{}' doesn't match recomputed '{}'",
                &block.hash[..block.hash.len().min(16)],
                &expected_hash[..16]
            );
        }

        // 6. PoW difficulty.
        let hash_to_check = if block.hash.is_empty() {
            &expected_hash
        } else {
            &block.hash
        };
        if !ConsensusEngine::is_block_hash_valid(hash_to_check, self.difficulty) {
            anyhow::bail!(
                "validate_block: PoW invalid — hash '{}' doesn't meet difficulty {}",
                &hash_to_check[..hash_to_check.len().min(16)],
                self.difficulty
            );
        }

        // 7. No duplicate TX hashes within the block.
        let mut seen_hashes: HashSet<[u8; 32]> = HashSet::with_capacity(block.transactions.len());
        for tx in &block.transactions {
            let h = tx.hash();
            if !seen_hashes.insert(h) {
                anyhow::bail!(
                    "validate_block: duplicate TX hash {} in block {}",
                    hex::encode(h),
                    block.index
                );
            }
        }

        Ok(())
    }

    // ─── apply_block ──────────────────────────────────────────────────────────
    //
    // Port of `blockchain.zig::applyBlock` (UTXO update half).
    //
    // After a block has been validated and appended to `self.blocks`, update
    // the UTXO set:
    //   - Coinbase output: add UTXO for miner_address with reward_sat.
    //   - For each TX: add outputs as new UTXOs.
    //   - Remove confirmed TXs from mempool.
    //
    // Called automatically from `add_block`. Exposed for replay (sync agent
    // calling blocks individually without re-running full PoW validation).

    /// Update the UTXO set and mempool for a newly-accepted block.
    pub fn apply_block(&mut self, block: &Block) {
        let h = block.index as u64;

        // Coinbase UTXO — the block reward paid to the miner.
        // Synthetic tx_hash "coinbase:<height>" gives each coinbase a unique key.
        if !block.miner_address.is_empty() && block.reward_sat > 0 {
            let coinbase_hash = format!("coinbase:{}", h);
            self.utxo_set.add(
                &coinbase_hash,
                0,
                &block.miner_address,
                block.reward_sat,
                h,
                "",
                true,
            );
        }

        // Per-TX: add output UTXOs and remove from mempool.
        for tx in &block.transactions {
            let tx_hash_hex = hex::encode(tx.hash());
            if !tx.to_address.is_empty() && tx.amount > 0 {
                self.utxo_set.add(
                    &tx_hash_hex,
                    0,
                    &tx.to_address,
                    tx.amount,
                    h,
                    "",
                    false,
                );
            }
            self.mempool.tx_hashes.remove(&tx.hash());
        }
    }

    // ─── rollback_block ───────────────────────────────────────────────────────
    //
    // Port of `blockchain/reorg.zig` rollback logic.
    //
    // Removes outputs added by `block` from the UTXO set and re-adds TXs to the
    // mempool. Returns `Err` if `block` is not the current tip.

    /// Undo the UTXO effects of `block`. Used for reorg recovery.
    ///
    /// After calling this the chain tip is the block that preceded `block`.
    pub fn rollback_block(&mut self, block: &Block) -> Result<()> {
        // Guard: can only roll back the current tip.
        let tip = self.tip();
        if tip.index != block.index || tip.hash != block.hash {
            anyhow::bail!(
                "rollback_block: block {} ({}) is not the current tip {} ({})",
                block.index,
                &block.hash[..block.hash.len().min(12)],
                tip.index,
                &tip.hash[..tip.hash.len().min(12)]
            );
        }

        let h = block.index as u64;

        // Remove coinbase UTXO.
        let coinbase_hash = format!("coinbase:{}", h);
        let _ = self.utxo_set.spend(&coinbase_hash, 0);

        // Remove TX outputs and re-queue TXs to mempool.
        for tx in &block.transactions {
            let tx_hash_hex = hex::encode(tx.hash());
            if !tx.to_address.is_empty() && tx.amount > 0 {
                let _ = self.utxo_set.spend(&tx_hash_hex, 0);
            }
            // Re-add TX to mempool so it can be re-mined on the new chain.
            self.mempool.tx_hashes.insert(tx.hash(), ());
        }

        // Remove the persisted DB record for this block.
        if let Some(pos) = self.db.blocks.iter().rposition(|r| r.height == h) {
            self.db.blocks.remove(pos);
        }

        // Pop the block from in-memory chain.
        self.blocks.pop();

        Ok(())
    }

    // ─── is_chain_valid ───────────────────────────────────────────────────────
    //
    // Port of `blockchain.zig::isChainValid` — full chain audit from a given
    // height. Checks hash linkage + PoW for every block in range.
    // Cost: O(n) hashes. Call infrequently (startup audit, explicit RPC).

    /// Validate every block from `from_height` to the tip.
    ///
    /// Returns `Ok(())` if all blocks are valid, or `Err(msg)` with the
    /// first failing block's height and reason.
    ///
    /// Pass `from_height = 0` for a full audit from genesis.
    pub fn is_chain_valid(&self, from_height: u64) -> Result<()> {
        let start = from_height as usize;
        if start >= self.blocks.len() {
            return Ok(()); // nothing to check
        }

        for i in start..self.blocks.len() {
            let block = &self.blocks[i];

            // Hash field consistency.
            let expected = block.calculate_hash_hex();
            if !block.hash.is_empty() && block.hash != expected {
                anyhow::bail!(
                    "is_chain_valid: block {} hash '{}' doesn't match recomputed '{}'",
                    i,
                    &block.hash[..block.hash.len().min(16)],
                    &expected[..16]
                );
            }

            // PoW (skip genesis at index 0 — it has a well-known fixed hash).
            let check_hash = if block.hash.is_empty() { &expected } else { &block.hash };
            if i > 0 && !ConsensusEngine::is_block_hash_valid(check_hash, self.difficulty) {
                anyhow::bail!(
                    "is_chain_valid: block {} PoW invalid (difficulty {})",
                    i,
                    self.difficulty
                );
            }

            // Hash linkage (skip genesis).
            if i > 0 {
                let parent = &self.blocks[i - 1];
                let parent_hash = if parent.hash.is_empty() {
                    parent.calculate_hash_hex()
                } else {
                    parent.hash.clone()
                };
                if block.previous_hash != parent_hash {
                    anyhow::bail!(
                        "is_chain_valid: block {} previous_hash '{}' != parent hash '{}'",
                        i,
                        &block.previous_hash[..block.previous_hash.len().min(16)],
                        &parent_hash[..parent_hash.len().min(16)]
                    );
                }
            }
        }

        Ok(())
    }

    // ─── P2P header serialization helpers ────────────────────────────────────
    //
    // Port of the V3 130-byte header codec used in core/sync.zig / p2p/wire.zig.
    // These feed the SyncManager (GetHeaders / Headers exchange).

    /// Serialize a block header into the V3 P2P wire format (130 bytes).
    ///
    /// Layout:
    /// ```text
    /// [0..8]   height    u64 LE
    /// [8..16]  timestamp i64 LE
    /// [16..48] prev_hash 32 bytes (raw)
    /// [48..80] merkle_root 32 bytes
    /// [80..88] nonce     u64 LE
    /// [88..130] miner_id 42 bytes ASCII, zero-padded
    /// ```
    pub fn block_to_p2p_header(block: &Block) -> [u8; 130] {
        use byteorder::{ByteOrder, LittleEndian};
        let mut buf = [0u8; 130];
        LittleEndian::write_u64(&mut buf[0..8], block.index as u64);
        LittleEndian::write_i64(&mut buf[8..16], block.timestamp);
        // previous_hash: 64-char hex → 32 raw bytes
        if block.previous_hash.len() >= 64 {
            for i in 0..32 {
                let pair = &block.previous_hash[i * 2..i * 2 + 2];
                if let Ok(b) = u8::from_str_radix(pair, 16) {
                    buf[16 + i] = b;
                }
            }
        }
        buf[48..80].copy_from_slice(&block.merkle_root);
        LittleEndian::write_u64(&mut buf[80..88], block.nonce);
        let mlen = block.miner_address.len().min(42);
        buf[88..88 + mlen].copy_from_slice(&block.miner_address.as_bytes()[..mlen]);
        buf
    }

    /// Reconstruct a minimal Block scaffold from a V3 P2P header (130 bytes).
    /// The returned block has no transactions — those arrive via GetBlocks.
    pub fn block_from_p2p_header(buf: &[u8; 130]) -> Block {
        use byteorder::{ByteOrder, LittleEndian};
        let height = LittleEndian::read_u64(&buf[0..8]) as u32;
        let timestamp = LittleEndian::read_i64(&buf[8..16]);
        let prev_hash = hex::encode(&buf[16..48]);
        let nonce = LittleEndian::read_u64(&buf[80..88]);
        let miner_raw = &buf[88..130];
        // Find last non-null byte so we handle both padded and exact-length addresses.
        let miner_end = miner_raw.iter().rposition(|&b| b != 0).map(|i| i + 1).unwrap_or(0);
        let miner_address = String::from_utf8_lossy(&miner_raw[..miner_end]).into_owned();
        let mut merkle_root = [0u8; 32];
        merkle_root.copy_from_slice(&buf[48..80]);

        let mut block = Block::new(height, prev_hash, timestamp);
        block.nonce = nonce;
        block.miner_address = miner_address;
        block.merkle_root = merkle_root;
        block
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

// ── Unit tests ───────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use crate::consensus::block::Tx;

    /// Create a temp-dir chain with difficulty=1 for fast mining in tests.
    fn open_test_chain() -> Chain {
        let dir = tempfile_util::mk_tempdir();
        let mut chain = Chain::open(&dir).expect("open chain");
        chain.difficulty = 1;
        chain
    }

    /// Grind a block on top of `chain` until PoW is satisfied.
    fn mine_block(chain: &Chain) -> Block {
        let tip = chain.tip();
        let mut block = Block::new(tip.index + 1, tip.hash.clone(), tip.timestamp + 1);
        block.miner_address = "ob1qtestminer00000000000000000000000000000".to_string();
        block.reward_sat = 8_333_333;
        block.recompute_merkle();
        loop {
            let h = block.calculate_hash_hex();
            if ConsensusEngine::is_block_hash_valid(&h, chain.difficulty) {
                block.hash = h;
                break;
            }
            block.nonce += 1;
        }
        block
    }

    // ── Inline tempdir helper (no dev-dep needed inside lib) ─────────────────
    mod tempfile_util {
        pub fn mk_tempdir() -> String {
            use std::env;
            let base = env::temp_dir();
            let unique = format!("omnibus_chain_test_{}", std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_nanos())
                .unwrap_or(0));
            let path = base.join(unique);
            std::fs::create_dir_all(&path).expect("create test dir");
            path.to_str().expect("valid path").to_string()
        }
    }

    // ── Test: valid block passes validate_block ───────────────────────────────

    #[test]
    fn validate_block_valid_passes() {
        let chain = open_test_chain();
        let block = mine_block(&chain);
        chain.validate_block(&block).expect("valid block should pass");
    }

    // ── Test: height mismatch is rejected ─────────────────────────────────────

    #[test]
    fn validate_block_height_mismatch_fails() {
        let chain = open_test_chain();
        let mut block = mine_block(&chain);
        block.index = 99;
        let err = chain.validate_block(&block).unwrap_err();
        assert!(err.to_string().contains("height mismatch"), "got: {err}");
    }

    // ── Test: wrong previous_hash is rejected ─────────────────────────────────

    #[test]
    fn validate_block_prev_hash_mismatch_fails() {
        let chain = open_test_chain();
        let mut block = mine_block(&chain);
        block.previous_hash = "0".repeat(64);
        let err = chain.validate_block(&block).unwrap_err();
        assert!(err.to_string().contains("previous_hash mismatch"), "got: {err}");
    }

    // ── Test: tampered merkle root is rejected ────────────────────────────────

    #[test]
    fn validate_block_tampered_merkle_fails() {
        let chain = open_test_chain();
        let mut block = mine_block(&chain);
        block.merkle_root = [0xAB; 32];
        let err = chain.validate_block(&block).unwrap_err();
        assert!(err.to_string().contains("merkle root mismatch"), "got: {err}");
    }

    // ── Test: block with too-high difficulty hash is rejected ─────────────────

    #[test]
    fn validate_block_pow_fails_for_insufficient_hash() {
        let mut chain = open_test_chain();
        chain.difficulty = 64; // impossible to satisfy with a single nonce grind here
        let tip = chain.tip();
        let mut block = Block::new(tip.index + 1, tip.hash.clone(), tip.timestamp + 1);
        block.miner_address = "ob1qtestminer".to_string();
        block.recompute_merkle();
        block.hash = block.calculate_hash_hex(); // not going to have 64 leading zeros
        let err = chain.validate_block(&block).unwrap_err();
        assert!(err.to_string().contains("PoW invalid"), "got: {err}");
    }

    // ── Test: UTXO apply_block / rollback_block roundtrip ────────────────────

    #[test]
    fn utxo_apply_rollback_roundtrip() {
        let mut chain = open_test_chain();
        let miner = "ob1qtestminer00000000000000000000000000000";

        // Initially no UTXO for the test miner.
        assert_eq!(chain.utxo_set.balance(miner), 0);

        // Mine and accept a block.
        let block = mine_block(&chain);
        chain.add_block(block.clone()).expect("add_block");

        // Miner should have reward UTXO.
        assert_eq!(
            chain.utxo_set.balance(miner),
            8_333_333,
            "miner reward should be credited after apply_block"
        );

        // Roll back.
        chain.rollback_block(&block).expect("rollback_block");

        // Reward UTXO should be gone.
        assert_eq!(
            chain.utxo_set.balance(miner),
            0,
            "miner reward should be removed after rollback"
        );
        assert_eq!(chain.height(), 0, "height back to genesis after rollback");
    }

    // ── Test: is_chain_valid on a clean chain ─────────────────────────────────

    #[test]
    fn is_chain_valid_clean_chain_passes() {
        let mut chain = open_test_chain();
        let block = mine_block(&chain);
        chain.add_block(block).expect("add block");
        chain.is_chain_valid(0).expect("clean chain should pass");
    }

    // ── Test: is_chain_valid detects a tampered block ─────────────────────────

    #[test]
    fn is_chain_valid_detects_tampered_hash() {
        let mut chain = open_test_chain();
        let block = mine_block(&chain);
        chain.add_block(block).expect("add block");

        // Tamper the block hash in memory.
        chain.blocks[1].hash = "f".repeat(64);

        let err = chain.is_chain_valid(0).unwrap_err();
        let msg = err.to_string();
        assert!(
            msg.contains("hash") || msg.contains("linkage") || msg.contains("previous_hash"),
            "expected hash/linkage error, got: {msg}"
        );
    }

    // ── Test: duplicate TX hashes within a block are rejected ────────────────

    #[test]
    fn validate_block_rejects_duplicate_tx_hashes() {
        let chain = open_test_chain();
        let tip = chain.tip();

        // Build a Tx with a fixed hash so we can duplicate it.
        let tx = Tx::default(); // hash field is [0u8;32] — same for both copies

        let mut block = Block::new(tip.index + 1, tip.hash.clone(), tip.timestamp + 1);
        block.transactions.push(tx.clone());
        block.transactions.push(tx); // deliberate duplicate
        block.miner_address = "ob1qtestminer".to_string();
        block.reward_sat = 8_333_333;
        block.recompute_merkle();
        loop {
            let h = block.calculate_hash_hex();
            if ConsensusEngine::is_block_hash_valid(&h, chain.difficulty) {
                block.hash = h;
                break;
            }
            block.nonce += 1;
        }

        let err = chain.validate_block(&block).unwrap_err();
        assert!(err.to_string().contains("duplicate TX"), "got: {err}");
    }

    // ── Test: P2P header roundtrip ────────────────────────────────────────────

    #[test]
    fn p2p_header_encode_decode_roundtrip() {
        let chain = open_test_chain();
        let block = mine_block(&chain);
        let buf = Chain::block_to_p2p_header(&block);
        let recovered = Chain::block_from_p2p_header(&buf);
        assert_eq!(recovered.index, block.index);
        assert_eq!(recovered.timestamp, block.timestamp);
        assert_eq!(recovered.nonce, block.nonce);
        assert_eq!(recovered.miner_address, block.miner_address);
        assert_eq!(recovered.merkle_root, block.merkle_root);
    }
}
