const std = @import("std");
const block_mod = @import("block.zig");
const transaction_mod = @import("transaction.zig");
const tx_payload_mod = @import("tx_payload.zig");
const matching_mod = @import("matching_engine.zig");
const hex_utils = @import("hex_utils.zig");
const script_mod = @import("script.zig");
const multisig_mod = @import("multisig.zig");
const utxo_mod = @import("utxo.zig");
const oracle_types = @import("oracle_types.zig");
const validator_mod = @import("validator_registry.zig");
pub const Validator = validator_mod.Validator;
// `main_mod` and `ws_exchange_feed_mod` are imported lazily so the WS feed
// snapshot can be wired into mineBlockForMiner without forcing every test
// translation unit to pull in the full main.zig graph. Zig resolves these
// imports lazily — they only matter when the corresponding fields are touched.
const main_mod = @import("main.zig");
const staking_mod = @import("staking.zig");
const ws_exchange_feed_mod = @import("ws_exchange_feed.zig");
const dns_mod = @import("dns_registry.zig");
const registrar_mod = @import("registrar_addresses.zig");
const label_mod = @import("label.zig");
const sub_mod = @import("subscription.zig");
const notarize_mod = @import("notarize.zig");
const escrow_mod = @import("escrow.zig");
const social_mod = @import("social_graph.zig");
const poap_mod = @import("poap.zig");
const gov_mod    = @import("governance_onchain.zig");
const faucet_mod = @import("faucet.zig");
const htlc_mod   = @import("htlc.zig");
const swap_link_mod = @import("order_swap_link.zig");
const intent_reg_mod = @import("intent_registry.zig");
const cold_wallet_mod = @import("cold_wallet.zig");
const timelock_mod    = @import("timelock_vault.zig");
const covenant_mod    = @import("covenant.zig");
const treasury_multi_mod = @import("treasury_multi.zig");
const array_list = std.array_list;

pub const Block = block_mod.Block;
pub const Transaction = transaction_mod.Transaction;
pub const Outpoint = transaction_mod.Outpoint;
pub const TxOutput = transaction_mod.TxOutput;
/// Re-export so existing call sites (`blockchain_mod.BlockPriceEntry`) keep
/// working after the type was extracted into oracle_types.zig to break the
/// block.zig ↔ blockchain.zig circular import.
pub const BlockPriceEntry = oracle_types.BlockPriceEntry;

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

/// Total fees burned (tracked for supply accounting)
pub var total_fees_burned_sat: u64 = 0;

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

/// `BlockPriceEntry` was moved to `oracle_types.zig` to allow `block.zig`
/// to embed it directly without a circular import. It is re-exported above
/// as `blockchain_mod.BlockPriceEntry` so callers don't need to change.

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

