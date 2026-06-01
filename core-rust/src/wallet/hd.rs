// HD wallet — wraps crypto::bip32::Bip32Wallet with the canonical OmniBus
// derivation paths. Mirrors core/wallet.zig (DOMAINS array + EVM coin 60).
//
// Paths:
//   OMNI native:  m/44'/777'/0'/0/idx  -> ob1q... (bech32 v0)
//   LOVE:         m/44'/778'/0'/0/idx  -> ob_k1_... (Base58Check 0x4F + prefix)
//   FOOD:         m/44'/779'/0'/0/idx  -> ob_f5_...
//   RENT:         m/44'/780'/0'/0/idx  -> ob_d5_...
//   VACATION:     m/44'/781'/0'/0/idx  -> ob_s3_...
//   EVM:          m/44'/60'/0'/0/idx   -> 0x... (EIP-55)
//
// Vector cross-checked:
//   mnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon
//               abandon abandon abandon abandon about", passphrase=""
//   path m/44'/60'/0'/0/0 EVM address is the well-known
//   0x9858EfFD232B4033E47d90003D41EC34EcaEda94 (Trezor/MetaMask test vector).

use crate::crypto::{Bip32Wallet, secp256k1::{private_key_to_uncompressed, private_key_to_public_key}, ripemd160::hash160, bech32::encode_ob_address};
use super::address::{Address, AddressKind, evm_checksum_address};

pub const COIN_OMNI: u32 = 777;
pub const COIN_LOVE: u32 = 778;
pub const COIN_FOOD: u32 = 779;
pub const COIN_RENT: u32 = 780;
pub const COIN_VACATION: u32 = 781;
pub const COIN_EVM: u32 = 60;

pub struct PqDomain {
    pub name: &'static str,
    pub algorithm: &'static str,
    pub prefix: &'static str,
    pub coin_type: u32,
}

pub const PQ_DOMAINS: [PqDomain; 5] = [
    PqDomain { name: "omnibus.omni",     algorithm: "ML-DSA-87",    prefix: "ob",     coin_type: COIN_OMNI },
    PqDomain { name: "omnibus.love",     algorithm: "ML-DSA-87",    prefix: "ob_k1_", coin_type: COIN_LOVE },
    PqDomain { name: "omnibus.food",     algorithm: "Falcon-512",   prefix: "ob_f5_", coin_type: COIN_FOOD },
    PqDomain { name: "omnibus.rent",     algorithm: "Dilithium-5",  prefix: "ob_d5_", coin_type: COIN_RENT },
    PqDomain { name: "omnibus.vacation", algorithm: "SLH-DSA-256s", prefix: "ob_s3_", coin_type: COIN_VACATION },
];

pub struct HdWallet {
    pub bip32: Bip32Wallet,
}

impl HdWallet {
    pub fn from_mnemonic(mnemonic: &str) -> Result<Self, String> {
        let bip32 = Bip32Wallet::from_mnemonic(mnemonic).map_err(|e| e.to_string())?;
        Ok(Self { bip32 })
    }

    pub fn from_mnemonic_passphrase(mnemonic: &str, passphrase: &str) -> Result<Self, String> {
        let bip32 = Bip32Wallet::from_mnemonic_passphrase(mnemonic, passphrase).map_err(|e| e.to_string())?;
        Ok(Self { bip32 })
    }

    /// Derive private key at m/44'/coin_type'/0'/0/index.
    pub fn private_key(&self, coin_type: u32, index: u32) -> Result<[u8; 32], String> {
        self.bip32.derive_child_key_for_path(44, coin_type, index).map_err(|e| e.to_string())
    }

    /// Native OMNI address: m/44'/777'/0'/0/index -> ob1q...
    pub fn omni_address(&self, index: u32) -> Result<String, String> {
        let priv_key = self.private_key(COIN_OMNI, index)?;
        let pubkey = private_key_to_public_key(&priv_key)?;
        let h160 = hash160(&pubkey);
        Ok(encode_ob_address(&h160))
    }

    /// EVM address: m/44'/60'/0'/0/index -> 0x... (EIP-55).
    pub fn evm_address(&self, index: u32) -> Result<String, String> {
        let priv_key = self.private_key(COIN_EVM, index)?;
        let xy = private_key_to_uncompressed(&priv_key)?;
        Ok(evm_checksum_address(&xy))
    }

    /// Soulbound / PQ-prefixed address for one of the 5 domains.
    pub fn domain_address(&self, coin_type: u32, index: u32) -> Result<String, String> {
        let prefix = PQ_DOMAINS.iter().find(|d| d.coin_type == coin_type)
            .map(|d| d.prefix)
            .ok_or_else(|| format!("unknown coin_type {coin_type}"))?;
        self.bip32.derive_address_for_domain(coin_type, index, prefix).map_err(|e| e.to_string())
    }

    /// Derive the 5 OmniBus PQ-prefixed addresses (index 0) — convenience for UIs.
    pub fn derive_all_domain_addresses(&self) -> Result<[Address; 5], String> {
        let mut out: Vec<Address> = Vec::with_capacity(5);
        for d in PQ_DOMAINS.iter() {
            let repr = self.bip32.derive_address_for_domain(d.coin_type, 0, d.prefix).map_err(|e| e.to_string())?;
            let kind = if d.coin_type == COIN_OMNI { AddressKind::OmniNative } else { AddressKind::PqSoulbound };
            out.push(Address { kind, repr, coin_type: d.coin_type, index: 0 });
        }
        // Vec<Address> -> [Address; 5]
        let arr: [Address; 5] = out.try_into().map_err(|_| "domain count != 5".to_string())?;
        Ok(arr)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const ABANDON_X11_ABOUT: &str = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";

    // vector: mnemonic "abandon...about" passphrase "" path m/44'/60'/0'/0/0
    //   EVM address = 0x9858EfFD232B4033E47d90003D41EC34EcaEda94
    // (well-known Trezor/MetaMask BIP-44 ETH vector — confirms BIP-39 PBKDF2
    //  + BIP-32 derivation + EIP-55 checksum all line up with the Zig impl.)
    #[test]
    fn evm_address_matches_trezor_vector() {
        let w = HdWallet::from_mnemonic(ABANDON_X11_ABOUT).unwrap();
        let addr = w.evm_address(0).unwrap();
        assert_eq!(addr, "0x9858EfFD232B4033E47d90003D41EC34EcaEda94");
    }

    #[test]
    fn omni_address_is_ob1q_and_deterministic() {
        let w = HdWallet::from_mnemonic(ABANDON_X11_ABOUT).unwrap();
        let a1 = w.omni_address(0).unwrap();
        let a2 = w.omni_address(0).unwrap();
        assert_eq!(a1, a2);
        assert!(a1.starts_with("ob1q"), "got {a1}");
        assert_eq!(a1.len(), 42);
    }

    #[test]
    fn all_five_domains_correct_prefixes() {
        let w = HdWallet::from_mnemonic(ABANDON_X11_ABOUT).unwrap();
        let addrs = w.derive_all_domain_addresses().unwrap();
        assert!(addrs[0].repr.starts_with("ob1q"));
        assert!(addrs[1].repr.starts_with("ob_k1_"));
        assert!(addrs[2].repr.starts_with("ob_f5_"));
        assert!(addrs[3].repr.starts_with("ob_d5_"));
        assert!(addrs[4].repr.starts_with("ob_s3_"));
    }
}
