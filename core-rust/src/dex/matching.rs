//! Price-time priority matching engine.
//!
//! Mirrors `core/matching_engine.zig` (deterministic — same input order →
//! same output on every node). Differences from Zig:
//!   - Uses `Vec<Order>` instead of fixed-size arrays (still O(N) inserts/
//!     scans, same algorithmic complexity).
//!   - Self-trade is ALLOWED (per Zig 2026-04-28 founder decision).
//!   - Reserved pairs (1, 4) are rejected at `place_order`.

use sha2::{Digest, Sha256};
use thiserror::Error;

use super::order::{Order, OrderId, OrderStatus, Side};
use super::pair::is_reserved_pair;

pub const MAX_ORDERS: usize = 10_000;
pub const MAX_FILLS: usize = 1_000;
pub const MAX_PAIRS: u16 = 64;

#[derive(Debug, Error)]
pub enum MatchingError {
    #[error("orderbook full")]
    OrderbookFull,
    #[error("fill buffer full")]
    FillBufferFull,
    #[error("order not found")]
    OrderNotFound,
    #[error("invalid price")]
    InvalidPrice,
    #[error("invalid amount")]
    InvalidAmount,
    #[error("invalid pair")]
    InvalidPair,
    #[error("reserved pair (1 BTC/USDC, 4 OMNI/BTC are not listed yet)")]
    ReservedPair,
}

/// A fill — the result of two orders matching.
#[derive(Debug, Clone)]
pub struct Fill {
    pub fill_id: u64,
    pub buy_order_id: OrderId,
    pub sell_order_id: OrderId,
    pub price_micro_usd: u64,
    pub amount_sat: u64,
    pub timestamp_ms: i64,
    pub pair_id: u16,
    pub buyer_address: Vec<u8>,
    pub seller_address: Vec<u8>,
    pub seller_evm: [u8; 20],
    pub evm_order_id: u64,
}

#[derive(Debug, Default)]
pub struct MatchingEngine {
    /// Bids sorted DESC by price, FIFO at same price (older timestamp first).
    bids: Vec<Order>,
    /// Asks sorted ASC by price, FIFO at same price.
    asks: Vec<Order>,
    /// Fills produced in the current sub-block.
    pub fills: Vec<Fill>,
    next_order_id: u64,
    next_fill_id: u64,
}

impl MatchingEngine {
    pub fn new() -> Self {
        Self {
            bids: Vec::new(),
            asks: Vec::new(),
            fills: Vec::new(),
            next_order_id: 1,
            next_fill_id: 1,
        }
    }

    /// Place an order: match first, then insert remainder into the book.
    /// Returns the assigned order_id.
    pub fn place_order(&mut self, mut order: Order) -> Result<OrderId, MatchingError> {
        if order.price_micro_usd == 0 {
            return Err(MatchingError::InvalidPrice);
        }
        if order.amount_sat == 0 {
            return Err(MatchingError::InvalidAmount);
        }
        if order.pair_id >= MAX_PAIRS {
            return Err(MatchingError::InvalidPair);
        }
        if is_reserved_pair(order.pair_id) {
            return Err(MatchingError::ReservedPair);
        }

        order.order_id = self.next_order_id;
        self.next_order_id += 1;
        order.status = OrderStatus::Active;
        order.filled_sat = 0;
        let assigned_id = order.order_id;

        self.match_order(&mut order);

        let pair_id_for_event = order.pair_id;
        if order.remaining_sat() > 0 {
            if order.filled_sat > 0 {
                order.status = OrderStatus::Partial;
            }
            match order.side {
                Side::Buy => self.insert_bid(order)?,
                Side::Sell => self.insert_ask(order)?,
            }
        }
        // WS event — OrderbookUpdate snapshot. No-op outside a WS context.
        let best_bid = self.best_bid(pair_id_for_event).unwrap_or(0);
        let best_ask = self.best_ask(pair_id_for_event).unwrap_or(0);
        let spread = self.spread(pair_id_for_event).unwrap_or(0);
        let count = self.order_count_for_pair(pair_id_for_event) as u32;
        crate::ws::try_broadcast(crate::ws::Event::OrderbookUpdate {
            pair_id: pair_id_for_event as u32,
            pair: format!("pair_{}", pair_id_for_event),
            best_bid,
            best_ask,
            spread,
            order_count: count,
            height: 0,
        });
        Ok(assigned_id)
    }

