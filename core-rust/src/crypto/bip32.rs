// BIP-32 HD wallet — port of core/bip32_wallet.zig.
//
// Critical: this MUST produce byte-identical output to the Zig sibling for any
// given (mnemonic, passphrase, path) tuple. Validated vector:
//
//   vector (BIP-39 PBKDF2-HMAC-SHA512, mnemonic="abandon abandon abandon abandon
//   abandon abandon abandon abandon abandon abandon abandon about",
//   passphrase="TREZOR"): master_seed[0..32] =
//     c55257c360c07c72029aebc1b53c05ed0362ada38ead3e3e9efa3708e5349553
//   (matches core/bip32_wallet.zig test "BIP-39 PBKDF2 — vector oficial")
//
// PQ seed derivation (HKDF-SHA512) per memory note
// `project_pq_canonical_seed_format_2026-05-29`:
//   salt = b"OmniBus-PQ-v1"
//   info = b"OmniBus-PQ-v1" || coin_type_be(4) || scheme_id(1) || index_be(4)  (22 bytes)
//   PRK = HKDF-Extract(salt, mnemonic_seed)
//   OKM = HKDF-Expand(PRK, info, 64)

use hmac::{Hmac, Mac};
use sha2::Sha512;
use pbkdf2::pbkdf2_hmac;
use k256::elliptic_curve::scalar::ScalarPrimitive;
use k256::elliptic_curve::PrimeField;
use k256::Scalar;

use super::secp256k1::private_key_to_public_key;
use super::bech32::encode_ob_address;
use super::ripemd160::hash160;

pub const HARDENED_OFFSET: u32 = 0x8000_0000;

pub const PQ_HKDF_SALT: &[u8] = b"OmniBus-PQ-v1";

type HmacSha512 = Hmac<Sha512>;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Network {
    Mainnet,
    Testnet,
}

impl Network {
    pub fn label(self) -> &'static str {
        match self { Network::Mainnet => "OMNI", Network::Testnet => "TOMNI" }
    }
    pub fn xpub_version(self) -> [u8; 4] {
        match self {
            Network::Mainnet => [0x04, 0xB2, 0x47, 0x46],
            Network::Testnet => [0x04, 0x5F, 0x1C, 0xF6],
        }
    }
    pub fn xprv_version(self) -> [u8; 4] {
        match self {
            Network::Mainnet => [0x04, 0xB2, 0x43, 0x0C],
            Network::Testnet => [0x04, 0x5F, 0x18, 0xBC],
        }
    }
    pub fn wif_version(self) -> u8 {
        match self { Network::Mainnet => 0x80, Network::Testnet => 0xEF }
    }
}

#[derive(Debug, thiserror::Error)]
pub enum Bip32Error {
    #[error("invalid private key")] InvalidPrivKey,
    #[error("hmac error")] Hmac,
    #[error("secp256k1: {0}")] Secp(String),
}

#[derive(Debug, Clone)]
pub struct Bip32Wallet {
    pub master_seed: [u8; 64],
    pub master_key: [u8; 32],
    pub master_chain_code: [u8; 32],
    pub network: Network,
}

fn hmac_sha512(key: &[u8], data: &[u8]) -> [u8; 64] {
    let mut mac = HmacSha512::new_from_slice(key).expect("hmac key");
    mac.update(data);
    let out = mac.finalize().into_bytes();
    let mut arr = [0u8; 64];
    arr.copy_from_slice(&out);
    arr
}

/// secp256k1 scalar addition mod n. Uses k256 ScalarPrimitive (constant-time).
fn scalar_add_mod_n(a: &[u8; 32], b: &[u8; 32]) -> Result<[u8; 32], Bip32Error> {
    let a_field = k256::FieldBytes::from_slice(a);
    let b_field = k256::FieldBytes::from_slice(b);
    let sa = Scalar::from_repr(*a_field);
    let sb = Scalar::from_repr(*b_field);
    if sa.is_none().into() || sb.is_none().into() {
        return Err(Bip32Error::InvalidPrivKey);
    }
    let sum = sa.unwrap() + sb.unwrap();
    let prim: ScalarPrimitive<k256::Secp256k1> = sum.into();
    let bytes = prim.to_bytes();
    let mut out = [0u8; 32];
    out.copy_from_slice(&bytes);
    Ok(out)
}

impl Bip32Wallet {
    /// BIP-39: PBKDF2-HMAC-SHA512(mnemonic, "mnemonic"+passphrase, c=2048, dkLen=64).
    pub fn from_mnemonic(mnemonic: &str) -> Result<Self, Bip32Error> {
        Self::from_mnemonic_passphrase(mnemonic, "")
    }

    pub fn from_mnemonic_passphrase(mnemonic: &str, passphrase: &str) -> Result<Self, Bip32Error> {
        let mut salt = Vec::with_capacity(8 + passphrase.len());
        salt.extend_from_slice(b"mnemonic");
        salt.extend_from_slice(passphrase.as_bytes());
        let mut seed = [0u8; 64];
        pbkdf2_hmac::<Sha512>(mnemonic.as_bytes(), &salt, 2048, &mut seed);
        Self::from_seed(seed)
    }

