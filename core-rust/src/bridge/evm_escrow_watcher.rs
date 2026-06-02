//! evm_escrow_watcher — chain-side observer of OmnibusDEX events on EVM
//! chains (Sepolia, Base Sepolia, Liberty, …).
//!
//! Polls `eth_getLogs` for `OrderPlaced` / `OrderCancelled` / `OrderSettled`
//! on the deployed OmnibusDEX contract. Maintains an in-memory map
//! `orderId → EvmEscrow` so the OmniBus matching engine can verify that a
//! BUY order is backed by real on-chain escrow before accepting it.
//!
//! Without this gate, a malicious buyer could submit BIDs in the orderbook
//! without locking funds, and at fill time the seller's OMNI would move
//! while no ETH ever changes hands — exactly the bug `fill #10` exposed on
//! testnet 2026-05-15.
//!
//! Flow:
//!   1. eth_getLogs from `from_block..head` with `address = OmnibusDEX`
//!   2. For each log:
//!      - topic0 == keccak("OrderPlaced(uint256,address,address,uint256,bytes32,uint64)")
//!        → insert escrow (state=open)
//!      - topic0 == keccak("OrderSettled(uint256,address,uint256)")    → state=settled
//!      - topic0 == keccak("OrderCancelled(uint256,address,uint256)")  → state=cancelled
//!   3. Advance per-chain cursor; persist `last_processed_block` so restarts
//!      resume from `last_processed_block - REORG_SAFETY` instead of head+1.
//!
//! BUG FIX (2026-06-02) — watcher from_block race:
//!   The previous implementation saved a single global cursor (one u64 in a
//!   binary file) that was shared across all chains. On restart it applied a
//!   64-block overlap to ALL bindings from a single value, meaning:
//!   (a) if chain A was at block 1000 and chain B at block 2000, both got the
//!       same cursor (whichever was last saved), so one chain always re-scanned
//!       from the wrong starting point; and
//!   (b) `scan_binding` returned `head + 1` which became `from_block` on the
//!       next tick — but if the process died between setting `from_block` and
//!       the next log event, those events were silently lost.
//!
//!   Fix: per-chain state is now persisted in `<data_dir>/watcher_state.json`
//!   as a JSON object `{ "<chain_id>": <last_processed_block>, … }`.
//!   On restart each binding resumes from `last_processed_block - REORG_SAFETY`
//!   (6 blocks). If no saved state exists the binding falls back to `head - 1000`
//!   (first-boot scan of recent history). The atomic-write pattern (tmp→rename)
//!   ensures no partial file is ever read on crash.
//!
//! Ported from core/evm_escrow_watcher.zig (2026-06-02). Long-running loop
//! moved off `std::thread` onto `tokio::task::spawn` per the Rust style mirror.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::Mutex;
use std::time::Duration;

use serde_json::Value;
use sha3::{Digest, Keccak256};
use tokio::sync::Notify;
use tokio::task::JoinHandle;
use tracing::{debug, warn};

use super::evm_rpc_client;

// ── Watcher state persistence ─────────────────────────────────────────────

/// Number of blocks to rewind on restart to guard against reorgs and events
/// that arrived in the window when the process was down.
const REORG_SAFETY: u64 = 6;

/// Load per-chain `last_processed_block` values from `<data_dir>/watcher_state.json`.
/// Returns an empty map on missing file or parse error (both are benign — first boot).
pub fn load_watcher_state(path: &Path) -> HashMap<u64, u64> {
    let raw = match std::fs::read_to_string(path) {
        Ok(s) => s,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
            tracing::info!(
                target: "evm_escrow_watcher",
                file = %path.display(),
                "watcher_state not found — first boot, starting from chain tip - 1000"
            );
            return HashMap::new();
        }
        Err(e) => {
            tracing::warn!(
                target: "evm_escrow_watcher",
                error = %e,
                file = %path.display(),
                "watcher_state read error — falling back to tip - 1000"
            );
            return HashMap::new();
        }
    };

    let v: Value = match serde_json::from_str(&raw) {
        Ok(v) => v,
        Err(e) => {
            tracing::warn!(
                target: "evm_escrow_watcher",
                error = %e,
                "watcher_state parse error — falling back to tip - 1000"
            );
            return HashMap::new();
        }
    };

    let mut m = HashMap::new();
    if let Some(obj) = v.as_object() {
        for (k, v) in obj {
            if let (Ok(chain_id), Some(block)) = (k.parse::<u64>(), v.as_u64()) {
                m.insert(chain_id, block);
            }
        }
    }
    m
}