    /// Cancel an order by ID. Removes from the book.
    pub fn cancel_order(&mut self, order_id: OrderId) -> Result<(), MatchingError> {
        if let Some(i) = self.bids.iter().position(|o| o.order_id == order_id) {
            self.bids.remove(i);
            return Ok(());
        }
        if let Some(i) = self.asks.iter().position(|o| o.order_id == order_id) {
            self.asks.remove(i);
            return Ok(());
        }
        Err(MatchingError::OrderNotFound)
    }

    pub fn clear_fills(&mut self) {
        self.fills.clear();
    }

    pub fn best_bid(&self, pair_id: u16) -> Option<u64> {
        self.bids
            .iter()
            .find(|o| o.pair_id == pair_id)
            .map(|o| o.price_micro_usd)
    }

    pub fn best_ask(&self, pair_id: u16) -> Option<u64> {
        self.asks
            .iter()
            .find(|o| o.pair_id == pair_id)
            .map(|o| o.price_micro_usd)
    }

    pub fn spread(&self, pair_id: u16) -> Option<u64> {
        let bb = self.best_bid(pair_id)?;
        let ba = self.best_ask(pair_id)?;
        Some(if ba <= bb { 0 } else { ba - bb })
    }

    pub fn order_count(&self) -> usize {
        self.bids.len() + self.asks.len()
    }

    pub fn order_count_for_pair(&self, pair_id: u16) -> usize {
        self.bids.iter().filter(|o| o.pair_id == pair_id).count()
            + self.asks.iter().filter(|o| o.pair_id == pair_id).count()
    }

    pub fn get_order(&self, order_id: OrderId) -> Option<&Order> {
        self.bids
            .iter()
            .find(|o| o.order_id == order_id)
            .or_else(|| self.asks.iter().find(|o| o.order_id == order_id))
    }

    /// Deterministic SHA-256 of the orderbook state. Every miner produces
    /// the same root for the same input. Layout matches Zig exactly.
    pub fn orderbook_merkle_root(&self) -> [u8; 32] {
        let mut h = Sha256::new();
        for o in &self.bids {
            Self::hash_order(&mut h, o);
        }
        h.update([0xFF, 0xFF, 0xFF, 0xFF]);
        for o in &self.asks {
            Self::hash_order(&mut h, o);
        }
        let mut out = [0u8; 32];
        out.copy_from_slice(&h.finalize());
        out
    }

    // ─── Private ─────────────────────────────────────────────────────────

    fn match_order(&mut self, order: &mut Order) {
        match order.side {
            Side::Buy => self.match_buy(order),
            Side::Sell => self.match_sell(order),
        }
    }

    fn match_buy(&mut self, buy: &mut Order) {
        let mut i = 0;
        while i < self.asks.len() && buy.remaining_sat() > 0 {
            if self.asks[i].price_micro_usd > buy.price_micro_usd {
                break;
            }
            if self.asks[i].pair_id != buy.pair_id {
                i += 1;
                continue;
            }
            if self.fills.len() >= MAX_FILLS {
                break;
            }
            // Self-trade ALLOWED (per Zig 2026-04-28 founder decision).
            let ask_remaining = self.asks[i].remaining_sat();
            let fill_amount = buy.remaining_sat().min(ask_remaining);
            let exec_price = self.asks[i].price_micro_usd;

            self.record_fill_buy(buy, i, exec_price, fill_amount);

            buy.filled_sat += fill_amount;
            self.asks[i].filled_sat += fill_amount;
            if self.asks[i].remaining_sat() == 0 {
                self.asks[i].status = OrderStatus::Filled;
                self.asks.remove(i);
                // don't advance i — next entry shifted into slot
            } else {
                self.asks[i].status = OrderStatus::Partial;
                i += 1;
            }
        }
        if buy.remaining_sat() == 0 {
            buy.status = OrderStatus::Filled;
        }
    }

