//! matching_engine.rs — Multi-pair central limit order book.
//!
//! This module wraps the low-level `matching.rs` engine and exposes the
//! Zig-spec surface described in the port task:
//!
//!   - `OrderBook`  per pair (bids DESC, asks ASC, price-time FIFO)
//!   - `MultiPairEngine` — HashMap<pair_id, MatchingEngine>
//!   - `place_order(pair_id, side, price, amount, trader)` → (order_id, fills[])
//!   - `cancel_order(pair_id, order_id, trader)` → bool
//!   - Fee schedule: 10 bps taker, 5 bps maker
//!
//! The actual matching logic lives in `matching.rs` (MatchingEngine). This
//! module is the pair-dispatching façade on top of it.

use std::collections::HashMap;

use super::matching::{Fill, MatchingEngine, MatchingError};
use super::order::{Order, OrderId, Side};

// ─── Fee constants (basis points) ────────────────────────────────────────────

/// Taker fee: 10 bps (0.10 %)
pub const TAKER_FEE_BPS: u64 = 10;
/// Maker fee:  5 bps (0.05 %)
pub const MAKER_FEE_BPS: u64 = 5;
/// One basis point denominator
pub const BPS_DENOM: u64 = 10_000;

/// Compute fee for a given amount and bps rate.
#[inline]
pub fn compute_fee(amount_sat: u64, bps: u64) -> u64 {
    amount_sat.saturating_mul(bps) / BPS_DENOM
}

// ─── OrderBook ────────────────────────────────────────────────────────────────

/// Per-pair order book delegate. Thin wrapper so callers can hold a named type.
/// All matching work is delegated to the inner `MatchingEngine`.
pub struct OrderBook {
    pub pair_id: u16,
    pub engine: MatchingEngine,
}

impl OrderBook {
    pub fn new(pair_id: u16) -> Self {
        Self {
            pair_id,
            engine: MatchingEngine::new(),
        }
    }

    /// Place an order into this order book.
    /// Returns the assigned `OrderId`.
    pub fn place(&mut self, order: Order) -> Result<OrderId, MatchingError> {
        self.engine.place_order(order)
    }

    /// Cancel by order_id. Returns `true` if removed.
    pub fn cancel(&mut self, order_id: OrderId) -> bool {
        self.engine.cancel_order(order_id).is_ok()
    }

    pub fn best_bid(&self) -> Option<u64> {
        self.engine.best_bid(self.pair_id)
    }

    pub fn best_ask(&self) -> Option<u64> {
        self.engine.best_ask(self.pair_id)
    }

    pub fn spread(&self) -> Option<u64> {
        self.engine.spread(self.pair_id)
    }

    pub fn order_count(&self) -> usize {
        self.engine.order_count()
    }

    pub fn drain_fills(&mut self) -> Vec<Fill> {
        let f = self.engine.fills.clone();
        self.engine.clear_fills();
        f
    }
}

// ─── MultiPairEngine ─────────────────────────────────────────────────────────

/// Central limit order book that dispatches across N trading pairs.
///
/// Mirrors the Zig `MatchingEngine` struct (which wraps the per-pair book in
/// a HashMap). The actual price-time priority matching is delegated to the
/// inner per-pair `MatchingEngine`.
#[derive(Default)]
pub struct MultiPairEngine {
    books: HashMap<u16, MatchingEngine>,
    next_order_id: u64,
}

impl MultiPairEngine {
    pub fn new() -> Self {
        Self {
            books: HashMap::new(),
            next_order_id: 1,
        }
    }

    /// Place an order into the matching engine.
    ///
    /// Returns `(order_id, fills)`. The fills slice is the list of matches
    /// produced by this order (taker fills). Remaining quantity (if any) rests
    /// in the book as a maker order.
    pub fn place_order(
        &mut self,
        pair_id: u16,
        side: Side,
        price_micro_usd: u64,
        amount_sat: u64,
        trader: Vec<u8>,
    ) -> Result<(OrderId, Vec<Fill>), MatchingError> {
        let order = Order::new(trader, pair_id, side, price_micro_usd, amount_sat, now_ms());
        let book = self.books.entry(pair_id).or_insert_with(MatchingEngine::new);
        let old_fill_count = book.fills.len();
        let oid = book.place_order(order)?;
        let new_fills: Vec<Fill> = book.fills[old_fill_count..].to_vec();
        Ok((oid, new_fills))
    }

    /// Cancel a resting order by its ID.
    /// Returns `true` if the order was found and removed.
    pub fn cancel_order(&mut self, pair_id: u16, order_id: OrderId, _trader: &[u8]) -> bool {
        if let Some(book) = self.books.get_mut(&pair_id) {
            book.cancel_order(order_id).is_ok()
        } else {
            false
        }
    }

