//! Block template construction and assembly helpers.
//!
//! Port of `core/block.zig` (block construction + Merkle root + mine loop)
//! extended with block-template helpers that the mining engine needs:
//!   - `BlockTemplate` — mutable candidate before PoW
//!   - `assemble_block`  — pull TXs from mempool, compute Merkle root
//!   - `finalize_block`  — set hash + reward after PoW succeeds
//!   - `validate_block`  — full block validation (PoW + Merkle + TX)
//!
//! Hash formula and Merkle algorithm are byte-for-byte identical to the Zig
//! implementation so a block mined by the Rust node is accepted by the Zig
//! node and vice-versa.

use sha2::{Digest, Sha256};

use crate::consensus::block::{Block, Tx};
use crate::consensus::consensus::ConsensusEngine;
use crate::consensus::mempool::Mempool;
use crate::consensus::{MAX_BLOCK_SIZE, MAX_BLOCK_TX};

// ── BlockTemplate ─────────────────────────────────────────────────────────────

/// A mutable candidate block ready for PoW.
///
/// Created by [`assemble_block`], mutated by the nonce-grinding loop, then
/// converted to a final [`Block`] by [`finalize_block`].
#[derive(Debug, Clone)]
pub struct BlockTemplate {
    pub index: u32,
    pub timestamp: i64,
    pub previous_hash: String,
    pub transactions: Vec<Tx>,
    pub merkle_root: [u8; 32],
    pub prices_root: [u8; 32],
    pub miner_address: String,
    pub difficulty: u32,
    /// Nonce incremented by the PoW loop.
    pub nonce: u64,
    /// Total TX fees included in this template.
    pub total_fees_sat: u64,
    /// Coinbase reward (base block reward + fees).
    pub reward_sat: u64,
}

impl BlockTemplate {
    /// Compute the block header hash for the current nonce.
    /// Mirrors `Block::calculate_hash` in `block.zig`.
    pub fn header_hash(&self) -> [u8; 32] {
        let header = format!(
            "{}{}{}{}",
            self.index, self.timestamp, self.previous_hash, self.nonce
        );
        let mut h = Sha256::new();
        h.update(header.as_bytes());
        h.update(&self.merkle_root);
        h.update(&self.prices_root);
        let mut out = [0u8; 32];
        out.copy_from_slice(&h.finalize());
        out
    }

    /// Hex-encoded header hash (64 lowercase ASCII chars).
    pub fn header_hash_hex(&self) -> String {
        hex::encode(self.header_hash())
    }

    /// True if the current hash satisfies the difficulty target.
    pub fn hash_satisfies_difficulty(&self) -> bool {
        let hex = self.header_hash_hex();
        ConsensusEngine::is_block_hash_valid(&hex, self.difficulty)
    }

    /// Recompute and cache the Merkle root from `self.transactions`.
    /// Call this once after all TXs are added and before PoW begins.
    pub fn recompute_merkle(&mut self) {
        self.merkle_root = compute_merkle_root(&self.transactions);
    }
}

// ── Block assembly ────────────────────────────────────────────────────────────

/// Pull up to `max_txs` transactions from the mempool and build a
/// `BlockTemplate` on top of `prev`.
///
/// The template's `nonce` starts at 0 — the caller (mining engine) runs the
/// nonce-grinding loop via `template.nonce += 1` or the stride-workers
/// approach in `pow::mine_block_nonce`.
pub fn assemble_block(
    prev: &Block,
    mempool: &mut Mempool,
    miner_address: String,
    difficulty: u32,
    base_reward_sat: u64,
    now_ms: i64,
) -> BlockTemplate {
    let max_txs = MAX_BLOCK_TX;
    let txs = mempool.take_for_block(max_txs);

    let total_fees: u64 = txs.iter().map(|t| t.fee).sum();
    let reward_sat = base_reward_sat.saturating_add(total_fees);

    let mut t = BlockTemplate {
        index: prev.index + 1,
        timestamp: now_ms,
        previous_hash: prev.calculate_hash_hex(),
        transactions: txs,
        merkle_root: [0u8; 32],
        prices_root: prev.prices_root, // inherit until oracle update
        miner_address,
        difficulty,
        nonce: 0,
        total_fees_sat: total_fees,
        reward_sat,
    };
    t.recompute_merkle();
    t
}