    fn match_sell(&mut self, sell: &mut Order) {
        let mut i = 0;
        while i < self.bids.len() && sell.remaining_sat() > 0 {
            if self.bids[i].price_micro_usd < sell.price_micro_usd {
                break;
            }
            if self.bids[i].pair_id != sell.pair_id {
                i += 1;
                continue;
            }
            if self.fills.len() >= MAX_FILLS {
                break;
            }
            let bid_remaining = self.bids[i].remaining_sat();
            let fill_amount = sell.remaining_sat().min(bid_remaining);
            let exec_price = self.bids[i].price_micro_usd;

            self.record_fill_sell(sell, i, exec_price, fill_amount);

            sell.filled_sat += fill_amount;
            self.bids[i].filled_sat += fill_amount;
            if self.bids[i].remaining_sat() == 0 {
                self.bids[i].status = OrderStatus::Filled;
                self.bids.remove(i);
            } else {
                self.bids[i].status = OrderStatus::Partial;
                i += 1;
            }
        }
        if sell.remaining_sat() == 0 {
            sell.status = OrderStatus::Filled;
        }
    }

    fn record_fill_buy(&mut self, buy: &Order, ask_idx: usize, exec_price: u64, amount: u64) {
        let ask = &self.asks[ask_idx];
        let fill = Fill {
            fill_id: self.next_fill_id,
            buy_order_id: buy.order_id,
            sell_order_id: ask.order_id,
            price_micro_usd: exec_price,
            amount_sat: amount,
            timestamp_ms: buy.timestamp_ms.max(ask.timestamp_ms),
            pair_id: buy.pair_id,
            buyer_address: buy.trader_address.clone(),
            seller_address: ask.trader_address.clone(),
            seller_evm: ask.seller_evm,
            evm_order_id: buy.evm_order_id,
        };
        self.next_fill_id += 1;
        let pair_str = format!("pair_{}", fill.pair_id);
        crate::ws::try_broadcast(crate::ws::Event::NewTrade {
            pair_id: fill.pair_id as u32,
            pair: pair_str.clone(),
            price_sat: fill.price_micro_usd,
            qty_sat: fill.amount_sat,
            side: "buy".to_string(),
            height: 0,
            timestamp: fill.timestamp_ms / 1000,
        });
        crate::ws::try_broadcast(crate::ws::Event::OrderFilled {
            order_id: fill.buy_order_id,
            pair_id: fill.pair_id as u32,
            pair: pair_str,
            price_sat: fill.price_micro_usd,
            filled_qty_sat: fill.amount_sat,
            side: "buy".to_string(),
            height: 0,
        });
        self.fills.push(fill);
    }

    fn record_fill_sell(&mut self, sell: &Order, bid_idx: usize, exec_price: u64, amount: u64) {
        let bid = &self.bids[bid_idx];
        let fill = Fill {
            fill_id: self.next_fill_id,
            buy_order_id: bid.order_id,
            sell_order_id: sell.order_id,
            price_micro_usd: exec_price,
            amount_sat: amount,
            timestamp_ms: bid.timestamp_ms.max(sell.timestamp_ms),
            pair_id: sell.pair_id,
            buyer_address: bid.trader_address.clone(),
            seller_address: sell.trader_address.clone(),
            seller_evm: sell.seller_evm,
            evm_order_id: bid.evm_order_id,
        };
        self.next_fill_id += 1;
        let pair_str = format!("pair_{}", fill.pair_id);
        crate::ws::try_broadcast(crate::ws::Event::NewTrade {
            pair_id: fill.pair_id as u32,
            pair: pair_str.clone(),
            price_sat: fill.price_micro_usd,
            qty_sat: fill.amount_sat,
            side: "sell".to_string(),
            height: 0,
            timestamp: fill.timestamp_ms / 1000,
        });
        crate::ws::try_broadcast(crate::ws::Event::OrderFilled {
            order_id: fill.sell_order_id,
            pair_id: fill.pair_id as u32,
            pair: pair_str,
            price_sat: fill.price_micro_usd,
            filled_qty_sat: fill.amount_sat,
            side: "sell".to_string(),
            height: 0,
        });
        self.fills.push(fill);
    }

