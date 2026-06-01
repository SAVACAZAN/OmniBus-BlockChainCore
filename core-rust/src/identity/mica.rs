//! MiCA + AML attest/disclose. Versioned, JSON-serializable, signable.
//!
//! Mirror of Zig `id_compliance.zig` / `id_economic.zig` MiCA types.
//! Canonical JSON order is FIXED for v1 — never reorder.

use sha2::{Digest, Sha256};
use serde::{Deserialize, Serialize};

pub const MICA_REPORT_VERSION: u32 = 1;

#[repr(u8)]
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum MicaRiskCategory {
    None = 0,
    Low = 1,
    Medium = 2,
    High = 3,
    AssetReferenced = 4,
    EmoneyToken = 5,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct MicaDisclosure {
    pub is_issuer: bool,
    pub white_paper_hash: [u8; 32],
    pub risk_category: MicaRiskCategory,
    pub issuer_legal_entity_hash: [u8; 32],
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct AmlAttestation {
    pub sanctions_screened: bool,
    pub screening_date_unix_s: u64,
    pub issuer_did_hash: [u8; 32],
    #[serde(with = "serde_64")]
    pub signature: [u8; 64],
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct KycAttestation {
    pub is_verified: bool,
    pub valid_until_unix_s: u64,
    pub issuer_did_hash: [u8; 32],
    #[serde(with = "serde_64")]
    pub signature: [u8; 64],
}

mod serde_64 {
    use serde::{Deserialize, Deserializer, Serialize, Serializer};
    pub fn serialize<S: Serializer>(b: &[u8; 64], s: S) -> Result<S::Ok, S::Error> {
        b.as_ref().serialize(s)
    }
    pub fn deserialize<'de, D: Deserializer<'de>>(d: D) -> Result<[u8; 64], D::Error> {
        let v: Vec<u8> = Vec::deserialize(d)?;
        if v.len() != 64 {
            return Err(serde::de::Error::custom("expected 64 bytes"));
        }
        let mut out = [0u8; 64];
        out.copy_from_slice(&v);
        Ok(out)
    }
}

#[derive(Clone, Debug)]
pub struct MicaSummary {
    pub is_issuer: bool,
    pub white_paper_hash: [u8; 32],
    pub risk_category: MicaRiskCategory,
    pub aml_screened: bool,
    pub aml_screening_date_unix_s: u64,
    pub kyc_verified: bool,
    pub kyc_valid_until_unix_s: u64,
}

pub fn build_mica_summary(
    mica: &MicaDisclosure,
    aml: &AmlAttestation,
    kyc: &KycAttestation,
) -> MicaSummary {
    MicaSummary {
        is_issuer: mica.is_issuer,
        white_paper_hash: mica.white_paper_hash,
        risk_category: mica.risk_category,
        aml_screened: aml.sanctions_screened,
        aml_screening_date_unix_s: aml.screening_date_unix_s,
        kyc_verified: kyc.is_verified,
        kyc_valid_until_unix_s: kyc.valid_until_unix_s,
    }
}

#[derive(Clone, Debug)]
pub struct MicaReport {
    pub version: u32,
    pub address: String,
    pub generated_unix_s: u64,
    pub node_id: String,
    pub mica: MicaDisclosure,
    pub aml: AmlAttestation,
    pub kyc: KycAttestation,
    pub report_hash: [u8; 32],
}

fn hex_lower(bytes: &[u8]) -> String {
    let mut s = String::with_capacity(bytes.len() * 2);
    for b in bytes {
        s.push_str(&format!("{:02x}", b));
    }
    s
}

/// Canonical pre-hash JSON body — must match Zig `micaReportCanonicalBody`
/// byte-for-byte so a Rust-built report has the same hash as a Zig-built one.
fn mica_report_canonical_body(
    address: &str,
    generated_unix_s: u64,
    node_id: &str,
    mica: &MicaDisclosure,
    aml: &AmlAttestation,
    kyc: &KycAttestation,
) -> String {
    format!(
        "{{\"version\":{ver},\"address\":\"{addr}\",\"generated_unix_s\":{gen},\"node_id\":\"{nid}\",\
         \"mica\":{{\"is_issuer\":{is_iss},\"white_paper_hash\":\"{wp}\",\"risk_category\":{risk},\"issuer_legal_entity_hash\":\"{le}\"}},\
         \"aml\":{{\"sanctions_screened\":{aml_sc},\"screening_date_unix_s\":{aml_d},\"issuer_did_hash\":\"{aml_iss}\",\"signature\":\"{aml_sig}\"}},\
         \"kyc\":{{\"is_verified\":{kyc_v},\"valid_until_unix_s\":{kyc_u},\"issuer_did_hash\":\"{kyc_iss}\",\"signature\":\"{kyc_sig}\"}}}}",
        ver = MICA_REPORT_VERSION,
        addr = address,
        gen = generated_unix_s,
        nid = node_id,
        is_iss = if mica.is_issuer { "true" } else { "false" },
        wp = hex_lower(&mica.white_paper_hash),
        risk = mica.risk_category as u8,
        le = hex_lower(&mica.issuer_legal_entity_hash),
        aml_sc = if aml.sanctions_screened { "true" } else { "false" },
        aml_d = aml.screening_date_unix_s,
        aml_iss = hex_lower(&aml.issuer_did_hash),
        aml_sig = hex_lower(&aml.signature),
        kyc_v = if kyc.is_verified { "true" } else { "false" },
        kyc_u = kyc.valid_until_unix_s,
        kyc_iss = hex_lower(&kyc.issuer_did_hash),
        kyc_sig = hex_lower(&kyc.signature),
    )
}

pub fn build_mica_report(
    address: impl Into<String>,
    generated_unix_s: u64,
    node_id: impl Into<String>,
    mica: MicaDisclosure,
    aml: AmlAttestation,
    kyc: KycAttestation,
) -> MicaReport {
    let address = address.into();
    let node_id = node_id.into();
    let body = mica_report_canonical_body(&address, generated_unix_s, &node_id, &mica, &aml, &kyc);
    let report_hash: [u8; 32] = Sha256::digest(body.as_bytes()).into();
    MicaReport {
        version: MICA_REPORT_VERSION,
        address,
        generated_unix_s,
        node_id,
        mica,
        aml,
        kyc,
        report_hash,
    }
}

pub fn mica_report_json(r: &MicaReport) -> String {
    let body = mica_report_canonical_body(&r.address, r.generated_unix_s, &r.node_id, &r.mica, &r.aml, &r.kyc);
    // Splice "report_hash" before the closing brace, preserving canonical order.
    debug_assert!(body.ends_with('}'));
    let head = &body[..body.len() - 1];
    format!("{},\"report_hash\":\"{}\"}}", head, hex_lower(&r.report_hash))
}

/// One-shot: build + serialize.
pub fn mica_report(
    address: impl Into<String>,
    generated_unix_s: u64,
    node_id: impl Into<String>,
    mica: MicaDisclosure,
    aml: AmlAttestation,
    kyc: KycAttestation,
) -> String {
    let r = build_mica_report(address, generated_unix_s, node_id, mica, aml, kyc);
    mica_report_json(&r)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample() -> (MicaDisclosure, AmlAttestation, KycAttestation) {
        (
            MicaDisclosure {
                is_issuer: true,
                white_paper_hash: [0x11; 32],
                risk_category: MicaRiskCategory::High,
                issuer_legal_entity_hash: [0x22; 32],
            },
            AmlAttestation {
                sanctions_screened: true,
                screening_date_unix_s: 1_750_000_000,
                issuer_did_hash: [0x33; 32],
                signature: [0x44; 64],
            },
            KycAttestation {
                is_verified: true,
                valid_until_unix_s: 2_000_000_000,
                issuer_did_hash: [0x55; 32],
                signature: [0x66; 64],
            },
        )
    }

    #[test]
    fn report_deterministic_and_versioned() {
        let (m, a, k) = sample();
        let a1 = mica_report("ob1qtest", 1_750_000_001, "node-1", m.clone(), a.clone(), k.clone());
        let a2 = mica_report("ob1qtest", 1_750_000_001, "node-1", m, a, k);
        assert_eq!(a1, a2);
        assert!(a1.contains("\"version\":1"));
        assert!(a1.contains("\"address\":\"ob1qtest\""));
        assert!(a1.contains("\"risk_category\":3"));
        assert!(a1.contains("\"report_hash\":\""));
        assert!(!a1.contains("deferred"));
        assert!(!a1.contains("stub"));
    }

    #[test]
    fn hash_changes_when_issuer_flips() {
        let (mut m, a, k) = sample();
        let r1 = build_mica_report("ob1qa", 100, "n1", m.clone(), a.clone(), k.clone());
        m.is_issuer = !m.is_issuer;
        let r2 = build_mica_report("ob1qa", 100, "n1", m, a, k);
        assert_ne!(r1.report_hash, r2.report_hash);
    }
}