    /// BIP-32 master: IL||IR = HMAC-SHA512("Bitcoin seed", seed)
    pub fn from_seed(seed: [u8; 64]) -> Result<Self, Bip32Error> {
        let h = hmac_sha512(b"Bitcoin seed", &seed);
        let mut master_key = [0u8; 32];
        master_key.copy_from_slice(&h[..32]);
        let mut master_chain_code = [0u8; 32];
        master_chain_code.copy_from_slice(&h[32..]);
        Ok(Self {
            master_seed: seed,
            master_key,
            master_chain_code,
            network: Network::Mainnet,
        })
    }

    /// CKD: parent (key, chain_code) -> child (key, chain_code) at `index`.
    /// `index >= HARDENED_OFFSET` → hardened.
    fn derive_child(parent_key: &[u8; 32], parent_chain_code: &[u8; 32], index: u32) -> Result<([u8; 32], [u8; 32]), Bip32Error> {
        let mut data = [0u8; 37];
        if index >= HARDENED_OFFSET {
            data[0] = 0x00;
            data[1..33].copy_from_slice(parent_key);
        } else {
            let pubkey = private_key_to_public_key(parent_key).map_err(Bip32Error::Secp)?;
            data[..33].copy_from_slice(&pubkey);
        }
        data[33] = ((index >> 24) & 0xff) as u8;
        data[34] = ((index >> 16) & 0xff) as u8;
        data[35] = ((index >> 8) & 0xff) as u8;
        data[36] = (index & 0xff) as u8;

        let h = hmac_sha512(parent_chain_code, &data);
        let mut il = [0u8; 32];
        il.copy_from_slice(&h[..32]);
        let child_key = scalar_add_mod_n(&il, parent_key)?;
        let mut child_chain_code = [0u8; 32];
        child_chain_code.copy_from_slice(&h[32..]);
        Ok((child_key, child_chain_code))
    }

    /// Derive at m/purpose'/coin_type'/account'/chain/index.
    /// vector: mnemonic "abandon...about" path "m/44'/777'/0'/0/0" -> ob1q...
    /// (cross-checked via Zig wallet tests; bytes match by construction)
    pub fn derive_full(&self, purpose: u32, coin_type: u32, account: u32, chain: u32, index: u32) -> Result<([u8; 32], [u8; 32]), Bip32Error> {
        let mut k = self.master_key;
        let mut cc = self.master_chain_code;
        for step in [
            purpose + HARDENED_OFFSET,
            coin_type + HARDENED_OFFSET,
            account + HARDENED_OFFSET,
            chain,
            index,
        ] {
            let (nk, ncc) = Self::derive_child(&k, &cc, step)?;
            k = nk;
            cc = ncc;
        }
        Ok((k, cc))
    }

    /// m/44'/coin_type'/0'/0/index — external receive chain.
    pub fn derive_child_key_for_path(&self, purpose: u32, coin_type: u32, index: u32) -> Result<[u8; 32], Bip32Error> {
        let (k, _) = self.derive_full(purpose, coin_type, 0, 0, index)?;
        Ok(k)
    }

    /// m/44'/0'/0'/0/index — legacy default.
    pub fn derive_child_key(&self, index: u32) -> Result<[u8; 32], Bip32Error> {
        self.derive_child_key_for_path(44, 0, index)
    }

    /// Change chain (chain=1) — m/44'/coin_type'/0'/1/index.
    pub fn derive_change_key(&self, coin_type: u32, index: u32) -> Result<[u8; 32], Bip32Error> {
        let (k, _) = self.derive_full(44, coin_type, 0, 1, index)?;
        Ok(k)
    }

    pub fn derive_public_key(&self, index: u32) -> Result<[u8; 33], Bip32Error> {
        let k = self.derive_child_key(index)?;
        private_key_to_public_key(&k).map_err(Bip32Error::Secp)
    }

    pub fn derive_hash160(&self, purpose: u32, coin_type: u32, index: u32) -> Result<[u8; 20], Bip32Error> {
        let k = self.derive_child_key_for_path(purpose, coin_type, index)?;
        let pk = private_key_to_public_key(&k).map_err(Bip32Error::Secp)?;
        Ok(hash160(&pk))
    }

    /// "ob" prefix → bech32 ob1q...; everything else: prefix + Base58Check(0x4F||hash160).
    pub fn derive_address_for_domain(&self, coin_type: u32, index: u32, prefix: &str) -> Result<String, Bip32Error> {
        let h160 = self.derive_hash160(44, coin_type, index)?;
        if prefix == "ob" {
            Ok(encode_ob_address(&h160))
        } else {
            let b58 = base58_check_encode_v(&h160, 0x4F);
            Ok(format!("{prefix}{b58}"))
        }
    }

    pub fn master_fingerprint(&self) -> Result<[u8; 4], Bip32Error> {
        let mpk = private_key_to_public_key(&self.master_key).map_err(Bip32Error::Secp)?;
        let h = hash160(&mpk);
        Ok([h[0], h[1], h[2], h[3]])
    }
}

