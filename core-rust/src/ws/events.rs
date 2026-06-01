//! events.rs — Event enum + Topic bitmask.
//!
//! JSON schema is FROZEN: it matches the Zig `core/ws_server.zig` output
//! exactly so the frontend (`frontend/src/api/rpc-client.ts`,
//! `BlockExplorer`, `Wallet`, etc.) keeps working when the Rust node
//! replaces the Zig node.
//!
//! Every variant serializes to `{"event":"<name>", ...fields}` thanks to
//! `#[serde(tag = "event", rename_all = "snake_case")]`.

use serde::{Deserialize, Serialize};

/// Topic bitmask — mirrors Zig `Topic` constants.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Topic;

impl Topic {
    pub const BLOCKS: u8 = 0x01;
    pub const TXS: u8 = 0x02;
    pub const TRADES: u8 = 0x04;
    pub const ORDERBOOK: u8 = 0x08;
    pub const ORACLE: u8 = 0x10;
    pub const ALL: u8 = 0x1F;
    /// 0 = "broadcast to every connected client regardless of sub mask".
    pub const BROADCAST_ALL: u8 = 0;

    /// Parse subscribe/unsubscribe topic name from a client text frame.
    pub fn from_name(name: &str) -> Option<u8> {
        match name {
            "blocks" => Some(Self::BLOCKS),
            "txs" => Some(Self::TXS),
            "trades" => Some(Self::TRADES),
            "orderbook" => Some(Self::ORDERBOOK),
            "oracle" => Some(Self::ORACLE),
            "all" => Some(Self::ALL),
            _ => None,
        }
    }
}

/// All WebSocket events the node can push to the frontend.
///
/// `tag = "event"` produces `{"event":"new_block", ...}` JSON, matching
/// the Zig hand-rolled formatting verbatim.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "event", rename_all = "snake_case")]
pub enum Event {
    /// Sent on initial connection and on demand.
    Status {
        height: u64,
        difficulty: u64,
    },
    /// Sent every 25 s on every connected client so idle WS connections
    /// don't get killed by NAT / reverse-proxy idle timers.
    Heartbeat {
        timestamp: i64,
    },
    /// A new block was mined.
    NewBlock {
        height: u64,
        hash: String,
        reward_sat: u64,
        difficulty: u64,
        mempool_size: usize,
        timestamp: i64,
    },
    /// Initial Block Download progress (UI shows sync banner).
    IbdProgress {
        local_height: u64,
        peer_height: u64,
        behind: u64,
        progress: u8,
        active: bool,
    },
    /// New transaction in mempool.
    NewTx {
        txid: String,
        from: String,
        amount_sat: u64,
    },
    /// A previously-pending TX got confirmed in a block.
    TxConfirmed {
        hash: String,
        #[serde(rename = "blockHeight")]
        block_height: u64,
        #[serde(rename = "blockHash")]
        block_hash: String,
    },
    /// A trade was matched + settled.
    NewTrade {
        pair_id: u32,
        pair: String,
        price_sat: u64,
        qty_sat: u64,
        side: String, // "buy" | "sell"
        height: u64,
        timestamp: i64,
    },
    /// Orderbook snapshot (best bid/ask + spread).
    OrderbookUpdate {
        pair_id: u32,
        pair: String,
        best_bid: u64,
        best_ask: u64,
        spread: u64,
        order_count: u32,
        height: u64,
    },
    /// Aggregated balance/state changed for an address (used by Wallet UI).
    BalanceChanged {
        address: String,
        balance_sat: u64,
        staked_sat: u64,
        height: u64,
    },
    /// Chain head moved (for explorers that don't need full block payload).
    ChainHead {
        height: u64,
        hash: String,
        timestamp: i64,
    },
    /// Order was filled (taker side).
    OrderFilled {
        order_id: u64,
        pair_id: u32,
        pair: String,
        price_sat: u64,
        filled_qty_sat: u64,
        side: String,
        height: u64,
    },
    /// DNS name registered.
    NameRegistered {
        name: String,
        tld: String,
        #[serde(rename = "fullLabel")]
        full_label: String,
        address: String,
        years: u8,
        timestamp: i64,
    },
    /// DNS name renewed.
    NameRenewed {
        name: String,
        tld: String,
        #[serde(rename = "fullLabel")]
        full_label: String,
        address: String,
        years: u8,
        timestamp: i64,
    },
    /// P2P peer connected.
    PeerConnect {
        #[serde(rename = "nodeId")]
        node_id: String,
        address: String,
        timestamp: i64,
    },
    /// P2P peer disconnected.
    PeerDisconnect {
        #[serde(rename = "nodeId")]
        node_id: String,
        address: String,
        timestamp: i64,
    },
    /// Oracle price update (USD).
    OraclePrice {
        pair: String,
        price_usd: f64,
        sources: u8,
        timestamp: i64,
    },
    /// Agent emitted a decision (mirrors `core/agent_manager.zig` queue).
    AgentDecision {
        wallet_index: u32,
        decision_id: u64,
        kind: String,
        venue: String,
        amount_sat: u64,
        pair: String,
        reason: String,
        block_height: u64,
    },
}

impl Event {
    /// Which topic bitmask should this event be filtered against?
    /// 0 = broadcast to every connected client (heartbeat / status / peer).
    pub fn topic(&self) -> u8 {
        match self {
            Event::NewBlock { .. } | Event::ChainHead { .. } => Topic::BLOCKS,
            Event::NewTx { .. } | Event::TxConfirmed { .. } => Topic::TXS,
            Event::NewTrade { .. } | Event::OrderFilled { .. } => Topic::TRADES,
            Event::OrderbookUpdate { .. } => Topic::ORDERBOOK,
            Event::OraclePrice { .. } => Topic::ORACLE,
            // BalanceChanged is per-address — broadcast (frontend filters).
            Event::BalanceChanged { .. } => Topic::BROADCAST_ALL,
            // Lifecycle / agent / peer / system events go to everyone.
            Event::Status { .. }
            | Event::Heartbeat { .. }
            | Event::IbdProgress { .. }
            | Event::NameRegistered { .. }
            | Event::NameRenewed { .. }
            | Event::PeerConnect { .. }
            | Event::PeerDisconnect { .. }
            | Event::AgentDecision { .. } => Topic::BROADCAST_ALL,
        }
    }

    /// Serialize to JSON string ready for a WS text frame.
    pub fn to_json(&self) -> String {
        serde_json::to_string(self).unwrap_or_else(|_| "{}".to_string())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn new_block_json_matches_zig_schema() {
        let e = Event::NewBlock {
            height: 42,
            hash: "abc".into(),
            reward_sat: 8_333_333,
            difficulty: 1024,
            mempool_size: 7,
            timestamp: 1_700_000_000,
        };
        let s = e.to_json();
        assert!(s.contains(r#""event":"new_block""#));
        assert!(s.contains(r#""height":42"#));
        assert!(s.contains(r#""hash":"abc""#));
    }

    #[test]
    fn topic_routing() {
        let blk = Event::ChainHead {
            height: 1,
            hash: "h".into(),
            timestamp: 0,
        };
        assert_eq!(blk.topic(), Topic::BLOCKS);
        let hb = Event::Heartbeat { timestamp: 1 };
        assert_eq!(hb.topic(), Topic::BROADCAST_ALL);
    }

    #[test]
    fn topic_from_name() {
        assert_eq!(Topic::from_name("blocks"), Some(Topic::BLOCKS));
        assert_eq!(Topic::from_name("all"), Some(Topic::ALL));
        assert_eq!(Topic::from_name("bogus"), None);
    }
}
