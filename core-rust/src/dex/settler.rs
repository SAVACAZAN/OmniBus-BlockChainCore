//! settler — DEX settler background thread.
//!
//! Watches the matching engine's fill list and turns OmniBus fills into
//! on-chain EVM `settle(uint256,address)` calls against deployed
//! OmnibusDEX contracts on Sepolia / Base / Liberty / etc.
//!
//! Flow:
//!   1. On startup: replay any fills from fills_log that have an evm_order_id
//!      but no settle record (crash recovery).
//!   2. Poll matching engine fills every `poll_ms`. For each unseen fill:
//!      - Skip non-EVM pairs (no binding).
//!      - Skip fills with zero seller_evm (STUCK — log loudly).
//!      - Build `settle(evm_order_id, seller_address)` calldata.
//!      - Sign + submit via `eth_sendRawTransaction`.
//!      - Advance cursor and persist.
//!
//! Ported from `core/dex/dex_settler.zig` (2026-06-02).

use super::{evm_rpc, evm_signer};
use super::fills_log::FillsLog;
use super::matching::MatchingEngine;
use std::collections::HashMap;
use std::fs::{File, OpenOptions};
use std::io::{Read, Seek, SeekFrom, Write};
use std::path::Path;
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

/// Per-pair EVM deployment config.
#[derive(Debug, Clone)]
pub struct PairBinding {
    pub pair_id: u16,
    /// EVM chain id (11155111 = Sepolia, 84532 = Base Sepolia, etc.)
    pub chain_id: u64,
    /// JSON-RPC endpoint URL.
    pub rpc_url: String,
    /// Deployed OmnibusDEX contract, "0x" + 40 hex chars.
    pub dex_contract: String,
}

/// Settler configuration — built once at startup.
#[derive(Clone)]
pub struct Config {
    /// Operator signing key (m/44'/60'/0'/0/2 from founder mnemonic).
    pub operator_key: evm_signer::SigningKey,
    /// Pair → chain mappings. Empty = all fills are skipped (native-only pairs).
    pub bindings: Vec<PairBinding>,
    /// Poll interval between fill scans.
    pub poll_ms: u64,
    /// Path to on-disk cursor (last settled fill_id). 8-byte LE u64.
    pub cursor_path: String,
    /// Optional fills log for recording settle tx hashes.
    pub fills_log: Option<Arc<FillsLog>>,
    /// Path to `fill_id → evm_order_id` sidecar for crash recovery.
    pub evm_index_path: String,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            operator_key: evm_signer::SigningKey { private_key: [0u8; 32], address: [0u8; 20] },
            bindings: Vec::new(),
            poll_ms: 2_000,
            cursor_path: "dex_settler_cursor.bin".into(),
            fills_log: None,
            evm_index_path: "dex_settler_evm_index.bin".into(),
        }
    }
}

// ---------------------------------------------------------------------------
// Settler
// ---------------------------------------------------------------------------

pub struct Settler {
    cfg: Config,
    engine: Arc<Mutex<MatchingEngine>>,
    last_settled_fill_id: u64,
    stop_flag: Arc<std::sync::atomic::AtomicBool>,
    thread: Option<thread::JoinHandle<()>>,
}

impl Settler {
    pub fn new(cfg: Config, engine: Arc<Mutex<MatchingEngine>>) -> Self {
        let cursor = load_cursor(&cfg.cursor_path).unwrap_or(0);
        Self {
            cfg,
            engine,
            last_settled_fill_id: cursor,
            stop_flag: Arc::new(std::sync::atomic::AtomicBool::new(false)),
            thread: None,
        }
    }

    pub fn start(&mut self) {
        if self.thread.is_some() {
            return;
        }
        let cfg = self.cfg.clone();
        let engine = Arc::clone(&self.engine);
        let cursor = self.last_settled_fill_id;
        let stop = Arc::clone(&self.stop_flag);

        let handle = thread::spawn(move || {
            let mut s = SettlerWorker {
                cfg,
                engine,
                last_settled: cursor,
                stop,
            };
            s.run();
        });
        self.thread = Some(handle);
    }

    pub fn stop(&mut self) {
        self.stop_flag.store(true, std::sync::atomic::Ordering::Release);
        if let Some(t) = self.thread.take() {
            let _ = t.join();
        }
    }
}

// ---------------------------------------------------------------------------
// Internal worker
// ---------------------------------------------------------------------------