pub const Blockchain = struct {
    chain: array_list.Managed(Block),
    mempool: array_list.Managed(Transaction),
    difficulty: u32,
    /// Cumulative chain work — Bitcoin-style heaviest-chain comparison.
    /// Each block contributes work = 1 << (4 * difficulty_at_block) (proxy
    /// for 2^256 / target). Used by reorg logic: a peer's chain replaces
    /// ours only if its cumulative_work strictly exceeds ours, and only
    /// if no hard checkpoint blocks the divergence.
    /// u128 because 2^32 difficulty * 2^64 max chain length comfortably
    /// fits and prevents overflow on long chains.
    cumulative_work: u128 = 0,
    /// Active validator set — slot-leader rotation reads from this list
    /// at every block. Initialised at genesis from
    /// validator_registry.GENESIS_VALIDATORS (bootstrap seed of 2 entries).
    /// Mutable thereafter via on-chain governance proposals (validator
    /// quorum / membership go through executeProposal). Address strings
    /// are static-lifetime (point at GENESIS_VALIDATORS data) until
    /// governance wires up dupe-on-add.
    validator_set: std.array_list.Managed(Validator),
    /// Mutable consensus parameters — governance proposals update this
    /// struct via executeProposal. See ConsensusParams above for fields.
    /// Defaults to the hardcoded constants at struct init.
    consensus_params: ConsensusParams = .{},
    /// Accumulator for exchange-engine network fees (FILL_NETWORK_FEE_SAT)
    /// that the matching engine collects between blocks. When the next
    /// block is mined / applied, this amount is credited to the miner
    /// alongside the coinbase reward and TX-level fees, then reset to 0.
    /// Bypasses the treasury entirely when consensus_params.route_fees_to_miner
    /// is true (the default — see applyExchangeFees and applyBlock).
    pending_miner_fees: u64 = 0,
    /// Cumulative network/exchange fees ever credited to miners (informational,
    /// surfaced via getminerstats). Distinct from per-TX fees which already
    /// flowed to miners via the existing total_fees pipeline.
    total_miner_exchange_fees: u64 = 0,
    allocator: std.mem.Allocator,
    /// Balantele adreselor (in-memory, sincronizat cu database)
    balances: std.StringHashMap(u64),
    /// Nonce tracking per adresa: urmatorul nonce asteptat (anti-replay, ca Ethereum)
    /// Previne replay attacks: aceeasi TX nu poate fi trimisa de doua ori
    nonces: std.StringHashMap(u64),
    /// Public key registry: address → compressed pubkey hex (66 chars)
    /// Folosit pentru verificarea semnaturii ECDSA in validateTransaction()
    pubkey_registry: std.StringHashMap([]const u8),
    /// TX hash → block height: tracks which block contains each transaction
    /// Used for confirmation counting (current_height - tx_block_height)
    tx_block_height: std.StringHashMap(u64),
    /// Cumulative stake per address (in SAT) — derived from `op_return` prefixes
    /// "stake:<amt>" (saturating add) and "unstake:<amt>" (saturating sub).
    /// Persisted to chain.dat v2 so VALIDATOR roles survive node restart even
    /// though full TX data isn't serialised (see database.zig stake_state section).
    stake_amounts: std.StringHashMap(u64),
    /// Per-address lock metadata for the current stake. Parallel to
    /// `stake_amounts` so DB persistence stays backward-compatible: old
    /// chain.dat files load with stake_amounts populated and stake_meta
    /// backfilled to `.{ .started_at_block = chain.len, .lock_blocks = 0 }`
    /// (no lock period for legacy stakes). New stakes set started_at_block
    /// to the block height at the time of the op_return TX, and parse an
    /// optional `:<lock_blocks>` suffix from "stake:<amt>:<lock_blocks>".
    stake_meta: std.StringHashMap(StakeMeta),
    /// Set of addresses that have registered as agents (`op_return` prefix
    /// "agent:register"). Persisted to chain.dat v2 (agent_state section) so
    /// AGENT roles survive restart.
    registered_agents: std.StringHashMap(void),
    /// Orphan block pool: blocks whose parent we don't have yet.
    /// When a new block arrives and connects, we re-check orphans.
    orphan_blocks: array_list.Managed(Block),
    /// Address TX index: address → list of TX hashes (reverse index for getaddresshistory)
    /// Includes both sent and received TXs, plus coinbase reward pseudo-entries.
    address_tx_index: std.StringHashMap(std.ArrayList([]const u8)),
    /// Multisig config registry: multisig address → MultisigConfig
    /// Stores the M-of-N configuration for each registered multisig wallet
    multisig_configs: [64]MultisigConfigEntry = [_]MultisigConfigEntry{MultisigConfigEntry{}} ** 64,
    multisig_count: u16 = 0,
    /// UTXO set — tracks all unspent transaction outputs (Bitcoin-compatible)
    utxo_set: utxo_mod.UTXOSet,
    /// Mutex — protejează chain/mempool/balances de data race (RPC + mining pe thread-uri diferite)
    mutex: std.Thread.Mutex = .{},

    /// PHASE C.3 — bc.balances write-only contract enforcement.
    ///
    /// `in_apply_block` is set to true while `applyBlock` is running; it
    /// signals that any balance mutation about to happen has a
    /// corresponding TX on chain (or coinbase reward). Mutations from
    /// outside that window are phantom credits/debits that get lost on
    /// restart — exactly the bug that wiped 51 testnet faucet balances
    /// last week.
    ///
    /// `stray_balance_writes` counts those phantom writes since process
    /// start. The mining-loop stabilizer reports this count once a
    /// minute and emits a loud [ALERT] when it grows.
    ///
    /// `mineBlockForMiner` and `recalculateFromHeight` also flip the
    /// flag while they replay TXs — same contract: if you're walking
    /// the chain, your writes are accounted for.
    ///
    /// Phase C.4 (chainstate KV refactor) deletes bc.balances entirely;
    /// until then this flag is the trip-wire.
    in_apply_block: bool = false,
    stray_balance_writes: u32 = 0,

    /// Auto-save: blocks mined since last save (triggers at 100)
    blocks_since_save: u32 = 0,
    /// Auto-save: unix timestamp of last save (triggers after 60s)
    last_save_time: i64 = 0,
    /// Auto-save: transactions processed since last save (triggers at 1000)
    txs_since_save: u32 = 0,
    /// Pointer to PersistentBlockchain — set by main after init
    persistent_db: ?*@import("database.zig").PersistentBlockchain = null,
    /// DB file path for auto-save
    db_path: []const u8 = "omnibus-chain.dat",
    /// DNS registry — set by main after init. Null in tests / nodes that
    /// run without NS support. When non-null, applyBlock auto-processes
    /// pay-to-claim TXs (op_return prefix `ns_claim:`) and registers names
    /// to the sender's address. See dns_registry.claimByPayment.
    dns_registry: ?*dns_mod.DnsRegistry = null,
    /// Per-block oracle price snapshot (6 slots: BTC×3 exchanges + LCX×3).
    /// Captured at mining time from g_ws_feed. In-memory only (not persisted
    /// to disk in DB v2, so a restart loses old prices but new blocks get fresh ones).
    /// Layout matches ws_exchange_feed.PriceFetch.
    block_prices: std.AutoHashMap(u32, [6]BlockPriceEntry) = undefined,
    block_prices_initialized: bool = false,

    /// PQ Identity attestation map: omni_address → PqIdentity.
    /// Populated when a TX with op_return "pq_attest_v1:..." is applied.
    /// First-claim wins — subsequent attests for the same omni_address are ignored.
    pq_identity_map: std.StringHashMap(PqIdentity),

    /// On-chain address label registry.
    /// Populated from op_return "label:<target>:<tag>[:<note>]" TXs.
    label_registry: label_mod.LabelRegistry,

    /// On-chain subscription registry.
    /// Populated from op_return "sub_create:..." TXs.
    /// Auto-executed per block in applyBlock.
    sub_registry: sub_mod.SubscriptionRegistry,

    /// On-chain document notarization registry.
    /// Populated from op_return "notarize:..." TXs.
    notarize_registry: notarize_mod.NotarizeRegistry,

    /// On-chain programmable escrow registry.
    escrow_registry: escrow_mod.EscrowRegistry,

    /// On-chain social graph (follow/unfollow).
    social_graph: social_mod.SocialGraph,

    /// POAP — Proof of Attendance Protocol (soulbound event badges).
    poap_registry: poap_mod.PoapRegistry,

    /// On-chain governance (propose / vote).
    gov_registry: gov_mod.GovernanceRegistry,

    /// Cold wallet (watch-only) registry.
    cold_wallet_store: cold_wallet_mod.ColdWalletStore,

    /// Pure CLTV timelock vault registry.
    timelock_store: timelock_mod.TimelockStore,

    /// Destination-whitelist covenant registry.
    covenant_store: covenant_mod.CovenantStore,

    /// Treasury auto-distribution registry.
    treasury_multi_store: treasury_multi_mod.TreasuryStore,

    /// Native cross-chain bridge state. Tracks locks, pending unlocks,
    /// processed nonces, daily volume cap (defense-in-depth from Ronin/
    /// Wormhole/Nomad/Kelp DAO post-mortems). Defined in bridge_native.zig.
    /// Nil-init via comptime literal — populated lazily on first bridge TX.
    bridge_state: ?@import("bridge_native.zig").BridgeState = null,

    /// PHASE 2B — pointer to the live matching engine attached by main.zig
    /// when the exchange is enabled on this node. Null on light nodes /
    /// replay paths; applyOrderTxs short-circuits when null so the chain
    /// stays consistent without consensus matching.
    exchange_engine: ?*matching_mod.MatchingEngine = null,

    /// PHASE 2F.2 — on-chain HTLC registry. Stores active/claimed/refunded
    /// hash-time-locked contracts created via TX type 0x30 (htlc_init) and
    /// transitioned via 0x31 (claim) / 0x32 (refund). State is fully
    /// persisted to data/<chain>/htlc_registry.bin via htlc_persist.zig so
    /// pending HTLCs survive restart. Funds locked in active HTLCs are
    /// virtually held — `bc.balances` is debited at init and re-credited
    /// to the matching party (recipient on claim, sender on refund). No
    /// UTXO movement happens for HTLC TXs themselves.
    htlc_registry: htlc_mod.HtlcOnChainRegistry = .{},

    /// PHASE 2F.5 — cross-chain atomic-swap binding registry. Populated by
    /// applyOrderTxs when an order_place TX carries a v2 cross-chain
    /// trailer (see core/order_swap_link.zig + tx_payload.OrderCrossChainTrailer).
    /// State machine: pending → both_locked → claimed | timed_out.
    /// Persisted alongside other registries to data/<chain>/swap_bindings.bin
    /// (caller wires the path via main.zig).
    swap_registry: swap_link_mod.SwapBindingRegistry = swap_link_mod.SwapBindingRegistry.init(),

    /// PHASE 2F.7 — bond accounting registry for cross-chain intents.
    /// applyIntentTx debits maker_bond at intent_post, taker_bond at
    /// intent_fill_commit, returns both on intent_settle, or slashes
    /// taker_bond → maker on intent_timeout. State persisted to
    /// data/<chain>/intent_registry.bin via core/intent_registry.zig.
    intent_registry: intent_reg_mod.IntentRegistry = intent_reg_mod.IntentRegistry.init(),

    /// PHASE 2D — fills produced per block height. Keyed by block.index,
    /// value is a heap-owned slice of Fill records generated when that
    /// block's order TXs ran through the matching engine. Initialised in
    /// init(), grown lazily as blocks produce fills. Empty for blocks
    /// that touched no orders. Persisted as a chain.dat v3 section so
    /// the trade history survives restart.
    fills_history: std.AutoHashMap(u32, []matching_mod.Fill) = undefined,

    pub fn init(allocator: std.mem.Allocator) !Blockchain {
        var chain = array_list.Managed(Block).init(allocator);
        const mempool = array_list.Managed(Transaction).init(allocator);

        // Create genesis block
        const genesis = Block{
            .index = 0,
            .timestamp = 1743000000,
            .transactions = array_list.Managed(Transaction).init(allocator),
            .previous_hash = "0000000000000000000000000000000000000000000000000000000000000000",
            .nonce = 0,
            .hash = "genesis_hash_omnibus_v1",
        };

        try chain.append(genesis);

        // Seed validator_set from the bootstrap registry. After genesis,
        // governance proposals add/remove entries on-chain. The bootstrap
        // is the ONLY hardcoded list — everything else is mutable state.
        var validator_set = array_list.Managed(Validator).init(allocator);
        for (validator_mod.GENESIS_VALIDATORS) |v| {
            try validator_set.append(v);
        }

        const bc = Blockchain{
            .chain = chain,
            .mempool = mempool,
            .difficulty = 4,
            .validator_set = validator_set,
            .allocator = allocator,
            .balances = std.StringHashMap(u64).init(allocator),
            .nonces = std.StringHashMap(u64).init(allocator),
            .pubkey_registry = std.StringHashMap([]const u8).init(allocator),
            .tx_block_height = std.StringHashMap(u64).init(allocator),
            .stake_amounts = std.StringHashMap(u64).init(allocator),
            .stake_meta = std.StringHashMap(StakeMeta).init(allocator),
            .registered_agents = std.StringHashMap(void).init(allocator),
            .orphan_blocks = array_list.Managed(Block).init(allocator),
            .address_tx_index = std.StringHashMap(std.ArrayList([]const u8)).init(allocator),
            .utxo_set = utxo_mod.UTXOSet.init(allocator),
            .block_prices = std.AutoHashMap(u32, [6]BlockPriceEntry).init(allocator),
            .block_prices_initialized = true,
            .fills_history = std.AutoHashMap(u32, []matching_mod.Fill).init(allocator),
            .pq_identity_map = std.StringHashMap(PqIdentity).init(allocator),
            .label_registry    = label_mod.LabelRegistry.init(allocator),
            .sub_registry      = sub_mod.SubscriptionRegistry.init(allocator),
            .notarize_registry = notarize_mod.NotarizeRegistry.init(allocator),
            .escrow_registry   = escrow_mod.EscrowRegistry.init(allocator),
            .social_graph      = social_mod.SocialGraph.init(allocator),
            .poap_registry     = poap_mod.PoapRegistry.init(allocator),
            .gov_registry      = gov_mod.GovernanceRegistry.init(allocator),
            .cold_wallet_store      = cold_wallet_mod.ColdWalletStore.init(allocator),
            .timelock_store         = timelock_mod.TimelockStore.init(allocator),
            .covenant_store         = covenant_mod.CovenantStore.init(allocator),
            .treasury_multi_store   = treasury_multi_mod.TreasuryStore.init(allocator),
        };
        return bc;
    }

    /// Snapshot oracle prices for a freshly mined block. Caller passes the
    /// 6 PriceFetch entries from g_ws_feed.snapshot(). Stored under block height.
    /// Trims old entries (>1000 blocks behind tip) to bound memory.
    pub fn recordBlockPrices(self: *Blockchain, height: u32, entries: []const BlockPriceEntry) void {
        if (!self.block_prices_initialized) return;
        if (entries.len < 6) return;
        var arr: [6]BlockPriceEntry = undefined;
        for (0..6) |i| arr[i] = entries[i];
        self.block_prices.put(height, arr) catch return;
        // Bound memory: drop entries older than 1000 blocks behind current.
        if (height > 1000) {
            const cutoff = height - 1000;
            var it = self.block_prices.iterator();
            var to_remove: [16]u32 = undefined;
            var rcount: usize = 0;
            while (it.next()) |e| {
                if (e.key_ptr.* < cutoff and rcount < to_remove.len) {
                    to_remove[rcount] = e.key_ptr.*;
                    rcount += 1;
                }
            }
            for (to_remove[0..rcount]) |k| _ = self.block_prices.remove(k);
        }
    }

    /// Return the 6 price entries snapshot for a block, or null if not recorded
    /// (e.g. block was mined before WS feed came online, or after node restart).
    pub fn getBlockPrices(self: *const Blockchain, height: u32) ?[6]BlockPriceEntry {
        if (!self.block_prices_initialized) return null;
        return self.block_prices.get(height);
    }

    pub fn deinit(self: *Blockchain) void {
        for (self.chain.items, 0..) |*block, i| {
            block.transactions.deinit();
            // Blocurile minate (index > 0) au hash alocat pe heap (64 hex chars)
            // Genesis (index 0) are hash string literal — nu se elibereaza
            if (i > 0 and block.hash.len == 64) {
                self.allocator.free(block.hash);
            }
            // miner_address alocat pe heap doar la blocuri restaurate din disc
            if (block.miner_heap) {
                self.allocator.free(block.miner_address);
            }
        }
        self.chain.deinit();
        self.mempool.deinit();
        self.validator_set.deinit();
        self.balances.deinit();
        self.utxo_set.deinit();
        self.nonces.deinit();
        self.pubkey_registry.deinit();
        self.tx_block_height.deinit();
        // stake_meta is keyed by the same addresses as stake_amounts but
        // owns its own duplicated keys so it can outlive a partial
        // dealloc race. Free the keys before tearing down the map.
        var meta_it = self.stake_meta.iterator();
        while (meta_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.stake_meta.deinit();
        self.stake_amounts.deinit();
        self.registered_agents.deinit();
        self.pq_identity_map.deinit();
        self.label_registry.deinit();
        self.sub_registry.deinit();
        self.notarize_registry.deinit();
        self.escrow_registry.deinit();
        self.social_graph.deinit();
        self.poap_registry.deinit();
        self.gov_registry.deinit();
        self.cold_wallet_store.deinit();
        self.timelock_store.deinit();
        self.covenant_store.deinit();
        self.treasury_multi_store.deinit();
        // Clean up address TX index (lists of TX hash pointers — no owned memory)
        {
            var ati_it = self.address_tx_index.iterator();
            while (ati_it.next()) |entry| {
                entry.value_ptr.deinit(self.allocator);
            }
            self.address_tx_index.deinit();
        }
        // Clean up orphan pool (orphans have heap-allocated 64-char hashes)
        for (self.orphan_blocks.items) |*orphan| {
            orphan.transactions.deinit();
            if (orphan.hash.len == 64) {
                self.allocator.free(orphan.hash);
            }
            if (orphan.miner_heap) {
                self.allocator.free(orphan.miner_address);
            }
        }
        self.orphan_blocks.deinit();
    }

    /// Returneaza balanta unei adrese (0 daca nu exista).
    /// PHASE-B: sursa de adevar este UTXO set-ul, nu RAM cache.
    pub fn getAddressBalance(self: *const Blockchain, address: []const u8) u64 {
        return self.utxo_set.getBalance(address);
    }

    /// Returneaza balanta matura (doar UTXO-uri cu >=100 confirmari).
    /// Coinbase-urile necesita 100 blocuri inainte de a fi cheltuibile.
    pub fn getMatureBalance(self: *const Blockchain, address: []const u8) u64 {
        const current_height = if (self.chain.items.len == 0) 0
                              else @as(u64, @intCast(self.chain.items.len - 1));
        const outpoints = self.utxo_set.getUTXOsForAddress(address);
        var total: u64 = 0;
        for (outpoints) |op| {
            if (self.utxo_set.utxos.get(op)) |utxo| {
                if (utxo.isMature(current_height)) total += utxo.amount;
            }
        }
        return total;
    }

    /// Audit: compara RAM cache (bc.balances) cu UTXO set.
    /// In debug builds fail-fast pe divergente; in release doar log.
    pub fn auditBalanceConsistency(self: *const Blockchain) struct {
        addresses_checked: usize,
        divergences: usize,
    } {
        var checked: usize = 0;
        var diverged: usize = 0;
        var it = self.balances.iterator();
        while (it.next()) |kv| {
            checked += 1;
            const ram = kv.value_ptr.*;
            const utxo = self.utxo_set.getBalance(kv.key_ptr.*);
            if (ram != utxo) {
                diverged += 1;
                std.debug.print(
                    "[AUDIT-DIVERGE] addr={s} ram={d} utxo={d}\n",
                    .{ kv.key_ptr.*, ram, utxo },
                );
            }
        }
        return .{ .addresses_checked = checked, .divergences = diverged };
    }

    /// Rebuild the active validator set from chain history + current balances.
    ///
    /// Determinism: same chain + same balances → same validator_set order.
    /// Every node executing this on the same chain produces an identical
    /// list, so `leaderForSlot` agrees across the network without any
    /// extra coordination message.
    ///
    /// Called after every block apply (mining or peer block). Cost is
    /// O(N_blocks + N_unique_miners), tiny compared to a SHA-256 round.
    /// Once set sizes grow we can switch to incremental updates.
    ///
    /// Validators below MIN_VALIDATOR_BALANCE drop out of rotation
    /// automatically — protects against a validator who spent its stake.
    pub fn rebuildValidatorSetFromChain(self: *Blockchain) !void {
        var seen = std.StringHashMap(u64).init(self.allocator);
        defer seen.deinit();

        // Walk chain, find unique miner per first-seen height. Skip empty
        // miner_address (genesis, plus pre-V3 peer-blocks that lost the
        // address through the old wire format).
        for (self.chain.items, 0..) |blk, height| {
            if (blk.miner_address.len == 0) continue;
            if (seen.contains(blk.miner_address)) continue;
            try seen.put(blk.miner_address, height);
        }

        // Build new set, filtering by balance ≥ MIN_VALIDATOR_BALANCE.
        var new_set = array_list.Managed(Validator).init(self.allocator);
        errdefer new_set.deinit();

        var it = seen.iterator();
        while (it.next()) |entry| {
            const balance = self.getAddressBalance(entry.key_ptr.*);
            if (balance < validator_mod.MIN_VALIDATOR_BALANCE) continue;
            try new_set.append(.{
                .address = entry.key_ptr.*,
                .weight = 1,
                .since_height = entry.value_ptr.*,
            });
        }

        // Sort by since_height ascending (then address as tiebreaker) for
        // identical ordering on every node. Without this, HashMap iteration
        // order would vary and `leaderForSlot` could diverge.
        std.mem.sort(Validator, new_set.items, {}, struct {
            fn lt(_: void, a: Validator, b: Validator) bool {
                if (a.since_height != b.since_height) return a.since_height < b.since_height;
                return std.mem.lessThan(u8, a.address, b.address);
            }
        }.lt);

        // Swap atomically — drop old, install new.
        self.validator_set.deinit();
        self.validator_set = new_set;
    }

    /// Returns the number of confirmations for a TX (null if TX not found in any block).
    /// confirmations = current_chain_height - block_height_containing_tx
    pub fn getConfirmations(self: *const Blockchain, tx_hash: []const u8) ?u64 {
        const block_height = self.tx_block_height.get(tx_hash) orelse return null;
        const current_height: u64 = @intCast(self.chain.items.len);
        if (current_height <= block_height) return 0;
        return current_height - block_height;
    }

    /// Returns the block height that contains a given TX (null if not found)
    pub fn getTxBlockHeight(self: *const Blockchain, tx_hash: []const u8) ?u64 {
        return self.tx_block_height.get(tx_hash);
    }

    /// Index a TX hash for a given address in address_tx_index.
    /// Creates the list if address not yet tracked.
    pub fn indexAddressTx(self: *Blockchain, address: []const u8, tx_hash: []const u8) void {
        if (address.len == 0) return;
        const list = self.address_tx_index.getPtr(address);
        if (list) |l| {
            l.append(self.allocator, tx_hash) catch {};
        } else {
            var new_list: std.ArrayList([]const u8) = .empty;
            new_list.append(self.allocator, tx_hash) catch {};
            self.address_tx_index.put(address, new_list) catch {};
        }
    }

    /// Returns the list of TX hashes associated with an address (both sent and received).
    /// Returns null if address has no history.
    /// CALLER must hold self.mutex — this is the unlocked read path used by
    /// applyBlock + RPC handlers that already hold the lock.
    pub fn getAddressHistory(self: *const Blockchain, address: []const u8) ?[]const []const u8 {
        const list = self.address_tx_index.get(address) orelse return null;
        if (list.items.len == 0) return null;
        return list.items;
    }

    /// Thread-safe version of getAddressHistory: takes the chain mutex
    /// briefly, returns an allocator-owned COPY of the hash list. Caller
    /// must `allocator.free` the returned slice.
    /// Fix B4: RPC handlers calling the unlocked variant concurrently with
    /// applyBlock's writes triggered hashmap rehash → "incorrect alignment"
    /// panic. This wrapper eliminates the race by returning a snapshot.
    pub fn getAddressHistoryLocked(
        self: *Blockchain,
        allocator: std.mem.Allocator,
        address: []const u8,
    ) !?[][]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        const list = self.address_tx_index.get(address) orelse return null;
        if (list.items.len == 0) return null;
        const copy = try allocator.alloc([]const u8, list.items.len);
        for (list.items, 0..) |hash, i| {
            copy[i] = try allocator.dupe(u8, hash);
        }
        return copy;
    }

    /// Adauga reward la balanta minerului.
    /// Lock-uit pentru a preveni race-ul cu RPC threads care citesc balances
    /// (HashMap-ul Zig nu e thread-safe; concurrent get/put produce segfault).
    pub fn creditBalance(self: *Blockchain, address: []const u8, amount: u64) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.creditBalanceLocked(address, amount);
    }

    /// Internal — caller must already hold self.mutex.
    /// Folosit din applyBlock / replayState, care deja tin mutex-ul.
    /// IMPORTANT: StringHashMap stocheaza slice-ul ca key fara sa-l copieze.
    /// Daca punem mereu slice nou (allocator.dupe in fiecare block), HashMap-ul
    /// keep slice-ul vechi ca key (vechiul pointer poate deveni invalid),
    /// produced silent balance corruption — count-ul intra in entries duplicate
    /// dupa content vs pointer.
    /// Solutie: getOrPut + dupe DOAR la prima insertie. Update-ul ulterior
    /// reutilizeaza key-ul deja persistent.
    pub fn creditBalanceLocked(self: *Blockchain, address: []const u8, amount: u64) !void {
        // PHASE C.3 — write-only contract enforcement.
        //
        // Every legitimate balance write happens inside applyBlock,
        // mineBlockForMiner, or recalculateFromHeight (chain replay).
        // All three flip `in_apply_block = true` for the duration of
        // their work. Any write outside that window is a phantom
        // mutation that vanishes on the next restart — the same class
        // of bug that wiped 51 testnet faucet recipients on 2026-04-28.
        // Count them, log them with a stack hint, surface via the
        // stabilizer ALERT once a minute. Do NOT panic — that would
        // kill the node on a real production run; the goal is to
        // *catch* phantoms in CI/staging long before mainnet.
        if (!self.in_apply_block) {
            self.stray_balance_writes += 1;
            std.debug.print(
                "[STRAY-CREDIT] addr={s} amount={d} count={d} — must come from applyBlock/mineBlock/recalc\n",
                .{ address[0..@min(20, address.len)], amount, self.stray_balance_writes },
            );
        }
        // SEGFAULT-FIX [scan-2026-04-26]: dupe FIRST, then getOrPut on the duped slice.
        // The previous code did getOrPut(externally-borrowed slice) and only duped
        // on !found_existing. Problem: getOrPut iterates HashMap buckets calling
        // eqlString on EXISTING keys. If any of those existing keys was inserted
        // earlier when caller's slice memory was later freed (e.g. dropped block's
        // miner_address) → eqlString dereferences dangling pointer → SEGFAULT
        // observed live 2026-04-26 at blockchain.zig:334.
        // The dupe-first approach trades a tiny extra alloc on found_existing
        // for guaranteed-valid keys throughout HashMap lifetime.
        // Debug print removed — was firing once per credit (~1/block) and
        // spammed several MB of log during 143k-block replay on testnet,
        // preventing the RPC server from starting before TimeoutStartSec=300.
        // Re-enable only behind an env var if you need it for forensics.
        if (address.len == 0) return; // skip empty addresses (no miner)

        const owned = try self.allocator.dupe(u8, address);
        const gop = self.balances.getOrPut(owned) catch |err| {
            self.allocator.free(owned);
            return err;
        };
        if (gop.found_existing) {
            // Key already in map — free our dupe; the existing key stays valid
            // (it was duped at its own first insertion).
            self.allocator.free(owned);
        } else {
            // First time — `owned` becomes the persistent key.
            gop.value_ptr.* = 0;
        }
        gop.value_ptr.* += amount;
    }

    /// Scade din balanta (pentru tranzactii)
    pub fn debitBalance(self: *Blockchain, address: []const u8, amount: u64) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.debitBalanceLocked(address, amount);
    }

    /// Internal — caller must already hold self.mutex.
    /// Same dupe-first pattern as creditBalanceLocked to avoid dangling
    /// HashMap key pointers when caller passes a transient slice.
    pub fn debitBalanceLocked(self: *Blockchain, address: []const u8, amount: u64) !void {
        // PHASE C.3 — same phantom-write detector as creditBalanceLocked.
        if (!self.in_apply_block) {
            self.stray_balance_writes += 1;
            std.debug.print(
                "[STRAY-DEBIT] addr={s} amount={d} count={d} — must come from applyBlock/mineBlock/recalc\n",
                .{ address[0..@min(20, address.len)], amount, self.stray_balance_writes },
            );
        }
        if (address.len == 0) return;
        const owned = try self.allocator.dupe(u8, address);
        const gop = self.balances.getOrPut(owned) catch |err| {
            self.allocator.free(owned);
            return err;
        };
        if (gop.found_existing) {
            self.allocator.free(owned);
        } else {
            gop.value_ptr.* = 0;
        }
        if (gop.value_ptr.* < amount) return error.InsufficientBalance;
        gop.value_ptr.* -= amount;
    }

    /// Settle exchange fees from a single fill: debit taker + maker by their
    /// fee shares, credit registrar slot #2 (exchange treasury) with the sum,
    /// plus the network fee. All under self.mutex with `in_apply_block=true`
    /// to bypass the phantom-write detector. Returns `error.InsufficientBalance`
    /// without partial mutation if either side cannot pay.
    ///
    /// NOTE on units: taker_fee_micro / maker_fee_micro are in QUOTE micro-USD,
    /// while balances are in OMNI SAT. We charge them as SAT 1:1 for now —
    /// caller is responsible for unit conversion when the quote isn't OMNI.
    /// The network fee is in SAT and split ceil(net/2) taker, floor(net/2) maker.
    ///
    /// Fee routing (2026-05): when consensus_params.route_fees_to_miner is
    /// true (default), the network_fee_sat portion accumulates in
    /// `pending_miner_fees` and is credited to the next block's miner during
    /// applyBlock. Taker/maker exchange fees still go to the treasury (those
    /// pay for matching/orderbook services, which are a treasury concern).
    /// When the flag is false, the legacy behaviour applies — full sum to
    /// the exchange treasury.
    ///
    /// Switching back to the old behaviour is a single governance proposal
    /// (action set_route_fees_to_miner=false) — no code change required.
    pub fn applyExchangeFees(
        self: *Blockchain,
        taker_addr: []const u8,
        maker_addr: []const u8,
        taker_fee: u64,
        maker_fee: u64,
        network_fee_sat: u64,
    ) !void {
        const treasury = registrar_mod.addressOf(.exchange) orelse return error.NoTreasury;
        const net_taker_share = (network_fee_sat + 1) / 2; // ceil
        const net_maker_share = network_fee_sat - net_taker_share; // floor
        const taker_total = taker_fee + net_taker_share;
        const maker_total = maker_fee + net_maker_share;

        self.mutex.lock();
        defer self.mutex.unlock();

        // Pre-check both balances so we never partial-mutate.
        const taker_bal = self.balances.get(taker_addr) orelse 0;
        const maker_bal = self.balances.get(maker_addr) orelse 0;
        if (taker_bal < taker_total) return error.InsufficientBalance;
        if (maker_bal < maker_total) return error.InsufficientBalance;

        const was_in_apply = self.in_apply_block;
        self.in_apply_block = true;
        defer self.in_apply_block = was_in_apply;

        if (taker_total > 0) try self.debitBalanceLocked(taker_addr, taker_total);
        if (maker_total > 0) try self.debitBalanceLocked(maker_addr, maker_total);

        // Treasury credit covers taker_fee + maker_fee always.
        // Network-fee portion goes to either accumulator (miner) or treasury
        // depending on the route_fees_to_miner switch.
        const treasury_credit = if (self.consensus_params.route_fees_to_miner)
            taker_fee + maker_fee
        else
            taker_total + maker_total;
        if (treasury_credit > 0) try self.creditBalanceLocked(treasury, treasury_credit);

        if (self.consensus_params.route_fees_to_miner and network_fee_sat > 0) {
            self.pending_miner_fees +|= network_fee_sat;
        }
    }

    /// Inregistreaza public key-ul unei adrese (pentru verificare semnatura TX)
    /// pubkey_hex = compressed secp256k1 public key, 66 hex chars
    pub fn registerPubkey(self: *Blockchain, address: []const u8, pubkey_hex: []const u8) !void {
        if (pubkey_hex.len != 66) return error.InvalidPubkeyLength;
        self.mutex.lock();
        defer self.mutex.unlock();
        // Nu suprascrie daca exista deja (prima inregistrare e autoritativa)
        if (self.pubkey_registry.get(address) == null) {
            try self.pubkey_registry.put(address, pubkey_hex);
        }
    }

    /// Register a multisig wallet configuration (address → M-of-N config).
    /// Called by the "createmultisig" RPC handler.
    pub fn registerMultisig(self: *Blockchain, address: []const u8, config: multisig_mod.MultisigConfig) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        // Check if already registered
        for (self.multisig_configs[0..self.multisig_count]) |entry| {
            if (std.mem.eql(u8, entry.address[0..entry.address_len], address)) return; // already exists
        }
        if (self.multisig_count >= 64) return error.MultisigRegistryFull;
        var entry = MultisigConfigEntry{};
        const copy_len = @min(address.len, 64);
        @memcpy(entry.address[0..copy_len], address[0..copy_len]);
        entry.address_len = @intCast(copy_len);
        entry.config = config;
        self.multisig_configs[self.multisig_count] = entry;
        self.multisig_count += 1;
    }

    /// Look up a multisig config by address.
    pub fn getMultisigConfig(self: *const Blockchain, address: []const u8) ?*const multisig_mod.MultisigConfig {
        for (self.multisig_configs[0..self.multisig_count]) |*entry| {
            if (std.mem.eql(u8, entry.address[0..entry.address_len], address)) {
                return &entry.config;
            }
        }
        return null;
    }

    pub fn addTransaction(self: *Blockchain, tx: Transaction) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const valid = self.validateTransaction(&tx) catch |err| {
            std.debug.print("[ADD-TX] validateTransaction errored: {} (from={s})\n",
                .{ err, tx.from_address[0..@min(tx.from_address.len, 20)] });
            return err;
        };
        if (!valid) {
            std.debug.print("[ADD-TX] InvalidTransaction (from={s} amount={d})\n",
                .{ tx.from_address[0..@min(tx.from_address.len, 20)], tx.amount });
            return error.InvalidTransaction;
        }
        try self.mempool.append(tx);
        std.debug.print("[ADD-TX] OK appended to mempool (size now={d})\n", .{self.mempool.items.len});

        // Push real-time WS event for new mempool TX. Off-thread broadcast
        // walks the connected-clients list under its own mutex; a few µs added
        // here is fine because addTransaction already holds bc.mutex (i.e. we
        // are NOT in the inner mining hot loop). Cheap inline JSON via
        // bufPrint inside ws_srv.broadcastTx — no allocations on this path.
        if (main_mod.g_ws_srv) |ws| {
            if (tx.hash.len > 0) {
                ws.broadcastTx(tx.hash, tx.from_address, tx.amount);
            }
        }
    }

    /// Returneaza totalul outgoing pending din mempool pentru o adresa (amount + fee per TX)
    /// Folosit in validateTransaction() pentru a preveni double-spend cu TX-uri rapide
    pub fn getPendingOutgoing(self: *const Blockchain, address: []const u8) u64 {
        var total: u64 = 0;
        for (self.mempool.items) |tx| {
            if (std.mem.eql(u8, tx.from_address, address)) {
                total += tx.amount + tx.fee;
            }
        }
        return total;
    }

    /// Returneaza urmatorul nonce confirmat pentru o adresa (0 daca nu exista)
    /// Acesta este nonce-ul pe chain — NU include TX-urile pending din mempool
    pub fn getNextNonce(self: *const Blockchain, address: []const u8) u64 {
        return self.nonces.get(address) orelse 0;
    }

    /// Returneaza urmatorul nonce disponibil pentru o adresa,
    /// incluzand TX-urile pending din mempool (chain_nonce + pending_count).
    /// Aceasta metoda este utila pentru RPC "getnonce" — clientul stie ce nonce sa puna pe urmatoarea TX.
    pub fn getNextAvailableNonce(self: *const Blockchain, address: []const u8) u64 {
        const chain_nonce = self.nonces.get(address) orelse 0;
        // Count pending TXs from this sender in mempool
        var pending: u64 = 0;
        for (self.mempool.items) |tx| {
            if (std.mem.eql(u8, tx.from_address, address)) {
                pending += 1;
            }
        }
        return chain_nonce + pending;
    }

    pub fn validateTransaction(self: *Blockchain, tx: *const Transaction) !bool {
        // 0. Locktime check: TX locked until block height N cannot be included before that
        if (tx.locktime > 0) {
            const current_height: u64 = @intCast(self.chain.items.len);
            if (tx.locktime > current_height) {
                std.debug.print("[VALIDATE] FAIL: TX locked until block {d}, current height {d}\n", .{ tx.locktime, current_height });
                return false;
            }
        }

        // 1. Amount trebuie > 0 (unless OP_RETURN data-only TX OR Phase-2A typed TX
        //    that carries its semantic value in `data`, e.g. order_place/order_cancel
        //    where the orderbook collateral is reserved separately and `amount`=0
        //    is the canonical wire form).
        const is_op_return_tx = tx.op_return.len > 0 and tx.amount == 0;
        const is_typed_tx = tx.tx_type != .transfer;
        if (tx.amount == 0 and !is_op_return_tx and !is_typed_tx) { std.debug.print("[VALIDATE] FAIL: amount=0\n", .{}); return false; }

        // 2. Adrese nu pot fi goale si trebuie minim 8 chars (prefix "ob1qhnj2fm3lrmgxzfvyejp97vv8s3ean92myqt9zt")
        if (tx.from_address.len < 8 or tx.to_address.len < 8) { std.debug.print("[VALIDATE] FAIL: addr too short from={d} to={d}\n", .{tx.from_address.len, tx.to_address.len}); return false; }

        // 3. Prefix valid (isValid verifică prefix + amount + op_return length)
        if (!tx.isValid()) { std.debug.print("[VALIDATE] FAIL: isValid() from={s} to={s} amt={d}\n", .{tx.from_address[0..@min(42,tx.from_address.len)], tx.to_address[0..@min(42,tx.to_address.len)], tx.amount}); return false; }

        // 3b. Dust threshold — respinge TX prea mici (anti-spam, ca Bitcoin 546 sat)
        //     Skip dust check for OP_RETURN data-only TXs (amount=0 is allowed)
        //     Skip for Phase-2A typed TXs (orderbook/bridge/etc. — amount carries
        //     no transfer semantics, the typed `data` payload does).
        if (!is_op_return_tx and !is_typed_tx and tx.amount < DUST_THRESHOLD_SAT) { std.debug.print("[VALIDATE] FAIL: dust {d} < {d}\n", .{tx.amount, DUST_THRESHOLD_SAT}); return false; }

        // 3c. Fee minimum check (fee market — at least TX_MIN_FEE = 1 SAT)
        if (tx.fee < TX_MIN_FEE) { std.debug.print("[VALIDATE] FAIL: fee {d} < min {d}\n", .{tx.fee, TX_MIN_FEE}); return false; }

        // 4. Strict nonce check (anti-replay + anti-gap, ca Ethereum)
        //    TX nonce must equal chain_nonce + pending_count (sequential, no gaps)
        //    This prevents replay attacks AND ensures no nonce gaps in the mempool
        const expected_nonce = self.getNextAvailableNonce(tx.from_address);
        if (tx.nonce != expected_nonce) { std.debug.print("[VALIDATE] FAIL: nonce {d} != expected {d} (chain={d})\n", .{tx.nonce, expected_nonce, self.getNextNonce(tx.from_address)}); return false; }

        // 5. PHASE-C wire v2: explicit UTXO inputs check.
        //    For v2 TXs, every listed input must exist in the UTXO set,
        //    must be owned by from_address, and the input total must
        //    cover amount + fee. No implicit balance check needed —
        //    the inputs ARE the balance.
        if (tx.isV2()) {
            var input_total: u64 = 0;
            const current_height: u64 = if (self.chain.items.len == 0) 0
                else @as(u64, @intCast(self.chain.items.len - 1));
            for (tx.inputs) |inp| {
                const utxo = self.utxo_set.getUTXO(inp.tx_hash, inp.output_index) orelse {
                    std.debug.print(
                        "[VALIDATE v2] FAIL: input {s}:{d} not in UTXO set\n",
                        .{ inp.tx_hash, inp.output_index },
                    );
                    return false;
                };
                if (!std.mem.eql(u8, utxo.address, tx.from_address)) {
                    std.debug.print(
                        "[VALIDATE v2] FAIL: input owner mismatch (expected={s}, got={s})\n",
                        .{ tx.from_address, utxo.address },
                    );
                    return false;
                }
                if (!utxo.isMature(current_height)) {
                    std.debug.print(
                        "[VALIDATE v2] FAIL: input {s}:{d} immature (coinbase needs 100 confirms)\n",
                        .{ inp.tx_hash, inp.output_index },
                    );
                    return false;
                }
                input_total += utxo.amount;
            }
            // Sum of explicit outputs (if any) must not exceed inputs - fee.
            var out_total: u64 = 0;
            for (tx.outputs) |out| out_total += out.amount;
            if (input_total < out_total + tx.fee) {
                std.debug.print(
                    "[VALIDATE v2] FAIL: inputs {d} < outputs {d} + fee {d}\n",
                    .{ input_total, out_total, tx.fee },
                );
                return false;
            }
            // Also enforce the implicit (amount, to_address) when outputs[]
            // is empty — keeps the v1 amount field meaningful.
            if (tx.outputs.len == 0 and input_total < tx.amount + tx.fee) {
                std.debug.print(
                    "[VALIDATE v2] FAIL: inputs {d} < amount {d} + fee {d}\n",
                    .{ input_total, tx.amount, tx.fee },
                );
                return false;
            }
        } else {
            // v1 backward-compat: classic balance + pending check.
            const sender_balance = self.getAddressBalance(tx.from_address);
            const pending_out = self.getPendingOutgoing(tx.from_address);
            const available = if (sender_balance > pending_out) sender_balance - pending_out else 0;
            if (available < tx.amount + tx.fee) { std.debug.print("[VALIDATE] FAIL: balance {d} - pending {d} = available {d} < amount+fee {d}\n", .{sender_balance, pending_out, available, tx.amount + tx.fee}); return false; }
        }

        // 5b-faucet. Faucet address restriction: TX from FAUCET_ADDR may only go
        //   to addresses that have NOT yet completed pq_attest (onboarding gate).
        //   This rule is enforced by every miner — funds cannot leave the faucet
        //   for any purpose other than onboarding a fresh address.
        if (std.mem.eql(u8, tx.from_address, faucet_mod.FAUCET_ADDR)) {
            // op_return must be a valid faucet_claim
            if (!std.mem.startsWith(u8, tx.op_return, faucet_mod.FAUCET_OP_PREFIX)) {
                std.debug.print("[VALIDATE] FAIL: faucet TX missing faucet_claim op_return\n", .{});
                return false;
            }
            // destination must NOT already have pq_attest (no double-funding)
            if (self.pq_identity_map.contains(tx.to_address)) {
                std.debug.print("[VALIDATE] FAIL: faucet TX to already-attested address {s}\n",
                    .{tx.to_address[0..@min(20, tx.to_address.len)]});
                return false;
            }
            // amount must not exceed FAUCET_AMOUNT_SAT (prevent draining)
            if (tx.amount > faucet_mod.FAUCET_AMOUNT_SAT) {
                std.debug.print("[VALIDATE] FAIL: faucet TX amount {d} > max {d}\n",
                    .{tx.amount, faucet_mod.FAUCET_AMOUNT_SAT});
                return false;
            }
        }

        // 5c-covenant. Covenant whitelist check: if the sender has an active
        //   destination-whitelist covenant, the TX.to_address must be allowed
        //   and amount must not exceed per-TX cap.
        {
            const current_block: u64 = @intCast(self.chain.items.len);
            if (!self.covenant_store.checkTx(tx.from_address, tx.to_address, tx.amount, current_block)) {
                std.debug.print("[VALIDATE] FAIL: covenant violation from={s} to={s} amt={d}\n",
                    .{ tx.from_address[0..@min(20, tx.from_address.len)],
                       tx.to_address[0..@min(20, tx.to_address.len)],
                       tx.amount });
                return false;
            }
        }

        // 5c. Multisig validation: if from_address is "ob_ms_*", recover the
        //     registered MultisigConfig, decode the M-of-N signature bundle
        //     from script_sig, and re-verify the quorum independently. Without
        //     re-verifying here anyone could spend from a registered multisig
        //     by submitting a TX with signature="multisig_verified".
        if (std.mem.startsWith(u8, tx.from_address, multisig_mod.MULTISIG_PREFIX)) {
            const ms_config = self.getMultisigConfig(tx.from_address) orelse {
                std.debug.print("[VALIDATE] FAIL: multisig address not registered: {s}\n",
                    .{tx.from_address[0..@min(20, tx.from_address.len)]});
                return false;
            };
            if (tx.script_sig.len == 0) {
                std.debug.print("[VALIDATE] FAIL: multisig TX missing script_sig bundle\n", .{});
                return false;
            }
            // The signers signed Transaction.calculateHash() — re-derive it
            // and verify the M-of-N quorum against the registered pubkeys.
            const expected_hash = tx.calculateHash();
            if (!multisig_mod.verifyBundle(ms_config, expected_hash, tx.script_sig)) {
                std.debug.print("[VALIDATE] FAIL: multisig M-of-N quorum verification failed for {s}\n",
                    .{tx.from_address[0..@min(20, tx.from_address.len)]});
                return false;
            }
            // Bonus check: tx.hash (if set) must match the canonical hash so
            // explorers/clients see a consistent value.
            if (tx.hash.len == 64) {
                var stored_hash: [32]u8 = undefined;
                hex_utils.hexToBytes(tx.hash, &stored_hash) catch return false;
                if (!std.mem.eql(u8, &stored_hash, &expected_hash)) {
                    std.debug.print("[VALIDATE] FAIL: multisig tx.hash mismatch\n", .{});
                    return false;
                }
            }
        }

        // 6. Verificare semnatura ECDSA secp256k1 cu public key inregistrat
        //    (signature = 128 hex chars = 64 bytes R||S, hash = 64 hex chars)
        //    Skip for multisig addresses (they use M-of-N verification instead)
        //    Skip for PQ schemes (love/food/rent/vacation) — verificate de RPC handler
        //    inainte de submit; signature size este variabila per scheme.
        const is_pq_scheme = tx.scheme != .omni_ecdsa;
        if (is_pq_scheme and tx.hash.len == 64) {
            // PQ TX: verifica integritatea hash-ului doar (semnatura PQ a fost
            // verificata de handler la submit). Daca hash-ul nu corespunde
            // bytes-urilor TX, respinge.
            const expected_hash = tx.calculateHash();
            var stored_hash: [32]u8 = undefined;
            hex_utils.hexToBytes(tx.hash, &stored_hash) catch return false;
            if (!std.mem.eql(u8, &stored_hash, &expected_hash)) return false;
        }
        if (!std.mem.startsWith(u8, tx.from_address, multisig_mod.MULTISIG_PREFIX) and
            !is_pq_scheme and
            tx.signature.len == 128 and tx.hash.len == 64)
        {
            // 6a. Integritate hash — hash-ul stocat trebuie sa corespunda continutului TX
            const expected_hash = tx.calculateHash();
            var stored_hash: [32]u8 = undefined;
            hex_utils.hexToBytes(tx.hash, &stored_hash) catch return false;
            if (!std.mem.eql(u8, &stored_hash, &expected_hash)) return false;

            // 6b. Verificare semnatura ECDSA cu public key din registru
            if (self.pubkey_registry.get(tx.from_address)) |pubkey_hex| {
                if (!tx.verifyWithHexPubkey(pubkey_hex)) {
                    std.debug.print(
                        "[VALIDATE] FAIL: ECDSA signature verification failed for {s} (registered pubkey: {s}, tx_hash: {s}, sig: {s}..)\n",
                        .{
                            tx.from_address[0..@min(20, tx.from_address.len)],
                            pubkey_hex[0..@min(16, pubkey_hex.len)],
                            tx.hash[0..@min(16, tx.hash.len)],
                            tx.signature[0..@min(16, tx.signature.len)],
                        },
                    );
                    return false;
                }
            }
            // Daca pubkey nu e inregistrat, acceptam TX (backward compat cu coinbase/genesis)
            // Urmatoarea TX de la aceasta adresa va fi verificata dupa registerPubkey()
        } else if (!std.mem.startsWith(u8, tx.from_address, multisig_mod.MULTISIG_PREFIX) and
                   !is_pq_scheme and
                   tx.signature.len > 0) {
            // Semnătură incompletă — respinge (skip for multisig which uses different sig format,
            // and for PQ schemes which validate at RPC layer with a separate verifier)
            return false;
        }

        // 7. Script validation (if TX has scripts attached)
        //    Empty scripts = legacy ECDSA-only mode (backward compatible)
        //    If script_pubkey is set but script_sig is empty → reject (can't unlock)
        //    If both are set → run ScriptVM to validate unlock against lock
        if (tx.script_pubkey.len > 0) {
            if (tx.script_sig.len == 0) {
                std.debug.print("[VALIDATE] FAIL: script_pubkey set but script_sig empty\n", .{});
                return false;
            }
            const tx_hash = tx.calculateHash();
            const current_height: u64 = @intCast(self.chain.items.len);
            if (!script_mod.validateScripts(tx.script_sig, tx.script_pubkey, tx_hash, current_height)) {
                std.debug.print("[VALIDATE] FAIL: script validation failed\n", .{});
                return false;
            }
        }

        return true;
    }

    pub fn mineBlock(self: *Blockchain) !Block {
        return self.mineBlockForMiner("");
    }

    /// Mine block + acorda reward minerului + proceseaza TX-urile din mempool
    pub fn mineBlockForMiner(self: *Blockchain, miner_address: []const u8) !Block {
        // PHASE C.3 — open the legitimate-write window for the duration
        // of the mine. The credit/debit calls below funnel through
        // creditBalance (mutex + creditBalanceLocked), and the audit
        // counter inside *Locked checks self.in_apply_block.
        self.in_apply_block = true;
        defer self.in_apply_block = false;

        // NU lock aici — PoW dureaza secunde, ar bloca tot RPC-ul
        // Lock doar pe secțiunile critice (read chain, write chain, update balances)
        if (self.chain.items.len == 0) {
            return error.EmptyChain;
        }

        // Lock doar pentru citire chain state
        self.mutex.lock();
        const previous_block = self.chain.items[self.chain.items.len - 1];
        const index = self.chain.items.len;
        self.mutex.unlock();
        const timestamp = std.time.timestamp();

        const reward = if (miner_address.len > 0) blockRewardAt(@intCast(index)) else 0;

        // Copy miner address — slice-ul extern poate fi din MinerPool global
        const miner_addr_owned = try self.allocator.dupe(u8, miner_address);

        var block = Block{
            .index = @intCast(index),
            .timestamp = timestamp,
            .transactions = self.mempool,
            .previous_hash = previous_block.hash,
            .nonce = 0,
            .hash = "",
            .miner_address = miner_addr_owned,
            .miner_heap = true,
            .reward_sat = reward,
        };

        // Calculate Merkle Root (commits to all TX in block header, like Bitcoin)
        block.merkle_root = block.calculateMerkleRoot();

        // ── Snapshot oracle prices into the block BEFORE PoW ────────────────
        // Why before PoW: calculateHash() now mixes prices_root into the
        // header. If prices were attached after mining, an attacker could
        // swap them without redoing PoW. By calling setPrices() first we
        // bind the snapshot to the work the miner is about to do — any
        // tampering invalidates the nonce.
        //
        // Conversion: ws_exchange_feed.PriceFetch (slice-backed strings)
        // → oracle_types.BlockPriceEntry (fixed-size strings, no allocator).
        // Genesis path never reaches here (index==0 chain is rejected at the
        // top), but if the WS feed is null we just leave the default-init
        // empty entries → prices_root stays all-zeros.
        if (main_mod.g_ws_feed) |*feed| {
            const live = feed.getImportantSnapshot();
            var entries: [oracle_types.BLOCK_PRICE_SLOTS]oracle_types.BlockPriceEntry = undefined;
            for (live, 0..) |p, i| {
                var e: oracle_types.BlockPriceEntry = .{};
                const elen = @min(p.exchange.len, 16);
                e.exchange_len = @intCast(elen);
                @memcpy(e.exchange[0..elen], p.exchange[0..elen]);
                const plen = @min(p.pair.len, 16);
                e.pair_len = @intCast(plen);
                @memcpy(e.pair[0..plen], p.pair[0..plen]);
                e.bid_micro_usd = p.bid_micro_usd;
                e.ask_micro_usd = p.ask_micro_usd;
                e.timestamp_ms  = p.timestamp_ms;
                e.success       = p.success;
                entries[i] = e;
            }
            block.setPrices(entries);
        }

        // Proof-of-Work hot loop — optimized 2026-05 (PERF_HOTSPOTS #1).
        //
        // Old path: per nonce we rebuilt the entire SHA-256 input, hex-encoded
        // the result into a heap-allocated 64-byte string, and walked ASCII
        // chars to count leading '0's. Each miss heap-freed the string. That
        // burned ~95% of the cycle budget on formatting and allocation rather
        // than hashing.
        //
        // New path:
        //   1. Pre-seed an SHA-256 state with the static prefix (index|ts|
        //      prev_hash_len) once per block attempt.
        //   2. Per nonce: clone the state, feed nonce decimal digits + tx
        //      hashes, finalize → [32]u8.
        //   3. Compare raw bytes against the difficulty target (no hex).
        // Hex conversion only happens once, on the accepted nonce, to keep
        // block.hash in its canonical 64-char hex form for storage/RPC.
        //
        // Consensus-equivalent: hex_utils.MiningPrefix.buildHash() feeds the
        // hasher in exactly the same byte order as the legacy path
        // (calculateBlockHashHex), so the digest for any (header, nonce) pair
        // is bit-identical. Difficulty check via meetsDifficultyRaw matches
        // isValidHashDifficulty's leading-hex-zero semantics.
        var tx_hashes_buf: [10000][]const u8 = undefined;
        const tx_count = @min(block.transactions.items.len, 10000);
        for (0..tx_count) |i| {
            tx_hashes_buf[i] = block.transactions.items[i].hash;
        }
        const tx_hashes_slice = tx_hashes_buf[0..tx_count];
        const mining_prefix = hex_utils.MiningPrefix.init(
            block.index, block.timestamp, block.previous_hash.len, &.{},
        );

        var nonce: u64 = 0;
        const MAX_NONCE: u64 = 4_294_967_296; // 2^32 — if not found, re-roll with new timestamp
        while (nonce < MAX_NONCE) {
            const raw = mining_prefix.buildHash(nonce, tx_hashes_slice);
            if (hex_utils.meetsDifficultyRaw(raw, self.difficulty)) {
                block.nonce = nonce;
                block.hash = try hex_utils.bytesToHexAlloc(raw, self.allocator);
                break;
            }
            nonce += 1;
        }

        // Proceseaza tranzactiile: debiteaza sender (amount + fee), crediteaza receiver, incrementeaza nonce
        var total_fees: u64 = 0;
        for (block.transactions.items) |tx| {
            const total_needed = tx.amount + tx.fee;
            // UTXO: spend sender's inputs.
            // FIX (2026-05-03): nu mai sarim TX-urile cand selectUTXOs esueaza.
            // Pentru wire-v1 (fara inputs[]/outputs[] explicite), validateTransaction
            // a verificat deja balance >= amount+fee inainte de mempool-add. Daca
            // selectUTXOs nu reuseste totusi sa acopere need-ul (ex: UTXO-uri inca
            // ne-indexate dupa restart sau tranzactii externe semnate de noi useri),
            // facem fallback la per-address balance bookkeeping si lasam UTXO-ul
            // recipient-ului sa fie creat pe baza credit-ului. recalculateFromHeight
            // la urmatorul restart va reconcilia UTXO-urile complet.
            var selection_opt: ?utxo_mod.UTXOSet.Selection = null;
            if (self.utxo_set.selectUTXOs(tx.from_address, total_needed, @intCast(index), self.allocator)) |sel| {
                selection_opt = sel;
            } else |err| {
                std.debug.print("[MINE] selectUTXOs failed for {s}: {} — fallback la balance check (v1)\n",
                    .{tx.from_address[0..@min(20, tx.from_address.len)], err});
            }
            if (selection_opt) |*selection| {
                defer selection.utxos.deinit(self.allocator);
                for (selection.utxos.items) |utxo| {
                    _ = self.utxo_set.spendUTXO(utxo.tx_hash, utxo.output_index) catch |err| {
                        std.debug.print("[MINE] spendUTXO failed: {}\n", .{err});
                    };
                }
                // UTXO: change output back to sender
                if (selection.total > total_needed) {
                    const change = selection.total - total_needed;
                    self.utxo_set.addUTXO(tx.hash, 1, tx.from_address, change, @intCast(index), "", false) catch {};
                }
            }

            self.debitBalance(tx.from_address, tx.amount + tx.fee) catch {}; // debit amount + fee
            self.creditBalance(tx.to_address, tx.amount) catch {};
            total_fees += tx.fee;
            // Incrementeaza nonce-ul sender-ului (anti-replay: urmatoarea TX trebuie nonce+1)
            const current_nonce = self.nonces.get(tx.from_address) orelse 0;
            self.nonces.put(tx.from_address, current_nonce + 1) catch {};
            // Track TX → block height for confirmation counting
            self.tx_block_height.put(tx.hash, @intCast(index)) catch {};
            // Update derived stake/agent state from op_return memo
            self.applyOpReturnRoles(tx);
            // Index TX for both sender and receiver address history
            self.indexAddressTx(tx.from_address, tx.hash);
            self.indexAddressTx(tx.to_address, tx.hash);
            // UTXO: create output for recipient at index 0
            self.utxo_set.addUTXO(tx.hash, 0, tx.to_address, tx.amount, @intCast(index), "", false) catch {};
        }

        // Fee split: FEE_BURN_PCT% burned (deflationary, like EIP-1559), rest to miner
        const fees_burned = total_fees * FEE_BURN_PCT / 100;
        const fees_to_miner = total_fees - fees_burned;
        total_fees_burned_sat += fees_burned;

        // Block reward + miner's share of fees
        if (miner_address.len > 0 and (reward > 0 or fees_to_miner > 0)) {
            self.creditBalance(miner_address, reward + fees_to_miner) catch {};
            // UTXO: coinbase output for miner (needs 100 confirmations to spend)
            self.utxo_set.addUTXO(block.hash, 0, miner_address, reward + fees_to_miner, @intCast(index), "", true) catch {};
            std.debug.print("[REWARD] Miner {s} +{d} SAT ({d:.2} OMNI) + {d} fees ({d} burned) @ block {d}\n",
                .{ miner_address[0..@min(16, miner_address.len)], reward,
                   @as(f64, @floatFromInt(reward)) / 1e9, fees_to_miner, fees_burned, index });
        }

        // Lock pentru chain write + balance update
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.chain.append(block);

        // Refresh validator set after a new block: a miner that just
        // crossed MIN_VALIDATOR_BALANCE joins automatically; one whose
        // balance dropped below the threshold drops out. Keeps the set
        // consistent across all nodes (chain-derived → deterministic).
        self.rebuildValidatorSetFromChain() catch |err| {
            std.debug.print("[VALIDATOR-SET] rebuild after mine failed: {}\n", .{err});
        };

        // Difficulty retarget la fiecare RETARGET_INTERVAL blocuri
        if (index % RETARGET_INTERVAL == 0 and index > 0) {
            const retarget_start = index - RETARGET_INTERVAL;
            const old_block_ts = self.chain.items[retarget_start].timestamp;
            const new_block_ts = block.timestamp;
            const actual_time = new_block_ts - old_block_ts;
            const new_diff = retargetDifficulty(self.difficulty, actual_time);
            if (new_diff != self.difficulty) {
                std.debug.print("[RETARGET] Block {d}: difficulty {d} → {d} (actual {d}s, target {d}s)\n",
                    .{ index, self.difficulty, new_diff, actual_time, TARGET_INTERVAL_S });
                self.difficulty = new_diff;
            }
        }

        // Reset mempool
        self.mempool = array_list.Managed(Transaction).init(self.allocator);

        return block;
    }

    /// Calculate block hash as 64-char hex string (shared implementation in hex_utils)
    pub fn calculateBlockHash(self: *Blockchain, block: *const Block) ![]const u8 {
        return hex_utils.hashBlock(block.*, self.allocator);
    }

    /// Check if hash meets difficulty (delegates to shared hex_utils)
    pub fn isValidHash(self: *Blockchain, hash: []const u8) !bool {
        return hex_utils.isValidHashDifficulty(hash, self.difficulty);
    }

    /// Maximum allowed clock drift for block timestamps (2 hours, like Bitcoin)
    const MAX_FUTURE_SECONDS: i64 = 7200;

    /// Validate a block against all consensus rules (Bitcoin-level validation).
    /// Returns true if the block passes all checks, false otherwise.
    /// Checks: merkle root, timestamp, previous hash, difficulty, fees/reward, TX validity.
    pub fn validateBlock(self: *Blockchain, block: *const Block) bool {
        // 0. Genesis block is trusted — skip validation
        if (block.index == 0) return true;

        // 1. Merkle root — recalculate from transactions and compare
        const expected_merkle = block.calculateMerkleRoot();
        if (!std.mem.eql(u8, &expected_merkle, &block.merkle_root)) {
            std.debug.print("[VALIDATE_BLOCK] FAIL: merkle root mismatch at block {d}\n", .{block.index});
            return false;
        }

        // 2. Timestamp validation
        const now = std.time.timestamp();
        // a) Not more than 2 hours in the future
        if (block.timestamp > now + MAX_FUTURE_SECONDS) {
            std.debug.print("[VALIDATE_BLOCK] FAIL: block {d} timestamp {d} too far in the future (now={d})\n", .{ block.index, block.timestamp, now });
            return false;
        }
        // b) Not before previous block's timestamp
        if (block.index > 0) {
            const prev_idx: usize = @intCast(block.index - 1);
            if (prev_idx < self.chain.items.len) {
                const prev_block = self.chain.items[prev_idx];
                if (block.timestamp < prev_block.timestamp) {
                    std.debug.print("[VALIDATE_BLOCK] FAIL: block {d} timestamp {d} < prev block timestamp {d}\n", .{ block.index, block.timestamp, prev_block.timestamp });
                    return false;
                }
            }
        }

        // 3. Previous hash — must match hash of the previous block in chain
        if (block.index > 0) {
            const prev_idx: usize = @intCast(block.index - 1);
            if (prev_idx < self.chain.items.len) {
                const prev_block = self.chain.items[prev_idx];
                if (!std.mem.eql(u8, block.previous_hash, prev_block.hash)) {
                    std.debug.print("[VALIDATE_BLOCK] FAIL: previous_hash mismatch at block {d}\n", .{block.index});
                    return false;
                }
            }
        }

        // 4. Difficulty — block hash must have required leading zeros
        if (!hex_utils.isValidHashDifficulty(block.hash, self.difficulty)) {
            std.debug.print("[VALIDATE_BLOCK] FAIL: hash does not meet difficulty {d} at block {d}\n", .{ self.difficulty, block.index });
            return false;
        }

        // 5. Fee validation — miner reward must be <= blockRewardAt(height) + total_fees_to_miner
        var total_fees: u64 = 0;
        for (block.transactions.items) |tx| {
            total_fees += tx.fee;
        }
        const max_reward = blockRewardAt(@intCast(block.index));
        const fees_to_miner = total_fees - (total_fees * FEE_BURN_PCT / 100);
        if (block.reward_sat > max_reward + fees_to_miner) {
            std.debug.print("[VALIDATE_BLOCK] FAIL: reward {d} > max {d} + fees {d} at block {d}\n", .{ block.reward_sat, max_reward, fees_to_miner, block.index });
            return false;
        }

        // 6. TX validation — all transactions must pass basic validation (prefix, amount > 0)
        if (!block.validateTransactions()) {
            std.debug.print("[VALIDATE_BLOCK] FAIL: invalid transaction in block {d}\n", .{block.index});
            return false;
        }

        // 7. Bridge limits — sum bridge-lock TXs in this block + last 86400
        // blocks must not exceed BRIDGE_MAX_DAILY_SAT, and no single TX may
        // exceed BRIDGE_MAX_PER_TX_SAT. Defense-in-depth from Ronin/Orbit
        // hacks: even a malicious miner can't push a giant lock through.
        if (!self.validateBridgeLimits(block)) {
            std.debug.print("[VALIDATE_BLOCK] FAIL: bridge cap exceeded in block {d}\n", .{block.index});
            return false;
        }

        return true;
    }

    // ─── Bridge consensus hooks ──────────────────────────────────────────────

    /// Returns true if `tx` is a bridge lock: destination = vault address
    /// (case-insensitive 0x... 40-hex compare) AND op_return starts with
    /// "OMNIBRIDGE:". Cheap inline check called on every TX during block
    /// validation, so kept simple.
    pub fn isBridgeLockTx(tx: *const Transaction) bool {
        const cfg = @import("chain_config.zig");
        const vault = cfg.BRIDGE_VAULT_ADDR_HEX;
        // to_address may be lowercase or mixed; compare case-insensitive on
        // the hex chars after "0x".
        if (tx.to_address.len != vault.len) return false;
        for (tx.to_address, vault) |a, b| {
            const al = if (a >= 'A' and a <= 'Z') a + 32 else a;
            const bl = if (b >= 'A' and b <= 'Z') b + 32 else b;
            if (al != bl) return false;
        }
        const prefix = "OMNIBRIDGE:";
        if (tx.op_return.len < prefix.len) return false;
        return std.mem.eql(u8, tx.op_return[0..prefix.len], prefix);
    }

    /// Sum lock amounts in `block` and verify per-tx + rolling-day caps.
    /// Caller MUST hold mutex (or be in single-threaded context).
    fn validateBridgeLimits(self: *Blockchain, block: *const Block) bool {
        const cfg = @import("chain_config.zig");
        var block_lock_sum: u64 = 0;
        for (block.transactions.items) |tx| {
            if (!isBridgeLockTx(&tx)) continue;
            // Per-tx hard cap.
            if (tx.amount == 0 or tx.amount > cfg.BRIDGE_MAX_PER_TX_SAT) {
                std.debug.print(
                    "[BRIDGE-LIMIT] TX over per-tx cap: amount={d} max={d}\n",
                    .{ tx.amount, cfg.BRIDGE_MAX_PER_TX_SAT },
                );
                return false;
            }
            block_lock_sum +%= tx.amount;
            if (block_lock_sum < tx.amount) return false; // overflow
        }
        if (block_lock_sum == 0) return true; // no bridge TXs in this block

        // Rolling 24h: sum lock TXs in the last BRIDGE_DAILY_WINDOW_BLOCKS
        // blocks (excluding the candidate block itself, which is not in
        // chain yet) plus the candidate's own lock sum.
        const window = cfg.BRIDGE_DAILY_WINDOW_BLOCKS;
        const tip = self.chain.items.len;
        const start = if (tip > window) tip - window else 0;
        var historical: u64 = 0;
        var i: usize = start;
        while (i < tip) : (i += 1) {
            const blk = &self.chain.items[i];
            for (blk.transactions.items) |htx| {
                if (isBridgeLockTx(&htx)) {
                    historical +%= htx.amount;
                    if (historical < htx.amount) return false; // overflow
                }
            }
        }
        const grand_total = historical +% block_lock_sum;
        if (grand_total < historical) return false; // overflow
        if (grand_total > cfg.BRIDGE_MAX_DAILY_SAT) {
            std.debug.print(
                "[BRIDGE-LIMIT] daily cap exceeded: hist={d} block={d} cap={d}\n",
                .{ historical, block_lock_sum, cfg.BRIDGE_MAX_DAILY_SAT },
            );
            return false;
        }
        return true;
    }

    /// Accept a block from a P2P peer. Fully validates before appending.
    /// Handles three cases:
    ///   1. Block extends our chain tip -> append normally
    ///   2. Block forks from our chain and creates a longer chain -> reorg
    ///   3. Block's parent is unknown -> store in orphan pool
    /// After appending, checks if any orphan blocks now connect.
    pub fn addExternalBlock(self: *Blockchain, block: Block) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const our_tip = self.chain.items[self.chain.items.len - 1];

        // Case 1: Block extends our chain tip (previous_hash matches tip hash)
        if (std.mem.eql(u8, block.previous_hash, our_tip.hash)) {
            if (!self.validateBlock(&block)) return error.InvalidBlock;
            try self.applyBlock(block);
            // After appending, try to connect orphans
            self.processOrphansInternal();
            return;
        }

        // Case 2: Check if block's parent exists somewhere in our chain (fork)
        const parent_idx = self.findBlockByHash(block.previous_hash);
        if (parent_idx) |pidx| {
            // We have the parent but it's not our tip => this is a fork.
            // new chain length from genesis = pidx + 1 (fork point inclusive) + 1 (new block)
            const new_chain_len = pidx + 2;
            const our_chain_len = self.chain.items.len;

            if (new_chain_len > our_chain_len) {
                // Single-block fork that's longer: reorg
                if (!self.validateBlockAtHeight(&block, pidx + 1)) return error.InvalidBlock;

                const reorg_depth = our_chain_len - 1 - pidx;
                if (reorg_depth > MAX_REORG_DEPTH) return error.ReorgTooDeep;

                std.debug.print("[REORG] Single-block reorg at fork={d}, depth={d}\n", .{ pidx, reorg_depth });

                // Collect TXs from blocks being removed (after fork point)
                try self.collectOrphanedTxs(pidx + 1);

                // Free removed blocks
                for (pidx + 1..self.chain.items.len) |i| {
                    var old_blk = &self.chain.items[i];
                    old_blk.transactions.deinit();
                    if (i > 0 and old_blk.hash.len == 64) {
                        self.allocator.free(old_blk.hash);
                    }
                    if (old_blk.miner_heap) {
                        self.allocator.free(old_blk.miner_address);
                    }
                }

                // Truncate chain to fork point + 1
                self.chain.items.len = pidx + 1;

                // Apply the new block
                try self.applyBlock(block);

                // Recalculate balances from scratch
                try self.recalculateFromHeight(pidx + 1);

                // Remove mempool TXs already in new chain
                self.removeMempoolDuplicates();

                self.processOrphansInternal();
            }
            // If new_chain_len <= our_chain_len, ignore the fork (shorter or equal)
            return;
        }

        // Case 3: Parent unknown -> orphan pool
        if (self.orphan_blocks.items.len < MAX_ORPHAN_POOL) {
            try self.orphan_blocks.append(block);
        }
    }

    /// Accept a full chain from a peer and reorg if it's longer.
    /// Validates all blocks in the new chain from the fork point.
    /// Returns orphaned TXs to mempool for re-mining.
    pub fn reorg(self: *Blockchain, new_chain: []const Block) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (new_chain.len == 0) return error.EmptyChain;

        // New chain must be strictly longer than ours
        if (new_chain.len <= self.chain.items.len) return error.ShorterChain;

        // Find the fork point (common ancestor)
        const fork_point = self.findForkPointInternal(new_chain) orelse return error.NoCommonAncestor;

        // Safety: reject reorgs deeper than MAX_REORG_DEPTH
        const reorg_depth = self.chain.items.len - 1 - fork_point;
        if (reorg_depth > MAX_REORG_DEPTH) return error.ReorgTooDeep;

        // Validate all new blocks from fork point onward
        for (fork_point + 1..new_chain.len) |i| {
            const blk = &new_chain[i];
            // Check basic block validity: merkle root, transactions
            if (!blk.validateTransactions()) return error.InvalidBlock;
            const expected_merkle = blk.calculateMerkleRoot();
            if (!std.mem.eql(u8, &expected_merkle, &blk.merkle_root)) return error.InvalidBlock;

            // Verify chain linkage: previous_hash must match prior block
            if (i > 0) {
                if (!std.mem.eql(u8, blk.previous_hash, new_chain[i - 1].hash)) return error.InvalidBlock;
            }

            // Verify block hash meets difficulty
            if (blk.index > 0) {
                if (!hex_utils.isValidHashDifficulty(blk.hash, self.difficulty)) return error.InvalidBlock;
            }

            // Verify reward is not inflated
            var blk_total_fees: u64 = 0;
            for (blk.transactions.items) |tx| {
                blk_total_fees += tx.fee;
            }
            const max_reward = blockRewardAt(@intCast(blk.index));
            const blk_fees_to_miner = blk_total_fees - (blk_total_fees * FEE_BURN_PCT / 100);
            if (blk.reward_sat > max_reward + blk_fees_to_miner) return error.InvalidBlock;
        }

        std.debug.print("[REORG] Full chain reorg at fork={d}, our_len={d} -> new_len={d}, depth={d}\n", .{ fork_point, self.chain.items.len, new_chain.len, reorg_depth });

        // Collect TXs from old blocks being removed (after fork point) -> return to mempool
        try self.collectOrphanedTxs(fork_point + 1);

        // Truncate chain to fork point (free removed blocks)
        for (fork_point + 1..self.chain.items.len) |i| {
            var old_blk = &self.chain.items[i];
            old_blk.transactions.deinit();
            if (i > 0 and old_blk.hash.len == 64) {
                self.allocator.free(old_blk.hash);
            }
            if (old_blk.miner_heap) {
                self.allocator.free(old_blk.miner_address);
            }
        }
        self.chain.items.len = fork_point + 1;

        // Append new blocks from fork point onward
        for (fork_point + 1..new_chain.len) |i| {
            try self.chain.append(new_chain[i]);
        }

        // Recalculate all balances, nonces, tx_block_height from scratch
        try self.recalculateFromHeight(fork_point + 1);

        // Remove from mempool any TXs that are now in the new chain
        self.removeMempoolDuplicates();

        self.processOrphansInternal();

        // Reorg is a critical event — force save to disc
        self.saveToDisc() catch |err| {
            std.debug.print("[DB] Reorg save failed: {}\n", .{err});
        };
    }

    /// Auto-save disabled. The blockchain IS the database — balances,
    /// nonces, and pubkey registry are deterministically reconstructed
    /// by replaying the chain on startup. Restart resyncs from peers,
    /// which on a real mesh is faster than re-reading a multi-GB .dat
    /// file. Save now happens only on graceful shutdown (signal handler).
    pub fn checkAutoSave(self: *Blockchain) void {
        const BLOCK_THRESHOLD: u32 = 100;
        const TX_THRESHOLD: u32 = 1000;
        if (self.blocks_since_save >= BLOCK_THRESHOLD or self.txs_since_save >= TX_THRESHOLD) {
            if (self.persistent_db != null) {
                self.saveToDisc() catch |err| {
                    std.debug.print("[AUTOSAVE] saveToDisc failed: {}\n", .{err});
                };
            }
            self.blocks_since_save = 0;
            self.txs_since_save = 0;
        }
    }

    /// Convenience method: save full blockchain state to disc via PersistentBlockchain.
    /// No-op if persistent_db has not been attached (e.g. in unit tests).
    ///
    /// Thread-safety: takes self.mutex for the duration of the write. The
    /// background save thread (g_state_save_thread in main.zig) calls this
    /// every 30 s as backup, plus the mining loop calls it after every block
    /// for primary persistence; the mining loop holds the mutex briefly to
    /// apply each block's TXs, so the saver and the miner serialise cleanly.
    /// A slow disk write blocks new blocks from being added during the save —
    /// that's fine, our save is ~hundreds of ms and we're targeting
    /// 1 s/block so there's plenty of slack.
    pub fn saveToDisc(self: *Blockchain) !void {
        const pdb = self.persistent_db orelse return;
        self.mutex.lock();
        defer self.mutex.unlock();
        try pdb.saveBlockchain(self, self.db_path);
        // Update bookkeeping fields so a graceful-shutdown save sees fresh
        // numbers and the operator's log shows what was persisted.
        self.last_save_time = std.time.timestamp();
        self.blocks_since_save = 0;
        self.txs_since_save = 0;
        std.debug.print("[DB] Auto-saved: {d} blocks, {d} addresses\n", .{ self.chain.items.len, self.balances.count() });
    }

    /// Find the highest block index where both chains have the same hash.
    /// Returns null if no common ancestor found (completely divergent chains).
    pub fn findForkPoint(self: *const Blockchain, other_chain: []const Block) ?usize {
        return self.findForkPointInternal(other_chain);
    }

    /// Internal fork point finder (no mutex, called from methods that already hold it).
    fn findForkPointInternal(self: *const Blockchain, other_chain: []const Block) ?usize {
        const max_idx = @min(self.chain.items.len, other_chain.len);
        if (max_idx == 0) return null;

        var i: usize = max_idx;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, self.chain.items[i].hash, other_chain[i].hash)) {
                return i;
            }
        }
        return null;
    }

    /// Find a block in our chain by its hash. Returns the index or null.
    fn findBlockByHash(self: *const Blockchain, hash: []const u8) ?usize {
        var i: usize = self.chain.items.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, self.chain.items[i].hash, hash)) {
                return i;
            }
        }
        return null;
    }

    /// Validate a block as if it were at a specific height (used during reorg).
    fn validateBlockAtHeight(self: *Blockchain, block: *const Block, height: usize) bool {
        if (block.index == 0) return true;

        const expected_merkle = block.calculateMerkleRoot();
        if (!std.mem.eql(u8, &expected_merkle, &block.merkle_root)) return false;

        const now = std.time.timestamp();
        if (block.timestamp > now + MAX_FUTURE_SECONDS) return false;

        if (!hex_utils.isValidHashDifficulty(block.hash, self.difficulty)) return false;

        var total_fees: u64 = 0;
        for (block.transactions.items) |tx| {
            total_fees += tx.fee;
        }
        const max_reward = blockRewardAt(@intCast(height));
        const fees_to_miner = total_fees - (total_fees * FEE_BURN_PCT / 100);
        if (block.reward_sat > max_reward + fees_to_miner) return false;

        if (!block.validateTransactions()) return false;

        return true;
    }

    /// Apply a validated block to the chain: process TXs, credit miner, append.
    /// Caller must hold mutex.
    /// Update cumulative stake & agent-registration maps from a single TX's
    /// `op_return` payload. Called from applyBlock / mineBlockForMiner /
    /// recalculateFromHeight so the derived state stays in sync regardless
    /// of which path produced the block. Keys are duped (HashMap-owned)
    /// because the TX slice may be transient (mempool buffer, replay loop).
    fn applyOpReturnRoles(self: *Blockchain, tx: Transaction) void {
        if (tx.op_return.len == 0 or tx.from_address.len == 0) return;
        if (std.mem.startsWith(u8, tx.op_return, "stake:")) {
            // Cap stake at the user's actual balance. Without this we'd
            // accept stake > balance which would later make unstake credit
            // back funds the user never owned.
            const cur_bal = self.balances.get(tx.from_address) orelse 0;
            const effective = @min(tx.amount, cur_bal);
            if (effective == 0) return;

            // Parse optional lock_blocks suffix: "stake:<amt>:<lock_blocks>".
            // The colon-amt segment is informational (we use tx.amount as the
            // source of truth for SAT) but `lock_blocks` after a second colon
            // is the user's commitment. Older clients send "stake:<amt>" with
            // no second colon → lock_blocks = 0 (immediate unstake allowed).
            var lock_blocks: u64 = 0;
            if (std.mem.indexOfScalarPos(u8, tx.op_return, "stake:".len, ':')) |second_colon| {
                const lock_str = tx.op_return[second_colon + 1 ..];
                lock_blocks = std.fmt.parseInt(u64, lock_str, 10) catch 0;
            }

            // Debit balance (lock funds). Caller (applyBlock) already holds
            // the chain mutex AND has set in_apply_block=true, so the
            // phantom-write detector is happy.
            self.debitBalanceLocked(tx.from_address, effective) catch return;

            const owned = self.allocator.dupe(u8, tx.from_address) catch return;
            const gop = self.stake_amounts.getOrPut(owned) catch {
                self.allocator.free(owned);
                return;
            };
            if (gop.found_existing) {
                self.allocator.free(owned);
            } else {
                gop.value_ptr.* = 0;
            }
            gop.value_ptr.* +|= effective; // saturating add

            // Update stake_meta. On top-up: keep the EARLIEST started_at
            // (so the lock countdown starts from the first stake) and the
            // MAX lock_blocks (longest commitment wins). Fresh stake gets
            // both fields populated from current block height + parsed
            // lock_blocks.
            const meta_key = self.allocator.dupe(u8, tx.from_address) catch return;
            const meta_gop = self.stake_meta.getOrPut(meta_key) catch {
                self.allocator.free(meta_key);
                return;
            };
            const current_block: u64 = @intCast(self.chain.items.len);
            if (meta_gop.found_existing) {
                self.allocator.free(meta_key);
                // Keep earliest start; pick max of existing and new lock.
                if (lock_blocks > meta_gop.value_ptr.lock_blocks) {
                    meta_gop.value_ptr.lock_blocks = lock_blocks;
                }
            } else {
                meta_gop.value_ptr.* = .{
                    .started_at_block = current_block,
                    .lock_blocks = lock_blocks,
                };
            }

            // Auto-promote to validator when total stake >= VALIDATOR_MIN_STAKE
            // (100 OMNI). Reads main_mod.g_staking_engine which is set in
            // main.zig at init. Idempotent: existing validators just have
            // their total_stake updated; new ones are registered + activated.
            if (main_mod.g_staking_engine) |se| {
                if (gop.value_ptr.* >= staking_mod.VALIDATOR_MIN_STAKE) {
                    const block_h = self.chain.items.len;
                    if (se.findValidatorIndex(tx.from_address)) |idx| {
                        // Already registered — update stake amount
                        se.validators[idx].total_stake = gop.value_ptr.*;
                        se.validators[idx].self_stake = gop.value_ptr.*;
                    } else if (se.registerValidator(
                        tx.from_address,
                        gop.value_ptr.*,
                        @intCast(block_h),
                    )) |new_idx| {
                        se.activateValidator(new_idx) catch {};
                    } else |_| {
                        // ValidatorSetFull or AlreadyRegistered — silent skip
                    }
                }
            }
        } else if (std.mem.startsWith(u8, tx.op_return, "unstake:")) {
            // Unstake: credit back the user's full stake to their balance.
            // (Future: parse partial unstake amount from op_return; for now
            // we unstake everything stored under this address.)
            const cur_stake = self.stake_amounts.get(tx.from_address) orelse 0;
            if (cur_stake == 0) return;

            // Enforce lock period if metadata says so. Older stakes with
            // lock_blocks=0 (legacy or explicit no-lock) bypass this check.
            if (self.stake_meta.get(tx.from_address)) |meta| {
                if (meta.lock_blocks > 0) {
                    const current_block: u64 = @intCast(self.chain.items.len);
                    const unlock_at = meta.unlockAtBlock();
                    if (current_block < unlock_at) {
                        // Lock not yet expired — drop unstake silently
                        // (no-op for non-failure path; user keeps stake).
                        return;
                    }
                }
            }

            self.creditBalanceLocked(tx.from_address, cur_stake) catch return;

            const owned = self.allocator.dupe(u8, tx.from_address) catch return;
            const gop = self.stake_amounts.getOrPut(owned) catch {
                self.allocator.free(owned);
                return;
            };
            if (gop.found_existing) {
                self.allocator.free(owned);
            }
            gop.value_ptr.* = 0; // clear stake

            // Clean up stake_meta — entry no longer applies.
            if (self.stake_meta.fetchRemove(tx.from_address)) |kv| {
                self.allocator.free(kv.key);
            }
        } else if (std.mem.startsWith(u8, tx.op_return, "agent:register")) {
            const owned = self.allocator.dupe(u8, tx.from_address) catch return;
            const gop = self.registered_agents.getOrPut(owned) catch {
                self.allocator.free(owned);
                return;
            };
            if (gop.found_existing) {
                self.allocator.free(owned);
            }
        } else if (std.mem.startsWith(u8, tx.op_return, "pq_attest_v1:")) {
            // Format: pq_attest_v1:<love>:<food>:<rent>:<vacation>[:<btc>][:<eth>]
            // First-claim wins — if already registered, ignore.
            if (self.pq_identity_map.contains(tx.from_address)) return;

            const payload = tx.op_return["pq_attest_v1:".len..];
            var identity = PqIdentity{};

            // Parse colon-separated fields: love:food:rent:vacation[:btc][:eth]
            var it = std.mem.splitScalar(u8, payload, ':');
            var fi: usize = 0;
            while (it.next()) |field| : (fi += 1) {
                const copy_len_u = @min(field.len, 127);
                const copy_len: u8 = @intCast(copy_len_u);
                switch (fi) {
                    0 => { @memcpy(identity.love[0..copy_len_u], field[0..copy_len_u]); identity.love_len = copy_len; },
                    1 => { @memcpy(identity.food[0..copy_len_u], field[0..copy_len_u]); identity.food_len = copy_len; },
                    2 => { @memcpy(identity.rent[0..copy_len_u], field[0..copy_len_u]); identity.rent_len = copy_len; },
                    3 => { @memcpy(identity.vacation[0..copy_len_u], field[0..copy_len_u]); identity.vacation_len = copy_len; },
                    4 => { const c = @min(field.len, 127); @memcpy(identity.btc[0..c], field[0..c]); identity.btc_len = @intCast(c); },
                    5 => { const c = @min(field.len, 63); @memcpy(identity.eth[0..c], field[0..c]); identity.eth_len = @intCast(c); },
                    else => break,
                }
            }

            // Require at least 4 soulbound fields
            if (identity.love_len == 0 or identity.food_len == 0 or
                identity.rent_len == 0 or identity.vacation_len == 0) return;

            // Validate soulbound prefixes
            if (!std.mem.startsWith(u8, identity.loveSlice(), "ob_k1_")) return;
            if (!std.mem.startsWith(u8, identity.foodSlice(), "ob_f5_")) return;
            if (!std.mem.startsWith(u8, identity.rentSlice(), "ob_d5_")) return;
            if (!std.mem.startsWith(u8, identity.vacationSlice(), "ob_s3_")) return;

            // Store attest block + tx hash
            identity.attest_block = @intCast(self.chain.items.len);
            const tx_hash_copy = @min(tx.hash.len, identity.attest_tx.len - 1);
            @memcpy(identity.attest_tx[0..tx_hash_copy], tx.hash[0..tx_hash_copy]);
            identity.attest_tx_len = @intCast(tx_hash_copy);

            // Store with owned key (first-claim wins)
            const owned_key = self.allocator.dupe(u8, tx.from_address) catch return;
            self.pq_identity_map.put(owned_key, identity) catch {
                self.allocator.free(owned_key);
                return;
            };
            // Persist to disk (JSONL append) so the registry survives restarts.
            // Best-effort: failure here doesn't break consensus, just means the
            // identity will need to be re-applied via chain replay on next start.
            persistPqIdentityAppend(self.allocator, tx.from_address, &identity);
        } else if (std.mem.startsWith(u8, tx.op_return, "label:")) {
            // op_return: "label:<target>:<tag>[:<note>]"
            // Fee check: minimum LABEL_FEE_SAT (0.1 OMNI) anti-spam
            if (tx.fee < label_mod.LABEL_FEE_SAT) return;
            const parsed = label_mod.parseApply(tx.op_return) orelse return;
            // reporter tier — look up reputation, fall back to OMNI default
            const reporter_tier = blk: {
                // Reputation module not directly accessible here; default "OMNI"
                // The tier weight will be overridden by RPC when submitting.
                break :blk "OMNI";
            };
            _ = self.label_registry.apply(
                parsed.target,
                tx.from_address,
                parsed.tag,
                parsed.note,
                reporter_tier,
                @intCast(self.chain.items.len),
                tx.hash,
            ) catch return;
        } else if (std.mem.startsWith(u8, tx.op_return, "label_remove:")) {
            // op_return: "label_remove:<id>"
            const label_id = label_mod.parseRemove(tx.op_return) orelse return;
            _ = self.label_registry.remove(label_id, tx.from_address);
        } else if (std.mem.startsWith(u8, tx.op_return, "sub_create:")) {
            // op_return: "sub_create:<to>:<amount>:<interval>:<max>[:<note>]"
            if (tx.fee < sub_mod.SUB_CREATE_FEE_SAT) return;
            const parsed = sub_mod.parseCreate(tx.op_return) orelse return;
            _ = self.sub_registry.create(
                tx.from_address,
                parsed,
                @intCast(self.chain.items.len),
            ) catch return;
        } else if (std.mem.startsWith(u8, tx.op_return, "sub_cancel:")) {
            // op_return: "sub_cancel:<id>"
            const sub_id = sub_mod.parseCancel(tx.op_return) orelse return;
            _ = self.sub_registry.cancel(sub_id, tx.from_address);
        } else if (std.mem.startsWith(u8, tx.op_return, "notarize:")) {
            // op_return: "notarize:<sha256>:<doc_type>:<expiry>[:<note>]"
            if (tx.fee < notarize_mod.NOTARIZE_FEE_SAT) return;
            const parsed = notarize_mod.parsNotarize(tx.op_return) orelse return;
            _ = self.notarize_registry.notarize(
                tx.from_address,
                parsed,
                @intCast(self.chain.items.len),
                tx.hash,
            ) catch return;
        } else if (std.mem.startsWith(u8, tx.op_return, "notarize_revoke:")) {
            // op_return: "notarize_revoke:<id>"
            if (tx.fee < notarize_mod.NOTARIZE_REVOKE_FEE_SAT) return;
            const notarize_id = notarize_mod.parseRevoke(tx.op_return) orelse return;
            _ = self.notarize_registry.revoke(notarize_id, tx.from_address);
        } else if (std.mem.startsWith(u8, tx.op_return, "escrow_create:")) {
            // op_return: "escrow_create:<to>:<amount>:<condition_hash>:<timeout>[:<note>]"
            if (tx.fee < escrow_mod.ESCROW_CREATE_FEE_SAT) return;
            const parsed = escrow_mod.parseCreate(tx.op_return) orelse return;
            // Fondurile sunt deja debitate din UTXO-ul senderului in applyBlock.
            // Inregistram escrow-ul — suma e tinuta virtual in registry.
            _ = self.escrow_registry.create(
                tx.from_address, parsed,
                @intCast(self.chain.items.len),
                tx.hash,
            ) catch return;
        } else if (std.mem.startsWith(u8, tx.op_return, "escrow_release:")) {
            // op_return: "escrow_release:<id>:<proof_hash>"
            const parsed = escrow_mod.parseRelease(tx.op_return) orelse return;
            const amount = self.escrow_registry.tryRelease(
                parsed.escrow_id, parsed.proof_hash,
                tx.from_address, @intCast(self.chain.items.len),
            );
            if (amount > 0) {
                // Crediteaza to_address (from_address este to-ul escrow-ului)
                const bal = self.balances.get(tx.from_address) orelse 0;
                self.balances.put(tx.from_address, bal + amount) catch {};
            }
        } else if (std.mem.startsWith(u8, tx.op_return, "escrow_refund:")) {
            // op_return: "escrow_refund:<id>"
            const escrow_id = escrow_mod.parseRefund(tx.op_return) orelse return;
            const amount = self.escrow_registry.tryRefund(
                escrow_id, tx.from_address,
                @intCast(self.chain.items.len),
            );
            if (amount > 0) {
                const bal = self.balances.get(tx.from_address) orelse 0;
                self.balances.put(tx.from_address, bal + amount) catch {};
            }
        } else if (std.mem.startsWith(u8, tx.op_return, "escrow_dispute:")) {
            if (tx.fee < escrow_mod.ESCROW_DISPUTE_FEE_SAT) return;
            const escrow_id = escrow_mod.parseDispute(tx.op_return) orelse return;
            _ = self.escrow_registry.openDispute(escrow_id, tx.from_address);

        // ── Social Graph ────────────────────────────────────────────────
        } else if (std.mem.startsWith(u8, tx.op_return, "follow:")) {
            const target = social_mod.parseFollow(tx.op_return) orelse return;
            self.social_graph.follow(
                tx.from_address, target, @intCast(self.chain.items.len),
            ) catch return;
        } else if (std.mem.startsWith(u8, tx.op_return, "unfollow:")) {
            const target = social_mod.parseUnfollow(tx.op_return) orelse return;
            self.social_graph.unfollow(tx.from_address, target);

        // ── POAP ────────────────────────────────────────────────────────
        } else if (std.mem.startsWith(u8, tx.op_return, "poap_event:")) {
            if (tx.fee < poap_mod.POAP_EVENT_FEE_SAT) return;
            const parsed = poap_mod.parseEvent(tx.op_return) orelse return;
            self.poap_registry.createEvent(
                tx.from_address, parsed, @intCast(self.chain.items.len),
            ) catch return;
        } else if (std.mem.startsWith(u8, tx.op_return, "poap_claim:")) {
            if (tx.fee < poap_mod.POAP_CLAIM_FEE_SAT) return;
            const event_id = poap_mod.parseClaim(tx.op_return) orelse return;
            self.poap_registry.claimPoap(
                tx.from_address, event_id, @intCast(self.chain.items.len), tx.hash,
            ) catch return;
        } else if (std.mem.startsWith(u8, tx.op_return, "poap_close:")) {
            const event_id = poap_mod.parseClose(tx.op_return) orelse return;
            _ = self.poap_registry.closeEvent(event_id, tx.from_address);

        // ── Governance ──────────────────────────────────────────────────
        } else if (std.mem.startsWith(u8, tx.op_return, "gov_propose:")) {
            if (tx.fee < gov_mod.GOV_PROPOSE_FEE_SAT) return;
            const parsed = gov_mod.parsePropose(tx.op_return) orelse return;
            _ = self.gov_registry.propose(
                tx.from_address, parsed, @intCast(self.chain.items.len),
            ) catch return;
        } else if (std.mem.startsWith(u8, tx.op_return, "gov_vote:")) {
            if (tx.fee < gov_mod.GOV_VOTE_FEE_SAT) return;
            const parsed = gov_mod.parseVote(tx.op_return) orelse return;
            self.gov_registry.vote(
                parsed.id, tx.from_address, parsed.yes, "OMNI",
                @intCast(self.chain.items.len),
            ) catch return;
        }
    }

    // ── Governance execution ─────────────────────────────────────────────────

    /// Apply a passed governance proposal's action to consensus_params and
    /// mark it executed. Errors on:
    ///   - error.ProposalNotFound — id not in registry
    ///   - error.ProposalNotPassed — status != .passed (still voting / rejected
    ///     / expired / already executed all surface as ProposalNotPassed via
    ///     gov_registry.markExecuted)
    ///   - error.AlreadyExecuted — markExecuted reports this for the second
    ///     execution attempt during a race (caller already past status check)
    ///
    /// Idempotent across the chain: once a proposal's status flips to .executed,
    /// subsequent applyBlock passes skip it via collectPassedUnexecuted.
    pub fn executeProposal(self: *Blockchain, proposal_id: u64, current_block: u64) !void {
        const proposal = self.gov_registry.getProposal(proposal_id) orelse
            return error.ProposalNotFound;
        if (proposal.status != .passed) return error.ProposalNotPassed;
        if (proposal.executed) return error.AlreadyExecuted;

        // Apply the action. Unknown action kinds (forward-compat from a future
        // node version) are treated as no-op so the chain doesn't fork on the
        // execution itself — the proposal is still marked executed.
        switch (proposal.action.kind) {
            .none => {},
            .set_block_reward => self.consensus_params.block_reward_sat = proposal.action.u64_value,
            .set_min_difficulty => self.consensus_params.min_difficulty =
                @intCast(@min(proposal.action.u64_value, @as(u64, MAX_DIFFICULTY))),
            .set_block_size_limit => self.consensus_params.block_size_limit = proposal.action.u64_value,
            .set_pq_signature_max => self.consensus_params.pq_signature_max = proposal.action.u64_value,
            .set_dns_signed_required => self.consensus_params.dns_signed_required = proposal.action.bool_value,
            .set_validator_quorum_min => self.consensus_params.validator_quorum_min =
                @intCast(@min(proposal.action.u64_value, @as(u64, std.math.maxInt(u32)))),
            .set_route_fees_to_miner => self.consensus_params.route_fees_to_miner = proposal.action.bool_value,
            _ => {
                // Forward-compat: unknown action kind. Mark executed anyway so
                // proposals aren't re-tried every block in a stuck loop.
            },
        }

        try self.gov_registry.markExecuted(proposal_id, current_block);

        // Push WS event so dashboards / explorers see the protocol parameter
        // change in real time. Best-effort: failure to format / broadcast must
        // not roll back the executed mutation (it's already on chain via the
        // governance registry).
        if (main_mod.g_ws_srv) |ws| {
            var buf: [512]u8 = undefined;
            const json = std.fmt.bufPrint(&buf,
                "{{\"type\":\"gov_executed\",\"proposal_id\":{d}," ++
                "\"action_kind\":{d},\"u64_value\":{d},\"bool_value\":{}," ++
                "\"executed_block\":{d}}}",
                .{
                    proposal_id,
                    @intFromEnum(proposal.action.kind),
                    proposal.action.u64_value,
                    proposal.action.bool_value,
                    current_block,
                }) catch null;
            if (json) |j| ws.broadcast(j);
        }
    }

    /// Auto-execute every passed-but-unexecuted proposal at the current block
    /// height. Called from applyBlock once per block. Safe under self.mutex
    /// because executeProposal only mutates consensus_params + the gov registry
    /// (both already serialised by applyBlock's caller).
    fn autoExecutePassedProposals(self: *Blockchain, current_block: u64) void {
        var ids: [16]u64 = undefined;
        const n = self.gov_registry.collectPassedUnexecuted(&ids);
        for (ids[0..n]) |pid| {
            self.executeProposal(pid, current_block) catch |err| {
                std.debug.print("[GOV-EXEC] proposal {d} failed: {}\n", .{ pid, err });
            };
        }
    }

    fn applyBlock(self: *Blockchain, block: Block) !void {
        // PHASE C.3 — open the legitimate-write window.
        self.in_apply_block = true;
        defer self.in_apply_block = false;

        var total_fees: u64 = 0;

        // ─── PHASE 2B step 1: route typed TXs that DON'T move UTXOs ─────
        // Order place/cancel/modify and bridge management TXs are handled
        // by per-type processors AFTER the classic UTXO transfer loop, so
        // they share consensus state but don't accidentally hit the
        // implicit-coin-selection UTXO path. We collect their indices here
        // and apply them in deterministic order at the end.
        for (block.transactions.items) |tx| {
            const total_needed = tx.amount + tx.fee;
            // Skip non-transfer typed TXs in this loop — they have no UTXO
            // movement (the trader's collateral lock is virtual until fill).
            // Bridge_lock IS a UTXO movement (vault payment) and falls
            // through to the regular path; bridge_unlock_request is virtual.
            if (tx.tx_type != .transfer and tx.tx_type != .bridge_lock) {
                // PHASE 2F.2 — HTLC state transitions before the generic
                // typed-TX fallthrough. Funds are tracked virtually via
                // bc.balances: init debits sender, claim credits recipient,
                // refund credits sender. UTXOs are not touched (the typed
                // TX has amount=0 by convention).
                self.applyHtlcTx(tx, @intCast(block.index)) catch |err| {
                    std.debug.print("[HTLC] apply tx {s} type={} failed: {}\n",
                        .{ tx.hash[0..@min(16, tx.hash.len)], tx.tx_type, err });
                };
                // Phase 2F.3 — intent TXs (0x40/0x41/0x43). Routes through
                // applyIntentTx; applyHtlcTx ignored these (else => {}). The
                // dispatch is by tx_type, so a TX won't be double-applied.
                self.applyIntentTx(tx, @intCast(block.index)) catch |err| {
                    std.debug.print("[INTENT] apply tx {s} type={} failed: {}\n",
                        .{ tx.hash[0..@min(16, tx.hash.len)], tx.tx_type, err });
                };
                // Still increment nonce + index TX so listings show it.
                const cur_nonce = self.nonces.get(tx.from_address) orelse 0;
                self.nonces.put(tx.from_address, cur_nonce + 1) catch {};
                self.tx_block_height.put(tx.hash, @intCast(block.index)) catch {};
                self.indexAddressTx(tx.from_address, tx.hash);
                continue;
            }

            // PHASE-C wire v2: explicit inputs/outputs path.
            // When TX carries inputs[], spend exactly those — no
            // implicit coin-selection. Total of input UTXOs must
            // cover amount+fee (already enforced in validateTransaction).
            // Change goes back to from_address as a single synthetic
            // UTXO unless the TX explicitly listed it in outputs[].
            if (tx.isV2()) {
                var input_total: u64 = 0;
                for (tx.inputs) |inp| {
                    if (self.utxo_set.spendUTXO(inp.tx_hash, inp.output_index)) |spent_utxo| {
                        input_total += spent_utxo.amount;
                    } else |err| {
                        std.debug.print(
                            "[APPLY-BLOCK v2] spendUTXO failed for input {s}:{d}: {}\n",
                            .{ inp.tx_hash, inp.output_index, err },
                        );
                    }
                }
                // Materialise explicit outputs.
                var out_total: u64 = 0;
                for (tx.outputs, 0..) |out, oi| {
                    self.utxo_set.addUTXO(
                        tx.hash, @intCast(oi), out.address, out.amount,
                        @intCast(block.index), "", false,
                    ) catch {};
                    out_total += out.amount;
                }
                // Implicit change to sender if inputs over-pay outputs+fee.
                // (Wallets that want explicit change must list it in outputs.)
                if (input_total > out_total + tx.fee) {
                    const change = input_total - out_total - tx.fee;
                    const change_idx: u32 = @intCast(tx.outputs.len);
                    self.utxo_set.addUTXO(
                        tx.hash, change_idx, tx.from_address, change,
                        @intCast(block.index), "", false,
                    ) catch {};
                }
            } else {
                // v1 backward-compat: implicit coin-selection.
                // FIX (2026-05-03): la fel ca in mineBlockForMiner — daca selectUTXOs
                // esueaza pentru wire-v1, NU sarim TX-ul; lasam balance/nonce/index
                // sa fie procesate si lasam recipient UTXO-ul sa fie creat.
                var selection_opt: ?utxo_mod.UTXOSet.Selection = null;
                if (self.utxo_set.selectUTXOs(tx.from_address, total_needed, @intCast(block.index), self.allocator)) |sel| {
                    selection_opt = sel;
                } else |err| {
                    std.debug.print("[APPLY-BLOCK v1] selectUTXOs failed for {s}: {} — fallback la balance check\n",
                        .{tx.from_address[0..@min(20, tx.from_address.len)], err});
                }
                if (selection_opt) |*selection| {
                    defer selection.utxos.deinit(self.allocator);
                    for (selection.utxos.items) |utxo| {
                        _ = self.utxo_set.spendUTXO(utxo.tx_hash, utxo.output_index) catch |err| {
                            std.debug.print("[APPLY-BLOCK v1] spendUTXO failed: {}\n", .{err});
                        };
                    }
                    if (selection.total > total_needed) {
                        const change = selection.total - total_needed;
                        self.utxo_set.addUTXO(tx.hash, 1, tx.from_address, change, @intCast(block.index), "", false) catch {};
                    }
                }
                // v1 implicit recipient output at index 0.
                self.utxo_set.addUTXO(tx.hash, 0, tx.to_address, tx.amount, @intCast(block.index), "", false) catch {};
            }

            // RAM cache mirror (write-only for non-replay code; read goes
            // through utxo_set.getBalance per Phase B).
            self.debitBalanceLocked(tx.from_address, tx.amount + tx.fee) catch {};
            self.creditBalanceLocked(tx.to_address, tx.amount) catch {};
            // Cold wallet incoming-receive hook
            self.cold_wallet_store.onReceive(tx.to_address, tx.amount);
            total_fees += tx.fee;
            const current_nonce = self.nonces.get(tx.from_address) orelse 0;
            self.nonces.put(tx.from_address, current_nonce + 1) catch {};
            self.tx_block_height.put(tx.hash, @intCast(block.index)) catch {};
            self.applyOpReturnRoles(tx);
            self.indexAddressTx(tx.from_address, tx.hash);
            self.indexAddressTx(tx.to_address, tx.hash);
        }

        // ─── PHASE 2B+2D: deterministic order matching + fill capture ──
        // Now that all transfers have settled, process order TXs in
        // canonical order (sort by pair_id, price, tx_hash) so every
        // node reaches identical fills regardless of mempool arrival
        // order. Fills produced are recorded in self.fills_history
        // (Phase 2D trade history) keyed by block height.
        self.applyOrderTxs(block) catch |err| {
            std.debug.print("[APPLY-BLOCK] order matching failed: {}\n", .{err});
        };

        const fees_burned = total_fees * FEE_BURN_PCT / 100;
        const fees_to_miner = total_fees - fees_burned;
        total_fees_burned_sat += fees_burned;

        // Drain accumulated network fees from applyExchangeFees into this
        // block's miner. See ConsensusParams.route_fees_to_miner. Reset to
        // zero whether or not we credited (orphan-block path may skip the
        // credit but still wants the slate clean for the next attempt).
        const exchange_fees_to_miner: u64 = if (self.consensus_params.route_fees_to_miner)
            self.pending_miner_fees
        else
            0;
        self.pending_miner_fees = 0;

        const total_miner_credit: u64 = block.reward_sat + fees_to_miner + exchange_fees_to_miner;
        if (block.miner_address.len > 0 and total_miner_credit > 0) {
            self.creditBalanceLocked(block.miner_address, total_miner_credit) catch {};
            self.utxo_set.addUTXO(block.hash, 0, block.miner_address, total_miner_credit, @intCast(block.index), "", true) catch {};
            self.total_miner_exchange_fees +|= exchange_fees_to_miner;
        }

        // ── Pay-to-claim NS scan ────────────────────────────────────────────
        //
        // Any TX in the block that pays >= feeForName to the NS treasury
        // (registrar slot 5 = ens.omnibus) AND carries an op_return memo
        // matching `ns_claim:<name>.<tld>` triggers an automatic registry
        // entry naming `<name>.<tld>` to `tx.from_address`. The TX itself
        // is the proof — no separate signed RPC call needed. Fee already
        // moved to treasury as part of the regular UTXO accounting above.
        //
        // Skipped when:
        //   - dns_registry pointer not attached (test paths, light nodes)
        //   - ens.omnibus slot has no canonical address yet (mainnet pre-fill)
        //   - registry full / name reserved / owner capped — claimByPayment
        //     reports the error, we log and continue (other TXs still apply).
        if (self.dns_registry) |dns| {
            if (registrar_mod.addressOf(.ens)) |ns_treasury| {
                for (block.transactions.items) |tx| {
                    if (tx.op_return.len == 0) continue;
                    const claim = dns_mod.parseClaimMemo(tx.op_return) orelse continue;
                    if (!std.mem.eql(u8, tx.to_address, ns_treasury)) continue;
                    // Sybil-resistant pricing: an owner already holding many
                    // names pays a progressively larger fee per new claim.
                    // Pay-to-claim is always 1-year (no `years` field in the
                    // op_return memo), so feeForRegistrationWithOwnerCount
                    // with years=1 reduces to feeForName × sybilMultiplier.
                    const owner_count = dns.countNamesOwnedBy(
                        tx.from_address, @intCast(block.index));
                    const required_fee = dns_mod.feeForRegistrationWithOwnerCount(
                        claim.name, claim.tld, 1, owner_count);
                    if (tx.amount < required_fee) {
                        std.debug.print(
                            "[NS-CLAIM] underpaid: {s}.{s} need {d} got {d} (owner has {d} names)\n",
                            .{ claim.name, claim.tld, required_fee, tx.amount, owner_count },
                        );
                        continue;
                    }
                    dns.claimByPayment(claim.name, claim.tld, tx.from_address, @intCast(block.index)) catch |err| {
                        std.debug.print(
                            "[NS-CLAIM] reject {s}.{s} from {s}: {}\n",
                            .{ claim.name, claim.tld, tx.from_address, err },
                        );
                        continue;
                    };
                    std.debug.print(
                        "[NS-CLAIM] {s}.{s} -> {s} (paid {d} sat at block {d})\n",
                        .{ claim.name, claim.tld, tx.from_address, tx.amount, block.index },
                    );
                }
            }
        }

        // ── Governance proposal finalization + auto-execute ─────────────────
        // finalizeProposals flips voting → passed/rejected/expired for any
        // proposal whose voting_end_block < current. autoExecutePassedProposals
        // then runs each newly-passed action against consensus_params and marks
        // it .executed so it never re-runs.
        self.gov_registry.finalizeProposals(@intCast(block.index));
        self.autoExecutePassedProposals(@intCast(block.index));

        // ── Escrow auto-refund (timeout expired) ────────────────────────────
        // Verifica escrow-uri timed-out si returneaza fondurile la from_address.
        {
            var timed_out: [32]u64 = undefined;
            const n_to = self.escrow_registry.collectTimedOut(@intCast(block.index), &timed_out);
            for (timed_out[0..n_to]) |esc_id| {
                const esc = self.escrow_registry.get(esc_id) orelse continue;
                // Auto-refund: nu necesita TX explicit, chain o face automat
                const amount = self.escrow_registry.tryRefund(
                    esc_id, esc.fromSlice(), @intCast(block.index),
                );
                if (amount > 0) {
                    const bal = self.balances.get(esc.fromSlice()) orelse 0;
                    self.balances.put(esc.fromSlice(), bal + amount) catch {};
                    std.debug.print("[ESCROW-TIMEOUT] id={d} refund={d} to={s}\n",
                        .{ esc_id, amount, esc.fromSlice()[0..@min(16, esc.fromSlice().len)] });
                }
            }
        }

        // ── Subscription auto-execution ─────────────────────────────────────
        // For every subscription due at this block height, debit the
        // subscriber and credit the recipient directly in the balance cache.
        // Skips if subscriber doesn't have enough funds (payment deferred to
        // next interval — subscription stays active, not cancelled).
        {
            var due_ids: [64]u64 = undefined;
            const n_due = self.sub_registry.collectDue(@intCast(block.index), &due_ids);
            for (due_ids[0..n_due]) |sub_id| {
                const sub = self.sub_registry.get(sub_id) orelse continue;
                const total_debit = sub.amount_sat + sub_mod.SUB_EXEC_FEE_SAT;
                const from_bal = self.balances.get(sub.fromSlice()) orelse 0;
                if (from_bal < total_debit) {
                    // Insufficient funds — defer, advance next_block anyway
                    self.sub_registry.markExecuted(sub_id, @intCast(block.index));
                    continue;
                }
                self.balances.put(sub.fromSlice(), from_bal - total_debit) catch {};
                const to_bal = self.balances.get(sub.toSlice()) orelse 0;
                self.balances.put(sub.toSlice(), to_bal + sub.amount_sat) catch {};
                // SUB_EXEC_FEE goes to miner (already in block.reward via fee accounting)
                self.sub_registry.markExecuted(sub_id, @intCast(block.index));
                std.debug.print("[SUB-EXEC] id={d} from={s} to={s} amount={d}\n",
                    .{ sub_id, sub.fromSlice()[0..@min(16, sub.fromSlice().len)],
                       sub.toSlice()[0..@min(16, sub.toSlice().len)], sub.amount_sat });
            }
        }

        // ── Treasury auto-distribution hook ─────────────────────────────────
        // Check all active treasuries; if balance >= trigger_amount_sat,
        // auto-distribute to destinations (split by share_bps).
        // NOTE: Treasury structs are large (~8.7 KB each); use heap to avoid
        // stack overflow on every block apply.
        {
            const treas_buf = try self.allocator.alloc(treasury_multi_mod.Treasury, 64);
            defer self.allocator.free(treas_buf);
            const n_treas = self.treasury_multi_store.listAll(treas_buf[0..64]);
            for (treas_buf[0..n_treas]) |treas| {
                if (treas.trigger_amount_sat == 0) continue; // manual-only
                const bal = self.balances.get(treas.treasurySlice()) orelse 0;
                if (bal < treas.trigger_amount_sat) continue;
                var distributed: u64 = 0;
                var di: usize = 0;
                while (di < treas.dest_count) : (di += 1) {
                    const dest_amt = treas.destAmount(di, bal);
                    if (dest_amt == 0) continue;
                    if (bal < distributed + dest_amt) break;
                    distributed += dest_amt;
                    const to_bal = self.balances.get(treas.destinations[di].addressSlice()) orelse 0;
                    self.balances.put(treas.destinations[di].addressSlice(), to_bal + dest_amt) catch {};
                }
                if (distributed > 0) {
                    const from_bal = self.balances.get(treas.treasurySlice()) orelse 0;
                    self.balances.put(treas.treasurySlice(), from_bal -| distributed) catch {};
                    self.treasury_multi_store.recordDistribute(
                        treas.id[0..treasury_multi_mod.ID_HEX_LEN], distributed, @intCast(block.index),
                    );
                    std.debug.print("[TREASURY] auto-distribute {d} sat from {s}\n",
                        .{ distributed, treas.treasurySlice()[0..@min(20, treas.treasurySlice().len)] });
                }
            }
        }

        try self.chain.append(block);

        // Update cumulative work — proxy for 2^256 / target. Difficulty is
        // expressed as leading-zero hex digits, so adding a block at
        // difficulty D contributes work = 1 << (4*D). u128 prevents overflow
        // even at D=32 (work=2^128) over millions of blocks.
        self.cumulative_work += blockWork(self.difficulty);

        // Difficulty retarget
        const index = self.chain.items.len - 1;
        if (index % RETARGET_INTERVAL == 0 and index > 0) {
            const retarget_start = index - RETARGET_INTERVAL;
            const old_block_ts = self.chain.items[retarget_start].timestamp;
            const new_block_ts = block.timestamp;
            const actual_time = new_block_ts - old_block_ts;
            const new_diff = retargetDifficulty(self.difficulty, actual_time);
            if (new_diff != self.difficulty) {
                self.difficulty = new_diff;
            }
        }
    }

    /// Collect transactions from blocks being removed during reorg and return them to mempool.
    fn collectOrphanedTxs(self: *Blockchain, from_height: usize) !void {
        for (from_height..self.chain.items.len) |i| {
            const blk = &self.chain.items[i];
            for (blk.transactions.items) |tx| {
                try self.mempool.append(tx);
            }
        }
    }

    /// Remove mempool TXs that already exist in the current chain.
    fn removeMempoolDuplicates(self: *Blockchain) void {
        var write: usize = 0;
        for (self.mempool.items) |tx| {
            if (self.tx_block_height.get(tx.hash) != null) continue;
            self.mempool.items[write] = tx;
            write += 1;
        }
        self.mempool.items.len = write;
    }

    /// Recalculate balances, nonces, and tx_block_height by replaying all blocks from genesis.
    /// Made `pub` so p2p.zig can call after a truncate (reorg) to keep state coherent
    /// — without this, the balances HashMap retains entries for now-discarded blocks
    /// whose dupe()'d address keys may have been freed → segfault on next getOrPut.
    pub fn recalculateFromHeight(self: *Blockchain, from_height: usize) !void {
        // PHASE C.3 — full chain replay is a legitimate write window.
        self.in_apply_block = true;
        defer self.in_apply_block = false;

        _ = from_height;
        // Clear all balance/nonce/tx state and replay from genesis
        self.balances.clearRetainingCapacity();
        self.nonces.clearRetainingCapacity();
        self.tx_block_height.clearRetainingCapacity();
        self.stake_amounts.clearRetainingCapacity();
        // Free meta keys before clearing — same pattern as deinit().
        var meta_it_clear = self.stake_meta.iterator();
        while (meta_it_clear.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.stake_meta.clearRetainingCapacity();
        self.registered_agents.clearRetainingCapacity();
        // Clear and rebuild UTXO set from chain
        self.utxo_set.deinit();
        self.utxo_set = utxo_mod.UTXOSet.init(self.allocator);

        for (1..self.chain.items.len) |i| {
            const blk = &self.chain.items[i];
            var blk_total_fees: u64 = 0;
            for (blk.transactions.items) |tx| {
                const total_needed = tx.amount + tx.fee;
                // FIX (2026-05-03): la replay nu sarim TX-urile cu selectUTXOs failed.
                // Aceeasi logica ca in mineBlockForMiner — fallback pe balance check.
                var selection_opt: ?utxo_mod.UTXOSet.Selection = null;
                if (self.utxo_set.selectUTXOs(tx.from_address, total_needed, @intCast(blk.index), self.allocator)) |sel| {
                    selection_opt = sel;
                } else |err| {
                    std.debug.print("[RECALC] selectUTXOs failed for {s}: {} — fallback la balance check\n",
                        .{tx.from_address[0..@min(20, tx.from_address.len)], err});
                }
                if (selection_opt) |*selection| {
                    defer selection.utxos.deinit(self.allocator);
                    for (selection.utxos.items) |utxo| {
                        _ = self.utxo_set.spendUTXO(utxo.tx_hash, utxo.output_index) catch |err| {
                            std.debug.print("[RECALC] spendUTXO failed: {}\n", .{err});
                        };
                    }
                    if (selection.total > total_needed) {
                        const change = selection.total - total_needed;
                        self.utxo_set.addUTXO(tx.hash, 1, tx.from_address, change, @intCast(blk.index), "", false) catch {};
                    }
                }

                self.debitBalanceLocked(tx.from_address, tx.amount + tx.fee) catch {};
                self.creditBalanceLocked(tx.to_address, tx.amount) catch {};
                blk_total_fees += tx.fee;
                const current_nonce = self.nonces.get(tx.from_address) orelse 0;
                self.nonces.put(tx.from_address, current_nonce + 1) catch {};
                self.tx_block_height.put(tx.hash, @intCast(blk.index)) catch {};
                self.applyOpReturnRoles(tx);
                // Rebuild address_tx_index from persisted TXs (DB v4) so that
                // getaddresshistory returns history through restarts.
                self.indexAddressTx(tx.from_address, tx.hash);
                if (!std.mem.eql(u8, tx.from_address, tx.to_address)) {
                    self.indexAddressTx(tx.to_address, tx.hash);
                }
                self.utxo_set.addUTXO(tx.hash, 0, tx.to_address, tx.amount, @intCast(blk.index), "", false) catch {};
            }
            const fees_burned = blk_total_fees * FEE_BURN_PCT / 100;
            const fees_to_miner = blk_total_fees - fees_burned;
            if (blk.miner_address.len > 0 and (blk.reward_sat > 0 or fees_to_miner > 0)) {
                self.creditBalanceLocked(blk.miner_address, blk.reward_sat + fees_to_miner) catch {};
                self.utxo_set.addUTXO(blk.hash, 0, blk.miner_address, blk.reward_sat + fees_to_miner, @intCast(blk.index), "", true) catch {};
            }
        }
    }

    /// Process orphan blocks: check if any now connect to our chain tip.
    /// Keeps trying until no more orphans connect (cascading resolution).
    pub fn processOrphans(self: *Blockchain) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.processOrphansInternal();
    }

    /// Internal processOrphans (no mutex, called from methods that already hold it).
    fn processOrphansInternal(self: *Blockchain) void {
        var progress = true;
        while (progress) {
            progress = false;
            const tip_hash = self.chain.items[self.chain.items.len - 1].hash;
            var i: usize = 0;
            while (i < self.orphan_blocks.items.len) {
                const orphan = self.orphan_blocks.items[i];
                if (std.mem.eql(u8, orphan.previous_hash, tip_hash)) {
                    if (self.validateBlock(&orphan)) {
                        self.applyBlock(orphan) catch {
                            i += 1;
                            continue;
                        };
                        _ = self.orphan_blocks.swapRemove(i);
                        progress = true;
                        continue;
                    }
                }
                i += 1;
            }
        }
    }

    pub fn getBlock(self: *Blockchain, index: u32) ?Block {
        if (index < self.chain.items.len) {
            return self.chain.items[index];
        }
        return null;
    }

    // SEGFAULT-FIX [scan-2026-04-25] HIGH — getLatestBlock now deep-clones
    // under the chain mutex and returns an owned Block whose every heap-
    // borrowed slice (`hash`, `previous_hash`, `miner_address`, every TX
    // string, optional `fills` slice) is independently allocated from
    // `alloc`. Caller MUST call `freeClonedBlock(alloc, &block)` when done —
    // failing to do so leaks the cloned strings, the cloned TX list, and the
    // optional fills buffer. The returned Block is safe to access after
    // releasing bc.mutex even while the mining loop appends new blocks: it
    // shares no memory with `self.chain`.
    //
    // For RPC handlers that just need a header snapshot, prefer
    // `getLatestBlockSnapshot()` — no allocation, fixed-size buffers.
    // `getLatestBlock` is intentionally kept for code paths that need the
    // full Block (with TX list) — primarily test code.
    pub fn getLatestBlock(self: *Blockchain, alloc: std.mem.Allocator) !Block {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.chain.items.len == 0) return error.EmptyChain;
        return cloneBlockOwned(alloc, &self.chain.items[self.chain.items.len - 1]);
    }

    /// Free a Block returned by `getLatestBlock`. Frees every heap-borrowed
    /// slice, the cloned TX list, and the optional fills buffer.
    pub fn freeClonedBlock(alloc: std.mem.Allocator, block: *Block) void {
        if (block.hash.len > 0) alloc.free(block.hash);
        if (block.previous_hash.len > 0) alloc.free(block.previous_hash);
        if (block.miner_address.len > 0) alloc.free(block.miner_address);
        for (block.transactions.items) |*tx| {
            freeClonedTx(alloc, tx);
        }
        block.transactions.deinit();
        if (block.fills_heap and block.fills.len > 0) {
            alloc.free(block.fills);
        }
    }

    /// Internal: deep-clone a Block. Every heap-borrowed slice gets a fresh
    /// allocation from `alloc`. The returned Block shares no memory with `src`.
    fn cloneBlockOwned(alloc: std.mem.Allocator, src: *const Block) !Block {
        var out = Block{
            .index = src.index,
            .timestamp = src.timestamp,
            .transactions = array_list.Managed(Transaction).init(alloc),
            .previous_hash = "",
            .nonce = src.nonce,
            .hash = "",
            .merkle_root = src.merkle_root,
            .miner_address = "",
            .reward_sat = src.reward_sat,
            .miner_heap = true,
            .prices = src.prices,
            .prices_root = src.prices_root,
            .fills = &.{},
            .fills_root = src.fills_root,
            .fills_heap = false,
        };
        errdefer freeClonedBlock(alloc, &out);

        if (src.hash.len > 0) {
            out.hash = try alloc.dupe(u8, src.hash);
        }
        if (src.previous_hash.len > 0) {
            out.previous_hash = try alloc.dupe(u8, src.previous_hash);
        }
        if (src.miner_address.len > 0) {
            out.miner_address = try alloc.dupe(u8, src.miner_address);
        }
        try out.transactions.ensureTotalCapacity(src.transactions.items.len);
        for (src.transactions.items) |*src_tx| {
            const cloned_tx = try cloneTxOwned(alloc, src_tx);
            try out.transactions.append(cloned_tx);
        }
        if (src.fills.len > 0) {
            const Fill = @import("matching_engine.zig").Fill;
            const fills_buf = try alloc.alloc(Fill, src.fills.len);
            @memcpy(fills_buf, src.fills);
            out.fills = fills_buf;
            out.fills_heap = true;
        }
        return out;
    }

    fn cloneTxOwned(alloc: std.mem.Allocator, src: *const Transaction) !Transaction {
        var out: Transaction = src.*;
        // Reset slice fields so errdefer cleanup is well-defined if a later
        // dupe() fails partway through.
        out.from_address = "";
        out.to_address = "";
        out.op_return = "";
        out.script_pubkey = "";
        out.script_sig = "";
        out.signature = "";
        out.hash = "";
        out.public_key = "";
        out.inputs = &.{};
        out.outputs = &.{};
        out.data = "";
        errdefer freeClonedTx(alloc, &out);

        if (src.from_address.len > 0)  out.from_address  = try alloc.dupe(u8, src.from_address);
        if (src.to_address.len > 0)    out.to_address    = try alloc.dupe(u8, src.to_address);
        if (src.op_return.len > 0)     out.op_return     = try alloc.dupe(u8, src.op_return);
        if (src.script_pubkey.len > 0) out.script_pubkey = try alloc.dupe(u8, src.script_pubkey);
        if (src.script_sig.len > 0)    out.script_sig    = try alloc.dupe(u8, src.script_sig);
        if (src.signature.len > 0)     out.signature     = try alloc.dupe(u8, src.signature);
        if (src.hash.len > 0)          out.hash          = try alloc.dupe(u8, src.hash);
        if (src.public_key.len > 0)    out.public_key    = try alloc.dupe(u8, src.public_key);
        if (src.inputs.len > 0) {
            const InT = @TypeOf(src.inputs[0]);
            const buf = try alloc.alloc(InT, src.inputs.len);
            @memcpy(buf, src.inputs);
            out.inputs = buf;
        }
        if (src.outputs.len > 0) {
            const OutT = @TypeOf(src.outputs[0]);
            const buf = try alloc.alloc(OutT, src.outputs.len);
            @memcpy(buf, src.outputs);
            out.outputs = buf;
        }
        if (src.data.len > 0)          out.data          = try alloc.dupe(u8, src.data);
        return out;
    }

    fn freeClonedTx(alloc: std.mem.Allocator, tx: *Transaction) void {
        if (tx.from_address.len > 0)  alloc.free(tx.from_address);
        if (tx.to_address.len > 0)    alloc.free(tx.to_address);
        if (tx.op_return.len > 0)     alloc.free(tx.op_return);
        if (tx.script_pubkey.len > 0) alloc.free(tx.script_pubkey);
        if (tx.script_sig.len > 0)    alloc.free(tx.script_sig);
        if (tx.signature.len > 0)     alloc.free(tx.signature);
        if (tx.hash.len > 0)          alloc.free(tx.hash);
        if (tx.public_key.len > 0)    alloc.free(tx.public_key);
        if (tx.inputs.len > 0)        alloc.free(tx.inputs);
        if (tx.outputs.len > 0)       alloc.free(tx.outputs);
        if (tx.data.len > 0)          alloc.free(tx.data);
    }

    // SEGFAULT-FIX [scan-2026-04-25] LOW — read len under chain mutex so the
    // value can't change while a caller turns it into an index on the very
    // next line. ArrayList.items.len is a single usize (no torn read on
    // x86-64), but the larger correctness issue was that the value was used
    // immediately afterward to index `chain.items`; locking ensures this read
    // doesn't interleave with an in-flight `chain.append` reallocation. The
    // chain only grows during normal operation, so the value remains valid
    // (as a high-water mark) until the next append on this same thread.
    pub fn getBlockCount(self: *Blockchain) u32 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return @intCast(self.chain.items.len);
    }

    /// Lock-free variant of getBlockCount for callers that already hold
    /// self.mutex (non-reentrant std.Thread.Mutex panics on double-lock)
    /// or for read-only contexts where an off-by-one stale value is fine.
    /// Use this in RPC handlers that took the chain mutex earlier in the
    /// same function.
    pub fn getBlockCountUnlocked(self: *const Blockchain) u32 {
        return @intCast(self.chain.items.len);
    }

    /// Self-contained snapshot of the latest block — no slice-into-chain pointers,
    /// safe to use after releasing bc.mutex. Eliminates UAF in RPC handlers that
    /// previously held a Block-by-value while the chain reallocated underneath.
    /// SEGFAULT-FIX [scan-2026-04-25]: callers no longer need to keep bc.mutex
    /// locked across allocPrint — they get a stable copy and unlock immediately.
    pub fn getLatestBlockSnapshot(self: *Blockchain) BlockSnapshot {
        self.mutex.lock();
        defer self.mutex.unlock();
        const last = &self.chain.items[self.chain.items.len - 1];
        var snap = BlockSnapshot{
            .height       = last.index,
            .timestamp    = last.timestamp,
            .nonce        = last.nonce,
            .difficulty   = self.difficulty,
            .tx_count     = last.transactions.items.len,
            .hash_buf     = [_]u8{0} ** 96,
            .hash_len     = 0,
            .prev_hash_buf= [_]u8{0} ** 96,
            .prev_hash_len= 0,
            .merkle_root  = last.merkle_root,
        };
        const hl = @min(last.hash.len, snap.hash_buf.len);
        @memcpy(snap.hash_buf[0..hl], last.hash[0..hl]);
        snap.hash_len = hl;
        const pl = @min(last.previous_hash.len, snap.prev_hash_buf.len);
        @memcpy(snap.prev_hash_buf[0..pl], last.previous_hash[0..pl]);
        snap.prev_hash_len = pl;
        return snap;
    }

    // ─── PHASE 2F.2 — HTLC state transitions ────────────────────────────
    //
    // Dispatch a single HTLC-typed TX (htlc_init / htlc_claim / htlc_refund).
    // Called from applyBlock for every TX whose `tx_type` is in the HTLC
    // group. Funds are tracked virtually: bc.balances is the only ledger
    // touched. UTXO state is intentionally left alone — htlc_init carries
    // amount=0 on the typed envelope; the locked value lives entirely in
    // the registry until claim/refund releases it back into bc.balances.
    //
    // This emits WS events on success (htlc_created/htlc_claimed/htlc_refunded)
    // so the UI can react in real time. Errors are logged and the TX is
    // skipped — applyBlock keeps going so a single bad HTLC TX cannot stall
    // the rest of the block.
    fn applyHtlcTx(self: *Blockchain, tx: Transaction, block_height: u32) !void {
        switch (tx.tx_type) {
            .htlc_init => {
                const payload = try tx_payload_mod.HtlcInitPayload.decode(tx.data);
                try payload.validate();

                // Sender must have enough free balance to lock.
                const sender_bal = self.balances.get(tx.from_address) orelse 0;
                if (sender_bal < payload.amount_sat) return error.HtlcInsufficientFunds;

                // Build the deterministic 32-byte id from the init TX hash.
                const id = htlc_mod.computeHtlcId(tx.hash);

                // Build entry. sender = tx.from_address, recipient = tx.to_address.
                if (tx.from_address.len > htlc_mod.HTLC_MAX_ADDR_LEN) return error.HtlcAddressTooLong;
                if (tx.to_address.len > htlc_mod.HTLC_MAX_ADDR_LEN) return error.HtlcAddressTooLong;

                var e = htlc_mod.HtlcEntry{
                    .id = id,
                    .amount_sat = payload.amount_sat,
                    .hash_lock = payload.hash_lock,
                    .timelock_block = payload.timelock_block,
                    .init_block = block_height,
                    .state = .active,
                };
                @memcpy(e.sender[0..tx.from_address.len], tx.from_address);
                e.sender_len = @intCast(tx.from_address.len);
                @memcpy(e.recipient[0..tx.to_address.len], tx.to_address);
                e.recipient_len = @intCast(tx.to_address.len);
                if (tx.hash.len <= 64) {
                    @memcpy(e.init_tx_hash[0..tx.hash.len], tx.hash);
                    e.init_tx_hash_len = @intCast(tx.hash.len);
                }

                try self.htlc_registry.addEntry(e);
                // Lock sender funds (debit balance — held until claim/refund).
                try self.debitBalanceLocked(tx.from_address, payload.amount_sat);

                // WS event: htlc_created.
                if (main_mod.g_ws_srv) |ws| {
                    var json_buf: [512]u8 = undefined;
                    const json = std.fmt.bufPrint(&json_buf,
                        "{{\"type\":\"htlc_created\",\"htlc_id\":\"{s}\",\"sender\":\"{s}\",\"recipient\":\"{s}\",\"amount_sat\":{d},\"timelock_block\":{d}}}",
                        .{ tx.hash, tx.from_address, tx.to_address, payload.amount_sat, payload.timelock_block }) catch null;
                    if (json) |j| ws.broadcast(j);
                }
            },
            .htlc_claim => {
                const payload = try tx_payload_mod.HtlcClaimPayload.decode(tx.data);
                try payload.validate();

                // Lookup BEFORE applying claim so we can validate identity.
                const entry_opt = self.htlc_registry.get(payload.htlc_id);
                const entry = entry_opt orelse return error.HtlcNotFound;
                if (entry.state != .active) return error.HtlcNotActive;
                // Only the registered recipient can claim.
                if (!std.mem.eql(u8, entry.recipientSlice(), tx.from_address))
                    return error.HtlcUnauthorizedClaim;

                try self.htlc_registry.applyClaim(payload.htlc_id, payload.preimage);
                // Release locked funds to recipient (== tx.from_address here).
                try self.creditBalanceLocked(tx.from_address, entry.amount_sat);

                if (main_mod.g_ws_srv) |ws| {
                    var json_buf: [512]u8 = undefined;
                    var pre_hex: [64]u8 = undefined;
                    for (payload.preimage, 0..) |b, i| {
                        _ = std.fmt.bufPrint(pre_hex[i*2..i*2+2], "{x:0>2}", .{b}) catch {};
                    }
                    const json = std.fmt.bufPrint(&json_buf,
                        "{{\"type\":\"htlc_claimed\",\"htlc_id_tx\":\"{s}\",\"recipient\":\"{s}\",\"amount_sat\":{d},\"preimage\":\"{s}\"}}",
                        .{ tx.hash, tx.from_address, entry.amount_sat, &pre_hex }) catch null;
                    if (json) |j| ws.broadcast(j);
                }
            },
            .htlc_refund => {
                const payload = try tx_payload_mod.HtlcRefundPayload.decode(tx.data);
                try payload.validate();

                const entry_opt = self.htlc_registry.get(payload.htlc_id);
                const entry = entry_opt orelse return error.HtlcNotFound;
                if (entry.state != .active and entry.state != .expired)
                    return error.HtlcNotRefundable;
                // Only the original sender can refund.
                if (!std.mem.eql(u8, entry.senderSlice(), tx.from_address))
                    return error.HtlcUnauthorizedRefund;
                if (block_height < entry.timelock_block) return error.HtlcNotExpired;

                try self.htlc_registry.applyRefund(payload.htlc_id, block_height);
                // Return locked funds to sender.
                try self.creditBalanceLocked(tx.from_address, entry.amount_sat);

                if (main_mod.g_ws_srv) |ws| {
                    var json_buf: [512]u8 = undefined;
                    const json = std.fmt.bufPrint(&json_buf,
                        "{{\"type\":\"htlc_refunded\",\"htlc_id_tx\":\"{s}\",\"sender\":\"{s}\",\"amount_sat\":{d}}}",
                        .{ tx.hash, tx.from_address, entry.amount_sat }) catch null;
                    if (json) |j| ws.broadcast(j);
                }
            },
            else => {}, // not an HTLC TX — caller filtered already
        }
    }

    // ─── PHASE 2F.3: intent TX state transitions ─────────────────────────
    //
    // Intent TXs (0x40/0x41/0x43) carry signed off-chain swap commitments
    // through the chain so every node converges on the same SwapBinding
    // state. They do NOT move coin directly — bond locking is virtual via
    // bc.balances; settlement happens through the htlc_claim that the
    // taker eventually broadcasts on the destination chain. This function
    // emits WS events so the UI/orderbook can react in real time.
    //
    // Intent semantics here are intentionally minimal — the swap_registry
    // already captures full state via order_swap_link.zig, so applyIntentTx
    // serves mainly as: (a) on-chain receipt for solvers, (b) WS broadcast
    // surface, (c) a hook for future bond accounting. Errors are logged
    // and the TX is accepted into history regardless — the caller filters.
    fn applyIntentTx(self: *Blockchain, tx: Transaction, block_height: u32) !void {
        switch (tx.tx_type) {
            .intent_post => {
                const payload = try tx_payload_mod.IntentPostPayload.decode(tx.data);
                try payload.validate();

                // Bond accounting: maker locks `maker_amount_sat` worth of
                // collateral up-front. Without this, a malicious maker can
                // spam intents that cost them nothing and waste solver
                // bond bandwidth. We treat `maker_amount_sat` itself as
                // the maker's locked-bond size — the asset they're offering
                // — which matches how the matching engine collateralises
                // the parent order.
                //
                // We try the debit but DO NOT abort the TX on insufficient
                // funds: applyBlock is called for every TX in a block, and
                // a fork or replay must not panic the chain. If the maker
                // is broke, we emit a "warning" event and skip registry
                // entry — the order itself was already validated by mempool
                // admission, so insufficient funds at apply time means the
                // maker double-spent during the block window.
                const maker_bond = payload.maker_amount_sat;
                self.debitBalanceLocked(tx.from_address, maker_bond) catch |err| {
                    std.debug.print(
                        "[INTENT] post: cannot lock maker bond {d} for {s}: {} — entry skipped\n",
                        .{ maker_bond, tx.from_address[0..@min(20, tx.from_address.len)], err },
                    );
                    if (main_mod.g_ws_srv) |ws| {
                        var iid_hex: [64]u8 = undefined;
                        for (payload.intent_id, 0..) |b, i| {
                            _ = std.fmt.bufPrint(iid_hex[i*2..i*2+2], "{x:0>2}", .{b}) catch {};
                        }
                        var json_buf: [256]u8 = undefined;
                        const j = std.fmt.bufPrint(&json_buf,
                            "{{\"type\":\"intent_post_failed\",\"intent_id\":\"{s}\",\"reason\":\"insufficient_bond\"}}",
                            .{ &iid_hex }) catch null;
                        if (j) |s| ws.broadcast(s);
                    }
                    return;
                };

                // Build the registry entry. Caller's address slice is owned
                // by the TX, but we copy into the entry's fixed buffer so
                // it survives independently.
                if (tx.from_address.len > intent_reg_mod.MAX_ADDR_LEN) {
                    // Refund the bond we just took — entry can't be created.
                    self.creditBalanceLocked(tx.from_address, maker_bond) catch {};
                    return error.IntentAddressTooLong;
                }
                var entry: intent_reg_mod.IntentEntry = .{
                    .intent_id = payload.intent_id,
                    .swap_id = payload.swap_id,
                    .maker_amount_sat = payload.maker_amount_sat,
                    .taker_min_sat = payload.taker_min_sat,
                    .maker_bond_locked_sat = maker_bond,
                    .expiry_block = payload.expiry_block,
                    .state = .posted,
                };
                @memcpy(entry.maker_address[0..tx.from_address.len], tx.from_address);
                entry.maker_address_len = @intCast(tx.from_address.len);
                self.intent_registry.addEntry(entry) catch |err| {
                    // Refund on duplicate/full so book stays balanced.
                    self.creditBalanceLocked(tx.from_address, maker_bond) catch {};
                    std.debug.print("[INTENT] post addEntry failed: {} (bond refunded)\n", .{err});
                    return;
                };

                if (main_mod.g_ws_srv) |ws| {
                    var iid_hex: [64]u8 = undefined;
                    var sid_hex: [64]u8 = undefined;
                    for (payload.intent_id, 0..) |b, i| {
                        _ = std.fmt.bufPrint(iid_hex[i*2..i*2+2], "{x:0>2}", .{b}) catch {};
                    }
                    for (payload.swap_id, 0..) |b, i| {
                        _ = std.fmt.bufPrint(sid_hex[i*2..i*2+2], "{x:0>2}", .{b}) catch {};
                    }
                    var json_buf: [768]u8 = undefined;
                    const json = std.fmt.bufPrint(&json_buf,
                        "{{\"type\":\"intent_posted\",\"intent_id\":\"{s}\",\"swap_id\":\"{s}\",\"maker\":\"{s}\",\"taker_chain\":{d},\"expiry_block\":{d},\"maker_amount_sat\":{d},\"maker_bond_locked_sat\":{d}}}",
                        .{ &iid_hex, &sid_hex, tx.from_address, payload.taker_chain,
                           payload.expiry_block, payload.maker_amount_sat, maker_bond }) catch null;
                    if (json) |j| ws.broadcast(j);
                }
            },
            .intent_fill_commit => {
                const payload = try tx_payload_mod.IntentFillCommitPayload.decode(tx.data);
                try payload.validate();

                // Look up the parent intent. If it doesn't exist (rogue
                // commit, or post was skipped due to insufficient bond), we
                // skip registry mutation but accept the TX into history so
                // the address index sees it.
                const parent_opt = self.intent_registry.findById(payload.intent_id);
                if (parent_opt == null) {
                    std.debug.print("[INTENT] fill_commit: unknown intent_id — TX accepted, no bond locked\n", .{});
                    return;
                }
                const parent = parent_opt.?;
                if (parent.state != .posted) {
                    std.debug.print("[INTENT] fill_commit: intent in state {} — TX accepted, no bond locked\n",
                        .{parent.state});
                    return;
                }

                // Lock the solver's bond from their on-chain balance.
                self.debitBalanceLocked(tx.from_address, payload.bond_locked_sat) catch |err| {
                    std.debug.print(
                        "[INTENT] fill_commit: cannot lock taker bond {d} for {s}: {} — TX accepted, registry unchanged\n",
                        .{ payload.bond_locked_sat, tx.from_address[0..@min(20, tx.from_address.len)], err },
                    );
                    return;
                };

                self.intent_registry.commitFill(
                    payload.intent_id,
                    tx.from_address,
                    payload.bond_locked_sat,
                    payload.commit_block,
                ) catch |err| {
                    // Roll back the debit so the taker's balance is consistent.
                    self.creditBalanceLocked(tx.from_address, payload.bond_locked_sat) catch {};
                    std.debug.print("[INTENT] commitFill failed: {} (bond refunded)\n", .{err});
                    return;
                };

                if (main_mod.g_ws_srv) |ws| {
                    var iid_hex: [64]u8 = undefined;
                    for (payload.intent_id, 0..) |b, i| {
                        _ = std.fmt.bufPrint(iid_hex[i*2..i*2+2], "{x:0>2}", .{b}) catch {};
                    }
                    var json_buf: [512]u8 = undefined;
                    const json = std.fmt.bufPrint(&json_buf,
                        "{{\"type\":\"intent_committed\",\"intent_id\":\"{s}\",\"taker\":\"{s}\",\"bond_locked_sat\":{d},\"commit_block\":{d}}}",
                        .{ &iid_hex, tx.from_address, payload.bond_locked_sat, payload.commit_block }) catch null;
                    if (json) |j| ws.broadcast(j);
                }
            },
            .intent_timeout => {
                const payload = try tx_payload_mod.IntentTimeoutPayload.decode(tx.data);
                try payload.validate();

                const parent_opt = self.intent_registry.findById(payload.intent_id);
                if (parent_opt == null) {
                    std.debug.print("[INTENT] timeout: unknown intent_id — TX accepted, no slash applied\n", .{});
                    return;
                }
                const parent = parent_opt.?;

                // Two valid prior states:
                //  * .committed → taker bond is slashed to maker (penalty
                //    for missing the deadline). Maker bond is also returned.
                //  * .posted    → no taker bond exists; only the maker
                //    bond is refunded (intent expired before any solver
                //    committed — no slash, just cleanup).
                // Any other state (.settled / .timed_out) is a no-op.
                if (parent.state == .committed) {
                    const slash_amount = if (payload.slashed_bond_sat == 0)
                        parent.taker_bond_locked_sat
                    else
                        @min(payload.slashed_bond_sat, parent.taker_bond_locked_sat);

                    // Slash → maker.
                    if (slash_amount > 0 and parent.maker_address_len > 0) {
                        self.creditBalanceLocked(parent.makerSlice(), slash_amount) catch |err| {
                            std.debug.print("[INTENT] timeout: slash credit failed: {}\n", .{err});
                        };
                    }
                    // Refund any excess taker bond back to taker (not slashed).
                    const taker_refund = parent.taker_bond_locked_sat - slash_amount;
                    if (taker_refund > 0 and parent.taker_address_len > 0) {
                        self.creditBalanceLocked(parent.takerSlice(), taker_refund) catch {};
                    }
                    // Refund maker bond to maker.
                    if (parent.maker_bond_locked_sat > 0 and parent.maker_address_len > 0) {
                        self.creditBalanceLocked(parent.makerSlice(), parent.maker_bond_locked_sat) catch {};
                    }
                    self.intent_registry.markTimedOut(payload.intent_id) catch {};
                } else if (parent.state == .posted) {
                    // Only refund maker bond — no taker exists.
                    if (parent.maker_bond_locked_sat > 0 and parent.maker_address_len > 0) {
                        self.creditBalanceLocked(parent.makerSlice(), parent.maker_bond_locked_sat) catch {};
                    }
                    self.intent_registry.markTimedOut(payload.intent_id) catch {};
                } else {
                    std.debug.print("[INTENT] timeout: state {} — no-op\n", .{parent.state});
                }

                if (main_mod.g_ws_srv) |ws| {
                    var iid_hex: [64]u8 = undefined;
                    for (payload.intent_id, 0..) |b, i| {
                        _ = std.fmt.bufPrint(iid_hex[i*2..i*2+2], "{x:0>2}", .{b}) catch {};
                    }
                    var json_buf: [512]u8 = undefined;
                    const json = std.fmt.bufPrint(&json_buf,
                        "{{\"type\":\"intent_timed_out\",\"intent_id\":\"{s}\",\"slashed_bond_sat\":{d},\"block_height\":{d}}}",
                        .{ &iid_hex, payload.slashed_bond_sat, block_height }) catch null;
                    if (json) |j| ws.broadcast(j);
                }
            },
            .intent_settle => {
                // Settlement: parse intent_id from the payload (first 32 bytes
                // after the version byte — same convention as the other
                // intent payloads). Refund both bonds to their owners.
                //
                // We don't have a strict IntentSettlePayload decoder yet
                // (validatePayload accepts any non-empty bytes for this
                // type — see tx_payload.zig). The minimal field we need
                // is intent_id; tx.data layout: [0]=version, [1..33]=intent_id.
                if (tx.data.len < 33 or tx.data[0] != 1) {
                    std.debug.print("[INTENT] settle: bad payload — TX accepted, no bond movement\n", .{});
                    return;
                }
                var iid: [32]u8 = undefined;
                @memcpy(&iid, tx.data[1..33]);

                const parent_opt = self.intent_registry.findById(iid);
                if (parent_opt == null) {
                    std.debug.print("[INTENT] settle: unknown intent_id\n", .{});
                    return;
                }
                const parent = parent_opt.?;
                if (parent.state != .posted and parent.state != .committed) {
                    return; // already terminal — no-op
                }
                // Refund both bonds to their owners.
                if (parent.maker_bond_locked_sat > 0 and parent.maker_address_len > 0) {
                    self.creditBalanceLocked(parent.makerSlice(), parent.maker_bond_locked_sat) catch {};
                }
                if (parent.taker_bond_locked_sat > 0 and parent.taker_address_len > 0) {
                    self.creditBalanceLocked(parent.takerSlice(), parent.taker_bond_locked_sat) catch {};
                }
                self.intent_registry.markSettled(iid) catch {};

                if (main_mod.g_ws_srv) |ws| {
                    var iid_hex: [64]u8 = undefined;
                    for (iid, 0..) |b, i| {
                        _ = std.fmt.bufPrint(iid_hex[i*2..i*2+2], "{x:0>2}", .{b}) catch {};
                    }
                    var json_buf: [384]u8 = undefined;
                    const json = std.fmt.bufPrint(&json_buf,
                        "{{\"type\":\"intent_settled\",\"intent_id\":\"{s}\",\"maker_bond_refunded\":{d},\"taker_bond_refunded\":{d}}}",
                        .{ &iid_hex, parent.maker_bond_locked_sat, parent.taker_bond_locked_sat }) catch null;
                    if (json) |j| ws.broadcast(j);
                }
            },
            else => {}, // not an intent TX — caller filtered already
        }
    }

    // ─── PHASE 2B: deterministic order matching ─────────────────────────
    //
    // Called from applyBlock after all transfer TXs have settled.
    // Processes order_cancel TXs first (frees collateral), then sorts
    // order_place TXs canonically by (pair_id, price, tx_hash) and pushes
    // them through the matching engine. Same input block → same orderbook
    // state on every node, regardless of mempool arrival order.
    //
    // This routes orders to `self.exchange_engine` if attached. When the
    // matching engine isn't yet wired (testnet bootstrap, light node, or
    // pre-Phase-2 chain replay), we accept the TXs into history but skip
    // the match step — the orderbook will be empty until the engine is
    // attached, but the chain stays consistent.
    fn applyOrderTxs(self: *Blockchain, block: Block) !void {
        // Engine may be null on light nodes / replay paths. Accept the
        // TXs as recorded in history but skip matching.
        const engine_opt: ?*matching_mod.MatchingEngine = self.exchange_engine;

        // PHASE 2D — record the engine.fill_count BEFORE this block's order
        // TXs run, so we can slice the new fills generated for this block.
        const fills_before: u32 = if (engine_opt) |e| e.fill_count else 0;

        // ── Step 1: cancels first (frees collateral before matching) ──
        for (block.transactions.items) |tx| {
            if (tx.tx_type != .order_cancel) continue;
            const payload = tx_payload_mod.OrderCancelPayload.decode(tx.data) catch |err| {
                std.debug.print("[ORDER-CANCEL] decode {s} failed: {}\n",
                    .{ tx.hash[0..@min(16, tx.hash.len)], err });
                continue;
            };
            if (engine_opt) |eng| {
                eng.cancelOrder(payload.order_id) catch |err| switch (err) {
                    error.OrderNotFound => {}, // already cancelled / filled
                    else => std.debug.print("[ORDER-CANCEL] {d}: {}\n", .{ payload.order_id, err }),
                };
            }
        }

        // ── Step 2: collect + canonical sort of order_place TXs ───────
        var place_txs = std.ArrayList(usize){};
        defer place_txs.deinit(self.allocator);
        for (block.transactions.items, 0..) |tx, idx| {
            if (tx.tx_type != .order_place) continue;
            place_txs.append(self.allocator, idx) catch continue;
        }
        if (place_txs.items.len == 0) return; // nothing to match

        // Canonical sort: pair_id ASC, price ASC, tx_hash ASC.
        // No timestamps (clock-attackable), no mempool order
        // (non-deterministic). Tx hash is the unfakeable post-image.
        const SortCtx = struct {
            txs: []const transaction_mod.Transaction,
            fn lessThan(ctx: @This(), a_idx: usize, b_idx: usize) bool {
                const a_tx = ctx.txs[a_idx];
                const b_tx = ctx.txs[b_idx];
                const ap = tx_payload_mod.OrderPlacePayload.decode(a_tx.data) catch
                    return false;
                const bp = tx_payload_mod.OrderPlacePayload.decode(b_tx.data) catch
                    return false;
                if (ap.pair_id != bp.pair_id) return ap.pair_id < bp.pair_id;
                if (ap.price_micro_usd != bp.price_micro_usd)
                    return ap.price_micro_usd < bp.price_micro_usd;
                return std.mem.lessThan(u8, a_tx.hash, b_tx.hash);
            }
        };
        std.mem.sort(usize, place_txs.items, SortCtx{ .txs = block.transactions.items },
            SortCtx.lessThan);

        // ── Step 3: push each order through the matching engine ───────
        for (place_txs.items) |idx| {
            const tx = block.transactions.items[idx];
            const payload = tx_payload_mod.OrderPlacePayload.decode(tx.data) catch continue;

            // Check for optional cross-chain trailer. When present + chain != 0,
            // we register a SwapBinding before (or in parallel with) placing
            // the order. The Omnibus side still goes through the matching
            // engine so a local taker can match it; the binding tracks the
            // remote-chain HTLC counterpart.
            const trailer_opt: ?tx_payload_mod.OrderCrossChainTrailer = blk: {
                const got = tx_payload_mod.decodeOrderPlaceWithTrailer(tx.data) catch break :blk null;
                break :blk got.trailer;
            };

            var assigned_order_id: u64 = 0;
            if (engine_opt) |eng| {
                var order = matching_mod.Order.empty();
                order.side = switch (payload.side) {
                    .buy => .buy,
                    .sell => .sell,
                };
                order.pair_id = payload.pair_id;
                order.price_micro_usd = payload.price_micro_usd;
                order.amount_sat = payload.amount_sat;
                order.timestamp_ms = block.timestamp;
                const tn = @min(tx.from_address.len, order.trader_address.len);
                @memcpy(order.trader_address[0..tn], tx.from_address[0..tn]);
                order.trader_addr_len = @intCast(tn);
                order.status = .active;

                // Capture the order_id assigned by the matching engine
                // before placing (eng.next_order_id is the next id it will
                // hand out — it bumps on success, so this is correct).
                assigned_order_id = eng.next_order_id;
                eng.placeOrder(order) catch |err| {
                    std.debug.print("[ORDER-PLACE] {s} pair={d}: {}\n",
                        .{ tx.from_address[0..@min(16, tx.from_address.len)],
                           payload.pair_id, err });
                    assigned_order_id = 0; // signal failure
                };
            }

            // ─ cross-chain binding ─────────────────────────────────────
            if (trailer_opt) |t| {
                if (assigned_order_id == 0) continue; // engine rejected
                const taker_chain = swap_link_mod.Chain.fromU8(t.cross_chain_chain) orelse continue;
                if (taker_chain == .omnibus) continue; // not actually cross-chain
                // Build references. Maker side = Omnibus (the order TX itself is
                // the on-chain commitment; we use the tx hash as a synthetic
                // htlc id until htlc_init lands). Taker side = remote chain;
                // we copy the first 32 bytes of the htlc_ref blob as a
                // chain-agnostic anchor.
                var maker_anchor: [32]u8 = undefined;
                {
                    const hn = @min(tx.hash.len, 32);
                    @memset(&maker_anchor, 0);
                    @memcpy(maker_anchor[0..hn], tx.hash[0..hn]);
                }
                const maker_ref = swap_link_mod.HtlcRef{ .omnibus = maker_anchor };
                const taker_ref: swap_link_mod.HtlcRef = switch (taker_chain) {
                    .btc => blk: {
                        var txid: [32]u8 = undefined;
                        @memcpy(&txid, t.cross_chain_htlc_ref[0..32]);
                        const vout = std.mem.readInt(u32, t.cross_chain_htlc_ref[32..36], .little);
                        break :blk swap_link_mod.HtlcRef{ .btc = .{ .txid = txid, .vout = vout } };
                    },
                    .eth, .base, .liberty => blk: {
                        const chain_id = std.mem.readInt(u64, t.cross_chain_htlc_ref[0..8], .little);
                        var contract: [20]u8 = undefined;
                        @memcpy(&contract, t.cross_chain_htlc_ref[8..28]);
                        var hid: [32]u8 = std.mem.zeroes([32]u8);
                        @memcpy(hid[0..12], t.cross_chain_htlc_ref[28..40]);
                        break :blk swap_link_mod.HtlcRef{ .eth = .{
                            .chain_id = chain_id,
                            .contract = contract,
                            .id = hid,
                        } };
                    },
                    .omnibus => unreachable,
                };
                self.swap_registry.open(
                    assigned_order_id,
                    t.cross_chain_hash_lock,
                    .omnibus, // maker side is Omnibus (this chain)
                    taker_chain,
                    maker_ref,
                    taker_ref,
                    t.cross_chain_timeout_block,
                    block.index,
                ) catch |err| {
                    std.debug.print("[SWAP-BIND] open failed order_id={d}: {}\n",
                        .{ assigned_order_id, err });
                };
            }
        }

        // ─── PHASE 2D: capture fills generated by this block ────────────
        // Slice engine.fills[fills_before .. engine.fill_count] is the set
        // of fills produced by this block's order TXs. Copy into a
        // heap-owned slice keyed by block height in self.fills_history
        // so RPC endpoints (Ledgers, TradesHistory, OHLC, Spread) can
        // derive responses from chain state.
        if (engine_opt) |eng| {
            const fills_after = eng.fill_count;
            if (fills_after > fills_before) {
                const new_count = fills_after - fills_before;
                const heap_fills = self.allocator.alloc(matching_mod.Fill, new_count) catch {
                    std.debug.print("[ORDER-FILLS] alloc failed for {d} fills\n", .{new_count});
                    return;
                };
                var i: u32 = 0;
                while (i < new_count) : (i += 1) {
                    heap_fills[i] = eng.fills[fills_before + i];
                }
                self.fills_history.put(@intCast(block.index), heap_fills) catch {
                    self.allocator.free(heap_fills);
                };
            }
        }
    }
};

