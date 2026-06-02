//! bridge_relay — Cross-Chain Bridge Relay (Lock / Mint / Burn / Redeem).
//!
//! Model: Lock-and-Mint (ca Wrapped Bitcoin — WBTC):
//!   1. User sends foreign asset to the bridge lock address on the foreign chain.
//!   2. Relayer confirms the lock on the foreign chain.
//!   3. Bridge mints wrapped asset (wBTC, wETH, …) on the OMNI chain.
//!   4. At redeem: burn wrapped asset on OMNI → unlock original on foreign chain.
//!
//! Security:
//!   - Relayers are OmniBus validators with stake.
//!   - N/M multisig: `BRIDGE_REQUIRED_SIGS`-of-`BRIDGE_MAX_RELAYERS` must confirm.
//!   - Timeout: if not confirmed within `BRIDGE_TIMEOUT_BLOCKS` → refund eligible.
//!   - Oracle provides the conversion rate (reference_micro_usd) for foreign ↔ OMNI.
//!
//! Ported from `core/bridge/bridge_relay.zig` (373 LoC) — 2026-06-02.

use serde::{Deserialize, Serialize};
use serde_big_array::BigArray;

fn default_relayer_sigs() -> [[u8; 64]; BRIDGE_MAX_RELAYERS] {
    [[0u8; 64]; BRIDGE_MAX_RELAYERS]
}
use thiserror::Error;

// ── Constants ─────────────────────────────────────────────────────────────────

/// Multisig: minimum confirmations required out of at most `BRIDGE_MAX_RELAYERS`.
pub const BRIDGE_REQUIRED_SIGS: u8 = 2;
/// Maximum number of relayers that may sign a single operation.
pub const BRIDGE_MAX_RELAYERS: usize = 9;
/// Timeout in OMNI blocks for a bridge operation to be confirmed. After this the
/// operation can be refunded.
pub const BRIDGE_TIMEOUT_BLOCKS: u64 = 100;
/// Bridge fee in basis points (10 BPS = 0.1 %).
pub const BRIDGE_FEE_BPS: u64 = 10;

/// Maximum number of entries in the wrapped-asset table.
/// Mirrors the Zig `[20]WrappedAsset` array.
pub const MAX_WRAPPED_CHAINS: usize = 20;

// ── Chain / exchange identifier ───────────────────────────────────────────────

/// Identifier for the foreign chain involved in a bridge operation.
///
/// Variants are assigned numeric indices that index into the `wrapped` table
/// in `BridgeRelay`. Values must be stable (< MAX_WRAPPED_CHAINS).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[repr(u8)]
pub enum ChainId {
    Omni = 0,
    Btc = 1,
    Eth = 2,
    Liberty = 3,
    Base = 4,
    Arbitrum = 5,
    Optimism = 6,
    Minato = 7,
    Solana = 8,
    Xrp = 9,
}

impl ChainId {
    pub fn name(self) -> &'static str {
        match self {
            ChainId::Omni => "OMNI",
            ChainId::Btc => "BTC",
            ChainId::Eth => "ETH",
            ChainId::Liberty => "Liberty",
            ChainId::Base => "Base",
            ChainId::Arbitrum => "Arbitrum",
            ChainId::Optimism => "Optimism",
            ChainId::Minato => "Minato",
            ChainId::Solana => "SOL",
            ChainId::Xrp => "XRP",
        }
    }

    /// Index into the `wrapped` array in `BridgeRelay`.
    pub fn index(self) -> usize {
        self as usize
    }
}

// ── Oracle price entry ────────────────────────────────────────────────────────

/// Simplified price record used for bridge conversion.
///
/// The relay only needs a single reference price (mid-point) expressed in
/// micro-USD (1 USD = 1_000_000 units — same scale as `core/price_oracle.zig`).
/// For the full async Chainlink/Pyth/CoinGecko adapter, see `dex/oracle.rs`.
#[derive(Debug, Clone, Copy)]
pub struct BridgePrice {
    pub chain_id: ChainId,
    /// Reference mid-price in micro-USD (i.e. 1 USD = 1_000_000).
    pub reference_micro_usd: u64,
}

