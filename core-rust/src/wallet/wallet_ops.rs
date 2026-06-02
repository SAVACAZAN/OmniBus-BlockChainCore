//! wallet_ops.rs — High-level OmniBus wallet: balance, TX building, address management.
//!
//! Port of `core/wallet.zig` (951 LoC, 2026-06-02).
//!
//! This file is named `wallet_ops` to avoid a name collision with the `wallet`
//! module directory.
//!
//! Key exports:
//!   `WalletAccount`           — HD wallet + 5 PQ domains + balance
//!   `build_transfer_tx`       — plain UTXO transfer
//!   `build_op_return_tx`      — OP_RETURN metadata TX
//!   `build_ns_register_tx`    — name service registration (op_return "ns:name")
//!   `build_stake_tx`          — stake (op_return "stake:amount")
//!   `build_agent_register_tx` — agent registration (op_return "agent:register:id")
//!   `get_balance`             — sum UTXOs for an address
//!   `get_staked`              — look up staked amount for an address (stub)

use std::time::{SystemTime, UNIX_EPOCH};

use crate::wallet::transaction::Transaction;
use crate::wallet::utxo::UtxoSet;

// ── WalletDomain ──────────────────────────────────────────────────────────────

/// One of the 5 BIP-44 derivation domains in OmniBus.
///
/// Mirrors the `Address` inner struct of `wallet.zig`.
#[derive(Debug, Clone)]
pub struct WalletDomain {
    /// Logical name, e.g. `"omnibus.omni"`.
    pub domain: &'static str,
    /// Algorithm label, e.g. `"ML-DSA-87"`.
    pub algorithm: &'static str,
    /// Derived address for this domain.
    pub address: String,
    /// Compressed secp256k1 public key (hex, 66 chars).
    pub public_key_hex: String,
    /// BIP-44 coin type.
    pub coin_type: u32,
    /// Security level in bits.
    pub security_level: u32,
}

// ── WalletAccount ─────────────────────────────────────────────────────────────

/// HD wallet covering 5 OmniBus PQ domains.
///
/// Mirrors the top-level `Wallet` struct in `core/wallet.zig`.
#[derive(Debug, Clone)]
pub struct WalletAccount {
    /// Primary OMNI address (ob1q…, coin_type 777).
    pub address: String,
    /// Compressed secp256k1 private key (32 bytes) — OMNI primary.
    /// Stored only while the wallet is live; zeroised on `drop`.
    private_key: [u8; 32],
    /// Compressed secp256k1 public key (33 bytes) — OMNI primary.
    pub public_key: [u8; 33],
    /// Public key hex (66 chars) — OMNI primary.
    pub public_key_hex: String,
    /// 5 derivation domains (OMNI + LOVE + FOOD + RENT + VACATION).
    pub domains: Vec<WalletDomain>,
    /// Current balance in SAT (kept in sync by node RPC fetch).
    pub balance: u64,
    /// Transaction count.
    pub tx_count: u64,
    /// BIP-44 derivation path used for the primary OMNI key.
    pub derivation_path: String,
    /// Human-readable label.
    pub label: String,
    /// Creation timestamp (unix seconds).
    pub created_at: i64,
}

impl Drop for WalletAccount {
    /// Zero private key material on drop (security hygiene).
    fn drop(&mut self) {
        self.private_key.fill(0);
    }
}

impl WalletAccount {
    // ── Constructors ─────────────────────────────────────────────────────────

    /// Construct a `WalletAccount` from a BIP-39 mnemonic (no passphrase).
    /// Address index 0, account 0, external chain (BIP-44 standard).
    pub fn from_mnemonic(mnemonic: &str) -> Result<Self, String> {
        Self::from_mnemonic_full(mnemonic, "", 0)
    }

