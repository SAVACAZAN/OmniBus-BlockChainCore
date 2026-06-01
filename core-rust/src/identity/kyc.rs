//! KYC status storage + getStatus.
//!
//! Per-address sled::Tree of `KycStatus` blobs. Stored value = canonical
//! JSON so off-chain tooling can read it without the chain binary.

use serde::{Deserialize, Serialize};
use std::sync::Arc;
use thiserror::Error;

#[derive(Debug, Error)]
pub enum KycError {
    #[error("storage error: {0}")]
    Storage(#[from] sled::Error),
    #[error("encoding error: {0}")]
    Encoding(#[from] serde_json::Error),
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct KycStatus {
    pub address: String,
    /// SHA-256 of (salt || kyc_doc) — opaque to the chain.
    pub kyc_hash: [u8; 32],
    pub is_verified: bool,
    pub valid_until_unix_s: u64,
    /// Hash of issuer DID (KYC provider).
    pub issuer_did_hash: [u8; 32],
}

impl KycStatus {
    pub fn is_currently_valid(&self, now_unix_s: u64) -> bool {
        if !self.is_verified {
            return false;
        }
        if self.valid_until_unix_s == 0 {
            return true;
        }
        self.valid_until_unix_s > now_unix_s
    }
}

/// Sled-backed KYC store, keyed by address string.
pub struct KycStore {
    tree: Arc<sled::Tree>,
}

impl KycStore {
    pub fn open(db: &sled::Db) -> Result<Self, KycError> {
        Ok(Self {
            tree: Arc::new(db.open_tree(b"identity/kyc")?),
        })
    }

    pub fn put(&self, status: &KycStatus) -> Result<(), KycError> {
        let v = serde_json::to_vec(status)?;
        self.tree.insert(status.address.as_bytes(), v)?;
        Ok(())
    }

    pub fn get(&self, address: &str) -> Result<Option<KycStatus>, KycError> {
        match self.tree.get(address.as_bytes())? {
            Some(v) => Ok(Some(serde_json::from_slice(&v)?)),
            None => Ok(None),
        }
    }

    pub fn delete(&self, address: &str) -> Result<(), KycError> {
        self.tree.remove(address.as_bytes())?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sled_tmp() -> sled::Db {
        sled::Config::new().temporary(true).open().unwrap()
    }

    #[test]
    fn put_get_delete() {
        let db = sled_tmp();
        let store = KycStore::open(&db).unwrap();
        let s = KycStatus {
            address: "ob1qtest".into(),
            kyc_hash: [0xAB; 32],
            is_verified: true,
            valid_until_unix_s: 2_000_000_000,
            issuer_did_hash: [0u8; 32],
        };
        store.put(&s).unwrap();
        let got = store.get("ob1qtest").unwrap().unwrap();
        assert_eq!(got, s);
        store.delete("ob1qtest").unwrap();
        assert!(store.get("ob1qtest").unwrap().is_none());
    }

    #[test]
    fn validity_window() {
        let s = KycStatus {
            address: "x".into(),
            kyc_hash: [0u8; 32],
            is_verified: true,
            valid_until_unix_s: 2_000_000_000,
            issuer_did_hash: [0u8; 32],
        };
        assert!(s.is_currently_valid(1_900_000_000));
        assert!(!s.is_currently_valid(2_100_000_000));

        let never_expires = KycStatus { valid_until_unix_s: 0, ..s.clone() };
        assert!(never_expires.is_currently_valid(u64::MAX));

        let unverified = KycStatus { is_verified: false, ..s };
        assert!(!unverified.is_currently_valid(0));
    }
}
