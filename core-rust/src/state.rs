// Persistent state backed by sled (embedded KV store, pure Rust). Trees:
//   accounts   : addr20 → {balance, nonce, code}
//   meta       : "chain_id" | "block_number" | "block_hash"
//   txs        : tx_hash → {block, from, nonce, to, value, data}
//   receipts   : tx_hash → {block, gas_used, status, contract_addr}
//   blocks     : block_number(BE) → concatenated tx_hashes
//
// Data path: $OMNIBUS_EVM_STATE_DIR or ./data/evm-state. Survives restarts.
//
// Phase 2 plan: swap sled for an LMDB adapter shared with BlockChainCore
// native storage so OMNI balance is one unified ledger across both VMs.

use std::path::Path;
use sled::{Db, Tree};
use crate::tx::TxParsed;

pub type Address20 = [u8; 20];

#[derive(Default, Debug, Clone)]
pub struct Account {
    pub balance: u128,
    pub nonce: u64,
    pub code: Vec<u8>,
}

pub struct EvmState {
    pub db: Db,
    pub accounts: Tree,
    pub meta: Tree,
    pub txs: Tree,
    pub receipts: Tree,
    pub blocks: Tree,
    /// Contract storage: key = addr20 || slot_be (52 bytes) → value (32 bytes U256 BE).
    pub evm_storage: Tree,
    /// Contract code: key = keccak256(code) (32B) → raw bytecode.
    pub evm_code: Tree,
    /// Event logs: key = tx_hash (32B) → encoded Vec<Log> (see evm/logs.rs).
    pub evm_logs: Tree,
}

impl EvmState {
    pub fn open() -> anyhow::Result<Self> {
        let path = std::env::var("OMNIBUS_EVM_STATE_DIR")
            .unwrap_or_else(|_| "./data/evm-state".to_string());
        Self::open_at(&path)
    }

    pub fn open_at<P: AsRef<Path>>(path: P) -> anyhow::Result<Self> {
        let db = sled::open(&path)?;
        let accounts = db.open_tree(b"accounts")?;
        let meta = db.open_tree(b"meta")?;
        let txs = db.open_tree(b"txs")?;
        let receipts = db.open_tree(b"receipts")?;
        let blocks = db.open_tree(b"blocks")?;
        let evm_storage = db.open_tree(b"evm_storage")?;
        let evm_code = db.open_tree(b"evm_code")?;
        let evm_logs = db.open_tree(b"evm_logs")?;

        if meta.get(b"chain_id")?.is_none() {
            meta.insert(b"chain_id", &7771u64.to_be_bytes())?;
            meta.insert(b"block_number", &0u64.to_be_bytes())?;
            meta.insert(b"block_hash", &[0u8; 32])?;

            // Dev faucet: pre-fund slot 2 and slot 6 each with 1000 OMNI.
            // Disable with env OMNIBUS_FAUCET_OFF=1.
            if std::env::var("OMNIBUS_FAUCET_OFF").is_err() {
                let one_thousand_omni: u128 = 1_000u128 * 10u128.pow(18);
                for addr_hex in [
                    "A66235662c363e9915b6353f79df309F67D146A6", // slot 2 (operator)
                    "c5A63d78B451768Ba1dc799Fb08Ad41c6b37C938", // slot 6 (deployer)
                ] {
                    let mut addr = [0u8; 20];
                    let raw = hex::decode(addr_hex).unwrap();
                    addr.copy_from_slice(&raw);
                    let acc = Account { balance: one_thousand_omni, nonce: 0, code: vec![] };
                    accounts.insert(addr, encode_account(&acc))?;
                }
                tracing::info!("faucet: pre-funded slots 2 + 6 with 1000 OMNI each");
            }

            db.flush()?;
            tracing::info!(path = %path.as_ref().display(), "EVM state initialized — genesis written");
        } else {
            tracing::info!(path = %path.as_ref().display(), "EVM state opened — existing data preserved");
        }

        Ok(Self { db, accounts, meta, txs, receipts, blocks, evm_storage, evm_code, evm_logs })
    }

    pub fn chain_id(&self) -> u64 {
        self.meta.get(b"chain_id").ok().flatten()
            .and_then(|v| v.as_ref().try_into().ok().map(u64::from_be_bytes))
            .unwrap_or(7771)
    }

