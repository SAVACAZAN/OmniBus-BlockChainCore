//! Economic Facet (leaf index 9 of master Manifest) — MiCA + AML + KYC.
//!
//! 6-leaf top tree (FIXED order):
//!   [addresses_subroot, donations_subroot, volumes_leaf, mica_leaf, aml_leaf, kyc_leaf]
//! `visibility_mask` is hashed into `volumes_leaf` so it cannot be edited
//! retroactively without changing the facet root.

use sha2::{Digest, Sha256};

use crate::identity::merkle::{self, Hash, ProofStep};
use crate::identity::mica::{AmlAttestation, KycAttestation, MicaDisclosure};

#[repr(u8)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ChainKind {
    Omni = 0,
    Bitcoin = 1,
    Ethereum = 2,
    Solana = 3,
    Base = 4,
    Polygon = 5,
    Other = 99,
}

#[derive(Clone, Debug)]
pub struct PublicAddress {
    pub chain: ChainKind,
    pub address_hash: [u8; 32],
    pub is_public: bool,
    pub added_unix_s: u64,
}

#[derive(Clone, Debug)]
pub struct PublicDonation {
    pub tx_hash: [u8; 32],
    pub amount_sat: u64,
    pub memo_hash: [u8; 32],
    pub received_unix_s: u64,
    pub is_public: bool,
}

pub const VIS_ADDRESSES: u8 = 1 << 0;
pub const VIS_DONATIONS: u8 = 1 << 1;
pub const VIS_VOLUME: u8 = 1 << 2;
pub const VIS_MICA: u8 = 1 << 3;
pub const VIS_AML: u8 = 1 << 4;
pub const VIS_KYC: u8 = 1 << 5;

#[derive(Clone, Debug)]
pub struct EconomicFacet {
    pub public_addresses: Vec<PublicAddress>,
    pub public_donations: Vec<PublicDonation>,
    pub declared_volume_30d_sat: u64,
    pub declared_volume_90d_sat: u64,
    pub declared_volume_1y_sat: u64,
    pub mica: MicaDisclosure,
    pub aml: AmlAttestation,
    pub kyc: KycAttestation,
    pub visibility_mask: u8,
}

// --- canonical leaf preimages (must match Zig byte-for-byte) ---

fn address_leaf_bytes(a: &PublicAddress) -> [u8; 42] {
    let mut buf = [0u8; 42];
    buf[0] = a.chain as u8;
    buf[1..33].copy_from_slice(&a.address_hash);
    buf[33] = if a.is_public { 1 } else { 0 };
    buf[34..42].copy_from_slice(&a.added_unix_s.to_le_bytes());
    buf
}

fn address_leaf_hash(a: &PublicAddress) -> Hash {
    if a.is_public {
        merkle::hash_leaf(&address_leaf_bytes(a))
    } else {
        let mut inner = [0u8; 32 + 15];
        inner[0..32].copy_from_slice(&a.address_hash);
        inner[32..47].copy_from_slice(b"private_address");
        let redacted: [u8; 32] = Sha256::digest(inner).into();
        merkle::hash_leaf(&redacted)
    }
}

fn donation_leaf_bytes(d: &PublicDonation) -> [u8; 81] {
    let mut buf = [0u8; 81];
    buf[0..32].copy_from_slice(&d.tx_hash);
    buf[32..40].copy_from_slice(&d.amount_sat.to_le_bytes());
    buf[40..72].copy_from_slice(&d.memo_hash);
    buf[72..80].copy_from_slice(&d.received_unix_s.to_le_bytes());
    buf[80] = if d.is_public { 1 } else { 0 };
    buf
}

fn donation_leaf_hash(d: &PublicDonation) -> Hash {
    if d.is_public {
        merkle::hash_leaf(&donation_leaf_bytes(d))
    } else {
        let mut inner = [0u8; 32 + 16];
        inner[0..32].copy_from_slice(&d.tx_hash);
        inner[32..48].copy_from_slice(b"private_donation");
        let redacted: [u8; 32] = Sha256::digest(inner).into();
        merkle::hash_leaf(&redacted)
    }
}

fn volumes_leaf_bytes(f: &EconomicFacet) -> [u8; 25] {
    let mut buf = [0u8; 25];
    buf[0..8].copy_from_slice(&f.declared_volume_30d_sat.to_le_bytes());
    buf[8..16].copy_from_slice(&f.declared_volume_90d_sat.to_le_bytes());
    buf[16..24].copy_from_slice(&f.declared_volume_1y_sat.to_le_bytes());
    buf[24] = f.visibility_mask;
    buf
}