// ── PQ identity persistence ─────────────────────────────────────────────────
// pq_identity_map needs to survive restarts. We append-only-log every accepted
// pq_attest_v1 to a JSONL sidecar file at data/<chain>/pq_identities.jsonl,
// then re-hydrate the in-memory map at startup (see loadPqIdentitiesFromDisk
// below — called from main.zig after database restore).

var g_pq_persist_path_buf: [512]u8 = @splat(0);
var g_pq_persist_path_len: usize = 0;
var g_pq_persist_mutex: std.Thread.Mutex = .{};

pub fn pqPersistSetPath(path: []const u8) void {
    g_pq_persist_mutex.lock();
    defer g_pq_persist_mutex.unlock();
    const n = @min(path.len, g_pq_persist_path_buf.len);
    @memcpy(g_pq_persist_path_buf[0..n], path[0..n]);
    g_pq_persist_path_len = n;
}

fn pqPersistPath() ?[]const u8 {
    if (g_pq_persist_path_len == 0) return null;
    return g_pq_persist_path_buf[0..g_pq_persist_path_len];
}

fn persistPqIdentityAppend(alloc: std.mem.Allocator, from: []const u8, idt: *const PqIdentity) void {
    g_pq_persist_mutex.lock();
    defer g_pq_persist_mutex.unlock();
    const path = pqPersistPath() orelse return;

    const f = std.fs.cwd().createFile(path, .{ .truncate = false, .read = false }) catch |err| {
        std.debug.print("[PQ-IDENT] persist open {s} failed: {}\n", .{ path, err });
        return;
    };
    defer f.close();
    f.seekFromEnd(0) catch return;

    // Layout:
    //  {"from":"...","love":"...","food":"...","rent":"...","vacation":"...",
    //   "btc":"...","eth":"...","attest_block":N,"attest_tx":"..."}\n
    var buf = std.array_list.Managed(u8).init(alloc);
    defer buf.deinit();
    buf.writer().print(
        "{{\"from\":\"{s}\",\"love\":\"{s}\",\"food\":\"{s}\",\"rent\":\"{s}\",\"vacation\":\"{s}\"," ++
        "\"btc\":\"{s}\",\"eth\":\"{s}\",\"attest_block\":{d},\"attest_tx\":\"{s}\"}}\n",
        .{
            from,
            idt.loveSlice(), idt.foodSlice(), idt.rentSlice(), idt.vacationSlice(),
            idt.btcSlice(), idt.ethSlice(),
            idt.attest_block, idt.attestTxSlice(),
        },
    ) catch return;
    _ = f.writeAll(buf.items) catch |err| {
        std.debug.print("[PQ-IDENT] append failed: {}\n", .{err});
    };
}

