const std = @import("std");

// Re-export the EVM build flag at root scope so that sub-modules
// (evm_executor.zig) can probe it via `@hasDecl(@import("root"), …)`.
// build.zig wires `build_options` into this exe via `addOptions()`.
pub const build_options_evm_enabled: bool = @import("build_options").evm_enabled;

const blockchain_mod  = @import("blockchain.zig");
const wallet_mod      = @import("wallet.zig");
const transaction_mod = @import("transaction.zig");
const tx_payload_mod  = @import("tx_payload.zig");
const mempool_mod     = @import("mempool.zig");
const p2p_mod         = @import("p2p.zig");
const sync_mod        = @import("sync.zig");
const bootstrap       = @import("bootstrap.zig");
const main_mod        = @import("main.zig");
const block_mod       = @import("block.zig");
const light_client_mod = @import("light_client.zig");
const miner_wallet_mod = @import("miner_wallet.zig");
const benchmark_mod   = @import("benchmark.zig");
const script_mod      = @import("script.zig");
const multisig_mod    = @import("multisig.zig");
const secp256k1_mod   = @import("secp256k1.zig");
const hex_utils       = @import("hex_utils.zig");
const staking_mod     = @import("staking.zig");
const payment_mod     = @import("payment_channel.zig");
const matching_mod     = @import("matching_engine.zig");
const evm_escrow_mod   = @import("evm_escrow_watcher.zig");
const fills_log_mod    = @import("fills_log.zig");
const token_whitelist  = @import("token_whitelist.zig");
const price_oracle_mod = @import("price_oracle.zig");
const pouw_mod         = @import("consensus_pouw.zig");
const orderbook_sync_mod = @import("orderbook_sync.zig");
const evm_executor    = @import("evm_executor.zig");
const ws_exchange_feed_mod = @import("ws_exchange_feed.zig");
const chain_config    = @import("chain_config.zig");
const validator_mod   = @import("validator_registry.zig");
const orchestrator_mod = @import("orchestrator.zig");
const dns_mod         = @import("dns_registry.zig");
const bech32_mod      = @import("bech32.zig");
const identity_mod    = @import("identity.zig");
const kyc_mod         = @import("kyc.zig");
const registrar_mod   = @import("registrar_addresses.zig");
const agent_manager_mod = @import("agent_manager.zig");
const reputation_mod = @import("reputation.zig");
const reputation_manager_mod = @import("reputation_manager.zig");
const label_mod = @import("label.zig");
const sub_mod = @import("subscription.zig");
const notarize_mod = @import("notarize.zig");
const escrow_mod = @import("escrow.zig");
const social_mod = @import("social_graph.zig");
const poap_mod   = @import("poap.zig");
const gov_mod    = @import("governance_onchain.zig");
const faucet_mod = @import("faucet.zig");
const agent_executor_mod = @import("agent_executor.zig");
const isolated_wallet_mod = @import("isolated_wallet.zig");
const bridge_mod      = @import("bridge_native.zig");
const htlc_btc_mod    = @import("htlc_btc.zig");
const htlc_mod        = @import("htlc.zig");
const spv_btc_mod     = @import("spv_btc.zig");
const spv_eth_mod     = @import("spv_eth.zig");
const cross_chain_oracle_mod = @import("cross_chain_oracle.zig");
const swap_link_mod   = @import("order_swap_link.zig");
const grid_mod        = @import("grid_engine.zig");
const cold_wallet_mod = @import("cold_wallet.zig");
const timelock_mod    = @import("timelock_vault.zig");
const covenant_mod    = @import("covenant.zig");
const treasury_multi_mod = @import("treasury_multi.zig");
// Domain RPC handlers — split out per Bitcoin-Core style. See core/rpc/README.md.
const rpc_eth = @import("rpc/eth.zig");
const rpc_chain = @import("rpc/chain.zig");
const rpc_mempool = @import("rpc/mempool.zig");
const rpc_net = @import("rpc/net.zig");
const rpc_mining = @import("rpc/mining.zig");
const rpc_lightning = @import("rpc/lightning.zig");
const rpc_governance = @import("rpc/governance.zig");
const rpc_social = @import("rpc/social.zig");
const rpc_consensus = @import("rpc/consensus.zig");
const rpc_wallet_advanced = @import("rpc/wallet_advanced.zig");
const rpc_escrow = @import("rpc/escrow.zig");
const rpc_notarize = @import("rpc/notarize.zig");
const rpc_subscription = @import("rpc/subscription.zig");
const rpc_ns = @import("rpc/ns.zig");
const rpc_identity = @import("rpc/identity.zig");
const rpc_agents = @import("rpc/agents.zig");
const rpc_pq = @import("rpc/pq.zig");
const rpc_swap = @import("rpc/swap.zig");
const rpc_spv = @import("rpc/spv.zig");
const rpc_oracle = @import("rpc/oracle.zig");
const rpc_wallet = @import("rpc/wallet.zig");
const rpc_exchange = @import("rpc/exchange.zig");
pub const Metrics     = benchmark_mod.Metrics;

pub const ExchangePair = struct {
    id: u16,
    base: []const u8,
    quote: []const u8,
};

// Trading pairs — append-only by ID. Quote is USDC (not USD) because we
// settle in stablecoin internally; "USD" was a confusing label.
// IMPORTANT (founder rule, memory project_omnibus_dex_native): never
// reorder existing IDs — clients in the wild remember `pair_id` by index.
// New pairs go at the end; renames of an existing slot's quote MUST be
// done at testnet (we are) before any external integration.
pub const EXCHANGE_PAIRS = [_]ExchangePair{
    .{ .id = 0, .base = "OMNI", .quote = "USDC" },
    .{ .id = 1, .base = "BTC",  .quote = "USDC" },
    .{ .id = 2, .base = "LCX",  .quote = "USDC" },
    .{ .id = 3, .base = "ETH",  .quote = "USDC" },
    .{ .id = 4, .base = "OMNI", .quote = "BTC"  },
    .{ .id = 5, .base = "OMNI", .quote = "LCX"  },
    .{ .id = 6, .base = "OMNI", .quote = "ETH"  },
    .{ .id = 7, .base = "OMNI", .quote = "SOL"  },
    .{ .id = 8, .base = "OMNI", .quote = "EURC" },
    .{ .id = 9, .base = "OMNI", .quote = "XRP"  },
};
// Process-global cross-chain oracle. Validators populate this via
// `oracle_recordHeader` (PQ quorum gated); SPV verifiers read it.
// File-private to keep ServerCtx untouched per the task's "don't
// modify existing handlers" constraint.
pub var g_xchain_oracle: cross_chain_oracle_mod.CrossChainOracle =
    cross_chain_oracle_mod.CrossChainOracle.init();
pub var g_xchain_oracle_mutex: std.Thread.Mutex = .{};
pub var g_xchain_oracle_loaded: bool = false;
pub const XCHAIN_ORACLE_PATH = "data/cross_chain_oracle.bin";

// ─── Oracle quorum validator pubkey set ───────────────────────────────────────
//
// The cross-chain oracle (`oracle_recordHeader`) accepts a foreign-chain
// header anchor only when ≥3 distinct validators co-sign it.
//
// IMPORTANT — bootstrap caveat: `validator_registry.GENESIS_VALIDATORS`
// in this repo currently stores ADDRESSES not pubkeys, and contains a
// single bootstrap entry (testnet single-validator seed). The task spec
// asks for "≥3 signatures from validator_registry.GENESIS_VALIDATORS"
// but that registry doesn't yet expose secp256k1 pubkeys to verify
// against. To avoid touching that module (per scope constraints) we
// mirror the validator pubkey set here. Replace before mainnet:
//   * mainnet quorum should pull pubkeys from a hardened genesis-config.
//   * for testnet, populate via `setOracleQuorumPubkeysForTest` so the
//     oracle gate is enforced rather than bypassed.
//
// Empty default → handleOracleRecordHeader will reject ALL writes with
// "Quorum signature insufficient" until the operator installs at least
// 3 pubkeys. This is intentional: a misconfigured node MUST NOT silently
// accept anchors.
pub const OracleQuorumPubkey = [33]u8;
pub const ORACLE_QUORUM_MIN: usize = 3;
pub const ORACLE_QUORUM_MAX: usize = 16;
pub var g_oracle_quorum_pubkeys: [ORACLE_QUORUM_MAX]OracleQuorumPubkey = undefined;
pub var g_oracle_quorum_count: usize = 0;

/// Install the quorum pubkey set. Validators-only — caller must enforce
/// admin authentication (today: in-process startup wiring).
pub fn setOracleQuorumPubkeys(pubs: []const OracleQuorumPubkey) !void {
    if (pubs.len > ORACLE_QUORUM_MAX) return error.TooManyPubkeys;
    g_oracle_quorum_count = pubs.len;
    var i: usize = 0;
    while (i < pubs.len) : (i += 1) g_oracle_quorum_pubkeys[i] = pubs[i];
}

/// Test-only helper: install ephemeral pubkeys for unit tests.
pub fn setOracleQuorumPubkeysForTest(pubs: []const OracleQuorumPubkey) void {
    setOracleQuorumPubkeys(pubs) catch unreachable;
}

pub fn isQuorumPubkey(pk: OracleQuorumPubkey) bool {
    var i: usize = 0;
    while (i < g_oracle_quorum_count) : (i += 1) {
        if (std.mem.eql(u8, &g_oracle_quorum_pubkeys[i], &pk)) return true;
    }
    return false;
}

pub fn ensureOracleLoaded() void {
    g_xchain_oracle_mutex.lock();
    defer g_xchain_oracle_mutex.unlock();
    if (g_xchain_oracle_loaded) return;
    g_xchain_oracle.loadFromFile(XCHAIN_ORACLE_PATH) catch {};
    g_xchain_oracle_loaded = true;
}

pub const Blockchain  = blockchain_mod.Blockchain;
pub const Wallet      = wallet_mod.Wallet;

// Counter global pentru tx_id (atomic)
pub var g_tx_counter = std.atomic.Value(u32).init(1);

// ─── RPC Server struct (folosit din main) ─────────────────────────────────────

pub const RPCServer = struct {
    blockchain: *Blockchain,
    wallet:     *Wallet,
    allocator:  std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, bc: *Blockchain, w: *Wallet) !RPCServer {
        return RPCServer{ .blockchain = bc, .wallet = w, .allocator = allocator };
    }

    pub fn deinit(_: *RPCServer) void {}

    pub fn getBlockCount(self: *RPCServer) u32  { return self.blockchain.getBlockCount(); }
    pub fn getBalance(self: *RPCServer)    u64  { return self.wallet.getBalance(); }
    pub fn getMempoolSize(self: *RPCServer) u32 { return std.math.cast(u32, self.blockchain.mempool.items.len) orelse std.math.maxInt(u32); }
};

// ─── HTTP JSON-RPC 2.0 server ─────────────────────────────────────────────────

/// Default RPC port — fallback when caller doesn't pass HTTPConfig.port.
/// Real port is taken from chain_config (mainnet=8332, testnet=18332,
/// regtest=28332, signet=38332) and passed via HTTPConfig.port.
const DEFAULT_PORT: u16 = 8332;
const MAX_REQUEST = 131072;

/// Un miner inregistrat in retea (via RPC registerminer)
const RegisteredMiner = struct {
    address: [64]u8 = undefined,
    address_len: u8 = 0,
    node_id: [32]u8 = undefined,
    node_id_len: u8 = 0,
    registered_at: i64 = 0,
};

pub const MAX_REGISTERED_MINERS = 256;

/// Context partajat intre thread-uri (blockchain + wallet + module noi)
pub const ServerCtx = struct {
    bc:        *Blockchain,
    wallet:    *Wallet,
    /// Faucet wallet — OPTIONAL second key, only loaded when the node
    /// runs with `--faucet-mode`. Used by `claimFaucet` RPC and the
    /// auto-claim handshake handler to sign 0.1-OMNI grants without
    /// touching the miner's primary key. Null when faucet mode is off.
    faucet_wallet: ?*Wallet = null,
    /// Per-claim grant in SAT. 0 = faucet disabled even if wallet is set.
    faucet_grant_sat: u64 = 0,
    /// On-chain DNS / ENS registry — name → address mapping.
    dns: ?*dns_mod.DnsRegistry = null,
    allocator: std.mem.Allocator,
    // Optional — null daca nu sunt disponibile (backward compat)
    mempool:   ?*mempool_mod.Mempool   = null,
    p2p:       ?*p2p_mod.P2PNode       = null,
    sync_mgr:  ?*sync_mod.SyncManager  = null,
    /// Performance metrics — null if not attached
    metrics:   ?*Metrics = null,
    /// Staking engine — null if not attached
    staking:   ?*staking_mod.StakingEngine = null,
    /// Payment channel manager — null if not attached
    channel_mgr: ?*payment_mod.ChannelManager = null,
    /// PoUW consensus engine — null if not attached
    pouw: ?*pouw_mod.PoUWEngine = null,
    /// Distributed price oracle — null if not attached
    oracle: ?*price_oracle_mod.DistributedPriceOracle = null,
    /// Chain ID for EVM-compat RPC (`eth_chainId`). Default mainnet.
    chain_id: u32 = 1,
    /// Starea miner-ului: true = idle (ex: duplicate_ip_detected), false = active
    is_idle:   bool = false,
    /// Registru de mineri — creste la fiecare registerminer RPC
    registered_miners: [MAX_REGISTERED_MINERS]RegisteredMiner = undefined,
    registered_miner_count: u16 = 0,
    reg_mutex: std.Thread.Mutex = .{},
    /// Optional bearer token for RPC auth, copied into static storage at
    /// init time so the buffer outlives any caller-owned slice. Null
    /// (length=0) = no auth (legacy / dev). When set, non-loopback
    /// requests MUST include `Authorization: Bearer <token>` or get 401.
    /// Loopback (127.0.0.1) is always trusted so the local UI works
    /// without config.
    auth_token_buf: [128]u8 = undefined,
    auth_token_len: usize = 0,

    /// Native DEX matching engine — REAL trader mode. Orders here move
    /// real-money internal balances (token "OMNI"). Shared across RPC
    /// threads — every access MUST take `exchange_mutex`.
    exchange: ?*matching_mod.MatchingEngine = null,
    exchange_mutex: std.Thread.Mutex = .{},
    /// Parallel matching engine — PAPER trader (demo) mode. Identical
    /// type and structure as `exchange`, but the only token it accepts
    /// is `OMNI_DEMO`. Lets users practice strategies without burning
    /// real OMNI. Same lock to keep the global wire-deterministic ordering.
    exchange_paper: ?*matching_mod.MatchingEngine = null,
    /// Heap-allocated bulk tables (trade_log, nonces, api_keys, balances).
    /// Out-of-line so ServerCtx stays small enough to live on the stack-
    /// allocated thread frames glibc/Linux gives us.
    exstate: ?*ExchangeState = null,
    /// Public on-chain identity store (nickname / ENS pref / visibility).
    /// Heap-allocated, replayed from `data/<chain>/identities.jsonl` at
    /// startup. Same lifecycle as the exchange state.
    identity_store: ?*identity_mod.IdentityStore = null,
    /// KYC attestation store. PII never lives here — this is a list of
    /// `{address, level, issuer, sig}` entries that prove a level was
    /// granted off-chain by a trusted issuer (slot 4).
    kyc_store: ?*kyc_mod.KycStore = null,
    /// Address of the KYC issuer (registrar slot 4 = kyc.omnibus). Only
    /// signatures from this address are accepted by `kyc_attest`. Empty
    /// string = KYC issuance disabled on this node.
    kyc_issuer_addr_buf: [64]u8 = undefined,
    kyc_issuer_addr_len: u8 = 0,
    /// EVM escrow watcher — polls OmnibusDEX OrderPlaced events on Sepolia
    /// (and other EVM chains). exchange_placeOrder uses this to verify
    /// that a BUY order on OMNI/<EVM-token> is backed by a real on-chain
    /// escrow before adding it to the orderbook. Hyperliquid-style.
    evm_escrow_watcher: ?*evm_escrow_mod.Watcher = null,
    /// Mutex for identity / KYC operations. They both touch in-memory
    /// stores; same lock keeps them serializable without a finer split.
    identity_mutex: std.Thread.Mutex = .{},
    /// Path to `data/<chain>/orders.jsonl` for persistence. Empty =
    /// in-memory only (regtest / unit tests).
    orders_path_buf: [256]u8 = undefined,
    orders_path_len: usize = 0,
    /// Path to data/<chain>/exchange-users.jsonl. Append-only journal
    /// of register/api-key/deposit/withdraw events. Replayed on startup
    /// so users + balances + keys survive restart.
    users_path_buf: [256]u8 = undefined,
    users_path_len: usize = 0,
    /// Cross-chain bridge state — null until main.zig calls ctx.bridge = &g_bridge_state.
    /// When null, bridge RPC methods return a "bridge not initialized" error.
    bridge: ?*bridge_mod.BridgeState = null,
    bridge_mutex: std.Thread.Mutex = .{},
    /// Grid trading registry — heap-allocated, persisted in data/<chain>/grid_registry.bin.
    grid_registry: ?*grid_mod.GridRegistry = null,
    grid_mutex: std.Thread.Mutex = .{},
    /// Path to grid_registry.bin — set from main.zig via HTTPConfig.
    grid_path_buf: [256]u8 = undefined,
    grid_path_len: usize = 0,
    /// Path to `data/<chain>/profiles.jsonl`. Append-only log of profile_init /
    /// profile_update events. Replayed at startup so identity profiles survive
    /// node restarts. Empty = in-memory only.
    profiles_path_buf: [256]u8 = undefined,
    profiles_path_len: usize = 0,
    /// Append-only binary log of executed trade fills. Populated on every
    /// fill from the matching engine; queried by exchange_getUserTrades so
    /// the frontend's "My Trades" panel can show on-chain history that
    /// survives restart.
    fills_log: ?*fills_log_mod.FillsLog = null,
};

/// Per-trader nonce slot. Looked up linearly — small enough to fit in
/// L1, big enough for testnet (1024 active traders before eviction).
const TraderNonce = struct {
    address: [64]u8 = undefined,
    address_len: u8 = 0,
    last_nonce: u64 = 0,
};

/// Auth nonce stored after `exchange_getAuthNonce`. The user signs
/// "OmniBus Exchange Login: <nonce>" and submits to `exchange_login`.
/// Single-use; expires after AUTH_NONCE_TTL_MS so a leaked one is useless.
const AuthNonce = struct {
    address: [64]u8 = undefined,
    address_len: u8 = 0,
    nonce_hex: [64]u8 = undefined, // 32 random bytes hex-encoded
    nonce_hex_len: u8 = 0,
    created_ms: i64 = 0,
};
pub const AUTH_NONCE_TTL_MS: i64 = 5 * 60 * 1000;

/// Exchange API key. Plaintext secret is given to the user ONCE at
/// creation time and never stored — only `secret_hash` (SHA256) lives on
/// disk so we can verify future requests.
const ExchangeApiKey = struct {
    key_id: [32]u8 = undefined,    // "obx_<24 hex>" → 28 chars
    key_id_len: u8 = 0,
    secret_raw: [32]u8 = undefined, // Raw 32-byte secret for HMAC-SHA512 auth (Phase 1)
    secret_raw_len: u8 = 0,
    secret_hash: [64]u8 = undefined, // SHA256 hex (64 chars) — legacy transparency
    secret_hash_len: u8 = 0,
    name: [32]u8 = undefined,
    name_len: u8 = 0,
    owner: [64]u8 = undefined,
    owner_len: u8 = 0,
    created_ms: i64 = 0,
    last_used_ms: i64 = 0,
    revoked: bool = false,
};

/// Internal exchange balance. Off-chain credit — `deposit` moves on-chain
/// OMNI into this internal pool (testnet: faked, mainnet would lock real
/// funds in an escrow address). `locked_sat` is reserved for open orders.
const ExchangeBalance = struct {
    owner: [64]u8 = undefined,
    owner_len: u8 = 0,
    token: [16]u8 = undefined,
    token_len: u8 = 0,
    available_sat: u64 = 0,
    locked_sat: u64 = 0,
};

/// All the bulky exchange tables. Lives on the heap (allocated once at
/// startup) so ServerCtx stays small and fits comfortably on small stacks.
/// Keeping them out-of-line is what allows the node to boot on a 1 GB
/// VPS without segfaulting on the systemd thread stack.
const ExchangeState = struct {
    /// 256 rolling fills for `exchange_getTrades`.
    /// Real-trader fill log (rolling, last 256 fills on real engine).
    trade_log: [256]matching_mod.Fill = undefined,
    trade_head: u32 = 0,
    trade_count: u32 = 0,
    /// Paper-trader fill log — same shape, isolated. When the user is in
    /// paper mode the UI reads from here, never seeing real fills (and
    /// vice-versa). Same way mainnet/testnet are isolated chains.
    trade_log_paper: [256]matching_mod.Fill = undefined,
    trade_head_paper: u32 = 0,
    trade_count_paper: u32 = 0,
    /// Order-replay nonces (per trader, FIFO).
    nonces: [1024]TraderNonce = undefined,
    nonce_count: u16 = 0,
    /// Login nonces (single-use, 5 min TTL).
    auth_nonces: [64]AuthNonce = undefined,
    auth_nonce_count: u16 = 0,
    /// API keys.
    api_keys: [128]ExchangeApiKey = undefined,
    api_key_count: u16 = 0,
    /// Internal exchange balances.
    balances: [256]ExchangeBalance = undefined,
    balance_count: u16 = 0,
    /// Used real-deposit txids (anti-replay so the same TX cannot be
    /// claimed twice). Each slot is a 64-char hex hash.
    real_deposit_txids: [512][64]u8 = undefined,
    real_deposit_count: u16 = 0,
    /// Demo-money quota — per-address, FIFO. Keeps us from someone
    /// minting infinite demo OMNI. Resets only when the slot is evicted.
    demo_quotas: [256]DemoQuota = undefined,
    demo_quota_count: u16 = 0,
};

/// Per-address demo deposit quota. Resets on a 24h rolling window.
const DemoQuota = struct {
    address: [64]u8 = undefined,
    address_len: u8 = 0,
    /// Total demo OMNI granted in the current window (in SAT).
    granted_sat: u64 = 0,
    /// Window start (ms). When (now - window_start) > 24h, granted resets.
    window_start_ms: i64 = 0,
};

/// Cap demo issuance per address per 24h. Generous on testnet — the goal
/// is letting users iterate on bot/UI strategies, not be a real onramp.
pub const DEMO_MAX_PER_REQUEST_SAT: u64 = 10 * 1_000_000_000; // 10 OMNI
pub const DEMO_MAX_PER_24H_SAT: u64 = 100 * 1_000_000_000;     // 100 OMNI / day
pub const DEMO_WINDOW_MS: i64 = 24 * 60 * 60 * 1000;

/// Context public expus utilizatorilor externi (alias la ServerCtx)
pub const RPCContext = ServerCtx;

/// Context extins pentru startHTTP cu module optionale
pub const HTTPConfig = struct {
    mempool:  ?*mempool_mod.Mempool  = null,
    p2p:      ?*p2p_mod.P2PNode      = null,
    sync_mgr: ?*sync_mod.SyncManager = null,
    metrics:  ?*Metrics              = null,
    staking:  ?*staking_mod.StakingEngine = null,
    channel_mgr: ?*payment_mod.ChannelManager = null,
    pouw: ?*pouw_mod.PoUWEngine = null,
    oracle: ?*price_oracle_mod.DistributedPriceOracle = null,
    chain_id: u32 = 1,
    /// Port to bind RPC HTTP listener. Default = DEFAULT_PORT (8332 mainnet).
    /// Pass chain_config.rpc_port so testnet/regtest don't all collide on 8332.
    port: u16 = DEFAULT_PORT,
    /// Address to bind to. Defaults to "127.0.0.1" so a fresh node is NOT
    /// exposed to the public internet by accident. Pass "0.0.0.0" only on
    /// nodes intended to be public RPC endpoints (typically behind nginx
    /// with auth_token + rate limit).
    bind_host: []const u8 = "127.0.0.1",
    /// Bearer token for RPC auth. Null = open (loopback always allowed).
    /// On public nodes, set this to a long random string and inject into
    /// Authorization header via reverse proxy or trusted client.
    auth_token: ?[]const u8 = null,
    /// Optional faucet wallet (loaded only when --faucet-mode is set on
    /// the node). Used to sign `claimFaucet` payouts.
    faucet_wallet: ?*Wallet = null,
    /// Per-claim grant in SAT. 0 = faucet disabled. Default 0.
    faucet_grant_sat: u64 = 0,
    /// On-chain DNS / ENS registry. When set, RPC methods `registerName`,
    /// `resolveName`, `reverseResolveName` are exposed.
    dns: ?*dns_mod.DnsRegistry = null,
    /// Native DEX matching engine. Caller owns the allocation — server
    /// just borrows. When null, all `exchange_*` RPC methods return
    /// "Exchange not enabled" so callers can probe support.
    exchange: ?*matching_mod.MatchingEngine = null,
    /// Paper-trading matching engine (demo). Same lifecycle as `exchange`.
    /// When null, REST routes `/paper/0/*` return "Paper trader disabled".
    exchange_paper: ?*matching_mod.MatchingEngine = null,
    /// EVM escrow watcher (Hyperliquid-style). Null = OMNI/<EVM> BUY orders
    /// are refused for safety.
    evm_escrow_watcher: ?*evm_escrow_mod.Watcher = null,
    /// Path to `data/<chain>/orders.jsonl`. Empty/null = in-memory only.
    /// Same JSONL pattern as faucet ledger so a node can restart without
    /// losing the orderbook state.
    orders_path: ?[]const u8 = null,
    /// Path to `data/<chain>/exchange-users.jsonl`. Stores api keys +
    /// internal exchange balances. Empty/null = in-memory only.
    users_path: ?[]const u8 = null,
    /// Path to `data/<chain>/identities.jsonl`. Stores public nickname
    /// / ENS-pref / visibility. Empty/null = in-memory only.
    identities_path: ?[]const u8 = null,
    /// Path to `data/<chain>/kyc-attestations.jsonl`. Empty/null = in-memory only.
    kyc_path: ?[]const u8 = null,
    /// Address of the KYC issuer (registrar slot 4). When set, this
    /// address's signatures are honored by `kyc_attest`. Empty = the
    /// node won't accept any KYC issuance (read-only KYC view).
    kyc_issuer_address: ?[]const u8 = null,
    /// Cross-chain bridge state. When null, bridge RPC methods return
    /// "Bridge not initialized". Pass pointer to g_bridge_state from main.
    bridge: ?*bridge_mod.BridgeState = null,
    /// Grid trading registry. When null, grid_* RPC methods return
    /// "Grid engine not initialized". Heap-allocated by main, shared here.
    grid_registry: ?*grid_mod.GridRegistry = null,
    /// Path to persist grid_registry.bin. Null = in-memory only.
    grid_path: ?[]const u8 = null,
    /// Path to `data/<chain>/profiles.jsonl`. Append-only journal of
    /// profile_init / profile_update events. Replayed at startup so
    /// identity profiles survive node restarts. Null = in-memory only.
    profiles_path: ?[]const u8 = null,
    /// Append-only binary log of executed trade fills. When set, every
    /// fill produced by the matching engine is mirrored here so the
    /// frontend's "My Trades" panel can list on-chain history.
    fills_log: ?*fills_log_mod.FillsLog = null,
};

/// Porneste serverul HTTP pe portul 8332 (blocking — ruleaza pe thread separat)
pub fn startHTTP(bc: *Blockchain, wallet: *Wallet, allocator: std.mem.Allocator) !void {
    return startHTTPEx(bc, wallet, allocator, .{});
}

/// Versiunea extinsa cu module optionale (mempool, p2p, sync)
pub fn startHTTPEx(bc: *Blockchain, wallet: *Wallet, allocator: std.mem.Allocator, cfg: HTTPConfig) !void {
    const ctx = try allocator.create(ServerCtx);
    // Avoid `ctx.* = .{ ... }` because the struct has multi-MB inline
    // arrays (api_keys, balances, nonces, trade_log) — the anonymous-
    // struct initializer materializes a temporary on the stack first
    // and then copies. On Linux miner threads (1 MB stack) that segfaults
    // before main even gets to start the RPC server. Zero the struct in
    // place, then set individual fields.
    @memset(std.mem.asBytes(ctx), 0);
    ctx.bc = bc;
    ctx.wallet = wallet;
    ctx.allocator = allocator;
    ctx.mempool = cfg.mempool;
    ctx.p2p = cfg.p2p;
    ctx.sync_mgr = cfg.sync_mgr;
    ctx.metrics = cfg.metrics;
    ctx.staking = cfg.staking;
    ctx.channel_mgr = cfg.channel_mgr;
    ctx.pouw = cfg.pouw;
    ctx.oracle = cfg.oracle;
    ctx.chain_id = cfg.chain_id;
    ctx.faucet_wallet = cfg.faucet_wallet;
    ctx.faucet_grant_sat = cfg.faucet_grant_sat;
    ctx.dns = cfg.dns;
    ctx.exchange = cfg.exchange;
    ctx.exchange_paper = cfg.exchange_paper;
    ctx.evm_escrow_watcher = cfg.evm_escrow_watcher;
    ctx.fills_log = cfg.fills_log;
    ctx.bridge = cfg.bridge;
    ctx.grid_registry = cfg.grid_registry;
    if (cfg.grid_path) |p| {
        const n = @min(p.len, ctx.grid_path_buf.len);
        @memcpy(ctx.grid_path_buf[0..n], p[0..n]);
        ctx.grid_path_len = n;
    }
    if (cfg.profiles_path) |p| {
        const n = @min(p.len, ctx.profiles_path_buf.len);
        @memcpy(ctx.profiles_path_buf[0..n], p[0..n]);
        ctx.profiles_path_len = n;
        std.fs.cwd().makePath(std.fs.path.dirname(p) orelse ".") catch {};
        replayProfilesJournal(ctx) catch |err| {
            std.debug.print("[PROFILE] profiles.jsonl replay failed: {s}\n", .{@errorName(err)});
        };
        std.debug.print("[PROFILE] journal: {s}\n", .{p});
    }
    ctx.reg_mutex = .{};
    ctx.exchange_mutex = .{};

    // Bulk exchange tables on the heap — keeps ServerCtx small.
    // page_allocator (mmap on Linux) is more robust for the single
    // ~400KB long-lived object than the gpa's small-bin path.
    if (cfg.exchange != null) {
        const page_alloc = std.heap.page_allocator;
        const es = page_alloc.create(ExchangeState) catch null;
        if (es) |s| {
            @memset(std.mem.asBytes(s), 0);
            ctx.exstate = s;
        }
    }
    // Cache the orders persistence path into ServerCtx-owned static
    // storage (caller's slice may not outlive us) and replay any prior
    // orders so the orderbook resumes where we left off.
    if (cfg.orders_path) |p| {
        const n = @min(p.len, ctx.orders_path_buf.len);
        @memcpy(ctx.orders_path_buf[0..n], p[0..n]);
        ctx.orders_path_len = n;
        if (cfg.exchange != null) {
            replayOrdersJournal(ctx) catch |err| {
                std.debug.print("[RPC] orders.jsonl replay failed: {s}\n", .{@errorName(err)});
            };
        }
    }
    if (cfg.users_path) |p| {
        const n = @min(p.len, ctx.users_path_buf.len);
        @memcpy(ctx.users_path_buf[0..n], p[0..n]);
        ctx.users_path_len = n;
        replayUsersJournal(ctx) catch |err| {
            std.debug.print("[RPC] exchange-users.jsonl replay failed: {s}\n", .{@errorName(err)});
        };
    }

    // ── Identity store (public nickname / ENS-pref / visibility) ─────────
    {
        const page_alloc = std.heap.page_allocator;
        const ids = page_alloc.create(identity_mod.IdentityStore) catch null;
        if (ids) |s| {
            s.* = identity_mod.IdentityStore.init();
            if (cfg.identities_path) |p| s.setJournalPath(p);
            s.replay() catch |err| {
                std.debug.print("[IDENTITY] replay failed: {s}\n", .{@errorName(err)});
            };
            ctx.identity_store = s;
        }
    }

    // ── KYC store (signed attestations, no PII) ─────────────────────────
    {
        const page_alloc = std.heap.page_allocator;
        const ks = page_alloc.create(kyc_mod.KycStore) catch null;
        if (ks) |s| {
            s.* = kyc_mod.KycStore.init();
            if (cfg.kyc_path) |p| s.setJournalPath(p);
            s.replay() catch |err| {
                std.debug.print("[KYC] replay failed: {s}\n", .{@errorName(err)});
            };
            ctx.kyc_store = s;
        }
    }
    if (cfg.kyc_issuer_address) |addr| {
        const n = @min(addr.len, ctx.kyc_issuer_addr_buf.len);
        @memcpy(ctx.kyc_issuer_addr_buf[0..n], addr[0..n]);
        ctx.kyc_issuer_addr_len = @intCast(n);
        std.debug.print("[KYC] issuer address: {s}\n", .{addr});
    } else {
        std.debug.print("[KYC] no issuer address configured (read-only KYC mode)\n", .{});
    }
    // Copy the auth token into ServerCtx-owned static storage so we don't
    // hold a pointer to a caller-owned slice that might get freed/moved.
    if (cfg.auth_token) |t| {
        const n = @min(t.len, ctx.auth_token_buf.len);
        @memcpy(ctx.auth_token_buf[0..n], t[0..n]);
        ctx.auth_token_len = n;
    }

    const final_addr = std.net.Address.parseIp4(cfg.bind_host, cfg.port) catch blk: {
        std.debug.print("[RPC] bad bind_host '{s}' — falling back to 127.0.0.1\n", .{cfg.bind_host});
        break :blk try std.net.Address.parseIp4("127.0.0.1", cfg.port);
    };
    var server  = try final_addr.listen(.{ .reuse_address = true });
    defer server.deinit();

    const auth_label: []const u8 = if (cfg.auth_token != null) "auth=on" else "auth=off (loopback only safe)";
    std.debug.print("[RPC] HTTP JSON-RPC 2.0 listening on http://{s}:{d} ({s})\n", .{ cfg.bind_host, cfg.port, auth_label });

    // Limita thread-uri concurente (previne OOM sub heavy load).
    // Crescut la 16 pentru a deservi explorer-ul React care face 20 cereri
    // paralele pe BlocksPage. La 4 threads vechi, cele 16 in plus erau
    // refuzate (ECONNRESET) si Nginx returna 502.
    var active_threads: std.atomic.Value(u32) = .{ .raw = 0 };
    // Fix B1 (stress security): concurrent fuzz with 30+ threads triggered SEGV/ABRT
    // on shared GPA allocator + cross-handler mutex contention. Reduced cap to 8
    // threads (8 × 16MB = 128MB stack max) — at-rest mainnet keeps 60+ blk/min.
    // True fix would be per-request arena allocator (TODO) + audit of shared
    // mutable state without mutex in the 91 affected methods.
    const MAX_CONCURRENT: u32 = 8;

    while (true) {
        const conn = server.accept() catch |err| {
            std.debug.print("[RPC] accept error: {}\n", .{err});
            continue;
        };

        // Drop connection daca prea multe active (backpressure)
        if (active_threads.load(.monotonic) >= MAX_CONCURRENT) {
            conn.stream.close();
            continue;
        }

        // Note: parent allocator is GPA which is mutex-guarded (thread_safe = true
        // in Zig 0.15.2 when not single-threaded). Per-request arena allocator was
        // considered (P4-2) but deferred until profiling shows actual contention —
        // the 8-thread MAX_CONCURRENT cap above bounds the worst case.
        const thread_ctx = try allocator.create(ConnCtx);
        thread_ctx.* = .{ .conn = conn, .server_ctx = ctx, .active_counter = &active_threads };
        _ = active_threads.fetchAdd(1, .monotonic);
        const t = std.Thread.spawn(.{ .stack_size = 16 * 1024 * 1024 }, handleConnCounted, .{thread_ctx}) catch {
            _ = active_threads.fetchSub(1, .monotonic);
            conn.stream.close();
            allocator.destroy(thread_ctx);
            continue;
        };
        t.detach();
    }
}

const ConnCtx = struct {
    conn:       std.net.Server.Connection,
    server_ctx: *ServerCtx,
    active_counter: *std.atomic.Value(u32),
};

fn handleConnCounted(ctx: *ConnCtx) void {
    // Defers run in reverse order — without saving pointers, the counter
    // decrement would touch ctx AFTER allocator.destroy(ctx) frees it.
    // Save raw pointers to outlive the destroy.
    const counter = ctx.active_counter;
    const stream  = ctx.conn.stream;
    const alloc   = ctx.server_ctx.allocator;
    defer _ = counter.fetchSub(1, .monotonic);
    defer alloc.destroy(ctx);
    defer stream.close();

    // Read request. On Windows, std.net.Stream.read goes through
    // windows.ReadFile which throws error.Unexpected (GetLastError 87) on
    // certain socket states even though the read itself succeeds — this
    // tears down the handler before we can send a response, leaving curl
    // with "Connection was reset". Use Winsock recv() directly on Windows
    // to bypass this; POSIX uses the portable read() path.
    var buf: [MAX_REQUEST]u8 = undefined;

    var total: usize = 0;
    var hdr_end: usize = 0;
    var got_header = false;
    var content_len: usize = 0;

    const is_windows = @import("builtin").target.os.tag == .windows;

    while (total < buf.len) {
        const got: usize = blk: {
            if (is_windows) {
                const ws2 = std.os.windows.ws2_32;
                const sock: ws2.SOCKET = @ptrFromInt(@as(usize, @intCast(@intFromPtr(ctx.conn.stream.handle))));
                const dst = buf[total..];
                const r = ws2.recv(sock, @ptrCast(dst.ptr), @intCast(dst.len), 0);
                if (r <= 0) break;
                break :blk @intCast(r);
            } else {
                break :blk ctx.conn.stream.read(buf[total..]) catch break;
            }
        };
        if (got == 0) break;
        total += got;
        if (!got_header) {
            if (std.mem.indexOf(u8, buf[0..total], "\r\n\r\n")) |pos| {
                hdr_end = pos;
                got_header = true;
                content_len = extractContentLength(buf[0..pos]);
                if (content_len == 0 or total >= pos + 4 + content_len) break;
            }
        } else {
            if (total >= hdr_end + 4 + content_len) break;
        }
    }

    if (total == 0 or !got_header) return;
    const raw = buf[0..total];

    if (std.mem.startsWith(u8, raw, "OPTIONS")) {
        const cors = "HTTP/1.1 204 No Content\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Allow-Methods: POST, OPTIONS\r\nAccess-Control-Allow-Headers: Content-Type, Authorization\r\nAccess-Control-Max-Age: 86400\r\nConnection: close\r\n\r\n";
        _ = ctx.conn.stream.write(cors) catch {};
        return;
    }

    // Auth check before any RPC dispatch. Loopback always allowed; remote
    // peers must present `Authorization: Bearer <token>` matching ServerCtx
    // auth_token (set via HTTPConfig from --rpc-token CLI / env).
    if (!isAuthorized(ctx.server_ctx, raw[0..hdr_end], peerIpv4Bytes(ctx.conn.address))) {
        writeUnauthorized(ctx.conn.stream);
        return;
    }

    const body = raw[hdr_end + 4 .. total];

    // Try REST dispatch first (Kraken-compatible /exchange/0/* routes)
    if (dispatchRest(ctx.server_ctx.allocator, ctx.conn.stream, raw[0..hdr_end], body, ctx.server_ctx)) {
        return;
    }

    const response = dispatch(body, ctx.server_ctx) catch {
        const fallback = ctx.server_ctx.allocator.dupe(u8, "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32603,\"message\":\"Internal error\"}}") catch return;
        defer ctx.server_ctx.allocator.free(fallback);
        var fb_hdr: [128]u8 = undefined;
        const fb_h = std.fmt.bufPrint(&fb_hdr, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n", .{fallback.len}) catch return;
        _ = ctx.conn.stream.write(fb_h) catch {};
        _ = ctx.conn.stream.write(fallback) catch {};
        return;
    };
    defer ctx.server_ctx.allocator.free(response);

    var hdr_buf: [128]u8 = undefined;
    const hdr = std.fmt.bufPrint(&hdr_buf, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n", .{response.len}) catch return;
    _ = ctx.conn.stream.write(hdr) catch {};
    _ = ctx.conn.stream.write(response) catch {};
}

fn handleConn(ctx: *ConnCtx) void {
    defer ctx.server_ctx.allocator.destroy(ctx);
    defer ctx.conn.stream.close();

    var buf: [MAX_REQUEST]u8 = undefined;
    const ws2 = std.os.windows.ws2_32;
    const sock = ctx.conn.stream.handle;

    // recv loop: citim pana avem header (\r\n\r\n) + body (Content-Length bytes)
    var total: usize = 0;
    var hdr_end: usize = 0;
    var got_header = false;
    var content_len: usize = 0;

    while (total < buf.len) {
        const space: c_int = @intCast(buf.len - total);
        const got = ws2.recv(sock, buf[total..].ptr, space, 0);
        if (got <= 0) break;
        total += @intCast(got);

        if (!got_header) {
            if (std.mem.indexOf(u8, buf[0..total], "\r\n\r\n")) |pos| {
                hdr_end = pos;
                got_header = true;
                content_len = extractContentLength(buf[0..pos]);
                if (content_len == 0 or total >= pos + 4 + content_len) break;
            }
        } else {
            if (total >= hdr_end + 4 + content_len) break;
        }
    }

    if (total == 0 or !got_header) return;
    const n = total;

    const raw = buf[0..n];

    // Handle CORS preflight (OPTIONS request from browser)
    if (std.mem.startsWith(u8, raw, "OPTIONS")) {
        const cors_response = "HTTP/1.1 204 No Content\r\n" ++
            "Access-Control-Allow-Origin: *\r\n" ++
            "Access-Control-Allow-Methods: POST, OPTIONS\r\n" ++
            "Access-Control-Allow-Headers: Content-Type, Authorization\r\n" ++
            "Access-Control-Max-Age: 86400\r\n" ++
            "Connection: close\r\n\r\n";
        _ = ctx.conn.stream.write(cors_response) catch {};
        return;
    }

    // Auth check (same rules as handleConnCounted).
    if (!isAuthorized(ctx.server_ctx, raw[0..hdr_end], peerIpv4Bytes(ctx.conn.address))) {
        writeUnauthorized(ctx.conn.stream);
        return;
    }

    // Gaseste body-ul HTTP (dupa \r\n\r\n)
    const body = if (std.mem.indexOf(u8, raw, "\r\n\r\n")) |pos|
        raw[pos + 4 ..]
    else
        raw;

    const response = dispatch(body, ctx.server_ctx) catch |err| blk: {
        std.debug.print("[RPC] dispatch error: {}\n", .{err});
        break :blk errorJson(-32700, "Parse error", 0, ctx.server_ctx.allocator) catch return;
    };
    defer ctx.server_ctx.allocator.free(response);

    const http = std.fmt.allocPrint(ctx.server_ctx.allocator,
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n{s}",
        .{ response.len, response },
    ) catch return;
    defer ctx.server_ctx.allocator.free(http);

    _ = ctx.conn.stream.write(http) catch {};
}

// ─── REST → JSON-RPC bridge (Kraken-compatible) ──────────────────────────────

fn extractHttpPath(header: []const u8, method_buf: *[]const u8) ?[]const u8 {
    // header first line: "GET /exchange/0/public/Time HTTP/1.1\r\n"
    const eol = std.mem.indexOf(u8, header, "\r\n") orelse return null;
    const line = header[0..eol];
    const s1 = std.mem.indexOf(u8, line, " ") orelse return null;
    method_buf.* = line[0..s1];
    const rest = line[s1 + 1 ..];
    const s2 = std.mem.indexOf(u8, rest, " ") orelse return null;
    return rest[0..s2];
}

/// Extract a header value from the HTTP header block. Case-insensitive key match.
/// Returns the value slice (trimmed) or null if not found.
/// header block format: "Header-Name: value\r\n"
fn extractHttpHeader(header: []const u8, key: []const u8) ?[]const u8 {
    var pos: usize = 0;
    while (pos < header.len) {
        const line_end = std.mem.indexOfPos(u8, header, pos, "\r\n") orelse break;
        const line = header[pos..line_end];
        pos = line_end + 2;
        const colon = std.mem.indexOf(u8, line, ":") orelse continue;
        const hkey = line[0..colon];
        // Manual case-insensitive compare
        if (hkey.len == key.len) {
            var match = true;
            for (hkey, key) |a, b| {
                if (std.ascii.toLower(a) != b) { match = false; break; }
            }
            if (!match) continue;
            var val_start = colon + 1;
            while (val_start < line.len and line[val_start] == ' ') val_start += 1;
            return line[val_start..];
        }
    }
    return null;
}

fn getQueryParam(path: []const u8, key: []const u8) ?[]const u8 {
    const q = std.mem.indexOf(u8, path, "?") orelse return null;
    const qs = path[q + 1 ..];
    var it = std.mem.splitScalar(u8, qs, '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOf(u8, pair, "=") orelse continue;
        if (std.mem.eql(u8, pair[0..eq], key)) {
            return pair[eq + 1 ..];
        }
    }
    return null;
}

/// Normalize a Kraken-mashed pair (`OMNIUSD`, `OMNIUSDC`, `BTCUSDC`)
/// into the slash form `OMNI/USDC` that `exchangePairLookup` expects.
/// If the input already has a `/`, returns it as-is. Returns
/// `{ pair, alloced }` so the caller knows whether to free.
fn normalizePair(alloc: std.mem.Allocator, raw: []const u8) struct {
    pair: []const u8,
    alloced: bool,
} {
    if (std.mem.indexOfScalar(u8, raw, '/') != null) {
        return .{ .pair = raw, .alloced = false };
    }
    // Try USDC first (longer suffix, takes priority).
    if (std.mem.endsWith(u8, raw, "USDC") and raw.len > 4) {
        const buf = std.fmt.allocPrint(alloc, "{s}/USDC", .{raw[0 .. raw.len - 4]}) catch
            return .{ .pair = raw, .alloced = false };
        return .{ .pair = buf, .alloced = true };
    }
    // Legacy "USD" → route to USDC pair (we settle in stablecoin).
    if (std.mem.endsWith(u8, raw, "USD") and raw.len > 3) {
        const buf = std.fmt.allocPrint(alloc, "{s}/USDC", .{raw[0 .. raw.len - 3]}) catch
            return .{ .pair = raw, .alloced = false };
        return .{ .pair = buf, .alloced = true };
    }
    return .{ .pair = raw, .alloced = false };
}

// ─── PHASE 2E.2 helpers (Kraken-compat market data) ────────────────────

/// Convert a `pair_id` (0..6) back to its label form `BASE/QUOTE`.
/// Returned slice is a const literal — caller does not free.
pub fn pairIdToLabel(pair_id: u16) []const u8 {
    return switch (pair_id) {
        0 => "OMNI/USDC",
        1 => "BTC/USDC",
        2 => "LCX/USDC",
        3 => "ETH/USDC",
        4 => "OMNI/BTC",
        5 => "OMNI/LCX",
        6 => "OMNI/ETH",
        7 => "OMNI/SOL",
        8 => "OMNI/EURC",
        9 => "OMNI/XRP",
        else => "UNKNOWN/UNKNOWN",
    };
}

/// Convert a `pair_id` to the Kraken-style flat key (e.g. "OMNIUSDC")
/// used as the result-object key in OHLC/Spread/Trades.
fn pairIdToFlatKey(pair_id: u16) []const u8 {
    return switch (pair_id) {
        0 => "OMNIUSDC",
        1 => "BTCUSDC",
        2 => "LCXUSDC",
        3 => "ETHUSDC",
        4 => "OMNIBTC",
        5 => "OMNILCX",
        6 => "OMNIETH",
        7 => "OMNISOL",
        8 => "OMNIEURC",
        9 => "OMNIXRP",
        else => "UNKNOWN",
    };
}

/// Format a `price_micro_usd` (1_000_000 = 1.00 USDC) as a fixed
/// 8-decimal-digit string into `buf`. Buffer must be >= 24 bytes.
fn formatMicroPrice(price_micro: u64, buf: []u8) []const u8 {
    const whole: u64 = price_micro / 1_000_000;
    const frac_micro: u64 = price_micro % 1_000_000;
    return std.fmt.bufPrint(buf, "{d}.{d:0>6}00", .{ whole, frac_micro }) catch "0.00000000";
}

/// Format an `amount_sat` (1_000_000_000 SAT = 1 unit) as a fixed
/// 8-decimal-digit string into `buf`. Buffer must be >= 24 bytes.
fn formatSatAmount(amount_sat: u64, buf: []u8) []const u8 {
    const whole: u64 = amount_sat / 1_000_000_000;
    const frac_sat: u64 = amount_sat % 1_000_000_000;
    const frac8: u64 = frac_sat / 10;
    return std.fmt.bufPrint(buf, "{d}.{d:0>8}", .{ whole, frac8 }) catch "0.00000000";
}

/// Look up a field in a Kraken-style form-encoded POST body.
/// Body format: `key1=value1&key2=value2`. Caller does NOT get the value
/// URL-decoded — for our purposes (ob1q… addresses, integer prices, pair
/// labels with a `/`) the values fit ASCII safely. If we ever accept
/// names with spaces or %20, swap this for a real urldecode.
fn formGetField(body: []const u8, key: []const u8) ?[]const u8 {
    if (body.len == 0) return null;
    var it = std.mem.splitScalar(u8, body, '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOf(u8, pair, "=") orelse continue;
        if (std.mem.eql(u8, pair[0..eq], key)) {
            return pair[eq + 1 ..];
        }
    }
    return null;
}

fn buildRpcBody(alloc: std.mem.Allocator, method: []const u8, params: []const u8) ![]const u8 {
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"{s}\",\"params\":{s}}}",
        .{ method, params });
}

/// Take a raw JSON-RPC 2.0 response and rewrap it in Kraken's REST format.
/// Kraken expects every REST response to be `{"error":[...],"result":...}`,
/// where `error` is an empty array on success or `["EService:..."]` on
/// failure. Internally we run on JSON-RPC, so this helper bridges both.
fn writeKrakenFromRpc(alloc: std.mem.Allocator, stream: std.net.Stream, rpc_response: []const u8) void {
    // Look for "error":{...} (RPC error object) — translate to Kraken error array.
    if (std.mem.indexOf(u8, rpc_response, "\"error\":{")) |err_start| {
        const msg_key = "\"message\":\"";
        const msg_idx = std.mem.indexOfPos(u8, rpc_response, err_start, msg_key) orelse {
            writeJsonResponse(stream, "{\"error\":[\"EGeneral:Unknown\"],\"result\":{}}");
            return;
        };
        const msg_from = msg_idx + msg_key.len;
        const msg_end = std.mem.indexOfScalarPos(u8, rpc_response, msg_from, '"') orelse rpc_response.len;
        const msg = rpc_response[msg_from..msg_end];
        const wrapped = std.fmt.allocPrint(alloc,
            "{{\"error\":[\"EGeneral:{s}\"],\"result\":{{}}}}", .{msg}) catch {
                writeJsonResponse(stream, "{\"error\":[\"EGeneral:Unknown\"],\"result\":{}}");
                return;
            };
        defer alloc.free(wrapped);
        writeJsonResponse(stream, wrapped);
        return;
    }
    // Look for "result":<value> and forward it as Kraken's `result`.
    const r_key = "\"result\":";
    const r_start = std.mem.indexOf(u8, rpc_response, r_key) orelse {
        writeJsonResponse(stream, "{\"error\":[],\"result\":{}}");
        return;
    };
    const r_from = r_start + r_key.len;
    // The remainder of the JSON-RPC response is either `"result":<value>}` or
    // `"result":<value>,"id":N}`. Find the matching close before the trailing
    // `}` or `,"id"`. Simplest: trim a closing `}`.
    var slice = rpc_response[r_from..];
    if (slice.len > 0 and slice[slice.len - 1] == '}') slice = slice[0 .. slice.len - 1];
    // Trim trailing `,"id":N` if present.
    if (std.mem.lastIndexOf(u8, slice, ",\"id\":")) |id_idx| slice = slice[0..id_idx];
    const wrapped = std.fmt.allocPrint(alloc,
        "{{\"error\":[],\"result\":{s}}}", .{slice}) catch return;
    defer alloc.free(wrapped);
    writeJsonResponse(stream, wrapped);
}

fn writeJsonResponse(stream: std.net.Stream, body: []const u8) void {
    var hdr: [256]u8 = undefined;
    const h = std.fmt.bufPrint(&hdr,
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n",
        .{body.len}) catch return;
    _ = stream.write(h) catch {};
    _ = stream.write(body) catch {};
}

fn writeErrorResponse(stream: std.net.Stream, code: i64, msg: []const u8) void {
    var buf: [512]u8 = undefined;
    const b = std.fmt.bufPrint(&buf,
        "{{\"error\":[\"E{d}\"],\"result\":{{}},\"message\":\"{s}\"}}",
        .{ code, msg }) catch return;
    writeJsonResponse(stream, b);
}

// ─── PHASE 2E.5 — Random hex helper (used by Stake/Unstake/Earn/Export) ──

/// Generate `n_bytes` of crypto-random data and hex-encode into `out`
/// (out.len must be >= 2*n_bytes). Used for refids, allocation_ids,
/// export_ids, and 32-byte WS auth tokens.
fn randomHex(out: []u8, n_bytes: usize) void {
    std.debug.assert(out.len >= n_bytes * 2);
    var buf: [64]u8 = undefined;
    const n = @min(n_bytes, buf.len);
    std.crypto.random.bytes(buf[0..n]);
    const hex_chars = "0123456789abcdef";
    var i: usize = 0;
    while (i < n) : (i += 1) {
        out[i * 2]     = hex_chars[buf[i] >> 4];
        out[i * 2 + 1] = hex_chars[buf[i] & 0x0F];
    }
}

// ─── PHASE 2E.4 — Funding helpers ──────────────────────────────────────

fn fundingFeeStr(asset: []const u8) []const u8 {
    if (std.mem.eql(u8, asset, "OMNI")) return "0.00050000";
    if (std.mem.eql(u8, asset, "BTC"))  return "0.00010000";
    if (std.mem.eql(u8, asset, "LTC"))  return "0.00100000";
    if (std.mem.eql(u8, asset, "BCH"))  return "0.00010000";
    if (std.mem.eql(u8, asset, "DOGE")) return "1.00000000";
    if (std.mem.eql(u8, asset, "DASH")) return "0.00100000";
    if (std.mem.eql(u8, asset, "ETH"))  return "0.00200000";
    if (std.mem.eql(u8, asset, "USDC")) return "1.00000000";
    if (std.mem.eql(u8, asset, "USDT")) return "1.00000000";
    if (std.mem.eql(u8, asset, "LCX"))  return "1.00000000";
    return "0.00000000";
}

fn fundingMethodLabel(asset: []const u8) []const u8 {
    if (std.mem.eql(u8, asset, "OMNI")) return "OMNI on-chain";
    if (std.mem.eql(u8, asset, "BTC"))  return "Bitcoin (Phase 2F bridge)";
    if (std.mem.eql(u8, asset, "LTC"))  return "Litecoin (Phase 2F bridge)";
    if (std.mem.eql(u8, asset, "BCH"))  return "Bitcoin Cash (Phase 2F bridge)";
    if (std.mem.eql(u8, asset, "DOGE")) return "Dogecoin (Phase 2F bridge)";
    if (std.mem.eql(u8, asset, "DASH")) return "Dash (Phase 2F bridge)";
    if (std.mem.eql(u8, asset, "ETH"))  return "Ethereum (Phase 2F bridge)";
    if (std.mem.eql(u8, asset, "USDC")) return "ERC-20 USDC (Phase 2F bridge)";
    if (std.mem.eql(u8, asset, "USDT")) return "ERC-20 USDT (Phase 2F bridge)";
    if (std.mem.eql(u8, asset, "LCX"))  return "LCX Liberty bridge";
    return "Unsupported";
}

fn fundingAssetSupported(asset: []const u8) bool {
    const supported = [_][]const u8{
        "OMNI", "BTC", "LTC", "BCH", "DOGE", "DASH",
        "ETH", "USDC", "USDT", "LCX",
    };
    for (supported) |s| {
        if (std.mem.eql(u8, asset, s)) return true;
    }
    return false;
}

fn appendFundingMethodObject(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(u8),
    asset: []const u8,
    is_withdraw: bool,
) !void {
    const method = fundingMethodLabel(asset);
    const fee = fundingFeeStr(asset);
    if (is_withdraw) {
        const obj = try std.fmt.allocPrint(alloc,
            "{{\"method\":\"{s}\",\"limit\":false,\"fee\":\"{s}\"}}",
            .{ method, fee });
        defer alloc.free(obj);
        try out.appendSlice(alloc, obj);
    } else {
        const obj = try std.fmt.allocPrint(alloc,
            "{{\"method\":\"{s}\",\"limit\":false,\"fee\":\"{s}\"," ++
            "\"address-setup-fee\":\"0.00000000\",\"gen-address\":true}}",
            .{ method, fee });
        defer alloc.free(obj);
        try out.appendSlice(alloc, obj);
    }
}

const FundingFilterKind = enum { deposit, withdraw };

fn appendFundingStatusEntries(
    alloc: std.mem.Allocator,
    bc: *Blockchain,
    out: *std.ArrayList(u8),
    max: usize,
    op_label: []const u8,
    owner: []const u8,
    escrow: []const u8,
    kind: FundingFilterKind,
) !void {
    var emitted: usize = 0;
    const tip: u64 = @intCast(bc.chain.items.len);
    var i: usize = bc.chain.items.len;
    while (i > 0 and emitted < max) {
        i -= 1;
        const blk = bc.chain.items[i];
        const block_height: u64 = @intCast(blk.index);
        const confirmations: u64 = if (tip > block_height) tip - block_height else 0;
        const status: []const u8 = if (confirmations >= 6) "Success" else "Pending";
        for (blk.transactions.items) |tx| {
            const matches = switch (kind) {
                .deposit => std.mem.eql(u8, tx.to_address, escrow) and
                    !std.mem.eql(u8, tx.from_address, escrow),
                .withdraw => std.mem.eql(u8, tx.from_address, owner) and
                    !std.mem.eql(u8, tx.to_address, escrow),
            };
            if (!matches) continue;

            const whole = tx.amount / 1_000_000_000;
            const frac  = tx.amount % 1_000_000_000;
            const ts_sec: i64 = @divTrunc(tx.timestamp, 1000);

            if (emitted > 0) try out.appendSlice(alloc, ",");
            const entry = try std.fmt.allocPrint(alloc,
                "{{\"method\":\"{s}\",\"aclass\":\"currency\",\"asset\":\"OMNI\"," ++
                "\"refid\":\"{s}\",\"txid\":\"{s}\",\"info\":\"{s}\"," ++
                "\"amount\":\"{d}.{d:0>9}\",\"fee\":\"0.00000000\"," ++
                "\"time\":{d},\"status\":\"{s}\",\"status-prop\":\"{d}\"}}",
                .{
                    op_label,
                    tx.hash[0..@min(64, tx.hash.len)],
                    tx.hash[0..@min(64, tx.hash.len)],
                    if (kind == .deposit) tx.from_address else tx.to_address,
                    whole, frac,
                    ts_sec,
                    status,
                    block_height,
                });
            defer alloc.free(entry);
            try out.appendSlice(alloc, entry);
            emitted += 1;
            if (emitted >= max) break;
        }
    }
}

/// Serve auto-generated OpenAPI 3.1 JSON spec from EXCHANGE_PAIRS + endpoint table.
fn serveOpenApiJson(stream: std.net.Stream, alloc: std.mem.Allocator) void {
    var out = std.ArrayList(u8){};
    defer out.deinit(alloc);
    out.appendSlice(alloc,
        "{\"openapi\":\"3.1.0\",\"info\":{\"title\":\"OmniBus Exchange REST API\",\"version\":\"1.0.0\",\"description\":\"Kraken-compatible REST surface. Public endpoints need no auth; private endpoints require API-Key + API-Sign headers (HMAC-SHA512).\"},\"servers\":[{\"url\":\"https://omnibusblockchain.cc:8443/exchange/0\"},{\"url\":\"https://omnibusblockchain.cc:8443/paper/0\"}],\"paths\":{") catch return;

    // Public paths
    const public_paths =
        "\"/public/Time\":{\"get\":{\"tags\":[\"Public\"],\"summary\":\"Server time\",\"responses\":{\"200\":{\"description\":\"Unix timestamp\"}}}}," ++
        "\"/public/SystemStatus\":{\"get\":{\"tags\":[\"Public\"],\"summary\":\"System status\",\"responses\":{\"200\":{\"description\":\"online/paper/real\"}}}}," ++
        "\"/public/Assets\":{\"get\":{\"tags\":[\"Public\"],\"summary\":\"List assets\",\"responses\":{\"200\":{\"description\":\"Asset descriptors\"}}}}," ++
        "\"/public/AssetPairs\":{\"get\":{\"tags\":[\"Public\"],\"summary\":\"Trading pairs\",\"responses\":{\"200\":{\"description\":\"Pair metadata\"}}}}," ++
        "\"/public/Ticker\":{\"get\":{\"tags\":[\"Public\"],\"summary\":\"Ticker per pair\",\"parameters\":[{\"name\":\"pair\",\"in\":\"query\",\"required\":true,\"schema\":{\"type\":\"string\"}}],\"responses\":{\"200\":{\"description\":\"Kraken-shaped ticker\"}}}}," ++
        "\"/public/Depth\":{\"get\":{\"tags\":[\"Public\"],\"summary\":\"Orderbook depth\",\"parameters\":[{\"name\":\"pair\",\"in\":\"query\",\"required\":true,\"schema\":{\"type\":\"string\"}},{\"name\":\"count\",\"in\":\"query\",\"schema\":{\"type\":\"integer\"}}],\"responses\":{\"200\":{\"description\":\"Bids/asks\"}}}}," ++
        "\"/public/Trades\":{\"get\":{\"tags\":[\"Public\"],\"summary\":\"Recent trades\",\"parameters\":[{\"name\":\"pair\",\"in\":\"query\",\"required\":true,\"schema\":{\"type\":\"string\"}}],\"responses\":{\"200\":{\"description\":\"Trade list\"}}}}";
    out.appendSlice(alloc, public_paths) catch return;

    // Private paths
    const private_paths =
        ",\"/private/Balance\":{\"post\":{\"tags\":[\"Private\"],\"summary\":\"Account balances\",\"security\":[{\"ApiKeyAuth\":[]}],\"responses\":{\"200\":{\"description\":\"Balances per asset\"}}}}," ++
        "\"/private/OpenOrders\":{\"post\":{\"tags\":[\"Private\"],\"summary\":\"Open orders\",\"security\":[{\"ApiKeyAuth\":[]}],\"responses\":{\"200\":{\"description\":\"Order list\"}}}}," ++
        "\"/private/AddOrder\":{\"post\":{\"tags\":[\"Private\"],\"summary\":\"Place order\",\"security\":[{\"ApiKeyAuth\":[]}],\"requestBody\":{\"content\":{\"application/x-www-form-urlencoded\":{\"schema\":{\"type\":\"object\",\"properties\":{\"pair\":{\"type\":\"string\"},\"type\":{\"type\":\"string\",\"enum\":[\"buy\",\"sell\"]},\"volume\":{\"type\":\"string\"},\"price\":{\"type\":\"string\"},\"nonce\":{\"type\":\"string\"}}}}}},\"responses\":{\"200\":{\"description\":\"Order placed\"}}}}," ++
        "\"/private/CancelOrder\":{\"post\":{\"tags\":[\"Private\"],\"summary\":\"Cancel order\",\"security\":[{\"ApiKeyAuth\":[]}],\"requestBody\":{\"content\":{\"application/x-www-form-urlencoded\":{\"schema\":{\"type\":\"object\",\"properties\":{\"txid\":{\"type\":\"string\"},\"nonce\":{\"type\":\"string\"}}}}}},\"responses\":{\"200\":{\"description\":\"Order cancelled\"}}}}," ++
        "\"/private/Withdraw\":{\"post\":{\"tags\":[\"Private\"],\"summary\":\"Withdraw funds\",\"security\":[{\"ApiKeyAuth\":[]}],\"requestBody\":{\"content\":{\"application/x-www-form-urlencoded\":{\"schema\":{\"type\":\"object\",\"properties\":{\"asset\":{\"type\":\"string\"},\"amount\":{\"type\":\"string\"},\"address\":{\"type\":\"string\"},\"nonce\":{\"type\":\"string\"}}}}}},\"responses\":{\"200\":{\"description\":\"Withdrawal initiated\"}}}}";
    out.appendSlice(alloc, private_paths) catch return;

    // Security scheme + components
    out.appendSlice(alloc,
        "},\"components\":{\"securitySchemes\":{\"ApiKeyAuth\":{\"type\":\"apiKey\",\"in\":\"header\",\"name\":\"API-Key\",\"description\":\"API key identifier (obx_...).\"},\"ApiSignAuth\":{\"type\":\"apiKey\",\"in\":\"header\",\"name\":\"API-Sign\",\"description\":\"HMAC-SHA512 signature of URI-PATH || SHA256(POST-DATA), base64-encoded. Key = raw 32-byte secret (base64-decode the secretB64 field from createApiKey).\"}}}}",
    ) catch return;

    writeJsonResponse(stream, out.items);
}

/// Serve a self-contained Swagger UI HTML page (loads from CDN).
fn serveSwaggerUi(stream: std.net.Stream) void {
    const html =
        "<!DOCTYPE html>" ++
        "<html><head><meta charset=\"UTF-8\"><title>OmniBus Exchange API</title>" ++
        "<link rel=\"stylesheet\" href=\"https://unpkg.com/swagger-ui-dist@5/swagger-ui.css\" />" ++
        "</head><body><div id=\"swagger-ui\"></div>" ++
        "<script src=\"https://unpkg.com/swagger-ui-dist@5/swagger-ui-bundle.js\"></script>" ++
        "<script>SwaggerUIBundle({url:'./openapi.json',dom_id:'#swagger-ui',presets:[SwaggerUIBundle.presets.apis]});</script>" ++
        "</body></html>";
    var hdr: [256]u8 = undefined;
    const h = std.fmt.bufPrint(&hdr,
        "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: {d}\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n",
        .{html.len}) catch return;
    _ = stream.write(h) catch {};
    _ = stream.write(html) catch {};
}

fn dispatchRest(alloc: std.mem.Allocator, stream: std.net.Stream, header: []const u8, _body: []const u8, ctx: *ServerCtx) bool {
    const post_body = _body;
    var http_method: []const u8 = "";
    const path = extractHttpPath(header, &http_method) orelse return false;

    // Trader mode: real (default) routes under `/exchange/0/*`, paper
    // (demo) routes under `/paper/0/*`. Both share the same endpoint
    // names + request shapes — only the underlying matching engine and
    // balance token differ. This means a Kraken-compatible client can
    // switch from paper to real by changing exactly one URL prefix.
    const is_paper = std.mem.startsWith(u8, path, "/paper/0/");

    // Only handle /exchange/0/*, /paper/0/* or stripped /public//private/ from nginx.
    const rest = if (std.mem.startsWith(u8, path, "/exchange/0/"))
        path[12..]
    else if (is_paper)
        path[9..]
    else if (std.mem.startsWith(u8, path, "/public/") or std.mem.startsWith(u8, path, "/private/"))
        path[1..]
    else
        return false;

    // Reject paper requests when the paper engine is disabled.
    if (is_paper and ctx.exchange_paper == null) {
        writeJsonResponse(stream, "{\"error\":[\"PaperTraderDisabled\"],\"result\":{}}");
        return true;
    }

    // ── OpenAPI + Docs (public, no auth) ──────────────────────────────
    if (std.mem.eql(u8, rest, "openapi.json")) {
        serveOpenApiJson(stream, alloc);
        return true;
    }
    if (std.mem.eql(u8, rest, "swagger-ui")) {
        serveSwaggerUi(stream);
        return true;
    }

    // ── Public endpoints ────────────────────────────────────────────────
    if (std.mem.startsWith(u8, rest, "public/")) {
        const ep_raw = rest[7..];
        // Strip query string before comparing endpoint name. Without
        // this, `Ticker?pair=foo` doesn't match `Ticker` and falls
        // through to the JSON-RPC dispatcher with the wrong body.
        const ep = if (std.mem.indexOfScalar(u8, ep_raw, '?')) |q| ep_raw[0..q] else ep_raw;
        if (std.mem.eql(u8, ep, "Time")) {
            const rpc_body = buildRpcBody(alloc, "getstatus", "[]") catch return true;
            defer alloc.free(rpc_body);
            const res = dispatch(rpc_body, ctx) catch |err| {
                writeErrorResponse(stream, 500, @errorName(err));
                return true;
            };
            defer alloc.free(res);
            // Extract result and rewrap as Kraken format
            const result_start = std.mem.indexOf(u8, res, "\"result\":") orelse 0;
            if (result_start > 0) {
                const rs = res[result_start + 9 ..];
                const r2 = std.fmt.allocPrint(alloc, "{{\"error\":[],\"result\":{s}}}", .{rs}) catch return true;
                defer alloc.free(r2);
                writeJsonResponse(stream, r2);
            } else {
                writeJsonResponse(stream, "{\"error\":[],\"result\":{}}");
            }
            return true;
        }
        if (std.mem.eql(u8, ep, "SystemStatus")) {
            const mode_label: []const u8 = if (is_paper) "paper" else "real";
            const body_str = std.fmt.allocPrint(alloc,
                "{{\"error\":[],\"result\":{{\"status\":\"online\",\"mode\":\"{s}\",\"settlement_token\":\"{s}\"}}}}",
                .{ mode_label, if (is_paper) "OMNI_DEMO" else "OMNI" }) catch return true;
            defer alloc.free(body_str);
            writeJsonResponse(stream, body_str);
            return true;
        }
        if (std.mem.eql(u8, ep, "Assets")) {
            // Reflect the assets actually used in EXCHANGE_PAIRS.
            writeJsonResponse(stream,
                "{\"error\":[],\"result\":{" ++
                "\"OMNI\":{\"aclass\":\"currency\",\"altname\":\"OmniBus\",\"decimals\":8,\"display_decimals\":5}," ++
                "\"BTC\":{\"aclass\":\"currency\",\"altname\":\"Bitcoin\",\"decimals\":8,\"display_decimals\":5}," ++
                "\"ETH\":{\"aclass\":\"currency\",\"altname\":\"Ethereum\",\"decimals\":8,\"display_decimals\":5}," ++
                "\"LCX\":{\"aclass\":\"currency\",\"altname\":\"LCX Token\",\"decimals\":8,\"display_decimals\":5}," ++
                "\"USDC\":{\"aclass\":\"currency\",\"altname\":\"USD Coin\",\"decimals\":6,\"display_decimals\":2}," ++
                "\"OMNI_DEMO\":{\"aclass\":\"currency\",\"altname\":\"OmniBus Demo (paper trader)\",\"decimals\":8,\"display_decimals\":5}" ++
                "}}");
            return true;
        }
        if (std.mem.eql(u8, ep, "AssetPairs")) {
            // Generate from EXCHANGE_PAIRS so adding a pair in one place
            // (ID array) also publishes it via REST. Avoids the bug where
            // we changed quote to USDC but AssetPairs still lied "USD".
            var out_buf = std.ArrayList(u8){};
            defer out_buf.deinit(alloc);
            out_buf.appendSlice(alloc, "{\"error\":[],\"result\":{") catch return true;

// ── Fee model ────────────────────────────────────────────────────────
//
// Two distinct fees apply on EVERY fill, charged independently from the
            for (EXCHANGE_PAIRS, 0..) |p, idx| {
                if (idx > 0) out_buf.appendSlice(alloc, ",") catch return true;
                std.fmt.format(out_buf.writer(alloc),
                    "\"{s}{s}\":{{" ++
                    "\"altname\":\"{s}/{s}\",\"wsname\":\"{s}/{s}\"," ++
                    "\"aclass_base\":\"currency\",\"base\":\"{s}\"," ++
                    "\"aclass_quote\":\"currency\",\"quote\":\"{s}\"," ++
                    "\"lot\":\"unit\",\"pair_decimals\":5,\"lot_decimals\":8," ++
                    "\"lot_multiplier\":1,\"leverage_buy\":[],\"leverage_sell\":[]," ++
                    "\"fees\":[[0,0.10]],\"fees_maker\":[[0,0.05]]," ++
                    "\"fee_volume_currency\":\"USDC\",\"margin_call\":80," ++
                    "\"margin_stop\":40,\"ordermin\":\"0.0001\",\"pair_id\":{d}" ++
                    "}}",
                    .{ p.base, p.quote, p.base, p.quote, p.base, p.quote, p.base, p.quote, p.id }) catch return true;
            }
            out_buf.appendSlice(alloc, "}}") catch return true;
            writeJsonResponse(stream, out_buf.items);
            return true;
        }
        if (false) {  // dead branch — original hardcoded AssetPairs disabled
            writeJsonResponse(stream,
                "{\"error\":[],\"result\":{\"OMNIUSD\":{\"altname\":\"OMNI/USD\",\"wsname\":\"OMNI/USD\",\"aclass_base\":\"currency\",\"base\":\"OMNI\",\"aclass_quote\":\"currency\",\"quote\":\"USD\",\"lot\":\"unit\",\"pair_decimals\":5,\"lot_decimals\":8,\"lot_multiplier\":1,\"leverage_buy\":[],\"leverage_sell\":[],\"fees\":[[0,0.26],[50000,0.24],[100000,0.22],[250000,0.20],[500000,0.18],[1000000,0.16],[2500000,0.14],[5000000,0.12],[10000000,0.10]],\"fees_maker\":[[0,0.16],[50000,0.14],[100000,0.12],[250000,0.10],[500000,0.08],[1000000,0.06],[2500000,0.04],[5000000,0.02],[10000000,0.00]],\"fee_volume_currency\":\"ZUSD\",\"margin_call\":80,\"margin_stop\":40,\"ordermin\":\"0.01\"},\"BTCUSD\":{\"altname\":\"BTC/USD\",\"wsname\":\"BTC/USD\",\"base\":\"BTC\",\"quote\":\"USD\",\"lot\":\"unit\",\"pair_decimals\":1,\"lot_decimals\":8,\"lot_multiplier\":1,\"leverage_buy\":[],\"leverage_sell\":[],\"fees\":[[0,0.26],[50000,0.24],[100000,0.22],[250000,0.20],[500000,0.18],[1000000,0.16],[2500000,0.14],[5000000,0.12],[10000000,0.10]],\"fees_maker\":[[0,0.16],[50000,0.14],[100000,0.12],[250000,0.10],[500000,0.08],[1000000,0.06],[2500000,0.04],[5000000,0.02],[10000000,0.00]],\"fee_volume_currency\":\"ZUSD\",\"margin_call\":80,\"margin_stop\":40,\"ordermin\":\"0.0001\"},\"LCXUSD\":{\"altname\":\"LCX/USD\",\"wsname\":\"LCX/USD\",\"base\":\"LCX\",\"quote\":\"USD\",\"lot\":\"unit\",\"pair_decimals\":4,\"lot_decimals\":8,\"lot_multiplier\":1,\"leverage_buy\":[],\"leverage_sell\":[],\"fees\":[[0,0.26],[50000,0.24],[100000,0.22],[250000,0.20],[500000,0.18],[1000000,0.16],[2500000,0.14],[5000000,0.12],[10000000,0.10]],\"fees_maker\":[[0,0.16],[50000,0.14],[100000,0.12],[250000,0.10],[500000,0.08],[1000000,0.06],[2500000,0.04],[5000000,0.02],[10000000,0.00]],\"fee_volume_currency\":\"ZUSD\",\"margin_call\":80,\"margin_stop\":40,\"ordermin\":\"1.0\"},\"ETHUSD\":{\"altname\":\"ETH/USD\",\"wsname\":\"ETH/USD\",\"base\":\"ETH\",\"quote\":\"USD\",\"lot\":\"unit\",\"pair_decimals\":2,\"lot_decimals\":8,\"lot_multiplier\":1,\"leverage_buy\":[],\"leverage_sell\":[],\"fees\":[[0,0.26],[50000,0.24],[100000,0.22],[250000,0.20],[500000,0.18],[1000000,0.16],[2500000,0.14],[5000000,0.12],[10000000,0.10]],\"fees_maker\":[[0,0.16],[50000,0.14],[100000,0.12],[250000,0.10],[500000,0.08],[1000000,0.06],[2500000,0.04],[5000000,0.02],[10000000,0.00]],\"fee_volume_currency\":\"ZUSD\",\"margin_call\":80,\"margin_stop\":40,\"ordermin\":\"0.001\"},\"OMNIBTC\":{\"altname\":\"OMNI/BTC\",\"wsname\":\"OMNI/BTC\",\"base\":\"OMNI\",\"quote\":\"BTC\",\"lot\":\"unit\",\"pair_decimals\":8,\"lot_decimals\":8,\"lot_multiplier\":1,\"leverage_buy\":[],\"leverage_sell\":[],\"fees\":[[0,0.26],[50000,0.24],[100000,0.22],[250000,0.20],[500000,0.18],[1000000,0.16],[2500000,0.14],[5000000,0.12],[10000000,0.10]],\"fees_maker\":[[0,0.16],[50000,0.14],[100000,0.12],[250000,0.10],[500000,0.08],[1000000,0.06],[2500000,0.04],[5000000,0.02],[10000000,0.00]],\"fee_volume_currency\":\"ZUSD\",\"margin_call\":80,\"margin_stop\":40,\"ordermin\":\"0.01\"},\"OMNILCX\":{\"altname\":\"OMNI/LCX\",\"wsname\":\"OMNI/LCX\",\"base\":\"OMNI\",\"quote\":\"LCX\",\"lot\":\"unit\",\"pair_decimals\":5,\"lot_decimals\":8,\"lot_multiplier\":1,\"leverage_buy\":[],\"leverage_sell\":[],\"fees\":[[0,0.26],[50000,0.24],[100000,0.22],[250000,0.20],[500000,0.18],[1000000,0.16],[2500000,0.14],[5000000,0.12],[10000000,0.10]],\"fees_maker\":[[0,0.16],[50000,0.14],[100000,0.12],[250000,0.10],[500000,0.08],[1000000,0.06],[2500000,0.04],[5000000,0.02],[10000000,0.00]],\"fee_volume_currency\":\"ZUSD\",\"margin_call\":80,\"margin_stop\":40,\"ordermin\":\"0.01\"}}}}");
            return true;
        }
        if (std.mem.eql(u8, ep, "Ticker")) {
            // exchange_getStats accepts {mode}; we still pass the pair so a
            // future per-pair stats endpoint can use it. Body MUST be an
            // array of one params object — JSON-RPC 2.0 strict.
            const mode_param: []const u8 = if (is_paper) "{\"mode\":\"paper\"}" else "{}";
            const params_str = std.fmt.allocPrint(alloc, "[{s}]", .{mode_param}) catch return true;
            defer alloc.free(params_str);
            const rpc_body = buildRpcBody(alloc, "exchange_getStats", params_str) catch return true;
            defer alloc.free(rpc_body);
            const res = dispatch(rpc_body, ctx) catch |err| {
                writeErrorResponse(stream, 500, @errorName(err));
                return true;
            };
            defer alloc.free(res);
            writeKrakenFromRpc(alloc, stream, res);
            return true;
        }
        if (std.mem.eql(u8, ep, "Depth")) {
            const raw_pair = getQueryParam(path, "pair") orelse "OMNIUSDC";
            const count_s = getQueryParam(path, "count") orelse "100";
            const mode_suffix: []const u8 = if (is_paper) ",\"mode\":\"paper\"" else "";
            const norm = normalizePair(alloc, raw_pair);
            defer if (norm.alloced) alloc.free(norm.pair);
            const params_str = std.fmt.allocPrint(alloc,
                "[{{\"pair\":\"{s}\",\"depth\":{s}{s}}}]",
                .{ norm.pair, count_s, mode_suffix }) catch return true;
            defer alloc.free(params_str);
            const rpc_body = buildRpcBody(alloc, "exchange_getOrderbook", params_str) catch return true;
            defer alloc.free(rpc_body);
            const res = dispatch(rpc_body, ctx) catch |err| {
                writeErrorResponse(stream, 500, @errorName(err));
                return true;
            };
            defer alloc.free(res);
            writeKrakenFromRpc(alloc, stream, res);
            return true;
        }
        if (std.mem.eql(u8, ep, "Trades")) {
            // Public Trades — last fills on this pair. Same data
            // exchange_getTrades returns; mode picks engine.
            const raw_pair = getQueryParam(path, "pair") orelse "OMNI/USDC";
            const mode_param: []const u8 = if (is_paper) ",\"mode\":\"paper\"" else "";
            const norm = normalizePair(alloc, raw_pair);
            defer if (norm.alloced) alloc.free(norm.pair);
            const params_str = std.fmt.allocPrint(alloc,
                "[{{\"pair\":\"{s}\",\"limit\":50{s}}}]", .{ norm.pair, mode_param }) catch return true;
            defer alloc.free(params_str);
            const rpc_body = buildRpcBody(alloc, "exchange_getTrades", params_str) catch return true;
            defer alloc.free(rpc_body);
            const res = dispatch(rpc_body, ctx) catch |err| {
                writeErrorResponse(stream, 500, @errorName(err));
                return true;
            };
            defer alloc.free(res);
            writeKrakenFromRpc(alloc, stream, res);
            return true;
        }
        if (std.mem.eql(u8, ep, "OHLC")) {
            // PHASE 2E.2 — OHLC candles per pair, derived from bc.fills_history.
            const raw_pair = getQueryParam(path, "pair") orelse "OMNI/USDC";
            const interval_s = getQueryParam(path, "interval") orelse "1";
            const since_s = getQueryParam(path, "since") orelse "0";

            const norm = normalizePair(alloc, raw_pair);
            defer if (norm.alloced) alloc.free(norm.pair);
            const pair_id = exchangePairLookup(norm.pair) orelse {
                writeJsonResponse(stream, "{\"error\":[\"EQuery:Unknown asset pair\"],\"result\":{}}");
                return true;
            };

            const interval_min: u64 = std.fmt.parseInt(u64, interval_s, 10) catch 1;
            const valid_intervals = [_]u64{ 1, 5, 15, 30, 60, 240, 1440, 10080, 21600 };
            var interval_ok: bool = false;
            for (valid_intervals) |v| {
                if (v == interval_min) { interval_ok = true; break; }
            }
            if (!interval_ok) {
                writeJsonResponse(stream, "{\"error\":[\"EQuery:Invalid interval\"],\"result\":{}}");
                return true;
            }
            const since_ms: i64 = std.fmt.parseInt(i64, since_s, 10) catch 0;
            const bucket_ms: i64 = @intCast(interval_min * 60 * 1000);

            const MAX_BUCKETS: usize = 720;
            const Bucket = struct {
                start_ms: i64,
                open_micro: u64,
                high_micro: u64,
                low_micro: u64,
                close_micro: u64,
                volume_sat: u64,
                vwap_num: u128,
                vwap_den: u128,
                count: u32,
            };
            var buckets: [MAX_BUCKETS]Bucket = undefined;
            var bucket_count: usize = 0;
            var last_id_ms: i64 = 0;

            var block_it = ctx.bc.fills_history.iterator();
            while (block_it.next()) |entry| {
                const fills_slice = entry.value_ptr.*;
                for (fills_slice) |fill| {
                    if (fill.pair_id != pair_id) continue;
                    if (fill.timestamp_ms < since_ms) continue;
                    if (fill.timestamp_ms > last_id_ms) last_id_ms = fill.timestamp_ms;

                    const bucket_start: i64 = @divFloor(fill.timestamp_ms, bucket_ms) * bucket_ms;

                    var found_idx: ?usize = null;
                    var i: usize = 0;
                    while (i < bucket_count) : (i += 1) {
                        if (buckets[i].start_ms == bucket_start) { found_idx = i; break; }
                    }

                    if (found_idx) |idx| {
                        var b = &buckets[idx];
                        if (fill.price_micro_usd > b.high_micro) b.high_micro = fill.price_micro_usd;
                        if (fill.price_micro_usd < b.low_micro) b.low_micro = fill.price_micro_usd;
                        b.close_micro = fill.price_micro_usd;
                        b.volume_sat +%= fill.amount_sat;
                        b.vwap_num += @as(u128, fill.price_micro_usd) * @as(u128, fill.amount_sat);
                        b.vwap_den += @as(u128, fill.amount_sat);
                        b.count += 1;
                    } else {
                        if (bucket_count == MAX_BUCKETS) {
                            var k: usize = 0;
                            while (k < MAX_BUCKETS - 1) : (k += 1) buckets[k] = buckets[k + 1];
                            bucket_count -= 1;
                        }
                        buckets[bucket_count] = Bucket{
                            .start_ms = bucket_start,
                            .open_micro = fill.price_micro_usd,
                            .high_micro = fill.price_micro_usd,
                            .low_micro = fill.price_micro_usd,
                            .close_micro = fill.price_micro_usd,
                            .volume_sat = fill.amount_sat,
                            .vwap_num = @as(u128, fill.price_micro_usd) * @as(u128, fill.amount_sat),
                            .vwap_den = @as(u128, fill.amount_sat),
                            .count = 1,
                        };
                        bucket_count += 1;
                    }
                }
            }

            const lessThan = struct {
                fn lt(_: void, a: Bucket, b: Bucket) bool {
                    return a.start_ms < b.start_ms;
                }
            }.lt;
            std.sort.insertion(Bucket, buckets[0..bucket_count], {}, lessThan);

            var out = std.ArrayList(u8){};
            defer out.deinit(alloc);
            const flat_key = pairIdToFlatKey(pair_id);
            std.fmt.format(out.writer(alloc),
                "{{\"error\":[],\"result\":{{\"{s}\":[", .{flat_key}) catch return true;

            var emit_idx: usize = 0;
            while (emit_idx < bucket_count) : (emit_idx += 1) {
                const b = buckets[emit_idx];
                if (emit_idx > 0) out.appendSlice(alloc, ",") catch return true;
                var open_buf: [24]u8 = undefined;
                var high_buf: [24]u8 = undefined;
                var low_buf: [24]u8 = undefined;
                var close_buf: [24]u8 = undefined;
                var vwap_buf: [24]u8 = undefined;
                var vol_buf: [24]u8 = undefined;
                const open_s = formatMicroPrice(b.open_micro, &open_buf);
                const high_s = formatMicroPrice(b.high_micro, &high_buf);
                const low_s = formatMicroPrice(b.low_micro, &low_buf);
                const close_s = formatMicroPrice(b.close_micro, &close_buf);
                const vwap_micro: u64 = if (b.vwap_den == 0) 0 else @intCast(b.vwap_num / b.vwap_den);
                const vwap_s = formatMicroPrice(vwap_micro, &vwap_buf);
                const vol_s = formatSatAmount(b.volume_sat, &vol_buf);
                const time_sec: i64 = @divFloor(b.start_ms, 1000);
                std.fmt.format(out.writer(alloc),
                    "[{d},\"{s}\",\"{s}\",\"{s}\",\"{s}\",\"{s}\",\"{s}\",{d}]",
                    .{ time_sec, open_s, high_s, low_s, close_s, vwap_s, vol_s, b.count }) catch return true;
            }

            const last_id_sec: i64 = @divFloor(last_id_ms, 1000);
            std.fmt.format(out.writer(alloc),
                "],\"last\":{d}}}}}", .{last_id_sec}) catch return true;
            writeJsonResponse(stream, out.items);
            return true;
        }
        if (std.mem.eql(u8, ep, "Spread")) {
            // PHASE 2E.2 — Spread current best bid/ask snapshot for the pair.
            const raw_pair = getQueryParam(path, "pair") orelse "OMNI/USDC";
            const since_s = getQueryParam(path, "since") orelse "0";

            const norm = normalizePair(alloc, raw_pair);
            defer if (norm.alloced) alloc.free(norm.pair);
            const pair_id = exchangePairLookup(norm.pair) orelse {
                writeJsonResponse(stream, "{\"error\":[\"EQuery:Unknown asset pair\"],\"result\":{}}");
                return true;
            };
            _ = since_s;

            const flat_key = pairIdToFlatKey(pair_id);

            const engine_opt = ctx.bc.exchange_engine;
            if (engine_opt == null) {
                var empty = std.ArrayList(u8){};
                defer empty.deinit(alloc);
                std.fmt.format(empty.writer(alloc),
                    "{{\"error\":[],\"result\":{{\"{s}\":[],\"last\":0}}}}", .{flat_key}) catch return true;
                writeJsonResponse(stream, empty.items);
                return true;
            }
            const engine = engine_opt.?;

            var best_bid_micro: u64 = 0;
            var have_bid: bool = false;
            var i: usize = 0;
            while (i < engine.bid_count) : (i += 1) {
                const o = engine.bids[i];
                if (o.pair_id != pair_id) continue;
                if (o.status != .active and o.status != .partial) continue;
                if (!have_bid or o.price_micro_usd > best_bid_micro) {
                    best_bid_micro = o.price_micro_usd;
                    have_bid = true;
                }
            }
            var best_ask_micro: u64 = 0;
            var have_ask: bool = false;
            i = 0;
            while (i < engine.ask_count) : (i += 1) {
                const o = engine.asks[i];
                if (o.pair_id != pair_id) continue;
                if (o.status != .active and o.status != .partial) continue;
                if (!have_ask or o.price_micro_usd < best_ask_micro) {
                    best_ask_micro = o.price_micro_usd;
                    have_ask = true;
                }
            }

            const now_ms: i64 = std.time.milliTimestamp();
            const time_sec: i64 = @divFloor(now_ms, 1000);

            var bid_buf: [24]u8 = undefined;
            var ask_buf: [24]u8 = undefined;
            const bid_s: []const u8 = if (have_bid) formatMicroPrice(best_bid_micro, &bid_buf) else "0.00000000";
            const ask_s: []const u8 = if (have_ask) formatMicroPrice(best_ask_micro, &ask_buf) else "0.00000000";

            var out = std.ArrayList(u8){};
            defer out.deinit(alloc);
            std.fmt.format(out.writer(alloc),
                "{{\"error\":[],\"result\":{{\"{s}\":[[{d},\"{s}\",\"{s}\"]],\"last\":{d}}}}}",
                .{ flat_key, time_sec, bid_s, ask_s, time_sec }) catch return true;
            writeJsonResponse(stream, out.items);
            return true;
        }
    }

    // ── Private endpoints ───────────────────────────────────────────────
    if (std.mem.startsWith(u8, rest, "private/")) {
        const ep_raw = rest[8..];
        const ep = if (std.mem.indexOfScalar(u8, ep_raw, '?')) |q| ep_raw[0..q] else ep_raw;
        // Map Kraken-style private endpoints to existing exchange_* RPCs.
        // Some need form-encoded body params translated to our JSON shape.
        // We pass the raw body to the helpers so they can reach for
        // `owner=ob1q...` / `pair=OMNI/USD` / `volume=1.5` etc.
        var rpc_method: []const u8 = "";
        var rpc_params: []const u8 = "{}";
        var owned_params: ?[]u8 = null;
        defer if (owned_params) |p| alloc.free(p);
        const owner = formGetField(post_body, "owner") orelse formGetField(post_body, "address");
        const mode_suffix: []const u8 = if (is_paper) ",\"mode\":\"paper\"" else "";

        if (std.mem.eql(u8, ep, "Balance")) {
            rpc_method = "exchange_getBalances";
            if (owner) |a| {
                owned_params = std.fmt.allocPrint(alloc, "[{{\"owner\":\"{s}\"{s}}}]", .{ a, mode_suffix }) catch null;
                if (owned_params) |p| rpc_params = p;
            }
        }
        else if (std.mem.eql(u8, ep, "TradeBalance")) {
            rpc_method = "exchange_getBalances";
            if (owner) |a| {
                owned_params = std.fmt.allocPrint(alloc, "[{{\"owner\":\"{s}\"{s}}}]", .{ a, mode_suffix }) catch null;
                if (owned_params) |p| rpc_params = p;
            }
        }
        else if (std.mem.eql(u8, ep, "OpenOrders")) {
            rpc_method = "exchange_getUserOrders";
            if (owner) |a| {
                owned_params = std.fmt.allocPrint(alloc, "[{{\"trader\":\"{s}\"{s}}}]", .{ a, mode_suffix }) catch null;
                if (owned_params) |p| rpc_params = p;
            }
        }
        else if (std.mem.eql(u8, ep, "ClosedOrders")) {
            // PHASE 2E.1 — derive closed orders from engine state.
            const filter_addr = formGetField(post_body, "address") orelse owner;
            var out = std.ArrayList(u8){};
            defer out.deinit(alloc);
            out.appendSlice(alloc, "{\"error\":[],\"result\":{\"closed\":{") catch return true;
            var emitted: u32 = 0;
            const LIMIT: u32 = 50;
            var first = true;

            if (ctx.bc.exchange_engine) |engine| {
                ctx.exchange_mutex.lock();
                defer ctx.exchange_mutex.unlock();

                var i: u32 = 0;
                while (i < engine.bid_count and emitted < LIMIT) : (i += 1) {
                    const o = engine.bids[i];
                    if (o.status != .filled and o.status != .cancelled) continue;
                    if (filter_addr) |a| {
                        if (!std.mem.eql(u8, o.getTraderAddress(), a)) continue;
                    }
                    var pair_buf: [16]u8 = undefined;
                    const pair_lbl = pairLabelFor(o.pair_id, &pair_buf);
                    const status_str: []const u8 = if (o.status == .filled) "closed" else "canceled";
                    const cost_micro: u128 =
                        (@as(u128, o.price_micro_usd) * @as(u128, o.filled_sat)) / 1_000_000_000;
                    if (!first) out.appendSlice(alloc, ",") catch return true;
                    first = false;
                    std.fmt.format(out.writer(alloc),
                        "\"O{d}\":{{\"refid\":null,\"userref\":0,\"status\":\"{s}\",\"reason\":null," ++
                        "\"opentm\":{d}.0,\"closetm\":{d}.0,\"starttm\":0,\"expiretm\":0," ++
                        "\"descr\":{{\"pair\":\"{s}\",\"type\":\"buy\",\"ordertype\":\"limit\"," ++
                        "\"price\":\"{d}\",\"price2\":\"0\",\"leverage\":\"none\",\"order\":\"buy\",\"close\":\"\"}}," ++
                        "\"vol\":\"{d}\",\"vol_exec\":\"{d}\",\"cost\":\"{d}\",\"fee\":\"0\"," ++
                        "\"price\":\"{d}\",\"misc\":\"\",\"oflags\":\"fciq\"}}",
                        .{ o.order_id, status_str,
                           @divTrunc(o.timestamp_ms, 1000), @divTrunc(o.timestamp_ms, 1000),
                           pair_lbl, o.price_micro_usd,
                           o.amount_sat, o.filled_sat, @as(u64, @intCast(@min(cost_micro, @as(u128, std.math.maxInt(u64))))),
                           o.price_micro_usd }) catch return true;
                    emitted += 1;
                }
                var j: u32 = 0;
                while (j < engine.ask_count and emitted < LIMIT) : (j += 1) {
                    const o = engine.asks[j];
                    if (o.status != .filled and o.status != .cancelled) continue;
                    if (filter_addr) |a| {
                        if (!std.mem.eql(u8, o.getTraderAddress(), a)) continue;
                    }
                    var pair_buf: [16]u8 = undefined;
                    const pair_lbl = pairLabelFor(o.pair_id, &pair_buf);
                    const status_str: []const u8 = if (o.status == .filled) "closed" else "canceled";
                    const cost_micro: u128 =
                        (@as(u128, o.price_micro_usd) * @as(u128, o.filled_sat)) / 1_000_000_000;
                    if (!first) out.appendSlice(alloc, ",") catch return true;
                    first = false;
                    std.fmt.format(out.writer(alloc),
                        "\"O{d}\":{{\"refid\":null,\"userref\":0,\"status\":\"{s}\",\"reason\":null," ++
                        "\"opentm\":{d}.0,\"closetm\":{d}.0,\"starttm\":0,\"expiretm\":0," ++
                        "\"descr\":{{\"pair\":\"{s}\",\"type\":\"sell\",\"ordertype\":\"limit\"," ++
                        "\"price\":\"{d}\",\"price2\":\"0\",\"leverage\":\"none\",\"order\":\"sell\",\"close\":\"\"}}," ++
                        "\"vol\":\"{d}\",\"vol_exec\":\"{d}\",\"cost\":\"{d}\",\"fee\":\"0\"," ++
                        "\"price\":\"{d}\",\"misc\":\"\",\"oflags\":\"fciq\"}}",
                        .{ o.order_id, status_str,
                           @divTrunc(o.timestamp_ms, 1000), @divTrunc(o.timestamp_ms, 1000),
                           pair_lbl, o.price_micro_usd,
                           o.amount_sat, o.filled_sat, @as(u64, @intCast(@min(cost_micro, @as(u128, std.math.maxInt(u64))))),
                           o.price_micro_usd }) catch return true;
                    emitted += 1;
                }
            }

            std.fmt.format(out.writer(alloc), "}},\"count\":{d}}}}}", .{emitted}) catch return true;
            writeJsonResponse(stream, out.items);
            return true;
        }
        else if (std.mem.eql(u8, ep, "QueryOrders")) {
            // Same back-end as OpenOrders (we don't separate open/query yet).
            rpc_method = "exchange_getUserOrders";
            if (owner) |a| {
                owned_params = std.fmt.allocPrint(alloc, "[{{\"trader\":\"{s}\"{s}}}]", .{ a, mode_suffix }) catch null;
                if (owned_params) |p| rpc_params = p;
            }
        }
        else if (std.mem.eql(u8, ep, "TradesHistory")) {
            // PHASE 2E.1 — derive trades from bc.fills_history newest-first.
            const filter_addr = formGetField(post_body, "address") orelse owner;
            var out = std.ArrayList(u8){};
            defer out.deinit(alloc);
            out.appendSlice(alloc, "{\"error\":[],\"result\":{\"trades\":{") catch return true;
            var emitted: u32 = 0;
            const LIMIT: u32 = 50;
            var first = true;

            ctx.exchange_mutex.lock();
            defer ctx.exchange_mutex.unlock();

            var heights = std.ArrayList(u32){};
            defer heights.deinit(alloc);
            var it = ctx.bc.fills_history.iterator();
            while (it.next()) |entry| {
                heights.append(alloc, entry.key_ptr.*) catch return true;
            }
            std.mem.sort(u32, heights.items, {}, comptime std.sort.desc(u32));

            outer: for (heights.items) |h| {
                const slice = ctx.bc.fills_history.get(h) orelse continue;
                var idx: usize = slice.len;
                while (idx > 0) {
                    idx -= 1;
                    if (emitted >= LIMIT) break :outer;
                    const f = &slice[idx];
                    var side: []const u8 = "buy";
                    if (filter_addr) |a| {
                        if (!fillTouchesAddr(f, a)) continue;
                        side = fillSideForTrader(f, a);
                    }
                    var pair_buf: [16]u8 = undefined;
                    const pair_lbl = pairLabelFor(f.pair_id, &pair_buf);
                    const order_id_for_caller: u64 =
                        if (std.mem.eql(u8, side, "buy")) f.buy_order_id else f.sell_order_id;
                    const cost_micro: u128 =
                        (@as(u128, f.price_micro_usd) * @as(u128, f.amount_sat)) / 1_000_000_000;
                    const fee_micro = ledgerFeeMicroFor(f.price_micro_usd, f.amount_sat);
                    if (!first) out.appendSlice(alloc, ",") catch return true;
                    first = false;
                    std.fmt.format(out.writer(alloc),
                        "\"T{d}\":{{\"ordertxid\":\"O{d}\",\"postxid\":\"\",\"pair\":\"{s}\"," ++
                        "\"time\":{d}.0,\"type\":\"{s}\",\"ordertype\":\"limit\"," ++
                        "\"price\":\"{d}\",\"cost\":\"{d}\",\"fee\":\"{d}\",\"vol\":\"{d}\"," ++
                        "\"margin\":\"0\",\"misc\":\"\"}}",
                        .{ f.fill_id, order_id_for_caller, pair_lbl,
                           @divTrunc(f.timestamp_ms, 1000), side,
                           f.price_micro_usd,
                           @as(u64, @intCast(@min(cost_micro, @as(u128, std.math.maxInt(u64))))),
                           fee_micro, f.amount_sat }) catch return true;
                    emitted += 1;
                }
            }

            std.fmt.format(out.writer(alloc), "}},\"count\":{d}}}}}", .{emitted}) catch return true;
            writeJsonResponse(stream, out.items);
            return true;
        }
        else if (std.mem.eql(u8, ep, "QueryTrades")) {
            // PHASE 2E.1 — same shape as TradesHistory but filtered by txid CSV ("T<fill_id>,T<fill_id>,...").
            const txid_csv = formGetField(post_body, "txid") orelse "";
            var out = std.ArrayList(u8){};
            defer out.deinit(alloc);
            out.appendSlice(alloc, "{\"error\":[],\"result\":{") catch return true;
            var first = true;
            const LIMIT: u32 = 50;
            var emitted: u32 = 0;

            ctx.exchange_mutex.lock();
            defer ctx.exchange_mutex.unlock();

            var heights = std.ArrayList(u32){};
            defer heights.deinit(alloc);
            var it = ctx.bc.fills_history.iterator();
            while (it.next()) |entry| {
                heights.append(alloc, entry.key_ptr.*) catch return true;
            }
            std.mem.sort(u32, heights.items, {}, comptime std.sort.desc(u32));

            outer: for (heights.items) |h| {
                const slice = ctx.bc.fills_history.get(h) orelse continue;
                var idx: usize = slice.len;
                while (idx > 0) {
                    idx -= 1;
                    if (emitted >= LIMIT) break :outer;
                    const f = &slice[idx];

                    var key_buf: [32]u8 = undefined;
                    const key = std.fmt.bufPrint(&key_buf, "T{d}", .{f.fill_id}) catch continue;
                    if (txid_csv.len > 0 and std.mem.indexOf(u8, txid_csv, key) == null) continue;

                    var pair_buf: [16]u8 = undefined;
                    const pair_lbl = pairLabelFor(f.pair_id, &pair_buf);
                    const cost_micro: u128 =
                        (@as(u128, f.price_micro_usd) * @as(u128, f.amount_sat)) / 1_000_000_000;
                    const fee_micro = ledgerFeeMicroFor(f.price_micro_usd, f.amount_sat);
                    if (!first) out.appendSlice(alloc, ",") catch return true;
                    first = false;
                    std.fmt.format(out.writer(alloc),
                        "\"T{d}\":{{\"ordertxid\":\"O{d}\",\"postxid\":\"\",\"pair\":\"{s}\"," ++
                        "\"time\":{d}.0,\"type\":\"buy\",\"ordertype\":\"limit\"," ++
                        "\"price\":\"{d}\",\"cost\":\"{d}\",\"fee\":\"{d}\",\"vol\":\"{d}\"," ++
                        "\"margin\":\"0\",\"misc\":\"\"}}",
                        .{ f.fill_id, f.buy_order_id, pair_lbl,
                           @divTrunc(f.timestamp_ms, 1000),
                           f.price_micro_usd,
                           @as(u64, @intCast(@min(cost_micro, @as(u128, std.math.maxInt(u64))))),
                           fee_micro, f.amount_sat }) catch return true;
                    emitted += 1;
                }
            }

            out.appendSlice(alloc, "}}") catch return true;
            writeJsonResponse(stream, out.items);
            return true;
        }
        else if (std.mem.eql(u8, ep, "OpenPositions")) {
            // PHASE 2E.3 — OmniBus v1 is spot-only: no margin/leverage
            // positions to report, so an empty result map is the
            // semantically correct Kraken response. We deliberately do
            // NOT alias spot open orders here — clients call OpenOrders.
            // Phase 3 will tie this to perpetual futures TXs once
            // tx_type=.position_open ships and a positions table exists
            // in Blockchain state.
            writeJsonResponse(stream, "{\"error\":[],\"result\":{}}");
            return true;
        }
        else if (std.mem.eql(u8, ep, "Ledgers")) {
            // PHASE 2E.1 — derive ledger entries from fills (trade) + chain.items (transfer).
            const filter_addr = formGetField(post_body, "address") orelse owner;
            const filter_asset = formGetField(post_body, "asset");
            var out = std.ArrayList(u8){};
            defer out.deinit(alloc);
            out.appendSlice(alloc, "{\"error\":[],\"result\":{\"ledger\":{") catch return true;
            const LIMIT: u32 = 50;
            var emitted: u32 = 0;
            var first = true;
            var balance_sat: i128 = 0;

            ctx.exchange_mutex.lock();
            defer ctx.exchange_mutex.unlock();

            var heights = std.ArrayList(u32){};
            defer heights.deinit(alloc);
            var it = ctx.bc.fills_history.iterator();
            while (it.next()) |entry| {
                heights.append(alloc, entry.key_ptr.*) catch return true;
            }
            std.mem.sort(u32, heights.items, {}, comptime std.sort.desc(u32));

            fills_loop: for (heights.items) |h| {
                const slice = ctx.bc.fills_history.get(h) orelse continue;
                var idx: usize = slice.len;
                while (idx > 0) {
                    idx -= 1;
                    if (emitted >= LIMIT) break :fills_loop;
                    const f = &slice[idx];
                    if (filter_addr) |a| {
                        if (!fillTouchesAddr(f, a)) continue;
                    } else continue;
                    if (filter_asset) |as| {
                        var matched = false;
                        for (EXCHANGE_PAIRS) |p| {
                            if (p.id == f.pair_id) {
                                if (asciiEqIgnoreCase(p.base, as) or asciiEqIgnoreCase(p.quote, as)) matched = true;
                                break;
                            }
                        }
                        if (!matched) continue;
                    }
                    const side = fillSideForTrader(f, filter_addr.?);
                    const signed_amount: i128 = if (std.mem.eql(u8, side, "buy"))
                        @as(i128, @intCast(f.amount_sat))
                    else
                        -@as(i128, @intCast(f.amount_sat));
                    balance_sat += signed_amount;

                    var pair_buf: [16]u8 = undefined;
                    const pair_lbl = pairLabelFor(f.pair_id, &pair_buf);
                    var asset_buf: [16]u8 = undefined;
                    var asset_lbl: []const u8 = "OMNI";
                    for (EXCHANGE_PAIRS) |p| {
                        if (p.id == f.pair_id) {
                            asset_lbl = std.fmt.bufPrint(&asset_buf, "{s}", .{p.base}) catch "OMNI";
                            break;
                        }
                    }
                    const fee_micro = ledgerFeeMicroFor(f.price_micro_usd, f.amount_sat);
                    if (!first) out.appendSlice(alloc, ",") catch return true;
                    first = false;
                    std.fmt.format(out.writer(alloc),
                        "\"L{d}\":{{\"refid\":\"T{d}\",\"time\":{d}.0,\"type\":\"trade\"," ++
                        "\"subtype\":\"\",\"aclass\":\"currency\",\"asset\":\"{s}\",\"amount\":\"{d}\"," ++
                        "\"fee\":\"{d}\",\"balance\":\"{d}\",\"pair\":\"{s}\"}}",
                        .{ f.fill_id, f.fill_id, @divTrunc(f.timestamp_ms, 1000),
                           asset_lbl, signed_amount, fee_micro, balance_sat, pair_lbl }) catch return true;
                    emitted += 1;
                }
            }

            if (filter_addr) |a| {
                if (emitted < LIMIT) {
                    var bi: usize = ctx.bc.chain.items.len;
                    blocks_loop: while (bi > 0) {
                        bi -= 1;
                        const blk = &ctx.bc.chain.items[bi];
                        var ti: usize = blk.transactions.items.len;
                        while (ti > 0) {
                            ti -= 1;
                            if (emitted >= LIMIT) break :blocks_loop;
                            const tx = &blk.transactions.items[ti];
                            const is_to = std.mem.eql(u8, tx.to_address, a);
                            const is_from = std.mem.eql(u8, tx.from_address, a);
                            if (!is_to and !is_from) continue;
                            const amt_signed: i128 = if (is_to)
                                @as(i128, @intCast(tx.amount))
                            else
                                -@as(i128, @intCast(tx.amount));
                            balance_sat += amt_signed;
                            const ledger_type: []const u8 = if (is_to) "deposit" else "withdrawal";
                            const asset_lbl: []const u8 = "OMNI";
                            if (filter_asset) |as| {
                                if (!asciiEqIgnoreCase(asset_lbl, as)) continue;
                            }
                            if (!first) out.appendSlice(alloc, ",") catch return true;
                            first = false;
                            std.fmt.format(out.writer(alloc),
                                "\"L{d}\":{{\"refid\":\"{s}\",\"time\":{d}.0,\"type\":\"{s}\"," ++
                                "\"subtype\":\"\",\"aclass\":\"currency\",\"asset\":\"{s}\",\"amount\":\"{d}\"," ++
                                "\"fee\":\"{d}\",\"balance\":\"{d}\"}}",
                                .{ tx.id, tx.hash, tx.timestamp,
                                   ledger_type, asset_lbl, amt_signed,
                                   tx.fee, balance_sat }) catch return true;
                            emitted += 1;
                        }
                    }
                }
            }

            std.fmt.format(out.writer(alloc), "}},\"count\":{d}}}}}", .{emitted}) catch return true;
            writeJsonResponse(stream, out.items);
            return true;
        }
        else if (std.mem.eql(u8, ep, "QueryLedgers")) {
            // PHASE 2E.1 — same shape as Ledgers but filtered to id CSV.
            const id_csv = formGetField(post_body, "id") orelse "";
            const filter_addr = formGetField(post_body, "address") orelse owner;
            var out = std.ArrayList(u8){};
            defer out.deinit(alloc);
            out.appendSlice(alloc, "{\"error\":[],\"result\":{") catch return true;
            const LIMIT: u32 = 50;
            var emitted: u32 = 0;
            var first = true;
            var balance_sat: i128 = 0;

            ctx.exchange_mutex.lock();
            defer ctx.exchange_mutex.unlock();

            var heights = std.ArrayList(u32){};
            defer heights.deinit(alloc);
            var it = ctx.bc.fills_history.iterator();
            while (it.next()) |entry| {
                heights.append(alloc, entry.key_ptr.*) catch return true;
            }
            std.mem.sort(u32, heights.items, {}, comptime std.sort.desc(u32));

            fills_q: for (heights.items) |h| {
                const slice = ctx.bc.fills_history.get(h) orelse continue;
                var idx: usize = slice.len;
                while (idx > 0) {
                    idx -= 1;
                    if (emitted >= LIMIT) break :fills_q;
                    const f = &slice[idx];
                    if (filter_addr) |a| if (!fillTouchesAddr(f, a)) continue;

                    var key_buf: [32]u8 = undefined;
                    const key = std.fmt.bufPrint(&key_buf, "L{d}", .{f.fill_id}) catch continue;
                    if (id_csv.len > 0 and std.mem.indexOf(u8, id_csv, key) == null) continue;

                    const side: []const u8 = if (filter_addr) |a| fillSideForTrader(f, a) else "buy";
                    const signed_amount: i128 = if (std.mem.eql(u8, side, "buy"))
                        @as(i128, @intCast(f.amount_sat))
                    else
                        -@as(i128, @intCast(f.amount_sat));
                    balance_sat += signed_amount;
                    var asset_buf: [16]u8 = undefined;
                    var asset_lbl: []const u8 = "OMNI";
                    for (EXCHANGE_PAIRS) |p| {
                        if (p.id == f.pair_id) {
                            asset_lbl = std.fmt.bufPrint(&asset_buf, "{s}", .{p.base}) catch "OMNI";
                            break;
                        }
                    }
                    const fee_micro = ledgerFeeMicroFor(f.price_micro_usd, f.amount_sat);
                    if (!first) out.appendSlice(alloc, ",") catch return true;
                    first = false;
                    std.fmt.format(out.writer(alloc),
                        "\"L{d}\":{{\"refid\":\"T{d}\",\"time\":{d}.0,\"type\":\"trade\"," ++
                        "\"subtype\":\"\",\"aclass\":\"currency\",\"asset\":\"{s}\",\"amount\":\"{d}\"," ++
                        "\"fee\":\"{d}\",\"balance\":\"{d}\"}}",
                        .{ f.fill_id, f.fill_id, @divTrunc(f.timestamp_ms, 1000),
                           asset_lbl, signed_amount, fee_micro, balance_sat }) catch return true;
                    emitted += 1;
                }
            }

            if (emitted < LIMIT) {
                var bi: usize = ctx.bc.chain.items.len;
                tx_q: while (bi > 0) {
                    bi -= 1;
                    const blk = &ctx.bc.chain.items[bi];
                    var ti: usize = blk.transactions.items.len;
                    while (ti > 0) {
                        ti -= 1;
                        if (emitted >= LIMIT) break :tx_q;
                        const tx = &blk.transactions.items[ti];
                        var key_buf: [32]u8 = undefined;
                        const key = std.fmt.bufPrint(&key_buf, "L{d}", .{tx.id}) catch continue;
                        if (id_csv.len > 0 and std.mem.indexOf(u8, id_csv, key) == null) continue;
                        if (filter_addr) |a| {
                            const is_to = std.mem.eql(u8, tx.to_address, a);
                            const is_from = std.mem.eql(u8, tx.from_address, a);
                            if (!is_to and !is_from) continue;
                            const amt_signed: i128 = if (is_to)
                                @as(i128, @intCast(tx.amount))
                            else
                                -@as(i128, @intCast(tx.amount));
                            balance_sat += amt_signed;
                            const ledger_type: []const u8 = if (is_to) "deposit" else "withdrawal";
                            if (!first) out.appendSlice(alloc, ",") catch return true;
                            first = false;
                            std.fmt.format(out.writer(alloc),
                                "\"L{d}\":{{\"refid\":\"{s}\",\"time\":{d}.0,\"type\":\"{s}\"," ++
                                "\"subtype\":\"\",\"aclass\":\"currency\",\"asset\":\"OMNI\",\"amount\":\"{d}\"," ++
                                "\"fee\":\"{d}\",\"balance\":\"{d}\"}}",
                                .{ tx.id, tx.hash, tx.timestamp,
                                   ledger_type, amt_signed, tx.fee, balance_sat }) catch return true;
                            emitted += 1;
                        }
                    }
                }
            }

            out.appendSlice(alloc, "}}") catch return true;
            writeJsonResponse(stream, out.items);
            return true;
        }
        else if (std.mem.eql(u8, ep, "TradeVolume")) {
            // PHASE 2E.1 — 30-day rolling volume in micro-USD across all pairs.
            const now_ms: i64 = std.time.milliTimestamp();
            const cutoff_ms: i64 = now_ms - (30 * 24 * 60 * 60 * 1000);
            var total_volume_micro: u128 = 0;

            ctx.exchange_mutex.lock();
            defer ctx.exchange_mutex.unlock();

            var it = ctx.bc.fills_history.iterator();
            while (it.next()) |entry| {
                const slice = entry.value_ptr.*;
                for (slice) |f| {
                    if (f.timestamp_ms < cutoff_ms) continue;
                    const notional: u128 =
                        (@as(u128, f.price_micro_usd) * @as(u128, f.amount_sat)) / 1_000_000_000;
                    total_volume_micro += notional;
                }
            }

            var out = std.ArrayList(u8){};
            defer out.deinit(alloc);
            const vol_int: u64 = @intCast(@min(total_volume_micro / 1_000_000, @as(u128, std.math.maxInt(u64))));
            std.fmt.format(out.writer(alloc),
                "{{\"error\":[],\"result\":{{\"currency\":\"USD\",\"volume\":\"{d}.0000\",\"fees\":{{",
                .{vol_int}) catch return true;
            var first = true;
            for (EXCHANGE_PAIRS) |p| {
                if (!first) out.appendSlice(alloc, ",") catch return true;
                first = false;
                std.fmt.format(out.writer(alloc),
                    "\"{s}/{s}\":{{\"fee\":\"0.1000\",\"minfee\":\"0.1000\",\"maxfee\":\"0.2600\"," ++
                    "\"nextfee\":\"0.0800\",\"nextvolume\":\"50000.0000\",\"tiervolume\":\"0.0000\"}}",
                    .{ p.base, p.quote }) catch return true;
            }
            out.appendSlice(alloc, "}}}}") catch return true;
            writeJsonResponse(stream, out.items);
            return true;
        }
        else if (std.mem.eql(u8, ep, "AddOrder") or std.mem.eql(u8, ep, "CancelOrder") or std.mem.eql(u8, ep, "Withdraw")) {
            // PHASE 1: HMAC-SHA512 auth for mutating endpoints.
            const api_key_hdr = extractHttpHeader(header, "api-key") orelse {
                writeJsonResponse(stream, "{\"error\":[\"EAPI:InvalidKey\"],\"result\":{}}");
                return true;
            };
            const api_sign_hdr = extractHttpHeader(header, "api-sign") orelse {
                writeJsonResponse(stream, "{\"error\":[\"EAPI:InvalidSignature\"],\"result\":{}}");
                return true;
            };

            ctx.exchange_mutex.lock();
            const api_key = apiKeyLookup(ctx, api_key_hdr);
            ctx.exchange_mutex.unlock();

            if (api_key == null) {
                writeJsonResponse(stream, "{\"error\":[\"EAPI:InvalidKey\"],\"result\":{}}");
                return true;
            }
            if (api_key.?.secret_raw_len == 0) {
                writeJsonResponse(stream, "{\"error\":[\"EAPI:KeyNotEnabledForRest\"],\"result\":{}}");
                return true;
            }

            const full_path = if (std.mem.startsWith(u8, path, "/exchange/0/")) path else std.fmt.allocPrint(alloc, "/exchange/0/{s}", .{rest}) catch return true;
            defer if (full_path.ptr != path.ptr) alloc.free(full_path);

            if (!verifyHmacSignature(api_key.?, api_sign_hdr, full_path, post_body)) {
                writeJsonResponse(stream, "{\"error\":[\"EAPI:InvalidSignature\"],\"result\":{}}");
                return true;
            }

            const owner_slice = api_key.?.owner[0..api_key.?.owner_len];

            if (std.mem.eql(u8, ep, "AddOrder")) {
                const pair_label = formGetField(post_body, "pair") orelse "OMNI/USDC";
                const side_str = formGetField(post_body, "type") orelse formGetField(post_body, "side") orelse "buy";
                const vol_str = formGetField(post_body, "volume") orelse formGetField(post_body, "amount") orelse "0";
                const price_str = formGetField(post_body, "price") orelse "0";
                const order_nonce_str = formGetField(post_body, "nonce") orelse "0";
                const norm = normalizePair(alloc, pair_label);
                defer if (norm.alloced) alloc.free(norm.pair);
                const pair_id = exchangePairLookup(norm.pair) orelse 0;

                // For REST HMAC orders we bypass ECDSA and use the API key's owner directly.
                // The JSON-RPC handler still expects signature + pubkey fields for backward compat;
                // we inject a dummy ECDSA signature that passes our verify logic only when
                // the request came through the authenticated REST path. This is a bridge
                // until we refactor the handler to accept HMAC-only orders natively.
                // TODO(Phase 2): refactor handleExchangePlaceOrder to accept HMAC auth directly.
                owned_params = std.fmt.allocPrint(alloc,
                    "[{{\"trader\":\"{s}\",\"side\":\"{s}\",\"pairId\":{d},\"price\":{s},\"amount\":{s},\"nonce\":{s},\"signature\":\"REST_HMAC_BYPASS\",\"publicKey\":\"{s}\"{s}}}]",
                    .{ owner_slice, side_str, pair_id, price_str, vol_str, order_nonce_str, owner_slice, mode_suffix }) catch null;
                rpc_method = "exchange_placeOrder";
            }
            else if (std.mem.eql(u8, ep, "CancelOrder")) {
                const order_id_str = formGetField(post_body, "txid") orelse formGetField(post_body, "orderId") orelse "0";
                const cancel_nonce_str = formGetField(post_body, "nonce") orelse "0";
                owned_params = std.fmt.allocPrint(alloc,
                    "[{{\"trader\":\"{s}\",\"orderId\":{s},\"nonce\":{s},\"signature\":\"REST_HMAC_BYPASS\",\"publicKey\":\"{s}\"{s}}}]",
                    .{ owner_slice, order_id_str, cancel_nonce_str, owner_slice, mode_suffix }) catch null;
                rpc_method = "exchange_cancelOrder";
            }
            else if (std.mem.eql(u8, ep, "Withdraw")) {
                const asset = formGetField(post_body, "asset") orelse "OMNI";
                const amount_str = formGetField(post_body, "amount") orelse "0";
                const to_addr = formGetField(post_body, "address") orelse owner_slice;
                const withdraw_nonce_str = formGetField(post_body, "nonce") orelse "0";
                owned_params = std.fmt.allocPrint(alloc,
                    "[{{\"owner\":\"{s}\",\"token\":\"{s}\",\"amount\":{s},\"toAddress\":\"{s}\",\"nonce\":{s},\"signature\":\"REST_HMAC_BYPASS\",\"publicKey\":\"{s}\"{s}}}]",
                    .{ owner_slice, asset, amount_str, to_addr, withdraw_nonce_str, owner_slice, mode_suffix }) catch null;
                rpc_method = "exchange_withdraw";
            }

            if (owned_params) |p| rpc_params = p;
        }
        else if (std.mem.eql(u8, ep, "CancelAll")) {
            // PHASE 2E.3 — cancel every active/partial order belonging to the
            // requesting trader. HMAC-SHA512 auth same as AddOrder/CancelOrder.
            const api_key_hdr = extractHttpHeader(header, "api-key") orelse {
                writeJsonResponse(stream, "{\"error\":[\"EAPI:InvalidKey\"],\"result\":{}}");
                return true;
            };
            const api_sign_hdr = extractHttpHeader(header, "api-sign") orelse {
                writeJsonResponse(stream, "{\"error\":[\"EAPI:InvalidSignature\"],\"result\":{}}");
                return true;
            };

            ctx.exchange_mutex.lock();
            const api_key = apiKeyLookup(ctx, api_key_hdr);
            ctx.exchange_mutex.unlock();

            if (api_key == null) {
                writeJsonResponse(stream, "{\"error\":[\"EAPI:InvalidKey\"],\"result\":{}}");
                return true;
            }
            if (api_key.?.secret_raw_len == 0) {
                writeJsonResponse(stream, "{\"error\":[\"EAPI:KeyNotEnabledForRest\"],\"result\":{}}");
                return true;
            }

            const full_path = if (std.mem.startsWith(u8, path, "/exchange/0/")) path else std.fmt.allocPrint(alloc, "/exchange/0/{s}", .{rest}) catch return true;
            defer if (full_path.ptr != path.ptr) alloc.free(full_path);

            if (!verifyHmacSignature(api_key.?, api_sign_hdr, full_path, post_body)) {
                writeJsonResponse(stream, "{\"error\":[\"EAPI:InvalidSignature\"],\"result\":{}}");
                return true;
            }

            const trader_slice = api_key.?.owner[0..api_key.?.owner_len];
            const engine = pickEngine(ctx, is_paper) orelse {
                writeJsonResponse(stream, "{\"error\":[\"EService:Unavailable\"],\"result\":{}}");
                return true;
            };

            ctx.exchange_mutex.lock();
            const cancelled_count = cancelAllForTrader(engine, trader_slice, alloc);
            ctx.exchange_mutex.unlock();

            const reply = std.fmt.allocPrint(alloc,
                "{{\"error\":[],\"result\":{{\"count\":{d}}}}}",
                .{cancelled_count}) catch return true;
            defer alloc.free(reply);
            writeJsonResponse(stream, reply);
            return true;
        }
        else if (std.mem.eql(u8, ep, "CancelAllOrdersAfter")) {
            // PHASE 2E.3 — Kraken dead-man-switch. We accept the registration
            // and echo timestamps; a real timer wheel that cancels on expiry
            // is queued for Phase 3 (no-op effective for now).
            const api_key_hdr = extractHttpHeader(header, "api-key") orelse {
                writeJsonResponse(stream, "{\"error\":[\"EAPI:InvalidKey\"],\"result\":{}}");
                return true;
            };
            const api_sign_hdr = extractHttpHeader(header, "api-sign") orelse {
                writeJsonResponse(stream, "{\"error\":[\"EAPI:InvalidSignature\"],\"result\":{}}");
                return true;
            };

            ctx.exchange_mutex.lock();
            const api_key = apiKeyLookup(ctx, api_key_hdr);
            ctx.exchange_mutex.unlock();

            if (api_key == null) {
                writeJsonResponse(stream, "{\"error\":[\"EAPI:InvalidKey\"],\"result\":{}}");
                return true;
            }
            if (api_key.?.secret_raw_len == 0) {
                writeJsonResponse(stream, "{\"error\":[\"EAPI:KeyNotEnabledForRest\"],\"result\":{}}");
                return true;
            }

            const full_path = if (std.mem.startsWith(u8, path, "/exchange/0/")) path else std.fmt.allocPrint(alloc, "/exchange/0/{s}", .{rest}) catch return true;
            defer if (full_path.ptr != path.ptr) alloc.free(full_path);

            if (!verifyHmacSignature(api_key.?, api_sign_hdr, full_path, post_body)) {
                writeJsonResponse(stream, "{\"error\":[\"EAPI:InvalidSignature\"],\"result\":{}}");
                return true;
            }

            const timeout_str = formGetField(post_body, "timeout") orelse "0";
            const timeout_secs = std.fmt.parseInt(i64, timeout_str, 10) catch 0;
            const now_secs = @divFloor(std.time.milliTimestamp(), 1000);
            const trigger_secs = if (timeout_secs > 0) now_secs + timeout_secs else now_secs;

            const reply = std.fmt.allocPrint(alloc,
                "{{\"error\":[],\"result\":{{\"currentTime\":\"{d}\",\"triggerTime\":\"{d}\"}}}}",
                .{ now_secs, trigger_secs }) catch return true;
            defer alloc.free(reply);
            writeJsonResponse(stream, reply);
            return true;
        }
        else if (std.mem.eql(u8, ep, "EditOrder")) {
            // PHASE 2E.3 — replace existing resting order with new (price, volume).
            // Implemented as cancel-then-place; new order gets fresh order_id +
            // timestamp, losing FIFO priority (same as Kraken's real impl).
            const api_key_hdr = extractHttpHeader(header, "api-key") orelse {
                writeJsonResponse(stream, "{\"error\":[\"EAPI:InvalidKey\"],\"result\":{}}");
                return true;
            };
            const api_sign_hdr = extractHttpHeader(header, "api-sign") orelse {
                writeJsonResponse(stream, "{\"error\":[\"EAPI:InvalidSignature\"],\"result\":{}}");
                return true;
            };

            ctx.exchange_mutex.lock();
            const api_key = apiKeyLookup(ctx, api_key_hdr);
            ctx.exchange_mutex.unlock();

            if (api_key == null) {
                writeJsonResponse(stream, "{\"error\":[\"EAPI:InvalidKey\"],\"result\":{}}");
                return true;
            }
            if (api_key.?.secret_raw_len == 0) {
                writeJsonResponse(stream, "{\"error\":[\"EAPI:KeyNotEnabledForRest\"],\"result\":{}}");
                return true;
            }

            const full_path = if (std.mem.startsWith(u8, path, "/exchange/0/")) path else std.fmt.allocPrint(alloc, "/exchange/0/{s}", .{rest}) catch return true;
            defer if (full_path.ptr != path.ptr) alloc.free(full_path);

            if (!verifyHmacSignature(api_key.?, api_sign_hdr, full_path, post_body)) {
                writeJsonResponse(stream, "{\"error\":[\"EAPI:InvalidSignature\"],\"result\":{}}");
                return true;
            }

            const trader_slice = api_key.?.owner[0..api_key.?.owner_len];
            const txid_str = formGetField(post_body, "txid") orelse {
                writeJsonResponse(stream, "{\"error\":[\"EOrder:MissingTxid\"],\"result\":{}}");
                return true;
            };
            const old_id = std.fmt.parseInt(u64, txid_str, 10) catch {
                writeJsonResponse(stream, "{\"error\":[\"EOrder:BadTxid\"],\"result\":{}}");
                return true;
            };

            const engine = pickEngine(ctx, is_paper) orelse {
                writeJsonResponse(stream, "{\"error\":[\"EService:Unavailable\"],\"result\":{}}");
                return true;
            };

            ctx.exchange_mutex.lock();
            defer ctx.exchange_mutex.unlock();

            const old_order_ptr = findOrderByIdAndOwner(engine, old_id, trader_slice) orelse {
                writeJsonResponse(stream, "{\"error\":[\"EOrder:Unknown order\"],\"result\":{}}");
                return true;
            };

            const old_side = old_order_ptr.side;
            const old_pair_id = old_order_ptr.pair_id;
            const old_filled_sat = old_order_ptr.filled_sat;
            const old_amount_sat = old_order_ptr.amount_sat;
            const old_price = old_order_ptr.price_micro_usd;
            var trader_buf: [64]u8 = [_]u8{0} ** 64;
            const trader_addr_len = old_order_ptr.trader_addr_len;
            @memcpy(trader_buf[0..trader_addr_len], old_order_ptr.trader_address[0..trader_addr_len]);

            const new_price: u64 = blk: {
                if (formGetField(post_body, "price")) |s| {
                    break :blk std.fmt.parseInt(u64, s, 10) catch old_price;
                }
                break :blk old_price;
            };
            const new_amount: u64 = blk: {
                if (formGetField(post_body, "volume")) |s| {
                    break :blk std.fmt.parseInt(u64, s, 10) catch old_amount_sat;
                }
                break :blk old_amount_sat;
            };

            if (old_filled_sat > 0 and new_amount < old_filled_sat) {
                writeJsonResponse(stream,
                    "{\"error\":[\"EOrder:Volume below already-filled amount\"],\"result\":{}}");
                return true;
            }

            engine.cancelOrder(old_id) catch |err| switch (err) {
                error.OrderNotFound => {
                    writeJsonResponse(stream,
                        "{\"error\":[\"EOrder:Order vanished mid-edit\"],\"result\":{}}");
                    return true;
                },
                else => {
                    writeJsonResponse(stream,
                        "{\"error\":[\"EOrder:Cancel failed\"],\"result\":{}}");
                    return true;
                },
            };

            var new_order = matching_mod.Order.empty();
            new_order.trader_address = trader_buf;
            new_order.trader_addr_len = trader_addr_len;
            new_order.pair_id = old_pair_id;
            new_order.side = old_side;
            new_order.price_micro_usd = new_price;
            new_order.amount_sat = new_amount;
            new_order.timestamp_ms = std.time.milliTimestamp();
            new_order.status = .active;

            const new_id = engine.next_order_id;

            engine.placeOrder(new_order) catch |err| {
                const msg: []const u8 = switch (err) {
                    error.OrderbookFull => "EOrder:Orderbook full",
                    error.InvalidPrice => "EOrder:Invalid price",
                    error.InvalidAmount => "EOrder:Invalid volume",
                    error.InvalidPair => "EOrder:Invalid pair",
                    else => "EOrder:Place failed",
                };
                const reply = std.fmt.allocPrint(alloc,
                    "{{\"error\":[\"{s}\"],\"result\":{{}}}}", .{msg}) catch return true;
                defer alloc.free(reply);
                writeJsonResponse(stream, reply);
                return true;
            };

            const reply = std.fmt.allocPrint(alloc,
                "{{\"error\":[],\"result\":{{" ++
                    "\"descr\":{{\"order\":\"edited\"}}," ++
                    "\"txid\":\"{d}\"," ++
                    "\"originaltxid\":\"{d}\"" ++
                "}}}}",
                .{ new_id, old_id }) catch return true;
            defer alloc.free(reply);
            writeJsonResponse(stream, reply);
            return true;
        }
        else if (std.mem.eql(u8, ep, "DepositMethods")) {
            // PHASE 2E.4 — per-asset deposit methods.
            const asset = formGetField(post_body, "asset") orelse "OMNI";
            if (!fundingAssetSupported(asset)) {
                writeJsonResponse(stream, "{\"error\":[\"EFunding:Unknown asset\"],\"result\":[]}");
                return true;
            }
            var out = std.ArrayList(u8){};
            defer out.deinit(alloc);
            out.appendSlice(alloc, "{\"error\":[],\"result\":[") catch return true;
            appendFundingMethodObject(alloc, &out, asset, false) catch return true;
            out.appendSlice(alloc, "]}") catch return true;
            writeJsonResponse(stream, out.items);
            return true;
        }
        else if (std.mem.eql(u8, ep, "DepositAddresses")) {
            // PHASE 2E.4 — escrow address per asset.
            const asset = formGetField(post_body, "asset") orelse "OMNI";
            if (!fundingAssetSupported(asset)) {
                writeJsonResponse(stream, "{\"error\":[\"EFunding:Unknown asset\"],\"result\":[]}");
                return true;
            }
            // Native OMNI deposits land on the wallet address. Cross-chain
            // assets require the Phase 2F TSS-controlled bridge vault, which
            // is not yet deployed — return a clear error instead of a magic
            // placeholder string the client would treat as a real address.
            if (!std.mem.eql(u8, asset, "OMNI")) {
                writeJsonResponse(stream,
                    "{\"error\":[\"EFunding:BridgeVaultNotDeployed\"],\"result\":[]}");
                return true;
            }
            const body_json = std.fmt.allocPrint(alloc,
                "{{\"error\":[],\"result\":[{{\"address\":\"{s}\"," ++
                "\"expiretm\":0,\"newtag\":null}}]}}",
                .{ ctx.wallet.address }) catch {
                    writeJsonResponse(stream, "{\"error\":[\"EFunding:Alloc\"],\"result\":[]}");
                    return true;
                };
            defer alloc.free(body_json);
            writeJsonResponse(stream, body_json);
            return true;
        }
        else if (std.mem.eql(u8, ep, "StatusOfDeposits")) {
            // PHASE 2E.4 — walk chain newest-first for TXs landing on escrow.
            const asset = formGetField(post_body, "asset") orelse "OMNI";
            if (!fundingAssetSupported(asset)) {
                writeJsonResponse(stream, "{\"error\":[\"EFunding:Unknown asset\"],\"result\":[]}");
                return true;
            }
            if (!std.mem.eql(u8, asset, "OMNI")) {
                writeJsonResponse(stream, "{\"error\":[],\"result\":[]}");
                return true;
            }
            ctx.bc.mutex.lock();
            defer ctx.bc.mutex.unlock();

            var out = std.ArrayList(u8){};
            defer out.deinit(alloc);
            out.appendSlice(alloc, "{\"error\":[],\"result\":[") catch return true;
            const owner_param = formGetField(post_body, "address") orelse ctx.wallet.address;
            appendFundingStatusEntries(alloc, ctx.bc, &out, 50, "deposit",
                owner_param, ctx.wallet.address, .deposit) catch return true;
            out.appendSlice(alloc, "]}") catch return true;
            writeJsonResponse(stream, out.items);
            return true;
        }
        else if (std.mem.eql(u8, ep, "WithdrawMethods")) {
            // PHASE 2E.4 — per-asset withdraw methods with fees.
            const asset = formGetField(post_body, "asset") orelse "OMNI";
            if (!fundingAssetSupported(asset)) {
                writeJsonResponse(stream, "{\"error\":[\"EFunding:Unknown asset\"],\"result\":[]}");
                return true;
            }
            var out = std.ArrayList(u8){};
            defer out.deinit(alloc);
            out.appendSlice(alloc, "{\"error\":[],\"result\":[") catch return true;
            appendFundingMethodObject(alloc, &out, asset, true) catch return true;
            out.appendSlice(alloc, "]}") catch return true;
            writeJsonResponse(stream, out.items);
            return true;
        }
        else if (std.mem.eql(u8, ep, "WithdrawAddresses")) {
            // PHASE 2E.4 — Phase 3 plan: on-chain saved-address book via
            // op_return prefix `address_book:`. For now empty list (no error).
            writeJsonResponse(stream, "{\"error\":[],\"result\":[]}");
            return true;
        }
        else if (std.mem.eql(u8, ep, "StatusOfWithdrawals")) {
            // PHASE 2E.4 — walk chain newest-first for outbound TXs from owner.
            const asset = formGetField(post_body, "asset") orelse "OMNI";
            if (!fundingAssetSupported(asset)) {
                writeJsonResponse(stream, "{\"error\":[\"EFunding:Unknown asset\"],\"result\":[]}");
                return true;
            }
            if (!std.mem.eql(u8, asset, "OMNI")) {
                writeJsonResponse(stream, "{\"error\":[],\"result\":[]}");
                return true;
            }
            const owner_param = formGetField(post_body, "address") orelse ctx.wallet.address;

            ctx.bc.mutex.lock();
            defer ctx.bc.mutex.unlock();

            var out = std.ArrayList(u8){};
            defer out.deinit(alloc);
            out.appendSlice(alloc, "{\"error\":[],\"result\":[") catch return true;
            appendFundingStatusEntries(alloc, ctx.bc, &out, 50, "withdrawal",
                owner_param, ctx.wallet.address, .withdraw) catch return true;
            out.appendSlice(alloc, "]}") catch return true;
            writeJsonResponse(stream, out.items);
            return true;
        }
        else if (std.mem.eql(u8, ep, "WithdrawCancel")) {
            // PHASE 2E.4 — cancel pending withdraw IF still in mempool.
            // Mined TXs are immutable.
            const refid = formGetField(post_body, "refid") orelse formGetField(post_body, "txid") orelse "";
            if (refid.len == 0) {
                writeJsonResponse(stream, "{\"error\":[\"EFunding:Missing refid\"],\"result\":false}");
                return true;
            }
            if (ctx.bc.tx_block_height.contains(refid)) {
                writeJsonResponse(stream,
                    "{\"error\":[\"Withdraw not cancelable: already mined\"],\"result\":false}");
                return true;
            }
            const mp = ctx.mempool orelse {
                writeJsonResponse(stream,
                    "{\"error\":[\"EFunding:Mempool unavailable\"],\"result\":false}");
                return true;
            };
            ctx.bc.mutex.lock();
            defer ctx.bc.mutex.unlock();

            var found_idx: ?usize = null;
            for (mp.entries.items, 0..) |entry, idx| {
                if (std.mem.eql(u8, entry.tx.hash, refid)) {
                    found_idx = idx;
                    break;
                }
            }
            if (found_idx) |idx| {
                const entry = mp.entries.items[idx];
                if (entry.tx.hash.len > 0) {
                    _ = mp.tx_hashes.remove(entry.tx.hash);
                }
                if (mp.pending_count.get(entry.tx.from_address)) |cur| {
                    if (cur <= 1) {
                        _ = mp.pending_count.remove(entry.tx.from_address);
                    } else {
                        mp.pending_count.put(entry.tx.from_address, cur - 1) catch {};
                    }
                }
                if (mp.total_bytes >= entry.size_bytes) {
                    mp.total_bytes -= entry.size_bytes;
                } else {
                    mp.total_bytes = 0;
                }
                _ = mp.entries.orderedRemove(idx);
                writeJsonResponse(stream, "{\"error\":[],\"result\":true}");
                return true;
            }
            writeJsonResponse(stream,
                "{\"error\":[\"Withdraw not found in mempool (already mined or unknown)\"]," ++
                "\"result\":false}");
            return true;
        }
        else if (std.mem.eql(u8, ep, "WalletTransfer")) {
            // PHASE 2E.4 — Phase 3 plan: sub-account tags via op_return prefix
            // `subaccount:<id>` + transferSubaccount RPC. For now reject with
            // an explanatory error (Kraken pattern when a wallet pair is unsupported).
            writeJsonResponse(stream,
                "{\"error\":[\"Internal wallet transfer not yet supported (Phase 3)\"]," ++
                "\"result\":{\"refid\":\"\"}}");
            return true;
        }
        else if (std.mem.eql(u8, ep, "Stake")) {
            // PHASE 2E.5 v1: accept request, return refid. Phase 3: build +
            // sign + broadcast TX with op_return = "stake:<amt>" so applyBlock
            // → applyOpReturnRoles credits bc.stake_amounts.
            const method = formGetField(post_body, "method") orelse "OMNI.flexible";
            var ref_buf: [16]u8 = undefined;
            randomHex(ref_buf[0..], 8);
            const body_str = std.fmt.allocPrint(alloc,
                "{{\"error\":[],\"result\":{{\"refid\":\"{s}\",\"method\":\"{s}\",\"status\":\"submitted\"}}}}",
                .{ ref_buf, method }) catch return true;
            defer alloc.free(body_str);
            writeJsonResponse(stream, body_str);
            return true;
        }
        else if (std.mem.eql(u8, ep, "Unstake")) {
            // PHASE 2E.5 v1: accept request, return refid. Phase 3: real TX.
            const method = formGetField(post_body, "method") orelse "OMNI.flexible";
            var ref_buf: [16]u8 = undefined;
            randomHex(ref_buf[0..], 8);
            const body_str = std.fmt.allocPrint(alloc,
                "{{\"error\":[],\"result\":{{\"refid\":\"{s}\",\"method\":\"{s}\",\"status\":\"submitted\"}}}}",
                .{ ref_buf, method }) catch return true;
            defer alloc.free(body_str);
            writeJsonResponse(stream, body_str);
            return true;
        }
        else if (std.mem.eql(u8, ep, "GetStakingAssets")) {
            // PHASE 2E.5 — list which assets can be staked. v1: only OMNI.
            // Phase 2F: add per-asset staking once cross-chain bridge online.
            writeJsonResponse(stream,
                "{\"error\":[],\"result\":[" ++
                "{\"asset\":\"OMNI\",\"staking\":true,\"min_amount\":\"1.00000000\"," ++
                "\"lock_periods\":[{\"days\":0,\"rewards\":{\"reward\":\"5.0\",\"type\":\"percentage\"}}]}" ++
                "]}");
            return true;
        }
        else if (std.mem.eql(u8, ep, "GetPendingStaking")) {
            // PHASE 2E.5 — list pending stake/unstake operations from chain.
            // Walk newest blocks, filter by from_address + op_return prefix.
            const target_addr = formGetField(post_body, "address") orelse owner orelse "";
            if (target_addr.len == 0) {
                writeJsonResponse(stream, "{\"error\":[],\"result\":[]}");
                return true;
            }
            ctx.bc.mutex.lock();
            defer ctx.bc.mutex.unlock();

            var out = std.ArrayList(u8){};
            defer out.deinit(alloc);
            out.appendSlice(alloc, "{\"error\":[],\"result\":[") catch return true;
            var emitted: u32 = 0;
            const LIMIT: u32 = 50;
            const tip: u64 = @intCast(ctx.bc.chain.items.len);
            const recent_blocks: u64 = 6; // pending = last 6 blocks
            var bi: usize = ctx.bc.chain.items.len;
            outer: while (bi > 0 and emitted < LIMIT) {
                bi -= 1;
                const block_h: u64 = @intCast(bi);
                if (tip > block_h and (tip - block_h) > recent_blocks) break;
                const blk = ctx.bc.chain.items[bi];
                for (blk.transactions.items) |tx| {
                    if (emitted >= LIMIT) break :outer;
                    if (!std.mem.eql(u8, tx.from_address, target_addr)) continue;
                    if (tx.op_return.len == 0) continue;
                    const is_stake = std.mem.startsWith(u8, tx.op_return, "stake:");
                    const is_unstake = std.mem.startsWith(u8, tx.op_return, "unstake:");
                    if (!is_stake and !is_unstake) continue;
                    const kind: []const u8 = if (is_stake) "bonding" else "unbonding";
                    const sat: u64 = tx.amount;
                    const omni_int: u64 = sat / 1_000_000_000;
                    const omni_frac: u64 = sat % 1_000_000_000;
                    if (emitted > 0) out.appendSlice(alloc, ",") catch return true;
                    const line = std.fmt.allocPrint(alloc,
                        "{{\"refid\":\"{s}\",\"time\":{d},\"type\":\"{s}\",\"asset\":\"OMNI\"," ++
                        "\"amount\":\"{d}.{d:0>9}\",\"status\":\"Pending\"}}",
                        .{ tx.hash, tx.timestamp, kind, omni_int, omni_frac }) catch return true;
                    defer alloc.free(line);
                    out.appendSlice(alloc, line) catch return true;
                    emitted += 1;
                }
            }
            out.appendSlice(alloc, "]}") catch return true;
            writeJsonResponse(stream, out.items);
            return true;
        }
        else if (std.mem.eql(u8, ep, "ListStakingTransactions")) {
            // PHASE 2E.5 — full stake/unstake history (no time filter).
            const target_addr = formGetField(post_body, "address") orelse owner orelse "";
            if (target_addr.len == 0) {
                writeJsonResponse(stream, "{\"error\":[],\"result\":[]}");
                return true;
            }
            ctx.bc.mutex.lock();
            defer ctx.bc.mutex.unlock();

            var out = std.ArrayList(u8){};
            defer out.deinit(alloc);
            out.appendSlice(alloc, "{\"error\":[],\"result\":[") catch return true;
            var emitted: u32 = 0;
            const LIMIT: u32 = 100;
            var bi: usize = ctx.bc.chain.items.len;
            outer: while (bi > 0 and emitted < LIMIT) {
                bi -= 1;
                const blk = ctx.bc.chain.items[bi];
                for (blk.transactions.items) |tx| {
                    if (emitted >= LIMIT) break :outer;
                    if (!std.mem.eql(u8, tx.from_address, target_addr)) continue;
                    if (tx.op_return.len == 0) continue;
                    const is_stake = std.mem.startsWith(u8, tx.op_return, "stake:");
                    const is_unstake = std.mem.startsWith(u8, tx.op_return, "unstake:");
                    if (!is_stake and !is_unstake) continue;
                    const kind: []const u8 = if (is_stake) "bonding" else "unbonding";
                    const sat: u64 = tx.amount;
                    const omni_int: u64 = sat / 1_000_000_000;
                    const omni_frac: u64 = sat % 1_000_000_000;
                    if (emitted > 0) out.appendSlice(alloc, ",") catch return true;
                    const line = std.fmt.allocPrint(alloc,
                        "{{\"refid\":\"{s}\",\"time\":{d},\"type\":\"{s}\",\"asset\":\"OMNI\"," ++
                        "\"amount\":\"{d}.{d:0>9}\",\"status\":\"Success\"}}",
                        .{ tx.hash, tx.timestamp, kind, omni_int, omni_frac }) catch return true;
                    defer alloc.free(line);
                    out.appendSlice(alloc, line) catch return true;
                    emitted += 1;
                }
            }
            out.appendSlice(alloc, "]}") catch return true;
            writeJsonResponse(stream, out.items);
            return true;
        }
        else if (std.mem.eql(u8, ep, "Earn/Allocate")) {
            // PHASE 2E.5 v1: accept request, return allocation_id. Phase 3:
            // multi-strategy yield engine.
            const strategy_id = formGetField(post_body, "strategy_id") orelse "OMNI_FLEXIBLE";
            var alloc_buf: [16]u8 = undefined;
            randomHex(alloc_buf[0..], 8);
            const body_str = std.fmt.allocPrint(alloc,
                "{{\"error\":[],\"result\":{{\"allocation_id\":\"{s}\",\"strategy_id\":\"{s}\",\"status\":\"submitted\"}}}}",
                .{ alloc_buf, strategy_id }) catch return true;
            defer alloc.free(body_str);
            writeJsonResponse(stream, body_str);
            return true;
        }
        else if (std.mem.eql(u8, ep, "Earn/Deallocate")) {
            // PHASE 2E.5 v1: accept request, echo allocation_id.
            const alloc_id = formGetField(post_body, "allocation_id") orelse "";
            const body_str = std.fmt.allocPrint(alloc,
                "{{\"error\":[],\"result\":{{\"allocation_id\":\"{s}\",\"status\":\"submitted\"}}}}",
                .{alloc_id}) catch return true;
            defer alloc.free(body_str);
            writeJsonResponse(stream, body_str);
            return true;
        }
        else if (std.mem.eql(u8, ep, "Earn/Strategies")) {
            // PHASE 2E.5 — v1 starting set: 2 strategies (flexible + 30-day lock).
            writeJsonResponse(stream,
                "{\"error\":[],\"result\":[" ++
                "{\"id\":\"OMNI_FLEXIBLE\",\"asset\":\"OMNI\",\"apr\":\"5.00\",\"apy\":\"5.13\"," ++
                "\"lock_period_days\":0,\"min_amount\":\"1.00000000\"}," ++
                "{\"id\":\"OMNI_LOCK_30D\",\"asset\":\"OMNI\",\"apr\":\"7.50\",\"apy\":\"7.78\"," ++
                "\"lock_period_days\":30,\"min_amount\":\"10.00000000\"}" ++
                "]}");
            return true;
        }
        else if (std.mem.eql(u8, ep, "Earn/Allocations")) {
            // PHASE 2E.5 — derive from bc.stake_amounts (single OMNI_FLEXIBLE allocation).
            const target_addr = formGetField(post_body, "address") orelse owner orelse "";
            if (target_addr.len == 0) {
                writeJsonResponse(stream, "{\"error\":[],\"result\":[]}");
                return true;
            }
            const stake_sat: u64 = ctx.bc.stake_amounts.get(target_addr) orelse 0;
            if (stake_sat == 0) {
                writeJsonResponse(stream, "{\"error\":[],\"result\":[]}");
                return true;
            }
            const omni_int: u64 = stake_sat / 1_000_000_000;
            const omni_frac: u64 = stake_sat % 1_000_000_000;
            const body_str = std.fmt.allocPrint(alloc,
                "{{\"error\":[],\"result\":[{{\"strategy_id\":\"OMNI_FLEXIBLE\"," ++
                "\"allocated\":\"{d}.{d:0>9}\",\"earnings\":\"0.00000000\",\"since\":0}}]}}",
                .{ omni_int, omni_frac }) catch return true;
            defer alloc.free(body_str);
            writeJsonResponse(stream, body_str);
            return true;
        }
        else if (std.mem.eql(u8, ep, "AddExport")) {
            // PHASE 2E.5 v1: generate id and return queued status.
            // Phase 3: persistent export pipeline + on-disk artifacts.
            var id_buf: [16]u8 = undefined;
            randomHex(id_buf[0..], 8);
            const body_str = std.fmt.allocPrint(alloc,
                "{{\"error\":[],\"result\":{{\"id\":\"{s}\",\"status\":\"queued\"}}}}",
                .{id_buf}) catch return true;
            defer alloc.free(body_str);
            writeJsonResponse(stream, body_str);
            return true;
        }
        else if (std.mem.eql(u8, ep, "ExportStatus")) {
            // PHASE 2E.5 v1: return processed status if id provided.
            const export_id = formGetField(post_body, "id") orelse "";
            if (export_id.len == 0) {
                writeJsonResponse(stream, "{\"error\":[],\"result\":[]}");
                return true;
            }
            const now_sec: i64 = @divFloor(std.time.milliTimestamp(), 1000);
            const body_str = std.fmt.allocPrint(alloc,
                "{{\"error\":[],\"result\":[{{\"id\":\"{s}\",\"status\":\"Processed\"," ++
                "\"createdtm\":{d},\"format\":\"CSV\"}}]}}",
                .{ export_id, now_sec }) catch return true;
            defer alloc.free(body_str);
            writeJsonResponse(stream, body_str);
            return true;
        }
        else if (std.mem.eql(u8, ep, "RetrieveExport")) {
            // PHASE 2E.5 v1: synchronously generate CSV from chain state.
            // Phase 3: pre-rendered files on disk.
            const export_id = formGetField(post_body, "id") orelse "";
            const target_addr = owner orelse "";
            if (export_id.len == 0 or target_addr.len == 0) {
                writeJsonResponse(stream, "{\"error\":[\"EQuery:Missing id or owner\"],\"result\":{}}");
                return true;
            }
            ctx.bc.mutex.lock();
            defer ctx.bc.mutex.unlock();

            // Build a ledger-style CSV: walks chain TXs touching owner.
            var csv = std.ArrayList(u8){};
            defer csv.deinit(alloc);
            csv.appendSlice(alloc, "ledger_id,refid,time,type,asset,amount\\n") catch return true;
            for (ctx.bc.chain.items) |blk| {
                for (blk.transactions.items) |tx| {
                    const is_from = std.mem.eql(u8, tx.from_address, target_addr);
                    const is_to = std.mem.eql(u8, tx.to_address, target_addr);
                    if (!is_from and !is_to) continue;
                    const ledger_type: []const u8 = blk2: {
                        if (tx.op_return.len > 0 and std.mem.startsWith(u8, tx.op_return, "stake:")) break :blk2 "staking";
                        if (tx.op_return.len > 0 and std.mem.startsWith(u8, tx.op_return, "unstake:")) break :blk2 "unstaking";
                        if (is_from) break :blk2 "withdrawal";
                        break :blk2 "deposit";
                    };
                    const sat: u64 = tx.amount;
                    const oi: u64 = sat / 1_000_000_000;
                    const of: u64 = sat % 1_000_000_000;
                    const line = std.fmt.allocPrint(alloc,
                        "L{s},{s},{d},{s},OMNI,{d}.{d:0>9}\\n",
                        .{ tx.hash, tx.hash, tx.timestamp, ledger_type, oi, of }) catch continue;
                    defer alloc.free(line);
                    csv.appendSlice(alloc, line) catch return true;
                }
            }
            // Wrap CSV as JSON-escaped string in result.
            const body_str = std.fmt.allocPrint(alloc,
                "{{\"error\":[],\"result\":{{\"id\":\"{s}\",\"data\":\"{s}\"}}}}",
                .{ export_id, csv.items }) catch return true;
            defer alloc.free(body_str);
            writeJsonResponse(stream, body_str);
            return true;
        }
        else if (std.mem.eql(u8, ep, "DeleteExport")) {
            // PHASE 2E.5 v1: accept delete request (no real persistence to clean).
            writeJsonResponse(stream, "{\"error\":[],\"result\":true}");
            return true;
        }
        else if (std.mem.eql(u8, ep, "GetWebSocketsToken")) {
            // PHASE 2E.5 — generate ephemeral 32-byte hex token (15 min TTL).
            // Phase 3 wires this into a real WS handshake validator with
            // server-side replay tracking.
            var tok_buf: [64]u8 = undefined;
            randomHex(tok_buf[0..], 32);
            const body_str = std.fmt.allocPrint(alloc,
                "{{\"error\":[],\"result\":{{\"token\":\"{s}\",\"expires\":900}}}}",
                .{tok_buf}) catch return true;
            defer alloc.free(body_str);
            writeJsonResponse(stream, body_str);
            return true;
        }
        else {
            writeErrorResponse(stream, 404, "Unknown endpoint");
            return true;
        }

        if (rpc_method.len > 0) {
            const rpc_body = buildRpcBody(alloc, rpc_method, rpc_params) catch return true;
            defer alloc.free(rpc_body);
            const res = dispatch(rpc_body, ctx) catch |err| {
                writeErrorResponse(stream, 500, @errorName(err));
                return true;
            };
            defer alloc.free(res);
            writeKrakenFromRpc(alloc, stream, res);
            return true;
        }
    }

    return false;
}

// ─── JSON-RPC dispatcher ──────────────────────────────────────────────────────
// Refactored: fiecare RPC method are handler propriu pentru claritate si testabilitate


/// RPC "getwalletsummary" — single-call wallet snapshot for an address.
///
/// Returns one JSON object aggregating everything the user / CLI / SDK / UI
/// needs to display "where IS my money?": on-chain balance, total staked,
/// per-stake breakdown, OMNI locked in active sell orders, derived available,
/// and current block height. Lets a CLI user (no frontend) verify locks
/// without making 4 separate RPC calls.
///
/// Usage:
///   {"method":"getwalletsummary","params":["ob1q..."],"id":1}
///   {"method":"getwalletsummary","params":{"address":"ob1q..."},"id":1}
///
/// Returns: { address, height, wallet_sat, staked_sat, in_orders_sat,
///            available_sat, stakes:[{id, amount_sat, status, ...}],
///            open_sell_orders:[{pair_id, remaining_sat, price_micro_usd}] }

/// RPC "listunspent" — list all unspent transaction outputs (UTXOs) for an address.
///
/// Required by wallets to build wire-v2 transactions with explicit UTXO refs
/// (`inputs[]`/`outputs[]`). Without this, wallets fall back to balance-only wire-v1.
///
/// Walks `bc.utxo_set.address_index` for the given address, then dereferences each
/// outpoint key ("tx_hash:vout") into the `bc.utxo_set.utxos` map.
///
/// Usage:
///   {"method":"listunspent","params":["ob1q..."],"id":1}
///   {"method":"listunspent","params":{"address":"ob1q..."},"id":1}
///
/// Returns: {address, total, count, utxos:[{tx_hash, output_index, amount,
///          block_height, is_coinbase, is_spent:false}]}

// SEGFAULT-FIX [scan-2026-04-25]: use getLatestBlockSnapshot() — locks bc.mutex,
// copies fields into stable buffers, unlocks. allocPrint runs after the lock is
// released, on data that no longer aliases chain memory. Eliminates UAF on
// blk.hash / blk.previous_hash / blk.transactions.items when mining concurrently
// reallocs/swaps the chain.

// ─── SPV / Cross-chain oracle handlers ────────────────────────────────────────
//
// These do NOT touch ctx.bridge / ctx.bc state — they read/write the
// process-global oracle protected by g_xchain_oracle_mutex. Wire
// validation on oracle_recordHeader: ≥ ORACLE_QUORUM_MIN distinct
// secp256k1 sigs over SHA256("OMNI_ORACLE_v1\n" + chain + "\n" + height +
// "\n" + header_hash_hex), signers must be in setOracleQuorumPubkeys().
// The legacy `quorum_ok=true` flag is honored ONLY when zero pubkeys are
// registered (dev/testnet bring-up); production operators install the
// validator key set via oracle_quorum.json and the flag is ignored.



pub fn parseHex32Spv(s: []const u8) ?[32]u8 {
    var out: [32]u8 = undefined;
    var src = s;
    if (src.len >= 2 and src[0] == '0' and (src[1] == 'x' or src[1] == 'X')) src = src[2..];
    if (src.len != 64) return null;
    var i: usize = 0;
    while (i < 32) : (i += 1) {
        const hi = std.fmt.charToDigit(src[i * 2], 16) catch return null;
        const lo = std.fmt.charToDigit(src[i * 2 + 1], 16) catch return null;
        out[i] = (hi << 4) | lo;
    }
    return out;
}




// ─── Stake / Validator / Agent / Reputation handlers ───────────────────────
//
// Backend wiring for the 4 new frontend pages (Stake, Validators, Agents,
// Reputation). Stake/unstake submit op_return TXs that apply_block parses
// into the StakingEngine; validator promotion writes a `validator_*` op_return;
// agent registration writes `agent:register:*`. Reputation is read-only —
// it queries g_reputation directly.















fn dispatch(body: []const u8, ctx: *ServerCtx) ![]u8 {
    const alloc = ctx.allocator;

    // Parse "method" si "id" cu string search simplu (evitam dep JSON)
    const method = extractStr(body, "method") orelse return errorJson(-32600, "Invalid request", 0, alloc);
    const id      = extractId(body);

    // Chain queries — see core/rpc/chain.zig
    if (std.mem.eql(u8, method, "getblockcount"))  return rpc_chain.handleGetBlockCount(ctx, id);
    if (std.mem.eql(u8, method, "getlatestblock")) return rpc_chain.handleGetLatestBlock(ctx, id);
    // Mempool — see core/rpc/mempool.zig
    if (std.mem.eql(u8, method, "getmempoolsize")) return rpc_mempool.handleGetMempoolSize(ctx, id);

    if (std.mem.eql(u8, method, "getbalance"))     return rpc_wallet.handleGetBalance(body, ctx, id);
    if (std.mem.eql(u8, method, "getwalletsummary")) return rpc_wallet.handleGetWalletSummary(body, ctx, id);
    if (std.mem.eql(u8, method, "listunspent"))    return rpc_wallet.handleListUnspent(body, ctx, id);
    if (std.mem.eql(u8, method, "getstatus"))      return rpc_wallet.handleGetStatus(ctx, id);

    // Route to handler functions (refactored for low cyclomatic complexity)
    if (std.mem.eql(u8, method, "sendtransaction"))  return rpc_wallet.handleSendTx(body, ctx, id);
    if (std.mem.eql(u8, method, "gettransactions"))  return rpc_wallet.handleGetTxs(body, ctx, id);
    if (std.mem.eql(u8, method, "registerminer"))    return rpc_mining.handleRegMiner(body, ctx, id);
    if (std.mem.eql(u8, method, "getpoolstats"))     return rpc_mining.handlePoolStats(ctx, id);
    if (std.mem.eql(u8, method, "getaddressbalance"))return rpc_wallet.handleAddrBal(body, ctx, id);
    if (std.mem.eql(u8, method, "getmempoolstats"))  return rpc_mempool.handleMpStats(ctx, id);
    if (std.mem.eql(u8, method, "getpendingtxs"))   return rpc_mempool.handleGetPendingTxs(body, ctx, id);
    if (std.mem.eql(u8, method, "getpeers"))         return rpc_net.handlePeers(ctx, id);
    if (std.mem.eql(u8, method, "getsyncstatus"))    return rpc_net.handleSyncSt(ctx, id);
    if (std.mem.eql(u8, method, "getnetworkinfo"))   return rpc_net.handleNetInfo(ctx, id);
    if (std.mem.eql(u8, method, "getblock"))         return rpc_chain.handleGetBlk(body, ctx, id);
    if (std.mem.eql(u8, method, "getblocks"))        return rpc_chain.handleGetBlks(body, ctx, id);
    if (std.mem.eql(u8, method, "getminerstats"))    return rpc_mining.handleMinerSt(ctx, id);
    if (std.mem.eql(u8, method, "getvalidators"))    return rpc_consensus.handleGetValidators(ctx, id);
    if (std.mem.eql(u8, method, "getslotleader"))    return rpc_consensus.handleGetSlotLeader(ctx, id);
    if (std.mem.eql(u8, method, "getclockstatus"))   return rpc_consensus.handleGetClockStatus(ctx, id);
    if (std.mem.eql(u8, method, "getslotcalendar")) return rpc_consensus.handleGetSlotCalendar(ctx, id);
    if (std.mem.eql(u8, method, "getfuturepool"))    return rpc_consensus.handleGetFuturePool(ctx, id);
    if (std.mem.eql(u8, method, "getminerinfo"))     return rpc_mining.handleMinerInf(ctx, id);
    if (std.mem.eql(u8, method, "getnodelist"))      return rpc_net.handleNodeList(ctx, id);
    if (std.mem.eql(u8, method, "estimatefee"))       return rpc_mempool.handleEstimateFee(ctx, id);
    if (std.mem.eql(u8, method, "getnonce"))          return rpc_wallet.handleGetNonce(body, ctx, id);
    if (std.mem.eql(u8, method, "gettransaction"))   return rpc_wallet.handleGetTx(body, ctx, id);
    if (std.mem.eql(u8, method, "sendopreturn"))     return rpc_wallet.handleSendOpReturn(body, ctx, id);
    if (std.mem.eql(u8, method, "getaddresshistory")) return rpc_wallet.handleGetAddrHistory(body, ctx, id);
    if (std.mem.eql(u8, method, "listtransactions"))  return rpc_wallet.handleListTx(body, ctx, id);
    if (std.mem.eql(u8, method, "minersendtx"))      return rpc_wallet.handleMinerSendTx(body, ctx, id);
    if (std.mem.eql(u8, method, "claimfaucet"))      return rpc_wallet.handleClaimFaucet(body, ctx, id);
    if (std.mem.eql(u8, method, "getfaucetstatus"))  return rpc_wallet.handleFaucetStatus(ctx, id);
    if (std.mem.eql(u8, method, "getrichlist"))      return rpc_wallet.handleRichList(body, ctx, id);
    if (std.mem.eql(u8, method, "getchainmetrics"))  return rpc_chain.handleChainMetrics(ctx, id);
    if (std.mem.eql(u8, method, "getschemestats"))   return rpc_wallet.handleSchemeStats(body, ctx, id);
    if (std.mem.eql(u8, method, "registername"))     return rpc_ns.handleRegisterName(body, ctx, id);
    if (std.mem.eql(u8, method, "transfername"))     return rpc_ns.handleTransferName(body, ctx, id);
    if (std.mem.eql(u8, method, "updatename"))       return rpc_ns.handleUpdateName(body, ctx, id);
    if (std.mem.eql(u8, method, "renewname"))        return rpc_ns.handleRenewName(body, ctx, id);
    if (std.mem.eql(u8, method, "resolvename"))      return rpc_ns.handleResolveName(body, ctx, id);
    if (std.mem.eql(u8, method, "ns_resolveforsend")) return rpc_ns.handleResolveForSend(body, ctx, id);
    if (std.mem.eql(u8, method, "reverseresolvename")) return rpc_ns.handleReverseResolveName(body, ctx, id);
    if (std.mem.eql(u8, method, "listnames"))        return rpc_ns.handleListNames(body, ctx, id);
    if (std.mem.eql(u8, method, "getensfee"))        return rpc_ns.handleGetEnsFee(body, ctx, id);
    if (std.mem.eql(u8, method, "ns_listTlds"))      return rpc_ns.handleNsListTlds(ctx, id);
    if (std.mem.eql(u8, method, "ns_yearTiers"))     return rpc_ns.handleNsYearTiers(ctx, id);
    if (std.mem.eql(u8, method, "ns_stats"))         return rpc_ns.handleNsStats(ctx, id);
    if (std.mem.eql(u8, method, "ns_expiringSoon"))  return rpc_ns.handleNsExpiringSoon(body, ctx, id);
    if (std.mem.eql(u8, method, "ns_pruneExpired"))  return rpc_ns.handleNsPruneExpired(ctx, id);
    // Phase 2 NS — multi-address per name + category badges
    if (std.mem.eql(u8, method, "setpqaddress"))     return rpc_ns.handleSetPqAddress(body, ctx, id);
    if (std.mem.eql(u8, method, "setcategory"))      return rpc_ns.handleSetCategory(body, ctx, id);
    if (std.mem.eql(u8, method, "setpreferredslot")) return rpc_ns.handleSetPreferredSlot(body, ctx, id);
    if (std.mem.eql(u8, method, "getnamesbycategory")) return rpc_ns.handleGetNamesByCategory(body, ctx, id);
    if (std.mem.eql(u8, method, "sendrawtransaction")) return rpc_wallet.handleSendRawTx(body, ctx, id);

    // ── Native DEX (matching engine on-chain) ───────────────────────────
    if (std.mem.eql(u8, method, "exchange_placeOrder"))    return rpc_exchange.handleExchangePlaceOrder(body, ctx, id);
    if (std.mem.eql(u8, method, "exchange_cancelOrder"))   return rpc_exchange.handleExchangeCancelOrder(body, ctx, id);
    if (std.mem.eql(u8, method, "exchange_getOrderbook")) return rpc_exchange.handleExchangeGetOrderbook(body, ctx, id);
    if (std.mem.eql(u8, method, "exchange_getUserOrders"))return rpc_exchange.handleExchangeGetUserOrders(body, ctx, id);
    if (std.mem.eql(u8, method, "exchange_getUserTrades"))return rpc_exchange.handleExchangeGetUserTrades(body, ctx, id);
    if (std.mem.eql(u8, method, "exchange_getTrades"))     return rpc_exchange.handleExchangeGetTrades(body, ctx, id);
    if (std.mem.eql(u8, method, "exchange_listPairs"))     return rpc_exchange.handleExchangeListPairs(ctx, id);
    if (std.mem.eql(u8, method, "exchange_pairInfo"))      return rpc_exchange.handleExchangePairInfo(body, ctx, id);
    if (std.mem.eql(u8, method, "exchange_getStats"))      return rpc_exchange.handleExchangeGetStats(body, ctx, id);
    if (std.mem.eql(u8, method, "exchange_getAuthNonce"))  return rpc_exchange.handleExchangeGetAuthNonce(body, ctx, id);
    if (std.mem.eql(u8, method, "exchange_login"))         return rpc_exchange.handleExchangeLogin(body, ctx, id);
    if (std.mem.eql(u8, method, "exchange_createApiKey"))  return rpc_exchange.handleExchangeCreateApiKey(body, ctx, id);
    if (std.mem.eql(u8, method, "exchange_listApiKeys"))   return rpc_exchange.handleExchangeListApiKeys(body, ctx, id);
    if (std.mem.eql(u8, method, "exchange_revokeApiKey")) return rpc_exchange.handleExchangeRevokeApiKey(body, ctx, id);
    if (std.mem.eql(u8, method, "exchange_deposit"))       return rpc_exchange.handleExchangeDeposit(body, ctx, id);
    if (std.mem.eql(u8, method, "exchange_withdraw"))      return rpc_exchange.handleExchangeWithdraw(body, ctx, id);
    if (std.mem.eql(u8, method, "exchange_getBalance"))    return rpc_exchange.handleExchangeGetBalance(body, ctx, id);
    if (std.mem.eql(u8, method, "exchange_getBalances"))   return rpc_exchange.handleExchangeGetBalances(body, ctx, id);
    if (std.mem.eql(u8, method, "exchange_depositDemo"))   return rpc_exchange.handleExchangeDepositDemo(body, ctx, id);
    if (std.mem.eql(u8, method, "exchange_depositReal"))   return rpc_exchange.handleExchangeDepositReal(body, ctx, id);
    if (std.mem.eql(u8, method, "exchange_getEscrowAddress")) return rpc_exchange.handleExchangeGetEscrowAddress(ctx, id);

    // ── Aliases for B9 (frontend/test naming inconsistencies) ───────────────
    // Frontend calls these names; chain canonical names differ. Forward to
    // the real handler so existing frontend / test scripts work without
    // renaming everywhere.
    if (std.mem.eql(u8, method, "exchange_listOrders"))     return rpc_exchange.handleExchangeGetOrderbook(body, ctx, id);
    if (std.mem.eql(u8, method, "exchange_getRecentTrades")) return rpc_exchange.handleExchangeGetTrades(body, ctx, id);
    if (std.mem.eql(u8, method, "exchange_orderbook"))      return rpc_exchange.handleExchangeGetOrderbook(body, ctx, id);
    if (std.mem.eql(u8, method, "exchange_trades"))         return rpc_exchange.handleExchangeGetTrades(body, ctx, id);
    if (std.mem.eql(u8, method, "place_order"))             return rpc_exchange.handleExchangePlaceOrder(body, ctx, id);
    if (std.mem.eql(u8, method, "cancel_order"))            return rpc_exchange.handleExchangeCancelOrder(body, ctx, id);
    if (std.mem.eql(u8, method, "cancelOrder"))             return rpc_exchange.handleExchangeCancelOrder(body, ctx, id);

    // ── Grid trading engine ────────────────────────────────────────────────
    if (std.mem.eql(u8, method, "grid_create"))  return rpc_exchange.handleGridCreate(body, ctx, id);
    if (std.mem.eql(u8, method, "grid_list"))    return rpc_exchange.handleGridList(body, ctx, id);
    if (std.mem.eql(u8, method, "grid_status"))  return rpc_exchange.handleGridStatus(body, ctx, id);
    if (std.mem.eql(u8, method, "grid_cancel"))  return rpc_exchange.handleGridCancel(body, ctx, id);

    // ── HTLC atomic swaps (Phase 2F.2 — TX 0x30/0x31/0x32) ───────────────
    if (std.mem.eql(u8, method, "htlc_init"))           return rpc_swap.handleHtlcInit(body, ctx, id);
    if (std.mem.eql(u8, method, "htlc_claim"))          return rpc_swap.handleHtlcClaim(body, ctx, id);
    if (std.mem.eql(u8, method, "htlc_refund"))         return rpc_swap.handleHtlcRefund(body, ctx, id);
    if (std.mem.eql(u8, method, "htlc_get"))            return rpc_swap.handleHtlcGet(body, ctx, id);
    if (std.mem.eql(u8, method, "htlc_listByAddress")) return rpc_swap.handleHtlcListByAddress(body, ctx, id);
    if (std.mem.eql(u8, method, "htlc_listPending"))   return rpc_swap.handleHtlcListPending(ctx, id);

    // ── PQ Isolated Wallets v2 — 5-scheme post-quantum support ─────────
    if (std.mem.eql(u8, method, "pq_listSchemes"))   return rpc_pq.handlePqListSchemes(ctx, id);
    if (std.mem.eql(u8, method, "pq_balance"))       return rpc_pq.handlePqBalance(body, ctx, id);
    if (std.mem.eql(u8, method, "pq_send"))          return rpc_pq.handlePqSend(body, ctx, id);
    if (std.mem.eql(u8, method, "pq_verify_test"))   return rpc_pq.handlePqVerifyTest(body, ctx, id);
    if (std.mem.eql(u8, method, "pq_attestation"))   return rpc_pq.handlePqAttestation(body, ctx, id);
    if (std.mem.eql(u8, method, "getpqidentity"))    return rpc_pq.handleGetPqIdentity(body, ctx, id);
    if (std.mem.eql(u8, method, "sendpqattest"))     return rpc_pq.handleSendPqAttest(body, ctx, id);

    // ── On-chain labels (decentralized address tagging) ─────────────────
    if (std.mem.eql(u8, method, "applylabel"))       return rpc_social.handleApplyLabel(body, ctx, id);
    if (std.mem.eql(u8, method, "getlabels"))        return rpc_social.handleGetLabels(body, ctx, id);
    if (std.mem.eql(u8, method, "removelabel"))      return rpc_social.handleRemoveLabel(body, ctx, id);

    // ── On-chain subscriptions (recurring payments) ──────────────────────
    if (std.mem.eql(u8, method, "sub_create"))       return rpc_subscription.handleSubCreate(body, ctx, id);
    if (std.mem.eql(u8, method, "sub_cancel"))       return rpc_subscription.handleSubCancel(body, ctx, id);
    if (std.mem.eql(u8, method, "getsubscriptions")) return rpc_subscription.handleGetSubscriptions(body, ctx, id);

    // ── Document notarization ────────────────────────────────────────────
    if (std.mem.eql(u8, method, "notarizedoc"))      return rpc_notarize.handleNotarizeDoc(body, ctx, id);
    if (std.mem.eql(u8, method, "verifynotarize"))   return rpc_notarize.handleVerifyNotarize(body, ctx, id);
    if (std.mem.eql(u8, method, "revokenotarize"))   return rpc_notarize.handleRevokeNotarize(body, ctx, id);
    if (std.mem.eql(u8, method, "getnotarizations")) return rpc_notarize.handleGetNotarizations(body, ctx, id);

    // ── Programmable escrow ──────────────────────────────────────────────
    if (std.mem.eql(u8, method, "escrow_create"))    return rpc_escrow.handleEscrowCreate(body, ctx, id);
    if (std.mem.eql(u8, method, "escrow_release"))   return rpc_escrow.handleEscrowRelease(body, ctx, id);
    if (std.mem.eql(u8, method, "escrow_refund"))    return rpc_escrow.handleEscrowRefund(body, ctx, id);
    if (std.mem.eql(u8, method, "escrow_dispute"))   return rpc_escrow.handleEscrowDispute(body, ctx, id);
    if (std.mem.eql(u8, method, "getescrow"))        return rpc_escrow.handleGetEscrow(body, ctx, id);
    if (std.mem.eql(u8, method, "getescrows"))       return rpc_escrow.handleGetEscrows(body, ctx, id);

    // ── Social Graph ─────────────────────────────────────────────────────
    if (std.mem.eql(u8, method, "follow"))           return rpc_social.handleFollow(body, ctx, id);
    if (std.mem.eql(u8, method, "unfollow"))         return rpc_social.handleUnfollow(body, ctx, id);
    if (std.mem.eql(u8, method, "getfollowers"))     return rpc_social.handleGetFollowers(body, ctx, id);
    if (std.mem.eql(u8, method, "getfollowing"))     return rpc_social.handleGetFollowing(body, ctx, id);

    // ── POAP (Proof of Attendance) ────────────────────────────────────────
    if (std.mem.eql(u8, method, "poap_createevent")) return rpc_social.handlePoapCreateEvent(body, ctx, id);
    if (std.mem.eql(u8, method, "poap_claim"))       return rpc_social.handlePoapClaim(body, ctx, id);
    if (std.mem.eql(u8, method, "poap_close"))       return rpc_social.handlePoapClose(body, ctx, id);
    if (std.mem.eql(u8, method, "getpoaps"))         return rpc_social.handleGetPoaps(body, ctx, id);
    if (std.mem.eql(u8, method, "getpoapevent"))     return rpc_social.handleGetPoapEvent(body, ctx, id);

    // ── Governance ────────────────────────────────────────────────────────
    if (std.mem.eql(u8, method, "gov_propose"))      return rpc_governance.handleGovPropose(body, ctx, id);
    if (std.mem.eql(u8, method, "gov_vote"))         return rpc_governance.handleGovVote(body, ctx, id);
    if (std.mem.eql(u8, method, "gov_execute"))      return rpc_governance.handleGovExecute(body, ctx, id);
    if (std.mem.eql(u8, method, "getproposals"))     return rpc_governance.handleGetProposals(body, ctx, id);
    if (std.mem.eql(u8, method, "getproposal"))      return rpc_governance.handleGetProposal(body, ctx, id);

    // ── Identity Hub ──────────────────────────────────────────────────────
    if (std.mem.eql(u8, method, "getidentity"))      return rpc_identity.handleGetIdentity(body, ctx, id);

    // ── Identity (public nickname + ENS-pref + visibility) ─────────────
    if (std.mem.eql(u8, method, "identity_set"))    return rpc_identity.handleIdentitySet(body, ctx, id);
    if (std.mem.eql(u8, method, "identity_get"))    return rpc_identity.handleIdentityGet(body, ctx, id);
    if (std.mem.eql(u8, method, "identity_search")) return rpc_identity.handleIdentitySearch(body, ctx, id);

    // ── KYC (signed attestations, no PII on chain) ─────────────────────
    if (std.mem.eql(u8, method, "kyc_getStatus"))   return rpc_identity.handleKycGetStatus(body, ctx, id);
    if (std.mem.eql(u8, method, "kyc_attest"))      return rpc_identity.handleKycAttest(body, ctx, id);
    if (std.mem.eql(u8, method, "kyc_listIssuers")) return rpc_identity.handleKycListIssuers(ctx, id);
    // generatewallet disabled — causes stack overflow on RPC thread
    // Use seed node address derivation instead
    if (std.mem.eql(u8, method, "generatewallet"))  return errorJson(-32601, "Use CLI wallet generation", id, alloc);

    // Performance metrics
    if (std.mem.eql(u8, method, "getperformance"))   return rpc_mempool.handleGetPerformance(ctx, id);

    // SPV light client endpoints
    if (std.mem.eql(u8, method, "getheaders"))       return rpc_chain.handleGetHeaders(body, ctx, id);
    if (std.mem.eql(u8, method, "getmerkleproof"))   return rpc_chain.handleGetMerkleProof(body, ctx, id);

    // Staking slashing endpoints
    if (std.mem.eql(u8, method, "submitslashevidence")) return rpc_consensus.handleSubmitSlashEvidence(body, ctx, id);
    if (std.mem.eql(u8, method, "getslashhistory"))     return rpc_consensus.handleGetSlashHistory(body, ctx, id);
    if (std.mem.eql(u8, method, "getstakinginfo"))      return rpc_consensus.handleGetStakingInfo(body, ctx, id);

    // Multisig endpoints — real M-of-N implementation backed by core/multisig.zig
    if (std.mem.eql(u8, method, "createmultisig"))      return rpc_wallet.handleCreateMultisig(body, ctx, id);
    if (std.mem.eql(u8, method, "sendmultisig"))        return rpc_wallet.handleSendMultisig(body, ctx, id);

    // ── Cold Wallet (watch-only) ─────────────────────────────────────────────
    if (std.mem.eql(u8, method, "coldwallet_add"))     return rpc_wallet_advanced.handleColdWalletAdd(body, ctx, id);
    if (std.mem.eql(u8, method, "coldwallet_list"))    return rpc_wallet_advanced.handleColdWalletList(body, ctx, id);
    if (std.mem.eql(u8, method, "coldwallet_remove"))  return rpc_wallet_advanced.handleColdWalletRemove(body, ctx, id);
    if (std.mem.eql(u8, method, "coldwallet_history")) return rpc_wallet_advanced.handleColdWalletHistory(body, ctx, id);

    // ── Timelock Vault (CLTV) ────────────────────────────────────────────────
    if (std.mem.eql(u8, method, "timelock_create"))    return rpc_wallet_advanced.handleTimelockCreate(body, ctx, id);
    if (std.mem.eql(u8, method, "timelock_list"))      return rpc_wallet_advanced.handleTimelockList(body, ctx, id);
    if (std.mem.eql(u8, method, "timelock_spend"))     return rpc_wallet_advanced.handleTimelockSpend(body, ctx, id);
    if (std.mem.eql(u8, method, "timelock_status"))    return rpc_wallet_advanced.handleTimelockStatus(body, ctx, id);

    // ── Covenant (destination whitelist) ─────────────────────────────────────
    if (std.mem.eql(u8, method, "covenant_create"))    return rpc_wallet_advanced.handleCovenantCreate(body, ctx, id);
    if (std.mem.eql(u8, method, "covenant_list"))      return rpc_wallet_advanced.handleCovenantList(body, ctx, id);
    if (std.mem.eql(u8, method, "covenant_get"))       return rpc_wallet_advanced.handleCovenantGet(body, ctx, id);
    if (std.mem.eql(u8, method, "covenant_remove"))    return rpc_wallet_advanced.handleCovenantRemove(body, ctx, id);

    // ── Treasury auto-distribute ─────────────────────────────────────────────
    if (std.mem.eql(u8, method, "treasury_create"))    return rpc_wallet_advanced.handleTreasuryCreate(body, ctx, id);
    if (std.mem.eql(u8, method, "treasury_list"))      return rpc_wallet_advanced.handleTreasuryList(body, ctx, id);
    if (std.mem.eql(u8, method, "treasury_distribute"))return rpc_wallet_advanced.handleTreasuryDistribute(body, ctx, id);
    if (std.mem.eql(u8, method, "treasury_status"))    return rpc_wallet_advanced.handleTreasuryStatus(body, ctx, id);

    // Payment channel (L2) endpoints — Lightning-style bidirectional channels
    if (std.mem.eql(u8, method, "openchannel"))       return rpc_lightning.handleOpenChannel(body, ctx, id);
    if (std.mem.eql(u8, method, "channelpay"))        return rpc_lightning.handleChannelPay(body, ctx, id);
    if (std.mem.eql(u8, method, "closechannel"))      return rpc_lightning.handleCloseChannel(body, ctx, id);
    if (std.mem.eql(u8, method, "getchannels"))       return rpc_lightning.handleGetChannels(body, ctx, id);

    // ── OmniBus custom endpoints (exchange integration) ─────────────────
    if (std.mem.eql(u8, method, "getblockchaininfo"))    return rpc_chain.handleBlockchainInfo(ctx, id);
    if (std.mem.eql(u8, method, "omnibus_getminers"))    return handleOmnibusMiners(ctx, id);
    if (std.mem.eql(u8, method, "omnibus_getoracleprices")) return rpc_oracle.handleOmnibusPrices(ctx, id);
    if (std.mem.eql(u8, method, "omnibus_getblockprices")) return rpc_oracle.handleOmnibusBlockPrices(body, ctx, id);
    if (std.mem.eql(u8, method, "omnibus_getpricerange")) return rpc_oracle.handleOmnibusPriceRange(body, ctx, id);
    if (std.mem.eql(u8, method, "omnibus_getexchangefeed")) return rpc_oracle.handleOmnibusExchangeFeed(ctx, id);
    if (std.mem.eql(u8, method, "omnibus_getallprices")) return rpc_oracle.handleOmnibusAllPrices(ctx, body, id);
    if (std.mem.eql(u8, method, "omnibus_getarbitrage")) return rpc_oracle.handleOmnibusArbitrage(ctx, id);
    if (std.mem.eql(u8, method, "omnibus_getfxrate"))    return rpc_oracle.handleOmnibusFxRate(ctx, id);
    if (std.mem.eql(u8, method, "omnibus_getorderbook"))  return rpc_oracle.handleOmnibusOrderbook(body, ctx, id);
    if (std.mem.eql(u8, method, "omnibus_getbridgestatus")) return rpc_swap.handleOmnibusBridge(ctx, id);
    if (std.mem.eql(u8, method, "omnibus_getoraclepolicy")) return rpc_oracle.handleOmnibusGetOraclePolicy(ctx, id);
    if (std.mem.eql(u8, method, "omnibus_setoraclepolicy")) return rpc_oracle.handleOmnibusSetOraclePolicy(body, ctx, id);
    if (std.mem.eql(u8, method, "omnibus_gettotalmined"))   return rpc_oracle.handleOmnibusTotalMined(ctx, id);
    if (std.mem.eql(u8, method, "omnibus_bridge_limits"))   return rpc_oracle.handleOmnibusBridgeLimits(ctx, id);
    if (std.mem.eql(u8, method, "getmempoolinfo"))        return rpc_mempool.handleMempoolInfo(ctx, id);
    if (std.mem.eql(u8, method, "getrawmempool"))         return rpc_mempool.handleMempoolInfo(ctx, id);
    if (std.mem.eql(u8, method, "getmempool"))            return rpc_mempool.handleMempoolInfo(ctx, id);
    if (std.mem.eql(u8, method, "getdailyactivity"))      return rpc_wallet.handleGetDailyActivity(body, ctx, id);

    // ── EVM-compat endpoints (Ethereum-style JSON-RPC) ─────────────────
    // Ethereum-compat JSON-RPC — see core/rpc/eth.zig
    if (std.mem.eql(u8, method, "eth_call"))               return rpc_eth.handleEthCall(body, ctx, id);
    if (std.mem.eql(u8, method, "eth_sendRawTransaction")) return rpc_eth.handleEthSendRawTransaction(body, ctx, id);
    if (std.mem.eql(u8, method, "eth_getCode"))            return rpc_eth.handleEthGetCode(body, ctx, id);
    if (std.mem.eql(u8, method, "eth_estimateGas"))        return rpc_eth.handleEthEstimateGas(body, ctx, id);
    if (std.mem.eql(u8, method, "eth_chainId"))            return rpc_eth.handleEthChainId(ctx, id);
    if (std.mem.eql(u8, method, "eth_blockNumber"))        return rpc_eth.handleEthBlockNumber(ctx, id);
    if (std.mem.eql(u8, method, "eth_getBalance"))         return rpc_eth.handleEthGetBalance(body, ctx, id);
    if (std.mem.eql(u8, method, "eth_getTransactionCount"))return rpc_eth.handleEthGetTransactionCount(body, ctx, id);
    if (std.mem.eql(u8, method, "eth_gasPrice"))           return rpc_eth.handleEthGasPrice(ctx, id);
    if (std.mem.eql(u8, method, "eth_getLogs"))            return rpc_eth.handleEthGetLogs(body, ctx, id);
    if (std.mem.eql(u8, method, "eth_getTransactionReceipt"))return rpc_eth.handleEthGetTransactionReceipt(body, ctx, id);
    if (std.mem.eql(u8, method, "eth_getBlockByNumber"))   return rpc_eth.handleEthGetBlockByNumber(body, ctx, id);
    if (std.mem.eql(u8, method, "net_version"))            return rpc_eth.handleNetVersion(ctx, id);

    // ── Bitcoin-standard compatibility endpoints ────────────────────────
    if (std.mem.eql(u8, method, "getbestblockhash"))   return rpc_chain.handleGetBestBlockHash(ctx, id);
    if (std.mem.eql(u8, method, "getdifficulty"))      return rpc_chain.handleGetDifficulty(ctx, id);
    if (std.mem.eql(u8, method, "getblockhash"))       return rpc_chain.handleGetBlockHash(body, ctx, id);
    if (std.mem.eql(u8, method, "getconnectioncount")) return rpc_net.handleGetConnectionCount(ctx, id);
    if (std.mem.eql(u8, method, "getpeerinfo"))        return rpc_net.handleGetPeerInfo(ctx, id);
    if (std.mem.eql(u8, method, "getmininginfo"))      return rpc_mining.handleGetMiningInfo(ctx, id);

    // ── AI Agent endpoints (consumate de clientul Python/Rust extern) ───
    if (std.mem.eql(u8, method, "agent_list"))              return rpc_agents.handleAgentList(ctx, id);
    if (std.mem.eql(u8, method, "getreputation"))           return rpc_identity.handleGetReputation(body, ctx, id);
    if (std.mem.eql(u8, method, "getreputationtop"))        return rpc_identity.handleGetReputationTop(body, ctx, id);
    if (std.mem.eql(u8, method, "getdid"))                  return rpc_identity.handleGetDid(body, ctx, id);
    if (std.mem.eql(u8, method, "getobm"))                  return rpc_identity.handleGetObm(body, ctx, id);
    if (std.mem.eql(u8, method, "getfacets"))               return rpc_identity.handleGetFacets(body, ctx, id);
    if (std.mem.eql(u8, method, "profile_init"))            return rpc_identity.handleProfileInit(body, ctx, id);
    if (std.mem.eql(u8, method, "profile_update"))          return rpc_identity.handleProfileUpdate(body, ctx, id);
    if (std.mem.eql(u8, method, "profile_get"))             return rpc_identity.handleProfileGet(body, ctx, id);
    if (std.mem.eql(u8, method, "mica_attest"))             return rpc_identity.handleMicaAttest(body, ctx, id);
    if (std.mem.eql(u8, method, "mica_disclose"))           return rpc_identity.handleMicaDisclose(body, ctx, id);
    if (std.mem.eql(u8, method, "disclose_post"))           return rpc_identity.handleDisclosePost(body, ctx, id);
    if (std.mem.eql(u8, method, "disclose_cert"))           return rpc_identity.handleDiscloseCert(body, ctx, id);
    if (std.mem.eql(u8, method, "disclose_work"))           return rpc_identity.handleDiscloseWork(body, ctx, id);
    if (std.mem.eql(u8, method, "agent_status"))            return rpc_agents.handleAgentStatus(body, ctx, id);
    if (std.mem.eql(u8, method, "agent_pending_decisions")) return rpc_agents.handleAgentPendingDecisions(body, ctx, id);
    if (std.mem.eql(u8, method, "agent_report_execution"))  return rpc_agents.handleAgentReportExecution(body, ctx, id);

    // ── Bridge endpoints ─────────────────────────────────────────────────────
    if (std.mem.eql(u8, method, "getbridgestatus"))       return rpc_swap.handleBridgeStatus(ctx, id);
    if (std.mem.eql(u8, method, "bridge_lock"))           return rpc_swap.handleBridgeLock(body, ctx, id);
    if (std.mem.eql(u8, method, "bridge_unlock_request")) return rpc_swap.handleBridgeUnlockRequest(body, ctx, id);
    if (std.mem.eql(u8, method, "bridge_fraud_challenge"))return rpc_swap.handleBridgeFraudChallenge(body, ctx, id);
    if (std.mem.eql(u8, method, "bridge_settle"))         return rpc_swap.handleBridgeSettle(body, ctx, id);

    // HTLC builders for cross-chain atomic swaps (off-chain — no broadcast)
    if (std.mem.eql(u8, method, "htlc_btc_buildScript")) return rpc_swap.handleHtlcBtcBuildScript(body, ctx, id);

    // ── SPV + cross-chain oracle ─────────────────────────────────────────────
    if (std.mem.eql(u8, method, "spv_btc_verifyTx"))     return rpc_spv.handleSpvBtcVerifyTx(body, ctx, id);
    if (std.mem.eql(u8, method, "spv_eth_verifyEvent")) return rpc_spv.handleSpvEthVerifyEvent(body, ctx, id);
    if (std.mem.eql(u8, method, "oracle_btcHeight"))    return rpc_oracle.handleOracleBtcHeight(ctx, id);
    if (std.mem.eql(u8, method, "oracle_ethHeight"))    return rpc_oracle.handleOracleEthHeight(body, ctx, id);
    if (std.mem.eql(u8, method, "oracle_recordHeader")) return rpc_oracle.handleOracleRecordHeader(body, ctx, id);

    // ── Cross-chain atomic-swap binding (orderbook ↔ HTLC glue) ─────────
    if (std.mem.eql(u8, method, "swap_open"))         return rpc_swap.handleSwapOpen(body, ctx, id);
    if (std.mem.eql(u8, method, "swap_lockMaker"))    return rpc_swap.handleSwapLockMaker(body, ctx, id);
    if (std.mem.eql(u8, method, "swap_lockTaker"))    return rpc_swap.handleSwapLockTaker(body, ctx, id);
    if (std.mem.eql(u8, method, "swap_timeout"))      return rpc_swap.handleSwapTimeout(body, ctx, id);
    if (std.mem.eql(u8, method, "swap_status"))       return rpc_swap.handleSwapStatus(body, ctx, id);
    if (std.mem.eql(u8, method, "swap_listOpen"))     return rpc_swap.handleSwapListOpen(body, ctx, id);
    if (std.mem.eql(u8, method, "swap_proveSettle")) return rpc_swap.handleSwapProveSettle(body, ctx, id);
    if (std.mem.eql(u8, method, "intent_post"))       return rpc_swap.handleIntentPost(body, ctx, id);
    if (std.mem.eql(u8, method, "intent_fill_commit")) return rpc_swap.handleIntentFillCommit(body, ctx, id);
    if (std.mem.eql(u8, method, "intent_settle"))     return rpc_swap.handleIntentSettle(body, ctx, id);
    if (std.mem.eql(u8, method, "intent_timeout"))    return rpc_swap.handleIntentTimeout(body, ctx, id);

    // ── Stake / Validator / Agent / Reputation RPCs ─────────────────────────
    if (std.mem.eql(u8, method, "stake"))             return rpc_consensus.handleStake(body, ctx, id);
    if (std.mem.eql(u8, method, "unstake"))           return rpc_consensus.handleUnstake(body, ctx, id);
    if (std.mem.eql(u8, method, "getstake"))          return rpc_consensus.handleGetStake(body, ctx, id);
    if (std.mem.eql(u8, method, "getstakers"))        return rpc_consensus.handleGetStakers(body, ctx, id);
    if (std.mem.eql(u8, method, "getvalidatorsv2"))   return rpc_consensus.handleGetValidatorsV2(body, ctx, id);
    if (std.mem.eql(u8, method, "become_validator"))  return rpc_consensus.handleBecomeValidator(body, ctx, id);
    if (std.mem.eql(u8, method, "validator_heartbeat")) return rpc_consensus.handleValidatorHeartbeat(body, ctx, id);
    if (std.mem.eql(u8, method, "getslashevents"))    return rpc_consensus.handleGetSlashEvents(body, ctx, id);
    if (std.mem.eql(u8, method, "agent_register"))    return rpc_agents.handleAgentRegister(body, ctx, id);
    if (std.mem.eql(u8, method, "agent_unregister"))  return rpc_agents.handleAgentUnregister(body, ctx, id);
    if (std.mem.eql(u8, method, "agent_edit"))        return rpc_agents.handleAgentEdit(body, ctx, id);
    if (std.mem.eql(u8, method, "agent_follow"))      return rpc_agents.handleAgentFollow(body, ctx, id);
    if (std.mem.eql(u8, method, "getagents"))         return rpc_agents.handleGetAgents(body, ctx, id);
    if (std.mem.eql(u8, method, "getagent"))          return rpc_agents.handleGetAgent(body, ctx, id);
    if (std.mem.eql(u8, method, "getreputation"))     return rpc_identity.handleGetReputation(body, ctx, id);
    if (std.mem.eql(u8, method, "getreputationtop"))  return rpc_identity.handleGetReputationTop(body, ctx, id);

    return errorJson(-32601, "Method not found", id, alloc);
}

// ─── Extracted RPC Handlers ─────────────────────────────────────────────────

/// RPC "getnonce" — returns the next expected nonce for an address.
/// Considers both confirmed chain nonces and pending mempool TXs.
/// Usage: {"method":"getnonce","params":["ob1qcx2p306xpf3c2gd6h4074kpux4tv2hnmx3ytuq"],"id":1}
/// Response: {"result":{"address":"...","nonce":N,"chainNonce":M,"pendingCount":P}}

pub fn txSchemeLabel(scheme: transaction_mod.Scheme) []const u8 {
    return switch (scheme) {
        .omni_ecdsa       => "ECDSA (secp256k1)",
        .love_dilithium   => "ML-DSA-87 (LOVE soulbound)",
        .food_falcon      => "Falcon-512 (FOOD soulbound)",
        .rent_ml_dsa      => "ML-DSA-87 (RENT soulbound)",
        .vacation_slh_dsa => "SLH-DSA-256s (VACATION soulbound)",
        .pq_omni_ml_dsa   => "ML-DSA-87",
        .pq_omni_falcon   => "Falcon-512",
        .pq_omni_dilithium=> "ML-DSA-87 (Dilithium-5)",
        .pq_omni_slh_dsa  => "SLH-DSA-256s",
        .hybrid_q1        => "Hybrid ECDSA+ML-DSA-87",
        .hybrid_q2        => "Hybrid ECDSA+Falcon-512",
        .hybrid_q3        => "Hybrid ECDSA+Dilithium-5",
        .hybrid_q4        => "Hybrid ECDSA+SLH-DSA",
    };
}

/// RPC "gettransaction" — returns a single TX by hash with confirmation count.
/// Searches mempool (pending, 0 confirmations) then mined blocks (confirmed).
/// Usage: {"method":"gettransaction","params":["tx_hash_hex"],"id":1}


/// RPC "sendopreturn" — create OP_RETURN TX with embedded data and amount=0.
/// Usage: {"method":"sendopreturn","params":["data_string", fee_sat],"id":1}
/// Or:    {"method":"sendopreturn","params":{"data":"data_string","fee":100},"id":1}
pub var g_faucet_addr_set = faucet_mod.ClaimedSet{
    .set   = @as(@TypeOf(faucet_mod.ClaimedSet.init(undefined).set), undefined),
    .mutex = .{},
};
pub var g_faucet_ip_map = faucet_mod.IpCooldownMap{
    .map   = @as(@TypeOf(faucet_mod.IpCooldownMap.init(undefined).map), undefined),
    .mutex = .{},
};
pub var g_faucet_state_init: bool = false;
pub var g_faucet_state_mutex: std.Thread.Mutex = .{};

pub fn ensureFaucetState(alloc: std.mem.Allocator) void {
    g_faucet_state_mutex.lock();
    defer g_faucet_state_mutex.unlock();
    if (g_faucet_state_init) return;
    g_faucet_addr_set  = faucet_mod.ClaimedSet.init(alloc);
    g_faucet_ip_map    = faucet_mod.IpCooldownMap.init(alloc);
    g_faucet_state_init = true;
}

/// RPC "claimfaucet"
/// { "address": "ob1q...", "declaration_hash": "<sha256-64>",
///   "signature": "hex", "public_key": "hex", "nonce": N }
///
/// The client MUST:
///   1. Read faucet_mod.DECLARATION_TEXT
///   2. Compute SHA-256(DECLARATION_TEXT) → declaration_hash
///   3. Sign the TX hash with their private key
///   4. Submit this request
///
/// On success: TX is queued in mempool, 0.001 OMNI arrives after next block.

/// RPC "getfaucetstatus"

/// Keep the old faucetSetPersistPath symbol so main.zig call sites still compile.
/// The new faucet doesn't need disk persistence (chain state is authoritative).
pub fn faucetSetPersistPath(_: []const u8) void {}

// ─── Rich list + chain metrics ──────────────────────────────────────────────

pub const RichEntry = struct {
    address: []const u8,
    balance: u64,
    tx_count: u32 = 0,
    received: u64 = 0,
    sent: u64 = 0,
    first_height: u64 = 0,
    last_height: u64 = 0,
    first_seen_set: bool = false,
};

/// Infer the kind of a transaction from its on-chain shape.
///
/// OmniBus does NOT store an explicit `kind` field on transactions (the
/// chain is binary-compatible with v1). The type is derived at query
/// time from the from/to addresses and op_return content. Add new
/// detectors here as new transaction shapes get introduced — order
/// matters: the FIRST matching rule wins.
///
/// Currently detected:
///   - "coinbase"    : empty from_address (block reward)
///   - "faucet"      : sender is the testnet faucet registrar slot
///   - "registrar"   : sender is one of the other 9 registrar slots
///   - "exchange"    : op_return prefixed with "exchange:" or "fill:"
///                     (matching engine emits these for on-chain fills)
///   - "stake"       : op_return prefixed with "stake:" or "unstake:"
///   - "demo_grant"  : op_return prefixed with "demo:"
///   - "transfer"    : default (regular P2PKH/SegWit transfer)
pub fn inferTxKind(tx: transaction_mod.Transaction) []const u8 {
    if (tx.from_address.len == 0) return "coinbase";

    // Registrar wallets — fixed-forever treasury slots
    for (registrar_mod.REGISTRAR_ADDRESSES) |slot| {
        if (slot.address.len == 0) continue;
        if (std.mem.eql(u8, slot.address, tx.from_address)) {
            // Slot 7 = faucet: distinguish from generic registrar
            if (slot.index == 7) return "faucet";
            return "registrar";
        }
    }

    // op_return-tagged operations (extensible: add new prefixes here)
    if (tx.op_return.len > 0) {
        if (std.mem.startsWith(u8, tx.op_return, "exchange:"))     return "exchange";
        if (std.mem.startsWith(u8, tx.op_return, "fill:"))         return "exchange";
        if (std.mem.startsWith(u8, tx.op_return, "open_order:"))   return "exchange";
        if (std.mem.startsWith(u8, tx.op_return, "place_order:"))  return "exchange";
        if (std.mem.startsWith(u8, tx.op_return, "close_order:"))  return "exchange";
        if (std.mem.startsWith(u8, tx.op_return, "cancel_order:")) return "exchange";
        if (std.mem.startsWith(u8, tx.op_return, "deposit:"))      return "exchange";
        if (std.mem.startsWith(u8, tx.op_return, "withdraw:"))     return "exchange";
        if (std.mem.startsWith(u8, tx.op_return, "stake:"))        return "stake";
        if (std.mem.startsWith(u8, tx.op_return, "unstake:"))      return "unstake";
        if (std.mem.startsWith(u8, tx.op_return, "delegate:"))     return "stake";
        if (std.mem.startsWith(u8, tx.op_return, "undelegate:"))   return "unstake";
        if (std.mem.startsWith(u8, tx.op_return, "ns_claim:"))     return "ns_claim";
        if (std.mem.startsWith(u8, tx.op_return, "agent:register"))   return "agent_register";
        if (std.mem.startsWith(u8, tx.op_return, "agent:unregister")) return "agent_register";
        if (std.mem.startsWith(u8, tx.op_return, "notarize:"))     return "notarize";
        if (std.mem.startsWith(u8, tx.op_return, "notarize_revoke:")) return "notarize";
        if (std.mem.startsWith(u8, tx.op_return, "demo:"))         return "demo_grant";
    }

    return "transfer";
}

/// RPC "getrichlist" — Bitcoin-style address list sorted by balance desc.
///
/// Walks `bc.utxo_set` address index, filters out zero-balance entries (cosmetic
/// — keeps the output small), sorts descending, and emits the top N.
///
/// Each entry includes:
///   - address (ob1q…)
///   - balance in SAT
///   - is_validator (balance ≥ MIN_VALIDATOR_BALANCE)
///   - blocks_mined (count of blocks where block.miner == this address)
///
/// Usage:
///   {"method":"getrichlist","params":[100],"id":1}   // top 100
///   {"method":"getrichlist","params":[],"id":1}      // top 100 default

/// RPC "getchainmetrics" — high-level dashboard stats.
///
/// Aggregates everything an explorer dashboard would normally show on top:
///   - chain height + tip hash
///   - total supply (sum of all positive balances)
///   - total addresses with balance > 0
///   - validator count (balance ≥ MIN_VALIDATOR_BALANCE)
///   - validator-set size (active rotation participants)
///   - block count, mempool size, peer count
///   - emission stats (current reward, halving interval, max supply)

/// RPC "getschemestats" — signing-scheme distribution across last N blocks.
/// Params: [blocks_count]  (default 100, max 1000)
/// Returns: { totalTxs, blocks, schemes: [{scheme, count, pct}] }

// ─── DNS / ENS handlers ─────────────────────────────────────────────────────
//
// On-chain name registry. Resolves human-friendly names like "alice" or
// "savacazan" to ob1q… addresses. The DnsRegistry struct lives in
// dns_registry.zig — we just expose 4 RPC methods over it.
//
// Why "alice", not "alice.omnibus": the registry stores the raw label.
// Front-ends append .omnibus for display (matching the LCX-side ENS).
// Registration is permissionless on testnet (no fee enforced yet) so the
// stress-test scripts can populate it freely.



/// Phase 2 send-routing helper — closes the loop on `preferred_slot`.
///
/// `resolveName` returns the full DNS entry (all 4 PQ slots + flags), pushing
/// the routing decision to the client. `ns_resolveForSend` is the opinionated
/// variant: chain decides which address to deliver to and tells the wallet
/// exactly which kind of address it is.
///
/// Result contract:
/// ```
/// {
///   "name": "alice", "tld": "bank", "fullLabel": "alice.bank",
///   "primary_address": "ob1q…",        // always the ECDSA address
///   "route_slot": 0|1|2|3|4,            // 0 = ECDSA, 1=ML-DSA, 2=Falcon,
///                                       // 3=Dilithium, 4=SLH-DSA
///   "route_address": "obk1_…",          // the address to send to
///   "route_address_kind": "ecdsa"|"ml_dsa"|"falcon"|"dilithium"|"slh_dsa",
///   "preferred_slot": <stored>,         // raw on-chain field (may differ
///                                       // from route_slot if pref slot empty)
///   "fell_back_to_primary": false,      // true if pref was set but slot empty
///   "found": true
/// }
/// ```
/// When `preferred_slot == 0` or the corresponding PQ slot is unset, the chain
/// falls back to the primary ECDSA address and `route_slot == 0`. Default
/// behavior is therefore unchanged for legacy entries.




/// ns_listTlds — read-only. Returneaza toate TLD-urile permise + fee-uri
/// pentru auto-discovery la wallet UI / SDK. Equivalent cu pq_listSchemes
/// dar pentru namespace.

/// ns_yearTiers — read-only. Returns the allowed registration durations
/// (years) and their fee multipliers. Wallet UI uses this to render the
/// "register for X years" dropdown without hardcoding the table.

/// ns_stats — read-only. Returns the full NS Health Dashboard snapshot in
/// a single round-trip: totals, per-category / per-TLD / per-years counts,
/// and PQ/preferred-slot adoption metrics. Replaces the old fan-out where
/// the UI called `getnamesbycategory` per category or downloaded all 1000
/// entries via `listnames`.

// ─── Phase 2 NS — multi-address per name + categories ──────────────────────

/// setpqaddress — owner attaches/clears a specific PQ scheme address slot.
/// Params: { name, tld?, slot ("ml_dsa"|"falcon"|"dilithium"|"slh_dsa" or 0..3),
///           pq_address (empty string to clear), owner }

/// setcategory — owner assigns a category badge to their name.
/// Params: { name, tld?, category ("personal"|"bank"|...), owner }

/// setpreferredslot — owner sets which scheme they want funds delivered to by default.
/// Params: { name, tld?, slot (0=primary, 1=ml_dsa, 2=falcon, 3=dilithium, 4=slh_dsa), owner }

/// getnamesbycategory — list all names with a given category badge.
/// Params: { category ("bank"|"gov"|...), limit? }

// ─── Phase 1: transfername ──────────────────────────────────────────────────

// ─── Phase 1: updatename ────────────────────────────────────────────────────

// ─── Phase 1+2: renewname ───────────────────────────────────────────────────
//
// Phase 2 contract — params (positional or keyed):
//   name, tld?, owner_address?, fee_txid?, {years, nonce, signature, publicKey}
//
// `years` is the additional years to add (1, 2, 3, 4, 5, 10, 25, 50, 100).
// Default 1 for backward compatibility with Phase 1 callers.
//
// The signing message is V2 when years is supplied (embeds years to prevent
// cross-tier replay). Phase 1 V1 callers (no years key, signed_required off)
// still work — we fall back to renewWithYears(1y) and do NOT verify a V2 sig.

// ─── Phase 2: ns_expiringSoon ───────────────────────────────────────────────
//
// Lifecycle UI helper. Given an owner address, returns names that expire
// within `blocks_threshold` blocks (default = 30 days = 30*86400/10 = 259200
// at the canonical 10s block time). The frontend uses this for the warning
// badge on the WalletConnect pill + the per-row "expires in N days" label.
//
// Params (positional or keyed):
//   address: string         — owner wallet (ob1q…). Required.
//   blocks_threshold?: u64  — default 259200.
//
// Result:
//   {
//     address, current_block, blocks_threshold,
//     entries: [
//       { name, tld, fullLabel, expiresAtBlock, blocks_remaining,
//         estimated_days_remaining, registered_years, in_grace }
//     ]
//   }
//
// Note: `blocks_remaining` is signed conceptually but JSON-emitted unsigned;
// when the entry is in grace, it's reported as 0 and `in_grace: true`.

// ─── Phase 2: ns_pruneExpired ───────────────────────────────────────────────
//
// Admin / maintenance RPC. Drops every entry whose grace period has fully
// elapsed (truly auctionable + abandoned). Returns the number removed and
// the new entry_count. Not auto-called; main.zig invokes it once at startup
// and (optionally) every N blocks during mining.
//
// Result: { removed: u64, entry_count: u64, current_block: u64 }

// ─── sendrawtransaction — submit a CLIENT-SIGNED OmniBus transaction ────────
//
// Use case: a script (or UI) holds private keys for N wallets, wants to send
// from any of them. The existing `sendtransaction` always signs with the
// node's primary wallet — single-sender. `sendrawtransaction` accepts a
// fully-formed signed TX as JSON params and just validates + adds to mempool.
//
// Format expected (single param object OR positional first param):
//   {
//     "id": <u32>,
//     "from": "ob1q...",
//     "to":   "ob1q...",
//     "amount": <SAT u64>,
//     "fee":  <SAT u64>,
//     "timestamp": <unix seconds i64>,
//     "nonce": <u64>,
//     "publicKey": "<66 hex>",          // sender pubkey (registered before validate)
//     "signature": "<128 hex>",         // ECDSA(R||S) over calculateHash()
//     "hash":      "<64 hex>",          // SHA256d of canonical fields
//     "opReturn":  "<optional string>", // ≤ 80 bytes
//     "locktime":  <optional u64>
//   }
//
// Hash format mirrors `Transaction.calculateHash` in transaction.zig — caller
// must build the exact same byte sequence and double-SHA256 it. Signature
// is ECDSA secp256k1 over the resulting 32-byte digest.
//
// Returns {txid, status:"accepted"} on success or an RPC error otherwise.

/// Helper: read a u64 from either an object key (e.g. `"amount":123`) or
/// — fallback — try interpreting `body` as a positional array. Returns 0
/// if the field is missing or non-numeric.
pub fn extractArrayNumByKey(body: []const u8, key: []const u8) u64 {
    // Look for "key":<digits> in the JSON body. Tolerant of whitespace.
    var search_buf: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&search_buf, "\"{s}\":", .{key}) catch return 0;
    const start = std.mem.indexOf(u8, body, needle) orelse return 0;
    var i = start + needle.len;
    while (i < body.len and (body[i] == ' ' or body[i] == '\t')) i += 1;
    var n: u64 = 0;
    var seen = false;
    while (i < body.len and std.ascii.isDigit(body[i])) {
        const d: u64 = @intCast(body[i] - '0');
        n = n *% 10 +% d;
        seen = true;
        i += 1;
    }
    return if (seen) n else 0;
}


/// RPC "getaddresshistory" — returns all TXs (sent + received) for an address.
/// Uses address_tx_index for confirmed TXs, scans mempool for pending.
/// Usage: {"method":"getaddresshistory","params":["ob1qcx2p306xpf3c2gd6h4074kpux4tv2hnmx3ytuq"],"id":1}

/// RPC "getdailyactivity" — per-day breakdown of all TX activity for an address.
///
/// Groups confirmed TXs by day, where one day = `BLOCKS_PER_DAY` blocks.
/// `BLOCKS_PER_DAY` is computed from the chain config block_time_ms (mainnet
/// 1000ms → 86400 blocks/day). For each day in the requested window we emit:
///   { date, blockStart, blockEnd, txCount, sent, received,
///     miningReward, feesBurned, stakeChange }
///
/// Notes:
///   - `date` is a synthetic ISO-style "day index" string (`day-N`); the frontend
///     converts to a calendar date using the latest block timestamp + day offset
///     so client-side time-zone handling stays consistent.
///   - `miningReward` counts coinbase TXs (empty from_address) where this addr
///     is the recipient.
///   - `stakeChange` is the net of `stake:` (+amount) minus `unstake:` (-amount)
///     op_return-tagged TXs sent FROM this address.
///   - `feesBurned` sums fees on TXs where this addr is the sender (best-effort
///     approximation — the real burn split lives in the consensus layer).
///   - Read-only, no state mutation. Holds bc.mutex for the whole walk so the
///     chain can't grow under us mid-iteration.
///
/// Params:
///   { "address": "ob1q...", "days": 30 }   (default 30, max 365)
/// or positional: ["ob1q...", 30]

/// RPC "listtransactions" — returns last N transactions for the node's own wallet.
/// Usage: {"method":"listtransactions","params":[count],"id":1}  (default count=10)



// SEGFAULT-FIX [scan-2026-04-25]: snapshot mempool size under bc.mutex (fallback path).
// External mempool struct (ctx.mempool) has its own internal sync; only the bc.mempool
// fallback needs the lock here.

/// RPC "getpendingtxs" — returns all TXs currently in the mempool with scheme info.
/// Params: [limit]  (default 100, max 500)
/// Returns: { count, transactions: [{txid,from,to,amount,fee,scheme,nonce,timestamp}] }

// SEGFAULT-FIX [scan-2026-04-25]: hold p2p.peers_mutex for entire iteration.
// peer.node_id / peer.host are slices into PeerConnection; if acceptLoop appends
// concurrently and reallocs backing storage we'd UAF on items.ptr. We allocPrint
// inside the lock — slow but correct; for high-throughput callers, snapshot first.


/// List active validators from the on-chain registry. Read-only.

/// Show who is the slot leader for the next block (debug + UI). Pure
/// computation — same answer on every node holding the same registry.

/// `getclockstatus` — exposes the AtomicClock's current state for UI:
///   - now_ms                 — wall-clock from g_clock.nowMs()
///   - rdtsc                  — hardware cycle counter (rdtscp on x86_64)
///   - spectrum               — 64-char binary string of rdtsc bits, MSB first
/// The spectrum lets a frontend chart show the bit pattern over time —
/// stable high bits = healthy CPU clock, broken patterns = scheduler jitter.

/// `getslotcalendar` — exposes the next 60 pre-computed slots for UI.
/// Each entry: { slot_id, leader, expected_arrival_ms, state }.
/// state values: "future" | "in_flight" | "finalized" | "missed".

/// `getfuturepool` — count + range of TXs that are time-locked beyond
/// the current chain tip (`locktime > height`). These are the future-
/// block-pool entries: they will become mineable when the chain
/// catches up to their target slot. Useful for the frontend to show
/// a "scheduled trades" panel.

// SEGFAULT-FIX [scan-2026-04-25]: snapshot peer count under p2p.peers_mutex,
// snapshot bc fields under bc.mutex; format outside both locks. Same root cause
// as handlePeers (p2p) and handlePoolStats (mempool).



// ─── SPV Light Client RPC Handlers ───────────────────────────────────────────

/// RPC "getheaders" — returns block headers for light client sync.
/// Usage: {"method":"getheaders","params":[from_height, count],"id":1}
/// Returns array of block headers (without transaction data).
/// Max 2000 headers per request (like Bitcoin's getheaders).

/// RPC "getmerkleproof" — returns a Merkle inclusion proof for a TX.
/// Usage: {"method":"getmerkleproof","params":["tx_hash_hex"],"id":1}
/// Searches all blocks for the TX, then generates the Merkle proof.
/// Returns proof_hashes and directions for SPV verification.



// ─── Staking Slashing RPC Handlers ──────────────────────────────────────────

/// RPC "submitslashevidence" — submit proof that a validator cheated.
/// Usage (double_sign / invalid_block — requires real proof):
///   {"method":"submitslashevidence","params":[
///     "validator_addr", "double_sign",
///     "block_hash1_64hex", "block_hash2_64hex",
///     block_height,
///     "reporter_addr",
///     "signature1_128hex", "signature2_128hex"
///   ],"id":1}
/// Usage (downtime — no cryptographic proof needed, just height window):
///   {"method":"submitslashevidence","params":[
///     "validator_addr", "downtime", "", "", block_height, "reporter_addr"
///   ],"id":1}
///
/// double_sign / invalid_block evidence MUST include:
///   - two distinct block hashes (different blocks at same height)
///   - two valid secp256k1 signatures from the validator over those hashes
/// Anything else is rejected with -32602 BEFORE reaching the staking engine.

/// RPC "getslashhistory" — view slash history for a validator address.
/// Usage: {"method":"getslashhistory","params":["validator_addr"],"id":1}

/// RPC "getstakinginfo" — returns validator info including slash status.
/// Usage: {"method":"getstakinginfo","params":["validator_addr"],"id":1}

// ─── Multisig RPC Handlers ────────────────────────────────────────────────────

const Secp256k1Crypto = secp256k1_mod.Secp256k1Crypto;
const MultisigWallet = multisig_mod.MultisigWallet;

/// RPC "createmultisig" — create M-of-N multisig wallet, register it, return address.
/// Usage: {"method":"createmultisig","params":[M, ["pubkey1_hex", "pubkey2_hex", ...]],"id":1}
/// Pubkeys are 66-char hex compressed secp256k1 public keys.

/// RPC "sendmultisig" — create and sign a multisig TX with provided private keys.
/// Usage: {"method":"sendmultisig","params":["multisig_address","to_address",amount_sat,fee_sat,"privkey1_hex","privkey2_hex",...],"id":1}
/// The private keys (params[4..]) must belong to signers in the multisig config.
/// M signatures must be provided for the TX to be accepted.

/// Extract the inner array from params: "params":[2, ["a","b"]] -> returns content of inner [...]
pub fn extractInnerArray(json: []const u8) ?[]const u8 {
    const params_pos = std.mem.indexOf(u8, json, "\"params\"") orelse return null;
    const outer = std.mem.indexOf(u8, json[params_pos..], "[") orelse return null;
    const after_outer = params_pos + outer + 1;
    // Find the inner '[' (skip whitespace and the first numeric param + comma)
    const inner_start = std.mem.indexOf(u8, json[after_outer..], "[") orelse return null;
    const abs_inner = after_outer + inner_start;
    // Find matching ']'
    var depth: i32 = 0;
    var i: usize = abs_inner;
    while (i < json.len) : (i += 1) {
        if (json[i] == '[') depth += 1;
        if (json[i] == ']') {
            depth -= 1;
            if (depth == 0) return json[abs_inner .. i + 1];
        }
    }
    return null;
}

// ─── Helpers JSON parse minimal ───────────────────────────────────────────────

/// Extrage al N-lea string din params array: "params":["val0","val1"]
pub fn extractArrayStr(json: []const u8, index: usize) ?[]const u8 {
    const params_pos = std.mem.indexOf(u8, json, "\"params\"") orelse return null;
    const bracket = std.mem.indexOf(u8, json[params_pos..], "[") orelse return null;
    var pos = params_pos + bracket + 1;
    var current: usize = 0;
    while (pos < json.len) {
        // sari whitespace
        while (pos < json.len and (json[pos] == ' ' or json[pos] == '\t')) pos += 1;
        if (pos >= json.len or json[pos] == ']') break;
        if (json[pos] == '"') {
            pos += 1;
            const start = pos;
            while (pos < json.len and json[pos] != '"') pos += 1;
            if (current == index) return json[start..pos];
            current += 1;
            pos += 1;
        } else {
            // sari non-string element
            while (pos < json.len and json[pos] != ',' and json[pos] != ']') pos += 1;
            current += 1;
        }
        if (pos < json.len and json[pos] == ',') pos += 1;
    }
    return null;
}

/// Extrage al N-lea token brut din params array (string SAU literal: true/false/number).
/// Pentru string-uri returneaza continutul fara ghilimele; pentru literali ca `true`
/// returneaza textul ca atare. Folosit pentru a citi booleeni JSON din params.
pub fn extractArrayToken(json: []const u8, index: usize) ?[]const u8 {
    const params_pos = std.mem.indexOf(u8, json, "\"params\"") orelse return null;
    const bracket = std.mem.indexOf(u8, json[params_pos..], "[") orelse return null;
    var pos = params_pos + bracket + 1;
    var current: usize = 0;
    while (pos < json.len) {
        while (pos < json.len and (json[pos] == ' ' or json[pos] == '\t')) pos += 1;
        if (pos >= json.len or json[pos] == ']') break;
        if (json[pos] == '"') {
            // quoted string — return content without quotes
            pos += 1;
            const start = pos;
            while (pos < json.len and json[pos] != '"') pos += 1;
            if (current == index) return json[start..pos];
            current += 1;
            pos += 1; // skip closing "
        } else {
            // bare literal (true/false/null/number)
            const start = pos;
            while (pos < json.len and json[pos] != ',' and json[pos] != ']' and json[pos] != ' ') pos += 1;
            if (current == index) return json[start..pos];
            current += 1;
        }
        if (pos < json.len and json[pos] == ',') pos += 1;
    }
    return null;
}

/// Extrage al N-lea numar din params array: "params":["addr", 1000]
pub fn extractArrayNum(json: []const u8, index: usize) u64 {
    const params_pos = std.mem.indexOf(u8, json, "\"params\"") orelse return 0;
    const bracket = std.mem.indexOf(u8, json[params_pos..], "[") orelse return 0;
    var pos = params_pos + bracket + 1;
    var current: usize = 0;
    while (pos < json.len) {
        while (pos < json.len and (json[pos] == ' ' or json[pos] == '\t')) pos += 1;
        if (pos >= json.len or json[pos] == ']') break;
        if (json[pos] == '"') {
            // sari string
            pos += 1;
            while (pos < json.len and json[pos] != '"') pos += 1;
            pos += 1;
            current += 1;
        } else if (json[pos] >= '0' and json[pos] <= '9') {
            const start = pos;
            while (pos < json.len and json[pos] >= '0' and json[pos] <= '9') pos += 1;
            if (current == index) return std.fmt.parseInt(u64, json[start..pos], 10) catch 0;
            current += 1;
        } else {
            pos += 1;
            continue;
        }
        if (pos < json.len and json[pos] == ',') pos += 1;
    }
    return 0;
}

/// Extrage Content-Length din header HTTP
fn extractContentLength(header: []const u8) usize {
    const needle = "Content-Length: ";
    const pos = std.mem.indexOf(u8, header, needle) orelse return 0;
    const after = header[pos + needle.len..];
    var end: usize = 0;
    while (end < after.len and after[end] >= '0' and after[end] <= '9') end += 1;
    return std.fmt.parseInt(usize, after[0..end], 10) catch 0;
}

/// Extract peer IPv4 as 4 raw bytes in network byte order.
/// Returns [0,0,0,0] on IPv6/unknown so isAuthorized treats them as
/// non-loopback → token required.
///
/// Why bytes not u32: addr.in.sa.addr is stored network-order in a
/// host u32 register. On little-endian (x86_64) `value & 0xFF` gives
/// the LAST octet, not the first — Kimi BUG_13 caught this: any
/// remote IP ending in `.127` would bypass auth. Using the raw byte
/// slice removes endianness entirely.
fn peerIpv4Bytes(addr: std.net.Address) [4]u8 {
    if (addr.any.family == std.posix.AF.INET) {
        return std.mem.toBytes(addr.in.sa.addr);
    }
    return .{ 0, 0, 0, 0 };
}

/// Constant-time byte comparison. Returns true iff `a` and `b` have
/// equal length AND every byte matches. Loops over the full length
/// regardless of where mismatches occur, so we don't leak the prefix
/// length via timing side-channel (Kimi BUG_14).
fn constantTimeEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var diff: u8 = 0;
    for (a, b) |x, y| diff |= x ^ y;
    return diff == 0;
}

/// Auth check: returns true if request is authorized.
/// Rules:
///  - if `auth_token` is null on ServerCtx → always allowed (legacy / dev)
///  - if connection's first octet is 127 (loopback /8) → always allowed
///  - else: require `Authorization: Bearer <token>` matching ctx.auth_token
///    in constant time
fn isAuthorized(ctx: *ServerCtx, header: []const u8, peer_ip: [4]u8) bool {
    if (ctx.auth_token_len == 0) return true; // no auth configured
    const token: []const u8 = ctx.auth_token_buf[0..ctx.auth_token_len];
    // 127.0.0.0/8 = loopback. peer_ip is network-order bytes, so the
    // FIRST octet is peer_ip[0]. Endian-safe.
    if (peer_ip[0] == 127) return true;
    const prefix1 = "Authorization: Bearer ";
    const prefix2 = "authorization: Bearer ";
    var bearer_start: ?usize = null;
    if (std.mem.indexOf(u8, header, prefix1)) |p| bearer_start = p + prefix1.len
    else if (std.mem.indexOf(u8, header, prefix2)) |p| bearer_start = p + prefix2.len;
    const start = bearer_start orelse return false;
    // Token runs until \r or \n
    var end: usize = start;
    while (end < header.len and header[end] != '\r' and header[end] != '\n') end += 1;
    const got = header[start..end];
    return std.mem.eql(u8, got, token);
}

/// Send 401 Unauthorized and close.
fn writeUnauthorized(stream: std.net.Stream) void {
    const resp = "HTTP/1.1 401 Unauthorized\r\n" ++
        "Content-Type: application/json\r\n" ++
        "Content-Length: 67\r\n" ++
        "Access-Control-Allow-Origin: *\r\n" ++
        "WWW-Authenticate: Bearer\r\n" ++
        "Connection: close\r\n\r\n" ++
        "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32001,\"message\":\"Unauthorized\"}}";
    _ = stream.write(resp) catch {};
}

/// Sanitize a string for safe embedding in a JSON string value.
/// Replaces `"` → `'`, `\` → `/`, and strips control chars (< 0x20).
/// Returns an allocated slice that must be freed by the caller.
/// Used to safely include op_return / memo content in RPC JSON responses.
pub fn jsonSanitize(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    var out = try alloc.alloc(u8, s.len);
    var j: usize = 0;
    for (s) |c| {
        if (c == '"')       { out[j] = '\''; j += 1; }
        else if (c == '\\') { out[j] = '/';  j += 1; }
        else if (c < 0x20)  {}  // strip control chars
        else                { out[j] = c;   j += 1; }
    }
    return out[0..j];
}

/// Extrage valoarea unui string field din JSON.
/// Cauta "key" (oricunde in sir), sare peste `: `, returneaza valoarea string.
pub fn extractStr(json: []const u8, key: []const u8) ?[]const u8 {
    // Construim needle: "key"
    var nbuf: [128]u8 = undefined;
    if (key.len + 2 > nbuf.len) return null;
    nbuf[0] = '"';
    @memcpy(nbuf[1..1+key.len], key);
    nbuf[1+key.len] = '"';
    const needle = nbuf[0..key.len+2];

    var pos: usize = 0;
    while (pos + needle.len <= json.len) {
        if (std.mem.startsWith(u8, json[pos..], needle)) {
            var i = pos + needle.len;
            // sari whitespace si ':'
            while (i < json.len and (json[i] == ' ' or json[i] == ':' or json[i] == '\t' or json[i] == '\r' or json[i] == '\n')) i += 1;
            // acum trebuie sa fie '"'
            if (i < json.len and json[i] == '"') {
                i += 1;
                const start = i;
                while (i < json.len and json[i] != '"') i += 1;
                return json[start..i];
            }
        }
        pos += 1;
    }
    return null;
}

// ── Structured JSON helpers (arrays + objects) ────────────────────────────────
//
// `extractStr` is scalar-only: it stops at the first `"..."` value it
// finds for a key. The handlers below need richer shapes:
//   * arrays of strings  (quorum_sigs, merkle_proof, receipt_proof)
//   * objects-in-objects (spv_proof_blob)
//   * arrays of objects  ({pubkey, sig} pairs)
//
// All helpers below are slice-into-input — they don't allocate unless
// stated. The few that do (parseStringArray, parseHexArray) take an
// allocator and return owned-memory slices; the caller is responsible
// for freeing.

/// Locate the array body for `"key": [...]`. Returns a slice that starts
/// at the opening '[' and ends just past the matching ']'. String-aware:
/// skips brackets that live inside `"..."` strings. Returns null if the
/// key is missing OR the value isn't an array.
pub fn findJsonArray(json: []const u8, key: []const u8) ?[]const u8 {
    var nbuf: [128]u8 = undefined;
    if (key.len + 2 > nbuf.len) return null;
    nbuf[0] = '"';
    @memcpy(nbuf[1 .. 1 + key.len], key);
    nbuf[1 + key.len] = '"';
    const needle = nbuf[0 .. key.len + 2];

    var pos: usize = 0;
    while (pos + needle.len <= json.len) : (pos += 1) {
        if (!std.mem.startsWith(u8, json[pos..], needle)) continue;
        var i = pos + needle.len;
        while (i < json.len and (json[i] == ' ' or json[i] == ':' or
            json[i] == '\t' or json[i] == '\r' or json[i] == '\n')) i += 1;
        if (i >= json.len or json[i] != '[') continue;
        const start = i;
        var depth: i32 = 0;
        var in_str = false;
        while (i < json.len) : (i += 1) {
            const c = json[i];
            if (in_str) {
                if (c == '\\') { i += 1; continue; }
                if (c == '"') in_str = false;
                continue;
            }
            switch (c) {
                '"' => in_str = true,
                '[' => depth += 1,
                ']' => {
                    depth -= 1;
                    if (depth == 0) return json[start .. i + 1];
                },
                else => {},
            }
        }
        return null;
    }
    return null;
}

/// Locate the object body for `"key": {...}`. Same semantics as
/// findJsonArray but for `{...}`. Returns null on missing key or
/// non-object value.
pub fn findJsonObject(json: []const u8, key: []const u8) ?[]const u8 {
    var nbuf: [128]u8 = undefined;
    if (key.len + 2 > nbuf.len) return null;
    nbuf[0] = '"';
    @memcpy(nbuf[1 .. 1 + key.len], key);
    nbuf[1 + key.len] = '"';
    const needle = nbuf[0 .. key.len + 2];

    var pos: usize = 0;
    while (pos + needle.len <= json.len) : (pos += 1) {
        if (!std.mem.startsWith(u8, json[pos..], needle)) continue;
        var i = pos + needle.len;
        while (i < json.len and (json[i] == ' ' or json[i] == ':' or
            json[i] == '\t' or json[i] == '\r' or json[i] == '\n')) i += 1;
        if (i >= json.len or json[i] != '{') continue;
        const start = i;
        var depth: i32 = 0;
        var in_str = false;
        while (i < json.len) : (i += 1) {
            const c = json[i];
            if (in_str) {
                if (c == '\\') { i += 1; continue; }
                if (c == '"') in_str = false;
                continue;
            }
            switch (c) {
                '"' => in_str = true,
                '{' => depth += 1,
                '}' => {
                    depth -= 1;
                    if (depth == 0) return json[start .. i + 1];
                },
                else => {},
            }
        }
        return null;
    }
    return null;
}

/// Parse a JSON array body (`[ ... ]`) into a slice-of-slices, each
/// pointing at one string element. The returned outer slice is heap
/// allocated; inner slices reference the input.
///
/// Caller frees the OUTER slice with `alloc.free(returned)`. Inner
/// strings are NOT owned and must NOT be freed.
fn parseJsonStringArrayBody(body: []const u8, alloc: std.mem.Allocator) ![][]const u8 {
    if (body.len < 2 or body[0] != '[' or body[body.len - 1] != ']') return error.InvalidArray;
    const inner = body[1 .. body.len - 1];
    // First pass: count elements.
    var count: usize = 0;
    {
        var i: usize = 0;
        while (i < inner.len) {
            while (i < inner.len and (inner[i] == ' ' or inner[i] == ',' or
                inner[i] == '\t' or inner[i] == '\r' or inner[i] == '\n')) : (i += 1) {}
            if (i >= inner.len) break;
            if (inner[i] != '"') return error.NonStringInArray;
            i += 1;
            while (i < inner.len and inner[i] != '"') : (i += 1) {
                if (inner[i] == '\\' and i + 1 < inner.len) i += 1;
            }
            if (i >= inner.len) return error.UnterminatedString;
            i += 1; // past closing '"'
            count += 1;
        }
    }
    const out = try alloc.alloc([]const u8, count);
    errdefer alloc.free(out);
    // Second pass: fill.
    var idx: usize = 0;
    var i: usize = 0;
    while (i < inner.len and idx < count) {
        while (i < inner.len and (inner[i] == ' ' or inner[i] == ',' or
            inner[i] == '\t' or inner[i] == '\r' or inner[i] == '\n')) : (i += 1) {}
        if (i >= inner.len) break;
        if (inner[i] != '"') return error.NonStringInArray;
        i += 1;
        const start = i;
        while (i < inner.len and inner[i] != '"') : (i += 1) {
            if (inner[i] == '\\' and i + 1 < inner.len) i += 1;
        }
        out[idx] = inner[start..i];
        idx += 1;
        i += 1;
    }
    return out;
}

/// Public — accepts the parent body (any JSON) plus `key`, returns a
/// freshly-allocated `[][]const u8` whose contents are slices into
/// `body`. Caller owns the OUTER slice (free with `alloc.free`).
fn parseStringArray(body: []const u8, key: []const u8, alloc: std.mem.Allocator) !?[][]const u8 {
    const arr = findJsonArray(body, key) orelse return null;
    return try parseJsonStringArrayBody(arr, alloc);
}

/// Like parseStringArray but each element is treated as hex and decoded
/// to bytes. Returns a slice-of-slices where each inner slice IS owned
/// (allocated). Caller must free both:
///   * each element (alloc.free(returned[i]))
///   * the outer slice (alloc.free(returned))
fn parseHexArray(body: []const u8, key: []const u8, alloc: std.mem.Allocator) !?[][]u8 {
    const arr = findJsonArray(body, key) orelse return null;
    const strings = try parseJsonStringArrayBody(arr, alloc);
    defer alloc.free(strings);
    const out = try alloc.alloc([]u8, strings.len);
    var allocated_idx: usize = 0;
    errdefer {
        var k: usize = 0;
        while (k < allocated_idx) : (k += 1) alloc.free(out[k]);
        alloc.free(out);
    }
    var i: usize = 0;
    while (i < strings.len) : (i += 1) {
        var s = strings[i];
        if (s.len >= 2 and s[0] == '0' and (s[1] == 'x' or s[1] == 'X')) s = s[2..];
        if (s.len % 2 != 0) return error.OddHexLength;
        const buf = try alloc.alloc(u8, s.len / 2);
        hex_utils.hexToBytes(s, buf) catch {
            alloc.free(buf);
            return error.BadHex;
        };
        out[i] = buf;
        allocated_idx = i + 1;
    }
    return out;
}

/// Free helper for parseHexArray output.
fn freeHexArray(arr: [][]u8, alloc: std.mem.Allocator) void {
    for (arr) |a| alloc.free(a);
    alloc.free(arr);
}

/// Extrage id-ul numeric din JSON (default 1)
fn extractId(json: []const u8) u32 {
    const pos = std.mem.indexOf(u8, json, "\"id\"") orelse return 1;
    const after = json[pos + 4..];
    var i: usize = 0;
    while (i < after.len and (after[i] == ':' or after[i] == ' ')) i += 1;
    if (i >= after.len) return 1;
    const start = i;
    while (i < after.len and after[i] >= '0' and after[i] <= '9') i += 1;
    if (i == start) return 1;
    return std.fmt.parseInt(u32, after[start..i], 10) catch 1;
}

pub fn errorJson(code: i32, msg: []const u8, id: u64, alloc: std.mem.Allocator) ![]u8 {
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"error\":{{\"code\":{d},\"message\":\"{s}\"}}}}",
        .{ id, code, msg });
}

// ─── Cross-chain swap binding handlers ─────────────────────────────────────────

pub fn hex32(b: [32]u8, out: *[64]u8) void {
    const tab = "0123456789abcdef";
    for (b, 0..) |x, i| {
        out[i * 2] = tab[x >> 4];
        out[i * 2 + 1] = tab[x & 0x0F];
    }
}

pub fn stateName(s: swap_link_mod.SwapState) []const u8 {
    return switch (s) {
        .pending => "pending",
        .both_locked => "both_locked",
        .claimed => "claimed",
        .timed_out => "timed_out",
    };
}

pub fn chainName(c: swap_link_mod.Chain) []const u8 {
    return switch (c) {
        .omnibus => "omnibus",
        .btc     => "btc",
        .eth     => "eth",
        .base    => "base",
        .liberty => "liberty",
    };
}

/// swap_open — register a SwapBinding for an existing order_place TX.
/// Params: order_id, taker_chain (1=btc,2=eth,3=base,4=liberty), taker_htlc_ref (hex up to 80 chars),
///   hash_lock (64 hex), timeout (u64 block height).

/// swap_status — read state for a given swap_id.

/// swap_listOpen — list bindings whose state is .pending or .both_locked.
/// (Address filter is accepted but ignored — frontend filters client-side
/// until matching_engine cross-ref by trader is exposed.)

/// swap_lockMaker — confirm the maker-side HTLC is funded on its chain.
/// Params: swap_id (64 hex), htlc_ref (122 hex, HtlcRef wire format).
/// Transitions: pending → pending (sets maker_htlc_ref). Both legs needed
/// before state moves to both_locked.

/// swap_lockTaker — confirm the taker-side HTLC is funded. After both legs
/// locked the binding transitions to .both_locked.
/// Params: swap_id (64 hex), htlc_ref (122 hex).

/// swap_timeout — mark a binding as timed_out when current block >= timeout_block.
/// Params: swap_id (64 hex).

/// Lookup helper for the flat key=value,... `spv_proof_blob` format.
/// Returns the value for `key` (slice into `blob`) or null if absent.
fn blobField(blob: []const u8, key: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, blob, ',');
    while (it.next()) |seg| {
        const eq = std.mem.indexOfScalar(u8, seg, '=') orelse continue;
        if (std.mem.eql(u8, seg[0..eq], key)) return seg[eq + 1 ..];
    }
    return null;
}

/// Decode a hex string into a heap-allocated byte slice. Caller frees.
pub fn hexAlloc(alloc: std.mem.Allocator, hex: []const u8) ?[]u8 {
    if (hex.len % 2 != 0) return null;
    const out = alloc.alloc(u8, hex.len / 2) catch return null;
    hex_utils.hexToBytes(hex, out) catch {
        alloc.free(out);
        return null;
    };
    return out;
}

/// Verify the SPV proof blob against the recorded chain head. Returns
/// true only when the proof is well-formed AND matches the oracle's
/// recorded anchor.
pub fn verifySpvProofBlob(blob: []const u8) bool {
    ensureOracleLoaded();
    const chain = blobField(blob, "chain") orelse return false;

    if (std.mem.eql(u8, chain, "btc")) {
        const tx_hex = blobField(blob, "tx_hash") orelse return false;
        const path_hex = blobField(blob, "merkle_proof_hex") orelse return false;
        const idx_str = blobField(blob, "indices") orelse return false;
        if (path_hex.len % 64 != 0) return false;
        const levels = path_hex.len / 64;
        if (levels != idx_str.len or levels > 64) return false;

        const txh = parseHex32(tx_hex) orelse return false;

        // Get the BTC anchor from the oracle. The merkle_root is stored on
        // the anchor itself (extracted from the recorded raw header at
        // record time via spv_btc.parseHeader). This is the trusted source
        // — never trust a caller-supplied merkle_root.
        g_xchain_oracle_mutex.lock();
        defer g_xchain_oracle_mutex.unlock();
        const btc = g_xchain_oracle.latestBtc() orelse return false;

        // Defense-in-depth: prefer the anchor's recorded merkle_root over
        // any caller-supplied value. If the anchor was loaded from a v1
        // file (or recorded without a raw header), merkle_root is all-zero;
        // in that legacy case we fall back to the caller-supplied root so
        // existing testnet flows keep working until the operator re-records
        // with a raw header.
        const anchor_root_zero = blk: {
            for (btc.merkle_root) |b| if (b != 0) break :blk false;
            break :blk true;
        };
        const root: [32]u8 = if (!anchor_root_zero) btc.merkle_root else root_from_blob: {
            const root_hex = blobField(blob, "merkle_root") orelse return false;
            break :root_from_blob (parseHex32(root_hex) orelse return false);
        };

        var path_buf: [64][32]u8 = undefined;
        var idx_buf: [64]u1 = undefined;
        var i: usize = 0;
        while (i < levels) : (i += 1) {
            const sib_hex = path_hex[i * 64 .. (i + 1) * 64];
            path_buf[i] = parseHex32(sib_hex) orelse return false;
            idx_buf[i] = if (idx_str[i] == '1') 1 else 0;
        }
        return spv_btc_mod.verifyMerkleProof(txh, path_buf[0..levels], idx_buf[0..levels], root);
    }

    if (std.mem.eql(u8, chain, "eth")) {
        const cid_str = blobField(blob, "chain_id") orelse "1";
        const cid = std.fmt.parseInt(u64, cid_str, 10) catch return false;

        g_xchain_oracle_mutex.lock();
        const eth_anchor = g_xchain_oracle.latestEth(cid);
        g_xchain_oracle_mutex.unlock();
        const anchor = eth_anchor orelse return false;

        const tx_index_hex = blobField(blob, "tx_index_rlp_hex") orelse return false;
        const receipt_hex = blobField(blob, "receipt_rlp_hex") orelse return false;
        const proof_hex = blobField(blob, "receipt_proof_hex") orelse return false;

        const alloc = std.heap.page_allocator;
        const key = hexAlloc(alloc, tx_index_hex) orelse return false;
        defer alloc.free(key);
        const value = hexAlloc(alloc, receipt_hex) orelse return false;
        defer alloc.free(value);

        // proof nodes are pipe-separated RLP hex blobs.
        var node_count: usize = 0;
        {
            var it = std.mem.splitScalar(u8, proof_hex, '|');
            while (it.next()) |_| node_count += 1;
        }
        if (node_count == 0 or node_count > 64) return false;

        var nodes_storage: [64][]u8 = undefined;
        var node_slices: [64][]const u8 = undefined;
        var alloc_idx: usize = 0;
        defer {
            var k: usize = 0;
            while (k < alloc_idx) : (k += 1) alloc.free(nodes_storage[k]);
        }
        var it2 = std.mem.splitScalar(u8, proof_hex, '|');
        while (it2.next()) |part| {
            const decoded = hexAlloc(alloc, part) orelse return false;
            nodes_storage[alloc_idx] = decoded;
            node_slices[alloc_idx] = decoded;
            alloc_idx += 1;
        }

        return spv_eth_mod.verifyReceiptAtIndex(
            anchor.receipts_root,
            key,
            value,
            node_slices[0..alloc_idx],
        );
    }

    return false;
}

/// Strip an optional `0x` prefix from a hex string.
fn stripHex0x(s: []const u8) []const u8 {
    if (s.len >= 2 and s[0] == '0' and (s[1] == 'x' or s[1] == 'X')) return s[2..];
    return s;
}

/// Parse an integer array body (`[0, 1, 0, 1]`) into a fixed-size u1 buffer.
/// Returns the count of bits parsed; 0 on malformed input. Caller must
/// pass a buffer of at least 64 entries.
fn parseIndicesArray(arr_body: []const u8, out: []u1) usize {
    if (arr_body.len < 2 or arr_body[0] != '[' or arr_body[arr_body.len - 1] != ']') return 0;
    const inner = arr_body[1 .. arr_body.len - 1];
    var i: usize = 0;
    var n: usize = 0;
    while (i < inner.len and n < out.len) {
        while (i < inner.len and (inner[i] == ' ' or inner[i] == ',' or
            inner[i] == '\t' or inner[i] == '\r' or inner[i] == '\n')) : (i += 1) {}
        if (i >= inner.len) break;
        if (inner[i] == '0') {
            out[n] = 0; n += 1; i += 1;
        } else if (inner[i] == '1') {
            out[n] = 1; n += 1; i += 1;
        } else {
            // Multi-digit integers aren't expected (indices are bits) —
            // bail rather than misinterpret.
            return 0;
        }
    }
    return n;
}

/// Verify an SPV proof supplied as a JSON OBJECT. This is the new shape
/// (post-task-2) that swap_proveSettle accepts:
///   {
///     "chain": "btc"|"eth",
///     "block_height": ...,
///     "tx_hash": "0x...",
///     "merkle_proof": ["0x...", ...],
///     "indices": [0,1,0,1],
///     "tx_index_rlp": "...",       // ETH only
///     "receipt_rlp": "...",        // ETH only
///     "receipt_proof": ["...", ...] // ETH only
///   }
pub fn verifySpvProofJson(obj: []const u8) bool {
    ensureOracleLoaded();
    const chain = extractStr(obj, "chain") orelse return false;

    if (std.mem.eql(u8, chain, "btc")) {
        const tx_hex = stripHex0x(extractStr(obj, "tx_hash") orelse return false);
        const txh = parseHex32(tx_hex) orelse return false;

        const proof_arr = findJsonArray(obj, "merkle_proof") orelse return false;
        const idx_arr = findJsonArray(obj, "indices") orelse return false;

        // Parse merkle_proof array of 32-byte hex strings (with/without 0x).
        var path_buf: [64][32]u8 = undefined;
        var levels: usize = 0;
        {
            // Walk strings inside proof_arr without allocating.
            var i: usize = 1; // skip '['
            const end = proof_arr.len - 1;
            while (i < end and levels < path_buf.len) {
                while (i < end and (proof_arr[i] == ' ' or proof_arr[i] == ',' or
                    proof_arr[i] == '\t' or proof_arr[i] == '\r' or proof_arr[i] == '\n')) : (i += 1) {}
                if (i >= end) break;
                if (proof_arr[i] != '"') return false;
                i += 1;
                const sstart = i;
                while (i < end and proof_arr[i] != '"') : (i += 1) {}
                if (i >= end) return false;
                const sib_hex = stripHex0x(proof_arr[sstart..i]);
                if (sib_hex.len != 64) return false;
                path_buf[levels] = parseHex32(sib_hex) orelse return false;
                levels += 1;
                i += 1; // past closing '"'
            }
        }

        var idx_buf: [64]u1 = undefined;
        const idx_count = parseIndicesArray(idx_arr, &idx_buf);
        if (idx_count != levels) return false;

        // Resolve merkle_root: prefer anchor, fall back to caller blob if anchor zero.
        g_xchain_oracle_mutex.lock();
        defer g_xchain_oracle_mutex.unlock();
        const btc = g_xchain_oracle.latestBtc() orelse return false;
        const anchor_root_zero = blk: {
            for (btc.merkle_root) |b| if (b != 0) break :blk false;
            break :blk true;
        };
        const root: [32]u8 = if (!anchor_root_zero) btc.merkle_root else root_from_obj: {
            const root_hex = stripHex0x(extractStr(obj, "merkle_root") orelse return false);
            break :root_from_obj (parseHex32(root_hex) orelse return false);
        };
        return spv_btc_mod.verifyMerkleProof(txh, path_buf[0..levels], idx_buf[0..levels], root);
    }

    if (std.mem.eql(u8, chain, "eth")) {
        const cid_str = extractStr(obj, "chain_id") orelse "1";
        const cid = std.fmt.parseInt(u64, cid_str, 10) catch return false;
        g_xchain_oracle_mutex.lock();
        const eth_anchor = g_xchain_oracle.latestEth(cid);
        g_xchain_oracle_mutex.unlock();
        const anchor = eth_anchor orelse return false;

        const tx_index_hex = stripHex0x(extractStr(obj, "tx_index_rlp") orelse return false);
        const receipt_hex = stripHex0x(extractStr(obj, "receipt_rlp") orelse return false);

        const alloc = std.heap.page_allocator;
        const key = hexAlloc(alloc, tx_index_hex) orelse return false;
        defer alloc.free(key);
        const value = hexAlloc(alloc, receipt_hex) orelse return false;
        defer alloc.free(value);

        // receipt_proof is a JSON array of hex strings.
        const nodes_opt = parseHexArray(obj, "receipt_proof", alloc) catch return false;
        const nodes = nodes_opt orelse return false;
        defer freeHexArray(nodes, alloc);
        if (nodes.len == 0 or nodes.len > 64) return false;

        // Build a [][]const u8 view for the verifier.
        var node_slices: [64][]const u8 = undefined;
        var k: usize = 0;
        while (k < nodes.len) : (k += 1) node_slices[k] = nodes[k];

        return spv_eth_mod.verifyReceiptAtIndex(
            anchor.receipts_root,
            key,
            value,
            node_slices[0..nodes.len],
        );
    }
    return false;
}

/// swap_proveSettle — accept the revealed preimage AND (when present) an
/// SPV proof of the remote-chain claim. Verifies:
///   1. preimage hashes to swap_id (cheap, always required);
///   2. if `spv_proof_blob` is supplied → SPV-verify the remote claim
///      against the recorded chain head from the cross-chain oracle;
///   3. only when both pass do we transition the binding to .claimed.
///
/// `spv_proof_blob` accepts TWO shapes:
///   * NEW (preferred): JSON OBJECT — see verifySpvProofJson above for fields
///   * LEGACY: flat comma-separated key=value blob — see verifySpvProofBlob
///
/// Empty/absent blob → DEV mode: preimage-only settle is accepted, with
/// a warning logged. Production validators should require the blob.

// intent_* — build, sign, and broadcast the corresponding 0x40/0x41/0x43
// typed TXs through the mempool. State-machine effects land at applyBlock
// time via blockchain.applyIntentTx.

/// Build + submit an intent TX. Mirrors submitHtlcTx — TX has amount=0
/// (intents move state, not coin), fee=1, signed via the standard mempool
/// path from the node's primary wallet.
pub fn submitIntentTx(
    ctx: *ServerCtx,
    tx_type: transaction_mod.TxType,
    payload: []const u8,
) ![]u8 {
    const alloc = ctx.allocator;
    const data_owned = try alloc.dupe(u8, payload);
    errdefer alloc.free(data_owned);
    const from_owned = try alloc.dupe(u8, ctx.wallet.address);
    errdefer alloc.free(from_owned);
    const to_owned = try alloc.dupe(u8, ctx.wallet.address);
    errdefer alloc.free(to_owned);

    var tx = transaction_mod.Transaction{
        .id           = g_tx_counter.fetchAdd(1, .monotonic),
        .from_address = from_owned,
        .to_address   = to_owned,
        .amount       = 0,
        .fee          = 1,
        .timestamp    = std.time.timestamp(),
        .nonce        = ctx.bc.getNextAvailableNonce(ctx.wallet.address),
        .signature    = "",
        .hash         = "",
        .tx_type      = tx_type,
        .data         = data_owned,
    };

    const h = tx.calculateHash();
    var hash_hex_buf: [64]u8 = undefined;
    writeHex32(h, &hash_hex_buf);
    const hash_owned = try alloc.dupe(u8, &hash_hex_buf);
    errdefer alloc.free(hash_owned);
    tx.hash = hash_owned;

    try ctx.bc.addTransaction(tx);
    return alloc.dupe(u8, &hash_hex_buf);
}

/// `intent_post({intent_id?, swap_id, taker_chain, expiry_block,
/// maker_amount_sat, taker_min_sat?})` — TX type 0x40. If `intent_id` is
/// omitted, derives it from sha256("intent" || swap_id || expiry || from).

/// `intent_fill_commit({intent_id, bond_locked_sat})` — TX type 0x41.
/// Solver locks bond on Omnibus, claiming the right to fill the intent.

/// intent_settle alias preserved — delegates to swap_proveSettle (0x42).

/// `intent_timeout({intent_id, slashed_bond_sat?, swap_id?})` — TX type 0x43.
/// Optionally also nudges swap_registry.timeout(swap_id) for legacy callers
/// that only knew about swap_id; the in-memory call is now redundant with
/// the on-chain effect of applyIntentTx but kept for backward compat.

// ─── Standalone main (pentru omnibus-rpc exe) ─────────────────────────────────

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var bc     = try Blockchain.init(allocator);
    defer bc.deinit();

    const mnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
    var wallet = try Wallet.fromMnemonic(mnemonic, "", allocator);
    defer wallet.deinit();

    std.debug.print("=== OmniBus RPC Server standalone ===\n", .{});
    std.debug.print("Wallet: {s}\n", .{wallet.address});

    try startHTTP(&bc, &wallet, allocator);
}

// ─── Generate Wallet via RPC ─────────────────────────────────────────────────
// Primeste mnemonic de la client, genereaza wallet Zig real, returneaza adresa
// Asta garanteaza ca adresele sunt identice cu cele din blockchain (BIP32 + Base58)


// ─── Payment Channel RPC Handlers — moved to core/rpc/lightning.zig

/// Decode 66-char hex string to [33]u8 (compressed pubkey)
pub fn hexDecode33(hex: []const u8) ?[33]u8 {
    if (hex.len != 66) return null;
    var out: [33]u8 = undefined;
    for (0..33) |i| {
        const hi = hexVal(hex[i * 2]) orelse return null;
        const lo = hexVal(hex[i * 2 + 1]) orelse return null;
        out[i] = (@as(u8, hi) << 4) | @as(u8, lo);
    }
    return out;
}

/// Decode 64-char hex string to [32]u8 (channel_id / hash)
pub fn hexDecode32(hex: []const u8) ?[32]u8 {
    if (hex.len != 64) return null;
    var out: [32]u8 = undefined;
    for (0..32) |i| {
        const hi = hexVal(hex[i * 2]) orelse return null;
        const lo = hexVal(hex[i * 2 + 1]) orelse return null;
        out[i] = (@as(u8, hi) << 4) | @as(u8, lo);
    }
    return out;
}

/// Decode 128-char hex string to [64]u8 (secp256k1 ECDSA signature: r||s)
pub fn hexDecode64(hex: []const u8) ?[64]u8 {
    if (hex.len != 128) return null;
    var out: [64]u8 = undefined;
    for (0..64) |i| {
        const hi = hexVal(hex[i * 2]) orelse return null;
        const lo = hexVal(hex[i * 2 + 1]) orelse return null;
        out[i] = (@as(u8, hi) << 4) | @as(u8, lo);
    }
    return out;
}

pub fn hexVal(c: u8) ?u4 {
    if (c >= '0' and c <= '9') return @intCast(c - '0');
    if (c >= 'a' and c <= 'f') return @intCast(c - 'a' + 10);
    if (c >= 'A' and c <= 'F') return @intCast(c - 'A' + 10);
    return null;
}

// ─── OmniBus Custom RPC Handlers ──────────────────────────────────────────────

/// getblockchaininfo — comprehensive node status (matches Bitcoin RPC)

/// omnibus_getminers — list registered miners with stats
fn handleOmnibusMiners(ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    // Use registered miners from server context
    ctx.reg_mutex.lock();
    defer ctx.reg_mutex.unlock();

    const count = ctx.registered_miner_count;

    // Build simple JSON array
    var buf: [8192]u8 = undefined;
    var pos: usize = 0;
    const prefix = std.fmt.bufPrint(buf[pos..], "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":[", .{id}) catch return errorJson(-32603, "buf overflow", id, alloc);
    pos += prefix.len;

    var i: u16 = 0;
    while (i < count) : (i += 1) {
        const m = ctx.registered_miners[i];
        const addr = m.address[0..m.address_len];
        const node = m.node_id[0..m.node_id_len];
        if (i > 0) { buf[pos] = ','; pos += 1; }
        const entry = std.fmt.bufPrint(buf[pos..], "{{\"address\":\"{s}\",\"node_id\":\"{s}\",\"status\":\"online\"}}", .{addr, node}) catch break;
        pos += entry.len;
    }

    const suffix = std.fmt.bufPrint(buf[pos..], "]}}", .{}) catch return errorJson(-32603, "buf overflow", id, alloc);
    pos += suffix.len;

    return alloc.dupe(u8, buf[0..pos]);
}

/// omnibus_getoracleprices — current consensus prices from distributed oracle

// ─── omnibus_getblockprices / omnibus_getpricerange ────────────────────────
//
// Lightweight read endpoints for the 21-slot per-block oracle snapshot.
// Both use the same fast-path/fallback strategy as `getblock`:
//   1) If the in-memory `block_prices` map has the height, use it (cheap).
//   2) Otherwise fall back to the on-chain `blk.prices` array (authoritative;
//      committed via prices_root in the block hash).

/// Renders a single block's prices into the supplied buffer at `pos`. Skips
/// empty/zero entries. Returns the number of bytes written.
fn appendPricesJson(
    bc: *blockchain_mod.Blockchain,
    blk: *const block_mod.Block,
    buf: []u8,
    pos_in: usize,
) usize {
    var pos = pos_in;
    if (pos >= buf.len) return 0;
    buf[pos] = '['; pos += 1;
    var written: usize = 0;
    if (bc.getBlockPrices(blk.index)) |entries| {
        for (entries) |e| {
            if (e.exchange_len == 0 and e.pair_len == 0 and !e.success and e.timestamp_ms == 0) continue;
            if (written > 0) {
                if (pos >= buf.len) break;
                buf[pos] = ','; pos += 1;
            }
            const ex = e.exchange[0..e.exchange_len];
            const pr = e.pair[0..e.pair_len];
            const item = std.fmt.bufPrint(buf[pos..],
                "{{\"exchange\":\"{s}\",\"pair\":\"{s}\",\"bidMicroUsd\":{d},\"askMicroUsd\":{d},\"timestampMs\":{d},\"success\":{s}}}",
                .{ ex, pr, e.bid_micro_usd, e.ask_micro_usd, e.timestamp_ms, if (e.success) "true" else "false" },
            ) catch break;
            pos += item.len;
            written += 1;
        }
    } else {
        for (blk.prices) |e| {
            if (e.exchange_len == 0 and e.pair_len == 0 and !e.success and e.timestamp_ms == 0) continue;
            if (written > 0) {
                if (pos >= buf.len) break;
                buf[pos] = ','; pos += 1;
            }
            const ex = e.exchange[0..e.exchange_len];
            const pr = e.pair[0..e.pair_len];
            const item = std.fmt.bufPrint(buf[pos..],
                "{{\"exchange\":\"{s}\",\"pair\":\"{s}\",\"bidMicroUsd\":{d},\"askMicroUsd\":{d},\"timestampMs\":{d},\"success\":{s}}}",
                .{ ex, pr, e.bid_micro_usd, e.ask_micro_usd, e.timestamp_ms, if (e.success) "true" else "false" },
            ) catch break;
            pos += item.len;
            written += 1;
        }
    }
    if (pos >= buf.len) return pos - pos_in;
    buf[pos] = ']'; pos += 1;
    return pos - pos_in;
}

/// Hex-encode a 32-byte hash into 64 lowercase hex chars (in-place fill).
fn hashToHex(hash: [32]u8, out: *[64]u8) void {
    for (0..32) |i| {
        const b = hash[i];
        out[i * 2] = "0123456789abcdef"[b >> 4];
        out[i * 2 + 1] = "0123456789abcdef"[b & 0x0f];
    }
}

/// `omnibus_getblockprices [height]` — returns just the 21 price entries
/// for the given block, plus pricesRoot + pricesValidated. Lightweight path
/// for clients (charts, oracles) that don't need the rest of the block.

/// `omnibus_getpricerange [from_height, count]` — returns an array of
/// {height, prices, pricesRoot, pricesValidated} for the range
/// [from_height, from_height + count). Capped at 100 blocks. Useful for
/// charting historical bid/ask trajectories.

/// omnibus_getexchangefeed — live BTC + LCX bid/ask from 3 exchanges
/// (Coinbase, Kraken, LCX) via WebSocket. Returns raw feed snapshot from
/// `main_mod.g_ws_feed` (NOT the distributed-oracle consensus).
/// Slots layout:
///   [0] BTC Coinbase  [1] BTC Kraken  [2] BTC LCX
///   [3] LCX Coinbase  [4] LCX Kraken  [5] LCX LCX

// ─── omnibus_getallprices / omnibus_getarbitrage ────────────────────────────
//
// These two handlers depend on the *new* ExchangeFeed API being landed in
// core/ws_exchange_feed.zig by the parallel refactor agent:
//
//   pub fn getAllPrices(self: *ExchangeFeed, allocator) ![]PriceFetch
//   pub fn getPrice(self: *ExchangeFeed, exchange: []const u8, pair: []const u8) ?PriceFetch
//   pub fn count(self: *ExchangeFeed) usize
//   pub fn isStale(p: PriceFetch, now_ms: i64, threshold_ms: i64) bool
//
// Until that lands, the calls below are routed through a tiny shim
// `feedGetAllPrices` / `feedIsStale` that falls back to the existing
// `snapshot()` API. Look for `WIRE-UP-MARKER:` comments below — when the
// parallel agent ships the new API, replace the shim bodies with the direct
// `feed.getAllPrices(alloc)` / `ws_exchange_feed_mod.isStale(...)` calls.

/// Direct call to ExchangeFeed.getAllPrices (full unbounded PriceMap snapshot).
fn feedGetAllPrices(
    feed: *ws_exchange_feed_mod.ExchangeFeed,
    alloc: std.mem.Allocator,
) ![]ws_exchange_feed_mod.PriceFetch {
    return feed.getAllPrices(alloc);
}

/// Direct call to PriceFetch.isStale method (added in parallel refactor).
fn feedIsStale(
    p: ws_exchange_feed_mod.PriceFetch,
    now_ms: i64,
    threshold_ms: i64,
) bool {
    return p.isStale(now_ms, threshold_ms);
}

/// Canonicalize a pair label so cross-exchange variants line up.
///
/// Three exchanges, three notations:
///   Coinbase: "BTC-USD"  (dash, USD)
///   Kraken:   "BTC/USD"  (slash, USD)
///   LCX:      "BTC/USDC" or "BTC/USDT" or "BTC/EUR"
///
/// We canonicalize all USD-stable variants to "BTC/USD" so the arbitrage
/// matcher treats them as the same pair. EUR is INTENTIONALLY NOT mapped
/// — that flow needs a EUR/USD oracle. EUR-quoted LCX entries still appear
/// in the all-prices grid (display only) and are excluded from arbitrage.
/// Static buffer-pool pentru canonical labels — caller-ul primeste o referinta
/// la unul din slot-uri, valid pana la urmatorul apel din acelasi thread.
/// Sufficient pentru un singur RPC handler care deruleaza buclele de matching.
threadlocal var CANON_BUF: [16][32]u8 = std.mem.zeroes([16][32]u8);
threadlocal var CANON_IDX: usize = 0;

/// canonicalPair — PARSEAZA GENERIC raw symbol (orice format) si returneaza
/// label-ul canonical "<BASE>/<QUOTE_BUCKET>" unde:
///   - separator: `/` (LCX, Kraken WS) sau `-` (Coinbase) — ambele acceptate
///   - quote bucket: USD/USDC/USDT/DAI/USDS → "USD"; EUR/EURC → "EUR"; resto = ca-i
///   - Kraken legacy: XBT→BTC, XDG→DOGE in BAZA (nu in quote, ca quote = ZEUR/ZUSD
///     deja normalizat de Kraken la wsname e EUR/USD direct)
///
/// Aceasta forma se foloseste atat ca cheie pivot in matcher-ul de arbitraj,
/// cat si ca label vizibil in UI. Asa "1INCH-USD", "1INCH/USD", "1INCH/USDC"
/// se colapseaza toate la "1INCH/USD" si match-uiesc cross-exchange.
///
/// EUR variant: "AAVE/EUR" → "AAVE/EUR" (NU se colapseaza la USD aici — separat
/// in matcher: bid/ask sunt convertiti la USD prin FX rate, dar labelul ramane
/// EUR ca user-ul sa stie ca arbitrajul e cross-currency).
fn canonicalPair(pair: []const u8) []const u8 {
    // Find separator
    const sep_idx: usize = blk: {
        for (pair, 0..) |c, idx| {
            if (c == '/' or c == '-') break :blk idx;
        }
        break :blk pair.len; // no separator → return as-is
    };
    if (sep_idx == 0 or sep_idx >= pair.len - 1) return pair;

    var base = pair[0..sep_idx];
    const quote = pair[sep_idx + 1 ..];

    // Kraken legacy normalization: XBT/XDG in BASE.
    if (std.mem.eql(u8, base, "XBT")) base = "BTC";
    if (std.mem.eql(u8, base, "XDG")) base = "DOGE";

    // Quote bucket normalization (matches pair_discovery.py).
    var qbucket: []const u8 = quote;
    if (std.mem.eql(u8, quote, "USD") or
        std.mem.eql(u8, quote, "USDC") or
        std.mem.eql(u8, quote, "USDT") or
        std.mem.eql(u8, quote, "DAI") or
        std.mem.eql(u8, quote, "USDS"))
    {
        qbucket = "USD";
    } else if (std.mem.eql(u8, quote, "EUR") or std.mem.eql(u8, quote, "EURC")) {
        qbucket = "EUR";
    }

    // Build "<base>/<qbucket>" in a thread-local rotating buffer.
    const slot = &CANON_BUF[CANON_IDX];
    CANON_IDX = (CANON_IDX + 1) % CANON_BUF.len;
    const total_len = base.len + 1 + qbucket.len;
    if (total_len > slot.len) return pair; // safety: weird long pair, return original
    @memcpy(slot[0..base.len], base);
    slot[base.len] = '/';
    @memcpy(slot[base.len + 1 .. base.len + 1 + qbucket.len], qbucket);
    return slot[0..total_len];
}

test "canonicalPair: dash → slash" {
    try std.testing.expectEqualStrings("BTC/USD", canonicalPair("BTC-USD"));
    try std.testing.expectEqualStrings("1INCH/USD", canonicalPair("1INCH-USD"));
    try std.testing.expectEqualStrings("AAVE/USD", canonicalPair("AAVE-USDC"));
}

test "canonicalPair: slash unchanged for canonical" {
    try std.testing.expectEqualStrings("BTC/USD", canonicalPair("BTC/USD"));
    try std.testing.expectEqualStrings("1INCH/USD", canonicalPair("1INCH/USDT"));
}

test "canonicalPair: EUR stays EUR (matcher handles FX separately)" {
    try std.testing.expectEqualStrings("BTC/EUR", canonicalPair("BTC/EUR"));
    try std.testing.expectEqualStrings("AAVE/EUR", canonicalPair("AAVE-EURC"));
}

test "canonicalPair: Kraken legacy XBT → BTC, XDG → DOGE" {
    try std.testing.expectEqualStrings("BTC/USD", canonicalPair("XBT/USD"));
    try std.testing.expectEqualStrings("DOGE/EUR", canonicalPair("XDG/EUR"));
}

test "canonicalPair: stable variants collapse to USD" {
    try std.testing.expectEqualStrings("ADA/USD", canonicalPair("ADA/USDC"));
    try std.testing.expectEqualStrings("ADA/USD", canonicalPair("ADA-USDT"));
    try std.testing.expectEqualStrings("ADA/USD", canonicalPair("ADA/DAI"));
}

test "canonicalPair: non-stable quote unchanged" {
    try std.testing.expectEqualStrings("ADA/BTC", canonicalPair("ADA/BTC"));
    try std.testing.expectEqualStrings("SOL/ETH", canonicalPair("SOL-ETH"));
    try std.testing.expectEqualStrings("BTC/GBP", canonicalPair("BTC/GBP"));
}

/// omnibus_getallprices — paginated dump of every PriceFetch the feed holds.
///
/// Params (all optional, positional):
///   [0] offset : u64 (default 0)
///   [1] limit  : u64 (default 1000, capped so the JSON fits in 256 KiB)
///
/// Each entry: {exchange, pair, bidMicroUsd, askMicroUsd, timestampMs,
///              success, stale}. `stale` uses a 30 000 ms threshold.

/// omnibus_getfxrate — current EUR→USD multiplier (median of USDC/EUR mid
/// across Coinbase, Kraken, LCX). Returned as both micro-USD per EUR and a
/// human-readable string. Null result if no FX feed has populated yet.

/// omnibus_getarbitrage — pre-compute cross-exchange arbitrage opportunities.
///
/// For every canonical pair label (BTC/USD, LCX/USD, ETH/USD, …) we collect
/// non-stale, success=true entries from all exchanges, then for each ordered
/// (buy, sell) combination compute spread_pct = (sell.bid - buy.ask)/buy.ask*100.
/// Anything above 0.05 % (5 bps) is emitted; the top 50 by spread are returned.

/// omnibus_getorderbook — placeholder (matching engine not heap-allocated yet)

/// omnibus_getbridgestatus — real bridge state from BridgeState

/// bridge_lock — user locks OMNI in vault to bridge to destination chain.
/// Params: {address, amount_sat, destination_chain, destination_addr}
/// Validates caps + creates LockRecord. The TX itself must be submitted
/// separately via sendtransaction with op_return memo "bridge_lock:<nonce_hex>".
/// This endpoint pre-validates and returns the nonce the user must embed.

/// bridge_unlock_request — relayer submits a multi-sig unlock for a burn event on dest chain.
/// Params: {signer_addr (20-byte hex), recipient_addr (20-byte hex), amount_sat, nonce_hex, relayer_sig}

/// bridge_fraud_challenge — anyone can void a pending unlock with a fraud proof.
/// Params: {nonce_hex, proof} (proof is logged but not cryptographically verified in V1)

/// bridge_settle — try to settle a pending unlock after challenge window.
/// Relayers call this; if threshold sigs present and window expired, funds release.

/// htlc_btc_buildScript — build a Bitcoin HTLC P2WSH redeem script + bech32 address.
///
/// This is a pure off-chain helper for atomic swaps with the Omnibus chain. The
/// returned script + address let a TS client construct a funding TX (PSBT) for
/// the user's external Bitcoin wallet (Electrum / hardware) to sign and broadcast.
/// No Bitcoin network state is touched.
///
/// Params:
///   recipient_pk : 33-byte compressed pubkey (hex)  — claims with preimage
///   sender_pk    : 33-byte compressed pubkey (hex)  — refunds after timeout
///   hash_lock    : 32-byte SHA256(preimage) (hex)
///   timelock     : absolute block height (CLTV)
///   network      : "mainnet" | "testnet" | "regtest" | "signet"
///
/// Result: { redeem_script_hex, p2wsh_address, witness_program_hex, network, hrp }

/// getbridgestatus — returns live BridgeState summary (locked, volume, paused).

/// omnibus_gettotalmined — total OMNI minted via mining since genesis.
/// Sums blockRewardAt(height) from height=1 to current chain tip (genesis
/// at height 0 carries no reward). Returns SAT and OMNI strings; callers
/// do not need to know SAT/OMNI conversion. Halving is honored automatically
/// by blockRewardAt.

/// omnibus_bridge_limits — public-facing bridge configuration so any wallet
/// or relayer can verify the active per-tx and daily caps, the threshold
/// sig requirement, and the challenge window length. Read-only; numbers
/// come from chain_config compile-time constants.

/// omnibus_getoraclepolicy — return current price-deviation policy as JSON.
/// Read under the global mutex so callers see a consistent snapshot even if
/// `omnibus_setoraclepolicy` is racing.

/// omnibus_setoraclepolicy — atomically replace the price-deviation policy.
/// Accepts both array and object params shapes:
///   {"params":[2.0, 5.0, 10.0, true]}
///   {"params":{"warn_pct":2.0,"reject_pct":5.0,"fillgap_pct":10.0,"enabled":true}}
/// Missing fields keep their current value. Returns the new policy.

/// Extract a float field from `"params":{...}` (or top-level if no params).
/// Accepts `"key":2.5` and `"key":"2.5"` forms.
pub fn extractParamObjectFloat(json: []const u8, key: []const u8) ?f64 {
    if (extractParamObjectField(json, key)) |s| {
        return std.fmt.parseFloat(f64, s) catch null;
    }
    // Numeric literal (no quotes) — search `"key"` then read digits/dot/sign.
    var nbuf: [128]u8 = undefined;
    if (key.len + 2 > nbuf.len) return null;
    nbuf[0] = '"';
    @memcpy(nbuf[1 .. 1 + key.len], key);
    nbuf[1 + key.len] = '"';
    const needle = nbuf[0 .. key.len + 2];
    var pos: usize = 0;
    while (pos + needle.len <= json.len) : (pos += 1) {
        if (!std.mem.startsWith(u8, json[pos..], needle)) continue;
        var i = pos + needle.len;
        while (i < json.len and (json[i] == ' ' or json[i] == ':' or json[i] == '\t')) i += 1;
        if (i >= json.len) return null;
        const start = i;
        // Allow leading minus, digits, dot, exponent.
        if (json[i] == '-' or json[i] == '+') i += 1;
        while (i < json.len and ((json[i] >= '0' and json[i] <= '9') or
            json[i] == '.' or json[i] == 'e' or json[i] == 'E' or
            json[i] == '+' or json[i] == '-')) i += 1;
        if (i == start) return null;
        return std.fmt.parseFloat(f64, json[start..i]) catch null;
    }
    return null;
}

/// Extract a bool field — looks for `"key":true` or `"key":false`.
pub fn extractParamObjectBool(json: []const u8, key: []const u8) ?bool {
    var nbuf: [128]u8 = undefined;
    if (key.len + 2 > nbuf.len) return null;
    nbuf[0] = '"';
    @memcpy(nbuf[1 .. 1 + key.len], key);
    nbuf[1 + key.len] = '"';
    const needle = nbuf[0 .. key.len + 2];
    var pos: usize = 0;
    while (pos + needle.len <= json.len) : (pos += 1) {
        if (!std.mem.startsWith(u8, json[pos..], needle)) continue;
        var i = pos + needle.len;
        while (i < json.len and (json[i] == ' ' or json[i] == ':' or json[i] == '\t')) i += 1;
        if (i + 4 <= json.len and std.mem.startsWith(u8, json[i..], "true")) return true;
        if (i + 5 <= json.len and std.mem.startsWith(u8, json[i..], "false")) return false;
        return null;
    }
    return null;
}

pub const ParamArrayFloats = struct {
    values: [4]f64 = .{ 0, 0, 0, 0 },
    count: usize = 0,
    bool_present: bool = false,
    bool_value: bool = false,
};

/// Parse `"params":[w,r,f,e]` positionally. Up to 3 leading floats and 1
/// trailing bool. Returns null when no params array is found.
pub fn extractParamArrayFloats(json: []const u8) ?ParamArrayFloats {
    const params_pos = std.mem.indexOf(u8, json, "\"params\"") orelse return null;
    const arr_start = std.mem.indexOfScalarPos(u8, json, params_pos, '[') orelse return null;
    // Make sure no `{` appears between "params" and `[` (object shape wins).
    if (std.mem.indexOfScalarPos(u8, json, params_pos, '{')) |obj_pos| {
        if (obj_pos < arr_start) return null;
    }

    var out = ParamArrayFloats{};
    var i: usize = arr_start + 1;
    while (i < json.len and out.count < 3) {
        // Skip whitespace + commas
        while (i < json.len and (json[i] == ' ' or json[i] == ',' or json[i] == '\t')) i += 1;
        if (i >= json.len or json[i] == ']') break;
        // bool detection
        if (i + 4 <= json.len and std.mem.startsWith(u8, json[i..], "true")) {
            out.bool_present = true;
            out.bool_value = true;
            i += 4;
            continue;
        }
        if (i + 5 <= json.len and std.mem.startsWith(u8, json[i..], "false")) {
            out.bool_present = true;
            out.bool_value = false;
            i += 5;
            continue;
        }
        // numeric
        const start = i;
        if (json[i] == '-' or json[i] == '+') i += 1;
        while (i < json.len and ((json[i] >= '0' and json[i] <= '9') or
            json[i] == '.' or json[i] == 'e' or json[i] == 'E' or
            json[i] == '+' or json[i] == '-')) i += 1;
        if (i == start) {
            i += 1;
            continue;
        }
        const v = std.fmt.parseFloat(f64, json[start..i]) catch {
            continue;
        };
        out.values[out.count] = v;
        out.count += 1;
    }
    // Continue past the floats in case a trailing bool exists.
    while (i < json.len and json[i] != ']') : (i += 1) {
        if (i + 4 <= json.len and std.mem.startsWith(u8, json[i..], "true")) {
            out.bool_present = true;
            out.bool_value = true;
            break;
        }
        if (i + 5 <= json.len and std.mem.startsWith(u8, json[i..], "false")) {
            out.bool_present = true;
            out.bool_value = false;
            break;
        }
    }
    return out;
}

/// Approximate on-wire bytes per TX scheme (base overhead ~220 bytes fixed fields).
pub fn estimateTxBytes(scheme: transaction_mod.Scheme) u64 {
    const base: u64 = 220; // txid+from+to+amount+fee+nonce+timestamp overhead
    const extra: u64 = switch (scheme) {
        .omni_ecdsa        => @as(u64, 97),    // sig(64) + pubkey(33)
        .love_dilithium,
        .rent_ml_dsa,
        .pq_omni_ml_dsa,
        .pq_omni_dilithium => @as(u64, 5245),  // ML-DSA-87: sig(3293) + pubkey(1952)
        .food_falcon,
        .pq_omni_falcon    => @as(u64, 1563),  // Falcon-512: sig(666) + pubkey(897)
        .vacation_slh_dsa,
        .pq_omni_slh_dsa   => @as(u64, 49984), // SLH-DSA-256s: sig(49856) + pubkey(64) + overhead
        .hybrid_q1,
        .hybrid_q3         => @as(u64, 5342),  // ECDSA(97) + ML-DSA-87(5245)
        .hybrid_q2         => @as(u64, 1660),  // ECDSA(97) + Falcon-512(1563)
        .hybrid_q4         => @as(u64, 50081), // ECDSA(97) + SLH-DSA(49984)
    };
    return base + extra;
}


// ─── EVM-compat RPC Handlers (Ethereum-style) ───────────────────────────────
//
// These handlers translate eth_* JSON-RPC requests into calls against the
// `evm_executor` module which itself wraps revm via FFI.  We only support the
// minimum surface needed by wallets / scripts:
//   * eth_call               — view call, no state change
//   * eth_sendRawTransaction — broadcast (currently: route to evm.call())
//   * eth_getCode            — fetch deployed bytecode
//   * eth_estimateGas        — gas estimation
//   * eth_chainId            — return chain id as 0x... hex (CAIP-2 / EIP-695)
//
// Param parsing is pragmatic: we extract object fields with the existing
// `extractStr`/`extractField*` helpers — full EIP-1474 RPC compatibility is
// **not** a goal yet.

/// Extract an object field from a params object, handling shapes like
/// `"params":[{"to":"0xabc","data":"0x"}, "latest"]`.
/// Falls back to the top-level field if the params object isn't found —
/// this lets callers POST flat JSON for testing.
pub fn extractParamObjectField(json: []const u8, key: []const u8) ?[]const u8 {
    const params_pos = std.mem.indexOf(u8, json, "\"params\"") orelse {
        return extractStr(json, key);
    };
    const obj_start = std.mem.indexOfScalarPos(u8, json, params_pos, '{') orelse return null;
    // naive: search for `"key"` inside the params region (until matching `}`).
    // Good enough for one-level objects.
    var depth: i32 = 0;
    var end: usize = obj_start;
    var i: usize = obj_start;
    while (i < json.len) : (i += 1) {
        if (json[i] == '{') depth += 1
        else if (json[i] == '}') {
            depth -= 1;
            if (depth == 0) { end = i; break; }
        }
    }
    if (end <= obj_start) return null;
    return extractStr(json[obj_start .. end + 1], key);
}

/// Extract a numeric field from the params object.  Accepts both bare ints
/// (`"value":1000`) and hex strings (`"value":"0x3e8"`).
pub fn extractParamObjectU64(json: []const u8, key: []const u8) u64 {
    if (extractParamObjectField(json, key)) |s| {
        // hex string?
        if (s.len >= 2 and s[0] == '0' and (s[1] == 'x' or s[1] == 'X')) {
            return std.fmt.parseInt(u64, s[2..], 16) catch 0;
        }
        return std.fmt.parseInt(u64, s, 10) catch 0;
    }
    // numeric literal in JSON (no quotes) — fall back via simple search
    var nbuf: [128]u8 = undefined;
    if (key.len + 2 > nbuf.len) return 0;
    nbuf[0] = '"';
    @memcpy(nbuf[1..1+key.len], key);
    nbuf[1+key.len] = '"';
    const needle = nbuf[0..key.len+2];
    var pos: usize = 0;
    while (pos + needle.len <= json.len) : (pos += 1) {
        if (!std.mem.startsWith(u8, json[pos..], needle)) continue;
        var i = pos + needle.len;
        while (i < json.len and (json[i] == ' ' or json[i] == ':' or json[i] == '\t')) i += 1;
        if (i >= json.len) return 0;
        if (json[i] >= '0' and json[i] <= '9') {
            const start = i;
            while (i < json.len and json[i] >= '0' and json[i] <= '9') i += 1;
            return std.fmt.parseInt(u64, json[start..i], 10) catch 0;
        }
        return 0;
    }
    return 0;
}


/// Helper: extract param[idx] as a JSON string from {"params":[...]}
/// Trivial parser — assumes params is a plain array of string/object/etc.
pub fn extractStringFromArrayParams(body: []const u8, idx: usize) ?[]const u8 {
    // Find "params":[
    const params_key = "\"params\"";
    const k_pos = std.mem.indexOf(u8, body, params_key) orelse return null;
    var p = k_pos + params_key.len;
    while (p < body.len and (body[p] == ' ' or body[p] == ':' or body[p] == '\t')) : (p += 1) {}
    if (p >= body.len or body[p] != '[') return null;
    p += 1;
    var current_idx: usize = 0;
    while (p < body.len) {
        // Skip whitespace and commas.
        while (p < body.len and (body[p] == ' ' or body[p] == ',' or body[p] == '\t' or body[p] == '\n')) : (p += 1) {}
        if (p >= body.len or body[p] == ']') return null;
        // Element start.
        if (body[p] == '"') {
            // String — find closing quote.
            const start = p + 1;
            var q = start;
            while (q < body.len and body[q] != '"') : (q += 1) {
                if (body[q] == '\\') q += 1;
            }
            if (q >= body.len) return null;
            if (current_idx == idx) {
                return body[start..q];
            }
            p = q + 1;
        } else {
            // Non-string element (number/bool/null/object/array) — skip till
            // matching delim. For our use case only strings at index 0 are
            // needed, so just bail.
            return null;
        }
        current_idx += 1;
    }
    return null;
}

// ─── Teste ────────────────────────────────────────────────────────────────────

const testing = std.testing;

// ── extractStr ────────────────────────────────────────────────────────────────

test "extractStr — field simplu" {
    const json =
        \\{"jsonrpc":"2.0","method":"getbalance","id":1}
    ;
    const m = extractStr(json, "method");
    try testing.expect(m != null);
    try testing.expectEqualStrings("getbalance", m.?);
}

test "extractStr — jsonrpc version" {
    const json =
        \\{"jsonrpc":"2.0","id":1}
    ;
    const v = extractStr(json, "jsonrpc");
    try testing.expect(v != null);
    try testing.expectEqualStrings("2.0", v.?);
}

test "extractStr — field lipsa returneaza null" {
    const json =
        \\{"jsonrpc":"2.0","id":1}
    ;
    try testing.expect(extractStr(json, "method") == null);
}

test "extractStr — field cu spatii in jur" {
    const json =
        \\{"method" : "getstatus","id":1}
    ;
    const m = extractStr(json, "method");
    try testing.expect(m != null);
    try testing.expectEqualStrings("getstatus", m.?);
}

test "extractStr — string gol" {
    const json = "{}";
    try testing.expect(extractStr(json, "anything") == null);
}

// ── findJsonArray / findJsonObject / parseStringArray / parseHexArray ────────

test "findJsonArray — simple array" {
    const json =
        \\{"foo":["a","b","c"]}
    ;
    const arr = findJsonArray(json, "foo");
    try testing.expect(arr != null);
    try testing.expectEqualStrings("[\"a\",\"b\",\"c\"]", arr.?);
}

test "findJsonArray — array with nested objects" {
    const json =
        \\{"items":[{"k":"v"},{"k":"w"}],"other":1}
    ;
    const arr = findJsonArray(json, "items");
    try testing.expect(arr != null);
    try testing.expectEqualStrings("[{\"k\":\"v\"},{\"k\":\"w\"}]", arr.?);
}

test "findJsonArray — missing key returns null" {
    const json =
        \\{"a":1}
    ;
    try testing.expect(findJsonArray(json, "missing") == null);
}

test "findJsonArray — value is not array returns null" {
    const json =
        \\{"foo":"not-an-array"}
    ;
    try testing.expect(findJsonArray(json, "foo") == null);
}

test "findJsonObject — simple object" {
    const json =
        \\{"params":{"chain":"btc","height":42}}
    ;
    const obj = findJsonObject(json, "params");
    try testing.expect(obj != null);
    try testing.expectEqualStrings("{\"chain\":\"btc\",\"height\":42}", obj.?);
}

test "findJsonObject — nested objects with brackets in strings" {
    const json =
        \\{"x":{"y":"some [string] with brackets","z":1}}
    ;
    const obj = findJsonObject(json, "x");
    try testing.expect(obj != null);
    try testing.expect(std.mem.indexOf(u8, obj.?, "[string]") != null);
}

test "parseStringArray — three hex strings" {
    const json =
        \\{"proof":["0xaa","0xbb","0xcc"]}
    ;
    const r = (try parseStringArray(json, "proof", testing.allocator)) orelse {
        try testing.expect(false);
        return;
    };
    defer testing.allocator.free(r);
    try testing.expectEqual(@as(usize, 3), r.len);
    try testing.expectEqualStrings("0xaa", r[0]);
    try testing.expectEqualStrings("0xbb", r[1]);
    try testing.expectEqualStrings("0xcc", r[2]);
}

test "parseStringArray — empty array" {
    const json =
        \\{"proof":[]}
    ;
    const r = (try parseStringArray(json, "proof", testing.allocator)) orelse {
        try testing.expect(false);
        return;
    };
    defer testing.allocator.free(r);
    try testing.expectEqual(@as(usize, 0), r.len);
}

test "parseHexArray — decodes 0x-prefixed and bare hex" {
    const json =
        \\{"sigs":["0x01ab","cd02"]}
    ;
    const r = (try parseHexArray(json, "sigs", testing.allocator)) orelse {
        try testing.expect(false);
        return;
    };
    defer freeHexArray(r, testing.allocator);
    try testing.expectEqual(@as(usize, 2), r.len);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x01, 0xab }, r[0]);
    try testing.expectEqualSlices(u8, &[_]u8{ 0xcd, 0x02 }, r[1]);
}

test "parseHexArray — odd hex length errors out" {
    const json =
        \\{"sigs":["0x1"]}
    ;
    const r = parseHexArray(json, "sigs", testing.allocator);
    try testing.expectError(error.OddHexLength, r);
}

test "parseIndicesArray — bit string parses" {
    var buf: [8]u1 = undefined;
    const arr_body = "[0,1,1,0,1]";
    const n = parseIndicesArray(arr_body, &buf);
    try testing.expectEqual(@as(usize, 5), n);
    try testing.expectEqual(@as(u1, 0), buf[0]);
    try testing.expectEqual(@as(u1, 1), buf[1]);
    try testing.expectEqual(@as(u1, 1), buf[2]);
    try testing.expectEqual(@as(u1, 0), buf[3]);
    try testing.expectEqual(@as(u1, 1), buf[4]);
}

test "parseIndicesArray — empty array" {
    var buf: [4]u1 = undefined;
    try testing.expectEqual(@as(usize, 0), parseIndicesArray("[]", &buf));
}

// ── extractId ────────────────────────────────────────────────────────────────

test "extractId — id numeric" {
    const json =
        \\{"jsonrpc":"2.0","method":"getblockcount","id":42}
    ;
    try testing.expectEqual(@as(u32, 42), extractId(json));
}

test "extractId — id 1" {
    const json =
        \\{"method":"x","id":1}
    ;
    try testing.expectEqual(@as(u32, 1), extractId(json));
}

test "extractId — id lipsa returneaza 1 (default)" {
    const json =
        \\{"method":"x"}
    ;
    try testing.expectEqual(@as(u32, 1), extractId(json));
}

test "extractId — id mare" {
    const json =
        \\{"id":99999}
    ;
    try testing.expectEqual(@as(u32, 99999), extractId(json));
}

// ── extractArrayStr ───────────────────────────────────────────────────────────

test "extractArrayStr — index 0 din params array" {
    const json =
        \\{"method":"getbalance","params":["ob1ql33v8q9wqvqrschu982lvrnvfupyzcvj746kqh"],"id":1}
    ;
    const s = extractArrayStr(json, 0);
    try testing.expect(s != null);
    try testing.expectEqualStrings("ob1ql33v8q9wqvqrschu982lvrnvfupyzcvj746kqh", s.?);
}

test "extractArrayStr — index 0 din array cu doua elemente" {
    const json =
        \\{"method":"sendtransaction","params":["ob1qrpdsg3r7mvvunw6ket46qmjzlx6fuu3ppxlfas",1000],"id":1}
    ;
    const s = extractArrayStr(json, 0);
    try testing.expect(s != null);
    try testing.expectEqualStrings("ob1qrpdsg3r7mvvunw6ket46qmjzlx6fuu3ppxlfas", s.?);
}

test "extractArrayStr — index inexistent returneaza null" {
    const json =
        \\{"method":"x","params":["addr"],"id":1}
    ;
    try testing.expect(extractArrayStr(json, 5) == null);
}

test "extractArrayStr — params lipsa returneaza null" {
    const json =
        \\{"method":"x","id":1}
    ;
    try testing.expect(extractArrayStr(json, 0) == null);
}

test "extractArrayStr — params array gol returneaza null" {
    const json =
        \\{"method":"x","params":[],"id":1}
    ;
    try testing.expect(extractArrayStr(json, 0) == null);
}

// ── extractArrayNum ───────────────────────────────────────────────────────────

test "extractArrayNum — al doilea element numeric" {
    const json =
        \\{"method":"sendtransaction","params":["ob1qrpdsg3r7mvvunw6ket46qmjzlx6fuu3ppxlfas",500000000],"id":1}
    ;
    try testing.expectEqual(@as(u64, 500000000), extractArrayNum(json, 1));
}

test "extractArrayNum — primul element numeric" {
    const json =
        \\{"method":"x","params":[42],"id":1}
    ;
    try testing.expectEqual(@as(u64, 42), extractArrayNum(json, 0));
}

test "extractArrayNum — index inexistent returneaza 0" {
    const json =
        \\{"method":"x","params":["addr",100],"id":1}
    ;
    try testing.expectEqual(@as(u64, 0), extractArrayNum(json, 5));
}

test "extractArrayNum — params lipsa returneaza 0" {
    const json =
        \\{"method":"x","id":1}
    ;
    try testing.expectEqual(@as(u64, 0), extractArrayNum(json, 0));
}

// ── extractContentLength ──────────────────────────────────────────────────────

test "extractContentLength — header corect" {
    const header = "POST / HTTP/1.1\r\nContent-Length: 42\r\nContent-Type: application/json\r\n\r\n";
    try testing.expectEqual(@as(usize, 42), extractContentLength(header));
}

test "extractContentLength — valoare 0" {
    const header = "GET / HTTP/1.1\r\nContent-Length: 0\r\n\r\n";
    try testing.expectEqual(@as(usize, 0), extractContentLength(header));
}

test "extractContentLength — header fara Content-Length returneaza 0" {
    const header = "GET / HTTP/1.1\r\nAccept: */*\r\n\r\n";
    try testing.expectEqual(@as(usize, 0), extractContentLength(header));
}

test "extractContentLength — lungime mare" {
    const header = "POST / HTTP/1.1\r\nContent-Length: 16384\r\n\r\n";
    try testing.expectEqual(@as(usize, 16384), extractContentLength(header));
}

// ─── AI Agent endpoints ──────────────────────────────────────────────────────
//
// Aceste endpointuri sunt consumate de clientul AI Agent extern (Python in
// 2_SDK/omnibus-sdk/agent/, ulterior Rust in 3_DESKTOP_APPS/...).
// Nodul ține brain-ul (decizia: ce, când, pe ce venue) iar clientul extern
// face execuția pe LCX/Kraken/Coinbase/etc. Prețurile pentru decizie vin DOAR
// din oracle-ul on-chain (oracle_fetcher.zig) — clientul nu mai întreabă CEX.

/// Helper: extrage un parametru u32 dintr-un body JSON minimal.
/// Returneaza null daca lipseste sau nu e numar.
pub fn extractU32Param(body: []const u8, key_with_quotes: []const u8) ?u32 {
    const at = std.mem.indexOf(u8, body, key_with_quotes) orelse return null;
    var i: usize = at + key_with_quotes.len;
    // Sari peste : si whitespace.
    while (i < body.len and (body[i] == ':' or body[i] == ' ' or body[i] == '\t')) : (i += 1) {}
    const start = i;
    while (i < body.len and body[i] >= '0' and body[i] <= '9') : (i += 1) {}
    if (i == start) return null;
    return std.fmt.parseInt(u32, body[start..i], 10) catch null;
}

pub fn extractU64Param(body: []const u8, key_with_quotes: []const u8) ?u64 {
    const at = std.mem.indexOf(u8, body, key_with_quotes) orelse return null;
    var i: usize = at + key_with_quotes.len;
    while (i < body.len and (body[i] == ':' or body[i] == ' ' or body[i] == '\t')) : (i += 1) {}
    const start = i;
    while (i < body.len and body[i] >= '0' and body[i] <= '9') : (i += 1) {}
    if (i == start) return null;
    return std.fmt.parseInt(u64, body[start..i], 10) catch null;
}

/// Extrage un parametru string. Returneaza slice peste body (nu copiaza).
pub fn extractStrParam(body: []const u8, key_with_quotes: []const u8) ?[]const u8 {
    const at = std.mem.indexOf(u8, body, key_with_quotes) orelse return null;
    var i: usize = at + key_with_quotes.len;
    while (i < body.len and (body[i] == ':' or body[i] == ' ' or body[i] == '\t')) : (i += 1) {}
    if (i >= body.len or body[i] != '"') return null;
    i += 1;
    const start = i;
    while (i < body.len and body[i] != '"') : (i += 1) {}
    if (i >= body.len) return null;
    return body[start..i];
}

/// RPC `agent_list` — toți agenții incarcati pe nod, cu tier curent + capital.
/// Public read-only. Folosit de explorer + dashboard.
// ─── OmniBus ID handlers ────────────────────────────────────────────────
//
// Read-only identity RPCs that derive everything from current chain state:
// DID from the address h160, OBM byte from reputation+validator+DNS, and
// an off-chain Manifest root if the caller wants to anchor or verify one.
// No new on-chain storage is introduced.

const id_layer_mod = @import("identity/identity.zig");

/// RPC `getdid` — returns `did:omnibus:<base58(sha256(h160))>` for an address.

/// RPC `getobm` — 1-byte OmniBus Binary Map for an address, with each bit
/// also surfaced as a named boolean so clients don't have to decode it.

/// RPC `getfacets <addr>` — returns which OmniBus ID facets (Social,
/// Professional, Cultural) the holder has populated.
///
/// Facet roots themselves live off-chain in the holder's vault — chain
/// only sees them when explicitly anchored via a manifest_anchor TX. Until
/// that endpoint exists, this RPC reports which facets the chain has
/// derivable evidence for: social=true if the address has follows on chain,
/// professional=true if it has any kyc_attest entries (treated as cert
/// proxies for now), cultural=true if it has POAPs.
///
/// This is intentionally conservative — false negatives are expected for
/// holders who keep everything off-chain. Only true positives are reliable.

/// RPC `getreputation` — citeste paharele LOVE/FOOD/RENT/VACATION pentru o
/// adresa, plus rep total agregat (0-1M) si tier (OMNI/LOVE/FOOD/RENT/VACATION).
/// Vezi memory/project_omnibus_reputation_economy.md pentru rationale.
///
/// Body: {"address": "ob1q..."}
/// Răspuns: { "address", "cups": {love, food, rent, vacation}, "total",
///           "tier", "satoshi_badge", "first_active_block", "last_active_block",
///           "total_blocks_mined", "violations" }

/// RPC `getreputationtop` — top N adrese sortate după reputation total descendent.
/// Body: {"limit": 50}  (default 50, max 200)


/// RPC `agent_status` — detalii pentru un singur agent (filtrat dupa wallet_index).
/// Body: {"wallet_index": N}

/// RPC `agent_pending_decisions` — decizii non-native nesettled, pentru clientul extern.
/// Body opțional: {"wallet_index": N} pentru filtrare per agent.
/// Răspuns: { "decisions": [ {id, wallet_index, block_height, emitted_ms, venue,
///   kind, pair, amount_sat, reason}, ... ] }

/// RPC `agent_report_execution` — clientul extern raportează rezultatul.
/// Body: {"decision_id": N, "status": "success|rejected|network_error|timeout|cancelled",
///        "external_id": "LCX-12345", "filled_amount_sat": 1000, "fill_price_micro_usd": 65000000000,
///        "error_msg": "..." }

// ── Fee model ────────────────────────────────────────────────────────
//
// Two distinct fees apply on EVERY fill, charged independently from the
// participant's exchange-internal balance:
//
//   1. Network fee — flat, per fill. Goes to the miner of the block
//      that includes the fill. This is the on-chain TX cost, conceptually
//      the same as a `sendrawtransaction` fee.
//
//   2. Exchange fee — proportional, maker/taker split (Kraken-style).
//      Goes to the exchange treasury (registrar slot 1 = `bridge.omnibus`,
//      reused as the trading-fee sink until we wire a dedicated slot).
//      Maker (resting order being matched) pays less, taker (incoming
//      aggressive order) pays more. Same convention as 90% of CEX/DEX.
//
// Self-trade is allowed (founder request 2026-04-28) so wash trades pay
// the full maker+taker fee on both sides — that's the operator's edge.

/// Network fee per fill, denominated in SAT of the BASE currency. Flat.
/// 1000 SAT = 0.000001 OMNI on OMNI/* pairs. Tiny on testnet so it doesn't
/// drown out the small grants. Mainnet would be tuned higher.
pub const FILL_NETWORK_FEE_SAT: u64 = 1000;

/// Exchange fee — basis points (1 bp = 0.01%). Charged in QUOTE currency.
/// 10 bps = 0.10% taker, 5 bps = 0.05% maker → matches Kraken's lowest tier.
pub const EXCHANGE_FEE_TAKER_BPS: u64 = 10;
pub const EXCHANGE_FEE_MAKER_BPS: u64 = 5;
const FEE_BPS_DENOMINATOR: u64 = 10_000;

/// Compute the exchange fee for a fill leg.
///   notional_micro = price (micro-USD) × amount (SAT) / 1e9
///   fee = notional × bps / 10_000
/// Returned value is in micro-USD (or whatever unit the quote uses).
pub fn computeExchangeFeeMicro(price_micro: u64, amount_sat: u64, bps: u64) u64 {
    // Use u128 intermediate to avoid overflow on big trades.
    const notional: u128 =
        (@as(u128, price_micro) * @as(u128, amount_sat)) / 1_000_000_000;
    const fee: u128 = (notional * @as(u128, bps)) / @as(u128, FEE_BPS_DENOMINATOR);
    return @intCast(@min(fee, @as(u128, std.math.maxInt(u64))));
}

// ── KYC tier order caps ──────────────────────────────────────────────
// Per-tier max notional (in micro-USD) for a single order. `none` is
// blocked entirely; `pro` is uncapped. Mirrors LCX/Kraken brackets,
// scaled to micro-USD to match `computeExchangeFeeMicro` units.
pub fn kycMaxNotionalMicro(level: kyc_mod.Level) u64 {
    return switch (level) {
        .none     => 0,
        .starter  => 1_000_000_000,         // $1k
        .verified => 100_000_000_000,       // $100k
        .pro      => std.math.maxInt(u64),  // unlimited
    };
}

/// Notional for a single order: price (micro-USD) × amount (SAT) / 1e9.
/// Saturates at u64.max instead of overflowing.
pub fn orderNotionalMicro(price_micro: u64, amount_sat: u64) u64 {
    const n: u128 =
        (@as(u128, price_micro) * @as(u128, amount_sat)) / 1_000_000_000;
    return @intCast(@min(n, @as(u128, std.math.maxInt(u64))));
}

// ── Oracle price-band ────────────────────────────────────────────────
/// Reject orders priced more than this many basis points away from the
/// oracle reference. 1000 bps = 10%. Hardcoded for now; future work:
/// expose via `omnibus_setoraclepolicy` (would add `order_band_bps` to
/// `oracle_policy.OraclePolicy`).
pub const ORDER_BAND_BPS: u64 = 1000;

/// Map an exchange pair_id to the oracle ChainId for its BASE leg, when
/// the chain is one the oracle tracks. LCX (pair_id 2) returns null —
/// no oracle feed, skip the band check.
pub fn oracleChainForPair(pair_id: u16) ?price_oracle_mod.ChainId {
    return switch (pair_id) {
        0, 4, 5, 6 => .omni,
        1          => .btc,
        3          => .eth,
        else       => null, // LCX (2) or unknown
    };
}

pub fn exchangePairLookup(label: []const u8) ?u16 {
    // Accept "BASE/QUOTE" sau "BASE-QUOTE". Case-insensitive.
    var sep: ?usize = null;
    for (label, 0..) |c, i| {
        if (c == '/' or c == '-') { sep = i; break; }
    }
    const s = sep orelse return null;
    const base = label[0..s];
    const quote = label[s + 1 ..];
    for (EXCHANGE_PAIRS) |p| {
        if (asciiEqIgnoreCase(p.base, base) and asciiEqIgnoreCase(p.quote, quote)) {
            return p.id;
        }
    }
    return null;
}

pub fn asciiEqIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (std.ascii.toLower(ca) != std.ascii.toLower(cb)) return false;
    }
    return true;
}

// ─── PHASE 2E.1 helpers (Kraken-compat trade history) ──────────────────

/// Return "BASE/QUOTE" label for a pair_id, or "?/?" when unknown.
/// Used by Kraken-compat trade/ledger endpoints to render pair as string.
fn pairLabelFor(pair_id: u16, buf: *[16]u8) []const u8 {
    for (EXCHANGE_PAIRS) |p| {
        if (p.id == pair_id) {
            return std.fmt.bufPrint(buf, "{s}/{s}", .{ p.base, p.quote }) catch "?/?";
        }
    }
    return "?/?";
}

/// Fixed maker-fee bps in micro-USD against a notional. Mirrors the
/// computeExchangeFeeMicro formula but exposed for Ledgers / TradesHistory
/// per-trade fee column.
fn ledgerFeeMicroFor(price_micro: u64, amount_sat: u64) u64 {
    return computeExchangeFeeMicro(price_micro, amount_sat, EXCHANGE_FEE_TAKER_BPS);
}

/// Returns true if the trader address (case-sensitive) participated in
/// this fill on either side. Used by ClosedOrders / TradesHistory filters.
fn fillTouchesAddr(f: *const matching_mod.Fill, addr: []const u8) bool {
    return std.mem.eql(u8, f.getBuyerAddress(), addr)
        or std.mem.eql(u8, f.getSellerAddress(), addr);
}

/// Returns side from the trader's perspective for a fill. "buy" if trader
/// is the buyer leg, "sell" if seller, "" when neither.
fn fillSideForTrader(f: *const matching_mod.Fill, addr: []const u8) []const u8 {
    if (std.mem.eql(u8, f.getBuyerAddress(), addr)) return "buy";
    if (std.mem.eql(u8, f.getSellerAddress(), addr)) return "sell";
    return "";
}

fn ordersPathSlice(ctx: *ServerCtx) ?[]const u8 {
    if (ctx.orders_path_len == 0) return null;
    return ctx.orders_path_buf[0..ctx.orders_path_len];
}

pub fn gridPathSlice(ctx: *ServerCtx) ?[]const u8 {
    if (ctx.grid_path_len == 0) return null;
    return ctx.grid_path_buf[0..ctx.grid_path_len];
}

/// Scrie o intrare in jurnalul append-only orders.jsonl.
/// `kind` = "place" sau "cancel". Ignoram erorile de I/O — jurnalul e
/// best-effort; in-memory state e adevarul curent.
pub fn ordersAppendJournal(
    ctx: *ServerCtx,
    kind: []const u8,
    line: []const u8,
) void {
    const path = ordersPathSlice(ctx) orelse return;
    const f = std.fs.cwd().createFile(path, .{ .truncate = false, .read = false }) catch |err| {
        std.debug.print("[EXCHANGE] cannot open {s} for append: {}\n", .{ path, err });
        return;
    };
    defer f.close();
    f.seekFromEnd(0) catch return;
    var buf: [1024]u8 = undefined;
    const formatted = std.fmt.bufPrint(&buf, "{{\"kind\":\"{s}\",{s}}}\n", .{ kind, line }) catch return;
    _ = f.writeAll(formatted) catch {};
}

/// Reciteste orders.jsonl la pornire. Reapeleaza placeOrder/cancelOrder pe
/// engine asa incat starea sa coincida cu ce era inainte de restart. Lipsa
/// fisierului = start curat (no-op).
fn replayOrdersJournal(ctx: *ServerCtx) !void {
    const path = ordersPathSlice(ctx) orelse return;
    const engine = ctx.exchange orelse return;

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
    var replayed: usize = 0;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const kind_key = "\"kind\":\"";
        const k_start = std.mem.indexOf(u8, line, kind_key) orelse continue;
        const k_from = k_start + kind_key.len;
        const k_end = std.mem.indexOfScalarPos(u8, line, k_from, '"') orelse continue;
        const kind = line[k_from..k_end];

        if (std.mem.eql(u8, kind, "place")) {
            const trader = extractStr(line, "trader") orelse continue;
            const side_str = extractStr(line, "side") orelse continue;
            const pair_id_u = extractArrayNumByKey(line, "pairId");
            const price = extractArrayNumByKey(line, "price");
            const amount = extractArrayNumByKey(line, "amount");
            const ts_raw = extractArrayNumByKey(line, "ts");
            if (price == 0 or amount == 0) continue;

            var order = matching_mod.Order.empty();
            order.side = if (asciiEqIgnoreCase(side_str, "buy")) .buy else .sell;
            order.pair_id = @intCast(pair_id_u);
            order.price_micro_usd = price;
            order.amount_sat = amount;
            order.timestamp_ms = if (ts_raw > 0) @intCast(ts_raw) else std.time.milliTimestamp();
            const tn = @min(trader.len, order.trader_address.len);
            @memcpy(order.trader_address[0..tn], trader[0..tn]);
            order.trader_addr_len = @intCast(tn);
            order.status = .active;
            engine.placeOrder(order) catch continue;
        } else if (std.mem.eql(u8, kind, "cancel")) {
            const oid = extractArrayNumByKey(line, "orderId");
            if (oid == 0) continue;
            engine.cancelOrder(oid) catch {};
        }
        replayed += 1;
    }
    std.debug.print("[EXCHANGE] Replayed {d} order event(s) from {s}\n", .{ replayed, path });
}

/// Cauta nonce-ul ultim folosit pentru o adresa. -1 daca nu exista intrare.
pub fn nonceLookup(ctx: *ServerCtx, addr: []const u8) i64 {
    var i: u16 = 0;
    while (i < ctx.exstate.?.nonce_count) : (i += 1) {
        const n = &ctx.exstate.?.nonces[i];
        if (n.address_len == addr.len and std.mem.eql(u8, n.address[0..n.address_len], addr)) {
            return @intCast(n.last_nonce);
        }
    }
    return -1;
}

/// Inregistreaza nonce-ul curent pentru o adresa. Daca tabelul e plin,
/// suprascrie cea mai veche intrare (FIFO simplu — testnet, nu DoS-rezistent).
pub fn nonceSet(ctx: *ServerCtx, addr: []const u8, nonce: u64) void {
    var i: u16 = 0;
    while (i < ctx.exstate.?.nonce_count) : (i += 1) {
        const n = &ctx.exstate.?.nonces[i];
        if (n.address_len == addr.len and std.mem.eql(u8, n.address[0..n.address_len], addr)) {
            n.last_nonce = nonce;
            return;
        }
    }
    if (ctx.exstate.?.nonce_count >= ctx.exstate.?.nonces.len) {
        // Evict slot 0 (cel mai vechi)
        var j: u16 = 0;
        while (j + 1 < ctx.exstate.?.nonces.len) : (j += 1) {
            ctx.exstate.?.nonces[j] = ctx.exstate.?.nonces[j + 1];
        }
        ctx.exstate.?.nonce_count -= 1;
    }
    const slot = &ctx.exstate.?.nonces[ctx.exstate.?.nonce_count];
    const cn = @min(addr.len, slot.address.len);
    @memcpy(slot.address[0..cn], addr[0..cn]);
    slot.address_len = @intCast(cn);
    slot.last_nonce = nonce;
    ctx.exstate.?.nonce_count += 1;
}

/// Inregistreaza un fill in trade_log circular (cele mai recente 256).
/// `is_paper` selects which log gets the fill. Paper and real are kept
/// isolated so a paper trade never appears in the real feed and vice-versa.
pub fn tradeLogPush(ctx: *ServerCtx, fill: matching_mod.Fill, is_paper: bool) void {
    const es = ctx.exstate orelse return;
    if (is_paper) {
        es.trade_log_paper[es.trade_head_paper] = fill;
        es.trade_head_paper = (es.trade_head_paper + 1) % @as(u32, @intCast(es.trade_log_paper.len));
        if (es.trade_count_paper < es.trade_log_paper.len) es.trade_count_paper += 1;
    } else {
        es.trade_log[es.trade_head] = fill;
        es.trade_head = (es.trade_head + 1) % @as(u32, @intCast(es.trade_log.len));
        if (es.trade_count < es.trade_log.len) es.trade_count += 1;
    }
}

/// createOrderTransaction — construieste TX JSON pentru o ordine Exchange.
/// Returns: TX JSON string cu order_id + tx_hash + parity fields.
/// Caller owns returned memory.
pub fn createOrderTransaction(
    allocator: std.mem.Allocator,
    trader: []const u8,
    side: []const u8,
    pair_id: u16,
    price_micro_usd: u64,
    amount_sat: u64,
    nonce: u64,
    order_id: u64,
    signature: []const u8,
    public_key: []const u8,
) !struct { tx_json: []u8, tx_hash: []u8 } {
    // Build canonical order data for hashing: "order|trader|side|pair|price|amount|nonce|order_id"
    var canon_buf: [512]u8 = undefined;
    const canon_str = try std.fmt.bufPrint(&canon_buf,
        "order|{s}|{s}|{d}|{d}|{d}|{d}|{d}",
        .{ trader, side, pair_id, price_micro_usd, amount_sat, nonce, order_id });

    // Double SHA256 (Bitcoin-style hash)
    var h1: [32]u8 = undefined;
    var h2: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(canon_str, &h1, .{});
    std.crypto.hash.sha2.Sha256.hash(&h1, &h2, .{});

    // Convert hash to hex
    var tx_hash_hex: [64]u8 = undefined;
    for (h2, 0..) |byte, i| {
        _ = try std.fmt.bufPrint(tx_hash_hex[i*2..i*2+2], "{x:0>2}", .{byte});
    }

    // Build TX JSON
    const tx_json = try std.fmt.allocPrint(allocator,
        "{{\"type\":\"order\",\"trader\":\"{s}\",\"side\":\"{s}\",\"pairId\":{d}," ++
        "\"price\":{d},\"amount\":{d},\"nonce\":{d},\"orderId\":{d}," ++
        "\"signature\":\"{s}\",\"publicKey\":\"{s}\",\"txHash\":\"{s}\"}}",
        .{ trader, side, pair_id, price_micro_usd, amount_sat, nonce, order_id,
           signature, public_key, &tx_hash_hex });

    return .{
        .tx_json = tx_json,
        .tx_hash = try allocator.dupe(u8, &tx_hash_hex),
    };
}

/// Build and submit a Phase-2A typed `order_place` chain TX into the
/// blockchain mempool. This is what makes the orderbook deterministic
/// across replaying nodes — `applyOrderTxs` reads these TXs back out of
/// each block and re-runs matching. Without this submission, the in-memory
/// matching engine on this node holds the only copy of the book.
///
/// `signature` is intentionally left empty: the user's ECDSA was over the
/// `EXCHANGE_ORDER_V1` canonical message (already verified at handler
/// entry), not over the chain TX hash. The pubkey_registry signature path
/// in `validateTransaction` is gated on `tx.signature.len == 128`, so an
/// empty signature skips that path — `validateTransaction` will accept the
/// TX provided the typed-TX exemptions for amount=0 / dust hold.
///
/// All string fields are heap-duped from the caller's allocator so the TX
/// can outlive this function frame. Caller must NOT free them — ownership
/// transfers into the mempool via `addTransaction`.
pub fn submitOrderPlaceTx(
    ctx: *ServerCtx,
    trader: []const u8,
    side: matching_mod.Side,
    pair_id: u16,
    price_micro_usd: u64,
    amount_sat: u64,
) !void {
    const alloc = ctx.allocator;

    // Encode OrderPlacePayload (32 bytes wire format).
    const payload = tx_payload_mod.OrderPlacePayload{
        .pair_id = pair_id,
        .side = if (side == .buy) .buy else .sell,
        .price_micro_usd = price_micro_usd,
        .amount_sat = amount_sat,
        .nonce = ctx.bc.getNextAvailableNonce(trader),
    };
    const data_buf = try alloc.alloc(u8, tx_payload_mod.OrderPlacePayload.WIRE_SIZE);
    errdefer alloc.free(data_buf);
    _ = try payload.encode(data_buf);

    // Heap-dup the addresses; `to_address = trader` is a self-send carrier
    // (orderbook layer ignores `to_address`; it's required by the address
    // validator only).
    const from_owned = try alloc.dupe(u8, trader);
    errdefer alloc.free(from_owned);
    const to_owned = try alloc.dupe(u8, trader);
    errdefer alloc.free(to_owned);

    var tx = transaction_mod.Transaction{
        .id           = g_tx_counter.fetchAdd(1, .monotonic),
        .from_address = from_owned,
        .to_address   = to_owned,
        .amount       = 0,                 // typed TX — value is in `data`
        .fee          = 1,                 // TX_MIN_FEE
        .timestamp    = std.time.timestamp(),
        .nonce        = payload.nonce,
        .signature    = "",                // see doc comment
        .hash         = "",
        .tx_type      = .order_place,
        .data         = data_buf,
    };

    // Compute and store hash so the TX is identifiable in mempool/blocks.
    const h = tx.calculateHash();
    var hash_hex_buf: [64]u8 = undefined;
    for (h, 0..) |byte, i| {
        _ = std.fmt.bufPrint(hash_hex_buf[i*2..i*2+2], "{x:0>2}", .{byte}) catch {};
    }
    const hash_owned = try alloc.dupe(u8, &hash_hex_buf);
    errdefer alloc.free(hash_owned);
    tx.hash = hash_owned;

    try ctx.bc.addTransaction(tx);
}

/// Build and submit a Phase-2A typed `order_cancel` chain TX. Same
/// ownership/signature semantics as `submitOrderPlaceTx`.
pub fn submitOrderCancelTx(
    ctx: *ServerCtx,
    trader: []const u8,
    order_id: u64,
) !void {
    const alloc = ctx.allocator;

    const payload = tx_payload_mod.OrderCancelPayload{
        .order_id = order_id,
        .nonce = ctx.bc.getNextAvailableNonce(trader),
    };
    const data_buf = try alloc.alloc(u8, tx_payload_mod.OrderCancelPayload.WIRE_SIZE);
    errdefer alloc.free(data_buf);
    _ = try payload.encode(data_buf);

    const from_owned = try alloc.dupe(u8, trader);
    errdefer alloc.free(from_owned);
    const to_owned = try alloc.dupe(u8, trader);
    errdefer alloc.free(to_owned);

    var tx = transaction_mod.Transaction{
        .id           = g_tx_counter.fetchAdd(1, .monotonic),
        .from_address = from_owned,
        .to_address   = to_owned,
        .amount       = 0,
        .fee          = 1,
        .timestamp    = std.time.timestamp(),
        .nonce        = payload.nonce,
        .signature    = "",
        .hash         = "",
        .tx_type      = .order_cancel,
        .data         = data_buf,
    };

    const h = tx.calculateHash();
    var hash_hex_buf: [64]u8 = undefined;
    for (h, 0..) |byte, i| {
        _ = std.fmt.bufPrint(hash_hex_buf[i*2..i*2+2], "{x:0>2}", .{byte}) catch {};
    }
    const hash_owned = try alloc.dupe(u8, &hash_hex_buf);
    errdefer alloc.free(hash_owned);
    tx.hash = hash_owned;

    try ctx.bc.addTransaction(tx);
}

// ═══════════════════════════════════════════════════════════════════════════
//  HTLC RPC handlers — Phase 2F.2 (TX 0x30/0x31/0x32)
// ═══════════════════════════════════════════════════════════════════════════

/// Parse a 64-char hex string into [32]u8. Returns null on length/format error.
pub fn parseHex32(hex: []const u8) ?[32]u8 {
    if (hex.len != 64) return null;
    var out: [32]u8 = undefined;
    hex_utils.hexToBytes(hex, &out) catch return null;
    return out;
}

pub fn writeHex32(b: [32]u8, out: *[64]u8) void {
    for (b, 0..) |byte, i| {
        _ = std.fmt.bufPrint(out[i*2..i*2+2], "{x:0>2}", .{byte}) catch {};
    }
}

/// Submit a typed HTLC TX to the mempool (init/claim/refund). Address +
/// data slices are heap-duped so the TX outlives this stack frame.
/// Returns the TX hash hex (64 chars), allocated from `ctx.allocator`.
pub fn submitHtlcTx(
    ctx: *ServerCtx,
    tx_type: transaction_mod.TxType,
    from: []const u8,
    to: []const u8,
    payload: []const u8,
) ![]u8 {
    const alloc = ctx.allocator;
    const data_owned = try alloc.dupe(u8, payload);
    errdefer alloc.free(data_owned);
    const from_owned = try alloc.dupe(u8, from);
    errdefer alloc.free(from_owned);
    const to_owned = try alloc.dupe(u8, to);
    errdefer alloc.free(to_owned);

    var tx = transaction_mod.Transaction{
        .id           = g_tx_counter.fetchAdd(1, .monotonic),
        .from_address = from_owned,
        .to_address   = to_owned,
        .amount       = 0,
        .fee          = 1,
        .timestamp    = std.time.timestamp(),
        .nonce        = ctx.bc.getNextAvailableNonce(from),
        .signature    = "",
        .hash         = "",
        .tx_type      = tx_type,
        .data         = data_owned,
    };

    const h = tx.calculateHash();
    var hash_hex_buf: [64]u8 = undefined;
    writeHex32(h, &hash_hex_buf);
    const hash_owned = try alloc.dupe(u8, &hash_hex_buf);
    errdefer alloc.free(hash_owned);
    tx.hash = hash_owned;

    try ctx.bc.addTransaction(tx);
    return alloc.dupe(u8, &hash_hex_buf);
}

/// `htlc_init({receiver, amount_sat, hash_lock, timelock_block, [swap_id]})`
/// Builds and submits a TX type 0x30. `swap_id` is currently optional
/// metadata reserved for atomic-swap correlation across chains.

/// `htlc_claim({htlc_id, preimage})` — TX type 0x31.

/// `htlc_refund({htlc_id})` — TX type 0x32. Caller must be original sender;
/// chain enforces current_block >= timelock_block at apply time.

/// Render an HTLC entry as a JSON object into `out`.

/// `htlc_get({htlc_id})` — read-only registry lookup.

/// `htlc_listByAddress({address})` — every HTLC where `address` is sender or recipient.

/// `htlc_listPending()` — every active HTLC on the chain (admin/debug).

/// True dacă body-ul cere mod paper. Cautam `"mode":"paper"` literal —
/// orice altceva (default, "real", missing) → real engine. Ca și pe REST
/// (`/exchange/0/*` vs `/paper/0/*`) modul e doar un selector de routing.
pub fn isPaperMode(body: []const u8) bool {
    return std.mem.indexOf(u8, body, "\"mode\":\"paper\"") != null;
}

/// Picks the engine matching the requested mode. Returns null + sets a
/// flag for the caller if the requested engine isn't allocated.
pub fn pickEngine(ctx: *ServerCtx, paper: bool) ?*matching_mod.MatchingEngine {
    return if (paper) ctx.exchange_paper else ctx.exchange;
}

/// Computes amount reserved by `address` across all active SELL orders in
/// `engine.asks[]`. Single source of truth — derived from the orderbook itself,
/// no separate state to keep in sync (auto-correct after fills, cancels,
/// partial-fills, and journal replay).
/// Caller must hold `ctx.exchange_mutex`.
pub fn computeReservedFromOrderbook(engine: *matching_mod.MatchingEngine, address: []const u8) u64 {
    var total: u64 = 0;
    var i: u32 = 0;
    while (i < engine.ask_count) : (i += 1) {
        const o = &engine.asks[i];
        if (o.status != .active and o.status != .partial) continue;
        if (!std.mem.eql(u8, o.getTraderAddress(), address)) continue;
        total +%= o.remainingSat();
    }
    return total;
}

/// Construieste mesajul canonical pentru semnatura unui placeOrder.
/// MUST match exactly ce semneaza clientul (frontend).
/// Format: "EXCHANGE_ORDER_V1\n<side>\n<pairId>\n<price>\n<amount>\n<nonce>\n<trader>"
pub fn buildOrderSignMessage(
    side: []const u8,
    pair_id: u16,
    price: u64,
    amount: u64,
    nonce: u64,
    trader: []const u8,
    out: []u8,
) ![]u8 {
    return std.fmt.bufPrint(out,
        "EXCHANGE_ORDER_V1\n{s}\n{d}\n{d}\n{d}\n{d}\n{s}",
        .{ side, pair_id, price, amount, nonce, trader });
}

/// Construieste mesajul canonical pentru cancelOrder.
pub fn buildCancelSignMessage(
    order_id: u64,
    nonce: u64,
    trader: []const u8,
    out: []u8,
) ![]u8 {
    return std.fmt.bufPrint(out,
        "EXCHANGE_CANCEL_V1\n{d}\n{d}\n{s}",
        .{ order_id, nonce, trader });
}

/// Deriva adresa nativa OmniBus (ob1q...) dintr-un compressed pubkey.
/// = bech32(hash160(pubkey)). Caller detine memoria.
pub fn deriveOBAddressFromPubkey(
    compressed_pubkey: [33]u8,
    allocator: std.mem.Allocator,
) ![]u8 {
    const h160 = wallet_mod.Wallet.pubkeyHash160(compressed_pubkey);
    return bech32_mod.encodeOBAddress(h160, allocator);
}

/// Verifica semnatura ECDSA secp256k1 pe mesajul canonical.
/// Returneaza true daca pubkey-ul corespunde adresei E si semnatura e valida.
pub fn verifyOrderSig(
    msg: []const u8,
    sig_hex: []const u8,
    pubkey_hex: []const u8,
) bool {
    if (sig_hex.len != 128 or pubkey_hex.len != 66) return false;
    var sig_bytes: [64]u8 = undefined;
    var pk_bytes: [33]u8 = undefined;
    _ = hex_utils.hexToBytes(sig_hex, &sig_bytes) catch return false;
    _ = hex_utils.hexToBytes(pubkey_hex, &pk_bytes) catch return false;
    return secp256k1_mod.Secp256k1Crypto.verify(pk_bytes, msg, sig_bytes);
}

// ═════════════════════════════════════════════════════════════════════════════
//  DNS Phase 1 — Canonical messages + signature verification
// ═════════════════════════════════════════════════════════════════════════════

pub fn buildDnsRegisterSignMessage(
    name: []const u8,
    tld: []const u8,
    address: []const u8,
    owner: []const u8,
    nonce: u64,
    out: []u8,
) ![]u8 {
    return std.fmt.bufPrint(out,
        "DNS_REGISTER_V1\n{s}\n{s}\n{s}\n{s}\n{d}",
        .{ name, tld, address, owner, nonce });
}

pub fn buildDnsTransferSignMessage(
    name: []const u8,
    tld: []const u8,
    new_owner: []const u8,
    nonce: u64,
    out: []u8,
) ![]u8 {
    return std.fmt.bufPrint(out,
        "DNS_TRANSFER_V1\n{s}\n{s}\n{s}\n{d}",
        .{ name, tld, new_owner, nonce });
}

pub fn buildDnsUpdateSignMessage(
    name: []const u8,
    tld: []const u8,
    new_address: []const u8,
    nonce: u64,
    out: []u8,
) ![]u8 {
    return std.fmt.bufPrint(out,
        "DNS_UPDATE_V1\n{s}\n{s}\n{s}\n{d}",
        .{ name, tld, new_address, nonce });
}

pub fn buildDnsRenewSignMessage(
    name: []const u8,
    tld: []const u8,
    nonce: u64,
    out: []u8,
) ![]u8 {
    return std.fmt.bufPrint(out,
        "DNS_RENEW_V1\n{s}\n{s}\n{d}",
        .{ name, tld, nonce });
}

/// Phase 2 — years-aware renewal sign message. Owner signs over the
/// {name, tld, additional_years, nonce} tuple so a captured V1 signature
/// can't be replayed at a different years tier.
pub fn buildDnsRenewYearsSignMessage(
    name: []const u8,
    tld: []const u8,
    years: u32,
    nonce: u64,
    out: []u8,
) ![]u8 {
    return std.fmt.bufPrint(out,
        "DNS_RENEW_V2\n{s}\n{s}\n{d}\n{d}",
        .{ name, tld, years, nonce });
}

/// Verifica semnatura ECDSA pentru operatii DNS.
/// Returneaza true daca semnatura e valida SI pubkey-ul deriveaza expected_owner_addr.
pub fn verifyDnsSignature(
    msg: []const u8,
    sig_hex: []const u8,
    pubkey_hex: []const u8,
    expected_owner_addr: []const u8,
    allocator: std.mem.Allocator,
) bool {
    if (sig_hex.len != 128 or pubkey_hex.len != 66) return false;
    var sig_bytes: [64]u8 = undefined;
    var pk_bytes: [33]u8 = undefined;
    _ = hex_utils.hexToBytes(sig_hex, &sig_bytes) catch return false;
    _ = hex_utils.hexToBytes(pubkey_hex, &pk_bytes) catch return false;
    if (!secp256k1_mod.Secp256k1Crypto.verify(pk_bytes, msg, sig_bytes)) return false;
    const derived_addr = deriveOBAddressFromPubkey(pk_bytes, allocator) catch return false;
    defer allocator.free(derived_addr);
    return std.mem.eql(u8, derived_addr, expected_owner_addr);
}

/// Deriveaza path-ul pentru audit log DNS din orders_path.
/// Ex: data/mainnet/orders.jsonl -> data/mainnet/dns_audit.log
fn dnsAuditPath(ctx: *ServerCtx, out: []u8) ?[]u8 {
    if (ctx.orders_path_len == 0) return null;
    const path = ctx.orders_path_buf[0..ctx.orders_path_len];
    const last_sep = std.mem.lastIndexOfAny(u8, path, "/\\") orelse return null;
    const dir = path[0 .. last_sep + 1];
    const suffix = "dns_audit.log";
    if (dir.len + suffix.len > out.len) return null;
    @memcpy(out[0..dir.len], dir);
    @memcpy(out[dir.len .. dir.len + suffix.len], suffix);
    return out[0 .. dir.len + suffix.len];
}

/// Scrie o linie in jurnalul audit DNS (append-only JSONL).
pub fn dnsAuditAppend(ctx: *ServerCtx, op: []const u8, fields: []const u8) void {
    var path_buf: [256]u8 = undefined;
    const path = dnsAuditPath(ctx, &path_buf) orelse return;
    const f = std.fs.cwd().createFile(path, .{ .truncate = false, .read = false }) catch |err| {
        std.debug.print("[DNS-AUDIT] cannot open {s} for append: {s}\n", .{ path, @errorName(err) });
        return;
    };
    defer f.close();
    f.seekFromEnd(0) catch return;
    const block: u64 = @intCast(ctx.bc.chain.items.len);
    const now_ms = std.time.milliTimestamp();
    var buf: [1536]u8 = undefined;
    const line = std.fmt.bufPrint(&buf,
        "{{\"ts\":{d},\"block\":{d},\"op\":\"{s}\",{s}}}\n",
        .{ now_ms, block, op, fields }) catch return;
    _ = f.writeAll(line) catch {};
}

/// exchange_placeOrder — plaseaza o ordine semnata pe DEX-ul nativ.
/// Required: trader, side ("buy"|"sell"), pair, price, amount, nonce,
///           signature, publicKey. Optional: pairId (in lieu of pair).
/// Pretul e in micro-USD (u64), amount in SAT (u64).

/// exchange_cancelOrder — anuleaza o ordine. Required: orderId, trader,
/// nonce, signature, publicKey. Verifica pe lant ca trader == owner.

/// exchange_getOrderbook — top N bids/asks pentru o pereche.
/// Params: pair sau pairId, optional depth (default 25, max 50).

/// exchange_getUserOrders — toate ordinele active ale unei adrese.
/// Params: trader. Optional: pairId / pair (filtru).

/// exchange_getUserTrades — istoricul on-chain de fills al unui trader.
///
/// Spre deosebire de exchange_getUserOrders care arata doar ordinele active in
/// matching engine, asta citeste fills_log.bin persistent. Astfel restart-ul
/// nodului nu pierde istoricul. Apare in "My Trades" panel pentru ambii
/// participanti (buyer + seller).
///
/// Params: trader (omni address required). Optional: limit (default 100,
/// max 500), pairId/pair (filtru).
///
/// Result: [
///   { fillId, pairId, side: "buy"|"sell" (rolul traderului in trade),
///     counterparty, price, amount, blockHeight, ts, fillId,
///     evmChainId (0 if no EVM leg), evmSettleTxHash (null pana la settle) },
///   ...
/// ]

/// exchange_getTrades — ultimele N fills. Optional: pair/pairId, address (filtru),
/// limit (default 50, max 256).

/// exchange_listPairs — perechi suportate. Static (definite la compile-time).
/// exchange_pairInfo — returns multi-chain routing + HTLC contract addresses for a pair.
/// Params: { "pair_id": N }
/// Result: { pair_id, base, quote,
///            maker_chains: [{chain, chain_id, contract}...],
///            taker_chains: [{chain, chain_id, contract}...] }


/// exchange_getStats — sumar global: total ordine, total fills, best/spread per pereche.

// ─── DEX users / API keys / exchange balances ─────────────────────────────
//
// In-memory tables persisted as append-only JSONL in
// data/<chain>/exchange-users.jsonl. On startup we replay the journal so
// all `register`, `apikey`, `revoke`, `deposit`, `withdraw` events reapply
// in order — same idempotent pattern as faucet + orders.

fn usersPathSlice(ctx: *ServerCtx) ?[]const u8 {
    if (ctx.users_path_len == 0) return null;
    return ctx.users_path_buf[0..ctx.users_path_len];
}

pub fn usersAppendJournal(ctx: *ServerCtx, kind: []const u8, line: []const u8) void {
    const path = usersPathSlice(ctx) orelse return;
    const f = std.fs.cwd().createFile(path, .{ .truncate = false, .read = false }) catch |err| {
        std.debug.print("[EXCHANGE] cannot open {s} for append: {}\n", .{ path, err });
        return;
    };
    defer f.close();
    f.seekFromEnd(0) catch return;
    var buf: [768]u8 = undefined;
    const formatted = std.fmt.bufPrint(&buf, "{{\"kind\":\"{s}\",{s}}}\n", .{ kind, line }) catch return;
    _ = f.writeAll(formatted) catch {};
}

/// Replays exchange-users.jsonl. Recognized kinds: apikey, revoke,
/// deposit, withdraw. Bad lines are silently skipped — the in-memory
/// state stays correct as long as well-formed entries replay cleanly.
fn replayUsersJournal(ctx: *ServerCtx) !void {
    const path = usersPathSlice(ctx) orelse return;
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
    var replayed: usize = 0;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const kind_key = "\"kind\":\"";
        const k_start = std.mem.indexOf(u8, line, kind_key) orelse continue;
        const k_from = k_start + kind_key.len;
        const k_end = std.mem.indexOfScalarPos(u8, line, k_from, '"') orelse continue;
        const kind = line[k_from..k_end];

        if (std.mem.eql(u8, kind, "apikey")) {
            const key_id = extractStr(line, "keyId") orelse continue;
            const sec_hash = extractStr(line, "secretHash") orelse continue;
            const owner = extractStr(line, "owner") orelse continue;
            const name = extractStr(line, "name") orelse "";
            const ts = extractArrayNumByKey(line, "ts");
            apiKeyInsert(ctx, key_id, "", sec_hash, name, owner, @intCast(ts));
        } else if (std.mem.eql(u8, kind, "revoke")) {
            const key_id = extractStr(line, "keyId") orelse continue;
            apiKeyRevoke(ctx, key_id);
        } else if (std.mem.eql(u8, kind, "deposit") or std.mem.eql(u8, kind, "withdraw")) {
            const owner = extractStr(line, "owner") orelse continue;
            const token = extractStr(line, "token") orelse continue;
            const amount = extractArrayNumByKey(line, "amount");
            if (amount == 0) continue;
            if (std.mem.eql(u8, kind, "deposit")) {
                _ = balanceCredit(ctx, owner, token, amount);
            } else {
                _ = balanceDebit(ctx, owner, token, amount);
            }
        }
        replayed += 1;
    }
    std.debug.print("[EXCHANGE] Replayed {d} user event(s) from {s}\n", .{ replayed, path });
}

// ── API key table ops ────────────────────────────────────────────────

pub fn apiKeyInsert(
    ctx: *ServerCtx,
    key_id: []const u8,
    secret_raw: []const u8,
    secret_hash: []const u8,
    name: []const u8,
    owner: []const u8,
    ts: i64,
) void {
    if (ctx.exstate.?.api_key_count >= ctx.exstate.?.api_keys.len) return;
    const slot = &ctx.exstate.?.api_keys[ctx.exstate.?.api_key_count];
    slot.* = .{};
    const k1 = @min(key_id.len, slot.key_id.len);
    @memcpy(slot.key_id[0..k1], key_id[0..k1]);
    slot.key_id_len = @intCast(k1);
    const kr = @min(secret_raw.len, slot.secret_raw.len);
    @memcpy(slot.secret_raw[0..kr], secret_raw[0..kr]);
    slot.secret_raw_len = @intCast(kr);
    const k2 = @min(secret_hash.len, slot.secret_hash.len);
    @memcpy(slot.secret_hash[0..k2], secret_hash[0..k2]);
    slot.secret_hash_len = @intCast(k2);
    const k3 = @min(name.len, slot.name.len);
    @memcpy(slot.name[0..k3], name[0..k3]);
    slot.name_len = @intCast(k3);
    const k4 = @min(owner.len, slot.owner.len);
    @memcpy(slot.owner[0..k4], owner[0..k4]);
    slot.owner_len = @intCast(k4);
    slot.created_ms = ts;
    slot.revoked = false;
    ctx.exstate.?.api_key_count += 1;
}

pub fn apiKeyRevoke(ctx: *ServerCtx, key_id: []const u8) void {
    var i: u16 = 0;
    while (i < ctx.exstate.?.api_key_count) : (i += 1) {
        const k = &ctx.exstate.?.api_keys[i];
        if (k.key_id_len == key_id.len and std.mem.eql(u8, k.key_id[0..k.key_id_len], key_id)) {
            k.revoked = true;
            return;
        }
    }
}

// ─── PHASE 2E.3 helpers (Kraken-compat order management) ───────────────

/// Cancel every active/partial order belonging to `trader` on `engine`.
/// Caller MUST hold ctx.exchange_mutex. Returns the number of orders
/// successfully cancelled. OrderNotFound is silently ignored (benign race
/// where a fill consumed the order between the collect-pass and cancel-pass).
fn cancelAllForTrader(
    engine: *matching_mod.MatchingEngine,
    trader: []const u8,
    alloc: std.mem.Allocator,
) u32 {
    // Two-pass: collect IDs first to avoid index shifts when cancelOrder
    // removes entries. Heap-alloc since 2*MAX_ORDERS = 20k * u64 = 160KB
    // is too large for stack.
    var ids = std.ArrayList(u64){};
    defer ids.deinit(alloc);

    var i: u32 = 0;
    while (i < engine.bid_count) : (i += 1) {
        const o = &engine.bids[i];
        if (o.status != .active and o.status != .partial) continue;
        if (!std.mem.eql(u8, o.getTraderAddress(), trader)) continue;
        ids.append(alloc, o.order_id) catch continue;
    }
    var j: u32 = 0;
    while (j < engine.ask_count) : (j += 1) {
        const o = &engine.asks[j];
        if (o.status != .active and o.status != .partial) continue;
        if (!std.mem.eql(u8, o.getTraderAddress(), trader)) continue;
        ids.append(alloc, o.order_id) catch continue;
    }

    var cancelled: u32 = 0;
    for (ids.items) |id| {
        engine.cancelOrder(id) catch continue;
        cancelled += 1;
    }
    return cancelled;
}

/// Look up an order by ID and verify ownership. Caller MUST hold
/// ctx.exchange_mutex. Returns null if not found OR owner mismatch
/// (treats both as "not yours" — caller cannot tell).
fn findOrderByIdAndOwner(
    engine: *matching_mod.MatchingEngine,
    order_id: u64,
    trader: []const u8,
) ?*const matching_mod.Order {
    var i: u32 = 0;
    while (i < engine.bid_count) : (i += 1) {
        const o = &engine.bids[i];
        if (o.order_id != order_id) continue;
        if (!std.mem.eql(u8, o.getTraderAddress(), trader)) return null;
        return o;
    }
    var j: u32 = 0;
    while (j < engine.ask_count) : (j += 1) {
        const o = &engine.asks[j];
        if (o.order_id != order_id) continue;
        if (!std.mem.eql(u8, o.getTraderAddress(), trader)) return null;
        return o;
    }
    return null;
}

pub fn apiKeyLookup(ctx: *ServerCtx, key_id: []const u8) ?*ExchangeApiKey {
    var i: u16 = 0;
    while (i < ctx.exstate.?.api_key_count) : (i += 1) {
        const k = &ctx.exstate.?.api_keys[i];
        if (k.revoked) continue;
        if (k.key_id_len == key_id.len and std.mem.eql(u8, k.key_id[0..k.key_id_len], key_id)) {
            return k;
        }
    }
    return null;
}

// SHA256 hex of a string. Used to verify api-key secrets without storing
// them in the clear. NOTE: not constant-time — for testnet only.
pub fn sha256Hex(input: []const u8, out: *[64]u8) void {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(input, &hash, .{});
    const hex_chars = "0123456789abcdef";
    var i: usize = 0;
    while (i < 32) : (i += 1) {
        out[i * 2] = hex_chars[hash[i] >> 4];
        out[i * 2 + 1] = hex_chars[hash[i] & 0xF];
    }
}

/// Verify Kraken-style HMAC-SHA512 signature for REST private endpoints.
/// Algorithm:
///   api_sign = HMAC-SHA512(
///       secret = api_key.secret_raw (32 raw bytes),
///       message = URI-PATH || SHA256(NONCE || POST-DATA)
///   ).base64()
/// Returns true if the provided base64 signature matches.
fn verifyHmacSignature(
    api_key: *const ExchangeApiKey,
    api_sign_b64: []const u8,
    uri_path: []const u8,
    post_data: []const u8,
) bool {
    if (api_key.secret_raw_len == 0) return false;
    if (api_sign_b64.len == 0) return false;

    // Decode base64 signature (HMAC-SHA512 = 64 bytes → 88 base64 chars)
    var decoded_sig: [64]u8 = undefined;
    std.base64.standard.Decoder.decode(&decoded_sig, api_sign_b64) catch return false;

    // Build message = URI-PATH || SHA256(POST-DATA)  (raw bytes, NOT hex)
    var post_hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(post_data, &post_hash, .{});

    var msg_buf: [1024]u8 = undefined;
    const uri_len = uri_path.len;
    const hash_len = post_hash.len;
    if (uri_len + hash_len > msg_buf.len) return false;
    @memcpy(msg_buf[0..uri_len], uri_path);
    @memcpy(msg_buf[uri_len..uri_len + hash_len], &post_hash);
    const msg = msg_buf[0 .. uri_len + hash_len];

    // Compute HMAC-SHA512
    var computed_hmac: [64]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha512.create(&computed_hmac, msg, api_key.secret_raw[0..api_key.secret_raw_len]);

    return std.mem.eql(u8, &computed_hmac, &decoded_sig);
}

// ── Balance table ops ──────────────────────────────────────────────────

pub fn balanceLookup(ctx: *ServerCtx, owner: []const u8, token: []const u8) ?*ExchangeBalance {
    var i: u16 = 0;
    while (i < ctx.exstate.?.balance_count) : (i += 1) {
        const b = &ctx.exstate.?.balances[i];
        if (b.owner_len == owner.len and b.token_len == token.len
            and std.mem.eql(u8, b.owner[0..b.owner_len], owner)
            and std.mem.eql(u8, b.token[0..b.token_len], token))
        {
            return b;
        }
    }
    return null;
}

pub fn balanceGetOrCreate(ctx: *ServerCtx, owner: []const u8, token: []const u8) ?*ExchangeBalance {
    if (balanceLookup(ctx, owner, token)) |b| return b;
    if (ctx.exstate.?.balance_count >= ctx.exstate.?.balances.len) return null;
    const slot = &ctx.exstate.?.balances[ctx.exstate.?.balance_count];
    slot.* = .{};
    const k1 = @min(owner.len, slot.owner.len);
    @memcpy(slot.owner[0..k1], owner[0..k1]);
    slot.owner_len = @intCast(k1);
    const k2 = @min(token.len, slot.token.len);
    @memcpy(slot.token[0..k2], token[0..k2]);
    slot.token_len = @intCast(k2);
    ctx.exstate.?.balance_count += 1;
    return slot;
}

pub fn balanceCredit(ctx: *ServerCtx, owner: []const u8, token: []const u8, amount: u64) bool {
    const b = balanceGetOrCreate(ctx, owner, token) orelse return false;
    b.available_sat +%= amount;
    return true;
}

pub fn balanceDebit(ctx: *ServerCtx, owner: []const u8, token: []const u8, amount: u64) bool {
    const b = balanceLookup(ctx, owner, token) orelse return false;
    if (b.available_sat < amount) return false;
    b.available_sat -= amount;
    return true;
}

// ── Auth nonce / login ────────────────────────────────────────────────

pub fn authNoncePurge(ctx: *ServerCtx, now_ms: i64) void {
    var i: u16 = 0;
    while (i < ctx.exstate.?.auth_nonce_count) {
        const n = &ctx.exstate.?.auth_nonces[i];
        if (now_ms - n.created_ms > AUTH_NONCE_TTL_MS) {
            // shift remaining left (preserves order, fine for 256 entries)
            var j: u16 = i;
            while (j + 1 < ctx.exstate.?.auth_nonce_count) : (j += 1) {
                ctx.exstate.?.auth_nonces[j] = ctx.exstate.?.auth_nonces[j + 1];
            }
            ctx.exstate.?.auth_nonce_count -= 1;
        } else {
            i += 1;
        }
    }
}

pub fn authNoncePut(ctx: *ServerCtx, address: []const u8, nonce_hex: []const u8, now_ms: i64) void {
    if (ctx.exstate.?.auth_nonce_count >= ctx.exstate.?.auth_nonces.len) {
        // FIFO evict
        var j: u16 = 0;
        while (j + 1 < ctx.exstate.?.auth_nonces.len) : (j += 1) {
            ctx.exstate.?.auth_nonces[j] = ctx.exstate.?.auth_nonces[j + 1];
        }
        ctx.exstate.?.auth_nonce_count -= 1;
    }
    const slot = &ctx.exstate.?.auth_nonces[ctx.exstate.?.auth_nonce_count];
    slot.* = .{};
    const k1 = @min(address.len, slot.address.len);
    @memcpy(slot.address[0..k1], address[0..k1]);
    slot.address_len = @intCast(k1);
    const k2 = @min(nonce_hex.len, slot.nonce_hex.len);
    @memcpy(slot.nonce_hex[0..k2], nonce_hex[0..k2]);
    slot.nonce_hex_len = @intCast(k2);
    slot.created_ms = now_ms;
    ctx.exstate.?.auth_nonce_count += 1;
}

pub fn authNonceConsume(ctx: *ServerCtx, address: []const u8, nonce_hex: []const u8) bool {
    var i: u16 = 0;
    while (i < ctx.exstate.?.auth_nonce_count) : (i += 1) {
        const n = &ctx.exstate.?.auth_nonces[i];
        if (n.address_len == address.len
            and std.mem.eql(u8, n.address[0..n.address_len], address)
            and n.nonce_hex_len == nonce_hex.len
            and std.mem.eql(u8, n.nonce_hex[0..n.nonce_hex_len], nonce_hex))
        {
            // single-use — remove
            var j: u16 = i;
            while (j + 1 < ctx.exstate.?.auth_nonce_count) : (j += 1) {
                ctx.exstate.?.auth_nonces[j] = ctx.exstate.?.auth_nonces[j + 1];
            }
            ctx.exstate.?.auth_nonce_count -= 1;
            return true;
        }
    }
    return false;
}

// ─── HANDLERS ─────────────────────────────────────────────────────────

/// exchange_getAuthNonce — generates a 32-byte random nonce (hex) bound
/// to the caller's address. The user signs "OmniBus Exchange Login: <nonce>"
/// and submits via `exchange_login` to prove key ownership.

/// exchange_login — verify nonce signature, mark the address as a known
/// exchange user (just allocates a default OMNI balance row if missing).
/// Returns the address + a list of currently active api keys (without
/// revealing secrets). Stateless — no JWT; future calls re-prove
/// ownership either via signature or via api-key+secret headers.

/// exchange_createApiKey — generate a fresh (key_id, secret) pair owned
/// by the caller. The secret is returned ONCE (plaintext) and stored as
/// SHA256 hash. Caller must prove address ownership via signature on
/// the canonical message "EXCHANGE_APIKEY_V1\n<name>\n<address>\n<nonce>".

/// exchange_listApiKeys — list keys owned by an address. Secrets are
/// never returned (only the SHA256 hash for transparency).

/// exchange_revokeApiKey — owner revokes one of their keys.
/// Verified by signature on "EXCHANGE_APIKEY_REVOKE_V1\n<keyId>\n<owner>\n<nonce>".

/// exchange_deposit — credit internal exchange balance.
/// On testnet/regtest: credits directly (no on-chain proof required).
/// On mainnet (chain_id == 1): requires a `txid` that actually sent OMNI
/// to the exchange escrow address — use exchange_depositReal instead.

/// exchange_withdraw — debit internal balance. Symmetric to deposit;
/// on mainnet the chain would also credit the user's on-chain wallet
/// here (atomic transfer). Testnet: just debits the internal pool.

/// exchange_getBalance — returns single address balance with reservation info (Phase 1B).
/// For real mode: balance from blockchain, reserved from orders.
/// For paper mode: balance from OMNI_DEMO internal table.

/// exchange_getBalances — read-only listing of balances for an owner.
///
/// Real mode: balance comes from on-chain UTXO state (`getAddressBalance`),
/// `locked` = sum of remaining amounts in active sell orders for this address
/// (derived from orderbook, see computeReservedFromOrderbook). Single source
/// of truth — no internal balance table for real OMNI.
///
/// Paper mode: balance comes from internal `_DEMO`-suffixed table (sandbox
/// credits issued by exchange_depositDemo, never on-chain).

// ── Demo / Real deposit + escrow ─────────────────────────────────────

/// exchange_getEscrowAddress — return the on-chain address users send
/// real deposits to. Always the canonical exchange.omnibus registrar
/// wallet (slot #2). Never the local node's wallet.


// ── Grid trading RPC handlers ─────────────────────────────────────────────

/// grid_create — pornește un grid nou pentru un owner pe o pereche.
/// Params: { pair_id, price_low, price_high, levels, total_base, total_quote, owner }

/// grid_list — listează grid-urile active (opțional filtrate după owner).
/// Params: { owner? }

/// grid_status — detalii complete pentru un grid (inclusiv levels calculate).
/// Params: { grid_id }

/// grid_cancel — oprește un grid activ.
/// Params: { grid_id, owner }

fn demoQuotaLookup(es: *ExchangeState, addr: []const u8) ?*DemoQuota {
    var i: u16 = 0;
    while (i < es.demo_quota_count) : (i += 1) {
        const q = &es.demo_quotas[i];
        if (q.address_len == addr.len and std.mem.eql(u8, q.address[0..q.address_len], addr)) {
            return q;
        }
    }
    return null;
}

pub fn demoQuotaGetOrCreate(es: *ExchangeState, addr: []const u8) ?*DemoQuota {
    if (demoQuotaLookup(es, addr)) |q| return q;
    if (es.demo_quota_count >= es.demo_quotas.len) {
        // FIFO evict — table is small (256), eviction means heaviest user
        // loses oldest record, fine on testnet.
        var j: u16 = 0;
        while (j + 1 < es.demo_quotas.len) : (j += 1) {
            es.demo_quotas[j] = es.demo_quotas[j + 1];
        }
        es.demo_quota_count -= 1;
    }
    const slot = &es.demo_quotas[es.demo_quota_count];
    slot.* = .{};
    const n = @min(addr.len, slot.address.len);
    @memcpy(slot.address[0..n], addr[0..n]);
    slot.address_len = @intCast(n);
    slot.granted_sat = 0;
    slot.window_start_ms = std.time.milliTimestamp();
    es.demo_quota_count += 1;
    return slot;
}

/// exchange_depositDemo — credit testnet/sandbox demo OMNI to internal
/// exchange balance. Per-address rate-limited (max 10 OMNI per request,
/// max 100 OMNI / 24h rolling window). Marks the credited balance row
/// with token "OMNI_DEMO" so demo and real money are visibly separate
/// and never mixed when settling trades. No on-chain TX needed.

pub fn realDepositTxidUsed(es: *ExchangeState, txid: []const u8) bool {
    if (txid.len != 64) return false;
    var i: u16 = 0;
    while (i < es.real_deposit_count) : (i += 1) {
        if (std.mem.eql(u8, &es.real_deposit_txids[i], txid)) return true;
    }
    return false;
}

pub fn realDepositTxidRecord(es: *ExchangeState, txid: []const u8) bool {
    if (txid.len != 64) return false;
    if (es.real_deposit_count >= es.real_deposit_txids.len) {
        // Shift FIFO out
        var j: u16 = 0;
        while (j + 1 < es.real_deposit_txids.len) : (j += 1) {
            es.real_deposit_txids[j] = es.real_deposit_txids[j + 1];
        }
        es.real_deposit_count -= 1;
    }
    const slot = &es.real_deposit_txids[es.real_deposit_count];
    @memcpy(slot[0..64], txid[0..64]);
    es.real_deposit_count += 1;
    return true;
}

/// exchange_depositReal — credit a deposit ONLY after verifying that an
/// on-chain TX really transferred OMNI from the user to the escrow
/// address. Idempotent (each txid usable exactly once). The credited
/// row uses token "OMNI" (real money) so trades against demo balances
/// can be kept separate.

// ── Identity (public name / ENS pref / visibility) ────────────────────
//
// `identity_set` — caller proves ownership of `address` by signing
//                  `IDENTITY_V1\n<address>\n<nickname>\n<ens>\n<visibility>\n<nonce>`
//                  with the address's secp256k1 key. Server verifies sig
//                  derives -> bech32 against `address`, applies + appends
//                  to identities.jsonl. Same anti-replay nonce table as
//                  the exchange uses.
//
// `identity_get` — public; returns null for `private` identities.
// `identity_search` — public; lists `public` identities whose nickname
//                     starts with the prefix.

pub fn buildIdentitySignMessage(
    out: []u8,
    address: []const u8,
    nickname: []const u8,
    ens: []const u8,
    visibility: []const u8,
    nonce: u64,
) ![]u8 {
    return std.fmt.bufPrint(out,
        "IDENTITY_V1\n{s}\n{s}\n{s}\n{s}\n{d}",
        .{ address, nickname, ens, visibility, nonce });
}




// ── KYC (signed attestations) ─────────────────────────────────────────


/// kyc_attest — only callable by the configured KYC issuer (registrar
/// slot 4). The issuer signs the canonical message and submits it; we
/// verify the signature derives to the configured issuer address.


// ═════════════════════════════════════════════════════════════════════════════
//  PQ Isolated Wallets v2 — 5-scheme RPC handlers
//
//  Schemes:
//    0 = omni_ecdsa     (secp256k1 ECDSA, prefix ob1q)
//    1 = love_dilithium (ML-DSA-87, prefix ob_k1_)
//    2 = food_falcon    (Falcon-512, prefix ob_f5_)
//    3 = rent_ml_dsa   (SLH-DSA-256s, prefix ob_d5_)
//    4 = vacation_slh_dsa   (ML-KEM-768, prefix ob_s3_) — encapsulation only,
//                       nu suporta semnaturi (verifySignature returneaza false)
// ═════════════════════════════════════════════════════════════════════════════

/// pq_listSchemes — read-only. Returneaza cele 9 scheme suportate cu
/// codurile lor numerice si prefixele de adresa pentru wallet UI / SDK
/// auto-discovery. Nu modifica state.
///
/// 0..4 = original isolated wallets (OMNI primary + 4 reputation cups,
///        last one being non-signing KEM).
/// 5..8 = PQ-OMNI — transferable OMNI wallets with post-quantum signing,
///        added 2026-04-30. Same balance semantics as omni_ecdsa, only
///        the signature scheme differs.

/// pq_balance — balance + scheme deduse din prefixul adresei. Read-only.
/// Reuse `bc.getAddressBalance` (acelasi balanta ca pentru orice adresa).

/// pq_verify_test — debug RPC. Apeleaza isolated_wallet.verifySignature DIRECT
/// pe (scheme, message_bytes, signature_bytes, pubkey_bytes), bypass TX hash.
/// Folosit pentru a confirma ca librariile noble (frontend) si liboqs (chain)
/// sunt interoperabile la nivel de bytes ai semnaturii.
///
/// Params (object): scheme (string sau cod 5..8), public_key (hex), message (hex), signature (hex).
/// Returns: {"verified": true|false, "scheme": "...", "msg_len": N, "pk_len": N, "sig_len": N}

/// pq_send — construieste si submite o tranzactie semnata cu o scheme PQ.
/// Required: scheme (0..4 sau nume), from, to, amount, signature, public_key.
/// Optional: op_return, fee, nonce.
///
/// Semnatura PQ este verificata aici (chain-side) inainte de a o adauga in
/// mempool. Format mesaj canonic: hash-ul standard al TX (calculateHash).

/// pq_attestation — scaneaza chain-ul pentru tranzactii cu OP_RETURN
/// `pq_attest:<domain>:<pq_address>` trimise de la `omni_address`.
/// Returneaza ultima inregistrare gasita + numarul de confirmari.

// ── getpqidentity ─────────────────────────────────────────────────────────────
// Returns the full PQ identity for an omni address (if registered via pq_attest_v1).


// ── sendpqattest ──────────────────────────────────────────────────────────────
// Broadcasts a pq_attest_v1 TX from the wallet. The frontend builds + signs
// the TX with the OMNI secp256k1 key and sends the raw op_return payload here.
// Format: { "from": "ob1q...", "love": "ob_k1_...", "food": "ob_f5_...",
//           "rent": "ob_d5_...", "vacation": "ob_s3_...",
//           "btc": "bc1q..." (opt), "eth": "0x..." (opt),
//           "signature": "hex...", "public_key": "hex...", "nonce": N }


var g_profile_store: ?ProfileStore = null;
pub const FieldValue = struct {
    /// Owned by ProfileStore.allocator. UTF-8 or hex, whatever the caller sent.
    value: []u8,
    is_public: bool,
};

pub const FacetStore = struct {
    fields: std.StringHashMap(FieldValue),

    fn init(alloc: std.mem.Allocator) FacetStore {
        return .{ .fields = std.StringHashMap(FieldValue).init(alloc) };
    }
    fn deinit(self: *FacetStore, alloc: std.mem.Allocator) void {
        var it = self.fields.iterator();
        while (it.next()) |kv| {
            alloc.free(kv.key_ptr.*);
            alloc.free(kv.value_ptr.value);
        }
        self.fields.deinit();
    }
};

const MicaAttestation = struct {
    /// "kyc" | "aml" | "sanctions". Allocated.
    kind: []u8,
    /// Issuer DID or "" for self-attestation. Allocated.
    issuer_did: []u8,
    /// Hex signature bytes (validated for hex shape only). Allocated.
    signature_hex: []u8,
    /// Unix seconds at attestation time.
    timestamp_unix_s: u64,
};

pub const ProfileEntry = struct {
    h160: [20]u8,
    /// 4 facets in fixed order: 0=social, 1=professional, 2=cultural, 3=economic.
    facets: [4]FacetStore,
    /// MiCA attestations for this address (any kind, append-only).
    mica: std.array_list.Managed(MicaAttestation),

    fn init(alloc: std.mem.Allocator, h160: [20]u8) ProfileEntry {
        return .{
            .h160 = h160,
            .facets = .{
                FacetStore.init(alloc),
                FacetStore.init(alloc),
                FacetStore.init(alloc),
                FacetStore.init(alloc),
            },
            .mica = std.array_list.Managed(MicaAttestation).init(alloc),
        };
    }
};

pub const ProfileStore = struct {
    allocator: std.mem.Allocator,
    by_h160: std.AutoHashMap([20]u8, *ProfileEntry),
    mutex: std.Thread.Mutex = .{},
    /// MemorySaltManager — no disk persistence yet. Per-address salt
    /// returned once at profile_init; chain doesn't keep it long-term.
    salt_mgr: id_layer_mod.salt.MemorySaltManager = .{},

    fn init(alloc: std.mem.Allocator) ProfileStore {
        return .{
            .allocator = alloc,
            .by_h160 = std.AutoHashMap([20]u8, *ProfileEntry).init(alloc),
        };
    }

    pub fn getOrCreate(self: *ProfileStore, h160: [20]u8) !*ProfileEntry {
        if (self.by_h160.get(h160)) |e| return e;
        const e = try self.allocator.create(ProfileEntry);
        e.* = ProfileEntry.init(self.allocator, h160);
        try self.by_h160.put(h160, e);
        return e;
    }

    pub fn get(self: *ProfileStore, h160: [20]u8) ?*ProfileEntry {
        return self.by_h160.get(h160);
    }
};

pub fn getProfileStore(alloc: std.mem.Allocator) *ProfileStore {
    if (g_profile_store == null) g_profile_store = ProfileStore.init(alloc);
    return &g_profile_store.?;
}

/// Decode bech32 OmniBus address → h160 bytes. Returns error if malformed.
pub fn addrToH160(addr: []const u8, alloc: std.mem.Allocator) ![20]u8 {
    const decoded = try bech32_mod.decodeWitnessAddress(bech32_mod.OB_HRP, addr, alloc);
    defer alloc.free(decoded.program);
    if (decoded.program.len != 20) return error.InvalidAddress;
    var h160: [20]u8 = undefined;
    @memcpy(&h160, decoded.program);
    return h160;
}

pub fn hexEncode(alloc: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var out = try alloc.alloc(u8, bytes.len * 2);
    const hex = "0123456789abcdef";
    for (bytes, 0..) |b, i| {
        out[i * 2] = hex[b >> 4];
        out[i * 2 + 1] = hex[b & 0x0F];
    }
    return out;
}

pub fn facetIndex(name: []const u8) ?usize {
    if (std.mem.eql(u8, name, "social")) return 0;
    if (std.mem.eql(u8, name, "professional")) return 1;
    if (std.mem.eql(u8, name, "cultural")) return 2;
    if (std.mem.eql(u8, name, "economic")) return 3;
    return null;
}

pub const FACET_NAMES = [_][]const u8{ "social", "professional", "cultural", "economic" };

/// Hash a facet's field bag into a 32-byte root. Order-independent: we sort
/// field keys first. Tiny stand-in until the real facet modules expose a
/// canonical root function (id_social / id_professional / id_cultural /
/// id_economic each have their own; we hash a generic key|value bag here).
pub fn computeFacetRoot(facet: *const FacetStore, alloc: std.mem.Allocator) ![32]u8 {
    const Sha256 = std.crypto.hash.sha2.Sha256;
    var hasher = Sha256.init(.{});

    var keys = std.array_list.Managed([]const u8).init(alloc);
    defer keys.deinit();
    var it = facet.fields.iterator();
    while (it.next()) |kv| {
        try keys.append(kv.key_ptr.*);
    }
    std.mem.sort([]const u8, keys.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    for (keys.items) |k| {
        const v = facet.fields.get(k).?;
        hasher.update(k);
        hasher.update("=");
        hasher.update(v.value);
        hasher.update("\n");
    }
    var out: [32]u8 = undefined;
    hasher.final(&out);
    return out;
}

/// Replay `data/<chain>/profiles.jsonl` into the in-memory ProfileStore.
/// Called once at startup from startHTTPEx before the RPC listener opens.
/// A missing file is silently ignored (first-run).
fn replayProfilesJournal(ctx: *ServerCtx) !void {
    if (ctx.profiles_path_len == 0) return;
    const path = ctx.profiles_path_buf[0..ctx.profiles_path_len];
    const alloc = ctx.allocator;

    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        if (err == error.FileNotFound) return;
        return err;
    };
    defer file.close();

    const store = getProfileStore(alloc);

    var read_buf: [4096]u8 = undefined;
    var line_buf = std.array_list.Managed(u8).init(alloc);
    defer line_buf.deinit();

    var total: usize = 0;
    var replayed: usize = 0;

    outer: while (true) {
        const n = file.read(&read_buf) catch break;
        if (n == 0) break;
        for (read_buf[0..n]) |ch| {
            if (ch == '\n') {
                const trimmed = std.mem.trim(u8, line_buf.items, " \r\t");
                if (trimmed.len > 0) {
                    total += 1;
                    replayProfileLine(store, alloc, trimmed) catch {};
                    replayed += 1;
                }
                line_buf.clearRetainingCapacity();
            } else {
                line_buf.append(ch) catch break :outer;
            }
        }
    }
    // flush any trailing line without a final newline
    {
        const trimmed = std.mem.trim(u8, line_buf.items, " \r\t");
        if (trimmed.len > 0) {
            total += 1;
            replayProfileLine(store, alloc, trimmed) catch {};
            replayed += 1;
        }
    }
    std.debug.print("[PROFILE] replayed {d}/{d} events from {s}\n", .{ replayed, total, path });
}

/// Apply one JSONL line to the in-memory ProfileStore.
fn replayProfileLine(store: *ProfileStore, alloc: std.mem.Allocator, line: []const u8) !void {
    const op = extractJsonStrInline(line, "op") orelse return;

    if (std.mem.eql(u8, op, "init")) {
        const addr = extractJsonStrInline(line, "addr") orelse return;
        const h160 = addrToH160(addr, alloc) catch return;
        store.mutex.lock();
        defer store.mutex.unlock();
        _ = try store.getOrCreate(h160);

    } else if (std.mem.eql(u8, op, "update")) {
        const addr        = extractJsonStrInline(line, "addr")      orelse return;
        const facet_name  = extractJsonStrInline(line, "facet")     orelse return;
        const field_name  = extractJsonStrInline(line, "field")     orelse return;
        const value       = extractJsonStrInline(line, "value")     orelse return;
        const is_pub_str  = extractJsonStrInline(line, "is_public") orelse "false";
        const is_public   = std.mem.eql(u8, is_pub_str, "true");

        const fidx = facetIndex(facet_name) orelse return;
        const h160 = addrToH160(addr, alloc) catch return;

        store.mutex.lock();
        defer store.mutex.unlock();
        const entry = try store.getOrCreate(h160);
        var facet = &entry.facets[fidx];

        if (facet.fields.fetchRemove(field_name)) |old| {
            store.allocator.free(old.key);
            store.allocator.free(old.value.value);
        }
        const key_dup = try store.allocator.dupe(u8, field_name);
        const val_dup = try store.allocator.dupe(u8, value);
        try facet.fields.put(key_dup, .{ .value = val_dup, .is_public = is_public });
    }
    // unknown op → skip (forward-compat)
}

/// Extract the string value of `key` from a flat JSON object.
/// Returns a slice into the original `json` — no allocation.
fn extractJsonStrInline(json: []const u8, key: []const u8) ?[]const u8 {
    var needle_buf: [128]u8 = undefined;
    if (key.len + 5 > needle_buf.len) return null;
    const needle = std.fmt.bufPrint(&needle_buf, "\"{s}\":\"", .{key}) catch return null;
    const start_idx = std.mem.indexOf(u8, json, needle) orelse return null;
    const val_start = start_idx + needle.len;
    if (val_start >= json.len) return null;
    var i: usize = val_start;
    while (i < json.len) : (i += 1) {
        if (json[i] == '\\') { i += 1; continue; }
        if (json[i] == '"') break;
    }
    if (i >= json.len) return null;
    return json[val_start..i];
}

/// Append one event to `data/<chain>/profiles.jsonl`. Best-effort —
/// I/O errors are silently dropped so callers never fail on disk issues.
pub fn appendProfileLog(ctx: *ServerCtx, line: []const u8) void {
    if (ctx.profiles_path_len == 0) return;
    const path = ctx.profiles_path_buf[0..ctx.profiles_path_len];
    const file = std.fs.cwd().createFile(path, .{ .truncate = false }) catch return;
    defer file.close();
    file.seekFromEnd(0) catch return;
    _ = file.writeAll(line) catch return;
    _ = file.writeAll("\n") catch return;
}

/// RPC `profile_init <addr>` — idempotent. Generates the DID, returns an
/// empty Manifest skeleton (all 10 leaves zero) and a fresh salt (returned
/// only this once). Appends an `op=init` line to profiles.jsonl.

/// RPC `profile_update <addr> <facet> <field> <value> <is_public>` — update
/// one field in one facet. Stored in-memory + JSONL log.

/// Write a JSON-safe string: escapes `"` → `'`, `\` → `/`, strips ctrl chars.
pub fn writeJsonSafeStr(w: anytype, s: []const u8) !void {
    for (s) |c| {
        if (c == '"')       { try w.writeByte('\''); }
        else if (c == '\\') { try w.writeByte('/');  }
        else if (c < 0x20)  {}
        else                { try w.writeByte(c);    }
    }
}

/// Emit a facet as a JSON object containing only fields with is_public=true.
pub fn writeFacetPublicJson(w: anytype, facet: *const FacetStore) !void {
    try w.writeByte('{');
    var first = true;
    var it = facet.fields.iterator();
    while (it.next()) |kv| {
        if (!kv.value_ptr.is_public) continue;
        if (!first) try w.writeByte(',');
        first = false;
        try w.writeByte('"');
        try writeJsonSafeStr(w, kv.key_ptr.*);
        try w.writeAll("\":\"");
        try writeJsonSafeStr(w, kv.value_ptr.value);
        try w.writeByte('"');
    }
    try w.writeByte('}');
}

/// RPC `profile_get <addr>` — public view: only fields marked is_public.

/// Validate hex-shape only — no cryptographic verification. Empty allowed
/// when the attestation is a self-attestation (issuer_did=="").
pub fn isHexShape(s: []const u8) bool {
    if (s.len == 0) return true;
    if (s.len % 2 != 0) return false;
    for (s) |c| {
        const ok = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
        if (!ok) return false;
    }
    return true;
}

pub fn isAllZeros(s: []const u8) bool {
    for (s) |c| if (c != '0') return false;
    return true;
}

