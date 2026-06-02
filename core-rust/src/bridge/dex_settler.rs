//! dex_settler — DEX cross-chain settler bot (SKELETON).
//!
//! The Zig original (`core/dex_settler.zig`, 557 LoC) is a long-running
//! orchestrator that:
//!   1. Reads OmniBus matching engine fills from chain state.
//!   2. Looks up the matching EVM escrow via `evm_escrow_watcher`.
//!   3. Generates the HTLC preimage server-side (see
//!      `dex::htlc::SwapRegistry::generate_preimage`).
//!   4. Signs an EVM `settle(orderId, preimage)` tx using the operator key
//!      (BIP-44 m/44'/60'/0'/0/2 = `exchange.omnibus`) via `evm_signer`.
//!   5. Submits via `evm_rpc_client::send_raw_transaction`, watches the
//!      receipt with `get_receipt`, retries with bumped gas on stalls.
//!   6. On the OmniBus side, calls the matching engine to credit the OMNI
//!      leg once the EVM leg is confirmed.
//!
//! Status: NOT IMPLEMENTED (core settlement loop). Blocked on:
//!   * `wallet/treasury.rs` — needs the operator BIP-44 derivation. Currently
//!     scattered across `wallet/` and `crypto/` (Agent 4 scope).
//!   * `chain.rs` matching-engine fill stream — Agent 1 owns chain lifecycle.
//!   * Stable nonce manager — none of the Rust impls currently track EVM
//!     nonces per chain. Each settler tick races `eth_getTransactionCount`
//!     which the Zig original explicitly cached.
//!
//! CURSOR BUG FIX (2026-06-02):
//!   The Zig original uses `data/settler_state.bin` to persist the fill
//!   cursor so that restarts don't re-process already-settled fills.
//!   The previous Rust stub held no cursor at all (pure in-memory), meaning
//!   every restart started from fill #0, potentially double-settling orders.
//!   Fix: `SettlerCursor` is now backed by a small JSON file
//!   (`<data_dir>/settler_cursor.json`). The cursor is flushed to disk after
//!   every successfully processed fill. No new crate dependencies — uses
//!   `std::fs` + hand-rolled JSON (two integer fields).
//!
//! Once the full settlement loop lands, call `cursor.advance(fill_id)` after
//! each confirmed EVM receipt and the cursor will stay durable across restarts.
//!
//! Moving pieces already ported and ready:
//!   `evm_signer`, `evm_rpc_client`, `evm_escrow_watcher`,
//!   `dex::htlc::SwapRegistry`.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use super::evm_escrow_watcher::Watcher;
use crate::dex::htlc::SwapRegistry;

// ── PairBinding ───────────────────────────────────────────────────────────────

/// Per-pair EVM binding — mirrors `PairBinding` in `core/dex/dex_settler.zig`.
#[derive(Debug, Clone)]
pub struct PairBinding {
    /// Matching engine pair_id.
    pub pair_id: u16,
    /// EVM chain id (e.g. 11155111 = Sepolia, 84532 = Base Sepolia).
    pub chain_id: u64,
    /// JSON-RPC endpoint for this chain.
    pub rpc_url: String,
    /// Deployed OmnibusDEX contract address (0x-prefixed, 42 chars).
    pub dex_contract: String,
}

// ── Fill record (in-memory, from matching engine) ─────────────────────────────

/// A fill record as seen from the matching engine. Mirrors the `Fill` struct
/// in `core/matching_engine.zig` for the fields the settler needs.
#[derive(Debug, Clone, Default)]
pub struct Fill {
    pub fill_id: u64,
    pub pair_id: u16,
    /// EVM order id the buyer used when locking funds in OmnibusDEX.
    pub evm_order_id: u64,
    /// EVM address where the buyer's escrowed quote token should be delivered.
    pub seller_evm: [u8; 20],
    /// Block height at which the fill was created.
    pub block_height: u64,
}

// ── EVM index sidecar ─────────────────────────────────────────────────────────

/// 16-byte records: fill_id(u64 LE) + evm_order_id(u64 LE).
/// Written for each new EVM fill; read at startup to replay lost fills.
/// Mirrors `appendEvmIndex` / `loadEvmIndex` in Zig.
pub fn append_evm_index(path: &str, fill_id: u64, evm_order_id: u64) {
    use std::fs::OpenOptions;
    use std::io::Write;
    let mut buf = [0u8; 16];
    buf[..8].copy_from_slice(&fill_id.to_le_bytes());
    buf[8..].copy_from_slice(&evm_order_id.to_le_bytes());
    if let Ok(mut f) = OpenOptions::new().create(true).append(true).open(path) {
        let _ = f.write_all(&buf);
    }
}