/// Minimal price oracle used by the bridge relay to convert foreign amounts to
/// OMNI satoshis.
///
/// In production this wraps the distributed on-chain oracle (submitted by miners
/// and aggregated by consensus); in tests it can be populated directly.
#[derive(Debug, Default)]
pub struct SimplePriceOracle {
    /// Prices keyed by chain index (same as `ChainId::index()`).
    prices: [u64; MAX_WRAPPED_CHAINS], // micro-USD; 0 = unknown
}

impl SimplePriceOracle {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn set_price(&mut self, chain: ChainId, micro_usd: u64) {
        let idx = chain.index();
        if idx < MAX_WRAPPED_CHAINS {
            self.prices[idx] = micro_usd;
        }
    }

    pub fn get_bridge_price(&self, chain: ChainId) -> Result<BridgePrice, RelayError> {
        let idx = chain.index();
        let price = if idx < MAX_WRAPPED_CHAINS {
            self.prices[idx]
        } else {
            0
        };
        if price == 0 {
            return Err(RelayError::OraclePriceUnavailable);
        }
        Ok(BridgePrice { chain_id: chain, reference_micro_usd: price })
    }
}

// ── Operation types ───────────────────────────────────────────────────────────

/// Direction of the bridge operation.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[repr(u8)]
pub enum BridgeOpType {
    /// Extern → OMNI: lock on foreign chain, mint wrapped asset on OMNI.
    LockAndMint = 1,
    /// OMNI → Extern: burn wrapped asset on OMNI, redeem on foreign chain.
    BurnAndRedeem = 2,
}

/// Lifecycle status of a bridge operation.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[repr(u8)]
pub enum BridgeOpStatus {
    /// Initiated — waiting for relayer confirmations.
    Pending = 0,
    /// N/M relayers have confirmed.
    Confirmed = 1,
    /// Executed (mint or redeem completed).
    Executed = 2,
    /// Timeout or error — eligible for refund.
    Failed = 3,
    /// Returned to the user.
    Refunded = 4,
}

// ── Bridge operation ──────────────────────────────────────────────────────────

/// One bridge operation — either a lock→mint or a burn→redeem.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BridgeOperation {
    pub op_id: u64,
    pub op_type: BridgeOpType,
    pub status: BridgeOpStatus,

    /// The foreign chain (BTC, ETH, Liberty, …).
    pub foreign_chain: ChainId,

    /// User's address on the foreign chain (UTF-8, up to 64 bytes).
    #[serde(with = "BigArray")]
    pub foreign_addr: [u8; 64],
    pub foreign_addr_len: u8,

    /// User's address on the OMNI chain (32 bytes).
    pub omni_addr: [u8; 32],

    /// Amount in atomic units of the foreign chain (satoshis for BTC, wei for ETH).
    /// Stored as u64; for ETH wei amounts, values are scaled (e.g. micro-USD units).
    pub amount_foreign: u64,

    /// Amount in OMNI satoshis (after conversion via oracle), net of fee.
    pub amount_omni_sat: u64,

    /// Fee taken by the bridge in OMNI satoshis.
    pub fee_sat: u64,

    /// Hash of the TX on the foreign chain (proof of lock).
    pub foreign_tx_hash: [u8; 32],

    /// OMNI block at which this operation was initiated.
    pub initiated_block: u64,

    /// Signatures submitted by relayers. Not (de)serialized — sigs are
    /// kept in memory only; persistence happens in `bridge_state.json` via
    /// the relayer registry, not on the BridgeOperation row.
    #[serde(skip, default = "default_relayer_sigs")]
    pub relayer_sigs: [[u8; 64]; BRIDGE_MAX_RELAYERS],
    pub sig_count: u8,
}

