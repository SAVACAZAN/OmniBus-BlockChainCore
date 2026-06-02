//! Consensus rules — block-header validation, difficulty adjustment, halving schedule.
//!
//! Port of `core/consensus.zig` (ConsensusRound / ConsensusEngine) and
//! `core/blockchain/consensus_params.zig` (retarget + reward schedule).
//!
//! Additions beyond the base `consensus.rs`:
//!   * `ConsensusRules` struct — canonical chain parameters
//!   * `validate_block_header` — hash ≤ target, timestamp window ±2h, height = prev+1
//!   * `adjust_difficulty` — Bitcoin-style retarget (clamp 4×/0.25×)
//!
//! `ConsensusRules` is the single source of truth for parameters that must be
//! identical across Zig and Rust nodes. Constants are taken from the Zig source
//! and cross-checked against the live testnet.

use super::{
    HALVING_INTERVAL, MAX_SUPPLY_SAT, RETARGET_INTERVAL, TARGET_BLOCK_TIME_S,
};

// ── Chain identity & network config (ported from chain_config.zig) ───────────

/// OmniBus chain network IDs — mirrors `ChainId` in `chain_config.zig`.
///
/// Values match Ethereum EIP-155 convention: prevents replay across networks.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u32)]
pub enum OmnibusChainId {
    Mainnet = 1,
    Testnet = 2,
    Devnet  = 3,
    Regtest = 4,
}

/// Network magic bytes — first 4 bytes of every P2P message (mirrors Bitcoin
/// 0xF9BEB4D9 mainnet, 0xFABFB5DA testnet).
///
/// Mirrors `NetworkMagic` in `chain_config.zig`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct NetworkMagic(pub [u8; 4]);

impl NetworkMagic {
    /// "OMNI"
    pub const MAINNET: Self = Self([0x4F, 0x4D, 0x4E, 0x49]);
    /// "TEST"
    pub const TESTNET: Self = Self([0x54, 0x45, 0x53, 0x54]);
    /// "DEVN"
    pub const DEVNET:  Self = Self([0x44, 0x45, 0x56, 0x4E]);
    /// "REGT"
    pub const REGTEST: Self = Self([0x52, 0x45, 0x47, 0x54]);

    pub fn for_chain(id: OmnibusChainId) -> Self {
        match id {
            OmnibusChainId::Mainnet => Self::MAINNET,
            OmnibusChainId::Testnet => Self::TESTNET,
            OmnibusChainId::Devnet  => Self::DEVNET,
            OmnibusChainId::Regtest => Self::REGTEST,
        }
    }
}

/// Verified block checkpoint (mirrors Bitcoin's `assumevalid`).
///
/// Nodes may skip PoW validation for blocks older than the highest known
/// checkpoint. Founder signs each new checkpoint at release time.
#[derive(Debug, Clone, Copy)]
pub struct Checkpoint {
    pub height: u64,
    /// Lowercase ASCII hex string of the 32-byte block hash (64 chars).
    pub hash_hex: &'static str,
    pub timestamp: i64,
}

// ── Bridge V1 consensus constants (ported from chain_config.zig) ──────────────
//
// Hard caps enforced at the consensus layer — cannot be bypassed without a fork.
// Conservative start values; increase only after audit + TVL growth.
//
// Lessons: Ronin $625M, Wormhole $326M, Nomad $190M, Kelp DAO $292M (2026-04)
// — per-tx cap limits blast radius; rolling daily cap prevents catastrophic drain.

/// Deterministic bridge vault address (last 20 bytes of
/// `keccak256("OMNIBUS_BRIDGE_VAULT_V1")`).
pub const BRIDGE_VAULT_ADDR_HEX: &str =
    "0xd58169164e9a3b9390dc3e25817d6a385718e409";

/// Bridge wallet address (deterministic, non-EVM fallback).
pub const BRIDGE_WALLET_ADDR_HEX: &str =
    "0x835947f3731ecd6ca7f14c3c17f9f0fc231987c9";

/// Maximum OMNI locked in a single bridge TX (in SAT). 100 OMNI.
pub const BRIDGE_MAX_PER_TX_SAT: u64 = 100_000_000_000;

/// Rolling 24h limit across all bridge locks combined (in SAT). 1 000 OMNI.
pub const BRIDGE_MAX_DAILY_SAT: u64 = 1_000_000_000_000;

