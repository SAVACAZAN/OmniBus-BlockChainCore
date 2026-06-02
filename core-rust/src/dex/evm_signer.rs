//! evm_signer — sign legacy EVM transactions (EIP-155) using secp256k1.
//!
//! Produces a single correct signed tx (k256 exposes the recovery id
//! directly, so we don't need the two-candidate workaround the Zig version
//! uses). Wire format: RLP-encoded legacy tx with EIP-155 v.
//!
//! Ported from `core/bridge/evm_signer.zig`.

use k256::{
    ecdsa::{signature::hazmat::PrehashSigner, RecoveryId, Signature, SigningKey as EcdsaKey},
    SecretKey,
};
use sha3::{Digest, Keccak256};

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

/// Caller-provided operator key (BIP-44 m/44'/60'/0'/0/2 from founder
/// mnemonic = exchange.omnibus slot).
#[derive(Debug, Clone)]
pub struct SigningKey {
    pub private_key: [u8; 32],
    pub address: [u8; 20],
}

impl SigningKey {
    /// Derive the 20-byte EVM address from a raw secp256k1 private key.
    pub fn from_privkey(pk: [u8; 32]) -> Result<Self, SignError> {
        let sk = SecretKey::from_slice(&pk).map_err(|_| SignError::InvalidPrivateKey)?;
        let vk = sk.public_key();
        // Uncompressed SEC1 = 0x04 || x(32) || y(32) → 65 bytes.
        let sec1 = vk.to_sec1_bytes();
        let hash = Keccak256::digest(&sec1[1..]);
        let mut addr = [0u8; 20];
        addr.copy_from_slice(&hash[12..]);
        Ok(Self { private_key: pk, address: addr })
    }
}

/// Inputs to a legacy transaction.
#[derive(Debug, Clone)]
pub struct TxInput {
    pub chain_id: u64,
    pub nonce: u64,
    /// Wei.
    pub gas_price: u64,
    pub gas_limit: u64,
    /// 20-byte target contract.
    pub to: [u8; 20],
    /// Wei (0 for pure ERC-20 calls).
    pub value: u128,
    /// ABI-encoded calldata.
    pub data: Vec<u8>,
}

#[derive(Debug, thiserror::Error)]
pub enum SignError {
    #[error("invalid private key")]
    InvalidPrivateKey,
    #[error("sign operation failed")]
    SignFailed,
    #[error("hex decode: {0}")]
    HexDecode(String),
}

// ---------------------------------------------------------------------------
// RLP helpers
// ---------------------------------------------------------------------------

fn rlp_uint(v: u128) -> Vec<u8> {
    if v == 0 {
        return vec![0x80]; // empty string = 0
    }
    let bytes = v.to_be_bytes();
    let start = bytes.iter().position(|&b| b != 0).unwrap_or(15);
    rlp_bytes_raw(&bytes[start..])
}

fn rlp_bytes_raw(data: &[u8]) -> Vec<u8> {
    if data.len() == 1 && data[0] < 0x80 {
        return data.to_vec();
    }
    let mut out = Vec::new();
    if data.len() <= 55 {
        out.push(0x80 + data.len() as u8);
    } else {
        let len_b = data.len().to_be_bytes();
        let s = len_b.iter().position(|&b| b != 0).unwrap_or(7);
        let lb = &len_b[s..];
        out.push(0xb7 + lb.len() as u8);
        out.extend_from_slice(lb);
    }
    out.extend_from_slice(data);
    out
}

fn rlp_list(items: &[Vec<u8>]) -> Vec<u8> {
    let body: Vec<u8> = items.iter().flat_map(|i| i.iter().cloned()).collect();
    let mut out = Vec::new();
    if body.len() <= 55 {
        out.push(0xc0 + body.len() as u8);
    } else {
        let len_b = body.len().to_be_bytes();
        let s = len_b.iter().position(|&b| b != 0).unwrap_or(7);
        let lb = &len_b[s..];
        out.push(0xf7 + lb.len() as u8);
        out.extend_from_slice(lb);
    }
    out.extend(body);
    out
}

