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

/// Bridge Vault — smart contract address derived deterministically from
/// `keccak256("OMNIBUS_BRIDGE_VAULT_V1")[12..]` (last 20 bytes).
/// Since this is purely a function of the literal string, ANY full node
/// can recompute and verify the address — no trust needed.
///
/// The contract holds locked OMNI balances waiting to be relayed to
/// partner chains (Liberty testnet, Base Sepolia, etc). It has NO
/// private key — funds move only via the contract's bridge logic
/// gated by relayer signatures (multi-sig threshold inside the contract).
///
/// To rotate (V2, etc), bump the version suffix and re-derive — old
/// vault remains as historical state until drain-and-migrate.
pub const BRIDGE_VAULT_ADDR_HEX = "0xd58169164e9a3b9390dc3e25817d6a385718e409";

/// Bridge wallet — separate adresa derivată tot determinist, folosită
/// pentru tranzacțiile non-EVM (dacă cineva trimite OMNI direct la o
/// adresă wallet, nu printr-un contract call). Simbolic — în practica
/// curentă V1 toate fondurile merg prin contract.
pub const BRIDGE_WALLET_ADDR_HEX = "0x835947f3731ecd6ca7f14c3c17f9f0fc231987c9";

// ─── Native Bridge V1 — Defense-in-Depth Limits ─────────────────────────────
//
// Lessons from 2022-2026 bridge hacks (Ronin $625M, Wormhole $326M, Nomad
// $190M, Kelp DAO $292M Apr 2026): >90% of losses came from key management
// and missing source validation. We mitigate at the consensus layer:
//
//   1. Per-tx hard cap          → blast radius of any single failure
//   2. Per-day rolling cap      → catastrophic-drain protection
//   3. Threshold multi-sig      → no single relayer key compromise
//   4. Challenge window         → optimistic verification, fraud-proof time
//   5. Non-upgradeable          → no Nomad-style "set merkle root to 0"
//
// All numbers are CONSERVATIVE start values. Increase only after audit + TVL.

/// Maximum OMNI that can be locked in a single bridge TX (in SAT).
/// Default: 100 OMNI = 100_000_000_000 SAT. Conservative — bumps require
/// chain upgrade vote. Lecția Ronin: blast radius matters.
pub const BRIDGE_MAX_PER_TX_SAT: u64 = 100_000_000_000;

/// Rolling 24h limit across ALL bridge locks combined (in SAT).
/// Default: 1000 OMNI = 1_000_000_000_000 SAT. Anything over auto-rejects
/// at consensus level (block validation), cannot be bypassed without fork.
pub const BRIDGE_MAX_DAILY_SAT: u64 = 1_000_000_000_000;

/// Window in blocks for the rolling-day limit. With 1s blocks: 86400.
pub const BRIDGE_DAILY_WINDOW_BLOCKS: u64 = 86_400;

// ─── PQ deterministic signing (FAZA 6 feature flag) ──────────────────────────
//
// When `true`, `wallet.signWithAllPQDomains` derives PQ keypairs deterministically
// from the BIP-39 master seed via `bip32_wallet.derivePQSeed` (HKDF-SHA512). Same
// mnemonic always recovers the same PQ keys → soulbound badges survive restore.
//
// When `false` (current mainnet default), legacy non-deterministic behavior is
// preserved: `pq_crypto.generateKeyPair()` returns random keys on every call.
// This is the broken-but-shipped behavior — keeping it the default avoids a
// silent consensus change on mainnet nodes that don't recompile.
//
// Flipping this to `true` on a chain with existing PQ-derived state is a
// HARD FORK. Migration path: `core/pq_migrate_consensus.zig` defines a
// `pq_migrate_v1` consensus TX type that binds old_pubkey → new_pubkey with
// a self-signed proof-of-ownership. See `PQ_MIGRATION_PLAN.md` at repo root.
//
// Test/regtest builds set `zig build -Dpq_deterministic=true` to enable.
// The `build_options.pq_deterministic_signing` value overrides this default at
// compile time; if the build_options field is missing (e.g. when building a
// test binary without the options module) we fall back to `false`.
const build_options = @import("build_options");
pub const PQ_DETERMINISTIC_SIGNING: bool = if (@hasDecl(build_options, "pq_deterministic_signing"))
    build_options.pq_deterministic_signing
else
    false;

/// Minimum signatures required to unlock from the bridge vault.
/// Default: 3 of N. Lecția Kelp DAO (1/1 DVN forjat = $292M): never trust
/// a single relayer. Lecția Ronin: 5/9 with all keys on same infra was
/// also compromised — distribuiți cheile pe HW separat fizic.
pub const BRIDGE_REQUIRED_SIGS: u8 = 3;

/// Maximum number of registered relayers. Even with all N compromised,
/// the threshold above is the security floor.
pub const BRIDGE_MAX_RELAYERS: u8 = 9;

/// After threshold sigs are collected for an unlock, the request enters
/// a challenge window before funds move. Anyone can submit a fraud-proof
/// during this period (e.g., showing the destination chain mint event
/// never happened, or amount mismatch). Default: 6h = 21600 blocks @ 1s.
pub const BRIDGE_CHALLENGE_WINDOW_BLOCKS: u64 = 21_600;

