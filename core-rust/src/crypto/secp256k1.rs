// secp256k1 wrapper over the k256 crate.
// Mirrors core/secp256k1.zig: privateKeyToPublicKey (33-byte compressed),
// privateKeyToHash160 (20-byte), uncompressed pubkey for EVM addresses.
//
// k256 internally implements RFC 6979 + SEC1 compressed encoding; same bytes
// as the pure-Zig core/secp256k1.zig impl for any given private key.

use k256::elliptic_curve::sec1::ToEncodedPoint;
use k256::{SecretKey, PublicKey};
use super::ripemd160::hash160;

/// Convert a 32-byte private key to the 33-byte SEC1 compressed public key.
/// Matches `Secp256k1Crypto.privateKeyToPublicKey` in core/secp256k1.zig.
pub fn private_key_to_public_key(private_key: &[u8; 32]) -> Result<[u8; 33], String> {
    let sk = SecretKey::from_slice(private_key).map_err(|e| format!("invalid privkey: {e}"))?;
    let pk: PublicKey = sk.public_key();
    let enc = pk.to_encoded_point(true); // compressed
    let bytes = enc.as_bytes();
    if bytes.len() != 33 {
        return Err(format!("unexpected compressed pubkey len {}", bytes.len()));
    }
    let mut out = [0u8; 33];
    out.copy_from_slice(bytes);
    Ok(out)
}

/// 64-byte uncompressed pubkey (X || Y, no 0x04 prefix). Used for EVM keccak.
pub fn private_key_to_uncompressed(private_key: &[u8; 32]) -> Result<[u8; 64], String> {
    let sk = SecretKey::from_slice(private_key).map_err(|e| format!("invalid privkey: {e}"))?;
    let pk: PublicKey = sk.public_key();
    let enc = pk.to_encoded_point(false); // uncompressed: 0x04 || X || Y
    let bytes = enc.as_bytes();
    if bytes.len() != 65 || bytes[0] != 0x04 {
        return Err(format!("unexpected uncompressed pubkey len {}", bytes.len()));
    }
    let mut out = [0u8; 64];
    out.copy_from_slice(&bytes[1..]);
    Ok(out)
}

/// Hash160 of compressed pubkey for a private key.
pub fn private_key_to_hash160(private_key: &[u8; 32]) -> Result<[u8; 20], String> {
    let pubkey = private_key_to_public_key(private_key)?;
    Ok(hash160(&pubkey))
}