/// Reload pq_identity_map from the JSONL sidecar. Called once at startup
/// after the database restore. Idempotent — duplicate `from` entries are
/// silently skipped (first-claim wins, matches on-chain semantics).
pub fn loadPqIdentitiesFromDisk(bc: *Blockchain, path: []const u8) !void {
    pqPersistSetPath(path);
    const f = std.fs.cwd().openFile(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer f.close();
    const stat = try f.stat();
    if (stat.size == 0) return;

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const buf = try arena.allocator().alloc(u8, @intCast(stat.size));
    _ = try f.readAll(buf);

    var lines = std.mem.splitScalar(u8, buf, '\n');
    var loaded: usize = 0;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const from = extractJsonStr(line, "\"from\":\"") orelse continue;
        if (bc.pq_identity_map.contains(from)) continue;

        var ident = PqIdentity{};
        if (extractJsonStr(line, "\"love\":\""))     |s| { copyToFixed(&ident.love,     &ident.love_len,     s); }
        if (extractJsonStr(line, "\"food\":\""))     |s| { copyToFixed(&ident.food,     &ident.food_len,     s); }
        if (extractJsonStr(line, "\"rent\":\""))     |s| { copyToFixed(&ident.rent,     &ident.rent_len,     s); }
        if (extractJsonStr(line, "\"vacation\":\"")) |s| { copyToFixed(&ident.vacation, &ident.vacation_len, s); }
        if (extractJsonStr(line, "\"btc\":\""))      |s| { copyToFixed(&ident.btc,      &ident.btc_len,      s); }
        if (extractJsonStr(line, "\"eth\":\""))      |s| { copyToFixed(&ident.eth,      &ident.eth_len,      s); }
        if (extractJsonStr(line, "\"attest_tx\":\"")) |s| {
            const c = @min(s.len, ident.attest_tx.len - 1);
            @memcpy(ident.attest_tx[0..c], s[0..c]);
            ident.attest_tx_len = @intCast(c);
        }
        if (extractJsonU64(line, "\"attest_block\":")) |n| ident.attest_block = n;

        const owned = bc.allocator.dupe(u8, from) catch continue;
        bc.pq_identity_map.put(owned, ident) catch {
            bc.allocator.free(owned);
            continue;
        };
        loaded += 1;
    }
    std.debug.print("[PQ-IDENT] Loaded {d} identity record(s) from {s}\n", .{ loaded, path });
}

