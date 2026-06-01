//! Periodic external-feed ingest into the flag registry.
//!
//! Today we support a JSONL file feed (one record per line). The path
//! can come from a config flag or a cron-style poller. Each record has:
//!
//! ```json
//! {"address": "0x1234..(40 hex)", "severity": "sanctioned",
//!  "reason": "OFAC SDN list 2025-01-02", "source": "ofac"}
//! ```
//!
//! Records flagged via the oracle feed use a synthetic reporter address
//! (all-zero 20 bytes), bypass the reporter-whitelist check, and arrive
//! at the registry already attestation-confirmed (oracle = upstream
//! attestation).

use super::flags::{FlagSeverity, FlagsRegistry, FlagsError};
use serde::Deserialize;
use sha2::{Digest, Sha256};
use std::fs::File;
use std::io::{BufRead, BufReader};
use thiserror::Error;

pub const ORACLE_REPORTER: [u8; 20] = [0u8; 20];

#[derive(Debug, Error)]
pub enum OracleSyncError {
    #[error("io: {0}")]
    Io(#[from] std::io::Error),
    #[error("json: {0}")]
    Json(#[from] serde_json::Error),
    #[error("flag store: {0}")]
    Flags(#[from] FlagsError),
    #[error("bad address {0}")]
    BadAddress(String),
    #[error("bad severity {0}")]
    BadSeverity(String),
}

#[derive(Debug, Deserialize)]
struct FeedRecord {
    address: String,
    severity: String,
    reason: String,
    #[serde(default)]
    source: String,
}

/// Read a JSONL feed file and insert/attest entries into `registry`.
/// Existing flags are bumped via `add_attestation` (using the synthetic
/// oracle reporter) so re-running the sync is idempotent. Returns the
/// number of records processed.
pub fn sync_from_file(
    registry: &FlagsRegistry,
    path: &str,
    current_block: u64,
) -> Result<usize, OracleSyncError> {
    let file = File::open(path)?;
    let reader = BufReader::new(file);
    let mut n = 0usize;
    for line in reader.lines() {
        let line = line?;
        let trimmed = line.trim();
        if trimmed.is_empty() || trimmed.starts_with('#') {
            continue;
        }
        let rec: FeedRecord = serde_json::from_str(trimmed)?;
        let addr = parse_addr_20(&rec.address)
            .ok_or_else(|| OracleSyncError::BadAddress(rec.address.clone()))?;
        let severity = FlagSeverity::from_str(&rec.severity)
            .ok_or_else(|| OracleSyncError::BadSeverity(rec.severity.clone()))?;
        let evidence = evidence_hash(&rec);

        match registry.get_flag(&addr)? {
            None => {
                registry.flag_address(
                    addr,
                    severity,
                    rec.reason.clone(),
                    evidence,
                    ORACLE_REPORTER,
                    current_block,
                )?;
            }
            Some(existing) => {
                if !existing.reporters.iter().any(|r| r == &ORACLE_REPORTER) {
                    // first-time oracle attestation on a community flag
                    let _ = registry.add_attestation(&addr, ORACLE_REPORTER);
                }
            }
        }
        n += 1;
    }
    Ok(n)
}

fn parse_addr_20(s: &str) -> Option<[u8; 20]> {
    let s = s.trim().trim_start_matches("0x");
    if s.len() != 40 { return None; }
    let raw = hex::decode(s).ok()?;
    if raw.len() != 20 { return None; }
    let mut a = [0u8; 20];
    a.copy_from_slice(&raw);
    Some(a)
}

fn evidence_hash(rec: &FeedRecord) -> [u8; 32] {
    let mut h = Sha256::new();
    h.update(rec.source.as_bytes());
    h.update(b"|");
    h.update(rec.reason.as_bytes());
    h.update(b"|");
    h.update(rec.address.as_bytes());
    let mut out = [0u8; 32];
    out.copy_from_slice(&h.finalize());
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    #[test]
    fn ingest_jsonl() {
        let dir = tempdir();
        let path = format!("{}/feed.jsonl", dir);
        {
            let mut f = File::create(&path).unwrap();
            writeln!(
                f,
                r#"{{"address":"0x{}","severity":"sanctioned","reason":"OFAC SDN","source":"ofac"}}"#,
                "11".repeat(20)
            ).unwrap();
            writeln!(
                f,
                r#"{{"address":"0x{}","severity":"phishing","reason":"reported phish","source":"community"}}"#,
                "22".repeat(20)
            ).unwrap();
        }
        let db = sled::Config::new().temporary(true).open().unwrap();
        let reg = FlagsRegistry::open(&db).unwrap();
        let n = sync_from_file(&reg, &path, 10).unwrap();
        assert_eq!(n, 2);
        let a1 = [0x11u8; 20];
        assert_eq!(reg.get_flag(&a1).unwrap().unwrap().severity, FlagSeverity::Sanctioned);
        // re-run = idempotent
        sync_from_file(&reg, &path, 11).unwrap();
        let _ = std::fs::remove_dir_all(&dir);
    }

    fn tempdir() -> String {
        let p = std::env::temp_dir().join(format!("omnibus-oracle-test-{}", rand_suffix()));
        std::fs::create_dir_all(&p).unwrap();
        p.to_string_lossy().to_string()
    }

    fn rand_suffix() -> u64 {
        use std::time::{SystemTime, UNIX_EPOCH};
        SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos() as u64
    }
}