/// Load the EVM index sidecar into a `HashMap<fill_id, evm_order_id>`.
pub fn load_evm_index(path: &str) -> HashMap<u64, u64> {
    let mut map = HashMap::new();
    let Ok(data) = std::fs::read(path) else {
        return map;
    };
    let mut i = 0;
    while i + 16 <= data.len() {
        let fid = u64::from_le_bytes(data[i..i + 8].try_into().unwrap_or([0u8; 8]));
        let oid = u64::from_le_bytes(data[i + 8..i + 16].try_into().unwrap_or([0u8; 8]));
        map.insert(fid, oid);
        i += 16;
    }
    map
}

// ── Binding helpers ───────────────────────────────────────────────────────────

/// Find the first binding for `pair_id`.
pub fn find_binding<'a>(bindings: &'a [PairBinding], pair_id: u16) -> Option<&'a PairBinding> {
    bindings.iter().find(|b| b.pair_id == pair_id)
}

/// Prefer a binding whose `chain_id` matches `target_chain_id`.
/// Falls back to the first matching binding when `target_chain_id == 0`
/// (e.g. escrow not in watcher map) so legacy single-chain setups still work.
/// Mirrors `findBindingForChain` in Zig.
pub fn find_binding_for_chain<'a>(
    bindings: &'a [PairBinding],
    pair_id: u16,
    target_chain_id: u64,
) -> Option<&'a PairBinding> {
    if target_chain_id != 0 {
        if let Some(b) = bindings
            .iter()
            .find(|b| b.pair_id == pair_id && b.chain_id == target_chain_id)
        {
            return Some(b);
        }
    }
    find_binding(bindings, pair_id)
}

// ── ABI helpers ───────────────────────────────────────────────────────────────

/// Compute the `settle(uint256,address)` 4-byte function selector:
/// `keccak256("settle(uint256,address)")[0..4]` = `0x962d1938`.
/// Mirrors `settleSelector` in Zig (comptime keccak).
pub fn settle_selector() -> [u8; 4] {
    use sha3::{Digest, Keccak256};
    let hash = Keccak256::digest(b"settle(uint256,address)");
    [hash[0], hash[1], hash[2], hash[3]]
}

/// ABI-encode a `settle(uint256 orderId, address seller)` calldata (68 bytes):
/// 4-byte selector + 32-byte uint256 (orderId) + 32-byte address (seller).
pub fn encode_settle_calldata(order_id: u64, seller_20: [u8; 20]) -> [u8; 68] {
    let mut cd = [0u8; 68];
    let sel = settle_selector();
    cd[..4].copy_from_slice(&sel);
    // uint256 orderId — big-endian, left-padded to 32 bytes
    cd[28..36].copy_from_slice(&order_id.to_be_bytes());
    // address seller — left-padded to 32 bytes (top 12 bytes stay 0)
    cd[48..68].copy_from_slice(&seller_20);
    cd
}

/// Format a 20-byte address as a `0x`-prefixed lowercase hex string.
pub fn addr20_to_hex(addr: [u8; 20]) -> String {
    let hex: String = addr.iter().map(|b| format!("{:02x}", b)).collect();
    format!("0x{}", hex)
}

/// Format a byte slice as a `0x`-prefixed lowercase hex string.
pub fn bytes_to_hex0x(bytes: &[u8]) -> String {
    let hex: String = bytes.iter().map(|b| format!("{:02x}", b)).collect();
    format!("0x{}", hex)
}

/// Parse a `0x`-prefixed hex string into a fixed-size byte array.
/// Returns all-zeros on parse error (mirrors Zig `hex0xToBytes`).
pub fn hex0x_to_bytes20(s: &str) -> [u8; 20] {
    let body = s.strip_prefix("0x").or_else(|| s.strip_prefix("0X")).unwrap_or(s);
    let mut out = [0u8; 20];
    for (i, chunk) in body.as_bytes().chunks(2).enumerate() {
        if i >= 20 { break; }
        if let (Some(&hi), Some(&lo)) = (chunk.first(), chunk.get(1)) {
            fn nib(c: u8) -> u8 {
                match c {
                    b'0'..=b'9' => c - b'0',
                    b'a'..=b'f' => c - b'a' + 10,
                    b'A'..=b'F' => c - b'A' + 10,
                    _ => 0,
                }
            }
            out[i] = (nib(hi) << 4) | nib(lo);
        }
    }
    out
}

