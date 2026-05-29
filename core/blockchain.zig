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

// Consensus parameters + standalone helpers + POD types live in a leaf
// module so they can be imported without pulling in the Blockchain struct.
// All names below are re-exported for backwards compatibility — existing
// call sites (`blockchain_mod.BLOCK_REWARD_SAT`, `.blockRewardAt(...)`,
// `.ConsensusParams`, etc.) keep working unchanged.
const consensus_params = @import("blockchain/consensus_params.zig");

pub const BLOCK_REWARD_SAT     = consensus_params.BLOCK_REWARD_SAT;
pub const HALVING_INTERVAL     = consensus_params.HALVING_INTERVAL;
pub const MAX_SUPPLY_SAT       = consensus_params.MAX_SUPPLY_SAT;
pub const COINBASE_MATURITY    = consensus_params.COINBASE_MATURITY;
pub const DUST_THRESHOLD_SAT   = consensus_params.DUST_THRESHOLD_SAT;
pub const MAX_REORG_DEPTH      = consensus_params.MAX_REORG_DEPTH;
pub const MAX_ORPHAN_POOL      = consensus_params.MAX_ORPHAN_POOL;
pub const RETARGET_INTERVAL    = consensus_params.RETARGET_INTERVAL;
pub const TARGET_BLOCK_TIME_S  = consensus_params.TARGET_BLOCK_TIME_S;
pub const TARGET_INTERVAL_S    = consensus_params.TARGET_INTERVAL_S;
pub const MIN_DIFFICULTY       = consensus_params.MIN_DIFFICULTY;
pub const MAX_DIFFICULTY       = consensus_params.MAX_DIFFICULTY;
pub const FEE_BURN_PCT         = consensus_params.FEE_BURN_PCT;
pub const TX_MIN_FEE           = consensus_params.TX_MIN_FEE;

pub const blockWork          = consensus_params.blockWork;
pub const retargetDifficulty = consensus_params.retargetDifficulty;
pub const blockRewardAt      = consensus_params.blockRewardAt;

pub const MultisigConfigEntry = consensus_params.MultisigConfigEntry;
pub const ConsensusParams     = consensus_params.ConsensusParams;
pub const PqIdentity          = consensus_params.PqIdentity;
pub const StakeMeta           = consensus_params.StakeMeta;

/// Total fees burned (tracked for supply accounting). Stays here because
/// it's mutable global state mutated by Blockchain methods below.
pub var total_fees_burned_sat: u64 = 0;