/// Auto-pause threshold: if locked volume in a single block exceeds this
/// fraction of the daily limit, bridge halts pending manual review.
/// 0.30 = 30%. A single block draining 30% of daily quota = anomaly.
pub const BRIDGE_AUTO_PAUSE_BLOCK_FRACTION_BPS: u16 = 3_000; // 30.00%

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
            // Canonical genesis hash = SHA256( fmt("{0}{1743000000}{prev_64_zeros}{0}")
            //                                  ++ merkle_root[32]=zero
            //                                  ++ prices_root[32]=zero )
            // i.e. Block.calculateHash() applied to the genesis block in
            // genesis.zig:buildBlockchain. Cross-network collision with testnet
            // is intentional and safe — the P2P handshake's chain_magic ("OMNI"
            // vs "TEST") separates the networks before any block is exchanged.
            // Locked by the "canonical genesis hash matches calculateHash" test.
            .genesis_hash = "82ec46e83af37b1ea0e6b3fe66a8f04795a8e8aae7db414d451eff1154245982",
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
            // Same canonical genesis hash as mainnet (see note there); chain
            // separation is enforced by NetworkMagic, not by the genesis hash.
            .genesis_hash = "82ec46e83af37b1ea0e6b3fe66a8f04795a8e8aae7db414d451eff1154245982",
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
            .checkpoints = &TESTNET_CHECKPOINTS,
        };
    }

    /// Devnet configuration (development local, easy mining, no isolation)
    pub fn devnet() ChainConfig {
        return .{
            .chain_id = .devnet,
            .name = "omnibus-devnet",
            .magic = NetworkMagic.DEVNET,
            .genesis_hash = "82ec46e83af37b1ea0e6b3fe66a8f04795a8e8aae7db414d451eff1154245982",
            .genesis_timestamp = 1_743_000_000,
            .p2p_port = 38333,
            .rpc_port = 38332,
            .ws_port = 38334,
            .initial_difficulty = 1,
            .block_time_ms = 500,
            .max_supply_sat = 21_000_000_000_000_000,
            .initial_reward_sat = 8_333_333,
            .halving_interval = 50_000,
            .retarget_interval = 100,
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
            .genesis_hash = "82ec46e83af37b1ea0e6b3fe66a8f04795a8e8aae7db414d451eff1154245982",
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

    /// Print configuration in a human-readable banner (similar to NetworkConfig.print)
    pub fn print(self: ChainConfig) void {
        const sat_per_omni: f64 = 1_000_000_000.0; // 1e9
        const max_supply_omni = @as(f64, @floatFromInt(self.max_supply_sat)) / sat_per_omni;
        const reward_omni = @as(f64, @floatFromInt(self.initial_reward_sat)) / sat_per_omni;

        std.debug.print(
            \\═══════════════════════════════════════════
            \\  Chain Configuration
            \\═══════════════════════════════════════════
            \\  Name              {s}
            \\  Chain ID          {d} ({s})
            \\  Magic             {s}
            \\  Genesis hash      {s}
            \\  Genesis timestamp {d}
            \\  P2P port          {d}
            \\  RPC port          {d}
            \\  WebSocket port    {d}
            \\  Block time        {d} ms
            \\  Initial difficulty {d}
            \\  Max supply        {d:.2} OMNI
            \\  Initial reward    {d:.8} OMNI
            \\  Halving interval  {d} blocks
            \\  Retarget interval {d} blocks
            \\  Sub-blocks/block  {d}
            \\  Checkpoints       {d}
            \\═══════════════════════════════════════════
            \\
        , .{
            self.name,
            @intFromEnum(self.chain_id),
            @tagName(self.chain_id),
            self.magic.bytes,
            self.genesis_hash[0..@min(16, self.genesis_hash.len)],
            self.genesis_timestamp,
            self.p2p_port,
            self.rpc_port,
            self.ws_port,
            self.block_time_ms,
            self.initial_difficulty,
            max_supply_omni,
            reward_omni,
            self.halving_interval,
            self.retarget_interval,
            self.sub_blocks_per_block,
            self.checkpoints.len,
        });
    }
};

/// Mainnet checkpoints (verified block hashes for fast sync + reorg protection).
/// A peer's chain that diverges below the highest checkpoint we know is
/// rejected outright — no amount of cumulative work can rewrite history
/// past these points. Founder signs these in each release.
const MAINNET_CHECKPOINTS = [_]Checkpoint{
    .{ .height = 0, .hash = "82ec46e83af37b1ea0e6b3fe66a8f04795a8e8aae7db414d451eff1154245982".*, .timestamp = 1_743_000_000 },
};

/// Testnet checkpoints — kept short, refreshed each release. Last verified
/// height is the highest block both VPS seeds + founder PC observed at
/// release time. Mostly to anchor the chain before the reorg logic ships.
/// Height-46000 checkpoint dropped: belongs to the pre-canonical-genesis chain
/// that was wiped on the 2026-05-18 reset; refresh after the new chain mines
/// past a stable height.
const TESTNET_CHECKPOINTS = [_]Checkpoint{
    .{ .height = 0, .hash = "82ec46e83af37b1ea0e6b3fe66a8f04795a8e8aae7db414d451eff1154245982".*, .timestamp = 1_743_000_000 },
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

test "ChainConfig print does not crash" {
    const cfg = ChainConfig.mainnet();
    cfg.print();
}