// ── Scan / settle logic ───────────────────────────────────────────────────────

/// Result of attempting to settle a single fill.
#[derive(Debug)]
pub enum SettleOutcome {
    /// Fill settled — cursor should be advanced.
    Settled { evm_tx_hash: String },
    /// No EVM leg for this pair — cursor should be advanced (skip).
    SkippedNoBinding,
    /// Seller EVM address is zero but buyer has an escrow — STUCK. Cursor must
    /// NOT be advanced; operator intervention required.
    StuckZeroSeller,
    /// Seller EVM address is zero and buyer has no escrow — cursor should be
    /// advanced (pure native fill, no EVM settlement needed).
    SkippedNoEscrow,
    /// RPC error — retry on next tick (do not advance cursor).
    RpcError(String),
}

/// Determine the settle outcome for a single fill in dry-run mode (no actual
/// EVM TX submitted). Used for testing + rehearsal.
pub fn settle_dry_run(
    fill: &Fill,
    bindings: &[PairBinding],
    escrow_chain_id: Option<u64>,
) -> SettleOutcome {
    let target_chain_id = escrow_chain_id.unwrap_or(0);
    let Some(_binding) = find_binding_for_chain(bindings, fill.pair_id, target_chain_id) else {
        return SettleOutcome::SkippedNoBinding;
    };

    let all_zero = fill.seller_evm.iter().all(|&b| b == 0);
    if all_zero {
        if fill.evm_order_id != 0 {
            tracing::warn!(
                target: "dex_settler",
                fill_id = fill.fill_id,
                pair_id = fill.pair_id,
                evm_order_id = fill.evm_order_id,
                "STUCK fill: seller_evm is zero but BUY has escrow — refusing to advance cursor"
            );
            return SettleOutcome::StuckZeroSeller;
        }
        return SettleOutcome::SkippedNoEscrow;
    }

    if fill.evm_order_id == 0 {
        return SettleOutcome::SkippedNoEscrow;
    }

    // Dry-run: log what we would do and return a fake tx hash.
    let seller_hex = addr20_to_hex(fill.seller_evm);
    tracing::info!(
        target: "dex_settler",
        fill_id = fill.fill_id,
        order_id = fill.evm_order_id,
        seller = %seller_hex,
        pair_id = fill.pair_id,
        target_chain_id,
        "[DRY-RUN] would call settle({}, {}) on chain {}",
        fill.evm_order_id, seller_hex, target_chain_id,
    );

    SettleOutcome::Settled {
        evm_tx_hash: format!("0x{:0>64x}", fill.fill_id),
    }
}

/// Scan a slice of fills (from the matching engine) and return how many were
/// settled / skipped / stuck. Advances the cursor in-place.
///
/// Actual EVM submission is delegated to `submit_fn` (injectable for testing).
/// The function signature mirrors the Zig `scanOnce` loop.
pub fn scan_fills(
    fills: &[Fill],
    cursor: &mut SettlerCursor,
    bindings: &[PairBinding],
    evm_index_path: &str,
    get_escrow_chain_id: &dyn Fn(u64) -> Option<u64>,
    submit_fn: &dyn Fn(&Fill, &PairBinding) -> Result<String, String>,
) -> ScanStats {
    let mut stats = ScanStats::default();

    for fill in fills {
        if cursor.is_settled(fill.fill_id) {
            continue;
        }

        // Persist (fill_id → evm_order_id) for crash-recovery replay.
        if fill.evm_order_id != 0 {
            append_evm_index(evm_index_path, fill.fill_id, fill.evm_order_id);
        }

        let target_chain_id = get_escrow_chain_id(fill.evm_order_id).unwrap_or(0);

        let Some(binding) = find_binding_for_chain(bindings, fill.pair_id, target_chain_id) else {
            // No EVM leg — mark processed.
            let _ = cursor.advance(fill.fill_id, fill.block_height);
            stats.skipped += 1;
            continue;
        };

        let all_zero = fill.seller_evm.iter().all(|&b| b == 0);
        if all_zero {
            if fill.evm_order_id != 0 {
                tracing::warn!(
                    target: "dex_settler",
                    fill_id = fill.fill_id,
                    evm_order_id = fill.evm_order_id,
                    "STUCK fill: seller_evm zero but BUY has escrow — refusing to advance cursor"
                );
                stats.stuck += 1;
                return stats; // bail; don't advance cursor
            }
            let _ = cursor.advance(fill.fill_id, fill.block_height);
            stats.skipped += 1;
            continue;
        }

        if fill.evm_order_id == 0 {
            let _ = cursor.advance(fill.fill_id, fill.block_height);
            stats.skipped += 1;
            continue;
        }

        tracing::info!(
            target: "dex_settler",
            fill_id = fill.fill_id,
            pair_id = fill.pair_id,
            target_chain = target_chain_id,
            binding_chain = binding.chain_id,
            "processing fill"
        );

        match submit_fn(fill, binding) {
            Ok(tx_hash) => {
                tracing::info!(
                    target: "dex_settler",
                    fill_id = fill.fill_id,
                    order_id = fill.evm_order_id,
                    tx = %tx_hash,
                    chain_id = binding.chain_id,
                    "settled"
                );
                let _ = cursor.advance(fill.fill_id, fill.block_height);
                stats.settled += 1;
            }
            Err(e) => {
                tracing::warn!(
                    target: "dex_settler",
                    fill_id = fill.fill_id,
                    error = %e,
                    "settle failed — will retry next tick"
                );
                stats.errors += 1;
                return stats; // bail without advancing cursor; retry next tick
            }
        }
    }

    stats
}