/// `BlockPriceEntry` was moved to `oracle_types.zig` to allow `block.zig`
/// to embed it directly without a circular import. It is re-exported above
/// as `blockchain_mod.BlockPriceEntry` so callers don't need to change.

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

        // Create genesis block. The hash here is a placeholder for tests that
        // call Blockchain.init() directly; production paths go through
        // genesis.zig:buildBlockchain which immediately overwrites chain[0]
        // with the chain-specific canonical genesis from ChainConfig.
        const genesis = Block{
            .index = 0,
            .timestamp = 1743000000,
            .transactions = array_list.Managed(Transaction).init(allocator),
            .previous_hash = "0000000000000000000000000000000000000000000000000000000000000000",
            .nonce = 0,
            .hash = "82ec46e83af37b1ea0e6b3fe66a8f04795a8e8aae7db414d451eff1154245982",
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
        return @import("blockchain/accessors.zig").recordBlockPrices(self, height, entries);
    }

    /// Return the 6 price entries snapshot for a block, or null if not recorded
    /// (e.g. block was mined before WS feed came online, or after node restart).
    pub fn getBlockPrices(self: *const Blockchain, height: u32) ?[6]BlockPriceEntry {
        return @import("blockchain/accessors.zig").getBlockPrices(self, height);
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
        return @import("blockchain/balances.zig").getAddressBalance(self, address);
    }

    /// Returns the OMNI amount this address has locked in resting SELL orders
    /// on the native DEX. Funds remain in the wallet (UTXO) but are "soft
    /// escrowed" — validateTransaction subtracts this from spendable balance
    /// so the user cannot double-spend OMNI that's already promised to a fill.
    ///
    /// Mirrors `computeReservedFromOrderbook` in rpc_server.zig but lives on
    /// Blockchain so the validation path (which has no rpc context) can use it.
    pub fn getReservedFromOrders(self: *const Blockchain, address: []const u8) u64 {
        return @import("blockchain/accessors.zig").getReservedFromOrders(self, address);
    }

    /// Returneaza balanta matura (doar UTXO-uri cu >=100 confirmari).
    /// Coinbase-urile necesita 100 blocuri inainte de a fi cheltuibile.
    pub fn getMatureBalance(self: *const Blockchain, address: []const u8) u64 {
        return @import("blockchain/balances.zig").getMatureBalance(self, address);
    }

    /// Audit: compara RAM cache (bc.balances) cu UTXO set.
    /// In debug builds fail-fast pe divergente; in release doar log.
    pub fn auditBalanceConsistency(self: *const Blockchain) @import("blockchain/balances.zig").AuditResult {
        return @import("blockchain/balances.zig").auditBalanceConsistency(self);
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
        return @import("blockchain/governance.zig").rebuildValidatorSetFromChain(self);
    }

    pub fn getConfirmations(self: *const Blockchain, tx_hash: []const u8) ?u64 {
        return @import("blockchain/address_index.zig").getConfirmations(self, tx_hash);
    }

    pub fn getTxBlockHeight(self: *const Blockchain, tx_hash: []const u8) ?u64 {
        return @import("blockchain/address_index.zig").getTxBlockHeight(self, tx_hash);
    }

    pub fn indexAddressTx(self: *Blockchain, address: []const u8, tx_hash: []const u8) void {
        return @import("blockchain/address_index.zig").indexAddressTx(self, address, tx_hash);
    }

    pub fn getAddressHistory(self: *const Blockchain, address: []const u8) ?[]const []const u8 {
        return @import("blockchain/address_index.zig").getAddressHistory(self, address);
    }

    pub fn getAddressHistoryLocked(
        self: *Blockchain,
        allocator: std.mem.Allocator,
        address: []const u8,
    ) !?[][]const u8 {
        return @import("blockchain/address_index.zig").getAddressHistoryLocked(self, allocator, address);
    }

    /// Adauga reward la balanta minerului.
    /// Lock-uit pentru a preveni race-ul cu RPC threads care citesc balances
    /// (HashMap-ul Zig nu e thread-safe; concurrent get/put produce segfault).
    pub fn creditBalance(self: *Blockchain, address: []const u8, amount: u64) !void {
        return @import("blockchain/balances.zig").creditBalance(self, address, amount);
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
        return @import("blockchain/balances.zig").creditBalanceLocked(self, address, amount);
    }

    /// Scade din balanta (pentru tranzactii)
    pub fn debitBalance(self: *Blockchain, address: []const u8, amount: u64) !void {
        return @import("blockchain/balances.zig").debitBalance(self, address, amount);
    }

    /// Internal — caller must already hold self.mutex.
    /// Same dupe-first pattern as creditBalanceLocked to avoid dangling
    /// HashMap key pointers when caller passes a transient slice.
    pub fn debitBalanceLocked(self: *Blockchain, address: []const u8, amount: u64) !void {
        return @import("blockchain/balances.zig").debitBalanceLocked(self, address, amount);
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
    /// Settle the base-asset leg of an OMNI-base fill: spend a UTXO from
    /// seller and create one for buyer (+ change to seller if leftover).
    /// Source of truth in this chain is the UTXO set, so updating the
    /// in-RAM `balances` cache is not enough — getAddressBalance reads
    /// UTXO directly.
    ///
    /// We synthesize a virtual "fill" tx hash unique per fill so the
    /// outpoint key doesn't collide with real transactions.
    pub fn applyFillTransferOmniBase(
        self: *Blockchain,
        buyer_addr: []const u8,
        seller_addr: []const u8,
        amount_sat: u64,
        fill_id: u64,
    ) !void {
        return @import("blockchain/balances.zig").applyFillTransferOmniBase(self, buyer_addr, seller_addr, amount_sat, fill_id);
    }

    pub fn applyExchangeFees(
        self: *Blockchain,
        taker_addr: []const u8,
        maker_addr: []const u8,
        taker_fee: u64,
        maker_fee: u64,
        network_fee_sat: u64,
    ) !void {
        return @import("blockchain/balances.zig").applyExchangeFees(self, taker_addr, maker_addr, taker_fee, maker_fee, network_fee_sat);
    }

    pub fn registerPubkey(self: *Blockchain, address: []const u8, pubkey_hex: []const u8) !void {
        return @import("blockchain/pubkey_registry.zig").registerPubkey(self, address, pubkey_hex);
    }

    pub fn registerMultisig(self: *Blockchain, address: []const u8, config: multisig_mod.MultisigConfig) !void {
        return @import("blockchain/pubkey_registry.zig").registerMultisig(self, address, config);
    }

    pub fn getMultisigConfig(self: *const Blockchain, address: []const u8) ?*const multisig_mod.MultisigConfig {
        return @import("blockchain/pubkey_registry.zig").getMultisigConfig(self, address);
    }

    pub fn addTransaction(self: *Blockchain, tx: Transaction) !void {
        return @import("blockchain/mempool_helpers.zig").addTransaction(self, tx);
    }

    /// Returneaza totalul outgoing pending din mempool pentru o adresa (amount + fee per TX)
    /// Folosit in validateTransaction() pentru a preveni double-spend cu TX-uri rapide
    pub fn getPendingOutgoing(self: *const Blockchain, address: []const u8) u64 {
        return @import("blockchain/balances.zig").getPendingOutgoing(self, address);
    }

    /// Returneaza urmatorul nonce confirmat pentru o adresa (0 daca nu exista)
    /// Acesta este nonce-ul pe chain — NU include TX-urile pending din mempool
    pub fn getNextNonce(self: *const Blockchain, address: []const u8) u64 {
        return @import("blockchain/balances.zig").getNextNonce(self, address);
    }

    /// Returneaza urmatorul nonce disponibil pentru o adresa,
    /// incluzand TX-urile pending din mempool (chain_nonce + pending_count).
    /// Aceasta metoda este utila pentru RPC "getnonce" — clientul stie ce nonce sa puna pe urmatoarea TX.
    pub fn getNextAvailableNonce(self: *const Blockchain, address: []const u8) u64 {
        return @import("blockchain/balances.zig").getNextAvailableNonce(self, address);
    }

    pub fn validateTransaction(self: *Blockchain, tx: *const Transaction) !bool {
        return @import("blockchain/validation.zig").validateTransaction(self, tx);
    }

    pub fn mineBlock(self: *Blockchain) !Block {
        return @import("blockchain/mining.zig").mineBlock(self);
    }

    /// Mine block + acorda reward minerului + proceseaza TX-urile din mempool
    pub fn mineBlockForMiner(self: *Blockchain, miner_address: []const u8) !Block {
        return @import("blockchain/mining.zig").mineBlockForMiner(self, miner_address);
    }

    /// Calculate block hash as 64-char hex string (shared implementation in hex_utils)
    pub fn calculateBlockHash(self: *Blockchain, block: *const Block) ![]const u8 {
        return @import("blockchain/validation.zig").calculateBlockHash(self, block);
    }

    /// Check if hash meets difficulty (delegates to shared hex_utils)
    pub fn isValidHash(self: *Blockchain, hash: []const u8) !bool {
        return @import("blockchain/validation.zig").isValidHash(self, hash);
    }

    /// Maximum allowed clock drift for block timestamps (2 hours, like Bitcoin)
    const MAX_FUTURE_SECONDS: i64 = 7200;

    /// Validate a block against all consensus rules (Bitcoin-level validation).
    /// Returns true if the block passes all checks, false otherwise.
    /// Checks: merkle root, timestamp, previous hash, difficulty, fees/reward, TX validity.
    pub fn validateBlock(self: *Blockchain, block: *const Block) bool {
        return @import("blockchain/validation.zig").validateBlock(self, block);
    }

    // ─── Bridge consensus hooks ──────────────────────────────────────────────

    /// Returns true if `tx` is a bridge lock: destination = vault address
    /// (case-insensitive 0x... 40-hex compare) AND op_return starts with
    /// "OMNIBRIDGE:". Cheap inline check called on every TX during block
    /// validation, so kept simple.
    pub fn isBridgeLockTx(tx: *const Transaction) bool {
        return @import("blockchain/validation.zig").isBridgeLockTx(tx);
    }

    /// Sum lock amounts in `block` and verify per-tx + rolling-day caps.
    /// Caller MUST hold mutex (or be in single-threaded context).
    fn validateBridgeLimits(self: *Blockchain, block: *const Block) bool {
        return @import("blockchain/validation.zig").validateBridgeLimits(self, block);
    }

    /// Accept a block from a P2P peer. Fully validates before appending.
    /// Handles three cases:
    ///   1. Block extends our chain tip -> append normally
    ///   2. Block forks from our chain and creates a longer chain -> reorg
    ///   3. Block's parent is unknown -> store in orphan pool
    /// After appending, checks if any orphan blocks now connect.
    pub fn addExternalBlock(self: *Blockchain, block: Block) !void {
        return @import("blockchain/reorg.zig").addExternalBlock(self, block);
    }

    /// Accept a full chain from a peer and reorg if it's longer.
    /// Validates all blocks in the new chain from the fork point.
    /// Returns orphaned TXs to mempool for re-mining.
    pub fn reorg(self: *Blockchain, new_chain: []const Block) !void {
        return @import("blockchain/reorg.zig").reorg(self, new_chain);
    }

    /// Auto-save disabled. The blockchain IS the database — balances,
    /// nonces, and pubkey registry are deterministically reconstructed
    /// by replaying the chain on startup. Restart resyncs from peers,
    /// which on a real mesh is faster than re-reading a multi-GB .dat
    /// file. Save now happens only on graceful shutdown (signal handler).
    /// Delegates to blockchain/persistence.zig.
    pub fn checkAutoSave(self: *Blockchain) void {
        return @import("blockchain/persistence.zig").checkAutoSave(self);
    }

    /// Delegates to blockchain/persistence.zig.
    pub fn saveToDisc(self: *Blockchain) !void {
        return @import("blockchain/persistence.zig").saveToDisc(self);
    }

    /// Find the highest block index where both chains have the same hash.
    /// Returns null if no common ancestor found (completely divergent chains).
    pub fn findForkPoint(self: *const Blockchain, other_chain: []const Block) ?usize {
        return @import("blockchain/reorg.zig").findForkPoint(self, other_chain);
    }

    /// Internal fork point finder (no mutex, called from methods that already hold it).
    fn findForkPointInternal(self: *const Blockchain, other_chain: []const Block) ?usize {
        return @import("blockchain/reorg.zig").findForkPointInternal(self, other_chain);
    }

    /// Find a block in our chain by its hash. Returns the index or null.
    fn findBlockByHash(self: *const Blockchain, hash: []const u8) ?usize {
        return @import("blockchain/reorg.zig").findBlockByHash(self, hash);
    }

    /// Validate a block as if it were at a specific height (used during reorg).
    fn validateBlockAtHeight(self: *Blockchain, block: *const Block, height: usize) bool {
        return @import("blockchain/validation.zig").validateBlockAtHeight(self, block, height);
    }

    /// Apply a validated block to the chain: process TXs, credit miner, append.
    /// Caller must hold mutex.
    /// Update cumulative stake & agent-registration maps from a single TX's
    /// `op_return` payload. Called from applyBlock / mineBlockForMiner /
    /// recalculateFromHeight so the derived state stays in sync regardless
    /// of which path produced the block. Keys are duped (HashMap-owned)
    /// because the TX slice may be transient (mempool buffer, replay loop).
    pub fn applyOpReturnRoles(self: *Blockchain, tx: Transaction) void {
        return @import("blockchain/op_returns.zig").applyOpReturnRoles(self, tx);
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
        return @import("blockchain/governance.zig").executeProposal(self, proposal_id, current_block);
    }

    /// Auto-execute every passed-but-unexecuted proposal at the current block
    /// height. Called from applyBlock once per block. Safe under self.mutex
    /// because executeProposal only mutates consensus_params + the gov registry
    /// (both already serialised by applyBlock's caller).
    fn autoExecutePassedProposals(self: *Blockchain, current_block: u64) void {
        @import("blockchain/governance.zig").autoExecutePassedProposals(self, current_block);
    }

    fn applyBlock(self: *Blockchain, block: Block) !void {
        return @import("blockchain/apply.zig").applyBlock(self, block);
    }

    /// Collect transactions from blocks being removed during reorg and return them to mempool.
    fn collectOrphanedTxs(self: *Blockchain, from_height: usize) !void {
        return @import("blockchain/mempool_helpers.zig").collectOrphanedTxs(self, from_height);
    }

    /// Remove mempool TXs that already exist in the current chain.
    fn removeMempoolDuplicates(self: *Blockchain) void {
        return @import("blockchain/mempool_helpers.zig").removeMempoolDuplicates(self);
    }

    /// Recalculate balances, nonces, and tx_block_height by replaying all blocks from genesis.
    /// Made `pub` so p2p.zig can call after a truncate (reorg) to keep state coherent
    /// — without this, the balances HashMap retains entries for now-discarded blocks
    /// whose dupe()'d address keys may have been freed → segfault on next getOrPut.
    pub fn recalculateFromHeight(self: *Blockchain, from_height: usize) !void {
        return @import("blockchain/mempool_helpers.zig").recalculateFromHeight(self, from_height);
    }

    /// Process orphan blocks: check if any now connect to our chain tip.
    /// Keeps trying until no more orphans connect (cascading resolution).
    pub fn processOrphans(self: *Blockchain) void {
        return @import("blockchain/mempool_helpers.zig").processOrphans(self);
    }

    /// Internal processOrphans (no mutex, called from methods that already hold it).
    fn processOrphansInternal(self: *Blockchain) void {
        return @import("blockchain/mempool_helpers.zig").processOrphansInternal(self);
    }

    pub fn getBlock(self: *Blockchain, index: u32) ?Block {
        return @import("blockchain/accessors.zig").getBlock(self, index);
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
        return @import("blockchain/accessors.zig").getLatestBlock(self, alloc);
    }

    /// Free a Block returned by `getLatestBlock`. Frees every heap-borrowed
    /// slice, the cloned TX list, and the optional fills buffer.
    pub fn freeClonedBlock(alloc: std.mem.Allocator, block: *Block) void {
        return @import("blockchain/accessors.zig").freeClonedBlock(alloc, block);
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
        return @import("blockchain/accessors.zig").getBlockCount(self);
    }

    /// Lock-free variant of getBlockCount for callers that already hold
    /// self.mutex (non-reentrant std.Thread.Mutex panics on double-lock)
    /// or for read-only contexts where an off-by-one stale value is fine.
    /// Use this in RPC handlers that took the chain mutex earlier in the
    /// same function.
    pub fn getBlockCountUnlocked(self: *const Blockchain) u32 {
        return @import("blockchain/accessors.zig").getBlockCountUnlocked(self);
    }

    /// Self-contained snapshot of the latest block — no slice-into-chain pointers,
    /// safe to use after releasing bc.mutex. Eliminates UAF in RPC handlers that
    /// previously held a Block-by-value while the chain reallocated underneath.
    /// SEGFAULT-FIX [scan-2026-04-25]: callers no longer need to keep bc.mutex
    /// locked across allocPrint — they get a stable copy and unlock immediately.
    pub fn getLatestBlockSnapshot(self: *Blockchain) BlockSnapshot {
        return @import("blockchain/accessors.zig").getLatestBlockSnapshot(self);
    }

    // HTLC TX dispatcher — extracted to blockchain/htlc_tx.zig
    fn applyHtlcTx(self: *Blockchain, tx: Transaction, block_height: u32) !void {
        return @import("blockchain/htlc_tx.zig").applyHtlcTx(self, tx, block_height);
    }

    // Intent TX dispatcher — extracted to blockchain/intent_tx.zig
    fn applyIntentTx(self: *Blockchain, tx: Transaction, block_height: u32) !void {
        return @import("blockchain/intent_tx.zig").applyIntentTx(self, tx, block_height);
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
        return @import("blockchain/apply.zig").applyOrderTxs(self, block);
    }
};