fn extractJsonStr(line: []const u8, key: []const u8) ?[]const u8 {
    const start = std.mem.indexOf(u8, line, key) orelse return null;
    const from = start + key.len;
    if (from >= line.len) return null;
    const end = std.mem.indexOfScalarPos(u8, line, from, '"') orelse return null;
    return line[from..end];
}

fn extractJsonU64(line: []const u8, key: []const u8) ?u64 {
    const start = std.mem.indexOf(u8, line, key) orelse return null;
    const from = start + key.len;
    var end = from;
    while (end < line.len and std.ascii.isDigit(line[end])) : (end += 1) {}
    if (end == from) return null;
    return std.fmt.parseInt(u64, line[from..end], 10) catch null;
}

fn copyToFixed(buf: []u8, len_field: *u8, src: []const u8) void {
    const c = @min(src.len, buf.len);
    @memcpy(buf[0..c], src[0..c]);
    len_field.* = @intCast(c);
}

/// Self-contained snapshot of a block's metadata. No heap pointers / no slices
/// into the chain — safe to read after the originating Blockchain.mutex is released.
/// SEGFAULT-FIX [scan-2026-04-25]: replaces returning Block-by-value (which kept
/// hash/prev_hash slices into chain-owned memory and transactions ArrayList items
/// pointer, causing UAF when mining loop reallocs/swaps the chain).
pub const BlockSnapshot = struct {
    height:       u32,
    timestamp:    i64,
    nonce:        u64,
    difficulty:   u32,
    tx_count:     usize,
    /// Hex-encoded hash (typically 64 chars) — fixed buffer + length, no slice.
    hash_buf:     [96]u8,
    hash_len:     usize,
    prev_hash_buf:[96]u8,
    prev_hash_len:usize,
    /// 32-byte raw merkle root copy.
    merkle_root:  [32]u8,

    /// Returns the hash as a slice into the snapshot's own buffer. Safe for any
    /// lifetime ≤ that of the snapshot.
    pub fn hash(self: *const BlockSnapshot) []const u8 {
        return self.hash_buf[0..self.hash_len];
    }

    /// Returns the previous-hash as a slice into the snapshot's own buffer.
    pub fn prevHash(self: *const BlockSnapshot) []const u8 {
        return self.prev_hash_buf[0..self.prev_hash_len];
    }

    /// No-op — kept for API symmetry with future heap-allocated snapshots.
    pub fn deinit(_: *BlockSnapshot, _: std.mem.Allocator) void {}
};