struct SettlerWorker {
    cfg: Config,
    engine: Arc<Mutex<MatchingEngine>>,
    last_settled: u64,
    stop: Arc<std::sync::atomic::AtomicBool>,
}

impl SettlerWorker {
    fn run(&mut self) {
        replay_pending_fills(self);

        while !self.stop.load(std::sync::atomic::Ordering::Acquire) {
            if let Err(e) = self.scan_once() {
                eprintln!("[dex_settler] tick err: {e}");
            }
            // Sleep in 50ms chunks so stop() returns promptly.
            let mut slept = 0u64;
            while slept < self.cfg.poll_ms
                && !self.stop.load(std::sync::atomic::Ordering::Acquire)
            {
                thread::sleep(Duration::from_millis(50));
                slept += 50;
            }
        }
    }

    fn scan_once(&mut self) -> Result<(), Box<dyn std::error::Error>> {
        let fills: Vec<_> = {
            let eng = self.engine.lock().unwrap();
            eng.fills.clone()
        };

        for fill in &fills {
            if fill.fill_id <= self.last_settled {
                continue;
            }

            // Persist fill_id → evm_order_id for crash recovery
            if fill.evm_order_id != 0 {
                append_evm_index(&self.cfg.evm_index_path, fill.fill_id, fill.evm_order_id);
            }

            let binding = find_binding(&self.cfg.bindings, fill.pair_id, 0);

            let Some(binding) = binding else {
                // Non-EVM pair — skip
                self.last_settled = fill.fill_id;
                let _ = save_cursor(&self.cfg.cursor_path, self.last_settled);
                continue;
            };

            // Check seller_evm is non-zero
            if fill.seller_evm == [0u8; 20] {
                if fill.evm_order_id != 0 {
                    eprintln!(
                        "[dex_settler] STUCK fill {} pair={} evm_order_id={}: \
                         seller_evm is zero but BUY has escrow — refusing to advance cursor.",
                        fill.fill_id, fill.pair_id, fill.evm_order_id
                    );
                    return Ok(()); // bail without advancing cursor
                }
                self.last_settled = fill.fill_id;
                let _ = save_cursor(&self.cfg.cursor_path, self.last_settled);
                continue;
            }

            if fill.evm_order_id == 0 {
                self.last_settled = fill.fill_id;
                let _ = save_cursor(&self.cfg.cursor_path, self.last_settled);
                continue;
            }

            let seller_hex = addr_to_hex(&fill.seller_evm);

            eprintln!(
                "[dex_settler] processing fill {} pair={} binding_chain={}",
                fill.fill_id, fill.pair_id, binding.chain_id
            );

            if let Err(e) = self.submit_settle(&binding, fill.evm_order_id, fill.fill_id, &seller_hex) {
                eprintln!(
                    "[dex_settler] fill {} settle failed: {e} — will retry next tick",
                    fill.fill_id
                );
                return Ok(()); // bail, retry next tick
            }

            self.last_settled = fill.fill_id;
            let _ = save_cursor(&self.cfg.cursor_path, self.last_settled);
        }
        Ok(())
    }