/// Window for the rolling-day limit. With 1 s blocks = 86 400 blocks.
pub const BRIDGE_DAILY_WINDOW_BLOCKS: u64 = 86_400;

/// Minimum relayer signatures required to unlock from the bridge vault.
/// Lesson Kelp DAO: never trust a single relayer.
pub const BRIDGE_REQUIRED_SIGS: u8 = 3;

/// Maximum number of registered relayers.
pub const BRIDGE_MAX_RELAYERS: u8 = 9;

/// Challenge window in blocks before a threshold-signed unlock is executed.
/// 6 h @ 1 s/block = 21 600 blocks.
pub const BRIDGE_CHALLENGE_WINDOW_BLOCKS: u64 = 21_600;

/// Auto-pause threshold in basis points (30% = 3 000 bps). A single block
/// locking ≥30% of the daily quota triggers a bridge halt pending review.
pub const BRIDGE_AUTO_PAUSE_BLOCK_FRACTION_BPS: u16 = 3_000;

// ── Per-network port assignments ──────────────────────────────────────────────

/// Default ports for each network (matches Zig `ChainConfig`).
#[derive(Debug, Clone, Copy)]
pub struct NetworkPorts {
    pub p2p: u16,
    pub rpc: u16,
    pub ws: u16,
}

impl NetworkPorts {
    pub const MAINNET: Self = Self { p2p: 8333,  rpc: 8332,  ws: 8334  };
    pub const TESTNET: Self = Self { p2p: 18333, rpc: 18332, ws: 18334 };
    pub const DEVNET:  Self = Self { p2p: 38333, rpc: 38332, ws: 38334 };
    pub const REGTEST: Self = Self { p2p: 28333, rpc: 28332, ws: 28334 };

    pub fn for_chain(id: OmnibusChainId) -> Self {
        match id {
            OmnibusChainId::Mainnet => Self::MAINNET,
            OmnibusChainId::Testnet => Self::TESTNET,
            OmnibusChainId::Devnet  => Self::DEVNET,
            OmnibusChainId::Regtest => Self::REGTEST,
        }
    }
}

/// Canonical genesis block hash (SHA-256 of the genesis block fields).
/// Same value for all networks — chain separation is enforced by `NetworkMagic`.
pub const GENESIS_HASH: &str =
    "82ec46e83af37b1ea0e6b3fe66a8f04795a8e8aae7db414d451eff1154245982";
/// Genesis block timestamp (Unix seconds).
pub const GENESIS_TIMESTAMP: i64 = 1_743_000_000;

/// Number of sub-blocks per key-block (mirrors `sub_blocks_per_block`).
pub const SUB_BLOCKS_PER_BLOCK: u8 = 10;

/// Full chain configuration — one value per network.
///
/// Mirrors `ChainConfig` in `chain_config.zig`. The `ConsensusRules` struct
/// contains the consensus-critical subset (reward schedule, difficulty); this
/// struct adds the network-identity and port fields.
#[derive(Debug, Clone, Copy)]
pub struct ChainConfig {
    pub chain_id: OmnibusChainId,
    pub name: &'static str,
    pub magic: NetworkMagic,
    pub genesis_hash: &'static str,
    pub genesis_timestamp: i64,
    pub ports: NetworkPorts,
    pub initial_difficulty: u32,
    pub block_time_ms: u64,
    pub max_supply_sat: u64,
    pub initial_reward_sat: u64,
    pub halving_interval: u64,
    pub retarget_interval: u64,
    pub sub_blocks_per_block: u8,
    pub checkpoints: &'static [Checkpoint],
}

/// Mainnet checkpoints. Height-0 anchor = canonical genesis.
pub static MAINNET_CHECKPOINTS: [Checkpoint; 1] = [Checkpoint {
    height: 0,
    hash_hex: GENESIS_HASH,
    timestamp: GENESIS_TIMESTAMP,
}];

/// Testnet checkpoints.
pub static TESTNET_CHECKPOINTS: [Checkpoint; 1] = [Checkpoint {
    height: 0,
    hash_hex: GENESIS_HASH,
    timestamp: GENESIS_TIMESTAMP,
}];