    pub fn block_number(&self) -> u64 {
        self.meta.get(b"block_number").ok().flatten()
            .and_then(|v| v.as_ref().try_into().ok().map(u64::from_be_bytes))
            .unwrap_or(0)
    }

    pub fn balance(&self, addr: &Address20) -> u128 {
        match self.accounts.get(addr).ok().flatten() {
            Some(bytes) => decode_account(&bytes).balance,
            None => 0,
        }
    }

    pub fn nonce(&self, addr: &Address20) -> u64 {
        match self.accounts.get(addr).ok().flatten() {
            Some(bytes) => decode_account(&bytes).nonce,
            None => 0,
        }
    }

    pub fn code(&self, addr: &Address20) -> Vec<u8> {
        match self.accounts.get(addr).ok().flatten() {
            Some(bytes) => decode_account(&bytes).code,
            None => Vec::new(),
        }
    }

    pub fn set_account(&self, addr: &Address20, acc: &Account) -> anyhow::Result<()> {
        self.accounts.insert(addr, encode_account(acc))?;
        Ok(())
    }

    pub fn bump_block(&self) -> Result<u64, String> {
        let prev = self.block_number();
        let new = prev + 1;
        self.meta.insert(b"block_number", &new.to_be_bytes())
            .map_err(|e| format!("bump_block: {e}"))?;
        Ok(new)
    }

    pub fn write_tx(&self, hash: &[u8; 32], tx: &TxParsed, block: u64) -> Result<(), String> {
        let mut out = Vec::with_capacity(80 + tx.data.len());
        out.extend_from_slice(&block.to_be_bytes());
        out.extend_from_slice(&tx.from);
        out.extend_from_slice(&tx.nonce.to_be_bytes());
        match tx.to {
            Some(a) => { out.push(1); out.extend_from_slice(&a); }
            None    => { out.push(0); out.extend_from_slice(&[0u8; 20]); }
        };
        out.extend_from_slice(&tx.value.to_be_bytes());
        out.extend_from_slice(&(tx.data.len() as u32).to_be_bytes());
        out.extend_from_slice(&tx.data);
        self.txs.insert(hash, out).map_err(|e| format!("write_tx: {e}"))?;
        let key = block.to_be_bytes();
        let mut block_txs = self.blocks.get(key).ok().flatten()
            .map(|v| v.to_vec()).unwrap_or_default();
        block_txs.extend_from_slice(hash);
        self.blocks.insert(key, block_txs).map_err(|e| format!("blocks: {e}"))?;
        Ok(())
    }

    pub fn write_receipt(&self, hash: &[u8; 32], block: u64, gas_used: u64, status: u8, contract: Option<[u8; 20]>) -> Result<(), String> {
        let mut out = Vec::with_capacity(38);
        out.extend_from_slice(&block.to_be_bytes());
        out.extend_from_slice(&gas_used.to_be_bytes());
        out.push(status);
        match contract {
            Some(a) => { out.push(1); out.extend_from_slice(&a); }
            None    => { out.push(0); out.extend_from_slice(&[0u8; 20]); }
        };
        self.receipts.insert(hash, out).map_err(|e| format!("write_receipt: {e}"))?;
        self.db.flush().map_err(|e| format!("flush: {e}"))?;
        Ok(())
    }

    pub fn read_tx(&self, hash: &[u8; 32]) -> Option<TxRecord> {
        let bytes = self.txs.get(hash).ok().flatten()?;
        if bytes.len() < 77 { return None; }
        let block = u64::from_be_bytes(bytes[0..8].try_into().ok()?);
        let mut from = [0u8; 20]; from.copy_from_slice(&bytes[8..28]);
        let nonce = u64::from_be_bytes(bytes[28..36].try_into().ok()?);
        let to_present = bytes[36] == 1;
        let mut to = [0u8; 20]; to.copy_from_slice(&bytes[37..57]);
        let value = u128::from_be_bytes(bytes[57..73].try_into().ok()?);
        let data_len = u32::from_be_bytes(bytes[73..77].try_into().ok()?) as usize;
        let data = if bytes.len() >= 77 + data_len { bytes[77..77+data_len].to_vec() } else { Vec::new() };
        Some(TxRecord {
            hash: *hash, block, from, nonce,
            to: if to_present { Some(to) } else { None },
            value, data,
        })
    }

    // ---------- EVM contract storage ----------