impl BridgeOperation {
    /// True if the operation has exceeded `BRIDGE_TIMEOUT_BLOCKS` without being
    /// confirmed.
    pub fn is_expired(&self, current_block: u64) -> bool {
        current_block > self.initiated_block + BRIDGE_TIMEOUT_BLOCKS
    }

    /// True if enough relayer signatures have been collected.
    pub fn has_enough_sigs(&self) -> bool {
        self.sig_count >= BRIDGE_REQUIRED_SIGS
    }

    /// Fee calculation: `amount * BRIDGE_FEE_BPS / 10_000`.
    pub fn calc_fee(amount: u64) -> u64 {
        amount * BRIDGE_FEE_BPS / 10_000
    }
}

// ── Wrapped asset accounting ──────────────────────────────────────────────────

/// Tracks the total minted / burned supply of a wrapped asset on the OMNI chain
/// (e.g. wBTC, wETH).
#[derive(Debug, Clone, Copy, Default, Serialize, Deserialize)]
pub struct WrappedAsset {
    pub chain_id_index: u8,
    /// Total ever minted (= total ever locked on the foreign chain), in OMNI SAT.
    pub total_minted_sat: u64,
    /// Total ever burned (= total ever redeemed), in OMNI SAT.
    pub total_burned_sat: u64,
}

impl WrappedAsset {
    /// Currently circulating (minted − burned). Returns 0 if burned ≥ minted.
    pub fn circulating_supply(&self) -> u64 {
        self.total_minted_sat.saturating_sub(self.total_burned_sat)
    }
}

// ── Error types ───────────────────────────────────────────────────────────────

#[derive(Debug, PartialEq, Eq, Error)]
pub enum RelayError {
    #[error("oracle price unavailable for chain")]
    OraclePriceUnavailable,
    #[error("oracle price is invalid (zero)")]
    InvalidOraclePrice,
    #[error("amount too large for u64 after conversion")]
    AmountTooLarge,
    #[error("amount too small to cover bridge fee")]
    AmountTooSmall,
    #[error("operation not found (id={0})")]
    OperationNotFound(u64),
    #[error("operation is not in Pending status")]
    OperationNotPending,
    #[error("operation is not in Confirmed status")]
    OperationNotConfirmed,
    #[error("operation has not yet expired")]
    OperationNotExpired,
    #[error("operation has expired without enough confirmations")]
    OperationExpired,
    #[error("not enough relayer confirmations")]
    NotEnoughConfirmations,
    #[error("too many relayers for this operation")]
    TooManyRelayers,
    #[error("insufficient wrapped asset supply for burn")]
    InsufficientWrappedSupply,
}

// ── BridgeRelay ───────────────────────────────────────────────────────────────

/// The bridge relay manages the full lifecycle of cross-chain bridge operations.
///
/// Instantiate one per node. The relay is synchronous — all mutation is
/// `&mut self`. If you need concurrent access, wrap in a `Mutex` / `RwLock`.
pub struct BridgeRelay {
    pub operations: Vec<BridgeOperation>,
    pub next_op_id: u64,

    /// Per-chain wrapped-asset accounting (indexed by `ChainId::index()`).
    pub wrapped: [WrappedAsset; MAX_WRAPPED_CHAINS],

    /// Price oracle for foreign ↔ OMNI conversion.
    pub oracle: SimplePriceOracle,
}

impl BridgeRelay {
    pub fn new(oracle: SimplePriceOracle) -> Self {
        let mut wrapped = [WrappedAsset::default(); MAX_WRAPPED_CHAINS];
        for (i, w) in wrapped.iter_mut().enumerate() {
            w.chain_id_index = i as u8;
        }
        Self {
            operations: Vec::new(),
            next_op_id: 1,
            wrapped,
            oracle,
        }
    }

    // ── Lock-and-Mint ─────────────────────────────────────────────────────────