/// Convert a mined template into a final `Block`.
///
/// Should be called only AFTER the nonce-grinding loop has found a valid
/// hash; the caller must pass that hash.
pub fn finalize_block(template: BlockTemplate, hash_hex: String) -> Block {
    Block {
        index: template.index,
        timestamp: template.timestamp,
        transactions: template.transactions,
        previous_hash: template.previous_hash,
        nonce: template.nonce,
        hash: hash_hex,
        merkle_root: template.merkle_root,
        miner_address: template.miner_address,
        reward_sat: template.reward_sat,
        prices_root: template.prices_root,
        fills_root: [0u8; 32],
    }
}

// ── Block validation ──────────────────────────────────────────────────────────

/// Outcome of full block validation.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BlockValidation {
    Valid,
    /// Hash doesn't satisfy the difficulty target.
    InvalidPoW,
    /// Stored hash doesn't match recomputed hash.
    HashMismatch,
    /// Stored Merkle root doesn't match recomputed root.
    MerkleRootMismatch,
    /// Block is too large (> `MAX_BLOCK_SIZE` bytes).
    BlockTooLarge,
    /// Height is not `prev.index + 1`.
    HeightMismatch,
    /// `previous_hash` field doesn't match `prev`'s canonical hash.
    PrevHashMismatch,
    /// One or more transactions are structurally invalid.
    InvalidTransaction,
}

/// Validate a block in full against its predecessor.
///
/// Checks performed (in order):
///   1. Height continuity.
///   2. previous_hash matches `prev`.
///   3. PoW (hash ≤ target).
///   4. Stored hash == recomputed hash.
///   5. Merkle root.
///   6. Block size limit.
///   7. Basic TX validity (non-empty from/to, amount > 0).
pub fn validate_block(block: &Block, prev: &Block, difficulty: u32) -> BlockValidation {
    // 1. Height.
    if block.index != prev.index + 1 {
        return BlockValidation::HeightMismatch;
    }

    // 2. prev_hash link.
    let prev_hash_hex = prev.calculate_hash_hex();
    if block.previous_hash != prev_hash_hex {
        return BlockValidation::PrevHashMismatch;
    }

    // 3. PoW.
    if !ConsensusEngine::is_block_hash_valid(&block.hash, difficulty) {
        return BlockValidation::InvalidPoW;
    }

    // 4. Hash integrity.
    let recomputed = hex::encode(block.calculate_hash());
    if block.hash != recomputed {
        return BlockValidation::HashMismatch;
    }

    // 5. Merkle root.
    let recomputed_mr = compute_merkle_root(&block.transactions);
    if block.merkle_root != recomputed_mr {
        return BlockValidation::MerkleRootMismatch;
    }

    // 6. Block size (rough byte estimate using serialized TX sizes).
    let approx_bytes: usize = block
        .transactions
        .iter()
        .map(|t| t.from_address.len() + t.to_address.len() + t.signature.len() + 64)
        .sum::<usize>()
        + 256; // header overhead
    if approx_bytes > MAX_BLOCK_SIZE {
        return BlockValidation::BlockTooLarge;
    }

    // 7. TX validity.
    for tx in &block.transactions {
        if tx.from_address.is_empty() || tx.to_address.is_empty() || tx.amount == 0 {
            return BlockValidation::InvalidTransaction;
        }
    }

    BlockValidation::Valid
}

// ── Merkle root ───────────────────────────────────────────────────────────────