// ── PQ identity persistence ─────────────────────────────────────────────────
// Implementation lives in blockchain/persistence.zig. Re-exported here so
// external callers (main.zig, etc.) continue to use blockchain_mod.<name>.

const persistence_mod = @import("blockchain/persistence.zig");

pub const pqPersistSetPath         = persistence_mod.pqPersistSetPath;
pub const persistPqIdentityAppend  = persistence_mod.persistPqIdentityAppend;
pub const loadPqIdentitiesFromDisk = persistence_mod.loadPqIdentitiesFromDisk;
pub const extractJsonStr           = persistence_mod.extractJsonStr;
pub const extractJsonU64           = persistence_mod.extractJsonU64;
pub const copyToFixed              = persistence_mod.copyToFixed;

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
        .previous_hash = "82ec46e83af37b1ea0e6b3fe66a8f04795a8e8aae7db414d451eff1154245982",
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
        .previous_hash = "82ec46e83af37b1ea0e6b3fe66a8f04795a8e8aae7db414d451eff1154245982",
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
        .previous_hash = "82ec46e83af37b1ea0e6b3fe66a8f04795a8e8aae7db414d451eff1154245982",
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
        .previous_hash = "82ec46e83af37b1ea0e6b3fe66a8f04795a8e8aae7db414d451eff1154245982",
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
        .previous_hash = "82ec46e83af37b1ea0e6b3fe66a8f04795a8e8aae7db414d451eff1154245982",
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
        .previous_hash = "82ec46e83af37b1ea0e6b3fe66a8f04795a8e8aae7db414d451eff1154245982",
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
        .previous_hash = "82ec46e83af37b1ea0e6b3fe66a8f04795a8e8aae7db414d451eff1154245982",
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
    const block1 = try makeTestBlock(testing.allocator, 1, "82ec46e83af37b1ea0e6b3fe66a8f04795a8e8aae7db414d451eff1154245982", "ob1qfsflcfe5y0hxdk746q87f03kvdr6pyxy324k6w");
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
    const block1 = try makeTestBlock(testing.allocator, 1, "82ec46e83af37b1ea0e6b3fe66a8f04795a8e8aae7db414d451eff1154245982", "ob1qfsflcfe5y0hxdk746q87f03kvdr6pyxy324k6w");
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
    var prev_hash: []const u8 = "82ec46e83af37b1ea0e6b3fe66a8f04795a8e8aae7db414d451eff1154245982";
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
    const block1 = try makeTestBlock(testing.allocator, 1, "82ec46e83af37b1ea0e6b3fe66a8f04795a8e8aae7db414d451eff1154245982", "ob1qfsflcfe5y0hxdk746q87f03kvdr6pyxy324k6w");
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
    const block1 = try makeTestBlock(testing.allocator, 1, "82ec46e83af37b1ea0e6b3fe66a8f04795a8e8aae7db414d451eff1154245982", "ob1qfsflcfe5y0hxdk746q87f03kvdr6pyxy324k6w");
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
        .previous_hash = "82ec46e83af37b1ea0e6b3fe66a8f04795a8e8aae7db414d451eff1154245982",
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
        .previous_hash = "82ec46e83af37b1ea0e6b3fe66a8f04795a8e8aae7db414d451eff1154245982", .nonce = 0,
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
        .previous_hash = "82ec46e83af37b1ea0e6b3fe66a8f04795a8e8aae7db414d451eff1154245982",
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
        .previous_hash = "82ec46e83af37b1ea0e6b3fe66a8f04795a8e8aae7db414d451eff1154245982",
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
        .previous_hash = "82ec46e83af37b1ea0e6b3fe66a8f04795a8e8aae7db414d451eff1154245982",
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
        .previous_hash = "82ec46e83af37b1ea0e6b3fe66a8f04795a8e8aae7db414d451eff1154245982",
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
        .previous_hash = "82ec46e83af37b1ea0e6b3fe66a8f04795a8e8aae7db414d451eff1154245982", .nonce = 0,
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
        .previous_hash = "82ec46e83af37b1ea0e6b3fe66a8f04795a8e8aae7db414d451eff1154245982",
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
