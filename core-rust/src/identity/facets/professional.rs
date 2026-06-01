//! Professional Facet (leaf index 7 of master Manifest).
//!
//! Top tree: [certifications_subroot, work_subroot, endorsements_leaf, visibility_leaf].

use crate::identity::merkle::{self, Hash, ProofStep};

#[derive(Clone, Debug)]
pub struct Certification {
    pub issuer_did_hash: [u8; 32],
    pub subject_did_hash: [u8; 32],
    pub credential_kind: u32, // degree=1, cert=2, license=3, ...
    pub issued_at_unix_s: u64,
    pub expires_at_unix_s: u64, // 0 = never expires
    pub hash: [u8; 32],
}

#[derive(Clone, Debug)]
pub struct WorkEntry {
    pub employer_did_hash: [u8; 32],
    pub started_unix_s: u64,
    pub ended_unix_s: u64, // 0 = current
    pub role_hash: [u8; 32],
}

#[derive(Clone, Debug, Default)]
pub struct ProfessionalFacet {
    pub certifications: Vec<Certification>,
    pub work_history: Vec<WorkEntry>,
    pub endorsements_count: u32,
    pub visibility_mask: u8,
}

pub const VIS_CERTIFICATIONS: u8 = 1 << 0;
pub const VIS_WORK_HISTORY: u8 = 1 << 1;
pub const VIS_ENDORSEMENTS: u8 = 1 << 2;

const ZERO_LEAF: Hash = [0u8; 32];

fn cert_leaf_bytes(c: &Certification) -> [u8; 136] {
    let mut buf = [0u8; 136];
    buf[0..32].copy_from_slice(&c.issuer_did_hash);
    buf[32..64].copy_from_slice(&c.subject_did_hash);
    buf[64..68].copy_from_slice(&c.credential_kind.to_le_bytes());
    buf[68..76].copy_from_slice(&c.issued_at_unix_s.to_le_bytes());
    buf[76..84].copy_from_slice(&c.expires_at_unix_s.to_le_bytes());
    buf[84..116].copy_from_slice(&c.hash);
    // 116..136 already zero
    buf
}

fn work_leaf_bytes(w: &WorkEntry) -> [u8; 104] {
    let mut buf = [0u8; 104];
    buf[0..32].copy_from_slice(&w.employer_did_hash);
    buf[32..40].copy_from_slice(&w.started_unix_s.to_le_bytes());
    buf[40..48].copy_from_slice(&w.ended_unix_s.to_le_bytes());
    buf[48..80].copy_from_slice(&w.role_hash);
    buf
}

fn cert_leaf_hash(c: &Certification) -> Hash {
    merkle::hash_leaf(&cert_leaf_bytes(c))
}

fn work_leaf_hash(w: &WorkEntry) -> Hash {
    merkle::hash_leaf(&work_leaf_bytes(w))
}

fn top_leaves(facet: &ProfessionalFacet) -> [Hash; 4] {
    let cert_subroot = if facet.certifications.is_empty() {
        ZERO_LEAF
    } else {
        let leaves: Vec<Hash> = facet.certifications.iter().map(cert_leaf_hash).collect();
        merkle::root_of_leaf_hashes(&leaves)
    };
    let work_subroot = if facet.work_history.is_empty() {
        ZERO_LEAF
    } else {
        let leaves: Vec<Hash> = facet.work_history.iter().map(work_leaf_hash).collect();
        merkle::root_of_leaf_hashes(&leaves)
    };
    let endorsements_leaf = merkle::hash_leaf(&facet.endorsements_count.to_le_bytes());
    let visibility_leaf = merkle::hash_leaf(&[facet.visibility_mask]);
    [cert_subroot, work_subroot, endorsements_leaf, visibility_leaf]
}

pub fn compute_professional_root(facet: &ProfessionalFacet) -> Hash {
    merkle::root_of_leaf_hashes(&top_leaves(facet))
}

#[derive(Clone, Debug)]
pub struct CertProof {
    pub cert: Certification,
    /// Inner steps inside cert subtree, then outer steps from subroot (leaf 0)
    /// up to facet root.
    pub proof: Vec<ProofStep>,
}