    /// Initiate a Lock-and-Mint operation.
    ///
    /// The user has already sent `amount_foreign` units to the lock address on
    /// `foreign_chain`. The relay fetches the oracle price, converts to OMNI
    /// satoshis, deducts the bridge fee, creates a `Pending` operation, and
    /// returns the operation ID.
    pub fn initiate_lock_mint(
        &mut self,
        foreign_chain: ChainId,
        foreign_addr: &[u8],
        omni_addr: [u8; 32],
        amount_foreign: u64,
        foreign_tx_hash: [u8; 32],
        current_block: u64,
    ) -> Result<u64, RelayError> {
        let bridge_price = self.oracle.get_bridge_price(foreign_chain)?;
        let omni_price = self.oracle.get_bridge_price(ChainId::Omni)?;

        if omni_price.reference_micro_usd == 0 {
            return Err(RelayError::InvalidOraclePrice);
        }

        // amount_omni_sat = amount_foreign * foreign_price / omni_price
        // Use u128 to avoid overflow.
        let amount_omni_sat_raw = (amount_foreign as u128)
            * (bridge_price.reference_micro_usd as u128)
            / (omni_price.reference_micro_usd as u128);

        if amount_omni_sat_raw > u64::MAX as u128 {
            return Err(RelayError::AmountTooLarge);
        }
        let amount_omni_sat = amount_omni_sat_raw as u64;

        let fee = BridgeOperation::calc_fee(amount_omni_sat);
        let amount_net = amount_omni_sat
            .checked_sub(fee)
            .filter(|&n| n > 0)
            .ok_or(RelayError::AmountTooSmall)?;

        let mut fa = [0u8; 64];
        let copy_len = foreign_addr.len().min(64);
        fa[..copy_len].copy_from_slice(&foreign_addr[..copy_len]);

        let op = BridgeOperation {
            op_id: self.next_op_id,
            op_type: BridgeOpType::LockAndMint,
            status: BridgeOpStatus::Pending,
            foreign_chain,
            foreign_addr: fa,
            foreign_addr_len: copy_len as u8,
            omni_addr,
            amount_foreign,
            amount_omni_sat: amount_net,
            fee_sat: fee,
            foreign_tx_hash,
            initiated_block: current_block,
            relayer_sigs: [[0u8; 64]; BRIDGE_MAX_RELAYERS],
            sig_count: 0,
        };

        let op_id = op.op_id;
        tracing::debug!(
            target: "bridge_relay",
            "Lock-Mint initiated: op#{} | {} {} -> OMNI {} SAT (fee={})",
            op_id, foreign_chain.name(), amount_foreign, amount_net, fee
        );

        self.operations.push(op);
        self.next_op_id += 1;
        Ok(op_id)
    }

    // ── Relayer confirmation ──────────────────────────────────────────────────

    /// Add a relayer signature to a pending operation. Once `BRIDGE_REQUIRED_SIGS`
    /// confirmations are collected the status advances to `Confirmed`.
    pub fn confirm_operation(
        &mut self,
        op_id: u64,
        relayer_sig: [u8; 64],
    ) -> Result<(), RelayError> {
        let op = self.find_operation_mut(op_id)?;

        if op.status != BridgeOpStatus::Pending {
            return Err(RelayError::OperationNotPending);
        }
        if op.sig_count as usize >= BRIDGE_MAX_RELAYERS {
            return Err(RelayError::TooManyRelayers);
        }

        op.relayer_sigs[op.sig_count as usize] = relayer_sig;
        op.sig_count += 1;

        tracing::debug!(
            target: "bridge_relay",
            "Op #{} confirmed by relayer ({}/{})",
            op_id, op.sig_count, BRIDGE_REQUIRED_SIGS
        );

        if op.has_enough_sigs() && op.status == BridgeOpStatus::Pending {
            op.status = BridgeOpStatus::Confirmed;
        }
        Ok(())
    }

    // ── Execution (mint or redeem) ────────────────────────────────────────────

