//! `.omnibus` Name System registry (ENS-style).
//!
//! Per-chain ENS fee — canonical 0.1 OMNI on testnet (1e8 SAT per memory
//! `project_omnibus_evm_build_blocker`). Mainnet uses per-TLD tiers from
//! Zig `dns_registry.zig` (5 OMNI .omnibus, 10 OMNI .arbitraje, etc.).
//!
//! Sled persistence: tree `identity/ns` keyed by canonical lowercase
//! "name.tld" → JSON-serialized `NsEntry`.

use serde::{Deserialize, Serialize};
use std::sync::Arc;
use thiserror::Error;

pub const SAT_PER_OMNI: u64 = 1_000_000_000;

/// Default per-name fee (mainnet baseline).
pub const REGISTER_COST_SAT: u64 = SAT_PER_OMNI; // 1 OMNI
pub const COST_OMNIBUS_SAT: u64 = 5 * SAT_PER_OMNI;
pub const COST_ARBITRAJE_SAT: u64 = 10 * SAT_PER_OMNI;

/// Per-chain ENS fee on testnet: 0.1 OMNI = 1e8 SAT.
/// Canonical value — locked across all chains per
/// `project_omnibus_evm_build_blocker`.
pub const ENS_FEE_TESTNET_SAT: u64 = 100_000_000;

pub const MIN_NAME_LEN: usize = 3;
pub const MAX_NAME_LEN: usize = 25;
pub const BLOCKS_PER_YEAR: u64 = 31_557_600;
pub const GRACE_PERIOD_BLOCKS: u64 = 2_592_000;

