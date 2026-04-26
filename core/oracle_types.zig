//! Oracle price types shared between block.zig and blockchain.zig.
//!
//! Extracted into a leaf module to avoid the circular import that would arise
//! if BlockPriceEntry stayed in blockchain.zig (which already imports block.zig).
//! Both block.zig and blockchain.zig now import THIS file.
//!
//! The `BlockPriceEntry` layout intentionally mirrors `ws_exchange_feed.PriceFetch`
//! with fixed-size strings so the entry can be embedded in a Block (no allocator
//! deps) AND stored in a HashMap for the legacy out-of-band cache in Blockchain.

const std = @import("std");

/// Number of "important" trading pairs the WS feed tracks (e.g. BTC/USD,
/// ETH/USD, LCX/USD, ...). Mirrors `ws_exchange_feed.IMPORTANT_PAIRS.len`.
pub const IMPORTANT_PAIRS_COUNT: usize = 7;

/// Number of exchanges sampled per pair (Coinbase, Kraken, LCX).
pub const EXCHANGES_COUNT: usize = 3;

/// Total snapshot slots embedded in a mined Block.
pub const BLOCK_PRICE_SLOTS: usize = IMPORTANT_PAIRS_COUNT * EXCHANGES_COUNT; // 21

/// Per-block oracle price entry — copy of ws_exchange_feed.PriceFetch with
/// fixed-size strings so it can live in a Block (no allocator deps).
/// Captured at mining time and exposed via getblock RPC.
pub const BlockPriceEntry = struct {
    /// "Coinbase", "Kraken", "LCX" — fixed 16 bytes
    exchange: [16]u8 = [_]u8{0} ** 16,
    exchange_len: u8 = 0,
    /// "BTC/USD" or "LCX/USD" — fixed 16 bytes
    pair: [16]u8 = [_]u8{0} ** 16,
    pair_len: u8 = 0,
    bid_micro_usd: u64 = 0,
    ask_micro_usd: u64 = 0,
    /// Milliseconds since Unix epoch (3 decimals — same precision as
    /// ws_exchange_feed.PriceFetch.timestamp_ms). Drift between the 3
    /// exchange clocks is typically ±10-50ms via NTP, so 3 decimals
    /// (1ms) is the highest meaningful precision.
    timestamp_ms: i64 = 0,
    success: bool = false,
};
