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
    pub fn validateBlockAtHeight(self: *Blockchain, block: *const Block, height: usize) bool {
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
    pub fn autoExecutePassedProposals(self: *Blockchain, current_block: u64) void {
        @import("blockchain/governance.zig").autoExecutePassedProposals(self, current_block);
    }

    pub fn applyBlock(self: *Blockchain, block: Block) !void {
        return @import("blockchain/apply.zig").applyBlock(self, block);
    }

    /// Collect transactions from blocks being removed during reorg and return them to mempool.
    pub fn collectOrphanedTxs(self: *Blockchain, from_height: usize) !void {
        return @import("blockchain/mempool_helpers.zig").collectOrphanedTxs(self, from_height);
    }

    /// Remove mempool TXs that already exist in the current chain.
    pub fn removeMempoolDuplicates(self: *Blockchain) void {
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
    pub fn processOrphansInternal(self: *Blockchain) void {
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
    pub fn applyHtlcTx(self: *Blockchain, tx: Transaction, block_height: u32) !void {
        return @import("blockchain/htlc_tx.zig").applyHtlcTx(self, tx, block_height);
    }

    // Intent TX dispatcher — extracted to blockchain/intent_tx.zig
    pub fn applyIntentTx(self: *Blockchain, tx: Transaction, block_height: u32) !void {
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
    pub fn applyOrderTxs(self: *Blockchain, block: Block) !void {
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

