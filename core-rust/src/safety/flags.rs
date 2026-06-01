//! Flagged-address registry.
//!
//! Persistence: sled tree `safety/flags`, keyed by 20-byte address.
//! Each record carries severity + reason + evidence hash + reporter list
//! + dispute status. Mutations are append-only at the protocol level —
//! callers `add_attestation` to raise confidence, `dispute_flag` to
//! contest, `resolve_dispute` (governance) to clear or confirm.

use serde::{Deserialize, Serialize};
use sled::{Db, Tree};
use thiserror::Error;

/// Severity ladder. `Sanctioned` is the only tier that the tx-guard
/// hard-rejects on; everything else is a wallet warning.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[repr(u8)]
pub enum FlagSeverity {
    Sanctioned = 1,
    Phishing = 2,
    Scam = 3,
    Mixer = 4,
    Compromised = 5,
    Suspicious = 6,
}

impl FlagSeverity {
    pub fn as_str(self) -> &'static str {
        match self {
            FlagSeverity::Sanctioned => "sanctioned",
            FlagSeverity::Phishing => "phishing",
            FlagSeverity::Scam => "scam",
            FlagSeverity::Mixer => "mixer",
            FlagSeverity::Compromised => "compromised",
            FlagSeverity::Suspicious => "suspicious",
        }
    }

    pub fn from_str(s: &str) -> Option<Self> {
        Some(match s.to_ascii_lowercase().as_str() {
            "sanctioned" => FlagSeverity::Sanctioned,
            "phishing" => FlagSeverity::Phishing,
            "scam" => FlagSeverity::Scam,
            "mixer" => FlagSeverity::Mixer,
            "compromised" => FlagSeverity::Compromised,
            "suspicious" => FlagSeverity::Suspicious,
            _ => return None,
        })
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[repr(u8)]
pub enum DisputeStatus {
    None = 0,
    Pending = 1,
    ResolvedCleared = 2,
    ResolvedConfirmed = 3,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FlagRecord {
    /// 20-byte EVM-style address (interop with state.rs `Address20`).
    pub address: [u8; 20],
    pub severity: FlagSeverity,
    pub reason: String,
    pub evidence_hash: [u8; 32],
    pub reporters: Vec<[u8; 20]>,
    pub attestation_count: u32,
    pub flagged_at_block: u64,
    pub dispute_status: DisputeStatus,
}

impl FlagRecord {
    /// Minimum reporter attestations required for a flag to count as
    /// "confirmed" (and thus enforced by the tx-guard at warn level).
    pub const MIN_ATTESTATIONS: u32 = 2;

    /// Returns true if this flag is currently active (not cleared on
    /// dispute) and has met the attestation threshold OR is sanctioned
    /// (sanctioned tier from oracle ingest doesn't need extra
    /// attestations — the upstream feed is the attestation).
    pub fn is_enforced(&self) -> bool {
        if matches!(self.dispute_status, DisputeStatus::ResolvedCleared) {
            return false;
        }
        if self.severity == FlagSeverity::Sanctioned {
            return true;
        }
        self.attestation_count >= Self::MIN_ATTESTATIONS
    }
}

#[derive(Debug, Error)]
pub enum FlagsError {
    #[error("sled error: {0}")]
    Sled(#[from] sled::Error),
    #[error("serde error: {0}")]
    Serde(#[from] serde_json::Error),
    #[error("flag not found for address")]
    NotFound,
    #[error("flag already exists; use add_attestation")]
    AlreadyExists,
    #[error("dispute not pending")]
    NoPendingDispute,
    #[error("duplicate attestation by same reporter")]
    DuplicateReporter,
}

#[derive(Clone)]
pub struct FlagsRegistry {
    tree: Tree,
}

impl FlagsRegistry {
    pub fn open(db: &Db) -> Result<Self, FlagsError> {
        let tree = db.open_tree("safety/flags")?;
        Ok(Self { tree })
    }

    pub fn flag_address(
        &self,
        address: [u8; 20],
        severity: FlagSeverity,
        reason: String,
        evidence_hash: [u8; 32],
        reporter: [u8; 20],
        block: u64,
    ) -> Result<FlagRecord, FlagsError> {
        if self.tree.get(address)?.is_some() {
            return Err(FlagsError::AlreadyExists);
        }
        let rec = FlagRecord {
            address,
            severity,
            reason,
            evidence_hash,
            reporters: vec![reporter],
            attestation_count: 1,
            flagged_at_block: block,
            dispute_status: DisputeStatus::None,
        };
        self.put(&rec)?;
        Ok(rec)
    }

    pub fn add_attestation(
        &self,
        address: &[u8; 20],
        reporter: [u8; 20],
    ) -> Result<FlagRecord, FlagsError> {
        let mut rec = self.get_flag(address)?.ok_or(FlagsError::NotFound)?;
        if rec.reporters.iter().any(|r| r == &reporter) {
            return Err(FlagsError::DuplicateReporter);
        }
        rec.reporters.push(reporter);
        rec.attestation_count = rec.attestation_count.saturating_add(1);
        self.put(&rec)?;
        Ok(rec)
    }

    pub fn get_flag(&self, address: &[u8; 20]) -> Result<Option<FlagRecord>, FlagsError> {
        match self.tree.get(address)? {
            Some(b) => Ok(Some(serde_json::from_slice(&b)?)),
            None => Ok(None),
        }
    }

    pub fn dispute_flag(
        &self,
        address: &[u8; 20],
        _defense_evidence: [u8; 32],
    ) -> Result<FlagRecord, FlagsError> {
        let mut rec = self.get_flag(address)?.ok_or(FlagsError::NotFound)?;
        // (defense_evidence_hash can be stored alongside if/when schema expands.)
        rec.dispute_status = DisputeStatus::Pending;
        self.put(&rec)?;
        Ok(rec)
    }

    /// Governance-resolved outcome. `cleared=true` clears the flag (false
    /// positive), `cleared=false` confirms it.
    pub fn resolve_dispute(
        &self,
        address: &[u8; 20],
        cleared: bool,
    ) -> Result<FlagRecord, FlagsError> {
        let mut rec = self.get_flag(address)?.ok_or(FlagsError::NotFound)?;
        if rec.dispute_status != DisputeStatus::Pending {
            return Err(FlagsError::NoPendingDispute);
        }
        rec.dispute_status = if cleared {
            DisputeStatus::ResolvedCleared
        } else {
            DisputeStatus::ResolvedConfirmed
        };
        self.put(&rec)?;
        Ok(rec)
    }

    pub fn list_flagged(
        &self,
        severity_filter: Option<FlagSeverity>,
    ) -> Result<Vec<FlagRecord>, FlagsError> {
        let mut out = Vec::new();
        for kv in self.tree.iter() {
            let (_, bytes) = kv?;
            let rec: FlagRecord = serde_json::from_slice(&bytes)?;
            if let Some(sf) = severity_filter {
                if rec.severity != sf {
                    continue;
                }
            }
            out.push(rec);
        }
        Ok(out)
    }

    fn put(&self, rec: &FlagRecord) -> Result<(), FlagsError> {
        let bytes = serde_json::to_vec(rec)?;
        self.tree.insert(rec.address, bytes)?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn open() -> (sled::Db, FlagsRegistry) {
        let db = sled::Config::new().temporary(true).open().unwrap();
        let reg = FlagsRegistry::open(&db).unwrap();
        (db, reg)
    }

    #[test]
    fn flag_then_get() {
        let (_db, reg) = open();
        let addr = [0x11u8; 20];
        let rep = [0x22u8; 20];
        reg.flag_address(addr, FlagSeverity::Scam, "rugpull".into(), [0u8; 32], rep, 100)
            .unwrap();
        let got = reg.get_flag(&addr).unwrap().unwrap();
        assert_eq!(got.severity, FlagSeverity::Scam);
        assert_eq!(got.attestation_count, 1);
    }

    #[test]
    fn double_flag_rejected_but_attestation_works() {
        let (_db, reg) = open();
        let addr = [0x11u8; 20];
        reg.flag_address(addr, FlagSeverity::Scam, "x".into(), [0u8; 32], [1u8; 20], 1)
            .unwrap();
        let err = reg
            .flag_address(addr, FlagSeverity::Scam, "y".into(), [0u8; 32], [2u8; 20], 2)
            .unwrap_err();
        assert!(matches!(err, FlagsError::AlreadyExists));
        let r = reg.add_attestation(&addr, [2u8; 20]).unwrap();
        assert_eq!(r.attestation_count, 2);
        assert!(r.is_enforced());
    }

    #[test]
    fn dispute_cycle() {
        let (_db, reg) = open();
        let addr = [0x11u8; 20];
        reg.flag_address(addr, FlagSeverity::Phishing, "x".into(), [0u8; 32], [1u8; 20], 1)
            .unwrap();
        reg.dispute_flag(&addr, [9u8; 32]).unwrap();
        let r = reg.resolve_dispute(&addr, true).unwrap();
        assert_eq!(r.dispute_status, DisputeStatus::ResolvedCleared);
        assert!(!r.is_enforced());
    }

    #[test]
    fn sanctioned_always_enforced() {
        let (_db, reg) = open();
        let addr = [0xAAu8; 20];
        let r = reg
            .flag_address(addr, FlagSeverity::Sanctioned, "ofac".into(), [0u8; 32], [1u8; 20], 1)
            .unwrap();
        assert!(r.is_enforced());
    }
}
