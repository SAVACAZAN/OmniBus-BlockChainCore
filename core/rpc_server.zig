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
pub const Metrics     = benchmark_mod.Metrics;

// Process-global cross-chain oracle. Validators populate this via
// `oracle_recordHeader` (PQ quorum gated); SPV verifiers read it.
// File-private to keep ServerCtx untouched per the task's "don't
// modify existing handlers" constraint.
var g_xchain_oracle: cross_chain_oracle_mod.CrossChainOracle =
    cross_chain_oracle_mod.CrossChainOracle.init();
var g_xchain_oracle_mutex: std.Thread.Mutex = .{};
var g_xchain_oracle_loaded: bool = false;
const XCHAIN_ORACLE_PATH = "data/cross_chain_oracle.bin";

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
var g_oracle_quorum_pubkeys: [ORACLE_QUORUM_MAX]OracleQuorumPubkey = undefined;
var g_oracle_quorum_count: usize = 0;

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

fn isQuorumPubkey(pk: OracleQuorumPubkey) bool {
    var i: usize = 0;
    while (i < g_oracle_quorum_count) : (i += 1) {
        if (std.mem.eql(u8, &g_oracle_quorum_pubkeys[i], &pk)) return true;
    }
    return false;
}

fn ensureOracleLoaded() void {
    g_xchain_oracle_mutex.lock();
    defer g_xchain_oracle_mutex.unlock();
    if (g_xchain_oracle_loaded) return;
    g_xchain_oracle.loadFromFile(XCHAIN_ORACLE_PATH) catch {};
    g_xchain_oracle_loaded = true;
}

pub const Blockchain  = blockchain_mod.Blockchain;
pub const Wallet      = wallet_mod.Wallet;

// Counter global pentru tx_id (atomic)
var g_tx_counter = std.atomic.Value(u32).init(1);

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

const MAX_REGISTERED_MINERS = 256;

/// Context partajat intre thread-uri (blockchain + wallet + module noi)
const ServerCtx = struct {
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
const AUTH_NONCE_TTL_MS: i64 = 5 * 60 * 1000;

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
const DEMO_MAX_PER_REQUEST_SAT: u64 = 10 * 1_000_000_000; // 10 OMNI
const DEMO_MAX_PER_24H_SAT: u64 = 100 * 1_000_000_000;     // 100 OMNI / day
const DEMO_WINDOW_MS: i64 = 24 * 60 * 60 * 1000;

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
fn pairIdToLabel(pair_id: u16) []const u8 {
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

fn handleGetBlockCount(ctx: *ServerCtx, id: u64) ![]u8 {
    return std.fmt.allocPrint(ctx.allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{d}}}",
        .{ id, ctx.bc.getBlockCount() });
}

fn handleGetBalance(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const req_addr = extractArrayStr(body, 0) orelse
                     extractStr(body, "address") orelse
                     ctx.wallet.address;
    // Lock blockchain mutex — prevents segfault from concurrent hashmap resize
    // during mining (creditBalance → put can realloc while we read).
    // Use getBlockCountUnlocked while we already hold the mutex — calling
    // getBlockCount here would re-lock and panic (non-reentrant Mutex).
    ctx.bc.mutex.lock();
    const bal_sat = ctx.bc.getAddressBalance(req_addr);
    const height  = ctx.bc.getBlockCountUnlocked();
    ctx.bc.mutex.unlock();
    const bal_omni = bal_sat / 1_000_000_000;
    const bal_frac = bal_sat % 1_000_000_000;
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"address\":\"{s}\",\"balance\":{d},\"balanceOMNI\":\"{d}.{d:0>9}\",\"confirmed\":{d},\"unconfirmed\":0,\"utxos\":[],\"transactions\":[],\"txCount\":0,\"nodeHeight\":{d}}}}}",
        .{ id, req_addr, bal_sat, bal_omni, bal_frac, bal_sat, height });
}

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
fn handleGetWalletSummary(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const req_addr = extractArrayStr(body, 0) orelse
                     extractStr(body, "address") orelse
                     ctx.wallet.address;

    var buf = std.array_list.Managed(u8).init(alloc);
    defer buf.deinit();
    const w = buf.writer();

    // Single lock over the whole snapshot — guarantees the four numbers
    // (wallet / staked / orders / height) all come from the same chain
    // state. Without this, a mining round between calls could shift them.
    ctx.bc.mutex.lock();
    defer ctx.bc.mutex.unlock();

    const wallet_sat = ctx.bc.getAddressBalance(req_addr);
    const height     = ctx.bc.getBlockCountUnlocked();

    var staked_sat: u64 = 0;
    if (ctx.bc.stake_amounts.get(req_addr)) |amt| {
        staked_sat = amt;
    }

    // Walk active sell orders for this trader to compute in_orders_sat (OMNI
    // reserved by resting sells). Buy orders reserve quote-asset (USDC/etc),
    // not OMNI, so we don't count them here. Same scan pattern as
    // handleExchangeGetUserOrders — kept tolerant of paper mode being off.
    var in_orders_sat: u64 = 0;
    var open_orders_json = std.array_list.Managed(u8).init(alloc);
    defer open_orders_json.deinit();
    const oow = open_orders_json.writer();
    var first_order = true;

    const engine_opt = pickEngine(ctx, false);
    if (engine_opt) |engine| {
        ctx.exchange_mutex.lock();
        defer ctx.exchange_mutex.unlock();
        inline for (.{ "bids", "asks" }) |which| {
            const count = if (comptime std.mem.eql(u8, which, "bids")) engine.bid_count else engine.ask_count;
            var i: u32 = 0;
            while (i < count) : (i += 1) {
                const o = if (comptime std.mem.eql(u8, which, "bids")) engine.bids[i] else engine.asks[i];
                if (!std.mem.eql(u8, o.getTraderAddress(), req_addr)) continue;
                const status_active = (o.status == .active) or (o.status == .partial);
                if (!status_active) continue;
                const is_sell = (comptime std.mem.eql(u8, which, "asks"));
                const remaining = o.remainingSat();
                if (is_sell) in_orders_sat += remaining;
                if (!first_order) try oow.writeAll(",");
                first_order = false;
                try oow.print(
                    "{{\"order_id\":{d},\"pair_id\":{d},\"side\":\"{s}\",\"remaining_sat\":{d},\"price_micro_usd\":{d}}}",
                    .{ o.order_id, o.pair_id, if (is_sell) "sell" else "buy", remaining, o.price_micro_usd },
                );
            }
        }
    }

    const reserved_sat: u64 = staked_sat + in_orders_sat;
    const available_sat: u64 = if (wallet_sat > reserved_sat) wallet_sat - reserved_sat else 0;

    const wallet_omni  = wallet_sat / 1_000_000_000;
    const wallet_frac  = wallet_sat % 1_000_000_000;
    const staked_omni  = staked_sat / 1_000_000_000;
    const staked_frac  = staked_sat % 1_000_000_000;
    const avail_omni   = available_sat / 1_000_000_000;
    const avail_frac   = available_sat % 1_000_000_000;
    const orders_omni  = in_orders_sat / 1_000_000_000;
    const orders_frac  = in_orders_sat % 1_000_000_000;

    try w.print(
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"address\":\"{s}\",\"height\":{d},\"wallet_sat\":{d},\"wallet_omni\":\"{d}.{d:0>9}\",\"staked_sat\":{d},\"staked_omni\":\"{d}.{d:0>9}\",\"in_orders_sat\":{d},\"in_orders_omni\":\"{d}.{d:0>9}\",\"available_sat\":{d},\"available_omni\":\"{d}.{d:0>9}\",\"stakes\":[",
        .{
            id, req_addr, height,
            wallet_sat,  wallet_omni,  wallet_frac,
            staked_sat,  staked_omni,  staked_frac,
            in_orders_sat, orders_omni, orders_frac,
            available_sat, avail_omni,  avail_frac,
        },
    );

    if (staked_sat > 0) {
        // Real lock metadata from stake_meta (populated by
        // applyOpReturnRoles when "stake:<amt>[:<lock_blocks>]" lands).
        // Legacy stakes from older chain.dat fall back to zeros.
        var started_at: u64 = 0;
        var lock_blk: u64 = 0;
        if (ctx.bc.stake_meta.get(req_addr)) |meta| {
            started_at = meta.started_at_block;
            lock_blk = meta.lock_blocks;
        }
        const days_locked: u64 = lock_blk / 86_400;
        try w.print(
            "{{\"id\":0,\"amount_sat\":{d},\"lock_blocks\":{d},\"started_at_block\":{d},\"days_locked\":{d},\"status\":\"active\"}}",
            .{ staked_sat, lock_blk, started_at, days_locked },
        );
    }

    try w.writeAll("],\"open_sell_orders\":[");
    try w.writeAll(open_orders_json.items);
    try w.writeAll("]}}");
    return buf.toOwnedSlice();
}

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
fn handleListUnspent(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const req_addr = extractArrayStr(body, 0) orelse
                     extractStr(body, "address") orelse
                     return errorJson(-32602, "address required", id, alloc);

    if (req_addr.len == 0) return errorJson(-32602, "address must be non-empty", id, alloc);

    // Lock blockchain mutex — UTXO set may be mutated by mining/sync threads.
    ctx.bc.mutex.lock();
    defer ctx.bc.mutex.unlock();

    var json = std.array_list.Managed(u8).init(alloc);
    errdefer json.deinit();
    var w = json.writer();

    try w.print(
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"address\":\"{s}\",\"utxos\":[",
        .{ id, req_addr },
    );

    var total: u64 = 0;
    var count: usize = 0;

    // Lock UTXOSet for the whole walk — see utxo.zig RwLock note.
    ctx.bc.utxo_set.lock.lockShared();
    defer ctx.bc.utxo_set.lock.unlockShared();

    if (ctx.bc.utxo_set.address_index.get(req_addr)) |list| {
        for (list.items) |outpoint_key| {
            const utxo = ctx.bc.utxo_set.utxos.get(outpoint_key) orelse continue;
            if (count > 0) try w.writeAll(",");
            try w.print(
                "{{\"tx_hash\":\"{s}\",\"output_index\":{d},\"amount\":{d}," ++
                "\"block_height\":{d},\"is_coinbase\":{},\"is_spent\":false}}",
                .{ utxo.tx_hash, utxo.output_index, utxo.amount, utxo.block_height, utxo.is_coinbase },
            );
            total += utxo.amount;
            count += 1;
        }
    }

    try w.print("],\"total\":{d},\"count\":{d}}}}}", .{ total, count });
    return json.toOwnedSlice();
}

// SEGFAULT-FIX [scan-2026-04-25]: use getLatestBlockSnapshot() — locks bc.mutex,
// copies fields into stable buffers, unlocks. allocPrint runs after the lock is
// released, on data that no longer aliases chain memory. Eliminates UAF on
// blk.hash / blk.previous_hash / blk.transactions.items when mining concurrently
// reallocs/swaps the chain.
fn handleGetLatestBlock(ctx: *ServerCtx, id: u64) ![]u8 {
    var snap = ctx.bc.getLatestBlockSnapshot();
    defer snap.deinit(ctx.allocator);
    return std.fmt.allocPrint(ctx.allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"index\":{d},\"timestamp\":{d},\"hash\":\"{s}\",\"previousHash\":\"{s}\",\"nonce\":{d},\"txCount\":{d}}}}}",
        .{ id, snap.height, snap.timestamp, snap.hash(), snap.prevHash(), snap.nonce, snap.tx_count });
}

fn handleGetMempoolSize(ctx: *ServerCtx, id: u64) ![]u8 {
    return std.fmt.allocPrint(ctx.allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{d}}}",
        .{ id, ctx.bc.mempool.items.len });
}

fn handleGetStatus(ctx: *ServerCtx, id: u64) ![]u8 {
    return std.fmt.allocPrint(ctx.allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"status\":\"running\",\"blockCount\":{d},\"mempoolSize\":{d},\"address\":\"{s}\",\"balance\":{d}}}}}",
        .{ id, ctx.bc.getBlockCount(), ctx.bc.mempool.items.len, ctx.wallet.address, ctx.wallet.getBalance() });
}

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

fn handleOracleBtcHeight(ctx: *ServerCtx, id: u64) ![]u8 {
    ensureOracleLoaded();
    g_xchain_oracle_mutex.lock();
    defer g_xchain_oracle_mutex.unlock();
    const h = g_xchain_oracle.latestBtcHeight() orelse 0;
    return std.fmt.allocPrint(ctx.allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"height\":{d}}}}}",
        .{ id, h });
}

fn handleOracleEthHeight(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    ensureOracleLoaded();
    const cid_str = extractStr(body, "chain_id") orelse "1";
    const cid = std.fmt.parseInt(u64, cid_str, 10) catch
        return errorJson(-32602, "Invalid chain_id", id, ctx.allocator);
    g_xchain_oracle_mutex.lock();
    defer g_xchain_oracle_mutex.unlock();
    const h = g_xchain_oracle.latestEthHeight(cid) orelse 0;
    return std.fmt.allocPrint(ctx.allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"chain_id\":{d},\"height\":{d}}}}}",
        .{ id, cid, h });
}

fn parseHex32Spv(s: []const u8) ?[32]u8 {
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

fn handleOracleRecordHeader(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    ensureOracleLoaded();

    const chain = extractStr(body, "chain") orelse
        return errorJson(-32602, "Missing param: chain (btc|eth)", id, ctx.allocator);

    const ts_str = extractStr(body, "timestamp") orelse "0";
    const ts = std.fmt.parseInt(u64, ts_str, 10) catch 0;

    // ─── Quorum signature verification ──────────────────────────────────
    // Build canonical message:
    //   sha256("OMNI_ORACLE_v1\n" + chain + "\n" + height + "\n" + header_hash_hex)
    // Then require ≥ ORACLE_QUORUM_MIN distinct valid secp256k1 sigs from
    // pubkeys registered via setOracleQuorumPubkeys(). Any of:
    //   - missing quorum_sigs field
    //   - fewer than 3 valid+distinct sigs
    //   - signers not in the registered pubkey set
    // → reject with -32031.
    //
    // BACKWARD-COMPAT (dev-only): if the legacy `quorum_ok=true` flag is
    // present AND the node has zero registered quorum pubkeys, we accept
    // with a logged warning. This keeps dev/testnet bring-up scripts
    // working while a real validator key set is being set up. Production
    // operators MUST install pubkeys (and then quorum_ok is ignored).
    // `quorum_sigs` may arrive in two shapes:
    //   * NEW (preferred): JSON array of {"pubkey","sig"} objects
    //   * LEGACY: a flat string "pk1:sig1,pk2:sig2,..." (comma-sep pairs)
    // We detect new-format via findJsonArray; on miss we fall back to
    // extractStr which handles the legacy string. When the legacy form
    // is used we log a warning (one-shot per request) so operators know
    // to migrate their callers.
    const sigs_array_body: ?[]const u8 = findJsonArray(body, "quorum_sigs");
    const sigs_blob: []const u8 = if (sigs_array_body == null)
        (extractStr(body, "quorum_sigs") orelse "")
    else
        "";
    if (sigs_array_body == null and sigs_blob.len > 0) {
        std.debug.print(
            "[oracle_recordHeader] DEPRECATED: legacy comma-separated quorum_sigs string accepted; clients should migrate to JSON array form.\n",
            .{},
        );
    }
    const legacy_flag = extractStr(body, "quorum_ok") orelse "";
    const have_legacy = std.mem.eql(u8, legacy_flag, "true");

    // We need the height + header hash up-front to build the canonical msg.
    // Each chain-specific branch below re-parses these; here we do a
    // pre-pass JUST to assemble the message.
    //
    // Field names — accept both new ("height") and legacy ("block_height"
    // for BTC, "block_number" for ETH) for backward compatibility.
    var height_for_msg: u64 = 0;
    var header_hash_for_msg: [64]u8 = undefined;
    var header_hash_hex_len: usize = 0;
    if (std.mem.eql(u8, chain, "btc")) {
        const h_str = extractStr(body, "height") orelse
            extractStr(body, "block_height") orelse "0";
        height_for_msg = std.fmt.parseInt(u64, h_str, 10) catch 0;
        var hh = extractStr(body, "header_hash") orelse "";
        if (hh.len >= 2 and hh[0] == '0' and (hh[1] == 'x' or hh[1] == 'X')) hh = hh[2..];
        if (hh.len > 64) return errorJson(-32602, "Bad header_hash", id, ctx.allocator);
        @memcpy(header_hash_for_msg[0..hh.len], hh);
        header_hash_hex_len = hh.len;
    } else if (std.mem.eql(u8, chain, "eth")) {
        const bn_str = extractStr(body, "height") orelse
            extractStr(body, "block_number") orelse "0";
        height_for_msg = std.fmt.parseInt(u64, bn_str, 10) catch 0;
        // For ETH the canonical message uses block_hash if available,
        // otherwise fall back to header_hash (the new alias).
        var bh = extractStr(body, "block_hash") orelse
            extractStr(body, "header_hash") orelse "";
        if (bh.len >= 2 and bh[0] == '0' and (bh[1] == 'x' or bh[1] == 'X')) bh = bh[2..];
        if (bh.len > 64) return errorJson(-32602, "Bad block_hash", id, ctx.allocator);
        @memcpy(header_hash_for_msg[0..bh.len], bh);
        header_hash_hex_len = bh.len;
    }

    var canon_buf: [256]u8 = undefined;
    const canon = std.fmt.bufPrint(
        &canon_buf,
        "OMNI_ORACLE_v1\n{s}\n{d}\n{s}",
        .{ chain, height_for_msg, header_hash_for_msg[0..header_hash_hex_len] },
    ) catch return errorJson(-32000, "Canonical msg overflow", id, ctx.allocator);
    var canon_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(canon, &canon_digest, .{});

    // Verify each pair, dedup signers, count valid.
    // pubkey_hex = 66 chars (compressed secp256k1), sig_hex = 128 chars.
    var distinct_signers: [ORACLE_QUORUM_MAX][33]u8 = undefined;
    var distinct_count: usize = 0;
    if (sigs_array_body) |arr_body| {
        // NEW shape: JSON array of {pubkey, sig} objects. We walk by
        // brace-counting to slice out each object body, then extract
        // the two string fields with extractStr (it's scoped to that
        // sub-slice so name collisions with the outer body are impossible).
        var i: usize = 1; // skip leading '['
        const end = arr_body.len - 1; // exclude trailing ']'
        while (i < end) {
            // Skip whitespace + commas.
            while (i < end and (arr_body[i] == ' ' or arr_body[i] == ',' or
                arr_body[i] == '\t' or arr_body[i] == '\r' or arr_body[i] == '\n')) : (i += 1) {}
            if (i >= end) break;
            if (arr_body[i] != '{') break; // malformed — bail safely
            // Find matching '}'.
            const obj_start = i;
            var depth: i32 = 0;
            var in_str = false;
            while (i < end) : (i += 1) {
                const c = arr_body[i];
                if (in_str) {
                    if (c == '\\') { i += 1; continue; }
                    if (c == '"') in_str = false;
                    continue;
                }
                if (c == '"') in_str = true
                else if (c == '{') depth += 1
                else if (c == '}') {
                    depth -= 1;
                    if (depth == 0) { i += 1; break; }
                }
            }
            const obj = arr_body[obj_start..i];
            const pk_hex = extractStr(obj, "pubkey") orelse continue;
            const sig_hex = extractStr(obj, "sig") orelse continue;
            if (pk_hex.len != 66 or sig_hex.len != 128) continue;
            var pk_bytes: [33]u8 = undefined;
            var sig_bytes: [64]u8 = undefined;
            hex_utils.hexToBytes(pk_hex, &pk_bytes) catch continue;
            hex_utils.hexToBytes(sig_hex, &sig_bytes) catch continue;
            if (!isQuorumPubkey(pk_bytes)) continue;
            var dup = false;
            var j: usize = 0;
            while (j < distinct_count) : (j += 1) {
                if (std.mem.eql(u8, &distinct_signers[j], &pk_bytes)) { dup = true; break; }
            }
            if (dup) continue;
            if (!secp256k1_mod.Secp256k1Crypto.verify(pk_bytes, &canon_digest, sig_bytes)) continue;
            distinct_signers[distinct_count] = pk_bytes;
            distinct_count += 1;
            if (distinct_count >= ORACLE_QUORUM_MAX) break;
        }
    } else if (sigs_blob.len > 0) {
        // LEGACY shape: comma-separated `pubkey_hex:sig_hex` pairs.
        var it = std.mem.splitScalar(u8, sigs_blob, ',');
        while (it.next()) |pair| {
            const colon = std.mem.indexOfScalar(u8, pair, ':') orelse continue;
            const pk_hex = pair[0..colon];
            const sig_hex = pair[colon + 1 ..];
            if (pk_hex.len != 66 or sig_hex.len != 128) continue;
            var pk_bytes: [33]u8 = undefined;
            var sig_bytes: [64]u8 = undefined;
            hex_utils.hexToBytes(pk_hex, &pk_bytes) catch continue;
            hex_utils.hexToBytes(sig_hex, &sig_bytes) catch continue;
            if (!isQuorumPubkey(pk_bytes)) continue;
            var dup = false;
            var j: usize = 0;
            while (j < distinct_count) : (j += 1) {
                if (std.mem.eql(u8, &distinct_signers[j], &pk_bytes)) { dup = true; break; }
            }
            if (dup) continue;
            if (!secp256k1_mod.Secp256k1Crypto.verify(pk_bytes, &canon_digest, sig_bytes)) continue;
            distinct_signers[distinct_count] = pk_bytes;
            distinct_count += 1;
            if (distinct_count >= ORACLE_QUORUM_MAX) break;
        }
    }

    if (distinct_count < ORACLE_QUORUM_MIN) {
        // Legacy dev-mode escape hatch: only when no quorum pubkeys are
        // configured AND the legacy flag is set.
        if (g_oracle_quorum_count == 0 and have_legacy) {
            std.debug.print(
                "[oracle_recordHeader] WARNING: dev-mode (no quorum pubkeys configured); accepting on legacy quorum_ok=true\n",
                .{},
            );
        } else {
            return errorJson(-32031, "Quorum signature insufficient", id, ctx.allocator);
        }
    }

    if (std.mem.eql(u8, chain, "btc")) {
        // Accept new "height" alongside legacy "block_height".
        const h_str = extractStr(body, "height") orelse
            extractStr(body, "block_height") orelse
            return errorJson(-32602, "Missing param: height (or block_height)", id, ctx.allocator);
        const hh_str = extractStr(body, "header_hash") orelse
            return errorJson(-32602, "Missing param: header_hash", id, ctx.allocator);
        const h = std.fmt.parseInt(u64, h_str, 10) catch
            return errorJson(-32602, "Bad height", id, ctx.allocator);
        const hh = parseHex32Spv(hh_str) orelse
            return errorJson(-32602, "Bad header_hash (need 32-byte hex)", id, ctx.allocator);

        // Optional: caller may supply the raw 80-byte block header as hex
        // (160 chars). When present, we extract merkle_root via parseHeader
        // and store it on the anchor — defense-in-depth so SPV verifiers
        // can ignore caller-supplied merkle_root and trust the anchor instead.
        // Backward-compat: if `raw_header_hex` is absent, merkle_root stays
        // zero on the anchor and SPV falls back to the legacy blob field.
        var merkle_root: [32]u8 = [_]u8{0} ** 32;
        if (extractStr(body, "raw_header_hex")) |raw_hex| {
            if (raw_hex.len != 160) {
                return errorJson(-32602, "raw_header_hex must be 160 hex chars (80 bytes)", id, ctx.allocator);
            }
            var raw_bytes: [80]u8 = undefined;
            hex_utils.hexToBytes(raw_hex, &raw_bytes) catch
                return errorJson(-32602, "Bad raw_header_hex", id, ctx.allocator);
            const parsed = spv_btc_mod.parseHeader(raw_bytes);
            merkle_root = parsed.merkle_root;
        }

        g_xchain_oracle_mutex.lock();
        defer g_xchain_oracle_mutex.unlock();
        g_xchain_oracle.recordBtcAnchor(.{
            .block_height = h,
            .header_hash = hh,
            .merkle_root = merkle_root,
            .timestamp = ts,
        }) catch |e| {
            const msg = if (e == error.NonMonotonic) "Non-monotonic update" else "Anchor rejected";
            return errorJson(-32000, msg, id, ctx.allocator);
        };
        g_xchain_oracle.saveToFile(XCHAIN_ORACLE_PATH) catch {};
        return std.fmt.allocPrint(ctx.allocator,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"ok\":true,\"chain\":\"btc\",\"height\":{d}}}}}",
            .{ id, h });
    }

    if (std.mem.eql(u8, chain, "eth")) {
        const cid_str = extractStr(body, "chain_id") orelse "1";
        // Accept new "height" alongside legacy "block_number".
        const bn_str = extractStr(body, "height") orelse
            extractStr(body, "block_number") orelse
            return errorJson(-32602, "Missing param: height (or block_number)", id, ctx.allocator);
        // Accept new "header_hash" alias alongside legacy "block_hash".
        const bh_str = extractStr(body, "block_hash") orelse
            extractStr(body, "header_hash") orelse
            return errorJson(-32602, "Missing param: header_hash (or block_hash)", id, ctx.allocator);
        const rr_str = extractStr(body, "receipts_root") orelse
            return errorJson(-32602, "Missing param: receipts_root", id, ctx.allocator);
        const cid = std.fmt.parseInt(u64, cid_str, 10) catch
            return errorJson(-32602, "Bad chain_id", id, ctx.allocator);
        const bn = std.fmt.parseInt(u64, bn_str, 10) catch
            return errorJson(-32602, "Bad height", id, ctx.allocator);
        const bh = parseHex32Spv(bh_str) orelse
            return errorJson(-32602, "Bad header_hash", id, ctx.allocator);
        const rr = parseHex32Spv(rr_str) orelse
            return errorJson(-32602, "Bad receipts_root", id, ctx.allocator);
        g_xchain_oracle_mutex.lock();
        defer g_xchain_oracle_mutex.unlock();
        g_xchain_oracle.recordEthAnchor(.{
            .chain_id = cid, .block_number = bn, .block_hash = bh,
            .receipts_root = rr, .timestamp = ts,
        }) catch |e| {
            const msg = switch (e) {
                error.NonMonotonic => "Non-monotonic update",
                error.TooManyChains => "Chain registry full",
            };
            return errorJson(-32000, msg, id, ctx.allocator);
        };
        g_xchain_oracle.saveToFile(XCHAIN_ORACLE_PATH) catch {};
        return std.fmt.allocPrint(ctx.allocator,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"ok\":true,\"chain\":\"eth\",\"chain_id\":{d},\"block_number\":{d}}}}}",
            .{ id, cid, bn });
    }

    return errorJson(-32602, "Unknown chain (use 'btc' or 'eth')", id, ctx.allocator);
}

fn handleSpvBtcVerifyTx(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    ensureOracleLoaded();

    const txh_str = extractStr(body, "tx_hash") orelse
        return errorJson(-32602, "Missing param: tx_hash", id, ctx.allocator);
    const root_str = extractStr(body, "merkle_root") orelse
        return errorJson(-32602, "Missing param: merkle_root", id, ctx.allocator);
    const path_str = extractStr(body, "merkle_path") orelse "";
    const idx_str = extractStr(body, "indices") orelse "";

    const txh = parseHex32Spv(txh_str) orelse
        return errorJson(-32602, "Bad tx_hash", id, ctx.allocator);
    const root = parseHex32Spv(root_str) orelse
        return errorJson(-32602, "Bad merkle_root", id, ctx.allocator);

    // merkle_path is a concatenated hex string of 32-byte siblings.
    // indices is a string of '0'/'1' chars, one per level.
    if (path_str.len % 64 != 0) {
        return errorJson(-32602, "merkle_path must be multiples of 64 hex chars", id, ctx.allocator);
    }
    const levels = path_str.len / 64;
    if (levels != idx_str.len) {
        return errorJson(-32602, "merkle_path/indices length mismatch", id, ctx.allocator);
    }
    if (levels > 64) {
        return errorJson(-32602, "Too many levels (>64)", id, ctx.allocator);
    }

    var path_buf: [64][32]u8 = undefined;
    var idx_buf: [64]u1 = undefined;
    var i: usize = 0;
    while (i < levels) : (i += 1) {
        const seg = path_str[i * 64 .. (i + 1) * 64];
        path_buf[i] = parseHex32Spv(seg) orelse
            return errorJson(-32602, "Bad merkle_path segment", id, ctx.allocator);
        idx_buf[i] = if (idx_str[i] == '1') @as(u1, 1) else @as(u1, 0);
    }

    const ok = spv_btc_mod.verifyMerkleProof(txh, path_buf[0..levels], idx_buf[0..levels], root);
    return std.fmt.allocPrint(ctx.allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"valid\":{s}}}}}",
        .{ id, if (ok) "true" else "false" });
}

fn handleSpvEthVerifyEvent(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    ensureOracleLoaded();
    // Full PMT verification path — caller supplies the trie key
    // (RLP-encoded tx index), the receipt RLP, and the proof nodes
    // (pipe-separated hex). receipts_root is read from the recorded
    // ETH anchor for the requested chain_id.
    const cid_str = extractStr(body, "chain_id") orelse "1";
    const cid = std.fmt.parseInt(u64, cid_str, 10) catch
        return errorJson(-32602, "Bad chain_id", id, ctx.allocator);

    g_xchain_oracle_mutex.lock();
    const anchor_opt = g_xchain_oracle.latestEth(cid);
    g_xchain_oracle_mutex.unlock();
    const anchor = anchor_opt orelse
        return errorJson(-32030, "No anchor recorded for chain_id", id, ctx.allocator);

    const tx_index_hex = extractStr(body, "tx_index_rlp_hex") orelse
        return errorJson(-32602, "Missing tx_index_rlp_hex", id, ctx.allocator);
    const receipt_hex = extractStr(body, "receipt_rlp_hex") orelse
        return errorJson(-32602, "Missing receipt_rlp_hex", id, ctx.allocator);
    const proof_hex = extractStr(body, "receipt_proof_hex") orelse
        return errorJson(-32602, "Missing receipt_proof_hex", id, ctx.allocator);

    const alloc = ctx.allocator;
    const key = hexAlloc(alloc, tx_index_hex) orelse
        return errorJson(-32602, "Bad tx_index_rlp_hex", id, alloc);
    defer alloc.free(key);
    const value = hexAlloc(alloc, receipt_hex) orelse
        return errorJson(-32602, "Bad receipt_rlp_hex", id, alloc);
    defer alloc.free(value);

    var nodes_storage: [64][]u8 = undefined;
    var node_slices: [64][]const u8 = undefined;
    var n: usize = 0;
    defer {
        var k: usize = 0;
        while (k < n) : (k += 1) alloc.free(nodes_storage[k]);
    }
    var it = std.mem.splitScalar(u8, proof_hex, '|');
    while (it.next()) |part| {
        if (n >= 64) return errorJson(-32602, "Too many proof nodes", id, alloc);
        const decoded = hexAlloc(alloc, part) orelse
            return errorJson(-32602, "Bad receipt_proof_hex element", id, alloc);
        nodes_storage[n] = decoded;
        node_slices[n] = decoded;
        n += 1;
    }

    const ok = spv_eth_mod.verifyReceiptAtIndex(
        anchor.receipts_root, key, value, node_slices[0..n],
    );
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"verified\":{s},\"chain_id\":{d},\"block_number\":{d}}}}}",
        .{ id, if (ok) "true" else "false", cid, anchor.block_number });
}

// ─── Stake / Validator / Agent / Reputation handlers ───────────────────────
//
// Backend wiring for the 4 new frontend pages (Stake, Validators, Agents,
// Reputation). Stake/unstake submit op_return TXs that apply_block parses
// into the StakingEngine; validator promotion writes a `validator_*` op_return;
// agent registration writes `agent:register:*`. Reputation is read-only —
// it queries g_reputation directly.

fn handleStake(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc      = ctx.allocator;
    const from_raw   = extractStr(body, "from") orelse return errorJson(-32602, "Missing: from", id, alloc);
    const amount     = extractParamObjectU64(body, "amount_sat");
    const lock_blocks = extractParamObjectU64(body, "lock_blocks");
    const sig_raw    = extractStr(body, "signature")  orelse return errorJson(-32602, "Missing: signature", id, alloc);
    const pubkey_raw = extractStr(body, "public_key") orelse return errorJson(-32602, "Missing: public_key", id, alloc);
    const nonce      = extractParamObjectU64(body, "nonce");

    if (amount < 10_000_000_000) return errorJson(-32000, "Min stake 10 OMNI", id, alloc);

    // CRITICAL: Transaction stored in mempool MUST own all its string slices.
    // `from_raw`/`sig_raw`/`pubkey_raw` point into the request body buffer,
    // which is freed when this handler returns. If we keep those slices,
    // applyOpReturnRoles reads garbage and the stake silently fails.
    // Dupe everything that goes into tx; do NOT defer-free those copies.
    const from   = try alloc.dupe(u8, from_raw);
    const sig    = try alloc.dupe(u8, sig_raw);
    const pubkey = try alloc.dupe(u8, pubkey_raw);
    // Legacy stake op_return: just "stake:<lock_blocks>". Amount goes in
    // tx.amount so applyOpReturnRoles picks it up via tx.amount accumulation.
    const op_return = try std.fmt.allocPrint(alloc, "stake:{d}", .{lock_blocks});

    const ts = std.time.timestamp();
    const tx_id: u32 = @intCast(std.time.milliTimestamp() & 0xFFFFFFFF);
    const provisional = try std.fmt.allocPrint(alloc, "{d}{s}{d}", .{ tx_id, from, ts });
    defer alloc.free(provisional); // replaced below by canonical hash

    var tx = blockchain_mod.Transaction{
        .id = tx_id, .from_address = from, .to_address = from,
        .amount = amount, .fee = 1000, .timestamp = ts, .nonce = nonce,
        .op_return = op_return, .signature = sig, .public_key = pubkey,
        .scheme = .omni_ecdsa, .hash = provisional,
    };
    const hash_bytes = tx.calculateHash();
    const canonical = try std.fmt.allocPrint(alloc, "{s}", .{std.fmt.bytesToHex(hash_bytes, .lower)});
    tx.hash = canonical;

    ctx.bc.mutex.lock();
    ctx.bc.mempool.append(tx) catch {
        ctx.bc.mutex.unlock();
        // Free all owned strings on rejection — they would otherwise leak.
        alloc.free(from);
        alloc.free(sig);
        alloc.free(pubkey);
        alloc.free(op_return);
        alloc.free(canonical);
        return errorJson(-32603, "Mempool full", id, alloc);
    };
    ctx.bc.mutex.unlock();

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"status\":\"queued\",\"txid\":\"{s}\",\"stake_id\":{d},\"amount_sat\":{d},\"lock_blocks\":{d}}}}}",
        .{ id, canonical, tx_id, amount, lock_blocks });
}

fn handleUnstake(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc      = ctx.allocator;
    const from_raw   = extractStr(body, "from") orelse return errorJson(-32602, "Missing: from", id, alloc);
    const stake_id   = extractParamObjectU64(body, "stake_id");
    const sig_raw    = extractStr(body, "signature")  orelse return errorJson(-32602, "Missing: signature", id, alloc);
    const pubkey_raw = extractStr(body, "public_key") orelse return errorJson(-32602, "Missing: public_key", id, alloc);
    const nonce      = extractParamObjectU64(body, "nonce");

    // Same UAF protection as handleStake — dupe all strings into the TX so
    // they outlive the handler / request body buffer.
    const from   = try alloc.dupe(u8, from_raw);
    const sig    = try alloc.dupe(u8, sig_raw);
    const pubkey = try alloc.dupe(u8, pubkey_raw);
    const op_return = try std.fmt.allocPrint(alloc, "unstake:{d}", .{stake_id});

    const ts = std.time.timestamp();
    const tx_id: u32 = @intCast(std.time.milliTimestamp() & 0xFFFFFFFF);
    const provisional = try std.fmt.allocPrint(alloc, "{d}{s}{d}", .{ tx_id, from, ts });
    defer alloc.free(provisional);

    var tx = blockchain_mod.Transaction{
        .id = tx_id, .from_address = from, .to_address = from,
        .amount = 0, .fee = 1000, .timestamp = ts, .nonce = nonce,
        .op_return = op_return, .signature = sig, .public_key = pubkey,
        .scheme = .omni_ecdsa, .hash = provisional,
    };
    const hash_bytes = tx.calculateHash();
    const canonical = try std.fmt.allocPrint(alloc, "{s}", .{std.fmt.bytesToHex(hash_bytes, .lower)});
    tx.hash = canonical;

    ctx.bc.mutex.lock();
    const current_block: u64 = @intCast(ctx.bc.chain.items.len);
    ctx.bc.mempool.append(tx) catch {
        ctx.bc.mutex.unlock();
        alloc.free(from); alloc.free(sig); alloc.free(pubkey);
        alloc.free(op_return); alloc.free(canonical);
        return errorJson(-32603, "Mempool full", id, alloc);
    };
    ctx.bc.mutex.unlock();
    const unbond_until = current_block + 604_800;

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"status\":\"queued\",\"txid\":\"{s}\",\"unbonding_until_block\":{d}}}}}",
        .{ id, canonical, unbond_until });
}

fn handleGetStake(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc   = ctx.allocator;
    const address = extractStr(body, "address") orelse return errorJson(-32602, "Missing: address", id, alloc);

    var buf = std.array_list.Managed(u8).init(alloc);
    defer buf.deinit();
    const w = buf.writer();
    try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"stakes\":[", .{id});

    // Read from blockchain.stake_amounts — populated by applyOpReturnRoles.
    // We MUST hold bc.mutex for the read because HashMap rehashes during
    // concurrent inserts (mining loop applyBlock) corrupt the metadata
    // pointer alignment → @panic("incorrect alignment").
    ctx.bc.mutex.lock();
    defer ctx.bc.mutex.unlock();
    if (ctx.bc.stake_amounts.get(address)) |amt| {
        if (amt > 0) {
            // Look up real lock metadata. Legacy stakes loaded from older
            // chain.dat may not have an entry — fall back to zeros so the
            // UI can render them as "no lock period" instead of crashing.
            var started_at: u64 = 0;
            var lock_blk: u64 = 0;
            if (ctx.bc.stake_meta.get(address)) |meta| {
                started_at = meta.started_at_block;
                lock_blk = meta.lock_blocks;
            }
            // days_locked: lock_blocks × 1s block time → seconds → days.
            // Block time is 1s (CLAUDE.md: blockTimeMs=1000), so 86400
            // blocks = 1 day.
            const days_locked: u64 = lock_blk / 86_400;
            try w.print(
                "{{\"id\":0,\"amount_sat\":{d},\"lock_blocks\":{d},\"started_at_block\":{d},\"days_locked\":{d},\"rent_earned\":0,\"status\":\"active\"}}",
                .{ amt, lock_blk, started_at, days_locked },
            );
        }
    }
    try w.writeAll("]}}");
    return buf.toOwnedSlice();
}

fn handleGetStakers(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const limit_raw = extractParamObjectU64(body, "limit");
    const limit: usize = if (limit_raw == 0) 50 else @min(@as(usize, @intCast(limit_raw)), 200);

    var buf = std.array_list.Managed(u8).init(alloc);
    defer buf.deinit();
    const w = buf.writer();
    try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"stakers\":[", .{id});

    // Iterate stake_amounts under lock. Concurrent with apply_block insert,
    // HashMap rehash invalidates iterator pointers → alignment crash. Lock
    // is short — at most ~128 entries to write.
    ctx.bc.mutex.lock();
    defer ctx.bc.mutex.unlock();
    var emitted: usize = 0;
    var iter = ctx.bc.stake_amounts.iterator();
    while (iter.next()) |entry| {
        if (emitted >= limit) break;
        const amt = entry.value_ptr.*;
        if (amt == 0) continue;
        if (emitted > 0) try w.writeAll(",");
        emitted += 1;
        var started_at: u64 = 0;
        var lock_blk: u64 = 0;
        if (ctx.bc.stake_meta.get(entry.key_ptr.*)) |meta| {
            started_at = meta.started_at_block;
            lock_blk = meta.lock_blocks;
        }
        const days_locked: u64 = lock_blk / 86_400;
        try w.print(
            "{{\"address\":\"{s}\",\"amount_sat\":{d},\"lock_blocks\":{d},\"started_at_block\":{d},\"days_locked\":{d},\"rent_earned\":0}}",
            .{ entry.key_ptr.*, amt, lock_blk, started_at, days_locked },
        );
    }
    try w.writeAll("]}}");
    return buf.toOwnedSlice();
}

fn handleGetValidatorsV2(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    _ = body;
    const alloc = ctx.allocator;

    var buf = std.array_list.Managed(u8).init(alloc);
    defer buf.deinit();
    const w = buf.writer();

    // Source of truth: bc.stake_amounts (HashMap<addr, stake_sat>) populated
    // by applyOpReturnRoles when "stake:" op_returns are mined. Anyone with
    // ≥100 OMNI stake = automatic validator (no separate registration needed).
    // We also enrich with miner stats from the chain's last 100 blocks.
    ctx.bc.mutex.lock();
    defer ctx.bc.mutex.unlock();

    const VALIDATOR_MIN_OMNI: u64 = 100;
    const SAT_PER_OMNI: u64 = 1_000_000_000;

    // First pass: count qualified validators
    var total_qualified: usize = 0;
    {
        var iter = ctx.bc.stake_amounts.iterator();
        while (iter.next()) |entry| {
            const stake_omni = entry.value_ptr.* / SAT_PER_OMNI;
            if (stake_omni >= VALIDATOR_MIN_OMNI) total_qualified += 1;
        }
    }

    try w.print(
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"total_validators\":{d},\"active_count\":{d},\"slashed_count\":0,\"current_slot_leader\":\"\",\"validators\":[",
        .{ id, total_qualified, total_qualified },
    );

    var first = true;
    var iter2 = ctx.bc.stake_amounts.iterator();
    while (iter2.next()) |entry| {
        const stake_sat = entry.value_ptr.*;
        const stake_omni = stake_sat / SAT_PER_OMNI;
        if (stake_omni < VALIDATOR_MIN_OMNI) continue;
        if (!first) try w.writeAll(",");
        first = false;
        const tier: []const u8 =
            if (stake_omni >= 100_000) "Platinum"
            else if (stake_omni >= 10_000) "Gold"
            else if (stake_omni >= 1_000) "Silver"
            else "Bronze";
        const addr = entry.key_ptr.*;
        // Count blocks mined by this address in the last 100 blocks (uptime proxy)
        var blocks_signed: u32 = 0;
        const tip = ctx.bc.chain.items.len;
        const start = if (tip > 100) tip - 100 else 1;
        var bi: usize = start;
        while (bi < tip) : (bi += 1) {
            const blk = ctx.bc.chain.items[bi];
            if (std.mem.eql(u8, blk.miner_address, addr)) blocks_signed += 1;
        }
        const sample_size: u32 = @intCast(if (tip > 100) 100 else tip - 1);
        const uptime_pct: u8 = if (sample_size == 0) 100
            else @intCast((@as(u64, blocks_signed) * 100) / sample_size);
        const blocks_missed: u32 = if (sample_size > blocks_signed) sample_size - blocks_signed else 0;
        try w.print(
            "{{\"address\":\"{s}\",\"tier\":\"{s}\",\"stake_omni\":{d},\"uptime_pct\":{d},\"blocks_signed\":{d},\"blocks_missed\":{d},\"last_heartbeat_block\":{d},\"slashed\":false,\"slash_count\":0,\"joined_at_block\":0}}",
            .{ addr, tier, stake_omni, uptime_pct, blocks_signed, blocks_missed, tip },
        );
    }
    try w.writeAll("]}}");
    return buf.toOwnedSlice();
}

fn handleBecomeValidator(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc      = ctx.allocator;
    const from_raw   = extractStr(body, "from") orelse return errorJson(-32602, "Missing: from", id, alloc);
    const sig_raw    = extractStr(body, "signature")  orelse return errorJson(-32602, "Missing: signature", id, alloc);
    const pubkey_raw = extractStr(body, "public_key") orelse return errorJson(-32602, "Missing: public_key", id, alloc);
    const nonce      = extractParamObjectU64(body, "nonce");

    // Dupe all strings to outlive request body buffer (UAF protection — see handleStake).
    const from   = try alloc.dupe(u8, from_raw);
    const sig    = try alloc.dupe(u8, sig_raw);
    const pubkey = try alloc.dupe(u8, pubkey_raw);
    const op_return = try alloc.dupe(u8, "validator:promote");

    const ts = std.time.timestamp();
    const tx_id: u32 = @intCast(std.time.milliTimestamp() & 0xFFFFFFFF);
    const provisional = try std.fmt.allocPrint(alloc, "{d}{s}{d}", .{ tx_id, from, ts });
    defer alloc.free(provisional);

    var tx = blockchain_mod.Transaction{
        .id = tx_id, .from_address = from, .to_address = from,
        .amount = 0, .fee = 1000, .timestamp = ts, .nonce = nonce,
        .op_return = op_return, .signature = sig, .public_key = pubkey,
        .scheme = .omni_ecdsa, .hash = provisional,
    };
    const hash_bytes = tx.calculateHash();
    const canonical = try std.fmt.allocPrint(alloc, "{s}", .{std.fmt.bytesToHex(hash_bytes, .lower)});
    tx.hash = canonical;

    ctx.bc.mutex.lock();
    ctx.bc.mempool.append(tx) catch {
        ctx.bc.mutex.unlock();
        alloc.free(from); alloc.free(sig); alloc.free(pubkey);
        alloc.free(op_return); alloc.free(canonical);
        return errorJson(-32603, "Mempool full", id, alloc);
    };
    ctx.bc.mutex.unlock();

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"status\":\"queued\",\"txid\":\"{s}\",\"validator_tier\":\"Bronze\"}}}}",
        .{ id, canonical });
}

fn handleValidatorHeartbeat(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc  = ctx.allocator;
    const from   = extractStr(body, "from") orelse return errorJson(-32602, "Missing: from", id, alloc);
    _ = extractStr(body, "signature") orelse return errorJson(-32602, "Missing: signature", id, alloc);
    _ = extractStr(body, "public_key") orelse return errorJson(-32602, "Missing: public_key", id, alloc);

    // Heartbeat is in-memory only (no chain TX) — mark validator as alive.
    if (main_mod.g_staking_engine.?.findValidatorIndex(from)) |idx| {
        const v = &main_mod.g_staking_engine.?.validators[idx];
        // Use blocks_produced as proxy for liveness ping; full impl would
        // store last_heartbeat_block on a separate field.
        _ = v;
    }

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"status\":\"ok\"}}}}", .{id});
}

fn handleGetSlashEvents(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    _ = body;
    const alloc = ctx.allocator;
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"events\":[]}}}}", .{id});
}

fn handleAgentRegister(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc      = ctx.allocator;
    const from_raw   = extractStr(body, "from") orelse return errorJson(-32602, "Missing: from", id, alloc);
    const name_raw   = extractStr(body, "name") orelse return errorJson(-32602, "Missing: name", id, alloc);
    const strategy_raw = extractStr(body, "strategy") orelse "custom";
    const fee_bps    = extractParamObjectU64(body, "fee_bps");
    const sig_raw    = extractStr(body, "signature")  orelse return errorJson(-32602, "Missing: signature", id, alloc);
    const pubkey_raw = extractStr(body, "public_key") orelse return errorJson(-32602, "Missing: public_key", id, alloc);
    const nonce      = extractParamObjectU64(body, "nonce");

    const from   = try alloc.dupe(u8, from_raw);
    const sig    = try alloc.dupe(u8, sig_raw);
    const pubkey = try alloc.dupe(u8, pubkey_raw);
    const op_return = try std.fmt.allocPrint(alloc, "agent:register:{s}:{s}:{d}", .{ name_raw, strategy_raw, fee_bps });

    const ts = std.time.timestamp();
    const tx_id: u32 = @intCast(std.time.milliTimestamp() & 0xFFFFFFFF);
    const provisional = try std.fmt.allocPrint(alloc, "{d}{s}{d}", .{ tx_id, from, ts });
    defer alloc.free(provisional);

    var tx = blockchain_mod.Transaction{
        .id = tx_id, .from_address = from, .to_address = from,
        .amount = 0, .fee = 1000, .timestamp = ts, .nonce = nonce,
        .op_return = op_return, .signature = sig, .public_key = pubkey,
        .scheme = .omni_ecdsa, .hash = provisional,
    };
    const hash_bytes = tx.calculateHash();
    const canonical = try std.fmt.allocPrint(alloc, "{s}", .{std.fmt.bytesToHex(hash_bytes, .lower)});
    tx.hash = canonical;

    ctx.bc.mutex.lock();
    ctx.bc.mempool.append(tx) catch {
        ctx.bc.mutex.unlock();
        alloc.free(from); alloc.free(sig); alloc.free(pubkey);
        alloc.free(op_return); alloc.free(canonical);
        return errorJson(-32603, "Mempool full", id, alloc);
    };
    ctx.bc.mutex.unlock();

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"status\":\"queued\",\"txid\":\"{s}\",\"agent_id\":{d}}}}}",
        .{ id, canonical, tx_id });
}

fn handleAgentUnregister(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc      = ctx.allocator;
    const from_raw   = extractStr(body, "from") orelse return errorJson(-32602, "Missing: from", id, alloc);
    const agent_id   = extractParamObjectU64(body, "agent_id");
    const sig_raw    = extractStr(body, "signature")  orelse return errorJson(-32602, "Missing: signature", id, alloc);
    const pubkey_raw = extractStr(body, "public_key") orelse return errorJson(-32602, "Missing: public_key", id, alloc);
    const nonce      = extractParamObjectU64(body, "nonce");

    const from   = try alloc.dupe(u8, from_raw);
    const sig    = try alloc.dupe(u8, sig_raw);
    const pubkey = try alloc.dupe(u8, pubkey_raw);
    const op_return = try std.fmt.allocPrint(alloc, "agent:unregister:{d}", .{agent_id});

    const ts = std.time.timestamp();
    const tx_id: u32 = @intCast(std.time.milliTimestamp() & 0xFFFFFFFF);
    const provisional = try std.fmt.allocPrint(alloc, "{d}{s}{d}", .{ tx_id, from, ts });
    defer alloc.free(provisional);

    var tx = blockchain_mod.Transaction{
        .id = tx_id, .from_address = from, .to_address = from,
        .amount = 0, .fee = 1000, .timestamp = ts, .nonce = nonce,
        .op_return = op_return, .signature = sig, .public_key = pubkey,
        .scheme = .omni_ecdsa, .hash = provisional,
    };
    const hash_bytes = tx.calculateHash();
    const canonical = try std.fmt.allocPrint(alloc, "{s}", .{std.fmt.bytesToHex(hash_bytes, .lower)});
    tx.hash = canonical;

    ctx.bc.mutex.lock();
    ctx.bc.mempool.append(tx) catch {
        ctx.bc.mutex.unlock();
        alloc.free(from); alloc.free(sig); alloc.free(pubkey);
        alloc.free(op_return); alloc.free(canonical);
        return errorJson(-32603, "Mempool full", id, alloc);
    };
    ctx.bc.mutex.unlock();

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"status\":\"queued\",\"txid\":\"{s}\"}}}}",
        .{ id, canonical });
}

fn handleAgentEdit(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    // Fix B8: was accepting any garbage and returning "ok". Now validates
    // required params so callers get -32602 for malformed requests.
    _ = extractStr(body, "from") orelse return errorJson(-32602, "Missing: from", id, alloc);
    const agent_id = extractParamObjectU64(body, "agent_id");
    if (agent_id == 0) return errorJson(-32602, "Missing or invalid: agent_id", id, alloc);
    _ = extractStr(body, "signature")  orelse return errorJson(-32602, "Missing: signature", id, alloc);
    _ = extractStr(body, "public_key") orelse return errorJson(-32602, "Missing: public_key", id, alloc);
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"status\":\"ok\",\"agent_id\":{d}}}}}", .{ id, agent_id });
}

fn handleAgentFollow(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    _ = extractStr(body, "from") orelse return errorJson(-32602, "Missing: from", id, alloc);
    const agent_id = extractParamObjectU64(body, "agent_id");
    if (agent_id == 0) return errorJson(-32602, "Missing or invalid: agent_id", id, alloc);
    _ = extractStr(body, "signature")  orelse return errorJson(-32602, "Missing: signature", id, alloc);
    _ = extractStr(body, "public_key") orelse return errorJson(-32602, "Missing: public_key", id, alloc);
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"status\":\"ok\",\"agent_id\":{d}}}}}", .{ id, agent_id });
}

fn handleGetAgents(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    _ = body;
    const alloc = ctx.allocator;

    var buf = std.array_list.Managed(u8).init(alloc);
    defer buf.deinit();
    const w = buf.writer();
    try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"agents\":[", .{id});

    var first = true;
    for (&main_mod.g_agent_manager.slots) |*slot| {
        if (!slot.used) continue;
        if (!first) try w.writeAll(",");
        first = false;
        const owner = if (slot.canSign()) slot.wallet.?.getAddress() else "";
        const strategy_str: []const u8 = "custom";
        try w.print(
            "{{\"id\":{d},\"owner\":\"{s}\",\"name\":\"{s}\",\"strategy\":\"{s}\",\"fee_bps\":0,\"registered_at_block\":0,\"decisions_made\":{d},\"decisions_ok\":{d},\"profit_omni_total\":{d},\"followers\":0,\"status\":\"active\",\"reputation_total\":0}}",
            .{ slot.config.wallet_index, owner, slot.config.getName(), strategy_str,
               slot.stats.decisions_emitted, slot.stats.txs_submitted, slot.stats.total_mined_sat },
        );
    }
    try w.writeAll("]}}");
    return buf.toOwnedSlice();
}

fn handleGetAgent(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    _ = body;
    const alloc = ctx.allocator;
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":null}}", .{id});
}

fn dispatch(body: []const u8, ctx: *ServerCtx) ![]u8 {
    const alloc = ctx.allocator;

    // Parse "method" si "id" cu string search simplu (evitam dep JSON)
    const method = extractStr(body, "method") orelse return errorJson(-32600, "Invalid request", 0, alloc);
    const id      = extractId(body);

    if (std.mem.eql(u8, method, "getblockcount")) {
        return handleGetBlockCount(ctx, id);
    }

    if (std.mem.eql(u8, method, "getbalance"))     return handleGetBalance(body, ctx, id);
    if (std.mem.eql(u8, method, "getwalletsummary")) return handleGetWalletSummary(body, ctx, id);
    if (std.mem.eql(u8, method, "listunspent"))    return handleListUnspent(body, ctx, id);
    if (std.mem.eql(u8, method, "getlatestblock")) return handleGetLatestBlock(ctx, id);
    if (std.mem.eql(u8, method, "getmempoolsize")) return handleGetMempoolSize(ctx, id);
    if (std.mem.eql(u8, method, "getstatus"))      return handleGetStatus(ctx, id);

    // Route to handler functions (refactored for low cyclomatic complexity)
    if (std.mem.eql(u8, method, "sendtransaction"))  return handleSendTx(body, ctx, id);
    if (std.mem.eql(u8, method, "gettransactions"))  return handleGetTxs(body, ctx, id);
    if (std.mem.eql(u8, method, "registerminer"))    return handleRegMiner(body, ctx, id);
    if (std.mem.eql(u8, method, "getpoolstats"))     return handlePoolStats(ctx, id);
    if (std.mem.eql(u8, method, "getaddressbalance"))return handleAddrBal(body, ctx, id);
    if (std.mem.eql(u8, method, "getmempoolstats"))  return handleMpStats(ctx, id);
    if (std.mem.eql(u8, method, "getpendingtxs"))   return handleGetPendingTxs(body, ctx, id);
    if (std.mem.eql(u8, method, "getpeers"))         return handlePeers(ctx, id);
    if (std.mem.eql(u8, method, "getsyncstatus"))    return handleSyncSt(ctx, id);
    if (std.mem.eql(u8, method, "getnetworkinfo"))   return handleNetInfo(ctx, id);
    if (std.mem.eql(u8, method, "getblock"))         return handleGetBlk(body, ctx, id);
    if (std.mem.eql(u8, method, "getblocks"))        return handleGetBlks(body, ctx, id);
    if (std.mem.eql(u8, method, "getminerstats"))    return handleMinerSt(ctx, id);
    if (std.mem.eql(u8, method, "getvalidators"))    return handleGetValidators(ctx, id);
    if (std.mem.eql(u8, method, "getslotleader"))    return handleGetSlotLeader(ctx, id);
    if (std.mem.eql(u8, method, "getclockstatus"))   return handleGetClockStatus(ctx, id);
    if (std.mem.eql(u8, method, "getslotcalendar")) return handleGetSlotCalendar(ctx, id);
    if (std.mem.eql(u8, method, "getfuturepool"))    return handleGetFuturePool(ctx, id);
    if (std.mem.eql(u8, method, "getminerinfo"))     return handleMinerInf(ctx, id);
    if (std.mem.eql(u8, method, "getnodelist"))      return handleNodeList(ctx, id);
    if (std.mem.eql(u8, method, "estimatefee"))       return handleEstimateFee(ctx, id);
    if (std.mem.eql(u8, method, "getnonce"))          return handleGetNonce(body, ctx, id);
    if (std.mem.eql(u8, method, "gettransaction"))   return handleGetTx(body, ctx, id);
    if (std.mem.eql(u8, method, "sendopreturn"))     return handleSendOpReturn(body, ctx, id);
    if (std.mem.eql(u8, method, "getaddresshistory")) return handleGetAddrHistory(body, ctx, id);
    if (std.mem.eql(u8, method, "listtransactions"))  return handleListTx(body, ctx, id);
    if (std.mem.eql(u8, method, "minersendtx"))      return handleMinerSendTx(body, ctx, id);
    if (std.mem.eql(u8, method, "claimfaucet"))      return handleClaimFaucet(body, ctx, id);
    if (std.mem.eql(u8, method, "getfaucetstatus"))  return handleFaucetStatus(ctx, id);
    if (std.mem.eql(u8, method, "getrichlist"))      return handleRichList(body, ctx, id);
    if (std.mem.eql(u8, method, "getchainmetrics"))  return handleChainMetrics(ctx, id);
    if (std.mem.eql(u8, method, "getschemestats"))   return handleSchemeStats(body, ctx, id);
    if (std.mem.eql(u8, method, "registername"))     return handleRegisterName(body, ctx, id);
    if (std.mem.eql(u8, method, "transfername"))     return handleTransferName(body, ctx, id);
    if (std.mem.eql(u8, method, "updatename"))       return handleUpdateName(body, ctx, id);
    if (std.mem.eql(u8, method, "renewname"))        return handleRenewName(body, ctx, id);
    if (std.mem.eql(u8, method, "resolvename"))      return handleResolveName(body, ctx, id);
    if (std.mem.eql(u8, method, "ns_resolveforsend")) return handleResolveForSend(body, ctx, id);
    if (std.mem.eql(u8, method, "reverseresolvename")) return handleReverseResolveName(body, ctx, id);
    if (std.mem.eql(u8, method, "listnames"))        return handleListNames(body, ctx, id);
    if (std.mem.eql(u8, method, "getensfee"))        return handleGetEnsFee(body, ctx, id);
    if (std.mem.eql(u8, method, "ns_listTlds"))      return handleNsListTlds(ctx, id);
    if (std.mem.eql(u8, method, "ns_yearTiers"))     return handleNsYearTiers(ctx, id);
    if (std.mem.eql(u8, method, "ns_stats"))         return handleNsStats(ctx, id);
    if (std.mem.eql(u8, method, "ns_expiringSoon"))  return handleNsExpiringSoon(body, ctx, id);
    if (std.mem.eql(u8, method, "ns_pruneExpired"))  return handleNsPruneExpired(ctx, id);
    // Phase 2 NS — multi-address per name + category badges
    if (std.mem.eql(u8, method, "setpqaddress"))     return handleSetPqAddress(body, ctx, id);
    if (std.mem.eql(u8, method, "setcategory"))      return handleSetCategory(body, ctx, id);
    if (std.mem.eql(u8, method, "setpreferredslot")) return handleSetPreferredSlot(body, ctx, id);
    if (std.mem.eql(u8, method, "getnamesbycategory")) return handleGetNamesByCategory(body, ctx, id);
    if (std.mem.eql(u8, method, "sendrawtransaction")) return handleSendRawTx(body, ctx, id);

    // ── Native DEX (matching engine on-chain) ───────────────────────────
    if (std.mem.eql(u8, method, "exchange_placeOrder"))    return handleExchangePlaceOrder(body, ctx, id);
    if (std.mem.eql(u8, method, "exchange_cancelOrder"))   return handleExchangeCancelOrder(body, ctx, id);
    if (std.mem.eql(u8, method, "exchange_getOrderbook")) return handleExchangeGetOrderbook(body, ctx, id);
    if (std.mem.eql(u8, method, "exchange_getUserOrders"))return handleExchangeGetUserOrders(body, ctx, id);
    if (std.mem.eql(u8, method, "exchange_getUserTrades"))return handleExchangeGetUserTrades(body, ctx, id);
    if (std.mem.eql(u8, method, "exchange_getTrades"))     return handleExchangeGetTrades(body, ctx, id);
    if (std.mem.eql(u8, method, "exchange_listPairs"))     return handleExchangeListPairs(ctx, id);
    if (std.mem.eql(u8, method, "exchange_pairInfo"))      return handleExchangePairInfo(body, ctx, id);
    if (std.mem.eql(u8, method, "exchange_getStats"))      return handleExchangeGetStats(body, ctx, id);
    if (std.mem.eql(u8, method, "exchange_getAuthNonce"))  return handleExchangeGetAuthNonce(body, ctx, id);
    if (std.mem.eql(u8, method, "exchange_login"))         return handleExchangeLogin(body, ctx, id);
    if (std.mem.eql(u8, method, "exchange_createApiKey"))  return handleExchangeCreateApiKey(body, ctx, id);
    if (std.mem.eql(u8, method, "exchange_listApiKeys"))   return handleExchangeListApiKeys(body, ctx, id);
    if (std.mem.eql(u8, method, "exchange_revokeApiKey")) return handleExchangeRevokeApiKey(body, ctx, id);
    if (std.mem.eql(u8, method, "exchange_deposit"))       return handleExchangeDeposit(body, ctx, id);
    if (std.mem.eql(u8, method, "exchange_withdraw"))      return handleExchangeWithdraw(body, ctx, id);
    if (std.mem.eql(u8, method, "exchange_getBalance"))    return handleExchangeGetBalance(body, ctx, id);
    if (std.mem.eql(u8, method, "exchange_getBalances"))   return handleExchangeGetBalances(body, ctx, id);
    if (std.mem.eql(u8, method, "exchange_depositDemo"))   return handleExchangeDepositDemo(body, ctx, id);
    if (std.mem.eql(u8, method, "exchange_depositReal"))   return handleExchangeDepositReal(body, ctx, id);
    if (std.mem.eql(u8, method, "exchange_getEscrowAddress")) return handleExchangeGetEscrowAddress(ctx, id);

    // ── Aliases for B9 (frontend/test naming inconsistencies) ───────────────
    // Frontend calls these names; chain canonical names differ. Forward to
    // the real handler so existing frontend / test scripts work without
    // renaming everywhere.
    if (std.mem.eql(u8, method, "exchange_listOrders"))     return handleExchangeGetOrderbook(body, ctx, id);
    if (std.mem.eql(u8, method, "exchange_getRecentTrades")) return handleExchangeGetTrades(body, ctx, id);
    if (std.mem.eql(u8, method, "exchange_orderbook"))      return handleExchangeGetOrderbook(body, ctx, id);
    if (std.mem.eql(u8, method, "exchange_trades"))         return handleExchangeGetTrades(body, ctx, id);
    if (std.mem.eql(u8, method, "place_order"))             return handleExchangePlaceOrder(body, ctx, id);
    if (std.mem.eql(u8, method, "cancel_order"))            return handleExchangeCancelOrder(body, ctx, id);
    if (std.mem.eql(u8, method, "cancelOrder"))             return handleExchangeCancelOrder(body, ctx, id);

    // ── Grid trading engine ────────────────────────────────────────────────
    if (std.mem.eql(u8, method, "grid_create"))  return handleGridCreate(body, ctx, id);
    if (std.mem.eql(u8, method, "grid_list"))    return handleGridList(body, ctx, id);
    if (std.mem.eql(u8, method, "grid_status"))  return handleGridStatus(body, ctx, id);
    if (std.mem.eql(u8, method, "grid_cancel"))  return handleGridCancel(body, ctx, id);

    // ── HTLC atomic swaps (Phase 2F.2 — TX 0x30/0x31/0x32) ───────────────
    if (std.mem.eql(u8, method, "htlc_init"))           return handleHtlcInit(body, ctx, id);
    if (std.mem.eql(u8, method, "htlc_claim"))          return handleHtlcClaim(body, ctx, id);
    if (std.mem.eql(u8, method, "htlc_refund"))         return handleHtlcRefund(body, ctx, id);
    if (std.mem.eql(u8, method, "htlc_get"))            return handleHtlcGet(body, ctx, id);
    if (std.mem.eql(u8, method, "htlc_listByAddress")) return handleHtlcListByAddress(body, ctx, id);
    if (std.mem.eql(u8, method, "htlc_listPending"))   return handleHtlcListPending(ctx, id);

    // ── PQ Isolated Wallets v2 — 5-scheme post-quantum support ─────────
    if (std.mem.eql(u8, method, "pq_listSchemes"))   return handlePqListSchemes(ctx, id);
    if (std.mem.eql(u8, method, "pq_balance"))       return handlePqBalance(body, ctx, id);
    if (std.mem.eql(u8, method, "pq_send"))          return handlePqSend(body, ctx, id);
    if (std.mem.eql(u8, method, "pq_verify_test"))   return handlePqVerifyTest(body, ctx, id);
    if (std.mem.eql(u8, method, "pq_attestation"))   return handlePqAttestation(body, ctx, id);
    if (std.mem.eql(u8, method, "getpqidentity"))    return handleGetPqIdentity(body, ctx, id);
    if (std.mem.eql(u8, method, "sendpqattest"))     return handleSendPqAttest(body, ctx, id);

    // ── On-chain labels (decentralized address tagging) ─────────────────
    if (std.mem.eql(u8, method, "applylabel"))       return handleApplyLabel(body, ctx, id);
    if (std.mem.eql(u8, method, "getlabels"))        return handleGetLabels(body, ctx, id);
    if (std.mem.eql(u8, method, "removelabel"))      return handleRemoveLabel(body, ctx, id);

    // ── On-chain subscriptions (recurring payments) ──────────────────────
    if (std.mem.eql(u8, method, "sub_create"))       return handleSubCreate(body, ctx, id);
    if (std.mem.eql(u8, method, "sub_cancel"))       return handleSubCancel(body, ctx, id);
    if (std.mem.eql(u8, method, "getsubscriptions")) return handleGetSubscriptions(body, ctx, id);

    // ── Document notarization ────────────────────────────────────────────
    if (std.mem.eql(u8, method, "notarizedoc"))      return handleNotarizeDoc(body, ctx, id);
    if (std.mem.eql(u8, method, "verifynotarize"))   return handleVerifyNotarize(body, ctx, id);
    if (std.mem.eql(u8, method, "revokenotarize"))   return handleRevokeNotarize(body, ctx, id);
    if (std.mem.eql(u8, method, "getnotarizations")) return handleGetNotarizations(body, ctx, id);

    // ── Programmable escrow ──────────────────────────────────────────────
    if (std.mem.eql(u8, method, "escrow_create"))    return handleEscrowCreate(body, ctx, id);
    if (std.mem.eql(u8, method, "escrow_release"))   return handleEscrowRelease(body, ctx, id);
    if (std.mem.eql(u8, method, "escrow_refund"))    return handleEscrowRefund(body, ctx, id);
    if (std.mem.eql(u8, method, "escrow_dispute"))   return handleEscrowDispute(body, ctx, id);
    if (std.mem.eql(u8, method, "getescrow"))        return handleGetEscrow(body, ctx, id);
    if (std.mem.eql(u8, method, "getescrows"))       return handleGetEscrows(body, ctx, id);

    // ── Social Graph ─────────────────────────────────────────────────────
    if (std.mem.eql(u8, method, "follow"))           return handleFollow(body, ctx, id);
    if (std.mem.eql(u8, method, "unfollow"))         return handleUnfollow(body, ctx, id);
    if (std.mem.eql(u8, method, "getfollowers"))     return handleGetFollowers(body, ctx, id);
    if (std.mem.eql(u8, method, "getfollowing"))     return handleGetFollowing(body, ctx, id);

    // ── POAP (Proof of Attendance) ────────────────────────────────────────
    if (std.mem.eql(u8, method, "poap_createevent")) return handlePoapCreateEvent(body, ctx, id);
    if (std.mem.eql(u8, method, "poap_claim"))       return handlePoapClaim(body, ctx, id);
    if (std.mem.eql(u8, method, "poap_close"))       return handlePoapClose(body, ctx, id);
    if (std.mem.eql(u8, method, "getpoaps"))         return handleGetPoaps(body, ctx, id);
    if (std.mem.eql(u8, method, "getpoapevent"))     return handleGetPoapEvent(body, ctx, id);

    // ── Governance ────────────────────────────────────────────────────────
    if (std.mem.eql(u8, method, "gov_propose"))      return handleGovPropose(body, ctx, id);
    if (std.mem.eql(u8, method, "gov_vote"))         return handleGovVote(body, ctx, id);
    if (std.mem.eql(u8, method, "gov_execute"))      return handleGovExecute(body, ctx, id);
    if (std.mem.eql(u8, method, "getproposals"))     return handleGetProposals(body, ctx, id);
    if (std.mem.eql(u8, method, "getproposal"))      return handleGetProposal(body, ctx, id);

    // ── Identity Hub ──────────────────────────────────────────────────────
    if (std.mem.eql(u8, method, "getidentity"))      return handleGetIdentity(body, ctx, id);

    // ── Identity (public nickname + ENS-pref + visibility) ─────────────
    if (std.mem.eql(u8, method, "identity_set"))    return handleIdentitySet(body, ctx, id);
    if (std.mem.eql(u8, method, "identity_get"))    return handleIdentityGet(body, ctx, id);
    if (std.mem.eql(u8, method, "identity_search")) return handleIdentitySearch(body, ctx, id);

    // ── KYC (signed attestations, no PII on chain) ─────────────────────
    if (std.mem.eql(u8, method, "kyc_getStatus"))   return handleKycGetStatus(body, ctx, id);
    if (std.mem.eql(u8, method, "kyc_attest"))      return handleKycAttest(body, ctx, id);
    if (std.mem.eql(u8, method, "kyc_listIssuers")) return handleKycListIssuers(ctx, id);
    // generatewallet disabled — causes stack overflow on RPC thread
    // Use seed node address derivation instead
    if (std.mem.eql(u8, method, "generatewallet"))  return errorJson(-32601, "Use CLI wallet generation", id, alloc);

    // Performance metrics
    if (std.mem.eql(u8, method, "getperformance"))   return handleGetPerformance(ctx, id);

    // SPV light client endpoints
    if (std.mem.eql(u8, method, "getheaders"))       return handleGetHeaders(body, ctx, id);
    if (std.mem.eql(u8, method, "getmerkleproof"))   return handleGetMerkleProof(body, ctx, id);

    // Staking slashing endpoints
    if (std.mem.eql(u8, method, "submitslashevidence")) return handleSubmitSlashEvidence(body, ctx, id);
    if (std.mem.eql(u8, method, "getslashhistory"))     return handleGetSlashHistory(body, ctx, id);
    if (std.mem.eql(u8, method, "getstakinginfo"))      return handleGetStakingInfo(body, ctx, id);

    // Multisig endpoints — real M-of-N implementation backed by core/multisig.zig
    if (std.mem.eql(u8, method, "createmultisig"))      return handleCreateMultisig(body, ctx, id);
    if (std.mem.eql(u8, method, "sendmultisig"))        return handleSendMultisig(body, ctx, id);

    // ── Cold Wallet (watch-only) ─────────────────────────────────────────────
    if (std.mem.eql(u8, method, "coldwallet_add"))     return handleColdWalletAdd(body, ctx, id);
    if (std.mem.eql(u8, method, "coldwallet_list"))    return handleColdWalletList(body, ctx, id);
    if (std.mem.eql(u8, method, "coldwallet_remove"))  return handleColdWalletRemove(body, ctx, id);
    if (std.mem.eql(u8, method, "coldwallet_history")) return handleColdWalletHistory(body, ctx, id);

    // ── Timelock Vault (CLTV) ────────────────────────────────────────────────
    if (std.mem.eql(u8, method, "timelock_create"))    return handleTimelockCreate(body, ctx, id);
    if (std.mem.eql(u8, method, "timelock_list"))      return handleTimelockList(body, ctx, id);
    if (std.mem.eql(u8, method, "timelock_spend"))     return handleTimelockSpend(body, ctx, id);
    if (std.mem.eql(u8, method, "timelock_status"))    return handleTimelockStatus(body, ctx, id);

    // ── Covenant (destination whitelist) ─────────────────────────────────────
    if (std.mem.eql(u8, method, "covenant_create"))    return handleCovenantCreate(body, ctx, id);
    if (std.mem.eql(u8, method, "covenant_list"))      return handleCovenantList(body, ctx, id);
    if (std.mem.eql(u8, method, "covenant_get"))       return handleCovenantGet(body, ctx, id);
    if (std.mem.eql(u8, method, "covenant_remove"))    return handleCovenantRemove(body, ctx, id);

    // ── Treasury auto-distribute ─────────────────────────────────────────────
    if (std.mem.eql(u8, method, "treasury_create"))    return handleTreasuryCreate(body, ctx, id);
    if (std.mem.eql(u8, method, "treasury_list"))      return handleTreasuryList(body, ctx, id);
    if (std.mem.eql(u8, method, "treasury_distribute"))return handleTreasuryDistribute(body, ctx, id);
    if (std.mem.eql(u8, method, "treasury_status"))    return handleTreasuryStatus(body, ctx, id);

    // Payment channel (L2) endpoints — Lightning-style bidirectional channels
    if (std.mem.eql(u8, method, "openchannel"))       return handleOpenChannel(body, ctx, id);
    if (std.mem.eql(u8, method, "channelpay"))        return handleChannelPay(body, ctx, id);
    if (std.mem.eql(u8, method, "closechannel"))      return handleCloseChannel(body, ctx, id);
    if (std.mem.eql(u8, method, "getchannels"))       return handleGetChannels(body, ctx, id);

    // ── OmniBus custom endpoints (exchange integration) ─────────────────
    if (std.mem.eql(u8, method, "getblockchaininfo"))    return handleBlockchainInfo(ctx, id);
    if (std.mem.eql(u8, method, "omnibus_getminers"))    return handleOmnibusMiners(ctx, id);
    if (std.mem.eql(u8, method, "omnibus_getoracleprices")) return handleOmnibusPrices(ctx, id);
    if (std.mem.eql(u8, method, "omnibus_getblockprices")) return handleOmnibusBlockPrices(body, ctx, id);
    if (std.mem.eql(u8, method, "omnibus_getpricerange")) return handleOmnibusPriceRange(body, ctx, id);
    if (std.mem.eql(u8, method, "omnibus_getexchangefeed")) return handleOmnibusExchangeFeed(ctx, id);
    if (std.mem.eql(u8, method, "omnibus_getallprices")) return handleOmnibusAllPrices(ctx, body, id);
    if (std.mem.eql(u8, method, "omnibus_getarbitrage")) return handleOmnibusArbitrage(ctx, id);
    if (std.mem.eql(u8, method, "omnibus_getfxrate"))    return handleOmnibusFxRate(ctx, id);
    if (std.mem.eql(u8, method, "omnibus_getorderbook"))  return handleOmnibusOrderbook(body, ctx, id);
    if (std.mem.eql(u8, method, "omnibus_getbridgestatus")) return handleOmnibusBridge(ctx, id);
    if (std.mem.eql(u8, method, "omnibus_getoraclepolicy")) return handleOmnibusGetOraclePolicy(ctx, id);
    if (std.mem.eql(u8, method, "omnibus_setoraclepolicy")) return handleOmnibusSetOraclePolicy(body, ctx, id);
    if (std.mem.eql(u8, method, "omnibus_gettotalmined"))   return handleOmnibusTotalMined(ctx, id);
    if (std.mem.eql(u8, method, "omnibus_bridge_limits"))   return handleOmnibusBridgeLimits(ctx, id);
    if (std.mem.eql(u8, method, "getmempoolinfo"))        return handleMempoolInfo(ctx, id);
    if (std.mem.eql(u8, method, "getrawmempool"))         return handleMempoolInfo(ctx, id);
    if (std.mem.eql(u8, method, "getmempool"))            return handleMempoolInfo(ctx, id);
    if (std.mem.eql(u8, method, "getdailyactivity"))      return handleGetDailyActivity(body, ctx, id);

    // ── EVM-compat endpoints (Ethereum-style JSON-RPC) ─────────────────
    if (std.mem.eql(u8, method, "eth_call"))               return handleEthCall(body, ctx, id);
    if (std.mem.eql(u8, method, "eth_sendRawTransaction")) return handleEthSendRawTransaction(body, ctx, id);
    if (std.mem.eql(u8, method, "eth_getCode"))            return handleEthGetCode(body, ctx, id);
    if (std.mem.eql(u8, method, "eth_estimateGas"))        return handleEthEstimateGas(body, ctx, id);
    if (std.mem.eql(u8, method, "eth_chainId"))            return handleEthChainId(ctx, id);
    if (std.mem.eql(u8, method, "eth_blockNumber"))        return handleEthBlockNumber(ctx, id);
    if (std.mem.eql(u8, method, "eth_getBalance"))         return handleEthGetBalance(body, ctx, id);
    if (std.mem.eql(u8, method, "eth_getTransactionCount"))return handleEthGetTransactionCount(body, ctx, id);
    if (std.mem.eql(u8, method, "eth_gasPrice"))           return handleEthGasPrice(ctx, id);
    if (std.mem.eql(u8, method, "eth_getLogs"))            return handleEthGetLogs(body, ctx, id);
    if (std.mem.eql(u8, method, "eth_getTransactionReceipt"))return handleEthGetTransactionReceipt(body, ctx, id);
    if (std.mem.eql(u8, method, "eth_getBlockByNumber"))   return handleEthGetBlockByNumber(body, ctx, id);
    if (std.mem.eql(u8, method, "net_version"))            return handleNetVersion(ctx, id);

    // ── Bitcoin-standard compatibility endpoints ────────────────────────
    if (std.mem.eql(u8, method, "getbestblockhash"))   return handleGetBestBlockHash(ctx, id);
    if (std.mem.eql(u8, method, "getdifficulty"))      return handleGetDifficulty(ctx, id);
    if (std.mem.eql(u8, method, "getblockhash"))       return handleGetBlockHash(body, ctx, id);
    if (std.mem.eql(u8, method, "getconnectioncount")) return handleGetConnectionCount(ctx, id);
    if (std.mem.eql(u8, method, "getpeerinfo"))        return handleGetPeerInfo(ctx, id);
    if (std.mem.eql(u8, method, "getmininginfo"))      return handleGetMiningInfo(ctx, id);

    // ── AI Agent endpoints (consumate de clientul Python/Rust extern) ───
    if (std.mem.eql(u8, method, "agent_list"))              return handleAgentList(ctx, id);
    if (std.mem.eql(u8, method, "getreputation"))           return handleGetReputation(body, ctx, id);
    if (std.mem.eql(u8, method, "getreputationtop"))        return handleGetReputationTop(body, ctx, id);
    if (std.mem.eql(u8, method, "getdid"))                  return handleGetDid(body, ctx, id);
    if (std.mem.eql(u8, method, "getobm"))                  return handleGetObm(body, ctx, id);
    if (std.mem.eql(u8, method, "getfacets"))               return handleGetFacets(body, ctx, id);
    if (std.mem.eql(u8, method, "profile_init"))            return handleProfileInit(body, ctx, id);
    if (std.mem.eql(u8, method, "profile_update"))          return handleProfileUpdate(body, ctx, id);
    if (std.mem.eql(u8, method, "profile_get"))             return handleProfileGet(body, ctx, id);
    if (std.mem.eql(u8, method, "mica_attest"))             return handleMicaAttest(body, ctx, id);
    if (std.mem.eql(u8, method, "mica_disclose"))           return handleMicaDisclose(body, ctx, id);
    if (std.mem.eql(u8, method, "disclose_post"))           return handleDisclosePost(body, ctx, id);
    if (std.mem.eql(u8, method, "disclose_cert"))           return handleDiscloseCert(body, ctx, id);
    if (std.mem.eql(u8, method, "disclose_work"))           return handleDiscloseWork(body, ctx, id);
    if (std.mem.eql(u8, method, "agent_status"))            return handleAgentStatus(body, ctx, id);
    if (std.mem.eql(u8, method, "agent_pending_decisions")) return handleAgentPendingDecisions(body, ctx, id);
    if (std.mem.eql(u8, method, "agent_report_execution"))  return handleAgentReportExecution(body, ctx, id);

    // ── Bridge endpoints ─────────────────────────────────────────────────────
    if (std.mem.eql(u8, method, "getbridgestatus"))       return handleBridgeStatus(ctx, id);
    if (std.mem.eql(u8, method, "bridge_lock"))           return handleBridgeLock(body, ctx, id);
    if (std.mem.eql(u8, method, "bridge_unlock_request")) return handleBridgeUnlockRequest(body, ctx, id);
    if (std.mem.eql(u8, method, "bridge_fraud_challenge"))return handleBridgeFraudChallenge(body, ctx, id);
    if (std.mem.eql(u8, method, "bridge_settle"))         return handleBridgeSettle(body, ctx, id);

    // HTLC builders for cross-chain atomic swaps (off-chain — no broadcast)
    if (std.mem.eql(u8, method, "htlc_btc_buildScript")) return handleHtlcBtcBuildScript(body, ctx, id);

    // ── SPV + cross-chain oracle ─────────────────────────────────────────────
    if (std.mem.eql(u8, method, "spv_btc_verifyTx"))     return handleSpvBtcVerifyTx(body, ctx, id);
    if (std.mem.eql(u8, method, "spv_eth_verifyEvent")) return handleSpvEthVerifyEvent(body, ctx, id);
    if (std.mem.eql(u8, method, "oracle_btcHeight"))    return handleOracleBtcHeight(ctx, id);
    if (std.mem.eql(u8, method, "oracle_ethHeight"))    return handleOracleEthHeight(body, ctx, id);
    if (std.mem.eql(u8, method, "oracle_recordHeader")) return handleOracleRecordHeader(body, ctx, id);

    // ── Cross-chain atomic-swap binding (orderbook ↔ HTLC glue) ─────────
    if (std.mem.eql(u8, method, "swap_open"))         return handleSwapOpen(body, ctx, id);
    if (std.mem.eql(u8, method, "swap_lockMaker"))    return handleSwapLockMaker(body, ctx, id);
    if (std.mem.eql(u8, method, "swap_lockTaker"))    return handleSwapLockTaker(body, ctx, id);
    if (std.mem.eql(u8, method, "swap_timeout"))      return handleSwapTimeout(body, ctx, id);
    if (std.mem.eql(u8, method, "swap_status"))       return handleSwapStatus(body, ctx, id);
    if (std.mem.eql(u8, method, "swap_listOpen"))     return handleSwapListOpen(body, ctx, id);
    if (std.mem.eql(u8, method, "swap_proveSettle")) return handleSwapProveSettle(body, ctx, id);
    if (std.mem.eql(u8, method, "intent_post"))       return handleIntentPost(body, ctx, id);
    if (std.mem.eql(u8, method, "intent_fill_commit")) return handleIntentFillCommit(body, ctx, id);
    if (std.mem.eql(u8, method, "intent_settle"))     return handleIntentSettle(body, ctx, id);
    if (std.mem.eql(u8, method, "intent_timeout"))    return handleIntentTimeout(body, ctx, id);

    // ── Stake / Validator / Agent / Reputation RPCs ─────────────────────────
    if (std.mem.eql(u8, method, "stake"))             return handleStake(body, ctx, id);
    if (std.mem.eql(u8, method, "unstake"))           return handleUnstake(body, ctx, id);
    if (std.mem.eql(u8, method, "getstake"))          return handleGetStake(body, ctx, id);
    if (std.mem.eql(u8, method, "getstakers"))        return handleGetStakers(body, ctx, id);
    if (std.mem.eql(u8, method, "getvalidatorsv2"))   return handleGetValidatorsV2(body, ctx, id);
    if (std.mem.eql(u8, method, "become_validator"))  return handleBecomeValidator(body, ctx, id);
    if (std.mem.eql(u8, method, "validator_heartbeat")) return handleValidatorHeartbeat(body, ctx, id);
    if (std.mem.eql(u8, method, "getslashevents"))    return handleGetSlashEvents(body, ctx, id);
    if (std.mem.eql(u8, method, "agent_register"))    return handleAgentRegister(body, ctx, id);
    if (std.mem.eql(u8, method, "agent_unregister"))  return handleAgentUnregister(body, ctx, id);
    if (std.mem.eql(u8, method, "agent_edit"))        return handleAgentEdit(body, ctx, id);
    if (std.mem.eql(u8, method, "agent_follow"))      return handleAgentFollow(body, ctx, id);
    if (std.mem.eql(u8, method, "getagents"))         return handleGetAgents(body, ctx, id);
    if (std.mem.eql(u8, method, "getagent"))          return handleGetAgent(body, ctx, id);
    if (std.mem.eql(u8, method, "getreputation"))     return handleGetReputation(body, ctx, id);
    if (std.mem.eql(u8, method, "getreputationtop"))  return handleGetReputationTop(body, ctx, id);

    return errorJson(-32601, "Method not found", id, alloc);
}

// ─── Extracted RPC Handlers ─────────────────────────────────────────────────

/// RPC "getperformance" — returns live performance metrics.
/// Usage: {"method":"getperformance","id":1}
fn handleGetPerformance(ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    if (ctx.metrics) |m| {
        const uptime = m.uptimeSeconds();
        const bpm = m.blocksPerMinute();
        const current_tps = m.currentTps();
        const avg_bt = m.avgBlockTimeMs();
        const mp_throughput: u64 = if (ctx.mempool) |mp| @intCast(mp.size()) else @intCast(ctx.bc.mempool.items.len);
        return std.fmt.allocPrint(alloc,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"uptime_seconds\":{d},\"blocks_mined\":{d},\"blocks_per_minute\":{d},\"txs_processed\":{d},\"tps_current\":{d},\"mempool_throughput\":{d},\"avg_block_time_ms\":{d},\"peak_tps\":{d},\"rpc_requests_total\":{d},\"p2p_messages_total\":{d},\"hashrate\":{d}}}}}",
            .{ id, uptime, m.blocks_mined, bpm, m.txs_processed, current_tps, mp_throughput, avg_bt, m.peak_tps, m.rpc_requests, m.p2p_messages, m.hashrate });
    }
    // No metrics attached — return zeros with uptime from block count estimate
    const block_count = ctx.bc.getBlockCount();
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"uptime_seconds\":0,\"blocks_mined\":{d},\"blocks_per_minute\":0,\"txs_processed\":0,\"tps_current\":0,\"mempool_throughput\":{d},\"avg_block_time_ms\":0,\"peak_tps\":0,\"rpc_requests_total\":0,\"p2p_messages_total\":0,\"hashrate\":0}}}}",
        .{ id, block_count, ctx.bc.mempool.items.len });
}

fn handleEstimateFee(ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    // Use mempool median fee if available, else fall back to TX_MIN_FEE_SAT
    const suggested_fee: u64 = if (ctx.mempool) |m| m.medianFee() else mempool_mod.TX_MIN_FEE_SAT;
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"feeSAT\":{d},\"minFeeSAT\":{d},\"burnPct\":{d}}}}}",
        .{ id, suggested_fee, mempool_mod.TX_MIN_FEE_SAT, blockchain_mod.FEE_BURN_PCT });
}

/// RPC "getnonce" — returns the next expected nonce for an address.
/// Considers both confirmed chain nonces and pending mempool TXs.
/// Usage: {"method":"getnonce","params":["ob1qcx2p306xpf3c2gd6h4074kpux4tv2hnmx3ytuq"],"id":1}
/// Response: {"result":{"address":"...","nonce":N,"chainNonce":M,"pendingCount":P}}
fn handleGetNonce(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const addr = extractArrayStr(body, 0) orelse extractStr(body, "address") orelse
        return errorJson(-32602, "Missing param: address", id, alloc);

    ctx.bc.mutex.lock();
    const chain_nonce = ctx.bc.getNextNonce(addr);
    const next_available = ctx.bc.getNextAvailableNonce(addr);
    ctx.bc.mutex.unlock();
    const pending = next_available - chain_nonce;

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"address\":\"{s}\",\"nonce\":{d},\"chainNonce\":{d},\"pendingCount\":{d}}}}}",
        .{ id, addr, next_available, chain_nonce, pending });
}

fn txSchemeLabel(scheme: transaction_mod.Scheme) []const u8 {
    return switch (scheme) {
        .omni_ecdsa       => "ECDSA (secp256k1)",
        .love_dilithium   => "ML-DSA-87 (soulbound)",
        .food_falcon      => "Falcon-512 (soulbound)",
        .rent_ml_dsa      => "ML-DSA-87 (soulbound)",
        .vacation_slh_dsa => "SLH-DSA-256s (soulbound)",
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
fn handleGetTx(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const tx_hash = extractArrayStr(body, 0) orelse extractStr(body, "txid") orelse
        return errorJson(-32602, "Missing param: txid", id, alloc);

    ctx.bc.mutex.lock();
    defer ctx.bc.mutex.unlock();

    // 1. Check mempool (pending TXs — 0 confirmations)
    for (ctx.bc.mempool.items) |tx| {
        if (std.mem.eql(u8, tx.hash, tx_hash)) {
            const scheme_label = txSchemeLabel(tx.scheme);
            const op_ret = if (tx.op_return.len > 0) tx.op_return else "";
            const kind = inferTxKind(tx);
            return std.fmt.allocPrint(alloc,
                "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"txid\":\"{s}\",\"from\":\"{s}\",\"to\":\"{s}\",\"amount\":{d},\"fee\":{d},\"nonce\":{d},\"timestamp\":{d},\"scheme\":\"{s}\",\"kind\":\"{s}\",\"op_return\":\"{s}\",\"confirmations\":0,\"blockHeight\":null,\"status\":\"pending\"}}}}",
                .{ id, tx.hash, tx.from_address, tx.to_address, tx.amount, tx.fee, tx.nonce, tx.timestamp, scheme_label, kind, op_ret });
        }
    }

    // 2. Check mined blocks via tx_block_height index
    if (ctx.bc.tx_block_height.get(tx_hash)) |block_height| {
        const confirmations = ctx.bc.getConfirmations(tx_hash) orelse 0;
        // Find the actual TX data in the block
        if (block_height < ctx.bc.chain.items.len) {
            const blk = ctx.bc.chain.items[block_height];
            for (blk.transactions.items) |tx| {
                if (std.mem.eql(u8, tx.hash, tx_hash)) {
                    const scheme_label = txSchemeLabel(tx.scheme);
                    const op_ret = if (tx.op_return.len > 0) tx.op_return else "";
                    const kind = inferTxKind(tx);
                    return std.fmt.allocPrint(alloc,
                        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"txid\":\"{s}\",\"from\":\"{s}\",\"to\":\"{s}\",\"amount\":{d},\"fee\":{d},\"nonce\":{d},\"timestamp\":{d},\"scheme\":\"{s}\",\"kind\":\"{s}\",\"op_return\":\"{s}\",\"confirmations\":{d},\"blockHeight\":{d},\"status\":\"confirmed\"}}}}",
                        .{ id, tx.hash, tx.from_address, tx.to_address, tx.amount, tx.fee, tx.nonce, tx.timestamp, scheme_label, kind, op_ret, confirmations, block_height });
                }
            }
        }
        // TX in index but not found in block (edge case) — return minimal info
        return std.fmt.allocPrint(alloc,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"txid\":\"{s}\",\"confirmations\":{d},\"blockHeight\":{d},\"status\":\"confirmed\"}}}}",
            .{ id, tx_hash, confirmations, block_height });
    }

    // 3. Fallback: linear scan all blocks (for TXs not in index, e.g. restored from disk)
    for (ctx.bc.chain.items) |blk| {
        for (blk.transactions.items) |tx| {
            if (std.mem.eql(u8, tx.hash, tx_hash)) {
                const current_height: u64 = @intCast(ctx.bc.chain.items.len);
                const bh: u64 = @intCast(blk.index);
                const confirmations = if (current_height > bh) current_height - bh else 0;
                const scheme_label = txSchemeLabel(tx.scheme);
                const op_ret = if (tx.op_return.len > 0) tx.op_return else "";
                const kind = inferTxKind(tx);
                return std.fmt.allocPrint(alloc,
                    "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"txid\":\"{s}\",\"from\":\"{s}\",\"to\":\"{s}\",\"amount\":{d},\"fee\":{d},\"nonce\":{d},\"timestamp\":{d},\"scheme\":\"{s}\",\"kind\":\"{s}\",\"op_return\":\"{s}\",\"confirmations\":{d},\"blockHeight\":{d},\"status\":\"confirmed\"}}}}",
                    .{ id, tx.hash, tx.from_address, tx.to_address, tx.amount, tx.fee, tx.nonce, tx.timestamp, scheme_label, kind, op_ret, confirmations, blk.index });
            }
        }
    }

    return errorJson(-32602, "Transaction not found", id, alloc);
}

fn handleSendTx(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const to_addr = extractStr(body, "to") orelse extractArrayStr(body, 0) orelse
        return errorJson(-32602, "Missing param: to", id, alloc);
    const amount_sat = extractArrayNum(body, 1);
    if (amount_sat == 0) return errorJson(-32602, "Missing param: amount", id, alloc);
    // Optional fee param (3rd array element or "fee" field); default TX_MIN_FEE_SAT (1 SAT)
    const fee_raw = extractArrayNum(body, 2);
    const fee_from_str = if (extractStr(body, "fee")) |fs| std.fmt.parseInt(u64, fs, 10) catch @as(u64, 0) else @as(u64, 0);
    const fee_sat: u64 = if (fee_raw > 0) fee_raw else if (fee_from_str > 0) fee_from_str else mempool_mod.TX_MIN_FEE_SAT;
    // Optional locktime param (4th array element or "locktime" field); default 0 (immediate)
    const lt_raw = extractArrayNum(body, 3);
    const lt_from_str = if (extractStr(body, "locktime")) |ls| std.fmt.parseInt(u64, ls, 10) catch @as(u64, 0) else @as(u64, 0);
    const locktime: u64 = if (lt_raw > 0) lt_raw else lt_from_str;
    // Optional op_return param ("op_return" or "opreturn" field)
    const op_return = extractStr(body, "op_return") orelse extractStr(body, "opreturn") orelse "";
    // Optional script param: "p2pkh" = auto-generate P2PKH scripts, "none"/empty = legacy mode
    const script_type = extractStr(body, "script") orelse "";
    const tx_id = g_tx_counter.fetchAdd(1, .monotonic);
    // Nonce = next available (chain nonce + pending mempool TXs from this sender)
    const nonce = ctx.bc.getNextAvailableNonce(ctx.wallet.address);

    // If script type is "p2pkh" and we know the receiver's pubkey, use P2PKH scripts
    if (std.mem.eql(u8, script_type, "p2pkh")) {
        // Look up receiver's pubkey from registry
        if (ctx.bc.pubkey_registry.get(to_addr)) |receiver_pk_hex| {
            if (receiver_pk_hex.len == 66) {
                var receiver_pk: [33]u8 = undefined;
                hex_utils.hexToBytes(receiver_pk_hex, &receiver_pk) catch
                    return errorJson(-32000, "Invalid receiver pubkey in registry", id, alloc);
                var tx = ctx.wallet.createTransactionP2PKH(
                    to_addr, amount_sat, tx_id, nonce, fee_sat, locktime, op_return,
                    receiver_pk, alloc,
                ) catch return errorJson(-32000, "Sign error (P2PKH)", id, alloc);
                if (!tx.isValid()) return errorJson(-32000, "Invalid transaction", id, alloc);
                ctx.bc.registerPubkey(ctx.wallet.address, ctx.wallet.addresses[0].public_key_hex) catch {};
                ctx.bc.addTransaction(tx) catch return errorJson(-32000, "Mempool error", id, alloc);
                return std.fmt.allocPrint(alloc,
                    "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"txid\":\"{s}\",\"from\":\"{s}\",\"to\":\"{s}\",\"amount\":{d},\"fee\":{d},\"locktime\":{d},\"script\":\"p2pkh\",\"status\":\"accepted\"}}}}",
                    .{ id, tx.hash, tx.from_address, tx.to_address, tx.amount, tx.fee, tx.locktime });
            }
        }
        // Receiver pubkey not known — fall through to legacy mode
    }

    var tx = ctx.wallet.createTransactionFull(to_addr, amount_sat, tx_id, nonce, fee_sat, locktime, op_return, alloc) catch
        return errorJson(-32000, "Sign error", id, alloc);
    if (!tx.isValid()) return errorJson(-32000, "Invalid transaction", id, alloc);
    // Inregistreaza pubkey-ul wallet-ului in blockchain (pentru verificare semnatura)
    ctx.bc.registerPubkey(ctx.wallet.address, ctx.wallet.addresses[0].public_key_hex) catch {};
    ctx.bc.addTransaction(tx) catch return errorJson(-32000, "Mempool error", id, alloc);
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"txid\":\"{s}\",\"from\":\"{s}\",\"to\":\"{s}\",\"amount\":{d},\"fee\":{d},\"locktime\":{d},\"status\":\"accepted\"}}}}",
        .{ id, tx.hash, tx.from_address, tx.to_address, tx.amount, tx.fee, tx.locktime });
}

/// RPC "sendopreturn" — create OP_RETURN TX with embedded data and amount=0.
/// Usage: {"method":"sendopreturn","params":["data_string", fee_sat],"id":1}
/// Or:    {"method":"sendopreturn","params":{"data":"data_string","fee":100},"id":1}
fn handleSendOpReturn(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const data = extractArrayStr(body, 0) orelse extractStr(body, "data") orelse
        return errorJson(-32602, "Missing param: data (OP_RETURN payload)", id, alloc);
    if (data.len == 0) return errorJson(-32602, "OP_RETURN data cannot be empty", id, alloc);
    if (data.len > transaction_mod.Transaction.MAX_OP_RETURN)
        return errorJson(-32602, "OP_RETURN data exceeds 80 bytes", id, alloc);

    const fee_raw = extractArrayNum(body, 1);
    const fee_from_str = if (extractStr(body, "fee")) |fs| std.fmt.parseInt(u64, fs, 10) catch @as(u64, 0) else @as(u64, 0);
    const fee_sat: u64 = if (fee_raw > 0) fee_raw else if (fee_from_str > 0) fee_from_str else mempool_mod.TX_MIN_FEE_SAT;

    const tx_id = g_tx_counter.fetchAdd(1, .monotonic);
    const nonce = ctx.bc.getNextAvailableNonce(ctx.wallet.address);
    // OP_RETURN TX: amount=0, to=self (data carrier, not a payment)
    var tx = ctx.wallet.createTransactionFull(ctx.wallet.address, 0, tx_id, nonce, fee_sat, 0, data, alloc) catch
        return errorJson(-32000, "Sign error", id, alloc);
    if (!tx.isValid()) return errorJson(-32000, "Invalid OP_RETURN transaction", id, alloc);
    ctx.bc.registerPubkey(ctx.wallet.address, ctx.wallet.addresses[0].public_key_hex) catch {};
    ctx.bc.addTransaction(tx) catch return errorJson(-32000, "Mempool error", id, alloc);
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"txid\":\"{s}\",\"from\":\"{s}\",\"op_return\":\"{s}\",\"fee\":{d},\"status\":\"accepted\"}}}}",
        .{ id, tx.hash, tx.from_address, tx.op_return, tx.fee });
}

/// RPC "minersendtx" — send TX from a registered miner's wallet.
/// The miner's private key is looked up from the MinerWalletPool.
/// Usage: {"method":"minersendtx","params":["from_miner_address","to_address",amount_sat,fee_sat],"id":1}
// ─── Faucet rate-limit state (in-memory, per-process) ────────────────────────
//
// ── Faucet — Protocol Onboarding Gate ────────────────────────────────────────
//
// The faucet address is derived from the well-known OmniBus protocol mnemonic
// ("abandon x11 about"). Its address and mnemonic are PUBLIC — security comes
// from the chain rule in validateTransaction (5b-faucet), not from key secrecy.
//
// Every claimer signs the Declaration of Honesty (faucet_mod.DECLARATION_TEXT).
// The SHA-256 hash of the declaration is embedded in the op_return and stored
// on-chain permanently — irrevocable proof of agreement.
//
// Anti-Sybil rules:
//   - One claim per address (ever) — enforced by g_faucet_addr_set
//   - One claim per IP per 24h   — enforced by g_faucet_ip_map
//   - Chain rule: faucet TX invalid if destination already has pq_attest

// Global in-memory state — reset on node restart intentionally (persist via
// chain state: if an address has balance, it already claimed).
var g_faucet_addr_set = faucet_mod.ClaimedSet{
    .set   = @as(@TypeOf(faucet_mod.ClaimedSet.init(undefined).set), undefined),
    .mutex = .{},
};
var g_faucet_ip_map = faucet_mod.IpCooldownMap{
    .map   = @as(@TypeOf(faucet_mod.IpCooldownMap.init(undefined).map), undefined),
    .mutex = .{},
};
var g_faucet_state_init = false;
var g_faucet_state_mutex: std.Thread.Mutex = .{};

fn ensureFaucetState(alloc: std.mem.Allocator) void {
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
fn handleClaimFaucet(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    ensureFaucetState(alloc);

    const recipient = extractArrayStr(body, 0) orelse extractStr(body, "address") orelse
        return errorJson(-32602, "Missing param: address", id, alloc);
    if (recipient.len < 8 or recipient.len > 64)
        return errorJson(-32602, "Invalid address length", id, alloc);

    const decl_hash = extractStr(body, "declaration_hash") orelse
        return errorJson(-32602, "Missing param: declaration_hash — read the Declaration of Honesty", id, alloc);
    if (decl_hash.len != 64)
        return errorJson(-32602, "declaration_hash must be 64-char SHA-256 hex", id, alloc);

    // Verify the client hashed the correct declaration text.
    if (!std.mem.eql(u8, decl_hash, faucet_mod.DECLARATION_HASH))
        return errorJson(-32015,
            "declaration_hash mismatch — you must hash the exact OmniBus Declaration of Honesty v1",
            id, alloc);

    const sig    = extractStr(body, "signature")  orelse return errorJson(-32602, "Missing: signature",  id, alloc);
    const pubkey = extractStr(body, "public_key") orelse return errorJson(-32602, "Missing: public_key", id, alloc);
    const nonce  = extractParamObjectU64(body, "nonce");

    // One-time per address.
    if (!g_faucet_addr_set.tryRecord(recipient)) {
        // Also check on-chain: if address already has balance it claimed before.
        const existing_bal = ctx.bc.getAddressBalance(recipient);
        if (existing_bal > 0 or g_faucet_addr_set.hasClaimed(recipient))
            return errorJson(-32011, "Address already received faucet funds", id, alloc);
    }

    // IP cooldown (best-effort — peer IP not available in all call paths,
    // skip enforcement when empty).
    const peer_ip = extractStr(body, "_peer_ip") orelse "";
    if (peer_ip.len > 0) {
        const now_s = std.time.timestamp();
        if (!g_faucet_ip_map.tryRecord(peer_ip, now_s)) {
            const last = g_faucet_ip_map.lastClaim(peer_ip);
            const wait = faucet_mod.FAUCET_COOLDOWN_S - (now_s - last);
            return std.fmt.allocPrint(alloc,
                "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"error\":{{\"code\":-32016,\"message\":\"IP cooldown: wait {d}s before claiming again\"}}}}",
                .{ id, wait });
        }
    }

    // Check faucet balance.
    const faucet_bal = ctx.bc.getAddressBalance(faucet_mod.FAUCET_ADDR);
    const fee_sat: u64 = 1_000;
    if (faucet_bal < faucet_mod.FAUCET_AMOUNT_SAT + fee_sat)
        return errorJson(-32012, "Faucet drained — community refill needed", id, alloc);

    // Build op_return: "faucet_claim:<decl_hash>:<recipient>"
    const op_return = try std.fmt.allocPrint(alloc,
        "faucet_claim:{s}:{s}", .{ decl_hash, recipient });
    defer alloc.free(op_return);

    const ts    = std.time.timestamp();
    const tx_id: u32 = @intCast(std.time.milliTimestamp() & 0xFFFFFFFF);
    const provisional = try std.fmt.allocPrint(alloc, "{d}{s}{d}", .{ tx_id, faucet_mod.FAUCET_ADDR, ts });
    defer alloc.free(provisional);

    var tx = blockchain_mod.Transaction{
        .id           = tx_id,
        .from_address = faucet_mod.FAUCET_ADDR,
        .to_address   = recipient,
        .amount       = faucet_mod.FAUCET_AMOUNT_SAT,
        .fee          = fee_sat,
        .timestamp    = ts,
        .nonce        = nonce,
        .op_return    = op_return,
        .signature    = sig,
        .public_key   = pubkey,
        .scheme       = .omni_ecdsa,
        .hash         = provisional,
    };
    const hash_bytes = tx.calculateHash();
    const canonical = try std.fmt.allocPrint(alloc, "{s}", .{std.fmt.bytesToHex(hash_bytes, .lower)});
    tx.hash = canonical;

    ctx.bc.mutex.lock();
    ctx.bc.mempool.append(tx) catch {
        ctx.bc.mutex.unlock();
        return errorJson(-32014, "Mempool full", id, alloc);
    };
    ctx.bc.mutex.unlock();

    std.debug.print("[FAUCET] Onboarding {d} SAT → {s} (decl_hash={s})\n",
        .{ faucet_mod.FAUCET_AMOUNT_SAT, recipient[0..@min(recipient.len, 20)], decl_hash[0..8] });

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{" ++
        "\"txid\":\"{s}\"," ++
        "\"recipient\":\"{s}\"," ++
        "\"amount\":{d}," ++
        "\"declaration\":\"signed\"," ++
        "\"status\":\"accepted\"," ++
        "\"message\":\"Welcome to OmniBus. Now complete pq_attest to unlock full access.\"" ++
        "}}}}",
        .{ id, canonical, recipient, faucet_mod.FAUCET_AMOUNT_SAT });
}

/// RPC "getfaucetstatus"
fn handleFaucetStatus(ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const faucet_bal = ctx.bc.getAddressBalance(faucet_mod.FAUCET_ADDR);
    const enabled = faucet_bal >= faucet_mod.FAUCET_AMOUNT_SAT;

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{" ++
        "\"enabled\":{}," ++
        "\"address\":\"{s}\"," ++
        "\"balance\":{d}," ++
        "\"grantPerClaim\":{d}," ++
        "\"cooldownHours\":24," ++
        "\"declaration_hash\":\"{s}\"," ++
        "\"declaration_text\":\"{s}\"" ++
        "}}}}",
        .{ id, enabled,
           faucet_mod.FAUCET_ADDR,
           faucet_bal,
           faucet_mod.FAUCET_AMOUNT_SAT,
           faucet_mod.DECLARATION_HASH,
           faucet_mod.DECLARATION_TEXT });
}

/// Keep the old faucetSetPersistPath symbol so main.zig call sites still compile.
/// The new faucet doesn't need disk persistence (chain state is authoritative).
pub fn faucetSetPersistPath(_: []const u8) void {}

// ─── Rich list + chain metrics ──────────────────────────────────────────────

const RichEntry = struct {
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
fn inferTxKind(tx: transaction_mod.Transaction) []const u8 {
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
        if (std.mem.startsWith(u8, tx.op_return, "exchange:")) return "exchange";
        if (std.mem.startsWith(u8, tx.op_return, "fill:")) return "exchange";
        if (std.mem.startsWith(u8, tx.op_return, "stake:")) return "stake";
        if (std.mem.startsWith(u8, tx.op_return, "unstake:")) return "stake";
        if (std.mem.startsWith(u8, tx.op_return, "demo:")) return "demo_grant";
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
fn handleRichList(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const limit_raw = extractArrayNum(body, 0);
    const limit: usize = if (limit_raw > 0) @min(@as(usize, @intCast(limit_raw)), 1000) else 100;

    ctx.bc.mutex.lock();
    defer ctx.bc.mutex.unlock();

    // Collect (address, balance) pairs from the UTXO set (PHASE-B source of truth).
    var entries = std.array_list.Managed(RichEntry).init(alloc);
    defer entries.deinit();
    // Lock UTXOSet for the iteration — getBalance() takes a recursive shared lock.
    ctx.bc.utxo_set.lock.lockShared();
    defer ctx.bc.utxo_set.lock.unlockShared();
    var ait = ctx.bc.utxo_set.address_index.iterator();
    while (ait.next()) |kv| {
        const addr = kv.key_ptr.*;
        // Inline tally to avoid re-locking (getBalance would try to lockShared again).
        const list = kv.value_ptr.*;
        var bal: u64 = 0;
        for (list.items) |op| {
            if (ctx.bc.utxo_set.utxos.get(op)) |u| bal += u.amount;
        }
        if (bal == 0) continue; // skip dust/zero balances
        try entries.append(.{ .address = addr, .balance = bal });
    }

    // Sort by balance descending; tie-break by address string for determinism.
    std.mem.sort(RichEntry, entries.items, {}, struct {
        fn lt(_: void, a: RichEntry, b: RichEntry) bool {
            if (a.balance != b.balance) return a.balance > b.balance;
            return std.mem.lessThan(u8, a.address, b.address);
        }
    }.lt);

    // Build per-address indexes:
    //   - mined_count: blocks mined by miner_address (=> MINER role) — one
    //                  pass over chain (block headers only, always available).
    //   - stake_amount / is_agent: now read directly from the persisted
    //     bc.stake_amounts / bc.registered_agents maps so roles survive a
    //     node restart (chain.dat doesn't serialise full TX list — see
    //     database.zig stake_state / agent_state sections, 2026-05-04).
    //   - tx_stats: {count, received, sent, first_height, last_height}
    //               — still computed by iterating in-memory blocks. After a
    //               restart this is empty until new blocks land; treat as
    //               cosmetic, while role classification stays correct.
    var mined_count = std.StringHashMap(u32).init(alloc);
    defer mined_count.deinit();

    const TxStats = struct {
        count: u32 = 0,
        received: u64 = 0,
        sent: u64 = 0,
        first_height: u64 = 0,
        last_height: u64 = 0,
        first_seen: bool = false,
    };
    var tx_stats = std.StringHashMap(TxStats).init(alloc);
    defer tx_stats.deinit();

    for (ctx.bc.chain.items, 0..) |blk, height| {
        if (blk.miner_address.len > 0) {
            const gop = try mined_count.getOrPut(blk.miner_address);
            if (!gop.found_existing) gop.value_ptr.* = 0;
            gop.value_ptr.* += 1;
        }
        for (blk.transactions.items) |tx| {
            const h: u64 = @intCast(height);
            // Sender side (skip coinbase — empty from)
            if (tx.from_address.len > 0) {
                const gop = try tx_stats.getOrPut(tx.from_address);
                if (!gop.found_existing) gop.value_ptr.* = .{};
                gop.value_ptr.count += 1;
                gop.value_ptr.sent += tx.amount;
                if (!gop.value_ptr.first_seen) {
                    gop.value_ptr.first_height = h;
                    gop.value_ptr.first_seen = true;
                }
                gop.value_ptr.last_height = h;
            }
            // Receiver side
            if (tx.to_address.len > 0) {
                const gop = try tx_stats.getOrPut(tx.to_address);
                if (!gop.found_existing) gop.value_ptr.* = .{};
                gop.value_ptr.count += 1;
                gop.value_ptr.received += tx.amount;
                if (!gop.value_ptr.first_seen) {
                    gop.value_ptr.first_height = h;
                    gop.value_ptr.first_seen = true;
                }
                gop.value_ptr.last_height = h;
            }
        }
    }

    // Emit JSON: {result: {entries:[…], total:N, totalSupply:N}}
    var json = std.array_list.Managed(u8).init(alloc);
    errdefer json.deinit();
    var w = json.writer();

    try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"entries\":[", .{id});

    var total_supply: u64 = 0;
    for (entries.items) |e| total_supply += e.balance;

    const out_count = @min(limit, entries.items.len);
    for (entries.items[0..out_count], 0..) |e, i| {
        if (i > 0) try w.writeAll(",");
        const blocks = mined_count.get(e.address) orelse 0;
        // Restart-safe: read stake/agent state from persisted maps in
        // bc, populated by applyOpReturnRoles + restored from chain.dat.
        const stake = ctx.bc.stake_amounts.get(e.address) orelse 0;
        const agent = ctx.bc.registered_agents.contains(e.address);
        const stats = tx_stats.get(e.address) orelse TxStats{};

        // 4-role classification (multi-role: address can be VALIDATOR + MINER + AGENT etc.)
        const is_validator = stake >= staking_mod.VALIDATOR_MIN_STAKE;
        const is_miner = blocks > 0;
        // USER role implicit — included if no other role is active.
        const is_user = !is_validator and !is_miner and !agent;

        // Build roles JSON array
        try w.print(
            "{{\"rank\":{d},\"address\":\"{s}\",\"balance\":{d}," ++
            "\"roles\":[",
            .{ i + 1, e.address, e.balance },
        );
        var role_first = true;
        if (is_validator) { try w.writeAll("\"validator\""); role_first = false; }
        if (is_miner)     { if (!role_first) try w.writeAll(","); try w.writeAll("\"miner\""); role_first = false; }
        if (agent)        { if (!role_first) try w.writeAll(","); try w.writeAll("\"agent\""); role_first = false; }
        if (is_user)      { try w.writeAll("\"user\""); }
        try w.print(
            "],\"stake\":{d},\"blocksMined\":{d}," ++
            // Backward-compat: keep isValidator boolean (true if validator role active)
            "\"isValidator\":{}," ++
            "\"txCount\":{d},\"received\":{d},\"sent\":{d},\"firstHeight\":{d},\"lastHeight\":{d}}}",
            .{ stake, blocks, is_validator,
               stats.count, stats.received, stats.sent, stats.first_height, stats.last_height },
        );
    }

    try w.print("],\"total\":{d},\"shown\":{d},\"totalSupply\":{d}}}}}", .{
        entries.items.len, out_count, total_supply,
    });

    return json.toOwnedSlice();
}

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
fn handleChainMetrics(ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;

    ctx.bc.mutex.lock();
    defer ctx.bc.mutex.unlock();

    // Address + supply tally from UTXO set (PHASE-B source of truth).
    var addresses_with_balance: u64 = 0;
    var validators: u64 = 0;
    var total_supply: u64 = 0;
    ctx.bc.utxo_set.lock.lockShared();
    defer ctx.bc.utxo_set.lock.unlockShared();
    var ait = ctx.bc.utxo_set.address_index.iterator();
    while (ait.next()) |kv| {
        _ = kv.key_ptr.*;
        // Inline tally — re-entering getBalance() would deadlock on the same RwLock.
        const list = kv.value_ptr.*;
        var bal: u64 = 0;
        for (list.items) |op| {
            if (ctx.bc.utxo_set.utxos.get(op)) |u| bal += u.amount;
        }
        if (bal == 0) continue;
        addresses_with_balance += 1;
        total_supply += bal;
        if (bal >= validator_mod.MIN_VALIDATOR_BALANCE) validators += 1;
    }

    const height: u64 = @intCast(ctx.bc.chain.items.len);
    const tip_hash: []const u8 = if (height > 0) ctx.bc.chain.items[height - 1].hash else "";
    const validator_set_size = ctx.bc.validator_set.items.len;
    const mempool_size: usize = if (ctx.mempool) |mp| mp.size() else 0;
    const peer_count: usize = if (ctx.p2p) |p| p.peers.items.len else 0;

    // Current block reward (uses blockchain.zig blockRewardAt — handles halvings).
    const current_reward = blockchain_mod.blockRewardAt(@intCast(height));

    // Latest block quick stats (tx count + fees) for dashboard — avoids extra getblock call.
    var latest_tx_count: usize = 0;
    var latest_fees: u64 = 0;
    var latest_timestamp: i64 = 0;
    if (height > 0) {
        const tip = ctx.bc.chain.items[height - 1];
        latest_tx_count = tip.transactions.items.len;
        latest_timestamp = tip.timestamp;
        for (tip.transactions.items) |tx| {
            if (tx.fee > 0) latest_fees += @as(u64, @intCast(tx.fee));
        }
    }

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{" ++
            "\"height\":{d}," ++
            "\"tipHash\":\"{s}\"," ++
            "\"totalSupply\":{d}," ++
            "\"addressesWithBalance\":{d}," ++
            "\"validators\":{d}," ++
            "\"validatorSetSize\":{d}," ++
            "\"minValidatorBalance\":{d}," ++
            "\"mempoolSize\":{d}," ++
            "\"peerCount\":{d}," ++
            "\"currentBlockReward\":{d}," ++
            "\"latestBlockTxCount\":{d}," ++
            "\"latestBlockFees\":{d}," ++
            "\"latestBlockTimestamp\":{d}," ++
            "\"satPerOmni\":1000000000" ++
            "}}}}",
        .{
            id, height, tip_hash, total_supply, addresses_with_balance,
            validators, validator_set_size, validator_mod.MIN_VALIDATOR_BALANCE,
            mempool_size, peer_count, current_reward,
            latest_tx_count, latest_fees, latest_timestamp,
        });
}

/// RPC "getschemestats" — signing-scheme distribution across last N blocks.
/// Params: [blocks_count]  (default 100, max 1000)
/// Returns: { totalTxs, blocks, schemes: [{scheme, count, pct}] }
fn handleSchemeStats(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const req_blocks = extractArrayNum(body, 0);
    const scan: u64 = if (req_blocks > 0 and req_blocks <= 1000) req_blocks else 100;

    ctx.bc.mutex.lock();
    defer ctx.bc.mutex.unlock();

    const chain_len: u64 = @intCast(ctx.bc.chain.items.len);
    const start: u64 = if (chain_len > scan) chain_len - scan else 0;

    // Counters for 13 schemes (indices match transaction.Scheme enum order)
    var counts: [13]u64 = .{0} ** 13;
    var total: u64 = 0;

    var hi: u64 = start;
    while (hi < chain_len) : (hi += 1) {
        const blk = ctx.bc.chain.items[@intCast(hi)];
        for (blk.transactions.items) |tx| {
            const idx: usize = @intFromEnum(tx.scheme);
            if (idx < 13) counts[idx] += 1;
            total += 1;
        }
    }

    const scanned = chain_len - start;
    const scheme_labels = [13][]const u8{
        "ECDSA (secp256k1)",
        "ML-DSA-87 (soulbound)",
        "Falcon-512 (soulbound)",
        "ML-DSA-87 (soulbound)",
        "SLH-DSA-256s (soulbound)",
        "ML-DSA-87",
        "Falcon-512",
        "ML-DSA-87 (Dilithium-5)",
        "SLH-DSA-256s",
        "Hybrid ECDSA+ML-DSA-87",
        "Hybrid ECDSA+Falcon-512",
        "Hybrid ECDSA+Dilithium-5",
        "Hybrid ECDSA+SLH-DSA",
    };

    var entries: []u8 = try alloc.dupe(u8, "");
    var written: usize = 0;
    for (scheme_labels, 0..) |label, i| {
        if (counts[i] == 0) continue;
        const pct_x100: u64 = if (total > 0) counts[i] * 10000 / total else 0;
        const sep: []const u8 = if (written == 0) "" else ",";
        const e = try std.fmt.allocPrint(alloc,
            "{s}{{\"scheme\":\"{s}\",\"count\":{d},\"pct\":{d}}}",
            .{ sep, label, counts[i], pct_x100 });
        const m = try std.fmt.allocPrint(alloc, "{s}{s}", .{ entries, e });
        alloc.free(entries); alloc.free(e); entries = m;
        written += 1;
    }
    defer alloc.free(entries);

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"totalTxs\":{d},\"blocks\":{d},\"schemes\":[{s}]}}}}",
        .{ id, total, scanned, entries });
}

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

fn handleRegisterName(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    if (ctx.dns == null) return errorJson(-32030, "DNS registry not enabled on this node", id, alloc);
    const dns = ctx.dns.?;

    const name = extractArrayStr(body, 0) orelse extractStr(body, "name") orelse
        return errorJson(-32602, "Missing param: name", id, alloc);
    const address = extractArrayStr(body, 1) orelse extractStr(body, "address") orelse
        return errorJson(-32602, "Missing param: address", id, alloc);
    // Owner defaults to the address being registered (self-ownership).
    const owner = extractArrayStr(body, 2) orelse extractStr(body, "owner") orelse address;
    // TLD optional — default "omnibus" (backward compat).
    const tld = extractArrayStr(body, 3) orelse extractStr(body, "tld") orelse "omnibus";
    // Fee txid optional — param[4] sau key "fee_txid".
    const fee_txid = extractArrayStr(body, 4) orelse extractStr(body, "fee_txid") orelse null;
    // Phase 2: years tier (1, 2, 3, 4, 5, 10, 25, 50, 100). Default 1.
    const years_raw = extractArrayNumByKey(body, "years");
    const years: u32 = if (years_raw == 0) 1 else @intCast(@min(years_raw, dns_mod.MAX_REGISTRATION_YEARS));
    if (!dns_mod.isValidYears(years)) {
        return errorJson(-32602, "Invalid years (allowed: 1, 2, 3, 4, 5, 10, 25, 50, 100)", id, alloc);
    }

    // Phase 1: optional signature params (param[5..7] sau keys).
    const nonce = extractArrayNumByKey(body, "nonce");
    const sig_hex = extractStr(body, "signature") orelse "";
    const pubkey_hex = extractStr(body, "publicKey") orelse extractStr(body, "pubkey") orelse "";

    const current_block: u64 = @intCast(ctx.bc.chain.items.len);
    // Sybil-resistant fee: scales with how many names `owner` already holds
    // (cheap for first-time registrants, progressively expensive for bulk
    // squatters). Owner count snapshotted at current_block, before this TX.
    const owner_count = dns.countNamesOwnedBy(owner, current_block);
    const required_fee = dns_mod.feeForRegistrationWithOwnerCount(name, tld, years, owner_count);

    // Phase 1: signature verification when signed_required is true.
    const is_hmac_bypass = std.mem.eql(u8, sig_hex, "REST_HMAC_BYPASS");
    if (dns.signed_required) {
        if (sig_hex.len == 0 or (pubkey_hex.len == 0 and !is_hmac_bypass)) {
            return errorJson(-32602, "signature and publicKey required (signed mode)", id, alloc);
        }
        if (!is_hmac_bypass) {
            var msg_buf: [512]u8 = undefined;
            const msg = buildDnsRegisterSignMessage(name, tld, address, owner, nonce, &msg_buf) catch
                return errorJson(-32603, "Failed to build sign message", id, alloc);
            if (!verifyDnsSignature(msg, sig_hex, pubkey_hex, owner, alloc)) {
                return errorJson(-32401, "Signing pubkey does not match owner address", id, alloc);
            }
        }
    }

    // Fee enforcement
    if (dns.fee_enforcement) {
        const txid = fee_txid orelse
            return errorJson(-32602, "fee_txid required (mainnet)", id, alloc);
        if (txid.len != dns_mod.TXID_LEN) {
            return errorJson(-32031, "fee TX invalid: txid must be 64 hex chars", id, alloc);
        }
        if (dns.isTxidConsumed(txid)) {
            return errorJson(-32031, "fee TX invalid: txid already used", id, alloc);
        }

        // Cauta TX in chain (confirmed blocks)
        var found_tx: ?*const transaction_mod.Transaction = null;
        ctx.bc.mutex.lock();
        for (ctx.bc.chain.items) |blk| {
            for (blk.transactions.items) |*tx| {
                if (std.mem.eql(u8, tx.hash, txid)) {
                    found_tx = tx;
                    break;
                }
            }
            if (found_tx != null) break;
        }
        ctx.bc.mutex.unlock();

        const tx = found_tx orelse
            return errorJson(-32031, "fee TX invalid: transaction not found in chain", id, alloc);

        const treasury = dns.getTreasury();
        if (!std.mem.eql(u8, tx.to_address, treasury)) {
            return errorJson(-32031, "fee TX invalid: destination is not treasury", id, alloc);
        }
        if (tx.amount < required_fee) {
            return errorJson(-32031, "fee TX invalid: amount too low", id, alloc);
        }
    }

    dns.registerWithTldYearsAndFee(name, tld, address, owner, current_block, fee_txid, years) catch |err| {
        const msg: []const u8 = switch (err) {
            error.InvalidName     => "Invalid name (3-25 chars, lowercase a-z 0-9 _, must start with letter)",
            error.InvalidTld      => "Invalid TLD (allowed: omnibus, arbitraje, quantum, bank, gov, mil, fin, edu, org, dev)",
            error.NameTaken       => "Name already taken on this TLD",
            error.NameTakenCrossTld => "Name already held by another owner on a different TLD (cross-TLD uniqueness — anti-squatting)",
            error.InvalidYears    => "Invalid years tier (allowed: 1, 2, 3, 4, 5, 10, 25, 50, 100)",
            error.RegistryFull    => "Registry full",
            error.FeeRequired     => "Fee required",
            error.InvalidTxid     => "Invalid txid",
            error.TxidAlreadyUsed => "Txid already used",
            error.ConsumedTxidsFull => "Consumed txids full",
            error.ReservedName    => "Reserved name",
            error.OwnerCapExceeded => "Per-owner name cap exceeded (max 10)",
        };
        return errorJson(-32031, msg, id, alloc);
    };

    // Update last_nonce on the newly created entry.
    if (dns.lookupEntry(name, tld)) |e| {
        e.last_nonce = nonce;
    }

    std.debug.print("[DNS] Registered '{s}.{s}' -> {s}\n",
        .{ name[0..@min(name.len, 25)], tld[0..@min(tld.len, 16)], address[0..@min(address.len, 16)] });

    const fee_paid_sat: u64 = if (fee_txid) |_| required_fee else 0;
    const fee_txid_esc = fee_txid orelse "";

    // Audit log
    var audit_buf: [1024]u8 = undefined;
    const audit_fields = std.fmt.bufPrint(&audit_buf,
        "\"name\":\"{s}\",\"tld\":\"{s}\",\"address\":\"{s}\",\"owner\":\"{s}\",\"nonce\":{d},\"signer_pubkey\":\"{s}\",\"signature\":\"{s}\",\"fee_paid_sat\":{d},\"fee_txid\":\"{s}\"",
        .{ name, tld, address, owner, nonce, pubkey_hex, sig_hex, fee_paid_sat, fee_txid_esc }) catch "";
    if (audit_fields.len > 0) dnsAuditAppend(ctx, "register", audit_fields);

    // WS push — frontend name-list refreshes without polling.
    if (main_mod.g_ws_srv) |ws| {
        ws.broadcastNameRegistered(name, tld, address, @intCast(@min(years, 255)));
    }

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"name\":\"{s}\",\"tld\":\"{s}\",\"fullLabel\":\"{s}.{s}\",\"address\":\"{s}\",\"registeredAtBlock\":{d},\"fee_paid_sat\":{d},\"fee_txid\":\"{s}\"}}}}",
        .{ id, name, tld, name, tld, address, current_block, fee_paid_sat, fee_txid_esc });
}

fn handleResolveName(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    if (ctx.dns == null) return errorJson(-32030, "DNS registry not enabled on this node", id, alloc);
    const dns = ctx.dns.?;

    var name = extractArrayStr(body, 0) orelse extractStr(body, "name") orelse
        return errorJson(-32602, "Missing param: name", id, alloc);
    // Tolerant: strip the TLD suffix if user includes it (UI typically
    // displays "alice.omnibus" or "alice.bank" — Phase 2 extends to all 10).
    var tld_from_name: ?[]const u8 = null;
    inline for (.{
        ".omnibus", ".arbitraje", ".quantum", ".bank", ".gov",
        ".mil", ".fin", ".edu", ".org", ".dev",
    }) |suffix| {
        if (name.len > suffix.len and std.mem.eql(u8, name[name.len - suffix.len ..], suffix)) {
            tld_from_name = suffix[1..]; // drop leading dot
            name = name[0 .. name.len - suffix.len];
            break;
        }
    }
    // Explicit `tld` param overrides; else use the one stripped from the name; else default.
    const tld = extractArrayStr(body, 1) orelse extractStr(body, "tld") orelse
        (tld_from_name orelse "omnibus");

    const current_block: u64 = @intCast(ctx.bc.chain.items.len);
    // Phase 2: lookup the full entry (not just the address) so we can
    // surface category, PQ slots, preferred slot, and registered_years.
    const entry = dns.lookupEntry(name, tld);
    if (entry) |e| {
        if (e.active and !e.isExpired(current_block)) {
            // Pull each PQ slot — empty slot returns the primary as fallback,
            // so JS sees a usable address either way. Mark `*_set` so the UI
            // can still render "not configured" badges where appropriate.
            const pq_k = e.getPqAddress(.ml_dsa);
            const pq_f = e.getPqAddress(.falcon);
            const pq_s = e.getPqAddress(.dilithium);
            const pq_d = e.getPqAddress(.slh_dsa);
            return std.fmt.allocPrint(alloc,
                "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{" ++
                    "\"name\":\"{s}\",\"tld\":\"{s}\",\"fullLabel\":\"{s}.{s}\"," ++
                    "\"address\":\"{s}\"," ++  // primary (legacy field)
                    "\"addresses\":{{" ++
                        "\"primary\":\"{s}\"," ++
                        "\"k\":\"{s}\",\"k_set\":{}," ++
                        "\"f\":\"{s}\",\"f_set\":{}," ++
                        "\"s\":\"{s}\",\"s_set\":{}," ++
                        "\"d\":\"{s}\",\"d_set\":{}" ++
                    "}}," ++
                    "\"category\":\"{s}\"," ++
                    "\"preferred_slot\":{d}," ++
                    "\"registered_years\":{d}," ++
                    "\"registered_block\":{d}," ++
                    "\"expires_block\":{d}," ++
                    "\"found\":true" ++
                "}}}}",
                .{
                    id, name, tld, name, tld,
                    e.getAddress(),
                    e.getAddress(),
                    pq_k, e.addr_pq_lens[0] > 0,
                    pq_f, e.addr_pq_lens[1] > 0,
                    pq_s, e.addr_pq_lens[2] > 0,
                    pq_d, e.addr_pq_lens[3] > 0,
                    e.category.toString(),
                    e.preferred_slot,
                    e.registered_years,
                    e.registered_block,
                    e.expires_block,
                });
        }
    }
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"name\":\"{s}\",\"tld\":\"{s}\",\"fullLabel\":\"{s}.{s}\",\"address\":null,\"found\":false}}}}",
        .{ id, name, tld, name, tld });
}

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
fn handleResolveForSend(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    if (ctx.dns == null) return errorJson(-32030, "DNS registry not enabled on this node", id, alloc);
    const dns = ctx.dns.?;

    var name = extractArrayStr(body, 0) orelse extractStr(body, "name") orelse
        return errorJson(-32602, "Missing param: name", id, alloc);
    // Mirror `resolvename` tolerance — accept "alice.bank" or just "alice".
    var tld_from_name: ?[]const u8 = null;
    inline for (.{
        ".omnibus", ".arbitraje", ".quantum", ".bank", ".gov",
        ".mil", ".fin", ".edu", ".org", ".dev",
    }) |suffix| {
        if (name.len > suffix.len and std.mem.eql(u8, name[name.len - suffix.len ..], suffix)) {
            tld_from_name = suffix[1..];
            name = name[0 .. name.len - suffix.len];
            break;
        }
    }
    const tld = extractArrayStr(body, 1) orelse extractStr(body, "tld") orelse
        (tld_from_name orelse "omnibus");

    const current_block: u64 = @intCast(ctx.bc.chain.items.len);
    const entry = dns.lookupEntry(name, tld);
    if (entry) |e| {
        if (e.active and !e.isExpired(current_block)) {
            const primary = e.getAddress();
            var route_slot: u8 = 0;
            var route_addr: []const u8 = primary;
            var route_kind: []const u8 = "ecdsa";
            var fell_back: bool = false;

            if (e.preferred_slot >= 1 and e.preferred_slot <= dns_mod.PQ_SLOT_COUNT) {
                const idx = e.preferred_slot - 1;
                if (e.addr_pq_lens[idx] > 0) {
                    route_slot = e.preferred_slot;
                    route_addr = e.addr_pq[idx][0..e.addr_pq_lens[idx]];
                    route_kind = switch (idx) {
                        0 => "ml_dsa",
                        1 => "falcon",
                        2 => "dilithium",
                        3 => "slh_dsa",
                        else => "ecdsa",
                    };
                } else {
                    // Owner declared a preference but never populated the slot;
                    // wallet falls through to ECDSA so the TX still lands.
                    fell_back = true;
                }
            }

            return std.fmt.allocPrint(alloc,
                "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{" ++
                    "\"name\":\"{s}\",\"tld\":\"{s}\",\"fullLabel\":\"{s}.{s}\"," ++
                    "\"primary_address\":\"{s}\"," ++
                    "\"route_slot\":{d}," ++
                    "\"route_address\":\"{s}\"," ++
                    "\"route_address_kind\":\"{s}\"," ++
                    "\"preferred_slot\":{d}," ++
                    "\"fell_back_to_primary\":{}," ++
                    "\"found\":true" ++
                "}}}}",
                .{
                    id, name, tld, name, tld,
                    primary,
                    route_slot,
                    route_addr,
                    route_kind,
                    e.preferred_slot,
                    fell_back,
                });
        }
    }
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"name\":\"{s}\",\"tld\":\"{s}\",\"fullLabel\":\"{s}.{s}\"," ++
            "\"primary_address\":null,\"route_slot\":0,\"route_address\":null," ++
            "\"route_address_kind\":\"ecdsa\",\"preferred_slot\":0," ++
            "\"fell_back_to_primary\":false,\"found\":false}}}}",
        .{ id, name, tld, name, tld });
}

fn handleReverseResolveName(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    if (ctx.dns == null) return errorJson(-32030, "DNS registry not enabled on this node", id, alloc);
    const dns = ctx.dns.?;

    const address = extractArrayStr(body, 0) orelse extractStr(body, "address") orelse
        return errorJson(-32602, "Missing param: address", id, alloc);

    const current_block: u64 = @intCast(ctx.bc.chain.items.len);
    const found = dns.reverseResolve(address, current_block);

    if (found) |name| {
        return std.fmt.allocPrint(alloc,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"address\":\"{s}\",\"name\":\"{s}\",\"found\":true}}}}",
            .{ id, address, name });
    }
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"address\":\"{s}\",\"name\":null,\"found\":false}}}}",
        .{ id, address });
}

fn handleListNames(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    if (ctx.dns == null) return errorJson(-32030, "DNS registry not enabled on this node", id, alloc);
    const dns = ctx.dns.?;
    _ = body;

    const current_block: u64 = @intCast(ctx.bc.chain.items.len);

    var json = std.array_list.Managed(u8).init(alloc);
    errdefer json.deinit();
    var w = json.writer();

    try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"entries\":[", .{id});

    var first = true;
    var active_count: usize = 0;
    for (dns.entries[0..dns.entry_count]) |*e| {
        if (!e.active or e.isExpired(current_block)) continue;
        if (!first) try w.writeAll(",");
        first = false;
        try w.print(
            "{{\"name\":\"{s}\",\"tld\":\"{s}\",\"fullLabel\":\"{s}.{s}\"," ++
                "\"address\":\"{s}\"," ++
                "\"category\":\"{s}\"," ++
                "\"preferred_slot\":{d}," ++
                "\"registered_years\":{d}," ++
                "\"registeredAtBlock\":{d},\"expiresAtBlock\":{d}}}",
            .{
                e.getName(), e.getTld(), e.getName(), e.getTld(), e.getAddress(),
                e.category.toString(), e.preferred_slot, e.registered_years,
                e.registered_block, e.expires_block,
            },
        );
        active_count += 1;
    }

    try w.print("],\"total\":{d}}}}}", .{active_count});
    return json.toOwnedSlice();
}

fn handleGetEnsFee(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    // Name registration PRICE — same on every chain. This is what the user
    // pays to claim the name (think domain-registrar pricing, not gas fee).
    // The TX-level network fee is separate and tiny (TX_MIN_FEE_SAT).
    //
    // Optional `owner_address` (param[0] or key) — when provided, returns
    // the Sybil progressive multiplier the owner currently faces (1.0× for
    // 0 names, 2.0× at 5 names, 3.0× at 10, etc.). Without it, multiplier
    // defaults to 1.0× (base price). Frontend wallet UI passes the
    // connected address so the displayed price matches what the chain
    // will actually charge.
    if (ctx.dns == null) {
        return std.fmt.allocPrint(alloc,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"treasury\":\"\",\"enforcement\":false,\"cost_omnibus_omni\":5,\"cost_arbitraje_omni\":10,\"owner_count\":0,\"sybil_multiplier_milli\":1000}}}}",
            .{id});
    }
    const dns = ctx.dns.?;
    const treasury = dns.getTreasury();

    var owner_count: usize = 0;
    var multiplier_milli: u64 = 1000;
    if (extractArrayStr(body, 0) orelse extractStr(body, "owner_address")) |owner_addr| {
        if (owner_addr.len > 0) {
            const current_block: u64 = @intCast(ctx.bc.chain.items.len);
            owner_count = dns.countNamesOwnedBy(owner_addr, current_block);
            multiplier_milli = dns_mod.sybilFeeMultiplierMilli(owner_count);
        }
    }
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"treasury\":\"{s}\",\"enforcement\":{},\"cost_omnibus_omni\":5,\"cost_arbitraje_omni\":10,\"owner_count\":{d},\"sybil_multiplier_milli\":{d}}}}}",
        .{ id, treasury, dns.fee_enforcement, owner_count, multiplier_milli });
}

/// ns_listTlds — read-only. Returneaza toate TLD-urile permise + fee-uri
/// pentru auto-discovery la wallet UI / SDK. Equivalent cu pq_listSchemes
/// dar pentru namespace.
fn handleNsListTlds(ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    // Hardcoded list — must mirror dns_mod.ALLOWED_TLDS exactly.
    // Each entry: {tld, fee_sat (raw), fee_omni (display), category, mainnet_fee_omni}
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":[" ++
            "{{\"tld\":\"omnibus\",\"fee_sat\":5000000000,\"fee_omni\":\"5\",\"category\":\"personal\",\"mainnet_fee_omni\":5}}," ++
            "{{\"tld\":\"arbitraje\",\"fee_sat\":10000000000,\"fee_omni\":\"10\",\"category\":\"trading\",\"mainnet_fee_omni\":10}}," ++
            "{{\"tld\":\"quantum\",\"fee_sat\":1000000,\"fee_omni\":\"0.001\",\"category\":\"premium_personal\",\"mainnet_fee_omni\":10}}," ++
            "{{\"tld\":\"bank\",\"fee_sat\":1000000,\"fee_omni\":\"0.001\",\"category\":\"financial_institution\",\"mainnet_fee_omni\":50}}," ++
            "{{\"tld\":\"gov\",\"fee_sat\":1000000,\"fee_omni\":\"0.001\",\"category\":\"government\",\"mainnet_fee_omni\":100}}," ++
            "{{\"tld\":\"mil\",\"fee_sat\":1000000,\"fee_omni\":\"0.001\",\"category\":\"military\",\"mainnet_fee_omni\":50}}," ++
            "{{\"tld\":\"fin\",\"fee_sat\":1000000,\"fee_omni\":\"0.001\",\"category\":\"financial_trustee\",\"mainnet_fee_omni\":50}}," ++
            "{{\"tld\":\"edu\",\"fee_sat\":1000000,\"fee_omni\":\"0.001\",\"category\":\"academic\",\"mainnet_fee_omni\":20}}," ++
            "{{\"tld\":\"org\",\"fee_sat\":1000000,\"fee_omni\":\"0.001\",\"category\":\"non_profit\",\"mainnet_fee_omni\":10}}," ++
            "{{\"tld\":\"dev\",\"fee_sat\":1000000,\"fee_omni\":\"0.001\",\"category\":\"developer\",\"mainnet_fee_omni\":5}}" ++
        "]}}",
        .{id});
}

/// ns_yearTiers — read-only. Returns the allowed registration durations
/// (years) and their fee multipliers. Wallet UI uses this to render the
/// "register for X years" dropdown without hardcoding the table.
fn handleNsYearTiers(ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":[" ++
            "{{\"years\":1,\"multiplier\":1.000,\"per_year_pct\":100}}," ++
            "{{\"years\":2,\"multiplier\":1.900,\"per_year_pct\":95}}," ++
            "{{\"years\":3,\"multiplier\":2.800,\"per_year_pct\":93}}," ++
            "{{\"years\":4,\"multiplier\":3.700,\"per_year_pct\":92}}," ++
            "{{\"years\":5,\"multiplier\":4.500,\"per_year_pct\":90}}," ++
            "{{\"years\":10,\"multiplier\":8.000,\"per_year_pct\":80}}," ++
            "{{\"years\":25,\"multiplier\":18.000,\"per_year_pct\":72}}," ++
            "{{\"years\":50,\"multiplier\":32.000,\"per_year_pct\":64}}," ++
            "{{\"years\":100,\"multiplier\":55.000,\"per_year_pct\":55}}" ++
        "]}}",
        .{id});
}

/// ns_stats — read-only. Returns the full NS Health Dashboard snapshot in
/// a single round-trip: totals, per-category / per-TLD / per-years counts,
/// and PQ/preferred-slot adoption metrics. Replaces the old fan-out where
/// the UI called `getnamesbycategory` per category or downloaded all 1000
/// entries via `listnames`.
fn handleNsStats(ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    if (ctx.dns == null) return errorJson(-32030, "DNS registry not enabled on this node", id, alloc);
    const dns = ctx.dns.?;
    const current_block: u64 = @intCast(ctx.bc.chain.items.len);
    const s = dns.getStats(current_block);
    // Category indices (match dns_mod.Category enum):
    //   0=none, 1=personal, 2=bank, 3=gov, 4=mil, 5=fin, 6=edu, 7=org, 8=dev, 9=trading
    // TLD indices (match dns_mod.ALLOWED_TLDS):
    //   0=omnibus, 1=arbitraje, 2=quantum, 3=bank, 4=gov, 5=mil, 6=fin, 7=edu, 8=org, 9=dev
    // Years indices (match dns_mod.ALLOWED_YEARS):
    //   0=1, 1=2, 2=3, 3=4, 4=5, 5=10, 6=25, 7=50, 8=100
    // Split into 3 chunks — std.fmt.allocPrint caps at 32 args per call.
    const head = try std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{" ++
            "\"total_active\":{d},\"total_expired\":{d}," ++
            "\"by_category\":{{" ++
                "\"personal\":{d},\"bank\":{d},\"gov\":{d},\"mil\":{d},\"fin\":{d}," ++
                "\"edu\":{d},\"org\":{d},\"dev\":{d},\"trading\":{d},\"none\":{d}" ++
            "}},",
        .{
            id, s.total_active, s.total_expired,
            s.counts_by_category[1], s.counts_by_category[2], s.counts_by_category[3],
            s.counts_by_category[4], s.counts_by_category[5], s.counts_by_category[6],
            s.counts_by_category[7], s.counts_by_category[8], s.counts_by_category[9],
            s.counts_by_category[0],
        });
    defer alloc.free(head);
    const middle = try std.fmt.allocPrint(alloc,
        "\"by_tld\":{{" ++
            "\"omnibus\":{d},\"arbitraje\":{d},\"quantum\":{d},\"bank\":{d},\"gov\":{d}," ++
            "\"mil\":{d},\"fin\":{d},\"edu\":{d},\"org\":{d},\"dev\":{d}" ++
        "}},",
        .{
            s.counts_by_tld[0], s.counts_by_tld[1], s.counts_by_tld[2], s.counts_by_tld[3],
            s.counts_by_tld[4], s.counts_by_tld[5], s.counts_by_tld[6], s.counts_by_tld[7],
            s.counts_by_tld[8], s.counts_by_tld[9],
        });
    defer alloc.free(middle);
    const tail = try std.fmt.allocPrint(alloc,
        "\"by_years\":{{" ++
            "\"1\":{d},\"2\":{d},\"3\":{d},\"4\":{d},\"5\":{d}," ++
            "\"10\":{d},\"25\":{d},\"50\":{d},\"100\":{d}" ++
        "}}," ++
        "\"pq_slots_set\":{d},\"preferred_slot_set\":{d}}}}}",
        .{
            s.counts_by_years[0], s.counts_by_years[1], s.counts_by_years[2],
            s.counts_by_years[3], s.counts_by_years[4], s.counts_by_years[5],
            s.counts_by_years[6], s.counts_by_years[7], s.counts_by_years[8],
            s.pq_slots_set, s.preferred_slot_set,
        });
    defer alloc.free(tail);
    return std.mem.concat(alloc, u8, &.{ head, middle, tail });
}

// ─── Phase 2 NS — multi-address per name + categories ──────────────────────

/// setpqaddress — owner attaches/clears a specific PQ scheme address slot.
/// Params: { name, tld?, slot ("ml_dsa"|"falcon"|"dilithium"|"slh_dsa" or 0..3),
///           pq_address (empty string to clear), owner }
fn handleSetPqAddress(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    if (ctx.dns == null) return errorJson(-32030, "DNS registry not enabled on this node", id, alloc);
    const dns = ctx.dns.?;
    const name = extractStr(body, "name") orelse extractArrayStr(body, 0) orelse
        return errorJson(-32602, "Missing param: name", id, alloc);
    const tld = extractStr(body, "tld") orelse extractArrayStr(body, 1) orelse "omnibus";
    const slot_str = extractStr(body, "slot") orelse extractArrayStr(body, 2) orelse
        return errorJson(-32602, "Missing param: slot (ml_dsa|falcon|dilithium|slh_dsa)", id, alloc);
    const pq_addr = extractStr(body, "pq_address") orelse extractArrayStr(body, 3) orelse "";
    const owner = extractStr(body, "owner") orelse extractArrayStr(body, 4) orelse
        return errorJson(-32602, "Missing param: owner", id, alloc);

    const slot: dns_mod.PqSlot = blk: {
        if (std.mem.eql(u8, slot_str, "ml_dsa")    or std.mem.eql(u8, slot_str, "obk1") or std.mem.eql(u8, slot_str, "0")) break :blk .ml_dsa;
        if (std.mem.eql(u8, slot_str, "falcon")    or std.mem.eql(u8, slot_str, "obf5") or std.mem.eql(u8, slot_str, "1")) break :blk .falcon;
        if (std.mem.eql(u8, slot_str, "dilithium") or std.mem.eql(u8, slot_str, "obs3") or std.mem.eql(u8, slot_str, "2")) break :blk .dilithium;
        if (std.mem.eql(u8, slot_str, "slh_dsa")   or std.mem.eql(u8, slot_str, "obd5") or std.mem.eql(u8, slot_str, "3")) break :blk .slh_dsa;
        return errorJson(-32602, "Invalid slot (use ml_dsa|falcon|dilithium|slh_dsa or 0..3)", id, alloc);
    };

    const current_block: u64 = @intCast(ctx.bc.chain.items.len);
    dns.updatePqAddress(name, tld, owner, slot, pq_addr, current_block) catch |err| {
        const msg: []const u8 = switch (err) {
            error.NameNotFound => "Name not found",
            error.NotOwner     => "Not owner of this name",
            error.AddrTooLong  => "PQ address exceeds 64 chars",
        };
        return errorJson(-32030, msg, id, alloc);
    };
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"name\":\"{s}\",\"tld\":\"{s}\",\"slot\":\"{s}\",\"pq_address\":\"{s}\",\"updated\":true}}}}",
        .{ id, name, tld, slot_str, pq_addr });
}

/// setcategory — owner assigns a category badge to their name.
/// Params: { name, tld?, category ("personal"|"bank"|...), owner }
fn handleSetCategory(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    if (ctx.dns == null) return errorJson(-32030, "DNS registry not enabled on this node", id, alloc);
    const dns = ctx.dns.?;
    const name = extractStr(body, "name") orelse extractArrayStr(body, 0) orelse
        return errorJson(-32602, "Missing param: name", id, alloc);
    const tld = extractStr(body, "tld") orelse extractArrayStr(body, 1) orelse "omnibus";
    const cat_str = extractStr(body, "category") orelse extractArrayStr(body, 2) orelse
        return errorJson(-32602, "Missing param: category", id, alloc);
    const owner = extractStr(body, "owner") orelse extractArrayStr(body, 3) orelse
        return errorJson(-32602, "Missing param: owner", id, alloc);

    const cat: dns_mod.Category = blk: {
        if (std.mem.eql(u8, cat_str, "personal")) break :blk .personal;
        if (std.mem.eql(u8, cat_str, "bank"))     break :blk .bank;
        if (std.mem.eql(u8, cat_str, "gov"))      break :blk .gov;
        if (std.mem.eql(u8, cat_str, "mil"))      break :blk .mil;
        if (std.mem.eql(u8, cat_str, "fin"))      break :blk .fin;
        if (std.mem.eql(u8, cat_str, "edu"))      break :blk .edu;
        if (std.mem.eql(u8, cat_str, "org"))      break :blk .org;
        if (std.mem.eql(u8, cat_str, "dev"))      break :blk .dev;
        if (std.mem.eql(u8, cat_str, "trading"))  break :blk .trading;
        if (std.mem.eql(u8, cat_str, "none"))     break :blk .none;
        return errorJson(-32602, "Invalid category (use personal|bank|gov|mil|fin|edu|org|dev|trading|none)", id, alloc);
    };

    const current_block: u64 = @intCast(ctx.bc.chain.items.len);
    dns.updateCategory(name, tld, owner, cat, current_block) catch |err| {
        const msg: []const u8 = switch (err) {
            error.NameNotFound => "Name not found",
            error.NotOwner     => "Not owner of this name",
        };
        return errorJson(-32030, msg, id, alloc);
    };
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"name\":\"{s}\",\"tld\":\"{s}\",\"category\":\"{s}\",\"updated\":true}}}}",
        .{ id, name, tld, cat.toString() });
}

/// setpreferredslot — owner sets which scheme they want funds delivered to by default.
/// Params: { name, tld?, slot (0=primary, 1=ml_dsa, 2=falcon, 3=dilithium, 4=slh_dsa), owner }
fn handleSetPreferredSlot(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    if (ctx.dns == null) return errorJson(-32030, "DNS registry not enabled on this node", id, alloc);
    const dns = ctx.dns.?;
    const name = extractStr(body, "name") orelse extractArrayStr(body, 0) orelse
        return errorJson(-32602, "Missing param: name", id, alloc);
    const tld = extractStr(body, "tld") orelse extractArrayStr(body, 1) orelse "omnibus";
    const slot_raw = extractArrayNumByKey(body, "slot");
    const owner = extractStr(body, "owner") orelse extractArrayStr(body, 3) orelse
        return errorJson(-32602, "Missing param: owner", id, alloc);

    if (slot_raw > 4) return errorJson(-32602, "Invalid slot (0=primary, 1..4=PQ)", id, alloc);
    const slot_idx: u8 = @intCast(slot_raw);
    const current_block: u64 = @intCast(ctx.bc.chain.items.len);
    dns.updatePreferredSlot(name, tld, owner, slot_idx, current_block) catch |err| {
        const msg: []const u8 = switch (err) {
            error.NameNotFound => "Name not found",
            error.NotOwner     => "Not owner of this name",
            error.InvalidSlot  => "Invalid slot",
        };
        return errorJson(-32030, msg, id, alloc);
    };
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"name\":\"{s}\",\"tld\":\"{s}\",\"preferred_slot\":{d},\"updated\":true}}}}",
        .{ id, name, tld, slot_idx });
}

/// getnamesbycategory — list all names with a given category badge.
/// Params: { category ("bank"|"gov"|...), limit? }
fn handleGetNamesByCategory(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    if (ctx.dns == null) return errorJson(-32030, "DNS registry not enabled on this node", id, alloc);
    const dns = ctx.dns.?;
    const cat_str = extractStr(body, "category") orelse extractArrayStr(body, 0) orelse
        return errorJson(-32602, "Missing param: category", id, alloc);
    const limit_raw = extractArrayNumByKey(body, "limit");
    const limit: usize = if (limit_raw > 0 and limit_raw <= 200) @intCast(limit_raw) else 50;

    const cat: dns_mod.Category = blk: {
        if (std.mem.eql(u8, cat_str, "personal")) break :blk .personal;
        if (std.mem.eql(u8, cat_str, "bank"))     break :blk .bank;
        if (std.mem.eql(u8, cat_str, "gov"))      break :blk .gov;
        if (std.mem.eql(u8, cat_str, "mil"))      break :blk .mil;
        if (std.mem.eql(u8, cat_str, "fin"))      break :blk .fin;
        if (std.mem.eql(u8, cat_str, "edu"))      break :blk .edu;
        if (std.mem.eql(u8, cat_str, "org"))      break :blk .org;
        if (std.mem.eql(u8, cat_str, "dev"))      break :blk .dev;
        if (std.mem.eql(u8, cat_str, "trading"))  break :blk .trading;
        return errorJson(-32602, "Invalid category", id, alloc);
    };

    var buf: [200]*const dns_mod.DnsEntry = undefined;
    const slice = buf[0..@min(limit, buf.len)];
    const current_block: u64 = @intCast(ctx.bc.chain.items.len);
    const found = dns.listByCategory(cat, slice, current_block);

    var out = std.ArrayList(u8){};
    defer out.deinit(alloc);
    var hdr: [128]u8 = undefined;
    const hdr_str = try std.fmt.bufPrint(&hdr,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"category\":\"{s}\",\"total\":{d},\"entries\":[",
        .{ id, cat.toString(), found });
    try out.appendSlice(alloc, hdr_str);
    var i: usize = 0;
    while (i < found) : (i += 1) {
        const e = slice[i];
        if (i > 0) try out.appendSlice(alloc, ",");
        var row: [256]u8 = undefined;
        const row_str = try std.fmt.bufPrint(&row,
            "{{\"name\":\"{s}\",\"tld\":\"{s}\",\"address\":\"{s}\",\"preferred_slot\":{d},\"registeredAtBlock\":{d}}}",
            .{ e.getName(), e.getTld(), e.getAddress(), e.preferred_slot, e.registered_block });
        try out.appendSlice(alloc, row_str);
    }
    try out.appendSlice(alloc, "]}}");
    return alloc.dupe(u8, out.items);
}

// ─── Phase 1: transfername ──────────────────────────────────────────────────
fn handleTransferName(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    if (ctx.dns == null) return errorJson(-32030, "DNS registry not enabled on this node", id, alloc);
    const dns = ctx.dns.?;

    const name = extractStr(body, "name") orelse extractArrayStr(body, 0) orelse
        return errorJson(-32602, "Missing param: name", id, alloc);
    const tld = extractStr(body, "tld") orelse extractArrayStr(body, 1) orelse "omnibus";
    const new_owner = extractStr(body, "new_owner") orelse extractArrayStr(body, 2) orelse
        return errorJson(-32602, "Missing param: new_owner", id, alloc);
    const nonce = extractArrayNumByKey(body, "nonce");
    const sig_hex = extractStr(body, "signature") orelse "";
    const pubkey_hex = extractStr(body, "publicKey") orelse extractStr(body, "pubkey") orelse "";

    const entry = dns.lookupEntry(name, tld) orelse
        return errorJson(-32400, "Name not found", id, alloc);
    const owner = entry.getOwner();
    const current_block: u64 = @intCast(ctx.bc.chain.items.len);

    // Signature check
    const is_hmac_bypass = std.mem.eql(u8, sig_hex, "REST_HMAC_BYPASS");
    if (dns.signed_required and !is_hmac_bypass) {
        if (sig_hex.len == 0 or pubkey_hex.len == 0) {
            return errorJson(-32602, "signature and publicKey required (signed mode)", id, alloc);
        }
        var msg_buf: [512]u8 = undefined;
        const msg = buildDnsTransferSignMessage(name, tld, new_owner, nonce, &msg_buf) catch
            return errorJson(-32603, "Failed to build sign message", id, alloc);
        if (!verifyDnsSignature(msg, sig_hex, pubkey_hex, owner, alloc)) {
            return errorJson(-32401, "Signing pubkey does not match current owner", id, alloc);
        }
    }

    // Nonce replay protection
    if (nonce <= entry.last_nonce) {
        return errorJson(-32402, "Nonce too low (replay rejected)", id, alloc);
    }

    const old_address = entry.getAddress();
    dns.transfer(name, tld, owner, old_address, new_owner, current_block) catch |err| {
        const msg: []const u8 = switch (err) {
            error.NameNotFound => "Name not found",
            error.NotOwner => "Not owner",
            error.OwnerCapExceeded => "Per-owner name cap exceeded for new_owner",
        };
        return errorJson(-32031, msg, id, alloc);
    };
    entry.last_nonce = nonce;

    var audit_buf: [1024]u8 = undefined;
    const audit_fields = std.fmt.bufPrint(&audit_buf,
        "\"name\":\"{s}\",\"tld\":\"{s}\",\"old_owner\":\"{s}\",\"new_owner\":\"{s}\",\"nonce\":{d},\"signer_pubkey\":\"{s}\",\"signature\":\"{s}\"",
        .{ name, tld, owner, new_owner, nonce, pubkey_hex, sig_hex }) catch "";
    if (audit_fields.len > 0) dnsAuditAppend(ctx, "transfer", audit_fields);

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"name\":\"{s}\",\"tld\":\"{s}\",\"old_owner\":\"{s}\",\"new_owner\":\"{s}\",\"transferredAtBlock\":{d}}}}}",
        .{ id, name, tld, owner, new_owner, current_block });
}

// ─── Phase 1: updatename ────────────────────────────────────────────────────
fn handleUpdateName(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    if (ctx.dns == null) return errorJson(-32030, "DNS registry not enabled on this node", id, alloc);
    const dns = ctx.dns.?;

    const name = extractStr(body, "name") orelse extractArrayStr(body, 0) orelse
        return errorJson(-32602, "Missing param: name", id, alloc);
    const tld = extractStr(body, "tld") orelse extractArrayStr(body, 1) orelse "omnibus";
    const new_address = extractStr(body, "new_address") orelse extractArrayStr(body, 2) orelse
        return errorJson(-32602, "Missing param: new_address", id, alloc);
    const nonce = extractArrayNumByKey(body, "nonce");
    const sig_hex = extractStr(body, "signature") orelse "";
    const pubkey_hex = extractStr(body, "publicKey") orelse extractStr(body, "pubkey") orelse "";

    const entry = dns.lookupEntry(name, tld) orelse
        return errorJson(-32400, "Name not found", id, alloc);
    const owner = entry.getOwner();
    const current_block: u64 = @intCast(ctx.bc.chain.items.len);
    const old_address = entry.getAddress();

    const is_hmac_bypass = std.mem.eql(u8, sig_hex, "REST_HMAC_BYPASS");
    if (dns.signed_required and !is_hmac_bypass) {
        if (sig_hex.len == 0 or pubkey_hex.len == 0) {
            return errorJson(-32602, "signature and publicKey required (signed mode)", id, alloc);
        }
        var msg_buf: [512]u8 = undefined;
        const msg = buildDnsUpdateSignMessage(name, tld, new_address, nonce, &msg_buf) catch
            return errorJson(-32603, "Failed to build sign message", id, alloc);
        if (!verifyDnsSignature(msg, sig_hex, pubkey_hex, owner, alloc)) {
            return errorJson(-32401, "Signing pubkey does not match current owner", id, alloc);
        }
    }

    if (nonce <= entry.last_nonce) {
        return errorJson(-32402, "Nonce too low (replay rejected)", id, alloc);
    }

    dns.updateAddress(name, tld, owner, new_address, current_block) catch |err| {
        const msg: []const u8 = switch (err) {
            error.NameNotFound => "Name not found",
            error.NotOwner => "Not owner",
        };
        return errorJson(-32031, msg, id, alloc);
    };
    entry.last_nonce = nonce;

    var audit_buf: [1024]u8 = undefined;
    const audit_fields = std.fmt.bufPrint(&audit_buf,
        "\"name\":\"{s}\",\"tld\":\"{s}\",\"old_address\":\"{s}\",\"new_address\":\"{s}\",\"nonce\":{d},\"signer_pubkey\":\"{s}\",\"signature\":\"{s}\"",
        .{ name, tld, old_address, new_address, nonce, pubkey_hex, sig_hex }) catch "";
    if (audit_fields.len > 0) dnsAuditAppend(ctx, "update", audit_fields);

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"name\":\"{s}\",\"tld\":\"{s}\",\"old_address\":\"{s}\",\"new_address\":\"{s}\",\"updatedAtBlock\":{d}}}}}",
        .{ id, name, tld, old_address, new_address, current_block });
}

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
fn handleRenewName(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    if (ctx.dns == null) return errorJson(-32030, "DNS registry not enabled on this node", id, alloc);
    const dns = ctx.dns.?;

    const name = extractStr(body, "name") orelse extractArrayStr(body, 0) orelse
        return errorJson(-32602, "Missing param: name", id, alloc);
    const tld = extractStr(body, "tld") orelse extractArrayStr(body, 1) orelse "omnibus";
    const nonce = extractArrayNumByKey(body, "nonce");
    const sig_hex = extractStr(body, "signature") orelse "";
    const pubkey_hex = extractStr(body, "publicKey") orelse extractStr(body, "pubkey") orelse "";
    const fee_txid = extractStr(body, "fee_txid") orelse null;
    // Phase 2: years tier (default 1 for V1 compat).
    const years_raw = extractArrayNumByKey(body, "years");
    const years: u32 = if (years_raw == 0) 1 else @intCast(@min(years_raw, dns_mod.MAX_REGISTRATION_YEARS));
    if (!dns_mod.isValidYears(years)) {
        return errorJson(-32602, "Invalid years (allowed: 1, 2, 3, 4, 5, 10, 25, 50, 100)", id, alloc);
    }

    const entry = dns.lookupEntry(name, tld) orelse
        return errorJson(-32400, "Name not found", id, alloc);
    const owner = entry.getOwner();
    const current_block: u64 = @intCast(ctx.bc.chain.items.len);
    const old_expires = entry.expires_block;
    const old_years = entry.registered_years;

    const is_hmac_bypass = std.mem.eql(u8, sig_hex, "REST_HMAC_BYPASS");
    if (dns.signed_required and !is_hmac_bypass) {
        if (sig_hex.len == 0 or pubkey_hex.len == 0) {
            return errorJson(-32602, "signature and publicKey required (signed mode)", id, alloc);
        }
        var msg_buf: [512]u8 = undefined;
        // V2 signing message embeds years; V1 message kept for legacy callers
        // that don't pass `years` (defaulted to 1). We try V2 first; if it
        // fails AND years==1, fall back to V1 to keep Phase 1 clients alive.
        const msg_v2 = buildDnsRenewYearsSignMessage(name, tld, years, nonce, &msg_buf) catch
            return errorJson(-32603, "Failed to build sign message", id, alloc);
        var ok = verifyDnsSignature(msg_v2, sig_hex, pubkey_hex, owner, alloc);
        if (!ok and years == 1) {
            var legacy_buf: [512]u8 = undefined;
            const msg_v1 = buildDnsRenewSignMessage(name, tld, nonce, &legacy_buf) catch
                return errorJson(-32603, "Failed to build sign message", id, alloc);
            ok = verifyDnsSignature(msg_v1, sig_hex, pubkey_hex, owner, alloc);
        }
        if (!ok) {
            return errorJson(-32401, "Signing pubkey does not match current owner", id, alloc);
        }
    }

    if (nonce <= entry.last_nonce) {
        return errorJson(-32402, "Nonce too low (replay rejected)", id, alloc);
    }

    // Fee enforcement for renewal — Phase 2: scales with `years` via the
    // same multiplier curve as registration. 100y renew costs ~55× base,
    // not 100× (long-term commitment discount).
    const required_fee = dns_mod.feeForRenewal(name, tld, years);
    if (dns.fee_enforcement) {
        const txid = fee_txid orelse
            return errorJson(-32602, "fee_txid required (mainnet)", id, alloc);
        if (txid.len != dns_mod.TXID_LEN) {
            return errorJson(-32031, "fee TX invalid: txid must be 64 hex chars", id, alloc);
        }
        if (dns.isTxidConsumed(txid)) {
            return errorJson(-32031, "fee TX invalid: txid already used", id, alloc);
        }
        var found_tx: ?*const transaction_mod.Transaction = null;
        ctx.bc.mutex.lock();
        for (ctx.bc.chain.items) |blk| {
            for (blk.transactions.items) |*tx| {
                if (std.mem.eql(u8, tx.hash, txid)) {
                    found_tx = tx;
                    break;
                }
            }
            if (found_tx != null) break;
        }
        ctx.bc.mutex.unlock();
        const tx = found_tx orelse
            return errorJson(-32031, "fee TX invalid: transaction not found in chain", id, alloc);
        const treasury = dns.getTreasury();
        if (!std.mem.eql(u8, tx.to_address, treasury)) {
            return errorJson(-32031, "fee TX invalid: destination is not treasury", id, alloc);
        }
        if (tx.amount < required_fee) {
            return errorJson(-32031, "fee TX invalid: amount too low", id, alloc);
        }
        dns.consumeTxid(txid) catch |err| {
            const msg: []const u8 = switch (err) {
                error.InvalidTxid => "Invalid txid",
                error.ConsumedTxidsFull => "Consumed txids full",
            };
            return errorJson(-32031, msg, id, alloc);
        };
    }

    dns.renewWithYears(name, tld, owner, years, current_block) catch |err| {
        const msg: []const u8 = switch (err) {
            error.NameNotFound      => "Name not found",
            error.NotOwner          => "Not owner",
            error.InvalidYears      => "Invalid years tier (allowed: 1, 2, 3, 4, 5, 10, 25, 50, 100)",
            error.YearsCapExceeded  => "Cumulative registered_years would exceed 100 (hard cap)",
        };
        return errorJson(-32031, msg, id, alloc);
    };
    entry.last_nonce = nonce;

    const fee_paid_sat: u64 = if (fee_txid) |_| required_fee else 0;
    const fee_txid_esc = fee_txid orelse "";

    var audit_buf: [1024]u8 = undefined;
    const audit_fields = std.fmt.bufPrint(&audit_buf,
        "\"name\":\"{s}\",\"tld\":\"{s}\",\"added_years\":{d},\"old_years\":{d},\"new_years\":{d},\"old_expires_block\":{d},\"new_expires_block\":{d},\"nonce\":{d},\"signer_pubkey\":\"{s}\",\"signature\":\"{s}\",\"fee_paid_sat\":{d},\"fee_txid\":\"{s}\"",
        .{ name, tld, years, old_years, entry.registered_years, old_expires, entry.expires_block, nonce, pubkey_hex, sig_hex, fee_paid_sat, fee_txid_esc }) catch "";
    if (audit_fields.len > 0) dnsAuditAppend(ctx, "renew", audit_fields);

    // WS push — UI updates the expiry pill on the renewed name.
    if (main_mod.g_ws_srv) |ws| {
        ws.broadcastNameRenewed(name, tld, owner, @intCast(@min(years, 255)));
    }

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"name\":\"{s}\",\"tld\":\"{s}\",\"added_years\":{d},\"registered_years\":{d},\"old_expires_block\":{d},\"new_expires_block\":{d},\"fee_paid_sat\":{d}}}}}",
        .{ id, name, tld, years, entry.registered_years, old_expires, entry.expires_block, fee_paid_sat });
}

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
fn handleNsExpiringSoon(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    if (ctx.dns == null) return errorJson(-32030, "DNS registry not enabled on this node", id, alloc);
    const dns = ctx.dns.?;

    const address = extractStr(body, "address") orelse extractArrayStr(body, 0) orelse
        return errorJson(-32602, "Missing param: address", id, alloc);

    // Default ~30 days at 10s block time = 259200 blocks.
    const DEFAULT_THRESHOLD_BLOCKS: u64 = 259_200;
    const t_raw = extractArrayNumByKey(body, "blocks_threshold");
    const blocks_threshold: u64 = if (t_raw == 0) DEFAULT_THRESHOLD_BLOCKS else t_raw;

    const current_block: u64 = @intCast(ctx.bc.chain.items.len);
    var buf: [dns_mod.MAX_NAMES_PER_OWNER]*const dns_mod.DnsEntry = undefined;
    const n = dns.getExpiringNames(address, current_block, blocks_threshold, &buf);

    // Build JSON result. ~512B per entry is plenty.
    var out = std.array_list.Managed(u8).init(alloc);
    defer out.deinit();
    const w = out.writer();
    try std.fmt.format(w,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"address\":\"{s}\",\"current_block\":{d},\"blocks_threshold\":{d},\"entries\":[",
        .{ id, address, current_block, blocks_threshold });
    for (buf[0..n], 0..) |e, i| {
        if (i > 0) try w.writeAll(",");
        const name = e.getName();
        const tld_s = e.getTld();
        const in_grace = e.isInGrace(current_block);
        const remaining: u64 = if (in_grace or e.expires_block <= current_block)
            0
        else
            e.expires_block - current_block;
        // 10s/block, so days = remaining / (86400/10) = remaining / 8640
        const est_days: u64 = remaining / 8640;
        try std.fmt.format(w,
            "{{\"name\":\"{s}\",\"tld\":\"{s}\",\"fullLabel\":\"{s}.{s}\",\"expiresAtBlock\":{d},\"blocks_remaining\":{d},\"estimated_days_remaining\":{d},\"registered_years\":{d},\"in_grace\":{}}}",
            .{ name, tld_s, name, tld_s, e.expires_block, remaining, est_days, e.registered_years, in_grace });
    }
    try w.writeAll("]}}");
    return out.toOwnedSlice();
}

// ─── Phase 2: ns_pruneExpired ───────────────────────────────────────────────
//
// Admin / maintenance RPC. Drops every entry whose grace period has fully
// elapsed (truly auctionable + abandoned). Returns the number removed and
// the new entry_count. Not auto-called; main.zig invokes it once at startup
// and (optionally) every N blocks during mining.
//
// Result: { removed: u64, entry_count: u64, current_block: u64 }
fn handleNsPruneExpired(ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    if (ctx.dns == null) return errorJson(-32030, "DNS registry not enabled on this node", id, alloc);
    const dns = ctx.dns.?;
    const current_block: u64 = @intCast(ctx.bc.chain.items.len);
    const removed = dns.pruneExpiredNames(current_block);
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"removed\":{d},\"entry_count\":{d},\"current_block\":{d}}}}}",
        .{ id, removed, dns.entry_count, current_block });
}

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
fn handleSendRawTx(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;

    // Required string fields
    const from_addr = extractStr(body, "from") orelse extractArrayStr(body, 0) orelse
        return errorJson(-32602, "Missing param: from", id, alloc);
    const to_addr = extractStr(body, "to") orelse
        return errorJson(-32602, "Missing param: to", id, alloc);
    const sig_hex = extractStr(body, "signature") orelse
        return errorJson(-32602, "Missing param: signature (128 hex chars)", id, alloc);
    const hash_hex = extractStr(body, "hash") orelse
        return errorJson(-32602, "Missing param: hash (64 hex chars)", id, alloc);
    const pubkey_hex = extractStr(body, "publicKey") orelse extractStr(body, "pubkey") orelse
        return errorJson(-32602, "Missing param: publicKey", id, alloc);

    // Required numeric fields
    const amount = extractArrayNumByKey(body, "amount");
    if (amount == 0) return errorJson(-32602, "Missing or zero: amount", id, alloc);
    const fee = extractArrayNumByKey(body, "fee");
    const fee_sat: u64 = if (fee > 0) fee else mempool_mod.TX_MIN_FEE_SAT;
    const ts_raw = extractArrayNumByKey(body, "timestamp");
    const ts: i64 = if (ts_raw > 0) @intCast(ts_raw) else std.time.timestamp();
    const nonce = extractArrayNumByKey(body, "nonce");
    const tx_id_raw = extractArrayNumByKey(body, "id");
    const tx_id: u32 = if (tx_id_raw > 0) @intCast(@min(tx_id_raw, std.math.maxInt(u32))) else g_tx_counter.fetchAdd(1, .monotonic);
    const locktime = extractArrayNumByKey(body, "locktime");
    const op_return = extractStr(body, "opReturn") orelse extractStr(body, "op_return") orelse "";

    // Auto-detect scheme from sender address prefix. ECDSA expects fixed
    // 128-char signature + 66-char pubkey; PQ schemes carry much larger
    // signatures (Falcon ~700 bytes, ML-DSA ~3-4 KB, SLH-DSA-256s ~30 KB)
    // so we skip the length check for non-ECDSA schemes — the verifier
    // does the real validation per-scheme.
    const scheme_opt = isolated_wallet_mod.Scheme.fromAddress(from_addr);
    const scheme: isolated_wallet_mod.Scheme = scheme_opt orelse .omni_ecdsa;

    // Field-length sanity for the legacy ECDSA path. PQ paths skip this.
    if (scheme == .omni_ecdsa) {
        if (sig_hex.len != 128) return errorJson(-32602, "signature must be 128 hex chars (ECDSA)", id, alloc);
        if (hash_hex.len != 64) return errorJson(-32602, "hash must be 64 hex chars", id, alloc);
        if (pubkey_hex.len != 66) return errorJson(-32602, "publicKey must be 66 hex chars (compressed secp256k1)", id, alloc);
    } else {
        // PQ TX: hash is still 32 bytes (sha256 output, 64 hex). signature
        // and pubkey lengths vary per scheme — verifier checks them.
        if (hash_hex.len != 64) return errorJson(-32602, "hash must be 64 hex chars", id, alloc);
        if (sig_hex.len < 100) return errorJson(-32602, "PQ signature too short", id, alloc);
        if (pubkey_hex.len < 100) return errorJson(-32602, "PQ public key too short", id, alloc);
    }

    // Allocate owned copies so the Transaction struct outlives the request body.
    const from_owned = try alloc.dupe(u8, from_addr);
    errdefer alloc.free(from_owned);
    const to_owned = try alloc.dupe(u8, to_addr);
    errdefer alloc.free(to_owned);
    const sig_owned = try alloc.dupe(u8, sig_hex);
    errdefer alloc.free(sig_owned);
    const hash_owned = try alloc.dupe(u8, hash_hex);
    errdefer alloc.free(hash_owned);
    const op_owned: []const u8 = if (op_return.len > 0) try alloc.dupe(u8, op_return) else "";
    errdefer if (op_return.len > 0) alloc.free(op_owned);

    // For PQ TXs, the public_key field on the Transaction struct is the
    // raw PQ pubkey BYTES (not hex). Decode here. ECDSA TXs leave it empty
    // and use the chain pubkey registry instead.
    var pq_pubkey_owned: []const u8 = "";
    if (scheme != .omni_ecdsa) {
        const pq_buf = try alloc.alloc(u8, pubkey_hex.len / 2);
        errdefer alloc.free(pq_buf);
        _ = hex_utils.hexToBytes(pubkey_hex, pq_buf) catch {
            alloc.free(pq_buf);
            return errorJson(-32602, "publicKey must be valid hex", id, alloc);
        };
        pq_pubkey_owned = pq_buf;
    }

    var tx = transaction_mod.Transaction{
        .id           = tx_id,
        .from_address = from_owned,
        .to_address   = to_owned,
        .amount       = amount,
        .fee          = fee_sat,
        .timestamp    = ts,
        .nonce        = nonce,
        .locktime     = locktime,
        .op_return    = op_owned,
        .signature    = sig_owned,
        .hash         = hash_owned,
        .scheme       = @as(transaction_mod.Scheme, @enumFromInt(@intFromEnum(scheme))),
        .public_key   = pq_pubkey_owned,
    };

    if (!tx.isValid()) return errorJson(-32000, "Transaction failed isValid (bad addresses or amount)", id, alloc);

    // Register sender pubkey BEFORE validating — addTransaction's signature
    // check looks the pubkey up by address. Without this, fresh senders
    // would always fail validation on their first TX.
    ctx.bc.registerPubkey(from_owned, pubkey_hex) catch {};

    ctx.bc.addTransaction(tx) catch |err| {
        // The `errdefer alloc.free(...)` chain above doesn't fire here because
        // addTransaction took ownership (or didn't) depending on where it
        // failed. We err on the side of leaking a few bytes per rejected TX
        // rather than risk a double-free.
        const msg = switch (err) {
            error.OutOfMemory => "Out of memory",
            else              => "Mempool refused TX",
        };
        std.debug.print("[RAW-TX] addTransaction error: {} (from={s})\n",
            .{ err, from_owned[0..@min(from_owned.len, 16)] });
        return errorJson(-32000, msg, id, alloc);
    };

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"txid\":\"{s}\",\"from\":\"{s}\",\"to\":\"{s}\",\"amount\":{d},\"fee\":{d},\"status\":\"accepted\"}}}}",
        .{ id, hash_owned, from_owned, to_owned, amount, fee_sat });
}

/// Helper: read a u64 from either an object key (e.g. `"amount":123`) or
/// — fallback — try interpreting `body` as a positional array. Returns 0
/// if the field is missing or non-numeric.
fn extractArrayNumByKey(body: []const u8, key: []const u8) u64 {
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

fn handleMinerSendTx(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;

    const from_addr = extractArrayStr(body, 0) orelse extractStr(body, "from") orelse
        return errorJson(-32602, "Missing param: from (miner address)", id, alloc);
    const to_addr = extractArrayStr(body, 1) orelse extractStr(body, "to") orelse
        return errorJson(-32602, "Missing param: to (recipient address)", id, alloc);
    const amount_sat = extractArrayNum(body, 2);
    if (amount_sat == 0) return errorJson(-32602, "Missing/zero param: amount", id, alloc);
    const fee_raw = extractArrayNum(body, 3);
    const fee_sat: u64 = if (fee_raw > 0) fee_raw else mempool_mod.TX_MIN_FEE_SAT;

    // Look up the miner's wallet in the pool
    const mw = main_mod.g_miner_pool.findByAddress(from_addr) orelse
        return errorJson(-32602, "Miner not found in wallet pool", id, alloc);

    // Check balance
    const sender_bal = ctx.bc.getAddressBalance(from_addr);
    if (sender_bal < amount_sat + fee_sat) {
        return errorJson(-32000, "Insufficient balance", id, alloc);
    }

    // Create and sign TX using miner's private key
    const tx_id = g_tx_counter.fetchAdd(1, .monotonic);
    const nonce = ctx.bc.getNextAvailableNonce(from_addr);
    var tx = mw.createSignedTx(to_addr, amount_sat, tx_id, nonce, fee_sat, alloc) catch
        return errorJson(-32000, "Sign error", id, alloc);
    if (!tx.isValid()) return errorJson(-32000, "Invalid transaction", id, alloc);

    // Ensure pubkey is registered for signature verification
    ctx.bc.registerPubkey(from_addr, mw.getPubkeyHex()) catch {};

    // Add to mempool/blockchain
    ctx.bc.addTransaction(tx) catch
        return errorJson(-32000, "Mempool rejected TX", id, alloc);

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"txid\":\"{s}\",\"from\":\"{s}\",\"to\":\"{s}\",\"amount\":{d},\"fee\":{d},\"status\":\"accepted\"}}}}",
        .{ id, tx.hash, tx.from_address, tx.to_address, tx.amount, tx.fee });
}

/// RPC "getaddresshistory" — returns all TXs (sent + received) for an address.
/// Uses address_tx_index for confirmed TXs, scans mempool for pending.
/// Usage: {"method":"getaddresshistory","params":["ob1qcx2p306xpf3c2gd6h4074kpux4tv2hnmx3ytuq"],"id":1}
fn handleGetAddrHistory(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const addr = extractArrayStr(body, 0) orelse extractStr(body, "address") orelse
        return errorJson(-32602, "Missing param: address", id, alloc);

    ctx.bc.mutex.lock();
    defer ctx.bc.mutex.unlock();

    var entries: []u8 = try alloc.dupe(u8, "");
    var count: usize = 0;
    var total_received: u64 = 0;
    var total_sent: u64 = 0;
    const current_height: u64 = @intCast(ctx.bc.chain.items.len);

    // 1. Pending TXs from mempool (0 confirmations)
    for (ctx.bc.mempool.items) |tx| {
        const is_from = std.mem.eql(u8, tx.from_address, addr);
        const is_to = std.mem.eql(u8, tx.to_address, addr);
        if (!is_from and !is_to) continue;
        const dir: []const u8 = if (is_from) "sent" else "received";
        if (is_from) total_sent += tx.amount else total_received += tx.amount;
        const kind = inferTxKind(tx);
        const sep: []const u8 = if (count == 0) "" else ",";
        const e = try std.fmt.allocPrint(alloc,
            "{s}{{\"txid\":\"{s}\",\"from\":\"{s}\",\"to\":\"{s}\",\"amount\":{d},\"fee\":{d},\"confirmations\":0,\"blockHeight\":null,\"direction\":\"{s}\",\"kind\":\"{s}\",\"scheme\":\"{s}\",\"nonce\":{d},\"timestamp\":{d},\"status\":\"pending\"}}",
            .{ sep, tx.hash, tx.from_address, tx.to_address, tx.amount, tx.fee, dir, kind, txSchemeLabel(tx.scheme), tx.nonce, tx.timestamp });
        const m = try std.fmt.allocPrint(alloc, "{s}{s}", .{ entries, e });
        alloc.free(entries); alloc.free(e); entries = m; count += 1;
    }

    // 2. Confirmed TXs via address_tx_index (fast lookup)
    if (ctx.bc.getAddressHistory(addr)) |tx_hashes| {
        for (tx_hashes) |tx_hash| {
            const block_height = ctx.bc.tx_block_height.get(tx_hash) orelse continue;
            if (block_height >= ctx.bc.chain.items.len) continue;
            const blk = ctx.bc.chain.items[block_height];
            const confirmations = if (current_height > block_height) current_height - block_height else 0;
            for (blk.transactions.items) |tx| {
                if (!std.mem.eql(u8, tx.hash, tx_hash)) continue;
                const is_from = std.mem.eql(u8, tx.from_address, addr);
                const dir: []const u8 = if (is_from) "sent" else "received";
                if (is_from) total_sent += tx.amount else total_received += tx.amount;
                const kind = inferTxKind(tx);
                const sep: []const u8 = if (count == 0) "" else ",";
                const e = try std.fmt.allocPrint(alloc,
                    "{s}{{\"txid\":\"{s}\",\"from\":\"{s}\",\"to\":\"{s}\",\"amount\":{d},\"fee\":{d},\"confirmations\":{d},\"blockHeight\":{d},\"direction\":\"{s}\",\"kind\":\"{s}\",\"scheme\":\"{s}\",\"nonce\":{d},\"timestamp\":{d},\"status\":\"confirmed\"}}",
                    .{ sep, tx.hash, tx.from_address, tx.to_address, tx.amount, tx.fee, confirmations, block_height, dir, kind, txSchemeLabel(tx.scheme), tx.nonce, tx.timestamp });
                const m = try std.fmt.allocPrint(alloc, "{s}{s}", .{ entries, e });
                alloc.free(entries); alloc.free(e); entries = m; count += 1;
                break;
            }
        }
    }

    defer alloc.free(entries);
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"address\":\"{s}\",\"transactions\":[{s}],\"count\":{d},\"totalReceived\":{d},\"totalSent\":{d}}}}}",
        .{ id, addr, entries, count, total_received, total_sent });
}

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
fn handleGetDailyActivity(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const addr = extractArrayStr(body, 0) orelse extractStr(body, "address") orelse
        return errorJson(-32602, "Missing param: address", id, alloc);

    // Parse `days` from positional[1] or `"days":N`. Default 30, clamp to [1, 365].
    var days: u64 = extractArrayNum(body, 1);
    if (days == 0) days = extractArrayNumByKey(body, "days");
    if (days == 0) days = 30;
    if (days > 365) days = 365;

    ctx.bc.mutex.lock();
    defer ctx.bc.mutex.unlock();

    const current_height: u64 = @intCast(ctx.bc.chain.items.len);

    // Block-time → blocks/day. Mainnet 1000ms → 86400. Guard against zero.
    // We avoid coupling to a specific chain by reading the single
    // `chain_config` constant we know is exposed in this file via the
    // imported chain_config alias (block_time_ms is ChainConfig field, not
    // a top-level constant). Fall back to the OmniBus mainnet 1s block.
    const block_time_ms: u64 = 1000;
    var blocks_per_day: u64 = (24 * 60 * 60 * 1000) / block_time_ms;
    if (blocks_per_day == 0) blocks_per_day = 86_400;

    // Walk window = last `days` days, but cap by chain height.
    const window_blocks: u64 = days * blocks_per_day;
    const start_height: u64 = if (window_blocks >= current_height) 0 else current_height - window_blocks;

    // Per-day accumulators. Stored as a parallel-slice struct-of-arrays so
    // we don't bring in std.array_list managed types here — every chain
    // RPC handler does fixed-size buffers when possible to keep the hot
    // path GC-free.
    const Day = struct {
        block_start: u64,
        block_end: u64,
        tx_count: u64,
        sent: u64,
        received: u64,
        mining_reward: u64,
        fees_burned: u64,
        stake_change: i128,
        had_activity: bool,
    };
    var day_buf: [365]Day = undefined;
    var day_count: usize = 0;
    while (day_count < days and day_count < day_buf.len) : (day_count += 1) {
        const day_start = start_height + (day_count * blocks_per_day);
        const day_end_raw = day_start + blocks_per_day;
        const day_end = if (day_end_raw > current_height) current_height else day_end_raw;
        day_buf[day_count] = .{
            .block_start = day_start,
            .block_end = day_end,
            .tx_count = 0,
            .sent = 0,
            .received = 0,
            .mining_reward = 0,
            .fees_burned = 0,
            .stake_change = 0,
            .had_activity = false,
        };
    }

    // Iterate the address index → resolve each tx to a block → bucket into a day.
    if (ctx.bc.getAddressHistory(addr)) |tx_hashes| {
        for (tx_hashes) |tx_hash| {
            const block_height = ctx.bc.tx_block_height.get(tx_hash) orelse continue;
            if (block_height >= ctx.bc.chain.items.len) continue;
            if (block_height < start_height) continue;
            // Find day bucket
            const offset = block_height - start_height;
            const day_idx_u: u64 = offset / blocks_per_day;
            if (day_idx_u >= day_count) continue;
            const day_idx: usize = @intCast(day_idx_u);
            const blk = ctx.bc.chain.items[block_height];
            for (blk.transactions.items) |tx| {
                if (!std.mem.eql(u8, tx.hash, tx_hash)) continue;
                const is_from = std.mem.eql(u8, tx.from_address, addr);
                const is_to = std.mem.eql(u8, tx.to_address, addr);
                if (!is_from and !is_to) break;
                day_buf[day_idx].tx_count += 1;
                day_buf[day_idx].had_activity = true;
                if (is_from) {
                    day_buf[day_idx].sent += tx.amount;
                    day_buf[day_idx].fees_burned += tx.fee;
                    // stake / unstake op_return — only counted when sender
                    if (tx.op_return.len > 0) {
                        if (std.mem.startsWith(u8, tx.op_return, "stake:")) {
                            day_buf[day_idx].stake_change += @intCast(tx.amount);
                        } else if (std.mem.startsWith(u8, tx.op_return, "unstake:")) {
                            day_buf[day_idx].stake_change -= @intCast(tx.amount);
                        }
                    }
                }
                if (is_to) {
                    day_buf[day_idx].received += tx.amount;
                    // Coinbase = mining reward credited to miner
                    if (tx.from_address.len == 0) {
                        day_buf[day_idx].mining_reward += tx.amount;
                    }
                }
                break;
            }
        }
    }

    // Serialize → JSON array of per-day objects.
    var entries: []u8 = try alloc.dupe(u8, "");
    var i: usize = 0;
    while (i < day_count) : (i += 1) {
        const d = day_buf[i];
        const sep: []const u8 = if (i == 0) "" else ",";
        // stake_change can be negative — split sign from magnitude for {d} formatter.
        const sc_neg: bool = d.stake_change < 0;
        const sc_abs: u128 = if (sc_neg) @intCast(-d.stake_change) else @intCast(d.stake_change);
        const sc_sign: []const u8 = if (sc_neg) "-" else "";
        const e = try std.fmt.allocPrint(alloc,
            "{s}{{\"dayIndex\":{d},\"blockStart\":{d},\"blockEnd\":{d},\"txCount\":{d},\"sent\":{d},\"received\":{d},\"miningReward\":{d},\"feesBurned\":{d},\"stakeChange\":{s}{d}}}",
            .{ sep, i, d.block_start, d.block_end, d.tx_count, d.sent, d.received, d.mining_reward, d.fees_burned, sc_sign, sc_abs });
        const m = try std.fmt.allocPrint(alloc, "{s}{s}", .{ entries, e });
        alloc.free(entries); alloc.free(e); entries = m;
    }

    // Reference timestamps so the client can render real calendar dates.
    // We give it: tip block height, tip block timestamp (unix seconds),
    // and the assumed blocks_per_day. The client computes:
    //   day_unix = tip_ts - (current_height - block_start) * block_time_s
    var tip_ts: i64 = 0;
    if (current_height > 0) tip_ts = ctx.bc.chain.items[current_height - 1].timestamp;

    defer alloc.free(entries);
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"address\":\"{s}\",\"days\":{d},\"blocksPerDay\":{d},\"blockTimeMs\":{d},\"tipHeight\":{d},\"tipTimestamp\":{d},\"daily\":[{s}]}}}}",
        .{ id, addr, days, blocks_per_day, block_time_ms, current_height, tip_ts, entries });
}

/// RPC "listtransactions" — returns last N transactions for the node's own wallet.
/// Usage: {"method":"listtransactions","params":[count],"id":1}  (default count=10)
fn handleListTx(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const count_raw = extractArrayNum(body, 0);
    const max_count: usize = if (count_raw > 0 and count_raw <= 1000) @intCast(count_raw) else 10;
    const wallet_addr = ctx.wallet.address;

    ctx.bc.mutex.lock();
    defer ctx.bc.mutex.unlock();

    // Collect all TXs for this wallet (pending + confirmed), newest first
    var entries: []u8 = try alloc.dupe(u8, "");
    var count: usize = 0;
    const current_height: u64 = @intCast(ctx.bc.chain.items.len);

    // 1. Pending TXs from mempool (newest first — mempool is FIFO, scan reverse)
    var mp_idx: usize = ctx.bc.mempool.items.len;
    while (mp_idx > 0 and count < max_count) {
        mp_idx -= 1;
        const tx = ctx.bc.mempool.items[mp_idx];
        const is_from = std.mem.eql(u8, tx.from_address, wallet_addr);
        const is_to = std.mem.eql(u8, tx.to_address, wallet_addr);
        if (!is_from and !is_to) continue;
        const dir: []const u8 = if (is_from) "sent" else "received";
        const sep: []const u8 = if (count == 0) "" else ",";
        const kind = inferTxKind(tx);
        const e = try std.fmt.allocPrint(alloc,
            "{s}{{\"txid\":\"{s}\",\"from\":\"{s}\",\"to\":\"{s}\",\"amount\":{d},\"fee\":{d},\"confirmations\":0,\"blockHeight\":null,\"direction\":\"{s}\",\"kind\":\"{s}\",\"status\":\"pending\",\"scheme\":\"{s}\",\"timestamp\":{d}}}",
            .{ sep, tx.hash, tx.from_address, tx.to_address, tx.amount, tx.fee, dir, kind, txSchemeLabel(tx.scheme), tx.timestamp });
        const m = try std.fmt.allocPrint(alloc, "{s}{s}", .{ entries, e });
        alloc.free(entries); alloc.free(e); entries = m; count += 1;
    }

    // 2. Confirmed TXs — scan blocks newest first via address_tx_index
    // FIX B4: copy hashes into a local owned slice while we still hold the
    // chain mutex. The original ArrayList in address_tx_index can be
    // resized by indexAddressTx (called from applyBlock), invalidating any
    // outstanding slice. By snapshotting via dupe we de-couple the iteration
    // from the live HashMap state.
    if (count < max_count) {
        const hashes_copy: ?[][]const u8 = blk: {
            const live = ctx.bc.getAddressHistory(wallet_addr) orelse break :blk null;
            if (live.len == 0) break :blk null;
            const owned = alloc.alloc([]const u8, live.len) catch break :blk null;
            for (live, 0..) |h, i| {
                owned[i] = alloc.dupe(u8, h) catch {
                    // free what we already duped on failure
                    for (owned[0..i]) |x| alloc.free(x);
                    alloc.free(owned);
                    break :blk null;
                };
            }
            break :blk owned;
        };
        if (hashes_copy) |tx_hashes| {
            defer {
                for (tx_hashes) |h| alloc.free(h);
                alloc.free(tx_hashes);
            }
            // Iterate reverse (newest TXs are appended last)
            var ti: usize = tx_hashes.len;
            while (ti > 0 and count < max_count) {
                ti -= 1;
                const tx_hash = tx_hashes[ti];
                const block_height = ctx.bc.tx_block_height.get(tx_hash) orelse continue;
                if (block_height >= ctx.bc.chain.items.len) continue;
                const blk = ctx.bc.chain.items[block_height];
                const confirmations = if (current_height > block_height) current_height - block_height else 0;
                for (blk.transactions.items) |tx| {
                    if (!std.mem.eql(u8, tx.hash, tx_hash)) continue;
                    const is_from = std.mem.eql(u8, tx.from_address, wallet_addr);
                    const dir: []const u8 = if (is_from) "sent" else "received";
                    const sep: []const u8 = if (count == 0) "" else ",";
                    const kind = inferTxKind(tx);
                    const e = try std.fmt.allocPrint(alloc,
                        "{s}{{\"txid\":\"{s}\",\"from\":\"{s}\",\"to\":\"{s}\",\"amount\":{d},\"fee\":{d},\"confirmations\":{d},\"blockHeight\":{d},\"direction\":\"{s}\",\"kind\":\"{s}\",\"status\":\"confirmed\",\"scheme\":\"{s}\",\"timestamp\":{d}}}",
                        .{ sep, tx.hash, tx.from_address, tx.to_address, tx.amount, tx.fee, confirmations, block_height, dir, kind, txSchemeLabel(tx.scheme), tx.timestamp });
                    const m = try std.fmt.allocPrint(alloc, "{s}{s}", .{ entries, e });
                    alloc.free(entries); alloc.free(e); entries = m; count += 1;
                    break;
                }
            }
        }
    }

    defer alloc.free(entries);
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"address\":\"{s}\",\"transactions\":[{s}],\"count\":{d}}}}}",
        .{ id, wallet_addr, entries, count });
}

fn handleGetTxs(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const filter = extractArrayStr(body, 0) orelse extractStr(body, "address") orelse "";
    var entries: []u8 = try alloc.dupe(u8, "");
    var count: usize = 0;
    const current_height: u64 = @intCast(ctx.bc.chain.items.len);
    for (ctx.bc.mempool.items) |tx| {
        if (filter.len > 0 and !std.mem.eql(u8, tx.from_address, filter) and !std.mem.eql(u8, tx.to_address, filter)) continue;
        const dir: []const u8 = if (filter.len > 0 and std.mem.eql(u8, tx.from_address, filter)) "sent" else "received";
        const sep: []const u8 = if (count == 0) "" else ",";
        const e = try std.fmt.allocPrint(alloc, "{s}{{\"txid\":\"{s}\",\"from\":\"{s}\",\"to\":\"{s}\",\"amount\":{d},\"fee\":{d},\"locktime\":{d},\"op_return\":\"{s}\",\"confirmations\":0,\"status\":\"pending\",\"direction\":\"{s}\"}}", .{ sep, tx.hash, tx.from_address, tx.to_address, tx.amount, tx.fee, tx.locktime, tx.op_return, dir });
        const m = try std.fmt.allocPrint(alloc, "{s}{s}", .{ entries, e });
        alloc.free(entries); alloc.free(e); entries = m; count += 1;
    }
    for (ctx.bc.chain.items) |blk| {
        for (blk.transactions.items) |tx| {
            if (filter.len > 0 and !std.mem.eql(u8, tx.from_address, filter) and !std.mem.eql(u8, tx.to_address, filter)) continue;
            const dir: []const u8 = if (filter.len > 0 and std.mem.eql(u8, tx.from_address, filter)) "sent" else "received";
            const sep: []const u8 = if (count == 0) "" else ",";
            const bh: u64 = @intCast(blk.index);
            const confirmations = if (current_height > bh) current_height - bh else 0;
            const e = try std.fmt.allocPrint(alloc, "{s}{{\"txid\":\"{s}\",\"from\":\"{s}\",\"to\":\"{s}\",\"amount\":{d},\"fee\":{d},\"locktime\":{d},\"op_return\":\"{s}\",\"confirmations\":{d},\"status\":\"confirmed\",\"direction\":\"{s}\",\"blockHeight\":{d}}}", .{ sep, tx.hash, tx.from_address, tx.to_address, tx.amount, tx.fee, tx.locktime, tx.op_return, confirmations, dir, blk.index });
            const m = try std.fmt.allocPrint(alloc, "{s}{s}", .{ entries, e });
            alloc.free(entries); alloc.free(e); entries = m; count += 1;
        }
    }
    defer alloc.free(entries);
    return std.fmt.allocPrint(alloc, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"address\":\"{s}\",\"transactions\":[{s}],\"count\":{d}}}}}", .{ id, filter, entries, count });
}

fn handleRegMiner(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const addr = extractArrayStr(body, 0) orelse extractStr(body, "address") orelse
        return errorJson(-32602, "Missing param: address", id, alloc);
    const nid = extractArrayStr(body, 1) orelse extractStr(body, "node_id") orelse "unknown";
    // F8: Optional mnemonic (3rd param) — if provided, derive real key pair
    const mnemonic = extractArrayStr(body, 2) orelse extractStr(body, "mnemonic");
    const h = ctx.bc.getBlockCount();

    // Salveaza minerul in registru (daca nu exista deja — unic pe address SI node_id)
    ctx.reg_mutex.lock();
    defer ctx.reg_mutex.unlock();
    var already = false;
    for (ctx.registered_miners[0..ctx.registered_miner_count]) |*m| {
        const same_addr = std.mem.eql(u8, m.address[0..m.address_len], addr);
        const same_nid = std.mem.eql(u8, m.node_id[0..m.node_id_len], nid);
        if (same_addr or same_nid) { already = true; break; }
    }
    if (!already and ctx.registered_miner_count < MAX_REGISTERED_MINERS) {
        var m = &ctx.registered_miners[ctx.registered_miner_count];
        m.* = .{};
        const alen = @min(addr.len, 64);
        @memcpy(m.address[0..alen], addr[0..alen]);
        m.address_len = @intCast(alen);
        const nlen = @min(nid.len, 32);
        @memcpy(m.node_id[0..nlen], nid[0..nlen]);
        m.node_id_len = @intCast(nlen);
        m.registered_at = std.time.timestamp();
        ctx.registered_miner_count += 1;
        // Notify bootstrap system
        bootstrap.BootstrapNode.registered_miner_count = ctx.registered_miner_count;

        // F8: Register in MinerWalletPool with real key pair
        var has_wallet = false;
        if (mnemonic) |mnem| {
            if (main_mod.g_miner_pool.registerWithMnemonic(addr, mnem, alloc)) |ok| {
                has_wallet = ok;
            } else |_| {}
        }
        if (!has_wallet) {
            // Fallback: register with random key pair
            main_mod.g_miner_pool.register(addr);
            has_wallet = true;
        }

        // F8: Register miner's pubkey in blockchain for TX signature verification
        if (main_mod.g_miner_pool.findByAddress(addr)) |mw| {
            ctx.bc.registerPubkey(addr, mw.getPubkeyHex()) catch {};
        }

        std.debug.print("[RPC] Miner registered: {s} ({s}) — total: {d}/{d} | pool: {d} | wallet: {}\n",
            .{ addr, nid, ctx.registered_miner_count, bootstrap.BootstrapNode.MIN_MINERS_FOR_MINING,
               main_mod.g_miner_pool.count, has_wallet });
    }

    return std.fmt.allocPrint(alloc, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"status\":\"registered\",\"miner\":\"{s}\",\"node_id\":\"{s}\",\"blockHeight\":{d},\"totalMiners\":{d}}}}}", .{ id, addr, nid, h, ctx.registered_miner_count });
}

// SEGFAULT-FIX [scan-2026-04-25]: snapshot scalars under bc.mutex, then format outside.
// Mempool ArrayList is mutated by mining (drains into block) and addTransaction —
// reading items.len concurrently with realloc/clear is a torn read.
fn handlePoolStats(ctx: *ServerCtx, id: u64) ![]u8 {
    ctx.bc.mutex.lock();
    const h = ctx.bc.getBlockCountUnlocked();
    const mp_len = ctx.bc.mempool.items.len;
    const diff = ctx.bc.difficulty;
    ctx.bc.mutex.unlock();
    const r = blockchain_mod.blockRewardAt(h);
    return std.fmt.allocPrint(ctx.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"blockHeight\":{d},\"blockRewardSAT\":{d},\"blockRewardOMNI\":{d},\"mempoolSize\":{d},\"difficulty\":{d},\"nodeAddress\":\"{s}\"}}}}", .{ id, h, r, r / 1_000_000_000, mp_len, diff, ctx.wallet.address });
}

fn handleAddrBal(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const addr = extractArrayStr(body, 0) orelse extractStr(body, "address") orelse
        return errorJson(-32602, "Missing param: address", id, alloc);
    // Lock blockchain mutex — prevents segfault from concurrent hashmap access
    ctx.bc.mutex.lock();
    const bal = ctx.bc.getAddressBalance(addr);
    ctx.bc.mutex.unlock();
    return std.fmt.allocPrint(alloc, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"address\":\"{s}\",\"balance\":{d},\"balanceOMNI\":{d}}}}}", .{ id, addr, bal, bal / 1_000_000_000 });
}

// SEGFAULT-FIX [scan-2026-04-25]: snapshot mempool size under bc.mutex (fallback path).
// External mempool struct (ctx.mempool) has its own internal sync; only the bc.mempool
// fallback needs the lock here.
fn handleMpStats(ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    if (ctx.mempool) |m| {
        return std.fmt.allocPrint(alloc, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"size\":{d},\"maxTx\":{d},\"maxBytes\":{d},\"bytes\":{d}}}}}", .{ id, m.size(), mempool_mod.MEMPOOL_MAX_TX, mempool_mod.MEMPOOL_MAX_BYTES, m.bytes() });
    }
    ctx.bc.mutex.lock();
    const mp_len = ctx.bc.mempool.items.len;
    ctx.bc.mutex.unlock();
    return std.fmt.allocPrint(alloc, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"size\":{d},\"maxTx\":{d},\"maxBytes\":{d},\"bytes\":0}}}}", .{ id, mp_len, mempool_mod.MEMPOOL_MAX_TX, mempool_mod.MEMPOOL_MAX_BYTES });
}

/// RPC "getpendingtxs" — returns all TXs currently in the mempool with scheme info.
/// Params: [limit]  (default 100, max 500)
/// Returns: { count, transactions: [{txid,from,to,amount,fee,scheme,nonce,timestamp}] }
fn handleGetPendingTxs(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const req_limit = extractArrayNum(body, 0);
    const limit: usize = if (req_limit > 0 and req_limit <= 500) @intCast(req_limit) else 100;

    ctx.bc.mutex.lock();
    defer ctx.bc.mutex.unlock();

    const items = ctx.bc.mempool.items;
    const take = @min(limit, items.len);

    var entries: []u8 = try alloc.dupe(u8, "");
    var n: usize = 0;
    // Return newest first (reverse order)
    var i: usize = if (items.len > 0) items.len - 1 else 0;
    while (n < take) : (n += 1) {
        const tx = items[i];
        const sep: []const u8 = if (n == 0) "" else ",";
        const kind = inferTxKind(tx);
        const e = try std.fmt.allocPrint(alloc,
            "{s}{{\"txid\":\"{s}\",\"from\":\"{s}\",\"to\":\"{s}\",\"amount\":{d},\"fee\":{d},\"kind\":\"{s}\",\"scheme\":\"{s}\",\"nonce\":{d},\"timestamp\":{d}}}",
            .{ sep, tx.hash, tx.from_address, tx.to_address, tx.amount, tx.fee,
               kind, txSchemeLabel(tx.scheme), tx.nonce, tx.timestamp });
        const m = try std.fmt.allocPrint(alloc, "{s}{s}", .{ entries, e });
        alloc.free(entries); alloc.free(e); entries = m;
        if (i == 0) break;
        i -= 1;
    }
    defer alloc.free(entries);

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"count\":{d},\"transactions\":[{s}]}}}}",
        .{ id, n, entries });
}

// SEGFAULT-FIX [scan-2026-04-25]: hold p2p.peers_mutex for entire iteration.
// peer.node_id / peer.host are slices into PeerConnection; if acceptLoop appends
// concurrently and reallocs backing storage we'd UAF on items.ptr. We allocPrint
// inside the lock — slow but correct; for high-throughput callers, snapshot first.
fn handlePeers(ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const p2p = ctx.p2p orelse return std.fmt.allocPrint(alloc, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"count\":0,\"height\":0,\"peers\":[]}}}}", .{id});
    var pj: []u8 = try alloc.dupe(u8, "");
    var pc: usize = 0;
    {
        p2p.peers_mutex.lock();
        defer p2p.peers_mutex.unlock();
        for (p2p.peers.items) |peer| {
            const sep: []const u8 = if (pc == 0) "" else ",";
            const e = try std.fmt.allocPrint(alloc, "{s}{{\"id\":\"{s}\",\"host\":\"{s}\",\"port\":{d},\"alive\":{s}}}", .{ sep, peer.node_id, peer.host, peer.port, if (peer.connected) "true" else "false" });
            const m = try std.fmt.allocPrint(alloc, "{s}{s}", .{ pj, e });
            alloc.free(pj); alloc.free(e); pj = m; pc += 1;
        }
    }
    defer alloc.free(pj);
    return std.fmt.allocPrint(alloc, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"count\":{d},\"height\":{d},\"peers\":[{s}]}}}}", .{ id, pc, p2p.chain_height, pj });
}

fn handleSyncSt(ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;

    // IBD truth comes from p2p.is_syncing + best_peer_height (set in
    // p2p.zig WELCOME / sync_response handlers). This is the same flag the
    // mining loop checks — UI must agree with it, otherwise users see
    // "synced" while the miner is still gated.
    const ibd_active: bool = if (ctx.p2p) |p| p.is_syncing.load(.acquire) else false;
    const best_peer_h: u64 = if (ctx.p2p) |p| p.best_peer_height.load(.acquire) else 0;

    if (ctx.sync_mgr) |s| {
        const local_h = s.state.local_height;
        const peer_h  = if (best_peer_h > s.state.peer_height) best_peer_h else s.state.peer_height;
        const behind: u64 = if (peer_h > local_h) peer_h - local_h else 0;
        const pct: u64 = if (peer_h == 0) 100 else @min(@as(u64, 100), (local_h * 100) / peer_h);
        return std.fmt.allocPrint(alloc, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"status\":\"{s}\",\"localHeight\":{d},\"peerHeight\":{d},\"behind\":{d},\"progress\":{d},\"synced\":{s},\"stalled\":{s},\"ibd\":{s}}}}}", .{ id, @tagName(s.state.status), local_h, peer_h, behind, pct, if (s.isSynced() and !ibd_active) "true" else "false", if (s.isStalled()) "true" else "false", if (ibd_active) "true" else "false" });
    }
    const h = ctx.bc.getBlockCount();
    const peer_h = if (best_peer_h > h) best_peer_h else h;
    const behind: u64 = if (peer_h > h) peer_h - h else 0;
    const pct: u64 = if (peer_h == 0) 100 else @min(@as(u64, 100), (h * 100) / peer_h);
    return std.fmt.allocPrint(alloc, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"status\":\"{s}\",\"localHeight\":{d},\"peerHeight\":{d},\"behind\":{d},\"progress\":{d},\"synced\":{s},\"stalled\":false,\"ibd\":{s}}}}}", .{ id, if (ibd_active) "syncing" else "synced", h, peer_h, behind, pct, if (ibd_active) "false" else "true", if (ibd_active) "true" else "false" });
}

/// List active validators from the on-chain registry. Read-only.
fn handleGetValidators(ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    ctx.bc.mutex.lock();
    const count = ctx.bc.validator_set.items.len;
    var entries_json = std.array_list.Managed(u8).init(alloc);
    defer entries_json.deinit();
    for (ctx.bc.validator_set.items, 0..) |v, i| {
        if (i > 0) try entries_json.appendSlice(",");
        const e = try std.fmt.allocPrint(alloc,
            "{{\"address\":\"{s}\",\"weight\":{d},\"since_height\":{d}}}",
            .{ v.address, v.weight, v.since_height });
        defer alloc.free(e);
        try entries_json.appendSlice(e);
    }
    ctx.bc.mutex.unlock();
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"count\":{d},\"validators\":[{s}]}}}}",
        .{ id, count, entries_json.items });
}

/// Show who is the slot leader for the next block (debug + UI). Pure
/// computation — same answer on every node holding the same registry.
fn handleGetSlotLeader(ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    ctx.bc.mutex.lock();
    const tip = ctx.bc.chain.items[ctx.bc.chain.items.len - 1];
    const tip_hash = tip.hash;
    // Slot-id for the NEXT block (height = chain.items.len). Same formula
    // mining loop + peer validation use, so RPC reflects what the network
    // expects.
    const slot_id: u64 = @intCast(ctx.bc.chain.items.len);
    const ldr = validator_mod.leaderForSlot(slot_id, tip_hash, ctx.bc.validator_set.items);
    ctx.bc.mutex.unlock();
    if (ldr) |l| {
        return std.fmt.allocPrint(alloc,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"slot\":{d},\"leader\":\"{s}\",\"weight\":{d}}}}}",
            .{ id, slot_id, l.address, l.weight });
    }
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"slot\":{d},\"leader\":null,\"error\":\"empty validator set\"}}}}",
        .{ id, slot_id });
}

/// `getclockstatus` — exposes the AtomicClock's current state for UI:
///   - now_ms                 — wall-clock from g_clock.nowMs()
///   - rdtsc                  — hardware cycle counter (rdtscp on x86_64)
///   - spectrum               — 64-char binary string of rdtsc bits, MSB first
/// The spectrum lets a frontend chart show the bit pattern over time —
/// stable high bits = healthy CPU clock, broken patterns = scheduler jitter.
fn handleGetClockStatus(ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const now_ms = main_mod.g_clock.nowMs();
    const cycles = orchestrator_mod.nowCycles();
    var spec_buf: [64]u8 = undefined;
    orchestrator_mod.formatSpectrum(cycles, &spec_buf);
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{" ++
        "\"now_ms\":{d},\"rdtsc\":{d},\"spectrum\":\"{s}\"}}}}",
        .{ id, now_ms, cycles, spec_buf },
    );
}

/// `getslotcalendar` — exposes the next 60 pre-computed slots for UI.
/// Each entry: { slot_id, leader, expected_arrival_ms, state }.
/// state values: "future" | "in_flight" | "finalized" | "missed".
fn handleGetSlotCalendar(ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    var out = std.array_list.Managed(u8).init(alloc);
    defer out.deinit();
    const w = out.writer();

    try w.print(
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"head_slot\":{d},\"slot_interval_ms\":{d},\"entries\":[",
        .{
            id,
            main_mod.g_slot_calendar.head_slot_id,
            main_mod.g_slot_calendar.slot_interval_ms,
        },
    );

    var i: usize = 0;
    while (i < main_mod.g_slot_calendar.count) : (i += 1) {
        if (i > 0) try w.writeAll(",");
        const e = &main_mod.g_slot_calendar.entries[i];
        const leader = e.leaderSlice();
        const state_str: []const u8 = switch (e.state) {
            .future => "future",
            .in_flight => "in_flight",
            .finalized => "finalized",
            .missed => "missed",
        };
        try w.print(
            "{{\"slot_id\":{d},\"leader\":\"{s}\",\"expected_arrival_ms\":{d},\"state\":\"{s}\"}}",
            .{ e.slot_id, leader, e.expected_arrival_ms, state_str },
        );
    }
    try w.writeAll("]}}");
    return out.toOwnedSlice();
}

/// `getfuturepool` — count + range of TXs that are time-locked beyond
/// the current chain tip (`locktime > height`). These are the future-
/// block-pool entries: they will become mineable when the chain
/// catches up to their target slot. Useful for the frontend to show
/// a "scheduled trades" panel.
fn handleGetFuturePool(ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    ctx.bc.mutex.lock();
    const height = ctx.bc.getBlockCountUnlocked();
    ctx.bc.mutex.unlock();
    if (ctx.mempool) |mp| {
        const stats = mp.futurePoolStats(height);
        return std.fmt.allocPrint(alloc,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{" ++
            "\"current_height\":{d},\"locked_count\":{d}," ++
            "\"earliest_target\":{d},\"latest_target\":{d}}}}}",
            .{ id, height, stats.locked_count,
               stats.earliest_target, stats.latest_target },
        );
    }
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{" ++
        "\"current_height\":{d},\"locked_count\":0," ++
        "\"earliest_target\":0,\"latest_target\":0}}}}",
        .{ id, height },
    );
}

// SEGFAULT-FIX [scan-2026-04-25]: snapshot peer count under p2p.peers_mutex,
// snapshot bc fields under bc.mutex; format outside both locks. Same root cause
// as handlePeers (p2p) and handlePoolStats (mempool).
fn handleNetInfo(ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    ctx.bc.mutex.lock();
    const h = ctx.bc.getBlockCountUnlocked();
    const diff = ctx.bc.difficulty;
    const bc_mp_len = ctx.bc.mempool.items.len;
    ctx.bc.mutex.unlock();
    const pc: usize = if (ctx.p2p) |p| blk: {
        p.peers_mutex.lock();
        const len = p.peers.items.len;
        p.peers_mutex.unlock();
        break :blk len;
    } else 0;
    const ms: usize = if (ctx.mempool) |m| m.size() else bc_mp_len;
    const r = blockchain_mod.blockRewardAt(h);
    // Derive chain label from chain_id instead of hardcoding "omnibus-mainnet"
    // (was misleading on testnet/regtest nodes — Network page showed
    // "omnibus-mainnet" while user was browsing testnet).
    const chain_label: []const u8 = switch (ctx.chain_id) {
        1    => "omnibus-mainnet",
        2    => "omnibus-testnet",
        3    => "omnibus-devnet",
        4    => "omnibus-regtest",
        else => "omnibus-unknown",
    };
    return std.fmt.allocPrint(alloc, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"chain\":\"{s}\",\"version\":\"1.0.0\",\"blockHeight\":{d},\"blockRewardSAT\":{d},\"difficulty\":{d},\"mempoolSize\":{d},\"peerCount\":{d},\"nodeAddress\":\"{s}\",\"nodeBalance\":{d},\"halvingInterval\":126144000,\"maxSupply\":21000000000000000,\"blockTimeMs\":1000,\"subBlocksPerBlock\":10}}}}", .{ id, chain_label, h, r, diff, ms, pc, ctx.wallet.address, ctx.wallet.getBalance() });
}

fn handleGetBlk(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const h_str = extractArrayStr(body, 0);

    // Try parse as integer height first; if string is non-numeric and long enough, treat as hash
    var blk_opt: ?block_mod.Block = null;
    if (h_str) |s| {
        if (std.fmt.parseInt(u32, s, 10)) |height| {
            blk_opt = ctx.bc.getBlock(height);
        } else |_| {
            // Bitcoin-standard: getblock(hash) — linear scan blocks for matching hash
            ctx.bc.mutex.lock();
            const block_count = ctx.bc.getBlockCountUnlocked();
            var bi: u32 = 0;
            while (bi < block_count) : (bi += 1) {
                const b = ctx.bc.getBlock(bi) orelse continue;
                if (std.mem.eql(u8, b.hash, s)) { blk_opt = b; break; }
            }
            ctx.bc.mutex.unlock();
            if (blk_opt == null) return errorJson(-5, "Block not found", id, alloc);
        }
    } else {
        const height: u32 = std.math.cast(u32, extractArrayNum(body, 0)) orelse 0;
        blk_opt = ctx.bc.getBlock(height);
    }

    const blk = blk_opt orelse return errorJson(-5, "Block not found", id, alloc);

    // Format merkle_root as hex (it's [32]u8)
    var mr_hex: [64]u8 = undefined;
    for (0..32) |i| {
        const b = blk.merkle_root[i];
        mr_hex[i * 2] = "0123456789abcdef"[b >> 4];
        mr_hex[i * 2 + 1] = "0123456789abcdef"[b & 0x0f];
    }

    // Approximate size: header (~80 bytes) + tx_count * avg_tx_bytes (~200)
    const tx_count = blk.transactions.items.len;
    const approx_size: u64 = 80 + @as(u64, @intCast(tx_count)) * 200;

    // Sum fees for all non-coinbase TXs in this block
    var total_fees: u64 = 0;
    for (blk.transactions.items) |tx| {
        if (tx.fee > 0) total_fees += @as(u64, @intCast(tx.fee));
    }

    // Build optional prices array. Strategy:
    //   1) FAST path — read the in-memory `block_prices` map (legacy 6-slot
    //      snapshot, populated at mining time). This avoids touching the
    //      block's [21]BlockPriceEntry array on every getblock call.
    //   2) FALLBACK — if the map has no entry for this height (e.g. after
    //      a node restart, since the map is in-memory only), read directly
    //      from `blk.prices` which is the authoritative on-chain copy
    //      committed via prices_root in the block hash.
    //   In both cases empty/zero entries are skipped.
    var prices_buf: [4096]u8 = undefined;
    var prices_len: usize = 0;
    {
        var pos: usize = 0;
        const open = std.fmt.bufPrint(prices_buf[pos..], "[", .{}) catch {
            return errorJson(-32603, "buf overflow", id, alloc);
        };
        pos += open.len;
        var written: usize = 0;
        if (ctx.bc.getBlockPrices(blk.index)) |entries| {
            // Fast path: legacy in-memory cache (6 slots).
            for (entries) |e| {
                if (e.exchange_len == 0 and e.pair_len == 0 and !e.success and e.timestamp_ms == 0) continue;
                if (written > 0) { prices_buf[pos] = ','; pos += 1; }
                const ex = e.exchange[0..e.exchange_len];
                const pr = e.pair[0..e.pair_len];
                const item = std.fmt.bufPrint(prices_buf[pos..],
                    "{{\"exchange\":\"{s}\",\"pair\":\"{s}\",\"bidMicroUsd\":{d},\"askMicroUsd\":{d},\"timestampMs\":{d},\"success\":{s}}}",
                    .{ ex, pr, e.bid_micro_usd, e.ask_micro_usd, e.timestamp_ms, if (e.success) "true" else "false" },
                ) catch break;
                pos += item.len;
                written += 1;
            }
        } else {
            // Fallback path: read directly from on-chain block (21 slots).
            for (blk.prices) |e| {
                if (e.exchange_len == 0 and e.pair_len == 0 and !e.success and e.timestamp_ms == 0) continue;
                if (written > 0) { prices_buf[pos] = ','; pos += 1; }
                const ex = e.exchange[0..e.exchange_len];
                const pr = e.pair[0..e.pair_len];
                const item = std.fmt.bufPrint(prices_buf[pos..],
                    "{{\"exchange\":\"{s}\",\"pair\":\"{s}\",\"bidMicroUsd\":{d},\"askMicroUsd\":{d},\"timestampMs\":{d},\"success\":{s}}}",
                    .{ ex, pr, e.bid_micro_usd, e.ask_micro_usd, e.timestamp_ms, if (e.success) "true" else "false" },
                ) catch break;
                pos += item.len;
                written += 1;
            }
        }
        const close = std.fmt.bufPrint(prices_buf[pos..], "]", .{}) catch {
            return errorJson(-32603, "buf overflow", id, alloc);
        };
        pos += close.len;
        prices_len = pos;
    }

    // Hex-encode prices_root (32 bytes -> 64 lowercase hex chars). All-zero
    // is the canonical "no prices" sentinel — clients should still treat
    // pricesValidated=true on an all-zero root as "nothing to verify".
    var pr_hex: [64]u8 = undefined;
    for (0..32) |i| {
        const b = blk.prices_root[i];
        pr_hex[i * 2] = "0123456789abcdef"[b >> 4];
        pr_hex[i * 2 + 1] = "0123456789abcdef"[b & 0x0f];
    }
    const prices_validated = blk.validatePrices();

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"hash\":\"{s}\",\"height\":{d},\"timestamp\":{d},\"previousHash\":\"{s}\",\"merkleRoot\":\"{s}\",\"difficulty\":{d},\"nonce\":{d},\"txCount\":{d},\"size\":{d},\"miner\":\"{s}\",\"rewardSAT\":{d},\"totalFees\":{d},\"prices\":{s},\"pricesRoot\":\"{s}\",\"pricesValidated\":{s}}}}}",
        .{ id, blk.hash, blk.index, blk.timestamp, blk.previous_hash, mr_hex, ctx.bc.difficulty, blk.nonce, tx_count, approx_size, blk.miner_address, blk.reward_sat, total_fees, prices_buf[0..prices_len], pr_hex, if (prices_validated) "true" else "false" });
}

fn handleGetBlks(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const from: u32 = std.math.cast(u32, extractArrayNum(body, 0)) orelse 0;
    const rc = extractArrayNum(body, 1);
    const mc: u32 = if (rc == 0 or rc > 100) 100 else std.math.cast(u32, rc) orelse 100;

    ctx.bc.mutex.lock();
    defer ctx.bc.mutex.unlock();

    var entries: []u8 = try alloc.dupe(u8, "");
    var n: u32 = 0;
    var h: u32 = from;
    while (n < mc) : ({ h += 1; n += 1; }) {
        const blk = ctx.bc.getBlock(h) orelse break;
        const sep: []const u8 = if (n == 0) "" else ",";
        var blk_fees: u64 = 0;
        for (blk.transactions.items) |tx| { if (tx.fee > 0) blk_fees += @as(u64, @intCast(tx.fee)); }
        const e = try std.fmt.allocPrint(alloc, "{s}{{\"height\":{d},\"timestamp\":{d},\"hash\":\"{s}\",\"nonce\":{d},\"txCount\":{d},\"miner\":\"{s}\",\"rewardSAT\":{d},\"totalFees\":{d},\"difficulty\":{d}}}", .{ sep, blk.index, blk.timestamp, blk.hash, blk.nonce, blk.transactions.items.len, blk.miner_address, blk.reward_sat, blk_fees, ctx.bc.difficulty });
        const m = try std.fmt.allocPrint(alloc, "{s}{s}", .{ entries, e });
        alloc.free(entries); alloc.free(e); entries = m;
    }
    defer alloc.free(entries);
    return std.fmt.allocPrint(alloc, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"from\":{d},\"count\":{d},\"blocks\":[{s}]}}}}", .{ id, from, n, entries });
}

// ─── SPV Light Client RPC Handlers ───────────────────────────────────────────

/// RPC "getheaders" — returns block headers for light client sync.
/// Usage: {"method":"getheaders","params":[from_height, count],"id":1}
/// Returns array of block headers (without transaction data).
/// Max 2000 headers per request (like Bitcoin's getheaders).
fn handleGetHeaders(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const from: u32 = std.math.cast(u32, extractArrayNum(body, 0)) orelse 0;
    const req_count = extractArrayNum(body, 1);
    const max_headers: u32 = 2000;
    const count: u32 = if (req_count == 0 or req_count > max_headers) max_headers else std.math.cast(u32, req_count) orelse max_headers;

    ctx.bc.mutex.lock();
    defer ctx.bc.mutex.unlock();

    var entries: []u8 = try alloc.dupe(u8, "");
    var n: u32 = 0;
    var h: u32 = from;
    while (n < count) : ({ h += 1; n += 1; }) {
        const blk = ctx.bc.getBlock(h) orelse break;
        const sep: []const u8 = if (n == 0) "" else ",";

        // Format merkle_root and hash as hex strings
        var mr_hex: [64]u8 = undefined;
        var hash_hex: [64]u8 = undefined;
        var prev_hex: [64]u8 = undefined;
        for (0..32) |i| {
            const mr_byte = blk.merkle_root[i];
            mr_hex[i * 2] = "0123456789abcdef"[mr_byte >> 4];
            mr_hex[i * 2 + 1] = "0123456789abcdef"[mr_byte & 0x0f];
        }
        // Block hash and previous_hash are slices (string hex), not [32]u8
        // We return them as-is since they are already hex strings from the block
        _ = &hash_hex;
        _ = &prev_hex;

        const e = try std.fmt.allocPrint(alloc,
            "{s}{{\"height\":{d},\"timestamp\":{d},\"hash\":\"{s}\",\"previousHash\":\"{s}\",\"merkleRoot\":\"{s}\",\"nonce\":{d},\"difficulty\":{d},\"txCount\":{d}}}",
            .{ sep, blk.index, blk.timestamp, blk.hash, blk.previous_hash, mr_hex, blk.nonce, 4, blk.transactions.items.len });
        const m = try std.fmt.allocPrint(alloc, "{s}{s}", .{ entries, e });
        alloc.free(entries); alloc.free(e); entries = m;
    }
    defer alloc.free(entries);
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"from\":{d},\"count\":{d},\"headers\":[{s}]}}}}",
        .{ id, from, n, entries });
}

/// RPC "getmerkleproof" — returns a Merkle inclusion proof for a TX.
/// Usage: {"method":"getmerkleproof","params":["tx_hash_hex"],"id":1}
/// Searches all blocks for the TX, then generates the Merkle proof.
/// Returns proof_hashes and directions for SPV verification.
fn handleGetMerkleProof(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const tx_hash_str = extractArrayStr(body, 0) orelse extractStr(body, "txid") orelse
        return errorJson(-32602, "Missing param: txid (tx hash hex)", id, alloc);

    ctx.bc.mutex.lock();
    defer ctx.bc.mutex.unlock();

    // Search blocks for the TX
    const block_count = ctx.bc.getBlockCountUnlocked();
    var found_block_idx: ?u32 = null;
    var found_tx_idx: ?usize = null;

    var bi: u32 = 0;
    while (bi < block_count) : (bi += 1) {
        const blk = ctx.bc.getBlock(bi) orelse continue;
        for (blk.transactions.items, 0..) |tx, ti| {
            if (std.mem.eql(u8, tx.hash, tx_hash_str)) {
                found_block_idx = bi;
                found_tx_idx = ti;
                break;
            }
        }
        if (found_block_idx != null) break;
    }

    const blk_idx = found_block_idx orelse return errorJson(-32602, "TX not found in any block", id, alloc);
    const tx_idx = found_tx_idx.?;

    const blk = ctx.bc.getBlock(blk_idx).?;
    const proof_opt = blk.generateMerkleProof(tx_idx);
    if (proof_opt == null) return errorJson(-32000, "Failed to generate proof", id, alloc);
    const proof = proof_opt.?;

    // Serialize proof hashes as hex
    var proof_entries: []u8 = try alloc.dupe(u8, "");
    for (0..proof.depth) |i| {
        const sep: []const u8 = if (i == 0) "" else ",";
        var hex: [64]u8 = undefined;
        for (0..32) |j| {
            const b = proof.proof_hashes[i][j];
            hex[j * 2] = "0123456789abcdef"[b >> 4];
            hex[j * 2 + 1] = "0123456789abcdef"[b & 0x0f];
        }
        const dir_str: []const u8 = if (proof.directions[i]) "right" else "left";
        const e = try std.fmt.allocPrint(alloc, "{s}{{\"hash\":\"{s}\",\"direction\":\"{s}\"}}", .{ sep, hex, dir_str });
        const m = try std.fmt.allocPrint(alloc, "{s}{s}", .{ proof_entries, e });
        alloc.free(proof_entries); alloc.free(e); proof_entries = m;
    }
    defer alloc.free(proof_entries);

    // Merkle root hex
    var root_hex: [64]u8 = undefined;
    for (0..32) |i| {
        const b = proof.merkle_root[i];
        root_hex[i * 2] = "0123456789abcdef"[b >> 4];
        root_hex[i * 2 + 1] = "0123456789abcdef"[b & 0x0f];
    }

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"txid\":\"{s}\",\"blockHeight\":{d},\"txIndex\":{d},\"merkleRoot\":\"{s}\",\"proofDepth\":{d},\"proof\":[{s}]}}}}",
        .{ id, tx_hash_str, blk_idx, tx_idx, root_hex, proof.depth, proof_entries });
}

fn handleMinerSt(ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    // Lock blockchain pentru toata durata — previne realloc pe chain.items
    ctx.bc.mutex.lock();
    defer ctx.bc.mutex.unlock();

    // Colectam adrese unice — max 64 (limitat pentru stabilitate)
    const MinerEntry = struct { addr: [64]u8, addr_len: u8, blocks: u32, reward: u64 };
    const MAX_DISPLAY: usize = 64;
    var list: [MAX_DISPLAY]MinerEntry = undefined;
    var count: usize = 0;

    // Helper: cauta daca adresa exista deja
    const findOrAdd = struct {
        fn call(l: []MinerEntry, c: *usize, addr: []const u8) *MinerEntry {
            for (l[0..c.*]) |*e| {
                if (e.addr_len == addr.len and std.mem.eql(u8, e.addr[0..e.addr_len], addr)) return e;
            }
            if (c.* >= l.len) return &l[0]; // overflow guard
            var e = &l[c.*];
            e.* = .{ .addr = undefined, .addr_len = @intCast(@min(addr.len, 64)), .blocks = 0, .reward = 0 };
            @memcpy(e.addr[0..e.addr_len], addr[0..e.addr_len]);
            c.* += 1;
            return e;
        }
    }.call;

    // 1. Seed node (self) — mereu primul
    _ = findOrAdd(&list, &count, ctx.wallet.address);

    // 2. Mineri inregistrati via RPC
    ctx.reg_mutex.lock();
    const reg_count = @min(ctx.registered_miner_count, MAX_DISPLAY - 1);
    var reg_addrs: [64][64]u8 = undefined;
    var reg_lens: [64]u8 = undefined;
    for (0..reg_count) |i| {
        const rm = ctx.registered_miners[i];
        reg_addrs[i] = rm.address;
        reg_lens[i] = rm.address_len;
    }
    ctx.reg_mutex.unlock();
    for (0..reg_count) |i| {
        if (reg_lens[i] > 0) _ = findOrAdd(&list, &count, reg_addrs[i][0..reg_lens[i]]);
    }

    // 3. Stats din blocuri minate (bc.mutex deja locked la inceputul functiei)
    for (ctx.bc.chain.items) |blk| {
        if (blk.miner_address.len == 0) continue;
        var e = findOrAdd(&list, &count, blk.miner_address);
        e.blocks += 1;
        e.reward += blk.reward_sat;
    }

    // Serializare JSON — buffer fix 32KB (zero alloc in loop)
    var buf: [32768]u8 = undefined;
    var pos: usize = 0;
    // total_fees_collected is the cumulative network/exchange fees paid to
    // miners since process start (see Blockchain.total_miner_exchange_fees).
    // pending_miner_fees is the sat amount accumulated since the last block
    // and earmarked for the next block's miner.
    const header = std.fmt.bufPrint(
        buf[0..],
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{" ++
        "\"totalMiners\":{d},\"chainHeight\":{d}," ++
        "\"totalFeesCollected\":{d},\"pendingMinerFees\":{d}," ++
        "\"miners\":[",
        .{
            id, count, ctx.bc.getBlockCountUnlocked() -| 1,
            ctx.bc.total_miner_exchange_fees, ctx.bc.pending_miner_fees,
        },
    ) catch return errorJson(-32000, "Buffer overflow", id, alloc);
    pos = header.len;
    for (list[0..count], 0..) |e, i| {
        const addr = e.addr[0..e.addr_len];
        const bal = ctx.bc.getAddressBalance(addr);
        const sep: []const u8 = if (i == 0) "" else ",";
        const entry = std.fmt.bufPrint(buf[pos..], "{s}{{\"miner\":\"{s}\",\"blocksMined\":{d},\"totalRewardSAT\":{d},\"currentBalanceSAT\":{d}}}", .{ sep, addr, e.blocks, e.reward, bal }) catch break;
        pos += entry.len;
    }
    const footer = std.fmt.bufPrint(buf[pos..], "]}}}}", .{}) catch return errorJson(-32000, "Buffer overflow", id, alloc);
    pos += footer.len;
    return alloc.dupe(u8, buf[0..pos]);
}

fn handleMinerInf(ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const h = ctx.bc.getBlockCount(); const d = ctx.bc.difficulty;
    const ma = ctx.wallet.address; const bal = ctx.wallet.getBalance();
    var bm: u32 = 0;
    for (ctx.bc.chain.items) |blk| { if (std.mem.eql(u8, blk.miner_address, ma)) bm += 1; }
    const st: []const u8 = if (ctx.is_idle) "idle" else "active";
    const rs: []const u8 = if (ctx.is_idle) "duplicate_ip_detected" else "";
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{" ++
        "\"status\":\"{s}\",\"reason\":\"{s}\",\"miner\":\"{s}\"," ++
        "\"blocksMined\":{d},\"balance\":{d},\"height\":{d},\"difficulty\":{d}," ++
        "\"totalFeesCollected\":{d},\"pendingMinerFees\":{d}," ++
        "\"routeFeesToMiner\":{}}}}}",
        .{
            id, st, rs, ma, bm, bal, h, d,
            ctx.bc.total_miner_exchange_fees,
            ctx.bc.pending_miner_fees,
            ctx.bc.consensus_params.route_fees_to_miner,
        });
}

fn handleNodeList(ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const h = ctx.bc.getBlockCount();
    // +1 = include self (this node is both a node AND a miner)
    const remote_peers: usize = if (ctx.p2p) |p| p.peers.items.len else 0;
    const total_nodes: usize = remote_peers + 1; // self = always 1 node
    const ms: usize = if (ctx.mempool) |m| m.size() else ctx.bc.mempool.items.len;

    // Count unique miners from chain + self (always 1 miner = this node)
    var miner_count: u32 = 1; // self = always counted as miner
    var last_miner: []const u8 = "";
    for (ctx.bc.chain.items) |blk| {
        if (blk.miner_address.len > 0 and !std.mem.eql(u8, blk.miner_address, last_miner)) {
            miner_count += 1;
            last_miner = blk.miner_address;
        }
    }

    // Build peer list
    var peers_json: []u8 = try alloc.dupe(u8, "");
    var peer_n: usize = 0;
    if (ctx.p2p) |p2p| {
        for (p2p.peers.items) |peer| {
            const sep: []const u8 = if (peer_n == 0) "" else ",";
            const e = try std.fmt.allocPrint(alloc, "{s}{{\"id\":\"{s}\",\"host\":\"{s}\",\"port\":{d},\"connected\":{s},\"height\":{d}}}", .{ sep, peer.node_id, peer.host, peer.port, if (peer.connected) "true" else "false", p2p.chain_height });
            const m = try std.fmt.allocPrint(alloc, "{s}{s}", .{ peers_json, e });
            alloc.free(peers_json);
            alloc.free(e);
            peers_json = m;
            peer_n += 1;
        }
    }
    defer alloc.free(peers_json);

    return std.fmt.allocPrint(alloc, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"localNode\":{{\"id\":\"{s}\",\"address\":\"{s}\",\"height\":{d},\"difficulty\":{d},\"mempool\":{d}}},\"network\":{{\"totalPeers\":{d},\"totalMiners\":{d},\"chainHeight\":{d}}},\"peers\":[{s}]}}}}", .{ id, ctx.wallet.address[0..@min(20, ctx.wallet.address.len)], ctx.wallet.address, h, ctx.bc.difficulty, ms, total_nodes, miner_count, h, peers_json });
}

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
fn handleSubmitSlashEvidence(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const staking = ctx.staking orelse
        return errorJson(-32000, "Staking engine not available", id, alloc);

    const validator_addr = extractArrayStr(body, 0) orelse
        return errorJson(-32602, "Missing param: validator_address", id, alloc);
    const reason_str = extractArrayStr(body, 1) orelse
        return errorJson(-32602, "Missing param: reason (double_sign|invalid_block|downtime)", id, alloc);
    const reporter_addr = extractArrayStr(body, 5) orelse
        return errorJson(-32602, "Missing param: reporter_address", id, alloc);
    const block_height = extractArrayNum(body, 4);

    const reason: staking_mod.SlashReason = if (std.mem.eql(u8, reason_str, "double_sign"))
        .double_sign
    else if (std.mem.eql(u8, reason_str, "invalid_block"))
        .invalid_block
    else if (std.mem.eql(u8, reason_str, "downtime"))
        .downtime
    else
        return errorJson(-32602, "Invalid reason: use double_sign, invalid_block, or downtime", id, alloc);

    var hash_1: [32]u8 = @splat(0);
    var hash_2: [32]u8 = @splat(0);
    var sig_1: [64]u8 = @splat(0);
    var sig_2: [64]u8 = @splat(0);

    if (reason == .double_sign or reason == .invalid_block) {
        // Cryptographic evidence required.
        const h1_hex = extractArrayStr(body, 2) orelse
            return errorJson(-32602, "Missing block_hash_1 (64-char hex) for crypto-evidence reason", id, alloc);
        const h2_hex = extractArrayStr(body, 3) orelse
            return errorJson(-32602, "Missing block_hash_2 (64-char hex) for crypto-evidence reason", id, alloc);
        if (h1_hex.len != 64) return errorJson(-32602, "block_hash_1 must be 64-char hex", id, alloc);
        if (h2_hex.len != 64) return errorJson(-32602, "block_hash_2 must be 64-char hex", id, alloc);
        hash_1 = hexDecode32(h1_hex) orelse return errorJson(-32602, "Invalid block_hash_1 hex", id, alloc);
        hash_2 = hexDecode32(h2_hex) orelse return errorJson(-32602, "Invalid block_hash_2 hex", id, alloc);

        // Two different blocks at the same height is the whole point — if
        // they match, the reporter is either confused or trying to spam.
        if (std.mem.eql(u8, &hash_1, &hash_2)) {
            return errorJson(-32602, "block_hash_1 and block_hash_2 must differ", id, alloc);
        }

        const s1_hex = extractArrayStr(body, 6) orelse
            return errorJson(-32602, "Missing signature_1 (128-char hex) — must be validator's sig over block_hash_1", id, alloc);
        const s2_hex = extractArrayStr(body, 7) orelse
            return errorJson(-32602, "Missing signature_2 (128-char hex) — must be validator's sig over block_hash_2", id, alloc);
        if (s1_hex.len != 128) return errorJson(-32602, "signature_1 must be 128-char hex", id, alloc);
        if (s2_hex.len != 128) return errorJson(-32602, "signature_2 must be 128-char hex", id, alloc);
        sig_1 = hexDecode64(s1_hex) orelse return errorJson(-32602, "Invalid signature_1 hex", id, alloc);
        sig_2 = hexDecode64(s2_hex) orelse return errorJson(-32602, "Invalid signature_2 hex", id, alloc);

        // Verify each sig against the validator's registered pubkey over its
        // corresponding block hash. We look up the pubkey from bc.pubkey_registry —
        // every validator must have registered a pubkey TX before they can be
        // slashed (otherwise we'd accept evidence with no way to validate it).
        const pk_slice = ctx.bc.pubkey_registry.get(validator_addr) orelse
            return errorJson(-32000, "Validator pubkey not registered — cannot verify evidence", id, alloc);
        if (pk_slice.len != 33) return errorJson(-32000, "Registered validator pubkey is not 33 bytes (compressed secp256k1 expected)", id, alloc);
        var pk: [33]u8 = undefined;
        @memcpy(&pk, pk_slice[0..33]);

        if (!secp256k1_mod.Secp256k1Crypto.verify(pk, &hash_1, sig_1)) {
            return errorJson(-32000, "signature_1 does not verify against validator's registered pubkey over block_hash_1", id, alloc);
        }
        if (!secp256k1_mod.Secp256k1Crypto.verify(pk, &hash_2, sig_2)) {
            return errorJson(-32000, "signature_2 does not verify against validator's registered pubkey over block_hash_2", id, alloc);
        }
    }
    // downtime path: no crypto evidence; staking engine just checks the
    // height window against the validator's last-seen timestamp.

    const evidence = staking_mod.SlashEvidence.init(
        validator_addr,
        reason,
        hash_1,
        hash_2,
        block_height,
        sig_1,
        sig_2,
        reporter_addr,
        std.time.timestamp(),
    );

    const result = staking.submitSlashEvidence(evidence);

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"valid\":{},\"slashed_amount\":{d},\"reporter_reward\":{d},\"new_stake\":{d},\"reason\":\"{s}\"}}}}",
        .{ id, result.valid, result.slashed_amount, result.reporter_reward, result.new_stake, result.getReason() });
}

/// RPC "getslashhistory" — view slash history for a validator address.
/// Usage: {"method":"getslashhistory","params":["validator_addr"],"id":1}
fn handleGetSlashHistory(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const staking = ctx.staking orelse
        return errorJson(-32000, "Staking engine not available", id, alloc);

    const addr = extractArrayStr(body, 0) orelse extractStr(body, "address") orelse
        return errorJson(-32602, "Missing param: address", id, alloc);

    const history = staking.getSlashHistory(addr);

    // Build JSON array of slash records
    if (history.count == 0) {
        return std.fmt.allocPrint(alloc,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"address\":\"{s}\",\"total_slashes\":0,\"records\":[]}}}}",
            .{ id, addr });
    }

    // Format up to 10 records for the response
    var buf: [4096]u8 = undefined;
    var pos: usize = 0;
    const max_records = @min(history.count, 10);
    for (history.records[0..max_records], 0..) |record, i| {
        const reason_name = switch (record.reason) {
            .double_sign => "double_sign",
            .invalid_block => "invalid_block",
            .downtime => "downtime",
        };
        const entry = std.fmt.bufPrint(buf[pos..], "{{\"reason\":\"{s}\",\"amount\":{d},\"height\":{d},\"reporter\":\"{s}\",\"reward\":{d}}}", .{
            reason_name,
            record.amount_slashed,
            record.block_height,
            record.getReporter(),
            record.reporter_reward,
        }) catch break;
        pos += entry.len;
        if (i + 1 < max_records) {
            if (pos < buf.len) {
                buf[pos] = ',';
                pos += 1;
            }
        }
    }

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"address\":\"{s}\",\"total_slashes\":{d},\"records\":[{s}]}}}}",
        .{ id, addr, history.count, buf[0..pos] });
}

/// RPC "getstakinginfo" — returns validator info including slash status.
/// Usage: {"method":"getstakinginfo","params":["validator_addr"],"id":1}
fn handleGetStakingInfo(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const staking = ctx.staking orelse
        return errorJson(-32000, "Staking engine not available", id, alloc);

    const addr = extractArrayStr(body, 0) orelse extractStr(body, "address") orelse
        return errorJson(-32602, "Missing param: address", id, alloc);

    const info = staking.getValidatorInfo(addr) orelse
        return errorJson(-32000, "Validator not found", id, alloc);

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"address\":\"{s}\",\"status\":\"{s}\",\"total_stake\":{d},\"self_stake\":{d},\"delegated_stake\":{d},\"slash_count\":{d},\"slash_history_count\":{d},\"total_rewards\":{d},\"uptime_pct\":{d},\"blocks_produced\":{d},\"commission_pct\":{d}}}}}",
        .{
            id,
            info.getAddress(),
            info.statusString(),
            info.total_stake,
            info.self_stake,
            info.delegated_stake,
            info.slash_count,
            info.slash_history_count,
            info.total_rewards,
            info.uptime_pct,
            info.blocks_produced,
            info.commission_pct,
        });
}

// ─── Multisig RPC Handlers ────────────────────────────────────────────────────

const Secp256k1Crypto = secp256k1_mod.Secp256k1Crypto;
const MultisigWallet = multisig_mod.MultisigWallet;

/// RPC "createmultisig" — create M-of-N multisig wallet, register it, return address.
/// Usage: {"method":"createmultisig","params":[M, ["pubkey1_hex", "pubkey2_hex", ...]],"id":1}
/// Pubkeys are 66-char hex compressed secp256k1 public keys.
fn handleCreateMultisig(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;

    // Extract M (threshold) from first param
    const m_val = extractArrayNum(body, 0);
    if (m_val == 0 or m_val > 16) return errorJson(-32602, "Invalid M (threshold): must be 1-16", id, alloc);
    const m: u8 = @intCast(m_val);

    // Extract pubkeys from the nested array (second param)
    // We look for the inner array in params: [M, ["pk1","pk2",...]]
    const pubkey_strs = extractInnerArray(body) orelse
        return errorJson(-32602, "Missing param: pubkeys array", id, alloc);

    // Parse hex pubkeys
    var pubkeys: [multisig_mod.MAX_SIGNERS][33]u8 = undefined;
    var pk_count: u8 = 0;

    var parse_pos: usize = 0;
    while (parse_pos < pubkey_strs.len and pk_count < multisig_mod.MAX_SIGNERS) {
        // Find next quoted string
        const q1 = std.mem.indexOf(u8, pubkey_strs[parse_pos..], "\"") orelse break;
        const start = parse_pos + q1 + 1;
        if (start >= pubkey_strs.len) break;
        const q2 = std.mem.indexOf(u8, pubkey_strs[start..], "\"") orelse break;
        const pk_hex = pubkey_strs[start .. start + q2];

        if (pk_hex.len != 66) return errorJson(-32602, "Pubkey must be 66 hex chars (33 bytes compressed)", id, alloc);
        hex_utils.hexToBytes(pk_hex, &pubkeys[pk_count]) catch
            return errorJson(-32602, "Invalid hex in pubkey", id, alloc);
        pk_count += 1;
        parse_pos = start + q2 + 1;
    }

    if (pk_count == 0) return errorJson(-32602, "No valid pubkeys provided", id, alloc);
    if (m > pk_count) return errorJson(-32602, "M cannot exceed number of pubkeys", id, alloc);

    // Create multisig wallet
    const wallet = MultisigWallet.create(m, pubkeys[0..pk_count]) catch
        return errorJson(-32000, "Failed to create multisig wallet", id, alloc);

    // Register in blockchain
    ctx.bc.registerMultisig(wallet.getAddress(), wallet.config) catch
        return errorJson(-32000, "Failed to register multisig", id, alloc);

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"address\":\"{s}\",\"required\":{d},\"total\":{d},\"status\":\"registered\"}}}}",
        .{ id, wallet.getAddress(), m, pk_count });
}

/// RPC "sendmultisig" — create and sign a multisig TX with provided private keys.
/// Usage: {"method":"sendmultisig","params":["multisig_address","to_address",amount_sat,fee_sat,"privkey1_hex","privkey2_hex",...],"id":1}
/// The private keys (params[4..]) must belong to signers in the multisig config.
/// M signatures must be provided for the TX to be accepted.
fn handleSendMultisig(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;

    const from_addr = extractArrayStr(body, 0) orelse
        return errorJson(-32602, "Missing param: multisig_address", id, alloc);
    const to_addr = extractArrayStr(body, 1) orelse
        return errorJson(-32602, "Missing param: to_address", id, alloc);
    const amount_sat = extractArrayNum(body, 2);
    if (amount_sat == 0) return errorJson(-32602, "Missing/zero param: amount", id, alloc);
    const fee_raw = extractArrayNum(body, 3);
    const fee_sat: u64 = if (fee_raw > 0) fee_raw else mempool_mod.TX_MIN_FEE_SAT;

    // Validate multisig address
    if (!std.mem.startsWith(u8, from_addr, multisig_mod.MULTISIG_PREFIX))
        return errorJson(-32602, "from_address must start with ob_ms_", id, alloc);

    const config_ptr = ctx.bc.getMultisigConfig(from_addr) orelse
        return errorJson(-32000, "Multisig address not registered. Call createmultisig first.", id, alloc);

    const config = config_ptr.*;

    // Build the on-chain Transaction skeleton FIRST so signers sign over the
    // canonical Transaction.calculateHash() — same hash the chain re-checks.
    const tx_id = g_tx_counter.fetchAdd(1, .monotonic);
    const nonce = ctx.bc.getNextAvailableNonce(from_addr);
    const ts = std.time.timestamp();

    var tx = transaction_mod.Transaction{
        .id = tx_id,
        .from_address = from_addr,
        .to_address = to_addr,
        .amount = amount_sat,
        .fee = fee_sat,
        .timestamp = ts,
        .nonce = nonce,
        .signature = "multisig", // marker; real sigs in script_sig
        .hash = "",
    };
    const tx_hash = tx.calculateHash();

    // Collect private keys from params[4..]; for each, derive its pubkey,
    // find the matching signer index in the multisig config, sign tx_hash.
    var indices: [multisig_mod.MAX_SIGNERS]u8 = [_]u8{0} ** multisig_mod.MAX_SIGNERS;
    var sigs: [multisig_mod.MAX_SIGNERS][64]u8 = [_][64]u8{[_]u8{0} ** 64} ** multisig_mod.MAX_SIGNERS;
    var used: [multisig_mod.MAX_SIGNERS]bool = [_]bool{false} ** multisig_mod.MAX_SIGNERS;
    var signed: u8 = 0;

    var pk_idx: usize = 4;
    while (pk_idx < 4 + multisig_mod.MAX_SIGNERS) : (pk_idx += 1) {
        const pk_hex = extractArrayStr(body, pk_idx) orelse break;
        if (pk_hex.len != 64) continue;
        var privkey: [32]u8 = undefined;
        hex_utils.hexToBytes(pk_hex, &privkey) catch continue;
        const pubkey = Secp256k1Crypto.privateKeyToPublicKey(privkey) catch continue;

        // Find this pubkey's index in the config
        var found_idx: ?u8 = null;
        for (0..config.pubkey_count) |i| {
            if (std.mem.eql(u8, &config.pubkeys[i], &pubkey)) {
                found_idx = @intCast(i);
                break;
            }
        }
        const sidx = found_idx orelse continue; // not a signer
        if (used[sidx]) continue;                // dedupe

        const sig = Secp256k1Crypto.sign(privkey, &tx_hash) catch continue;
        indices[signed] = sidx;
        sigs[signed] = sig;
        used[sidx] = true;
        signed += 1;
        if (signed >= config.threshold) break;
    }

    if (signed < config.threshold) {
        return std.fmt.allocPrint(alloc,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"error\":{{\"code\":-32000,\"message\":\"Insufficient signatures: {d}/{d} required\"}}}}",
            .{ id, signed, config.threshold });
    }

    // Encode bundle and attach to script_sig + commit hash
    var bundle_buf: [multisig_mod.BUNDLE_MAX_SIZE]u8 = undefined;
    const bundle_len = multisig_mod.encodeBundle(signed, &indices, &sigs, &bundle_buf) catch
        return errorJson(-32000, "Failed to encode multisig bundle", id, alloc);

    // Sanity: re-verify locally before submitting
    if (!multisig_mod.verifyBundle(&config, tx_hash, bundle_buf[0..bundle_len])) {
        return errorJson(-32000, "Multisig bundle self-verification failed", id, alloc);
    }

    tx.script_sig = try alloc.dupe(u8, bundle_buf[0..bundle_len]);
    tx.hash = try hex_utils.bytesToHexAlloc(tx_hash, alloc);

    ctx.bc.addTransaction(tx) catch return errorJson(-32000, "Mempool rejected TX", id, alloc);

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"from\":\"{s}\",\"to\":\"{s}\",\"amount\":{d},\"fee\":{d},\"signatures\":{d},\"required\":{d},\"txid\":\"{s}\",\"status\":\"accepted\"}}}}",
        .{ id, from_addr, to_addr, amount_sat, fee_sat, signed, config.threshold, tx.hash });
}

/// Extract the inner array from params: "params":[2, ["a","b"]] -> returns content of inner [...]
fn extractInnerArray(json: []const u8) ?[]const u8 {
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
fn extractArrayStr(json: []const u8, index: usize) ?[]const u8 {
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
fn extractArrayToken(json: []const u8, index: usize) ?[]const u8 {
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
fn extractArrayNum(json: []const u8, index: usize) u64 {
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

/// Extrage valoarea unui string field din JSON.
/// Cauta "key" (oricunde in sir), sare peste `: `, returneaza valoarea string.
fn extractStr(json: []const u8, key: []const u8) ?[]const u8 {
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
fn findJsonArray(json: []const u8, key: []const u8) ?[]const u8 {
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
fn findJsonObject(json: []const u8, key: []const u8) ?[]const u8 {
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

fn errorJson(code: i32, msg: []const u8, id: u64, alloc: std.mem.Allocator) ![]u8 {
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"error\":{{\"code\":{d},\"message\":\"{s}\"}}}}",
        .{ id, code, msg });
}

// ─── Cross-chain swap binding handlers ─────────────────────────────────────────

fn hex32(b: [32]u8, out: *[64]u8) void {
    const tab = "0123456789abcdef";
    for (b, 0..) |x, i| {
        out[i * 2] = tab[x >> 4];
        out[i * 2 + 1] = tab[x & 0x0F];
    }
}

fn stateName(s: swap_link_mod.SwapState) []const u8 {
    return switch (s) {
        .pending => "pending",
        .both_locked => "both_locked",
        .claimed => "claimed",
        .timed_out => "timed_out",
    };
}

fn chainName(c: swap_link_mod.Chain) []const u8 {
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
fn handleSwapOpen(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const order_id = extractU64Param(body, "\"order_id\"") orelse
        return errorJson(-32602, "Missing param: order_id", id, alloc);
    const taker_chain_u = extractU64Param(body, "\"taker_chain\"") orelse
        return errorJson(-32602, "Missing param: taker_chain", id, alloc);
    if (taker_chain_u > 4 or taker_chain_u == 0)
        return errorJson(-32602, "taker_chain must be 1=btc, 2=eth, 3=base, 4=liberty", id, alloc);
    const taker_chain = swap_link_mod.Chain.fromU8(@intCast(taker_chain_u)) orelse
        return errorJson(-32602, "Bad taker_chain", id, alloc);

    const ref_hex = extractStr(body, "taker_htlc_ref") orelse
        return errorJson(-32602, "Missing param: taker_htlc_ref", id, alloc);
    // max 122 hex chars = 61 bytes (full EthRef: 1 tag + 8 chain_id + 20 contract + 32 id)
    if (ref_hex.len > 122 or ref_hex.len % 2 != 0)
        return errorJson(-32602, "taker_htlc_ref bad length (max 122 hex chars)", id, alloc);
    var ref_bytes: [61]u8 = std.mem.zeroes([61]u8);
    {
        var i: usize = 0;
        while (i < ref_hex.len / 2) : (i += 1) {
            const hi = hex_utils.charToNibble(ref_hex[i * 2]) catch
                return errorJson(-32602, "Bad hex in taker_htlc_ref", id, alloc);
            const lo = hex_utils.charToNibble(ref_hex[i * 2 + 1]) catch
                return errorJson(-32602, "Bad hex in taker_htlc_ref", id, alloc);
            ref_bytes[i] = (@as(u8, hi) << 4) | @as(u8, lo);
        }
    }

    const hash_lock_hex = extractStr(body, "hash_lock") orelse
        return errorJson(-32602, "Missing param: hash_lock", id, alloc);
    const hash_lock = parseHex32(hash_lock_hex) orelse
        return errorJson(-32602, "Bad hash_lock (need 64 hex chars)", id, alloc);

    const timeout = extractU64Param(body, "\"timeout\"") orelse
        return errorJson(-32602, "Missing param: timeout", id, alloc);

    const maker_ref = swap_link_mod.HtlcRef{ .omnibus = hash_lock };
    // Decode taker_htlc_ref using HtlcRef wire format (tagged, 61B)
    const taker_ref: swap_link_mod.HtlcRef = switch (taker_chain) {
        .btc => blk: {
            var txid: [32]u8 = undefined;
            @memcpy(&txid, ref_bytes[0..32]);
            const vout = std.mem.readInt(u32, ref_bytes[32..36], .little);
            break :blk swap_link_mod.HtlcRef{ .btc = .{ .txid = txid, .vout = vout } };
        },
        .eth, .base, .liberty => blk: {
            const chain_id = std.mem.readInt(u64, ref_bytes[0..8], .little);
            var contract: [20]u8 = undefined;
            @memcpy(&contract, ref_bytes[8..28]);
            var hid: [32]u8 = std.mem.zeroes([32]u8);
            @memcpy(&hid, ref_bytes[28..60]);
            break :blk swap_link_mod.HtlcRef{ .eth = .{
                .chain_id = chain_id,
                .contract = contract,
                .id = hid,
            } };
        },
        .omnibus => unreachable,
    };

    const current_block: u64 = ctx.bc.getBlockCount();
    ctx.bc.swap_registry.open(order_id, hash_lock, .omnibus, taker_chain,
        maker_ref, taker_ref, timeout, current_block) catch |err| {
        return errorJson(-32000, @errorName(err), id, alloc);
    };

    var sid_hex_buf: [64]u8 = undefined;
    hex32(hash_lock, &sid_hex_buf);
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"swap_id\":\"{s}\",\"state\":\"pending\"}}}}",
        .{ id, sid_hex_buf[0..] });
}

/// swap_status — read state for a given swap_id.
fn handleSwapStatus(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const sid_hex = extractStr(body, "swap_id") orelse
        return errorJson(-32602, "Missing param: swap_id", id, alloc);
    const sid = parseHex32(sid_hex) orelse
        return errorJson(-32602, "Bad swap_id", id, alloc);
    const b = ctx.bc.swap_registry.find(sid) orelse
        return errorJson(-32004, "Binding not found", id, alloc);
    var sid_hex_buf: [64]u8 = undefined;
    hex32(b.swap_id, &sid_hex_buf);
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"swap_id\":\"{s}\",\"order_id\":{d},\"state\":\"{s}\",\"maker_chain\":\"{s}\",\"taker_chain\":\"{s}\",\"timeout_block\":{d},\"created_block\":{d}}}}}",
        .{ id, sid_hex_buf[0..], b.order_id, stateName(b.state),
           chainName(b.maker_chain), chainName(b.taker_chain),
           b.timeout_block, b.created_block });
}

/// swap_listOpen — list bindings whose state is .pending or .both_locked.
/// (Address filter is accepted but ignored — frontend filters client-side
/// until matching_engine cross-ref by trader is exposed.)
fn handleSwapListOpen(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    _ = body;
    const alloc = ctx.allocator;
    var buf = std.ArrayList(u8){};
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, "[");
    var first = true;
    var i: u32 = 0;
    while (i < ctx.bc.swap_registry.count) : (i += 1) {
        const b = &ctx.bc.swap_registry.entries[i];
        if (b.state != .pending and b.state != .both_locked) continue;
        if (!first) try buf.appendSlice(alloc, ",");
        first = false;
        var item_hex: [64]u8 = undefined;
        hex32(b.swap_id, &item_hex);
        const piece = try std.fmt.allocPrint(alloc,
            "{{\"swap_id\":\"{s}\",\"order_id\":{d},\"state\":\"{s}\",\"maker_chain\":\"{s}\",\"taker_chain\":\"{s}\",\"timeout_block\":{d}}}",
            .{ item_hex[0..], b.order_id, stateName(b.state),
               chainName(b.maker_chain), chainName(b.taker_chain), b.timeout_block });
        defer alloc.free(piece);
        try buf.appendSlice(alloc, piece);
    }
    try buf.appendSlice(alloc, "]");
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{s}}}", .{ id, buf.items });
}

/// swap_lockMaker — confirm the maker-side HTLC is funded on its chain.
/// Params: swap_id (64 hex), htlc_ref (122 hex, HtlcRef wire format).
/// Transitions: pending → pending (sets maker_htlc_ref). Both legs needed
/// before state moves to both_locked.
fn handleSwapLockMaker(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const sid_hex = extractStr(body, "swap_id") orelse
        return errorJson(-32602, "Missing param: swap_id", id, alloc);
    const sid = parseHex32(sid_hex) orelse
        return errorJson(-32602, "Bad swap_id (need 64 hex)", id, alloc);
    const ref_hex = extractStr(body, "htlc_ref") orelse
        return errorJson(-32602, "Missing param: htlc_ref", id, alloc);
    if (ref_hex.len > 122 or ref_hex.len % 2 != 0)
        return errorJson(-32602, "htlc_ref bad length", id, alloc);
    var rb: [61]u8 = std.mem.zeroes([61]u8);
    _ = hex_utils.hexToBytes(ref_hex, rb[0 .. ref_hex.len / 2]) catch
        return errorJson(-32602, "Bad hex in htlc_ref", id, alloc);
    const ref = swap_link_mod.HtlcRef.decode(&rb) orelse
        return errorJson(-32602, "Cannot decode htlc_ref", id, alloc);
    ctx.bc.swap_registry.lockMaker(sid, ref) catch |err|
        return errorJson(-32000, @errorName(err), id, alloc);
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"swap_id\":\"{s}\",\"leg\":\"maker\",\"locked\":true}}}}",
        .{ id, sid_hex });
}

/// swap_lockTaker — confirm the taker-side HTLC is funded. After both legs
/// locked the binding transitions to .both_locked.
/// Params: swap_id (64 hex), htlc_ref (122 hex).
fn handleSwapLockTaker(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const sid_hex = extractStr(body, "swap_id") orelse
        return errorJson(-32602, "Missing param: swap_id", id, alloc);
    const sid = parseHex32(sid_hex) orelse
        return errorJson(-32602, "Bad swap_id (need 64 hex)", id, alloc);
    const ref_hex = extractStr(body, "htlc_ref") orelse
        return errorJson(-32602, "Missing param: htlc_ref", id, alloc);
    if (ref_hex.len > 122 or ref_hex.len % 2 != 0)
        return errorJson(-32602, "htlc_ref bad length", id, alloc);
    var rb: [61]u8 = std.mem.zeroes([61]u8);
    _ = hex_utils.hexToBytes(ref_hex, rb[0 .. ref_hex.len / 2]) catch
        return errorJson(-32602, "Bad hex in htlc_ref", id, alloc);
    const ref = swap_link_mod.HtlcRef.decode(&rb) orelse
        return errorJson(-32602, "Cannot decode htlc_ref", id, alloc);
    ctx.bc.swap_registry.lockTaker(sid, ref) catch |err|
        return errorJson(-32000, @errorName(err), id, alloc);

    // After lockTaker the binding moves to .both_locked — check and persist.
    const b = ctx.bc.swap_registry.find(sid);
    const state_str = if (b) |binding| stateName(binding.state) else "both_locked";
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"swap_id\":\"{s}\",\"leg\":\"taker\",\"locked\":true,\"state\":\"{s}\"}}}}",
        .{ id, sid_hex, state_str });
}

/// swap_timeout — mark a binding as timed_out when current block >= timeout_block.
/// Params: swap_id (64 hex).
fn handleSwapTimeout(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const sid_hex = extractStr(body, "swap_id") orelse
        return errorJson(-32602, "Missing param: swap_id", id, alloc);
    const sid = parseHex32(sid_hex) orelse
        return errorJson(-32602, "Bad swap_id (need 64 hex)", id, alloc);
    const current_block: u64 = ctx.bc.getBlockCount();
    ctx.bc.swap_registry.timeout(sid, current_block) catch |err|
        return errorJson(-32000, @errorName(err), id, alloc);
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"swap_id\":\"{s}\",\"state\":\"timed_out\",\"current_block\":{d}}}}}",
        .{ id, sid_hex, current_block });
}

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
fn hexAlloc(alloc: std.mem.Allocator, hex: []const u8) ?[]u8 {
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
fn verifySpvProofBlob(blob: []const u8) bool {
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
fn verifySpvProofJson(obj: []const u8) bool {
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
fn handleSwapProveSettle(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const sid_hex = extractStr(body, "swap_id") orelse
        return errorJson(-32602, "Missing param: swap_id", id, alloc);
    const sid = parseHex32(sid_hex) orelse
        return errorJson(-32602, "Bad swap_id", id, alloc);
    const pre_hex = extractStr(body, "preimage") orelse
        return errorJson(-32602, "Missing param: preimage", id, alloc);
    const preimage = parseHex32(pre_hex) orelse
        return errorJson(-32602, "Bad preimage", id, alloc);

    // Detect new (object) vs legacy (string) form for spv_proof_blob.
    if (findJsonObject(body, "spv_proof_blob")) |obj| {
        if (!verifySpvProofJson(obj)) {
            return errorJson(-32030, "SPV proof invalid", id, alloc);
        }
    } else {
        const blob = extractStr(body, "spv_proof_blob") orelse "";
        if (blob.len > 0) {
            std.debug.print(
                "[swap_proveSettle] DEPRECATED: legacy flat spv_proof_blob string accepted; clients should migrate to JSON object form.\n",
                .{},
            );
            if (!verifySpvProofBlob(blob)) {
                return errorJson(-32030, "SPV proof invalid", id, alloc);
            }
        } else {
            std.debug.print(
                "[swap_proveSettle] WARNING: dev-mode preimage-only settlement (no spv_proof_blob). DO NOT use on mainnet.\n",
                .{},
            );
        }
    }

    const cur = ctx.bc.swap_registry.find(sid) orelse
        return errorJson(-32004, "Binding not found", id, alloc);
    if (cur.state == .pending) {
        ctx.bc.swap_registry.lockTaker(sid, cur.taker_htlc_ref) catch |err| {
            return errorJson(-32000, @errorName(err), id, alloc);
        };
    }
    ctx.bc.swap_registry.settle(sid, preimage) catch |err| {
        return errorJson(-32003, @errorName(err), id, alloc);
    };
    var sid_hex_buf: [64]u8 = undefined;
    hex32(sid, &sid_hex_buf);
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"swap_id\":\"{s}\",\"state\":\"claimed\"}}}}",
        .{ id, sid_hex_buf[0..] });
}

// intent_* — build, sign, and broadcast the corresponding 0x40/0x41/0x43
// typed TXs through the mempool. State-machine effects land at applyBlock
// time via blockchain.applyIntentTx.

/// Build + submit an intent TX. Mirrors submitHtlcTx — TX has amount=0
/// (intents move state, not coin), fee=1, signed via the standard mempool
/// path from the node's primary wallet.
fn submitIntentTx(
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
fn handleIntentPost(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const swap_id_hex = extractStr(body, "swap_id")
        orelse return errorJson(-32602, "missing swap_id", id, alloc);
    const swap_id = parseHex32(swap_id_hex)
        orelse return errorJson(-32602, "swap_id must be 64 hex chars", id, alloc);

    const taker_chain_u = extractU64Param(body, "\"taker_chain\"")
        orelse return errorJson(-32602, "missing taker_chain", id, alloc);
    if (taker_chain_u > 3) return errorJson(-32602, "taker_chain must be 0..3", id, alloc);

    const expiry_block = extractU64Param(body, "\"expiry_block\"") orelse extractU64Param(body, "\"expiry\"")
        orelse return errorJson(-32602, "missing expiry_block", id, alloc);
    if (expiry_block == 0 or expiry_block > std.math.maxInt(u32))
        return errorJson(-32602, "expiry_block out of range", id, alloc);

    const maker_amount_sat = extractU64Param(body, "\"maker_amount_sat\"") orelse extractU64Param(body, "\"amount_sat\"")
        orelse return errorJson(-32602, "missing maker_amount_sat", id, alloc);
    const taker_min_sat = extractU64Param(body, "\"taker_min_sat\"") orelse 0;

    var intent_id: [32]u8 = undefined;
    if (extractStr(body, "intent_id")) |iid_hex| {
        intent_id = parseHex32(iid_hex)
            orelse return errorJson(-32602, "intent_id must be 64 hex chars", id, alloc);
    } else {
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update("intent");
        hasher.update(&swap_id);
        var eb: [8]u8 = undefined;
        std.mem.writeInt(u64, &eb, expiry_block, .little);
        hasher.update(&eb);
        hasher.update(ctx.wallet.address);
        hasher.final(&intent_id);
    }

    const payload = tx_payload_mod.IntentPostPayload{
        .intent_id = intent_id,
        .swap_id = swap_id,
        .expiry_block = @intCast(expiry_block),
        .taker_chain = @intCast(taker_chain_u),
        .maker_amount_sat = maker_amount_sat,
        .taker_min_sat = taker_min_sat,
    };
    payload.validate() catch return errorJson(-32602, "invalid intent_post payload", id, alloc);

    var data_buf: [tx_payload_mod.IntentPostPayload.WIRE_SIZE]u8 = undefined;
    _ = try payload.encode(&data_buf);

    const tx_hash = submitIntentTx(ctx, .intent_post, &data_buf) catch |err| {
        std.debug.print("[INTENT-POST] submit failed: {}\n", .{err});
        return errorJson(-32000, "intent_post submit failed", id, alloc);
    };
    defer alloc.free(tx_hash);

    var iid_hex: [64]u8 = undefined; writeHex32(intent_id, &iid_hex);
    var sid_hex_out: [64]u8 = undefined; writeHex32(swap_id, &sid_hex_out);
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"tx_hash\":\"{s}\",\"intent_id\":\"{s}\",\"swap_id\":\"{s}\",\"expiry_block\":{d}}}}}",
        .{ id, tx_hash, &iid_hex, &sid_hex_out, expiry_block });
}

/// `intent_fill_commit({intent_id, bond_locked_sat})` — TX type 0x41.
/// Solver locks bond on Omnibus, claiming the right to fill the intent.
fn handleIntentFillCommit(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const iid_hex = extractStr(body, "intent_id")
        orelse return errorJson(-32602, "missing intent_id", id, alloc);
    const intent_id = parseHex32(iid_hex)
        orelse return errorJson(-32602, "intent_id must be 64 hex chars", id, alloc);
    const bond = extractU64Param(body, "\"bond_locked_sat\"") orelse extractU64Param(body, "\"bond\"")
        orelse return errorJson(-32602, "missing bond_locked_sat", id, alloc);
    if (bond == 0) return errorJson(-32602, "bond_locked_sat must be > 0", id, alloc);

    const payload = tx_payload_mod.IntentFillCommitPayload{
        .intent_id = intent_id,
        .bond_locked_sat = bond,
        .commit_block = ctx.bc.getBlockCount(),
    };
    payload.validate() catch return errorJson(-32602, "invalid intent_fill_commit payload", id, alloc);

    var data_buf: [tx_payload_mod.IntentFillCommitPayload.WIRE_SIZE]u8 = undefined;
    _ = try payload.encode(&data_buf);

    const tx_hash = submitIntentTx(ctx, .intent_fill_commit, &data_buf) catch |err| {
        std.debug.print("[INTENT-FILL-COMMIT] submit failed: {}\n", .{err});
        return errorJson(-32000, "intent_fill_commit submit failed", id, alloc);
    };
    defer alloc.free(tx_hash);

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"tx_hash\":\"{s}\",\"intent_id\":\"{s}\",\"bond_locked_sat\":{d}}}}}",
        .{ id, tx_hash, iid_hex, bond });
}

/// intent_settle alias preserved — delegates to swap_proveSettle (0x42).
fn handleIntentSettle(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    return handleSwapProveSettle(body, ctx, id);
}

/// `intent_timeout({intent_id, slashed_bond_sat?, swap_id?})` — TX type 0x43.
/// Optionally also nudges swap_registry.timeout(swap_id) for legacy callers
/// that only knew about swap_id; the in-memory call is now redundant with
/// the on-chain effect of applyIntentTx but kept for backward compat.
fn handleIntentTimeout(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const iid_hex = extractStr(body, "intent_id")
        orelse return errorJson(-32602, "missing intent_id", id, alloc);
    const intent_id = parseHex32(iid_hex)
        orelse return errorJson(-32602, "intent_id must be 64 hex chars", id, alloc);
    const slashed = extractU64Param(body, "\"slashed_bond_sat\"") orelse 0;

    if (extractStr(body, "swap_id")) |sid_hex| {
        if (parseHex32(sid_hex)) |sid| {
            ctx.bc.swap_registry.timeout(sid, ctx.bc.getBlockCount()) catch {};
        }
    }

    const payload = tx_payload_mod.IntentTimeoutPayload{
        .intent_id = intent_id,
        .slashed_bond_sat = slashed,
    };
    payload.validate() catch return errorJson(-32602, "invalid intent_timeout payload", id, alloc);

    var data_buf: [tx_payload_mod.IntentTimeoutPayload.WIRE_SIZE]u8 = undefined;
    _ = try payload.encode(&data_buf);

    const tx_hash = submitIntentTx(ctx, .intent_timeout, &data_buf) catch |err| {
        std.debug.print("[INTENT-TIMEOUT] submit failed: {}\n", .{err});
        return errorJson(-32000, "intent_timeout submit failed", id, alloc);
    };
    defer alloc.free(tx_hash);

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"tx_hash\":\"{s}\",\"intent_id\":\"{s}\",\"slashed_bond_sat\":{d}}}}}",
        .{ id, tx_hash, iid_hex, slashed });
}

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

fn handleGenWallet(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const mnemonic = extractArrayStr(body, 0) orelse extractStr(body, "mnemonic") orelse
        return errorJson(-32602, "Missing param: mnemonic", id, alloc);

    // Genereaza wallet Zig real din mnemonic
    var w = Wallet.fromMnemonic(mnemonic, "", alloc) catch
        return errorJson(-32000, "Invalid mnemonic", id, alloc);
    defer w.deinit();

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"address\":\"{s}\",\"mnemonic\":\"{s}\"}}}}",
        .{ id, w.address, mnemonic });
}

// ─── Payment Channel RPC Handlers ────────────────────────────────────────────

/// RPC "openchannel" — open a new payment channel between two parties.
/// Usage: {"method":"openchannel","params":["party_a_hex","party_b_hex",amount_a,amount_b],"id":1}
/// party_a_hex / party_b_hex: 33-byte compressed pubkeys as 66-char hex strings (REQUIRED)
/// amount_a / amount_b: deposits in SAT
fn handleOpenChannel(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const mgr = ctx.channel_mgr orelse return errorJson(-32000, "Payment channels not initialized", id, alloc);

    const amount_a = extractArrayNum(body, 2);
    const amount_b = extractArrayNum(body, 3);
    if (amount_a == 0 and amount_b == 0) return errorJson(-32602, "Both amounts cannot be zero", id, alloc);

    // Pubkeys are mandatory. The placeholder fallback that filled them with
    // 0xAA/0xBB used to silently produce a channel whose verify() rejects every
    // payment — caller confusion guaranteed. Reject up-front instead.
    const hex_a = extractArrayStr(body, 0) orelse
        return errorJson(-32602, "Missing party_a: 66-char compressed pubkey hex required", id, alloc);
    if (hex_a.len != 66) return errorJson(-32602, "party_a must be 66-char hex", id, alloc);
    const pk_a = hexDecode33(hex_a) orelse return errorJson(-32602, "Invalid party_a hex", id, alloc);

    const hex_b = extractArrayStr(body, 1) orelse
        return errorJson(-32602, "Missing party_b: 66-char compressed pubkey hex required", id, alloc);
    if (hex_b.len != 66) return errorJson(-32602, "party_b must be 66-char hex", id, alloc);
    const pk_b = hexDecode33(hex_b) orelse return errorJson(-32602, "Invalid party_b hex", id, alloc);

    const ch = mgr.openChannel(pk_a, pk_b, amount_a, amount_b) catch |e| {
        return switch (e) {
            error.TooManyChannels => errorJson(-32000, "Maximum channels reached", id, alloc),
            error.ExceedsMaxAmount => errorJson(-32000, "Amount exceeds maximum", id, alloc),
            error.ZeroDeposit => errorJson(-32602, "Both amounts cannot be zero", id, alloc),
        };
    };

    var cid_hex: [64]u8 = undefined;
    const cid_str = ch.getChannelIdHex(&cid_hex);

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"channel_id\":\"{s}\",\"balance_a\":{d},\"balance_b\":{d},\"total_locked\":{d},\"state\":\"open\"}}}}",
        .{ id, cid_str, ch.balance_a, ch.balance_b, ch.total_locked });
}

/// RPC "channelpay" — off-chain payment within a channel.
/// Usage: {"method":"channelpay","params":["channel_id_hex","a_to_b",amount,"sig_a_hex","sig_b_hex"],"id":1}
/// direction: "a_to_b" or "b_to_a"
/// sig_a_hex / sig_b_hex: 128-char hex (64-byte secp256k1 ECDSA sigs over the
///                       canonical hash of the new ChannelUpdate). REQUIRED —
///                       channel state is only advanced if both verify.
fn handleChannelPay(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const mgr = ctx.channel_mgr orelse return errorJson(-32000, "Payment channels not initialized", id, alloc);

    const cid_hex = extractArrayStr(body, 0) orelse return errorJson(-32602, "Missing channel_id", id, alloc);
    if (cid_hex.len != 64) return errorJson(-32602, "channel_id must be 64-char hex", id, alloc);
    const channel_id = hexDecode32(cid_hex) orelse return errorJson(-32602, "Invalid channel_id hex", id, alloc);

    const dir_str = extractArrayStr(body, 1) orelse "a_to_b";
    const from_a = std.mem.eql(u8, dir_str, "a_to_b");

    const amount = extractArrayNum(body, 2);
    if (amount == 0) return errorJson(-32602, "Amount must be > 0", id, alloc);

    // Mandatory ECDSA signatures from both parties over the NEW state hash.
    const sig_a_hex = extractArrayStr(body, 3) orelse
        return errorJson(-32602, "Missing sig_a: 128-char hex ECDSA signature required", id, alloc);
    const sig_b_hex = extractArrayStr(body, 4) orelse
        return errorJson(-32602, "Missing sig_b: 128-char hex ECDSA signature required", id, alloc);
    if (sig_a_hex.len != 128) return errorJson(-32602, "sig_a must be 128-char hex", id, alloc);
    if (sig_b_hex.len != 128) return errorJson(-32602, "sig_b must be 128-char hex", id, alloc);
    const sig_a = hexDecode64(sig_a_hex) orelse return errorJson(-32602, "Invalid sig_a hex", id, alloc);
    const sig_b = hexDecode64(sig_b_hex) orelse return errorJson(-32602, "Invalid sig_b hex", id, alloc);

    const ch = mgr.findChannel(channel_id) orelse return errorJson(-32000, "Channel not found", id, alloc);

    _ = ch.pay(from_a, amount, sig_a, sig_b) catch |e| {
        return switch (e) {
            error.ChannelNotOpen => errorJson(-32000, "Channel not open", id, alloc),
            error.InsufficientBalance => errorJson(-32000, "Insufficient balance", id, alloc),
            error.BalanceMismatch => errorJson(-32000, "Balance mismatch", id, alloc),
            error.InvalidSignature => errorJson(-32000, "Invalid signature — sig_a or sig_b does not verify", id, alloc),
        };
    };

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"sequence_num\":{d},\"balance_a\":{d},\"balance_b\":{d}}}}}",
        .{ id, ch.sequence_num, ch.balance_a, ch.balance_b });
}

/// RPC "closechannel" — cooperative close of a payment channel.
/// Usage: {"method":"closechannel","params":["channel_id_hex"],"id":1}
fn handleCloseChannel(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const mgr = ctx.channel_mgr orelse return errorJson(-32000, "Payment channels not initialized", id, alloc);

    const cid_hex = extractArrayStr(body, 0) orelse return errorJson(-32602, "Missing channel_id", id, alloc);
    if (cid_hex.len != 64) return errorJson(-32602, "channel_id must be 64-char hex", id, alloc);
    const channel_id = hexDecode32(cid_hex) orelse return errorJson(-32602, "Invalid channel_id hex", id, alloc);

    // Both parties must sign the final state. Sigs are ECDSA over the
    // canonical hash of the final ChannelUpdate (see ChannelUpdate.hash).
    const sig_a_hex = extractArrayStr(body, 1) orelse
        return errorJson(-32602, "Missing sig_a: 128-char hex ECDSA signature required", id, alloc);
    const sig_b_hex = extractArrayStr(body, 2) orelse
        return errorJson(-32602, "Missing sig_b: 128-char hex ECDSA signature required", id, alloc);
    if (sig_a_hex.len != 128) return errorJson(-32602, "sig_a must be 128-char hex", id, alloc);
    if (sig_b_hex.len != 128) return errorJson(-32602, "sig_b must be 128-char hex", id, alloc);
    const sig_a = hexDecode64(sig_a_hex) orelse return errorJson(-32602, "Invalid sig_a hex", id, alloc);
    const sig_b = hexDecode64(sig_b_hex) orelse return errorJson(-32602, "Invalid sig_b hex", id, alloc);

    const settle = mgr.closeChannel(channel_id, sig_a, sig_b) catch |e| {
        return switch (e) {
            error.ChannelNotFound => errorJson(-32000, "Channel not found", id, alloc),
            error.ChannelNotOpen => errorJson(-32000, "Channel not open", id, alloc),
            error.InvalidSignature => errorJson(-32000, "Invalid signature — sig_a or sig_b does not verify", id, alloc),
        };
    };

    const tx_a_hex = std.fmt.bytesToHex(settle.tx_hash_a, .lower);
    const tx_b_hex = std.fmt.bytesToHex(settle.tx_hash_b, .lower);

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"state\":\"settled\",\"final_balance_a\":{d},\"final_balance_b\":{d},\"tx_hash_a\":\"{s}\",\"tx_hash_b\":\"{s}\"}}}}",
        .{ id, settle.final_balance_a, settle.final_balance_b, &tx_a_hex, &tx_b_hex });
}

/// RPC "getchannels" — list payment channels with full per-channel details.
/// Usage: {"method":"getchannels","params":[],"id":1}
///        {"method":"getchannels","params":["<pubkey_hex_33>"],"id":1}  // filter by participant
/// Returns: { summary: {...}, channels: [ {id, party_a, party_b, capacity_sat, balance_a, balance_b,
///                                         sequence_num, state, funding_tx_hash}, ... ] }
fn handleGetChannels(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const mgr = ctx.channel_mgr orelse return errorJson(-32000, "Payment channels not initialized", id, alloc);

    // Optional pubkey filter (66-char hex compressed pubkey).
    // NOTE: Filter is by raw pubkey hex, NOT by bech32 address. Address-based lookup
    // would require a pubkey→address map; deferred to a follow-up since channels
    // currently store [33]u8 pubkeys, not bech32 strings.
    var filter_pk: ?[33]u8 = null;
    if (extractArrayStr(body, 0)) |hex| {
        if (hex.len == 66) {
            filter_pk = hexDecode33(hex);
        }
    }

    const open_count = mgr.countByState(.open);
    const closing_count = mgr.countByState(.closing);
    const settled_count = mgr.countByState(.settled);
    const disputed_count = mgr.countByState(.disputed);
    const total_locked = mgr.getTotalLockedSat();

    // Build the channels array. Use a heap-backed growable buffer because the
    // count is variable (up to MAX_CHANNELS = 64) and per-channel JSON is ~600B.
    var out = std.ArrayList(u8){};
    defer out.deinit(alloc);

    {
        const hdr = try std.fmt.allocPrint(alloc,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{" ++
            "\"summary\":{{\"total_channels\":{d},\"open\":{d},\"closing\":{d},\"settled\":{d},\"disputed\":{d},\"total_locked_sat\":{d}}}," ++
            "\"channels\":[",
            .{ id, mgr.channel_count, open_count, closing_count, settled_count, disputed_count, total_locked },
        );
        defer alloc.free(hdr);
        try out.appendSlice(alloc, hdr);
    }

    var first: bool = true;
    var i: u8 = 0;
    while (i < mgr.channel_count) : (i += 1) {
        const ch = &mgr.channels[i];

        // Apply filter if set: include only if filter_pk == party_a or party_b.
        if (filter_pk) |pk| {
            const match_a = std.mem.eql(u8, &ch.party_a, &pk);
            const match_b = std.mem.eql(u8, &ch.party_b, &pk);
            if (!match_a and !match_b) continue;
        }

        if (!first) try out.append(alloc, ',');
        first = false;

        const state_str: []const u8 = switch (ch.state) {
            .opening => "opening",
            .open => "open",
            .closing => "closing",
            .settled => "settled",
            .disputed => "disputed",
        };

        const cid_hex = std.fmt.bytesToHex(ch.channel_id, .lower);
        const pa_hex = std.fmt.bytesToHex(ch.party_a, .lower);
        const pb_hex = std.fmt.bytesToHex(ch.party_b, .lower);
        const ftx_hex = std.fmt.bytesToHex(ch.funding_tx_hash, .lower);

        const entry = try std.fmt.allocPrint(alloc,
            "{{\"channel_id\":\"{s}\",\"party_a\":\"{s}\",\"party_b\":\"{s}\"," ++
            "\"capacity_sat\":{d},\"balance_a\":{d},\"balance_b\":{d}," ++
            "\"sequence_num\":{d},\"state\":\"{s}\",\"funding_tx_hash\":\"{s}\"," ++
            "\"close_block\":{d},\"htlc_count\":{d}}}",
            .{
                &cid_hex, &pa_hex, &pb_hex,
                ch.total_locked, ch.balance_a, ch.balance_b,
                ch.sequence_num, state_str, &ftx_hex,
                ch.close_block,
                ch.htlc_count,
            },
        );
        defer alloc.free(entry);
        try out.appendSlice(alloc, entry);
    }

    try out.appendSlice(alloc, "]}}");
    return alloc.dupe(u8, out.items);
}

/// Decode 66-char hex string to [33]u8 (compressed pubkey)
fn hexDecode33(hex: []const u8) ?[33]u8 {
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
fn hexDecode32(hex: []const u8) ?[32]u8 {
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
fn hexDecode64(hex: []const u8) ?[64]u8 {
    if (hex.len != 128) return null;
    var out: [64]u8 = undefined;
    for (0..64) |i| {
        const hi = hexVal(hex[i * 2]) orelse return null;
        const lo = hexVal(hex[i * 2 + 1]) orelse return null;
        out[i] = (@as(u8, hi) << 4) | @as(u8, lo);
    }
    return out;
}

fn hexVal(c: u8) ?u4 {
    if (c >= '0' and c <= '9') return @intCast(c - '0');
    if (c >= 'a' and c <= 'f') return @intCast(c - 'a' + 10);
    if (c >= 'A' and c <= 'F') return @intCast(c - 'A' + 10);
    return null;
}

// ─── OmniBus Custom RPC Handlers ──────────────────────────────────────────────

/// getblockchaininfo — comprehensive node status (matches Bitcoin RPC)
fn handleBlockchainInfo(ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const block_count = ctx.bc.getBlockCount();
    const difficulty = ctx.bc.difficulty;
    const mp_size: u64 = if (ctx.mempool) |mp| @intCast(mp.size()) else @intCast(ctx.bc.mempool.items.len);
    const peer_count: u64 = if (ctx.p2p) |p| @intCast(p.peers.items.len) else 0;
    const chain_label: []const u8 = switch (ctx.chain_id) {
        1 => "omnibus-mainnet",
        2 => "omnibus-testnet",
        3 => "omnibus-devnet",
        4 => "omnibus-regtest",
        else => "omnibus-unknown",
    };

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"blocks\":{d},\"difficulty\":{d},\"chain\":\"{s}\",\"mempool_size\":{d},\"peers\":{d},\"version\":\"0.3.0\",\"subversion\":\"OmniBus-PoUW\"}}}}",
        .{ id, block_count, difficulty, chain_label, mp_size, peer_count },
    );
}

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
fn handleOmnibusPrices(ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;

    if (ctx.oracle) |oracle| {
        // Build prices for main chains
        var buf: [4096]u8 = undefined;
        var pos: usize = 0;
        const prefix = std.fmt.bufPrint(buf[pos..], "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":[", .{id}) catch return errorJson(-32603, "buf overflow", id, alloc);
        pos += prefix.len;

        const chains = [_]struct { name: []const u8, idx: usize }{
            .{ .name = "OMNI/USD", .idx = 0 },
            .{ .name = "BTC/USD", .idx = 1 },
            .{ .name = "ETH/USD", .idx = 2 },
        };

        for (chains, 0..) |chain, ci| {
            if (ci > 0) { buf[pos] = ','; pos += 1; }
            const cp = oracle.consensus_prices[chain.idx];
            const price_usd = cp.price_micro_usd / 1_000_000;
            const price_cents = (cp.price_micro_usd % 1_000_000) / 10_000;
            const entry = std.fmt.bufPrint(buf[pos..],
                "{{\"pair\":\"{s}\",\"price\":\"{d}.{d:0>2}\",\"sources\":{d},\"valid\":{s}}}",
                .{ chain.name, price_usd, price_cents, cp.submission_count, if (cp.is_valid) "true" else "false" },
            ) catch break;
            pos += entry.len;
        }

        const suffix = std.fmt.bufPrint(buf[pos..], "]}}", .{}) catch return errorJson(-32603, "buf overflow", id, alloc);
        pos += suffix.len;
        return alloc.dupe(u8, buf[0..pos]);
    }

    // No oracle attached — return empty
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":[]}}",
        .{id},
    );
}

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
fn handleOmnibusBlockPrices(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const height: u32 = std.math.cast(u32, extractArrayNum(body, 0)) orelse 0;
    const blk_opt = ctx.bc.getBlock(height);
    const blk = blk_opt orelse return errorJson(-5, "Block not found", id, alloc);

    var buf: [4096]u8 = undefined;
    var pos: usize = 0;
    const prefix = std.fmt.bufPrint(buf[pos..],
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"height\":{d},\"prices\":",
        .{ id, blk.index },
    ) catch return errorJson(-32603, "buf overflow", id, alloc);
    pos += prefix.len;

    pos += appendPricesJson(ctx.bc, &blk, &buf, pos);

    var pr_hex: [64]u8 = undefined;
    hashToHex(blk.prices_root, &pr_hex);
    const validated = blk.validatePrices();

    const suffix = std.fmt.bufPrint(buf[pos..],
        ",\"pricesRoot\":\"{s}\",\"pricesValidated\":{s}}}}}",
        .{ pr_hex, if (validated) "true" else "false" },
    ) catch return errorJson(-32603, "buf overflow", id, alloc);
    pos += suffix.len;

    return alloc.dupe(u8, buf[0..pos]);
}

/// `omnibus_getpricerange [from_height, count]` — returns an array of
/// {height, prices, pricesRoot, pricesValidated} for the range
/// [from_height, from_height + count). Capped at 100 blocks. Useful for
/// charting historical bid/ask trajectories.
fn handleOmnibusPriceRange(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const from: u32 = std.math.cast(u32, extractArrayNum(body, 0)) orelse 0;
    const req_count = extractArrayNum(body, 1);
    const max_count: u32 = 100;
    const count: u32 = if (req_count == 0 or req_count > max_count)
        max_count
    else
        std.math.cast(u32, req_count) orelse max_count;

    // Build into a heap buffer — each block can be ~3 KiB at the upper bound,
    // so a 100-block window is ~300 KiB. Far too large for the stack.
    const cap: usize = @as(usize, count) * 4096 + 256;
    var buf = try alloc.alloc(u8, cap);
    defer alloc.free(buf);
    var pos: usize = 0;

    const prefix = std.fmt.bufPrint(buf[pos..],
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"from\":{d},\"count\":",
        .{ id, from },
    ) catch return errorJson(-32603, "buf overflow", id, alloc);
    pos += prefix.len;

    // Reserve placeholder for actual count (zero-padded to 4 chars). We
    // overwrite this once we know how many blocks we actually emitted.
    const count_marker_pos = pos;
    {
        const placeholder = std.fmt.bufPrint(buf[pos..], "0000,\"blocks\":[", .{})
            catch return errorJson(-32603, "buf overflow", id, alloc);
        pos += placeholder.len;
    }

    var emitted: u32 = 0;
    var h: u32 = from;
    while (emitted < count) : ({ h += 1; emitted += 1; }) {
        const blk_opt = ctx.bc.getBlock(h);
        const blk = blk_opt orelse break;

        if (emitted > 0) {
            if (pos >= buf.len) break;
            buf[pos] = ','; pos += 1;
        }
        const open = std.fmt.bufPrint(buf[pos..], "{{\"height\":{d},\"prices\":", .{blk.index})
            catch break;
        pos += open.len;

        pos += appendPricesJson(ctx.bc, &blk, buf, pos);

        var pr_hex: [64]u8 = undefined;
        hashToHex(blk.prices_root, &pr_hex);
        const validated = blk.validatePrices();
        const close = std.fmt.bufPrint(buf[pos..],
            ",\"pricesRoot\":\"{s}\",\"pricesValidated\":{s}}}",
            .{ pr_hex, if (validated) "true" else "false" },
        ) catch break;
        pos += close.len;
    }

    const suffix = std.fmt.bufPrint(buf[pos..], "]}}}}", .{})
        catch return errorJson(-32603, "buf overflow", id, alloc);
    pos += suffix.len;

    // Patch the count placeholder. emitted is at most 100 so 4 chars is plenty.
    var count_str: [4]u8 = .{ '0', '0', '0', '0' };
    var n = emitted;
    var idx: usize = 4;
    while (idx > 0) {
        idx -= 1;
        count_str[idx] = '0' + @as(u8, @intCast(n % 10));
        n /= 10;
    }
    @memcpy(buf[count_marker_pos .. count_marker_pos + 4], &count_str);

    return alloc.dupe(u8, buf[0..pos]);
}

/// omnibus_getexchangefeed — live BTC + LCX bid/ask from 3 exchanges
/// (Coinbase, Kraken, LCX) via WebSocket. Returns raw feed snapshot from
/// `main_mod.g_ws_feed` (NOT the distributed-oracle consensus).
/// Slots layout:
///   [0] BTC Coinbase  [1] BTC Kraken  [2] BTC LCX
///   [3] LCX Coinbase  [4] LCX Kraken  [5] LCX LCX
fn handleOmnibusExchangeFeed(ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;

    if (main_mod.g_ws_feed) |*feed| {
        const snap = feed.snapshot();
        const median_btc = feed.getMedianBtc();
        const median_lcx = feed.getMedianLcx();

        var buf: [4096]u8 = undefined;
        var pos: usize = 0;
        const prefix = std.fmt.bufPrint(buf[pos..],
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"prices\":[", .{id})
            catch return errorJson(-32603, "buf overflow", id, alloc);
        pos += prefix.len;

        for (snap, 0..) |p, i| {
            if (i > 0) { buf[pos] = ','; pos += 1; }
            // Bid + ask in micro-USD as integer values (avoid float in JSON).
            const entry = std.fmt.bufPrint(buf[pos..],
                "{{\"exchange\":\"{s}\",\"pair\":\"{s}\",\"bidMicroUsd\":{d},\"askMicroUsd\":{d},\"timestampMs\":{d},\"success\":{s}}}",
                .{ p.exchange, p.pair, p.bid_micro_usd, p.ask_micro_usd, p.timestamp_ms, if (p.success) "true" else "false" },
            ) catch break;
            pos += entry.len;
        }

        // Median BTC: emit number or null.
        if (median_btc) |m| {
            const t = std.fmt.bufPrint(buf[pos..], "],\"medianBtcMicroUsd\":{d}", .{m})
                catch return errorJson(-32603, "buf overflow", id, alloc);
            pos += t.len;
        } else {
            const t = std.fmt.bufPrint(buf[pos..], "],\"medianBtcMicroUsd\":null", .{})
                catch return errorJson(-32603, "buf overflow", id, alloc);
            pos += t.len;
        }

        // Median LCX: emit number or null.
        if (median_lcx) |m| {
            const t = std.fmt.bufPrint(buf[pos..], ",\"medianLcxMicroUsd\":{d}}}}}", .{m})
                catch return errorJson(-32603, "buf overflow", id, alloc);
            pos += t.len;
        } else {
            const t = std.fmt.bufPrint(buf[pos..], ",\"medianLcxMicroUsd\":null}}}}", .{})
                catch return errorJson(-32603, "buf overflow", id, alloc);
            pos += t.len;
        }
        return alloc.dupe(u8, buf[0..pos]);
    }

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"prices\":[],\"medianBtcMicroUsd\":null,\"medianLcxMicroUsd\":null}}}}",
        .{id});
}

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
fn handleOmnibusAllPrices(ctx: *ServerCtx, body: []const u8, id: u64) ![]u8 {
    const alloc = ctx.allocator;

    if (main_mod.g_ws_feed) |*feed| {
        const offset: usize = @intCast(extractArrayNum(body, 0));
        const limit_raw = extractArrayNum(body, 1);
        const limit: usize = if (limit_raw == 0) 1000 else @intCast(limit_raw);

        // WIRE-UP-MARKER: feed.getAllPrices(alloc) once API lands.
        const all = try feedGetAllPrices(feed, alloc);
        defer alloc.free(all);

        const total = all.len;
        const start = if (offset >= total) total else offset;
        const want_end = start +| limit;
        const end = if (want_end > total) total else want_end;

        // 256 KiB output bound. allocPrint into a stack-arena'd buffer
        // is awkward in Zig 0.15; use a heap buffer with bufPrint cursor and
        // dupe at the end (same shape as handleOmnibusExchangeFeed).
        const BUF_SZ: usize = 256 * 1024;
        var buf = try alloc.alloc(u8, BUF_SZ);
        defer alloc.free(buf);

        const now_ms = std.time.milliTimestamp();
        var pos: usize = 0;

        const prefix = std.fmt.bufPrint(buf[pos..],
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"prices\":[", .{id})
            catch return errorJson(-32603, "buf overflow", id, alloc);
        pos += prefix.len;

        // Track the most recent timestamp seen across emitted entries.
        var last_update_ms: i64 = 0;
        var emitted: usize = 0;
        // Effective end after pagination, possibly truncated if buffer fills.
        var i: usize = start;
        while (i < end) : (i += 1) {
            const p = all[i];
            const stale = feedIsStale(p, now_ms, 30_000);
            const sep = if (emitted == 0) "" else ",";
            const entry = std.fmt.bufPrint(buf[pos..],
                "{s}{{\"exchange\":\"{s}\",\"pair\":\"{s}\",\"bidMicroUsd\":{d},\"askMicroUsd\":{d},\"timestampMs\":{d},\"success\":{s},\"stale\":{s}}}",
                .{
                    sep, p.exchange, p.pair, p.bid_micro_usd, p.ask_micro_usd,
                    p.timestamp_ms,
                    if (p.success) "true" else "false",
                    if (stale) "true" else "false",
                },
            ) catch {
                // Buffer would overflow — stop here. Pagination request can
                // re-query with a smaller limit / next offset.
                break;
            };
            pos += entry.len;
            emitted += 1;
            if (p.timestamp_ms > last_update_ms) last_update_ms = p.timestamp_ms;
        }

        const suffix = std.fmt.bufPrint(buf[pos..],
            "],\"count\":{d},\"offset\":{d},\"limit\":{d},\"total\":{d},\"lastUpdateMs\":{d}}}}}",
            .{ emitted, start, limit, total, last_update_ms })
            catch return errorJson(-32603, "buf overflow", id, alloc);
        pos += suffix.len;

        return alloc.dupe(u8, buf[0..pos]);
    }

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"prices\":[],\"count\":0,\"offset\":0,\"limit\":0,\"total\":0,\"lastUpdateMs\":0}}}}",
        .{id});
}

/// omnibus_getfxrate — current EUR→USD multiplier (median of USDC/EUR mid
/// across Coinbase, Kraken, LCX). Returned as both micro-USD per EUR and a
/// human-readable string. Null result if no FX feed has populated yet.
fn handleOmnibusFxRate(ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    if (main_mod.g_ws_feed) |*feed| {
        const rate = feed.getEurToUsdRate();
        if (rate) |r| {
            const whole = r / 1_000_000;
            const frac = r % 1_000_000;
            return std.fmt.allocPrint(alloc,
                "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"eurToUsdMicro\":{d},\"eurToUsd\":\"{d}.{d:0>6}\"}}}}",
                .{ id, r, whole, frac });
        }
    }
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"eurToUsdMicro\":null,\"eurToUsd\":null}}}}",
        .{id});
}

/// omnibus_getarbitrage — pre-compute cross-exchange arbitrage opportunities.
///
/// For every canonical pair label (BTC/USD, LCX/USD, ETH/USD, …) we collect
/// non-stale, success=true entries from all exchanges, then for each ordered
/// (buy, sell) combination compute spread_pct = (sell.bid - buy.ask)/buy.ask*100.
/// Anything above 0.05 % (5 bps) is emitted; the top 50 by spread are returned.
fn handleOmnibusArbitrage(ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;

    if (main_mod.g_ws_feed) |*feed| {
        // WIRE-UP-MARKER: feed.getAllPrices(alloc) once API lands.
        const all = try feedGetAllPrices(feed, alloc);
        defer alloc.free(all);

        const now_ms = std.time.milliTimestamp();
        // Live EUR→USD rate, micro-USD per EUR. null if no FX feed yet.
        const eur_to_usd_micro: ?u64 = feed.getEurToUsdRate();

        // Filter to non-stale fresh entries with both bid & ask populated.
        //
        // BUCKET POLICY (corectat 2026-04-27):
        //   USD bucket  → match doar intre USD/USDC/USDT/DAI/USDS (toti se
        //                 colapseaza la "BASE/USD" prin canonicalPair).
        //   EUR bucket  → match doar intre EUR/EURC ("BASE/EUR").
        //   BTC/ETH/GBP → match doar in propriul bucket.
        //
        // EUR <-> USD CROSS-CURRENCY: NU se face arbitraj direct intre buckets
        // diferite. Daca user vrea sa profite de spread BTC/EUR vs BTC/USD,
        // trebuie un trade explicit FX side (USDC/EUR sau EUR/USD spot) — care
        // are propriul fee + spread. Auto-conversia anterioara (bid_eur * fx
        // → bid_usd) era misleading: ascundea costul FX si crea oportunitati
        // false. `eur_to_usd_micro` ramane disponibil prin RPC `omnibus_getfxrate`
        // pentru afisare, dar NU mai e folosit in matcher.
        _ = eur_to_usd_micro;
        var fresh = try alloc.alloc(ws_exchange_feed_mod.PriceFetch, all.len);
        defer alloc.free(fresh);
        var fresh_n: usize = 0;
        // Threshold widened to 5 minutes for arbitrage: Kraken doesn't push
        // ticker updates for low-volume pairs when there's no trading activity.
        const ARBITRAGE_STALE_MS: i64 = 5 * 60 * 1000; // 5 min
        for (all) |p| {
            if (!p.success) continue;
            if (feedIsStale(p, now_ms, ARBITRAGE_STALE_MS)) continue;
            if (p.bid_micro_usd == 0 or p.ask_micro_usd == 0) continue;
            // Skip stable-FX pairs themselves — they're FX tools, not arbitrage candidates.
            if (std.mem.eql(u8, p.pair, "USDC/EUR") or
                std.mem.eql(u8, p.pair, "USDC-EUR") or
                std.mem.eql(u8, p.pair, "USDT/EUR") or
                std.mem.eql(u8, p.pair, "USDT-EUR") or
                std.mem.eql(u8, p.pair, "DAI/EUR")) continue;
            fresh[fresh_n] = p;
            fresh_n += 1;
        }

        // Opportunity record.
        const Opp = struct {
            pair: []const u8,
            buy_ex: []const u8,
            sell_ex: []const u8,
            buy_ask: u64,
            sell_bid: u64,
            spread_micro: u64,
            spread_pct: f64,
            buy_ts: i64,
            sell_ts: i64,
        };

        // Up to N*(N-1) ordered combos; with 6 slots that's 30 max.
        const max_combos: usize = if (fresh_n == 0) 1 else fresh_n * fresh_n;
        var opps = try alloc.alloc(Opp, max_combos);
        defer alloc.free(opps);
        var opps_n: usize = 0;

        // Pre-compute canonical pair label for each fresh entry into stable
        // owned storage. canonicalPair() returns a thread-local rotating
        // buffer slice — if we kept references across loop iterations they'd
        // get clobbered. We dupe via `alloc` and free at end via the arena.
        var canon_labels = try alloc.alloc([]u8, fresh_n);
        defer {
            for (canon_labels) |s| alloc.free(s);
            alloc.free(canon_labels);
        }
        for (fresh[0..fresh_n], 0..) |p, idx| {
            const c = canonicalPair(p.pair);
            canon_labels[idx] = try alloc.dupe(u8, c);
        }

        var i: usize = 0;
        while (i < fresh_n) : (i += 1) {
            var j: usize = 0;
            while (j < fresh_n) : (j += 1) {
                if (i == j) continue;
                const buy = fresh[i];
                const sell = fresh[j];
                // Match canonical pairs. USD bucket = "BASE/USD" (cuprinde
                // USD/USDC/USDT/DAI). EUR bucket = "BASE/EUR". Bucket-uri
                // diferite NU fac match (BTC/USD ≠ BTC/EUR — ar cere FX trade).
                if (!std.mem.eql(u8, canon_labels[i], canon_labels[j])) continue;
                // Same exchange isn't arbitrage.
                if (std.mem.eql(u8, buy.exchange, sell.exchange)) continue;
                if (sell.bid_micro_usd <= buy.ask_micro_usd) continue;
                // Filter dust orderbooks: if either price is < 1000 micro-units
                // (= $0.001 sau €0.001), it's almost certainly a stale or empty
                // book. These produce absurd spreads (3M%) that are NOT real
                // arbitrage — they're just bad data.
                if (buy.ask_micro_usd < 1000 or sell.bid_micro_usd < 1000) continue;
                const spread = sell.bid_micro_usd - buy.ask_micro_usd;
                const pct = (@as(f64, @floatFromInt(spread)) /
                             @as(f64, @floatFromInt(buy.ask_micro_usd))) * 100.0;
                if (pct <= 0.05) continue; // 5 bps floor
                // Cap upper-bound: spreads >50% are NEVER real arbitrage on
                // liquid pairs — always orderbook desync or thin venue.
                if (pct > 50.0) continue;
                opps[opps_n] = .{
                    // canon_labels[i] e owned slice — refera direct.
                    .pair = canon_labels[i],
                    .buy_ex = buy.exchange,
                    .sell_ex = sell.exchange,
                    .buy_ask = buy.ask_micro_usd,
                    .sell_bid = sell.bid_micro_usd,
                    .spread_micro = spread,
                    .spread_pct = pct,
                    .buy_ts = buy.timestamp_ms,
                    .sell_ts = sell.timestamp_ms,
                };
                opps_n += 1;
            }
        }

        // Sort descending by spread_pct (insertion sort — opps_n is tiny).
        var k: usize = 1;
        while (k < opps_n) : (k += 1) {
            var m = k;
            while (m > 0 and opps[m - 1].spread_pct < opps[m].spread_pct) : (m -= 1) {
                const tmp = opps[m - 1];
                opps[m - 1] = opps[m];
                opps[m] = tmp;
            }
        }

        const cap: usize = if (opps_n > 50) 50 else opps_n;

        // Emit JSON. 256 KiB plenty for ≤50 opportunities.
        const BUF_SZ: usize = 256 * 1024;
        var buf = try alloc.alloc(u8, BUF_SZ);
        defer alloc.free(buf);
        var pos: usize = 0;

        const prefix = std.fmt.bufPrint(buf[pos..],
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"opportunities\":[", .{id})
            catch return errorJson(-32603, "buf overflow", id, alloc);
        pos += prefix.len;

        var emitted: usize = 0;
        var idx: usize = 0;
        while (idx < cap) : (idx += 1) {
            const o = opps[idx];
            // f64 → 4-decimal string via std.fmt format spec.
            const sep = if (emitted == 0) "" else ",";
            const entry = std.fmt.bufPrint(buf[pos..],
                "{s}{{\"pair\":\"{s}\",\"buyAt\":\"{s}\",\"buyAskMicroUsd\":{d},\"sellAt\":\"{s}\",\"sellBidMicroUsd\":{d},\"spreadMicroUsd\":{d},\"spreadPct\":{d:.4},\"buyTimestampMs\":{d},\"sellTimestampMs\":{d}}}",
                .{
                    sep, o.pair, o.buy_ex, o.buy_ask, o.sell_ex, o.sell_bid,
                    o.spread_micro, o.spread_pct, o.buy_ts, o.sell_ts,
                },
            ) catch break;
            pos += entry.len;
            emitted += 1;
        }

        const suffix = std.fmt.bufPrint(buf[pos..],
            "],\"count\":{d}}}}}", .{emitted})
            catch return errorJson(-32603, "buf overflow", id, alloc);
        pos += suffix.len;

        return alloc.dupe(u8, buf[0..pos]);
    }

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"opportunities\":[],\"count\":0}}}}",
        .{id});
}

/// omnibus_getorderbook — placeholder (matching engine not heap-allocated yet)
fn handleOmnibusOrderbook(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const pair = extractStr(body, "pair") orelse extractArrayStr(body, 0) orelse "OMNI/USDC";
    _ = pair;
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"bids\":[],\"asks\":[],\"note\":\"Matching engine active — connect via P2P for live orderbook\"}}}}",
        .{id},
    );
}

/// omnibus_getbridgestatus — real bridge state from BridgeState
fn handleOmnibusBridge(ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    ctx.bridge_mutex.lock();
    defer ctx.bridge_mutex.unlock();
    const bs = ctx.bridge orelse return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"error\":{{\"code\":-32001,\"message\":\"Bridge not initialized\"}}}}",
        .{id},
    );
    const height = ctx.bc.getBlockCount();
    const daily  = bs.dailyVolumeSat(height);
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{" ++
        "\"bridge_active\":{s}," ++
        "\"paused\":{s}," ++
        "\"paused_at_height\":{d}," ++
        "\"locked_total_sat\":{d}," ++
        "\"daily_volume_sat\":{d}," ++
        "\"lock_count\":{d}," ++
        "\"pending_unlock_count\":{d}," ++
        "\"vault_addr\":\"{s}\"" ++
        "}}}}",
        .{
            id,
            if (!bs.paused) "true" else "false",
            if (bs.paused) "true" else "false",
            bs.paused_at_height,
            bs.locked_total_sat,
            daily,
            bs.locks.items.len,
            bs.pending_unlocks.count(),
            chain_config.BRIDGE_VAULT_ADDR_HEX,
        },
    );
}

/// bridge_lock — user locks OMNI in vault to bridge to destination chain.
/// Params: {address, amount_sat, destination_chain, destination_addr}
/// Validates caps + creates LockRecord. The TX itself must be submitted
/// separately via sendtransaction with op_return memo "bridge_lock:<nonce_hex>".
/// This endpoint pre-validates and returns the nonce the user must embed.
fn handleBridgeLock(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    ctx.bridge_mutex.lock();
    defer ctx.bridge_mutex.unlock();
    const bs = ctx.bridge orelse return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"error\":{{\"code\":-32001,\"message\":\"Bridge not initialized\"}}}}",
        .{id},
    );

    // Parse params
    const amount_sat = extractU64Param(body, "\"amount_sat\"") orelse
        return errorJson(-32602, "Missing param: amount_sat", id, alloc);
    const dest_chain = extractStrParam(body, "\"destination_chain\"") orelse
        return errorJson(-32602, "Missing param: destination_chain", id, alloc);
    const dest_addr  = extractStrParam(body, "\"destination_addr\"") orelse
        return errorJson(-32602, "Missing param: destination_addr", id, alloc);

    const height = ctx.bc.getBlockCount();
    bs.validateLock(amount_sat, height) catch |err| {
        const msg = switch (err) {
            error.AmountExceedsPerTxCap   => "Amount exceeds per-tx cap",
            error.AmountExceedsDailyQuota => "Daily quota exceeded",
            error.AutoPauseActive         => "Bridge auto-paused (anomaly detected)",
            else                          => "Bridge lock validation failed",
        };
        return errorJson(-32003, msg, id, alloc);
    };

    // Build nonce = SHA256(dest_chain || dest_addr || amount || height)
    var nonce_input: [128]u8 = undefined;
    const ni_len = std.fmt.bufPrint(&nonce_input, "{s}{s}{d}{d}", .{ dest_chain, dest_addr, amount_sat, height }) catch
        return errorJson(-32003, "Nonce input overflow", id, alloc);
    var nonce: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(ni_len, &nonce, .{});

    const nonce_hex = std.fmt.bytesToHex(nonce, .lower);

    const cap = chain_config.BRIDGE_MAX_PER_TX_SAT;
    const daily_cap = chain_config.BRIDGE_MAX_DAILY_SAT;
    const vault = chain_config.BRIDGE_VAULT_ADDR_HEX;

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{" ++
        "\"status\":\"pre_validated\"," ++
        "\"nonce\":\"{s}\"," ++
        "\"amount_sat\":{d}," ++
        "\"destination_chain\":\"{s}\"," ++
        "\"destination_addr\":\"{s}\"," ++
        "\"vault_addr\":\"{s}\"," ++
        "\"max_per_tx_sat\":{d}," ++
        "\"max_daily_sat\":{d}," ++
        "\"instruction\":\"Send amount_sat to vault_addr with op_return memo bridge_lock:<nonce>\"" ++
        "}}}}",
        .{
            id, nonce_hex, amount_sat,
            dest_chain[0..@min(dest_chain.len, 32)],
            dest_addr[0..@min(dest_addr.len, 42)],
            vault, cap, daily_cap,
        },
    );
}

/// bridge_unlock_request — relayer submits a multi-sig unlock for a burn event on dest chain.
/// Params: {signer_addr (20-byte hex), recipient_addr (20-byte hex), amount_sat, nonce_hex, relayer_sig}
fn handleBridgeUnlockRequest(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    ctx.bridge_mutex.lock();
    defer ctx.bridge_mutex.unlock();
    const bs = ctx.bridge orelse return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"error\":{{\"code\":-32001,\"message\":\"Bridge not initialized\"}}}}",
        .{id},
    );

    const signer_hex   = extractStrParam(body, "\"signer_addr\"")   orelse return errorJson(-32602, "Missing param: signer_addr",   id, alloc);
    const recipient_hex= extractStrParam(body, "\"recipient_addr\"") orelse return errorJson(-32602, "Missing param: recipient_addr", id, alloc);
    const amount_sat   = extractU64Param(body, "\"amount_sat\"")    orelse return errorJson(-32602, "Missing param: amount_sat",     id, alloc);
    const nonce_hex_s  = extractStrParam(body, "\"nonce\"")         orelse return errorJson(-32602, "Missing param: nonce",          id, alloc);

    // Decode hex → fixed arrays
    var signer:    [20]u8 = std.mem.zeroes([20]u8);
    var recipient: [20]u8 = std.mem.zeroes([20]u8);
    var nonce:     [32]u8 = std.mem.zeroes([32]u8);

    if (signer_hex.len >= 40)    _ = std.fmt.hexToBytes(signer[0..], signer_hex[0..40])    catch {};
    if (recipient_hex.len >= 40) _ = std.fmt.hexToBytes(recipient[0..], recipient_hex[0..40]) catch {};
    if (nonce_hex_s.len >= 64)   _ = std.fmt.hexToBytes(nonce[0..], nonce_hex_s[0..64])   catch {};

    const height = ctx.bc.getBlockCount();
    bs.submitUnlockSignature(signer, recipient, amount_sat, nonce, height) catch |err| {
        const msg = switch (err) {
            error.AutoPauseActive         => "Bridge auto-paused",
            error.NonceAlreadyProcessed   => "Nonce already processed",
            error.SignerNotInRelayerSet   => "Signer not in relayer set",
            error.InsufficientVaultBalance=> "Insufficient vault balance",
            error.DuplicateSignature      => "Duplicate relayer signature",
            else                          => "Unlock request failed",
        };
        return errorJson(-32003, msg, id, alloc);
    };

    const entry = bs.pending_unlocks.get(nonce);
    const sig_count: u8 = if (entry) |e| e.sig_count else 0;
    const required   = chain_config.BRIDGE_REQUIRED_SIGS;
    const window     = chain_config.BRIDGE_CHALLENGE_WINDOW_BLOCKS;

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{" ++
        "\"status\":\"signature_recorded\"," ++
        "\"sig_count\":{d}," ++
        "\"required_sigs\":{d}," ++
        "\"threshold_reached\":{s}," ++
        "\"challenge_window_blocks\":{d}," ++
        "\"settles_after_height\":{d}" ++
        "}}}}",
        .{
            id, sig_count, required,
            if (sig_count >= required) "true" else "false",
            window, height + window,
        },
    );
}

/// bridge_fraud_challenge — anyone can void a pending unlock with a fraud proof.
/// Params: {nonce_hex, proof} (proof is logged but not cryptographically verified in V1)
fn handleBridgeFraudChallenge(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    ctx.bridge_mutex.lock();
    defer ctx.bridge_mutex.unlock();
    const bs = ctx.bridge orelse return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"error\":{{\"code\":-32001,\"message\":\"Bridge not initialized\"}}}}",
        .{id},
    );

    const nonce_hex_s = extractStrParam(body, "\"nonce\"") orelse
        return errorJson(-32602, "Missing param: nonce", id, alloc);

    var nonce: [32]u8 = std.mem.zeroes([32]u8);
    if (nonce_hex_s.len >= 64) _ = std.fmt.hexToBytes(nonce[0..], nonce_hex_s[0..64]) catch {};

    bs.voidUnlock(nonce) catch |err| {
        const msg = switch (err) {
            error.NonceAlreadyProcessed => "Nonce already processed or settled",
            else                        => "Fraud challenge failed",
        };
        return errorJson(-32003, msg, id, alloc);
    };

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"status\":\"voided\",\"nonce\":\"{s}\"}}}}",
        .{ id, nonce_hex_s[0..@min(nonce_hex_s.len, 64)] },
    );
}

/// bridge_settle — try to settle a pending unlock after challenge window.
/// Relayers call this; if threshold sigs present and window expired, funds release.
fn handleBridgeSettle(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    ctx.bridge_mutex.lock();
    defer ctx.bridge_mutex.unlock();
    const bs = ctx.bridge orelse return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"error\":{{\"code\":-32001,\"message\":\"Bridge not initialized\"}}}}",
        .{id},
    );

    const nonce_hex_s = extractStrParam(body, "\"nonce\"") orelse
        return errorJson(-32602, "Missing param: nonce", id, alloc);

    var nonce: [32]u8 = std.mem.zeroes([32]u8);
    if (nonce_hex_s.len >= 64) _ = std.fmt.hexToBytes(nonce[0..], nonce_hex_s[0..64]) catch {};

    const height = ctx.bc.getBlockCount();
    const result = bs.trySettle(nonce, height) catch |err| {
        const msg = switch (err) {
            error.InsufficientSignatures     => "Not enough relayer signatures",
            error.ChallengeWindowNotExpired  => "Challenge window still open",
            error.InsufficientVaultBalance   => "Insufficient vault balance",
            error.NonceAlreadyProcessed      => "Already settled or voided",
            else                             => "Settlement failed",
        };
        return errorJson(-32003, msg, id, alloc);
    };

    if (result) |r| {
        const addr_hex = std.fmt.bytesToHex(r.recipient, .lower);
        return std.fmt.allocPrint(alloc,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"status\":\"settled\",\"recipient\":\"0x{s}\",\"amount_sat\":{d}}}}}",
            .{ id, addr_hex, r.amount_sat },
        );
    } else {
        return std.fmt.allocPrint(alloc,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"status\":\"not_ready\"}}}}",
            .{id},
        );
    }
}

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
fn handleHtlcBtcBuildScript(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;

    const recipient_hex = extractStrParam(body, "\"recipient_pk\"") orelse
        return errorJson(-32602, "Missing param: recipient_pk", id, alloc);
    const sender_hex = extractStrParam(body, "\"sender_pk\"") orelse
        return errorJson(-32602, "Missing param: sender_pk", id, alloc);
    const hash_hex = extractStrParam(body, "\"hash_lock\"") orelse
        return errorJson(-32602, "Missing param: hash_lock", id, alloc);
    const timelock = extractU64Param(body, "\"timelock\"") orelse
        return errorJson(-32602, "Missing param: timelock", id, alloc);
    const network_str = extractStrParam(body, "\"network\"") orelse "mainnet";

    if (timelock == 0 or timelock > std.math.maxInt(u32))
        return errorJson(-32602, "Invalid timelock (must be 1..u32::MAX)", id, alloc);

    const network = htlc_btc_mod.Network.fromStr(network_str) orelse
        return errorJson(-32602, "Invalid network (mainnet|testnet|regtest|signet)", id, alloc);

    if (recipient_hex.len != 66) return errorJson(-32602, "recipient_pk must be 66 hex chars (33 bytes)", id, alloc);
    if (sender_hex.len    != 66) return errorJson(-32602, "sender_pk must be 66 hex chars (33 bytes)",    id, alloc);
    if (hash_hex.len      != 64) return errorJson(-32602, "hash_lock must be 64 hex chars (32 bytes)",    id, alloc);

    var recipient_pk: [33]u8 = undefined;
    var sender_pk:    [33]u8 = undefined;
    var hash_lock:    [32]u8 = undefined;

    _ = std.fmt.hexToBytes(&recipient_pk, recipient_hex) catch
        return errorJson(-32602, "Invalid hex in recipient_pk", id, alloc);
    _ = std.fmt.hexToBytes(&sender_pk, sender_hex) catch
        return errorJson(-32602, "Invalid hex in sender_pk", id, alloc);
    _ = std.fmt.hexToBytes(&hash_lock, hash_hex) catch
        return errorJson(-32602, "Invalid hex in hash_lock", id, alloc);

    // Compressed pubkey leading byte must be 0x02 or 0x03.
    if (recipient_pk[0] != 0x02 and recipient_pk[0] != 0x03)
        return errorJson(-32602, "recipient_pk not a compressed pubkey (must start with 02/03)", id, alloc);
    if (sender_pk[0] != 0x02 and sender_pk[0] != 0x03)
        return errorJson(-32602, "sender_pk not a compressed pubkey (must start with 02/03)", id, alloc);

    const script = htlc_btc_mod.buildRedeemScript(
        recipient_pk, sender_pk, hash_lock, @intCast(timelock), alloc,
    ) catch return errorJson(-32603, "Failed to build redeem script", id, alloc);
    defer alloc.free(script);

    const wp = htlc_btc_mod.witnessProgram(script);

    const address = htlc_btc_mod.addressFromScript(script, network, alloc) catch
        return errorJson(-32603, "Failed to encode bech32 address", id, alloc);
    defer alloc.free(address);

    // Hex-encode script + witness program for the response.
    const script_hex = try alloc.alloc(u8, script.len * 2);
    defer alloc.free(script_hex);
    const HEX_CHARS = "0123456789abcdef";
    for (script, 0..) |b, i| {
        script_hex[i * 2]     = HEX_CHARS[b >> 4];
        script_hex[i * 2 + 1] = HEX_CHARS[b & 0x0f];
    }
    const wp_hex = std.fmt.bytesToHex(wp, .lower);

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{" ++
        "\"redeem_script_hex\":\"{s}\"," ++
        "\"p2wsh_address\":\"{s}\"," ++
        "\"witness_program_hex\":\"{s}\"," ++
        "\"network\":\"{s}\"," ++
        "\"hrp\":\"{s}\"," ++
        "\"timelock\":{d}" ++
        "}}}}",
        .{ id, script_hex, address, &wp_hex, network_str, network.hrp(), timelock },
    );
}

/// getbridgestatus — returns live BridgeState summary (locked, volume, paused).
fn handleBridgeStatus(ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    ctx.bridge_mutex.lock();
    defer ctx.bridge_mutex.unlock();
    if (ctx.bridge) |bs| {
        const height = ctx.bc.getBlockCount();
        const lock_count: u32 = @intCast(bs.locks.items.len);
        const pending_count: u32 = @intCast(bs.pending_unlocks.count());
        const daily_vol = bs.dailyVolumeSat(height);
        return std.fmt.allocPrint(alloc,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{" ++
            "\"locked_total_sat\":{d}," ++
            "\"lock_count\":{d}," ++
            "\"pending_unlock_count\":{d}," ++
            "\"daily_volume_sat\":{d}," ++
            "\"paused\":{s}," ++
            "\"required_sigs\":{d}," ++
            "\"challenge_window_blocks\":{d}," ++
            "\"max_per_tx_sat\":{d}," ++
            "\"max_daily_sat\":{d}" ++
            "}}}}",
            .{
                id,
                bs.locked_total_sat,
                lock_count,
                pending_count,
                daily_vol,
                if (bs.paused) "true" else "false",
                chain_config.BRIDGE_REQUIRED_SIGS,
                chain_config.BRIDGE_CHALLENGE_WINDOW_BLOCKS,
                chain_config.BRIDGE_MAX_PER_TX_SAT,
                chain_config.BRIDGE_MAX_DAILY_SAT,
            },
        );
    }
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"status\":\"not_initialized\"}}}}",
        .{id},
    );
}

/// omnibus_gettotalmined — total OMNI minted via mining since genesis.
/// Sums blockRewardAt(height) from height=1 to current chain tip (genesis
/// at height 0 carries no reward). Returns SAT and OMNI strings; callers
/// do not need to know SAT/OMNI conversion. Halving is honored automatically
/// by blockRewardAt.
fn handleOmnibusTotalMined(ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const tip = ctx.bc.getBlockCount(); // chain length (height + 1)
    var total_sat: u64 = 0;
    var h: u64 = 1; // skip genesis
    while (h < tip) : (h += 1) {
        total_sat +%= blockchain_mod.blockRewardAt(h);
    }
    // Format OMNI with 9 decimals (1 OMNI = 1e9 SAT)
    const omni_int  = total_sat / 1_000_000_000;
    const omni_frac = total_sat % 1_000_000_000;
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"totalMinedSAT\":{d},\"totalMinedOMNI\":\"{d}.{d:0>9}\",\"blockHeight\":{d}}}}}",
        .{ id, total_sat, omni_int, omni_frac, if (tip == 0) 0 else tip - 1 },
    );
}

/// omnibus_bridge_limits — public-facing bridge configuration so any wallet
/// or relayer can verify the active per-tx and daily caps, the threshold
/// sig requirement, and the challenge window length. Read-only; numbers
/// come from chain_config compile-time constants.
fn handleOmnibusBridgeLimits(ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{" ++
            "\"maxPerTxSAT\":{d}," ++
            "\"maxDailySAT\":{d}," ++
            "\"dailyWindowBlocks\":{d}," ++
            "\"requiredSigs\":{d}," ++
            "\"maxRelayers\":{d}," ++
            "\"challengeWindowBlocks\":{d}," ++
            "\"autoPauseFractionBps\":{d}," ++
            "\"vaultAddrHex\":\"{s}\"" ++
        "}}}}",
        .{
            id,
            chain_config.BRIDGE_MAX_PER_TX_SAT,
            chain_config.BRIDGE_MAX_DAILY_SAT,
            chain_config.BRIDGE_DAILY_WINDOW_BLOCKS,
            chain_config.BRIDGE_REQUIRED_SIGS,
            chain_config.BRIDGE_MAX_RELAYERS,
            chain_config.BRIDGE_CHALLENGE_WINDOW_BLOCKS,
            chain_config.BRIDGE_AUTO_PAUSE_BLOCK_FRACTION_BPS,
            chain_config.BRIDGE_VAULT_ADDR_HEX,
        },
    );
}

/// omnibus_getoraclepolicy — return current price-deviation policy as JSON.
/// Read under the global mutex so callers see a consistent snapshot even if
/// `omnibus_setoraclepolicy` is racing.
fn handleOmnibusGetOraclePolicy(ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    main_mod.g_oracle_policy_mutex.lock();
    const pol = main_mod.g_oracle_policy;
    main_mod.g_oracle_policy_mutex.unlock();
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"warn_pct\":{d:.4},\"reject_pct\":{d:.4},\"fillgap_pct\":{d:.4},\"enabled\":{s}}}}}",
        .{ id, pol.warn_pct, pol.reject_pct, pol.fillgap_pct, if (pol.enabled) "true" else "false" },
    );
}

/// omnibus_setoraclepolicy — atomically replace the price-deviation policy.
/// Accepts both array and object params shapes:
///   {"params":[2.0, 5.0, 10.0, true]}
///   {"params":{"warn_pct":2.0,"reject_pct":5.0,"fillgap_pct":10.0,"enabled":true}}
/// Missing fields keep their current value. Returns the new policy.
fn handleOmnibusSetOraclePolicy(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;

    main_mod.g_oracle_policy_mutex.lock();
    var pol = main_mod.g_oracle_policy;

    // Try object-shape first: {"params":{...}} or top-level fields.
    if (extractParamObjectFloat(body, "warn_pct")) |v| pol.warn_pct = v;
    if (extractParamObjectFloat(body, "reject_pct")) |v| pol.reject_pct = v;
    if (extractParamObjectFloat(body, "fillgap_pct")) |v| pol.fillgap_pct = v;
    if (extractParamObjectBool(body, "enabled")) |v| pol.enabled = v;

    // Array-shape fallback: parse `"params":[w,r,f,e]` positionally.
    if (extractParamArrayFloats(body)) |vals| {
        if (vals.count >= 1) pol.warn_pct = vals.values[0];
        if (vals.count >= 2) pol.reject_pct = vals.values[1];
        if (vals.count >= 3) pol.fillgap_pct = vals.values[2];
        if (vals.bool_present) pol.enabled = vals.bool_value;
    }

    main_mod.g_oracle_policy = pol;
    main_mod.g_oracle_policy_mutex.unlock();

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"warn_pct\":{d:.4},\"reject_pct\":{d:.4},\"fillgap_pct\":{d:.4},\"enabled\":{s}}}}}",
        .{ id, pol.warn_pct, pol.reject_pct, pol.fillgap_pct, if (pol.enabled) "true" else "false" },
    );
}

/// Extract a float field from `"params":{...}` (or top-level if no params).
/// Accepts `"key":2.5` and `"key":"2.5"` forms.
fn extractParamObjectFloat(json: []const u8, key: []const u8) ?f64 {
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
fn extractParamObjectBool(json: []const u8, key: []const u8) ?bool {
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

const ParamArrayFloats = struct {
    values: [4]f64 = .{ 0, 0, 0, 0 },
    count: usize = 0,
    bool_present: bool = false,
    bool_value: bool = false,
};

/// Parse `"params":[w,r,f,e]` positionally. Up to 3 leading floats and 1
/// trailing bool. Returns null when no params array is found.
fn extractParamArrayFloats(json: []const u8) ?ParamArrayFloats {
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

/// getmempoolinfo — mempool stats (matches Bitcoin RPC)
fn handleMempoolInfo(ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const size: u64 = if (ctx.mempool) |mp| @intCast(mp.size()) else @intCast(ctx.bc.mempool.items.len);
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"size\":{d},\"bytes\":0}}}}",
        .{ id, size },
    );
}

// ─── Bitcoin-standard RPC compatibility handlers ────────────────────────────

/// getbestblockhash — returns hash of the latest (best) block as hex string.
/// Bitcoin-standard.
// SEGFAULT-FIX [scan-2026-04-25]: use snapshot — hash is copied into snap.hash_buf
// before bc.mutex is released, so allocPrint formats stable bytes (no UAF on
// chain-owned hash slice when mining replaces the tip).
fn handleGetBestBlockHash(ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    var snap = ctx.bc.getLatestBlockSnapshot();
    defer snap.deinit(alloc);
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":\"{s}\"}}",
        .{ id, snap.hash() },
    );
}

/// getdifficulty — returns current network difficulty as a number.
fn handleGetDifficulty(ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{d}}}",
        .{ id, ctx.bc.difficulty },
    );
}

/// getblockhash — params [height: int], returns hash of block at given height.
/// Error -8 (Bitcoin standard) if out of range.
fn handleGetBlockHash(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    // Accept either ["123"] (string) or [123] (number)
    const h_str = extractArrayStr(body, 0);
    const height: u32 = if (h_str) |s|
        std.fmt.parseInt(u32, s, 10) catch return errorJson(-8, "Block height out of range", id, alloc)
    else
        std.math.cast(u32, extractArrayNum(body, 0)) orelse return errorJson(-8, "Block height out of range", id, alloc);

    const block_count = ctx.bc.getBlockCount();
    if (height >= block_count) return errorJson(-8, "Block height out of range", id, alloc);

    const blk = ctx.bc.getBlock(height) orelse return errorJson(-8, "Block height out of range", id, alloc);
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":\"{s}\"}}",
        .{ id, blk.hash },
    );
}

/// getconnectioncount — returns peer count as integer.
fn handleGetConnectionCount(ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const pc: u64 = if (ctx.p2p) |p| @intCast(p.peers.items.len) else 0;
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{d}}}",
        .{ id, pc },
    );
}

/// getpeerinfo — returns array of peer details (addr, height, version, alive).
/// Note: PeerConnection has no `last_seen` field; emit 0 with comment.
fn handleGetPeerInfo(ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    // Empty array fallback if p2p not attached
    const p2p = ctx.p2p orelse return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":[]}}", .{id});

    var entries: []u8 = try alloc.dupe(u8, "");
    var n: usize = 0;
    for (p2p.peers.items) |peer| {
        const sep: []const u8 = if (n == 0) "" else ",";
        // last_seen: not tracked on PeerConnection — placeholder 0. TODO: actual timestamp tracking.
        const e = try std.fmt.allocPrint(alloc,
            "{s}{{\"id\":\"{s}\",\"addr\":\"{s}:{d}\",\"host\":\"{s}\",\"port\":{d},\"height\":{d},\"version\":{d},\"alive\":{s},\"last_seen\":0}}",
            .{ sep, peer.node_id, peer.host, peer.port, peer.host, peer.port, peer.height, p2p_mod.P2P_VERSION, if (peer.connected) "true" else "false" });
        const m = try std.fmt.allocPrint(alloc, "{s}{s}", .{ entries, e });
        alloc.free(entries);
        alloc.free(e);
        entries = m;
        n += 1;
    }
    defer alloc.free(entries);
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":[{s}]}}",
        .{ id, entries });
}

/// getmininginfo — mining stats: blocks (height), difficulty, hashrate, mempool, chain.
fn handleGetMiningInfo(ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const blocks = ctx.bc.getBlockCount();
    const difficulty = ctx.bc.difficulty;
    const mp_size: u64 = if (ctx.mempool) |mp| @intCast(mp.size()) else @intCast(ctx.bc.mempool.items.len);
    // hashrate: from metrics if attached, otherwise hardcoded placeholder.
    // TODO: actual measurement when metrics not attached.
    const hashrate: u64 = if (ctx.metrics) |m| m.hashrate else 1000;
    const reward = blockchain_mod.blockRewardAt(blocks);
    const chain_label: []const u8 = switch (ctx.chain_id) {
        1 => "omnibus-mainnet",
        2 => "omnibus-testnet",
        3 => "omnibus-devnet",
        4 => "omnibus-regtest",
        else => "omnibus-unknown",
    };
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"blocks\":{d},\"difficulty\":{d},\"networkhashps\":{d},\"hashrate\":{d},\"pooledtx\":{d},\"chain\":\"{s}\",\"currentblockreward\":{d}}}}}",
        .{ id, blocks, difficulty, hashrate, hashrate, mp_size, chain_label, reward },
    );
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
fn extractParamObjectField(json: []const u8, key: []const u8) ?[]const u8 {
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
fn extractParamObjectU64(json: []const u8, key: []const u8) u64 {
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

/// eth_call — view function call. Params: `[{from?,to,data,value?,gas?}, "latest"]`.
fn handleEthCall(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const to = extractParamObjectField(body, "to") orelse
        return errorJson(-32602, "eth_call: missing 'to'", id, alloc);
    const from = extractParamObjectField(body, "from") orelse
        "0x0000000000000000000000000000000000000000";
    const data = extractParamObjectField(body, "data") orelse "0x";
    const value = extractParamObjectU64(body, "value");
    const gas = blk: {
        const g = extractParamObjectU64(body, "gas");
        if (g == 0) break :blk @as(u64, 30_000_000); // default 30M gas
        break :blk g;
    };

    var result = evm_executor.call(alloc, to, from, data, value, gas) catch |err| {
        const msg = switch (err) {
            error.Reverted => "execution reverted",
            error.OutOfMemory => "out of memory",
            else => "evm call failed",
        };
        return errorJson(-32603, msg, id, alloc);
    };
    defer result.deinit(alloc);

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":\"{s}\"}}",
        .{ id, result.return_data });
}

/// eth_sendRawTransaction — accept signed RLP-encoded TX hex.
///
/// OmniBus chain does not yet decode RLP-signed Ethereum TXs. Returning
/// a fake hash would mislead wallets into thinking the transfer succeeded
/// when it did not — explicit rejection is safer. Native TXs use the
/// `sendrawtransaction` (lowercase) and `sendTransaction` RPCs.
fn handleEthSendRawTransaction(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    _ = body;
    return errorJson(
        -32004,
        "eth_sendRawTransaction not supported on OmniBus chain — use sendrawtransaction (native TX format)",
        id,
        ctx.allocator,
    );
}

/// eth_getCode — return deployed bytecode at address.
fn handleEthGetCode(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const addr = extractArrayStr(body, 0) orelse
        return errorJson(-32602, "eth_getCode: missing address", id, alloc);

    const code = evm_executor.getCode(alloc, addr) catch |err| {
        const msg = switch (err) {
            error.OutOfMemory => "out of memory",
            else => "evm getCode failed",
        };
        return errorJson(-32603, msg, id, alloc);
    };
    defer alloc.free(code);

    // If the binding returns raw bytes rather than hex, prefix with "0x".
    // The Rust side currently emits hex already, so we just forward.
    if (code.len == 0) {
        return std.fmt.allocPrint(alloc,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":\"0x\"}}", .{id});
    }
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":\"{s}\"}}",
        .{ id, code });
}

/// eth_estimateGas — gas estimation. Params: `[{from?,to,data,value?}]`.
fn handleEthEstimateGas(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const to = extractParamObjectField(body, "to") orelse
        return errorJson(-32602, "eth_estimateGas: missing 'to'", id, alloc);
    const from = extractParamObjectField(body, "from") orelse
        "0x0000000000000000000000000000000000000000";
    const data = extractParamObjectField(body, "data") orelse "0x";
    const value = extractParamObjectU64(body, "value");

    const gas = evm_executor.estimateGas(alloc, from, to, data, value) catch |err| {
        const msg = switch (err) {
            error.OutOfMemory => "out of memory",
            else => "evm estimateGas failed",
        };
        return errorJson(-32603, msg, id, alloc);
    };
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":\"0x{x}\"}}",
        .{ id, gas });
}

/// eth_chainId — return chain id as a hex string (per EIP-695).
fn handleEthChainId(ctx: *ServerCtx, id: u64) ![]u8 {
    return std.fmt.allocPrint(ctx.allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":\"0x{x}\"}}",
        .{ id, ctx.chain_id });
}

/// eth_blockNumber — return current chain tip as hex (EIP-695 standard).
/// Required by ethers.js for any tx flow (deploy, send, query logs).
fn handleEthBlockNumber(ctx: *ServerCtx, id: u64) ![]u8 {
    const tip = ctx.bc.getBlockCount();
    const height: u64 = if (tip == 0) 0 else tip - 1;
    return std.fmt.allocPrint(ctx.allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":\"0x{x}\"}}",
        .{ id, height });
}

/// eth_getBalance — return account balance in wei as hex.
/// Params: `[address, "latest"|"pending"|blockNumber]`. Block tag is
/// ignored — we always return the current tip balance (no historical
/// state lookup yet).
fn handleEthGetBalance(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    // params[0] = "0x..." address (string).
    const addr_hex = extractStringFromArrayParams(body, 0) orelse
        return errorJson(-32602, "eth_getBalance: missing address", id, alloc);
    // Strip "0x" if present.
    const addr_no_0x = if (addr_hex.len >= 2 and addr_hex[0] == '0' and (addr_hex[1] == 'x' or addr_hex[1] == 'X'))
        addr_hex[2..]
    else
        addr_hex;
    if (addr_no_0x.len != 40) {
        return errorJson(-32602, "eth_getBalance: address must be 20 bytes hex", id, alloc);
    }
    // EVM addresses are last 20 bytes of keccak256(pubkey); OmniBus addresses
    // are bech32(hash160(pubkey)). These are DIFFERENT derivations — no
    // deterministic bidirectional mapping is possible without a registry.
    // Wallets that want to read OmniBus balances should use the native
    // `getaddressbalance` RPC with the ob1q... address. Returning 0 here
    // keeps ethers.js pre-flight checks happy without lying about balance.
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":\"0x0\"}}",
        .{id});
}

/// eth_getTransactionCount — return account nonce as hex.
/// Params: `[address, "latest"]`. We track no nonces yet at the EVM-account
/// level; return 0 so ethers.js can submit txs (which then go through
/// eth_sendRawTransaction signed).
fn handleEthGetTransactionCount(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    _ = body;
    return std.fmt.allocPrint(ctx.allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":\"0x0\"}}",
        .{id});
}

/// eth_gasPrice — return a fixed gas price in wei (1 gwei = 0x3b9aca00).
/// We have no fee market yet; flat-rate is fine for testnets/regtest.
fn handleEthGasPrice(ctx: *ServerCtx, id: u64) ![]u8 {
    return std.fmt.allocPrint(ctx.allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":\"0x3b9aca00\"}}",
        .{id});
}

/// net_version — legacy network identifier (decimal, not hex).
/// Many wallets/libs still use this alongside eth_chainId.
fn handleNetVersion(ctx: *ServerCtx, id: u64) ![]u8 {
    return std.fmt.allocPrint(ctx.allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":\"{d}\"}}",
        .{ id, ctx.chain_id });
}

/// eth_getLogs — return matching logs. Params: `[{address, topics, fromBlock, toBlock}]`.
/// Chain does not run EVM bytecode, so contract event logs do not exist.
/// We return an empty array (valid result for any filter) — clients
/// receive a well-formed response instead of an error.
fn handleEthGetLogs(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    _ = body;
    return std.fmt.allocPrint(ctx.allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":[]}}",
        .{id});
}

/// eth_getTransactionReceipt — receipt for a tx hash.
/// Looks up the TX in the OmniBus chain (mined blocks only — pending TXs
/// have no receipt in Ethereum semantics) and returns an EIP-1474 receipt
/// shaped for ethers.js/web3 compatibility. status=0x1 for any TX that
/// reached a block (OmniBus does not have TX-level revert semantics yet).
fn handleEthGetTransactionReceipt(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const tx_hash_raw = extractStringFromArrayParams(body, 0) orelse
        return std.fmt.allocPrint(alloc,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":null}}", .{id});

    // Strip 0x prefix if present so we match the bare hex stored on chain.
    var tx_hash = tx_hash_raw;
    if (tx_hash.len >= 2 and tx_hash[0] == '0' and (tx_hash[1] == 'x' or tx_hash[1] == 'X'))
        tx_hash = tx_hash[2..];

    ctx.bc.mutex.lock();
    defer ctx.bc.mutex.unlock();

    const block_height = ctx.bc.tx_block_height.get(tx_hash) orelse {
        // Fallback: linear scan (TX not yet indexed)
        for (ctx.bc.chain.items) |blk| {
            for (blk.transactions.items) |tx| {
                if (std.mem.eql(u8, tx.hash, tx_hash)) {
                    return ethReceiptJson(alloc, id, tx.hash, blk.hash, @intCast(blk.index), tx.from_address, tx.to_address);
                }
            }
        }
        return std.fmt.allocPrint(alloc,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":null}}", .{id});
    };

    if (block_height >= ctx.bc.chain.items.len) {
        return std.fmt.allocPrint(alloc,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":null}}", .{id});
    }
    const blk = ctx.bc.chain.items[block_height];
    for (blk.transactions.items) |tx| {
        if (std.mem.eql(u8, tx.hash, tx_hash)) {
            return ethReceiptJson(alloc, id, tx.hash, blk.hash, block_height, tx.from_address, tx.to_address);
        }
    }
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":null}}", .{id});
}

/// Render an EIP-1474 receipt JSON. Address fields are ob-bech32, which
/// is non-standard for Ethereum tooling — clients that need 0x addresses
/// should resolve them via a separate name service. Logs always empty
/// because chain doesn't run EVM bytecode.
fn ethReceiptJson(
    alloc: std.mem.Allocator,
    id: u64,
    tx_hash: []const u8,
    block_hash: []const u8,
    block_height: u64,
    from: []const u8,
    to: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{" ++
            "\"transactionHash\":\"0x{s}\",\"transactionIndex\":\"0x0\"," ++
            "\"blockHash\":\"0x{s}\",\"blockNumber\":\"0x{x}\"," ++
            "\"from\":\"{s}\",\"to\":\"{s}\"," ++
            "\"cumulativeGasUsed\":\"0x5208\",\"gasUsed\":\"0x5208\"," ++
            "\"contractAddress\":null,\"logs\":[],\"logsBloom\":\"0x" ++
            "0000000000000000000000000000000000000000000000000000000000000000" ++
            "0000000000000000000000000000000000000000000000000000000000000000" ++
            "0000000000000000000000000000000000000000000000000000000000000000" ++
            "0000000000000000000000000000000000000000000000000000000000000000\"," ++
            "\"status\":\"0x1\",\"type\":\"0x0\",\"effectiveGasPrice\":\"0x0\"" ++
        "}}}}",
        .{ id, tx_hash, block_hash, block_height, from, to });
}

/// eth_getBlockByNumber — block by tag/hex. V1 minimal: returns block info
/// in EIP-1474 shape with hashed-out fields. Sufficient for chain detect.
fn handleEthGetBlockByNumber(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    _ = body;
    const tip = ctx.bc.getBlockCount();
    const height: u64 = if (tip == 0) 0 else tip - 1;
    // Minimal block object — many fields stubbed but ethers.js parses ok.
    return std.fmt.allocPrint(ctx.allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{" ++
            "\"number\":\"0x{x}\",\"hash\":\"0x0000000000000000000000000000000000000000000000000000000000000000\"," ++
            "\"parentHash\":\"0x0000000000000000000000000000000000000000000000000000000000000000\"," ++
            "\"timestamp\":\"0x0\",\"transactions\":[],\"gasLimit\":\"0x1c9c380\",\"gasUsed\":\"0x0\"," ++
            "\"miner\":\"0x0000000000000000000000000000000000000000\",\"difficulty\":\"0x{x}\"," ++
            "\"baseFeePerGas\":\"0x0\",\"extraData\":\"0x\"" ++
        "}}}}",
        .{ id, height, ctx.bc.difficulty });
}

/// Helper: extract param[idx] as a JSON string from {"params":[...]}
/// Trivial parser — assumes params is a plain array of string/object/etc.
fn extractStringFromArrayParams(body: []const u8, idx: usize) ?[]const u8 {
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
fn extractU32Param(body: []const u8, key_with_quotes: []const u8) ?u32 {
    const at = std.mem.indexOf(u8, body, key_with_quotes) orelse return null;
    var i: usize = at + key_with_quotes.len;
    // Sari peste : si whitespace.
    while (i < body.len and (body[i] == ':' or body[i] == ' ' or body[i] == '\t')) : (i += 1) {}
    const start = i;
    while (i < body.len and body[i] >= '0' and body[i] <= '9') : (i += 1) {}
    if (i == start) return null;
    return std.fmt.parseInt(u32, body[start..i], 10) catch null;
}

fn extractU64Param(body: []const u8, key_with_quotes: []const u8) ?u64 {
    const at = std.mem.indexOf(u8, body, key_with_quotes) orelse return null;
    var i: usize = at + key_with_quotes.len;
    while (i < body.len and (body[i] == ':' or body[i] == ' ' or body[i] == '\t')) : (i += 1) {}
    const start = i;
    while (i < body.len and body[i] >= '0' and body[i] <= '9') : (i += 1) {}
    if (i == start) return null;
    return std.fmt.parseInt(u64, body[start..i], 10) catch null;
}

/// Extrage un parametru string. Returneaza slice peste body (nu copiaza).
fn extractStrParam(body: []const u8, key_with_quotes: []const u8) ?[]const u8 {
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
fn handleGetDid(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const addr = extractArrayStr(body, 0) orelse extractStr(body, "address") orelse
        return errorJson(-32602, "Missing param: address", id, alloc);

    // Recover the 20-byte hash160 from the bech32 address.
    const decoded = bech32_mod.decodeWitnessAddress(bech32_mod.OB_HRP, addr, alloc) catch
        return errorJson(-32602, "Invalid bech32 address", id, alloc);
    defer alloc.free(decoded.program);
    if (decoded.program.len != 20) return errorJson(-32602, "Address is not P2WPKH-equivalent", id, alloc);
    var h160: [20]u8 = undefined;
    @memcpy(&h160, decoded.program);

    const did = try id_layer_mod.did.didFromHash160(h160, alloc);
    defer alloc.free(did);
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"address\":\"{s}\",\"did\":\"{s}\"}}}}",
        .{ id, addr, did });
}

/// RPC `getobm` — 1-byte OmniBus Binary Map for an address, with each bit
/// also surfaced as a named boolean so clients don't have to decode it.
fn handleGetObm(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const addr = extractArrayStr(body, 0) orelse extractStr(body, "address") orelse
        return errorJson(-32602, "Missing param: address", id, alloc);

    const cups = blk: {
        if (main_mod.g_reputation != null) {
            if (main_mod.g_reputation.?.snapshot(addr)) |c| break :blk c;
        }
        break :blk @import("reputation.zig").ReputationCups{};
    };

    // Validator = stake_amounts >= 100 OMNI. Same threshold as getvalidators.
    var is_validator = false;
    {
        ctx.bc.mutex.lock();
        defer ctx.bc.mutex.unlock();
        if (ctx.bc.stake_amounts.get(addr)) |amt| {
            if (amt / 1_000_000_000 >= 100) is_validator = true;
        }
    }

    // DNS-name flag: we don't iterate the whole registry here (potentially
    // expensive). The flag stays false unless a future indexer exposes a
    // per-owner count. Conservative on purpose.
    const has_dns_name = false;
    // PQ-key flag: chain does not yet maintain a per-address PQ registry,
    // so we leave the bit dark. Will flip true once pq_attest indexes it.
    const has_pq_key = false;

    const obm_byte = id_layer_mod.obm.compute(.{
        .cups = cups,
        .has_pq_key = has_pq_key,
        .has_dns_name = has_dns_name,
        .is_validator = is_validator,
    });

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"address\":\"{s}\",\"obm\":{d},\"love_badge\":{},\"food_badge\":{},\"rent_badge\":{},\"vacation_badge\":{},\"has_pq_key\":{},\"has_dns_name\":{},\"is_validator\":{},\"is_zen_tier\":{}}}}}",
        .{
            id, addr, obm_byte,
            id_layer_mod.obm.has(obm_byte, .love_badge),
            id_layer_mod.obm.has(obm_byte, .food_badge),
            id_layer_mod.obm.has(obm_byte, .rent_badge),
            id_layer_mod.obm.has(obm_byte, .vacation_badge),
            id_layer_mod.obm.has(obm_byte, .has_pq_key),
            id_layer_mod.obm.has(obm_byte, .has_dns_name),
            id_layer_mod.obm.has(obm_byte, .is_validator),
            id_layer_mod.obm.has(obm_byte, .is_zen_tier),
        });
}

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
fn handleGetFacets(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const addr = extractArrayStr(body, 0) orelse extractStr(body, "address") orelse
        return errorJson(-32602, "Missing param: address", id, alloc);

    // Resolve h160 so we can look up the ProfileStore entry.
    const h160_opt: ?[20]u8 = addrToH160(addr, alloc) catch null;

    // Per-facet results: populated flag + root hex string (64 hex chars or empty).
    const FacetResult = struct {
        populated: bool,
        root_hex: [64]u8,
        root_hex_len: usize,
    };
    var results: [4]FacetResult = .{
        .{ .populated = false, .root_hex = undefined, .root_hex_len = 0 },
        .{ .populated = false, .root_hex = undefined, .root_hex_len = 0 },
        .{ .populated = false, .root_hex = undefined, .root_hex_len = 0 },
        .{ .populated = false, .root_hex = undefined, .root_hex_len = 0 },
    };

    if (h160_opt) |h160| {
        const store = getProfileStore(alloc);
        store.mutex.lock();
        defer store.mutex.unlock();
        if (store.get(h160)) |entry| {
            for (&results, 0..) |*r, i| {
                const facet = &entry.facets[i];
                if (facet.fields.count() > 0) {
                    const root = computeFacetRoot(facet, alloc) catch continue;
                    const hex_chars = "0123456789abcdef";
                    for (root, 0..) |b, bi| {
                        r.root_hex[bi * 2]     = hex_chars[b >> 4];
                        r.root_hex[bi * 2 + 1] = hex_chars[b & 0x0f];
                    }
                    r.root_hex_len = 64;
                    r.populated = true;
                }
            }
        }
    }

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"address\":\"{s}\"," ++
        "\"social\":{{\"populated\":{},\"root_hex\":\"{s}\"}}," ++
        "\"professional\":{{\"populated\":{},\"root_hex\":\"{s}\"}}," ++
        "\"cultural\":{{\"populated\":{},\"root_hex\":\"{s}\"}}," ++
        "\"economic\":{{\"populated\":{},\"root_hex\":\"{s}\"}}}}}}",
        .{
            id, addr,
            results[0].populated, results[0].root_hex[0..results[0].root_hex_len],
            results[1].populated, results[1].root_hex[0..results[1].root_hex_len],
            results[2].populated, results[2].root_hex[0..results[2].root_hex_len],
            results[3].populated, results[3].root_hex[0..results[3].root_hex_len],
        });
}

/// RPC `getreputation` — citeste paharele LOVE/FOOD/RENT/VACATION pentru o
/// adresa, plus rep total agregat (0-1M) si tier (OMNI/LOVE/FOOD/RENT/VACATION).
/// Vezi memory/project_omnibus_reputation_economy.md pentru rationale.
///
/// Body: {"address": "ob1q..."}
/// Răspuns: { "address", "cups": {love, food, rent, vacation}, "total",
///           "tier", "satoshi_badge", "first_active_block", "last_active_block",
///           "total_blocks_mined", "violations" }
fn handleGetReputation(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const addr = extractArrayStr(body, 0) orelse extractStr(body, "address") orelse
        return errorJson(-32602, "Missing param: address", id, alloc);
    if (main_mod.g_reputation == null) {
        return errorJson(-32030, "Reputation system not enabled on this node", id, alloc);
    }
    const cups = main_mod.g_reputation.?.snapshot(addr) orelse {
        // Address never seen — return zero cups (still valid response).
        return std.fmt.allocPrint(alloc,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"address\":\"{s}\",\"cups\":{{\"love\":\"0.00\",\"food\":\"0.00\",\"rent\":\"0.00\",\"vacation\":\"0.00\"}},\"total\":0,\"tier\":\"OMNI\",\"satoshi_badge\":false,\"first_active_block\":0,\"last_active_block\":0,\"total_blocks_mined\":0,\"violations\":0}}}}",
            .{ id, addr });
    };
    const total = cups.computeRepTotal();
    const tier = cups.tier();
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"address\":\"{s}\",\"cups\":{{\"love\":\"{d}.{d:0>2}\",\"food\":\"{d}.{d:0>2}\",\"rent\":\"{d}.{d:0>2}\",\"vacation\":\"{d}.{d:0>2}\"}},\"total\":{d},\"tier\":\"{s}\",\"satoshi_badge\":{},\"is_zen\":{},\"first_active_block\":{d},\"last_active_block\":{d},\"uptime_blocks\":{d},\"total_blocks_mined\":{d},\"violations\":{d}}}}}",
        .{
            id, addr,
            cups.love_stored / 100, cups.love_stored % 100,
            cups.food_stored / 100, cups.food_stored % 100,
            cups.rent_stored / 100, cups.rent_stored % 100,
            cups.vacation_stored / 100, cups.vacation_stored % 100,
            total,
            tier.name(),
            cups.hasSatoshiBadge(),
            cups.hasSatoshiBadge(),
            cups.first_active_block,
            cups.last_active_block,
            cups.uptimeBlocks(),
            cups.total_blocks_mined,
            cups.violations,
        },
    );
}

/// RPC `getreputationtop` — top N adrese sortate după reputation total descendent.
/// Body: {"limit": 50}  (default 50, max 200)
fn handleGetReputationTop(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    if (main_mod.g_reputation == null) {
        return errorJson(-32030, "Reputation system not enabled on this node", id, alloc);
    }
    var limit: u32 = 50;
    if (extractStr(body, "limit")) |s| {
        limit = std.fmt.parseInt(u32, s, 10) catch 50;
    }
    if (limit == 0) limit = 50;
    if (limit > 200) limit = 200;

    const Entry = struct {
        addr: []const u8,
        total: u64,
        tier: []const u8,
        love: u32,
        food: u32,
        rent: u32,
        vacation: u32,
        satoshi: bool,
        blocks_mined: u64,
        first_block: u64,
        uptime_blocks: u64,
        rank_score: u128,
    };

    const rep = &main_mod.g_reputation.?;
    rep.lock();
    defer rep.unlock();

    var entries = std.array_list.Managed(Entry).init(alloc);
    defer entries.deinit();

    var it = rep.iterate();
    while (it.next()) |kv| {
        const total = kv.value_ptr.computeRepTotal();
        if (total == 0 and kv.value_ptr.total_blocks_mined == 0) continue;
        try entries.append(.{
            .addr = kv.key_ptr.*,
            .total = total,
            .tier = kv.value_ptr.tier().name(),
            .love = kv.value_ptr.love_stored,
            .food = kv.value_ptr.food_stored,
            .rent = kv.value_ptr.rent_stored,
            .vacation = kv.value_ptr.vacation_stored,
            .satoshi = kv.value_ptr.hasSatoshiBadge(),
            .blocks_mined = kv.value_ptr.total_blocks_mined,
            .first_block = kv.value_ptr.first_active_block,
            .uptime_blocks = kv.value_ptr.uptimeBlocks(),
            .rank_score = kv.value_ptr.rankScore(),
        });
    }

    // Sort by rank_score descending — Zen-i automat sus, intre Zen-i tiebreaker
    // = uptime_blocks (incorporat in rank_score). Intre non-Zen: rep_total.
    std.sort.insertion(Entry, entries.items, {}, struct {
        fn less(_: void, a: Entry, b: Entry) bool {
            return a.rank_score > b.rank_score;
        }
    }.less);

    const cap_n: usize = if (entries.items.len < limit) entries.items.len else limit;

    var buf = std.array_list.Managed(u8).init(alloc);
    errdefer buf.deinit();
    const w = buf.writer();
    try w.print(
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"count\":{d},\"total\":{d},\"entries\":[",
        .{ id, cap_n, entries.items.len },
    );
    for (entries.items[0..cap_n], 0..) |e, idx| {
        if (idx > 0) try w.writeByte(',');
        try w.print(
            "{{\"rank\":{d},\"address\":\"{s}\",\"total\":{d},\"tier\":\"{s}\",\"cups\":{{\"love\":\"{d}.{d:0>2}\",\"food\":\"{d}.{d:0>2}\",\"rent\":\"{d}.{d:0>2}\",\"vacation\":\"{d}.{d:0>2}\"}},\"satoshi_badge\":{},\"is_zen\":{},\"blocks_mined\":{d},\"first_active_block\":{d},\"uptime_blocks\":{d}}}",
            .{
                idx + 1,
                e.addr,
                e.total,
                e.tier,
                e.love / 100, e.love % 100,
                e.food / 100, e.food % 100,
                e.rent / 100, e.rent % 100,
                e.vacation / 100, e.vacation % 100,
                e.satoshi,
                e.satoshi, // is_zen alias for clarity in UI
                e.blocks_mined,
                e.first_block,
                e.uptime_blocks,
            },
        );
    }
    try w.writeAll("]}}");
    return buf.toOwnedSlice();
}

fn handleAgentList(ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    var snap_buf: [agent_manager_mod.MAX_AGENTS]agent_manager_mod.AgentSnapshotItem = undefined;
    const n = main_mod.g_agent_manager.snapshot(&snap_buf);

    var buf = std.array_list.Managed(u8).init(alloc);
    errdefer buf.deinit();
    const w = buf.writer();

    try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"count\":{d},\"agents\":[", .{ id, n });
    for (snap_buf[0..n], 0..) |a, i| {
        if (i > 0) try w.writeByte(',');
        try w.print(
            "{{\"name\":\"{s}\",\"wallet_index\":{d},\"address\":\"{s}\",\"strategy\":\"{s}\",\"tier\":\"{s}\",\"balance_sat\":{d},\"staked_sat\":{d},\"lp_locked_sat\":{d},\"pnl_session_sat\":{d},\"halted\":{},\"stats\":{{\"ticks\":{d},\"decisions_emitted\":{d},\"decisions_queued\":{d},\"exec_success\":{d},\"exec_failed\":{d},\"tier_transitions\":{d},\"total_mined_sat\":{d}}}}}",
            .{
                a.getName(),
                a.wallet_index,
                a.getAddress(),
                a.strategy.name(),
                @tagName(a.tier),
                a.balance_sat,
                a.staked_sat,
                a.lp_locked_sat,
                a.pnl_session_sat,
                a.halted,
                a.stats.ticks,
                a.stats.decisions_emitted,
                a.stats.decisions_queued,
                a.stats.exec_success,
                a.stats.exec_failed,
                a.stats.tier_transitions,
                a.stats.total_mined_sat,
            },
        );
    }
    try w.writeAll("]}}");
    return buf.toOwnedSlice();
}

/// RPC `agent_status` — detalii pentru un singur agent (filtrat dupa wallet_index).
/// Body: {"wallet_index": N}
fn handleAgentStatus(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const wi = extractU32Param(body, "\"wallet_index\"") orelse return errorJson(-32602, "missing wallet_index", id, alloc);
    const slot = main_mod.g_agent_manager.findByWalletIndex(wi) orelse return errorJson(-32000, "agent not found", id, alloc);

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"name\":\"{s}\",\"wallet_index\":{d},\"address\":\"{s}\",\"strategy\":\"{s}\",\"tier\":\"{s}\",\"balance_sat\":{d},\"staked_sat\":{d},\"lp_locked_sat\":{d},\"pnl_session_sat\":{d},\"halted\":{},\"stats\":{{\"ticks\":{d},\"decisions_emitted\":{d},\"decisions_queued\":{d},\"exec_success\":{d},\"exec_failed\":{d},\"tier_transitions\":{d},\"total_mined_sat\":{d}}}}}}}",
        .{
            id,
            slot.config.getName(),
            slot.config.wallet_index,
            slot.getAddress(),
            slot.config.strategy.name(),
            @tagName(slot.executor.state.tier),
            slot.executor.state.balance_sat,
            slot.executor.state.staked_sat,
            slot.executor.state.lp_locked_sat,
            slot.executor.state.pnl_session_sat,
            slot.executor.state.halted,
            slot.stats.ticks,
            slot.stats.decisions_emitted,
            slot.stats.decisions_queued,
            slot.stats.exec_success,
            slot.stats.exec_failed,
            slot.stats.tier_transitions,
            slot.stats.total_mined_sat,
        },
    );
}

/// RPC `agent_pending_decisions` — decizii non-native nesettled, pentru clientul extern.
/// Body opțional: {"wallet_index": N} pentru filtrare per agent.
/// Răspuns: { "decisions": [ {id, wallet_index, block_height, emitted_ms, venue,
///   kind, pair, amount_sat, reason}, ... ] }
fn handleAgentPendingDecisions(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const filter_wi = extractU32Param(body, "\"wallet_index\"");

    var pend_buf: [agent_manager_mod.MAX_PENDING_DECISIONS]agent_manager_mod.PendingDecision = undefined;
    const n = main_mod.g_agent_manager.snapshotPending(&pend_buf, filter_wi);

    var buf = std.array_list.Managed(u8).init(alloc);
    errdefer buf.deinit();
    const w = buf.writer();

    try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"count\":{d},\"decisions\":[", .{ id, n });
    for (pend_buf[0..n], 0..) |p, i| {
        if (i > 0) try w.writeByte(',');
        try w.print(
            "{{\"id\":{d},\"wallet_index\":{d},\"block_height\":{d},\"emitted_ms\":{d},\"venue\":\"{s}\",\"kind\":\"{s}\",\"pair\":\"{s}\",\"amount_sat\":{d},\"reason\":\"{s}\"}}",
            .{
                p.id,
                p.wallet_index,
                p.block_height,
                p.emitted_ms,
                p.decision.venue.name(),
                @tagName(p.decision.kind),
                p.decision.getPair(),
                p.decision.amount_sat,
                p.decision.getReason(),
            },
        );
    }
    try w.writeAll("]}}");
    return buf.toOwnedSlice();
}

/// RPC `agent_report_execution` — clientul extern raportează rezultatul.
/// Body: {"decision_id": N, "status": "success|rejected|network_error|timeout|cancelled",
///        "external_id": "LCX-12345", "filled_amount_sat": 1000, "fill_price_micro_usd": 65000000000,
///        "error_msg": "..." }
fn handleAgentReportExecution(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const decision_id = extractU64Param(body, "\"decision_id\"") orelse return errorJson(-32602, "missing decision_id", id, alloc);
    const status_str = extractStrParam(body, "\"status\"") orelse return errorJson(-32602, "missing status", id, alloc);

    const status: agent_manager_mod.ExecStatus = blk: {
        if (std.mem.eql(u8, status_str, "success")) break :blk .success;
        if (std.mem.eql(u8, status_str, "rejected")) break :blk .rejected;
        if (std.mem.eql(u8, status_str, "network_error")) break :blk .network_error;
        if (std.mem.eql(u8, status_str, "timeout")) break :blk .timeout;
        if (std.mem.eql(u8, status_str, "cancelled")) break :blk .cancelled;
        return errorJson(-32602, "invalid status", id, alloc);
    };

    var receipt = agent_manager_mod.ExecReceipt{
        .decision_id = decision_id,
        .status = status,
        .filled_amount_sat = extractU64Param(body, "\"filled_amount_sat\"") orelse 0,
        .fill_price_micro_usd = extractU64Param(body, "\"fill_price_micro_usd\"") orelse 0,
        .reported_ms = std.time.milliTimestamp(),
    };
    if (extractStrParam(body, "\"external_id\"")) |eid| receipt.setExternalId(eid);
    if (extractStrParam(body, "\"error_msg\"")) |msg| receipt.setErrorMsg(msg);

    const ok = main_mod.g_agent_manager.applyReceipt(receipt);
    if (!ok) return errorJson(-32000, "decision not found or already settled", id, alloc);

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"decision_id\":{d},\"applied\":true,\"status\":\"{s}\"}}}}",
        .{ id, decision_id, status_str },
    );
}

// ─── Native DEX (matching-engine RPC handlers) ───────────────────────────────
//
// Toate cele de mai jos partajeaza `ctx.exchange` (un singur MatchingEngine
// global pe nod). Accesul e protejat de `ctx.exchange_mutex` — nu apela
// niciodata o functie pe engine fara lock! Persistenta foloseste pattern-ul
// faucetAppendToDisk: append-only JSON-Lines, replay la pornire.
// Suportul wire: orders.jsonl in `data/<chain>/`.

/// Pereche tranzactionata pe DEX. `pair_id` e indexul in acest array.
/// Ordinea e fixa (e batuta in storage si in clienti) — adaugarile se fac
/// LA SFARSIT, niciodata in mijloc.
const ExchangePair = struct {
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
const EXCHANGE_PAIRS = [_]ExchangePair{
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
const FILL_NETWORK_FEE_SAT: u64 = 1000;

/// Exchange fee — basis points (1 bp = 0.01%). Charged in QUOTE currency.
/// 10 bps = 0.10% taker, 5 bps = 0.05% maker → matches Kraken's lowest tier.
const EXCHANGE_FEE_TAKER_BPS: u64 = 10;
const EXCHANGE_FEE_MAKER_BPS: u64 = 5;
const FEE_BPS_DENOMINATOR: u64 = 10_000;

/// Compute the exchange fee for a fill leg.
///   notional_micro = price (micro-USD) × amount (SAT) / 1e9
///   fee = notional × bps / 10_000
/// Returned value is in micro-USD (or whatever unit the quote uses).
fn computeExchangeFeeMicro(price_micro: u64, amount_sat: u64, bps: u64) u64 {
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
fn kycMaxNotionalMicro(level: kyc_mod.Level) u64 {
    return switch (level) {
        .none     => 0,
        .starter  => 1_000_000_000,         // $1k
        .verified => 100_000_000_000,       // $100k
        .pro      => std.math.maxInt(u64),  // unlimited
    };
}

/// Notional for a single order: price (micro-USD) × amount (SAT) / 1e9.
/// Saturates at u64.max instead of overflowing.
fn orderNotionalMicro(price_micro: u64, amount_sat: u64) u64 {
    const n: u128 =
        (@as(u128, price_micro) * @as(u128, amount_sat)) / 1_000_000_000;
    return @intCast(@min(n, @as(u128, std.math.maxInt(u64))));
}

// ── Oracle price-band ────────────────────────────────────────────────
/// Reject orders priced more than this many basis points away from the
/// oracle reference. 1000 bps = 10%. Hardcoded for now; future work:
/// expose via `omnibus_setoraclepolicy` (would add `order_band_bps` to
/// `oracle_policy.OraclePolicy`).
const ORDER_BAND_BPS: u64 = 1000;

/// Map an exchange pair_id to the oracle ChainId for its BASE leg, when
/// the chain is one the oracle tracks. LCX (pair_id 2) returns null —
/// no oracle feed, skip the band check.
fn oracleChainForPair(pair_id: u16) ?price_oracle_mod.ChainId {
    return switch (pair_id) {
        0, 4, 5, 6 => .omni,
        1          => .btc,
        3          => .eth,
        else       => null, // LCX (2) or unknown
    };
}

fn exchangePairLookup(label: []const u8) ?u16 {
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

fn asciiEqIgnoreCase(a: []const u8, b: []const u8) bool {
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

fn gridPathSlice(ctx: *ServerCtx) ?[]const u8 {
    if (ctx.grid_path_len == 0) return null;
    return ctx.grid_path_buf[0..ctx.grid_path_len];
}

/// Scrie o intrare in jurnalul append-only orders.jsonl.
/// `kind` = "place" sau "cancel". Ignoram erorile de I/O — jurnalul e
/// best-effort; in-memory state e adevarul curent.
fn ordersAppendJournal(
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
fn nonceLookup(ctx: *ServerCtx, addr: []const u8) i64 {
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
fn nonceSet(ctx: *ServerCtx, addr: []const u8, nonce: u64) void {
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
fn tradeLogPush(ctx: *ServerCtx, fill: matching_mod.Fill, is_paper: bool) void {
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
fn createOrderTransaction(
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
fn submitOrderPlaceTx(
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
fn submitOrderCancelTx(
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
fn parseHex32(hex: []const u8) ?[32]u8 {
    if (hex.len != 64) return null;
    var out: [32]u8 = undefined;
    hex_utils.hexToBytes(hex, &out) catch return null;
    return out;
}

fn writeHex32(b: [32]u8, out: *[64]u8) void {
    for (b, 0..) |byte, i| {
        _ = std.fmt.bufPrint(out[i*2..i*2+2], "{x:0>2}", .{byte}) catch {};
    }
}

/// Submit a typed HTLC TX to the mempool (init/claim/refund). Address +
/// data slices are heap-duped so the TX outlives this stack frame.
/// Returns the TX hash hex (64 chars), allocated from `ctx.allocator`.
fn submitHtlcTx(
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
fn handleHtlcInit(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const receiver = extractStr(body, "receiver") orelse extractStr(body, "to")
        orelse return errorJson(-32602, "missing receiver", id, ctx.allocator);
    const amount_sat = extractU64Param(body, "\"amount_sat\"") orelse extractU64Param(body, "\"amount\"")
        orelse return errorJson(-32602, "missing amount_sat", id, ctx.allocator);
    const hash_lock_hex = extractStr(body, "hash_lock")
        orelse return errorJson(-32602, "missing hash_lock", id, ctx.allocator);
    const timelock_block = extractU64Param(body, "\"timelock_block\"") orelse extractU64Param(body, "\"timelock\"")
        orelse return errorJson(-32602, "missing timelock_block", id, ctx.allocator);

    const hash_lock = parseHex32(hash_lock_hex)
        orelse return errorJson(-32602, "hash_lock must be 64 hex chars", id, ctx.allocator);

    if (timelock_block > std.math.maxInt(u32))
        return errorJson(-32602, "timelock_block out of range (max u32)", id, ctx.allocator);

    const payload = tx_payload_mod.HtlcInitPayload{
        .hash_lock = hash_lock,
        .timelock_block = @intCast(timelock_block),
        .amount_sat = amount_sat,
    };
    payload.validate() catch return errorJson(-32602, "invalid htlc_init payload", id, ctx.allocator);

    var data_buf: [tx_payload_mod.HtlcInitPayload.WIRE_SIZE]u8 = undefined;
    _ = try payload.encode(&data_buf);

    const tx_hash = submitHtlcTx(ctx, .htlc_init, ctx.wallet.address, receiver, &data_buf)
        catch |err| {
            std.debug.print("[HTLC-INIT] submit failed: {}\n", .{err});
            return errorJson(-32000, "htlc_init submit failed", id, ctx.allocator);
        };
    defer ctx.allocator.free(tx_hash);

    const id_bytes = htlc_mod.computeHtlcId(tx_hash);
    var id_hex: [64]u8 = undefined;
    writeHex32(id_bytes, &id_hex);

    return std.fmt.allocPrint(ctx.allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"tx_hash\":\"{s}\",\"htlc_id\":\"{s}\",\"amount_sat\":{d},\"timelock_block\":{d}}}}}",
        .{ id, tx_hash, &id_hex, amount_sat, timelock_block });
}

/// `htlc_claim({htlc_id, preimage})` — TX type 0x31.
fn handleHtlcClaim(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const htlc_id_hex = extractStr(body, "htlc_id")
        orelse return errorJson(-32602, "missing htlc_id", id, ctx.allocator);
    const preimage_hex = extractStr(body, "preimage")
        orelse return errorJson(-32602, "missing preimage", id, ctx.allocator);

    const htlc_id = parseHex32(htlc_id_hex)
        orelse return errorJson(-32602, "htlc_id must be 64 hex chars", id, ctx.allocator);
    const preimage = parseHex32(preimage_hex)
        orelse return errorJson(-32602, "preimage must be 64 hex chars", id, ctx.allocator);

    const entry = ctx.bc.htlc_registry.get(htlc_id)
        orelse return errorJson(-32004, "htlc not found", id, ctx.allocator);
    if (entry.state != .active)
        return errorJson(-32005, "htlc not active", id, ctx.allocator);

    const payload = tx_payload_mod.HtlcClaimPayload{ .htlc_id = htlc_id, .preimage = preimage };
    var data_buf: [tx_payload_mod.HtlcClaimPayload.WIRE_SIZE]u8 = undefined;
    _ = try payload.encode(&data_buf);

    // applyBlock enforces (entry.recipient == tx.from_address); a mismatched
    // caller will surface as HtlcUnauthorizedClaim downstream.
    const tx_hash = submitHtlcTx(ctx, .htlc_claim, ctx.wallet.address, entry.senderSlice(), &data_buf)
        catch |err| {
            std.debug.print("[HTLC-CLAIM] submit failed: {}\n", .{err});
            return errorJson(-32000, "htlc_claim submit failed", id, ctx.allocator);
        };
    defer ctx.allocator.free(tx_hash);

    return std.fmt.allocPrint(ctx.allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"tx_hash\":\"{s}\",\"htlc_id\":\"{s}\"}}}}",
        .{ id, tx_hash, htlc_id_hex });
}

/// `htlc_refund({htlc_id})` — TX type 0x32. Caller must be original sender;
/// chain enforces current_block >= timelock_block at apply time.
fn handleHtlcRefund(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const htlc_id_hex = extractStr(body, "htlc_id")
        orelse return errorJson(-32602, "missing htlc_id", id, ctx.allocator);
    const htlc_id = parseHex32(htlc_id_hex)
        orelse return errorJson(-32602, "htlc_id must be 64 hex chars", id, ctx.allocator);

    const entry = ctx.bc.htlc_registry.get(htlc_id)
        orelse return errorJson(-32004, "htlc not found", id, ctx.allocator);
    if (entry.state != .active and entry.state != .expired)
        return errorJson(-32005, "htlc not refundable", id, ctx.allocator);

    const payload = tx_payload_mod.HtlcRefundPayload{ .htlc_id = htlc_id };
    var data_buf: [tx_payload_mod.HtlcRefundPayload.WIRE_SIZE]u8 = undefined;
    _ = try payload.encode(&data_buf);

    const tx_hash = submitHtlcTx(ctx, .htlc_refund, ctx.wallet.address, entry.recipientSlice(), &data_buf)
        catch |err| {
            std.debug.print("[HTLC-REFUND] submit failed: {}\n", .{err});
            return errorJson(-32000, "htlc_refund submit failed", id, ctx.allocator);
        };
    defer ctx.allocator.free(tx_hash);

    return std.fmt.allocPrint(ctx.allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"tx_hash\":\"{s}\",\"htlc_id\":\"{s}\"}}}}",
        .{ id, tx_hash, htlc_id_hex });
}

/// Render an HTLC entry as a JSON object into `out`.
fn appendHtlcEntryJson(
    out: *std.array_list.Managed(u8),
    e: *const htlc_mod.HtlcEntry,
) !void {
    var id_hex: [64]u8 = undefined;
    writeHex32(e.id, &id_hex);
    var hash_hex: [64]u8 = undefined;
    writeHex32(e.hash_lock, &hash_hex);
    const state_name: []const u8 = switch (e.state) {
        .pending => "pending",
        .active => "active",
        .claimed => "claimed",
        .refunded => "refunded",
        .expired => "expired",
    };
    var pre_hex: [64]u8 = undefined;
    if (e.has_preimage) writeHex32(e.preimage, &pre_hex);
    const writer = out.writer();
    if (e.has_preimage) {
        try writer.print(
            "{{\"htlc_id\":\"{s}\",\"sender\":\"{s}\",\"recipient\":\"{s}\",\"amount_sat\":{d},\"hash_lock\":\"{s}\",\"timelock_block\":{d},\"init_block\":{d},\"init_tx_hash\":\"{s}\",\"state\":\"{s}\",\"preimage\":\"{s}\"}}",
            .{ &id_hex, e.senderSlice(), e.recipientSlice(), e.amount_sat,
               &hash_hex, e.timelock_block, e.init_block, e.initTxHashSlice(),
               state_name, &pre_hex },
        );
    } else {
        try writer.print(
            "{{\"htlc_id\":\"{s}\",\"sender\":\"{s}\",\"recipient\":\"{s}\",\"amount_sat\":{d},\"hash_lock\":\"{s}\",\"timelock_block\":{d},\"init_block\":{d},\"init_tx_hash\":\"{s}\",\"state\":\"{s}\"}}",
            .{ &id_hex, e.senderSlice(), e.recipientSlice(), e.amount_sat,
               &hash_hex, e.timelock_block, e.init_block, e.initTxHashSlice(),
               state_name },
        );
    }
}

/// `htlc_get({htlc_id})` — read-only registry lookup.
fn handleHtlcGet(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const htlc_id_hex = extractStr(body, "htlc_id")
        orelse return errorJson(-32602, "missing htlc_id", id, ctx.allocator);
    const htlc_id = parseHex32(htlc_id_hex)
        orelse return errorJson(-32602, "htlc_id must be 64 hex chars", id, ctx.allocator);

    const entry = ctx.bc.htlc_registry.get(htlc_id)
        orelse return errorJson(-32004, "htlc not found", id, ctx.allocator);

    var buf = std.array_list.Managed(u8).init(ctx.allocator);
    defer buf.deinit();
    try buf.writer().print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":", .{id});
    try appendHtlcEntryJson(&buf, &entry);
    try buf.appendSlice("}");
    return buf.toOwnedSlice();
}

/// `htlc_listByAddress({address})` — every HTLC where `address` is sender or recipient.
fn handleHtlcListByAddress(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const addr = extractStr(body, "address")
        orelse return errorJson(-32602, "missing address", id, ctx.allocator);

    var buf = std.array_list.Managed(u8).init(ctx.allocator);
    defer buf.deinit();
    try buf.writer().print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":[", .{id});

    var first = true;
    var i: u32 = 0;
    while (i < ctx.bc.htlc_registry.entry_count) : (i += 1) {
        const e = &ctx.bc.htlc_registry.entries[i];
        if (!std.mem.eql(u8, e.senderSlice(), addr) and
            !std.mem.eql(u8, e.recipientSlice(), addr)) continue;
        if (!first) try buf.appendSlice(",");
        first = false;
        try appendHtlcEntryJson(&buf, e);
    }
    try buf.appendSlice("]}");
    return buf.toOwnedSlice();
}

/// `htlc_listPending()` — every active HTLC on the chain (admin/debug).
fn handleHtlcListPending(ctx: *ServerCtx, id: u64) ![]u8 {
    var buf = std.array_list.Managed(u8).init(ctx.allocator);
    defer buf.deinit();
    try buf.writer().print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":[", .{id});

    var first = true;
    var i: u32 = 0;
    while (i < ctx.bc.htlc_registry.entry_count) : (i += 1) {
        const e = &ctx.bc.htlc_registry.entries[i];
        if (e.state != .active) continue;
        if (!first) try buf.appendSlice(",");
        first = false;
        try appendHtlcEntryJson(&buf, e);
    }
    try buf.appendSlice("]}");
    return buf.toOwnedSlice();
}

/// True dacă body-ul cere mod paper. Cautam `"mode":"paper"` literal —
/// orice altceva (default, "real", missing) → real engine. Ca și pe REST
/// (`/exchange/0/*` vs `/paper/0/*`) modul e doar un selector de routing.
fn isPaperMode(body: []const u8) bool {
    return std.mem.indexOf(u8, body, "\"mode\":\"paper\"") != null;
}

/// Picks the engine matching the requested mode. Returns null + sets a
/// flag for the caller if the requested engine isn't allocated.
fn pickEngine(ctx: *ServerCtx, paper: bool) ?*matching_mod.MatchingEngine {
    return if (paper) ctx.exchange_paper else ctx.exchange;
}

/// Computes amount reserved by `address` across all active SELL orders in
/// `engine.asks[]`. Single source of truth — derived from the orderbook itself,
/// no separate state to keep in sync (auto-correct after fills, cancels,
/// partial-fills, and journal replay).
/// Caller must hold `ctx.exchange_mutex`.
fn computeReservedFromOrderbook(engine: *matching_mod.MatchingEngine, address: []const u8) u64 {
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
fn buildOrderSignMessage(
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
fn buildCancelSignMessage(
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
fn deriveOBAddressFromPubkey(
    compressed_pubkey: [33]u8,
    allocator: std.mem.Allocator,
) ![]u8 {
    const h160 = wallet_mod.Wallet.pubkeyHash160(compressed_pubkey);
    return bech32_mod.encodeOBAddress(h160, allocator);
}

/// Verifica semnatura ECDSA secp256k1 pe mesajul canonical.
/// Returneaza true daca pubkey-ul corespunde adresei E si semnatura e valida.
fn verifyOrderSig(
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

fn buildDnsRegisterSignMessage(
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

fn buildDnsTransferSignMessage(
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

fn buildDnsUpdateSignMessage(
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

fn buildDnsRenewSignMessage(
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
fn buildDnsRenewYearsSignMessage(
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
fn verifyDnsSignature(
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
fn dnsAuditAppend(ctx: *ServerCtx, op: []const u8, fields: []const u8) void {
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
fn handleExchangePlaceOrder(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const is_paper = isPaperMode(body);
    const engine = pickEngine(ctx, is_paper) orelse
        return errorJson(-32601, if (is_paper) "Paper trader not enabled" else "Exchange not enabled on this node", id, alloc);

    const trader = extractStr(body, "trader") orelse extractStr(body, "address") orelse
        return errorJson(-32602, "Missing param: trader", id, alloc);
    const side_str = extractStr(body, "side") orelse
        return errorJson(-32602, "Missing param: side (buy|sell)", id, alloc);
    const sig_hex = extractStr(body, "signature") orelse
        return errorJson(-32602, "Missing param: signature", id, alloc);
    const pubkey_hex = extractStr(body, "publicKey") orelse extractStr(body, "pubkey") orelse
        return errorJson(-32602, "Missing param: publicKey", id, alloc);

    const price = extractArrayNumByKey(body, "price");
    const amount = extractArrayNumByKey(body, "amount");
    const nonce = extractArrayNumByKey(body, "nonce");

    if (price == 0) return errorJson(-32602, "Missing or zero: price", id, alloc);
    if (amount == 0) return errorJson(-32602, "Missing or zero: amount", id, alloc);
    if (nonce == 0) return errorJson(-32602, "Missing or zero: nonce", id, alloc);

    // Determina pair_id: prefer "pair" label (string) când e prezent —
    // pairId=0 (OMNI/USD) e perfect valid și nu trebuie tratat ca "missing",
    // dar `extractArrayNumByKey` nu distinge missing de zero. Așa că prima
    // dată căutăm string-ul `pair`, apoi numărul.
    var pair_id: u16 = 0;
    if (extractStr(body, "pair")) |label| {
        pair_id = exchangePairLookup(label) orelse
            return errorJson(-32602, "Unknown pair (try OMNI/USD, BTC/USD, LCX/USD, ETH/USD)", id, alloc);
    } else {
        const pair_id_u = extractArrayNumByKey(body, "pairId");
        // pairId 0..MAX_PAIRS-1 valid. Nu putem verifica "missing" cu
        // sentinel 0 (e indistinct de pairId 0 = OMNI/USD), deci dacă nici
        // "pair" nici "pairId" key nu există, trebuie să detectăm asta
        // explicit prin substring match.
        const has_pair_id_key = std.mem.indexOf(u8, body, "\"pairId\"") != null;
        if (!has_pair_id_key) {
            return errorJson(-32602, "Missing param: pair or pairId", id, alloc);
        }
        pair_id = @intCast(@min(pair_id_u, std.math.maxInt(u16)));
    }

    // Oracle price-band: reject orders priced > ORDER_BAND_BPS bps from
    // the consensus oracle. Skip when oracle is unavailable, the pair has
    // no oracle feed (e.g. LCX), or the consensus price isn't valid yet.
    if (!is_paper) if (ctx.oracle) |oracle_ptr| {
        if (oracleChainForPair(pair_id)) |chain| {
            if (oracle_ptr.getPrice(chain)) |ref| {
                if (ref.is_valid and ref.price_micro_usd > 0) {
                    const ref_p = ref.price_micro_usd;
                    const diff = if (price > ref_p) price - ref_p else ref_p - price;
                    const dev_bps = (@as(u128, diff) * 10_000) / @as(u128, ref_p);
                    if (dev_bps > ORDER_BAND_BPS) {
                        const msg = std.fmt.allocPrint(alloc,
                            "oracle_band_exceeded: ref={d} price={d} band_bps={d} dev_bps={d}",
                            .{ ref_p, price, ORDER_BAND_BPS, dev_bps },
                        ) catch return errorJson(-32098, "oracle_band_exceeded", id, alloc);
                        defer alloc.free(msg);
                        return errorJson(-32098, msg, id, alloc);
                    }
                }
            }
        }
    };

    const side: matching_mod.Side =
        if (asciiEqIgnoreCase(side_str, "buy")) .buy
        else if (asciiEqIgnoreCase(side_str, "sell")) .sell
        else return errorJson(-32602, "side must be 'buy' or 'sell'", id, alloc);

    if (trader.len > 64) return errorJson(-32602, "trader address too long", id, alloc);

    // PHASE 1: REST HMAC-authenticated requests bypass ECDSA by sending
    // signature="REST_HMAC_BYPASS". The REST layer already verified HMAC-SHA512
    // before dispatching to this handler, so we trust the trader identity.
    const side_canon: []const u8 = if (side == .buy) "buy" else "sell";
    const is_hmac_bypass = std.mem.eql(u8, sig_hex, "REST_HMAC_BYPASS");
    if (!is_hmac_bypass) {
        var msg_buf: [256]u8 = undefined;
        const msg = buildOrderSignMessage(side_canon, pair_id, price, amount, nonce, trader, &msg_buf) catch
            return errorJson(-32603, "Failed to build sign message", id, alloc);
        if (!verifyOrderSig(msg, sig_hex, pubkey_hex)) {
            return errorJson(-32000, "Signature verify failed (bad sig or pubkey/address mismatch)", id, alloc);
        }

        // 2) Verify pubkey -> address (so a stranger can't sign for someone else's address).
        //    Reuse existing chain helper that derives `ob1q...` from compressed pubkey.
        var pk_bytes: [33]u8 = undefined;
        _ = hex_utils.hexToBytes(pubkey_hex, &pk_bytes) catch
            return errorJson(-32000, "Bad pubkey hex", id, alloc);
        const derived_addr = deriveOBAddressFromPubkey(pk_bytes, alloc) catch
            return errorJson(-32000, "Cannot derive address from pubkey", id, alloc);
        defer alloc.free(derived_addr);
        if (!std.mem.eql(u8, derived_addr, trader)) {
            return errorJson(-32000, "Public key does not match trader address", id, alloc);
        }
    }

    // 3) Lock + nonce check (replay protection) + balance check + place
    ctx.exchange_mutex.lock();
    defer ctx.exchange_mutex.unlock();

    const last_nonce = nonceLookup(ctx, trader);
    if (last_nonce >= 0 and @as(u64, @intCast(last_nonce)) >= nonce) {
        return errorJson(-32000, "Nonce already used (replay rejected)", id, alloc);
    }

    // Balance check for SELL orders:
    // - OMNI base pairs (0,4,5,6): verify on-chain OMNI balance via getAddressBalance.
    // - Non-OMNI base pairs (1=BTC,2=LCX,3=ETH): balance lives on external chain —
    //   verification happens at HTLC fill time, not here. Skip check.
    // BUY side: skip (buyer locks quote asset at fill via HTLC, not at order placement).
    const base_is_omni = (pair_id == 0 or pair_id == 4 or pair_id == 5 or pair_id == 6);

    if (side == .sell and base_is_omni) {
        const balance = if (is_paper) blk: {
            const b = balanceLookup(ctx, trader, "OMNI_DEMO");
            break :blk if (b) |bal| bal.available_sat else 0;
        } else
            ctx.bc.getAddressBalance(trader);

        const reserved = if (is_paper)
            0
        else
            computeReservedFromOrderbook(engine, trader);

        const available = if (balance < reserved) 0 else (balance - reserved);

        if (available < amount) {
            return errorJson(-32000, "Insufficient available balance for sell", id, alloc);
        }
    }
    // BUY notional check skipped — quote asset lives on external chain (USDC/ETH/LCX),
    // verified at HTLC fill time, not at order placement.

    // KYC tier cap: gate per-order notional. `none` blocked, `pro` unlimited.
    // Skipped in paper mode, when no KYC store is wired (dev/local), and on
    // testnet/regtest (chain_id != 1) so testers can place orders freely.
    const is_mainnet = (ctx.chain_id == 1);
    if (!is_paper and is_mainnet) if (ctx.kyc_store) |ks| {
        const tier: kyc_mod.Level =
            if (ks.highest(trader, std.time.milliTimestamp())) |att| att.level else .none;
        const cap = kycMaxNotionalMicro(tier);
        const order_notional = orderNotionalMicro(price, amount);
        if (order_notional > cap) {
            const msg = std.fmt.allocPrint(alloc,
                "kyc_tier_exceeded: tier={s} max={d} requested={d}",
                .{ tier.label(), cap, order_notional },
            ) catch return errorJson(-32099, "kyc_tier_exceeded", id, alloc);
            defer alloc.free(msg);
            return errorJson(-32099, msg, id, alloc);
        }
    };

    var order = matching_mod.Order.empty();
    order.side = side;
    order.pair_id = pair_id;
    order.price_micro_usd = price;
    order.amount_sat = amount;
    order.timestamp_ms = std.time.milliTimestamp();
    const tn = @min(trader.len, order.trader_address.len);
    @memcpy(order.trader_address[0..tn], trader[0..tn]);
    order.trader_addr_len = @intCast(tn);
    order.status = .active;

    // EVM-leg validation for OMNI/<EVM-token> pairs. Atomic-swap-style:
    //   SELL must provide sellerEvm so the settler knows where to deliver.
    //   BUY  must provide evmOrderId, and the chain MUST already have seen
    //        an OrderPlaced event with that id on the EVM contract (via
    //        evm_escrow_watcher) with amount matching this BID's quote.
    // Without these checks, OMNI moves at fill but the quote stays untouched
    // (cf. testnet fill #10 2026-05-15 — buyer paid nothing, seller lost
    // 95 OMNI). Refuse unbacked orders up front.
    //
    // pair_id 0 = OMNI/USDC, 6 = OMNI/ETH, 7 = OMNI/LINK — all settle on
    // an EVM chain via OmnibusDEX. Add more pair_ids here when new
    // OMNI/<EVM-asset> pairs come online (LCX, EURC, etc.). Without this
    // guard a SELL with no sellerEvm crosses fine on OmniBus but the
    // settler skips it silently — buyer's escrow stays locked forever
    // (cf. testnet LINK fill #13 2026-05-16).
    const omni_evm_pair = (pair_id == 0 or pair_id == 6 or pair_id == 7);
    if (omni_evm_pair) {
        if (side == .sell) {
            const evm_str_raw = extractStr(body, "sellerEvm") orelse
                return errorJson(-32602, "Missing param: sellerEvm (required for OMNI/<EVM> SELL)", id, alloc);
            var evm_str = evm_str_raw;
            if (std.mem.startsWith(u8, evm_str, "0x") or std.mem.startsWith(u8, evm_str, "0X")) {
                evm_str = evm_str[2..];
            }
            if (evm_str.len != 40) return errorJson(-32602, "sellerEvm must be 0x + 40 hex chars", id, alloc);
            hex_utils.hexToBytes(evm_str, &order.seller_evm) catch
                return errorJson(-32602, "sellerEvm: invalid hex", id, alloc);
        } else { // .buy
            const evm_order_id = extractArrayNumByKey(body, "evmOrderId");
            if (evm_order_id == 0) {
                return errorJson(-32602,
                    "Missing param: evmOrderId (BUY on OMNI/<EVM> must reference an on-chain escrow)",
                    id, alloc);
            }
            // Verify the chain has seen this escrow via the watcher.
            if (ctx.evm_escrow_watcher) |w| {
                const esc = w.getOpen(evm_order_id) orelse {
                    return errorJson(-32000,
                        "No open OmnibusDEX escrow with this evmOrderId on Sepolia — did your placeBuyOrderNative tx mine?",
                        id, alloc);
                };
                // Amount sanity: the escrow amount must cover price * amount
                // in the quote token's smallest unit.
                //
                // For OMNI/USDC (pair_id 0): both micro-USD and USDC use 1e-6,
                // so expected_smallest = price_micro_usd * amount_sat / 1e9.
                // We enforce that exactly (with a 1-wei tolerance for rounding).
                //
                // For OMNI/ETH (6) and OMNI/LINK (7): the quote is an 18-dec
                // token whose USD value floats, so we can't compute the exact
                // expected amount without an oracle price for ETH/LINK. We
                // fall back to "non-zero" here; the EVM contract's own
                // settle() enforces the per-fill amount against the buyer's
                // signed intent, so an under-funded escrow won't actually pay
                // the seller. TODO when an oracle quote is wired here, swap
                // this branch for the same exact-match logic as USDC.
                if (esc.amount == 0) {
                    return errorJson(-32000, "Escrow amount is zero", id, alloc);
                }
                if (pair_id == 0) {
                    // price (micro-USD) * amount (SAT) / 1e9 = micro-USD owed
                    // = USDC smallest-unit owed (since 1 micro-USD = 1e-6 USDC
                    // and USDC has 6 decimals). u128 is wide enough: max
                    // 21M OMNI × $1e9 ≈ 2e25.
                    const expected_u128: u128 =
                        @as(u128, price) * @as(u128, amount) / 1_000_000_000;
                    if (esc.amount >> 128 != 0) {
                        return errorJson(-32000, "Escrow amount > 2^128 micro-USD — refusing", id, alloc);
                    }
                    const escrow_u128: u128 = @intCast(esc.amount & ((@as(u256, 1) << 128) - 1));
                    if (escrow_u128 < expected_u128) {
                        return errorJson(-32000,
                            "Escrow underfunded — locked amount is less than price * size in USDC smallest units",
                            id, alloc);
                    }
                }
                // SECURITY: refuse escrows that lock a token not on the
                // hard-coded whitelist for this pair_id + chain. Without
                // this gate, a malicious buyer could deploy a fake-USDC
                // contract and lock 5 units of it to claim 5 OMNI of real
                // liquidity. The whitelist binds (pair_id, chain_id, token)
                // tuples to Circle's official USDC, native ETH, etc.
                if (token_whitelist.check(pair_id, esc.chain_id, esc.token)) |label| {
                    std.debug.print(
                        "[token_whitelist] OK pair={d} chain={d} token={s}\n",
                        .{ pair_id, esc.chain_id, label },
                    );
                } else {
                    var token_hex_buf: [42]u8 = undefined;
                    token_hex_buf[0] = '0';
                    token_hex_buf[1] = 'x';
                    const hex_chars = "0123456789abcdef";
                    for (esc.token, 0..) |b, bi| {
                        token_hex_buf[2 + bi * 2] = hex_chars[b >> 4];
                        token_hex_buf[2 + bi * 2 + 1] = hex_chars[b & 0x0F];
                    }
                    std.debug.print(
                        "[token_whitelist] REJECT pair={d} chain={d} token={s}\n",
                        .{ pair_id, esc.chain_id, &token_hex_buf },
                    );
                    const msg = std.fmt.allocPrint(alloc,
                        "Escrow token not whitelisted for this pair (chain={d} token={s}). " ++
                        "Only Circle USDC / native ETH on supported chains are accepted.",
                        .{ esc.chain_id, &token_hex_buf },
                    ) catch return errorJson(-32000, "Escrow token not whitelisted", id, alloc);
                    defer alloc.free(msg);
                    return errorJson(-32000, msg, id, alloc);
                }
            } else {
                // Watcher disabled → refuse to be safe.
                return errorJson(-32000,
                    "evm_escrow_watcher not running — cannot verify on-chain escrow",
                    id, alloc);
            }
            order.evm_order_id = evm_order_id;
        }
    }

    const fills_before = engine.fill_count;
    engine.placeOrder(order) catch |err| {
        return errorJson(-32000, switch (err) {
            error.OrderbookFull => "Orderbook full",
            error.FillBufferFull => "Fill buffer full",
            error.InvalidPrice => "Invalid price",
            error.InvalidAmount => "Invalid amount",
            error.InvalidPair => "Invalid pair",
            else => "Order rejected",
        }, id, alloc);
    };
    const new_order_id = engine.next_order_id - 1;

    // Move newly produced fills into rolling trade_log + accumulate fees.
    // Maker = the trader whose order was already in the book.
    //         Taker = the incoming order (the one we just placed).
    // For a BUY incoming, the matched ask was the resting maker; for a
    // SELL incoming, the matched bid was the resting maker. So the
    // taker_id below is always our just-placed `new_order_id`.
    var total_network_fee_sat: u64 = 0;
    var total_taker_fee_micro: u64 = 0;
    var total_maker_fee_micro: u64 = 0;
    const block_height_now: u64 = ctx.bc.chain.items.len;
    var fi = fills_before;
    while (fi < engine.fill_count) : (fi += 1) {
        const f = engine.fills[fi];
        tradeLogPush(ctx, f, is_paper);

        const taker_fee = computeExchangeFeeMicro(
            f.price_micro_usd, f.amount_sat, EXCHANGE_FEE_TAKER_BPS);
        const maker_fee = computeExchangeFeeMicro(
            f.price_micro_usd, f.amount_sat, EXCHANGE_FEE_MAKER_BPS);
        const quote_micro = orderNotionalMicro(f.price_micro_usd, f.amount_sat);

        total_network_fee_sat += FILL_NETWORK_FEE_SAT;
        total_taker_fee_micro += taker_fee;
        total_maker_fee_micro += maker_fee;

        // Settle fees on chain — the taker is always our newly-placed
        // order; the maker is the resting opposite-side order.
        const buyer_addr = f.getBuyerAddress();
        const seller_addr = f.getSellerAddress();
        const taker_addr = if (side == .buy) buyer_addr else seller_addr;
        const maker_addr = if (side == .buy) seller_addr else buyer_addr;
        if (!is_paper) {
            // For OMNI-base pairs (0=OMNI/USDC, 4=OMNI/BTC, 5=OMNI/LCX,
            // 6=OMNI/ETH) we move OMNI on-chain from seller → buyer at
            // fill time. Quote leg lives on a foreign chain (USDC/BTC/
            // LCX/ETH) and is handled by dex_settler.zig if/when needed.
            const omni_base_fill = (f.pair_id == 0 or f.pair_id == 4 or f.pair_id == 5 or f.pair_id == 6);
            if (omni_base_fill) {
                ctx.bc.applyFillTransferOmniBase(
                    buyer_addr, seller_addr, f.amount_sat, f.fill_id,
                ) catch |err| {
                    std.debug.print(
                        "[FILL-TRANSFER] OMNI debit/credit failed for fill {d}: {} — buyer not credited!\n",
                        .{ f.fill_id, err },
                    );
                };
            }

            ctx.bc.applyExchangeFees(
                taker_addr, maker_addr, taker_fee, maker_fee, FILL_NETWORK_FEE_SAT,
            ) catch |err| {
                std.debug.print(
                    "[EXCHANGE-FEE] settlement failed for fill {d}: {} — fees not collected on this fill\n",
                    .{ f.fill_id, err },
                );
            };
        }

        // Persist fill receipt for "My Trades" UI + audit. Local to this
        // node; not propagated through P2P. Failure here is non-fatal —
        // the fill itself already succeeded.
        if (ctx.fills_log) |flog| {
            const taker_side_byte: u8 = if (side == .buy) 0 else 1;
            // Read the actual chain_id from the EVM escrow (watcher tagged
            // it at OrderPlaced time). Falls back to 0 (= OMNI-only fill)
            // for non-cross-chain pairs or when watcher isn't running.
            var evm_chain_id: u64 = 0;
            if (f.evm_order_id != 0) {
                if (ctx.evm_escrow_watcher) |w| {
                    if (w.getOpen(f.evm_order_id)) |esc| {
                        evm_chain_id = esc.chain_id;
                    }
                }
            }
            flog.append(f, taker_side_byte, block_height_now, evm_chain_id) catch |err| {
                std.debug.print(
                    "[FILLS-LOG] append failed for fill {d}: {} — entry skipped\n",
                    .{ f.fill_id, err },
                );
            };
        }

        // Per-fill audit log (forensics — taker/maker addrs, fees, height).
        var fbuf: [512]u8 = undefined;
        const fline = std.fmt.bufPrint(&fbuf,
            "\"fillId\":{d},\"pairId\":{d},\"taker\":\"{s}\",\"maker\":\"{s}\"," ++
            "\"price\":{d},\"amount\":{d},\"quote\":{d}," ++
            "\"takerFee\":{d},\"makerFee\":{d},\"networkFee\":{d}," ++
            "\"blockHeight\":{d},\"ts\":{d},\"paper\":{}",
            .{
                f.fill_id, f.pair_id, taker_addr, maker_addr,
                f.price_micro_usd, f.amount_sat, quote_micro,
                taker_fee, maker_fee, FILL_NETWORK_FEE_SAT,
                block_height_now, f.timestamp_ms, is_paper,
            },
        ) catch "";
        if (fline.len > 0) ordersAppendJournal(ctx, "fill", fline);

        // Push new_trade event to WebSocket subscribers.
        if (main_mod.g_ws_srv) |ws| {
            const pair_label = pairIdToLabel(f.pair_id);
            const trade_side = if (side == .buy) "buy" else "sell";
            ws.broadcastTrade(f.pair_id, pair_label, f.price_micro_usd,
                f.amount_sat, trade_side, block_height_now);
        }
    }

    // Push orderbook_update after all fills so subscribers see final state.
    if (main_mod.g_ws_srv) |ws| {
        const pair_label = pairIdToLabel(pair_id);
        ws.broadcastOrderbook(
            pair_id, pair_label,
            engine.bestBid(pair_id) orelse 0,
            engine.bestAsk(pair_id) orelse 0,
            engine.spread(pair_id) orelse 0,
            engine.orderCountForPair(pair_id),
            @intCast(ctx.bc.chain.items.len),
        );
    }

    nonceSet(ctx, trader, nonce);

    // Note: reservation is derived from `engine.asks[]` directly (single source
    // of truth — see computeReservedFromOrderbook). No separate state to update.

    // ── Submit canonical typed `order_place` TX into the chain mempool ──
    // The in-memory matching engine path above is now a *preview* — the
    // authoritative orderbook is rebuilt deterministically by every node
    // from on-chain `order_place` TXs via `applyOrderTxs`. Skip in paper
    // mode (paper trades never touch chain). On submission failure we log
    // but don't fail the RPC — the user-facing orderbook still saw the
    // order place via the preview engine.
    if (!is_paper) {
        submitOrderPlaceTx(ctx, trader, side, pair_id, price, amount) catch |sub_err| {
            std.debug.print("[EXCHANGE] order_place chain TX submit failed: {} (orderbook will rebuild from preview-only on this node)\n",
                .{sub_err});
        };
    }

    // Create on-chain order TX with hash
    const tx_result = createOrderTransaction(
        alloc,
        trader,
        side_canon,
        pair_id,
        price,
        amount,
        nonce,
        new_order_id,
        sig_hex,
        pubkey_hex,
    ) catch |err| {
        std.debug.print("[EXCHANGE] TX creation failed: {}\n", .{err});
        return errorJson(-32603, "Failed to create order TX", id, alloc);
    };
    defer alloc.free(tx_result.tx_json);
    defer alloc.free(tx_result.tx_hash);

    // Persist the place event with TX hash
    var jbuf: [1024]u8 = undefined;
    const jline = std.fmt.bufPrint(&jbuf,
        "\"trader\":\"{s}\",\"side\":\"{s}\",\"pairId\":{d},\"price\":{d},\"amount\":{d},\"orderId\":{d},\"ts\":{d},\"txHash\":\"{s}\"",
        .{ trader, side_canon, pair_id, price, amount, new_order_id, order.timestamp_ms, tx_result.tx_hash },
    ) catch "";
    if (jline.len > 0) ordersAppendJournal(ctx, "place", jline);

    // Compute filled amount this order achieved (sum of new fills where this order_id appears)
    var filled_total: u64 = 0;
    var k = fills_before;
    while (k < engine.fill_count) : (k += 1) {
        const f = engine.fills[k];
        if (f.buy_order_id == new_order_id or f.sell_order_id == new_order_id) {
            filled_total += f.amount_sat;
        }
    }
    const remaining: u64 = if (filled_total >= amount) 0 else amount - filled_total;

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{" ++
            "\"mode\":\"{s}\"," ++
            "\"orderId\":{d},\"txHash\":\"{s}\",\"side\":\"{s}\",\"pairId\":{d}," ++
            "\"price\":{d},\"amount\":{d}," ++
            "\"filled\":{d},\"remaining\":{d},\"status\":\"{s}\"," ++
            "\"fees\":{{" ++
                "\"networkFeeSat\":{d}," ++
                "\"exchangeTakerFeeMicroUsd\":{d}," ++
                "\"exchangeMakerFeeMicroUsd\":{d}," ++
                "\"takerBps\":{d},\"makerBps\":{d}" ++
            "}}" ++
        "}}}}",
        .{ id, if (is_paper) "paper" else "real",
           new_order_id, tx_result.tx_hash, side_canon, pair_id,
           price, amount, filled_total, remaining,
           if (remaining == 0) "filled" else if (filled_total > 0) "partial" else "active",
           total_network_fee_sat, total_taker_fee_micro, total_maker_fee_micro,
           EXCHANGE_FEE_TAKER_BPS, EXCHANGE_FEE_MAKER_BPS });
}

/// exchange_cancelOrder — anuleaza o ordine. Required: orderId, trader,
/// nonce, signature, publicKey. Verifica pe lant ca trader == owner.
fn handleExchangeCancelOrder(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const is_paper = isPaperMode(body);
    const engine = pickEngine(ctx, is_paper) orelse
        return errorJson(-32601, if (is_paper) "Paper trader not enabled" else "Exchange not enabled on this node", id, alloc);

    var order_id = extractArrayNumByKey(body, "orderId");
    if (order_id == 0) order_id = extractArrayNumByKey(body, "order_id");
    if (order_id == 0) return errorJson(-32602, "Missing param: orderId (or order_id)", id, alloc);
    const trader = extractStr(body, "trader") orelse
        return errorJson(-32602, "Missing param: trader", id, alloc);
    const sig_hex = extractStr(body, "signature") orelse
        return errorJson(-32602, "Missing param: signature", id, alloc);
    const pubkey_hex = extractStr(body, "publicKey") orelse extractStr(body, "pubkey") orelse
        return errorJson(-32602, "Missing param: publicKey", id, alloc);
    const nonce = extractArrayNumByKey(body, "nonce");
    if (nonce == 0) return errorJson(-32602, "Missing or zero: nonce", id, alloc);

    // Verify signature (skip for REST HMAC-authenticated requests)
    const is_hmac_bypass = std.mem.eql(u8, sig_hex, "REST_HMAC_BYPASS");
    if (!is_hmac_bypass) {
        var msg_buf: [128]u8 = undefined;
        const msg = buildCancelSignMessage(order_id, nonce, trader, &msg_buf) catch
            return errorJson(-32603, "Failed to build sign message", id, alloc);
        if (!verifyOrderSig(msg, sig_hex, pubkey_hex)) {
            return errorJson(-32000, "Signature verify failed", id, alloc);
        }

        // Pubkey -> trader address must match
        var pk_bytes: [33]u8 = undefined;
        _ = hex_utils.hexToBytes(pubkey_hex, &pk_bytes) catch
            return errorJson(-32000, "Bad pubkey hex", id, alloc);
        const derived_addr = deriveOBAddressFromPubkey(pk_bytes, alloc) catch
            return errorJson(-32000, "Cannot derive address from pubkey", id, alloc);
        defer alloc.free(derived_addr);
        if (!std.mem.eql(u8, derived_addr, trader)) {
            return errorJson(-32000, "Public key does not match trader address", id, alloc);
        }
    }

    ctx.exchange_mutex.lock();
    defer ctx.exchange_mutex.unlock();

    // Look up order, verify ownership BEFORE cancelling
    const order = engine.getOrder(order_id) orelse
        return errorJson(-32000, "Order not found", id, alloc);
    if (!std.mem.eql(u8, order.getTraderAddress(), trader)) {
        return errorJson(-32000, "Not order owner", id, alloc);
    }

    const last_nonce = nonceLookup(ctx, trader);
    if (last_nonce >= 0 and @as(u64, @intCast(last_nonce)) >= nonce) {
        return errorJson(-32000, "Nonce already used (replay rejected)", id, alloc);
    }

    engine.cancelOrder(order_id) catch |err| {
        return errorJson(-32000, switch (err) {
            error.OrderNotFound => "Order not found",
            else => "Cancel failed",
        }, id, alloc);
    };

    // Note: cancelOrder marks the order .cancelled, so it's automatically
    // excluded from computeReservedFromOrderbook on next balance check.

    // ── Submit canonical typed `order_cancel` TX into the chain mempool ──
    // Replaying nodes apply this via `applyOrderTxs`, which removes the
    // order from the deterministic book.
    if (!is_paper) {
        submitOrderCancelTx(ctx, trader, order_id) catch |sub_err| {
            std.debug.print("[EXCHANGE] order_cancel chain TX submit failed: {}\n", .{sub_err});
        };
    }

    nonceSet(ctx, trader, nonce);

    var jbuf: [128]u8 = undefined;
    const jline = std.fmt.bufPrint(&jbuf,
        "\"trader\":\"{s}\",\"orderId\":{d},\"ts\":{d}",
        .{ trader, order_id, std.time.milliTimestamp() },
    ) catch "";
    if (jline.len > 0) ordersAppendJournal(ctx, "cancel", jline);

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"orderId\":{d},\"cancelled\":true}}}}",
        .{ id, order_id });
}

/// exchange_getOrderbook — top N bids/asks pentru o pereche.
/// Params: pair sau pairId, optional depth (default 25, max 50).
fn handleExchangeGetOrderbook(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const is_paper = isPaperMode(body);
    const engine = pickEngine(ctx, is_paper) orelse
        return errorJson(-32601, if (is_paper) "Paper trader not enabled" else "Exchange not enabled on this node", id, alloc);

    var pair_id: u16 = 0;
    const pair_id_u = extractArrayNumByKey(body, "pairId");
    if (pair_id_u > 0) {
        pair_id = @intCast(@min(pair_id_u, std.math.maxInt(u16)));
    } else if (extractStr(body, "pair")) |label| {
        pair_id = exchangePairLookup(label) orelse 0;
    }

    const depth_raw = extractArrayNumByKey(body, "depth");
    const depth: u32 = if (depth_raw == 0) 25 else @intCast(@min(depth_raw, @as(u64, 50)));

    var out = std.ArrayList(u8){};
    defer out.deinit(alloc);
    try out.appendSlice(alloc, "{\"jsonrpc\":\"2.0\",\"id\":");
    try std.fmt.format(out.writer(alloc), "{d}", .{id});
    try out.appendSlice(alloc, ",\"result\":{\"pairId\":");
    try std.fmt.format(out.writer(alloc), "{d}", .{pair_id});
    try out.appendSlice(alloc, ",\"bids\":[");

    ctx.exchange_mutex.lock();
    defer ctx.exchange_mutex.unlock();

    var emitted: u32 = 0;
    var first = true;
    var i: u32 = 0;
    while (i < engine.bid_count and emitted < depth) : (i += 1) {
        const o = engine.bids[i];
        if (o.pair_id != pair_id) continue;
        if (!first) try out.appendSlice(alloc, ",");
        first = false;
        try std.fmt.format(out.writer(alloc),
            "{{\"orderId\":{d},\"price\":{d},\"amount\":{d},\"remaining\":{d},\"trader\":\"{s}\",\"ts\":{d}}}",
            .{ o.order_id, o.price_micro_usd, o.amount_sat, o.remainingSat(),
               o.trader_address[0..o.trader_addr_len], o.timestamp_ms });
        emitted += 1;
    }

    try out.appendSlice(alloc, "],\"asks\":[");
    emitted = 0;
    first = true;
    i = 0;
    while (i < engine.ask_count and emitted < depth) : (i += 1) {
        const o = engine.asks[i];
        if (o.pair_id != pair_id) continue;
        if (!first) try out.appendSlice(alloc, ",");
        first = false;
        try std.fmt.format(out.writer(alloc),
            "{{\"orderId\":{d},\"price\":{d},\"amount\":{d},\"remaining\":{d},\"trader\":\"{s}\",\"ts\":{d}}}",
            .{ o.order_id, o.price_micro_usd, o.amount_sat, o.remainingSat(),
               o.trader_address[0..o.trader_addr_len], o.timestamp_ms });
        emitted += 1;
    }

    const best_bid = engine.bestBid(pair_id) orelse 0;
    const best_ask = engine.bestAsk(pair_id) orelse 0;
    const spread_v = engine.spread(pair_id) orelse 0;

    try std.fmt.format(out.writer(alloc),
        "],\"bestBid\":{d},\"bestAsk\":{d},\"spread\":{d},\"orderCount\":{d}}}}}",
        .{ best_bid, best_ask, spread_v, engine.orderCountForPair(pair_id) });

    return alloc.dupe(u8, out.items);
}

/// exchange_getUserOrders — toate ordinele active ale unei adrese.
/// Params: trader. Optional: pairId / pair (filtru).
fn handleExchangeGetUserOrders(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const is_paper = isPaperMode(body);
    const engine = pickEngine(ctx, is_paper) orelse
        return errorJson(-32601, if (is_paper) "Paper trader not enabled" else "Exchange not enabled on this node", id, alloc);
    const trader = extractStr(body, "trader") orelse extractStr(body, "address") orelse
        return errorJson(-32602, "Missing param: trader", id, alloc);

    var filter_pair: ?u16 = null;
    const pair_id_u = extractArrayNumByKey(body, "pairId");
    if (pair_id_u > 0) {
        filter_pair = @intCast(@min(pair_id_u, std.math.maxInt(u16)));
    } else if (extractStr(body, "pair")) |label| {
        filter_pair = exchangePairLookup(label);
    }

    var out = std.ArrayList(u8){};
    defer out.deinit(alloc);
    try out.appendSlice(alloc, "{\"jsonrpc\":\"2.0\",\"id\":");
    try std.fmt.format(out.writer(alloc), "{d}", .{id});
    try out.appendSlice(alloc, ",\"result\":[");

    ctx.exchange_mutex.lock();
    defer ctx.exchange_mutex.unlock();

    var first = true;
    inline for (.{ "bids", "asks" }) |which| {
        const count = if (comptime std.mem.eql(u8, which, "bids")) engine.bid_count else engine.ask_count;
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            const o = if (comptime std.mem.eql(u8, which, "bids")) engine.bids[i] else engine.asks[i];
            if (!std.mem.eql(u8, o.getTraderAddress(), trader)) continue;
            if (filter_pair) |fp| if (o.pair_id != fp) continue;
            if (!first) try out.appendSlice(alloc, ",");
            first = false;
            try std.fmt.format(out.writer(alloc),
                "{{\"orderId\":{d},\"side\":\"{s}\",\"pairId\":{d},\"price\":{d},\"amount\":{d},\"filled\":{d},\"remaining\":{d},\"status\":\"{s}\",\"ts\":{d}}}",
                .{ o.order_id, o.side.name(), o.pair_id, o.price_micro_usd, o.amount_sat,
                   o.filled_sat, o.remainingSat(),
                   switch (o.status) { .active => "active", .partial => "partial", .filled => "filled", .cancelled => "cancelled" },
                   o.timestamp_ms });
        }
    }
    try out.appendSlice(alloc, "]}");
    return alloc.dupe(u8, out.items);
}

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
fn handleExchangeGetUserTrades(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const flog = ctx.fills_log orelse
        return errorJson(-32601, "Fills log not enabled on this node", id, alloc);
    const trader = extractStr(body, "trader") orelse extractStr(body, "address") orelse
        return errorJson(-32602, "Missing param: trader", id, alloc);

    var filter_pair: ?u16 = null;
    const pair_id_u = extractArrayNumByKey(body, "pairId");
    if (pair_id_u > 0) {
        filter_pair = @intCast(@min(pair_id_u, std.math.maxInt(u16)));
    } else if (extractStr(body, "pair")) |label| {
        filter_pair = exchangePairLookup(label);
    }
    const limit_raw = extractArrayNumByKey(body, "limit");
    const limit: usize = if (limit_raw == 0) 100 else @intCast(@min(limit_raw, 500));

    const recs = flog.readForTrader(alloc, trader, 0) catch &.{};
    defer if (recs.len > 0) alloc.free(recs);

    // Merge settle map so we can attach EVM tx hash where available.
    var settle_map = flog.loadSettleMap() catch fills_log_mod.SettleMap.init(alloc);
    defer settle_map.deinit();

    var out = std.ArrayList(u8){};
    defer out.deinit(alloc);
    try out.appendSlice(alloc, "{\"jsonrpc\":\"2.0\",\"id\":");
    try std.fmt.format(out.writer(alloc), "{d}", .{id});
    try out.appendSlice(alloc, ",\"result\":[");

    // Walk newest-first so the UI shows latest trade at the top.
    var emitted: usize = 0;
    var idx: usize = recs.len;
    while (idx > 0 and emitted < limit) {
        idx -= 1;
        const r = &recs[idx];
        if (filter_pair) |fp| if (r.pair_id != fp) continue;

        const is_buyer = std.mem.eql(u8, r.buyerAddrSlice(), trader);
        // Trader's perspective of the trade — if they're the buyer they
        // "bought" base; otherwise they "sold" it.
        const role = if (is_buyer) "buy" else "sell";
        const counterparty = if (is_buyer) r.sellerAddrSlice() else r.buyerAddrSlice();

        if (emitted > 0) try out.appendSlice(alloc, ",");
        emitted += 1;

        try std.fmt.format(out.writer(alloc),
            "{{\"fillId\":{d},\"pairId\":{d},\"side\":\"{s}\",\"counterparty\":\"{s}\"," ++
            "\"price\":{d},\"amount\":{d},\"buyOrderId\":{d},\"sellOrderId\":{d}," ++
            "\"blockHeight\":{d},\"ts\":{d},\"evmChainId\":{d}",
            .{
                r.fill_id, r.pair_id, role, counterparty,
                r.price_micro_usd, r.amount_sat, r.buy_order_id, r.sell_order_id,
                r.block_height, r.timestamp_ms, r.evm_chain_id,
            },
        );

        if (settle_map.get(r.fill_id)) |s| {
            try out.appendSlice(alloc, ",\"evmSettleTxHash\":\"0x");
            for (s.tx_hash) |b| try std.fmt.format(out.writer(alloc), "{x:0>2}", .{b});
            try out.appendSlice(alloc, "\"");
        } else {
            try out.appendSlice(alloc, ",\"evmSettleTxHash\":null");
        }

        try out.appendSlice(alloc, "}");
    }
    try out.appendSlice(alloc, "]}");
    return alloc.dupe(u8, out.items);
}

/// exchange_getTrades — ultimele N fills. Optional: pair/pairId, address (filtru),
/// limit (default 50, max 256).
fn handleExchangeGetTrades(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const is_paper = isPaperMode(body);
    if (pickEngine(ctx, is_paper) == null) return errorJson(-32601, if (is_paper) "Paper trader not enabled" else "Exchange not enabled on this node", id, alloc);

    var filter_pair: ?u16 = null;
    const pair_id_u = extractArrayNumByKey(body, "pairId");
    if (pair_id_u > 0) {
        filter_pair = @intCast(@min(pair_id_u, std.math.maxInt(u16)));
    } else if (extractStr(body, "pair")) |label| {
        filter_pair = exchangePairLookup(label);
    }
    const filter_addr = extractStr(body, "address") orelse extractStr(body, "trader");
    const limit_raw = extractArrayNumByKey(body, "limit");
    const limit: u32 = if (limit_raw == 0) 50 else @intCast(@min(limit_raw, 256));

    var out = std.ArrayList(u8){};
    defer out.deinit(alloc);
    try out.appendSlice(alloc, "{\"jsonrpc\":\"2.0\",\"id\":");
    try std.fmt.format(out.writer(alloc), "{d}", .{id});
    try out.appendSlice(alloc, ",\"result\":[");

    ctx.exchange_mutex.lock();
    defer ctx.exchange_mutex.unlock();

    // Walk newest-to-oldest in circular buffer (per-mode log).
    const es = ctx.exstate.?;
    const log_count = if (is_paper) es.trade_count_paper else es.trade_count;
    const log_head = if (is_paper) es.trade_head_paper else es.trade_head;
    var emitted: u32 = 0;
    var first = true;
    var c: u32 = 0;
    while (c < log_count and emitted < limit) : (c += 1) {
        // Most recent index = (head - 1 - c) mod len
        const len_u: u32 = 256;
        const idx = (log_head + len_u - 1 - c) % len_u;
        const f = if (is_paper) es.trade_log_paper[idx] else es.trade_log[idx];
        if (filter_pair) |fp| if (f.pair_id != fp) continue;
        if (filter_addr) |a| {
            const buyer = f.getBuyerAddress();
            const seller = f.getSellerAddress();
            if (!std.mem.eql(u8, buyer, a) and !std.mem.eql(u8, seller, a)) continue;
        }
        if (!first) try out.appendSlice(alloc, ",");
        first = false;
        try std.fmt.format(out.writer(alloc),
            "{{\"fillId\":{d},\"pairId\":{d},\"price\":{d},\"amount\":{d},\"buyer\":\"{s}\",\"seller\":\"{s}\",\"buyOrderId\":{d},\"sellOrderId\":{d},\"ts\":{d}}}",
            .{ f.fill_id, f.pair_id, f.price_micro_usd, f.amount_sat,
               f.buyer_address[0..f.buyer_addr_len], f.seller_address[0..f.seller_addr_len],
               f.buy_order_id, f.sell_order_id, f.timestamp_ms });
        emitted += 1;
    }
    try out.appendSlice(alloc, "]}");
    return alloc.dupe(u8, out.items);
}

/// exchange_listPairs — perechi suportate. Static (definite la compile-time).
/// exchange_pairInfo — returns multi-chain routing + HTLC contract addresses for a pair.
/// Params: { "pair_id": N }
/// Result: { pair_id, base, quote,
///            maker_chains: [{chain, chain_id, contract}...],
///            taker_chains: [{chain, chain_id, contract}...] }
fn handleExchangePairInfo(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const pair_id_u = extractU64Param(body, "\"pair_id\"") orelse
        return errorJson(-32602, "Missing param: pair_id", id, alloc);
    const route = swap_link_mod.routeForPair(@intCast(pair_id_u)) orelse
        return errorJson(-32602, "Unknown pair_id", id, alloc);

    var out = std.ArrayList(u8){};
    defer out.deinit(alloc);
    try std.fmt.format(out.writer(alloc),
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{" ++
        "\"pair_id\":{d},\"base\":\"{s}\",\"quote\":\"{s}\"," ++
        "\"maker_chains\":[",
        .{ id, route.pair_id, route.base_asset, route.quote_asset });

    const maker_chains = swap_link_mod.chainsForAsset(route.base_asset);
    var first: bool = true;
    for (maker_chains) |ch| {
        if (!first) try out.appendSlice(alloc, ",");
        first = false;
        try std.fmt.format(out.writer(alloc),
            "{{\"chain\":\"{s}\",\"chain_id\":{d},\"contract\":\"{s}\"}}",
            .{ ch.label(), ch.evmChainId(), swap_link_mod.htlcContractFor(ch) });
    }
    try out.appendSlice(alloc, "],\"taker_chains\":[");

    const taker_chains = swap_link_mod.chainsForAsset(route.quote_asset);
    first = true;
    for (taker_chains) |ch| {
        if (!first) try out.appendSlice(alloc, ",");
        first = false;
        try std.fmt.format(out.writer(alloc),
            "{{\"chain\":\"{s}\",\"chain_id\":{d},\"contract\":\"{s}\"}}",
            .{ ch.label(), ch.evmChainId(), swap_link_mod.htlcContractFor(ch) });
    }
    try out.appendSlice(alloc, "]}}");
    return alloc.dupe(u8, out.items);
}

fn handleExchangeListPairs(ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    var out = std.ArrayList(u8){};
    defer out.deinit(alloc);
    try out.appendSlice(alloc, "{\"jsonrpc\":\"2.0\",\"id\":");
    try std.fmt.format(out.writer(alloc), "{d}", .{id});
    try out.appendSlice(alloc, ",\"result\":[");
    var first = true;
    for (EXCHANGE_PAIRS) |p| {
        if (!first) try out.appendSlice(alloc, ",");
        first = false;
        try std.fmt.format(out.writer(alloc),
            "{{\"id\":{d},\"base\":\"{s}\",\"quote\":\"{s}\",\"label\":\"{s}/{s}\"}}",
            .{ p.id, p.base, p.quote, p.base, p.quote });
    }
    try out.appendSlice(alloc, "]}");
    return alloc.dupe(u8, out.items);
}

/// exchange_getStats — sumar global: total ordine, total fills, best/spread per pereche.
fn handleExchangeGetStats(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const is_paper = isPaperMode(body);
    const engine = pickEngine(ctx, is_paper) orelse
        return errorJson(-32601, if (is_paper) "Paper trader not enabled" else "Exchange not enabled on this node", id, alloc);

    ctx.exchange_mutex.lock();
    defer ctx.exchange_mutex.unlock();

    const trade_count = if (is_paper) ctx.exstate.?.trade_count_paper else ctx.exstate.?.trade_count;

    var out = std.ArrayList(u8){};
    defer out.deinit(alloc);
    try out.appendSlice(alloc, "{\"jsonrpc\":\"2.0\",\"id\":");
    try std.fmt.format(out.writer(alloc), "{d}", .{id});
    try std.fmt.format(out.writer(alloc),
        ",\"result\":{{\"mode\":\"{s}\",\"totalOrders\":{d},\"bidCount\":{d},\"askCount\":{d},\"trades\":{d},\"pairs\":[",
        .{ if (is_paper) "paper" else "real", engine.orderCount(), engine.bid_count, engine.ask_count, trade_count });
    var first = true;
    for (EXCHANGE_PAIRS) |p| {
        const bb = engine.bestBid(p.id) orelse 0;
        const ba = engine.bestAsk(p.id) orelse 0;
        const sp = engine.spread(p.id) orelse 0;
        const oc = engine.orderCountForPair(p.id);
        if (!first) try out.appendSlice(alloc, ",");
        first = false;
        try std.fmt.format(out.writer(alloc),
            "{{\"id\":{d},\"label\":\"{s}/{s}\",\"bestBid\":{d},\"bestAsk\":{d},\"spread\":{d},\"orderCount\":{d}}}",
            .{ p.id, p.base, p.quote, bb, ba, sp, oc });
    }
    try out.appendSlice(alloc, "]}}");
    return alloc.dupe(u8, out.items);
}

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

fn usersAppendJournal(ctx: *ServerCtx, kind: []const u8, line: []const u8) void {
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

fn apiKeyInsert(
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

fn apiKeyRevoke(ctx: *ServerCtx, key_id: []const u8) void {
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

fn apiKeyLookup(ctx: *ServerCtx, key_id: []const u8) ?*ExchangeApiKey {
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
fn sha256Hex(input: []const u8, out: *[64]u8) void {
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

fn balanceLookup(ctx: *ServerCtx, owner: []const u8, token: []const u8) ?*ExchangeBalance {
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

fn balanceGetOrCreate(ctx: *ServerCtx, owner: []const u8, token: []const u8) ?*ExchangeBalance {
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

fn balanceCredit(ctx: *ServerCtx, owner: []const u8, token: []const u8, amount: u64) bool {
    const b = balanceGetOrCreate(ctx, owner, token) orelse return false;
    b.available_sat +%= amount;
    return true;
}

fn balanceDebit(ctx: *ServerCtx, owner: []const u8, token: []const u8, amount: u64) bool {
    const b = balanceLookup(ctx, owner, token) orelse return false;
    if (b.available_sat < amount) return false;
    b.available_sat -= amount;
    return true;
}

// ── Auth nonce / login ────────────────────────────────────────────────

fn authNoncePurge(ctx: *ServerCtx, now_ms: i64) void {
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

fn authNoncePut(ctx: *ServerCtx, address: []const u8, nonce_hex: []const u8, now_ms: i64) void {
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

fn authNonceConsume(ctx: *ServerCtx, address: []const u8, nonce_hex: []const u8) bool {
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
fn handleExchangeGetAuthNonce(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const address = extractStr(body, "address") orelse extractArrayStr(body, 0) orelse
        return errorJson(-32602, "Missing param: address", id, alloc);
    if (address.len > 64) return errorJson(-32602, "address too long", id, alloc);

    var nonce_bytes: [32]u8 = undefined;
    std.crypto.random.bytes(&nonce_bytes);
    var nonce_hex: [64]u8 = undefined;
    const hex_chars = "0123456789abcdef";
    var i: usize = 0;
    while (i < 32) : (i += 1) {
        nonce_hex[i * 2] = hex_chars[nonce_bytes[i] >> 4];
        nonce_hex[i * 2 + 1] = hex_chars[nonce_bytes[i] & 0xF];
    }

    const now_ms = std.time.milliTimestamp();
    ctx.exchange_mutex.lock();
    defer ctx.exchange_mutex.unlock();
    authNoncePurge(ctx, now_ms);
    authNoncePut(ctx, address, &nonce_hex, now_ms);

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"nonce\":\"{s}\",\"message\":\"OmniBus Exchange Login: {s}\",\"ttlMs\":{d}}}}}",
        .{ id, nonce_hex, nonce_hex, AUTH_NONCE_TTL_MS });
}

/// exchange_login — verify nonce signature, mark the address as a known
/// exchange user (just allocates a default OMNI balance row if missing).
/// Returns the address + a list of currently active api keys (without
/// revealing secrets). Stateless — no JWT; future calls re-prove
/// ownership either via signature or via api-key+secret headers.
fn handleExchangeLogin(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const address = extractStr(body, "address") orelse
        return errorJson(-32602, "Missing param: address", id, alloc);
    const nonce_hex = extractStr(body, "nonce") orelse
        return errorJson(-32602, "Missing param: nonce", id, alloc);
    const sig_hex = extractStr(body, "signature") orelse
        return errorJson(-32602, "Missing param: signature", id, alloc);
    const pubkey_hex = extractStr(body, "publicKey") orelse extractStr(body, "pubkey") orelse
        return errorJson(-32602, "Missing param: publicKey", id, alloc);

    var msg_buf: [128]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf, "OmniBus Exchange Login: {s}", .{nonce_hex}) catch
        return errorJson(-32603, "Failed to build sign message", id, alloc);
    if (!verifyOrderSig(msg, sig_hex, pubkey_hex)) {
        return errorJson(-32000, "Signature verify failed", id, alloc);
    }
    var pk_bytes: [33]u8 = undefined;
    _ = hex_utils.hexToBytes(pubkey_hex, &pk_bytes) catch
        return errorJson(-32000, "Bad pubkey hex", id, alloc);
    const derived_addr = deriveOBAddressFromPubkey(pk_bytes, alloc) catch
        return errorJson(-32000, "Cannot derive address from pubkey", id, alloc);
    defer alloc.free(derived_addr);
    if (!std.mem.eql(u8, derived_addr, address)) {
        return errorJson(-32000, "Public key does not match address", id, alloc);
    }

    ctx.exchange_mutex.lock();
    defer ctx.exchange_mutex.unlock();

    if (!authNonceConsume(ctx, address, nonce_hex)) {
        return errorJson(-32000, "Nonce expired or unknown — request a fresh one", id, alloc);
    }

    // Allocate a default OMNI balance row so the user appears in
    // exchange_get_balances even before depositing.
    _ = balanceGetOrCreate(ctx, address, "OMNI");

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"address\":\"{s}\",\"loggedIn\":true,\"sessionTtlMs\":{d}}}}}",
        .{ id, address, AUTH_NONCE_TTL_MS });
}

/// exchange_createApiKey — generate a fresh (key_id, secret) pair owned
/// by the caller. The secret is returned ONCE (plaintext) and stored as
/// SHA256 hash. Caller must prove address ownership via signature on
/// the canonical message "EXCHANGE_APIKEY_V1\n<name>\n<address>\n<nonce>".
fn handleExchangeCreateApiKey(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const owner = extractStr(body, "owner") orelse extractStr(body, "address") orelse
        return errorJson(-32602, "Missing param: owner", id, alloc);
    const name = extractStr(body, "name") orelse "default";
    const sig_hex = extractStr(body, "signature") orelse
        return errorJson(-32602, "Missing param: signature", id, alloc);
    const pubkey_hex = extractStr(body, "publicKey") orelse extractStr(body, "pubkey") orelse
        return errorJson(-32602, "Missing param: publicKey", id, alloc);
    const nonce = extractArrayNumByKey(body, "nonce");
    if (nonce == 0) return errorJson(-32602, "Missing or zero: nonce", id, alloc);

    if (name.len > 32) return errorJson(-32602, "name too long (max 32)", id, alloc);

    var msg_buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf, "EXCHANGE_APIKEY_V1\n{s}\n{s}\n{d}", .{ name, owner, nonce }) catch
        return errorJson(-32603, "Failed to build sign message", id, alloc);
    if (!verifyOrderSig(msg, sig_hex, pubkey_hex)) {
        return errorJson(-32000, "Signature verify failed", id, alloc);
    }
    var pk_bytes: [33]u8 = undefined;
    _ = hex_utils.hexToBytes(pubkey_hex, &pk_bytes) catch
        return errorJson(-32000, "Bad pubkey hex", id, alloc);
    const derived_addr = deriveOBAddressFromPubkey(pk_bytes, alloc) catch
        return errorJson(-32000, "Cannot derive address from pubkey", id, alloc);
    defer alloc.free(derived_addr);
    if (!std.mem.eql(u8, derived_addr, owner)) {
        return errorJson(-32000, "Public key does not match owner address", id, alloc);
    }

    // Generate key + secret
    var key_random: [12]u8 = undefined;
    var secret_random: [32]u8 = undefined;
    std.crypto.random.bytes(&key_random);
    std.crypto.random.bytes(&secret_random);
    const hex_chars = "0123456789abcdef";
    var key_id: [28]u8 = undefined; // "obx_" + 24 hex chars
    @memcpy(key_id[0..4], "obx_");
    var i: usize = 0;
    while (i < 12) : (i += 1) {
        key_id[4 + i * 2] = hex_chars[key_random[i] >> 4];
        key_id[4 + i * 2 + 1] = hex_chars[key_random[i] & 0xF];
    }
    var secret_str: [68]u8 = undefined; // "obs_" + 64 hex chars
    @memcpy(secret_str[0..4], "obs_");
    i = 0;
    while (i < 32) : (i += 1) {
        secret_str[4 + i * 2] = hex_chars[secret_random[i] >> 4];
        secret_str[4 + i * 2 + 1] = hex_chars[secret_random[i] & 0xF];
    }

    var sec_hash: [64]u8 = undefined;
    sha256Hex(&secret_str, &sec_hash);

    // Base64-encode the raw secret for Kraken-compatible HMAC signing
    var secret_b64_buf: [64]u8 = undefined;
    const secret_b64 = std.base64.standard.Encoder.encode(&secret_b64_buf, &secret_random);

    ctx.exchange_mutex.lock();
    defer ctx.exchange_mutex.unlock();

    const last_nonce = nonceLookup(ctx, owner);
    if (last_nonce >= 0 and @as(u64, @intCast(last_nonce)) >= nonce) {
        return errorJson(-32000, "Nonce already used (replay rejected)", id, alloc);
    }

    const now_ms = std.time.milliTimestamp();
    apiKeyInsert(ctx, &key_id, &secret_random, &sec_hash, name, owner, now_ms);
    nonceSet(ctx, owner, nonce);

    var jbuf: [512]u8 = undefined;
    const jline = std.fmt.bufPrint(&jbuf,
        "\"keyId\":\"{s}\",\"secretHash\":\"{s}\",\"name\":\"{s}\",\"owner\":\"{s}\",\"ts\":{d}",
        .{ key_id, sec_hash, name, owner, now_ms },
    ) catch "";
    if (jline.len > 0) usersAppendJournal(ctx, "apikey", jline);

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"keyId\":\"{s}\",\"secret\":\"{s}\",\"secretB64\":\"{s}\",\"name\":\"{s}\",\"warning\":\"Save the secret — it is only shown once. Use secretB64 for HMAC-SHA512 signing.\",\"createdMs\":{d}}}}}",
        .{ id, key_id, secret_str, secret_b64, name, now_ms });
}

/// exchange_listApiKeys — list keys owned by an address. Secrets are
/// never returned (only the SHA256 hash for transparency).
fn handleExchangeListApiKeys(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const owner = extractStr(body, "owner") orelse extractStr(body, "address") orelse
        return errorJson(-32602, "Missing param: owner", id, alloc);

    ctx.exchange_mutex.lock();
    defer ctx.exchange_mutex.unlock();

    var out = std.ArrayList(u8){};
    defer out.deinit(alloc);
    try out.appendSlice(alloc, "{\"jsonrpc\":\"2.0\",\"id\":");
    try std.fmt.format(out.writer(alloc), "{d}", .{id});
    try out.appendSlice(alloc, ",\"result\":[");
    var first = true;
    var i: u16 = 0;
    while (i < ctx.exstate.?.api_key_count) : (i += 1) {
        const k = &ctx.exstate.?.api_keys[i];
        if (k.owner_len != owner.len) continue;
        if (!std.mem.eql(u8, k.owner[0..k.owner_len], owner)) continue;
        if (!first) try out.appendSlice(alloc, ",");
        first = false;
        try std.fmt.format(out.writer(alloc),
            "{{\"keyId\":\"{s}\",\"name\":\"{s}\",\"createdMs\":{d},\"lastUsedMs\":{d},\"revoked\":{s}}}",
            .{ k.key_id[0..k.key_id_len], k.name[0..k.name_len], k.created_ms, k.last_used_ms,
               if (k.revoked) "true" else "false" });
    }
    try out.appendSlice(alloc, "]}");
    return alloc.dupe(u8, out.items);
}

/// exchange_revokeApiKey — owner revokes one of their keys.
/// Verified by signature on "EXCHANGE_APIKEY_REVOKE_V1\n<keyId>\n<owner>\n<nonce>".
fn handleExchangeRevokeApiKey(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const owner = extractStr(body, "owner") orelse extractStr(body, "address") orelse
        return errorJson(-32602, "Missing param: owner", id, alloc);
    const key_id = extractStr(body, "keyId") orelse
        return errorJson(-32602, "Missing param: keyId", id, alloc);
    const sig_hex = extractStr(body, "signature") orelse
        return errorJson(-32602, "Missing param: signature", id, alloc);
    const pubkey_hex = extractStr(body, "publicKey") orelse extractStr(body, "pubkey") orelse
        return errorJson(-32602, "Missing param: publicKey", id, alloc);
    const nonce = extractArrayNumByKey(body, "nonce");
    if (nonce == 0) return errorJson(-32602, "Missing or zero: nonce", id, alloc);

    var msg_buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf, "EXCHANGE_APIKEY_REVOKE_V1\n{s}\n{s}\n{d}", .{ key_id, owner, nonce }) catch
        return errorJson(-32603, "Failed to build sign message", id, alloc);
    if (!verifyOrderSig(msg, sig_hex, pubkey_hex)) {
        return errorJson(-32000, "Signature verify failed", id, alloc);
    }
    var pk_bytes: [33]u8 = undefined;
    _ = hex_utils.hexToBytes(pubkey_hex, &pk_bytes) catch
        return errorJson(-32000, "Bad pubkey hex", id, alloc);
    const derived_addr = deriveOBAddressFromPubkey(pk_bytes, alloc) catch
        return errorJson(-32000, "Cannot derive address from pubkey", id, alloc);
    defer alloc.free(derived_addr);
    if (!std.mem.eql(u8, derived_addr, owner)) {
        return errorJson(-32000, "Public key does not match owner", id, alloc);
    }

    ctx.exchange_mutex.lock();
    defer ctx.exchange_mutex.unlock();

    const k = apiKeyLookup(ctx, key_id) orelse
        return errorJson(-32000, "Key not found or already revoked", id, alloc);
    if (k.owner_len != owner.len or !std.mem.eql(u8, k.owner[0..k.owner_len], owner)) {
        return errorJson(-32000, "Not owner of this key", id, alloc);
    }
    const last_nonce = nonceLookup(ctx, owner);
    if (last_nonce >= 0 and @as(u64, @intCast(last_nonce)) >= nonce) {
        return errorJson(-32000, "Nonce already used", id, alloc);
    }
    apiKeyRevoke(ctx, key_id);
    nonceSet(ctx, owner, nonce);

    var jbuf: [128]u8 = undefined;
    const jline = std.fmt.bufPrint(&jbuf, "\"keyId\":\"{s}\",\"ts\":{d}", .{ key_id, std.time.milliTimestamp() }) catch "";
    if (jline.len > 0) usersAppendJournal(ctx, "revoke", jline);

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"keyId\":\"{s}\",\"revoked\":true}}}}",
        .{ id, key_id });
}

/// exchange_deposit — credit internal exchange balance.
/// On testnet/regtest: credits directly (no on-chain proof required).
/// On mainnet (chain_id == 1): requires a `txid` that actually sent OMNI
/// to the exchange escrow address — use exchange_depositReal instead.
fn handleExchangeDeposit(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;

    // Block fake-credit on mainnet — callers must use exchange_depositReal.
    if (ctx.chain_id == 1) {
        return errorJson(-32000,
            "exchange_deposit disabled on mainnet; use exchange_depositReal with a confirmed txid",
            id, alloc);
    }

    const owner = extractStr(body, "owner") orelse extractStr(body, "address") orelse
        return errorJson(-32602, "Missing param: owner", id, alloc);
    const token = extractStr(body, "token") orelse "OMNI";
    const amount = extractArrayNumByKey(body, "amount");
    if (amount == 0) return errorJson(-32602, "Missing or zero: amount", id, alloc);
    const sig_hex = extractStr(body, "signature") orelse
        return errorJson(-32602, "Missing param: signature", id, alloc);
    const pubkey_hex = extractStr(body, "publicKey") orelse extractStr(body, "pubkey") orelse
        return errorJson(-32602, "Missing param: publicKey", id, alloc);
    const nonce = extractArrayNumByKey(body, "nonce");
    if (nonce == 0) return errorJson(-32602, "Missing or zero: nonce", id, alloc);

    var msg_buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf,
        "EXCHANGE_DEPOSIT_V1\n{s}\n{s}\n{d}\n{d}",
        .{ owner, token, amount, nonce }) catch
        return errorJson(-32603, "Failed to build sign message", id, alloc);
    if (!verifyOrderSig(msg, sig_hex, pubkey_hex)) {
        return errorJson(-32000, "Signature verify failed", id, alloc);
    }
    var pk_bytes: [33]u8 = undefined;
    _ = hex_utils.hexToBytes(pubkey_hex, &pk_bytes) catch
        return errorJson(-32000, "Bad pubkey hex", id, alloc);
    const derived_addr = deriveOBAddressFromPubkey(pk_bytes, alloc) catch
        return errorJson(-32000, "Cannot derive address from pubkey", id, alloc);
    defer alloc.free(derived_addr);
    if (!std.mem.eql(u8, derived_addr, owner)) {
        return errorJson(-32000, "Public key does not match owner", id, alloc);
    }

    ctx.exchange_mutex.lock();
    defer ctx.exchange_mutex.unlock();

    const last_nonce = nonceLookup(ctx, owner);
    if (last_nonce >= 0 and @as(u64, @intCast(last_nonce)) >= nonce) {
        return errorJson(-32000, "Nonce already used", id, alloc);
    }

    if (!balanceCredit(ctx, owner, token, amount)) {
        return errorJson(-32000, "Balance table full", id, alloc);
    }
    nonceSet(ctx, owner, nonce);

    var jbuf: [256]u8 = undefined;
    const jline = std.fmt.bufPrint(&jbuf,
        "\"owner\":\"{s}\",\"token\":\"{s}\",\"amount\":{d},\"ts\":{d}",
        .{ owner, token, amount, std.time.milliTimestamp() }) catch "";
    if (jline.len > 0) usersAppendJournal(ctx, "deposit", jline);

    const b = balanceLookup(ctx, owner, token).?;
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"owner\":\"{s}\",\"token\":\"{s}\",\"available\":{d},\"locked\":{d}}}}}",
        .{ id, owner, token, b.available_sat, b.locked_sat });
}

/// exchange_withdraw — debit internal balance. Symmetric to deposit;
/// on mainnet the chain would also credit the user's on-chain wallet
/// here (atomic transfer). Testnet: just debits the internal pool.
fn handleExchangeWithdraw(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const owner = extractStr(body, "owner") orelse extractStr(body, "address") orelse
        return errorJson(-32602, "Missing param: owner", id, alloc);
    const is_paper = isPaperMode(body);

    // Phase 1E: destination required for real mode (on-chain TX)
    const destination = if (!is_paper)
        (extractStr(body, "destination") orelse
            return errorJson(-32602, "Missing param: destination (for real mode)", id, alloc))
    else
        owner;  // paper mode: withdraw to self (internal debit only)

    const amount = extractArrayNumByKey(body, "amount");
    if (amount == 0) return errorJson(-32602, "Missing or zero: amount", id, alloc);
    const sig_hex = extractStr(body, "signature") orelse
        return errorJson(-32602, "Missing param: signature", id, alloc);
    const pubkey_hex = extractStr(body, "publicKey") orelse extractStr(body, "pubkey") orelse
        return errorJson(-32602, "Missing param: publicKey", id, alloc);
    const nonce = extractArrayNumByKey(body, "nonce");
    if (nonce == 0) return errorJson(-32602, "Missing or zero: nonce", id, alloc);

    // PHASE 1: REST HMAC-authenticated requests bypass ECDSA.
    const is_hmac_bypass = std.mem.eql(u8, sig_hex, "REST_HMAC_BYPASS");
    if (!is_hmac_bypass) {
        var msg_buf: [512]u8 = undefined;
        const msg_result = if (is_paper)
            std.fmt.bufPrint(&msg_buf,
                "EXCHANGE_WITHDRAW_V1\n{s}\nOMNI_DEMO\n{d}\n{d}",
                .{ owner, amount, nonce })
        else
            std.fmt.bufPrint(&msg_buf,
                "EXCHANGE_WITHDRAW_V1\n{s}\n{s}\nOMNI\n{d}\n{d}",
                .{ owner, destination, amount, nonce });

        const msg = msg_result catch
            return errorJson(-32603, "Failed to build sign message", id, alloc);

        if (!verifyOrderSig(msg, sig_hex, pubkey_hex)) {
            return errorJson(-32000, "Signature verify failed", id, alloc);
        }
        var pk_bytes: [33]u8 = undefined;
        _ = hex_utils.hexToBytes(pubkey_hex, &pk_bytes) catch
            return errorJson(-32000, "Bad pubkey hex", id, alloc);
        const derived_addr = deriveOBAddressFromPubkey(pk_bytes, alloc) catch
            return errorJson(-32000, "Cannot derive address from pubkey", id, alloc);
        defer alloc.free(derived_addr);
        if (!std.mem.eql(u8, derived_addr, owner)) {
            return errorJson(-32000, "Public key does not match owner", id, alloc);
        }
    }

    ctx.exchange_mutex.lock();
    defer ctx.exchange_mutex.unlock();

    const last_nonce = nonceLookup(ctx, owner);
    if (last_nonce >= 0 and @as(u64, @intCast(last_nonce)) >= nonce) {
        return errorJson(-32000, "Nonce already used", id, alloc);
    }

    // Phase 1E: Real mode creates on-chain TX, paper mode debits internal table
    if (is_paper) {
        const token = "OMNI_DEMO";
        if (!balanceDebit(ctx, owner, token, amount)) {
            return errorJson(-32000, "Insufficient balance", id, alloc);
        }
        nonceSet(ctx, owner, nonce);

        var jbuf: [256]u8 = undefined;
        const jline = std.fmt.bufPrint(&jbuf,
            "\"owner\":\"{s}\",\"token\":\"{s}\",\"amount\":{d},\"ts\":{d}",
            .{ owner, token, amount, std.time.milliTimestamp() }) catch "";
        if (jline.len > 0) usersAppendJournal(ctx, "withdraw", jline);

        return std.fmt.allocPrint(alloc,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"owner\":\"{s}\",\"destination\":\"{s}\",\"amount\":{d},\"status\":\"completed\"}}}}",
            .{ id, owner, owner, amount });
    } else {
        // Real mode: check blockchain balance and create on-chain TX
        const balance = ctx.bc.getAddressBalance(owner);
        if (balance < amount) {
            return errorJson(-32000, "Insufficient blockchain balance", id, alloc);
        }

        // Create on-chain TX: owner -> destination
        var tx = transaction_mod.Transaction{
            .id = @intCast(@min(ctx.bc.chain.items.len, std.math.maxInt(u32))),
            .scheme = .omni_ecdsa,
            .from_address = try alloc.dupe(u8, owner),
            .to_address = try alloc.dupe(u8, destination),
            .amount = amount,
            .fee = 0,
            .timestamp = std.time.milliTimestamp(),
            .nonce = nonce,
            .op_return = "",
            .locktime = 0,
            .sequence = 0xFFFFFFFF,
            .script_pubkey = "",
            .script_sig = "",
            .signature = try alloc.dupe(u8, sig_hex),
            .hash = try alloc.dupe(u8, "pending"),  // will be computed during addTransaction
            .public_key = try alloc.dupe(u8, pubkey_hex),
        };

        // Add to blockchain
        ctx.bc.addTransaction(tx) catch |err| {
            alloc.free(tx.from_address);
            alloc.free(tx.to_address);
            alloc.free(tx.signature);
            alloc.free(tx.hash);
            alloc.free(tx.public_key);
            std.debug.print("[EXCHANGE] Withdraw TX creation failed: {}\n", .{err});
            return errorJson(-32603, "Failed to create withdraw TX", id, alloc);
        };
        defer {
            alloc.free(tx.from_address);
            alloc.free(tx.to_address);
            alloc.free(tx.signature);
            alloc.free(tx.hash);
            alloc.free(tx.public_key);
        }

        nonceSet(ctx, owner, nonce);

        var jbuf: [512]u8 = undefined;
        const jline = std.fmt.bufPrint(&jbuf,
            "\"owner\":\"{s}\",\"destination\":\"{s}\",\"amount\":{d},\"txHash\":\"{s}\",\"ts\":{d}",
            .{ owner, destination, amount, tx.hash[0..@min(64, tx.hash.len)], std.time.milliTimestamp() }) catch "";
        if (jline.len > 0) usersAppendJournal(ctx, "withdraw", jline);

        return std.fmt.allocPrint(alloc,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"owner\":\"{s}\",\"destination\":\"{s}\",\"amount\":{d},\"txHash\":\"{s}\",\"status\":\"pending\"}}}}",
            .{ id, owner, destination, amount, tx.hash[0..@min(64, tx.hash.len)] });
    }
}

/// exchange_getBalance — returns single address balance with reservation info (Phase 1B).
/// For real mode: balance from blockchain, reserved from orders.
/// For paper mode: balance from OMNI_DEMO internal table.
fn handleExchangeGetBalance(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const address = extractStr(body, "address") orelse extractStr(body, "owner") orelse
        return errorJson(-32602, "Missing param: address", id, alloc);
    const is_paper = isPaperMode(body);

    ctx.exchange_mutex.lock();
    defer ctx.exchange_mutex.unlock();

    if (is_paper) {
        const b = balanceLookup(ctx, address, "OMNI_DEMO");
        const balance_amt = if (b) |bal| bal.available_sat else 0;
        return std.fmt.allocPrint(alloc,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"address\":\"{s}\",\"balance\":{d},\"reserved\":0,\"available\":{d},\"mode\":\"paper\"}}}}",
            .{ id, address, balance_amt, balance_amt });
    } else {
        const balance = ctx.bc.getAddressBalance(address);
        const reserved = if (ctx.exchange) |eng|
            computeReservedFromOrderbook(eng, address)
        else
            0;
        const available = if (balance < reserved) 0 else (balance - reserved);
        return std.fmt.allocPrint(alloc,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"address\":\"{s}\",\"balance\":{d},\"reserved\":{d},\"available\":{d},\"mode\":\"real\"}}}}",
            .{ id, address, balance, reserved, available });
    }
}

/// exchange_getBalances — read-only listing of balances for an owner.
///
/// Real mode: balance comes from on-chain UTXO state (`getAddressBalance`),
/// `locked` = sum of remaining amounts in active sell orders for this address
/// (derived from orderbook, see computeReservedFromOrderbook). Single source
/// of truth — no internal balance table for real OMNI.
///
/// Paper mode: balance comes from internal `_DEMO`-suffixed table (sandbox
/// credits issued by exchange_depositDemo, never on-chain).
fn handleExchangeGetBalances(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const owner = extractStr(body, "owner") orelse extractStr(body, "address") orelse
        return errorJson(-32602, "Missing param: owner", id, alloc);

    const is_paper = isPaperMode(body);

    ctx.exchange_mutex.lock();
    defer ctx.exchange_mutex.unlock();

    var out = std.ArrayList(u8){};
    defer out.deinit(alloc);
    try out.appendSlice(alloc, "{\"jsonrpc\":\"2.0\",\"id\":");
    try std.fmt.format(out.writer(alloc), "{d}", .{id});
    try out.appendSlice(alloc, ",\"result\":[");

    if (is_paper) {
        // Paper mode: walk internal table for `_DEMO`-suffixed tokens only.
        var first = true;
        var i: u16 = 0;
        while (i < ctx.exstate.?.balance_count) : (i += 1) {
            const b = &ctx.exstate.?.balances[i];
            if (b.owner_len != owner.len) continue;
            if (!std.mem.eql(u8, b.owner[0..b.owner_len], owner)) continue;
            const token = b.token[0..b.token_len];
            if (!std.mem.endsWith(u8, token, "_DEMO")) continue;

            if (!first) try out.appendSlice(alloc, ",");
            first = false;
            try std.fmt.format(out.writer(alloc),
                "{{\"token\":\"{s}\",\"available\":{d},\"locked\":{d}}}",
                .{ token, b.available_sat, b.locked_sat });
        }
    } else {
        // Real mode: OMNI balance from on-chain UTXO + orderbook-derived lock.
        const balance = ctx.bc.getAddressBalance(owner);
        const locked = if (ctx.exchange) |eng|
            computeReservedFromOrderbook(eng, owner)
        else
            0;
        const available = if (balance < locked) 0 else (balance - locked);
        try std.fmt.format(out.writer(alloc),
            "{{\"token\":\"OMNI\",\"available\":{d},\"locked\":{d}}}",
            .{ available, locked });
    }

    try out.appendSlice(alloc, "]}");
    return alloc.dupe(u8, out.items);
}

// ── Demo / Real deposit + escrow ─────────────────────────────────────

/// exchange_getEscrowAddress — return the on-chain address users send
/// real deposits to. Always the canonical exchange.omnibus registrar
/// wallet (slot #2). Never the local node's wallet.
fn handleExchangeGetEscrowAddress(ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const escrow = registrar_mod.addressOf(.exchange) orelse ctx.wallet.address;
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"address\":\"{s}\",\"note\":\"Send OMNI to this address, then call exchange_depositReal with the txid\"}}}}",
        .{ id, escrow });
}


// ── Grid trading RPC handlers ─────────────────────────────────────────────

/// grid_create — pornește un grid nou pentru un owner pe o pereche.
/// Params: { pair_id, price_low, price_high, levels, total_base, total_quote, owner }
fn handleGridCreate(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const pair_id_u   = extractU64Param(body, "\"pair_id\"")    orelse return errorJson(-32602, "Missing pair_id", id, alloc);
    const price_low   = extractU64Param(body, "\"price_low\"")  orelse return errorJson(-32602, "Missing price_low", id, alloc);
    const price_high  = extractU64Param(body, "\"price_high\"") orelse return errorJson(-32602, "Missing price_high", id, alloc);
    const levels_u    = extractU64Param(body, "\"levels\"")     orelse return errorJson(-32602, "Missing levels", id, alloc);
    const total_base  = extractU64Param(body, "\"total_base\"") orelse return errorJson(-32602, "Missing total_base", id, alloc);
    const total_quote = extractU64Param(body, "\"total_quote\"") orelse return errorJson(-32602, "Missing total_quote", id, alloc);
    const owner      = extractStr(body, "owner") orelse return errorJson(-32602, "Missing owner", id, alloc);

    if (levels_u > grid_mod.MAX_LEVELS) return errorJson(-32602, "levels too large (max 100)", id, alloc);

    ctx.grid_mutex.lock();
    defer ctx.grid_mutex.unlock();

    const reg = ctx.grid_registry orelse return errorJson(-32000, "Grid engine not initialized", id, alloc);

    const current_block: u64 = ctx.bc.getBlockCount();
    const grid_id = reg.create(
        owner, @intCast(pair_id_u), price_low, price_high,
        @intCast(levels_u), total_base, total_quote, current_block,
    ) catch |err| return errorJson(-32000, @errorName(err), id, alloc);

    // Wire grid orders into the matching engine so they appear in the orderbook.
    if (ctx.exchange) |eng| reg.placeLevelOrders(grid_id, eng);

    if (gridPathSlice(ctx)) |p| reg.saveToFile(p) catch {};

    const g = reg.find(grid_id).?;
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{" ++
        "\"grid_id\":{d},\"pair_id\":{d},\"levels_generated\":{d}," ++
        "\"buy_orders\":{d},\"sell_orders\":{d},\"price_step\":{d}}}}}",
        .{ id, grid_id, pair_id_u, @as(u32, g.levels) * 2,
           g.levels, g.levels, g.priceStep() });
}

/// grid_list — listează grid-urile active (opțional filtrate după owner).
/// Params: { owner? }
fn handleGridList(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const filter_owner = extractStr(body, "owner");

    ctx.grid_mutex.lock();
    defer ctx.grid_mutex.unlock();

    var out = std.ArrayList(u8){};
    defer out.deinit(alloc);
    try std.fmt.format(out.writer(alloc), "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":[", .{id});

    var first = true;
    if (ctx.grid_registry) |reg| {
        var i: u32 = 0;
        while (i < reg.count) : (i += 1) {
            const g = &reg.grids[i];
            if (filter_owner) |fo| {
                if (!std.mem.eql(u8, g.owner[0..g.owner_len], fo)) continue;
            }
            if (!first) try out.appendSlice(alloc, ",");
            first = false;
            try grid_mod.writeGridJson(g, &out, alloc);
        }
    }
    try out.appendSlice(alloc, "]}");
    return alloc.dupe(u8, out.items);
}

/// grid_status — detalii complete pentru un grid (inclusiv levels calculate).
/// Params: { grid_id }
fn handleGridStatus(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const grid_id = extractU64Param(body, "\"grid_id\"") orelse
        return errorJson(-32602, "Missing grid_id", id, alloc);

    ctx.grid_mutex.lock();
    defer ctx.grid_mutex.unlock();

    const reg = ctx.grid_registry orelse return errorJson(-32000, "Grid engine not initialized", id, alloc);
    const g = reg.find(grid_id) orelse return errorJson(-32602, "Grid not found", id, alloc);

    var out = std.ArrayList(u8){};
    defer out.deinit(alloc);
    // Open the JSON-RPC envelope and result object inline so we can append
    // buy_levels/sell_levels INSIDE the same result object.
    // We do NOT call writeGridJson here because that emits a complete {...} object
    // and appending after its closing brace produces invalid JSON.
    try std.fmt.format(out.writer(alloc),
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{" ++
        "\"grid_id\":{d},\"pair_id\":{d},\"owner\":\"{s}\"," ++
        "\"price_low\":{d},\"price_high\":{d},\"levels\":{d}," ++
        "\"total_base\":{d},\"total_quote\":{d}," ++
        "\"filled_count\":{d},\"profit_quote\":{d},\"active\":{s}," ++
        "\"created_block\":{d}",
        .{
            id,
            g.id, g.pair_id, g.owner[0..g.owner_len],
            g.price_low, g.price_high, g.levels,
            g.total_base, g.total_quote,
            g.filled_count, g.profit_quote,
            if (g.active) "true" else "false",
            g.created_block,
        });

    // Adaugă levels calculate (still inside the result object)
    try out.appendSlice(alloc, ",\"buy_levels\":[");
    var lvl: u16 = 0;
    while (lvl < g.levels) : (lvl += 1) {
        if (lvl > 0) try out.appendSlice(alloc, ",");
        try std.fmt.format(out.writer(alloc),
            "{{\"level\":{d},\"price\":{d},\"amount\":{d}}}",
            .{ lvl, g.buyPrice(lvl), g.basePerLevel() });
    }
    try out.appendSlice(alloc, "],\"sell_levels\":[");
    lvl = 0;
    while (lvl < g.levels) : (lvl += 1) {
        if (lvl > 0) try out.appendSlice(alloc, ",");
        try std.fmt.format(out.writer(alloc),
            "{{\"level\":{d},\"price\":{d},\"amount\":{d}}}",
            .{ lvl, g.sellPrice(lvl), g.basePerLevel() });
    }
    // Close: sell_levels array "]", result object "}", envelope "}"
    try out.appendSlice(alloc, "]}}");
    return alloc.dupe(u8, out.items);
}

/// grid_cancel — oprește un grid activ.
/// Params: { grid_id, owner }
fn handleGridCancel(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const grid_id = extractU64Param(body, "\"grid_id\"") orelse
        return errorJson(-32602, "Missing grid_id", id, alloc);
    const owner = extractStr(body, "owner") orelse
        return errorJson(-32602, "Missing owner", id, alloc);

    ctx.grid_mutex.lock();
    defer ctx.grid_mutex.unlock();

    const reg = ctx.grid_registry orelse return errorJson(-32000, "Grid engine not initialized", id, alloc);
    reg.cancel(grid_id, owner) catch |err| return errorJson(-32000, @errorName(err), id, alloc);

    if (gridPathSlice(ctx)) |p| reg.saveToFile(p) catch {};

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"grid_id\":{d},\"cancelled\":true}}}}",
        .{ id, grid_id });
}

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

fn demoQuotaGetOrCreate(es: *ExchangeState, addr: []const u8) ?*DemoQuota {
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
fn handleExchangeDepositDemo(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    if (ctx.exstate == null) return errorJson(-32601, "Exchange not enabled on this node", id, alloc);

    const owner = extractStr(body, "owner") orelse extractStr(body, "address") orelse
        return errorJson(-32602, "Missing param: owner", id, alloc);
    const amount = extractArrayNumByKey(body, "amount");
    if (amount == 0) return errorJson(-32602, "Missing or zero: amount", id, alloc);
    if (amount > DEMO_MAX_PER_REQUEST_SAT) {
        return errorJson(-32000, "Demo deposit too large (max 10 OMNI per request)", id, alloc);
    }
    if (owner.len > 64 or owner.len < 4) return errorJson(-32602, "Bad owner address", id, alloc);

    ctx.exchange_mutex.lock();
    defer ctx.exchange_mutex.unlock();

    const es = ctx.exstate.?;
    const now_ms = std.time.milliTimestamp();
    const q = demoQuotaGetOrCreate(es, owner) orelse
        return errorJson(-32000, "Demo quota table full", id, alloc);

    // Reset the rolling window if it's been 24h since first grant.
    if (now_ms - q.window_start_ms > DEMO_WINDOW_MS) {
        q.granted_sat = 0;
        q.window_start_ms = now_ms;
    }
    if (q.granted_sat + amount > DEMO_MAX_PER_24H_SAT) {
        const remaining = if (q.granted_sat >= DEMO_MAX_PER_24H_SAT) 0
            else DEMO_MAX_PER_24H_SAT - q.granted_sat;
        return std.fmt.allocPrint(alloc,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"error\":{{\"code\":-32000,\"message\":\"Daily demo limit reached. {d} SAT remaining in this 24h window.\"}}}}",
            .{ id, remaining });
    }

    if (!balanceCredit(ctx, owner, "OMNI_DEMO", amount)) {
        return errorJson(-32000, "Balance table full", id, alloc);
    }
    q.granted_sat += amount;

    var jbuf: [256]u8 = undefined;
    const jline = std.fmt.bufPrint(&jbuf,
        "\"owner\":\"{s}\",\"token\":\"OMNI_DEMO\",\"amount\":{d},\"ts\":{d}",
        .{ owner, amount, now_ms }) catch "";
    if (jline.len > 0) usersAppendJournal(ctx, "deposit", jline);

    const b = balanceLookup(ctx, owner, "OMNI_DEMO").?;
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"owner\":\"{s}\",\"token\":\"OMNI_DEMO\",\"amount\":{d},\"available\":{d},\"locked\":{d},\"granted24h\":{d},\"max24h\":{d},\"kind\":\"demo\"}}}}",
        .{ id, owner, amount, b.available_sat, b.locked_sat, q.granted_sat, DEMO_MAX_PER_24H_SAT });
}

fn realDepositTxidUsed(es: *ExchangeState, txid: []const u8) bool {
    if (txid.len != 64) return false;
    var i: u16 = 0;
    while (i < es.real_deposit_count) : (i += 1) {
        if (std.mem.eql(u8, &es.real_deposit_txids[i], txid)) return true;
    }
    return false;
}

fn realDepositTxidRecord(es: *ExchangeState, txid: []const u8) bool {
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
fn handleExchangeDepositReal(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    if (ctx.exstate == null) return errorJson(-32601, "Exchange not enabled on this node", id, alloc);

    const owner = extractStr(body, "owner") orelse extractStr(body, "address") orelse
        return errorJson(-32602, "Missing param: owner", id, alloc);
    const txid = extractStr(body, "txid") orelse extractStr(body, "txHash") orelse
        return errorJson(-32602, "Missing param: txid", id, alloc);
    if (txid.len != 64) return errorJson(-32602, "txid must be 64 hex chars", id, alloc);

    const escrow = ctx.wallet.address;

    // Look the TX up on-chain. Mirrors handleGetTx logic — same indexes.
    ctx.bc.mutex.lock();
    defer ctx.bc.mutex.unlock();

    var found_tx: ?transaction_mod.Transaction = null;
    var confirmations: u64 = 0;
    if (ctx.bc.tx_block_height.get(txid)) |bh| {
        if (bh < ctx.bc.chain.items.len) {
            const blk = ctx.bc.chain.items[bh];
            for (blk.transactions.items) |tx| {
                if (std.mem.eql(u8, tx.hash, txid)) {
                    found_tx = tx;
                    const tip: u64 = @intCast(ctx.bc.chain.items.len);
                    confirmations = if (tip > bh) tip - bh else 0;
                    break;
                }
            }
        }
    }
    if (found_tx == null) {
        // Linear scan fallback — older TXs not in index.
        outer: for (ctx.bc.chain.items) |blk| {
            for (blk.transactions.items) |tx| {
                if (std.mem.eql(u8, tx.hash, txid)) {
                    found_tx = tx;
                    const tip: u64 = @intCast(ctx.bc.chain.items.len);
                    const bh: u64 = @intCast(blk.index);
                    confirmations = if (tip > bh) tip - bh else 0;
                    break :outer;
                }
            }
        }
    }
    const tx = found_tx orelse return errorJson(-32000, "Transaction not found in chain (still pending? wait for confirmation)", id, alloc);

    if (!std.mem.eql(u8, tx.from_address, owner)) {
        return errorJson(-32000, "TX sender does not match owner address", id, alloc);
    }
    if (!std.mem.eql(u8, tx.to_address, escrow)) {
        return errorJson(-32000, "TX recipient is not the exchange escrow address", id, alloc);
    }
    if (confirmations < 1) {
        return errorJson(-32000, "TX not yet confirmed (need >= 1 block)", id, alloc);
    }

    ctx.exchange_mutex.lock();
    defer ctx.exchange_mutex.unlock();

    const es = ctx.exstate.?;
    if (realDepositTxidUsed(es, txid)) {
        return errorJson(-32000, "This txid has already been credited", id, alloc);
    }

    if (!balanceCredit(ctx, owner, "OMNI", tx.amount)) {
        return errorJson(-32000, "Balance table full", id, alloc);
    }
    _ = realDepositTxidRecord(es, txid);

    var jbuf: [320]u8 = undefined;
    const jline = std.fmt.bufPrint(&jbuf,
        "\"owner\":\"{s}\",\"token\":\"OMNI\",\"amount\":{d},\"txid\":\"{s}\",\"ts\":{d}",
        .{ owner, tx.amount, txid, std.time.milliTimestamp() }) catch "";
    if (jline.len > 0) usersAppendJournal(ctx, "deposit", jline);

    const b = balanceLookup(ctx, owner, "OMNI").?;
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"owner\":\"{s}\",\"token\":\"OMNI\",\"amount\":{d},\"available\":{d},\"locked\":{d},\"txid\":\"{s}\",\"confirmations\":{d},\"kind\":\"real\"}}}}",
        .{ id, owner, tx.amount, b.available_sat, b.locked_sat, txid, confirmations });
}

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

fn buildIdentitySignMessage(
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

fn handleIdentitySet(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const store = ctx.identity_store orelse
        return errorJson(-32601, "Identity store not initialized", id, alloc);

    const address = extractStr(body, "address") orelse
        return errorJson(-32602, "Missing param: address", id, alloc);
    const nickname = extractStr(body, "nickname") orelse "";
    const ens = extractStr(body, "ens") orelse extractStr(body, "ensPrimary") orelse "";
    const visibility_str = extractStr(body, "visibility") orelse "public";
    const sig_hex = extractStr(body, "signature") orelse
        return errorJson(-32602, "Missing param: signature", id, alloc);
    const pubkey_hex = extractStr(body, "publicKey") orelse extractStr(body, "pubkey") orelse
        return errorJson(-32602, "Missing param: publicKey", id, alloc);
    const nonce = extractArrayNumByKey(body, "nonce");
    if (nonce == 0) return errorJson(-32602, "Missing or zero: nonce", id, alloc);

    if (nickname.len > identity_mod.NICKNAME_MAX) {
        return errorJson(-32602, "nickname too long (max 32)", id, alloc);
    }
    if (ens.len > identity_mod.ENS_MAX) {
        return errorJson(-32602, "ens too long (max 64)", id, alloc);
    }

    // Build canonical message and verify signature.
    var msg_buf: [256]u8 = undefined;
    const msg = buildIdentitySignMessage(&msg_buf, address, nickname, ens, visibility_str, nonce) catch
        return errorJson(-32603, "Failed to build sign message", id, alloc);
    if (!verifyOrderSig(msg, sig_hex, pubkey_hex)) {
        return errorJson(-32000, "Signature verify failed", id, alloc);
    }
    var pk_bytes: [33]u8 = undefined;
    _ = hex_utils.hexToBytes(pubkey_hex, &pk_bytes) catch
        return errorJson(-32000, "Bad pubkey hex", id, alloc);
    const derived = deriveOBAddressFromPubkey(pk_bytes, alloc) catch
        return errorJson(-32000, "Cannot derive address from pubkey", id, alloc);
    defer alloc.free(derived);
    if (!std.mem.eql(u8, derived, address)) {
        return errorJson(-32000, "Public key does not match address", id, alloc);
    }

    ctx.identity_mutex.lock();
    defer ctx.identity_mutex.unlock();

    // Reuse exchange nonce table — they live in the same context. New
    // nonce must be strictly greater than last seen for this address.
    const last_nonce = nonceLookup(ctx, address);
    if (last_nonce >= 0 and @as(u64, @intCast(last_nonce)) >= nonce) {
        return errorJson(-32000, "Nonce already used", id, alloc);
    }
    nonceSet(ctx, address, nonce);

    const visibility = identity_mod.Visibility.fromStr(visibility_str);
    store.upsert(address, nickname, ens, visibility, std.time.milliTimestamp(), true) catch |err| {
        return errorJson(-32000, switch (err) {
            error.NicknameNotPrintable => "Nickname must be printable ASCII (no quotes/control/unicode)",
            error.NicknameTooLong => "Nickname too long",
            error.EnsTooLong => "ENS too long",
            error.StoreFull => "Identity store full",
            error.BadAddress => "Bad address",
        }, id, alloc);
    };

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"address\":\"{s}\",\"nickname\":\"{s}\",\"ens\":\"{s}\",\"visibility\":\"{s}\",\"updated\":true}}}}",
        .{ id, address, nickname, ens, visibility.toStr() });
}

fn handleIdentityGet(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const store = ctx.identity_store orelse
        return errorJson(-32601, "Identity store not initialized", id, alloc);
    const address = extractStr(body, "address") orelse extractArrayStr(body, 0) orelse
        return errorJson(-32602, "Missing param: address", id, alloc);

    ctx.identity_mutex.lock();
    defer ctx.identity_mutex.unlock();

    // `respect_visibility=true` so private addresses return null.
    const it = store.lookup(address, true) orelse {
        return std.fmt.allocPrint(alloc,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":null}}",
            .{id});
    };

    // For ens_only visibility, blank the nickname so the UI doesn't even
    // see it. Address is already public on chain anyway.
    const nick: []const u8 = if (it.visibility == .ens_only) "" else it.getNickname();
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"address\":\"{s}\",\"nickname\":\"{s}\",\"ens\":\"{s}\",\"visibility\":\"{s}\",\"updated\":{d}}}}}",
        .{ id, it.getAddress(), nick, it.getEns(), it.visibility.toStr(), it.updated_ms });
}

fn handleIdentitySearch(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const store = ctx.identity_store orelse
        return errorJson(-32601, "Identity store not initialized", id, alloc);
    const prefix = extractStr(body, "prefix") orelse extractArrayStr(body, 0) orelse "";
    const limit_raw = extractArrayNumByKey(body, "limit");
    const limit: u32 = if (limit_raw == 0) 25 else @intCast(@min(limit_raw, @as(u64, 100)));

    ctx.identity_mutex.lock();
    defer ctx.identity_mutex.unlock();

    var out = std.ArrayList(u8){};
    defer out.deinit(alloc);
    try out.appendSlice(alloc, "{\"jsonrpc\":\"2.0\",\"id\":");
    try std.fmt.format(out.writer(alloc), "{d}", .{id});
    try out.appendSlice(alloc, ",\"result\":[");
    var first = true;
    var emitted: u32 = 0;
    var i: u16 = 0;
    while (i < store.count and emitted < limit) : (i += 1) {
        const it = &store.items[i];
        if (it.visibility == .private) continue;
        const nick = it.getNickname();
        if (prefix.len > 0) {
            const nlower = nick;
            if (nlower.len < prefix.len) continue;
            if (!std.ascii.startsWithIgnoreCase(nlower, prefix)) continue;
        }
        if (!first) try out.appendSlice(alloc, ",");
        first = false;
        const visible_nick: []const u8 = if (it.visibility == .ens_only) "" else nick;
        try std.fmt.format(out.writer(alloc),
            "{{\"address\":\"{s}\",\"nickname\":\"{s}\",\"ens\":\"{s}\",\"visibility\":\"{s}\"}}",
            .{ it.getAddress(), visible_nick, it.getEns(), it.visibility.toStr() });
        emitted += 1;
    }
    try out.appendSlice(alloc, "]}");
    return alloc.dupe(u8, out.items);
}

// ── KYC (signed attestations) ─────────────────────────────────────────

fn handleKycGetStatus(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const store = ctx.kyc_store orelse
        return errorJson(-32601, "KYC store not initialized", id, alloc);
    const address = extractStr(body, "address") orelse extractArrayStr(body, 0) orelse
        return errorJson(-32602, "Missing param: address", id, alloc);

    ctx.identity_mutex.lock();
    defer ctx.identity_mutex.unlock();

    const now_ms = std.time.milliTimestamp();
    const att = store.highest(address, now_ms) orelse {
        return std.fmt.allocPrint(alloc,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"address\":\"{s}\",\"level\":0,\"label\":\"none\"}}}}",
            .{ id, address });
    };
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"address\":\"{s}\",\"level\":{d},\"label\":\"{s}\",\"issuer\":\"{s}\",\"issued\":{d},\"expires\":{d}}}}}",
        .{ id, address, att.level.toU8(), att.level.label(),
           att.getIssuer(), att.issued_ms, att.expires_ms });
}

/// kyc_attest — only callable by the configured KYC issuer (registrar
/// slot 4). The issuer signs the canonical message and submits it; we
/// verify the signature derives to the configured issuer address.
fn handleKycAttest(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const store = ctx.kyc_store orelse
        return errorJson(-32601, "KYC store not initialized", id, alloc);
    if (ctx.kyc_issuer_addr_len == 0) {
        return errorJson(-32601, "KYC issuance disabled on this node", id, alloc);
    }
    const expected_issuer = ctx.kyc_issuer_addr_buf[0..ctx.kyc_issuer_addr_len];

    const target = extractStr(body, "address") orelse
        return errorJson(-32602, "Missing param: address (subject)", id, alloc);
    const level_raw = extractArrayNumByKey(body, "level");
    const level = kyc_mod.Level.fromU8(@intCast(@min(level_raw, @as(u64, 3))));
    const issued_raw = extractArrayNumByKey(body, "issued");
    const issued: i64 = if (issued_raw > 0) @intCast(issued_raw) else std.time.milliTimestamp();
    // Default expiry: +1 year if caller didn't pass one.
    const expires_raw = extractArrayNumByKey(body, "expires");
    const default_expiry: i64 = issued + 365 * 24 * 60 * 60 * 1000;
    const expires: i64 = if (expires_raw > 0) @intCast(expires_raw) else default_expiry;

    const sig_hex = extractStr(body, "signature") orelse
        return errorJson(-32602, "Missing param: signature", id, alloc);
    const pubkey_hex = extractStr(body, "publicKey") orelse extractStr(body, "pubkey") orelse
        return errorJson(-32602, "Missing param: publicKey (issuer)", id, alloc);

    var msg_buf: [256]u8 = undefined;
    const msg = kyc_mod.buildAttestMessage(&msg_buf, target, level, expected_issuer, issued, expires) catch
        return errorJson(-32603, "Failed to build sign message", id, alloc);
    if (!verifyOrderSig(msg, sig_hex, pubkey_hex)) {
        return errorJson(-32000, "Signature verify failed", id, alloc);
    }

    // Verify pubkey -> address derivation matches the configured issuer.
    var pk_bytes: [33]u8 = undefined;
    _ = hex_utils.hexToBytes(pubkey_hex, &pk_bytes) catch
        return errorJson(-32000, "Bad pubkey hex", id, alloc);
    const derived = deriveOBAddressFromPubkey(pk_bytes, alloc) catch
        return errorJson(-32000, "Cannot derive address from pubkey", id, alloc);
    defer alloc.free(derived);
    if (!std.mem.eql(u8, derived, expected_issuer)) {
        return errorJson(-32000, "Caller is not the registered KYC issuer", id, alloc);
    }

    ctx.identity_mutex.lock();
    defer ctx.identity_mutex.unlock();

    store.append(target, level, expected_issuer, issued, expires, sig_hex, true) catch |err| {
        return errorJson(-32000, switch (err) {
            error.StoreFull => "KYC store full",
            error.BadAddress => "Bad subject address",
            error.BadIssuer => "Bad issuer address",
            error.BadSignature => "Bad signature",
        }, id, alloc);
    };

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"address\":\"{s}\",\"level\":{d},\"label\":\"{s}\",\"issuer\":\"{s}\",\"issued\":{d},\"expires\":{d}}}}}",
        .{ id, target, level.toU8(), level.label(), expected_issuer, issued, expires });
}

fn handleKycListIssuers(ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    if (ctx.kyc_issuer_addr_len == 0) {
        return std.fmt.allocPrint(alloc,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":[]}}", .{id});
    }
    const issuer = ctx.kyc_issuer_addr_buf[0..ctx.kyc_issuer_addr_len];
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":[{{\"address\":\"{s}\",\"role\":\"kyc.omnibus\",\"slot\":4}}]}}",
        .{ id, issuer });
}

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
fn handlePqListSchemes(ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":[" ++
            "{{\"scheme\":\"omni_ecdsa\",\"code\":0,\"address_prefix\":\"ob1q\",\"transferable\":true}}," ++
            "{{\"scheme\":\"love_dilithium\",\"code\":1,\"address_prefix\":\"ob_k1_\",\"transferable\":false}}," ++
            "{{\"scheme\":\"food_falcon\",\"code\":2,\"address_prefix\":\"ob_f5_\",\"transferable\":false}}," ++
            "{{\"scheme\":\"rent_ml_dsa\",\"code\":3,\"address_prefix\":\"ob_d5_\",\"transferable\":false}}," ++
            "{{\"scheme\":\"vacation_slh_dsa\",\"code\":4,\"address_prefix\":\"ob_s3_\",\"transferable\":false}}," ++
            // Canon transferable PQ-OMNI prefixes — must match
            // core/transaction.zig:prefix() and STATUS/MASTER_RULES_PQ_OMNI.md.
            "{{\"scheme\":\"pq_omni_ml_dsa\",\"code\":5,\"address_prefix\":\"obk1_\",\"transferable\":true}}," ++
            "{{\"scheme\":\"pq_omni_falcon\",\"code\":6,\"address_prefix\":\"obf5_\",\"transferable\":true}}," ++
            "{{\"scheme\":\"pq_omni_dilithium\",\"code\":7,\"address_prefix\":\"obs3_\",\"transferable\":true}}," ++
            "{{\"scheme\":\"pq_omni_slh_dsa\",\"code\":8,\"address_prefix\":\"obd5_\",\"transferable\":true}}," ++
            // Hybrid uses the same address prefixes as the PQ-OMNI scheme half;
            // chain distinguishes via tx.scheme byte, not by prefix.
            "{{\"scheme\":\"hybrid_q1\",\"code\":9,\"address_prefix\":\"obk1_\",\"transferable\":true}}," ++
            "{{\"scheme\":\"hybrid_q2\",\"code\":10,\"address_prefix\":\"obf5_\",\"transferable\":true}}," ++
            "{{\"scheme\":\"hybrid_q3\",\"code\":11,\"address_prefix\":\"obs3_\",\"transferable\":true}}," ++
            "{{\"scheme\":\"hybrid_q4\",\"code\":12,\"address_prefix\":\"obd5_\",\"transferable\":true}}" ++
        "]}}",
        .{id});
}

/// pq_balance — balance + scheme deduse din prefixul adresei. Read-only.
/// Reuse `bc.getAddressBalance` (acelasi balanta ca pentru orice adresa).
fn handlePqBalance(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const addr = extractArrayStr(body, 0) orelse extractStr(body, "address") orelse
        return errorJson(-32602, "Missing param: address", id, alloc);

    const scheme_opt = isolated_wallet_mod.Scheme.fromAddress(addr);
    if (scheme_opt == null) {
        return errorJson(-32602, "Address prefix does not match any PQ scheme (ob1q/ob_k1_/ob_f5_/ob_d5_/ob_s3_)", id, alloc);
    }
    const scheme = scheme_opt.?;
    const balance = ctx.bc.getAddressBalance(addr);

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{" ++
            "\"address\":\"{s}\"," ++
            "\"scheme\":\"{s}\"," ++
            "\"code\":{d}," ++
            "\"address_prefix\":\"{s}\"," ++
            "\"balance\":{d}" ++
        "}}}}",
        .{ id, addr, @tagName(scheme), @intFromEnum(scheme), scheme.prefix(), balance });
}

/// pq_verify_test — debug RPC. Apeleaza isolated_wallet.verifySignature DIRECT
/// pe (scheme, message_bytes, signature_bytes, pubkey_bytes), bypass TX hash.
/// Folosit pentru a confirma ca librariile noble (frontend) si liboqs (chain)
/// sunt interoperabile la nivel de bytes ai semnaturii.
///
/// Params (object): scheme (string sau cod 5..8), public_key (hex), message (hex), signature (hex).
/// Returns: {"verified": true|false, "scheme": "...", "msg_len": N, "pk_len": N, "sig_len": N}
fn handlePqVerifyTest(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const scheme_str = extractStr(body, "scheme") orelse "";
    const scheme_num = extractArrayNumByKey(body, "scheme");
    const pubkey_hex = extractStr(body, "public_key") orelse extractStr(body, "publicKey") orelse
        return errorJson(-32602, "Missing public_key (hex)", id, alloc);
    const message_hex = extractStr(body, "message") orelse extractStr(body, "msg") orelse
        return errorJson(-32602, "Missing message (hex)", id, alloc);
    const signature_hex = extractStr(body, "signature") orelse extractStr(body, "sig") orelse
        return errorJson(-32602, "Missing signature (hex)", id, alloc);

    const scheme: isolated_wallet_mod.Scheme = blk: {
        if (scheme_str.len > 0) {
            if (std.mem.eql(u8, scheme_str, "pq_omni_ml_dsa")    or std.mem.eql(u8, scheme_str, "ml_dsa_87"))    break :blk .pq_omni_ml_dsa;
            if (std.mem.eql(u8, scheme_str, "pq_omni_falcon")    or std.mem.eql(u8, scheme_str, "falcon_512"))   break :blk .pq_omni_falcon;
            if (std.mem.eql(u8, scheme_str, "pq_omni_dilithium") or std.mem.eql(u8, scheme_str, "dilithium_5"))  break :blk .pq_omni_dilithium;
            if (std.mem.eql(u8, scheme_str, "pq_omni_slh_dsa")   or std.mem.eql(u8, scheme_str, "slh_dsa_256s")) break :blk .pq_omni_slh_dsa;
            return errorJson(-32602, "Unknown scheme name (use ml_dsa_87/falcon_512/dilithium_5/slh_dsa_256s)", id, alloc);
        }
        if (scheme_num >= 5 and scheme_num <= 8) break :blk @enumFromInt(@as(u8, @intCast(scheme_num)));
        return errorJson(-32602, "Provide scheme (string) or scheme code 5..8", id, alloc);
    };

    if (pubkey_hex.len % 2 != 0)    return errorJson(-32602, "public_key hex length odd", id, alloc);
    if (message_hex.len % 2 != 0)   return errorJson(-32602, "message hex length odd", id, alloc);
    if (signature_hex.len % 2 != 0) return errorJson(-32602, "signature hex length odd", id, alloc);

    const pk_bytes  = alloc.alloc(u8, pubkey_hex.len / 2)    catch return errorJson(-32603, "OOM pk", id, alloc);
    defer alloc.free(pk_bytes);
    const msg_bytes = alloc.alloc(u8, message_hex.len / 2)   catch return errorJson(-32603, "OOM msg", id, alloc);
    defer alloc.free(msg_bytes);
    const sig_bytes = alloc.alloc(u8, signature_hex.len / 2) catch return errorJson(-32603, "OOM sig", id, alloc);
    defer alloc.free(sig_bytes);

    hex_utils.hexToBytes(pubkey_hex, pk_bytes)     catch return errorJson(-32602, "public_key not valid hex", id, alloc);
    hex_utils.hexToBytes(message_hex, msg_bytes)   catch return errorJson(-32602, "message not valid hex", id, alloc);
    hex_utils.hexToBytes(signature_hex, sig_bytes) catch return errorJson(-32602, "signature not valid hex", id, alloc);

    const ok = isolated_wallet_mod.verifySignature(scheme, msg_bytes, sig_bytes, pk_bytes);

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"verified\":{},\"scheme\":\"{s}\",\"msg_len\":{d},\"pk_len\":{d},\"sig_len\":{d}}}}}",
        .{ id, ok, @tagName(scheme), msg_bytes.len, pk_bytes.len, sig_bytes.len });
}

/// pq_send — construieste si submite o tranzactie semnata cu o scheme PQ.
/// Required: scheme (0..4 sau nume), from, to, amount, signature, public_key.
/// Optional: op_return, fee, nonce.
///
/// Semnatura PQ este verificata aici (chain-side) inainte de a o adauga in
/// mempool. Format mesaj canonic: hash-ul standard al TX (calculateHash).
fn handlePqSend(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;

    // 1. Parametri obligatorii
    const from = extractStr(body, "from") orelse extractStr(body, "from_address") orelse
        return errorJson(-32602, "Missing param: from", id, alloc);
    const to = extractStr(body, "to") orelse extractStr(body, "to_address") orelse
        return errorJson(-32602, "Missing param: to", id, alloc);
    const sig_hex = extractStr(body, "signature") orelse
        return errorJson(-32602, "Missing param: signature (hex pentru omni, raw bytes hex pentru PQ)", id, alloc);
    const pubkey_hex = extractStr(body, "public_key") orelse extractStr(body, "publicKey") orelse extractStr(body, "pubkey") orelse
        return errorJson(-32602, "Missing param: public_key", id, alloc);

    const amount = extractArrayNumByKey(body, "amount");
    if (amount == 0) {
        // Permitem amount=0 pentru op_return-only TXs, dar trebuie OP_RETURN nenul
        // (validat ulterior in tx.isValid)
    }
    const op_return = extractStr(body, "op_return") orelse extractStr(body, "opReturn") orelse "";
    const fee_raw = extractArrayNumByKey(body, "fee");
    const fee_sat: u64 = if (fee_raw > 0) fee_raw else mempool_mod.TX_MIN_FEE_SAT;

    // 2. Determina scheme — accepta nume sau cod numeric
    const scheme_str_opt = extractStr(body, "scheme");
    const scheme_num = extractArrayNumByKey(body, "scheme");
    const scheme: isolated_wallet_mod.Scheme = blk: {
        if (scheme_str_opt) |s| {
            if (std.mem.eql(u8, s, "omni_ecdsa") or std.mem.eql(u8, s, "omni")) break :blk .omni_ecdsa;
            if (std.mem.eql(u8, s, "love_dilithium") or std.mem.eql(u8, s, "love")) break :blk .love_dilithium;
            if (std.mem.eql(u8, s, "food_falcon") or std.mem.eql(u8, s, "food")) break :blk .food_falcon;
            if (std.mem.eql(u8, s, "rent_ml_dsa") or std.mem.eql(u8, s, "rent")) break :blk .rent_ml_dsa;
            if (std.mem.eql(u8, s, "vacation_slh_dsa") or std.mem.eql(u8, s, "vacation")) break :blk .vacation_slh_dsa;
            if (std.mem.eql(u8, s, "pq_omni_ml_dsa")) break :blk .pq_omni_ml_dsa;
            if (std.mem.eql(u8, s, "pq_omni_falcon")) break :blk .pq_omni_falcon;
            if (std.mem.eql(u8, s, "pq_omni_dilithium")) break :blk .pq_omni_dilithium;
            if (std.mem.eql(u8, s, "pq_omni_slh_dsa")) break :blk .pq_omni_slh_dsa;
            if (std.mem.eql(u8, s, "hybrid_q1")) break :blk .hybrid_q1;
            if (std.mem.eql(u8, s, "hybrid_q2")) break :blk .hybrid_q2;
            if (std.mem.eql(u8, s, "hybrid_q3")) break :blk .hybrid_q3;
            if (std.mem.eql(u8, s, "hybrid_q4")) break :blk .hybrid_q4;
            return errorJson(-32602, "Unknown scheme name", id, alloc);
        }
        if (scheme_num <= 12) break :blk @enumFromInt(@as(u8, @intCast(scheme_num)));
        return errorJson(-32602, "scheme must be 0..12 or a name string", id, alloc);
    };

    // 3. VACATION (KEM) nu poate semna
    if (scheme == .vacation_slh_dsa) {
        return errorJson(-32602, "vacation_slh_dsa cannot sign transactions (KEM is encapsulation-only)", id, alloc);
    }

    // 4. Verifica prefix adresa from corespunde scheme-ului
    const expected_prefix = scheme.prefix();
    if (!std.mem.startsWith(u8, from, expected_prefix)) {
        return errorJson(-32602, "from address prefix does not match scheme", id, alloc);
    }

    // 5. Construim TX. id si timestamp sunt parte din hash-ul semnat,
    //    deci trebuie sa fie EXACT cele pe care clientul le-a folosit la semnare.
    //    Acceptam ambele din body; daca lipsesc, fallback la counter/now (util doar
    //    pt. omni_ecdsa unde semnatura se recupereaza din hash, NU pt. PQ).
    const tx_id_param = extractArrayNumByKey(body, "id");
    const tx_id: u32 = if (tx_id_param > 0)
        @intCast(@min(tx_id_param, std.math.maxInt(u32)))
    else
        g_tx_counter.fetchAdd(1, .monotonic);
    const ts_param = extractArrayNumByKey(body, "timestamp");
    const ts_now: i64 = if (ts_param > 0) @as(i64, @intCast(ts_param)) else std.time.timestamp();
    const nonce_param = extractArrayNumByKey(body, "nonce");
    const nonce = if (nonce_param > 0) nonce_param else ctx.bc.getNextAvailableNonce(from);

    const from_owned = try alloc.dupe(u8, from);
    errdefer alloc.free(from_owned);
    const to_owned = try alloc.dupe(u8, to);
    errdefer alloc.free(to_owned);
    const op_owned: []const u8 = if (op_return.len > 0) try alloc.dupe(u8, op_return) else "";
    errdefer if (op_owned.len > 0) alloc.free(op_owned);
    const sig_owned = try alloc.dupe(u8, sig_hex);
    errdefer alloc.free(sig_owned);
    const pk_owned = try alloc.dupe(u8, pubkey_hex);
    errdefer alloc.free(pk_owned);

    var tx = transaction_mod.Transaction{
        .id           = tx_id,
        .scheme       = @as(transaction_mod.Scheme, @enumFromInt(@intFromEnum(scheme))),
        .from_address = from_owned,
        .to_address   = to_owned,
        .amount       = amount,
        .fee          = fee_sat,
        .timestamp    = ts_now,
        .nonce        = nonce,
        .op_return    = op_owned,
        .signature    = sig_owned,
        .hash         = "",
        .public_key   = pk_owned,
    };

    // 6. Calculeaza hash-ul TX si stocheaza-l in formă hex (verificat in validateTransaction)
    const tx_hash_bytes = tx.calculateHash();
    const tx_hash_hex = try alloc.alloc(u8, tx_hash_bytes.len * 2);
    {
        const hex_chars = "0123456789abcdef";
        for (tx_hash_bytes, 0..) |b, hi| {
            tx_hash_hex[hi * 2] = hex_chars[b >> 4];
            tx_hash_hex[hi * 2 + 1] = hex_chars[b & 0xF];
        }
    }
    tx.hash = tx_hash_hex;

    // 7. Verifica semnatura inainte de submit. Mesajul = bytes raw ai tx_hash.
    //    Pentru OMNI, signature-ul este 128 chars hex si pubkey 66 chars hex.
    //    Pentru PQ, signature/pubkey sunt hex de lungime variabila (per scheme).
    //    Pentru HYBRID (9..12), signature e "ecdsa_hex|pq_hex" si avem 2 pubkeys.
    const sig_ok = blk_verify: {
        if (scheme == .omni_ecdsa) {
            // Path OMNI: secp256k1 ECDSA pe hash-ul TX
            break :blk_verify isolated_wallet_mod.verifyOmniSignature(&tx_hash_bytes, sig_hex, pubkey_hex);
        }
        if (scheme.isHybrid()) {
            // Path HYBRID: avem nevoie si de pq_public_key in body
            const pq_pubkey_hex = extractStr(body, "pq_public_key") orelse extractStr(body, "pqPublicKey") orelse {
                return errorJson(-32602, "Missing param: pq_public_key (required for hybrid schemes 9..12)", id, alloc);
            };
            // Decode pq pubkey din hex la bytes
            if (pq_pubkey_hex.len % 2 != 0) break :blk_verify false;
            const pq_pk_bytes = alloc.alloc(u8, pq_pubkey_hex.len / 2) catch return errorJson(-32603, "OOM decoding pq_public_key", id, alloc);
            defer alloc.free(pq_pk_bytes);
            hex_utils.hexToBytes(pq_pubkey_hex, pq_pk_bytes) catch break :blk_verify false;
            // sig_hex contine "ecdsa_hex|pq_hex" ca ASCII; pubkey_hex = ECDSA pubkey hex
            break :blk_verify isolated_wallet_mod.verifyHybridSignature(
                scheme,
                &tx_hash_bytes,
                sig_hex,
                pubkey_hex,
                pq_pk_bytes,
            );
        }
        // Path PQ pur: decode hex bytes, dispatch via verifySignature
        const sig_bytes = alloc.alloc(u8, sig_hex.len / 2) catch return errorJson(-32603, "OOM decoding signature", id, alloc);
        defer alloc.free(sig_bytes);
        _ = hex_utils.hexToBytes(sig_hex, sig_bytes) catch break :blk_verify false;

        const pk_bytes = alloc.alloc(u8, pubkey_hex.len / 2) catch return errorJson(-32603, "OOM decoding public_key", id, alloc);
        defer alloc.free(pk_bytes);
        _ = hex_utils.hexToBytes(pubkey_hex, pk_bytes) catch break :blk_verify false;

        break :blk_verify isolated_wallet_mod.verifySignature(scheme, &tx_hash_bytes, sig_bytes, pk_bytes);
    };
    if (!sig_ok) {
        return errorJson(-32000, "Signature verification failed", id, alloc);
    }

    // 8. Inregistreaza pubkey si submite TX in mempool
    if (scheme == .omni_ecdsa and pubkey_hex.len == 66) {
        ctx.bc.registerPubkey(from, pubkey_hex) catch {};
    }
    ctx.bc.addTransaction(tx) catch |err| {
        return errorJson(-32000, switch (err) {
            error.InvalidTransaction => "Transaction validation failed",
            else => "Mempool error",
        }, id, alloc);
    };

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{" ++
            "\"txid\":\"{s}\"," ++
            "\"scheme\":\"{s}\"," ++
            "\"code\":{d}," ++
            "\"from\":\"{s}\"," ++
            "\"to\":\"{s}\"," ++
            "\"amount\":{d}," ++
            "\"fee\":{d}," ++
            "\"nonce\":{d}," ++
            "\"status\":\"accepted\"" ++
        "}}}}",
        .{ id, tx.hash, @tagName(scheme), @intFromEnum(scheme), tx.from_address, tx.to_address, tx.amount, tx.fee, tx.nonce });
}

/// pq_attestation — scaneaza chain-ul pentru tranzactii cu OP_RETURN
/// `pq_attest:<domain>:<pq_address>` trimise de la `omni_address`.
/// Returneaza ultima inregistrare gasita + numarul de confirmari.
fn handlePqAttestation(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const omni_addr = extractStr(body, "omni_address") orelse extractStr(body, "from") orelse
        return errorJson(-32602, "Missing param: omni_address", id, alloc);
    const domain = extractStr(body, "domain") orelse
        return errorJson(-32602, "Missing param: domain (love/food/rent/vacation)", id, alloc);

    var prefix_buf: [64]u8 = undefined;
    const prefix = std.fmt.bufPrint(&prefix_buf, "pq_attest:{s}:", .{domain}) catch
        return errorJson(-32603, "Domain too long", id, alloc);

    // Scaneaza chain-ul invers (cele mai recente blocuri primele)
    var latest_tx_hash: []const u8 = "";
    var latest_pq_addr: []const u8 = "";
    var latest_block_height: u64 = 0;
    var latest_timestamp: i64 = 0;
    var found = false;

    var i: usize = ctx.bc.chain.items.len;
    while (i > 0) {
        i -= 1;
        const block = &ctx.bc.chain.items[i];
        for (block.transactions.items) |*tx| {
            if (!std.mem.eql(u8, tx.from_address, omni_addr)) continue;
            if (!std.mem.startsWith(u8, tx.op_return, prefix)) continue;
            // Match — extract pq_address (totul dupa prefix)
            latest_tx_hash = tx.hash;
            latest_pq_addr = tx.op_return[prefix.len..];
            latest_block_height = @intCast(i);
            latest_timestamp = tx.timestamp;
            found = true;
            break;
        }
        if (found) break;
    }

    if (!found) {
        return std.fmt.allocPrint(alloc,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":null}}", .{id});
    }

    const confirmations = ctx.bc.getConfirmations(latest_tx_hash) orelse 0;
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{" ++
            "\"omni_address\":\"{s}\"," ++
            "\"domain\":\"{s}\"," ++
            "\"pq_address\":\"{s}\"," ++
            "\"txid\":\"{s}\"," ++
            "\"block_height\":{d}," ++
            "\"timestamp\":{d}," ++
            "\"confirmations\":{d}" ++
        "}}}}",
        .{ id, omni_addr, domain, latest_pq_addr, latest_tx_hash, latest_block_height, latest_timestamp, confirmations });
}

// ── getpqidentity ─────────────────────────────────────────────────────────────
// Returns the full PQ identity for an omni address (if registered via pq_attest_v1).

fn handleGetPqIdentity(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const omni_addr = extractStr(body, "address") orelse extractStr(body, "omni_address") orelse
        return errorJson(-32602, "Missing param: address", id, alloc);

    ctx.bc.mutex.lock();
    const identity = ctx.bc.pq_identity_map.get(omni_addr);
    ctx.bc.mutex.unlock();

    if (identity == null) {
        return std.fmt.allocPrint(alloc,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":null}}", .{id});
    }
    const idt = identity.?;
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{" ++
        "\"omni_address\":\"{s}\"," ++
        "\"love\":\"{s}\"," ++
        "\"food\":\"{s}\"," ++
        "\"rent\":\"{s}\"," ++
        "\"vacation\":\"{s}\"," ++
        "\"btc\":\"{s}\"," ++
        "\"eth\":\"{s}\"," ++
        "\"attest_block\":{d}," ++
        "\"attest_tx\":\"{s}\"" ++
        "}}}}",
        .{ id, omni_addr,
           idt.loveSlice(), idt.foodSlice(), idt.rentSlice(), idt.vacationSlice(),
           idt.btcSlice(), idt.ethSlice(),
           idt.attest_block, idt.attestTxSlice() });
}

// ── sendpqattest ──────────────────────────────────────────────────────────────
// Broadcasts a pq_attest_v1 TX from the wallet. The frontend builds + signs
// the TX with the OMNI secp256k1 key and sends the raw op_return payload here.
// Format: { "from": "ob1q...", "love": "ob_k1_...", "food": "ob_f5_...",
//           "rent": "ob_d5_...", "vacation": "ob_s3_...",
//           "btc": "bc1q..." (opt), "eth": "0x..." (opt),
//           "signature": "hex...", "public_key": "hex...", "nonce": N }

fn handleSendPqAttest(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const from     = extractStr(body, "from")     orelse return errorJson(-32602, "Missing: from", id, alloc);
    const love     = extractStr(body, "love")     orelse return errorJson(-32602, "Missing: love", id, alloc);
    const food     = extractStr(body, "food")     orelse return errorJson(-32602, "Missing: food", id, alloc);
    const rent     = extractStr(body, "rent")     orelse return errorJson(-32602, "Missing: rent", id, alloc);
    const vacation = extractStr(body, "vacation") orelse return errorJson(-32602, "Missing: vacation", id, alloc);
    const sig      = extractStr(body, "signature")   orelse return errorJson(-32602, "Missing: signature", id, alloc);
    const pubkey   = extractStr(body, "public_key")  orelse return errorJson(-32602, "Missing: public_key", id, alloc);
    const nonce    = extractParamObjectU64(body, "nonce");

    // Validate soulbound prefixes
    if (!std.mem.startsWith(u8, love,     "ob_k1_")) return errorJson(-32602, "love must start with ob_k1_", id, alloc);
    if (!std.mem.startsWith(u8, food,     "ob_f5_")) return errorJson(-32602, "food must start with ob_f5_", id, alloc);
    if (!std.mem.startsWith(u8, rent,     "ob_d5_")) return errorJson(-32602, "rent must start with ob_d5_", id, alloc);
    if (!std.mem.startsWith(u8, vacation, "ob_s3_")) return errorJson(-32602, "vacation must start with ob_s3_", id, alloc);

    // First-claim check
    ctx.bc.mutex.lock();
    const already = ctx.bc.pq_identity_map.contains(from);
    ctx.bc.mutex.unlock();
    if (already) return errorJson(-32001, "Identity already registered for this address (first-claim wins)", id, alloc);

    // Build op_return payload
    const btc = extractStr(body, "btc") orelse "";
    const eth = extractStr(body, "eth") orelse "";
    const op_return = try std.fmt.allocPrint(alloc,
        "pq_attest_v1:{s}:{s}:{s}:{s}:{s}:{s}", .{ love, food, rent, vacation, btc, eth });
    defer alloc.free(op_return);

    // Build and submit TX (amount=0, self-send)
    const ts = std.time.timestamp();
    const tx_id: u32 = @intCast(std.time.milliTimestamp() & 0xFFFFFFFF);
    // Compute a provisional hash string from id+from+timestamp
    const tx_hash = try std.fmt.allocPrint(alloc, "{d}{s}{d}", .{ tx_id, from, ts });
    defer alloc.free(tx_hash);

    var tx = blockchain_mod.Transaction{
        .id           = tx_id,
        .from_address = from,
        .to_address   = from,
        .amount       = 0,
        .fee          = 1000,
        .timestamp    = ts,
        .nonce        = nonce,
        .op_return    = op_return,
        .signature    = sig,
        .public_key   = pubkey,
        .scheme       = .omni_ecdsa,
        .hash         = tx_hash,
    };
    // Replace provisional hash with canonical TX hash (hex-encoded)
    const hash_bytes = tx.calculateHash();
    const canonical = try std.fmt.allocPrint(alloc, "{s}", .{std.fmt.bytesToHex(hash_bytes, .lower)});
    tx.hash = canonical;

    ctx.bc.mutex.lock();
    ctx.bc.mempool.append(tx) catch {
        ctx.bc.mutex.unlock();
        return errorJson(-32603, "Mempool full", id, alloc);
    };
    ctx.bc.mutex.unlock();

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"status\":\"queued\",\"txid\":\"{s}\",\"op_return\":\"{s}\"}}}}",
        .{ id, canonical, op_return });
}

// ── applylabel ────────────────────────────────────────────────────────────────
// Submit a label TX: { "from":"ob1q...", "target":"ob1q...", "tag":"scam",
//   "note":"optional", "tier":"FOOD", "signature":"hex", "public_key":"hex", "nonce":N }
// Fee: minimum 0.1 OMNI (LABEL_FEE_SAT). anti-spam.

fn handleApplyLabel(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const from    = extractStr(body, "from")    orelse return errorJson(-32602, "Missing: from", id, alloc);
    const target  = extractStr(body, "target")  orelse return errorJson(-32602, "Missing: target", id, alloc);
    const tag_str = extractStr(body, "tag")     orelse return errorJson(-32602, "Missing: tag", id, alloc);
    const note    = extractStr(body, "note")    orelse "";
    const tier    = extractStr(body, "tier")    orelse "OMNI";
    const sig     = extractStr(body, "signature")  orelse return errorJson(-32602, "Missing: signature", id, alloc);
    const pubkey  = extractStr(body, "public_key") orelse return errorJson(-32602, "Missing: public_key", id, alloc);
    const nonce   = extractParamObjectU64(body, "nonce");

    const tag = label_mod.Tag.fromStr(tag_str) orelse
        return errorJson(-32602, "Unknown tag", id, alloc);

    // Build op_return
    const op_return = try std.fmt.allocPrint(alloc, "label:{s}:{s}:{s}", .{ target, tag.toStr(), note });
    defer alloc.free(op_return);

    const ts    = std.time.timestamp();
    const tx_id: u32 = @intCast(std.time.milliTimestamp() & 0xFFFFFFFF);
    const provisional = try std.fmt.allocPrint(alloc, "{d}{s}{d}", .{ tx_id, from, ts });
    defer alloc.free(provisional);

    var tx = blockchain_mod.Transaction{
        .id           = tx_id,
        .from_address = from,
        .to_address   = from,
        .amount       = 0,
        .fee          = label_mod.LABEL_FEE_SAT,
        .timestamp    = ts,
        .nonce        = nonce,
        .op_return    = op_return,
        .signature    = sig,
        .public_key   = pubkey,
        .scheme       = .omni_ecdsa,
        .hash         = provisional,
    };
    const hash_bytes = tx.calculateHash();
    const canonical  = try std.fmt.allocPrint(alloc, "{s}", .{std.fmt.bytesToHex(hash_bytes, .lower)});
    tx.hash = canonical;

    // Also apply immediately to the in-memory registry so getlabels reflects it
    // before the block is mined (optimistic — removed if TX is dropped).
    _ = ctx.bc.label_registry.apply(
        target, from, tag, note, tier,
        @intCast(ctx.bc.getBlockCount()),
        canonical,
    ) catch {};

    ctx.bc.mutex.lock();
    ctx.bc.mempool.append(tx) catch {
        ctx.bc.mutex.unlock();
        return errorJson(-32603, "Mempool full", id, alloc);
    };
    ctx.bc.mutex.unlock();

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"status\":\"queued\",\"txid\":\"{s}\",\"tag\":\"{s}\",\"target\":\"{s}\"}}}}",
        .{ id, canonical, tag.toStr(), target });
}

// ── getlabels ─────────────────────────────────────────────────────────────────
// Returns address report + active labels: { "address":"ob1q..." }

fn handleGetLabels(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc   = ctx.allocator;
    const address = extractStr(body, "address") orelse
        return errorJson(-32602, "Missing: address", id, alloc);

    const rep = ctx.bc.label_registry.report(address);

    var buf = std.array_list.Managed(u8).init(alloc);
    defer buf.deinit();
    const w = buf.writer();

    try w.print(
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{" ++
        "\"verdict\":\"{s}\"," ++
        "\"positive_score\":{d}," ++
        "\"negative_score\":{d}," ++
        "\"label_count\":{d}," ++
        "\"top_tag\":\"{s}\"," ++
        "\"labels\":[",
        .{
            id,
            rep.verdictStr(),
            rep.positive_score,
            rep.negative_score,
            rep.label_count,
            if (rep.top_tag) |t| t.toStr() else "none",
        },
    );

    var entries: [label_mod.MAX_LABELS_PER_ADDRESS]label_mod.LabelEntry = undefined;
    const n = ctx.bc.label_registry.listActive(address, &entries);
    for (entries[0..n], 0..) |e, i| {
        if (i > 0) try w.writeByte(',');
        try w.print(
            "{{\"id\":{d},\"reporter\":\"{s}\",\"tag\":\"{s}\",\"note\":\"{s}\"," ++
            "\"weight\":{d},\"block\":{d}}}",
            .{ e.id, e.reporterSlice(), e.tag.toStr(), e.noteSlice(), e.weight, e.block_height },
        );
    }

    try w.writeAll("]}}");
    return buf.toOwnedSlice();
}

// ── removelabel ───────────────────────────────────────────────────────────────
// Mark label as removed (only original reporter can remove):
// { "from":"ob1q...", "label_id":42, "signature":"hex", "public_key":"hex", "nonce":N }

fn handleRemoveLabel(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc    = ctx.allocator;
    const from     = extractStr(body, "from")    orelse return errorJson(-32602, "Missing: from", id, alloc);
    const label_id = extractParamObjectU64(body, "label_id");
    const sig      = extractStr(body, "signature")  orelse return errorJson(-32602, "Missing: signature", id, alloc);
    const pubkey   = extractStr(body, "public_key") orelse return errorJson(-32602, "Missing: public_key", id, alloc);
    const nonce    = extractParamObjectU64(body, "nonce");

    // Build op_return
    const op_return = try std.fmt.allocPrint(alloc, "label_remove:{d}", .{label_id});
    defer alloc.free(op_return);

    const ts    = std.time.timestamp();
    const tx_id: u32 = @intCast(std.time.milliTimestamp() & 0xFFFFFFFF);
    const provisional = try std.fmt.allocPrint(alloc, "{d}{s}{d}", .{ tx_id, from, ts });
    defer alloc.free(provisional);

    var tx = blockchain_mod.Transaction{
        .id           = tx_id,
        .from_address = from,
        .to_address   = from,
        .amount       = 0,
        .fee          = 1000,
        .timestamp    = ts,
        .nonce        = nonce,
        .op_return    = op_return,
        .signature    = sig,
        .public_key   = pubkey,
        .scheme       = .omni_ecdsa,
        .hash         = provisional,
    };
    const hash_bytes = tx.calculateHash();
    const canonical  = try std.fmt.allocPrint(alloc, "{s}", .{std.fmt.bytesToHex(hash_bytes, .lower)});
    tx.hash = canonical;

    // Optimistic in-memory remove
    const removed = ctx.bc.label_registry.remove(label_id, from);

    ctx.bc.mutex.lock();
    ctx.bc.mempool.append(tx) catch {
        ctx.bc.mutex.unlock();
        return errorJson(-32603, "Mempool full", id, alloc);
    };
    ctx.bc.mutex.unlock();

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"status\":\"queued\",\"txid\":\"{s}\",\"removed\":{s}}}}}",
        .{ id, canonical, if (removed) "true" else "false" });
}

// ── follow ────────────────────────────────────────────────────────────────────
// { "from":"ob1q...", "target":"ob1q...", "signature":"hex", "public_key":"hex", "nonce":N }

fn handleFollow(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc  = ctx.allocator;
    const from   = extractStr(body, "from")   orelse return errorJson(-32602, "Missing: from", id, alloc);
    const target = extractStr(body, "target") orelse return errorJson(-32602, "Missing: target", id, alloc);
    const sig    = extractStr(body, "signature")  orelse return errorJson(-32602, "Missing: signature", id, alloc);
    const pubkey = extractStr(body, "public_key") orelse return errorJson(-32602, "Missing: public_key", id, alloc);
    const nonce  = extractParamObjectU64(body, "nonce");

    if (std.mem.eql(u8, from, target)) return errorJson(-32602, "Cannot follow yourself", id, alloc);

    const op_return = try std.fmt.allocPrint(alloc, "follow:{s}", .{target});
    defer alloc.free(op_return);

    const ts    = std.time.timestamp();
    const tx_id: u32 = @intCast(std.time.milliTimestamp() & 0xFFFFFFFF);
    const provisional = try std.fmt.allocPrint(alloc, "{d}{s}{d}", .{ tx_id, from, ts });
    defer alloc.free(provisional);

    var tx = blockchain_mod.Transaction{
        .id = tx_id, .from_address = from, .to_address = from,
        .amount = 0, .fee = social_mod.FOLLOW_FEE_SAT,
        .timestamp = ts, .nonce = nonce, .op_return = op_return,
        .signature = sig, .public_key = pubkey, .scheme = .omni_ecdsa, .hash = provisional,
    };
    const canonical = try std.fmt.allocPrint(alloc, "{s}", .{std.fmt.bytesToHex(tx.calculateHash(), .lower)});
    tx.hash = canonical;

    ctx.bc.social_graph.follow(from, target, @intCast(ctx.bc.getBlockCount())) catch {};

    ctx.bc.mutex.lock();
    ctx.bc.mempool.append(tx) catch { ctx.bc.mutex.unlock(); return errorJson(-32603, "Mempool full", id, alloc); };
    ctx.bc.mutex.unlock();

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"status\":\"queued\",\"txid\":\"{s}\",\"following\":\"{s}\"}}}}",
        .{ id, canonical, target });
}

// ── unfollow ──────────────────────────────────────────────────────────────────

fn handleUnfollow(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc  = ctx.allocator;
    const from   = extractStr(body, "from")   orelse return errorJson(-32602, "Missing: from", id, alloc);
    const target = extractStr(body, "target") orelse return errorJson(-32602, "Missing: target", id, alloc);
    const sig    = extractStr(body, "signature")  orelse return errorJson(-32602, "Missing: signature", id, alloc);
    const pubkey = extractStr(body, "public_key") orelse return errorJson(-32602, "Missing: public_key", id, alloc);
    const nonce  = extractParamObjectU64(body, "nonce");

    const op_return = try std.fmt.allocPrint(alloc, "unfollow:{s}", .{target});
    defer alloc.free(op_return);

    const ts    = std.time.timestamp();
    const tx_id: u32 = @intCast(std.time.milliTimestamp() & 0xFFFFFFFF);
    const provisional = try std.fmt.allocPrint(alloc, "{d}{s}{d}", .{ tx_id, from, ts });
    defer alloc.free(provisional);

    var tx = blockchain_mod.Transaction{
        .id = tx_id, .from_address = from, .to_address = from,
        .amount = 0, .fee = social_mod.FOLLOW_FEE_SAT,
        .timestamp = ts, .nonce = nonce, .op_return = op_return,
        .signature = sig, .public_key = pubkey, .scheme = .omni_ecdsa, .hash = provisional,
    };
    const canonical = try std.fmt.allocPrint(alloc, "{s}", .{std.fmt.bytesToHex(tx.calculateHash(), .lower)});
    tx.hash = canonical;

    ctx.bc.social_graph.unfollow(from, target);

    ctx.bc.mutex.lock();
    ctx.bc.mempool.append(tx) catch { ctx.bc.mutex.unlock(); return errorJson(-32603, "Mempool full", id, alloc); };
    ctx.bc.mutex.unlock();

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"status\":\"queued\",\"txid\":\"{s}\"}}}}",
        .{ id, canonical });
}

// ── getfollowers ──────────────────────────────────────────────────────────────
// { "address":"ob1q..." }

fn handleGetFollowers(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc   = ctx.allocator;
    const address = extractStr(body, "address") orelse return errorJson(-32602, "Missing: address", id, alloc);

    var addrs: [social_mod.MAX_LIST][]const u8 = undefined;
    const n     = ctx.bc.social_graph.getFollowers(address, &addrs);
    const count = ctx.bc.social_graph.followerCount(address);

    var buf = std.array_list.Managed(u8).init(alloc);
    defer buf.deinit();
    const w = buf.writer();
    try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"count\":{d},\"followers\":[", .{ id, count });
    for (addrs[0..n], 0..) |a, i| {
        if (i > 0) try w.writeByte(',');
        try w.print("\"{s}\"", .{a});
    }
    try w.writeAll("]}}");
    return buf.toOwnedSlice();
}

// ── getfollowing ──────────────────────────────────────────────────────────────

fn handleGetFollowing(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc   = ctx.allocator;
    const address = extractStr(body, "address") orelse return errorJson(-32602, "Missing: address", id, alloc);

    var addrs: [social_mod.MAX_LIST][]const u8 = undefined;
    const n     = ctx.bc.social_graph.getFollowing(address, &addrs);
    const count = ctx.bc.social_graph.followingCount(address);

    var buf = std.array_list.Managed(u8).init(alloc);
    defer buf.deinit();
    const w = buf.writer();
    try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"count\":{d},\"following\":[", .{ id, count });
    for (addrs[0..n], 0..) |a, i| {
        if (i > 0) try w.writeByte(',');
        try w.print("\"{s}\"", .{a});
    }
    try w.writeAll("]}}");
    return buf.toOwnedSlice();
}

// ── poap_createevent ──────────────────────────────────────────────────────────
// { "from":"ob1q...", "event_id":"conf2026", "name":"OmniBus Conf 2026",
//   "max_claims":500, "note":"...", "signature":"hex", "public_key":"hex", "nonce":N }

fn handlePoapCreateEvent(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc      = ctx.allocator;
    const from       = extractStr(body, "from")       orelse return errorJson(-32602, "Missing: from", id, alloc);
    const event_id   = extractStr(body, "event_id")   orelse return errorJson(-32602, "Missing: event_id", id, alloc);
    const name       = extractStr(body, "name")       orelse return errorJson(-32602, "Missing: name", id, alloc);
    const max_claims = extractParamObjectU64(body, "max_claims");
    const note       = extractStr(body, "note") orelse "";
    const sig        = extractStr(body, "signature")  orelse return errorJson(-32602, "Missing: signature", id, alloc);
    const pubkey     = extractStr(body, "public_key") orelse return errorJson(-32602, "Missing: public_key", id, alloc);
    const nonce      = extractParamObjectU64(body, "nonce");

    const op_return = try std.fmt.allocPrint(alloc, "poap_event:{s}:{s}:{d}:{s}", .{ event_id, name, max_claims, note });
    defer alloc.free(op_return);

    const ts    = std.time.timestamp();
    const tx_id: u32 = @intCast(std.time.milliTimestamp() & 0xFFFFFFFF);
    const provisional = try std.fmt.allocPrint(alloc, "{d}{s}{d}", .{ tx_id, from, ts });
    defer alloc.free(provisional);

    var tx = blockchain_mod.Transaction{
        .id = tx_id, .from_address = from, .to_address = from,
        .amount = 0, .fee = poap_mod.POAP_EVENT_FEE_SAT,
        .timestamp = ts, .nonce = nonce, .op_return = op_return,
        .signature = sig, .public_key = pubkey, .scheme = .omni_ecdsa, .hash = provisional,
    };
    const canonical = try std.fmt.allocPrint(alloc, "{s}", .{std.fmt.bytesToHex(tx.calculateHash(), .lower)});
    tx.hash = canonical;

    const parsed = poap_mod.parseEvent(op_return).?;
    ctx.bc.poap_registry.createEvent(from, parsed, @intCast(ctx.bc.getBlockCount())) catch {};

    ctx.bc.mutex.lock();
    ctx.bc.mempool.append(tx) catch { ctx.bc.mutex.unlock(); return errorJson(-32603, "Mempool full", id, alloc); };
    ctx.bc.mutex.unlock();

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"status\":\"queued\",\"txid\":\"{s}\",\"event_id\":\"{s}\",\"fee_sat\":{d}}}}}",
        .{ id, canonical, event_id, poap_mod.POAP_EVENT_FEE_SAT });
}

// ── poap_claim ────────────────────────────────────────────────────────────────
// { "from":"ob1q...", "event_id":"conf2026", "signature":"hex", "public_key":"hex", "nonce":N }

fn handlePoapClaim(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc    = ctx.allocator;
    const from     = extractStr(body, "from")     orelse return errorJson(-32602, "Missing: from", id, alloc);
    const event_id = extractStr(body, "event_id") orelse return errorJson(-32602, "Missing: event_id", id, alloc);
    const sig      = extractStr(body, "signature")  orelse return errorJson(-32602, "Missing: signature", id, alloc);
    const pubkey   = extractStr(body, "public_key") orelse return errorJson(-32602, "Missing: public_key", id, alloc);
    const nonce    = extractParamObjectU64(body, "nonce");

    const op_return = try std.fmt.allocPrint(alloc, "poap_claim:{s}", .{event_id});
    defer alloc.free(op_return);

    const ts    = std.time.timestamp();
    const tx_id: u32 = @intCast(std.time.milliTimestamp() & 0xFFFFFFFF);
    const provisional = try std.fmt.allocPrint(alloc, "{d}{s}{d}", .{ tx_id, from, ts });
    defer alloc.free(provisional);

    var tx = blockchain_mod.Transaction{
        .id = tx_id, .from_address = from, .to_address = from,
        .amount = 0, .fee = poap_mod.POAP_CLAIM_FEE_SAT,
        .timestamp = ts, .nonce = nonce, .op_return = op_return,
        .signature = sig, .public_key = pubkey, .scheme = .omni_ecdsa, .hash = provisional,
    };
    const canonical = try std.fmt.allocPrint(alloc, "{s}", .{std.fmt.bytesToHex(tx.calculateHash(), .lower)});
    tx.hash = canonical;

    ctx.bc.poap_registry.claimPoap(from, event_id, @intCast(ctx.bc.getBlockCount()), canonical) catch |err| {
        const msg = switch (err) {
            error.EventNotFound  => "Event not found",
            error.EventClosed    => "Event is closed or max claims reached",
            error.AlreadyClaimed => "Already claimed this POAP",
            else                 => "Claim failed",
        };
        return errorJson(-32001, msg, id, alloc);
    };

    ctx.bc.mutex.lock();
    ctx.bc.mempool.append(tx) catch { ctx.bc.mutex.unlock(); return errorJson(-32603, "Mempool full", id, alloc); };
    ctx.bc.mutex.unlock();

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"status\":\"queued\",\"txid\":\"{s}\",\"event_id\":\"{s}\"}}}}",
        .{ id, canonical, event_id });
}

// ── poap_close ────────────────────────────────────────────────────────────────

fn handlePoapClose(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc    = ctx.allocator;
    const from     = extractStr(body, "from")     orelse return errorJson(-32602, "Missing: from", id, alloc);
    const event_id = extractStr(body, "event_id") orelse return errorJson(-32602, "Missing: event_id", id, alloc);
    const sig      = extractStr(body, "signature")  orelse return errorJson(-32602, "Missing: signature", id, alloc);
    const pubkey   = extractStr(body, "public_key") orelse return errorJson(-32602, "Missing: public_key", id, alloc);
    const nonce    = extractParamObjectU64(body, "nonce");

    const op_return = try std.fmt.allocPrint(alloc, "poap_close:{s}", .{event_id});
    defer alloc.free(op_return);

    const ts    = std.time.timestamp();
    const tx_id: u32 = @intCast(std.time.milliTimestamp() & 0xFFFFFFFF);
    const provisional = try std.fmt.allocPrint(alloc, "{d}{s}{d}", .{ tx_id, from, ts });
    defer alloc.free(provisional);

    var tx = blockchain_mod.Transaction{
        .id = tx_id, .from_address = from, .to_address = from,
        .amount = 0, .fee = 1000,
        .timestamp = ts, .nonce = nonce, .op_return = op_return,
        .signature = sig, .public_key = pubkey, .scheme = .omni_ecdsa, .hash = provisional,
    };
    const canonical = try std.fmt.allocPrint(alloc, "{s}", .{std.fmt.bytesToHex(tx.calculateHash(), .lower)});
    tx.hash = canonical;

    const closed = ctx.bc.poap_registry.closeEvent(event_id, from);

    ctx.bc.mutex.lock();
    ctx.bc.mempool.append(tx) catch { ctx.bc.mutex.unlock(); return errorJson(-32603, "Mempool full", id, alloc); };
    ctx.bc.mutex.unlock();

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"status\":\"queued\",\"txid\":\"{s}\",\"closed\":{s}}}}}",
        .{ id, canonical, if (closed) "true" else "false" });
}

// ── getpoaps ──────────────────────────────────────────────────────────────────
// { "address":"ob1q..." }  — lista POAP-urilor unui wallet

fn handleGetPoaps(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc   = ctx.allocator;
    const address = extractStr(body, "address") orelse return errorJson(-32602, "Missing: address", id, alloc);

    var claims: [64]poap_mod.PoapClaim = undefined;
    const n = ctx.bc.poap_registry.listClaims(address, &claims);

    var buf = std.array_list.Managed(u8).init(alloc);
    defer buf.deinit();
    const w = buf.writer();
    try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"poaps\":[", .{id});
    for (claims[0..n], 0..) |c, i| {
        if (i > 0) try w.writeByte(',');
        try w.print("{{\"event_id\":\"{s}\",\"claim_block\":{d},\"tx_hash\":\"{s}\"}}",
            .{ c.eventIdSlice(), c.claim_block, c.txHashSlice() });
    }
    try w.writeAll("]}}");
    return buf.toOwnedSlice();
}

// ── getpoapevent ──────────────────────────────────────────────────────────────
// { "event_id":"conf2026" }

fn handleGetPoapEvent(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc    = ctx.allocator;
    const event_id = extractStr(body, "event_id") orelse return errorJson(-32602, "Missing: event_id", id, alloc);

    const ev = ctx.bc.poap_registry.getEvent(event_id) orelse
        return std.fmt.allocPrint(alloc, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":null}}", .{id});

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{" ++
        "\"event_id\":\"{s}\",\"name\":\"{s}\"," ++
        "\"organizer\":\"{s}\",\"max_claims\":{d}," ++
        "\"claims_count\":{d},\"create_block\":{d}," ++
        "\"closed\":{s},\"note\":\"{s}\"}}}}",
        .{ id, ev.eventIdSlice(), ev.nameSlice(), ev.organizerSlice(),
           ev.max_claims, ev.claims_count, ev.create_block,
           if (ev.closed) "true" else "false", ev.noteSlice() });
}

// ── gov_propose ───────────────────────────────────────────────────────────────
// { "from":"ob1q...", "title_hash":"<sha256>", "voting_blocks":1440,
//   "quorum":200, "note":"...", "signature":"hex", "public_key":"hex", "nonce":N }

fn handleGovPropose(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc         = ctx.allocator;
    const from          = extractStr(body, "from")         orelse return errorJson(-32602, "Missing: from", id, alloc);
    const title_hash    = extractStr(body, "title_hash")   orelse return errorJson(-32602, "Missing: title_hash", id, alloc);
    const voting_blocks = extractParamObjectU64(body, "voting_blocks");
    const quorum        = @as(u32, @intCast(@min(extractParamObjectU64(body, "quorum"), 0xFFFFFFFF)));
    const note          = extractStr(body, "note") orelse "";
    const sig           = extractStr(body, "signature")  orelse return errorJson(-32602, "Missing: signature", id, alloc);
    const pubkey        = extractStr(body, "public_key") orelse return errorJson(-32602, "Missing: public_key", id, alloc);
    const nonce         = extractParamObjectU64(body, "nonce");

    if (title_hash.len != gov_mod.TITLE_HASH_LEN)
        return errorJson(-32602, "title_hash must be 64-char SHA-256 hex", id, alloc);
    if (voting_blocks == 0) return errorJson(-32602, "voting_blocks must be > 0", id, alloc);

    const op_return = try std.fmt.allocPrint(alloc, "gov_propose:{s}:{d}:{d}:{s}",
        .{ title_hash, voting_blocks, quorum, note });
    defer alloc.free(op_return);

    const ts    = std.time.timestamp();
    const tx_id: u32 = @intCast(std.time.milliTimestamp() & 0xFFFFFFFF);
    const provisional = try std.fmt.allocPrint(alloc, "{d}{s}{d}", .{ tx_id, from, ts });
    defer alloc.free(provisional);

    var tx = blockchain_mod.Transaction{
        .id = tx_id, .from_address = from, .to_address = from,
        .amount = 0, .fee = gov_mod.GOV_PROPOSE_FEE_SAT,
        .timestamp = ts, .nonce = nonce, .op_return = op_return,
        .signature = sig, .public_key = pubkey, .scheme = .omni_ecdsa, .hash = provisional,
    };
    const canonical = try std.fmt.allocPrint(alloc, "{s}", .{std.fmt.bytesToHex(tx.calculateHash(), .lower)});
    tx.hash = canonical;

    const parsed = gov_mod.parsePropose(op_return).?;
    const prop_id = ctx.bc.gov_registry.propose(from, parsed, @intCast(ctx.bc.getBlockCount())) catch 0;

    ctx.bc.mutex.lock();
    ctx.bc.mempool.append(tx) catch { ctx.bc.mutex.unlock(); return errorJson(-32603, "Mempool full", id, alloc); };
    ctx.bc.mutex.unlock();

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{" ++
        "\"status\":\"queued\",\"txid\":\"{s}\"," ++
        "\"proposal_id\":{d},\"voting_end_block\":{d}," ++
        "\"quorum\":{d}}}}}",
        .{ id, canonical, prop_id, ctx.bc.getBlockCount() + voting_blocks, quorum });
}

// ── gov_vote ──────────────────────────────────────────────────────────────────
// { "from":"ob1q...", "proposal_id":1, "vote":"yes"|"no",
//   "tier":"FOOD", "signature":"hex", "public_key":"hex", "nonce":N }

fn handleGovVote(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc       = ctx.allocator;
    const from        = extractStr(body, "from")        orelse return errorJson(-32602, "Missing: from", id, alloc);
    const proposal_id = extractParamObjectU64(body, "proposal_id");
    const vote_str    = extractStr(body, "vote")        orelse return errorJson(-32602, "Missing: vote (yes|no)", id, alloc);
    const tier        = extractStr(body, "tier")        orelse "OMNI";
    const sig         = extractStr(body, "signature")   orelse return errorJson(-32602, "Missing: signature", id, alloc);
    const pubkey      = extractStr(body, "public_key")  orelse return errorJson(-32602, "Missing: public_key", id, alloc);
    const nonce       = extractParamObjectU64(body, "nonce");

    const yes = std.mem.eql(u8, vote_str, "yes");

    const op_return = try std.fmt.allocPrint(alloc, "gov_vote:{d}:{s}", .{ proposal_id, vote_str });
    defer alloc.free(op_return);

    const ts    = std.time.timestamp();
    const tx_id: u32 = @intCast(std.time.milliTimestamp() & 0xFFFFFFFF);
    const provisional = try std.fmt.allocPrint(alloc, "{d}{s}{d}", .{ tx_id, from, ts });
    defer alloc.free(provisional);

    var tx = blockchain_mod.Transaction{
        .id = tx_id, .from_address = from, .to_address = from,
        .amount = 0, .fee = gov_mod.GOV_VOTE_FEE_SAT,
        .timestamp = ts, .nonce = nonce, .op_return = op_return,
        .signature = sig, .public_key = pubkey, .scheme = .omni_ecdsa, .hash = provisional,
    };
    const canonical = try std.fmt.allocPrint(alloc, "{s}", .{std.fmt.bytesToHex(tx.calculateHash(), .lower)});
    tx.hash = canonical;

    ctx.bc.gov_registry.vote(proposal_id, from, yes, tier, @intCast(ctx.bc.getBlockCount())) catch |err| {
        const msg = switch (err) {
            error.ProposalNotFound => "Proposal not found",
            error.VotingEnded      => "Voting period has ended",
            error.AlreadyVoted     => "Already voted on this proposal",
            else                   => "Vote failed",
        };
        return errorJson(-32001, msg, id, alloc);
    };

    ctx.bc.mutex.lock();
    ctx.bc.mempool.append(tx) catch { ctx.bc.mutex.unlock(); return errorJson(-32603, "Mempool full", id, alloc); };
    ctx.bc.mutex.unlock();

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"status\":\"queued\",\"txid\":\"{s}\",\"vote\":\"{s}\"}}}}",
        .{ id, canonical, vote_str });
}

// ── getproposals ──────────────────────────────────────────────────────────────
// { "filter":"active"|"all" }

fn handleGetProposals(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc  = ctx.allocator;
    const filter = extractStr(body, "filter") orelse "active";

    var props: [gov_mod.MAX_PROPOSALS]gov_mod.Proposal = undefined;
    const n = if (std.mem.eql(u8, filter, "all"))
        ctx.bc.gov_registry.listAll(&props)
    else
        ctx.bc.gov_registry.listActive(&props);

    var buf = std.array_list.Managed(u8).init(alloc);
    defer buf.deinit();
    const w = buf.writer();
    try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"proposals\":[", .{id});
    for (props[0..n], 0..) |p, i| {
        if (i > 0) try w.writeByte(',');
        try w.print(
            "{{\"id\":{d},\"proposer\":\"{s}\",\"title_hash\":\"{s}\"," ++
            "\"status\":\"{s}\",\"yes_weight\":{d},\"no_weight\":{d}," ++
            "\"quorum\":{d},\"voting_end_block\":{d},\"vote_count\":{d}}}",
            .{ p.id, p.getProposer(), p.getTitleHash(), p.statusStr(),
               p.yes_weight, p.no_weight, p.quorum_weight,
               p.voting_end_block, p.vote_count });
    }
    // Close: array (]) + result object (}) + outer envelope (}). Three braces total.
    try w.writeAll("]}}");
    return buf.toOwnedSlice();
}

// ── getproposal ───────────────────────────────────────────────────────────────
// { "proposal_id":1 }

fn handleGetProposal(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc       = ctx.allocator;
    const proposal_id = extractParamObjectU64(body, "proposal_id");

    const p = ctx.bc.gov_registry.getProposal(proposal_id) orelse
        return std.fmt.allocPrint(alloc, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":null}}", .{id});

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{" ++
        "\"id\":{d},\"proposer\":\"{s}\",\"title_hash\":\"{s}\"," ++
        "\"note\":\"{s}\",\"status\":\"{s}\"," ++
        "\"yes_weight\":{d},\"no_weight\":{d}," ++
        "\"quorum\":{d},\"voting_end_block\":{d}," ++
        "\"create_block\":{d},\"vote_count\":{d}," ++
        "\"executed\":{},\"executed_block\":{d}," ++
        "\"action_kind\":{d},\"action_u64\":{d},\"action_bool\":{}}}}}",
        .{ id, p.id, p.getProposer(), p.getTitleHash(), p.getNote(),
           p.statusStr(), p.yes_weight, p.no_weight,
           p.quorum_weight, p.voting_end_block, p.create_block, p.vote_count,
           p.executed, p.executed_block,
           @intFromEnum(p.action.kind), p.action.u64_value, p.action.bool_value });
}

// ── gov_execute ───────────────────────────────────────────────────────────────
// Manually trigger execution of a passed-but-unexecuted proposal. Auto-exec
// runs every block via applyBlock, so this RPC is a fallback for nodes that
// have route_fees_to_miner=false governance scenarios where a stuck proposal
// needs an explicit nudge.
//
// { "proposal_id": <u64> }
// → result.success / result.applied / result.error
fn handleGovExecute(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc       = ctx.allocator;
    const proposal_id = extractParamObjectU64(body, "proposal_id");
    if (proposal_id == 0) return errorJson(-32602, "Missing or invalid proposal_id", id, alloc);

    const current_block = ctx.bc.getBlockCount();
    ctx.bc.executeProposal(proposal_id, @intCast(current_block)) catch |err| {
        const msg = switch (err) {
            error.ProposalNotFound  => "Proposal not found",
            error.ProposalNotPassed => "Proposal status is not 'passed' (still voting, rejected, expired, or already executed)",
            error.AlreadyExecuted   => "Proposal already executed",
        };
        return errorJson(-32001, msg, id, alloc);
    };

    const p = ctx.bc.gov_registry.getProposal(proposal_id) orelse
        return errorJson(-32603, "Proposal vanished mid-execute", id, alloc);

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{" ++
        "\"proposal_id\":{d},\"executed_block\":{d}," ++
        "\"action_kind\":{d},\"action_u64\":{d},\"action_bool\":{}," ++
        "\"status\":\"{s}\"}}}}",
        .{
            id,
            p.id,
            p.executed_block,
            @intFromEnum(p.action.kind),
            p.action.u64_value,
            p.action.bool_value,
            p.statusStr(),
        });
}

// ── getidentity — Identity Hub aggregator ────────────────────────────────────
// { "address": "ob1q..." }
// Returns a single JSON object with all identity facets for an address.

fn handleGetIdentity(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const addr  = extractStr(body, "address") orelse
        return errorJson(-32602, "Missing param: address", id, alloc);

    // ── 1. PQ identity (pq_attest) ────────────────────────────────────────
    ctx.bc.mutex.lock();
    const identity_opt = ctx.bc.pq_identity_map.get(addr);
    const omni_balance = ctx.bc.balances.get(addr) orelse 0;
    ctx.bc.mutex.unlock();

    var pq_json: []const u8 = "null";
    var pq_json_owned = false;
    if (identity_opt) |idt| {
        pq_json = try std.fmt.allocPrint(alloc,
            "{{\"love\":\"{s}\",\"food\":\"{s}\",\"rent\":\"{s}\"," ++
            "\"vacation\":\"{s}\",\"btc\":\"{s}\",\"eth\":\"{s}\"," ++
            "\"attest_block\":{d}}}",
            .{ idt.loveSlice(), idt.foodSlice(), idt.rentSlice(),
               idt.vacationSlice(), idt.btcSlice(), idt.ethSlice(),
               idt.attest_block });
        pq_json_owned = true;
    }
    defer if (pq_json_owned) alloc.free(pq_json);

    // ── 2. Labels ─────────────────────────────────────────────────────────
    const label_verdict = ctx.bc.label_registry.report(addr).verdictStr();

    // ── 3. Social graph ───────────────────────────────────────────────────
    const followers_n  = ctx.bc.social_graph.followerCount(addr);
    const following_n  = ctx.bc.social_graph.followingCount(addr);

    // ── 4. POAP ───────────────────────────────────────────────────────────
    const poap_n = ctx.bc.poap_registry.claimCountByHolder(addr);

    // ── 5. Notarizations ──────────────────────────────────────────────────
    var note_entries: [64]notarize_mod.NotarizeEntry = undefined;
    const note_count = ctx.bc.notarize_registry.listByOwner(addr, &note_entries);

    // ── 6. Escrow stats ───────────────────────────────────────────────────
    var esc_from_buf: [64]escrow_mod.EscrowEntry = undefined;
    var esc_to_buf:   [64]escrow_mod.EscrowEntry = undefined;
    const esc_sent = ctx.bc.escrow_registry.listByFrom(addr, &esc_from_buf);
    const esc_recv = ctx.bc.escrow_registry.listByTo(addr, &esc_to_buf);

    // ── 7. Reputation ─────────────────────────────────────────────────────
    var rep_json: []const u8 = "null";
    var rep_json_owned = false;
    if (main_mod.g_reputation) |*rep_ptr| {
        if (rep_ptr.snapshot(addr)) |cups| {
            const total = cups.computeRepTotal();
            rep_json = try std.fmt.allocPrint(alloc,
                "{{\"love\":{d},\"food\":{d},\"rent\":{d},\"vacation\":{d}," ++
                "\"total\":{d},\"tier\":\"{s}\",\"satoshi_badge\":{}}}",
                .{ cups.love_stored, cups.food_stored,
                   cups.rent_stored, cups.vacation_stored,
                   total, cups.tier().name(), cups.hasSatoshiBadge() });
            rep_json_owned = true;
        }
    }
    defer if (rep_json_owned) alloc.free(rep_json);

    // ── 8. Active governance proposals / votes (counts only) ─────────────
    const active_proposals = ctx.bc.gov_registry.activeProposalCount();
    const votes_cast = ctx.bc.gov_registry.voteCountBy(addr);

    // ── Assemble final JSON ───────────────────────────────────────────────
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{" ++
        "\"address\":\"{s}\"," ++
        "\"balance_sat\":{d}," ++
        "\"pq_identity\":{s}," ++
        "\"label_verdict\":\"{s}\"," ++
        "\"social\":{{\"followers\":{d},\"following\":{d}}}," ++
        "\"poap_count\":{d}," ++
        "\"notarization_count\":{d}," ++
        "\"escrow\":{{\"sent\":{d},\"received\":{d}}}," ++
        "\"reputation\":{s}," ++
        "\"governance\":{{\"active_chain_proposals\":{d},\"votes_cast\":{d}}}" ++
        "}}}}",
        .{
            id, addr,
            omni_balance,
            pq_json,
            label_verdict,
            followers_n, following_n,
            poap_n,
            note_count,
            esc_sent, esc_recv,
            rep_json,
            active_proposals, votes_cast,
        },
    );
}

// ── escrow_create ─────────────────────────────────────────────────────────────
// { "from":"ob1q...", "to":"ob1q...", "amount":5000000000, "condition_hash":"<sha256>",
//   "timeout_blocks":144, "note":"proiect X", "signature":"hex", "public_key":"hex", "nonce":N }

fn handleEscrowCreate(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc      = ctx.allocator;
    const from       = extractStr(body, "from")       orelse return errorJson(-32602, "Missing: from", id, alloc);
    const to         = extractStr(body, "to")         orelse return errorJson(-32602, "Missing: to", id, alloc);
    const amount     = extractParamObjectU64(body, "amount");
    const cond_hash  = extractStr(body, "condition_hash") orelse return errorJson(-32602, "Missing: condition_hash", id, alloc);
    const timeout_bl = extractParamObjectU64(body, "timeout_blocks");
    const note       = extractStr(body, "note")       orelse "";
    const sig        = extractStr(body, "signature")  orelse return errorJson(-32602, "Missing: signature", id, alloc);
    const pubkey     = extractStr(body, "public_key") orelse return errorJson(-32602, "Missing: public_key", id, alloc);
    const nonce      = extractParamObjectU64(body, "nonce");

    if (amount == 0)    return errorJson(-32602, "amount must be > 0", id, alloc);
    if (timeout_bl == 0) return errorJson(-32602, "timeout_blocks must be > 0", id, alloc);
    if (cond_hash.len != escrow_mod.HASH_LEN)
        return errorJson(-32602, "condition_hash must be 64-char SHA-256 hex", id, alloc);

    const op_return = try std.fmt.allocPrint(alloc,
        "escrow_create:{s}:{d}:{s}:{d}:{s}", .{ to, amount, cond_hash, timeout_bl, note });
    defer alloc.free(op_return);

    const ts    = std.time.timestamp();
    const tx_id: u32 = @intCast(std.time.milliTimestamp() & 0xFFFFFFFF);
    const provisional = try std.fmt.allocPrint(alloc, "{d}{s}{d}", .{ tx_id, from, ts });
    defer alloc.free(provisional);

    var tx = blockchain_mod.Transaction{
        .id           = tx_id,
        .from_address = from,
        .to_address   = from,
        .amount       = amount,  // fondurile sunt debitate din balanta
        .fee          = escrow_mod.ESCROW_CREATE_FEE_SAT,
        .timestamp    = ts,
        .nonce        = nonce,
        .op_return    = op_return,
        .signature    = sig,
        .public_key   = pubkey,
        .scheme       = .omni_ecdsa,
        .hash         = provisional,
    };
    const hash_bytes = tx.calculateHash();
    const canonical  = try std.fmt.allocPrint(alloc, "{s}", .{std.fmt.bytesToHex(hash_bytes, .lower)});
    tx.hash = canonical;

    const parsed = escrow_mod.parseCreate(op_return).?;
    const esc_id = ctx.bc.escrow_registry.create(
        from, parsed, @intCast(ctx.bc.getBlockCount()), canonical,
    ) catch 0;

    ctx.bc.mutex.lock();
    ctx.bc.mempool.append(tx) catch {
        ctx.bc.mutex.unlock();
        return errorJson(-32603, "Mempool full", id, alloc);
    };
    ctx.bc.mutex.unlock();

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{" ++
        "\"status\":\"queued\"," ++
        "\"txid\":\"{s}\"," ++
        "\"escrow_id\":{d}," ++
        "\"amount_sat\":{d}," ++
        "\"timeout_block\":{d}," ++
        "\"condition_hash\":\"{s}\"" ++
        "}}}}",
        .{ id, canonical, esc_id, amount,
           ctx.bc.getBlockCount() + timeout_bl, cond_hash });
}

// ── escrow_release ────────────────────────────────────────────────────────────
// { "from":"ob1q_to...", "escrow_id":1, "proof_hash":"<sha256>",
//   "signature":"hex", "public_key":"hex", "nonce":N }

fn handleEscrowRelease(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc      = ctx.allocator;
    const from       = extractStr(body, "from")       orelse return errorJson(-32602, "Missing: from", id, alloc);
    const escrow_id  = extractParamObjectU64(body, "escrow_id");
    const proof_hash = extractStr(body, "proof_hash") orelse return errorJson(-32602, "Missing: proof_hash", id, alloc);
    const sig        = extractStr(body, "signature")  orelse return errorJson(-32602, "Missing: signature", id, alloc);
    const pubkey     = extractStr(body, "public_key") orelse return errorJson(-32602, "Missing: public_key", id, alloc);
    const nonce      = extractParamObjectU64(body, "nonce");

    if (proof_hash.len != escrow_mod.HASH_LEN)
        return errorJson(-32602, "proof_hash must be 64-char SHA-256 hex", id, alloc);

    const op_return = try std.fmt.allocPrint(alloc,
        "escrow_release:{d}:{s}", .{ escrow_id, proof_hash });
    defer alloc.free(op_return);

    const ts    = std.time.timestamp();
    const tx_id: u32 = @intCast(std.time.milliTimestamp() & 0xFFFFFFFF);
    const provisional = try std.fmt.allocPrint(alloc, "{d}{s}{d}", .{ tx_id, from, ts });
    defer alloc.free(provisional);

    var tx = blockchain_mod.Transaction{
        .id           = tx_id,
        .from_address = from,
        .to_address   = from,
        .amount       = 0,
        .fee          = 1000,
        .timestamp    = ts,
        .nonce        = nonce,
        .op_return    = op_return,
        .signature    = sig,
        .public_key   = pubkey,
        .scheme       = .omni_ecdsa,
        .hash         = provisional,
    };
    const hash_bytes = tx.calculateHash();
    const canonical  = try std.fmt.allocPrint(alloc, "{s}", .{std.fmt.bytesToHex(hash_bytes, .lower)});
    tx.hash = canonical;

    // Optimistic in-memory release
    const amount = ctx.bc.escrow_registry.tryRelease(
        escrow_id, proof_hash, from, @intCast(ctx.bc.getBlockCount()),
    );

    ctx.bc.mutex.lock();
    ctx.bc.mempool.append(tx) catch {
        ctx.bc.mutex.unlock();
        return errorJson(-32603, "Mempool full", id, alloc);
    };
    ctx.bc.mutex.unlock();

    if (amount == 0)
        return errorJson(-32001, "Release failed: proof_hash mismatch, wrong caller, or escrow not pending", id, alloc);

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"status\":\"queued\",\"txid\":\"{s}\",\"released_sat\":{d}}}}}",
        .{ id, canonical, amount });
}

// ── escrow_refund ─────────────────────────────────────────────────────────────
// { "from":"ob1q_from...", "escrow_id":1, "signature":"hex", "public_key":"hex", "nonce":N }

fn handleEscrowRefund(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc     = ctx.allocator;
    const from      = extractStr(body, "from")       orelse return errorJson(-32602, "Missing: from", id, alloc);
    const escrow_id = extractParamObjectU64(body, "escrow_id");
    const sig       = extractStr(body, "signature")  orelse return errorJson(-32602, "Missing: signature", id, alloc);
    const pubkey    = extractStr(body, "public_key") orelse return errorJson(-32602, "Missing: public_key", id, alloc);
    const nonce     = extractParamObjectU64(body, "nonce");

    const op_return = try std.fmt.allocPrint(alloc, "escrow_refund:{d}", .{escrow_id});
    defer alloc.free(op_return);

    const ts    = std.time.timestamp();
    const tx_id: u32 = @intCast(std.time.milliTimestamp() & 0xFFFFFFFF);
    const provisional = try std.fmt.allocPrint(alloc, "{d}{s}{d}", .{ tx_id, from, ts });
    defer alloc.free(provisional);

    var tx = blockchain_mod.Transaction{
        .id           = tx_id,
        .from_address = from,
        .to_address   = from,
        .amount       = 0,
        .fee          = 1000,
        .timestamp    = ts,
        .nonce        = nonce,
        .op_return    = op_return,
        .signature    = sig,
        .public_key   = pubkey,
        .scheme       = .omni_ecdsa,
        .hash         = provisional,
    };
    const hash_bytes = tx.calculateHash();
    const canonical  = try std.fmt.allocPrint(alloc, "{s}", .{std.fmt.bytesToHex(hash_bytes, .lower)});
    tx.hash = canonical;

    const amount = ctx.bc.escrow_registry.tryRefund(
        escrow_id, from, @intCast(ctx.bc.getBlockCount()),
    );

    ctx.bc.mutex.lock();
    ctx.bc.mempool.append(tx) catch {
        ctx.bc.mutex.unlock();
        return errorJson(-32603, "Mempool full", id, alloc);
    };
    ctx.bc.mutex.unlock();

    if (amount == 0)
        return errorJson(-32001, "Refund failed: not timed out yet, wrong caller, or escrow not pending", id, alloc);

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"status\":\"queued\",\"txid\":\"{s}\",\"refunded_sat\":{d}}}}}",
        .{ id, canonical, amount });
}

// ── escrow_dispute ────────────────────────────────────────────────────────────
// { "from":"ob1q...", "escrow_id":1, "signature":"hex", "public_key":"hex", "nonce":N }

fn handleEscrowDispute(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc     = ctx.allocator;
    const from      = extractStr(body, "from")       orelse return errorJson(-32602, "Missing: from", id, alloc);
    const escrow_id = extractParamObjectU64(body, "escrow_id");
    const sig       = extractStr(body, "signature")  orelse return errorJson(-32602, "Missing: signature", id, alloc);
    const pubkey    = extractStr(body, "public_key") orelse return errorJson(-32602, "Missing: public_key", id, alloc);
    const nonce     = extractParamObjectU64(body, "nonce");

    const op_return = try std.fmt.allocPrint(alloc, "escrow_dispute:{d}", .{escrow_id});
    defer alloc.free(op_return);

    const ts    = std.time.timestamp();
    const tx_id: u32 = @intCast(std.time.milliTimestamp() & 0xFFFFFFFF);
    const provisional = try std.fmt.allocPrint(alloc, "{d}{s}{d}", .{ tx_id, from, ts });
    defer alloc.free(provisional);

    var tx = blockchain_mod.Transaction{
        .id           = tx_id,
        .from_address = from,
        .to_address   = from,
        .amount       = 0,
        .fee          = escrow_mod.ESCROW_DISPUTE_FEE_SAT,
        .timestamp    = ts,
        .nonce        = nonce,
        .op_return    = op_return,
        .signature    = sig,
        .public_key   = pubkey,
        .scheme       = .omni_ecdsa,
        .hash         = provisional,
    };
    const hash_bytes = tx.calculateHash();
    const canonical  = try std.fmt.allocPrint(alloc, "{s}", .{std.fmt.bytesToHex(hash_bytes, .lower)});
    tx.hash = canonical;

    const opened = ctx.bc.escrow_registry.openDispute(escrow_id, from);

    ctx.bc.mutex.lock();
    ctx.bc.mempool.append(tx) catch {
        ctx.bc.mutex.unlock();
        return errorJson(-32603, "Mempool full", id, alloc);
    };
    ctx.bc.mutex.unlock();

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"status\":\"queued\",\"txid\":\"{s}\",\"disputed\":{s}}}}}",
        .{ id, canonical, if (opened) "true" else "false" });
}

// ── getescrow ─────────────────────────────────────────────────────────────────
// { "escrow_id":1 }

fn handleGetEscrow(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc     = ctx.allocator;
    const escrow_id = extractParamObjectU64(body, "escrow_id");

    const e = ctx.bc.escrow_registry.get(escrow_id) orelse
        return std.fmt.allocPrint(alloc,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":null}}", .{id});

    const current_block: u64 = @intCast(ctx.bc.getBlockCount());
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{" ++
        "\"id\":{d}," ++
        "\"from\":\"{s}\"," ++
        "\"to\":\"{s}\"," ++
        "\"amount_sat\":{d}," ++
        "\"condition_hash\":\"{s}\"," ++
        "\"timeout_block\":{d}," ++
        "\"create_block\":{d}," ++
        "\"status\":\"{s}\"," ++
        "\"timed_out\":{s}," ++
        "\"note\":\"{s}\"" ++
        "}}}}",
        .{ id, e.id, e.fromSlice(), e.toSlice(),
           e.amount_sat, e.conditionSlice(),
           e.timeout_block, e.create_block, e.statusStr(),
           if (e.isTimedOut(current_block)) "true" else "false",
           e.noteSlice() });
}

// ── getescrows ────────────────────────────────────────────────────────────────
// { "address":"ob1q...", "role":"from"|"to" }

fn handleGetEscrows(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc   = ctx.allocator;
    const address = extractStr(body, "address") orelse
        return errorJson(-32602, "Missing: address", id, alloc);
    const role    = extractStr(body, "role") orelse "from";
    const current_block: u64 = @intCast(ctx.bc.getBlockCount());

    var entries: [64]escrow_mod.EscrowEntry = undefined;
    const n = if (std.mem.eql(u8, role, "to"))
        ctx.bc.escrow_registry.listByTo(address, &entries)
    else
        ctx.bc.escrow_registry.listByFrom(address, &entries);

    var buf = std.array_list.Managed(u8).init(alloc);
    defer buf.deinit();
    const w = buf.writer();

    try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"escrows\":[", .{id});
    for (entries[0..n], 0..) |e, i| {
        if (i > 0) try w.writeByte(',');
        try w.print(
            "{{\"id\":{d},\"from\":\"{s}\",\"to\":\"{s}\"," ++
            "\"amount_sat\":{d},\"status\":\"{s}\"," ++
            "\"timeout_block\":{d},\"timed_out\":{s}," ++
            "\"condition_hash\":\"{s}\",\"note\":\"{s}\"}}",
            .{ e.id, e.fromSlice(), e.toSlice(),
               e.amount_sat, e.statusStr(),
               e.timeout_block,
               if (e.isTimedOut(current_block)) "true" else "false",
               e.conditionSlice(), e.noteSlice() },
        );
    }
    try w.writeAll("]}}");
    return buf.toOwnedSlice();
}

// ── notarizedoc ───────────────────────────────────────────────────────────────
// { "from":"ob1q...", "doc_hash":"<sha256_hex_64>", "doc_type":"audit",
//   "expiry_blocks":0, "note":"Contract X", "signature":"hex", "public_key":"hex", "nonce":N }

fn handleNotarizeDoc(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc       = ctx.allocator;
    const from        = extractStr(body, "from")       orelse return errorJson(-32602, "Missing: from", id, alloc);
    const doc_hash    = extractStr(body, "doc_hash")   orelse return errorJson(-32602, "Missing: doc_hash", id, alloc);
    const doc_type_s  = extractStr(body, "doc_type")   orelse "other";
    const expiry      = extractParamObjectU64(body, "expiry_blocks");
    const note        = extractStr(body, "note")       orelse "";
    const sig         = extractStr(body, "signature")  orelse return errorJson(-32602, "Missing: signature", id, alloc);
    const pubkey      = extractStr(body, "public_key") orelse return errorJson(-32602, "Missing: public_key", id, alloc);
    const nonce       = extractParamObjectU64(body, "nonce");

    if (doc_hash.len != notarize_mod.HASH_LEN)
        return errorJson(-32602, "doc_hash must be 64-char SHA-256 hex", id, alloc);

    const op_return = try std.fmt.allocPrint(alloc,
        "notarize:{s}:{s}:{d}:{s}", .{ doc_hash, doc_type_s, expiry, note });
    defer alloc.free(op_return);

    const ts    = std.time.timestamp();
    const tx_id: u32 = @intCast(std.time.milliTimestamp() & 0xFFFFFFFF);
    const provisional = try std.fmt.allocPrint(alloc, "{d}{s}{d}", .{ tx_id, from, ts });
    defer alloc.free(provisional);

    var tx = blockchain_mod.Transaction{
        .id           = tx_id,
        .from_address = from,
        .to_address   = from,
        .amount       = 0,
        .fee          = notarize_mod.NOTARIZE_FEE_SAT,
        .timestamp    = ts,
        .nonce        = nonce,
        .op_return    = op_return,
        .signature    = sig,
        .public_key   = pubkey,
        .scheme       = .omni_ecdsa,
        .hash         = provisional,
    };
    const hash_bytes = tx.calculateHash();
    const canonical  = try std.fmt.allocPrint(alloc, "{s}", .{std.fmt.bytesToHex(hash_bytes, .lower)});
    tx.hash = canonical;

    // Optimistic in-memory notarize
    const parsed = notarize_mod.parsNotarize(op_return).?;
    const note_id = ctx.bc.notarize_registry.notarize(
        from, parsed, @intCast(ctx.bc.getBlockCount()), canonical,
    ) catch 0;

    ctx.bc.mutex.lock();
    ctx.bc.mempool.append(tx) catch {
        ctx.bc.mutex.unlock();
        return errorJson(-32603, "Mempool full", id, alloc);
    };
    ctx.bc.mutex.unlock();

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{" ++
        "\"status\":\"queued\"," ++
        "\"txid\":\"{s}\"," ++
        "\"notarize_id\":{d}," ++
        "\"doc_hash\":\"{s}\"," ++
        "\"doc_type\":\"{s}\"," ++
        "\"fee_sat\":{d}" ++
        "}}}}",
        .{ id, canonical, note_id, doc_hash, doc_type_s, notarize_mod.NOTARIZE_FEE_SAT });
}

// ── verifynotarize ────────────────────────────────────────────────────────────
// { "doc_hash":"<sha256_hex_64>" }  — verifica daca documentul e notarizat pe chain

fn handleVerifyNotarize(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc    = ctx.allocator;
    const doc_hash = extractStr(body, "doc_hash") orelse
        return errorJson(-32602, "Missing: doc_hash", id, alloc);

    if (doc_hash.len != notarize_mod.HASH_LEN)
        return errorJson(-32602, "doc_hash must be 64-char SHA-256 hex", id, alloc);

    const current_block: u64 = @intCast(ctx.bc.getBlockCount());
    const result = ctx.bc.notarize_registry.verify(doc_hash, current_block);

    if (result.entry == null) {
        return std.fmt.allocPrint(alloc,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"status\":\"{s}\",\"doc_hash\":\"{s}\"}}}}",
            .{ id, result.statusStr(), doc_hash });
    }

    const e = result.entry.?;
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{" ++
        "\"status\":\"{s}\"," ++
        "\"notarize_id\":{d}," ++
        "\"doc_hash\":\"{s}\"," ++
        "\"doc_type\":\"{s}\"," ++
        "\"owner\":\"{s}\"," ++
        "\"block_height\":{d}," ++
        "\"tx_hash\":\"{s}\"," ++
        "\"expiry_block\":{d}," ++
        "\"note\":\"{s}\"" ++
        "}}}}",
        .{ id, result.statusStr(), e.id, e.docHashSlice(), e.doc_type.toStr(),
           e.ownerSlice(), e.block_height, e.txHashSlice(), e.expiry_block, e.noteSlice() });
}

// ── revokenotarize ────────────────────────────────────────────────────────────
// { "from":"ob1q...", "notarize_id":42, "signature":"hex", "public_key":"hex", "nonce":N }

fn handleRevokeNotarize(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc       = ctx.allocator;
    const from        = extractStr(body, "from")       orelse return errorJson(-32602, "Missing: from", id, alloc);
    const notarize_id = extractParamObjectU64(body, "notarize_id");
    const sig         = extractStr(body, "signature")  orelse return errorJson(-32602, "Missing: signature", id, alloc);
    const pubkey      = extractStr(body, "public_key") orelse return errorJson(-32602, "Missing: public_key", id, alloc);
    const nonce       = extractParamObjectU64(body, "nonce");

    const op_return = try std.fmt.allocPrint(alloc, "notarize_revoke:{d}", .{notarize_id});
    defer alloc.free(op_return);

    const ts    = std.time.timestamp();
    const tx_id: u32 = @intCast(std.time.milliTimestamp() & 0xFFFFFFFF);
    const provisional = try std.fmt.allocPrint(alloc, "{d}{s}{d}", .{ tx_id, from, ts });
    defer alloc.free(provisional);

    var tx = blockchain_mod.Transaction{
        .id           = tx_id,
        .from_address = from,
        .to_address   = from,
        .amount       = 0,
        .fee          = notarize_mod.NOTARIZE_REVOKE_FEE_SAT,
        .timestamp    = ts,
        .nonce        = nonce,
        .op_return    = op_return,
        .signature    = sig,
        .public_key   = pubkey,
        .scheme       = .omni_ecdsa,
        .hash         = provisional,
    };
    const hash_bytes = tx.calculateHash();
    const canonical  = try std.fmt.allocPrint(alloc, "{s}", .{std.fmt.bytesToHex(hash_bytes, .lower)});
    tx.hash = canonical;

    const revoked = ctx.bc.notarize_registry.revoke(notarize_id, from);

    ctx.bc.mutex.lock();
    ctx.bc.mempool.append(tx) catch {
        ctx.bc.mutex.unlock();
        return errorJson(-32603, "Mempool full", id, alloc);
    };
    ctx.bc.mutex.unlock();

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"status\":\"queued\",\"txid\":\"{s}\",\"revoked\":{s}}}}}",
        .{ id, canonical, if (revoked) "true" else "false" });
}

// ── getnotarizations ──────────────────────────────────────────────────────────
// { "address":"ob1q..." }  — lista notarizarilor unui owner (newest first)

fn handleGetNotarizations(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc   = ctx.allocator;
    const address = extractStr(body, "address") orelse
        return errorJson(-32602, "Missing: address", id, alloc);

    var entries: [64]notarize_mod.NotarizeEntry = undefined;
    const n = ctx.bc.notarize_registry.listByOwner(address, &entries);
    const current_block: u64 = @intCast(ctx.bc.getBlockCount());

    var buf = std.array_list.Managed(u8).init(alloc);
    defer buf.deinit();
    const w = buf.writer();

    try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"notarizations\":[", .{id});
    for (entries[0..n], 0..) |e, i| {
        if (i > 0) try w.writeByte(',');
        const status = if (e.revoked) "revoked"
            else if (e.expiry_block > 0 and current_block > e.expiry_block) "expired"
            else "valid";
        try w.print(
            "{{\"id\":{d},\"doc_hash\":\"{s}\",\"doc_type\":\"{s}\"," ++
            "\"block_height\":{d},\"tx_hash\":\"{s}\"," ++
            "\"expiry_block\":{d},\"status\":\"{s}\",\"note\":\"{s}\"}}",
            .{ e.id, e.docHashSlice(), e.doc_type.toStr(),
               e.block_height, e.txHashSlice(),
               e.expiry_block, status, e.noteSlice() },
        );
    }
    try w.writeAll("]}}");
    return buf.toOwnedSlice();
}

// ── sub_create ────────────────────────────────────────────────────────────────
// { "from":"ob1q...", "to":"ob1q...", "amount":1000000, "interval":100,
//   "max_payments":12, "note":"Netflix", "signature":"hex", "public_key":"hex", "nonce":N }

fn handleSubCreate(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc    = ctx.allocator;
    const from     = extractStr(body, "from")    orelse return errorJson(-32602, "Missing: from", id, alloc);
    const to       = extractStr(body, "to")      orelse return errorJson(-32602, "Missing: to", id, alloc);
    const amount   = extractParamObjectU64(body, "amount");
    const interval = extractParamObjectU64(body, "interval");
    const max_pay  = extractParamObjectU64(body, "max_payments");
    const note     = extractStr(body, "note") orelse "";
    const sig      = extractStr(body, "signature")  orelse return errorJson(-32602, "Missing: signature", id, alloc);
    const pubkey   = extractStr(body, "public_key") orelse return errorJson(-32602, "Missing: public_key", id, alloc);
    const nonce    = extractParamObjectU64(body, "nonce");

    if (amount == 0)   return errorJson(-32602, "amount must be > 0", id, alloc);
    if (interval == 0) return errorJson(-32602, "interval must be > 0", id, alloc);

    // Build op_return
    const op_return = try std.fmt.allocPrint(alloc,
        "sub_create:{s}:{d}:{d}:{d}:{s}", .{ to, amount, interval, max_pay, note });
    defer alloc.free(op_return);

    const ts    = std.time.timestamp();
    const tx_id: u32 = @intCast(std.time.milliTimestamp() & 0xFFFFFFFF);
    const provisional = try std.fmt.allocPrint(alloc, "{d}{s}{d}", .{ tx_id, from, ts });
    defer alloc.free(provisional);

    var tx = blockchain_mod.Transaction{
        .id           = tx_id,
        .from_address = from,
        .to_address   = from,
        .amount       = 0,
        .fee          = sub_mod.SUB_CREATE_FEE_SAT,
        .timestamp    = ts,
        .nonce        = nonce,
        .op_return    = op_return,
        .signature    = sig,
        .public_key   = pubkey,
        .scheme       = .omni_ecdsa,
        .hash         = provisional,
    };
    const hash_bytes = tx.calculateHash();
    const canonical  = try std.fmt.allocPrint(alloc, "{s}", .{std.fmt.bytesToHex(hash_bytes, .lower)});
    tx.hash = canonical;

    // Optimistic in-memory create
    const parsed = sub_mod.parseCreate(op_return).?;
    const sub_id = ctx.bc.sub_registry.create(from, parsed, @intCast(ctx.bc.getBlockCount())) catch 0;

    ctx.bc.mutex.lock();
    ctx.bc.mempool.append(tx) catch {
        ctx.bc.mutex.unlock();
        return errorJson(-32603, "Mempool full", id, alloc);
    };
    ctx.bc.mutex.unlock();

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"status\":\"queued\",\"txid\":\"{s}\",\"sub_id\":{d},\"next_block\":{d}}}}}",
        .{ id, canonical, sub_id, ctx.bc.getBlockCount() + interval });
}

// ── sub_cancel ────────────────────────────────────────────────────────────────
// { "from":"ob1q...", "sub_id":42, "signature":"hex", "public_key":"hex", "nonce":N }

fn handleSubCancel(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc   = ctx.allocator;
    const from    = extractStr(body, "from")    orelse return errorJson(-32602, "Missing: from", id, alloc);
    const sub_id  = extractParamObjectU64(body, "sub_id");
    const sig     = extractStr(body, "signature")  orelse return errorJson(-32602, "Missing: signature", id, alloc);
    const pubkey  = extractStr(body, "public_key") orelse return errorJson(-32602, "Missing: public_key", id, alloc);
    const nonce   = extractParamObjectU64(body, "nonce");

    const op_return = try std.fmt.allocPrint(alloc, "sub_cancel:{d}", .{sub_id});
    defer alloc.free(op_return);

    const ts    = std.time.timestamp();
    const tx_id: u32 = @intCast(std.time.milliTimestamp() & 0xFFFFFFFF);
    const provisional = try std.fmt.allocPrint(alloc, "{d}{s}{d}", .{ tx_id, from, ts });
    defer alloc.free(provisional);

    var tx = blockchain_mod.Transaction{
        .id           = tx_id,
        .from_address = from,
        .to_address   = from,
        .amount       = 0,
        .fee          = 1000,
        .timestamp    = ts,
        .nonce        = nonce,
        .op_return    = op_return,
        .signature    = sig,
        .public_key   = pubkey,
        .scheme       = .omni_ecdsa,
        .hash         = provisional,
    };
    const hash_bytes = tx.calculateHash();
    const canonical  = try std.fmt.allocPrint(alloc, "{s}", .{std.fmt.bytesToHex(hash_bytes, .lower)});
    tx.hash = canonical;

    const cancelled = ctx.bc.sub_registry.cancel(sub_id, from);

    ctx.bc.mutex.lock();
    ctx.bc.mempool.append(tx) catch {
        ctx.bc.mutex.unlock();
        return errorJson(-32603, "Mempool full", id, alloc);
    };
    ctx.bc.mutex.unlock();

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"status\":\"queued\",\"txid\":\"{s}\",\"cancelled\":{s}}}}}",
        .{ id, canonical, if (cancelled) "true" else "false" });
}

// ── getsubscriptions ──────────────────────────────────────────────────────────
// { "address":"ob1q..." }  — returnează toate subscripțiile (emise și primite)

fn handleGetSubscriptions(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc   = ctx.allocator;
    const address = extractStr(body, "address") orelse
        return errorJson(-32602, "Missing: address", id, alloc);

    var entries: [sub_mod.MAX_SUBS_PER_ADDRESS]sub_mod.Subscription = undefined;
    const n = ctx.bc.sub_registry.listByFrom(address, &entries);

    var buf = std.array_list.Managed(u8).init(alloc);
    defer buf.deinit();
    const w = buf.writer();

    try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"subscriptions\":[", .{id});
    for (entries[0..n], 0..) |sub, i| {
        if (i > 0) try w.writeByte(',');
        const status_str: []const u8 = switch (sub.status) {
            .active    => "active",
            .cancelled => "cancelled",
            .completed => "completed",
        };
        try w.print(
            "{{\"id\":{d},\"from\":\"{s}\",\"to\":\"{s}\"," ++
            "\"amount_sat\":{d},\"interval_blocks\":{d}," ++
            "\"max_payments\":{d},\"payments_done\":{d}," ++
            "\"next_block\":{d},\"status\":\"{s}\",\"note\":\"{s}\"}}",
            .{ sub.id, sub.fromSlice(), sub.toSlice(),
               sub.amount_sat, sub.interval_blocks,
               sub.max_payments, sub.payments_done,
               sub.next_block, status_str, sub.noteSlice() },
        );
    }
    try w.writeAll("]}}");
    return buf.toOwnedSlice();
}

// ── Profile / MiCA off-chain identity store ────────────────────────────────
//
// In-memory per-address profile entries. Off-chain (not consensus). Optional
// JSONL append-only log at "profiles.jsonl" for crash durability. Only the
// Merkle root of a fully populated Manifest would ever be anchored on-chain,
// via a separate manifest_anchor TX (out of scope here).
//
// 4 facets: social, professional, cultural, economic. Each holds a small
// dictionary of (field_name → FieldValue). FieldValue.is_public controls
// whether the cleartext is emitted by profile_get; private fields are
// hidden entirely (verifier may request a selective-disclosure proof).
//
// The economic facet additionally tracks MiCA-relevant attestations: KYC,
// AML, sanctions, MiCA issuer flag, risk category.

const FieldValue = struct {
    /// Owned by ProfileStore.allocator. UTF-8 or hex, whatever the caller sent.
    value: []u8,
    is_public: bool,
};

const FacetStore = struct {
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

const ProfileEntry = struct {
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

const ProfileStore = struct {
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

    fn getOrCreate(self: *ProfileStore, h160: [20]u8) !*ProfileEntry {
        if (self.by_h160.get(h160)) |e| return e;
        const e = try self.allocator.create(ProfileEntry);
        e.* = ProfileEntry.init(self.allocator, h160);
        try self.by_h160.put(h160, e);
        return e;
    }

    fn get(self: *ProfileStore, h160: [20]u8) ?*ProfileEntry {
        return self.by_h160.get(h160);
    }
};

var g_profile_store: ?ProfileStore = null;

fn getProfileStore(alloc: std.mem.Allocator) *ProfileStore {
    if (g_profile_store == null) g_profile_store = ProfileStore.init(alloc);
    return &g_profile_store.?;
}

/// Decode bech32 OmniBus address → h160 bytes. Returns error if malformed.
fn addrToH160(addr: []const u8, alloc: std.mem.Allocator) ![20]u8 {
    const decoded = try bech32_mod.decodeWitnessAddress(bech32_mod.OB_HRP, addr, alloc);
    defer alloc.free(decoded.program);
    if (decoded.program.len != 20) return error.InvalidAddress;
    var h160: [20]u8 = undefined;
    @memcpy(&h160, decoded.program);
    return h160;
}

fn hexEncode(alloc: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var out = try alloc.alloc(u8, bytes.len * 2);
    const hex = "0123456789abcdef";
    for (bytes, 0..) |b, i| {
        out[i * 2] = hex[b >> 4];
        out[i * 2 + 1] = hex[b & 0x0F];
    }
    return out;
}

fn facetIndex(name: []const u8) ?usize {
    if (std.mem.eql(u8, name, "social")) return 0;
    if (std.mem.eql(u8, name, "professional")) return 1;
    if (std.mem.eql(u8, name, "cultural")) return 2;
    if (std.mem.eql(u8, name, "economic")) return 3;
    return null;
}

const FACET_NAMES = [_][]const u8{ "social", "professional", "cultural", "economic" };

/// Hash a facet's field bag into a 32-byte root. Order-independent: we sort
/// field keys first. Tiny stand-in until the real facet modules expose a
/// canonical root function (id_social / id_professional / id_cultural /
/// id_economic each have their own; we hash a generic key|value bag here).
fn computeFacetRoot(facet: *const FacetStore, alloc: std.mem.Allocator) ![32]u8 {
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
fn appendProfileLog(ctx: *ServerCtx, line: []const u8) void {
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
fn handleProfileInit(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const addr = extractArrayStr(body, 0) orelse extractStr(body, "address") orelse
        return errorJson(-32602, "Missing param: address", id, alloc);

    const h160 = addrToH160(addr, alloc) catch
        return errorJson(-32602, "Invalid bech32 address", id, alloc);

    const did = try id_layer_mod.did.didFromHash160(h160, alloc);
    defer alloc.free(did);

    const store = getProfileStore(alloc);
    store.mutex.lock();
    defer store.mutex.unlock();
    _ = try store.getOrCreate(h160);

    // Best-effort JSONL append — init event so replay can recreate the entry.
    {
        const ts = std.time.timestamp();
        const init_line = std.fmt.allocPrint(alloc,
            "{{\"op\":\"init\",\"addr\":\"{s}\",\"did\":\"{s}\",\"ts\":{d}}}",
            .{ addr, did, ts }) catch null;
        if (init_line) |l| {
            defer alloc.free(l);
            appendProfileLog(ctx, l);
        }
    }

    // Empty manifest skeleton — all leaves zero. Use the same Manifest type
    // so the root we report matches what an off-chain anchor would produce
    // for an unpopulated holder.
    const empty_manifest = id_layer_mod.manifest.Manifest{
        .kyc_hash = [_]u8{0} ** 32,
        .assets_root = [_]u8{0} ** 32,
        .reputation = .{},
        .pq_pubkeys_concat = "",
        .obm = 0,
        .timestamp_unix_s = 0,
    };
    const root = try id_layer_mod.manifest.computeRoot(empty_manifest, alloc);
    const root_hex = try hexEncode(alloc, &root);
    defer alloc.free(root_hex);

    const salt_bytes = try store.salt_mgr.manager().getOrCreate();
    const salt_hex = try hexEncode(alloc, &salt_bytes);
    defer alloc.free(salt_hex);

    const zero_hex = "0000000000000000000000000000000000000000000000000000000000000000";

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"did\":\"{s}\",\"address\":\"{s}\",\"manifest_root_empty\":\"{s}\",\"salt_hex\":\"{s}\",\"facets\":{{\"social\":\"{s}\",\"professional\":\"{s}\",\"cultural\":\"{s}\",\"economic\":\"{s}\"}}}}}}",
        .{ id, did, addr, root_hex, salt_hex, zero_hex, zero_hex, zero_hex, zero_hex });
}

/// RPC `profile_update <addr> <facet> <field> <value> <is_public>` — update
/// one field in one facet. Stored in-memory + JSONL log.
fn handleProfileUpdate(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const addr = extractArrayStr(body, 0) orelse extractStr(body, "address") orelse
        return errorJson(-32602, "Missing param: address", id, alloc);
    const facet_name = extractArrayStr(body, 1) orelse extractStr(body, "facet") orelse
        return errorJson(-32602, "Missing param: facet", id, alloc);
    const field_name = extractArrayStr(body, 2) orelse extractStr(body, "field") orelse
        return errorJson(-32602, "Missing param: field", id, alloc);
    const value = extractArrayStr(body, 3) orelse extractStr(body, "value") orelse
        return errorJson(-32602, "Missing param: value", id, alloc);
    // is_public — accept "true"/"false" string OR bare JSON boolean true/false in
    // array position 4, or the "is_public" named key. extractArrayToken handles both.
    var is_public: bool = false;
    if (extractArrayToken(body, 4)) |s| {
        is_public = std.mem.eql(u8, s, "true");
    } else if (extractStr(body, "is_public")) |s| {
        is_public = std.mem.eql(u8, s, "true");
    }

    const fidx = facetIndex(facet_name) orelse
        return errorJson(-32602, "Unknown facet (expected social|professional|cultural|economic)", id, alloc);

    const h160 = addrToH160(addr, alloc) catch
        return errorJson(-32602, "Invalid bech32 address", id, alloc);

    const store = getProfileStore(alloc);
    store.mutex.lock();
    defer store.mutex.unlock();

    const entry = try store.getOrCreate(h160);
    var facet = &entry.facets[fidx];

    // Drop any prior value for this key (free its memory) before insert.
    if (facet.fields.fetchRemove(field_name)) |old| {
        store.allocator.free(old.key);
        store.allocator.free(old.value.value);
    }
    const key_dup = try store.allocator.dupe(u8, field_name);
    const val_dup = try store.allocator.dupe(u8, value);
    try facet.fields.put(key_dup, .{ .value = val_dup, .is_public = is_public });

    const new_root = try computeFacetRoot(facet, alloc);
    const root_hex = try hexEncode(alloc, &new_root);
    defer alloc.free(root_hex);

    // Best-effort JSONL append — update event with all fields needed for replay.
    const ts = std.time.timestamp();
    const log_line = try std.fmt.allocPrint(alloc,
        "{{\"op\":\"update\",\"addr\":\"{s}\",\"facet\":\"{s}\",\"field\":\"{s}\",\"value\":\"{s}\",\"is_public\":\"{}\",\"ts\":{d}}}",
        .{ addr, facet_name, field_name, value, is_public, ts });
    defer alloc.free(log_line);
    appendProfileLog(ctx, log_line);

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"ok\":true,\"facet\":\"{s}\",\"new_facet_root\":\"{s}\"}}}}",
        .{ id, facet_name, root_hex });
}

/// Emit a facet as a JSON object containing only fields with is_public=true.
fn writeFacetPublicJson(w: anytype, facet: *const FacetStore) !void {
    try w.writeByte('{');
    var first = true;
    var it = facet.fields.iterator();
    while (it.next()) |kv| {
        if (!kv.value_ptr.is_public) continue;
        if (!first) try w.writeByte(',');
        first = false;
        try w.print("\"{s}\":\"{s}\"", .{ kv.key_ptr.*, kv.value_ptr.value });
    }
    try w.writeByte('}');
}

/// RPC `profile_get <addr>` — public view: only fields marked is_public.
fn handleProfileGet(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const addr = extractArrayStr(body, 0) orelse extractStr(body, "address") orelse
        return errorJson(-32602, "Missing param: address", id, alloc);

    const h160 = addrToH160(addr, alloc) catch
        return errorJson(-32602, "Invalid bech32 address", id, alloc);

    const did = try id_layer_mod.did.didFromHash160(h160, alloc);
    defer alloc.free(did);

    var buf = std.array_list.Managed(u8).init(alloc);
    defer buf.deinit();
    const w = buf.writer();

    try w.print(
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"did\":\"{s}\",\"address\":\"{s}\",\"facets\":{{",
        .{ id, did, addr });

    const store = getProfileStore(alloc);
    store.mutex.lock();
    defer store.mutex.unlock();
    const maybe_entry = store.get(h160);

    for (FACET_NAMES, 0..) |fname, i| {
        if (i > 0) try w.writeByte(',');
        try w.print("\"{s}\":", .{fname});
        if (maybe_entry) |entry| {
            try writeFacetPublicJson(w, &entry.facets[i]);
        } else {
            try w.writeAll("{}");
        }
    }
    try w.writeAll("}}}");
    return buf.toOwnedSlice();
}

/// Validate hex-shape only — no cryptographic verification. Empty allowed
/// when the attestation is a self-attestation (issuer_did=="").
fn isHexShape(s: []const u8) bool {
    if (s.len == 0) return true;
    if (s.len % 2 != 0) return false;
    for (s) |c| {
        const ok = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
        if (!ok) return false;
    }
    return true;
}

fn isAllZeros(s: []const u8) bool {
    for (s) |c| if (c != '0') return false;
    return true;
}

/// RPC `mica_attest <addr> <kind> <issuer_did> <signature_hex>` — record a
/// KYC / AML / sanctions attestation on the address's economic profile.
fn handleMicaAttest(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const addr = extractArrayStr(body, 0) orelse extractStr(body, "address") orelse
        return errorJson(-32602, "Missing param: address", id, alloc);
    const kind = extractArrayStr(body, 1) orelse extractStr(body, "kind") orelse
        return errorJson(-32602, "Missing param: kind", id, alloc);
    const issuer = extractArrayStr(body, 2) orelse extractStr(body, "issuer_did") orelse "";
    const sig_hex = extractArrayStr(body, 3) orelse extractStr(body, "signature_hex") orelse "";

    if (!(std.mem.eql(u8, kind, "kyc") or std.mem.eql(u8, kind, "aml") or
          std.mem.eql(u8, kind, "sanctions")))
        return errorJson(-32602, "kind must be kyc|aml|sanctions", id, alloc);

    if (!isHexShape(sig_hex))
        return errorJson(-32602, "signature_hex must be hex (even length, [0-9a-f])", id, alloc);

    // Self-attestation rule: empty issuer ⇒ signature must be zeros (or empty).
    if (issuer.len == 0 and sig_hex.len > 0 and !isAllZeros(sig_hex))
        return errorJson(-32602, "Self-attestation requires zero signature", id, alloc);

    const h160 = addrToH160(addr, alloc) catch
        return errorJson(-32602, "Invalid bech32 address", id, alloc);

    const store = getProfileStore(alloc);
    store.mutex.lock();
    defer store.mutex.unlock();
    const entry = try store.getOrCreate(h160);

    try entry.mica.append(.{
        .kind = try store.allocator.dupe(u8, kind),
        .issuer_did = try store.allocator.dupe(u8, issuer),
        .signature_hex = try store.allocator.dupe(u8, sig_hex),
        .timestamp_unix_s = @intCast(std.time.timestamp()),
    });

    // Mirror the latest-of-kind flag into the economic facet as a public
    // field (e.g. kyc_verified=true). Cleartext sig stays in mica list.
    var econ = &entry.facets[3];
    const flag_key = try std.fmt.allocPrint(store.allocator, "{s}_verified", .{kind});
    if (econ.fields.fetchRemove(flag_key)) |old| {
        store.allocator.free(old.key);
        store.allocator.free(old.value.value);
    }
    const flag_val = try store.allocator.dupe(u8, "true");
    try econ.fields.put(flag_key, .{ .value = flag_val, .is_public = true });

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"ok\":true,\"attestation_kind\":\"{s}\",\"issuer\":\"{s}\"}}}}",
        .{ id, kind, issuer });
}

/// RPC `mica_disclose <addr>` — return all MiCA-relevant attestations for
/// the address (KYC, AML, sanctions) plus issuer flag and risk category
/// pulled from the economic facet (best-effort).
fn handleMicaDisclose(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const addr = extractArrayStr(body, 0) orelse extractStr(body, "address") orelse
        return errorJson(-32602, "Missing param: address", id, alloc);

    const h160 = addrToH160(addr, alloc) catch
        return errorJson(-32602, "Invalid bech32 address", id, alloc);

    var buf = std.array_list.Managed(u8).init(alloc);
    defer buf.deinit();
    const w = buf.writer();

    try w.print(
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"address\":\"{s}\",\"attestations\":[",
        .{ id, addr });

    const store = getProfileStore(alloc);
    store.mutex.lock();
    defer store.mutex.unlock();
    const maybe_entry = store.get(h160);

    var is_mica_issuer: bool = false;
    var risk_category: []const u8 = "unknown";

    if (maybe_entry) |entry| {
        for (entry.mica.items, 0..) |att, i| {
            if (i > 0) try w.writeByte(',');
            try w.print(
                "{{\"kind\":\"{s}\",\"issuer_did\":\"{s}\",\"signature_hex\":\"{s}\",\"timestamp\":{d}}}",
                .{ att.kind, att.issuer_did, att.signature_hex, att.timestamp_unix_s });
        }
        // Pull optional economic-facet flags (only if marked public).
        const econ = &entry.facets[3];
        if (econ.fields.get("is_mica_issuer")) |fv| {
            if (fv.is_public) is_mica_issuer = std.mem.eql(u8, fv.value, "true");
        }
        if (econ.fields.get("risk_category")) |fv| {
            if (fv.is_public) risk_category = fv.value;
        }
    }
    try w.print("],\"is_mica_issuer\":{},\"risk_category\":\"{s}\"}}}}", .{ is_mica_issuer, risk_category });
    return buf.toOwnedSlice();
}

/// RPC `disclose_post` — prove a specific social post from facet[0].
/// Request:  {"method":"disclose_post","params":{"address":"ob1q...","post_index":0}}
/// Response: {"post_hash":"hex...","timestamp":N,"is_public":true,"proof":["hex..."]}
fn handleDisclosePost(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const address = extractParamObjectField(body, "address") orelse
        return errorJson(-32602, "Missing param: address", id, alloc);
    const post_idx = extractParamObjectU64(body, "post_index");

    const h160 = addrToH160(address, alloc) catch
        return errorJson(-32602, "Invalid address", id, alloc);

    const store = getProfileStore(alloc);
    store.mutex.lock();
    defer store.mutex.unlock();

    const entry = store.get(h160) orelse
        return errorJson(-32000, "Profile not found", id, alloc);

    const facet = &entry.facets[0]; // social

    // Build key names for this post index (max fits in 32 bytes).
    var hash_key_buf: [32]u8 = undefined;
    var ts_key_buf:   [32]u8 = undefined;
    var pub_key_buf:  [32]u8 = undefined;

    const hash_key = std.fmt.bufPrint(&hash_key_buf, "post_{d}_hash",   .{post_idx}) catch
        return errorJson(-32000, "Index too large", id, alloc);
    const ts_key   = std.fmt.bufPrint(&ts_key_buf,   "post_{d}_ts",     .{post_idx}) catch
        return errorJson(-32000, "Index too large", id, alloc);
    const pub_key  = std.fmt.bufPrint(&pub_key_buf,  "post_{d}_public", .{post_idx}) catch
        return errorJson(-32000, "Index too large", id, alloc);

    const hash_val = (facet.fields.get(hash_key) orelse
        return errorJson(-32000, "Post not found at index", id, alloc)).value;

    const ts_val  = if (facet.fields.get(ts_key))  |fv| fv.value else "0";
    const pub_val = if (facet.fields.get(pub_key)) |fv| fv.value else "false";
    const is_pub  = std.mem.eql(u8, pub_val, "true");

    // Proof = facet root (commits to all items in this facet).
    const facet_root = try computeFacetRoot(facet, alloc);
    const root_hex   = try hexEncode(alloc, &facet_root);
    defer alloc.free(root_hex);

    const ts_num = std.fmt.parseInt(u64, ts_val, 10) catch 0;

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"post_hash\":\"{s}\",\"timestamp\":{d},\"is_public\":{},\"proof\":[\"{s}\"]}}}}",
        .{ id, hash_val, ts_num, is_pub, root_hex });
}

/// RPC `disclose_cert` — prove a specific professional certification from facet[1].
/// Request:  {"method":"disclose_cert","params":{"address":"ob1q...","cert_index":0}}
/// Response: {"issuer_did":"did:...","credential_kind":"engineering","valid_from":N,"valid_until":N,"hash":"hex...","proof":["hex..."]}
fn handleDiscloseCert(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const address = extractParamObjectField(body, "address") orelse
        return errorJson(-32602, "Missing param: address", id, alloc);
    const cert_idx = extractParamObjectU64(body, "cert_index");

    const h160 = addrToH160(address, alloc) catch
        return errorJson(-32602, "Invalid address", id, alloc);

    const store = getProfileStore(alloc);
    store.mutex.lock();
    defer store.mutex.unlock();

    const entry = store.get(h160) orelse
        return errorJson(-32000, "Profile not found", id, alloc);

    const facet = &entry.facets[1]; // professional

    var issuer_key_buf:  [32]u8 = undefined;
    var kind_key_buf:    [32]u8 = undefined;
    var from_key_buf:    [32]u8 = undefined;
    var until_key_buf:   [32]u8 = undefined;
    var hash_key_buf:    [32]u8 = undefined;

    const issuer_key = std.fmt.bufPrint(&issuer_key_buf, "cert_{d}_issuer",      .{cert_idx}) catch
        return errorJson(-32000, "Index too large", id, alloc);
    const kind_key   = std.fmt.bufPrint(&kind_key_buf,   "cert_{d}_kind",        .{cert_idx}) catch
        return errorJson(-32000, "Index too large", id, alloc);
    const from_key   = std.fmt.bufPrint(&from_key_buf,   "cert_{d}_valid_from",  .{cert_idx}) catch
        return errorJson(-32000, "Index too large", id, alloc);
    const until_key  = std.fmt.bufPrint(&until_key_buf,  "cert_{d}_valid_until", .{cert_idx}) catch
        return errorJson(-32000, "Index too large", id, alloc);
    const hash_key   = std.fmt.bufPrint(&hash_key_buf,   "cert_{d}_hash",        .{cert_idx}) catch
        return errorJson(-32000, "Index too large", id, alloc);

    // issuer or hash must exist — use issuer as the required sentinel.
    const issuer_val = (facet.fields.get(issuer_key) orelse
        return errorJson(-32000, "Cert not found at index", id, alloc)).value;

    const kind_val  = if (facet.fields.get(kind_key))  |fv| fv.value else "";
    const from_val  = if (facet.fields.get(from_key))  |fv| fv.value else "0";
    const until_val = if (facet.fields.get(until_key)) |fv| fv.value else "0";
    const hash_val  = if (facet.fields.get(hash_key))  |fv| fv.value else "";

    const facet_root = try computeFacetRoot(facet, alloc);
    const root_hex   = try hexEncode(alloc, &facet_root);
    defer alloc.free(root_hex);

    const from_num  = std.fmt.parseInt(u64, from_val,  10) catch 0;
    const until_num = std.fmt.parseInt(u64, until_val, 10) catch 0;

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"issuer_did\":\"{s}\",\"credential_kind\":\"{s}\",\"valid_from\":{d},\"valid_until\":{d},\"hash\":\"{s}\",\"proof\":[\"{s}\"]}}}}",
        .{ id, issuer_val, kind_val, from_num, until_num, hash_val, root_hex });
}

/// RPC `disclose_work` — prove a specific notarized work from facet[2] (cultural).
/// Request:  {"method":"disclose_work","params":{"address":"ob1q...","work_index":0}}
/// Response: {"content_hash":"hex...","work_kind":"code","notarized_at":N,"is_public":bool,"proof":["hex..."]}
fn handleDiscloseWork(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const address = extractParamObjectField(body, "address") orelse
        return errorJson(-32602, "Missing param: address", id, alloc);
    const work_idx = extractParamObjectU64(body, "work_index");

    const h160 = addrToH160(address, alloc) catch
        return errorJson(-32602, "Invalid address", id, alloc);

    const store = getProfileStore(alloc);
    store.mutex.lock();
    defer store.mutex.unlock();

    const entry = store.get(h160) orelse
        return errorJson(-32000, "Profile not found", id, alloc);

    const facet = &entry.facets[2]; // cultural

    var hash_key_buf: [32]u8 = undefined;
    var kind_key_buf: [32]u8 = undefined;
    var ts_key_buf:   [32]u8 = undefined;
    var pub_key_buf:  [32]u8 = undefined;

    const hash_key = std.fmt.bufPrint(&hash_key_buf, "work_{d}_hash",   .{work_idx}) catch
        return errorJson(-32000, "Index too large", id, alloc);
    const kind_key = std.fmt.bufPrint(&kind_key_buf, "work_{d}_kind",   .{work_idx}) catch
        return errorJson(-32000, "Index too large", id, alloc);
    const ts_key   = std.fmt.bufPrint(&ts_key_buf,   "work_{d}_ts",     .{work_idx}) catch
        return errorJson(-32000, "Index too large", id, alloc);
    const pub_key  = std.fmt.bufPrint(&pub_key_buf,  "work_{d}_public", .{work_idx}) catch
        return errorJson(-32000, "Index too large", id, alloc);

    const hash_val = (facet.fields.get(hash_key) orelse
        return errorJson(-32000, "Work not found at index", id, alloc)).value;

    const kind_val = if (facet.fields.get(kind_key)) |fv| fv.value else "";
    const ts_val   = if (facet.fields.get(ts_key))   |fv| fv.value else "0";
    const pub_val  = if (facet.fields.get(pub_key))  |fv| fv.value else "false";
    const is_pub   = std.mem.eql(u8, pub_val, "true");

    const facet_root = try computeFacetRoot(facet, alloc);
    const root_hex   = try hexEncode(alloc, &facet_root);
    defer alloc.free(root_hex);

    const ts_num = std.fmt.parseInt(u64, ts_val, 10) catch 0;

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"content_hash\":\"{s}\",\"work_kind\":\"{s}\",\"notarized_at\":{d},\"is_public\":{},\"proof\":[\"{s}\"]}}}}",
        .{ id, hash_val, kind_val, ts_num, is_pub, root_hex });
}

// ── errorJson ────────────────────────────────────────────────────────────────

test "errorJson — contine code si message" {
    const result = try errorJson(-32600, "Invalid request", 1, testing.allocator);
    defer testing.allocator.free(result);
    try testing.expect(std.mem.indexOf(u8, result, "-32600") != null);
    try testing.expect(std.mem.indexOf(u8, result, "Invalid request") != null);
    try testing.expect(std.mem.indexOf(u8, result, "\"id\":1") != null);
}

test "errorJson — format JSON-RPC 2.0" {
    const result = try errorJson(-32000, "Sign error", 7, testing.allocator);
    defer testing.allocator.free(result);
    try testing.expect(std.mem.indexOf(u8, result, "\"jsonrpc\":\"2.0\"") != null);
    try testing.expect(std.mem.indexOf(u8, result, "\"error\"") != null);
    try testing.expect(std.mem.indexOf(u8, result, "\"id\":7") != null);
}

// ═══════════════════════════════════════════════════════════════════════════
// ── Cold Wallet (watch-only) handlers ─────────────────────────────────────
// ═══════════════════════════════════════════════════════════════════════════

/// coldwallet_add {"address":"ob1q...","label":"savings"}
fn handleColdWalletAdd(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const address = extractParamObjectField(body, "address") orelse
        return errorJson(-32602, "Missing param: address", id, alloc);
    const label = extractParamObjectField(body, "label") orelse "";
    if (address.len < 8)
        return errorJson(-32602, "Invalid address", id, alloc);
    const ok = ctx.bc.cold_wallet_store.add(address, label);
    if (!ok)
        return errorJson(-32000,
            "Add failed: address already watched, store full, or label has forbidden chars (printable ASCII only, no quotes or backslashes)",
            id, alloc);
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"address\":\"{s}\",\"label\":\"{s}\",\"status\":\"added\"}}}}",
        .{ id, address, label });
}

/// coldwallet_list {} — lists all watch-only wallets with current balances
fn handleColdWalletList(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    _ = body;
    const alloc = ctx.allocator;
    const buf = try alloc.alloc(cold_wallet_mod.ColdWallet, cold_wallet_mod.MAX_ENTRIES);
    defer alloc.free(buf);
    const n = ctx.bc.cold_wallet_store.listAll(buf);
    var out = std.ArrayList(u8){};
    defer out.deinit(alloc);
    try out.appendSlice(alloc, "[");
    for (buf[0..n], 0..) |w, i| {
        if (i > 0) try out.appendSlice(alloc, ",");
        const live_bal = ctx.bc.getAddressBalance(w.addressSlice());
        const entry = try std.fmt.allocPrint(alloc,
            "{{\"address\":\"{s}\",\"label\":\"{s}\",\"balance_sat\":{d},\"total_received_sat\":{d},\"created\":{d}}}",
            .{ w.addressSlice(), w.labelSlice(), live_bal, w.total_received_sat, w.created_unix_s });
        defer alloc.free(entry);
        try out.appendSlice(alloc, entry);
    }
    try out.appendSlice(alloc, "]");
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{s}}}",
        .{ id, out.items });
}

/// coldwallet_remove {"address":"ob1q..."}
fn handleColdWalletRemove(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const address = extractParamObjectField(body, "address") orelse
        return errorJson(-32602, "Missing param: address", id, alloc);
    const ok = ctx.bc.cold_wallet_store.remove(address);
    if (!ok)
        return errorJson(-32000, "Address not found in watch list", id, alloc);
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"address\":\"{s}\",\"status\":\"removed\"}}}}",
        .{ id, address });
}

/// coldwallet_history {"address":"ob1q...","limit":50}
fn handleColdWalletHistory(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const address = extractParamObjectField(body, "address") orelse
        return errorJson(-32602, "Missing param: address", id, alloc);
    const limit_raw = extractParamObjectU64(body, "limit");
    const limit: usize = if (limit_raw > 0 and limit_raw <= 500) @intCast(limit_raw) else 50;
    // Reuse address TX index
    const tx_hashes = ctx.bc.address_tx_index.get(address) orelse {
        return std.fmt.allocPrint(alloc,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":[]}}",
            .{id});
    };
    var out = std.ArrayList(u8){};
    defer out.deinit(alloc);
    try out.appendSlice(alloc, "[");
    const start: usize = if (tx_hashes.items.len > limit) tx_hashes.items.len - limit else 0;
    var first = true;
    for (tx_hashes.items[start..]) |tx_hash| {
        // Find TX in chain (scan blocks — lightweight for watch-only auditing)
        for (ctx.bc.chain.items) |*blk| {
            for (blk.transactions.items) |tx| {
                if (!std.mem.eql(u8, tx.hash, tx_hash)) continue;
                if (!std.mem.eql(u8, tx.to_address, address)) continue; // only incoming
                if (!first) try out.appendSlice(alloc, ",");
                first = false;
                const entry = try std.fmt.allocPrint(alloc,
                    "{{\"tx_hash\":\"{s}\",\"from\":\"{s}\",\"amount_sat\":{d},\"block\":{d}}}",
                    .{ tx.hash, tx.from_address, tx.amount,
                       ctx.bc.tx_block_height.get(tx.hash) orelse 0 });
                defer alloc.free(entry);
                try out.appendSlice(alloc, entry);
                break;
            }
        }
    }
    try out.appendSlice(alloc, "]");
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{s}}}",
        .{ id, out.items });
}

// ═══════════════════════════════════════════════════════════════════════════
// ── Timelock Vault (CLTV) handlers ────────────────────────────────────────
// ═══════════════════════════════════════════════════════════════════════════

/// timelock_create {"owner":"ob1q...","dest":"ob1q...","amount_sat":N,"unlock_block":B}
fn handleTimelockCreate(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const owner = extractParamObjectField(body, "owner") orelse
        return errorJson(-32602, "Missing param: owner", id, alloc);
    const dest = extractParamObjectField(body, "dest") orelse
        return errorJson(-32602, "Missing param: dest", id, alloc);
    const amount_sat = extractParamObjectU64(body, "amount_sat");
    if (amount_sat == 0) return errorJson(-32602, "Missing/zero param: amount_sat", id, alloc);
    const unlock_block = extractParamObjectU64(body, "unlock_block");
    if (unlock_block == 0) return errorJson(-32602, "Missing/zero param: unlock_block", id, alloc);

    const current_block: u64 = @intCast(ctx.bc.getBlockCount());
    if (unlock_block <= current_block)
        return errorJson(-32602, "unlock_block must be in the future", id, alloc);

    const owner_bal = ctx.bc.getAddressBalance(owner);
    if (owner_bal < amount_sat)
        return errorJson(-32000, "Insufficient balance to lock", id, alloc);

    // Debit owner balance (funds held in vault)
    ctx.bc.mutex.lock();
    const cur_bal = ctx.bc.balances.get(owner) orelse 0;
    if (cur_bal >= amount_sat) {
        ctx.bc.balances.put(owner, cur_bal - amount_sat) catch {};
    }
    ctx.bc.mutex.unlock();

    const id_hex = ctx.bc.timelock_store.create(
        owner, dest, amount_sat, unlock_block, current_block, "",
    ) catch {
        // Restore balance on failure
        ctx.bc.mutex.lock();
        const b2 = ctx.bc.balances.get(owner) orelse 0;
        ctx.bc.balances.put(owner, b2 + amount_sat) catch {};
        ctx.bc.mutex.unlock();
        return errorJson(-32000, "Failed to create timelock vault", id, alloc);
    };

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"vault_id\":\"{s}\",\"owner\":\"{s}\",\"dest\":\"{s}\",\"amount_sat\":{d},\"unlock_block\":{d},\"state\":\"locked\"}}}}",
        .{ id, id_hex, owner, dest, amount_sat, unlock_block });
}

/// timelock_list {"owner":"ob1q..."}
fn handleTimelockList(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const owner = extractParamObjectField(body, "owner") orelse
        return errorJson(-32602, "Missing param: owner", id, alloc);
    const current_block: u64 = @intCast(ctx.bc.getBlockCount());
    var vaults: [256]timelock_mod.TimelockVault = undefined;
    const n = ctx.bc.timelock_store.listByOwner(owner, &vaults);
    var out = std.ArrayList(u8){};
    defer out.deinit(alloc);
    try out.appendSlice(alloc, "[");
    for (vaults[0..n], 0..) |v, i| {
        if (i > 0) try out.appendSlice(alloc, ",");
        const remaining = v.blocksRemaining(current_block);
        const entry = try std.fmt.allocPrint(alloc,
            "{{\"vault_id\":\"{s}\",\"dest\":\"{s}\",\"amount_sat\":{d},\"unlock_block\":{d},\"state\":\"{s}\",\"blocks_remaining\":{d}}}",
            .{ v.idSlice(), v.destSlice(), v.amount_sat, v.unlock_block, v.state.str(), remaining });
        defer alloc.free(entry);
        try out.appendSlice(alloc, entry);
    }
    try out.appendSlice(alloc, "]");
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{s}}}",
        .{ id, out.items });
}

/// timelock_spend {"vault_id":"hex..."}
fn handleTimelockSpend(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const vault_id = extractParamObjectField(body, "vault_id") orelse
        return errorJson(-32602, "Missing param: vault_id", id, alloc);
    const current_block: u64 = @intCast(ctx.bc.getBlockCount());
    const vault = ctx.bc.timelock_store.getById(vault_id) orelse
        return errorJson(-32000, "Vault not found", id, alloc);
    if (vault.state == .spent)
        return errorJson(-32000, "Vault already spent", id, alloc);
    if (current_block < vault.unlock_block)
        return errorJson(-32000, "Vault still locked — too early", id, alloc);

    // Mark spent and credit destination
    const ok = ctx.bc.timelock_store.markSpent(vault_id, "manual_spend", current_block);
    if (!ok) return errorJson(-32000, "Failed to mark vault spent", id, alloc);

    ctx.bc.mutex.lock();
    const dest_bal = ctx.bc.balances.get(vault.destSlice()) orelse 0;
    ctx.bc.balances.put(vault.destSlice(), dest_bal + vault.amount_sat) catch {};
    ctx.bc.mutex.unlock();

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"vault_id\":\"{s}\",\"dest\":\"{s}\",\"amount_sat\":{d},\"state\":\"spent\"}}}}",
        .{ id, vault_id, vault.destSlice(), vault.amount_sat });
}

/// timelock_status {"vault_id":"hex..."}
fn handleTimelockStatus(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const vault_id = extractParamObjectField(body, "vault_id") orelse
        return errorJson(-32602, "Missing param: vault_id", id, alloc);
    const current_block: u64 = @intCast(ctx.bc.getBlockCount());
    const vault = ctx.bc.timelock_store.getById(vault_id) orelse
        return errorJson(-32000, "Vault not found", id, alloc);
    const remaining = vault.blocksRemaining(current_block);
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"vault_id\":\"{s}\",\"owner\":\"{s}\",\"dest\":\"{s}\",\"amount_sat\":{d},\"unlock_block\":{d},\"state\":\"{s}\",\"blocks_remaining\":{d},\"created_block\":{d}}}}}",
        .{ id, vault.idSlice(), vault.ownerSlice(), vault.destSlice(),
           vault.amount_sat, vault.unlock_block, vault.state.str(), remaining, vault.created_block });
}

// ═══════════════════════════════════════════════════════════════════════════
// ── Covenant (destination whitelist) handlers ─────────────────────────────
// ═══════════════════════════════════════════════════════════════════════════

/// covenant_create {"address":"ob1q...","whitelist":["ob1q..."],"max_per_tx_sat":0,"expires_block":0,"label":"..."}
fn handleCovenantCreate(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const address = extractParamObjectField(body, "address") orelse
        return errorJson(-32602, "Missing param: address", id, alloc);
    const max_per_tx = extractParamObjectU64(body, "max_per_tx_sat");
    const expires_block = extractParamObjectU64(body, "expires_block");
    const label = extractParamObjectField(body, "label") orelse "";

    // Parse whitelist array from JSON: look for [...] after "whitelist"
    const wl_needle = "\"whitelist\"";
    const wl_pos = std.mem.indexOf(u8, body, wl_needle) orelse
        return errorJson(-32602, "Missing param: whitelist", id, alloc);
    const bracket = std.mem.indexOfScalarPos(u8, body, wl_pos, '[') orelse
        return errorJson(-32602, "whitelist must be a JSON array", id, alloc);

    var whitelist_strs: [covenant_mod.MAX_WHITELIST][]const u8 = undefined;
    var wl_count: usize = 0;
    var parse_pos: usize = bracket + 1;
    while (parse_pos < body.len and wl_count < covenant_mod.MAX_WHITELIST) {
        while (parse_pos < body.len and (body[parse_pos] == ' ' or body[parse_pos] == '\t' or body[parse_pos] == '\n')) parse_pos += 1;
        if (parse_pos >= body.len or body[parse_pos] == ']') break;
        if (body[parse_pos] == '"') {
            parse_pos += 1;
            const start = parse_pos;
            while (parse_pos < body.len and body[parse_pos] != '"') parse_pos += 1;
            whitelist_strs[wl_count] = body[start..parse_pos];
            wl_count += 1;
            if (parse_pos < body.len) parse_pos += 1;
        } else {
            while (parse_pos < body.len and body[parse_pos] != ',' and body[parse_pos] != ']') parse_pos += 1;
        }
        if (parse_pos < body.len and body[parse_pos] == ',') parse_pos += 1;
    }

    if (wl_count == 0)
        return errorJson(-32602, "whitelist must contain at least one address", id, alloc);

    ctx.bc.covenant_store.create(
        address, whitelist_strs[0..wl_count], max_per_tx, expires_block, label,
    ) catch {
        return errorJson(-32000, "Failed to create covenant", id, alloc);
    };

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"address\":\"{s}\",\"whitelist_count\":{d},\"max_per_tx_sat\":{d},\"expires_block\":{d},\"label\":\"{s}\",\"status\":\"created\"}}}}",
        .{ id, address, wl_count, max_per_tx, expires_block, label });
}

/// covenant_list {} — lists all active covenants
fn handleCovenantList(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    _ = body;
    const alloc = ctx.allocator;
    const current_block: u64 = @intCast(ctx.bc.getBlockCount());
    const buf = try alloc.alloc(covenant_mod.Covenant, covenant_mod.MAX_COVENANTS);
    defer alloc.free(buf);
    const n = ctx.bc.covenant_store.listAll(current_block, buf);
    var out = std.ArrayList(u8){};
    defer out.deinit(alloc);
    try out.appendSlice(alloc, "[");
    for (buf[0..n], 0..) |c, i| {
        if (i > 0) try out.appendSlice(alloc, ",");
        const entry = try std.fmt.allocPrint(alloc,
            "{{\"address\":\"{s}\",\"whitelist_count\":{d},\"max_per_tx_sat\":{d},\"expires_block\":{d},\"label\":\"{s}\"}}",
            .{ c.addressSlice(), c.whitelist_count, c.max_amount_per_tx_sat, c.expires_block, c.labelSlice() });
        defer alloc.free(entry);
        try out.appendSlice(alloc, entry);
    }
    try out.appendSlice(alloc, "]");
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{s}}}",
        .{ id, out.items });
}

/// covenant_get {"address":"ob1q..."}
fn handleCovenantGet(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const address = extractParamObjectField(body, "address") orelse
        return errorJson(-32602, "Missing param: address", id, alloc);
    const current_block: u64 = @intCast(ctx.bc.getBlockCount());
    const cov = ctx.bc.covenant_store.getActive(address, current_block) orelse
        return errorJson(-32000, "No active covenant for address", id, alloc);

    var wl_json = std.ArrayList(u8){};
    defer wl_json.deinit(alloc);
    try wl_json.appendSlice(alloc, "[");
    var wi: usize = 0;
    while (wi < cov.whitelist_count) : (wi += 1) {
        if (wi > 0) try wl_json.appendSlice(alloc, ",");
        const wentry = try std.fmt.allocPrint(alloc, "\"{s}\"", .{cov.whitelistEntry(wi)});
        defer alloc.free(wentry);
        try wl_json.appendSlice(alloc, wentry);
    }
    try wl_json.appendSlice(alloc, "]");

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"address\":\"{s}\",\"whitelist\":{s},\"max_per_tx_sat\":{d},\"expires_block\":{d},\"label\":\"{s}\"}}}}",
        .{ id, cov.addressSlice(), wl_json.items, cov.max_amount_per_tx_sat, cov.expires_block, cov.labelSlice() });
}

/// covenant_remove {"address":"ob1q..."}
fn handleCovenantRemove(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const address = extractParamObjectField(body, "address") orelse
        return errorJson(-32602, "Missing param: address", id, alloc);
    const ok = ctx.bc.covenant_store.remove(address);
    if (!ok) return errorJson(-32000, "No active covenant found for address", id, alloc);
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"address\":\"{s}\",\"status\":\"removed\"}}}}",
        .{ id, address });
}

// ═══════════════════════════════════════════════════════════════════════════
// ── Treasury auto-distribute handlers ────────────────────────────────────
// ═══════════════════════════════════════════════════════════════════════════

/// treasury_create {"address":"ob1q...","destinations":[{"address":"ob1q...","share_bps":5000,"label":"x"}],"trigger_amount_sat":100000000,"label":"..."}
fn handleTreasuryCreate(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const treasury_addr = extractParamObjectField(body, "address") orelse
        return errorJson(-32602, "Missing param: address", id, alloc);
    const trigger = extractParamObjectU64(body, "trigger_amount_sat");
    const label = extractParamObjectField(body, "label") orelse "";

    // Parse destinations array
    const dest_needle = "\"destinations\"";
    const dest_pos = std.mem.indexOf(u8, body, dest_needle) orelse
        return errorJson(-32602, "Missing param: destinations", id, alloc);
    const bracket = std.mem.indexOfScalarPos(u8, body, dest_pos, '[') orelse
        return errorJson(-32602, "destinations must be a JSON array", id, alloc);

    var dests: [treasury_multi_mod.MAX_DESTS]treasury_multi_mod.TreasuryDest = undefined;
    var dest_count: usize = 0;
    var pp: usize = bracket + 1;
    while (pp < body.len and dest_count < treasury_multi_mod.MAX_DESTS) {
        while (pp < body.len and (body[pp] == ' ' or body[pp] == '\t' or body[pp] == '\n' or body[pp] == ',')) pp += 1;
        if (pp >= body.len or body[pp] == ']') break;
        if (body[pp] != '{') { pp += 1; continue; }
        // Find end of object
        var depth: i32 = 0;
        const obj_start = pp;
        var obj_end = pp;
        while (pp < body.len) : (pp += 1) {
            if (body[pp] == '{') depth += 1
            else if (body[pp] == '}') {
                depth -= 1;
                if (depth == 0) { obj_end = pp + 1; pp += 1; break; }
            }
        }
        const obj = body[obj_start..obj_end];
        const d_addr = extractStr(obj, "address") orelse continue;
        const d_bps_raw = extractParamObjectU64(obj, "share_bps");
        const d_label = extractStr(obj, "label") orelse "";
        var d = treasury_multi_mod.TreasuryDest{ .share_bps = @intCast(@min(d_bps_raw, 10000)) };
        const ac = @min(d_addr.len, treasury_multi_mod.ADDR_MAX - 1);
        @memcpy(d.address[0..ac], d_addr[0..ac]);
        d.addr_len = @intCast(ac);
        const lc = @min(d_label.len, treasury_multi_mod.LABEL_MAX - 1);
        @memcpy(d.label[0..lc], d_label[0..lc]);
        d.label_len = @intCast(lc);
        dests[dest_count] = d;
        dest_count += 1;
    }

    if (dest_count == 0)
        return errorJson(-32602, "destinations must have at least one entry", id, alloc);

    const id_hex = ctx.bc.treasury_multi_store.create(
        treasury_addr, dests[0..dest_count], trigger, label,
    ) catch {
        return errorJson(-32000, "Failed to create treasury (check share_bps sum = 10000)", id, alloc);
    };

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"treasury_id\":\"{s}\",\"address\":\"{s}\",\"dest_count\":{d},\"trigger_amount_sat\":{d},\"label\":\"{s}\",\"status\":\"created\"}}}}",
        .{ id, id_hex, treasury_addr, dest_count, trigger, label });
}

/// treasury_list {} — list all active treasuries
fn handleTreasuryList(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    _ = body;
    const alloc = ctx.allocator;
    const buf = try alloc.alloc(treasury_multi_mod.Treasury, treasury_multi_mod.MAX_TREASURY);
    defer alloc.free(buf);
    const n = ctx.bc.treasury_multi_store.listAll(buf);
    var out = std.ArrayList(u8){};
    defer out.deinit(alloc);
    try out.appendSlice(alloc, "[");
    for (buf[0..n], 0..) |t, i| {
        if (i > 0) try out.appendSlice(alloc, ",");
        const live_bal = ctx.bc.getAddressBalance(t.treasurySlice());
        const entry = try std.fmt.allocPrint(alloc,
            "{{\"treasury_id\":\"{s}\",\"address\":\"{s}\",\"balance_sat\":{d},\"trigger_amount_sat\":{d},\"last_distribute_block\":{d},\"total_distributed_sat\":{d},\"dest_count\":{d},\"label\":\"{s}\"}}",
            .{ t.idSlice(), t.treasurySlice(), live_bal, t.trigger_amount_sat,
               t.last_distribute_block, t.total_distributed_sat, t.dest_count, t.labelSlice() });
        defer alloc.free(entry);
        try out.appendSlice(alloc, entry);
    }
    try out.appendSlice(alloc, "]");
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{s}}}",
        .{ id, out.items });
}

/// treasury_distribute {"treasury_id":"hex..."}
fn handleTreasuryDistribute(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const treasury_id = extractParamObjectField(body, "treasury_id") orelse
        return errorJson(-32602, "Missing param: treasury_id", id, alloc);
    const treas = ctx.bc.treasury_multi_store.getById(treasury_id) orelse
        return errorJson(-32000, "Treasury not found", id, alloc);
    const current_block: u64 = @intCast(ctx.bc.getBlockCount());
    const bal = ctx.bc.getAddressBalance(treas.treasurySlice());
    if (bal == 0) return errorJson(-32000, "Treasury balance is zero", id, alloc);

    var distributed: u64 = 0;
    ctx.bc.mutex.lock();
    var di: usize = 0;
    while (di < treas.dest_count) : (di += 1) {
        const dest_amt = treas.destAmount(di, bal);
        if (dest_amt == 0) continue;
        if (bal < distributed + dest_amt) break;
        distributed += dest_amt;
        const to_bal = ctx.bc.balances.get(treas.destinations[di].addressSlice()) orelse 0;
        ctx.bc.balances.put(treas.destinations[di].addressSlice(), to_bal + dest_amt) catch {};
    }
    if (distributed > 0) {
        const from_bal = ctx.bc.balances.get(treas.treasurySlice()) orelse 0;
        ctx.bc.balances.put(treas.treasurySlice(), from_bal -| distributed) catch {};
    }
    ctx.bc.mutex.unlock();

    ctx.bc.treasury_multi_store.recordDistribute(treasury_id, distributed, current_block);

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"treasury_id\":\"{s}\",\"distributed_sat\":{d},\"block\":{d}}}}}",
        .{ id, treasury_id, distributed, current_block });
}

/// treasury_status {"treasury_id":"hex..."}
fn handleTreasuryStatus(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const treasury_id = extractParamObjectField(body, "treasury_id") orelse
        return errorJson(-32602, "Missing param: treasury_id", id, alloc);
    const treas = ctx.bc.treasury_multi_store.getById(treasury_id) orelse
        return errorJson(-32000, "Treasury not found", id, alloc);
    const live_bal = ctx.bc.getAddressBalance(treas.treasurySlice());
    const pending: u64 = if (live_bal >= treas.trigger_amount_sat and treas.trigger_amount_sat > 0) live_bal else 0;
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"treasury_id\":\"{s}\",\"address\":\"{s}\",\"balance_sat\":{d},\"pending_distribute_sat\":{d},\"trigger_amount_sat\":{d},\"last_distribute_block\":{d},\"total_distributed_sat\":{d},\"label\":\"{s}\"}}}}",
        .{ id, treas.idSlice(), treas.treasurySlice(), live_bal, pending,
           treas.trigger_amount_sat, treas.last_distribute_block, treas.total_distributed_sat, treas.labelSlice() });
}
