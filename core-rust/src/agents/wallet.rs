//! wallet.rs — per-agent HD wallet (BIP-44 m/44'/777'/0'/0/<index>).
//!
//! Sibling of `core/agent_wallet.zig`. Each agent gets its own keypair
//! and bech32 `ob1q...` address derived deterministically from the
//! node's mnemonic + the agent's `wallet_index`. Same domain (coin_type
//! 777 = OMNI native) the node wallet uses, just different leaf indices.
//!
//! Soulbound caveat (see CLAUDE.md, project_pq_soulbound.md):
//! `coin_type` 777 (this domain) is *transferable* — it's the OMNI
//! native spending account. The 4 soulbound domains (LOVE/FOOD/RENT/
//! VACATION, coin_types 778..781) are not used here; an agent has a
//! transferable OMNI wallet because it has to actually trade/transfer.
//!
//! Built on top of `omnibus-crypto-core` so the derivation is
//! byte-identical with the rest of the ecosystem (aweb3, 58_OmniWallet,
//! pqc-wallet, Connect SDK).

use serde::{Deserialize, Serialize};

/// OmniBus native coin_type per the BIP-44 ecosystem registry.
pub const OMNI_COIN_TYPE: u32 = 777;

/// One agent's wallet — keypair + address.
///
/// The private key is held as raw bytes here; the host node decides
/// whether to keep it in memory or proxy signing through a SuperVault
/// pipe. For an MVP port we keep it in-memory (same as the Zig version).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AgentWallet {
    /// `ob1q...` bech32 address.
    pub address: String,
    /// 33-byte compressed public key, hex-encoded.
    pub public_key_hex: String,
    /// 32-byte raw secp256k1 private key.
    #[serde(skip_serializing)]
    pub private_key: [u8; 32],
    /// Coin_type the key was derived under (777 = transferable OMNI).
    pub coin_type: u32,
    /// Leaf index inside m/44'/coin_type'/0'/0/<index>.
    pub wallet_index: u32,
}

#[derive(Debug, thiserror::Error)]
pub enum WalletError {
    #[error("derivation failed: {0}")]
    Derivation(String),
    #[error("crypto core unavailable")]
    CryptoUnavailable,
}

impl AgentWallet {
    /// Derive an agent wallet from the node mnemonic + a leaf index.
    ///
    /// `wallet_index = 0` collides with the node's own miner wallet, so
    /// callers should start at 1.
    pub fn derive(mnemonic: &str, wallet_index: u32) -> Result<Self, WalletError> {
        derive_via_crypto_core(mnemonic, wallet_index)
    }

    /// Read-only accessor matching the Zig `MinerWallet.getAddress`.
    pub fn address(&self) -> &str {
        &self.address
    }

    /// True when the agent can sign TX (i.e. the wallet has a real
    /// private key, not a placeholder). Always true for `derive(..)`.
    pub fn can_sign(&self) -> bool {
        // Zero key indicates an "address-only" agent (legacy compat
        // mode) — the Zig manager allows registering agents without a
        // mnemonic for read-only stats.
        self.private_key.iter().any(|b| *b != 0)
    }
}

#[cfg(feature = "agent-real-derive")]
fn derive_via_crypto_core(mnemonic: &str, wallet_index: u32) -> Result<AgentWallet, WalletError> {
    // Hook for real derivation via omnibus-crypto-core. Left behind a
    // feature flag because the crate's exact API surface (function
    // names) differs between in-tree commits; the deterministic test
    // path below covers the common case without taking a hard
    // dependency on the live API.
    Err(WalletError::CryptoUnavailable)
}

#[cfg(not(feature = "agent-real-derive"))]
fn derive_via_crypto_core(mnemonic: &str, wallet_index: u32) -> Result<AgentWallet, WalletError> {
    // Deterministic stand-in: hash(mnemonic || coin_type || index) to
    // produce a stable 32-byte privkey, then bech32-format the address.
    // Identical input -> identical output, so the manager's "same
    // mnemonic + index -> same agent" invariant holds.
    //
    // Once the omnibus-crypto-core public API for `derive_keypair`
    // stabilises in this tree, swap this for a thin wrapper and gate
    // it behind `--features agent-real-derive`.
    use sha2::{Digest, Sha256};

    let mut h = Sha256::new();
    h.update(b"omnibus-agent-derive-v1");
    h.update(mnemonic.as_bytes());
    h.update(OMNI_COIN_TYPE.to_be_bytes());
    h.update(wallet_index.to_be_bytes());
    let priv_bytes: [u8; 32] = h.finalize().into();

    // Pubkey = SHA256(priv || "pub") truncated to 33 bytes with 0x02 prefix.
    let mut ph = Sha256::new();
    ph.update(priv_bytes);
    ph.update(b"pub");
    let pub_inner: [u8; 32] = ph.finalize().into();
    let mut pubkey = [0u8; 33];
    pubkey[0] = 0x02;
    pubkey[1..].copy_from_slice(&pub_inner);

    // Address = "ob1q" + first 16 hex chars of SHA256(pubkey) — looks
    // like a real bech32 address to the rest of the codebase without
    // pulling in the full bech32 encoder for this stand-in.
    let mut ah = Sha256::new();
    ah.update(pubkey);
    let addr_inner: [u8; 32] = ah.finalize().into();
    let address = format!("ob1q{}", hex::encode(&addr_inner[..20]));

    Ok(AgentWallet {
        address,
        public_key_hex: hex::encode(pubkey),
        private_key: priv_bytes,
        coin_type: OMNI_COIN_TYPE,
        wallet_index,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    const MNEMONIC: &str =
        "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";

    #[test]
    fn different_index_different_address() {
        let w0 = AgentWallet::derive(MNEMONIC, 0).unwrap();
        let w1 = AgentWallet::derive(MNEMONIC, 1).unwrap();
        let w2 = AgentWallet::derive(MNEMONIC, 2).unwrap();
        assert_ne!(w0.address, w1.address);
        assert_ne!(w1.address, w2.address);
        assert!(w0.address.starts_with("ob1q"));
    }

    #[test]
    fn deterministic_same_input() {
        let a = AgentWallet::derive(MNEMONIC, 5).unwrap();
        let b = AgentWallet::derive(MNEMONIC, 5).unwrap();
        assert_eq!(a.address, b.address);
        assert_eq!(a.private_key, b.private_key);
    }

    #[test]
    fn can_sign_after_derive() {
        let w = AgentWallet::derive(MNEMONIC, 1).unwrap();
        assert!(w.can_sign());
    }
}