    /// Drain and return all fills for a pair since the last drain.
    pub fn drain_fills(&mut self, pair_id: u16) -> Vec<Fill> {
        let book = self.books.entry(pair_id).or_insert_with(MatchingEngine::new);
        let f = book.fills.clone();
        book.clear_fills();
        f
    }

    pub fn best_bid(&self, pair_id: u16) -> Option<u64> {
        self.books.get(&pair_id)?.best_bid(pair_id)
    }

    pub fn best_ask(&self, pair_id: u16) -> Option<u64> {
        self.books.get(&pair_id)?.best_ask(pair_id)
    }

    pub fn order_count(&self, pair_id: u16) -> usize {
        self.books
            .get(&pair_id)
            .map(|b| b.order_count_for_pair(pair_id))
            .unwrap_or(0)
    }

    /// Get a reference to the inner book for a pair (creates empty if absent).
    pub fn book_mut(&mut self, pair_id: u16) -> &mut MatchingEngine {
        self.books.entry(pair_id).or_insert_with(MatchingEngine::new)
    }

    pub fn book(&self, pair_id: u16) -> Option<&MatchingEngine> {
        self.books.get(&pair_id)
    }

    /// Look up a resting order by its ID across all pairs.
    /// Returns `None` if the order has already been filled/cancelled or does
    /// not exist. Mirrors `MatchingEngine.getOrder` in Zig.
    pub fn get_order(&self, order_id: u64) -> Option<&super::order::Order> {
        for book in self.books.values() {
            if let Some(o) = book.get_order(order_id) {
                return Some(o);
            }
        }
        None
    }

    /// Total resting orders for `pair_id` (bids + asks).
    /// Delegates to `MatchingEngine::order_count_for_pair`.
    pub fn order_count_for_pair(&self, pair_id: u16) -> usize {
        self.books
            .get(&pair_id)
            .map(|b| b.order_count_for_pair(pair_id))
            .unwrap_or(0)
    }

    /// Spread (ask − bid) for `pair_id`. Returns `None` if either side is empty.
    pub fn spread(&self, pair_id: u16) -> Option<u64> {
        self.books.get(&pair_id)?.spread(pair_id)
    }

    /// Deterministic SHA-256 Merkle root of the `pair_id` order book.
    /// All miners produce the same root for the same input.
    /// Returns `[0u8; 32]` if the pair has no open orders.
    pub fn orderbook_merkle_root(&self, pair_id: u16) -> [u8; 32] {
        self.books
            .get(&pair_id)
            .map(|b| b.orderbook_merkle_root())
            .unwrap_or([0u8; 32])
    }

    /// Compute taker fee for a fill amount using `TAKER_FEE_BPS`.
    /// Mirrors the fee model described in the Zig spec comment:
    /// `TAKER_FEE_BPS = 10` → 0.10 %.
    #[inline]
    pub fn taker_fee(&self, amount_sat: u64) -> u64 {
        compute_fee(amount_sat, TAKER_FEE_BPS)
    }

    /// Compute maker fee for a fill amount using `MAKER_FEE_BPS`.
    /// `MAKER_FEE_BPS = 5` → 0.05 %.
    #[inline]
    pub fn maker_fee(&self, amount_sat: u64) -> u64 {
        compute_fee(amount_sat, MAKER_FEE_BPS)
    }

    /// Place an order and return `(order_id, fills, taker_fee_sat, maker_fee_sat)`.
    ///
    /// Extends `place_order` with the fee schedule from the Zig spec:
    ///   - taker (incoming order) pays `TAKER_FEE_BPS` on the total filled qty.
    ///   - maker (resting order) pays `MAKER_FEE_BPS` per-fill.
    ///
    /// Fee amounts are returned for the caller to record in chain state.
    /// They are NOT deducted from the fill amounts (same as Zig — fees are
    /// a separate ledger entry).
    pub fn place_order_with_fees(
        &mut self,
        pair_id: u16,
        side: super::order::Side,
        price_micro_usd: u64,
        amount_sat: u64,
        trader: Vec<u8>,
    ) -> Result<(u64, Vec<Fill>, u64, u64), MatchingError> {
        let (oid, fills) =
            self.place_order(pair_id, side, price_micro_usd, amount_sat, trader)?;

        // Total taker fee: 10 bps on total filled quantity.
        let total_filled: u64 = fills.iter().map(|f| f.amount_sat).sum();
        let taker_fee = compute_fee(total_filled, TAKER_FEE_BPS);

        // Total maker fee: 5 bps per fill (charged to each resting order).
        let maker_fee: u64 = fills
            .iter()
            .map(|f| compute_fee(f.amount_sat, MAKER_FEE_BPS))
            .sum();

        Ok((oid, fills, taker_fee, maker_fee))
    }