// ─── Teste ───────────────────────────────────────────────────────────────────

const testing = std.testing;

test "blockRewardAt — bloc 0 = reward initial" {
    try testing.expectEqual(BLOCK_REWARD_SAT, blockRewardAt(0));
}

test "blockRewardAt — halving la HALVING_INTERVAL" {
    const r0 = blockRewardAt(0);
    const r1 = blockRewardAt(HALVING_INTERVAL);
    try testing.expectEqual(r0 / 2, r1);
}

test "blockRewardAt — dupa 64 halvings = 0" {
    try testing.expectEqual(@as(u64, 0), blockRewardAt(HALVING_INTERVAL * 64));
}

test "Blockchain.init — geneza + 1 bloc in chain" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();
    try testing.expectEqual(@as(u32, 1), bc.getBlockCount());
}

test "Blockchain.init — difficulty = 4" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();
    try testing.expectEqual(@as(u32, 4), bc.difficulty);
}

test "Blockchain.getBlock — bloc genesis la index 0" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();
    const genesis = bc.getBlock(0);
    try testing.expect(genesis != null);
    try testing.expectEqual(@as(u32, 0), genesis.?.index);
}

test "Blockchain.getBlock — index inexistent returneaza null" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();
    try testing.expect(bc.getBlock(999) == null);
}

test "Blockchain.getLatestBlock — initial = genesis" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();
    var latest = try bc.getLatestBlock(testing.allocator);
    defer Blockchain.freeClonedBlock(testing.allocator, &latest);
    try testing.expectEqual(@as(u32, 0), latest.index);
}

test "Blockchain.creditBalance — adauga sold" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();
    try bc.creditBalance("ob1ql33v8q9wqvqrschu982lvrnvfupyzcvj746kqh", 1_000_000_000);
    // PHASE-B: getAddressBalance citeste din UTXO, nu din RAM cache.
    // creditBalance scrie doar in cache; verificam cache-ul direct.
    try testing.expectEqual(@as(u64, 1_000_000_000), bc.balances.get("ob1ql33v8q9wqvqrschu982lvrnvfupyzcvj746kqh").?);
}

test "Blockchain.creditBalance — acumuleaza multiple credite" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();
    try bc.creditBalance("ob1ql33v8q9wqvqrschu982lvrnvfupyzcvj746kqh", 500_000_000);
    try bc.creditBalance("ob1ql33v8q9wqvqrschu982lvrnvfupyzcvj746kqh", 500_000_000);
    try testing.expectEqual(@as(u64, 1_000_000_000), bc.balances.get("ob1ql33v8q9wqvqrschu982lvrnvfupyzcvj746kqh").?);
}

test "Blockchain.debitBalance — scade sold" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();
    try bc.creditBalance("ob1qrpdsg3r7mvvunw6ket46qmjzlx6fuu3ppxlfas", 2_000_000_000);
    try bc.debitBalance("ob1qrpdsg3r7mvvunw6ket46qmjzlx6fuu3ppxlfas", 500_000_000);
    try testing.expectEqual(@as(u64, 1_500_000_000), bc.balances.get("ob1qrpdsg3r7mvvunw6ket46qmjzlx6fuu3ppxlfas").?);
}

test "Blockchain.debitBalance — sold insuficient => error" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();
    try bc.creditBalance("ob1q8yy5x2xqfdv0gt53wwfy66cqmkrafgx88kda02", 100);
    try testing.expectError(error.InsufficientBalance, bc.debitBalance("ob1q8yy5x2xqfdv0gt53wwfy66cqmkrafgx88kda02", 200));
}

test "Blockchain.getAddressBalance — adresa necunoscuta returneaza 0" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();
    try testing.expectEqual(@as(u64, 0), bc.getAddressBalance("ob1qqlkv63jlf7n2vh97tc4zj3h8tvplz0e5dj7mvq"));
}

test "Blockchain.validateTransaction — amount 0 invalid" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();
    const tx = Transaction{
        .id = 1, .from_address = "ob1qrgq6jnvvhcmp03ur849a85mhdvsvaqf6dprzn4", .to_address = "ob1qn8hr9y543qdvegeueffktd9lkrt2vq6q457xa0",
        .amount = 0, .timestamp = 0, .signature = "", .hash = "",
    };
    try testing.expect(!try bc.validateTransaction(&tx));
}

test "Blockchain.validateTransaction — adresa goala invalid" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();
    const tx = Transaction{
        .id = 1, .from_address = "", .to_address = "ob1qn8hr9y543qdvegeueffktd9lkrt2vq6q457xa0",
        .amount = 100, .timestamp = 0, .signature = "", .hash = "",
    };
    try testing.expect(!try bc.validateTransaction(&tx));
}

test "Blockchain.validateTransaction — prefix invalid" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();
    const tx = Transaction{
        .id = 1, .from_address = "invalid_prefix_addr", .to_address = "ob1qn8hr9y543qdvegeueffktd9lkrt2vq6q457xa0",
        .amount = 100, .timestamp = 0, .signature = "", .hash = "",
    };
    try testing.expect(!try bc.validateTransaction(&tx));
}

test "Blockchain.validateTransaction — nonce replay attack blocked" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();

    // Give sender some balance via UTXO (PHASE-B: validateTransaction reads from UTXO)
    try bc.utxo_set.addUTXO("funding_tx_01", 0, "ob1ql33v8q9wqvqrschu982lvrnvfupyzcvj746kqh", 10_000, 1, "", false);

    // First TX with nonce 0 should be valid (fee >= TX_MIN_FEE)
    const tx1 = Transaction{
        .id = 1, .from_address = "ob1ql33v8q9wqvqrschu982lvrnvfupyzcvj746kqh", .to_address = "ob1qrpdsg3r7mvvunw6ket46qmjzlx6fuu3ppxlfas",
        .amount = 100, .fee = 1, .timestamp = 1700000000, .nonce = 0, .signature = "", .hash = "",
    };
    try testing.expect(try bc.validateTransaction(&tx1));

    // Simulate nonce increment after processing
    try bc.nonces.put("ob1ql33v8q9wqvqrschu982lvrnvfupyzcvj746kqh", 1);

    // Replay same TX with nonce 0 should be rejected (nonce too low)
    try testing.expect(!try bc.validateTransaction(&tx1));

    // TX with nonce 1 should be valid
    const tx2 = Transaction{
        .id = 2, .from_address = "ob1ql33v8q9wqvqrschu982lvrnvfupyzcvj746kqh", .to_address = "ob1qrpdsg3r7mvvunw6ket46qmjzlx6fuu3ppxlfas",
        .amount = 100, .fee = 1, .timestamp = 1700000001, .nonce = 1, .signature = "", .hash = "",
    };
    try testing.expect(try bc.validateTransaction(&tx2));
}

test "Blockchain.validateTransaction — insufficient balance rejected (amount + fee)" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();

    // Sender has 0 balance
    const tx = Transaction{
        .id = 1, .from_address = "ob1qu6d376ysuserqh6rjeh8q0t39j7qp9fcl87hk6", .to_address = "ob1qrpdsg3r7mvvunw6ket46qmjzlx6fuu3ppxlfas",
        .amount = 1_000_000, .fee = 1, .timestamp = 1700000000, .nonce = 0, .signature = "", .hash = "",
    };
    try testing.expect(!try bc.validateTransaction(&tx));
}

test "Blockchain.validateTransaction — fee too low rejected" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();

    try bc.utxo_set.addUTXO("funding_tx_02", 0, "ob1ql33v8q9wqvqrschu982lvrnvfupyzcvj746kqh", 10_000, 1, "", false);
    const tx = Transaction{
        .id = 1, .from_address = "ob1ql33v8q9wqvqrschu982lvrnvfupyzcvj746kqh", .to_address = "ob1qrpdsg3r7mvvunw6ket46qmjzlx6fuu3ppxlfas",
        .amount = 100, .fee = 0, .timestamp = 1700000000, .nonce = 0, .signature = "", .hash = "",
    };
    try testing.expect(!try bc.validateTransaction(&tx));
}

test "Blockchain.validateTransaction — balance must cover amount + fee" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();

    // Sender has exactly 100 SAT via UTXO, TX needs 100 amount + 1 fee = 101
    try bc.utxo_set.addUTXO("funding_tx_03", 0, "ob1ql33v8q9wqvqrschu982lvrnvfupyzcvj746kqh", 100, 1, "", false);
    const tx = Transaction{
        .id = 1, .from_address = "ob1ql33v8q9wqvqrschu982lvrnvfupyzcvj746kqh", .to_address = "ob1qrpdsg3r7mvvunw6ket46qmjzlx6fuu3ppxlfas",
        .amount = 100, .fee = 1, .timestamp = 1700000000, .nonce = 0, .signature = "", .hash = "",
    };
    try testing.expect(!try bc.validateTransaction(&tx));
}

test "Blockchain.getNextNonce — unknown address returns 0" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();
    try testing.expectEqual(@as(u64, 0), bc.getNextNonce("ob1qf67we03tka2etd5u8lsa3uf5aq9605hu99yxc2"));
}

test "Blockchain.validateTransaction — nonce gap rejected (strict ordering)" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();

    try bc.utxo_set.addUTXO("funding_tx_04", 0, "ob1ql33v8q9wqvqrschu982lvrnvfupyzcvj746kqh", 100_000, 1, "", false);

    // Expected nonce is 0, but TX has nonce 5 — gap should be rejected
    const tx_gap = Transaction{
        .id = 1, .from_address = "ob1ql33v8q9wqvqrschu982lvrnvfupyzcvj746kqh", .to_address = "ob1qrpdsg3r7mvvunw6ket46qmjzlx6fuu3ppxlfas",
        .amount = 100, .fee = 1, .timestamp = 1700000000, .nonce = 5, .signature = "", .hash = "",
    };
    try testing.expect(!try bc.validateTransaction(&tx_gap));

    // nonce 0 should be accepted
    const tx_ok = Transaction{
        .id = 2, .from_address = "ob1ql33v8q9wqvqrschu982lvrnvfupyzcvj746kqh", .to_address = "ob1qrpdsg3r7mvvunw6ket46qmjzlx6fuu3ppxlfas",
        .amount = 100, .fee = 1, .timestamp = 1700000001, .nonce = 0, .signature = "", .hash = "",
    };
    try testing.expect(try bc.validateTransaction(&tx_ok));
}

test "Blockchain.getNextAvailableNonce — includes pending mempool TXs" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();

    // Chain nonce is 0
    try testing.expectEqual(@as(u64, 0), bc.getNextAvailableNonce("ob1ql33v8q9wqvqrschu982lvrnvfupyzcvj746kqh"));

    // Add a TX to the internal mempool (simulating addTransaction bypassing validation)
    try bc.mempool.append(Transaction{
        .id = 1, .from_address = "ob1ql33v8q9wqvqrschu982lvrnvfupyzcvj746kqh", .to_address = "ob1qrpdsg3r7mvvunw6ket46qmjzlx6fuu3ppxlfas",
        .amount = 100, .fee = 1, .timestamp = 1700000000, .nonce = 0, .signature = "", .hash = "",
    });

    // Now next available nonce should be 1 (chain_nonce=0 + 1 pending)
    try testing.expectEqual(@as(u64, 1), bc.getNextAvailableNonce("ob1ql33v8q9wqvqrschu982lvrnvfupyzcvj746kqh"));

    // Bob has no pending TXs
    try testing.expectEqual(@as(u64, 0), bc.getNextAvailableNonce("ob1qrpdsg3r7mvvunw6ket46qmjzlx6fuu3ppxlfas"));
}

test "Blockchain.isValidHash — 4 zerouri leading = valid" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();
    try testing.expect(try bc.isValidHash("0000abcdef123456789012345678901234567890123456789012345678901234"));
}

test "Blockchain.isValidHash — 3 zerouri leading = invalid (difficulty=4)" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();
    try testing.expect(!try bc.isValidHash("000abcdef1234567890123456789012345678901234567890123456789012345"));
}

test "Blockchain.calculateBlockHash — produce 64 chars hex" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();
    const genesis = bc.getBlock(0).?;
    const hash = try bc.calculateBlockHash(&genesis);
    defer bc.allocator.free(hash);
    try testing.expectEqual(@as(usize, 64), hash.len);
}

test "retargetDifficulty — prea rapid → creste dificultatea" {
    // actual_time = 504s = target/4 → clamp → new = old * 2016 / 504 = old*4
    const new_d = retargetDifficulty(4, 504);
    try testing.expectEqual(@as(u32, 16), new_d);
}

test "retargetDifficulty — prea lent → scade dificultatea" {
    // actual_time = 8064s = target*4 → clamp → new = old * 2016 / 8064 = old/4
    const new_d = retargetDifficulty(8, 8064);
    try testing.expectEqual(@as(u32, 2), new_d);
}

test "retargetDifficulty — exact target → dificultate neschimbata" {
    const new_d = retargetDifficulty(6, TARGET_INTERVAL_S);
    try testing.expectEqual(@as(u32, 6), new_d);
}

test "retargetDifficulty — clamp la MAX_DIFFICULTY" {
    // actual_time extrem de mic → ar da overflow → limitat la MAX
    const new_d = retargetDifficulty(MAX_DIFFICULTY, 1);
    try testing.expectEqual(MAX_DIFFICULTY, new_d);
}

test "retargetDifficulty — clamp la MIN_DIFFICULTY" {
    // actual_time maxim posibil, dificultate mica → nu scade sub 1
    const new_d = retargetDifficulty(1, TARGET_INTERVAL_S * 100);
    try testing.expectEqual(MIN_DIFFICULTY, new_d);
}

test "retargetDifficulty — actual_time zero → returneaza old" {
    const new_d = retargetDifficulty(5, 0);
    try testing.expectEqual(@as(u32, 5), new_d);
}

test "Blockchain.calculateBlockHash — determinist" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();
    const genesis = bc.getBlock(0).?;
    const h1 = try bc.calculateBlockHash(&genesis);
    defer bc.allocator.free(h1);
    const h2 = try bc.calculateBlockHash(&genesis);
    defer bc.allocator.free(h2);
    try testing.expectEqualSlices(u8, h1, h2);
}