/// Binary Merkle root over a slice of transactions.
/// Empty slice → all-zero root (matches Zig).
/// Odd count → duplicate the last node (Bitcoin convention).
pub fn compute_merkle_root(txs: &[Tx]) -> [u8; 32] {
    let count = txs.len().min(MAX_BLOCK_TX);
    if count == 0 {
        return [0u8; 32];
    }

    let mut layer: Vec<[u8; 32]> = txs[..count].iter().map(|t| t.hash()).collect();

    // Bitcoin rule: single TX → hash(tx || tx) before reduce.
    if layer.len() == 1 {
        let only = layer[0];
        layer.push(only);
    }

    while layer.len() > 1 {
        let next_count = (layer.len() + 1) / 2;
        let mut next = Vec::with_capacity(next_count);
        for i in 0..next_count {
            let left = i * 2;
            let right = if left + 1 < layer.len() { left + 1 } else { left };
            let mut h = Sha256::new();
            h.update(&layer[left]);
            h.update(&layer[right]);
            let mut out = [0u8; 32];
            out.copy_from_slice(&h.finalize());
            next.push(out);
        }
        layer = next;
    }
    layer[0]
}

/// Generate a Merkle inclusion proof for transaction at `tx_index`.
/// Returns `None` if `tx_index` is out of range.
pub fn generate_merkle_proof(txs: &[Tx], tx_index: usize) -> Option<MerkleProofSimple> {
    let count = txs.len().min(MAX_BLOCK_TX);
    if count == 0 || tx_index >= count {
        return None;
    }

    let mut layer: Vec<[u8; 32]> = txs[..count].iter().map(|t| t.hash()).collect();
    let tx_hash = layer[tx_index];
    let root = compute_merkle_root(txs);

    // Bitcoin rule: single TX → duplicate before building the proof path.
    if layer.len() == 1 {
        let only = layer[0];
        layer.push(only);
    }

    let mut path: Vec<([u8; 32], bool)> = Vec::new(); // (sibling_hash, is_right)
    let mut pos = tx_index;
    let mut level_count = layer.len();

    while level_count > 1 {
        let is_left = pos % 2 == 0;
        let sibling_pos = if is_left {
            if pos + 1 < level_count { pos + 1 } else { pos }
        } else {
            pos - 1
        };
        // sibling_is_right: true when we are on the left (sibling is to our right).
        path.push((layer[sibling_pos], is_left));

        // Recompute next level in-place.
        let next_count = (level_count + 1) / 2;
        let mut next = Vec::with_capacity(next_count);
        for i in 0..next_count {
            let l = i * 2;
            let r = if l + 1 < level_count { l + 1 } else { l };
            let mut h = Sha256::new();
            h.update(&layer[l]);
            h.update(&layer[r]);
            let mut out = [0u8; 32];
            out.copy_from_slice(&h.finalize());
            next.push(out);
        }
        layer = next;
        pos /= 2;
        level_count = next_count;
    }

    Some(MerkleProofSimple { tx_hash, root, path })
}

/// Minimal Merkle proof (TX hash + root + sibling path).
#[derive(Debug, Clone)]
pub struct MerkleProofSimple {
    pub tx_hash: [u8; 32],
    pub root: [u8; 32],
    /// Each step: (sibling_hash, sibling_is_right).
    /// `sibling_is_right = true` means the sibling goes on the right when hashing.
    pub path: Vec<([u8; 32], bool)>,
}

impl MerkleProofSimple {
    /// Verify the proof against the stored root.
    pub fn verify(&self) -> bool {
        let mut current = self.tx_hash;
        for (sibling, sibling_is_right) in &self.path {
            let mut h = Sha256::new();
            if *sibling_is_right {
                h.update(&current);
                h.update(sibling);
            } else {
                h.update(sibling);
                h.update(&current);
            }
            current.copy_from_slice(&h.finalize());
        }
        current == self.root
    }
}