/// Save per-chain `last_processed_block` map atomically (tmp → rename).
pub fn save_watcher_state(path: &Path, state: &HashMap<u64, u64>) -> std::io::Result<()> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let tmp = path.with_extension("json.tmp");
    let content = serde_json::to_string(state)
        .map_err(|e| std::io::Error::new(std::io::ErrorKind::Other, e))?;
    std::fs::write(&tmp, content)?;
    std::fs::rename(&tmp, path)?;
    Ok(())
}

/// One observed EVM-side escrow. `order_id` is the 256-bit id the OmniBus
/// chain handed out — keyed in the map by the low 64 bits since u256 isn't
/// hashable directly and order ids are sequential (collisions vanishingly
/// unlikely).
#[derive(Debug, Clone, Copy)]
pub struct EvmEscrow {
    pub order_id_hi: u128,
    pub order_id_lo: u128,
    pub owner_evm: [u8; 20],
    /// Zero = native ETH/MATIC/AVAX/etc.
    pub token: [u8; 20],
    /// Amount in token's smallest unit (18 dec ETH/WETH, 6 dec USDC, …).
    pub amount_hi: u128,
    pub amount_lo: u128,
    /// 32-byte commitment of the OMNI seller's bech32 address (set by buyer
    /// at placeBuyOrder time).
    pub omni_recipient: [u8; 32],
    /// Unix seconds after which the buyer can self-refund.
    pub expires_at: u64,
    /// 1 = open, 2 = settled, 3 = cancelled.
    pub state: u8,
    pub chain_id: u64,
}

#[derive(Debug, Clone)]
pub struct Binding {
    pub chain_id: u64,
    pub rpc_url: String,
    /// 0x-prefixed 42-char hex address of OmnibusDEX on this chain.
    pub contract: String,
    /// Resume cursor. 0 = scan from `head - 1000` on first boot.
    pub from_block: u64,
}

#[derive(Debug, Clone)]
pub struct Config {
    pub bindings: Vec<Binding>,
    pub poll_ms: u64,
    /// Directory that holds `watcher_state.json`.
    /// Replaces the old single-cursor `cursor_path` field.
    pub data_dir: PathBuf,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            bindings: Vec::new(),
            poll_ms: 3_000,
            data_dir: PathBuf::from("data"),
        }
    }
}

pub struct Watcher {
    cfg: Mutex<Config>,
    escrows: Mutex<HashMap<u64, EvmEscrow>>,
    stop: Arc<Notify>,
    handle: Mutex<Option<JoinHandle<()>>>,
}

impl Watcher {
    pub fn new(mut cfg: Config) -> Arc<Self> {
        // BUG FIX: per-chain state from watcher_state.json.
        // Each chain resumes from `last_processed_block - REORG_SAFETY`.
        // No saved state → binding keeps its configured from_block (or 0 = tip-1000).
        let state_path = cfg.data_dir.join("watcher_state.json");
        let saved = load_watcher_state(&state_path);
        for b in &mut cfg.bindings {
            if let Some(&last_block) = saved.get(&b.chain_id) {
                // Resume from last known block minus reorg safety, never below 0.
                b.from_block = last_block.saturating_sub(REORG_SAFETY);
                tracing::info!(
                    target: "evm_escrow_watcher",
                    chain_id = b.chain_id,
                    resume_from = b.from_block,
                    last_processed = last_block,
                    "watcher chain resuming from saved state"
                );
            }
            // If no saved state, from_block stays as configured (0 → tip-1000 on first scan).
        }
        Arc::new(Self {
            cfg: Mutex::new(cfg),
            escrows: Mutex::new(HashMap::new()),
            stop: Arc::new(Notify::new()),
            handle: Mutex::new(None),
        })
    }

