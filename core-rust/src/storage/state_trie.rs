//! State trie — port of `core/state_trie.zig`.
//!
//! Account state keyed by 20-byte compressed address. Account hash is SHA-256
//! over `address || "{balance}:{nonce}:{last_updated_block}"` (decimal ASCII),
//! mirroring the Zig version exactly (`std.fmt.bufPrint("{d}:{d}:{d}", ...)`).
//! Root hash is the sequential SHA-256 fold over per-account hashes in address
//! lexicographic order.

use sha2::{Digest, Sha256};
use std::collections::HashMap;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct AccountState {
    pub address: [u8; 20],
    pub balance: u64,
    pub nonce: u32,
    pub last_updated_block: u32,
    pub flags: u8,
}

impl AccountState {
    pub fn new(address: [u8; 20]) -> Self {
        Self { address, balance: 0, nonce: 0, last_updated_block: 0, flags: 0 }
    }

    /// SHA-256(address || ascii_decimal("balance:nonce:last_updated_block"))
    /// Matches Zig `AccountState.hash`.
    pub fn hash(&self) -> [u8; 32] {
        let mut h = Sha256::new();
        h.update(self.address);
        let s = format!("{}:{}:{}", self.balance, self.nonce, self.last_updated_block);
        h.update(s.as_bytes());
        let out = h.finalize();
        let mut r = [0u8; 32];
        r.copy_from_slice(&out);
        r
    }
}

#[derive(Debug, Default)]
pub struct StateTrie {
    pub accounts: HashMap<[u8; 20], AccountState>,
    pub root_hash: [u8; 32],
    pub block_height: u32,
}

impl StateTrie {
    pub fn new() -> Self { Self::default() }

    pub fn update_balance(&mut self, address: [u8; 20], new_balance: u64, block_height: u32) {
        let acc = self.accounts.entry(address).or_insert_with(|| AccountState::new(address));
        acc.balance = new_balance;
        acc.last_updated_block = block_height;
    }

    pub fn increment_nonce(&mut self, address: [u8; 20], block_height: u32) {
        let acc = self.accounts.entry(address).or_insert_with(|| AccountState::new(address));
        acc.nonce += 1;
        acc.last_updated_block = block_height;
    }

    pub fn get(&self, address: &[u8; 20]) -> Option<&AccountState> {
        self.accounts.get(address)
    }

    pub fn get_balance(&self, address: &[u8; 20]) -> u64 {
        self.accounts.get(address).map_or(0, |a| a.balance)
    }

    /// Recompute the root hash: sort accounts by address, then sequentially
    /// SHA-256 the running state with each account's hash.
    pub fn recompute_root(&mut self) -> [u8; 32] {
        let mut addrs: Vec<&[u8; 20]> = self.accounts.keys().collect();
        addrs.sort();
        let mut acc = [0u8; 32];
        for a in addrs {
            let mut h = Sha256::new();
            h.update(acc);
            h.update(self.accounts[a].hash());
            let out = h.finalize();
            acc.copy_from_slice(&out);
        }
        self.root_hash = acc;
        acc
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn account_hash_stable() {
        let acc = AccountState {
            address: [1u8; 20],
            balance: 1000,
            nonce: 5,
            last_updated_block: 42,
            flags: 0,
        };
        // Hash should be deterministic — same inputs → same output across runs.
        let h1 = acc.hash();
        let h2 = acc.hash();
        assert_eq!(h1, h2);
    }

    #[test]
    fn balance_update_and_nonce() {
        let mut t = StateTrie::new();
        t.update_balance([7u8; 20], 500, 10);
        assert_eq!(t.get_balance(&[7u8; 20]), 500);
        t.increment_nonce([7u8; 20], 11);
        assert_eq!(t.get(&[7u8; 20]).unwrap().nonce, 1);
        let r = t.recompute_root();
        assert_ne!(r, [0u8; 32]);
    }
}
