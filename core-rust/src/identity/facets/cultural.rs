//! Cultural Facet (leaf index 8 of master Manifest).
//!
//! Top tree: [poaps_root, works_root, badges_root, langs_leaf].
//! Private notarized works commit `SHA-256(work_hash || "private_work")`.

use sha2::{Digest, Sha256};

use crate::identity::merkle::{self, Hash, ProofStep};

#[repr(u8)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum WorkKind {
    Poem = 1,
    Music = 2,
    Visual = 3,
    Text = 4,
    Code = 5,
    Translation = 6,
    Other = 99,
}

#[derive(Clone, Debug)]
pub struct Poap {
    pub event_id: [u8; 32],
    pub event_unix_s: u64,
    pub claim_unix_s: u64,
}

#[derive(Clone, Debug)]
pub struct NotarizedWork {
    pub work_hash: [u8; 32],
    pub kind: WorkKind,
    pub notarized_unix_s: u64,
    pub is_public: bool,
}

#[derive(Clone, Debug, Default)]
pub struct CulturalFacet {
    pub poaps: Vec<Poap>,
    pub notarized_works: Vec<NotarizedWork>,
    pub cultural_badges: Vec<u32>,
    pub language_tags: Vec<u8>, // free-form ISO 639-1 sequence
}

const ZERO_LEAF: Hash = [0u8; 32];

fn leaf_for_poap(p: &Poap) -> Hash {
    let mut buf = [0u8; 48];
    buf[0..32].copy_from_slice(&p.event_id);
    buf[32..40].copy_from_slice(&p.event_unix_s.to_le_bytes());
    buf[40..48].copy_from_slice(&p.claim_unix_s.to_le_bytes());
    merkle::hash_leaf(&buf)
}

fn leaf_for_work(w: &NotarizedWork) -> Hash {
    if w.is_public {
        let mut buf = [0u8; 41];
        buf[0..32].copy_from_slice(&w.work_hash);
        buf[32] = w.kind as u8;
        buf[33..41].copy_from_slice(&w.notarized_unix_s.to_le_bytes());
        merkle::hash_leaf(&buf)
    } else {
        let mut inner = [0u8; 32 + 12];
        inner[0..32].copy_from_slice(&w.work_hash);
        inner[32..44].copy_from_slice(b"private_work");
        let hidden: [u8; 32] = Sha256::digest(inner).into();
        merkle::hash_leaf(&hidden)
    }
}

fn leaf_for_badge(b: u32) -> Hash {
    merkle::hash_leaf(&b.to_le_bytes())
}

fn section_root(leaves: &[Hash]) -> Hash {
    if leaves.is_empty() {
        return ZERO_LEAF;
    }
    merkle::root_of_leaf_hashes(leaves)
}

fn build_poap_leaves(f: &CulturalFacet) -> Vec<Hash> {
    f.poaps.iter().map(leaf_for_poap).collect()
}

fn build_work_leaves(f: &CulturalFacet) -> Vec<Hash> {
    f.notarized_works.iter().map(leaf_for_work).collect()
}

fn build_badge_leaves(f: &CulturalFacet) -> Vec<Hash> {
    f.cultural_badges.iter().map(|b| leaf_for_badge(*b)).collect()
}

fn language_leaf(f: &CulturalFacet) -> Hash {
    merkle::hash_leaf(&f.language_tags)
}

fn top_leaves(f: &CulturalFacet) -> [Hash; 4] {
    [
        section_root(&build_poap_leaves(f)),
        section_root(&build_work_leaves(f)),
        section_root(&build_badge_leaves(f)),
        language_leaf(f),
    ]
}

pub fn compute_cultural_root(f: &CulturalFacet) -> Hash {
    merkle::root_of_leaf_hashes(&top_leaves(f))
}

#[derive(Clone, Debug)]
pub struct PoapProof {
    pub poap: Poap,
    pub proof: Vec<ProofStep>,
}

#[derive(Clone, Debug)]
pub struct WorkProof {
    pub work: NotarizedWork,
    pub proof: Vec<ProofStep>,
}

pub fn prove_poap(f: &CulturalFacet, idx: usize) -> Result<PoapProof, &'static str> {
    if idx >= f.poaps.len() {
        return Err("index out of range");
    }
    let poap_leaves = build_poap_leaves(f);
    let mut inner = merkle::prove_leaf(&poap_leaves, idx)?;
    let tops = top_leaves(f);
    let outer = merkle::prove_leaf(&tops, 0)?;
    inner.extend(outer);
    Ok(PoapProof { poap: f.poaps[idx].clone(), proof: inner })
}