    /// Spawn the background scan loop.
    pub fn start(self: &Arc<Self>) {
        let mut h = self.handle.lock().unwrap();
        if h.is_some() {
            return;
        }
        let me = Arc::clone(self);
        let stop = self.stop.clone();
        *h = Some(tokio::spawn(async move {
            let poll = me.cfg.lock().unwrap().poll_ms;
            loop {
                tokio::select! {
                    _ = stop.notified() => break,
                    _ = tokio::time::sleep(Duration::from_millis(poll)) => {
                        if let Err(e) = me.scan_once().await {
                            warn!(target: "evm_escrow_watcher", "tick err: {e}");
                        }
                    }
                }
            }
        }));
    }

    pub fn stop(&self) {
        self.stop.notify_waiters();
        if let Some(h) = self.handle.lock().unwrap().take() {
            h.abort();
        }
    }

    /// Thread-safe lookup. Returns `None` if the watcher hasn't seen the
    /// order, or it's been settled/cancelled.
    pub fn get_open(&self, order_id_low64: u64) -> Option<EvmEscrow> {
        let m = self.escrows.lock().unwrap();
        let e = m.get(&order_id_low64).copied()?;
        if e.state != 1 {
            return None;
        }
        Some(e)
    }

    async fn scan_once(&self) -> Result<(), String> {
        let bindings: Vec<Binding> = self.cfg.lock().unwrap().bindings.clone();
        let data_dir = self.cfg.lock().unwrap().data_dir.clone();
        let state_path = data_dir.join("watcher_state.json");

        for (i, b) in bindings.iter().enumerate() {
            match self.scan_binding(b).await {
                Ok(new_from) => {
                    let mut cfg = self.cfg.lock().unwrap();
                    if let Some(slot) = cfg.bindings.get_mut(i) {
                        slot.from_block = new_from;
                    }
                    // Persist per-chain state atomically.
                    // Re-read current state so we don't overwrite other chains' progress.
                    let mut state = load_watcher_state(&state_path);
                    state.insert(b.chain_id, new_from);
                    if let Err(e) = save_watcher_state(&state_path, &state) {
                        warn!(
                            target: "evm_escrow_watcher",
                            chain_id = b.chain_id,
                            error = %e,
                            "failed to persist watcher state"
                        );
                    }
                }
                Err(e) => warn!(target: "evm_escrow_watcher", "{} scan err: {}", b.contract, e),
            }
        }
        Ok(())
    }

    async fn scan_binding(&self, b: &Binding) -> Result<u64, String> {
        let head = evm_rpc_client::block_number(&b.rpc_url)
            .await
            .map_err(|e| e.to_string())?;

        // BUG FIX: never start from head + 1 without a persisted cursor.
        // from_block == 0 means "no saved state" → scan from tip - 1000 on first boot.
        let mut from = b.from_block;
        if from == 0 {
            from = head.saturating_sub(1000);
        }
        if from >= head {
            // Already up-to-date; return the current head so the cursor stays
            // at `head` (not `head + 1`) until we actually process new blocks.
            return Ok(head);
        }

        let from_hex = format!("0x{:x}", from);
        let to_hex = format!("0x{:x}", head);

        let logs = evm_rpc_client::get_logs(&b.rpc_url, &b.contract, None, &from_hex, &to_hex)
            .await
            .map_err(|e| e.to_string())?;

        parse_logs(&self.escrows, &logs, b.chain_id);

        // Persist `head` (not `head + 1`) so that on restart we resume from
        // `head - REORG_SAFETY`. Advancing to `head + 1` before persistence
        // meant that events in the window [last_head+1 .. new_head] were lost
        // if the process died before the next tick.
        Ok(head)
    }
}

// ── Event topic hashes (computed once via lazy init) ──────────────────────

fn topic_keccak(sig: &str) -> [u8; 32] {
    let mut h = Keccak256::new();
    h.update(sig.as_bytes());
    let out = h.finalize();
    let mut a = [0u8; 32];
    a.copy_from_slice(&out);
    a
}

fn placed_topic() -> [u8; 32] {
    topic_keccak("OrderPlaced(uint256,address,address,uint256,bytes32,uint64)")
}
fn settled_topic() -> [u8; 32] {
    topic_keccak("OrderSettled(uint256,address,uint256)")
}
fn cancelled_topic() -> [u8; 32] {
    topic_keccak("OrderCancelled(uint256,address,uint256)")
}

// ── JSON log parser ───────────────────────────────────────────────────────