fn mica_leaf_bytes(m: &MicaDisclosure) -> [u8; 66] {
    let mut buf = [0u8; 66];
    buf[0] = if m.is_issuer { 1 } else { 0 };
    buf[1..33].copy_from_slice(&m.white_paper_hash);
    buf[33] = m.risk_category as u8;
    buf[34..66].copy_from_slice(&m.issuer_legal_entity_hash);
    buf
}

fn aml_leaf_bytes(a: &AmlAttestation) -> [u8; 105] {
    let mut buf = [0u8; 105];
    buf[0] = if a.sanctions_screened { 1 } else { 0 };
    buf[1..9].copy_from_slice(&a.screening_date_unix_s.to_le_bytes());
    buf[9..41].copy_from_slice(&a.issuer_did_hash);
    buf[41..105].copy_from_slice(&a.signature);
    buf
}

fn kyc_leaf_bytes(k: &KycAttestation) -> [u8; 105] {
    let mut buf = [0u8; 105];
    buf[0] = if k.is_verified { 1 } else { 0 };
    buf[1..9].copy_from_slice(&k.valid_until_unix_s.to_le_bytes());
    buf[9..41].copy_from_slice(&k.issuer_did_hash);
    buf[41..105].copy_from_slice(&k.signature);
    buf
}

const ZERO32: [u8; 32] = [0u8; 32];

fn addresses_subroot(f: &EconomicFacet) -> Hash {
    if f.public_addresses.is_empty() {
        return merkle::hash_leaf(&ZERO32);
    }
    let leaves: Vec<Hash> = f.public_addresses.iter().map(address_leaf_hash).collect();
    merkle::root_of_leaf_hashes(&leaves)
}

fn donations_subroot(f: &EconomicFacet) -> Hash {
    if f.public_donations.is_empty() {
        return merkle::hash_leaf(&ZERO32);
    }
    let leaves: Vec<Hash> = f.public_donations.iter().map(donation_leaf_hash).collect();
    merkle::root_of_leaf_hashes(&leaves)
}

fn top_leaves(f: &EconomicFacet) -> [Hash; 6] {
    let addr_sub = addresses_subroot(f);
    let don_sub = donations_subroot(f);
    let volumes_leaf = merkle::hash_leaf(&volumes_leaf_bytes(f));
    let mica_leaf = merkle::hash_leaf(&mica_leaf_bytes(&f.mica));
    let aml_leaf = merkle::hash_leaf(&aml_leaf_bytes(&f.aml));
    let kyc_leaf = merkle::hash_leaf(&kyc_leaf_bytes(&f.kyc));
    [addr_sub, don_sub, volumes_leaf, mica_leaf, aml_leaf, kyc_leaf]
}

pub fn compute_economic_root(f: &EconomicFacet) -> Hash {
    merkle::root_of_leaf_hashes(&top_leaves(f))
}

#[derive(Clone, Debug)]
pub struct AddressProof {
    pub address: PublicAddress,
    pub proof: Vec<ProofStep>,
}

#[derive(Clone, Debug)]
pub struct DonationProof {
    pub donation: PublicDonation,
    pub proof: Vec<ProofStep>,
}

pub fn prove_address(f: &EconomicFacet, idx: usize) -> Result<AddressProof, &'static str> {
    if idx >= f.public_addresses.len() {
        return Err("index out of range");
    }
    let leaves: Vec<Hash> = f.public_addresses.iter().map(address_leaf_hash).collect();
    let mut inner = merkle::prove_leaf(&leaves, idx)?;
    let tops = top_leaves(f);
    let outer = merkle::prove_leaf(&tops, 0)?;
    inner.extend(outer);
    Ok(AddressProof { address: f.public_addresses[idx].clone(), proof: inner })
}

pub fn verify_address(p: &AddressProof, facet_root: Hash) -> bool {
    merkle::verify_proof(address_leaf_hash(&p.address), &p.proof, facet_root)
}

pub fn prove_donation(f: &EconomicFacet, idx: usize) -> Result<DonationProof, &'static str> {
    if idx >= f.public_donations.len() {
        return Err("index out of range");
    }
    let leaves: Vec<Hash> = f.public_donations.iter().map(donation_leaf_hash).collect();
    let mut inner = merkle::prove_leaf(&leaves, idx)?;
    let tops = top_leaves(f);
    let outer = merkle::prove_leaf(&tops, 1)?;
    inner.extend(outer);
    Ok(DonationProof { donation: f.public_donations[idx].clone(), proof: inner })
}

pub fn verify_donation(p: &DonationProof, facet_root: Hash) -> bool {
    merkle::verify_proof(donation_leaf_hash(&p.donation), &p.proof, facet_root)
}

