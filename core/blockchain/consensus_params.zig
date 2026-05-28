// Consensus parameters + standalone helpers extracted from blockchain.zig.
//
// This module contains ONLY entities with zero references to the
// `Blockchain` struct: tunable constants, pure helper functions
// (blockWork, retargetDifficulty, blockRewardAt), and plain-old-data
// types (ConsensusParams, PqIdentity, StakeMeta, MultisigConfigEntry).
//
// Everything here is re-exported from blockchain.zig for backwards
// compatibility, so existing call sites (`blockchain_mod.BLOCK_REWARD_SAT`
// etc.) keep working unchanged.

const std = @import("std");
const multisig_mod = @import("../multisig.zig");

/// Block reward: 0.08333333 OMNI in SAT (9 decimale: 1 OMNI = 1,000,000,000 sat)
/// Echivalent cu 50 OMNI la 10 minute (600 blocuri × 0.08333333 = 50 OMNI)
/// Identic economic cu Bitcoin (50 BTC / 10 min), dar la viteza de 1 bloc/secunda
pub const BLOCK_REWARD_SAT: u64 = 8_333_333; // 0.08333333 OMNI
pub const HALVING_INTERVAL: u64 = 126_144_000; // 4 ani × 365.25 zile × 86400 sec/zi

/// Numarul total de SAT emisi vreodata: 21,000,000 × 10^9 = 21 × 10^15
pub const MAX_SUPPLY_SAT: u64 = 21_000_000_000_000_000;

/// Coinbase maturity: block rewards nu pot fi cheltuite inainte de N confirmari
/// Bitcoin: 100 blocks, Dogecoin: 100 blocks
/// OmniBus: 100 blocks (~100 secunde la 1 block/s)
pub const COINBASE_MATURITY: u32 = 100;

/// Dust threshold: TX cu amount sub aceasta valoare sunt respinse
/// Bitcoin: 546 sat, Dogecoin: 1 DOGE
/// OmniBus: 100 SAT (0.0000001 OMNI)
pub const DUST_THRESHOLD_SAT: u64 = 100;

/// Maximum reorg depth: deeper chain reorganizations are rejected for safety.
/// Bitcoin's practical limit is ~100 blocks; we use the same.
pub const MAX_REORG_DEPTH: usize = 100;

/// Maximum orphan blocks kept in the pool (prevent memory exhaustion)
pub const MAX_ORPHAN_POOL: usize = 64;

/// Difficulty retarget: la fiecare 2016 blocuri (ca Bitcoin)
pub const RETARGET_INTERVAL: u64 = 2016;
/// Timp tinta per bloc: 1 secunda (OmniBus block time)
pub const TARGET_BLOCK_TIME_S: i64 = 1;
/// Timp tinta total pentru un interval retarget: 2016 secunde
pub const TARGET_INTERVAL_S: i64 = @intCast(RETARGET_INTERVAL); // 2016s
/// Dificultate minima si maxima permisa
/// Extended range: MAX=256 (was 32) — closer to Bitcoin's full difficulty range
/// Bitcoin difficulty can go up to ~80 trillion; 256 leading zero bits = full SHA-256
pub const MIN_DIFFICULTY: u32 = 1;
pub const MAX_DIFFICULTY: u32 = 256;

/// Fee burn percentage (0-100): ce procent din fees se ard (ca EIP-1559)
/// Default 50%: jumatate la miner, jumatate arse (deflationary pressure)
/// Configurabil prin governance
pub const FEE_BURN_PCT: u64 = 50;

/// Minimum fee per transaction (1 SAT anti-spam, same as mempool)
pub const TX_MIN_FEE: u64 = 1;

/// Work contributed by a single block at the given difficulty. Bitcoin
/// uses work = 2^256 / target; we use difficulty in leading-zero hex
/// digits, so target = 2^(256 - 4*difficulty), and work ≈ 2^(4*difficulty).
/// Returns u128 — at MAX_DIFFICULTY=32 this is 2^128, then accumulates
/// over millions of blocks without overflow.
pub fn blockWork(difficulty: u32) u128 {
    if (difficulty == 0) return 1;
    const shift: u7 = @intCast(@min(@as(u32, 127), difficulty * 4));
    return @as(u128, 1) << shift;
}

/// Calculeaza noua dificultate dupa un interval de retarget.
/// Formula: new_difficulty = old_difficulty * TARGET_INTERVAL / actual_time
/// Clamped la ±4x fata de dificultatea anterioara (ca Bitcoin) si [MIN, MAX].
pub fn retargetDifficulty(old_difficulty: u32, actual_time_s: i64) u32 {
    if (actual_time_s <= 0) return old_difficulty;

    // Clamp actual time la [target/4, target*4] (ca Bitcoin)
    const clamped_time = @max(TARGET_INTERVAL_S / 4, @min(TARGET_INTERVAL_S * 4, actual_time_s));

    // new = old * TARGET / actual  (integer math)
    const old: i64 = @intCast(old_difficulty);
    const new_diff_i64 = @divTrunc(old * TARGET_INTERVAL_S, clamped_time);

    // Clamp la [MIN_DIFFICULTY, MAX_DIFFICULTY]
    if (new_diff_i64 < MIN_DIFFICULTY) return MIN_DIFFICULTY;
    if (new_diff_i64 > MAX_DIFFICULTY) return MAX_DIFFICULTY;
    return @intCast(new_diff_i64);
}

pub fn blockRewardAt(height: u64) u64 {
    const halvings = height / HALVING_INTERVAL;
    if (halvings >= 64) return 0;
    return BLOCK_REWARD_SAT >> @intCast(halvings);
}