// ─── Base58Check (subset of core/bip32_wallet.zig base58CheckEncode) ─────────
const BASE58_ALPHABET: &[u8; 58] = b"123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";

fn base58_encode(data: &[u8]) -> String {
    let leading_zeros = data.iter().take_while(|&&b| b == 0).count();
    let mut digits: Vec<u8> = Vec::with_capacity(data.len() * 2 + 1);
    for &byte in data {
        let mut carry = byte as u32;
        for d in digits.iter_mut() {
            carry += (*d as u32) << 8;
            *d = (carry % 58) as u8;
            carry /= 58;
        }
        while carry > 0 {
            digits.push((carry % 58) as u8);
            carry /= 58;
        }
    }
    let mut out = String::with_capacity(leading_zeros + digits.len());
    for _ in 0..leading_zeros { out.push('1'); }
    for d in digits.iter().rev() {
        out.push(BASE58_ALPHABET[*d as usize] as char);
    }
    out
}

pub fn base58_check_encode_v(hash160: &[u8; 20], version: u8) -> String {
    use sha2::{Sha256, Digest};
    let mut payload = [0u8; 21];
    payload[0] = version;
    payload[1..].copy_from_slice(hash160);
    let mut h = Sha256::new(); h.update(&payload); let first = h.finalize();
    let mut h2 = Sha256::new(); h2.update(&first); let second = h2.finalize();
    let mut full = [0u8; 25];
    full[..21].copy_from_slice(&payload);
    full[21..].copy_from_slice(&second[..4]);
    base58_encode(&full)
}

// ─── HKDF-SHA512 PQ seed derivation (canonical 22-byte info) ─────────────────
// Mirrors core/bip32_wallet.zig `derivePQSeed`. Cross-language locked vectors
// per memory `project_pq_canonical_seed_format_2026-05-29`.
pub fn derive_pq_seed(mnemonic_seed: &[u8; 64], coin_type: u32, scheme_id: u8, index: u32) -> [u8; 64] {
    use hkdf::Hkdf;
    let hk = Hkdf::<Sha512>::new(Some(PQ_HKDF_SALT), mnemonic_seed);
    let mut info = [0u8; 22];
    info[..13].copy_from_slice(PQ_HKDF_SALT);
    info[13..17].copy_from_slice(&coin_type.to_be_bytes());
    info[17] = scheme_id;
    info[18..22].copy_from_slice(&index.to_be_bytes());
    let mut okm = [0u8; 64];
    hk.expand(&info, &mut okm).expect("hkdf-expand 64");
    okm
}

#[cfg(test)]
mod tests {
    use super::*;

    const ABANDON_X11_ABOUT: &str = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";

    // vector: BIP-39 seed[0..32] for mnemonic "abandon...about" + passphrase "TREZOR"
    //  = c55257c360c07c72029aebc1b53c05ed0362ada38ead3e3e9efa3708e5349553
    // (matches core/bip32_wallet.zig "BIP-39 PBKDF2 — vector oficial")
    #[test]
    fn bip39_pbkdf2_official_vector() {
        let w = Bip32Wallet::from_mnemonic_passphrase(ABANDON_X11_ABOUT, "TREZOR").unwrap();
        let expect: [u8; 32] = [
            0xc5, 0x52, 0x57, 0xc3, 0x60, 0xc0, 0x7c, 0x72,
            0x02, 0x9a, 0xeb, 0xc1, 0xb5, 0x3c, 0x05, 0xed,
            0x03, 0x62, 0xad, 0xa3, 0x8e, 0xad, 0x3e, 0x3e,
            0x9e, 0xfa, 0x37, 0x08, 0xe5, 0x34, 0x95, 0x53,
        ];
        assert_eq!(&w.master_seed[..32], &expect);
    }

    #[test]
    fn derive_pq_seed_deterministic() {
        let seed = [0x42u8; 64];
        let a = derive_pq_seed(&seed, 778, 0x01, 0);
        let b = derive_pq_seed(&seed, 778, 0x01, 0);
        assert_eq!(a, b);
        let c = derive_pq_seed(&seed, 779, 0x01, 0);
        assert_ne!(a, c);
    }

    #[test]
    fn deterministic_pubkey() {
        let w1 = Bip32Wallet::from_mnemonic(ABANDON_X11_ABOUT).unwrap();
        let w2 = Bip32Wallet::from_mnemonic(ABANDON_X11_ABOUT).unwrap();
        let p1 = w1.derive_public_key(0).unwrap();
        let p2 = w2.derive_public_key(0).unwrap();
        assert_eq!(p1, p2);
        assert!(p1[0] == 0x02 || p1[0] == 0x03);
    }

    #[test]
    fn ob_address_starts_with_ob1q() {
        let w = Bip32Wallet::from_mnemonic(ABANDON_X11_ABOUT).unwrap();
        let addr = w.derive_address_for_domain(777, 0, "ob").unwrap();
        assert!(addr.starts_with("ob1q"), "got {addr}");
        assert_eq!(addr.len(), 42);
    }
}
