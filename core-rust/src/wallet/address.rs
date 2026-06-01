// Address types + encoding.
//
// Native OMNI: ob1q... bech32 (HRP "ob", witness v0, 20-byte hash160).
//   vector: hash160 = 751e76e8...3bd6 -> ob1q... (cf. core/bech32.zig test)
//
// EVM: 0x... with EIP-55 checksum casing.
//   address = keccak256(uncompressed_pubkey_xy_64bytes)[12..32]
//   checksum casing per EIP-55: uppercase nibble if keccak(lowercase_hex_addr)[i] >= 8.

use sha3::{Keccak256, Digest};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AddressKind {
    OmniNative,   // ob1q... bech32 v0
    OmniTaproot,  // ob1p... bech32m v1
    PqSoulbound,  // ob_{k1,f5,d5,s3}_... base58check
    Evm,          // 0x... EIP-55
}

#[derive(Debug, Clone)]
pub struct Address {
    pub kind: AddressKind,
    pub repr: String,
    pub coin_type: u32,
    pub index: u32,
}

/// EIP-55 checksum address from a 64-byte uncompressed pubkey (X||Y, no 0x04).
pub fn evm_checksum_address(uncompressed_pubkey_xy: &[u8; 64]) -> String {
    let mut k = Keccak256::new();
    k.update(uncompressed_pubkey_xy);
    let h = k.finalize();
    let addr20 = &h[12..32];
    eip55(addr20)
}

fn eip55(addr20: &[u8]) -> String {
    // lowercase hex (no 0x), keccak it, then case each nibble.
    let lower_hex: String = addr20.iter().map(|b| format!("{:02x}", b)).collect();
    let mut k = Keccak256::new();
    k.update(lower_hex.as_bytes());
    let hash = k.finalize();
    let mut out = String::with_capacity(42);
    out.push_str("0x");
    for (i, c) in lower_hex.chars().enumerate() {
        if c.is_ascii_digit() {
            out.push(c);
        } else {
            // nibble i of hash (high nibble of byte i/2, low nibble of i%2==1)
            let byte = hash[i / 2];
            let nibble = if i % 2 == 0 { byte >> 4 } else { byte & 0x0f };
            if nibble >= 8 {
                out.push(c.to_ascii_uppercase());
            } else {
                out.push(c);
            }
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    // EIP-55 reference vector from EIP-55 spec:
    // 0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed (mixed case)
    // lowercase repr: 5aaeb6053f3e94c9b9a09f33669435e7ef1beaed
    #[test]
    fn eip55_reference_vector() {
        // Take the 20-byte address bytes
        let addr20: [u8; 20] = hex_decode("5aaeb6053f3e94c9b9a09f33669435e7ef1beaed");
        let s = eip55(&addr20);
        assert_eq!(s, "0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed");
    }

    fn hex_decode(s: &str) -> [u8; 20] {
        let mut out = [0u8; 20];
        for i in 0..20 {
            out[i] = u8::from_str_radix(&s[i*2..i*2+2], 16).unwrap();
        }
        out
    }
}