/// Statistics returned by `scan_fills`.
#[derive(Debug, Default, Clone)]
pub struct ScanStats {
    pub settled: u32,
    pub skipped: u32,
    pub stuck: u32,
    pub errors: u32,
}

// ── SettlerCursor ─────────────────────────────────────────────────────────────

/// Durable fill cursor. Persists the id of the last fill that was fully
/// settled so that a restart doesn't re-process fills from the beginning.
///
/// File format (trivial, hand-rolled — no extra crate dependency):
/// ```json
/// {"last_settled_fill_id":42,"last_settled_block":1234}
/// ```
/// The file is written atomically: new content is flushed to
/// `<path>.tmp` then renamed into place, preventing a partial write
/// from corrupting the cursor on an unexpected shutdown.
#[derive(Debug, Clone)]
pub struct SettlerCursor {
    path: PathBuf,
    /// The fill id (monotonically increasing) of the last fill we have
    /// fully settled. Fills with `id <= last_settled_fill_id` are skipped.
    pub last_settled_fill_id: u64,
    /// Block height at which the last settlement was confirmed on-chain.
    pub last_settled_block: u64,
}

impl SettlerCursor {
    /// Load cursor from `path`, or return a zeroed cursor if the file does
    /// not exist yet (first boot). Any parse error is logged and treated as
    /// "start from zero" — safer than panicking on a corrupt file.
    pub fn load(path: impl AsRef<Path>) -> Self {
        let path = path.as_ref().to_path_buf();
        let (fill_id, block) = Self::try_load(&path).unwrap_or_else(|e| {
            if e.kind() == std::io::ErrorKind::NotFound {
                tracing::info!(
                    target: "dex_settler",
                    file = %path.display(),
                    "cursor file not found — starting from fill #0"
                );
            } else {
                tracing::warn!(
                    target: "dex_settler",
                    error = %e,
                    file = %path.display(),
                    "cursor load error — starting from fill #0"
                );
            }
            (0, 0)
        });
        tracing::info!(
            target: "dex_settler",
            last_fill = fill_id,
            last_block = block,
            "settler cursor loaded"
        );
        Self { path, last_settled_fill_id: fill_id, last_settled_block: block }
    }

    fn try_load(path: &Path) -> std::io::Result<(u64, u64)> {
        let raw = std::fs::read_to_string(path)?;
        // Hand-rolled parse: no serde dependency needed for two integers.
        let fill_id = parse_json_u64(&raw, "last_settled_fill_id").unwrap_or(0);
        let block   = parse_json_u64(&raw, "last_settled_block").unwrap_or(0);
        Ok((fill_id, block))
    }

    /// Advance the cursor to `fill_id` (confirmed at `block_height`) and flush
    /// to disk. Call this after every confirmed EVM settlement receipt.
    ///
    /// Advances only if `fill_id > self.last_settled_fill_id` (monotonic).
    pub fn advance(&mut self, fill_id: u64, block_height: u64) -> std::io::Result<()> {
        if fill_id <= self.last_settled_fill_id {
            return Ok(()); // already settled; idempotent
        }
        self.last_settled_fill_id = fill_id;
        self.last_settled_block = block_height;
        self.flush()
    }

