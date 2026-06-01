//! Identity Manifest — 10-leaf Merkle tree.
//!
//! Leaf order (FIXED — proofs are tied to these indices):
//!   0: kyc_hash (32)
//!   1: assets_root (32)
//!   2: reputation_snapshot (16 — 4 cups × u32 LE)
//!   3: pq_keys_hash (32 — SHA-256 of concatenated PQ pubkeys)
//!   4: obm (1)
//!   5: timestamp (8 — u64 LE)
//!   6: social_root (32)
//!   7: professional_root (32)
//!   8: cultural_root (32)
//!   9: economic_root (32)
//!
//! The chain anchors ONLY the Merkle root.

use sha2::{Digest, Sha256};

use super::merkle::{self, Hash};
use super::obm::{Obm, ReputationCups};

#[repr(u8)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum FieldIndex {
    KycHash = 0,
    AssetsRoot = 1,
    ReputationSnapshot = 2,
    PqKeysHash = 3,
    Obm = 4,
    Timestamp = 5,
    SocialRoot = 6,
    ProfessionalRoot = 7,
    CulturalRoot = 8,
    EconomicRoot = 9,
}

pub const FIELD_COUNT: usize = 10;

pub type KycHash = [u8; 32];
pub type ManifestRoot = [u8; 32];

#[derive(Clone, Debug)]
pub struct Manifest {
    pub kyc_hash: KycHash,
    pub assets_root: [u8; 32],
    pub reputation: ReputationCups,
    pub pq_pubkeys_concat: Vec<u8>,
    pub obm: Obm,
    pub timestamp_unix_s: u64,
    pub social_root: [u8; 32],
    pub professional_root: [u8; 32],
    pub cultural_root: [u8; 32],
    pub economic_root: [u8; 32],
}

impl Manifest {
    pub fn zeroed() -> Self {
        Self {
            kyc_hash: [0u8; 32],
            assets_root: [0u8; 32],
            reputation: ReputationCups::default(),
            pq_pubkeys_concat: Vec::new(),
            obm: 0,
            timestamp_unix_s: 0,
            social_root: [0u8; 32],
            professional_root: [0u8; 32],
            cultural_root: [0u8; 32],
            economic_root: [0u8; 32],
        }
    }
}

/// 16-byte little-endian serialization of the 4 cups (matches Zig).
pub fn serialize_reputation_field(cups: ReputationCups) -> [u8; 16] {
    let mut out = [0u8; 16];
    out[0..4].copy_from_slice(&cups.love_stored.to_le_bytes());
    out[4..8].copy_from_slice(&cups.food_stored.to_le_bytes());
    out[8..12].copy_from_slice(&cups.rent_stored.to_le_bytes());
    out[12..16].copy_from_slice(&cups.vacation_stored.to_le_bytes());
    out
}

pub fn hash_pq_keys(pq_pubkeys_concat: &[u8]) -> [u8; 32] {
    Sha256::digest(pq_pubkeys_concat).into()
}

pub fn compute_leaf_hashes(m: &Manifest) -> [Hash; FIELD_COUNT] {
    let rep_bytes = serialize_reputation_field(m.reputation);
    let pq_hash = hash_pq_keys(&m.pq_pubkeys_concat);
    let ts_bytes = m.timestamp_unix_s.to_le_bytes();
    let obm_byte = [m.obm];

    [
        merkle::hash_leaf(&m.kyc_hash),
        merkle::hash_leaf(&m.assets_root),
        merkle::hash_leaf(&rep_bytes),
        merkle::hash_leaf(&pq_hash),
        merkle::hash_leaf(&obm_byte),
        merkle::hash_leaf(&ts_bytes),
        merkle::hash_leaf(&m.social_root),
        merkle::hash_leaf(&m.professional_root),
        merkle::hash_leaf(&m.cultural_root),
        merkle::hash_leaf(&m.economic_root),
    ]
}

pub fn compute_root(m: &Manifest) -> ManifestRoot {
    let leaves = compute_leaf_hashes(m);
    merkle::root_of_leaf_hashes(&leaves)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample() -> Manifest {
        Manifest {
            kyc_hash: [1u8; 32],
            assets_root: [2u8; 32],
            reputation: ReputationCups {
                love_stored: 5000,
                food_stored: 4000,
                rent_stored: 3000,
                vacation_stored: 2000,
            },
            pq_pubkeys_concat: Vec::new(),
            obm: 0b0000_1111,
            timestamp_unix_s: 1_780_000_000,
            social_root: [0u8; 32],
            professional_root: [0u8; 32],
            cultural_root: [0u8; 32],
            economic_root: [0u8; 32],
        }
    }

    #[test]
    fn root_is_deterministic() {
        assert_eq!(compute_root(&sample()), compute_root(&sample()));
    }

    #[test]
    fn root_changes_on_field_flip() {
        let a = compute_root(&sample());
        let mut t = sample();
        t.obm = t.obm ^ 1;
        assert_ne!(a, compute_root(&t));
    }

    #[test]
    fn rep_field_le_layout() {
        let cups = ReputationCups {
            love_stored: 0x1122_3344,
            food_stored: 0x5566_7788,
            rent_stored: 0x99AA_BBCC,
            vacation_stored: 0xDDEE_FF00,
        };
        let b = serialize_reputation_field(cups);
        assert_eq!(b[0], 0x44);
        assert_eq!(b[3], 0x11);
        assert_eq!(b[12], 0x00);
        assert_eq!(b[15], 0xDD);
    }

    #[test]
    fn field_indices_stable() {
        assert_eq!(FieldIndex::Timestamp as u8, 5);
        assert_eq!(FieldIndex::SocialRoot as u8, 6);
        assert_eq!(FieldIndex::EconomicRoot as u8, 9);
        assert_eq!(FIELD_COUNT, 10);
    }
}
