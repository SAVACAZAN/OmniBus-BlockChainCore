//! Selective Disclosure — per-item Merkle proofs against the Manifest root.

use super::manifest::{self, FieldIndex, Manifest, ManifestRoot, FIELD_COUNT};
use super::merkle::{self, Hash, ProofStep};

#[derive(Clone, Copy, Debug, Default)]
pub struct DisclosureRequest {
    pub wants_kyc: bool,
    pub wants_assets: bool,
    pub wants_reputation: bool,
    pub wants_pq: bool,
    pub wants_obm: bool,
    pub wants_social: bool,
    pub wants_professional: bool,
    pub wants_cultural: bool,
    pub wants_economic: bool,
}

#[derive(Clone, Debug)]
pub struct Disclosure {
    pub field: FieldIndex,
    pub raw_bytes: Vec<u8>,
    pub proof: Vec<ProofStep>,
}

#[derive(Clone, Debug)]
pub struct DisclosureBundle {
    pub root: ManifestRoot,
    pub disclosures: Vec<Disclosure>,
}

fn field_bytes(field: FieldIndex, m: &Manifest) -> Vec<u8> {
    match field {
        FieldIndex::KycHash => m.kyc_hash.to_vec(),
        FieldIndex::AssetsRoot => m.assets_root.to_vec(),
        FieldIndex::ReputationSnapshot => manifest::serialize_reputation_field(m.reputation).to_vec(),
        FieldIndex::PqKeysHash => manifest::hash_pq_keys(&m.pq_pubkeys_concat).to_vec(),
        FieldIndex::Obm => vec![m.obm],
        FieldIndex::Timestamp => m.timestamp_unix_s.to_le_bytes().to_vec(),
        FieldIndex::SocialRoot => m.social_root.to_vec(),
        FieldIndex::ProfessionalRoot => m.professional_root.to_vec(),
        FieldIndex::CulturalRoot => m.cultural_root.to_vec(),
        FieldIndex::EconomicRoot => m.economic_root.to_vec(),
    }
}

fn add_one(
    list: &mut Vec<Disclosure>,
    field: FieldIndex,
    m: &Manifest,
    leaves: &[Hash; FIELD_COUNT],
) {
    let bytes = field_bytes(field, m);
    let proof = merkle::prove_leaf(leaves, field as usize).expect("valid index");
    list.push(Disclosure { field, raw_bytes: bytes, proof });
}

pub fn disclose_fields(m: &Manifest, request: DisclosureRequest) -> DisclosureBundle {
    let leaves = manifest::compute_leaf_hashes(m);
    let root = merkle::root_of_leaf_hashes(&leaves);
    let mut disclosures = Vec::new();

    if request.wants_kyc          { add_one(&mut disclosures, FieldIndex::KycHash, m, &leaves); }
    if request.wants_assets       { add_one(&mut disclosures, FieldIndex::AssetsRoot, m, &leaves); }
    if request.wants_reputation   { add_one(&mut disclosures, FieldIndex::ReputationSnapshot, m, &leaves); }
    if request.wants_pq           { add_one(&mut disclosures, FieldIndex::PqKeysHash, m, &leaves); }
    if request.wants_obm          { add_one(&mut disclosures, FieldIndex::Obm, m, &leaves); }
    if request.wants_social       { add_one(&mut disclosures, FieldIndex::SocialRoot, m, &leaves); }
    if request.wants_professional { add_one(&mut disclosures, FieldIndex::ProfessionalRoot, m, &leaves); }
    if request.wants_cultural     { add_one(&mut disclosures, FieldIndex::CulturalRoot, m, &leaves); }
    if request.wants_economic     { add_one(&mut disclosures, FieldIndex::EconomicRoot, m, &leaves); }

    DisclosureBundle { root, disclosures }
}

pub fn verify_disclosure(bundle: &DisclosureBundle) -> bool {
    for d in &bundle.disclosures {
        let leaf = merkle::hash_leaf(&d.raw_bytes);
        if !merkle::verify_proof(leaf, &d.proof, bundle.root) {
            return false;
        }
    }
    true
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::identity::obm::ReputationCups;

    fn sample() -> Manifest {
        Manifest {
            kyc_hash: [0xAA; 32],
            assets_root: [0xBB; 32],
            reputation: ReputationCups { love_stored: 7000, ..Default::default() },
            pq_pubkeys_concat: Vec::new(),
            obm: 1,
            timestamp_unix_s: 42,
            social_root: [0u8; 32],
            professional_root: [0u8; 32],
            cultural_root: [0u8; 32],
            economic_root: [0u8; 32],
        }
    }

    #[test]
    fn accepts_disclosed_reputation_only() {
        let b = disclose_fields(&sample(), DisclosureRequest { wants_reputation: true, ..Default::default() });
        assert_eq!(b.disclosures.len(), 1);
        assert!(verify_disclosure(&b));
    }

    #[test]
    fn rejects_tampered_bytes() {
        let mut b = disclose_fields(&sample(), DisclosureRequest { wants_obm: true, ..Default::default() });
        b.disclosures[0].raw_bytes[0] = 0xFF;
        assert!(!verify_disclosure(&b));
    }

    #[test]
    fn multi_field_disclosure() {
        let req = DisclosureRequest {
            wants_reputation: true,
            wants_obm: true,
            wants_pq: true,
            ..Default::default()
        };
        let b = disclose_fields(&sample(), req);
        assert_eq!(b.disclosures.len(), 3);
        assert!(verify_disclosure(&b));
    }
}
