//! SPV block header + Merkle inclusion proofs.
//!
//! Two related formats coexist in this codebase:
//!
//!   * **Native (Zig core/light_client.zig)** — `BlockHeader.serialize()` is
//!     200 bytes (index u32 + ts i64 + prev 32 + merkle 32 + nonce u64 +
//!     hash 32 + difficulty u32 + tx_count u32 + sub_blocks u8 + pad).
//!     Used for on-disk header storage in the Zig node.
//!
//!   * **P2P SPV wire (this struct)** — 124 bytes, see `p2p::wire`. Used by
//!     SPV light-client peers when downloading just headers. Layout:
//!     `index(8) + timestamp(8) + prev(32) + merkle(32) + hash(32) +
//!      difficulty(4) + nonce(8) = 124`.
//!
//! The Rust port treats `SpvBlockHeader` as the canonical light-client header
//! (the Zig P2P stack also uses the 124-byte form on the wire). The 200-byte
//! native serialization remains in the full-node storage layer.

use byteorder::{ByteOrder, LittleEndian};
use sha2::{Digest, Sha256};

/// SPV block header wire size (P2P).
pub const SPV_HEADER_SIZE: usize = 124;

/// Max merkle tree depth (2^20 ≈ 1M tx/block). Matches Zig MAX_MERKLE_DEPTH.
pub const MAX_MERKLE_DEPTH: usize = 20;

/// Compact block header used by SPV light clients.
///
/// Field layout (124 bytes, little-endian):
/// ```text
///   offset  size  field
///        0     8  index           u64
///        8     8  timestamp       i64
///       16    32  previous_hash   [u8; 32]
///       48    32  merkle_root     [u8; 32]
///       80    32  hash            [u8; 32]
///      112     4  difficulty      u32
///      116     8  nonce           u64
///      ----  ---
///            124  total
/// ```
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SpvBlockHeader {
    pub index: u64,
    pub timestamp: i64,
    pub previous_hash: [u8; 32],
    pub merkle_root: [u8; 32],
    pub hash: [u8; 32],
    pub difficulty: u32,
    pub nonce: u64,
}

impl SpvBlockHeader {
    pub fn zero() -> Self {
        Self {
            index: 0,
            timestamp: 0,
            previous_hash: [0u8; 32],
            merkle_root: [0u8; 32],
            hash: [0u8; 32],
            difficulty: 4,
            nonce: 0,
        }
    }

    pub fn new(index: u64) -> Self {
        let mut h = Self::zero();
        h.index = index;
        h
    }

    /// Serialize to 124-byte little-endian wire format.
    pub fn serialize(&self) -> [u8; SPV_HEADER_SIZE] {
        let mut buf = [0u8; SPV_HEADER_SIZE];
        self.write_to(&mut buf);
        buf
    }

    pub fn write_to(&self, buf: &mut [u8; SPV_HEADER_SIZE]) {
        LittleEndian::write_u64(&mut buf[0..8], self.index);
        LittleEndian::write_i64(&mut buf[8..16], self.timestamp);
        buf[16..48].copy_from_slice(&self.previous_hash);
        buf[48..80].copy_from_slice(&self.merkle_root);
        buf[80..112].copy_from_slice(&self.hash);
        LittleEndian::write_u32(&mut buf[112..116], self.difficulty);
        LittleEndian::write_u64(&mut buf[116..124], self.nonce);
    }

    pub fn deserialize(buf: &[u8; SPV_HEADER_SIZE]) -> Self {
        let mut h = Self::zero();
        h.index = LittleEndian::read_u64(&buf[0..8]);
        h.timestamp = LittleEndian::read_i64(&buf[8..16]);
        h.previous_hash.copy_from_slice(&buf[16..48]);
        h.merkle_root.copy_from_slice(&buf[48..80]);
        h.hash.copy_from_slice(&buf[80..112]);
        h.difficulty = LittleEndian::read_u32(&buf[112..116]);
        h.nonce = LittleEndian::read_u64(&buf[116..124]);
        h
    }
}

/// Merkle inclusion proof for a single transaction.
///
/// Mirrors Zig `MerkleProof` from core/light_client.zig.
#[derive(Debug, Clone)]
pub struct MerkleProof {
    pub tx_hash: [u8; 32],
    pub proof_hashes: Vec<[u8; 32]>, // sibling hashes
    pub directions: Vec<bool>,        // true = sibling is on the right
    pub merkle_root: [u8; 32],
    pub block_index: u64,
    pub tx_index: u32,
}

impl MerkleProof {
    pub fn new(tx_hash: [u8; 32], merkle_root: [u8; 32], block_index: u64, tx_index: u32) -> Self {
        Self {
            tx_hash,
            proof_hashes: Vec::new(),
            directions: Vec::new(),
            merkle_root,
            block_index,
            tx_index,
        }
    }

    pub fn add_step(&mut self, sibling: [u8; 32], is_right: bool) {
        if self.proof_hashes.len() >= MAX_MERKLE_DEPTH {
            return;
        }
        self.proof_hashes.push(sibling);
        self.directions.push(is_right);
    }

    pub fn depth(&self) -> usize {
        self.proof_hashes.len()
    }
}