    /// Full constructor with explicit address index.
    pub fn from_mnemonic_full(
        mnemonic: &str,
        passphrase: &str,
        address_index: u32,
    ) -> Result<Self, String> {
        use crate::wallet::hd::{HdWallet, PQ_DOMAINS, COIN_VACATION};
        use omnibus_crypto::primitives::curves::secp256k1_wrapper::private_to_public;

        let hd = if passphrase.is_empty() {
            HdWallet::from_mnemonic(mnemonic)?
        } else {
            HdWallet::from_mnemonic_passphrase(mnemonic, passphrase)?
        };

        // OMNI primary key (coin_type 777)
        let privkey = hd.private_key(777, address_index)?;
        let pubkey = private_to_public(&privkey).map_err(|e| format!("{:?}", e))?;
        let pk_hex = hex::encode(pubkey);

        // Primary address: ob1q… bech32
        let primary_addr = hd.omni_address(address_index)?;

        // 5 base PQ domain addresses (exclude EDU/GOV soulbound domains)
        let mut domains = Vec::with_capacity(5);
        for d in PQ_DOMAINS.iter().filter(|d| d.coin_type <= COIN_VACATION) {
            let pk_i = hd.private_key(d.coin_type, address_index)?;
            let pub_i = private_to_public(&pk_i).map_err(|e| format!("{:?}", e))?;
            let pub_hex_i = hex::encode(pub_i);
            let addr_i = if d.coin_type == 777 {
                hd.omni_address(address_index)?
            } else {
                hd.domain_address(d.coin_type, address_index)?
            };
            domains.push(WalletDomain {
                domain: d.name,
                algorithm: d.algorithm,
                address: addr_i,
                public_key_hex: pub_hex_i,
                coin_type: d.coin_type,
                security_level: match d.coin_type {
                    777 | 778 | 780 => 256,
                    779 => 192,
                    781 => 128,
                    _ => 256,
                },
            });
        }

        let deriv_path = format!("m/44'/777'/0'/0/{}", address_index);

        Ok(Self {
            address: primary_addr,
            private_key: privkey,
            public_key: pubkey,
            public_key_hex: pk_hex,
            domains,
            balance: 0,
            tx_count: 0,
            derivation_path: deriv_path,
            label: String::new(),
            created_at: unix_now(),
        })
    }

    // ── Balance helpers ───────────────────────────────────────────────────────

    pub fn get_balance(&self) -> u64 {
        self.balance
    }

    /// Balance in OMNI (1 OMNI = 1_000_000_000 SAT).
    pub fn get_balance_omni(&self) -> f64 {
        self.balance as f64 / 1_000_000_000.0
    }

    pub fn can_send(&self, amount_sat: u64) -> bool {
        self.balance >= amount_sat
    }

    pub fn update_balance(&mut self, new_balance_sat: u64) {
        self.balance = new_balance_sat;
    }

    // ── Transaction builders ──────────────────────────────────────────────────

    /// Build and sign a plain UTXO transfer to `to_address`.
    pub fn build_transfer_tx(
        &self,
        to_address: &str,
        amount_sat: u64,
        fee_sat: u64,
        tx_id: u32,
        nonce: u64,
    ) -> Result<Transaction, String> {
        let mut tx = Transaction {
            id: tx_id,
            from_address: self.address.clone(),
            to_address: to_address.to_string(),
            amount: amount_sat,
            fee: fee_sat,
            timestamp: unix_now(),
            nonce,
            ..Default::default()
        };
        tx.sign(&self.private_key)?;
        Ok(tx)
    }

    /// Build and sign an OP_RETURN metadata transaction (amount = 0).
    pub fn build_op_return_tx(
        &self,
        op_return_data: &str,
        fee_sat: u64,
        tx_id: u32,
        nonce: u64,
    ) -> Result<Transaction, String> {
        let mut tx = Transaction {
            id: tx_id,
            from_address: self.address.clone(),
            to_address: self.address.clone(),
            amount: 0,
            fee: fee_sat,
            timestamp: unix_now(),
            nonce,
            op_return: op_return_data.to_string(),
            ..Default::default()
        };
        tx.sign(&self.private_key)?;
        Ok(tx)
    }

    /// Build and sign a name service registration transaction.
    /// `op_return = "ns:{name}"`
    pub fn build_ns_register_tx(
        &self,
        name: &str,
        fee_sat: u64,
        tx_id: u32,
        nonce: u64,
    ) -> Result<Transaction, String> {
        let op = format!("ns:{}", name);
        self.build_op_return_tx(&op, fee_sat, tx_id, nonce)
    }