pub fn verify_poap(p: &PoapProof, facet_root: Hash) -> bool {
    merkle::verify_proof(leaf_for_poap(&p.poap), &p.proof, facet_root)
}

pub fn prove_work(f: &CulturalFacet, idx: usize) -> Result<WorkProof, &'static str> {
    if idx >= f.notarized_works.len() {
        return Err("index out of range");
    }
    let work_leaves = build_work_leaves(f);
    let mut inner = merkle::prove_leaf(&work_leaves, idx)?;
    let tops = top_leaves(f);
    let outer = merkle::prove_leaf(&tops, 1)?;
    inner.extend(outer);
    Ok(WorkProof { work: f.notarized_works[idx].clone(), proof: inner })
}

pub fn verify_work(p: &WorkProof, facet_root: Hash) -> bool {
    merkle::verify_proof(leaf_for_work(&p.work), &p.proof, facet_root)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn dummy_hash(seed: u8) -> [u8; 32] {
        let mut h = [0u8; 32];
        for (i, b) in h.iter_mut().enumerate() {
            *b = seed.wrapping_add(i as u8);
        }
        h
    }

    #[test]
    fn deterministic_root() {
        let f = CulturalFacet {
            poaps: vec![Poap { event_id: dummy_hash(1), event_unix_s: 1000, claim_unix_s: 1001 }],
            notarized_works: vec![NotarizedWork {
                work_hash: dummy_hash(2),
                kind: WorkKind::Poem,
                notarized_unix_s: 2000,
                is_public: true,
            }],
            cultural_badges: vec![1, 2, 4],
            language_tags: b"rofrenes".to_vec(),
        };
        assert_eq!(compute_cultural_root(&f), compute_cultural_root(&f));
    }

    #[test]
    fn toggling_is_public_changes_root() {
        let pub_w = CulturalFacet {
            notarized_works: vec![NotarizedWork {
                work_hash: dummy_hash(13),
                kind: WorkKind::Text,
                notarized_unix_s: 42,
                is_public: true,
            }],
            ..Default::default()
        };
        let priv_w = CulturalFacet {
            notarized_works: vec![NotarizedWork {
                work_hash: dummy_hash(13),
                kind: WorkKind::Text,
                notarized_unix_s: 42,
                is_public: false,
            }],
            ..Default::default()
        };
        assert_ne!(compute_cultural_root(&pub_w), compute_cultural_root(&priv_w));
    }

    #[test]
    fn prove_poap_roundtrip_and_tamper() {
        let f = CulturalFacet {
            poaps: vec![
                Poap { event_id: dummy_hash(20), event_unix_s: 1, claim_unix_s: 2 },
                Poap { event_id: dummy_hash(21), event_unix_s: 3, claim_unix_s: 4 },
                Poap { event_id: dummy_hash(22), event_unix_s: 5, claim_unix_s: 6 },
            ],
            notarized_works: vec![NotarizedWork {
                work_hash: dummy_hash(30),
                kind: WorkKind::Code,
                notarized_unix_s: 77,
                is_public: true,
            }],
            cultural_badges: vec![1, 3],
            language_tags: b"rofr".to_vec(),
        };
        let root = compute_cultural_root(&f);
        let p = prove_poap(&f, 1).unwrap();
        assert!(verify_poap(&p, root));
        let mut bad = p.clone();
        bad.poap.claim_unix_s = 9999;
        assert!(!verify_poap(&bad, root));
    }

    #[test]
    fn prove_work_public_and_private() {
        let f = CulturalFacet {
            poaps: vec![Poap { event_id: dummy_hash(40), event_unix_s: 100, claim_unix_s: 101 }],
            notarized_works: vec![
                NotarizedWork { work_hash: dummy_hash(50), kind: WorkKind::Poem, notarized_unix_s: 1, is_public: true },
                NotarizedWork { work_hash: dummy_hash(51), kind: WorkKind::Visual, notarized_unix_s: 2, is_public: false },
                NotarizedWork { work_hash: dummy_hash(52), kind: WorkKind::Translation, notarized_unix_s: 3, is_public: true },
            ],
            cultural_badges: vec![2, 4],
            language_tags: b"endeit".to_vec(),
        };
        let root = compute_cultural_root(&f);
        for i in 0..3 {
            let p = prove_work(&f, i).unwrap();
            assert!(verify_work(&p, root));
        }
    }

    #[test]
    fn empty_root_nonzero() {
        let r = compute_cultural_root(&CulturalFacet::default());
        assert_ne!(r, [0u8; 32]);
    }
}