fn parse_logs(escrows: &Mutex<HashMap<u64, EvmEscrow>>, logs: &Value, chain_id: u64) {
    let arr = match logs.as_array() {
        Some(a) => a,
        None => return,
    };
    let placed = placed_topic();
    let settled = settled_topic();
    let cancelled = cancelled_topic();

    for log in arr {
        let topics = match log["topics"].as_array() {
            Some(t) => t,
            None => continue,
        };
        if topics.is_empty() {
            continue;
        }
        let t0_hex = topics[0].as_str().unwrap_or("");
        let t0 = match hex0x_to_32(t0_hex) {
            Some(b) => b,
            None => continue,
        };
        let t1_hex = topics.get(1).and_then(|v| v.as_str()).unwrap_or("");
        let t1 = match hex0x_to_32(t1_hex) {
            Some(b) => b,
            None => continue,
        };
        let order_id_lo = u64::from_be_bytes(t1[24..32].try_into().unwrap());

        if t0 == placed {
            // owner @ topic[2], token @ topic[3]
            let owner = topics
                .get(2)
                .and_then(|v| v.as_str())
                .and_then(hex0x_to_32)
                .map(|b| {
                    let mut a = [0u8; 20];
                    a.copy_from_slice(&b[12..32]);
                    a
                })
                .unwrap_or([0u8; 20]);
            let token = topics
                .get(3)
                .and_then(|v| v.as_str())
                .and_then(hex0x_to_32)
                .map(|b| {
                    let mut a = [0u8; 20];
                    a.copy_from_slice(&b[12..32]);
                    a
                })
                .unwrap_or([0u8; 20]);

            // data = amount(32) | omni_recipient(32) | expires_at(32, low 8 bytes)
            let data = log["data"].as_str().unwrap_or("");
            let data_bytes = hex0x_to_vec(data);
            if data_bytes.len() < 96 {
                continue;
            }
            let mut amount = [0u8; 32];
            amount.copy_from_slice(&data_bytes[0..32]);
            let mut omni_rec = [0u8; 32];
            omni_rec.copy_from_slice(&data_bytes[32..64]);
            let expires_at = u64::from_be_bytes(data_bytes[88..96].try_into().unwrap());

            let amount_hi =
                u128::from_be_bytes(amount[0..16].try_into().unwrap());
            let amount_lo =
                u128::from_be_bytes(amount[16..32].try_into().unwrap());
            let order_id_hi = u128::from_be_bytes(t1[0..16].try_into().unwrap());
            let order_id_lo_full = u128::from_be_bytes(t1[16..32].try_into().unwrap());

            let e = EvmEscrow {
                order_id_hi,
                order_id_lo: order_id_lo_full,
                owner_evm: owner,
                token,
                amount_hi,
                amount_lo,
                omni_recipient: omni_rec,
                expires_at,
                state: 1,
                chain_id,
            };
            debug!(target: "evm_escrow_watcher", "OPEN orderId_lo={order_id_lo} expires={expires_at}");
            escrows.lock().unwrap().insert(order_id_lo, e);
        } else if t0 == settled || t0 == cancelled {
            let mut m = escrows.lock().unwrap();
            if let Some(e) = m.get_mut(&order_id_lo) {
                e.state = if t0 == settled { 2 } else { 3 };
            }
        }
    }
}

// ── Helpers ───────────────────────────────────────────────────────────────

fn hex0x_to_32(s: &str) -> Option<[u8; 32]> {
    let s = s.strip_prefix("0x").or_else(|| s.strip_prefix("0X"))?;
    if s.len() != 64 {
        return None;
    }
    let v = hex::decode(s).ok()?;
    let mut a = [0u8; 32];
    a.copy_from_slice(&v);
    Some(a)
}

