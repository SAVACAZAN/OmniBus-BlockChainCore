//! DID Core resolver — `did:omnibus:<base58(sha256(pubkey))>`.
//!
//! Matches the Zig output for the same compressed pubkey byte-for-byte
//! (SHA-256 of the 33-byte compressed pubkey, Base58 with leading-'1' zero
//! preservation per Bitcoin convention).

use sha2::{Digest, Sha256};
use thiserror::Error;

pub const DID_PREFIX: &str = "did:omnibus:";

const B58_ALPHABET: &[u8] = b"123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";

#[derive(Debug, Error, PartialEq)]
pub enum DidError {
    #[error("invalid DID format")]
    InvalidDid,
    #[error("unknown identifier")]
    UnknownIdentifier,
}

pub type Did = String;

/// Bitcoin-style Base58 encoder. Preserves leading zero bytes as '1's.
fn base58_encode(data: &[u8]) -> String {
    if data.is_empty() {
        return String::new();
    }
    let zeros = data.iter().take_while(|&&b| b == 0).count();
    let mut work: Vec<u8> = data.to_vec();
    let max_out = data.len() * 138 / 100 + 1;
    let mut buf = vec![0u8; max_out];
    let mut out_len = 0usize;
    let mut start = zeros;
    while start < work.len() {
        let mut remainder: u32 = 0;
        for byte in work.iter_mut().skip(start) {
            let acc = (remainder << 8) | (*byte as u32);
            *byte = (acc / 58) as u8;
            remainder = acc % 58;
        }
        buf[out_len] = B58_ALPHABET[remainder as usize];
        out_len += 1;
        while start < work.len() && work[start] == 0 {
            start += 1;
        }
    }
    let mut final_out = Vec::with_capacity(zeros + out_len);
    for _ in 0..zeros {
        final_out.push(b'1');
    }
    for k in 0..out_len {
        final_out.push(buf[out_len - 1 - k]);
    }
    String::from_utf8(final_out).expect("base58 alphabet is ASCII")
}

/// Build the DID for a 33-byte compressed secp256k1 public key.
pub fn did_from_compressed_pubkey(compressed_pubkey: &[u8; 33]) -> Did {
    let hash: [u8; 32] = Sha256::digest(compressed_pubkey).into();
    format!("{}{}", DID_PREFIX, base58_encode(&hash))
}

/// Build the DID from a `hash160` (P2WPKH program). Pads to 32 bytes by
/// SHA-256 so the DID-method-identifier length stays constant.
pub fn did_from_hash160(hash160: &[u8; 20]) -> Did {
    let padded: [u8; 32] = Sha256::digest(hash160).into();
    format!("{}{}", DID_PREFIX, base58_encode(&padded))
}

/// Returns the method-identifier slice after `did:omnibus:`.
pub fn parse_did(did: &str) -> Result<&str, DidError> {
    let body = did.strip_prefix(DID_PREFIX).ok_or(DidError::InvalidDid)?;
    if body.is_empty() {
        return Err(DidError::InvalidDid);
    }
    Ok(body)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn did_has_stable_prefix() {
        let mut pk = [0x02u8; 33];
        pk[1] = 0x01;
        let did = did_from_compressed_pubkey(&pk);
        assert!(did.starts_with(DID_PREFIX));
    }

    #[test]
    fn did_is_deterministic() {
        let mut pk = [0x03u8; 33];
        pk[2] = 0x42;
        assert_eq!(did_from_compressed_pubkey(&pk), did_from_compressed_pubkey(&pk));
    }

    #[test]
    fn did_differs_for_distinct_pubkeys() {
        let a = did_from_compressed_pubkey(&[0x02u8; 33]);
        let b = did_from_compressed_pubkey(&[0x03u8; 33]);
        assert_ne!(a, b);
    }

    #[test]
    fn parse_did_splits() {
        assert_eq!(parse_did("did:omnibus:1ABCxyz").unwrap(), "1ABCxyz");
        assert_eq!(parse_did("did:other:body"), Err(DidError::InvalidDid));
        assert_eq!(parse_did("did:omnibus:"), Err(DidError::InvalidDid));
    }

    #[test]
    fn base58_all_zero_is_all_ones() {
        assert_eq!(base58_encode(&[0, 0, 0, 0]), "1111");
    }
}