test "Blockchain.validateTransaction — rejects TX when pending outgoing exceeds balance" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();

    // Credit Alice 1000 SAT via UTXO
    try bc.utxo_set.addUTXO("funding_tx_pending", 0, "ob1qgg00y7hepe45r2fqcv8lw4009jyy7gc6c843ll", 1000, 1, "", false);

    // TX1: Alice sends 400 SAT (fee=1), nonce=0 — should succeed
    const tx1 = Transaction{
        .id = 1,
        .from_address = "ob1qgg00y7hepe45r2fqcv8lw4009jyy7gc6c843ll",
        .to_address = "ob1q3h3gwya8twy35f92qcyseqf2g3vc2qc8ln8g92",
        .amount = 400,
        .fee = 1,
        .timestamp = 1700000000,
        .nonce = 0,
        .signature = "",
        .hash = "",
    };
    try bc.addTransaction(tx1);

    // Verify pending outgoing is 401 (400 amount + 1 fee)
    try testing.expectEqual(@as(u64, 401), bc.getPendingOutgoing("ob1qgg00y7hepe45r2fqcv8lw4009jyy7gc6c843ll"));

    // TX2: Alice sends 700 SAT (fee=1), nonce=1 — should FAIL
    // Available = 1000 - 401 = 599, but TX2 needs 701 (700+1)
    const tx2 = Transaction{
        .id = 2,
        .from_address = "ob1qgg00y7hepe45r2fqcv8lw4009jyy7gc6c843ll",
        .to_address = "ob1q3h3gwya8twy35f92qcyseqf2g3vc2qc8ln8g92",
        .amount = 700,
        .fee = 1,
        .timestamp = 1700000001,
        .nonce = 1,
        .signature = "",
        .hash = "",
    };
    try testing.expectError(error.InvalidTransaction, bc.addTransaction(tx2));

    // TX3: Alice sends 500 SAT (fee=1), nonce=1 — should SUCCEED
    // Available = 1000 - 401 = 599, TX3 needs 501 (500+1) — fits
    const tx3 = Transaction{
        .id = 3,
        .from_address = "ob1qgg00y7hepe45r2fqcv8lw4009jyy7gc6c843ll",
        .to_address = "ob1q3h3gwya8twy35f92qcyseqf2g3vc2qc8ln8g92",
        .amount = 500,
        .fee = 1,
        .timestamp = 1700000002,
        .nonce = 1,
        .signature = "",
        .hash = "",
    };
    try bc.addTransaction(tx3);

    // After TX1 (401) + TX3 (501) pending = 902, available = 98
    try testing.expectEqual(@as(u64, 902), bc.getPendingOutgoing("ob1qgg00y7hepe45r2fqcv8lw4009jyy7gc6c843ll"));
}

test "Blockchain.getConfirmations — unknown TX returns null" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();
    try testing.expect(bc.getConfirmations("nonexistent_tx_hash") == null);
}

test "Blockchain.getConfirmations — tracked TX returns correct count" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();
    // Simulate: TX was included in block at height 5
    try bc.tx_block_height.put("test_tx_hash_001", 5);
    // Chain has 1 block (genesis at index 0), so chain.items.len = 1
    // Confirmations = 1 - 5 => would underflow, so should return 0
    try testing.expectEqual(@as(u64, 0), bc.getConfirmations("test_tx_hash_001").?);
}

test "Blockchain.getTxBlockHeight — returns stored height" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();
    try bc.tx_block_height.put("tx_abc", 42);
    try testing.expectEqual(@as(u64, 42), bc.getTxBlockHeight("tx_abc").?);
}

test "Blockchain.getTxBlockHeight — unknown returns null" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();
    try testing.expect(bc.getTxBlockHeight("unknown") == null);
}

// ─── Block Validation Tests (B7) ────────────────────────────────────────────

test "Blockchain.validateBlock — genesis block always valid" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();
    const genesis = bc.getBlock(0).?;
    try testing.expect(bc.validateBlock(&genesis));
}

test "Blockchain.validateBlock — wrong merkle root rejected" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();

    // Set difficulty to 1 so our fake hash passes difficulty check
    bc.difficulty = 1;

    var block = Block{
        .index = 1,
        .timestamp = 1743000001,
        .transactions = array_list.Managed(Transaction).init(testing.allocator),
        .previous_hash = "genesis_hash_omnibus_v1",
        .nonce = 0,
        .hash = "0aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .merkle_root = [_]u8{0xFF} ** 32, // Wrong merkle root (should be all zeros for empty TX list)
        .reward_sat = 0,
    };
    defer block.transactions.deinit();

    try testing.expect(!bc.validateBlock(&block));
}

test "Blockchain.validateBlock — future timestamp rejected" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();

    bc.difficulty = 1;
    const now = std.time.timestamp();

    var block = Block{
        .index = 1,
        .timestamp = now + 10000, // More than 2 hours in the future
        .transactions = array_list.Managed(Transaction).init(testing.allocator),
        .previous_hash = "genesis_hash_omnibus_v1",
        .nonce = 0,
        .hash = "0aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .merkle_root = [_]u8{0} ** 32,
        .reward_sat = 0,
    };
    defer block.transactions.deinit();

    try testing.expect(!bc.validateBlock(&block));
}

test "Blockchain.validateBlock — wrong previous_hash rejected" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();

    bc.difficulty = 1;

    var block = Block{
        .index = 1,
        .timestamp = 1743000001,
        .transactions = array_list.Managed(Transaction).init(testing.allocator),
        .previous_hash = "wrong_previous_hash_does_not_match_genesis",
        .nonce = 0,
        .hash = "0aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .merkle_root = [_]u8{0} ** 32,
        .reward_sat = 0,
    };
    defer block.transactions.deinit();

    try testing.expect(!bc.validateBlock(&block));
}

test "Blockchain.validateBlock — hash not meeting difficulty rejected" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();

    // difficulty = 4 (default), hash has only 1 leading zero
    var block = Block{
        .index = 1,
        .timestamp = 1743000001,
        .transactions = array_list.Managed(Transaction).init(testing.allocator),
        .previous_hash = "genesis_hash_omnibus_v1",
        .nonce = 0,
        .hash = "0aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .merkle_root = [_]u8{0} ** 32,
        .reward_sat = 0,
    };
    defer block.transactions.deinit();

    // difficulty=4 but hash has only 1 leading zero => rejected
    try testing.expect(!bc.validateBlock(&block));
}

test "Blockchain.validateBlock — inflated reward rejected" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();

    bc.difficulty = 1;

    var block = Block{
        .index = 1,
        .timestamp = 1743000001,
        .transactions = array_list.Managed(Transaction).init(testing.allocator),
        .previous_hash = "genesis_hash_omnibus_v1",
        .nonce = 0,
        .hash = "0aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .merkle_root = [_]u8{0} ** 32,
        .reward_sat = 999_999_999_999, // Way more than allowed block reward
    };
    defer block.transactions.deinit();

    try testing.expect(!bc.validateBlock(&block));
}

test "Blockchain.validateBlock — valid block passes all checks" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();

    bc.difficulty = 1;

    var block = Block{
        .index = 1,
        .timestamp = 1743000001,
        .transactions = array_list.Managed(Transaction).init(testing.allocator),
        .previous_hash = "genesis_hash_omnibus_v1",
        .nonce = 0,
        .hash = "0aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .merkle_root = [_]u8{0} ** 32, // Correct for empty TX list
        .reward_sat = BLOCK_REWARD_SAT, // Correct block reward
    };
    defer block.transactions.deinit();

    try testing.expect(bc.validateBlock(&block));
}

test "Blockchain.addExternalBlock — invalid block returns error" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();

    // Block with wrong merkle root
    var bad_block = Block{
        .index = 1,
        .timestamp = 1743000001,
        .transactions = array_list.Managed(Transaction).init(testing.allocator),
        .previous_hash = "genesis_hash_omnibus_v1",
        .nonce = 0,
        .hash = "0000aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .merkle_root = [_]u8{0xFF} ** 32,
        .reward_sat = 0,
    };
    defer bad_block.transactions.deinit();

    try testing.expectError(error.InvalidBlock, bc.addExternalBlock(bad_block));
}

test "Blockchain.addExternalBlock — valid block appended and miner credited" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();

    bc.difficulty = 1;
    const reward = blockRewardAt(1);

    // Heap-allocate hash so deinit can free it (blocks at index>0 with 64-char hash get freed)
    const hash_str = try testing.allocator.alloc(u8, 64);
    @memset(hash_str, 'a');
    hash_str[0] = '0'; // leading zero for difficulty=1
    const block = Block{
        .index = 1,
        .timestamp = 1743000001,
        .transactions = array_list.Managed(Transaction).init(testing.allocator),
        .previous_hash = "genesis_hash_omnibus_v1",
        .nonce = 0,
        .hash = hash_str,
        .merkle_root = [_]u8{0} ** 32,
        .miner_address = "ob1q5lk2scarv6nvqgzeekdv5xhjv7v9yex73qhm40",
        .reward_sat = reward,
    };
    // Do NOT defer deinit — blockchain takes ownership (deinit frees hash + transactions)

    try bc.addExternalBlock(block);

    // Chain should now have 2 blocks (genesis + external)
    try testing.expectEqual(@as(u32, 2), bc.getBlockCount());
    // Miner should be credited with block reward
    try testing.expectEqual(reward, bc.getAddressBalance("ob1q5lk2scarv6nvqgzeekdv5xhjv7v9yex73qhm40"));
}

// ─── Timelock + OP_RETURN Blockchain Tests (B4) ────────────────────────────

test "Blockchain.validateTransaction — locktime > current_height rejected" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();

    try bc.utxo_set.addUTXO("funding_tx_lockh", 0, "ob1qmcl7lj9e5wg6523ynqyg6xklhg67tgjspv7dg6", 100_000, 1, "", false);

    // Chain has 1 block (genesis), so chain.items.len = 1 = current_height
    // TX locked until block 100 → rejected (100 > 1)
    const tx = Transaction{
        .id = 1, .from_address = "ob1qmcl7lj9e5wg6523ynqyg6xklhg67tgjspv7dg6", .to_address = "ob1qlu4ev8rqhzw65w7m0at8khnvxje9y7t7n2plhn",
        .amount = 1000, .fee = 1, .timestamp = 1700000000, .nonce = 0,
        .locktime = 100,
        .signature = "", .hash = "",
    };
    try testing.expect(!try bc.validateTransaction(&tx));
}

test "Blockchain.validateTransaction — locktime <= current_height accepted" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();

    try bc.utxo_set.addUTXO("funding_tx_lock1", 0, "ob1qje7f8p2nm66d2x5m6vvx8s0wkuyhc439c2q85r", 100_000, 1, "", false);

    // Chain has 1 block, so current_height = 1
    // TX locked until block 1 → accepted (1 <= 1)
    const tx = Transaction{
        .id = 1, .from_address = "ob1qje7f8p2nm66d2x5m6vvx8s0wkuyhc439c2q85r", .to_address = "ob1qvwz680427a037eqyzv675xavxm8txh792h3m0r",
        .amount = 1000, .fee = 1, .timestamp = 1700000000, .nonce = 0,
        .locktime = 1,
        .signature = "", .hash = "",
    };
    try testing.expect(try bc.validateTransaction(&tx));
}

test "Blockchain.validateTransaction — locktime 0 always accepted (immediate)" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();

    try bc.utxo_set.addUTXO("funding_tx_lock0", 0, "ob1qwtdsz27whtcajhqjl4e6yc9l2vpujzzt7z8dxe", 100_000, 1, "", false);

    const tx = Transaction{
        .id = 1, .from_address = "ob1qwtdsz27whtcajhqjl4e6yc9l2vpujzzt7z8dxe", .to_address = "ob1qvvvn3uz7nh2v93eyx7y85rc7usumvgc3kle246",
        .amount = 1000, .fee = 1, .timestamp = 1700000000, .nonce = 0,
        .locktime = 0,
        .signature = "", .hash = "",
    };
    try testing.expect(try bc.validateTransaction(&tx));
}

test "Blockchain.validateTransaction — op_return data-only TX accepted" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();

    // OP_RETURN TX: amount=0, op_return set, fee >= 1
    try bc.utxo_set.addUTXO("funding_tx_opret", 0, "ob1q8nfugl99a2ntr06grn9g3szeuw9f4ztdq6trl2", 100_000, 1, "", false);

    const tx = Transaction{
        .id = 1, .from_address = "ob1q8nfugl99a2ntr06grn9g3szeuw9f4ztdq6trl2", .to_address = "ob1q8nfugl99a2ntr06grn9g3szeuw9f4ztdq6trl2",
        .amount = 0, .fee = 1, .timestamp = 1700000000, .nonce = 0,
        .op_return = "timestamp:2026-03-30T12:00:00Z",
        .signature = "", .hash = "",
    };
    try testing.expect(try bc.validateTransaction(&tx));
}

test "Blockchain.validateTransaction — op_return > 80 bytes rejected" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();

    try bc.utxo_set.addUTXO("funding_tx_big", 0, "ob1qtqh0uelqt8670n3j4ny0l6wpacgwe4as2f42d3", 100_000, 1, "", false);

    const big_data = "X" ** 81;
    const tx = Transaction{
        .id = 1, .from_address = "ob1qtqh0uelqt8670n3j4ny0l6wpacgwe4as2f42d3", .to_address = "ob1qtqh0uelqt8670n3j4ny0l6wpacgwe4as2f42d3",
        .amount = 0, .fee = 1, .timestamp = 1700000000, .nonce = 0,
        .op_return = big_data,
        .signature = "", .hash = "",
    };
    try testing.expect(!try bc.validateTransaction(&tx));
}

// ─── Chain Reorganization Tests (B8) ────────────────────────────────────────

/// Helper: create a valid block with given parameters (difficulty=1, no TX)
/// `variant` byte makes the hash unique across different chains (0='a' default)
fn makeTestBlockV(alloc: std.mem.Allocator, idx: u32, prev_hash: []const u8, miner: []const u8, variant: u8) !Block {
    const hash_str = try alloc.alloc(u8, 64);
    @memset(hash_str, 'a');
    hash_str[0] = '0'; // leading zero for difficulty=1

    // Make hash unique per index by encoding the index
    var idx_buf: [10]u8 = undefined;
    const idx_str = std.fmt.bufPrint(&idx_buf, "{d}", .{idx}) catch "0";
    for (idx_str, 0..) |c, j| {
        if (j + 1 < 64) hash_str[j + 1] = c;
    }
    // Variant byte at a safe position to differentiate chains
    if (variant != 0) {
        hash_str[12] = variant;
    }

    return Block{
        .index = idx,
        .timestamp = 1743000000 + @as(i64, @intCast(idx)),
        .transactions = array_list.Managed(Transaction).init(alloc),
        .previous_hash = prev_hash,
        .nonce = 0,
        .hash = hash_str,
        .merkle_root = [_]u8{0} ** 32,
        .miner_address = miner,
        .reward_sat = blockRewardAt(@intCast(idx)),
    };
}

fn makeTestBlock(alloc: std.mem.Allocator, idx: u32, prev_hash: []const u8, miner: []const u8) !Block {
    return makeTestBlockV(alloc, idx, prev_hash, miner, 0);
}

test "Blockchain.reorg — longer chain accepted" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();
    bc.difficulty = 1;

    // Add block 1 to our chain
    const block1 = try makeTestBlock(testing.allocator, 1, "genesis_hash_omnibus_v1", "ob1qfsflcfe5y0hxdk746q87f03kvdr6pyxy324k6w");
    try bc.addExternalBlock(block1);
    try testing.expectEqual(@as(u32, 2), bc.getBlockCount());

    // Build a longer competing chain: genesis + block1' + block2'
    // (same genesis, different blocks after)
    const genesis = bc.getBlock(0).?;

    const alt_block1 = try makeTestBlockV(testing.allocator, 1, genesis.hash, "ob1qgvffvjzwp6hvf6tv4ee65e3vdv0xw3e5qn3092", 'b');

    const alt_block2 = try makeTestBlockV(testing.allocator, 2, alt_block1.hash, "ob1qgvffvjzwp6hvf6tv4ee65e3vdv0xw3e5qn3092", 'b');

    var new_chain: [3]Block = undefined;
    new_chain[0] = genesis;
    new_chain[1] = alt_block1;
    new_chain[2] = alt_block2;

    try bc.reorg(&new_chain);

    // Chain should now be 3 blocks (genesis + alt1 + alt2)
    try testing.expectEqual(@as(u32, 3), bc.getBlockCount());
    // Miner B should be credited (from recalculation)
    try testing.expect(bc.getAddressBalance("ob1qgvffvjzwp6hvf6tv4ee65e3vdv0xw3e5qn3092") > 0);

    // Clean up alt blocks that are now owned by chain (deinit handles them)
    // alt_block1 and alt_block2 transactions are owned by the chain via append
}

test "Blockchain.reorg — shorter chain rejected" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();
    bc.difficulty = 1;

    // Add 2 blocks to our chain
    const block1 = try makeTestBlock(testing.allocator, 1, "genesis_hash_omnibus_v1", "ob1qfsflcfe5y0hxdk746q87f03kvdr6pyxy324k6w");
    try bc.addExternalBlock(block1);

    const block2 = try makeTestBlock(testing.allocator, 2, block1.hash, "ob1qfsflcfe5y0hxdk746q87f03kvdr6pyxy324k6w");
    try bc.addExternalBlock(block2);
    try testing.expectEqual(@as(u32, 3), bc.getBlockCount());

    // Try reorg with a chain of same length (3 blocks) — should be rejected
    const genesis = bc.getBlock(0).?;
    const alt_block1 = try makeTestBlock(testing.allocator, 1, genesis.hash, "ob1qgvffvjzwp6hvf6tv4ee65e3vdv0xw3e5qn3092");
    defer testing.allocator.free(alt_block1.hash);
    defer alt_block1.transactions.deinit();

    const alt_block2 = try makeTestBlock(testing.allocator, 2, alt_block1.hash, "ob1qgvffvjzwp6hvf6tv4ee65e3vdv0xw3e5qn3092");
    defer testing.allocator.free(alt_block2.hash);
    defer alt_block2.transactions.deinit();

    var same_len_chain: [3]Block = undefined;
    same_len_chain[0] = genesis;
    same_len_chain[1] = alt_block1;
    same_len_chain[2] = alt_block2;

    try testing.expectError(error.ShorterChain, bc.reorg(&same_len_chain));

    // Chain should still be 3 blocks (unchanged)
    try testing.expectEqual(@as(u32, 3), bc.getBlockCount());
}

test "Blockchain.reorg — depth > MAX_REORG_DEPTH rejected" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();
    bc.difficulty = 1;

    // Build a chain of MAX_REORG_DEPTH + 2 blocks (genesis + 101 blocks)
    var prev_hash: []const u8 = "genesis_hash_omnibus_v1";
    for (1..MAX_REORG_DEPTH + 2) |i| {
        const blk = try makeTestBlock(testing.allocator, @intCast(i), prev_hash, "ob1qfsflcfe5y0hxdk746q87f03kvdr6pyxy324k6w");
        try bc.addExternalBlock(blk);
        prev_hash = bc.chain.items[bc.chain.items.len - 1].hash;
    }

    // Our chain: genesis + 101 blocks = 102 blocks
    try testing.expectEqual(@as(u32, MAX_REORG_DEPTH + 2), bc.getBlockCount());

    // Build a competing chain that forks from genesis (depth = 101 > MAX_REORG_DEPTH)
    const genesis = bc.getBlock(0).?;

    // New chain needs to be longer: genesis + 102 alt blocks = 103 blocks
    var alt_chain_buf: [MAX_REORG_DEPTH + 3]Block = undefined;
    alt_chain_buf[0] = genesis;

    var alt_prev: []const u8 = genesis.hash;
    for (1..MAX_REORG_DEPTH + 3) |i| {
        const alt_blk = try makeTestBlockV(testing.allocator, @intCast(i), alt_prev, "ob1qgvffvjzwp6hvf6tv4ee65e3vdv0xw3e5qn3092", 'z');
        alt_chain_buf[i] = alt_blk;
        alt_prev = alt_blk.hash;
    }

    const result = bc.reorg(alt_chain_buf[0 .. MAX_REORG_DEPTH + 3]);
    try testing.expectError(error.ReorgTooDeep, result);

    // Chain should be unchanged
    try testing.expectEqual(@as(u32, MAX_REORG_DEPTH + 2), bc.getBlockCount());

    // Clean up alt blocks
    for (1..MAX_REORG_DEPTH + 3) |i| {
        testing.allocator.free(alt_chain_buf[i].hash);
        alt_chain_buf[i].transactions.deinit();
    }
}

test "Blockchain.addExternalBlock — orphan stored when parent unknown" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();
    bc.difficulty = 1;

    // Block whose parent we don't have
    const orphan = try makeTestBlock(testing.allocator, 5, "unknown_parent_hash_that_does_not_exist_in_our_chain_at_all_xxxx", "ob1q3c4mm4mpad5mnzpush3mzt0umdk7sqy7kml67e");

    try bc.addExternalBlock(orphan);

    // Block should be in orphan pool, not in chain
    try testing.expectEqual(@as(u32, 1), bc.getBlockCount()); // still just genesis
    try testing.expectEqual(@as(usize, 1), bc.orphan_blocks.items.len);
}

test "Blockchain.processOrphans — orphan connected when parent arrives" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();
    bc.difficulty = 1;

    // Create block 1 and block 2, but send block 2 first (orphan)
    const block1 = try makeTestBlock(testing.allocator, 1, "genesis_hash_omnibus_v1", "ob1qfsflcfe5y0hxdk746q87f03kvdr6pyxy324k6w");
    const block2 = try makeTestBlock(testing.allocator, 2, block1.hash, "ob1qfsflcfe5y0hxdk746q87f03kvdr6pyxy324k6w");

    // Send block 2 first — parent unknown, goes to orphan pool
    try bc.addExternalBlock(block2);
    try testing.expectEqual(@as(u32, 1), bc.getBlockCount()); // just genesis
    try testing.expectEqual(@as(usize, 1), bc.orphan_blocks.items.len);

    // Now send block 1 — connects to genesis, then orphan block 2 should auto-connect
    try bc.addExternalBlock(block1);

    // Chain should now have 3 blocks: genesis + block1 + block2
    try testing.expectEqual(@as(u32, 3), bc.getBlockCount());
    // Orphan pool should be empty
    try testing.expectEqual(@as(usize, 0), bc.orphan_blocks.items.len);
}

test "Blockchain.findForkPoint — common ancestor found" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();
    bc.difficulty = 1;

    // Add block 1
    const block1 = try makeTestBlock(testing.allocator, 1, "genesis_hash_omnibus_v1", "ob1qfsflcfe5y0hxdk746q87f03kvdr6pyxy324k6w");
    try bc.addExternalBlock(block1);

    // Other chain shares genesis + block1, then diverges
    const genesis = bc.getBlock(0).?;
    var other_chain: [3]Block = undefined;
    other_chain[0] = genesis;
    other_chain[1] = bc.chain.items[1]; // same block1

    const alt_block2 = try makeTestBlock(testing.allocator, 2, bc.chain.items[1].hash, "ob1qgvffvjzwp6hvf6tv4ee65e3vdv0xw3e5qn3092");
    defer testing.allocator.free(alt_block2.hash);
    defer alt_block2.transactions.deinit();
    other_chain[2] = alt_block2;

    const fork = bc.findForkPoint(&other_chain);
    try testing.expect(fork != null);
    try testing.expectEqual(@as(usize, 1), fork.?); // fork at block 1
}

test "Blockchain.findForkPoint — no common ancestor" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();

    // Build a chain with completely different hashes
    const fake_block = Block{
        .index = 0,
        .timestamp = 9999999999,
        .transactions = array_list.Managed(Transaction).init(testing.allocator),
        .previous_hash = "0000000000000000000000000000000000000000000000000000000000000000",
        .nonce = 0,
        .hash = "completely_different_genesis",
    };
    defer fake_block.transactions.deinit();

    var other_chain = [_]Block{fake_block};

    try testing.expect(bc.findForkPoint(&other_chain) == null);
}

test "Blockchain.indexAddressTx — TX appears in both sender and receiver history" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();

    const addr_a = "ob1qyfr7eu6lawmtpc70htrf7cxpenlfxhhm8pu952";
    const addr_b = "ob1q23qfxzsfjdsyj6em4u3egclxfqmzue5etu4h6u";
    const tx_hash = "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890";

    // Simulate indexing a TX for both addresses (like mineBlockForMiner does)
    bc.indexAddressTx(addr_a, tx_hash);
    bc.indexAddressTx(addr_b, tx_hash);

    // Both addresses should have the TX in their history
    const history_a = bc.getAddressHistory(addr_a);
    try testing.expect(history_a != null);
    try testing.expectEqual(@as(usize, 1), history_a.?.len);
    try testing.expectEqualStrings(tx_hash, history_a.?[0]);

    const history_b = bc.getAddressHistory(addr_b);
    try testing.expect(history_b != null);
    try testing.expectEqual(@as(usize, 1), history_b.?.len);
    try testing.expectEqualStrings(tx_hash, history_b.?[0]);
}

test "Blockchain.indexAddressTx — multiple TXs accumulate per address" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();

    const addr = "ob1qn8psc97zfjv0hak3nqyvgz7mjewq0hqyv7mgu7";
    const tx1 = "1111111111111111111111111111111111111111111111111111111111111111";
    const tx2 = "2222222222222222222222222222222222222222222222222222222222222222";
    const tx3 = "3333333333333333333333333333333333333333333333333333333333333333";

    bc.indexAddressTx(addr, tx1);
    bc.indexAddressTx(addr, tx2);
    bc.indexAddressTx(addr, tx3);

    const history = bc.getAddressHistory(addr);
    try testing.expect(history != null);
    try testing.expectEqual(@as(usize, 3), history.?.len);
}

test "Blockchain.getAddressHistory — unknown address returns null" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();

    try testing.expect(bc.getAddressHistory("ob1q80wdpvx6ewepelcnt4pu07jhe300kxtw5hhxyf") == null);
}

test "Blockchain.indexAddressTx — empty address ignored" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();

    bc.indexAddressTx("", "somehash");
    try testing.expect(bc.getAddressHistory("") == null);
}

test "Blockchain.blocks_since_save — increments and resets" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();

    // Initially zero
    try testing.expectEqual(@as(u32, 0), bc.blocks_since_save);

    // Increment
    bc.blocks_since_save += 1;
    try testing.expectEqual(@as(u32, 1), bc.blocks_since_save);

    bc.blocks_since_save += 49;
    try testing.expectEqual(@as(u32, 50), bc.blocks_since_save);

    // Reset
    bc.blocks_since_save = 0;
    try testing.expectEqual(@as(u32, 0), bc.blocks_since_save);
}

test "Blockchain.checkAutoSave — triggers at block threshold" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();

    // No persistent_db attached — checkAutoSave is a no-op (no crash)
    bc.blocks_since_save = 100;
    bc.checkAutoSave();
    // Without a persistent_db, counters still reset on threshold
    try testing.expectEqual(@as(u32, 0), bc.blocks_since_save);
}

test "Blockchain.checkAutoSave — triggers at TX threshold" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();

    bc.txs_since_save = 1000;
    bc.checkAutoSave();
    try testing.expectEqual(@as(u32, 0), bc.txs_since_save);
}

test "Blockchain.checkAutoSave — does not trigger below threshold" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();

    bc.blocks_since_save = 50;
    bc.txs_since_save = 500;
    bc.last_save_time = std.time.timestamp(); // just now
    bc.checkAutoSave();
    // Should NOT have reset — thresholds not met
    try testing.expectEqual(@as(u32, 50), bc.blocks_since_save);
    try testing.expectEqual(@as(u32, 500), bc.txs_since_save);
}

test "Blockchain.saveToDisc — no-op without persistent_db" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();

    // Should not error — just returns silently
    try bc.saveToDisc();
}

// ─── Script Engine Integration Tests ──────────────────────────────────────────

const Secp256k1Crypto = @import("secp256k1.zig").Secp256k1Crypto;
const Ripemd160 = @import("ripemd160.zig").Ripemd160;

test "Blockchain.validateTransaction — legacy TX (no scripts) still validates" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();
    try bc.utxo_set.addUTXO("funding_tx_legacy", 0, "ob1qpuvwpsyt4r0p9c800qhgmnz7n4mjffs36g8r5m", 10_000, 1, "", false);
    const tx = Transaction{
        .id = 1, .from_address = "ob1qpuvwpsyt4r0p9c800qhgmnz7n4mjffs36g8r5m", .to_address = "ob1qa85832ynnv6lmc43mm07qjxk80mswapgz0zc63",
        .amount = 100, .fee = 1, .timestamp = 1700000000, .nonce = 0,
        .signature = "", .hash = "",
        // script_pubkey and script_sig default to "" (legacy mode)
    };
    try testing.expect(try bc.validateTransaction(&tx));
}

test "Blockchain.validateTransaction — TX with valid P2PKH scripts validates" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();
    try bc.utxo_set.addUTXO("funding_tx_p2pkh", 0, "ob1qzkl36jh98nwlqhz2ldspp7enquuh9fvq2s5pna", 10_000, 1, "", false);

    // Generate sender keypair
    const kp = try Secp256k1Crypto.generateKeyPair();

    // Compute receiver pubkey hash (for locking script)
    // Here we lock to the sender's own key for simplicity
    var sha_out: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&kp.public_key, &sha_out, .{});
    var pubkey_hash: [20]u8 = undefined;
    Ripemd160.hash(&sha_out, &pubkey_hash);

    // Create P2PKH lock script
    const lock_script = script_mod.createP2PKH(pubkey_hash);

    // Create TX (unsigned first to get hash)
    var tx = Transaction{
        .id = 1, .from_address = "ob1qzkl36jh98nwlqhz2ldspp7enquuh9fvq2s5pna", .to_address = "ob1qp4zd3f7wuputqdljt0xmu8lah0gkt47usjayzf",
        .amount = 100, .fee = 1, .timestamp = 1700000000, .nonce = 0,
        .signature = "", .hash = "",
        .script_pubkey = &lock_script,
    };

    // Get TX hash and sign it
    const tx_hash = tx.calculateHash();
    const sig = try Secp256k1Crypto.sign(kp.private_key, &tx_hash);

    // Create P2PKH unlock script
    const unlock_script = script_mod.createP2PKHUnlock(sig, kp.public_key);
    tx.script_sig = &unlock_script;

    try testing.expect(try bc.validateTransaction(&tx));
}

test "Blockchain.validateTransaction — TX with invalid scripts rejected" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();
    try bc.utxo_set.addUTXO("funding_tx_invscript", 0, "ob1q8sfgk7l05gngpwm6u8m964j4cmz8arly600chj", 10_000, 1, "", false);

    const kp1 = try Secp256k1Crypto.generateKeyPair();
    const kp2 = try Secp256k1Crypto.generateKeyPair();

    // Lock to kp1's pubkey hash
    var sha_out: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&kp1.public_key, &sha_out, .{});
    var pubkey_hash: [20]u8 = undefined;
    Ripemd160.hash(&sha_out, &pubkey_hash);
    const lock_script = script_mod.createP2PKH(pubkey_hash);

    var tx = Transaction{
        .id = 1, .from_address = "ob1q8sfgk7l05gngpwm6u8m964j4cmz8arly600chj", .to_address = "ob1qtsdal04x4kahc0rzljtkzwqpnq8p3mhn4jrv8f",
        .amount = 100, .fee = 1, .timestamp = 1700000000, .nonce = 0,
        .signature = "", .hash = "",
        .script_pubkey = &lock_script,
    };

    // Sign with kp2 (wrong key) — unlock won't match lock
    const tx_hash = tx.calculateHash();
    const sig = try Secp256k1Crypto.sign(kp2.private_key, &tx_hash);
    const unlock_script = script_mod.createP2PKHUnlock(sig, kp2.public_key);
    tx.script_sig = &unlock_script;

    try testing.expect(!try bc.validateTransaction(&tx));
}

