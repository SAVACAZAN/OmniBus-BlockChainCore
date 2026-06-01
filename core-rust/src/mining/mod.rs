//! OmniBus mining subsystem — Rust port of `core/light_miner.zig`,
//! `core/mining_pool.zig`, `core/miner_genesis.zig` and the sub-block
//! mining loop in `core/main.zig`.
//!
//! Layout:
//!   - [`pow`]       SHA-256d PoW + difficulty target check (matches
//!                   `consensus::ConsensusEngine::is_block_hash_valid`).
//!   - [`engine`]    main mining loop — pull tx from mempool, build a
//!                   candidate block, mine PoW (10 sub-blocks per key block),
//!                   submit it.
//!   - [`pool`]      OmniBus mining-pool participant (JSON-RPC client to the
//!                   pool RPC on port 8332 — matches `scripts/miner-client.js`).
//!   - [`stratum`]   Stratum v1 protocol client for connecting to external
//!                   pools (`mining.subscribe` / `mining.authorize` /
//!                   `mining.notify` / `mining.submit`).
//!   - [`light`]     light miner that mines without holding full chain
//!                   state — validates via SPV proofs.

pub mod engine;
pub mod light;
pub mod pool;
pub mod pow;
pub mod stratum;

pub use engine::{MiningEngine, MiningConfig, MiningStats};
pub use light::{LightMiner, MinerStatus};
pub use pool::{MiningPool, MiningPoolClient, PoolStats};
pub use pow::{hash_pow, mine_block_nonce, sha256d, MineOutcome};
pub use stratum::{StratumClient, StratumJob, StratumShare};