    fn submit_settle(
        &self,
        binding: &PairBinding,
        order_id: u64,
        fill_id: u64,
        seller_0x: &str,
    ) -> Result<(), Box<dyn std::error::Error>> {
        let op_addr = addr_to_hex(&self.cfg.operator_key.address);

        eprintln!(
            "[dex_settler] submitSettle START fill={fill_id} order={order_id} \
             chain={} contract={} op={op_addr}",
            binding.chain_id, binding.dex_contract
        );

        let nonce = evm_rpc::get_transaction_count(&binding.rpc_url, &op_addr)?;
        let gp = evm_rpc::gas_price(&binding.rpc_url)?;
        let gp_bumped = gp.saturating_add(gp / 4);
        let chain_live = evm_rpc::chain_id(&binding.rpc_url)?;

        eprintln!(
            "[dex_settler] nonce={nonce} gas_price={gp_bumped} \
             chain_live={chain_live} chain_cfg={}",
            binding.chain_id
        );

        if chain_live != binding.chain_id {
            return Err(format!(
                "chain_id mismatch: cfg={} rpc={chain_live}",
                binding.chain_id
            )
            .into());
        }

        let calldata = build_settle_calldata(order_id, seller_0x)?;

        let to: [u8; 20] = evm_signer::hex0x_to_bytes(&binding.dex_contract)
            .map_err(|e| format!("bad dex_contract addr: {e}"))?;

        let tx = evm_signer::TxInput {
            chain_id: binding.chain_id,
            nonce,
            gas_price: gp_bumped,
            gas_limit: 120_000,
            to,
            value: 0,
            data: calldata,
        };

        let signed_hex = evm_signer::sign_legacy_tx(&tx, &self.cfg.operator_key)
            .map_err(|e| format!("sign: {e}"))?;

        let tx_hash = evm_rpc::send_raw_transaction(&binding.rpc_url, &signed_hex)?;

        eprintln!(
            "[dex_settler] settled order {order_id} → seller {seller_0x} \
             chain={} tx={tx_hash}",
            binding.chain_id
        );

        // Record in fills_log for "My Trades" UI
        if let Some(flog) = &self.cfg.fills_log {
            let mut tx_bytes = [0u8; 32];
            let hex_body = tx_hash.strip_prefix("0x").unwrap_or(&tx_hash);
            if let Ok(v) = hex::decode(&hex_body[..hex_body.len().min(64)]) {
                let n = v.len().min(32);
                tx_bytes[..n].copy_from_slice(&v[..n]);
            }
            let chain_u32 = binding.chain_id.min(u32::MAX as u64) as u32;
            if let Err(e) = flog.record_settle(fill_id, tx_bytes, chain_u32) {
                eprintln!("[dex_settler] fills_log.record_settle fill={fill_id} err={e}");
            }
        }

        Ok(())
    }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// `settle(uint256,address)` selector = keccak256[0..4] = 0x962d1938
fn settle_selector() -> [u8; 4] {
    use sha3::{Digest, Keccak256};
    let hash = Keccak256::digest(b"settle(uint256,address)");
    [hash[0], hash[1], hash[2], hash[3]]
}

/// ABI-encode `settle(uint256 orderId, address seller)` → 68-byte calldata.
fn build_settle_calldata(order_id: u64, seller_0x: &str) -> Result<Vec<u8>, Box<dyn std::error::Error>> {
    let mut cd = Vec::with_capacity(68);
    cd.extend_from_slice(&settle_selector());
    // uint256 orderId — left-padded to 32 bytes
    let mut word1 = [0u8; 32];
    word1[24..].copy_from_slice(&order_id.to_be_bytes());
    cd.extend_from_slice(&word1);
    // address seller — left-padded to 32 bytes (address is 20 bytes, right-aligned)
    let seller_bytes: [u8; 20] = evm_signer::hex0x_to_bytes(seller_0x)
        .map_err(|e| format!("bad seller addr: {e}"))?;
    let mut word2 = [0u8; 32];
    word2[12..].copy_from_slice(&seller_bytes);
    cd.extend_from_slice(&word2);
    Ok(cd)
}

fn find_binding(bindings: &[PairBinding], pair_id: u16, target_chain_id: u64) -> Option<PairBinding> {
    if target_chain_id != 0 {
        for b in bindings {
            if b.pair_id == pair_id && b.chain_id == target_chain_id {
                return Some(b.clone());
            }
        }
    }
    bindings.iter().find(|b| b.pair_id == pair_id).cloned()
}

fn addr_to_hex(addr: &[u8; 20]) -> String {
    format!("0x{}", hex::encode(addr))
}

// ---------------------------------------------------------------------------
// Cursor persistence (8-byte LE u64)
// ---------------------------------------------------------------------------

fn load_cursor(path: &str) -> Option<u64> {
    let mut f = File::open(path).ok()?;
    let mut buf = [0u8; 8];
    f.read_exact(&mut buf).ok()?;
    Some(u64::from_le_bytes(buf))
}

fn save_cursor(path: &str, value: u64) -> std::io::Result<()> {
    let mut f = File::create(path)?;
    f.write_all(&value.to_le_bytes())
}

// ---------------------------------------------------------------------------
// EVM index sidecar (16-byte records: fill_id(LE u64) + evm_order_id(LE u64))
// ---------------------------------------------------------------------------

fn append_evm_index(path: &str, fill_id: u64, evm_order_id: u64) {
    let Ok(mut f) = OpenOptions::new().create(true).append(true).open(path) else { return };
    let mut buf = [0u8; 16];
    buf[..8].copy_from_slice(&fill_id.to_le_bytes());
    buf[8..].copy_from_slice(&evm_order_id.to_le_bytes());
    let _ = f.write_all(&buf);
}

fn load_evm_index(path: &str) -> HashMap<u64, u64> {
    let mut map = HashMap::new();
    let Ok(mut f) = File::open(path) else { return map };
    let mut buf = [0u8; 16];
    loop {
        match f.read_exact(&mut buf) {
            Ok(()) => {
                let fid = u64::from_le_bytes(buf[..8].try_into().unwrap());
                let oid = u64::from_le_bytes(buf[8..].try_into().unwrap());
                map.insert(fid, oid);
            }
            Err(_) => break,
        }
    }
    map
}

// ---------------------------------------------------------------------------
// Startup replay — re-settle fills that landed but never got settle()d.
// ---------------------------------------------------------------------------

fn replay_pending_fills(w: &mut SettlerWorker) {
    let flog = match &w.cfg.fills_log {
        Some(f) => Arc::clone(f),
        None => return,
    };

    let settle_map = match flog.load_settle_map() {
        Ok(m) => m,
        Err(_) => return,
    };

    let evm_index = load_evm_index(&w.cfg.evm_index_path);

    let records = match flog.read_for_trader(b"", 0) {
        Ok(r) => r,
        Err(_) => return,
    };

    for rec in &records {
        if rec.fill_id <= w.last_settled {
            continue;
        }
        // Already settled
        if settle_map.contains_key(&rec.fill_id) {
            w.last_settled = w.last_settled.max(rec.fill_id);
            let _ = save_cursor(&w.cfg.cursor_path, w.last_settled);
            continue;
        }
        // Non-EVM fill
        if rec.evm_chain_id == 0 {
            w.last_settled = w.last_settled.max(rec.fill_id);
            let _ = save_cursor(&w.cfg.cursor_path, w.last_settled);
            continue;
        }
        let evm_order_id = match evm_index.get(&rec.fill_id) {
            Some(&id) => id,
            None => {
                eprintln!("[dex_settler] replay: fill {} not in EVM index — skipping", rec.fill_id);
                continue;
            }
        };
        if evm_order_id == 0 {
            w.last_settled = w.last_settled.max(rec.fill_id);
            let _ = save_cursor(&w.cfg.cursor_path, w.last_settled);
            continue;
        }
        let target_chain = rec.evm_chain_id;
        let Some(binding) = find_binding(&w.cfg.bindings, rec.pair_id, target_chain) else {
            eprintln!(
                "[dex_settler] replay: fill {} no binding pair={} chain={}",
                rec.fill_id, rec.pair_id, target_chain
            );
            w.last_settled = w.last_settled.max(rec.fill_id);
            let _ = save_cursor(&w.cfg.cursor_path, w.last_settled);
            continue;
        };
        if rec.seller_evm == [0u8; 20] {
            eprintln!("[dex_settler] replay: fill {} seller_evm zero — skip", rec.fill_id);
            w.last_settled = w.last_settled.max(rec.fill_id);
            let _ = save_cursor(&w.cfg.cursor_path, w.last_settled);
            continue;
        }
        let seller_hex = addr_to_hex(&rec.seller_evm);
        eprintln!(
            "[dex_settler] replay fill {} order={} chain={}",
            rec.fill_id, evm_order_id, target_chain
        );
        if let Err(e) = w.submit_settle(&binding, evm_order_id, rec.fill_id, &seller_hex) {
            eprintln!("[dex_settler] replay fill {} err: {e}", rec.fill_id);
            continue;
        }
        w.last_settled = w.last_settled.max(rec.fill_id);
        let _ = save_cursor(&w.cfg.cursor_path, w.last_settled);
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn settle_selector_correct() {
        let sel = settle_selector();
        assert_eq!(sel, [0x96, 0x2d, 0x19, 0x38]);
    }

    #[test]
    fn cursor_save_load_roundtrip() {
        let path = "test_settler_cursor_rs.tmp";
        save_cursor(path, 99_999).unwrap();
        let v = load_cursor(path).unwrap_or(0);
        let _ = std::fs::remove_file(path);
        assert_eq!(v, 99_999);
    }

    #[test]
    fn evm_index_append_and_load() {
        let path = "test_evm_index_rs.tmp";
        let _ = std::fs::remove_file(path);
        append_evm_index(path, 1, 101);
        append_evm_index(path, 2, 202);
        let m = load_evm_index(path);
        let _ = std::fs::remove_file(path);
        assert_eq!(m[&1], 101);
        assert_eq!(m[&2], 202);
    }

    #[test]
    fn build_settle_calldata_length() {
        let cd = build_settle_calldata(
            42,
            "0x0000000000000000000000000000000000000001",
        )
        .unwrap();
        assert_eq!(cd.len(), 68); // 4 selector + 32 uint256 + 32 address
    }
}