impl ChainConfig {
    /// Mainnet — live production chain.
    pub const fn mainnet() -> Self {
        Self {
            chain_id: OmnibusChainId::Mainnet,
            name: "omnibus-mainnet",
            magic: NetworkMagic::MAINNET,
            genesis_hash: GENESIS_HASH,
            genesis_timestamp: GENESIS_TIMESTAMP,
            ports: NetworkPorts::MAINNET,
            initial_difficulty: 4,
            block_time_ms: 1_000,
            max_supply_sat: 21_000_000_000_000_000,
            initial_reward_sat: 8_333_333,
            halving_interval: 126_144_000,
            retarget_interval: 2_016,
            sub_blocks_per_block: SUB_BLOCKS_PER_BLOCK,
            checkpoints: &MAINNET_CHECKPOINTS,
        }
    }

    /// Testnet — no real value, faucet available.
    pub const fn testnet() -> Self {
        Self {
            chain_id: OmnibusChainId::Testnet,
            name: "omnibus-testnet",
            magic: NetworkMagic::TESTNET,
            genesis_hash: GENESIS_HASH,
            genesis_timestamp: GENESIS_TIMESTAMP,
            ports: NetworkPorts::TESTNET,
            initial_difficulty: 1,
            block_time_ms: 1_000,
            max_supply_sat: 21_000_000_000_000_000,
            initial_reward_sat: 8_333_333,
            halving_interval: 126_144_000,
            retarget_interval: 2_016,
            sub_blocks_per_block: SUB_BLOCKS_PER_BLOCK,
            checkpoints: &TESTNET_CHECKPOINTS,
        }
    }

    /// Devnet — local development, fast blocks, easy mining.
    pub const fn devnet() -> Self {
        Self {
            chain_id: OmnibusChainId::Devnet,
            name: "omnibus-devnet",
            magic: NetworkMagic::DEVNET,
            genesis_hash: GENESIS_HASH,
            genesis_timestamp: GENESIS_TIMESTAMP,
            ports: NetworkPorts::DEVNET,
            initial_difficulty: 1,
            block_time_ms: 500,
            max_supply_sat: 21_000_000_000_000_000,
            initial_reward_sat: 8_333_333,
            halving_interval: 50_000,
            retarget_interval: 100,
            sub_blocks_per_block: SUB_BLOCKS_PER_BLOCK,
            checkpoints: &[],
        }
    }

    /// Regtest — instant mining, difficulty 1, short windows.
    pub const fn regtest() -> Self {
        Self {
            chain_id: OmnibusChainId::Regtest,
            name: "omnibus-regtest",
            magic: NetworkMagic::REGTEST,
            genesis_hash: GENESIS_HASH,
            genesis_timestamp: GENESIS_TIMESTAMP,
            ports: NetworkPorts::REGTEST,
            initial_difficulty: 1,
            block_time_ms: 100,
            max_supply_sat: 21_000_000_000_000_000,
            initial_reward_sat: 8_333_333,
            halving_interval: 150,
            retarget_interval: 10,
            sub_blocks_per_block: SUB_BLOCKS_PER_BLOCK,
            checkpoints: &[],
        }
    }

    /// Returns `true` if the chain ID of `other` would be replayed on `self`
    /// (i.e. they share a chain ID — should never happen in production).
    pub fn would_replay(&self, other: &ChainConfig) -> bool {
        self.chain_id == other.chain_id
    }
}

// ── FeeEstimator ──────────────────────────────────────────────────────────────

/// Mempool-pressure-based fee estimator.
///
/// Mirrors `FeeEstimator` in `chain_config.zig`. Algorithm:
///   - Empty mempool → 1 SAT (minimum).
///   - Each pressure tier doubles/increases the fee.
///   - Full mempool → 100 SAT (anti-spam ceiling).
#[derive(Debug, Clone, Copy)]
pub struct FeeEstimator {
    pub mempool_size: usize,
    pub mempool_max: usize,
}

impl FeeEstimator {
    pub fn new(mempool_size: usize, mempool_max: usize) -> Self {
        Self { mempool_size, mempool_max }
    }

    /// Estimate the fee (in SAT) required for next-block inclusion.
    pub fn estimate_fee(&self) -> u64 {
        if self.mempool_max == 0 {
            return 1;
        }
        let pressure_pct = self.mempool_size * 100 / self.mempool_max;
        match pressure_pct {
            0..=9   => 1,   // Low
            10..=24 => 2,   // Normal
            25..=49 => 5,   // Medium
            50..=74 => 10,  // High
            75..=89 => 50,  // Very high
            _       => 100, // Critical
        }
    }