    /// Execute a confirmed operation.
    ///
    /// - `LockAndMint`: increments `total_minted_sat` for the chain; returns the
    ///   minted OMNI satoshis.
    /// - `BurnAndRedeem`: decrements circulating supply; returns the foreign units
    ///   to be released.
    ///
    /// Returns `Err(OperationExpired)` for pending operations past the timeout.
    /// Returns `Err(NotEnoughConfirmations)` for pending operations still in window.
    pub fn execute_operation(
        &mut self,
        op_id: u64,
        current_block: u64,
    ) -> Result<u64, RelayError> {
        let op = self.find_operation_mut(op_id)?;

        if op.status == BridgeOpStatus::Pending {
            if op.is_expired(current_block) {
                op.status = BridgeOpStatus::Failed;
                return Err(RelayError::OperationExpired);
            }
            return Err(RelayError::NotEnoughConfirmations);
        }
        if op.status != BridgeOpStatus::Confirmed {
            return Err(RelayError::OperationNotConfirmed);
        }

        let chain_idx = op.foreign_chain.index();
        let op_type = op.op_type;
        let amount_omni = op.amount_omni_sat;
        let amount_foreign = op.amount_foreign;
        let chain_name = op.foreign_chain.name();

        match op_type {
            BridgeOpType::LockAndMint => {
                self.wrapped[chain_idx].total_minted_sat += amount_omni;
                // Update status on the op (we already have mutable access).
                let op = self.find_operation_mut(op_id).unwrap();
                op.status = BridgeOpStatus::Executed;
                tracing::debug!(
                    target: "bridge_relay",
                    "MINT: w{} {} SAT -> omni_addr", chain_name, amount_omni
                );
                Ok(amount_omni)
            }
            BridgeOpType::BurnAndRedeem => {
                let ws = &self.wrapped[chain_idx];
                if ws.circulating_supply() < amount_omni {
                    return Err(RelayError::InsufficientWrappedSupply);
                }
                self.wrapped[chain_idx].total_burned_sat += amount_omni;
                let op = self.find_operation_mut(op_id).unwrap();
                op.status = BridgeOpStatus::Executed;
                tracing::debug!(
                    target: "bridge_relay",
                    "BURN: w{} {} SAT -> redeem {} foreign units",
                    chain_name, amount_omni, amount_foreign
                );
                Ok(amount_foreign)
            }
        }
    }

    // ── Refund ────────────────────────────────────────────────────────────────

    /// Mark an expired pending operation as `Refunded`.
    pub fn refund_expired(&mut self, op_id: u64, current_block: u64) -> Result<(), RelayError> {
        let op = self.find_operation_mut(op_id)?;
        if op.status != BridgeOpStatus::Pending {
            return Err(RelayError::OperationNotPending);
        }
        if !op.is_expired(current_block) {
            return Err(RelayError::OperationNotExpired);
        }
        op.status = BridgeOpStatus::Refunded;
        tracing::debug!(target: "bridge_relay", "Op #{} REFUNDED (expired)", op_id);
        Ok(())
    }

    // ── Lookup ────────────────────────────────────────────────────────────────

    pub fn find_operation(&self, op_id: u64) -> Result<&BridgeOperation, RelayError> {
        self.operations
            .iter()
            .find(|op| op.op_id == op_id)
            .ok_or(RelayError::OperationNotFound(op_id))
    }

    fn find_operation_mut(&mut self, op_id: u64) -> Result<&mut BridgeOperation, RelayError> {
        self.operations
            .iter_mut()
            .find(|op| op.op_id == op_id)
            .ok_or(RelayError::OperationNotFound(op_id))
    }

    // ── Status display ────────────────────────────────────────────────────────