    fn insert_bid(&mut self, order: Order) -> Result<(), MatchingError> {
        if self.bids.len() >= MAX_ORDERS {
            return Err(MatchingError::OrderbookFull);
        }
        // Find position: DESC by price, FIFO at same price (older first).
        let pos = self
            .bids
            .iter()
            .position(|b| {
                order.price_micro_usd > b.price_micro_usd
                    || (order.price_micro_usd == b.price_micro_usd
                        && order.timestamp_ms < b.timestamp_ms)
            })
            .unwrap_or(self.bids.len());
        self.bids.insert(pos, order);
        Ok(())
    }

    fn insert_ask(&mut self, order: Order) -> Result<(), MatchingError> {
        if self.asks.len() >= MAX_ORDERS {
            return Err(MatchingError::OrderbookFull);
        }
        // ASC by price, FIFO at same price.
        let pos = self
            .asks
            .iter()
            .position(|a| {
                order.price_micro_usd < a.price_micro_usd
                    || (order.price_micro_usd == a.price_micro_usd
                        && order.timestamp_ms < a.timestamp_ms)
            })
            .unwrap_or(self.asks.len());
        self.asks.insert(pos, order);
        Ok(())
    }

    fn hash_order(h: &mut Sha256, o: &Order) {
        h.update(o.order_id.to_le_bytes());
        h.update(o.pair_id.to_le_bytes());
        h.update([o.side as u8]);
        h.update(o.price_micro_usd.to_le_bytes());
        h.update(o.remaining_sat().to_le_bytes());
        h.update(o.timestamp_ms.to_le_bytes());
        h.update(&o.trader_address);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::dex::order::Side;

    fn mk(addr: &[u8], side: Side, price: u64, amount: u64, ts: i64) -> Order {
        Order::new(addr.to_vec(), 0, side, price, amount, ts)
    }

    #[test]
    fn place_then_match() {
        let mut e = MatchingEngine::new();
        e.place_order(mk(b"alice", Side::Sell, 100, 10, 1)).unwrap();
        e.place_order(mk(b"bob", Side::Buy, 100, 10, 2)).unwrap();
        assert_eq!(e.fills.len(), 1);
        assert_eq!(e.fills[0].amount_sat, 10);
        assert_eq!(e.order_count(), 0);
    }

    #[test]
    fn price_time_priority() {
        let mut e = MatchingEngine::new();
        // Two asks at same price; older fills first.
        e.place_order(mk(b"a", Side::Sell, 100, 5, 1)).unwrap();
        e.place_order(mk(b"b", Side::Sell, 100, 5, 2)).unwrap();
        let id_buy = e.place_order(mk(b"c", Side::Buy, 100, 5, 3)).unwrap();
        let _ = id_buy;
        assert_eq!(e.fills[0].seller_address, b"a"); // older filled first
    }

    #[test]
    fn reserved_pair_rejected() {
        let mut e = MatchingEngine::new();
        let mut o = mk(b"a", Side::Buy, 100, 1, 1);
        o.pair_id = 1; // BTC/USDC reserved
        assert!(matches!(e.place_order(o), Err(MatchingError::ReservedPair)));
    }

    #[test]
    fn self_trade_allowed() {
        let mut e = MatchingEngine::new();
        e.place_order(mk(b"x", Side::Sell, 100, 5, 1)).unwrap();
        e.place_order(mk(b"x", Side::Buy, 100, 5, 2)).unwrap();
        assert_eq!(e.fills.len(), 1);
    }

    #[test]
    fn merkle_deterministic() {
        let mut e1 = MatchingEngine::new();
        let mut e2 = MatchingEngine::new();
        for e in [&mut e1, &mut e2] {
            e.place_order(mk(b"a", Side::Sell, 100, 5, 1)).unwrap();
            e.place_order(mk(b"b", Side::Buy, 90, 3, 2)).unwrap();
        }
        assert_eq!(e1.orderbook_merkle_root(), e2.orderbook_merkle_root());
    }
}