    /// Build and sign a staking transaction.
    /// `op_return = "stake:{amount_sat}"`
    pub fn build_stake_tx(
        &self,
        amount_sat: u64,
        fee_sat: u64,
        tx_id: u32,
        nonce: u64,
    ) -> Result<Transaction, String> {
        let op = format!("stake:{}", amount_sat);
        self.build_op_return_tx(&op, fee_sat, tx_id, nonce)
    }

    /// Build and sign an agent registration transaction.
    /// `op_return = "agent:register:{agent_id}"`
    pub fn build_agent_register_tx(
        &self,
        agent_id: &str,
        fee_sat: u64,
        tx_id: u32,
        nonce: u64,
    ) -> Result<Transaction, String> {
        let op = format!("agent:register:{}", agent_id);
        self.build_op_return_tx(&op, fee_sat, tx_id, nonce)
    }

    /// Build and sign a full transaction with explicit locktime + op_return.
    pub fn build_full_tx(
        &self,
        to_address: &str,
        amount_sat: u64,
        fee_sat: u64,
        tx_id: u32,
        nonce: u64,
        locktime: u64,
        op_return: &str,
    ) -> Result<Transaction, String> {
        let mut tx = Transaction {
            id: tx_id,
            from_address: self.address.clone(),
            to_address: to_address.to_string(),
            amount: amount_sat,
            fee: fee_sat,
            timestamp: unix_now(),
            nonce,
            locktime,
            op_return: op_return.to_string(),
            ..Default::default()
        };
        tx.sign(&self.private_key)?;
        Ok(tx)
    }
}

// ── Standalone helpers ────────────────────────────────────────────────────────

/// Get the UTXO-based balance for `address` from the provided `UtxoSet`.
///
/// Mirrors `Wallet.getBalance` in `wallet.zig` but operates on an external set.
pub fn get_balance(address: &str, utxo_set: &UtxoSet) -> u64 {
    utxo_set.balance(address)
}

/// Get the staked amount for `address`.
///
/// Stub implementation: returns 0. Full implementation requires scanning
/// `stake:` op_return transactions in chain state — handled at the node layer.
/// This placeholder maintains the same function signature as the Zig equivalent.
pub fn get_staked(_address: &str) -> u64 {
    0
}

// ── Internal helpers ──────────────────────────────────────────────────────────

fn unix_now() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs() as i64
}