pub fn is_kyc_currently_valid(kyc: &KycAttestation, now_unix_s: u64) -> bool {
    if !kyc.is_verified {
        return false;
    }
    if kyc.valid_until_unix_s == 0 {
        return true;
    }
    kyc.valid_until_unix_s > now_unix_s
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::identity::mica::MicaRiskCategory;

    fn dummy_mica(issuer: bool) -> MicaDisclosure {
        MicaDisclosure {
            is_issuer: issuer,
            white_paper_hash: if issuer { [0xAB; 32] } else { [0u8; 32] },
            risk_category: if issuer { MicaRiskCategory::Medium } else { MicaRiskCategory::None },
            issuer_legal_entity_hash: if issuer { [0xCD; 32] } else { [0u8; 32] },
        }
    }

    fn dummy_aml(screened: bool) -> AmlAttestation {
        AmlAttestation {
            sanctions_screened: screened,
            screening_date_unix_s: if screened { 1_750_000_000 } else { 0 },
            issuer_did_hash: [0u8; 32],
            signature: [0u8; 64],
        }
    }

    fn dummy_kyc(verified: bool, valid_until: u64) -> KycAttestation {
        KycAttestation {
            is_verified: verified,
            valid_until_unix_s: valid_until,
            issuer_did_hash: [0u8; 32],
            signature: [0u8; 64],
        }
    }

    fn empty_facet() -> EconomicFacet {
        EconomicFacet {
            public_addresses: vec![],
            public_donations: vec![],
            declared_volume_30d_sat: 0,
            declared_volume_90d_sat: 0,
            declared_volume_1y_sat: 0,
            mica: dummy_mica(false),
            aml: dummy_aml(false),
            kyc: dummy_kyc(false, 0),
            visibility_mask: 0,
        }
    }

    fn dummy_address(seed: u8, public: bool) -> PublicAddress {
        PublicAddress {
            chain: ChainKind::Omni,
            address_hash: [seed; 32],
            is_public: public,
            added_unix_s: 1_700_000_000 + seed as u64,
        }
    }

    fn dummy_donation(seed: u8, public: bool) -> PublicDonation {
        PublicDonation {
            tx_hash: [seed.wrapping_add(1); 32],
            amount_sat: seed as u64 * 1_000_000,
            memo_hash: [seed.wrapping_add(2); 32],
            received_unix_s: 1_700_000_000 + seed as u64,
            is_public: public,
        }
    }

    #[test]
    fn empty_deterministic_nonzero() {
        let f = empty_facet();
        let r1 = compute_economic_root(&f);
        let r2 = compute_economic_root(&f);
        assert_eq!(r1, r2);
        assert_ne!(r1, [0u8; 32]);
    }

    #[test]
    fn address_proof_roundtrip() {
        let mut f = empty_facet();
        f.public_addresses = vec![dummy_address(1, true), dummy_address(2, true), dummy_address(3, false)];
        f.visibility_mask = VIS_ADDRESSES;
        let root = compute_economic_root(&f);
        let p = prove_address(&f, 1).unwrap();
        assert!(verify_address(&p, root));
        let mut bad = p.clone();
        bad.address.added_unix_s ^= 1;
        assert!(!verify_address(&bad, root));
    }

    #[test]
    fn mica_disclosure_binds_root() {
        let mut fa = empty_facet();
        let mut fb = empty_facet();
        fa.mica = dummy_mica(false);
        fb.mica = dummy_mica(true);
        fb.visibility_mask = VIS_MICA;
        assert_ne!(compute_economic_root(&fa), compute_economic_root(&fb));
    }

    #[test]
    fn visibility_mask_changes_root() {
        let mut fa = empty_facet();
        let mut fb = empty_facet();
        fa.declared_volume_30d_sat = 1_000_000;
        fb.declared_volume_30d_sat = 1_000_000;
        fb.visibility_mask = VIS_VOLUME | VIS_KYC;
        assert_ne!(compute_economic_root(&fa), compute_economic_root(&fb));
    }

    #[test]
    fn tampered_donation_fails() {
        let mut f = empty_facet();
        f.public_donations = vec![dummy_donation(1, true), dummy_donation(2, true)];
        f.visibility_mask = VIS_DONATIONS;
        let root = compute_economic_root(&f);
        let p = prove_donation(&f, 0).unwrap();
        assert!(verify_donation(&p, root));
        let mut bad = p.clone();
        bad.donation.amount_sat = bad.donation.amount_sat.wrapping_add(1);
        assert!(!verify_donation(&bad, root));
    }

    #[test]
    fn kyc_validity_matrix() {
        assert!(!is_kyc_currently_valid(&dummy_kyc(false, 9_999_999_999), 1_000));
        assert!(is_kyc_currently_valid(&dummy_kyc(true, 0), u64::MAX));
        assert!(is_kyc_currently_valid(&dummy_kyc(true, 2_000_000_000), 1_900_000_000));
        assert!(!is_kyc_currently_valid(&dummy_kyc(true, 1_500_000_000), 1_900_000_000));
    }
}