test "Blockchain.validateTransaction — script_pubkey set but script_sig empty rejected" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();
    try bc.utxo_set.addUTXO("funding_tx_nosig", 0, "ob1qguvehlayw4x0v2ku25zw82tfkxsqcjv3l4xtns", 10_000, 1, "", false);

    const kp = try Secp256k1Crypto.generateKeyPair();
    var sha_out: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&kp.public_key, &sha_out, .{});
    var pubkey_hash: [20]u8 = undefined;
    Ripemd160.hash(&sha_out, &pubkey_hash);
    const lock_script = script_mod.createP2PKH(pubkey_hash);

    const tx = Transaction{
        .id = 1, .from_address = "ob1qguvehlayw4x0v2ku25zw82tfkxsqcjv3l4xtns", .to_address = "ob1qvuhxtgd6p0wu6f2vn3g9l9l70uhd02hjxwf938",
        .amount = 100, .fee = 1, .timestamp = 1700000000, .nonce = 0,
        .signature = "", .hash = "",
        .script_pubkey = &lock_script,
        .script_sig = "",  // empty — should be rejected
    };
    try testing.expect(!try bc.validateTransaction(&tx));
}

// ─── Bridge consensus hook tests ─────────────────────────────────────────────

test "Blockchain.isBridgeLockTx — recognizes vault address + OMNIBRIDGE prefix" {
    const cfg_local = @import("chain_config.zig");
    const tx = Transaction{
        .id = 1,
        .from_address = "ob1quser",
        .to_address = cfg_local.BRIDGE_VAULT_ADDR_HEX,
        .amount = 1_000_000,
        .fee = 1,
        .timestamp = 1700000000,
        .nonce = 0,
        .op_return = "OMNIBRIDGE:liberty_testnet:0xabcd",
        .signature = "",
        .hash = "",
    };
    try testing.expect(Blockchain.isBridgeLockTx(&tx));
}

test "Blockchain.isBridgeLockTx — rejects non-vault destination" {
    const tx = Transaction{
        .id = 1,
        .from_address = "ob1quser",
        .to_address = "ob1qsomeotheraddress0000000000000000000000",
        .amount = 1_000_000,
        .fee = 1,
        .timestamp = 1700000000,
        .nonce = 0,
        .op_return = "OMNIBRIDGE:liberty_testnet:0xabcd",
        .signature = "",
        .hash = "",
    };
    try testing.expect(!Blockchain.isBridgeLockTx(&tx));
}

test "Blockchain.isBridgeLockTx — rejects vault dest without OMNIBRIDGE prefix" {
    const cfg_local = @import("chain_config.zig");
    const tx = Transaction{
        .id = 1,
        .from_address = "ob1quser",
        .to_address = cfg_local.BRIDGE_VAULT_ADDR_HEX,
        .amount = 1_000_000,
        .fee = 1,
        .timestamp = 1700000000,
        .nonce = 0,
        .op_return = "regular memo not bridge",
        .signature = "",
        .hash = "",
    };
    try testing.expect(!Blockchain.isBridgeLockTx(&tx));
}


// ─── PHASE B: UTXO Source-of-Truth Tests ────────────────────────────────────

test "applyBlock spends sender UTXOs and creates recipient UTXO" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();

    // Fund address A with a mature non-coinbase UTXO
    try bc.utxo_set.addUTXO("coinbase_a", 0, "ob1qalice", 1_000_000_000, 1, "", false);

    // Build a block with A -> B for 500M
    const tx = Transaction{
        .id = 1,
        .from_address = "ob1qalice",
        .to_address = "ob1qbob",
        .amount = 500_000_000,
        .fee = 1_000,
        .timestamp = 1700000000,
        .nonce = 0,
        .signature = "",
        .hash = "tx_ab_01_hash_________________________________",
    };

    var block = Block{
        .index = 1,
        .timestamp = 1700000001,
        .transactions = array_list.Managed(Transaction).init(testing.allocator),
        .previous_hash = "genesis_hash_omnibus_v1",
        .nonce = 0,
        .hash = "block_01_hash_________________________________",
        .miner_address = "ob1qminer",
        .reward_sat = BLOCK_REWARD_SAT,
    };
    try block.transactions.append(tx);
    // NOTE: applyBlock appends a copy to chain; we must NOT deinit our copy's
    // transactions because chain's copy shares the same underlying allocation.

    bc.mutex.lock();
    defer bc.mutex.unlock();
    try bc.applyBlock(block);

    // UTXO set should have: B's output + A's change + miner's coinbase
    try testing.expectEqual(@as(u64, 3), bc.utxo_set.count);
    try testing.expectEqual(@as(u64, 500_000_000), bc.utxo_set.getBalance("ob1qbob"));
    try testing.expectEqual(@as(u64, 500_000_000 - 1_000), bc.utxo_set.getBalance("ob1qalice")); // change
    try testing.expect(bc.utxo_set.getBalance("ob1qminer") >= BLOCK_REWARD_SAT);

    // getAddressBalance reads from UTXO
    try testing.expectEqual(@as(u64, 500_000_000), bc.getAddressBalance("ob1qbob"));
    try testing.expectEqual(@as(u64, 500_000_000 - 1_000), bc.getAddressBalance("ob1qalice"));
}

test "auditBalanceConsistency returns 0 divergences after normal applyBlock" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();

    // Fund and transfer via applyBlock so both cache and UTXO are updated.
    // Must seed BOTH UTXO and RAM cache before applyBlock so they start aligned.
    try bc.utxo_set.addUTXO("fund_audit", 0, "ob1qaudit", 1_000_000_000, 1, "", false);
    try bc.creditBalance("ob1qaudit", 1_000_000_000);
    const tx = Transaction{
        .id = 1, .from_address = "ob1qaudit", .to_address = "ob1qrecv",
        .amount = 100_000_000, .fee = 1_000, .timestamp = 1700000000, .nonce = 0,
        .signature = "", .hash = "tx_audit_01_____________________________________",
    };
    var block = Block{
        .index = 1, .timestamp = 1700000001,
        .transactions = array_list.Managed(Transaction).init(testing.allocator),
        .previous_hash = "genesis_hash_omnibus_v1", .nonce = 0,
        .hash = "block_audit_01__________________________________",
        .miner_address = "ob1qminer", .reward_sat = BLOCK_REWARD_SAT,
    };
    try block.transactions.append(tx);

    bc.mutex.lock();
    defer bc.mutex.unlock();
    try bc.applyBlock(block);

    const result = bc.auditBalanceConsistency();
    try testing.expectEqual(@as(usize, 0), result.divergences);
}

test "auditBalanceConsistency catches phantom RAM credit" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();

    // Create a phantom RAM credit without UTXO
    try bc.balances.put("ob1qphantom", 999);

    const result = bc.auditBalanceConsistency();
    try testing.expectEqual(@as(usize, 1), result.divergences);
    try testing.expectEqual(@as(usize, 1), result.addresses_checked);
}

test "getMatureBalance excludes immature coinbase" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();

    // Coinbase to A at height 5
    try bc.utxo_set.addUTXO("coinbase_a", 0, "ob1qminerA", 50_000_000_000, 5, "", true);

    // Add dummy blocks to reach height 50 (genesis at 0, need 50 more)
    var h: u32 = 1;
    while (h <= 50) : (h += 1) {
        const b = Block{
            .index = h,
            .timestamp = 1700000000 + @as(i64, h),
            .transactions = array_list.Managed(Transaction).init(testing.allocator),
            .previous_hash = "dummy_prev____________________________________",
            .nonce = 0,
            .hash = "dummy_hash____________________________________",
        };
        try bc.chain.append(b);
    }

    // At height 50, coinbase at height 5 is NOT yet mature (needs 105)
    try testing.expectEqual(@as(u64, 0), bc.getMatureBalance("ob1qminerA"));
    try testing.expectEqual(@as(u64, 50_000_000_000), bc.getAddressBalance("ob1qminerA")); // total includes immature

    // Add 55 more blocks to reach height 105
    while (h <= 105) : (h += 1) {
        const b = Block{
            .index = h,
            .timestamp = 1700000000 + @as(i64, h),
            .transactions = array_list.Managed(Transaction).init(testing.allocator),
            .previous_hash = "dummy_prev____________________________________",
            .nonce = 0,
            .hash = "dummy_hash____________________________________",
        };
        try bc.chain.append(b);
    }

    // At height 105, coinbase at height 5 IS mature (5 + 100 = 105)
    try testing.expectEqual(@as(u64, 50_000_000_000), bc.getMatureBalance("ob1qminerA"));
}


// ─── PHASE C / wire-format v2 tests ─────────────────────────────────────────

test "v2 wire: TX spends listed inputs, leaves untouched UTXOs alone" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();

    // Seed two mature non-coinbase UTXOs to alice; spend only one.
    try bc.utxo_set.addUTXO("seed_a1", 0, "ob1qalicev2", 600_000_000, 1, "", false);
    try bc.utxo_set.addUTXO("seed_a2", 0, "ob1qalicev2", 400_000_000, 1, "", false);

    const inputs = [_]Outpoint{
        .{ .tx_hash = "seed_a1", .output_index = 0 },
    };
    const outputs = [_]TxOutput{
        .{ .amount = 100_000_000, .address = "ob1qbobv2" },
    };
    const tx = Transaction{
        .id = 1,
        .from_address = "ob1qalicev2",
        .to_address = "ob1qbobv2",
        .amount = 100_000_000,
        .fee = 1_000,
        .timestamp = 1700000000,
        .nonce = 0,
        .signature = "",
        .hash = "v2_tx_alice_to_bob______________________________",
        .inputs = &inputs,
        .outputs = &outputs,
    };

    var block = Block{
        .index = 1,
        .timestamp = 1700000001,
        .transactions = array_list.Managed(Transaction).init(testing.allocator),
        .previous_hash = "genesis_hash_omnibus_v1",
        .nonce = 0,
        .hash = "v2_block_01_____________________________________",
        .miner_address = "ob1qminerv2",
        .reward_sat = BLOCK_REWARD_SAT,
    };
    try block.transactions.append(tx);

    bc.mutex.lock();
    defer bc.mutex.unlock();
    try bc.applyBlock(block);

    // bob got 100M; alice change = 600M - 100M - 1000 = 499_999_000;
    // alice still has the untouched seed_a2 (400M) → total alice = 899_999_000.
    try testing.expectEqual(@as(u64, 100_000_000), bc.utxo_set.getBalance("ob1qbobv2"));
    try testing.expectEqual(@as(u64, 400_000_000 + 499_999_000),
        bc.utxo_set.getBalance("ob1qalicev2"));
}

test "v2 wire: TX with explicit outputs[] creates each as a UTXO" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();

    try bc.utxo_set.addUTXO("seed_b", 0, "ob1qsenderv2", 1_000_000_000, 1, "", false);

    const inputs = [_]Outpoint{ .{ .tx_hash = "seed_b", .output_index = 0 } };
    const outputs = [_]TxOutput{
        .{ .amount = 700_000_000, .address = "ob1qrecv1v2" },
        .{ .amount = 200_000_000, .address = "ob1qrecv2v2" },
    };
    const tx = Transaction{
        .id = 1,
        .from_address = "ob1qsenderv2",
        .to_address = "ob1qrecv1v2", // legacy field, ignored when outputs[] present
        .amount = 700_000_000,
        .fee = 1_000,
        .timestamp = 1700000000,
        .nonce = 0,
        .signature = "",
        .hash = "v2_multi_out_tx_________________________________",
        .inputs = &inputs,
        .outputs = &outputs,
    };

    var block = Block{
        .index = 1,
        .timestamp = 1700000001,
        .transactions = array_list.Managed(Transaction).init(testing.allocator),
        .previous_hash = "genesis_hash_omnibus_v1",
        .nonce = 0,
        .hash = "v2_block_multiout_______________________________",
        .miner_address = "ob1qminerv2",
        .reward_sat = BLOCK_REWARD_SAT,
    };
    try block.transactions.append(tx);

    bc.mutex.lock();
    defer bc.mutex.unlock();
    try bc.applyBlock(block);

    try testing.expectEqual(@as(u64, 700_000_000), bc.utxo_set.getBalance("ob1qrecv1v2"));
    try testing.expectEqual(@as(u64, 200_000_000), bc.utxo_set.getBalance("ob1qrecv2v2"));
    // change = 1B - 900M - 1000 = 99_999_000
    try testing.expectEqual(@as(u64, 99_999_000), bc.utxo_set.getBalance("ob1qsenderv2"));
}

test "v2 wire: validateTransaction rejects TX with input owned by other address" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();

    // Seed UTXO owned by victim
    try bc.utxo_set.addUTXO("seed_victim", 0, "ob1qvictimv2", 1_000_000_000, 1, "", false);

    // Attacker tries to spend it
    const inputs = [_]Outpoint{ .{ .tx_hash = "seed_victim", .output_index = 0 } };
    const tx = Transaction{
        .id = 1,
        .from_address = "ob1qattackerv2",
        .to_address = "ob1qattackerv2",
        .amount = 500_000_000,
        .fee = 1_000,
        .timestamp = 1700000000,
        .nonce = 0,
        .signature = "",
        .hash = "v2_steal_attempt________________________________",
        .inputs = &inputs,
    };

    const ok = try bc.validateTransaction(&tx);
    try testing.expect(!ok); // must reject — input not owned by from_address
}

test "v2 wire: validateTransaction rejects TX with non-existent input" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();

    const inputs = [_]Outpoint{
        .{ .tx_hash = "ghost_tx_does_not_exist", .output_index = 0 },
    };
    const tx = Transaction{
        .id = 1,
        .from_address = "ob1qghostv2",
        .to_address = "ob1qrecvghostv2",
        .amount = 1_000,
        .fee = 1_000,
        .timestamp = 1700000000,
        .nonce = 0,
        .signature = "",
        .hash = "v2_ghost_input__________________________________",
        .inputs = &inputs,
    };

    const ok = try bc.validateTransaction(&tx);
    try testing.expect(!ok); // must reject — input not in UTXO set
}

// Helper for fee-settlement tests: free the duped balance keys we inserted
// outside the normal apply_block flow (Blockchain.deinit doesn't own them).
fn freeBalanceKeys(bc: *Blockchain, addrs: []const []const u8) void {
    for (addrs) |a| {
        if (bc.balances.fetchRemove(a)) |kv| {
            bc.allocator.free(kv.key);
        }
    }
}

test "applyExchangeFees: routes network fee to miner accumulator (default)" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();

    const taker = "ob1qtestxtaker0000000000000000000000000000";
    const maker = "ob1qtestxmaker0000000000000000000000000000";
    const treasury = registrar_mod.addressOf(.exchange).?;
    defer freeBalanceKeys(&bc, &.{ taker, maker, treasury });

    bc.in_apply_block = true;
    try bc.creditBalanceLocked(taker, 1_000_000);
    try bc.creditBalanceLocked(maker, 1_000_000);
    bc.in_apply_block = false;

    const treasury_before = bc.balances.get(treasury) orelse 0;
    try testing.expect(bc.consensus_params.route_fees_to_miner); // default ON

    // Charge: taker_fee=2000, maker_fee=1000, network=1000 → split 500/500.
    // Default routing: treasury gets only the exchange fees (3_000), the
    // network 1_000 lands in pending_miner_fees and is settled at the next
    // applyBlock to that block's miner.
    try bc.applyExchangeFees(taker, maker, 2_000, 1_000, 1_000);

    try testing.expectEqual(@as(u64, 1_000_000 - 2_500), bc.balances.get(taker).?);
    try testing.expectEqual(@as(u64, 1_000_000 - 1_500), bc.balances.get(maker).?);
    try testing.expectEqual(treasury_before + 3_000, bc.balances.get(treasury) orelse 0);
    try testing.expectEqual(@as(u64, 1_000), bc.pending_miner_fees);
}

test "applyExchangeFees: legacy treasury routing when flag flipped" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();

    const taker = "ob1qtreasurytaker0000000000000000000000000";
    const maker = "ob1qtreasurymaker0000000000000000000000000";
    const treasury = registrar_mod.addressOf(.exchange).?;
    defer freeBalanceKeys(&bc, &.{ taker, maker, treasury });

    bc.consensus_params.route_fees_to_miner = false; // revert to old behaviour

    bc.in_apply_block = true;
    try bc.creditBalanceLocked(taker, 1_000_000);
    try bc.creditBalanceLocked(maker, 1_000_000);
    bc.in_apply_block = false;

    const treasury_before = bc.balances.get(treasury) orelse 0;

    try bc.applyExchangeFees(taker, maker, 2_000, 1_000, 1_000);

    try testing.expectEqual(@as(u64, 1_000_000 - 2_500), bc.balances.get(taker).?);
    try testing.expectEqual(@as(u64, 1_000_000 - 1_500), bc.balances.get(maker).?);
    // Full taker_fee + maker_fee + network goes to treasury (legacy path).
    try testing.expectEqual(treasury_before + 4_000, bc.balances.get(treasury) orelse 0);
    try testing.expectEqual(@as(u64, 0), bc.pending_miner_fees);
}

test "applyExchangeFees: rejects insufficient balance without partial mutation" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();

    const taker = "ob1qpoor0taker000000000000000000000000000";
    const maker = "ob1qrich0maker000000000000000000000000000";
    const treasury = registrar_mod.addressOf(.exchange).?;
    defer freeBalanceKeys(&bc, &.{ taker, maker, treasury });

    bc.in_apply_block = true;
    try bc.creditBalanceLocked(taker, 100);
    try bc.creditBalanceLocked(maker, 1_000_000);
    bc.in_apply_block = false;

    const treasury_before = bc.balances.get(treasury) orelse 0;

    try testing.expectError(
        error.InsufficientBalance,
        bc.applyExchangeFees(taker, maker, 5_000, 1_000, 1_000),
    );

    try testing.expectEqual(@as(u64, 100), bc.balances.get(taker).?);
    try testing.expectEqual(@as(u64, 1_000_000), bc.balances.get(maker).?);
    try testing.expectEqual(treasury_before, bc.balances.get(treasury) orelse 0);
}

// ─── Governance proposal execution + miner fee routing tests ────────────────

test "executeProposal: set_block_reward updates consensus_params after pass" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();

    // Bootstrap default == BLOCK_REWARD_SAT.
    try testing.expectEqual(@as(u64, BLOCK_REWARD_SAT), bc.consensus_params.block_reward_sat);

    const pp = gov_mod.ParsedPropose{
        .title_hash = "a" ** gov_mod.TITLE_HASH_LEN,
        .voting_blocks = 5,
        .quorum = 100,
        .note = "set reward to 40 OMNI",
    };
    const action = gov_mod.ProposalAction{
        .kind = .set_block_reward,
        .u64_value = 40_000_000_000, // 40 OMNI in SAT
    };
    const id = try bc.gov_registry.proposeWithAction("ob1qproposer", pp, 100, action);
    try bc.gov_registry.vote(id, "ob1qzen", true, "ZEN", 101); // weight 1000
    bc.gov_registry.finalizeProposals(110);

    try bc.executeProposal(id, 110);

    try testing.expectEqual(@as(u64, 40_000_000_000), bc.consensus_params.block_reward_sat);
    const p = bc.gov_registry.getProposal(id).?;
    try testing.expect(p.executed);
    try testing.expectEqual(gov_mod.ProposalStatus.executed, p.status);
}

test "executeProposal: rejects already-executed proposal" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();

    const pp = gov_mod.ParsedPropose{
        .title_hash = "b" ** gov_mod.TITLE_HASH_LEN,
        .voting_blocks = 5,
        .quorum = 50,
        .note = "",
    };
    const action = gov_mod.ProposalAction{
        .kind = .set_min_difficulty,
        .u64_value = 8,
    };
    const id = try bc.gov_registry.proposeWithAction("ob1qprop", pp, 100, action);
    try bc.gov_registry.vote(id, "ob1qzen", true, "ZEN", 101);
    bc.gov_registry.finalizeProposals(110);

    try bc.executeProposal(id, 110);
    try testing.expectEqual(@as(u32, 8), bc.consensus_params.min_difficulty);

    // Second call must reject — proposal is now .executed, not .passed.
    try testing.expectError(error.ProposalNotPassed, bc.executeProposal(id, 111));
}

test "executeProposal: rejects proposal that did not pass" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();

    const pp = gov_mod.ParsedPropose{
        .title_hash = "c" ** gov_mod.TITLE_HASH_LEN,
        .voting_blocks = 5,
        .quorum = 50,
        .note = "",
    };
    const action = gov_mod.ProposalAction{
        .kind = .set_block_size_limit,
        .u64_value = 2_097_152,
    };
    const id = try bc.gov_registry.proposeWithAction("ob1qprop", pp, 100, action);
    // Vote NO so the proposal is rejected at finalize.
    try bc.gov_registry.vote(id, "ob1qzen", false, "ZEN", 101);
    bc.gov_registry.finalizeProposals(110);

    try testing.expectError(error.ProposalNotPassed, bc.executeProposal(id, 110));
    try testing.expectEqual(@as(u64, 1_048_576), bc.consensus_params.block_size_limit); // unchanged
}

test "applyBlock auto-executes a passed proposal at the next block" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();

    const pp = gov_mod.ParsedPropose{
        .title_hash = "d" ** gov_mod.TITLE_HASH_LEN,
        .voting_blocks = 1,
        .quorum = 50,
        .note = "",
    };
    const action = gov_mod.ProposalAction{
        .kind = .set_validator_quorum_min,
        .u64_value = 5,
    };
    // Voting opens at create_block; ends at create_block + 1.
    const id = try bc.gov_registry.proposeWithAction("ob1qprop", pp, 0, action);
    try bc.gov_registry.vote(id, "ob1qzen", true, "ZEN", 1); // weight 1000

    // Mine a block at index >= voting_end_block (1) so finalize+autoExec kick.
    const block = Block{
        .index = 5,
        .timestamp = 1700000000,
        .transactions = array_list.Managed(Transaction).init(testing.allocator),
        .previous_hash = "genesis_hash_omnibus_v1",
        .nonce = 0,
        .hash = "block_gov_autoexec______________________________",
        .miner_address = "ob1qminergov",
        .reward_sat = BLOCK_REWARD_SAT,
    };

    bc.mutex.lock();
    defer bc.mutex.unlock();
    try bc.applyBlock(block);

    try testing.expectEqual(@as(u32, 5), bc.consensus_params.validator_quorum_min);
    const p = bc.gov_registry.getProposal(id).?;
    try testing.expectEqual(gov_mod.ProposalStatus.executed, p.status);
    try testing.expectEqual(@as(u64, 5), p.executed_block);
}

test "applyBlock credits accumulated exchange fees to miner alongside reward" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();

    // Simulate a fill that landed mid-block: pending_miner_fees has 7_500 sat.
    bc.pending_miner_fees = 7_500;
    try testing.expect(bc.consensus_params.route_fees_to_miner);

    const block = Block{
        .index = 1,
        .timestamp = 1700000000,
        .transactions = array_list.Managed(Transaction).init(testing.allocator),
        .previous_hash = "genesis_hash_omnibus_v1",
        .nonce = 0,
        .hash = "block_fees_to_miner____________________________1",
        .miner_address = "ob1qminerfees",
        .reward_sat = BLOCK_REWARD_SAT,
    };

    bc.mutex.lock();
    defer bc.mutex.unlock();
    try bc.applyBlock(block);

    // Miner receives reward + accumulator. No TX-level fees in this block.
    const miner_bal = bc.utxo_set.getBalance("ob1qminerfees");
    try testing.expectEqual(BLOCK_REWARD_SAT + 7_500, miner_bal);
    // Accumulator drained.
    try testing.expectEqual(@as(u64, 0), bc.pending_miner_fees);
    // Cumulative tracker incremented.
    try testing.expectEqual(@as(u64, 7_500), bc.total_miner_exchange_fees);
}

test "applyBlock: per-TX fees + N*F miner credit (block_reward + N*fee)" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();

    // Two senders, each pre-funded; each pays a fee F=10_000.
    try bc.utxo_set.addUTXO("seed_a_fees", 0, "ob1qfeealice", 1_000_000_000, 1, "", false);
    try bc.utxo_set.addUTXO("seed_b_fees", 0, "ob1qfeebob",   1_000_000_000, 1, "", false);

    const F: u64 = 10_000;
    const tx_a = Transaction{
        .id = 1, .from_address = "ob1qfeealice", .to_address = "ob1qfeerecv1",
        .amount = 100_000, .fee = F, .timestamp = 1700000000, .nonce = 0,
        .signature = "", .hash = "tx_fee_a_______________________________________a",
    };
    const tx_b = Transaction{
        .id = 2, .from_address = "ob1qfeebob", .to_address = "ob1qfeerecv2",
        .amount = 100_000, .fee = F, .timestamp = 1700000000, .nonce = 0,
        .signature = "", .hash = "tx_fee_b_______________________________________b",
    };

    var block = Block{
        .index = 1, .timestamp = 1700000001,
        .transactions = array_list.Managed(Transaction).init(testing.allocator),
        .previous_hash = "genesis_hash_omnibus_v1", .nonce = 0,
        .hash = "block_NF_to_miner______________________________1",
        .miner_address = "ob1qminerNF", .reward_sat = BLOCK_REWARD_SAT,
    };
    try block.transactions.append(tx_a);
    try block.transactions.append(tx_b);

    bc.mutex.lock();
    defer bc.mutex.unlock();
    try bc.applyBlock(block);

    // Total fees = 2*F = 20_000; FEE_BURN_PCT=50 → 10_000 burned, 10_000 to miner.
    const total_fees = 2 * F;
    const fees_burned = total_fees * FEE_BURN_PCT / 100;
    const fees_to_miner = total_fees - fees_burned;
    const expected = BLOCK_REWARD_SAT + fees_to_miner;

    try testing.expectEqual(expected, bc.utxo_set.getBalance("ob1qminerNF"));
}

// ─── PHASE 2F.2 — HTLC end-to-end test ──────────────────────────────────────

test "HTLC roundtrip: A locks → B claims with preimage → balances flip" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();

    const alice = "ob1qalice00000000000000000000000000000000";
    const bob   = "ob1qbob000000000000000000000000000000000";

    // Seed Alice's balance.
    bc.in_apply_block = true;
    try bc.creditBalanceLocked(alice, 1_000_000);
    bc.in_apply_block = false;

    // Generate preimage / hash.
    const pair = htlc_mod.HTLC.generatePreimage();

    // ── Block 1: Alice's htlc_init locks 500_000 ──────────────────────────
    var init_payload_buf: [tx_payload_mod.HtlcInitPayload.WIRE_SIZE]u8 = undefined;
    const init_p = tx_payload_mod.HtlcInitPayload{
        .hash_lock = pair.hash,
        .timelock_block = 100,
        .amount_sat = 500_000,
    };
    _ = try init_p.encode(&init_payload_buf);

    const init_tx_hash = "htlc_init_tx_hash_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const init_tx = Transaction{
        .id = 1,
        .from_address = alice,
        .to_address = bob,
        .amount = 0,
        .fee = 0,
        .timestamp = 1700000000,
        .nonce = 0,
        .signature = "",
        .hash = init_tx_hash,
        .tx_type = .htlc_init,
        .data = &init_payload_buf,
    };

    var b1 = Block{
        .index = 1,
        .timestamp = 1700000001,
        .transactions = array_list.Managed(Transaction).init(testing.allocator),
        .previous_hash = "genesis_hash_omnibus_v1",
        .nonce = 0,
        .hash = "htlc_block_1_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    };
    try b1.transactions.append(init_tx);

    bc.mutex.lock();
    try bc.applyBlock(b1);
    bc.mutex.unlock();

    // Alice should have lost 500_000; HTLC registry has 1 active entry.
    try testing.expectEqual(@as(u64, 500_000), bc.balances.get(alice).?);
    try testing.expectEqual(@as(u32, 1), bc.htlc_registry.entry_count);
    try testing.expectEqual(@as(u32, 1), bc.htlc_registry.activeCount());

    // ── Block 2: Bob's htlc_claim with the preimage ───────────────────────
    var claim_payload_buf: [tx_payload_mod.HtlcClaimPayload.WIRE_SIZE]u8 = undefined;
    const claim_p = tx_payload_mod.HtlcClaimPayload{
        .htlc_id = htlc_mod.computeHtlcId(init_tx_hash),
        .preimage = pair.preimage,
    };
    _ = try claim_p.encode(&claim_payload_buf);

    const claim_tx = Transaction{
        .id = 2,
        .from_address = bob,
        .to_address = alice, // not used by claim logic but required for address validation
        .amount = 0,
        .fee = 0,
        .timestamp = 1700000002,
        .nonce = 0,
        .signature = "",
        .hash = "htlc_claim_tx_hash_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        .tx_type = .htlc_claim,
        .data = &claim_payload_buf,
    };

    var b2 = Block{
        .index = 2,
        .timestamp = 1700000003,
        .transactions = array_list.Managed(Transaction).init(testing.allocator),
        .previous_hash = "htlc_block_1_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .nonce = 0,
        .hash = "htlc_block_2_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    };
    try b2.transactions.append(claim_tx);

    bc.mutex.lock();
    try bc.applyBlock(b2);
    bc.mutex.unlock();

    // Bob received the 500_000; Alice still at 500_000 (already debited).
    try testing.expectEqual(@as(u64, 500_000), bc.balances.get(bob).?);
    try testing.expectEqual(@as(u64, 500_000), bc.balances.get(alice).?);
    try testing.expectEqual(@as(u32, 0), bc.htlc_registry.activeCount());
    const final = bc.htlc_registry.get(claim_p.htlc_id).?;
    try testing.expectEqual(htlc_mod.HTLCState.claimed, final.state);
    try testing.expect(final.has_preimage);
}