// ── Fill wire codec (port of block.zig encode/decode/computeFillsRoot) ────────
//
// Canonical 180-byte on-wire layout for a single Fill record.
// Layout (little-endian integers, packed):
//   [0..8]     fill_id          u64
//   [8..16]    buy_order_id     u64
//   [16..24]   sell_order_id    u64
//   [24..32]   price_micro_usd  u64
//   [32..40]   amount_sat       u64
//   [40..48]   timestamp_ms     i64
//   [48..50]   pair_id          u16
//   [50..114]  buyer_address    [64]u8
//   [114]      buyer_addr_len   u8
//   [115..179] seller_address   [64]u8
//   [179]      seller_addr_len  u8

/// Canonical wire size for a single fill record (bytes).
pub const FILL_WIRE_SIZE: usize = 180;

/// Minimal Fill record for the mining layer.
///
/// The full canonical struct lives in the exchange/matching module; this thin
/// version carries exactly the fields needed for the block fill-root codec and
/// storage serialisation.
#[derive(Debug, Clone)]
pub struct FillRecord {
    pub fill_id: u64,
    pub buy_order_id: u64,
    pub sell_order_id: u64,
    pub price_micro_usd: u64,
    pub amount_sat: u64,
    pub timestamp_ms: i64,
    pub pair_id: u16,
    /// Buyer address bytes (canonical bech32 ASCII, padded to 64 bytes).
    pub buyer_address: [u8; 64],
    pub buyer_addr_len: u8,
    /// Seller address bytes (canonical bech32 ASCII, padded to 64 bytes).
    pub seller_address: [u8; 64],
    pub seller_addr_len: u8,
}

impl Default for FillRecord {
    fn default() -> Self {
        Self {
            fill_id: 0,
            buy_order_id: 0,
            sell_order_id: 0,
            price_micro_usd: 0,
            amount_sat: 0,
            timestamp_ms: 0,
            pair_id: 0,
            buyer_address: [0u8; 64],
            buyer_addr_len: 0,
            seller_address: [0u8; 64],
            seller_addr_len: 0,
        }
    }
}

impl FillRecord {
    /// Encode this record into `out[..FILL_WIRE_SIZE]`.
    ///
    /// Mirrors `Block.encodeFill` in `core/block.zig`.
    pub fn encode(&self, out: &mut [u8; FILL_WIRE_SIZE]) {
        out.fill(0);
        out[0..8].copy_from_slice(&self.fill_id.to_le_bytes());
        out[8..16].copy_from_slice(&self.buy_order_id.to_le_bytes());
        out[16..24].copy_from_slice(&self.sell_order_id.to_le_bytes());
        out[24..32].copy_from_slice(&self.price_micro_usd.to_le_bytes());
        out[32..40].copy_from_slice(&self.amount_sat.to_le_bytes());
        out[40..48].copy_from_slice(&self.timestamp_ms.to_le_bytes());
        out[48..50].copy_from_slice(&self.pair_id.to_le_bytes());
        out[50..114].copy_from_slice(&self.buyer_address);
        out[114] = self.buyer_addr_len;
        out[115..179].copy_from_slice(&self.seller_address);
        out[179] = self.seller_addr_len;
    }

    /// Decode 180 bytes into a `FillRecord`.
    ///
    /// Mirrors `Block.decodeFill` in `core/block.zig`.
    pub fn decode(buf: &[u8; FILL_WIRE_SIZE]) -> Self {
        let mut buyer_address = [0u8; 64];
        let mut seller_address = [0u8; 64];
        buyer_address.copy_from_slice(&buf[50..114]);
        seller_address.copy_from_slice(&buf[115..179]);
        Self {
            fill_id:          u64::from_le_bytes(buf[0..8].try_into().unwrap()),
            buy_order_id:     u64::from_le_bytes(buf[8..16].try_into().unwrap()),
            sell_order_id:    u64::from_le_bytes(buf[16..24].try_into().unwrap()),
            price_micro_usd:  u64::from_le_bytes(buf[24..32].try_into().unwrap()),
            amount_sat:       u64::from_le_bytes(buf[32..40].try_into().unwrap()),
            timestamp_ms:     i64::from_le_bytes(buf[40..48].try_into().unwrap()),
            pair_id:          u16::from_le_bytes(buf[48..50].try_into().unwrap()),
            buyer_address,
            buyer_addr_len:   buf[114],
            seller_address,
            seller_addr_len:  buf[179],
        }
    }
}