    /// Flush the cursor to disk atomically.
    pub fn flush(&self) -> std::io::Result<()> {
        // Ensure parent directory exists.
        if let Some(parent) = self.path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let tmp = self.path.with_extension("json.tmp");
        let content = format!(
            "{{\"last_settled_fill_id\":{},\"last_settled_block\":{}}}\n",
            self.last_settled_fill_id,
            self.last_settled_block
        );
        std::fs::write(&tmp, &content)?;
        std::fs::rename(&tmp, &self.path)?;
        tracing::debug!(
            target: "dex_settler",
            last_fill = self.last_settled_fill_id,
            last_block = self.last_settled_block,
            "cursor flushed"
        );
        Ok(())
    }

    /// Returns `true` if `fill_id` has already been settled (should be skipped).
    #[inline]
    pub fn is_settled(&self, fill_id: u64) -> bool {
        fill_id <= self.last_settled_fill_id
    }
}

/// Minimal JSON field extractor for `{"key":number}` without pulling in serde.
/// Looks for `"<key":<digits>` and returns the number. Returns `None` on any
/// parse failure (corrupt file → caller falls back to 0).
fn parse_json_u64(json: &str, key: &str) -> Option<u64> {
    // Build search pattern e.g. `"last_settled_fill_id":`
    let needle = format!("\"{}\":", key);
    let start = json.find(needle.as_str())?;
    let after_colon = start + needle.len();
    // Skip optional whitespace
    let rest = json[after_colon..].trim_start();
    // Parse digits until first non-digit
    let digits: String = rest.chars().take_while(|c| c.is_ascii_digit()).collect();
    digits.parse::<u64>().ok()
}

// ── SettlerConfig ─────────────────────────────────────────────────────────────

#[derive(Debug, Clone)]
pub struct SettlerConfig {
    pub poll_ms: u64,
    /// Operator private key (32 bytes). When `None`, settler runs in
    /// dry-run mode: it logs what it would have submitted but does not
    /// actually send tx. Useful for testnet rehearsal.
    pub operator_key: Option<[u8; 32]>,
    /// Directory for settler state files (cursor + nonce cache).
    /// Mirrors Zig's `data/` directory convention.
    pub data_dir: String,
}

impl Default for SettlerConfig {
    fn default() -> Self {
        Self {
            poll_ms: 5_000,
            operator_key: None,
            data_dir: "./data".to_string(),
        }
    }
}

// ── Settler ───────────────────────────────────────────────────────────────────

pub struct Settler {
    #[allow(dead_code)]
    cfg: SettlerConfig,
    #[allow(dead_code)]
    watcher: Arc<Watcher>,
    #[allow(dead_code)]
    swaps: Arc<SwapRegistry>,
    /// Durable fill cursor — survives restarts.
    cursor: SettlerCursor,
}

impl Settler {
    pub fn new(cfg: SettlerConfig, watcher: Arc<Watcher>, swaps: Arc<SwapRegistry>) -> Self {
        let cursor_path = PathBuf::from(&cfg.data_dir).join("settler_cursor.json");
        let cursor = SettlerCursor::load(&cursor_path);
        Self { cfg, watcher, swaps, cursor }
    }