pub fn prove_certification(
    facet: &ProfessionalFacet,
    cert_index: usize,
) -> Result<CertProof, &'static str> {
    if cert_index >= facet.certifications.len() {
        return Err("index out of range");
    }
    let cert_leaves: Vec<Hash> = facet.certifications.iter().map(cert_leaf_hash).collect();
    let mut inner = merkle::prove_leaf(&cert_leaves, cert_index)?;
    let tops = top_leaves(facet);
    let outer = merkle::prove_leaf(&tops, 0)?;
    inner.extend(outer);
    Ok(CertProof {
        cert: facet.certifications[cert_index].clone(),
        proof: inner,
    })
}

pub fn verify_certification(proof: &CertProof, facet_root: Hash) -> bool {
    let leaf = cert_leaf_hash(&proof.cert);
    merkle::verify_proof(leaf, &proof.proof, facet_root)
}

pub fn is_cert_currently_valid(c: &Certification, now_unix_s: u64) -> bool {
    if c.expires_at_unix_s == 0 {
        return true;
    }
    c.expires_at_unix_s > now_unix_s
}

#[cfg(test)]
mod tests {
    use super::*;

    fn dummy_cert(seed: u8) -> Certification {
        Certification {
            issuer_did_hash: [seed; 32],
            subject_did_hash: [seed.wrapping_add(1); 32],
            credential_kind: seed as u32,
            issued_at_unix_s: 1_700_000_000,
            expires_at_unix_s: 1_900_000_000,
            hash: [seed.wrapping_add(2); 32],
        }
    }

    fn dummy_work(seed: u8) -> WorkEntry {
        WorkEntry {
            employer_did_hash: [seed.wrapping_add(10); 32],
            started_unix_s: 1_600_000_000,
            ended_unix_s: 0,
            role_hash: [seed.wrapping_add(11); 32],
        }
    }

    #[test]
    fn deterministic_root() {
        let f = ProfessionalFacet {
            certifications: vec![dummy_cert(1), dummy_cert(2)],
            work_history: vec![dummy_work(1)],
            endorsements_count: 42,
            visibility_mask: VIS_CERTIFICATIONS,
        };
        assert_eq!(compute_professional_root(&f), compute_professional_root(&f));
    }

    #[test]
    fn root_changes_on_visibility() {
        let mut a = ProfessionalFacet::default();
        let mut b = ProfessionalFacet::default();
        a.endorsements_count = 5;
        b.endorsements_count = 5;
        b.visibility_mask = VIS_CERTIFICATIONS | VIS_WORK_HISTORY;
        assert_ne!(compute_professional_root(&a), compute_professional_root(&b));
    }

    #[test]
    fn prove_cert_roundtrip() {
        let f = ProfessionalFacet {
            certifications: vec![dummy_cert(1), dummy_cert(2), dummy_cert(3)],
            work_history: vec![dummy_work(7)],
            endorsements_count: 11,
            visibility_mask: VIS_CERTIFICATIONS,
        };
        let root = compute_professional_root(&f);
        for i in 0..3 {
            let p = prove_certification(&f, i).unwrap();
            assert!(verify_certification(&p, root));
            let mut bad = p.clone();
            bad.cert.credential_kind = bad.cert.credential_kind.wrapping_add(1);
            assert!(!verify_certification(&bad, root));
        }
    }

    #[test]
    fn validity_handles_never_expires() {
        let mut c = dummy_cert(5);
        c.expires_at_unix_s = 2_000_000_000;
        assert!(is_cert_currently_valid(&c, 1_800_000_000));
        assert!(!is_cert_currently_valid(&c, 2_100_000_000));
        c.expires_at_unix_s = 0;
        assert!(is_cert_currently_valid(&c, u64::MAX));
    }

    #[test]
    fn empty_root_nonzero() {
        let f = ProfessionalFacet::default();
        assert_ne!(compute_professional_root(&f), [0u8; 32]);
    }
}