    /// Estimate number of blocks until confirmation at the given `fee_sat`.
    pub fn estimate_blocks(&self, fee_sat: u64) -> u32 {
        let min_fee = self.estimate_fee();
        if fee_sat >= min_fee * 2 { 1 }       // Premium: next block
        else if fee_sat >= min_fee { 3 }       // Normal: 3 blocks
        else { 10 }                            // Low priority: 10 blocks
    }
}

// ── Chain parameters ─────────────────────────────────────────────────────────

/// Canonical set of consensus parameters for the OmniBus chain.
///
/// Mirrors `ConsensusConfig` / `ConsensusParams` from the Zig core and is
/// used wherever the Rust node needs to apply consensus rules (validation,
/// mining, retarget, reward split).
#[derive(Debug, Clone, Copy)]
pub struct ConsensusRules {
    /// Target block time (ms). 1000 ms = 1 s.
    pub target_block_time_ms: u64,
    /// Maximum block body size in bytes (1 MiB).
    pub max_block_size: usize,
    /// Blocks per halving era (210 000 — same as Bitcoin).
    pub halving_interval: u64,
    /// Initial coinbase reward in SAT (50 OMNI = 50 × 10^9 SAT).
    pub initial_reward_sat: u64,
    /// Maximum total supply in SAT (21 M OMNI).
    pub max_supply_sat: u64,
    /// Bitcoin-style retarget window (every 2 016 blocks).
    pub retarget_interval: u64,
    /// Maximum retarget adjustment factor (4×).
    pub max_retarget_factor: u64,
    /// Timestamp drift tolerance in seconds (±2 h = 7200 s).
    pub max_timestamp_drift_s: i64,
    /// Minimum PoW difficulty (leading hex-zero count).
    pub min_difficulty: u32,
    /// Maximum PoW difficulty (leading hex-zero count).
    pub max_difficulty: u32,
}

impl ConsensusRules {
    /// Production chain parameters — must match Zig `core/`.
    pub const fn mainnet() -> Self {
        Self {
            target_block_time_ms: (TARGET_BLOCK_TIME_S as u64) * 1_000,
            max_block_size: 1_048_576,
            halving_interval: HALVING_INTERVAL,
            initial_reward_sat: 83_333_333, // 50 OMNI / 600 blocks (1 SAT = 1e-9 OMNI)
            max_supply_sat: MAX_SUPPLY_SAT,
            retarget_interval: RETARGET_INTERVAL,
            max_retarget_factor: 4,
            max_timestamp_drift_s: 7_200, // ±2 h
            min_difficulty: 1,
            max_difficulty: 256,
        }
    }

    /// Regtest / unit-test parameters — short windows for fast iteration.
    pub const fn regtest() -> Self {
        Self {
            target_block_time_ms: 100,
            max_block_size: 1_048_576,
            halving_interval: 150,
            initial_reward_sat: 50_000_000_000,
            max_supply_sat: MAX_SUPPLY_SAT,
            retarget_interval: 10,
            max_retarget_factor: 4,
            max_timestamp_drift_s: 7_200,
            min_difficulty: 1,
            max_difficulty: 256,
        }
    }
}

// ── Block-header validation ──────────────────────────────────────────────────

/// Simple header snapshot for validation (no alloc needed).
#[derive(Debug, Clone, Copy)]
pub struct HeaderSnapshot {
    pub height: u64,
    pub timestamp_ms: i64,
    pub hash_hex: [u8; 64], // lowercase ASCII hex of the 32-byte hash
    pub hash_hex_len: usize,
    pub difficulty: u32,
}

impl HeaderSnapshot {
    pub fn hash_str(&self) -> &str {
        core::str::from_utf8(&self.hash_hex[..self.hash_hex_len]).unwrap_or("")
    }
}

/// Result of a header-validation check.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HeaderValidation {
    Ok,
    HashTooHigh,
    TimestampTooFarInFuture,
    TimestampTooFarInPast,
    HeightMismatch,
    InvalidDifficulty,
}

