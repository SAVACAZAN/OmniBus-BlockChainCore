// revm::Database adapter over the sled-backed EvmState.
//
// Two flavors:
//   * `EvmStateDb<'a>`   — read+commit, used by execute_tx (real txs).
//   * `EvmStateDbRef<'a>` — read-only via DatabaseRef, used by execute_call.
//
// Address/U256/B256 conversions are done at this boundary so the rest of the
// codebase keeps its plain `[u8;20]` / `[u8;32]` / `u128` types.

use std::convert::Infallible;

use revm::primitives::{
    keccak256, AccountInfo, Address, Bytecode, Bytes, HashMap, B256, KECCAK_EMPTY, U256,
};
use revm::{Database, DatabaseCommit, DatabaseRef};

use crate::state::{Account, EvmState};

// ---- helpers ----

#[inline]
pub fn addr20_from(a: Address) -> [u8; 20] {
    a.into_array()
}

#[inline]
pub fn addr_to(a: [u8; 20]) -> Address {
    Address::from(a)
}

#[inline]
pub fn u256_be(u: U256) -> [u8; 32] {
    u.to_be_bytes::<32>()
}

#[inline]
pub fn u256_from_be(b: [u8; 32]) -> U256 {
    U256::from_be_bytes(b)
}

fn u128_saturating_from_u256(u: U256) -> u128 {
    let bytes = u.to_be_bytes::<32>();
    if bytes[..16].iter().any(|b| *b != 0) {
        u128::MAX
    } else {
        let mut p = [0u8; 16]; p.copy_from_slice(&bytes[16..]); u128::from_be_bytes(p)
    }
}

fn load_account_info(state: &EvmState, addr: [u8; 20]) -> AccountInfo {
    let code = state.code(&addr);
    let (code_hash, code_field) = if code.is_empty() {
        (KECCAK_EMPTY, None)
    } else {
        let h = keccak256(&code);
        // make sure the by-hash tree has it so revm can `code_by_hash` later
        let _ = state.write_code_by_hash(&h.0, &code);
        (h, Some(Bytecode::new_raw(Bytes::from(code))))
    };
    AccountInfo {
        balance: U256::from(state.balance(&addr)),
        nonce: state.nonce(&addr),
        code_hash,
        code: code_field,
    }
}

// ---- &mut Database adapter (for execute_tx) ----

pub struct EvmStateDb<'a> {
    pub state: &'a EvmState,
}

impl<'a> EvmStateDb<'a> {
    pub fn new(state: &'a EvmState) -> Self { Self { state } }
}

impl<'a> Database for EvmStateDb<'a> {
    type Error = Infallible;

    fn basic(&mut self, address: Address) -> Result<Option<AccountInfo>, Self::Error> {
        let a = addr20_from(address);
        // Always return Some so revm can treat unknown accounts as empty (matches
        // mainnet behaviour where any address can hold balance).
        Ok(Some(load_account_info(self.state, a)))
    }

    fn code_by_hash(&mut self, code_hash: B256) -> Result<Bytecode, Self::Error> {
        if code_hash == KECCAK_EMPTY {
            return Ok(Bytecode::new());
        }
        match self.state.read_code_by_hash(&code_hash.0) {
            Some(code) => Ok(Bytecode::new_raw(Bytes::from(code))),
            None       => Ok(Bytecode::new()),
        }
    }

    fn storage(&mut self, address: Address, index: U256) -> Result<U256, Self::Error> {
        let a = addr20_from(address);
        let slot = u256_be(index);
        let v = self.state.read_storage_slot(&a, &slot);
        Ok(u256_from_be(v))
    }

    fn block_hash(&mut self, number: u64) -> Result<B256, Self::Error> {
        // Stub: deterministic placeholder until full chain header storage lands.
        Ok(keccak256(format!("block-{}", number).as_bytes()))
    }
}

impl<'a> DatabaseCommit for EvmStateDb<'a> {
    fn commit(&mut self, changes: HashMap<Address, revm::primitives::Account>) {
        for (addr, acc) in changes.into_iter() {
            if !acc.is_touched() { continue; }
            let a = addr20_from(addr);

            if acc.is_selfdestructed() {
                // Wipe account fully.
                let _ = self.state.set_account(&a, &Account::default());
                // (We leave evm_storage entries; gas refunds + future audits
                // can deal with cleanup. EIP-6780 makes selfdestruct rare.)
                continue;
            }

            // Persist code if changed.
            let mut code_bytes: Vec<u8> = Vec::new();
            if let Some(code) = acc.info.code.as_ref() {
                if !code.is_empty() {
                    let raw = code.original_bytes();
                    code_bytes = raw.to_vec();
                    let _ = self.state.write_code_by_hash(&acc.info.code_hash.0, &code_bytes);
                }
            } else if acc.info.code_hash != KECCAK_EMPTY {
                // Code already known by hash (revm cleared the cached copy);
                // fetch back from sled so the account row keeps its inline code.
                if let Some(c) = self.state.read_code_by_hash(&acc.info.code_hash.0) {
                    code_bytes = c;
                }
            }

            let new_acc = Account {
                balance: u128_saturating_from_u256(acc.info.balance),
                nonce: acc.info.nonce,
                code: code_bytes,
            };
            let _ = self.state.set_account(&a, &new_acc);

            // Persist storage diff.
            for (slot, slot_val) in acc.storage.iter() {
                if !slot_val.is_changed() { continue; }
                let slot_be = u256_be(*slot);
                let val_be = u256_be(slot_val.present_value);
                let _ = self.state.write_storage_slot(&a, &slot_be, &val_be);
            }
        }
        let _ = self.state.db.flush();
    }
}

// ---- DatabaseRef adapter (for execute_call) ----

pub struct EvmStateDbRef<'a> {
    pub state: &'a EvmState,
}

impl<'a> EvmStateDbRef<'a> {
    pub fn new(state: &'a EvmState) -> Self { Self { state } }
}

impl<'a> DatabaseRef for EvmStateDbRef<'a> {
    type Error = Infallible;

    fn basic_ref(&self, address: Address) -> Result<Option<AccountInfo>, Self::Error> {
        Ok(Some(load_account_info(self.state, addr20_from(address))))
    }

    fn code_by_hash_ref(&self, code_hash: B256) -> Result<Bytecode, Self::Error> {
        if code_hash == KECCAK_EMPTY {
            return Ok(Bytecode::new());
        }
        match self.state.read_code_by_hash(&code_hash.0) {
            Some(code) => Ok(Bytecode::new_raw(Bytes::from(code))),
            None       => Ok(Bytecode::new()),
        }
    }

    fn storage_ref(&self, address: Address, index: U256) -> Result<U256, Self::Error> {
        let a = addr20_from(address);
        let slot = u256_be(index);
        let v = self.state.read_storage_slot(&a, &slot);
        Ok(u256_from_be(v))
    }

    fn block_hash_ref(&self, number: u64) -> Result<B256, Self::Error> {
        Ok(keccak256(format!("block-{}", number).as_bytes()))
    }
}
