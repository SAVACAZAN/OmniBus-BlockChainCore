//! Canonical genesis block. Values copied verbatim from
//! `core/chain_config.zig` + `core/genesis.zig`.
//!
//! All four networks share the same canonical genesis hash by design —
//! networks are separated by `NetworkMagic`, not by genesis hash (see
//! `core/chain_config.zig:192`). The hash below is locked by the Zig test
//! `genesis.zig::"canonical genesis hash matches Block.calculateHash"`.

use super::block::Block;

/// Canonical genesis hash shared across mainnet/testnet/devnet/regtest.
/// Computed as `SHA256(ascii("00<prev_hash>0") || zeros32 || zeros32)`
/// where `<prev_hash>` is 64 ascii '0' chars. See `Block::calculate_hash`.
pub const GENESIS_HASH_HEX: &str =
    "82ec46e83af37b1ea0e6b3fe66a8f04795a8e8aae7db414d451eff1154245982";

/// 26 Mar 2026 00:00:00 UTC.
pub const GENESIS_TIMESTAMP: i64 = 1_743_000_000;

/// Protocol version at genesis.
pub const GENESIS_VERSION: u32 = 1;

/// Parent hash for the genesis block — 64 ascii '0' chars.
pub const GENESIS_PREV_HASH: &str =
    "0000000000000000000000000000000000000000000000000000000000000000";

/// Mainnet message embedded for provenance (not hashed by `calculate_hash`,
/// kept here for compatibility with the Zig API surface).
pub const GENESIS_MESSAGE_MAINNET: &str =
    "26/Mar/2026 OmniBus born — 600x faster than Bitcoin — Ada Spark verified — ob_omni_";

pub const GENESIS_MESSAGE_TESTNET: &str =
    "OmniBus Testnet Genesis — faucet enabled — no real value";

/// Identifies one of the four canonical networks.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ChainId {
    Mainnet = 1,
    Testnet = 2,
    Devnet = 3,
    Regtest = 4,
}

/// 4-byte P2P network magic (Bitcoin-style). Values match
/// `core/chain_config.zig::NetworkMagic`.
#[derive(Debug, Clone, Copy)]
pub struct NetworkMagic(pub [u8; 4]);

impl NetworkMagic {
    pub const MAINNET: NetworkMagic = NetworkMagic(*b"OMNI");
    pub const TESTNET: NetworkMagic = NetworkMagic(*b"TEST");
    pub const DEVNET: NetworkMagic = NetworkMagic(*b"DEVN");
    pub const REGTEST: NetworkMagic = NetworkMagic(*b"REGT");

    pub fn for_chain(chain_id: ChainId) -> Self {
        match chain_id {
            ChainId::Mainnet => Self::MAINNET,
            ChainId::Testnet => Self::TESTNET,
            ChainId::Devnet => Self::DEVNET,
            ChainId::Regtest => Self::REGTEST,
        }
    }
}

/// Per-network bootstrap parameters. Sibling to `ChainConfig` in Zig.
#[derive(Debug, Clone)]
pub struct ChainConfig {
    pub chain_id: ChainId,
    pub name: &'static str,
    pub magic: NetworkMagic,
    pub genesis_hash: &'static str,
    pub genesis_timestamp: i64,
    pub genesis_message: &'static str,
    pub max_supply_sat: u64,
    pub initial_reward_sat: u64,
    pub halving_interval: u64,
    pub block_time_ms: u32,
    pub sub_blocks_per_block: u8,
    pub rpc_port: u16,
    pub p2p_port: u16,
    pub ws_port: u16,
    pub initial_difficulty: u32,
}

impl ChainConfig {
    pub const fn mainnet() -> Self {
        Self {
            chain_id: ChainId::Mainnet,
            name: "omnibus-mainnet",
            magic: NetworkMagic::MAINNET,
            genesis_hash: GENESIS_HASH_HEX,
            genesis_timestamp: GENESIS_TIMESTAMP,
            genesis_message: GENESIS_MESSAGE_MAINNET,
            max_supply_sat: 21_000_000_000_000_000,
            initial_reward_sat: 8_333_333,
            halving_interval: 126_144_000,
            block_time_ms: 1_000,
            sub_blocks_per_block: 10,
            rpc_port: 8332,
            p2p_port: 8333,
            ws_port: 8334,
            initial_difficulty: 4,
        }
    }

    pub const fn testnet() -> Self {
        Self {
            chain_id: ChainId::Testnet,
            name: "omnibus-testnet",
            magic: NetworkMagic::TESTNET,
            genesis_hash: GENESIS_HASH_HEX,
            genesis_timestamp: GENESIS_TIMESTAMP,
            genesis_message: GENESIS_MESSAGE_TESTNET,
            max_supply_sat: 21_000_000_000_000_000,
            initial_reward_sat: 8_333_333,
            halving_interval: 126_144_000,
            block_time_ms: 1_000,
            sub_blocks_per_block: 10,
            rpc_port: 18332,
            p2p_port: 18333,
            ws_port: 18334,
            initial_difficulty: 1,
        }
    }

    pub const fn regtest() -> Self {
        Self {
            chain_id: ChainId::Regtest,
            name: "omnibus-regtest",
            magic: NetworkMagic::REGTEST,
            genesis_hash: GENESIS_HASH_HEX,
            genesis_timestamp: GENESIS_TIMESTAMP,
            genesis_message: "OmniBus Regtest Genesis — regression testing, difficulty 1",
            max_supply_sat: 21_000_000_000_000_000,
            initial_reward_sat: 8_333_333,
            halving_interval: 126_144_000,
            block_time_ms: 1_000,
            sub_blocks_per_block: 10,
            rpc_port: 28332,
            p2p_port: 28333,
            ws_port: 28334,
            initial_difficulty: 1,
        }
    }
}

/// Build the canonical genesis `Block` for the given chain. The cached
/// `hash` field is set to `GENESIS_HASH_HEX` directly — verified by
/// recomputation in tests on the Zig side.
pub fn build_genesis_block(cfg: &ChainConfig) -> Block {
    let mut b = Block::new(0, GENESIS_PREV_HASH.to_string(), cfg.genesis_timestamp);
    b.nonce = 0;
    b.merkle_root = [0u8; 32];
    b.prices_root = [0u8; 32];
    b.hash = cfg.genesis_hash.to_string();
    b
}

/// Convenience: mainnet genesis.
pub fn mainnet_genesis() -> Block {
    build_genesis_block(&ChainConfig::mainnet())
}

/// Convenience: testnet genesis.
pub fn testnet_genesis() -> Block {
    build_genesis_block(&ChainConfig::testnet())
}
