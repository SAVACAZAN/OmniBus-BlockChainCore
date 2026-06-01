//! OmniBus P2P — Rust port (sibling to core/ Zig).
//!
//! Wire-compatible with the Zig implementation byte-for-byte. A Rust node
//! and a Zig node running on the same network magic + genesis MUST be able
//! to peer, exchange HELLO/WELCOME, gossip blocks, and run sync.
//!
//! Port sources:
//!   - core/p2p.zig + core/p2p/wire.zig + core/p2p/peer.zig
//!   - core/bootstrap.zig
//!   - core/peer_scoring.zig
//!   - core/sync.zig
//!   - core/kademlia_dht.zig (stubbed)

pub mod bootstrap;
pub mod peer;
pub mod scoring;
pub mod sync;
pub mod wire;
pub mod node;

pub use bootstrap::{
    autodiscover, periodic_discovery, BootstrapNode, NodeStatus, PeerAddr, PeerInfo, PeerManager,
    SeedNodeConfig, MAX_PEERS, MIN_DIVERSE_PEERS, MAX_PEERS_PER_SUBNET, SEED_PEERS,
};
pub use peer::{ConnDirection, PeerConnection, RateLimitState, KnockResult};
pub use scoring::{
    BanRecord, PeerScore, PeerScoringEngine, ScoreEvent, BAN_DURATION_SEC, BAN_THRESHOLD,
    MAX_TRACKED_PEERS,
};
pub use sync::{
    BlockHeader as SyncBlockHeader, MsgBlocks, MsgGetBlocks, MsgGetHeaders, MsgHeaders, SyncManager,
    SyncState, SyncStatus,
};
pub use wire::{
    calc_checksum, decode_bloom_filter, decode_get_headers, decode_headers_batch, decode_peer_list,
    deserialize_spv_header, encode_bloom_filter, encode_get_headers, encode_headers_batch,
    encode_peer_list, serialize_spv_header, MessageType, MsgBlockAnnounce, MsgHeader, MsgHello,
    MsgPeerAddr, MsgPing, MsgStable, MsgWelcome, MSG_HEADER_SIZE, P2P_MAX_MSG_BYTES, P2P_VERSION,
    PEX_MAX_PEERS, PEX_PEER_SIZE, SPV_HEADER_SIZE, SPV_MAX_HEADERS_PER_MSG,
};

// ── P2P constants (mirror of core/p2p.zig) ──────────────────────────────────

/// Default P2P TCP port.
pub const P2P_PORT_DEFAULT: u16 = 8333;

/// TCP connect timeout (ms).
pub const P2P_CONNECT_TIMEOUT_MS: u64 = 3_000;

/// Stream read timeout (ms).
pub const P2P_READ_TIMEOUT_MS: u64 = 5_000;

/// Max inbound connections.
pub const MAX_INBOUND: usize = 32;

/// Max outbound connections.
pub const MAX_OUTBOUND: usize = 8;

/// IBD trigger gap (Bitcoin Core pattern).
pub const IBD_GAP_TRIGGER: u64 = 6;

/// IBD exit tolerance.
pub const IBD_TOLERANCE: u64 = 6;

/// Max total peers.
pub const MAX_TOTAL_PEERS: usize = MAX_INBOUND + MAX_OUTBOUND;

/// Max reconnect attempts before giving up.
pub const MAX_RECONNECT_ATTEMPTS: u8 = 3;

/// Reconnect delay (seconds).
pub const RECONNECT_DELAY_SEC: i64 = 30;

/// Rate limit: messages per second per peer.
pub const RATE_LIMIT_MSG_PER_SEC: u32 = 100;

/// Rate limit: bytes per second per peer (10 MB).
pub const RATE_LIMIT_BYTES_PER_SEC: u64 = 10 * 1024 * 1024;

/// Ban score added on rate-limit violation.
pub const RATE_LIMIT_BAN_SCORE: i32 = 50;

/// Max banned peers tracked at host:port level.
pub const MAX_BANNED_PEERS: usize = 256;

/// Max peers per /16 subnet (anti-eclipse, applies to both directions).
pub const MAX_PEERS_PER_SUBNET_TOTAL: usize = 2;

/// Max inbound peers per /16 subnet.
pub const MAX_INBOUND_PER_SUBNET: usize = 4;

/// Minimum distinct /16 subnets for diversity.
pub const MIN_SUBNET_DIVERSITY: usize = 4;

// ── Error type ──────────────────────────────────────────────────────────────

#[derive(Debug, thiserror::Error)]
pub enum P2pError {
    #[error("io error: {0}")]
    Io(#[from] std::io::Error),

    #[error("connection closed")]
    ConnectionClosed,

    #[error("protocol version mismatch")]
    ProtocolMismatch,

    #[error("payload too large ({0} bytes)")]
    PayloadTooLarge(u32),

    #[error("checksum mismatch")]
    ChecksumMismatch,

    #[error("invalid payload")]
    InvalidPayload,

    #[error("too many peers in payload")]
    TooManyPeers,

    #[error("too many headers in payload")]
    TooManyHeaders,

    #[error("not connected")]
    NotConnected,

    #[error("peer not found")]
    PeerNotFound,

    #[error("buffer too small")]
    BufferTooSmall,

    #[error("truncated input")]
    Truncated,

    #[error("invalid header in batch")]
    InvalidHeader,

    #[error("height mismatch")]
    HeightMismatch,

    #[error("invalid timestamp")]
    InvalidTimestamp,
}

pub type Result<T> = std::result::Result<T, P2pError>;