/// Compute the fills commitment: SHA-256 over all fill records in canonical
/// wire format, in order.  Empty slice → all-zero hash (matches Zig).
///
/// Mirrors `Block.computeFillsRoot` in `core/block.zig`.
pub fn compute_fills_root(fills: &[FillRecord]) -> [u8; 32] {
    if fills.is_empty() {
        return [0u8; 32];
    }
    let mut h = Sha256::new();
    let mut rec = [0u8; FILL_WIRE_SIZE];
    for f in fills {
        f.encode(&mut rec);
        h.update(&rec);
    }
    let mut out = [0u8; 32];
    out.copy_from_slice(&h.finalize());
    out
}

// ── Oracle price-snapshot helpers (port of block.zig computePricesRoot etc.) ──
//
// The 21-slot snapshot is stored off-chain / in the storage layer; the mining
// layer only needs the root hash that enters `calculate_hash`.
//
// Each PriceEntry encodes:
//   exchange_len: u8, exchange: exchange_len bytes (≤16)
//   pair_len:     u8, pair:     pair_len     bytes (≤16)
//   bid_micro_usd: u64 LE, ask_micro_usd: u64 LE, timestamp_ms: i64 LE
//   success:      u8 (0|1)
//
// If every slot has success=false AND timestamp_ms=0 the hash is all-zero
// ("no prices recorded").

/// Maximum string length for exchange/pair name in a PriceEntry.
pub const PRICE_ENTRY_STR_MAX: usize = 16;
/// Number of oracle price slots per block (7 pairs × 3 venues).
pub const BLOCK_PRICE_SLOTS: usize = 21;

/// One oracle price snapshot entry (per pair per venue).
///
/// Mirrors `BlockPriceEntry` in `core/oracle_types.zig`.
#[derive(Debug, Clone, Default)]
pub struct PriceEntry {
    pub exchange: [u8; PRICE_ENTRY_STR_MAX],
    pub exchange_len: u8,
    pub pair: [u8; PRICE_ENTRY_STR_MAX],
    pub pair_len: u8,
    pub bid_micro_usd: u64,
    pub ask_micro_usd: u64,
    pub timestamp_ms: i64,
    pub success: bool,
}

/// Compute SHA-256 over the canonical price-snapshot encoding.
/// Returns all-zero hash when every slot is empty (no data).
///
/// Mirrors `Block.computePricesRoot` in `core/block.zig`.
pub fn compute_prices_root(entries: &[PriceEntry; BLOCK_PRICE_SLOTS]) -> [u8; 32] {
    let any_data = entries.iter().any(|e| e.success || e.timestamp_ms != 0);
    if !any_data {
        return [0u8; 32];
    }
    let mut h = Sha256::new();
    for e in entries {
        let elen = (e.exchange_len as usize).min(PRICE_ENTRY_STR_MAX) as u8;
        let plen = (e.pair_len as usize).min(PRICE_ENTRY_STR_MAX) as u8;
        h.update(&[elen]);
        h.update(&e.exchange[..elen as usize]);
        h.update(&[plen]);
        h.update(&e.pair[..plen as usize]);
        h.update(&e.bid_micro_usd.to_le_bytes());
        h.update(&e.ask_micro_usd.to_le_bytes());
        h.update(&e.timestamp_ms.to_le_bytes());
        h.update(&[if e.success { 1u8 } else { 0u8 }]);
    }
    let mut out = [0u8; 32];
    out.copy_from_slice(&h.finalize());
    out
}

// ── Extended BlockTemplate helpers ────────────────────────────────────────────