/// Verify a merkle proof: hash tx with siblings up to root.
///
/// Special case: depth 0 means single-TX block where tx_hash IS the merkle root.
pub fn verify_merkle_proof(proof: &MerkleProof) -> bool {
    if proof.proof_hashes.is_empty() {
        return proof.tx_hash == proof.merkle_root;
    }

    let mut current = proof.tx_hash;
    for (i, sibling) in proof.proof_hashes.iter().enumerate() {
        let is_right = proof.directions[i];
        let mut hasher = Sha256::new();
        if is_right {
            // sibling on right: H(current || sibling)
            hasher.update(&current);
            hasher.update(sibling);
        } else {
            // sibling on left: H(sibling || current)
            hasher.update(sibling);
            hasher.update(&current);
        }
        current.copy_from_slice(&hasher.finalize());
    }
    current == proof.merkle_root
}

/// Validate a header against the previous one (chain linkage rules — no PoW yet).
/// Matches Zig `LightClient.validateHeader`.
///
/// Rules:
///   - difficulty > 0
///   - index == prev.index + 1
///   - previous_hash == prev.hash
///   - timestamp not more than 2h in the future
///   - timestamp >= prev.timestamp
pub fn validate_against_prev(prev: &SpvBlockHeader, next: &SpvBlockHeader, now_secs: i64) -> bool {
    if next.difficulty == 0 {
        return false;
    }
    if next.index != prev.index + 1 {
        return false;
    }
    if next.previous_hash != prev.hash {
        return false;
    }
    let two_hours: i64 = 2 * 60 * 60;
    if next.timestamp > now_secs + two_hours {
        return false;
    }
    if next.timestamp < prev.timestamp {
        return false;
    }
    true
}

/// Verify a header chain (linkage only — PoW verification is the caller's job;
/// difficulty retarget lives in consensus::retarget_difficulty()).
pub fn verify_chain(headers: &[SpvBlockHeader]) -> bool {
    if headers.len() < 2 {
        return true;
    }
    for i in 1..headers.len() {
        let prev = &headers[i - 1];
        let curr = &headers[i];
        if curr.previous_hash != prev.hash {
            return false;
        }
        if curr.index != prev.index + 1 {
            return false;
        }
    }
    true
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn serialize_roundtrip() {
        let mut h = SpvBlockHeader::new(42);
        h.timestamp = 1_743_000_000;
        h.previous_hash = [0xAA; 32];
        h.merkle_root = [0xBB; 32];
        h.hash = [0xCC; 32];
        h.difficulty = 7;
        h.nonce = 0xDEAD_BEEF_CAFE;

        let buf = h.serialize();
        assert_eq!(buf.len(), 124);
        let h2 = SpvBlockHeader::deserialize(&buf);
        assert_eq!(h, h2);
    }

    #[test]
    fn serialize_offsets() {
        // Verify the exact byte-level layout.
        let mut h = SpvBlockHeader::zero();
        h.index = 0x01_02_03_04_05_06_07_08;
        h.timestamp = 0x11_12_13_14_15_16_17_18;
        h.previous_hash[0] = 0x21;
        h.merkle_root[0] = 0x31;
        h.hash[0] = 0x41;
        h.difficulty = 0x51_52_53_54;
        h.nonce = 0x61_62_63_64_65_66_67_68;

        let buf = h.serialize();
        // index at offset 0, LE
        assert_eq!(&buf[0..8], &[0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01]);
        // timestamp at 8
        assert_eq!(buf[8], 0x18);
        // previous_hash at 16
        assert_eq!(buf[16], 0x21);
        // merkle_root at 48
        assert_eq!(buf[48], 0x31);
        // hash at 80
        assert_eq!(buf[80], 0x41);
        // difficulty at 112, LE
        assert_eq!(&buf[112..116], &[0x54, 0x53, 0x52, 0x51]);
        // nonce at 116
        assert_eq!(buf[116], 0x68);
    }

    #[test]
    fn merkle_proof_two_tx() {
        let mut h0 = Sha256::new();
        h0.update(b"tx0");
        let mut tx0 = [0u8; 32];
        tx0.copy_from_slice(&h0.finalize());

        let mut h1 = Sha256::new();
        h1.update(b"tx1");
        let mut tx1 = [0u8; 32];
        tx1.copy_from_slice(&h1.finalize());

        let mut hr = Sha256::new();
        hr.update(&tx0);
        hr.update(&tx1);
        let mut root = [0u8; 32];
        root.copy_from_slice(&hr.finalize());

        let mut proof = MerkleProof::new(tx0, root, 0, 0);
        proof.add_step(tx1, true);
        assert!(verify_merkle_proof(&proof));

        // Wrong sibling
        let mut bad = MerkleProof::new(tx0, root, 0, 0);
        bad.add_step([0xAA; 32], true);
        assert!(!verify_merkle_proof(&bad));
    }

    #[test]
    fn merkle_proof_depth_zero() {
        let tx = [0x42u8; 32];
        let p_ok = MerkleProof::new(tx, tx, 0, 0);
        assert!(verify_merkle_proof(&p_ok));
        let p_bad = MerkleProof::new(tx, [0xFF; 32], 0, 0);
        assert!(!verify_merkle_proof(&p_bad));
    }

    #[test]
    fn chain_link_check() {
        let mut a = SpvBlockHeader::new(0);
        a.hash = [0xAA; 32];
        let mut b = SpvBlockHeader::new(1);
        b.previous_hash = [0xAA; 32];
        b.hash = [0xBB; 32];
        let mut c = SpvBlockHeader::new(2);
        c.previous_hash = [0xBB; 32];

        assert!(verify_chain(&[a.clone(), b.clone(), c.clone()]));

        // Break the chain
        let mut bad = c.clone();
        bad.previous_hash = [0x00; 32];
        assert!(!verify_chain(&[a, b, bad]));
    }
}