    /// Iterate over all active pairs (those with at least one resting order).
    pub fn active_pair_ids(&self) -> Vec<u16> {
        self.books
            .iter()
            .filter(|(_, b)| b.order_count() > 0)
            .map(|(&id, _)| id)
            .collect()
    }

    /// Total resting orders across all pairs.
    pub fn total_order_count(&self) -> usize {
        self.books.values().map(|b| b.order_count()).sum()
    }
}

// ─── Helpers ──────────────────────────────────────────────────────────────────

fn now_ms() -> i64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

// ─── Tests ────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    fn mk(addr: &[u8], side: Side, price: u64, amount: u64) -> (Side, u64, u64, Vec<u8>) {
        (side, price, amount, addr.to_vec())
    }

    #[test]
    fn place_buy_sell_same_price_fills() {
        let mut e = MultiPairEngine::new();
        // First place sell (resting ask)
        let (_, fills) = e
            .place_order(0, Side::Sell, 100_000, 1_000_000, b"alice".to_vec())
            .unwrap();
        assert!(fills.is_empty(), "sell rests in book");

        // Then buy at same price → immediate fill
        let (_, fills) = e
            .place_order(0, Side::Buy, 100_000, 1_000_000, b"bob".to_vec())
            .unwrap();
        assert_eq!(fills.len(), 1);
        assert_eq!(fills[0].amount_sat, 1_000_000);
        assert_eq!(fills[0].price_micro_usd, 100_000);
        // Book should be empty
        assert_eq!(e.order_count(0), 0);
    }

    #[test]
    fn partial_fill_remainder_rests() {
        let mut e = MultiPairEngine::new();
        // Sell 1_000 sat
        e.place_order(0, Side::Sell, 100_000, 1_000, b"alice".to_vec())
            .unwrap();
        // Buy 2_000 sat — only 1_000 match, 1_000 rests as bid
        let (_, fills) = e
            .place_order(0, Side::Buy, 100_000, 2_000, b"bob".to_vec())
            .unwrap();
        assert_eq!(fills.len(), 1);
        assert_eq!(fills[0].amount_sat, 1_000);
        // Remaining bid in book
        assert_eq!(e.order_count(0), 1);
        assert_eq!(e.best_bid(0), Some(100_000));
    }

    #[test]
    fn cancel_resting_order() {
        let mut e = MultiPairEngine::new();
        let (oid, _) = e
            .place_order(0, Side::Sell, 100_000, 500, b"alice".to_vec())
            .unwrap();
        assert_eq!(e.order_count(0), 1);
        assert!(e.cancel_order(0, oid, b"alice"));
        assert_eq!(e.order_count(0), 0);
    }

    #[test]
    fn cancel_unknown_order_returns_false() {
        let mut e = MultiPairEngine::new();
        assert!(!e.cancel_order(0, 9999, b"x"));
    }

    #[test]
    fn fee_constants_correct() {
        // 1_000_000 sat × 10 bps = 1_000 sat taker fee
        assert_eq!(compute_fee(1_000_000, TAKER_FEE_BPS), 1_000);
        // 1_000_000 sat × 5 bps = 500 sat maker fee
        assert_eq!(compute_fee(1_000_000, MAKER_FEE_BPS), 500);
    }

    #[test]
    fn order_book_wrapper_delegates() {
        let mut ob = OrderBook::new(0);
        let order = Order::new(b"alice".to_vec(), 0, Side::Sell, 100_000, 500, 1);
        let oid = ob.place(order).unwrap();
        assert_eq!(ob.order_count(), 1);
        assert_eq!(ob.best_ask(), Some(100_000));
        assert!(ob.cancel(oid));
        assert_eq!(ob.order_count(), 0);
    }

    // ── New: MultiPairEngine extensions ──────────────────────────────────────

    #[test]
    fn get_order_finds_resting_order() {
        let mut e = MultiPairEngine::new();
        let (oid, fills) = e
            .place_order(0, Side::Sell, 100_000, 500, b"alice".to_vec())
            .unwrap();
        assert!(fills.is_empty());
        let o = e.get_order(oid);
        assert!(o.is_some());
        assert_eq!(o.unwrap().price_micro_usd, 100_000);
    }

    #[test]
    fn get_order_returns_none_after_fill() {
        let mut e = MultiPairEngine::new();
        let (sell_oid, _) = e
            .place_order(0, Side::Sell, 100_000, 500, b"alice".to_vec())
            .unwrap();
        // Match the sell completely
        let (_buy_oid, fills) = e
            .place_order(0, Side::Buy, 100_000, 500, b"bob".to_vec())
            .unwrap();
        assert_eq!(fills.len(), 1);
        // Filled order is removed from book
        assert!(e.get_order(sell_oid).is_none());
    }

    #[test]
    fn spread_is_ask_minus_bid() {
        let mut e = MultiPairEngine::new();
        e.place_order(0, Side::Sell, 110_000, 1_000, b"alice".to_vec())
            .unwrap();
        e.place_order(0, Side::Buy, 90_000, 1_000, b"bob".to_vec())
            .unwrap();
        assert_eq!(e.spread(0), Some(20_000));
    }

    #[test]
    fn spread_none_when_empty() {
        let e = MultiPairEngine::new();
        assert!(e.spread(0).is_none());
    }

    #[test]
    fn orderbook_merkle_root_deterministic() {
        // Same engine, two reads → must produce the same root. We can't
        // compare two SEPARATE engines because `Order::new` stamps wall-clock
        // `timestamp_ms` and that's part of the hash (intentional: it breaks
        // FIFO ties at the same price). Determinism therefore means
        // "stable for a given engine state", which is the property the
        // chain hashes anyway.
        let mut e = MultiPairEngine::new();
        e.place_order(0, Side::Sell, 110_000, 100, b"a".to_vec()).unwrap();
        e.place_order(0, Side::Buy, 90_000, 100, b"b".to_vec()).unwrap();
        let r1 = e.orderbook_merkle_root(0);
        let r2 = e.orderbook_merkle_root(0);
        assert_eq!(r1, r2);
        // And the root must change when state changes.
        e.place_order(0, Side::Buy, 95_000, 50, b"c".to_vec()).unwrap();
        assert_ne!(e.orderbook_merkle_root(0), r1);
    }

    #[test]
    fn orderbook_merkle_root_empty_pair_is_zero() {
        let e = MultiPairEngine::new();
        assert_eq!(e.orderbook_merkle_root(99), [0u8; 32]);
    }

    #[test]
    fn place_order_with_fees_returns_fee_amounts() {
        let mut e = MultiPairEngine::new();
        // Place sell (resting maker)
        e.place_order(0, Side::Sell, 100_000, 1_000_000, b"alice".to_vec())
            .unwrap();
        // Buy → immediate fill
        let (_, fills, taker_fee, maker_fee) = e
            .place_order_with_fees(0, Side::Buy, 100_000, 1_000_000, b"bob".to_vec())
            .unwrap();
        assert_eq!(fills.len(), 1);
        assert_eq!(fills[0].amount_sat, 1_000_000);
        // Taker: 10 bps of 1_000_000 = 1_000
        assert_eq!(taker_fee, 1_000);
        // Maker: 5 bps of 1_000_000 = 500
        assert_eq!(maker_fee, 500);
    }

    #[test]
    fn place_order_with_fees_no_fill_zero_fees() {
        let mut e = MultiPairEngine::new();
        let (_, fills, taker_fee, maker_fee) = e
            .place_order_with_fees(0, Side::Buy, 50_000, 1_000_000, b"bob".to_vec())
            .unwrap();
        assert!(fills.is_empty());
        assert_eq!(taker_fee, 0);
        assert_eq!(maker_fee, 0);
    }

    #[test]
    fn order_count_for_pair_vs_total() {
        let mut e = MultiPairEngine::new();
        e.place_order(0, Side::Sell, 100, 1, b"a".to_vec()).unwrap();
        e.place_order(0, Side::Sell, 101, 1, b"b".to_vec()).unwrap();
        e.place_order(2, Side::Buy, 50, 1, b"c".to_vec()).unwrap();
        assert_eq!(e.order_count_for_pair(0), 2);
        assert_eq!(e.order_count_for_pair(2), 1);
        assert_eq!(e.total_order_count(), 3);
    }

    #[test]
    fn active_pair_ids_lists_pairs_with_resting_orders() {
        let mut e = MultiPairEngine::new();
        e.place_order(0, Side::Sell, 100, 1, b"a".to_vec()).unwrap();
        e.place_order(3, Side::Buy, 50, 1, b"b".to_vec()).unwrap();
        let mut ids = e.active_pair_ids();
        ids.sort();
        assert_eq!(ids, vec![0, 3]);
    }

    #[test]
    fn taker_maker_fee_helpers() {
        let e = MultiPairEngine::new();
        assert_eq!(e.taker_fee(1_000_000), 1_000);
        assert_eq!(e.maker_fee(1_000_000), 500);
        assert_eq!(e.taker_fee(0), 0);
    }

    #[test]
    fn multi_pair_isolation() {
        let mut e = MultiPairEngine::new();
        // Sell on pair 0 should NOT match a buy on pair 5
        e.place_order(0, Side::Sell, 100_000, 500, b"alice".to_vec())
            .unwrap();
        let (_, fills) = e
            .place_order(5, Side::Buy, 100_000, 500, b"bob".to_vec())
            .unwrap();
        assert!(fills.is_empty(), "different pairs must not match");
        assert_eq!(e.order_count(0), 1);
        assert_eq!(e.order_count(5), 1);
    }
}