/// Validate a block header against its predecessor and the current wall clock.
///
/// Checks (mirrors Bitcoin Core's `CheckBlockHeader`):
///   1. Hash satisfies the difficulty target.
///   2. Timestamp is within ±`max_timestamp_drift_s` of `now_ms`.
///   3. Height equals `prev_height + 1`.
pub fn validate_block_header(
    header: &HeaderSnapshot,
    prev_height: u64,
    now_ms: i64,
    rules: &ConsensusRules,
) -> HeaderValidation {
    // 1. PoW check.
    let zeros = header
        .hash_str()
        .bytes()
        .take_while(|&b| b == b'0')
        .count() as u32;
    if zeros < header.difficulty {
        return HeaderValidation::HashTooHigh;
    }
    if header.difficulty < rules.min_difficulty || header.difficulty > rules.max_difficulty {
        return HeaderValidation::InvalidDifficulty;
    }

    // 2. Timestamp window.
    let drift_ms = rules.max_timestamp_drift_s * 1_000;
    if header.timestamp_ms > now_ms + drift_ms {
        return HeaderValidation::TimestampTooFarInFuture;
    }
    if header.timestamp_ms < now_ms - drift_ms {
        return HeaderValidation::TimestampTooFarInPast;
    }

    // 3. Height continuity.
    if header.height != prev_height + 1 {
        return HeaderValidation::HeightMismatch;
    }

    HeaderValidation::Ok
}

// ── Difficulty adjustment ────────────────────────────────────────────────────

/// Timestamps (ms) of the first and last block in the retarget window.
///
/// Supply the timestamps of blocks `height - RETARGET_INTERVAL` and `height`
/// (i.e. the window boundary blocks, not the internal ones).
pub struct RetargetWindow {
    pub start_ms: i64,
    pub end_ms: i64,
}

/// Bitcoin-style difficulty retarget — takes the actual elapsed time over the
/// last `RETARGET_INTERVAL` blocks and scales difficulty so the next window
/// hits the target block time.
///
/// Clamped to `[old_difficulty / 4, old_difficulty * 4]` to prevent sudden
/// jumps (same as Bitcoin Core `GetNextWorkRequired`).
///
/// Returns a value in `[rules.min_difficulty, rules.max_difficulty]`.
pub fn adjust_difficulty(
    old_difficulty: u32,
    window: &RetargetWindow,
    rules: &ConsensusRules,
) -> u32 {
    let actual_ms = (window.end_ms - window.start_ms).max(1);
    let target_ms = (rules.target_block_time_ms as i64)
        * (rules.retarget_interval as i64);

    // Clamp actual time to [target/4, target*4].
    let lo = target_ms / 4;
    let hi = target_ms * 4;
    let clamped = actual_ms.max(lo).min(hi);

    let new_diff = (old_difficulty as i64 * clamped) / target_ms;

    (new_diff as u32)
        .max(rules.min_difficulty)
        .min(rules.max_difficulty)
}

/// Block reward at a given height applying the PoUW halving schedule.
/// Matches Zig `PoUWEngine.getBlockReward`.
pub fn block_reward_sat(height: u64, rules: &ConsensusRules) -> u64 {
    let halvings = height / rules.halving_interval;
    // After 64 halvings the shift would wrap — treat as zero.
    if halvings >= 64 {
        return 0;
    }
    rules.initial_reward_sat >> halvings
}

/// Cumulative supply minted up to (but not including) `height`.
/// Caps at `rules.max_supply_sat`.
pub fn total_supply_at(height: u64, rules: &ConsensusRules) -> u64 {
    let mut total: u64 = 0;
    let mut remaining = height;
    let mut era: u64 = 0;

    while remaining > 0 && era < 64 {
        let blocks = remaining.min(rules.halving_interval);
        let reward = rules.initial_reward_sat >> era;
        if reward == 0 {
            break;
        }
        let era_minted = blocks.saturating_mul(reward);
        total = total.saturating_add(era_minted);
        if total >= rules.max_supply_sat {
            return rules.max_supply_sat;
        }
        remaining -= blocks;
        era += 1;
    }

    total.min(rules.max_supply_sat)
}