/// Entry for storing a multisig config alongside its address string.
pub const MultisigConfigEntry = struct {
    address: [64]u8 = [_]u8{0} ** 64,
    address_len: u8 = 0,
    config: multisig_mod.MultisigConfig = .{
        .threshold = 0,
        .total = 0,
        .pubkeys = [_][33]u8{[_]u8{0} ** 33} ** multisig_mod.MAX_SIGNERS,
        .pubkey_count = 0,
    },
};

/// Mutable consensus parameters that on-chain governance can override at
/// runtime. The hardcoded constants above (BLOCK_REWARD_SAT, MIN_DIFFICULTY,
/// etc.) are the bootstrap defaults; once a passing proposal calls
/// executeProposal, the corresponding field below is the live value used by
/// mining/validation/RPC.
///
/// Plain-old-data so it can be zero-initialised, copied, and (eventually)
/// persisted as part of chain.dat without owned slices to free.
pub const ConsensusParams = struct {
    /// Per-block coinbase reward in SAT. Bootstrapped to BLOCK_REWARD_SAT;
    /// updates apply to *future* blocks (existing block.reward_sat values
    /// stay intact for replay determinism).
    block_reward_sat: u64 = BLOCK_REWARD_SAT,
    /// Floor for PoW difficulty after retarget (clamps retargetDifficulty
    /// output). Bootstrapped to MIN_DIFFICULTY.
    min_difficulty: u32 = MIN_DIFFICULTY,
    /// Maximum block size in bytes. Bootstrapped to block.MAX_BLOCK_SIZE.
    block_size_limit: u64 = 1_048_576,
    /// Maximum size of a single PQ signature in bytes. Default 5KB covers
    /// SLH-DSA-256s (~30KB → set higher in PQ proposals).
    pq_signature_max: u64 = 5_120,
    /// Whether DNS records must be signed by the owner key for acceptance.
    dns_signed_required: bool = false,
    /// Minimum number of validators required for finality quorum. Default 2
    /// matches GENESIS_VALIDATORS bootstrap; raise via governance once the
    /// active set grows.
    validator_quorum_min: u32 = 2,
    /// When true, TX fees collected via applyExchangeFees flow to the next
    /// block's miner instead of the exchange treasury. Default true (Bitcoin-
    /// style miner incentive); flip via governance to revert to treasury.
    route_fees_to_miner: bool = true,
};

/// Cross-chain identity record — registered via op_return "pq_attest_v1:".
/// Stores the 4 soulbound domain addresses + optional BTC/ETH addresses.
/// First-claim wins: once registered, cannot be overwritten.
pub const PqIdentity = struct {
    /// The 4 soulbound domain addresses (ob_k1_/ob_f5_/ob_d5_/ob_s3_)
    love:     [128]u8 = [_]u8{0} ** 128,
    love_len: u8 = 0,
    food:     [128]u8 = [_]u8{0} ** 128,
    food_len: u8 = 0,
    rent:     [128]u8 = [_]u8{0} ** 128,
    rent_len: u8 = 0,
    vacation: [128]u8 = [_]u8{0} ** 128,
    vacation_len: u8 = 0,
    /// Optional cross-chain addresses (BTC native bech32, ETH 0x...)
    btc:     [128]u8 = [_]u8{0} ** 128,
    btc_len: u8 = 0,
    eth:     [64]u8 = [_]u8{0} ** 64,
    eth_len: u8 = 0,
    /// Block height when registered (for confirmations)
    attest_block: u64 = 0,
    /// TX hash of the attest transaction
    attest_tx: [64]u8 = [_]u8{0} ** 64,
    attest_tx_len: u8 = 0,

    pub fn loveSlice(self: *const PqIdentity) []const u8 { return self.love[0..self.love_len]; }
    pub fn foodSlice(self: *const PqIdentity) []const u8 { return self.food[0..self.food_len]; }
    pub fn rentSlice(self: *const PqIdentity) []const u8 { return self.rent[0..self.rent_len]; }
    pub fn vacationSlice(self: *const PqIdentity) []const u8 { return self.vacation[0..self.vacation_len]; }
    pub fn btcSlice(self: *const PqIdentity) []const u8 { return self.btc[0..self.btc_len]; }
    pub fn ethSlice(self: *const PqIdentity) []const u8 { return self.eth[0..self.eth_len]; }
    pub fn attestTxSlice(self: *const PqIdentity) []const u8 { return self.attest_tx[0..self.attest_tx_len]; }
};

/// Lock metadata for a single address's stake. Updated when a new
/// `stake:<amt>[:<lock_blocks>]` TX lands. On partial top-up we keep
/// the EARLIEST started_at_block (so the lock started when the
/// first OMNI was staked) and the MAX lock_blocks across top-ups
/// (the stake is now bound to the longest period the user committed).
pub const StakeMeta = struct {
    /// Block height at which the current stake started accumulating.
    /// 0 means "unknown" (legacy stakes loaded from older chain.dat).
    started_at_block: u64,
    /// Number of blocks the user committed to lock for. 0 = no lock
    /// (immediate unstake allowed, like the old behaviour).
    lock_blocks: u64,

    /// Returns the block height at which the lock expires. Caller
    /// compares with `chain.items.len`; if >= unlock_at, unstake is
    /// allowed.
    pub fn unlockAtBlock(self: StakeMeta) u64 {
        return self.started_at_block + self.lock_blocks;
    }
};