    /// Main settler poll loop.
    ///
    /// Each tick:
    ///   1. Load the EVM index sidecar (fill_id → evm_order_id).
    ///   2. Call `fill_provider` to get unseen fills from the matching engine.
    ///   3. For each fill: look up the escrow watcher for the target chain_id,
    ///      find the right `PairBinding`, build + sign + submit the
    ///      `settle(orderId, sellerEvm)` EVM call.
    ///   4. Advance the cursor + persist after each confirmed settlement.
    ///
    /// When `operator_key` is `None` (dry-run mode), the loop logs what it
    /// would settle but does not submit any EVM transactions.
    ///
    /// `fill_provider`: closure returning `Vec<Fill>` of fills after cursor.
    /// `bindings`: per-pair EVM contract bindings (injected at startup).
    pub async fn run_with_fills(
        &mut self,
        bindings: Vec<PairBinding>,
        fill_provider: impl Fn(u64) -> Vec<Fill>,
    ) {
        let evm_index_path = format!("{}/dex_settler_evm_index.bin", self.cfg.data_dir);
        let poll = tokio::time::Duration::from_millis(self.cfg.poll_ms);
        let is_dry_run = self.cfg.operator_key.is_none();

        if is_dry_run {
            tracing::warn!(
                target: "dex_settler",
                last_fill = self.cursor.last_settled_fill_id,
                "Settler running in DRY-RUN mode (no operator_key). \
                 Cursor starts at fill #{}.",
                self.cursor.last_settled_fill_id
            );
        } else {
            tracing::info!(
                target: "dex_settler",
                last_fill = self.cursor.last_settled_fill_id,
                "Settler started. Resuming from fill #{}.",
                self.cursor.last_settled_fill_id
            );
        }

        loop {
            tokio::time::sleep(poll).await;

            let fills = fill_provider(self.cursor.last_settled_fill_id);
            if fills.is_empty() {
                continue;
            }

            let watcher = self.watcher.clone();
            let get_escrow_chain_id = move |order_id: u64| -> Option<u64> {
                watcher.get_open(order_id).map(|e| e.chain_id)
            };

            let key = self.cfg.operator_key;
            let dry = is_dry_run;
            let submit_fn = move |fill: &Fill, binding: &PairBinding| -> Result<String, String> {
                if dry {
                    // Dry-run: fake tx hash.
                    return Ok(format!("0x{:0>64x}", fill.fill_id));
                }
                let Some(_k) = key else {
                    return Err("no operator key".to_string());
                };
                // TODO: wire evm_signer + evm_rpc_client once stable nonce manager lands.
                // For now, log the calldata we would submit.
                let cd = encode_settle_calldata(fill.evm_order_id, fill.seller_evm);
                let seller_hex = addr20_to_hex(fill.seller_evm);
                tracing::info!(
                    target: "dex_settler",
                    fill_id = fill.fill_id,
                    order_id = fill.evm_order_id,
                    seller = %seller_hex,
                    contract = %binding.dex_contract,
                    chain_id = binding.chain_id,
                    calldata = %bytes_to_hex0x(&cd),
                    "settle calldata ready (EVM submission pending stable nonce manager)"
                );
                Err("evm_submission_not_yet_wired".to_string())
            };

            let stats = scan_fills(
                &fills,
                &mut self.cursor,
                &bindings,
                &evm_index_path,
                &get_escrow_chain_id,
                &submit_fn,
            );

            if stats.settled > 0 || stats.errors > 0 || stats.stuck > 0 {
                tracing::info!(
                    target: "dex_settler",
                    settled = stats.settled,
                    skipped = stats.skipped,
                    stuck = stats.stuck,
                    errors = stats.errors,
                    last_fill = self.cursor.last_settled_fill_id,
                    "scan_fills tick complete"
                );
            }
        }
    }

    /// Backward-compat stub for callers that don't inject a fill provider.
    /// Logs a warning and runs the empty placeholder poll loop.
    pub async fn run(&mut self) {
        tracing::warn!(
            target: "dex_settler",
            last_fill = self.cursor.last_settled_fill_id,
            "Settler::run: use run_with_fills() to wire the fill stream. \
             Cursor is persistent — restarts will resume from fill #{}.",
            self.cursor.last_settled_fill_id
        );

        let poll = tokio::time::Duration::from_millis(self.cfg.poll_ms);
        loop {
            tokio::time::sleep(poll).await;
        }
    }
}