    pub fn print_status(&self) {
        tracing::info!(
            target: "bridge_relay",
            "Operations: {} | next_id: {}",
            self.operations.len(),
            self.next_op_id
        );
        for w in &self.wrapped {
            if w.total_minted_sat > 0 {
                tracing::info!(
                    target: "bridge_relay",
                    "  chain[{}]: minted={} burned={} circulating={}",
                    w.chain_id_index,
                    w.total_minted_sat,
                    w.total_burned_sat,
                    w.circulating_supply()
                );
            }
        }
    }
}

// ── Tests ─────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    fn setup_oracle() -> SimplePriceOracle {
        let mut oracle = SimplePriceOracle::new();
        // OMNI = $10  → 10_000_000 micro-USD
        oracle.set_price(ChainId::Omni, 10_000_000);
        // BTC = $50,000 → 50_000_000_000 micro-USD
        oracle.set_price(ChainId::Btc, 50_000_000_000);
        // ETH = $3,000  → 3_000_000_000 micro-USD
        oracle.set_price(ChainId::Eth, 3_000_000_000);
        oracle
    }

    fn new_relay() -> BridgeRelay {
        BridgeRelay::new(setup_oracle())
    }

    #[test]
    fn fee_calculated_correctly() {
        // 10 BPS = 0.1% of 1_000_000 = 1_000
        assert_eq!(BridgeOperation::calc_fee(1_000_000), 1_000);
    }

    #[test]
    fn is_expired_after_timeout_blocks() {
        let op = BridgeOperation {
            op_id: 1,
            op_type: BridgeOpType::LockAndMint,
            status: BridgeOpStatus::Pending,
            foreign_chain: ChainId::Btc,
            foreign_addr: [0u8; 64],
            foreign_addr_len: 0,
            omni_addr: [0u8; 32],
            amount_foreign: 0,
            amount_omni_sat: 0,
            fee_sat: 0,
            foreign_tx_hash: [0u8; 32],
            initiated_block: 100,
            relayer_sigs: [[0u8; 64]; BRIDGE_MAX_RELAYERS],
            sig_count: 0,
        };
        assert!(!op.is_expired(150));
        assert!(!op.is_expired(200));
        assert!(op.is_expired(201));
    }

    #[test]
    fn init_ok() {
        let relay = new_relay();
        assert_eq!(relay.next_op_id, 1);
        assert_eq!(relay.operations.len(), 0);
    }

    #[test]
    fn initiate_lock_mint_creates_operation() {
        let mut relay = new_relay();
        let omni_addr = [0xAAu8; 32];
        let tx_hash = [0x11u8; 32];

        let op_id = relay
            .initiate_lock_mint(
                ChainId::Btc,
                b"1BvBMSEYstWetqTFn5Au4m4GFg7xJaNVN2",
                omni_addr,
                100_000_000, // 1 BTC in satoshis
                tx_hash,
                1_000,
            )
            .unwrap();

        assert_eq!(op_id, 1);
        assert_eq!(relay.operations.len(), 1);
        assert_eq!(relay.next_op_id, 2);

        let op = relay.find_operation(1).unwrap();
        assert_eq!(op.status, BridgeOpStatus::Pending);
        assert_eq!(op.foreign_chain, ChainId::Btc);
    }

    #[test]
    fn confirm_and_execute() {
        let mut relay = new_relay();
        let omni_addr = [0xAAu8; 32];

        // ETH amount in micro-USD-scaled units.
        let op_id = relay
            .initiate_lock_mint(
                ChainId::Eth,
                b"0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045",
                omni_addr,
                3_000_000_000, // $3 000 in micro-USD
                [0x22u8; 32],
                1_000,
            )
            .unwrap();

        relay.confirm_operation(op_id, [0x01u8; 64]).unwrap();
        relay.confirm_operation(op_id, [0x02u8; 64]).unwrap();

        // After 2 confirmations → Confirmed.
        assert_eq!(
            relay.find_operation(op_id).unwrap().status,
            BridgeOpStatus::Confirmed
        );

        let minted = relay.execute_operation(op_id, 1_001).unwrap();
        assert!(minted > 0);
        assert_eq!(
            relay.find_operation(op_id).unwrap().status,
            BridgeOpStatus::Executed
        );
    }

    #[test]
    fn execute_without_confirmations_returns_error() {
        let mut relay = new_relay();
        let op_id = relay
            .initiate_lock_mint(
                ChainId::Btc,
                b"1BvBMSEYstWetqTFn5Au4m4GFg7xJaNVN2",
                [0xAAu8; 32],
                100_000_000,
                [0x11u8; 32],
                1_000,
            )
            .unwrap();

        let err = relay.execute_operation(op_id, 1_001).unwrap_err();
        assert_eq!(err, RelayError::NotEnoughConfirmations);
    }

    #[test]
    fn refund_after_expiry() {
        let mut relay = new_relay();
        let op_id = relay
            .initiate_lock_mint(
                ChainId::Btc,
                b"1BvBMSEYstWetqTFn5Au4m4GFg7xJaNVN2",
                [0xAAu8; 32],
                100_000_000,
                [0x11u8; 32],
                1_000,
            )
            .unwrap();

        // Before expiry.
        let err = relay.refund_expired(op_id, 1_050).unwrap_err();
        assert_eq!(err, RelayError::OperationNotExpired);

        // After expiry (initiated=1000, timeout=100 → expires at block 1101).
        relay.refund_expired(op_id, 1_200).unwrap();
        assert_eq!(
            relay.find_operation(op_id).unwrap().status,
            BridgeOpStatus::Refunded
        );
    }

    #[test]
    fn expired_execute_marks_failed() {
        let mut relay = new_relay();
        let op_id = relay
            .initiate_lock_mint(
                ChainId::Btc,
                b"addr",
                [0u8; 32],
                100_000_000,
                [0u8; 32],
                1_000,
            )
            .unwrap();

        let err = relay.execute_operation(op_id, 2_000).unwrap_err();
        assert_eq!(err, RelayError::OperationExpired);
        assert_eq!(
            relay.find_operation(op_id).unwrap().status,
            BridgeOpStatus::Failed
        );
    }

    #[test]
    fn wrapped_asset_supply_tracking() {
        let relay = new_relay();
        let btc_idx = ChainId::Btc.index();
        assert_eq!(relay.wrapped[btc_idx].circulating_supply(), 0);

        let mut relay = relay;
        relay.wrapped[btc_idx].total_minted_sat = 1_000_000;
        relay.wrapped[btc_idx].total_burned_sat = 300_000;
        assert_eq!(relay.wrapped[btc_idx].circulating_supply(), 700_000);
    }

    #[test]
    fn oracle_price_unavailable_rejects_initiation() {
        let oracle = SimplePriceOracle::new(); // no prices set
        let mut relay = BridgeRelay::new(oracle);

        let err = relay
            .initiate_lock_mint(ChainId::Btc, b"addr", [0u8; 32], 100, [0u8; 32], 1)
            .unwrap_err();
        assert_eq!(err, RelayError::OraclePriceUnavailable);
    }

    #[test]
    fn bridge_price_conversion_btc_to_omni() {
        // BTC=$50k, OMNI=$10 → 1 BTC (100_000_000 sat) should become
        // 50_000 OMNI sat (minus 0.1% fee).
        // Actually: 100_000_000 * 50_000_000_000 / 10_000_000 = 500_000_000_000 raw OMNI sat
        // fee = 500_000_000_000 * 10 / 10_000 = 500_000_000
        // net = 500_000_000_000 - 500_000_000 = 499_500_000_000
        let mut relay = new_relay();
        let op_id = relay
            .initiate_lock_mint(
                ChainId::Btc,
                b"addr",
                [0u8; 32],
                100_000_000,
                [0u8; 32],
                1_000,
            )
            .unwrap();
        let op = relay.find_operation(op_id).unwrap();
        assert_eq!(op.fee_sat, 500_000_000);
        assert_eq!(op.amount_omni_sat, 499_500_000_000);
    }
}
