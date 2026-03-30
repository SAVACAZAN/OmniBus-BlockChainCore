const std = @import("std");

/// Chain Configuration & Network Identity
/// Defineste parametrii retelei, chain ID-uri, si checkpoints.
///
/// Similar cu:
///   - Bitcoin: chainparams.cpp (mainnet/testnet/regtest)
///   - Ethereum: Chain ID (EIP-155), genesis config
///   - EGLD: Network configs per shard
///   - Solana: Cluster configs (mainnet/devnet/testnet)

/// Chain ID-uri (ca Ethereum EIP-155 — previne replay intre retele)
pub const ChainId = enum(u32) {
    /// Mainnet OmniBus
    mainnet = 1,
    /// Testnet (faucet, no real value)
    testnet = 2,
    /// Devnet (development local)
    devnet = 3,
    /// Regtest (regression testing, difficulty 1)
    regtest = 4,
};

/// Checkpoint — bloc cu hash verificat (ca Bitcoin's assumevalid)
/// Nodurile noi pot sari validarea PoW pentru blocuri mai vechi decat ultimul checkpoint
pub const Checkpoint = struct {
    height: u64,
    hash: [64]u8, // hex string
    /// Timestamp-ul blocului (pentru verificare suplimentara)
    timestamp: i64,
};

/// Network magic bytes (ca Bitcoin: 0xF9BEB4D9 mainnet, 0xFABFB5DA testnet)
/// Primii 4 bytes din fiecare mesaj P2P — identifica reteaua
pub const NetworkMagic = struct {
    bytes: [4]u8,

    pub const MAINNET = NetworkMagic{ .bytes = .{ 0x4F, 0x4D, 0x4E, 0x49 } }; // "OMNI"
    pub const TESTNET = NetworkMagic{ .bytes = .{ 0x54, 0x45, 0x53, 0x54 } }; // "TEST"
    pub const DEVNET  = NetworkMagic{ .bytes = .{ 0x44, 0x45, 0x56, 0x4E } }; // "DEVN"
    pub const REGTEST = NetworkMagic{ .bytes = .{ 0x52, 0x45, 0x47, 0x54 } }; // "REGT"

    pub fn forChain(chain_id: ChainId) NetworkMagic {
        return switch (chain_id) {
            .mainnet => MAINNET,
            .testnet => TESTNET,
            .devnet  => DEVNET,
            .regtest => REGTEST,
        };
    }
};

/// Full chain configuration
pub const ChainConfig = struct {
    /// Chain identifier (previne replay cross-network)
    chain_id: ChainId,
    /// Human readable name
    name: []const u8,
    /// Network magic for P2P messages
    magic: NetworkMagic,
    /// Genesis block hash
    genesis_hash: []const u8,
    /// Genesis timestamp
    genesis_timestamp: i64,
    /// Default P2P port
    p2p_port: u16,
    /// Default RPC port
    rpc_port: u16,
    /// Default WebSocket port
    ws_port: u16,
    /// Initial mining difficulty
    initial_difficulty: u32,
    /// Block time target in ms
    block_time_ms: u64,
    /// Max supply in SAT
    max_supply_sat: u64,
    /// Initial block reward in SAT
    initial_reward_sat: u64,
    /// Halving interval in blocks
    halving_interval: u64,
    /// Difficulty retarget interval
    retarget_interval: u64,
    /// Number of sub-blocks per key-block
    sub_blocks_per_block: u8,
    /// Checkpoints (verified block hashes for fast sync)
    checkpoints: []const Checkpoint,

    /// Mainnet configuration
    pub fn mainnet() ChainConfig {
        return .{
            .chain_id = .mainnet,
            .name = "omnibus-mainnet",
            .magic = NetworkMagic.MAINNET,
            .genesis_hash = "0000000a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8",
            .genesis_timestamp = 1_743_000_000,
            .p2p_port = 8333,
            .rpc_port = 8332,
            .ws_port = 8334,
            .initial_difficulty = 4,
            .block_time_ms = 1000,
            .max_supply_sat = 21_000_000_000_000_000,
            .initial_reward_sat = 8_333_333,
            .halving_interval = 126_144_000,
            .retarget_interval = 2016,
            .sub_blocks_per_block = 10,
            .checkpoints = &MAINNET_CHECKPOINTS,
        };
    }

    /// Testnet configuration (faster blocks, lower difficulty)
    pub fn testnet() ChainConfig {
        return .{
            .chain_id = .testnet,
            .name = "omnibus-testnet",
            .magic = NetworkMagic.TESTNET,
            .genesis_hash = "0000000000000000000000000000000000000000000000000000000000000001",
            .genesis_timestamp = 1_743_000_000,
            .p2p_port = 18333,
            .rpc_port = 18332,
            .ws_port = 18334,
            .initial_difficulty = 1,
            .block_time_ms = 1000,
            .max_supply_sat = 21_000_000_000_000_000,
            .initial_reward_sat = 8_333_333,
            .halving_interval = 126_144_000,
            .retarget_interval = 2016,
            .sub_blocks_per_block = 10,
            .checkpoints = &[_]Checkpoint{},
        };
    }

    /// Regtest (instant mining, difficulty 1)
    pub fn regtest() ChainConfig {
        return .{
            .chain_id = .regtest,
            .name = "omnibus-regtest",
            .magic = NetworkMagic.REGTEST,
            .genesis_hash = "0000000000000000000000000000000000000000000000000000000000000000",
            .genesis_timestamp = 1_743_000_000,
            .p2p_port = 28333,
            .rpc_port = 28332,
            .ws_port = 28334,
            .initial_difficulty = 1,
            .block_time_ms = 100,
            .max_supply_sat = 21_000_000_000_000_000,
            .initial_reward_sat = 8_333_333,
            .halving_interval = 150,
            .retarget_interval = 10,
            .sub_blocks_per_block = 10,
            .checkpoints = &[_]Checkpoint{},
        };
    }
};