    /// Read a contract storage slot. Returns 32 BE bytes; zeroes if absent.
    pub fn read_storage_slot(&self, addr: &Address20, slot_be: &[u8; 32]) -> [u8; 32] {
        let mut key = [0u8; 52];
        key[..20].copy_from_slice(addr);
        key[20..].copy_from_slice(slot_be);
        match self.evm_storage.get(&key).ok().flatten() {
            Some(v) if v.len() == 32 => {
                let mut out = [0u8; 32]; out.copy_from_slice(&v); out
            }
            _ => [0u8; 32],
        }
    }

    /// Write a contract storage slot (zero value deletes the entry).
    pub fn write_storage_slot(&self, addr: &Address20, slot_be: &[u8; 32], value_be: &[u8; 32]) -> Result<(), String> {
        let mut key = [0u8; 52];
        key[..20].copy_from_slice(addr);
        key[20..].copy_from_slice(slot_be);
        if value_be.iter().all(|b| *b == 0) {
            self.evm_storage.remove(&key).map_err(|e| format!("storage remove: {e}"))?;
        } else {
            self.evm_storage.insert(&key, value_be.to_vec()).map_err(|e| format!("storage insert: {e}"))?;
        }
        Ok(())
    }

    /// Read deployed bytecode by its keccak256 hash. None if missing.
    pub fn read_code_by_hash(&self, code_hash: &[u8; 32]) -> Option<Vec<u8>> {
        self.evm_code.get(code_hash).ok().flatten().map(|v| v.to_vec())
    }

    /// Persist bytecode keyed by its keccak256 hash. Idempotent.
    pub fn write_code_by_hash(&self, code_hash: &[u8; 32], code: &[u8]) -> Result<(), String> {
        self.evm_code.insert(code_hash, code).map_err(|e| format!("code insert: {e}"))?;
        Ok(())
    }

    pub fn read_receipt(&self, hash: &[u8; 32]) -> Option<ReceiptRecord> {
        let bytes = self.receipts.get(hash).ok().flatten()?;
        if bytes.len() < 38 { return None; }
        let block = u64::from_be_bytes(bytes[0..8].try_into().ok()?);
        let gas_used = u64::from_be_bytes(bytes[8..16].try_into().ok()?);
        let status = bytes[16];
        let contract_present = bytes[17] == 1;
        let mut contract = [0u8; 20]; contract.copy_from_slice(&bytes[18..38]);
        Some(ReceiptRecord {
            hash: *hash, block, gas_used, status,
            contract: if contract_present { Some(contract) } else { None },
        })
    }
}

#[derive(Debug)]
pub struct TxRecord {
    pub hash: [u8; 32],
    pub block: u64,
    pub from: [u8; 20],
    pub nonce: u64,
    pub to: Option<[u8; 20]>,
    pub value: u128,
    pub data: Vec<u8>,
}

#[derive(Debug)]
pub struct ReceiptRecord {
    pub hash: [u8; 32],
    pub block: u64,
    pub gas_used: u64,
    pub status: u8,
    pub contract: Option<[u8; 20]>,
}

fn encode_account(a: &Account) -> Vec<u8> {
    let mut out = Vec::with_capacity(16 + 8 + 4 + a.code.len());
    out.extend_from_slice(&a.balance.to_be_bytes());
    out.extend_from_slice(&a.nonce.to_be_bytes());
    out.extend_from_slice(&(a.code.len() as u32).to_be_bytes());
    out.extend_from_slice(&a.code);
    out
}

fn decode_account(bytes: &[u8]) -> Account {
    if bytes.len() < 28 { return Account::default(); }
    let balance = u128::from_be_bytes(bytes[0..16].try_into().unwrap());
    let nonce = u64::from_be_bytes(bytes[16..24].try_into().unwrap());
    let code_len = u32::from_be_bytes(bytes[24..28].try_into().unwrap()) as usize;
    let code = if bytes.len() >= 28 + code_len { bytes[28..28 + code_len].to_vec() } else { Vec::new() };
    Account { balance, nonce, code }
}

pub fn parse_addr(s: &str) -> Option<Address20> {
    let s = s.trim_start_matches("0x");
    if s.len() != 40 { return None; }
    let bytes = hex::decode(s).ok()?;
    let mut out = [0u8; 20];
    out.copy_from_slice(&bytes);
    Some(out)
}