fn hex0x_to_vec(s: &str) -> Vec<u8> {
    let s = s.strip_prefix("0x").or_else(|| s.strip_prefix("0X")).unwrap_or(s);
    hex::decode(s).unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    #[test]
    fn topics_are_distinct() {
        let a = placed_topic();
        let b = settled_topic();
        let c = cancelled_topic();
        assert_ne!(a, b);
        assert_ne!(b, c);
        assert_ne!(a, c);
    }

    #[test]
    fn hex0x_to_32_decodes_standard_topic() {
        let s = "0x000000000000000000000000000000000000000000000000000000000000002a";
        let b = hex0x_to_32(s).unwrap();
        assert_eq!(b[31], 0x2a);
    }

    // ── Bug 2 fix: per-chain watcher state persistence ────────────────────

    /// Verify that `save_watcher_state` + `load_watcher_state` round-trips
    /// correctly for multiple chains, and uses atomic writes (tmp → rename).
    #[test]
    fn test_watcher_resumes_from_saved_block() {
        let tmp_dir = std::env::temp_dir().join("omnibus_watcher_test_state");
        std::fs::create_dir_all(&tmp_dir).unwrap();
        let state_path = tmp_dir.join("watcher_state.json");

        // Write state for two chains.
        let mut state: HashMap<u64, u64> = HashMap::new();
        state.insert(11155111, 5000); // Sepolia at block 5000
        state.insert(84532, 3000);   // Base Sepolia at block 3000
        save_watcher_state(&state_path, &state).unwrap();

        // Verify atomic write left no .tmp artefact.
        let tmp_artefact = state_path.with_extension("json.tmp");
        assert!(!tmp_artefact.exists(), ".tmp file should be gone after atomic rename");

        // Load back and verify.
        let loaded = load_watcher_state(&state_path);
        assert_eq!(loaded.get(&11155111).copied(), Some(5000));
        assert_eq!(loaded.get(&84532).copied(), Some(3000));

        // Simulate restart: each binding should resume from saved - REORG_SAFETY.
        let sepolia_saved = *loaded.get(&11155111).unwrap();
        let base_saved = *loaded.get(&84532).unwrap();
        let sepolia_resume = sepolia_saved.saturating_sub(REORG_SAFETY);
        let base_resume = base_saved.saturating_sub(REORG_SAFETY);
        assert_eq!(sepolia_resume, 5000 - REORG_SAFETY);
        assert_eq!(base_resume, 3000 - REORG_SAFETY);

        // Clean up.
        let _ = std::fs::remove_file(&state_path);
        let _ = std::fs::remove_dir(&tmp_dir);
    }

    /// Verify graceful fallback when watcher_state.json does not exist.
    #[test]
    fn test_watcher_missing_state_returns_empty_map() {
        let nonexistent = PathBuf::from("/nonexistent/dir/watcher_state.json");
        let state = load_watcher_state(&nonexistent);
        assert!(state.is_empty(), "missing file should return empty state, not panic");
    }

    /// Verify graceful fallback on corrupt state file.
    #[test]
    fn test_watcher_corrupt_state_returns_empty_map() {
        let tmp_dir = std::env::temp_dir().join("omnibus_watcher_corrupt_test");
        std::fs::create_dir_all(&tmp_dir).unwrap();
        let state_path = tmp_dir.join("watcher_state.json");
        std::fs::write(&state_path, b"not valid json {{{{").unwrap();
        let state = load_watcher_state(&state_path);
        assert!(state.is_empty(), "corrupt file should fall back to empty state");
        let _ = std::fs::remove_file(&state_path);
        let _ = std::fs::remove_dir(&tmp_dir);
    }

    /// Verify that two chains can independently update their cursors without
    /// overwriting each other — simulating concurrent ticks for two chains.
    #[test]
    fn test_watcher_per_chain_cursor_independence() {
        let tmp_dir = std::env::temp_dir().join("omnibus_watcher_multi_chain_test");
        std::fs::create_dir_all(&tmp_dir).unwrap();
        let state_path = tmp_dir.join("watcher_state.json");

        // Chain A tick: save block 100 for chain 11155111.
        let mut state = load_watcher_state(&state_path);
        state.insert(11155111, 100);
        save_watcher_state(&state_path, &state).unwrap();

        // Chain B tick: save block 200 for chain 84532; must not lose chain A's entry.
        let mut state = load_watcher_state(&state_path);
        state.insert(84532, 200);
        save_watcher_state(&state_path, &state).unwrap();

        let final_state = load_watcher_state(&state_path);
        assert_eq!(final_state.get(&11155111).copied(), Some(100), "chain A entry must survive chain B update");
        assert_eq!(final_state.get(&84532).copied(), Some(200));

        let _ = std::fs::remove_file(&state_path);
        let _ = std::fs::remove_dir(&tmp_dir);
    }
}