// ── Tests ─────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use crate::wallet::utxo::UtxoSet;

    const MNEMONIC: &str =
        "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";

    // ── WalletAccount construction ────────────────────────────────────────────

    #[test]
    fn from_mnemonic_produces_ob1q_address() {
        let w = WalletAccount::from_mnemonic(MNEMONIC).expect("from_mnemonic");
        assert!(w.address.starts_with("ob1q"), "primary addr must be ob1q bech32");
        assert_eq!(w.address.len(), 42, "ob1q bech32 is 42 chars");
    }

    #[test]
    fn deterministic_same_mnemonic_same_address() {
        let w1 = WalletAccount::from_mnemonic(MNEMONIC).unwrap();
        let w2 = WalletAccount::from_mnemonic(MNEMONIC).unwrap();
        assert_eq!(w1.address, w2.address);
        assert_eq!(w1.public_key, w2.public_key);
    }

    #[test]
    fn different_mnemonics_different_addresses() {
        let w1 = WalletAccount::from_mnemonic(MNEMONIC).unwrap();
        let w2 = WalletAccount::from_mnemonic(
            "zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo wrong",
        )
        .unwrap();
        assert_ne!(w1.address, w2.address);
    }

    #[test]
    fn five_domains_derived() {
        let w = WalletAccount::from_mnemonic(MNEMONIC).unwrap();
        assert_eq!(w.domains.len(), 5);
        assert!(w.domains[0].address.starts_with("ob1q"),   "domain 0 = OMNI bech32");
        assert!(w.domains[1].address.starts_with("ob_k1_"), "domain 1 = LOVE");
        assert!(w.domains[2].address.starts_with("ob_f5_"), "domain 2 = FOOD");
        assert!(w.domains[3].address.starts_with("ob_d5_"), "domain 3 = RENT");
        assert!(w.domains[4].address.starts_with("ob_s3_"), "domain 4 = VACATION");
    }

    #[test]
    fn derivation_path_correct() {
        let w = WalletAccount::from_mnemonic(MNEMONIC).unwrap();
        assert_eq!(w.derivation_path, "m/44'/777'/0'/0/0");
    }

    // ── Balance helpers ───────────────────────────────────────────────────────

    #[test]
    fn balance_initially_zero() {
        let w = WalletAccount::from_mnemonic(MNEMONIC).unwrap();
        assert_eq!(w.get_balance(), 0);
        assert!(!w.can_send(1));
    }

    #[test]
    fn update_balance_and_can_send() {
        let mut w = WalletAccount::from_mnemonic(MNEMONIC).unwrap();
        w.update_balance(50_000_000_000); // 50 OMNI
        assert!(w.can_send(1_000_000_000));
        assert!(!w.can_send(60_000_000_000));
        let omni = w.get_balance_omni();
        assert!((omni - 50.0).abs() < f64::EPSILON);
    }

    // ── TX builders ───────────────────────────────────────────────────────────

    #[test]
    fn build_transfer_tx_signed() {
        let w = WalletAccount::from_mnemonic(MNEMONIC).unwrap();
        let tx = w
            .build_transfer_tx(
                "ob1q0l4glravfx9qt5j0uqqectjl0q3kjlnwlt22gt",
                1_000_000_000,
                1_000,
                1,
                0,
            )
            .expect("transfer tx");
        assert_eq!(tx.signature.len(), 128, "64B sig = 128 hex chars");
        assert_eq!(tx.hash.len(), 64);
        assert_eq!(tx.from_address, w.address);
        assert_eq!(tx.amount, 1_000_000_000);
        assert_eq!(tx.fee, 1_000);
        assert!(tx.op_return.is_empty());
    }

    #[test]
    fn build_op_return_tx_structure() {
        let w = WalletAccount::from_mnemonic(MNEMONIC).unwrap();
        let tx = w
            .build_op_return_tx("hello blockchain", 500, 2, 1)
            .expect("op_return tx");
        assert_eq!(tx.amount, 0, "op_return TXs carry zero value");
        assert_eq!(tx.op_return, "hello blockchain");
        assert_eq!(tx.signature.len(), 128);
    }

    #[test]
    fn build_ns_register_tx_op_return() {
        let w = WalletAccount::from_mnemonic(MNEMONIC).unwrap();
        let tx = w.build_ns_register_tx("myname", 1_000, 3, 2).expect("ns tx");
        assert_eq!(tx.op_return, "ns:myname");
    }

    #[test]
    fn build_stake_tx_op_return() {
        let w = WalletAccount::from_mnemonic(MNEMONIC).unwrap();
        let tx = w.build_stake_tx(10_000_000_000, 1_000, 4, 3).expect("stake tx");
        assert_eq!(tx.op_return, "stake:10000000000");
    }

    #[test]
    fn build_agent_register_tx_op_return() {
        let w = WalletAccount::from_mnemonic(MNEMONIC).unwrap();
        let tx = w.build_agent_register_tx("agent-42", 1_000, 5, 4).expect("agent tx");
        assert_eq!(tx.op_return, "agent:register:agent-42");
    }

    // ── get_balance via UtxoSet ───────────────────────────────────────────────

    #[test]
    fn get_balance_from_utxo_set() {
        let addr = "ob1qx787af2p22knzjlakn7ehz9r77p3ak2w8zkk2s";
        let utxo_set = UtxoSet::new();
        utxo_set.add(
            &"aa".repeat(32),
            0,
            addr,
            5_000_000_000,
            1,
            "",
            false,
        );
        utxo_set.add(
            &"bb".repeat(32),
            0,
            addr,
            3_000_000_000,
            2,
            "",
            false,
        );

        assert_eq!(get_balance(addr, &utxo_set), 8_000_000_000);
        assert_eq!(get_balance("nonexistent", &utxo_set), 0);
    }

    // ── get_staked stub ───────────────────────────────────────────────────────

    #[test]
    fn get_staked_returns_zero() {
        assert_eq!(get_staked("ob1qany_address"), 0);
    }
}