// ── Tests ────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    fn make_header(height: u64, hash_prefix_zeros: u32, ts_ms: i64) -> HeaderSnapshot {
        let mut hex = [b'a'; 64];
        for i in 0..(hash_prefix_zeros as usize).min(64) {
            hex[i] = b'0';
        }
        HeaderSnapshot {
            height,
            timestamp_ms: ts_ms,
            hash_hex: hex,
            hash_hex_len: 64,
            difficulty: hash_prefix_zeros,
        }
    }

    #[test]
    fn valid_header_accepted() {
        let rules = ConsensusRules::mainnet();
        let h = make_header(1, 2, 1_700_000_000_000);
        assert_eq!(
            validate_block_header(&h, 0, 1_700_000_000_000, &rules),
            HeaderValidation::Ok
        );
    }

    #[test]
    fn hash_too_high_rejected() {
        let rules = ConsensusRules::mainnet();
        let mut h = make_header(1, 2, 1_700_000_000_000);
        // Only 1 leading zero but difficulty = 2 → fail.
        h.hash_hex[1] = b'a';
        assert_eq!(
            validate_block_header(&h, 0, 1_700_000_000_000, &rules),
            HeaderValidation::HashTooHigh
        );
    }

    #[test]
    fn future_timestamp_rejected() {
        let rules = ConsensusRules::mainnet();
        let now = 1_700_000_000_000i64;
        let h = make_header(1, 2, now + (rules.max_timestamp_drift_s + 1) * 1_000);
        assert_eq!(
            validate_block_header(&h, 0, now, &rules),
            HeaderValidation::TimestampTooFarInFuture
        );
    }

    #[test]
    fn height_mismatch_rejected() {
        let rules = ConsensusRules::mainnet();
        let h = make_header(5, 2, 1_700_000_000_000);
        assert_eq!(
            validate_block_header(&h, 0, 1_700_000_000_000, &rules),
            HeaderValidation::HeightMismatch
        );
    }

    #[test]
    fn difficulty_retarget_too_fast_reduces_difficulty() {
        let rules = ConsensusRules::mainnet();
        // Blocks too fast → reduce difficulty (but clamp: can't drop below old/4).
        let target_ms = (rules.target_block_time_ms as i64) * (rules.retarget_interval as i64);
        let window = RetargetWindow {
            start_ms: 0,
            end_ms: target_ms / 8, // way too fast
        };
        let new_diff = adjust_difficulty(8, &window, &rules);
        // Clamped to old/4 = 2.
        assert_eq!(new_diff, 2);
    }

    #[test]
    fn difficulty_retarget_too_slow_increases_difficulty() {
        let rules = ConsensusRules::mainnet();
        let target_ms = (rules.target_block_time_ms as i64) * (rules.retarget_interval as i64);
        let window = RetargetWindow {
            start_ms: 0,
            end_ms: target_ms * 8, // way too slow
        };
        let new_diff = adjust_difficulty(4, &window, &rules);
        // Clamped to old*4 = 16.
        assert_eq!(new_diff, 16);
    }

    #[test]
    fn difficulty_retarget_on_target_unchanged() {
        let rules = ConsensusRules::mainnet();
        let target_ms = (rules.target_block_time_ms as i64) * (rules.retarget_interval as i64);
        let window = RetargetWindow {
            start_ms: 0,
            end_ms: target_ms,
        };
        assert_eq!(adjust_difficulty(4, &window, &rules), 4);
    }

    #[test]
    fn block_reward_halving() {
        let rules = ConsensusRules::mainnet();
        assert_eq!(block_reward_sat(0, &rules), 83_333_333);
        assert_eq!(block_reward_sat(rules.halving_interval, &rules), 41_666_666);
        assert_eq!(block_reward_sat(rules.halving_interval * 2, &rules), 20_833_333);
        assert_eq!(block_reward_sat(rules.halving_interval * 64, &rules), 0);
    }

    #[test]
    fn total_supply_first_era() {
        let rules = ConsensusRules::mainnet();
        let expected = rules.halving_interval * rules.initial_reward_sat;
        assert_eq!(total_supply_at(rules.halving_interval, &rules), expected);
    }

    #[test]
    fn total_supply_never_exceeds_cap() {
        let rules = ConsensusRules::mainnet();
        assert_eq!(total_supply_at(u64::MAX, &rules), rules.max_supply_sat);
    }

    // ── ChainConfig ──────────────────────────────────────────────────────────

    #[test]
    fn chain_config_mainnet_basics() {
        let cfg = ChainConfig::mainnet();
        assert_eq!(cfg.chain_id, OmnibusChainId::Mainnet);
        assert_eq!(cfg.ports.p2p, 8333);
        assert_eq!(cfg.ports.rpc, 8332);
        assert_eq!(cfg.max_supply_sat, 21_000_000_000_000_000);
        assert_eq!(cfg.block_time_ms, 1_000);
        assert_eq!(cfg.sub_blocks_per_block, 10);
        assert!(!cfg.checkpoints.is_empty());
        assert_eq!(cfg.checkpoints[0].height, 0);
    }

    #[test]
    fn chain_config_testnet_different_ports() {
        let cfg = ChainConfig::testnet();
        assert_eq!(cfg.chain_id, OmnibusChainId::Testnet);
        assert_eq!(cfg.ports.p2p, 18333);
        assert_eq!(cfg.initial_difficulty, 1);
    }

    #[test]
    fn chain_config_devnet_fast_blocks() {
        let cfg = ChainConfig::devnet();
        assert_eq!(cfg.block_time_ms, 500);
        assert_eq!(cfg.retarget_interval, 100);
    }

    #[test]
    fn chain_config_regtest_instant_mining() {
        let cfg = ChainConfig::regtest();
        assert_eq!(cfg.block_time_ms, 100);
        assert_eq!(cfg.halving_interval, 150);
        assert_eq!(cfg.retarget_interval, 10);
        assert!(cfg.checkpoints.is_empty());
    }

    #[test]
    fn network_magic_for_chain() {
        let mainnet = NetworkMagic::for_chain(OmnibusChainId::Mainnet);
        assert_eq!(mainnet.0, [0x4F, 0x4D, 0x4E, 0x49]); // "OMNI"
        let testnet = NetworkMagic::for_chain(OmnibusChainId::Testnet);
        assert_ne!(mainnet.0, testnet.0);
    }

    #[test]
    fn chain_id_prevents_replay() {
        let main_cfg = ChainConfig::mainnet();
        let test_cfg = ChainConfig::testnet();
        assert!(!main_cfg.would_replay(&test_cfg));
        assert!(main_cfg.would_replay(&ChainConfig::mainnet()));
    }

    // ── FeeEstimator ─────────────────────────────────────────────────────────

    #[test]
    fn fee_empty_mempool() {
        let est = FeeEstimator::new(0, 10_000);
        assert_eq!(est.estimate_fee(), 1);
    }

    #[test]
    fn fee_full_mempool() {
        let est = FeeEstimator::new(9_500, 10_000);
        assert_eq!(est.estimate_fee(), 100);
    }

    #[test]
    fn fee_half_full_mempool() {
        let est = FeeEstimator::new(5_000, 10_000);
        assert_eq!(est.estimate_fee(), 10);
    }

    #[test]
    fn fee_zero_max() {
        let est = FeeEstimator::new(100, 0);
        assert_eq!(est.estimate_fee(), 1);
    }

    #[test]
    fn fee_estimate_blocks() {
        let est = FeeEstimator::new(5_000, 10_000);
        let min = est.estimate_fee(); // 10
        assert_eq!(est.estimate_blocks(min * 2), 1); // premium
        assert_eq!(est.estimate_blocks(min), 3);     // normal
        assert_eq!(est.estimate_blocks(1), 10);      // low
    }

    // ── Bridge constants ──────────────────────────────────────────────────────

    #[test]
    fn bridge_constants_sane() {
        // Per-tx cap must be less than the daily cap.
        assert!(BRIDGE_MAX_PER_TX_SAT < BRIDGE_MAX_DAILY_SAT);
        // Must require at least 2 sigs (not 1-of-N).
        assert!(BRIDGE_REQUIRED_SIGS >= 2);
        // Threshold must not exceed the max relayer count.
        assert!(BRIDGE_REQUIRED_SIGS <= BRIDGE_MAX_RELAYERS);
        // Challenge window must be at least 1 hour (3600 blocks @ 1 s/block).
        assert!(BRIDGE_CHALLENGE_WINDOW_BLOCKS >= 3_600);
        // Auto-pause must be < 100%.
        assert!(BRIDGE_AUTO_PAUSE_BLOCK_FRACTION_BPS < 10_000);
    }

    #[test]
    fn bridge_vault_addr_format() {
        assert!(BRIDGE_VAULT_ADDR_HEX.starts_with("0x"));
        // 20 bytes = 40 hex chars + "0x" = 42 chars total.
        assert_eq!(BRIDGE_VAULT_ADDR_HEX.len(), 42);
    }
}
