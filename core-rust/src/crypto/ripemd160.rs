// RIPEMD-160 + Hash160 = RIPEMD160(SHA256(data)). Mirror of core/ripemd160.zig.
// We use the `ripemd` crate; Zig uses a hand-rolled impl but both implement
// the same FIPS-compatible RIPEMD-160, so outputs are identical.

use ripemd::{Ripemd160, Digest as RipemdDigest};
use sha2::Sha256;
use sha2::Digest as _;

/// RIPEMD-160 of arbitrary bytes — 20-byte output.
pub fn ripemd160(data: &[u8]) -> [u8; 20] {
    let mut hasher = Ripemd160::new();
    hasher.update(data);
    let out = hasher.finalize();
    let mut arr = [0u8; 20];
    arr.copy_from_slice(&out);
    arr
}

/// Hash160 = RIPEMD160(SHA256(data)). Same as Bitcoin / OmniBus.
pub fn hash160(data: &[u8]) -> [u8; 20] {
    let mut sha = Sha256::new();
    sha.update(data);
    let sha_out = sha.finalize();
    ripemd160(&sha_out)
}
