//! Reporter whitelist.
//!
//! Only addresses registered here (via DAO vote) may file flags. Each
//! reporter has a `reliability_score` (starts at 100, max 1000). Flags
//! that are disputed-and-cleared cost reliability; below 50 the reporter
//! can no longer submit.
//!
//! Persistence: sled tree `safety/reporters`.

use serde::{Deserialize, Serialize};
use sled::{Db, Tree};
use thiserror::Error;

pub const STARTING_RELIABILITY: u32 = 100;
pub const MAX_RELIABILITY: u32 = 1000;
pub const MIN_SUBMIT_RELIABILITY: u32 = 50;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ReporterRecord {
    pub address: [u8; 20],
    pub reliability_score: u32,
    pub flags_submitted: u32,
    pub flags_cleared: u32,
    pub revoked: bool,
    pub registered_at_block: u64,
}

impl ReporterRecord {
    pub fn can_submit(&self) -> bool {
        !self.revoked && self.reliability_score >= MIN_SUBMIT_RELIABILITY
    }
}

#[derive(Debug, Error)]
pub enum ReportersError {
    #[error("sled error: {0}")]
    Sled(#[from] sled::Error),
    #[error("serde error: {0}")]
    Serde(#[from] serde_json::Error),
    #[error("reporter not registered")]
    NotRegistered,
    #[error("reporter already registered")]
    AlreadyRegistered,
    #[error("reporter not authorized: revoked or reliability < {}", MIN_SUBMIT_RELIABILITY)]
    NotAuthorized,
}

#[derive(Clone)]
pub struct ReporterRegistry {
    tree: Tree,
}

impl ReporterRegistry {
    pub fn open(db: &Db) -> Result<Self, ReportersError> {
        let tree = db.open_tree("safety/reporters")?;
        Ok(Self { tree })
    }

    /// Register a new reporter. Caller is expected to gate this on a
    /// governance proposal having executed (`gov::Engine::execute`).
    pub fn register_reporter(
        &self,
        address: [u8; 20],
        block: u64,
    ) -> Result<ReporterRecord, ReportersError> {
        if self.tree.get(address)?.is_some() {
            return Err(ReportersError::AlreadyRegistered);
        }
        let rec = ReporterRecord {
            address,
            reliability_score: STARTING_RELIABILITY,
            flags_submitted: 0,
            flags_cleared: 0,
            revoked: false,
            registered_at_block: block,
        };
        self.put(&rec)?;
        Ok(rec)
    }

    /// Revoke (also governance-gated).
    pub fn revoke_reporter(&self, address: &[u8; 20]) -> Result<(), ReportersError> {
        let mut rec = self.get_reporter(address)?.ok_or(ReportersError::NotRegistered)?;
        rec.revoked = true;
        self.put(&rec)?;
        Ok(())
    }

    /// Called from `FlagsRegistry::add_attestation` path — increments
    /// the submit counter so reliability math has a denominator.
    pub fn attest(&self, address: &[u8; 20]) -> Result<(), ReportersError> {
        let mut rec = self.get_reporter(address)?.ok_or(ReportersError::NotRegistered)?;
        if !rec.can_submit() {
            return Err(ReportersError::NotAuthorized);
        }
        rec.flags_submitted = rec.flags_submitted.saturating_add(1);
        // Successful submissions slowly raise reliability (+1) to MAX.
        rec.reliability_score = (rec.reliability_score + 1).min(MAX_RELIABILITY);
        self.put(&rec)?;
        Ok(())
    }

    /// Called when a flag they raised gets disputed-and-cleared (false
    /// positive). Drops reliability by 25.
    pub fn penalise(&self, address: &[u8; 20]) -> Result<(), ReportersError> {
        let mut rec = self.get_reporter(address)?.ok_or(ReportersError::NotRegistered)?;
        rec.flags_cleared = rec.flags_cleared.saturating_add(1);
        rec.reliability_score = rec.reliability_score.saturating_sub(25);
        self.put(&rec)?;
        Ok(())
    }

    pub fn get_reporter(&self, address: &[u8; 20]) -> Result<Option<ReporterRecord>, ReportersError> {
        match self.tree.get(address)? {
            Some(b) => Ok(Some(serde_json::from_slice(&b)?)),
            None => Ok(None),
        }
    }

    pub fn get_reporter_score(&self, address: &[u8; 20]) -> Result<u32, ReportersError> {
        Ok(self.get_reporter(address)?.map(|r| r.reliability_score).unwrap_or(0))
    }

    /// True if the reporter exists and can currently submit attestations.
    pub fn is_authorized(&self, address: &[u8; 20]) -> Result<bool, ReportersError> {
        Ok(self.get_reporter(address)?.map(|r| r.can_submit()).unwrap_or(false))
    }

    fn put(&self, rec: &ReporterRecord) -> Result<(), ReportersError> {
        let bytes = serde_json::to_vec(rec)?;
        self.tree.insert(rec.address, bytes)?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn open() -> (sled::Db, ReporterRegistry) {
        let db = sled::Config::new().temporary(true).open().unwrap();
        let r = ReporterRegistry::open(&db).unwrap();
        (db, r)
    }

    #[test]
    fn register_and_authorize() {
        let (_db, r) = open();
        let addr = [0x11u8; 20];
        r.register_reporter(addr, 1).unwrap();
        assert!(r.is_authorized(&addr).unwrap());
    }

    #[test]
    fn penalise_drops_reliability() {
        let (_db, r) = open();
        let addr = [0x11u8; 20];
        r.register_reporter(addr, 1).unwrap();
        for _ in 0..3 { r.penalise(&addr).unwrap(); }
        // 100 - 75 = 25 < 50
        assert!(!r.is_authorized(&addr).unwrap());
    }

    #[test]
    fn revoke_blocks() {
        let (_db, r) = open();
        let addr = [0x11u8; 20];
        r.register_reporter(addr, 1).unwrap();
        r.revoke_reporter(&addr).unwrap();
        assert!(!r.is_authorized(&addr).unwrap());
    }
}
