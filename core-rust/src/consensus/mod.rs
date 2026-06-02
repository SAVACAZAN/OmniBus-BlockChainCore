//! OmniBus consensus + block production — Rust port of `core/*.zig`.
//!
//! Sibling to the Zig core implementation (like reth ↔ geth). Block hashing,
//! serialization, genesis values and the PoW/difficulty rules MUST be
//! deterministically identical to the Zig node so both impls produce the
//! same chain and peer over P2P.
//!
//! See `core/block.zig`, `core/consensus.zig`, `core/sub_block.zig`,
//! `core/finality.zig`, `core/genesis.zig`, `core/mempool.zig`, and
//! `core/blockchain/consensus_params.zig` for the reference behaviour.

pub mod block;
pub mod compact_blocks;
pub mod consensus;
pub mod consensus_rules;
pub mod finality;
pub mod genesis;
pub mod mempool;
pub mod oracle;
pub mod pouw;
pub mod sub_block;
pub mod validator_registry;
pub mod package_relay;
pub mod slot_calendar;
pub mod spark_consensus;

// ─── Canonical consensus constants (mirror core/blockchain/consensus_params.zig) ───

/// 1 OMNI = 1,000,000,000 SAT (9 decimals, like Bitcoin's BTC/sat ratio).
pub const SAT_PER_OMNI: u64 = 1_000_000_000;

/// Per-block coinbase reward in SAT. 0.0833333 OMNI/block at 1s blocks
/// = 50 OMNI per 600 blocks = same economic curve as Bitcoin's 50 BTC/10min.
/// 50 OMNI × 1e9 SAT/OMNI / 600 blocks = 83_333_333 SAT.
pub const BLOCK_REWARD_SAT: u64 = 83_333_333;

/// Halving interval in blocks: 4 years × 365.25 days × 86400 s/day.
pub const HALVING_INTERVAL: u64 = 126_144_000;

/// Maximum supply ever: 21,000,000 × 10^9 SAT.
pub const MAX_SUPPLY_SAT: u64 = 21_000_000_000_000_000;

/// Coinbase maturity (blocks before a block reward becomes spendable).
pub const COINBASE_MATURITY: u32 = 100;

/// Dust threshold in SAT — TXs below this are rejected.
pub const DUST_THRESHOLD_SAT: u64 = 100;

/// Maximum reorg depth (blocks).
pub const MAX_REORG_DEPTH: usize = 100;

/// Difficulty retarget interval (blocks). Same as Bitcoin.
pub const RETARGET_INTERVAL: u64 = 2016;

/// Target block time in seconds.
pub const TARGET_BLOCK_TIME_S: i64 = 1;

/// Target retarget interval in seconds = RETARGET_INTERVAL × TARGET_BLOCK_TIME_S.
pub const TARGET_INTERVAL_S: i64 = RETARGET_INTERVAL as i64;

/// Difficulty bounds (leading hex zeros required on block hash).
pub const MIN_DIFFICULTY: u32 = 1;
pub const MAX_DIFFICULTY: u32 = 256;

/// Fee burn percentage (EIP-1559-style). 50% by default.
pub const FEE_BURN_PCT: u64 = 50;

/// Minimum TX fee in SAT (anti-spam).
pub const TX_MIN_FEE: u64 = 1;

/// Maximum block size in bytes (1 MB).
pub const MAX_BLOCK_SIZE: usize = 1_048_576;

/// Maximum transactions per block (stack-allocated merkle buffer bound).
pub const MAX_BLOCK_TX: usize = 4_096;