fn keccak256(data: &[u8]) -> [u8; 32] {
    let mut out = [0u8; 32];
    out.copy_from_slice(&Keccak256::digest(data));
    out
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Sign a legacy EIP-155 transaction. Returns the RLP-encoded signed tx as
/// `"0x..." hex` ready for `eth_sendRawTransaction`.
pub fn sign_legacy_tx(tx: &TxInput, key: &SigningKey) -> Result<String, SignError> {
    // Step 1: signing pre-image = RLP([nonce, gp, gl, to, value, data, chainId, 0, 0])
    let pre_items: Vec<Vec<u8>> = vec![
        rlp_uint(tx.nonce as u128),
        rlp_uint(tx.gas_price as u128),
        rlp_uint(tx.gas_limit as u128),
        rlp_bytes_raw(&tx.to),
        rlp_uint(tx.value),
        rlp_bytes_raw(&tx.data),
        rlp_uint(tx.chain_id as u128),
        rlp_uint(0),
        rlp_uint(0),
    ];
    let pre_rlp = rlp_list(&pre_items);
    let hash = keccak256(&pre_rlp);

    // Step 2: ECDSA sign with recovery id
    let sk = EcdsaKey::from_slice(&key.private_key)
        .map_err(|_| SignError::InvalidPrivateKey)?;
    let (sig, recid): (Signature, RecoveryId) = sk
        .sign_prehash_recoverable(&hash)
        .map_err(|_| SignError::SignFailed)?;

    let sig_bytes = sig.to_bytes();
    let r = &sig_bytes[..32];
    let s = &sig_bytes[32..];

    // Step 3: EIP-155 v = chain_id * 2 + 35 + recovery_id
    let v: u128 = tx.chain_id as u128 * 2 + 35 + recid.to_byte() as u128;

    // Step 4: signed tx RLP
    let signed_items: Vec<Vec<u8>> = vec![
        rlp_uint(tx.nonce as u128),
        rlp_uint(tx.gas_price as u128),
        rlp_uint(tx.gas_limit as u128),
        rlp_bytes_raw(&tx.to),
        rlp_uint(tx.value),
        rlp_bytes_raw(&tx.data),
        rlp_uint(v),
        rlp_bytes_raw(r),
        rlp_bytes_raw(s),
    ];
    let encoded = rlp_list(&signed_items);
    Ok(format!("0x{}", hex::encode(encoded)))
}

/// Parse `"0x..."` hex into a fixed-size byte array.
pub fn hex0x_to_bytes<const N: usize>(s: &str) -> Result<[u8; N], SignError> {
    let hex = s.strip_prefix("0x").or_else(|| s.strip_prefix("0X")).unwrap_or(s);
    if hex.len() != N * 2 {
        return Err(SignError::HexDecode(format!(
            "expected {} hex chars, got {}",
            N * 2,
            hex.len()
        )));
    }
    let v = hex::decode(hex).map_err(|e| SignError::HexDecode(e.to_string()))?;
    let mut out = [0u8; N];
    out.copy_from_slice(&v);
    Ok(out)
}

/// Format a 20-byte address as `"0x..."` lowercase hex.
pub fn addr_to_hex(addr: &[u8; 20]) -> String {
    format!("0x{}", hex::encode(addr))
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rlp_zero_is_0x80() {
        assert_eq!(rlp_uint(0), vec![0x80]);
    }

    #[test]
    fn rlp_single_byte_under_80() {
        // 0x01 encodes as itself (< 0x80, single byte)
        assert_eq!(rlp_uint(1), vec![0x01]);
    }

    #[test]
    fn hex0x_to_bytes_roundtrip() {
        let addr_hex = "0x0000000000000000000000000000000000000001";
        let addr: [u8; 20] = hex0x_to_bytes(addr_hex).unwrap();
        assert_eq!(addr[19], 1);
        assert_eq!(addr[0], 0);
    }

    #[test]
    fn settle_selector_keccak() {
        // keccak256("settle(uint256,address)")[0..4] == 0x962d1938
        let hash = keccak256(b"settle(uint256,address)");
        assert_eq!(hash[0], 0x96);
        assert_eq!(hash[1], 0x2d);
        assert_eq!(hash[2], 0x19);
        assert_eq!(hash[3], 0x38);
    }
}