// ── Tests ─────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    // ─── PairBinding + binding lookup ─────────────────────────────────────────

    fn test_bindings() -> Vec<PairBinding> {
        vec![
            PairBinding {
                pair_id: 0,
                chain_id: 11155111,
                rpc_url: "https://sepolia.example.com".to_string(),
                dex_contract: "0xdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef".to_string(),
            },
            PairBinding {
                pair_id: 0,
                chain_id: 84532,
                rpc_url: "https://base-sepolia.example.com".to_string(),
                dex_contract: "0xcafecafecafecafecafecafecafecafecafecafe".to_string(),
            },
            PairBinding {
                pair_id: 3,
                chain_id: 11155111,
                rpc_url: "https://sepolia.example.com".to_string(),
                dex_contract: "0xfeedfeedfeedfeedfeedfeedfeedfeedfeedfeed".to_string(),
            },
        ]
    }

    #[test]
    fn find_binding_finds_first() {
        let b = test_bindings();
        let r = find_binding(&b, 0).unwrap();
        assert_eq!(r.chain_id, 11155111);
    }

    #[test]
    fn find_binding_missing() {
        let b = test_bindings();
        assert!(find_binding(&b, 99).is_none());
    }

    #[test]
    fn find_binding_for_chain_prefers_target() {
        let b = test_bindings();
        let r = find_binding_for_chain(&b, 0, 84532).unwrap();
        assert_eq!(r.chain_id, 84532);
    }

    #[test]
    fn find_binding_for_chain_falls_back_when_zero() {
        let b = test_bindings();
        // target=0 → fall back to first pair_id=0 binding
        let r = find_binding_for_chain(&b, 0, 0).unwrap();
        assert_eq!(r.chain_id, 11155111);
    }

    // ─── ABI helpers ──────────────────────────────────────────────────────────

    #[test]
    fn settle_selector_matches_keccak() {
        // Reference: keccak256("settle(uint256,address)")[0..4] = 0x962d1938
        let sel = settle_selector();
        assert_eq!(sel, [0x96, 0x2d, 0x19, 0x38]);
    }

    #[test]
    fn encode_settle_calldata_length() {
        let cd = encode_settle_calldata(42, [0xab; 20]);
        assert_eq!(cd.len(), 68);
        // Selector at bytes 0..4
        assert_eq!(&cd[..4], &[0x96, 0x2d, 0x19, 0x38]);
        // order_id=42 at bytes 28..36 big-endian
        assert_eq!(u64::from_be_bytes(cd[28..36].try_into().unwrap()), 42);
        // seller at bytes 48..68
        assert_eq!(&cd[48..68], &[0xab; 20]);
    }

    #[test]
    fn addr20_to_hex_format() {
        let addr = [0x00, 0xAB, 0xCD, 0xEF, 0x01, 0x23, 0x45, 0x67,
                    0x89, 0x9A, 0xBC, 0xDE, 0xF0, 0x12, 0x34, 0x56,
                    0x78, 0x9A, 0xBC, 0xDE];
        let hex = addr20_to_hex(addr);
        assert!(hex.starts_with("0x"));
        assert_eq!(hex.len(), 42);
    }

    #[test]
    fn hex0x_roundtrip() {
        let original = [0x00u8, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77,
                        0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff,
                        0x10, 0x20, 0x30, 0x40];
        let hex = addr20_to_hex(original);
        let back = hex0x_to_bytes20(&hex);
        assert_eq!(back, original);
    }

    // ─── scan_fills ───────────────────────────────────────────────────────────

    #[test]
    fn scan_fills_skips_settled() {
        let bindings = test_bindings();
        let fill = Fill {
            fill_id: 5,
            pair_id: 99, // no binding
            evm_order_id: 0,
            seller_evm: [0u8; 20],
            block_height: 100,
        };
        let tmp = std::env::temp_dir().join("omnibus_scan_test_cursor.json");
        let mut cursor = SettlerCursor {
            path: tmp.clone(),
            last_settled_fill_id: 5,
            last_settled_block: 50,
        };
        let stats = scan_fills(
            &[fill],
            &mut cursor,
            &bindings,
            "/nonexistent/evm_index.bin",
            &|_| None,
            &|_, _| Err("should_not_be_called".to_string()),
        );
        assert_eq!(stats.settled, 0);
        assert_eq!(stats.skipped, 0); // was already settled, loop body not entered
        let _ = std::fs::remove_file(&tmp);
    }

    #[test]
    fn scan_fills_skips_no_binding() {
        let bindings = test_bindings();
        let fill = Fill {
            fill_id: 10,
            pair_id: 99, // no binding
            evm_order_id: 100,
            seller_evm: [0xab; 20],
            block_height: 200,
        };
        let tmp = std::env::temp_dir().join("omnibus_scan_skip_cursor.json");
        let mut cursor = SettlerCursor {
            path: tmp.clone(),
            last_settled_fill_id: 0,
            last_settled_block: 0,
        };
        let stats = scan_fills(
            &[fill],
            &mut cursor,
            &bindings,
            "/nonexistent/evm_index.bin",
            &|_| None,
            &|_, _| Ok("0xhash".to_string()),
        );
        assert_eq!(stats.skipped, 1);
        assert_eq!(cursor.last_settled_fill_id, 10); // cursor advances past no-binding fills
        let _ = std::fs::remove_file(&tmp);
    }

    #[test]
    fn scan_fills_stuck_zero_seller_with_escrow() {
        let bindings = test_bindings();
        let fill = Fill {
            fill_id: 20,
            pair_id: 0, // has binding
            evm_order_id: 999, // non-zero → buyer had escrow
            seller_evm: [0u8; 20], // zero → STUCK
            block_height: 300,
        };
        let tmp = std::env::temp_dir().join("omnibus_stuck_cursor.json");
        let mut cursor = SettlerCursor {
            path: tmp.clone(),
            last_settled_fill_id: 0,
            last_settled_block: 0,
        };
        let stats = scan_fills(
            &[fill],
            &mut cursor,
            &bindings,
            "/nonexistent/evm_index.bin",
            &|_| Some(11155111u64),
            &|_, _| Ok("0xhash".to_string()),
        );
        assert_eq!(stats.stuck, 1);
        assert_eq!(cursor.last_settled_fill_id, 0); // cursor NOT advanced
        let _ = std::fs::remove_file(&tmp);
    }

    #[test]
    fn scan_fills_settles_happy_path() {
        let bindings = test_bindings();
        let fill = Fill {
            fill_id: 30,
            pair_id: 0,
            evm_order_id: 888,
            seller_evm: [0xca; 20],
            block_height: 400,
        };
        let tmp = std::env::temp_dir().join("omnibus_settle_cursor.json");
        let mut cursor = SettlerCursor {
            path: tmp.clone(),
            last_settled_fill_id: 0,
            last_settled_block: 0,
        };
        let stats = scan_fills(
            &[fill],
            &mut cursor,
            &bindings,
            "/nonexistent/evm_index.bin",
            &|_| Some(11155111u64),
            &|_, _| Ok("0xdeadbeefhash".to_string()),
        );
        assert_eq!(stats.settled, 1);
        assert_eq!(cursor.last_settled_fill_id, 30);
        let _ = std::fs::remove_file(&tmp);
    }

    // ─── settle_dry_run ───────────────────────────────────────────────────────

    #[test]
    fn dry_run_skips_no_binding() {
        let bindings = test_bindings();
        let fill = Fill { fill_id: 1, pair_id: 99, evm_order_id: 0,
            seller_evm: [0xab; 20], block_height: 1 };
        assert!(matches!(settle_dry_run(&fill, &bindings, None), SettleOutcome::SkippedNoBinding));
    }

    #[test]
    fn dry_run_stuck_zero_seller() {
        let bindings = test_bindings();
        let fill = Fill { fill_id: 2, pair_id: 0, evm_order_id: 100,
            seller_evm: [0u8; 20], block_height: 2 };
        assert!(matches!(settle_dry_run(&fill, &bindings, Some(11155111)), SettleOutcome::StuckZeroSeller));
    }

    #[test]
    fn dry_run_settled() {
        let bindings = test_bindings();
        let fill = Fill { fill_id: 3, pair_id: 0, evm_order_id: 200,
            seller_evm: [0xde; 20], block_height: 3 };
        let out = settle_dry_run(&fill, &bindings, Some(11155111));
        assert!(matches!(out, SettleOutcome::Settled { .. }));
    }

    // ─── parse_json_u64 (original tests preserved) ───────────────────────────

    #[test]
    fn parse_json_u64_basic() {
        let s = r#"{"last_settled_fill_id":42,"last_settled_block":1234}"#;
        assert_eq!(parse_json_u64(s, "last_settled_fill_id"), Some(42));
        assert_eq!(parse_json_u64(s, "last_settled_block"), Some(1234));
        assert_eq!(parse_json_u64(s, "missing_key"), None);
    }

    #[test]
    fn parse_json_u64_zero() {
        let s = r#"{"last_settled_fill_id":0,"last_settled_block":0}"#;
        assert_eq!(parse_json_u64(s, "last_settled_fill_id"), Some(0));
    }

    #[test]
    fn cursor_is_settled_logic() {
        let cursor = SettlerCursor {
            path: PathBuf::from("/tmp/test_cursor.json"),
            last_settled_fill_id: 10,
            last_settled_block: 100,
        };
        assert!(cursor.is_settled(10));
        assert!(cursor.is_settled(5));
        assert!(!cursor.is_settled(11));
    }

    #[test]
    fn cursor_advance_monotonic() {
        let tmp = std::env::temp_dir().join("omnibus_settler_test_cursor.json");
        let mut cursor = SettlerCursor {
            path: tmp.clone(),
            last_settled_fill_id: 5,
            last_settled_block: 50,
        };
        // Advance backwards should be a no-op (no write needed).
        cursor.advance(3, 30).unwrap();
        assert_eq!(cursor.last_settled_fill_id, 5);

        // Advance forwards — should update and flush.
        cursor.advance(7, 70).unwrap();
        assert_eq!(cursor.last_settled_fill_id, 7);
        assert_eq!(cursor.last_settled_block, 70);

        // Reload from disk and verify persistence.
        let loaded = SettlerCursor::load(&tmp);
        assert_eq!(loaded.last_settled_fill_id, 7);
        assert_eq!(loaded.last_settled_block, 70);

        // Clean up.
        let _ = std::fs::remove_file(&tmp);
    }
}