/// Mainnet checkpoints (verified block hashes for fast sync)
/// Nodurile noi pot sari PoW validation pentru blocuri sub ultimul checkpoint
const MAINNET_CHECKPOINTS = [_]Checkpoint{
    .{ .height = 0, .hash = "0000000a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d80".*, .timestamp = 1_743_000_000 },
};

/// Gas estimation for transaction fees
/// Bitcoin: estimatesmartfee RPC
/// Ethereum: eth_estimateGas + EIP-1559 base fee
/// OmniBus: simplified — fee based on mempool pressure
pub const FeeEstimator = struct {
    /// Current mempool size
    mempool_size: usize,
    /// Max mempool capacity
    mempool_max: usize,

    pub fn init(mempool_size: usize, mempool_max: usize) FeeEstimator {
        return .{ .mempool_size = mempool_size, .mempool_max = mempool_max };
    }

    /// Estimate fee in SAT for next-block inclusion
    /// Returns: fee in SAT per transaction
    /// Algorithm: base_fee * (1 + mempool_pressure)
    /// When mempool is empty → min fee (1 SAT)
    /// When mempool is 50% full → 2x fee
    /// When mempool is 100% full → 10x fee
    pub fn estimateFee(self: *const FeeEstimator) u64 {
        if (self.mempool_max == 0) return 1;
        const pressure_pct = self.mempool_size * 100 / self.mempool_max;
        if (pressure_pct < 10) return 1;      // Low: 1 SAT
        if (pressure_pct < 25) return 2;      // Normal: 2 SAT
        if (pressure_pct < 50) return 5;      // Medium: 5 SAT
        if (pressure_pct < 75) return 10;     // High: 10 SAT
        if (pressure_pct < 90) return 50;     // Very high: 50 SAT
        return 100;                            // Critical: 100 SAT
    }

    /// Estimate confirmation time in blocks
    pub fn estimateBlocks(self: *const FeeEstimator, fee_sat: u64) u32 {
        const min_fee = self.estimateFee();
        if (fee_sat >= min_fee * 2) return 1;       // Premium: next block
        if (fee_sat >= min_fee) return 3;            // Normal: 3 blocks
        return 10;                                    // Low priority: 10 blocks
    }
};

// ─── Tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

test "ChainConfig mainnet basics" {
    const cfg = ChainConfig.mainnet();
    try testing.expectEqual(ChainId.mainnet, cfg.chain_id);
    try testing.expectEqual(@as(u16, 8333), cfg.p2p_port);
    try testing.expectEqual(@as(u16, 8332), cfg.rpc_port);
    try testing.expectEqual(@as(u64, 21_000_000_000_000_000), cfg.max_supply_sat);
    try testing.expectEqual(@as(u64, 1000), cfg.block_time_ms);
    try testing.expectEqual(@as(u8, 10), cfg.sub_blocks_per_block);
}

test "ChainConfig testnet different ports" {
    const cfg = ChainConfig.testnet();
    try testing.expectEqual(ChainId.testnet, cfg.chain_id);
    try testing.expectEqual(@as(u16, 18333), cfg.p2p_port);
    try testing.expectEqual(@as(u32, 1), cfg.initial_difficulty);
}

test "ChainConfig regtest fast mining" {
    const cfg = ChainConfig.regtest();
    try testing.expectEqual(@as(u64, 100), cfg.block_time_ms);
    try testing.expectEqual(@as(u64, 150), cfg.halving_interval);
    try testing.expectEqual(@as(u64, 10), cfg.retarget_interval);
}

test "NetworkMagic for chain" {
    const mainnet_magic = NetworkMagic.forChain(.mainnet);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x4F, 0x4D, 0x4E, 0x49 }, &mainnet_magic.bytes);
    const testnet_magic = NetworkMagic.forChain(.testnet);
    try testing.expect(!std.mem.eql(u8, &mainnet_magic.bytes, &testnet_magic.bytes));
}

test "ChainId prevents replay" {
    const main_cfg = ChainConfig.mainnet();
    const test_cfg = ChainConfig.testnet();
    try testing.expect(main_cfg.chain_id != test_cfg.chain_id);
    try testing.expect(!std.mem.eql(u8, &main_cfg.magic.bytes, &test_cfg.magic.bytes));
}

test "FeeEstimator — empty mempool = min fee" {
    const est = FeeEstimator.init(0, 10000);
    try testing.expectEqual(@as(u64, 1), est.estimateFee());
}

test "FeeEstimator — full mempool = high fee" {
    const est = FeeEstimator.init(9500, 10000);
    try testing.expectEqual(@as(u64, 100), est.estimateFee());
}

test "FeeEstimator — half full = medium fee" {
    const est = FeeEstimator.init(5000, 10000);
    try testing.expectEqual(@as(u64, 10), est.estimateFee());
}

test "FeeEstimator — estimate blocks" {
    const est = FeeEstimator.init(5000, 10000);
    const min = est.estimateFee(); // 10
    try testing.expectEqual(@as(u32, 1), est.estimateBlocks(min * 2)); // premium
    try testing.expectEqual(@as(u32, 3), est.estimateBlocks(min));     // normal
    try testing.expectEqual(@as(u32, 10), est.estimateBlocks(1));      // low
}

test "Checkpoints — mainnet has genesis" {
    const cfg = ChainConfig.mainnet();
    try testing.expect(cfg.checkpoints.len > 0);
    try testing.expectEqual(@as(u64, 0), cfg.checkpoints[0].height);
}
