//! Order type, IDs, sides, statuses.
//!
//! Mirrors `core/matching_engine.zig::Order`.
//!
//! Units (same as Zig):
//!   - Prices: micro-USD (u64, 1_000_000 = $1.00)
//!   - Amounts: SAT (u64, 1 OMNI = 1_000_000_000 SAT)
//!   - Timestamps: Unix milliseconds (i64)

use serde::{Deserialize, Serialize};

pub type OrderId = u64;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[repr(u8)]
pub enum Side {
    Buy = 0,
    Sell = 1,
}

impl Side {
    pub fn opposite(self) -> Self {
        match self {
            Side::Buy => Side::Sell,
            Side::Sell => Side::Buy,
        }
    }

    pub fn name(self) -> &'static str {
        match self {
            Side::Buy => "BUY",
            Side::Sell => "SELL",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[repr(u8)]
pub enum OrderStatus {
    Active = 0,
    Partial = 1,
    Filled = 2,
    Cancelled = 3,
}

/// A resting or incoming order.
///
/// `trader_address` is variable-length (bech32 OmniBus address, up to 64
/// bytes). The Zig version uses `[64]u8 + len`; we use a `Vec<u8>` for
/// idiomatic Rust — wire format is unchanged because we only serialize
/// the canonical portion in matching/htlc hashing.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Order {
    pub order_id: OrderId,
    pub trader_address: Vec<u8>,
    pub pair_id: u16,
    pub side: Side,
    pub price_micro_usd: u64,
    pub amount_sat: u64,
    pub filled_sat: u64,
    pub timestamp_ms: i64,
    pub status: OrderStatus,
    /// SELL on OMNI/<EVM-token>: seller's EVM address for settler delivery.
    /// All-zero = no EVM leg requested.
    pub seller_evm: [u8; 20],
    /// BUY on OMNI/<EVM-token>: on-chain escrow orderId on the EVM side
    /// (verified by evm_escrow_watcher BEFORE the BID is accepted).
    /// 0 = not provided (only allowed for pairs without an EVM leg).
    pub evm_order_id: u64,
}

impl Order {
    pub fn new(
        trader_address: Vec<u8>,
        pair_id: u16,
        side: Side,
        price_micro_usd: u64,
        amount_sat: u64,
        timestamp_ms: i64,
    ) -> Self {
        Self {
            order_id: 0,
            trader_address,
            pair_id,
            side,
            price_micro_usd,
            amount_sat,
            filled_sat: 0,
            timestamp_ms,
            status: OrderStatus::Active,
            seller_evm: [0u8; 20],
            evm_order_id: 0,
        }
    }

    pub fn remaining_sat(&self) -> u64 {
        self.amount_sat.saturating_sub(self.filled_sat)
    }

    pub fn is_buy(&self) -> bool {
        self.side == Side::Buy
    }

    pub fn same_trader(&self, other: &Order) -> bool {
        self.trader_address == other.trader_address
    }
}