impl BlockTemplate {
    /// Set oracle price snapshot and recompute `prices_root`.
    /// Call BEFORE PoW begins so the block hash commits to the snapshot.
    ///
    /// Mirrors `Block.setPrices` in `core/block.zig`.
    pub fn set_prices(&mut self, entries: [PriceEntry; BLOCK_PRICE_SLOTS]) {
        self.prices_root = compute_prices_root(&entries);
    }

    /// Validate that `prices_root` matches the hash of the given entries.
    pub fn validate_prices(&self, entries: &[PriceEntry; BLOCK_PRICE_SLOTS]) -> bool {
        self.prices_root == compute_prices_root(entries)
    }

    /// Increment nonce by one (utility for single-threaded grinding loop).
    #[inline]
    pub fn tick_nonce(&mut self) {
        self.nonce = self.nonce.wrapping_add(1);
    }

    /// Run a simple single-threaded nonce-grinding loop on this template.
    ///
    /// Returns `true` and updates `self.nonce` when a valid hash is found,
    /// or `false` if `max_attempts` were exhausted.
    /// Mirrors `find_next_nonce` in the Zig consensus module.
    pub fn grind(&mut self, max_attempts: u64) -> bool {
        for _ in 0..max_attempts {
            if self.hash_satisfies_difficulty() {
                return true;
            }
            self.tick_nonce();
        }
        false
    }
}

