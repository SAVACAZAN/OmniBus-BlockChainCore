//! Multi-shard subsystem — port of `core/shard_coordinator.zig`,
//! `core/metachain.zig`, and the shard-aware bits of `core/blockchain_v2.zig`.
//!
//! Layout (mirrors the brief):
//!   - [`coordinator`] — 4-shard coordinator, address→shard routing,
//!     cross-shard detection, adaptive split/merge.
//!   - [`subchain`]    — per-shard blockchain state. Stripped-down sibling
//!     of the canonical [`crate::consensus::block`] chain — one of these
//!     exists per shard inside [`metachain::Metachain`].
//!   - [`metachain`]   — meta-chain that aggregates shard block headers
//!     plus cross-shard receipts (EGLD-style).

pub mod coordinator;
pub mod metachain;
pub mod subchain;

pub use coordinator::{
    ShardCoordinator, ShardStats, MAX_SHARDS, METACHAIN_SHARD, NUM_SHARDS,
    shard_for_address,
};
pub use metachain::{
    Metachain, MetaBlock, ShardBlockHeader, CrossShardReceipt, CrossShardPhase,
};
pub use subchain::{Subchain, SubchainBlock};