#[derive(Debug, Error)]
pub enum NsError {
    #[error("name too short or too long")]
    InvalidName,
    #[error("name already taken")]
    NameTaken,
    #[error("name not found")]
    NotFound,
    #[error("caller is not the owner")]
    NotOwner,
    #[error("expired and past grace period")]
    Expired,
    #[error("insufficient fee: required {required}, got {paid}")]
    InsufficientFee { required: u64, paid: u64 },
    #[error("storage error: {0}")]
    Storage(#[from] sled::Error),
    #[error("encoding error: {0}")]
    Encoding(#[from] serde_json::Error),
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct NsEntry {
    pub name: String,
    pub tld: String,
    pub owner: String,
    pub registered_at_block: u64,
    pub expires_at_block: u64,
    /// Years initially purchased (1..=100 per ALLOWED_YEARS in Zig).
    pub years: u32,
}

impl NsEntry {
    pub fn canonical_key(&self) -> String {
        canonical_key(&self.name, &self.tld)
    }

    pub fn is_expired(&self, current_block: u64) -> bool {
        current_block > self.expires_at_block + GRACE_PERIOD_BLOCKS
    }
}

fn canonical_key(name: &str, tld: &str) -> String {
    format!("{}.{}", name.to_lowercase(), tld.to_lowercase())
}

/// Validates name length & charset. Allowed: a-z, 0-9, '-' (not at boundaries).
fn validate_name(name: &str) -> Result<(), NsError> {
    let n = name.len();
    if !(MIN_NAME_LEN..=MAX_NAME_LEN).contains(&n) {
        return Err(NsError::InvalidName);
    }
    let bytes = name.as_bytes();
    if bytes.first() == Some(&b'-') || bytes.last() == Some(&b'-') {
        return Err(NsError::InvalidName);
    }
    for b in bytes {
        let ok = matches!(b, b'a'..=b'z' | b'0'..=b'9' | b'-' | b'A'..=b'Z');
        if !ok {
            return Err(NsError::InvalidName);
        }
    }
    Ok(())
}

/// Returns the canonical fee for a (tld, network) pair.
pub fn fee_for_tld(tld: &str, is_testnet: bool) -> u64 {
    if is_testnet {
        return ENS_FEE_TESTNET_SAT;
    }
    match tld.to_lowercase().as_str() {
        "omnibus" => COST_OMNIBUS_SAT,
        "arbitraje" => COST_ARBITRAJE_SAT,
        _ => REGISTER_COST_SAT,
    }
}

pub struct NsRegistry {
    tree: Arc<sled::Tree>,
    is_testnet: bool,
}

impl NsRegistry {
    pub fn open(db: &sled::Db, is_testnet: bool) -> Result<Self, NsError> {
        Ok(Self {
            tree: Arc::new(db.open_tree(b"identity/ns")?),
            is_testnet,
        })
    }

    pub fn fee_for_tld(&self, tld: &str) -> u64 {
        fee_for_tld(tld, self.is_testnet)
    }

    /// Register a name. Errors if name invalid, already taken, or fee short.
    pub fn register_name(
        &self,
        name: &str,
        tld: &str,
        owner: &str,
        years: u32,
        paid_sat: u64,
        current_block: u64,
    ) -> Result<NsEntry, NsError> {
        validate_name(name)?;
        let key = canonical_key(name, tld);
        if let Some(existing) = self.tree.get(key.as_bytes())? {
            let prev: NsEntry = serde_json::from_slice(&existing)?;
            if !prev.is_expired(current_block) {
                return Err(NsError::NameTaken);
            }
        }
        let required = self.fee_for_tld(tld) * years.max(1) as u64;
        if paid_sat < required {
            return Err(NsError::InsufficientFee { required, paid: paid_sat });
        }
        let entry = NsEntry {
            name: name.to_lowercase(),
            tld: tld.to_lowercase(),
            owner: owner.to_string(),
            registered_at_block: current_block,
            expires_at_block: current_block + (years as u64) * BLOCKS_PER_YEAR,
            years,
        };
        self.tree.insert(key.as_bytes(), serde_json::to_vec(&entry)?)?;
        Ok(entry)
    }

    /// Transfer name to a new owner. Owner must match the stored value.
    pub fn transfer_name(
        &self,
        name: &str,
        tld: &str,
        current_owner: &str,
        new_owner: &str,
        current_block: u64,
    ) -> Result<NsEntry, NsError> {
        let key = canonical_key(name, tld);
        let raw = self.tree.get(key.as_bytes())?.ok_or(NsError::NotFound)?;
        let mut entry: NsEntry = serde_json::from_slice(&raw)?;
        if entry.owner != current_owner {
            return Err(NsError::NotOwner);
        }
        if entry.is_expired(current_block) {
            return Err(NsError::Expired);
        }
        entry.owner = new_owner.to_string();
        self.tree.insert(key.as_bytes(), serde_json::to_vec(&entry)?)?;
        Ok(entry)
    }

    /// Resolve a name to its owner address. Returns `None` if not found or
    /// past grace period.
    pub fn resolve_name(
        &self,
        name: &str,
        tld: &str,
        current_block: u64,
    ) -> Result<Option<String>, NsError> {
        let key = canonical_key(name, tld);
        let Some(raw) = self.tree.get(key.as_bytes())? else {
            return Ok(None);
        };
        let entry: NsEntry = serde_json::from_slice(&raw)?;
        if entry.is_expired(current_block) {
            return Ok(None);
        }
        Ok(Some(entry.owner))
    }

    /// Inspect raw entry (for explorers / CLI). Returns even within grace
    /// period; caller decides what to do.
    pub fn get_entry(&self, name: &str, tld: &str) -> Result<Option<NsEntry>, NsError> {
        let key = canonical_key(name, tld);
        match self.tree.get(key.as_bytes())? {
            Some(raw) => Ok(Some(serde_json::from_slice(&raw)?)),
            None => Ok(None),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn db() -> sled::Db {
        sled::Config::new().temporary(true).open().unwrap()
    }

    #[test]
    fn fee_on_testnet_is_canonical() {
        assert_eq!(fee_for_tld("omnibus", true), 100_000_000);
        assert_eq!(fee_for_tld("arbitraje", true), 100_000_000);
    }

    #[test]
    fn fee_on_mainnet_per_tld() {
        assert_eq!(fee_for_tld("omnibus", false), COST_OMNIBUS_SAT);
        assert_eq!(fee_for_tld("arbitraje", false), COST_ARBITRAJE_SAT);
        assert_eq!(fee_for_tld("unknown", false), REGISTER_COST_SAT);
    }

    #[test]
    fn register_resolve_transfer_roundtrip() {
        let d = db();
        let ns = NsRegistry::open(&d, true).unwrap();

        let e = ns
            .register_name("alice", "omnibus", "ob1qalice", 1, ENS_FEE_TESTNET_SAT, 1000)
            .unwrap();
        assert_eq!(e.owner, "ob1qalice");
        assert_eq!(e.tld, "omnibus");

        let resolved = ns.resolve_name("alice", "omnibus", 1001).unwrap();
        assert_eq!(resolved.as_deref(), Some("ob1qalice"));

        let xfer = ns
            .transfer_name("alice", "omnibus", "ob1qalice", "ob1qbob", 1100)
            .unwrap();
        assert_eq!(xfer.owner, "ob1qbob");

        let r2 = ns.resolve_name("alice", "omnibus", 1101).unwrap();
        assert_eq!(r2.as_deref(), Some("ob1qbob"));
    }

    #[test]
    fn duplicate_register_rejected() {
        let d = db();
        let ns = NsRegistry::open(&d, true).unwrap();
        ns.register_name("alice", "omnibus", "ob1qa", 1, ENS_FEE_TESTNET_SAT, 1).unwrap();
        let err = ns
            .register_name("alice", "omnibus", "ob1qb", 1, ENS_FEE_TESTNET_SAT, 1)
            .unwrap_err();
        assert!(matches!(err, NsError::NameTaken));
    }

    #[test]
    fn insufficient_fee_rejected() {
        let d = db();
        let ns = NsRegistry::open(&d, true).unwrap();
        let err = ns
            .register_name("bob", "omnibus", "ob1qb", 1, ENS_FEE_TESTNET_SAT - 1, 1)
            .unwrap_err();
        assert!(matches!(err, NsError::InsufficientFee { .. }));
    }

    #[test]
    fn invalid_name_rejected() {
        let d = db();
        let ns = NsRegistry::open(&d, true).unwrap();
        assert!(matches!(
            ns.register_name("ab", "omnibus", "ob1q", 1, ENS_FEE_TESTNET_SAT, 1).unwrap_err(),
            NsError::InvalidName
        ));
        assert!(matches!(
            ns.register_name("-bad", "omnibus", "ob1q", 1, ENS_FEE_TESTNET_SAT, 1).unwrap_err(),
            NsError::InvalidName
        ));
    }

    #[test]
    fn non_owner_cannot_transfer() {
        let d = db();
        let ns = NsRegistry::open(&d, true).unwrap();
        ns.register_name("carol", "omnibus", "ob1qa", 1, ENS_FEE_TESTNET_SAT, 1).unwrap();
        let err = ns
            .transfer_name("carol", "omnibus", "ob1qb", "ob1qc", 2)
            .unwrap_err();
        assert!(matches!(err, NsError::NotOwner));
    }
}