// ── Tests ─────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    fn tx(hash_byte: u8, from: &str, to: &str, amount: u64) -> Tx {
        let mut h = [0u8; 32];
        h[0] = hash_byte;
        Tx {
            hash: h,
            from_address: from.to_string(),
            to_address: to.to_string(),
            amount,
            fee: 1,
            nonce: 0,
            timestamp_ms: 1_700_000_000,
            signature: vec![],
        }
    }

    fn genesis() -> Block {
        Block::new(0, "0".repeat(64), 1_700_000_000_000)
    }

    #[test]
    fn merkle_root_empty_is_zero() {
        let mr = compute_merkle_root(&[]);
        assert_eq!(mr, [0u8; 32]);
    }

    #[test]
    fn merkle_root_single_tx() {
        let t = tx(0x01, "alice", "bob", 100);
        let mr = compute_merkle_root(&[t.clone()]);
        // Single TX: hash(tx_hash || tx_hash) (Bitcoin duplicate-last rule).
        let mut h = Sha256::new();
        h.update(&t.hash());
        h.update(&t.hash());
        let mut expected = [0u8; 32];
        expected.copy_from_slice(&h.finalize());
        assert_eq!(mr, expected);
    }

    #[test]
    fn merkle_root_changes_with_different_txs() {
        let mr1 = compute_merkle_root(&[tx(0x01, "a", "b", 100)]);
        let mr2 = compute_merkle_root(&[tx(0x02, "c", "d", 200)]);
        assert_ne!(mr1, mr2);
    }

    #[test]
    fn merkle_proof_single_tx_verifies() {
        let txs = vec![tx(0x01, "a", "b", 100)];
        let proof = generate_merkle_proof(&txs, 0).unwrap();
        assert!(proof.verify());
    }

    #[test]
    fn merkle_proof_two_txs_both_verify() {
        let txs = vec![
            tx(0x01, "a", "b", 100),
            tx(0x02, "c", "d", 200),
        ];
        for i in 0..2 {
            let proof = generate_merkle_proof(&txs, i).unwrap();
            assert!(proof.verify(), "proof for tx[{i}] should verify");
        }
    }

    #[test]
    fn merkle_proof_four_txs_all_verify() {
        let txs: Vec<Tx> = (1u8..=4)
            .map(|i| tx(i, "from", "to", i as u64 * 100))
            .collect();
        for i in 0..4 {
            let proof = generate_merkle_proof(&txs, i).unwrap();
            assert!(proof.verify(), "proof for tx[{i}] should verify");
        }
    }

    #[test]
    fn merkle_proof_out_of_range_returns_none() {
        let txs = vec![tx(0x01, "a", "b", 100)];
        assert!(generate_merkle_proof(&txs, 5).is_none());
    }

    #[test]
    fn merkle_proof_empty_returns_none() {
        assert!(generate_merkle_proof(&[], 0).is_none());
    }

    #[test]
    fn block_template_header_hash_differs_on_nonce() {
        let g = genesis();
        let mut t = BlockTemplate {
            index: 1,
            timestamp: 1_700_000_000_000,
            previous_hash: g.calculate_hash_hex(),
            transactions: vec![],
            merkle_root: [0u8; 32],
            prices_root: [0u8; 32],
            miner_address: "ob1qminer".to_string(),
            difficulty: 1,
            nonce: 0,
            total_fees_sat: 0,
            reward_sat: 50_000_000_000,
        };
        let h0 = t.header_hash();
        t.nonce = 1;
        let h1 = t.header_hash();
        assert_ne!(h0, h1);
    }

    #[test]
    fn validate_block_invalid_pow() {
        let g = genesis();
        let mut b = Block::new(1, g.calculate_hash_hex(), 1_700_000_000_001);
        b.hash = "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff".to_string();
        // difficulty=1 requires at least one leading '0' — 'f' fails.
        assert_eq!(validate_block(&b, &g, 1), BlockValidation::InvalidPoW);
    }

    #[test]
    fn validate_block_height_mismatch() {
        let g = genesis();
        let mut b = Block::new(5, g.calculate_hash_hex(), 1_700_000_000_001);
        b.hash = "0".repeat(64);
        assert_eq!(validate_block(&b, &g, 1), BlockValidation::HeightMismatch);
    }

    #[test]
    fn validate_block_prev_hash_mismatch() {
        let g = genesis();
        let mut b = Block::new(1, "deadbeef".to_string(), 1_700_000_000_001);
        b.hash = "0".repeat(64);
        assert_eq!(validate_block(&b, &g, 1), BlockValidation::PrevHashMismatch);
    }

    // ── FillRecord codec ──────────────────────────────────────────────────────

    #[test]
    fn fill_encode_decode_roundtrip() {
        let mut f = FillRecord {
            fill_id: 1,
            buy_order_id: 2,
            sell_order_id: 3,
            price_micro_usd: 65_000_000_000,
            amount_sat: 100_000_000,
            timestamp_ms: 1_700_000_123_456,
            pair_id: 7,
            ..Default::default()
        };
        let addr = b"ob1qminer0000000000000000000000000000000000000000000000000000000";
        f.buyer_address[..addr.len()].copy_from_slice(addr);
        f.buyer_addr_len = addr.len() as u8;
        f.seller_address[..addr.len()].copy_from_slice(addr);
        f.seller_addr_len = addr.len() as u8;

        let mut buf = [0u8; FILL_WIRE_SIZE];
        f.encode(&mut buf);
        let decoded = FillRecord::decode(&buf);

        assert_eq!(decoded.fill_id, f.fill_id);
        assert_eq!(decoded.buy_order_id, f.buy_order_id);
        assert_eq!(decoded.sell_order_id, f.sell_order_id);
        assert_eq!(decoded.price_micro_usd, f.price_micro_usd);
        assert_eq!(decoded.amount_sat, f.amount_sat);
        assert_eq!(decoded.timestamp_ms, f.timestamp_ms);
        assert_eq!(decoded.pair_id, f.pair_id);
        assert_eq!(decoded.buyer_address, f.buyer_address);
        assert_eq!(decoded.buyer_addr_len, f.buyer_addr_len);
    }

    #[test]
    fn fills_root_empty_is_zero() {
        assert_eq!(compute_fills_root(&[]), [0u8; 32]);
    }

    #[test]
    fn fills_root_nonempty_is_nonzero_and_deterministic() {
        let f = FillRecord { fill_id: 42, amount_sat: 1_000, ..Default::default() };
        let r1 = compute_fills_root(&[f.clone()]);
        let r2 = compute_fills_root(&[f.clone()]);
        assert_ne!(r1, [0u8; 32]);
        assert_eq!(r1, r2);
    }

    #[test]
    fn fills_root_changes_with_different_fills() {
        let f1 = FillRecord { fill_id: 1, amount_sat: 100, ..Default::default() };
        let f2 = FillRecord { fill_id: 2, amount_sat: 200, ..Default::default() };
        assert_ne!(compute_fills_root(&[f1]), compute_fills_root(&[f2]));
    }

    // ── PriceEntry / compute_prices_root ─────────────────────────────────────

    #[test]
    fn prices_root_empty_snapshot_is_zero() {
        let entries: [PriceEntry; BLOCK_PRICE_SLOTS] = std::array::from_fn(|_| PriceEntry::default());
        assert_eq!(compute_prices_root(&entries), [0u8; 32]);
    }

    #[test]
    fn prices_root_with_data_is_nonzero_and_deterministic() {
        let mut entries: [PriceEntry; BLOCK_PRICE_SLOTS] = std::array::from_fn(|_| PriceEntry::default());
        let e = &mut entries[0];
        e.exchange[..7].copy_from_slice(b"Coinbase"[..7].as_ref());
        e.exchange_len = 8;
        e.pair[..7].copy_from_slice(b"BTC/USD"[..7].as_ref());
        e.pair_len = 7;
        e.bid_micro_usd = 65_000_000_000;
        e.ask_micro_usd = 65_001_000_000;
        e.timestamp_ms = 1_700_000_000;
        e.success = true;

        let r1 = compute_prices_root(&entries);
        let r2 = compute_prices_root(&entries);
        assert_ne!(r1, [0u8; 32]);
        assert_eq!(r1, r2);
    }

    #[test]
    fn prices_root_changes_when_bid_changes() {
        let mut entries: [PriceEntry; BLOCK_PRICE_SLOTS] = std::array::from_fn(|_| PriceEntry::default());
        entries[0].bid_micro_usd = 100;
        entries[0].success = true;
        let r1 = compute_prices_root(&entries);
        entries[0].bid_micro_usd = 101;
        let r2 = compute_prices_root(&entries);
        assert_ne!(r1, r2);
    }

    // ── BlockTemplate::grind ─────────────────────────────────────────────────

    #[test]
    fn template_grind_finds_difficulty_1() {
        let g = genesis();
        let mut t = BlockTemplate {
            index: 1,
            timestamp: 1_700_000_000_000,
            previous_hash: g.calculate_hash_hex(),
            transactions: vec![],
            merkle_root: [0u8; 32],
            prices_root: [0u8; 32],
            miner_address: "ob1qminer".to_string(),
            difficulty: 1,
            nonce: 0,
            total_fees_sat: 0,
            reward_sat: 8_333_333,
        };
        let found = t.grind(50_000);
        assert!(found, "grind should find difficulty=1 in 50k attempts");
        assert!(t.hash_satisfies_difficulty());
    }

    #[test]
    fn template_set_prices_updates_hash() {
        let g = genesis();
        let mut t = BlockTemplate {
            index: 1,
            timestamp: 1_700_000_000_000,
            previous_hash: g.calculate_hash_hex(),
            transactions: vec![],
            merkle_root: [0u8; 32],
            prices_root: [0u8; 32],
            miner_address: "ob1qminer".to_string(),
            difficulty: 1,
            nonce: 0,
            total_fees_sat: 0,
            reward_sat: 8_333_333,
        };
        let h_before = t.header_hash();
        let mut entries: [PriceEntry; BLOCK_PRICE_SLOTS] = std::array::from_fn(|_| PriceEntry::default());
        entries[0].bid_micro_usd = 65_000_000_000;
        entries[0].success = true;
        t.set_prices(entries);
        let h_after = t.header_hash();
        assert_ne!(h_before, h_after, "prices commitment should change block hash");
    }
}
