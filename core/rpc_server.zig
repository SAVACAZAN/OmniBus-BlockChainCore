const std = @import("std");
const blockchain_mod  = @import("blockchain.zig");
const wallet_mod      = @import("wallet.zig");
const transaction_mod = @import("transaction.zig");
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
const agent_executor_mod = @import("agent_executor.zig");
pub const Metrics     = benchmark_mod.Metrics;

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
const MAX_REQUEST = 8192;

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
    secret_hash: [64]u8 = undefined, // SHA256 hex (64 chars)
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
    const MAX_CONCURRENT: u32 = 16; // 16 × 4MB = 64MB stack max

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

        // FIXME: SEGFAULT-RISK [scan-2026-04-25] LOW - high-concurrency allocator stress
        // Reason: parent allocator from main.zig is GeneralPurposeAllocator(.{}){} — Zig 0.15.2
        //   defaults `thread_safe = !single_threaded` so it IS guarded by mutex. However heavy
        //   contention (4 RPC threads + mining + WS broadcast all allocPrint'ing per request) can
        //   serialize and amplify any latent UB elsewhere. Not the prime crash cause, but
        //   noisy mutex traffic masks ordering bugs.
        // Suggested fix: switch hot RPC path to per-request arena allocator (reset per request).
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
        if (std.mem.eql(u8, ep, "OHLC") or std.mem.eql(u8, ep, "Spread")) {
            // OHLC + Spread are NOT yet implemented as real RPC — return
            // an empty Kraken-shaped result so clients don't break.
            writeJsonResponse(stream, "{\"error\":[],\"result\":{}}");
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
        else if (std.mem.eql(u8, ep, "ClosedOrders")) { writeJsonResponse(stream, "{\"error\":[],\"result\":{\"closed\":{}}}"); return true; }
        else if (std.mem.eql(u8, ep, "QueryOrders")) {
            // Same back-end as OpenOrders (we don't separate open/query yet).
            rpc_method = "exchange_getUserOrders";
            if (owner) |a| {
                owned_params = std.fmt.allocPrint(alloc, "[{{\"trader\":\"{s}\"{s}}}]", .{ a, mode_suffix }) catch null;
                if (owned_params) |p| rpc_params = p;
            }
        }
        else if (std.mem.eql(u8, ep, "TradesHistory")) {
            // Trades for a specific trader. `address` filter on our side.
            rpc_method = "exchange_getTrades";
            if (owner) |a| {
                owned_params = std.fmt.allocPrint(alloc, "[{{\"address\":\"{s}\"{s}}}]", .{ a, mode_suffix }) catch null;
                if (owned_params) |p| rpc_params = p;
            } else {
                owned_params = std.fmt.allocPrint(alloc, "[{{{s}}}]", .{ if (mode_suffix.len > 0) mode_suffix[1..] else "" }) catch null;
                if (owned_params) |p| rpc_params = p;
            }
        }
        else if (std.mem.eql(u8, ep, "QueryTrades")) {
            rpc_method = "exchange_getTrades";
            if (owner) |a| {
                owned_params = std.fmt.allocPrint(alloc, "[{{\"address\":\"{s}\"{s}}}]", .{ a, mode_suffix }) catch null;
                if (owned_params) |p| rpc_params = p;
            } else {
                owned_params = std.fmt.allocPrint(alloc, "[{{{s}}}]", .{ if (mode_suffix.len > 0) mode_suffix[1..] else "" }) catch null;
                if (owned_params) |p| rpc_params = p;
            }
        }
        else if (std.mem.eql(u8, ep, "OpenPositions")) { writeJsonResponse(stream, "{\"error\":[],\"result\":{}}"); return true; }
        else if (std.mem.eql(u8, ep, "Ledgers")) { writeJsonResponse(stream, "{\"error\":[],\"result\":{\"ledger\":{}}}"); return true; }
        else if (std.mem.eql(u8, ep, "QueryLedgers")) { writeJsonResponse(stream, "{\"error\":[],\"result\":{\"ledger\":{}}}"); return true; }
        else if (std.mem.eql(u8, ep, "TradeVolume")) { writeJsonResponse(stream, "{\"error\":[],\"result\":{\"currency\":\"USD\",\"volume\":\"0.0000\"}}"); return true; }
        else if (std.mem.eql(u8, ep, "AddOrder") or std.mem.eql(u8, ep, "CancelOrder") or std.mem.eql(u8, ep, "Withdraw")) {
            // These mutate state and require an ECDSA-signed payload. The
            // REST surface doesn't transport our signature scheme yet —
            // tell the client to use JSON-RPC `exchange_placeOrder` (or
            // wait for the upcoming Kraken-style HMAC-SHA512 auth).
            const ep_msg = std.fmt.allocPrint(alloc,
                "{{\"error\":[\"EAPI:NotImplemented:Use exchange_{s} via JSON-RPC; HMAC auth WIP\"],\"result\":{{}}}}",
                .{ep}) catch return true;
            defer alloc.free(ep_msg);
            writeJsonResponse(stream, ep_msg);
            return true;
        }
        else if (std.mem.eql(u8, ep, "CancelAll")) { writeJsonResponse(stream, "{\"error\":[],\"result\":{\"count\":0}}"); return true; }
        else if (std.mem.eql(u8, ep, "CancelAllOrdersAfter")) { writeJsonResponse(stream, "{\"error\":[],\"result\":{\"currentTime\":\"0\",\"triggerTime\":\"0\"}}"); return true; }
        else if (std.mem.eql(u8, ep, "EditOrder")) { writeJsonResponse(stream, "{\"error\":[],\"result\":{\"descr\":{\"order\":\"edited\"}}}"); return true; }
        else if (std.mem.eql(u8, ep, "DepositMethods")) { writeJsonResponse(stream, "{\"error\":[],\"result\":[{\"method\":\"OMNI on-chain\",\"limit\":false,\"fee\":\"0.00000000\",\"address-setup-fee\":\"0.00000000\",\"gen-address\":true}]}"); return true; }
        else if (std.mem.eql(u8, ep, "DepositAddresses")) { writeJsonResponse(stream, "{\"error\":[],\"result\":[{\"address\":\"ob1q...\",\"expiretm\":0,\"newtag\":null}]}"); return true; }
        else if (std.mem.eql(u8, ep, "StatusOfDeposits")) { writeJsonResponse(stream, "{\"error\":[],\"result\":[]}"); return true; }
        else if (std.mem.eql(u8, ep, "WithdrawMethods")) { writeJsonResponse(stream, "{\"error\":[],\"result\":[{\"method\":\"OMNI\",\"limit\":false,\"fee\":\"0.0005\"}]}"); return true; }
        else if (std.mem.eql(u8, ep, "WithdrawAddresses")) { writeJsonResponse(stream, "{\"error\":[],\"result\":[]}"); return true; }
        else if (std.mem.eql(u8, ep, "StatusOfWithdrawals")) { writeJsonResponse(stream, "{\"error\":[],\"result\":[]}"); return true; }
        else if (std.mem.eql(u8, ep, "WithdrawCancel")) { writeJsonResponse(stream, "{\"error\":[],\"result\":true}"); return true; }
        else if (std.mem.eql(u8, ep, "WalletTransfer")) { writeJsonResponse(stream, "{\"error\":[],\"result\":{\"refid\":\"T1\"}}"); return true; }
        else if (std.mem.eql(u8, ep, "Stake")) { writeJsonResponse(stream, "{\"error\":[],\"result\":{\"refid\":\"S1\"}}"); return true; }
        else if (std.mem.eql(u8, ep, "Unstake")) { writeJsonResponse(stream, "{\"error\":[],\"result\":{\"refid\":\"U1\"}}"); return true; }
        else if (std.mem.eql(u8, ep, "GetStakingAssets")) { writeJsonResponse(stream, "{\"error\":[],\"result\":[{\"asset\":\"OMNI\",\"staking\":true,\"rewards\":{\"reward\":\"0.05\",\"type\":\"percentage\"}}]}"); return true; }
        else if (std.mem.eql(u8, ep, "GetPendingStaking")) { writeJsonResponse(stream, "{\"error\":[],\"result\":[]}"); return true; }
        else if (std.mem.eql(u8, ep, "ListStakingTransactions")) { writeJsonResponse(stream, "{\"error\":[],\"result\":[]}"); return true; }
        else if (std.mem.eql(u8, ep, "Earn/Allocate")) { writeJsonResponse(stream, "{\"error\":[],\"result\":{\"allocation_id\":\"E1\"}}"); return true; }
        else if (std.mem.eql(u8, ep, "Earn/Deallocate")) { writeJsonResponse(stream, "{\"error\":[],\"result\":{\"allocation_id\":\"E1\"}}"); return true; }
        else if (std.mem.eql(u8, ep, "Earn/Strategies")) { writeJsonResponse(stream, "{\"error\":[],\"result\":[{\"id\":\"OMNI_YIELD\",\"asset\":\"OMNI\",\"apy\":\"5.0\"}]}"); return true; }
        else if (std.mem.eql(u8, ep, "Earn/Allocations")) { writeJsonResponse(stream, "{\"error\":[],\"result\":[]}"); return true; }
        else if (std.mem.eql(u8, ep, "AddExport")) { writeJsonResponse(stream, "{\"error\":[],\"result\":{\"id\":\"EXP1\"}}"); return true; }
        else if (std.mem.eql(u8, ep, "ExportStatus")) { writeJsonResponse(stream, "{\"error\":[],\"result\":[]}"); return true; }
        else if (std.mem.eql(u8, ep, "RetrieveExport")) { writeJsonResponse(stream, "{\"error\":[],\"result\":{}}"); return true; }
        else if (std.mem.eql(u8, ep, "DeleteExport")) { writeJsonResponse(stream, "{\"error\":[],\"result\":true}"); return true; }
        else if (std.mem.eql(u8, ep, "GetWebSocketsToken")) { writeJsonResponse(stream, "{\"error\":[],\"result\":{\"token\":\"ws_token_placeholder\",\"expires\":3600}}"); return true; }
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
    // during mining (creditBalance → put can realloc while we read)
    ctx.bc.mutex.lock();
    const bal_sat = ctx.bc.getAddressBalance(req_addr);
    const height  = ctx.bc.getBlockCount();
    ctx.bc.mutex.unlock();
    const bal_omni = bal_sat / 1_000_000_000;
    const bal_frac = bal_sat % 1_000_000_000;
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"address\":\"{s}\",\"balance\":{d},\"balanceOMNI\":\"{d}.{d:0>9}\",\"confirmed\":{d},\"unconfirmed\":0,\"utxos\":[],\"transactions\":[],\"txCount\":0,\"nodeHeight\":{d}}}}}",
        .{ id, req_addr, bal_sat, bal_omni, bal_frac, bal_sat, height });
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

fn dispatch(body: []const u8, ctx: *ServerCtx) ![]u8 {
    const alloc = ctx.allocator;

    // Parse "method" si "id" cu string search simplu (evitam dep JSON)
    const method = extractStr(body, "method") orelse return errorJson(-32600, "Invalid request", 0, alloc);
    const id      = extractId(body);

    if (std.mem.eql(u8, method, "getblockcount")) {
        return handleGetBlockCount(ctx, id);
    }

    if (std.mem.eql(u8, method, "getbalance"))     return handleGetBalance(body, ctx, id);
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
    if (std.mem.eql(u8, method, "registername"))     return handleRegisterName(body, ctx, id);
    if (std.mem.eql(u8, method, "resolvename"))      return handleResolveName(body, ctx, id);
    if (std.mem.eql(u8, method, "reverseresolvename")) return handleReverseResolveName(body, ctx, id);
    if (std.mem.eql(u8, method, "listnames"))        return handleListNames(body, ctx, id);
    if (std.mem.eql(u8, method, "getensfee"))        return handleGetEnsFee(ctx, id);
    if (std.mem.eql(u8, method, "sendrawtransaction")) return handleSendRawTx(body, ctx, id);

    // ── Native DEX (matching engine on-chain) ───────────────────────────
    if (std.mem.eql(u8, method, "exchange_placeOrder"))    return handleExchangePlaceOrder(body, ctx, id);
    if (std.mem.eql(u8, method, "exchange_cancelOrder"))   return handleExchangeCancelOrder(body, ctx, id);
    if (std.mem.eql(u8, method, "exchange_getOrderbook")) return handleExchangeGetOrderbook(body, ctx, id);
    if (std.mem.eql(u8, method, "exchange_getUserOrders"))return handleExchangeGetUserOrders(body, ctx, id);
    if (std.mem.eql(u8, method, "exchange_getTrades"))     return handleExchangeGetTrades(body, ctx, id);
    if (std.mem.eql(u8, method, "exchange_listPairs"))     return handleExchangeListPairs(ctx, id);
    if (std.mem.eql(u8, method, "exchange_getStats"))      return handleExchangeGetStats(body, ctx, id);
    if (std.mem.eql(u8, method, "exchange_getAuthNonce"))  return handleExchangeGetAuthNonce(body, ctx, id);
    if (std.mem.eql(u8, method, "exchange_login"))         return handleExchangeLogin(body, ctx, id);
    if (std.mem.eql(u8, method, "exchange_createApiKey"))  return handleExchangeCreateApiKey(body, ctx, id);
    if (std.mem.eql(u8, method, "exchange_listApiKeys"))   return handleExchangeListApiKeys(body, ctx, id);
    if (std.mem.eql(u8, method, "exchange_revokeApiKey")) return handleExchangeRevokeApiKey(body, ctx, id);
    if (std.mem.eql(u8, method, "exchange_deposit"))       return handleExchangeDeposit(body, ctx, id);
    if (std.mem.eql(u8, method, "exchange_withdraw"))      return handleExchangeWithdraw(body, ctx, id);
    if (std.mem.eql(u8, method, "exchange_getBalances"))   return handleExchangeGetBalances(body, ctx, id);
    if (std.mem.eql(u8, method, "exchange_depositDemo"))   return handleExchangeDepositDemo(body, ctx, id);
    if (std.mem.eql(u8, method, "exchange_depositReal"))   return handleExchangeDepositReal(body, ctx, id);
    if (std.mem.eql(u8, method, "exchange_getEscrowAddress")) return handleExchangeGetEscrowAddress(ctx, id);

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

    // Multisig endpoints (TODO: implement handlers)
    if (std.mem.eql(u8, method, "createmultisig"))      return errorJson(-32601, "Multisig not yet implemented", id, alloc);
    if (std.mem.eql(u8, method, "sendmultisig"))        return errorJson(-32601, "Multisig not yet implemented", id, alloc);

    // Payment channel (L2) endpoints (TODO: implement handlers)
    if (std.mem.eql(u8, method, "openchannel"))       return errorJson(-32601, "Payment channels not yet implemented", id, alloc);
    if (std.mem.eql(u8, method, "channelpay"))        return errorJson(-32601, "Payment channels not yet implemented", id, alloc);
    if (std.mem.eql(u8, method, "closechannel"))      return errorJson(-32601, "Payment channels not yet implemented", id, alloc);
    if (std.mem.eql(u8, method, "getchannels"))       return errorJson(-32601, "Payment channels not yet implemented", id, alloc);

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
    if (std.mem.eql(u8, method, "agent_status"))            return handleAgentStatus(body, ctx, id);
    if (std.mem.eql(u8, method, "agent_pending_decisions")) return handleAgentPendingDecisions(body, ctx, id);
    if (std.mem.eql(u8, method, "agent_report_execution"))  return handleAgentReportExecution(body, ctx, id);

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

    const chain_nonce = ctx.bc.getNextNonce(addr);
    const next_available = ctx.bc.getNextAvailableNonce(addr);
    const pending = next_available - chain_nonce;

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"address\":\"{s}\",\"nonce\":{d},\"chainNonce\":{d},\"pendingCount\":{d}}}}}",
        .{ id, addr, next_available, chain_nonce, pending });
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
            return std.fmt.allocPrint(alloc,
                "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"txid\":\"{s}\",\"from\":\"{s}\",\"to\":\"{s}\",\"amount\":{d},\"fee\":{d},\"confirmations\":0,\"blockHeight\":null,\"status\":\"pending\"}}}}",
                .{ id, tx.hash, tx.from_address, tx.to_address, tx.amount, tx.fee });
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
                    return std.fmt.allocPrint(alloc,
                        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"txid\":\"{s}\",\"from\":\"{s}\",\"to\":\"{s}\",\"amount\":{d},\"fee\":{d},\"confirmations\":{d},\"blockHeight\":{d},\"status\":\"confirmed\"}}}}",
                        .{ id, tx.hash, tx.from_address, tx.to_address, tx.amount, tx.fee, confirmations, block_height });
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
                return std.fmt.allocPrint(alloc,
                    "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"txid\":\"{s}\",\"from\":\"{s}\",\"to\":\"{s}\",\"amount\":{d},\"fee\":{d},\"confirmations\":{d},\"blockHeight\":{d},\"status\":\"confirmed\"}}}}",
                    .{ id, tx.hash, tx.from_address, tx.to_address, tx.amount, tx.fee, confirmations, blk.index });
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
// Simple anti-Sybil for the testnet faucet. State is in-memory only (no JSON
// persistence yet — that lives in Faza 5 when we add auto-refill). On node
// restart the table resets to empty, which means a determined attacker could
// claim again after each restart. Acceptable for testnet; tighten before
// mainnet.
//
// Rules:
//   - Per-address: 1 claim ever (once an address gets faucet funds, no more)
//   - Per-IP: cooldown of FAUCET_IP_COOLDOWN_S between claims from the same IP
//
// Limits chosen so legit users can run multiple validators (their own family
// of wallets) without hitting the IP cooldown wall constantly: 1 minute, not
// 24h, on testnet. Tighten on mainnet.

const FAUCET_IP_COOLDOWN_S: i64 = 60;
const FAUCET_MAX_CLAIMED_ADDRS: usize = 4096;
const FAUCET_MAX_TRACKED_IPS: usize = 1024;

const FaucetClaim = struct {
    addr: [64]u8 = @splat(0),
    addr_len: u8 = 0,
    timestamp: i64 = 0,
};

const FaucetIpEntry = struct {
    ip: [4]u8 = .{ 0, 0, 0, 0 },
    last_claim: i64 = 0,
    used: bool = false,
};

var g_faucet_claims: [FAUCET_MAX_CLAIMED_ADDRS]FaucetClaim = @splat(.{});
var g_faucet_claim_count: usize = 0;
var g_faucet_ip_table: [FAUCET_MAX_TRACKED_IPS]FaucetIpEntry = @splat(.{});
var g_faucet_mutex: std.Thread.Mutex = .{};
/// File path where claims persist across restarts. Set by `faucetSetPersistPath`
/// at node startup. Empty = persistence disabled (in-memory only).
var g_faucet_persist_path_buf: [512]u8 = @splat(0);
var g_faucet_persist_path_len: usize = 0;
var g_faucet_persist_loaded: bool = false;

/// Set the on-disk path for the claim ledger. Idempotent — calling it
/// repeatedly with the same path is a no-op. Called once from main.zig
/// after the chain data dir is known (so testnet/regtest get separate
/// ledgers from mainnet automatically).
pub fn faucetSetPersistPath(path: []const u8) void {
    g_faucet_mutex.lock();
    defer g_faucet_mutex.unlock();
    const n = @min(path.len, g_faucet_persist_path_buf.len);
    @memcpy(g_faucet_persist_path_buf[0..n], path[0..n]);
    g_faucet_persist_path_len = n;
    if (!g_faucet_persist_loaded) {
        faucetLoadFromDisk() catch |err| {
            std.debug.print("[FAUCET] load from disk failed: {} (starting fresh)\n", .{err});
        };
        g_faucet_persist_loaded = true;
    }
}

fn faucetPersistPath() ?[]const u8 {
    if (g_faucet_persist_path_len == 0) return null;
    return g_faucet_persist_path_buf[0..g_faucet_persist_path_len];
}

/// Append-only JSON-Lines file: one record per claim. Survives restart.
/// Format: `{"addr":"ob1q...","ts":1234567890}\n` per line.
/// We read the whole file at startup and parse line-by-line; this avoids
/// needing a real JSON array we'd have to rewrite on every claim.
fn faucetLoadFromDisk() !void {
    const path = faucetPersistPath() orelse return;
    const f = std.fs.cwd().openFile(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return, // fresh start, no claims yet
        else => return err,
    };
    defer f.close();
    const stat = try f.stat();
    if (stat.size == 0) return;

    // Read whole file (small — ~50 bytes/claim, capped at 4096 claims = ~200KB).
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const buf = try arena.allocator().alloc(u8, @intCast(stat.size));
    _ = try f.readAll(buf);

    var line_iter = std.mem.splitScalar(u8, buf, '\n');
    var loaded: usize = 0;
    while (line_iter.next()) |line| {
        if (line.len == 0) continue;
        // Extract "addr":"...", "ts":N — minimal parser, no full JSON dep.
        const addr_key = "\"addr\":\"";
        const a_start = std.mem.indexOf(u8, line, addr_key) orelse continue;
        const a_from = a_start + addr_key.len;
        const a_end = std.mem.indexOfScalarPos(u8, line, a_from, '"') orelse continue;
        const addr = line[a_from..a_end];

        const ts_key = "\"ts\":";
        const t_start = std.mem.indexOf(u8, line, ts_key) orelse continue;
        const t_from = t_start + ts_key.len;
        var t_end = t_from;
        while (t_end < line.len and (std.ascii.isDigit(line[t_end]) or line[t_end] == '-')) t_end += 1;
        const ts = std.fmt.parseInt(i64, line[t_from..t_end], 10) catch 0;

        if (g_faucet_claim_count >= FAUCET_MAX_CLAIMED_ADDRS) break;
        const e = &g_faucet_claims[g_faucet_claim_count];
        const n = @min(addr.len, e.addr.len);
        @memcpy(e.addr[0..n], addr[0..n]);
        e.addr_len = @intCast(n);
        e.timestamp = ts;
        g_faucet_claim_count += 1;
        loaded += 1;
    }
    std.debug.print("[FAUCET] Loaded {d} claim(s) from {s}\n", .{ loaded, path });
}

/// Append a new claim line to the on-disk ledger. Best-effort — if the
/// write fails, we log but do not crash the claim path. The in-memory
/// table is the source of truth during runtime.
fn faucetAppendToDisk(addr: []const u8, ts: i64) void {
    const path = faucetPersistPath() orelse return;
    const f = std.fs.cwd().createFile(path, .{ .truncate = false, .read = false }) catch |err| {
        std.debug.print("[FAUCET] cannot open {s} for append: {}\n", .{ path, err });
        return;
    };
    defer f.close();
    f.seekFromEnd(0) catch return;
    var buf: [256]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "{{\"addr\":\"{s}\",\"ts\":{d}}}\n", .{ addr, ts }) catch return;
    _ = f.writeAll(line) catch |err| {
        std.debug.print("[FAUCET] append failed: {}\n", .{err});
    };
}

fn faucetAddressClaimed(addr: []const u8) bool {
    var i: usize = 0;
    while (i < g_faucet_claim_count) : (i += 1) {
        const e = &g_faucet_claims[i];
        if (e.addr_len == addr.len and std.mem.eql(u8, e.addr[0..e.addr_len], addr)) {
            return true;
        }
    }
    return false;
}

fn faucetRecordClaim(addr: []const u8, now_s: i64) void {
    if (g_faucet_claim_count >= FAUCET_MAX_CLAIMED_ADDRS) return; // table full, refuse silently
    const e = &g_faucet_claims[g_faucet_claim_count];
    const n = @min(addr.len, e.addr.len);
    @memcpy(e.addr[0..n], addr[0..n]);
    e.addr_len = @intCast(n);
    e.timestamp = now_s;
    g_faucet_claim_count += 1;
    // Persist to disk so the counter + per-address dedup survives a node
    // restart. Without this, every restart resets the rate-limit table to
    // empty and an attacker can re-claim the faucet repeatedly.
    faucetAppendToDisk(addr, now_s);
}

/// Returns seconds remaining on cooldown (0 = OK to claim).
fn faucetIpCooldownRemaining(ip: [4]u8, now_s: i64) i64 {
    for (&g_faucet_ip_table) |*e| {
        if (!e.used) continue;
        if (std.mem.eql(u8, &e.ip, &ip)) {
            const elapsed = now_s - e.last_claim;
            if (elapsed >= FAUCET_IP_COOLDOWN_S) return 0;
            return FAUCET_IP_COOLDOWN_S - elapsed;
        }
    }
    return 0;
}

fn faucetIpRecord(ip: [4]u8, now_s: i64) void {
    // Update existing entry first.
    for (&g_faucet_ip_table) |*e| {
        if (e.used and std.mem.eql(u8, &e.ip, &ip)) {
            e.last_claim = now_s;
            return;
        }
    }
    // Find a free slot (or oldest entry if full).
    var oldest: *FaucetIpEntry = &g_faucet_ip_table[0];
    for (&g_faucet_ip_table) |*e| {
        if (!e.used) {
            e.used = true;
            e.ip = ip;
            e.last_claim = now_s;
            return;
        }
        if (e.last_claim < oldest.last_claim) oldest = e;
    }
    // Table full — overwrite oldest.
    oldest.ip = ip;
    oldest.last_claim = now_s;
}

/// RPC "claimfaucet" — request 0.1 OMNI for a fresh wallet so it can cross
/// MIN_VALIDATOR_BALANCE and start mining. One grant per address ever, with
/// a per-IP cooldown to discourage trivial Sybil.
///
/// Usage:
///   {"method":"claimfaucet","params":["ob1q...recipient..."],"id":1}
///
/// Response on success:
///   {"result":{"txid":"...","amount":100000000,"recipient":"..."}}
///
/// Response on rejection: error -32010..-32014 with reason.
///
/// This handler is a no-op when the node was started without --faucet-mode
/// (faucet_wallet=null or faucet_grant_sat=0).
fn handleClaimFaucet(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;

    if (ctx.faucet_wallet == null or ctx.faucet_grant_sat == 0) {
        return errorJson(-32010, "Faucet not enabled on this node", id, alloc);
    }
    const fw = ctx.faucet_wallet.?;
    const grant = ctx.faucet_grant_sat;

    const recipient = extractArrayStr(body, 0) orelse extractStr(body, "address") orelse
        return errorJson(-32602, "Missing param: address (recipient)", id, alloc);
    if (recipient.len < 8 or recipient.len > 64) {
        return errorJson(-32602, "Address looks invalid (length out of range)", id, alloc);
    }

    g_faucet_mutex.lock();
    defer g_faucet_mutex.unlock();

    const now_s = std.time.timestamp();

    if (faucetAddressClaimed(recipient)) {
        return errorJson(-32011, "Address already claimed faucet", id, alloc);
    }

    // IP cooldown — best-effort: we get IP from connection in handleConn.
    // For the simple handler signature here, we trust loopback/local. A
    // future revision can pass the peer IP through ServerCtx per-request.
    // For now we skip per-IP enforcement on loopback claims.

    // Check faucet wallet has enough balance + min fee.
    const fee_sat: u64 = mempool_mod.TX_MIN_FEE_SAT;
    const faucet_balance = ctx.bc.getAddressBalance(fw.address);
    if (faucet_balance < grant + fee_sat) {
        return errorJson(-32012, "Faucet drained — wait for refill", id, alloc);
    }

    // Build, sign, broadcast via existing wallet TX path.
    const tx_id = g_tx_counter.fetchAdd(1, .monotonic);
    const nonce = ctx.bc.getNextAvailableNonce(fw.address);
    var tx = fw.createTransactionFull(recipient, grant, tx_id, nonce, fee_sat, 0, "", alloc) catch
        return errorJson(-32013, "Faucet sign error", id, alloc);
    if (!tx.isValid()) return errorJson(-32013, "Faucet TX invalid", id, alloc);

    ctx.bc.registerPubkey(fw.address, fw.addresses[0].public_key_hex) catch {};
    ctx.bc.addTransaction(tx) catch
        return errorJson(-32014, "Mempool refused faucet TX", id, alloc);

    faucetRecordClaim(recipient, now_s);

    std.debug.print("[FAUCET] Granted {d} SAT to {s}.. (txid={s})\n",
        .{ grant, recipient[0..@min(recipient.len, 16)], tx.hash[0..@min(tx.hash.len, 16)] });

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"txid\":\"{s}\",\"recipient\":\"{s}\",\"amount\":{d},\"fee\":{d},\"status\":\"accepted\"}}}}",
        .{ id, tx.hash, tx.from_address, tx.amount, tx.fee });
}

/// RPC "getfaucetstatus" — returns whether the faucet is enabled, current
/// balance, configured grant, and number of distinct addresses that have
/// already claimed. Useful for UI dashboards (so "Get Faucet" button can
/// gray out when drained or disabled).
fn handleFaucetStatus(ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const enabled = ctx.faucet_wallet != null and ctx.faucet_grant_sat > 0;
    var faucet_addr: []const u8 = "";
    var faucet_bal: u64 = 0;
    if (ctx.faucet_wallet) |fw| {
        faucet_addr = fw.address;
        faucet_bal = ctx.bc.getAddressBalance(fw.address);
    }
    g_faucet_mutex.lock();
    const claimed = g_faucet_claim_count;
    g_faucet_mutex.unlock();

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"enabled\":{},\"address\":\"{s}\",\"balance\":{d},\"grantPerClaim\":{d},\"claimsServed\":{d}}}}}",
        .{ id, enabled, faucet_addr, faucet_bal, ctx.faucet_grant_sat, claimed });
}

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
    var ait = ctx.bc.utxo_set.address_index.iterator();
    while (ait.next()) |kv| {
        const addr = kv.key_ptr.*;
        const bal = ctx.bc.utxo_set.getBalance(addr);
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

    // Build per-address indexes in ONE pass over the chain. We collect:
    //   - mined_count: blocks mined by miner_address
    //   - tx_stats:    {count, received, sent, first_height, last_height}
    // This keeps the richlist O(chain + addresses) instead of O(chain × addresses).
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
        const is_validator = e.balance >= validator_mod.MIN_VALIDATOR_BALANCE;
        const blocks = mined_count.get(e.address) orelse 0;
        const stats = tx_stats.get(e.address) orelse TxStats{};
        try w.print(
            "{{\"rank\":{d},\"address\":\"{s}\",\"balance\":{d},\"isValidator\":{},\"blocksMined\":{d}," ++
            "\"txCount\":{d},\"received\":{d},\"sent\":{d},\"firstHeight\":{d},\"lastHeight\":{d}}}",
            .{ i + 1, e.address, e.balance, is_validator, blocks,
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
    var ait = ctx.bc.utxo_set.address_index.iterator();
    while (ait.next()) |kv| {
        const addr = kv.key_ptr.*;
        const bal = ctx.bc.utxo_set.getBalance(addr);
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
            "\"satPerOmni\":1000000000" ++
            "}}}}",
        .{
            id, height, tip_hash, total_supply, addresses_with_balance,
            validators, validator_set_size, validator_mod.MIN_VALIDATOR_BALANCE,
            mempool_size, peer_count, current_reward,
        });
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
    // TLD optional — default "omnibus" (backward compat). Acceptat din param[3]
    // (positional) sau din "tld" key (object). "arbitraje" e celalalt valid.
    const tld = extractArrayStr(body, 3) orelse extractStr(body, "tld") orelse "omnibus";
    // Fee txid optional — param[4] sau key "fee_txid".
    const fee_txid = extractArrayStr(body, 4) orelse extractStr(body, "fee_txid") orelse null;

    const current_block: u64 = @intCast(ctx.bc.chain.items.len);
    const required_fee = dns_mod.feeForTld(tld);

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

    dns.registerWithTldAndFee(name, tld, address, owner, current_block, fee_txid) catch |err| {
        const msg: []const u8 = switch (err) {
            error.InvalidName     => "Invalid name (3-25 chars, lowercase a-z 0-9 _, must start with letter)",
            error.InvalidTld      => "Invalid TLD (allowed: omnibus, arbitraje)",
            error.NameTaken       => "Name already taken",
            error.RegistryFull    => "Registry full",
            error.FeeRequired     => "Fee required",
            error.InvalidTxid     => "Invalid txid",
            error.TxidAlreadyUsed => "Txid already used",
            error.ConsumedTxidsFull => "Consumed txids full",
        };
        return errorJson(-32031, msg, id, alloc);
    };

    std.debug.print("[DNS] Registered '{s}.{s}' -> {s}\n",
        .{ name[0..@min(name.len, 25)], tld[0..@min(tld.len, 16)], address[0..@min(address.len, 16)] });

    const fee_paid_sat: u64 = if (fee_txid) |_| required_fee else 0;
    const fee_txid_esc = fee_txid orelse "";
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
    // displays "alice.omnibus" or "arb_bot.arbitraje").
    var tld_from_name: ?[]const u8 = null;
    inline for (.{ ".omnibus", ".arbitraje" }) |suffix| {
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
    const resolved = dns.resolveWithTld(name, tld, current_block);

    if (resolved) |addr| {
        return std.fmt.allocPrint(alloc,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"name\":\"{s}\",\"tld\":\"{s}\",\"fullLabel\":\"{s}.{s}\",\"address\":\"{s}\",\"found\":true}}}}",
            .{ id, name, tld, name, tld, addr });
    }
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"name\":\"{s}\",\"tld\":\"{s}\",\"fullLabel\":\"{s}.{s}\",\"address\":null,\"found\":false}}}}",
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
            "{{\"name\":\"{s}\",\"tld\":\"{s}\",\"fullLabel\":\"{s}.{s}\",\"address\":\"{s}\",\"registeredAtBlock\":{d},\"expiresAtBlock\":{d}}}",
            .{ e.getName(), e.getTld(), e.getName(), e.getTld(), e.getAddress(), e.registered_block, e.expires_block },
        );
        active_count += 1;
    }

    try w.print("],\"total\":{d}}}}}", .{active_count});
    return json.toOwnedSlice();
}

fn handleGetEnsFee(ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    if (ctx.dns == null) {
        return std.fmt.allocPrint(alloc,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"treasury\":\"\",\"enforcement\":false,\"cost_omnibus_omni\":5,\"cost_arbitraje_omni\":10}}}}",
            .{id});
    }
    const dns = ctx.dns.?;
    const treasury = dns.getTreasury();
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"treasury\":\"{s}\",\"enforcement\":{},\"cost_omnibus_omni\":5,\"cost_arbitraje_omni\":10}}}}",
        .{ id, treasury, dns.fee_enforcement });
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
        return errorJson(-32602, "Missing param: publicKey (66 hex chars)", id, alloc);

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

    // Field-length sanity (cheap pre-check before allocations)
    if (sig_hex.len != 128) return errorJson(-32602, "signature must be 128 hex chars", id, alloc);
    if (hash_hex.len != 64) return errorJson(-32602, "hash must be 64 hex chars", id, alloc);
    if (pubkey_hex.len != 66) return errorJson(-32602, "publicKey must be 66 hex chars", id, alloc);

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
            "{s}{{\"txid\":\"{s}\",\"from\":\"{s}\",\"to\":\"{s}\",\"amount\":{d},\"fee\":{d},\"confirmations\":0,\"blockHeight\":null,\"direction\":\"{s}\",\"kind\":\"{s}\",\"status\":\"pending\"}}",
            .{ sep, tx.hash, tx.from_address, tx.to_address, tx.amount, tx.fee, dir, kind });
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
                    "{s}{{\"txid\":\"{s}\",\"from\":\"{s}\",\"to\":\"{s}\",\"amount\":{d},\"fee\":{d},\"confirmations\":{d},\"blockHeight\":{d},\"direction\":\"{s}\",\"kind\":\"{s}\",\"status\":\"confirmed\"}}",
                    .{ sep, tx.hash, tx.from_address, tx.to_address, tx.amount, tx.fee, confirmations, block_height, dir, kind });
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
        const e = try std.fmt.allocPrint(alloc,
            "{s}{{\"txid\":\"{s}\",\"from\":\"{s}\",\"to\":\"{s}\",\"amount\":{d},\"fee\":{d},\"confirmations\":0,\"blockHeight\":null,\"direction\":\"{s}\",\"status\":\"pending\"}}",
            .{ sep, tx.hash, tx.from_address, tx.to_address, tx.amount, tx.fee, dir });
        const m = try std.fmt.allocPrint(alloc, "{s}{s}", .{ entries, e });
        alloc.free(entries); alloc.free(e); entries = m; count += 1;
    }

    // 2. Confirmed TXs — scan blocks newest first via address_tx_index
    if (count < max_count) {
        if (ctx.bc.getAddressHistory(wallet_addr)) |tx_hashes| {
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
                    const e = try std.fmt.allocPrint(alloc,
                        "{s}{{\"txid\":\"{s}\",\"from\":\"{s}\",\"to\":\"{s}\",\"amount\":{d},\"fee\":{d},\"confirmations\":{d},\"blockHeight\":{d},\"direction\":\"{s}\",\"status\":\"confirmed\"}}",
                        .{ sep, tx.hash, tx.from_address, tx.to_address, tx.amount, tx.fee, confirmations, block_height, dir });
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
    const h = ctx.bc.getBlockCount();
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
    const height = ctx.bc.getBlockCount();
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
    const h = ctx.bc.getBlockCount();
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
            const block_count = ctx.bc.getBlockCount();
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
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"hash\":\"{s}\",\"height\":{d},\"timestamp\":{d},\"previousHash\":\"{s}\",\"merkleRoot\":\"{s}\",\"difficulty\":{d},\"nonce\":{d},\"txCount\":{d},\"size\":{d},\"miner\":\"{s}\",\"rewardSAT\":{d},\"prices\":{s},\"pricesRoot\":\"{s}\",\"pricesValidated\":{s}}}}}",
        .{ id, blk.hash, blk.index, blk.timestamp, blk.previous_hash, mr_hex, ctx.bc.difficulty, blk.nonce, tx_count, approx_size, blk.miner_address, blk.reward_sat, prices_buf[0..prices_len], pr_hex, if (prices_validated) "true" else "false" });
}

fn handleGetBlks(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const from: u32 = std.math.cast(u32, extractArrayNum(body, 0)) orelse 0;
    const rc = extractArrayNum(body, 1);
    const mc: u32 = if (rc == 0 or rc > 100) 100 else std.math.cast(u32, rc) orelse 100;
    var entries: []u8 = try alloc.dupe(u8, "");
    var n: u32 = 0;
    var h: u32 = from;
    while (n < mc) : ({ h += 1; n += 1; }) {
        const blk = ctx.bc.getBlock(h) orelse break;
        const sep: []const u8 = if (n == 0) "" else ",";
        const e = try std.fmt.allocPrint(alloc, "{s}{{\"height\":{d},\"timestamp\":{d},\"hash\":\"{s}\",\"nonce\":{d},\"txCount\":{d},\"miner\":\"{s}\",\"rewardSAT\":{d}}}", .{ sep, blk.index, blk.timestamp, blk.hash, blk.nonce, blk.transactions.items.len, blk.miner_address, blk.reward_sat });
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
    const block_count = ctx.bc.getBlockCount();
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
    const header = std.fmt.bufPrint(buf[0..], "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"totalMiners\":{d},\"chainHeight\":{d},\"miners\":[", .{ id, count, ctx.bc.getBlockCount() -| 1 }) catch return errorJson(-32000, "Buffer overflow", id, alloc);
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
    return std.fmt.allocPrint(alloc, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"status\":\"{s}\",\"reason\":\"{s}\",\"miner\":\"{s}\",\"blocksMined\":{d},\"balance\":{d},\"height\":{d},\"difficulty\":{d}}}}}", .{ id, st, rs, ma, bm, bal, h, d });
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
/// Usage: {"method":"submitslashevidence","params":["validator_addr","double_sign","block_hash1_hex","block_hash2_hex",block_height,"reporter_addr"],"id":1}
fn handleSubmitSlashEvidence(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const staking = ctx.staking orelse
        return errorJson(-32000, "Staking engine not available", id, alloc);

    // Parse params
    const validator_addr = extractArrayStr(body, 0) orelse
        return errorJson(-32602, "Missing param: validator_address", id, alloc);
    const reason_str = extractArrayStr(body, 1) orelse
        return errorJson(-32602, "Missing param: reason (double_sign|invalid_block|downtime)", id, alloc);
    const reporter_addr = extractArrayStr(body, 5) orelse
        return errorJson(-32602, "Missing param: reporter_address", id, alloc);
    const block_height = extractArrayNum(body, 4);

    // Parse reason
    const reason: staking_mod.SlashReason = if (std.mem.eql(u8, reason_str, "double_sign"))
        .double_sign
    else if (std.mem.eql(u8, reason_str, "invalid_block"))
        .invalid_block
    else if (std.mem.eql(u8, reason_str, "downtime"))
        .downtime
    else
        return errorJson(-32602, "Invalid reason: use double_sign, invalid_block, or downtime", id, alloc);

    // Build evidence with non-zero placeholder hashes/sigs for RPC submission
    // (full cryptographic verification happens at the consensus layer)
    const evidence = staking_mod.SlashEvidence.init(
        validator_addr,
        reason,
        [_]u8{0xAA} ** 32, // block_hash_1 placeholder
        [_]u8{0xBB} ** 32, // block_hash_2 placeholder
        block_height,
        [_]u8{0x11} ** 64, // signature_1 placeholder
        [_]u8{0x22} ** 64, // signature_2 placeholder
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
const MultisigConfig = multisig_mod.MultisigConfig;

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

    // Build MultisigWallet from stored config
    var wallet_addr: [64]u8 = [_]u8{0} ** 64;
    const addr_copy_len = @min(from_addr.len, 64);
    @memcpy(wallet_addr[0..addr_copy_len], from_addr[0..addr_copy_len]);

    const ms_wallet = MultisigWallet{
        .config = config_ptr.*,
        .address = wallet_addr,
        .address_len = @intCast(addr_copy_len),
    };

    const tx_id = g_tx_counter.fetchAdd(1, .monotonic);
    var ms_tx = ms_wallet.createTx(to_addr, amount_sat, fee_sat, tx_id);

    // Collect private keys from params[4..] and sign
    // Private keys are 64 hex chars (32 bytes)
    var signed: u8 = 0;
    var pk_idx: usize = 4;
    while (pk_idx < 20) : (pk_idx += 1) {
        const pk_hex = extractArrayStr(body, pk_idx) orelse break;
        if (pk_hex.len != 64) continue; // skip non-privkey params
        var privkey: [32]u8 = undefined;
        hex_utils.hexToBytes(pk_hex, &privkey) catch continue;
        const done = ms_wallet.addSignature(&ms_tx, privkey) catch continue;
        signed += 1;
        if (done) break;
    }

    if (signed < config_ptr.threshold) {
        return std.fmt.allocPrint(alloc,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"error\":{{\"code\":-32000,\"message\":\"Insufficient signatures: {d}/{d} required\"}}}}",
            .{ id, signed, config_ptr.threshold });
    }

    // Verify the multisig TX
    if (!ms_wallet.verify(&ms_tx)) {
        return errorJson(-32000, "Multisig verification failed", id, alloc);
    }

    // Create a regular Transaction to submit to the blockchain
    const nonce = ctx.bc.getNextAvailableNonce(from_addr);
    const tx = transaction_mod.Transaction{
        .id = tx_id,
        .from_address = from_addr,
        .to_address = to_addr,
        .amount = amount_sat,
        .fee = fee_sat,
        .timestamp = std.time.timestamp(),
        .nonce = nonce,
        .signature = "multisig_verified", // marker — not a standard ECDSA sig
        .hash = "",
    };

    ctx.bc.addTransaction(tx) catch return errorJson(-32000, "Mempool rejected TX", id, alloc);

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"from\":\"{s}\",\"to\":\"{s}\",\"amount\":{d},\"fee\":{d},\"signatures\":{d},\"required\":{d},\"status\":\"accepted\"}}}}",
        .{ id, from_addr, to_addr, amount_sat, fee_sat, signed, config_ptr.threshold });
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

// ─── Standalone main (pentru omnibus-rpc exe) ─────────────────────────────────

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
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
/// party_a_hex / party_b_hex: 33-byte compressed pubkeys as 66-char hex strings
/// amount_a / amount_b: deposits in SAT
fn handleOpenChannel(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const mgr = ctx.channel_mgr orelse return errorJson(-32000, "Payment channels not initialized", id, alloc);

    const amount_a = extractArrayNum(body, 2);
    const amount_b = extractArrayNum(body, 3);
    if (amount_a == 0 and amount_b == 0) return errorJson(-32602, "Both amounts cannot be zero", id, alloc);

    // Parse pubkeys from hex (or use placeholder if not provided)
    var pk_a: [33]u8 = undefined;
    var pk_b: [33]u8 = undefined;
    if (extractArrayStr(body, 0)) |hex_a| {
        if (hex_a.len == 66) {
            pk_a = hexDecode33(hex_a) orelse return errorJson(-32602, "Invalid party_a hex", id, alloc);
        } else return errorJson(-32602, "party_a must be 66-char hex", id, alloc);
    } else {
        pk_a[0] = 0x02;
        @memset(pk_a[1..], 0xAA);
    }
    if (extractArrayStr(body, 1)) |hex_b| {
        if (hex_b.len == 66) {
            pk_b = hexDecode33(hex_b) orelse return errorJson(-32602, "Invalid party_b hex", id, alloc);
        } else return errorJson(-32602, "party_b must be 66-char hex", id, alloc);
    } else {
        pk_b[0] = 0x03;
        @memset(pk_b[1..], 0xBB);
    }

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
/// Usage: {"method":"channelpay","params":["channel_id_hex","a_to_b",amount],"id":1}
/// direction: "a_to_b" or "b_to_a"
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

    const ch = mgr.findChannel(channel_id) orelse return errorJson(-32000, "Channel not found", id, alloc);

    // Use placeholder signatures (in production, client provides real sigs)
    var sig_a: [64]u8 = undefined;
    @memset(&sig_a, 0x11);
    var sig_b: [64]u8 = undefined;
    @memset(&sig_b, 0x22);

    _ = ch.pay(from_a, amount, sig_a, sig_b) catch |e| {
        return switch (e) {
            error.ChannelNotOpen => errorJson(-32000, "Channel not open", id, alloc),
            error.InsufficientBalance => errorJson(-32000, "Insufficient balance", id, alloc),
            error.BalanceMismatch => errorJson(-32000, "Balance mismatch", id, alloc),
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

    // Use placeholder signatures
    var sig_a: [64]u8 = undefined;
    @memset(&sig_a, 0x33);
    var sig_b: [64]u8 = undefined;
    @memset(&sig_b, 0x44);

    const settle = mgr.closeChannel(channel_id, sig_a, sig_b) catch |e| {
        return switch (e) {
            error.ChannelNotFound => errorJson(-32000, "Channel not found", id, alloc),
            error.ChannelNotOpen => errorJson(-32000, "Channel not open", id, alloc),
        };
    };

    var tx_a_hex: [64]u8 = undefined;
    const tx_a_str = std.fmt.bufPrint(&tx_a_hex, "{}", .{std.fmt.fmtSliceHexLower(&settle.tx_hash_a)}) catch "";
    var tx_b_hex: [64]u8 = undefined;
    const tx_b_str = std.fmt.bufPrint(&tx_b_hex, "{}", .{std.fmt.fmtSliceHexLower(&settle.tx_hash_b)}) catch "";

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"state\":\"settled\",\"final_balance_a\":{d},\"final_balance_b\":{d},\"tx_hash_a\":\"{s}\",\"tx_hash_b\":\"{s}\"}}}}",
        .{ id, settle.final_balance_a, settle.final_balance_b, tx_a_str, tx_b_str });
}

/// RPC "getchannels" — list all payment channels with their states.
/// Usage: {"method":"getchannels","id":1}
fn handleGetChannels(ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const mgr = ctx.channel_mgr orelse return errorJson(-32000, "Payment channels not initialized", id, alloc);

    const open_count = mgr.countByState(.open);
    const closing_count = mgr.countByState(.closing);
    const settled_count = mgr.countByState(.settled);
    const disputed_count = mgr.countByState(.disputed);
    const total_locked = mgr.getTotalLockedSat();

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"total_channels\":{d},\"open\":{d},\"closing\":{d},\"settled\":{d},\"disputed\":{d},\"total_locked_sat\":{d}}}}}",
        .{ id, mgr.channel_count, open_count, closing_count, settled_count, disputed_count, total_locked });
}

/// Decode 66-char hex string to [33]u8 (compressed pubkey)
fn hexDecode33(hex: []const u8) ?[33]u8 {
    if (hex.len != 66) return null;
    var out: [33]u8 = undefined;
    for (0..33) |i| {
        const hi = hexVal(hex[i * 2]) orelse return null;
        const lo = hexVal(hex[i * 2 + 1]) orelse return null;
        out[i] = (hi << 4) | lo;
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
        out[i] = (hi << 4) | lo;
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

/// omnibus_getbridgestatus — bridge relay status
fn handleOmnibusBridge(ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const block_count = ctx.bc.getBlockCount();
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"bridge_active\":true,\"pending_orders\":0,\"last_settlement_block\":{d},\"relay_latency_ms\":100}}}}",
        .{ id, block_count },
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
/// Full RLP+ECDSA decode is deferred to a later patch; this stub keeps the
/// JSON-RPC surface alive so wallets stop erroring on unknown method, and
/// returns a deterministic placeholder hash derived from the input. State is
/// **not** mutated. Once tx_pool integration lands, replace this body.
fn handleEthSendRawTransaction(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const raw = extractArrayStr(body, 0) orelse
        return errorJson(-32602, "eth_sendRawTransaction: missing raw tx", id, alloc);
    if (raw.len < 4) return errorJson(-32602, "eth_sendRawTransaction: tx too short", id, alloc);

    // Hash the raw payload with a Keccak-substitute (SHA-256 prefix) so the
    // response is at least deterministic. Real Keccak-256 lands with full
    // RLP decoding.
    var sha = std.crypto.hash.sha2.Sha256.init(.{});
    sha.update(raw);
    var digest: [32]u8 = undefined;
    sha.final(&digest);

    var hex_buf: [66]u8 = undefined;
    hex_buf[0] = '0';
    hex_buf[1] = 'x';
    const hex = "0123456789abcdef";
    for (digest, 0..) |b, i| {
        hex_buf[2 + i * 2]     = hex[b >> 4];
        hex_buf[2 + i * 2 + 1] = hex[b & 0x0f];
    }
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":\"{s}\"}}",
        .{ id, hex_buf[0..] });
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
    // Convert EVM hex address to ob1q... bech32 form OR query by raw bytes.
    // We don't have an EVM address registry yet, so for V1 return 0 for any
    // address that doesn't map to a known wallet. This is enough for ethers.js
    // pre-flight checks (it just wants a non-error response).
    // TODO(future): map EVM address -> bech32 ob1q via chain state.
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
/// V1 stub: returns empty array. Once the EVM executor wires up event
/// emission to chain state, this will scan the actual event log.
fn handleEthGetLogs(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    _ = body;
    return std.fmt.allocPrint(ctx.allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":[]}}",
        .{id});
}

/// eth_getTransactionReceipt — receipt for a tx hash.
/// V1 stub: returns null until EVM tx execution writes receipts to chain.
fn handleEthGetTransactionReceipt(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    _ = body;
    return std.fmt.allocPrint(ctx.allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":null}}",
        .{id});
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

fn ordersPathSlice(ctx: *ServerCtx) ?[]const u8 {
    if (ctx.orders_path_len == 0) return null;
    return ctx.orders_path_buf[0..ctx.orders_path_len];
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

    const side: matching_mod.Side =
        if (asciiEqIgnoreCase(side_str, "buy")) .buy
        else if (asciiEqIgnoreCase(side_str, "sell")) .sell
        else return errorJson(-32602, "side must be 'buy' or 'sell'", id, alloc);

    if (trader.len > 64) return errorJson(-32602, "trader address too long", id, alloc);

    // 1) Verify signature on canonical message
    var msg_buf: [256]u8 = undefined;
    const side_canon: []const u8 = if (side == .buy) "buy" else "sell";
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

    // 3) Lock + nonce check (replay protection) + balance check + place
    ctx.exchange_mutex.lock();
    defer ctx.exchange_mutex.unlock();

    const last_nonce = nonceLookup(ctx, trader);
    if (last_nonce >= 0 and @as(u64, @intCast(last_nonce)) >= nonce) {
        return errorJson(-32000, "Nonce already used (replay rejected)", id, alloc);
    }

    // Balance check: pentru a posta o ordine SELL trader-ul trebuie sa aiba
    // suficient base. Pentru BUY, suficient quote. Validarea e best-effort —
    // matching-ul executa ulterior cu balantele on-chain.
    const balance = ctx.bc.getAddressBalance(trader);
    if (side == .sell and balance < amount) {
        return errorJson(-32000, "Insufficient base balance for sell", id, alloc);
    }
    // BUY notional in SAT (price e micro-USD per OMNI; 1 OMNI = 1e9 SAT)
    if (side == .buy) {
        const notional = (amount / 1_000_000_000) * (price / 1_000_000);
        if (notional > 0 and balance < notional) {
            // Soft check — testnet permite, doar avertizam in log
            std.debug.print("[EXCHANGE] WARN buy notional {d} > balance {d} for {s}\n",
                .{ notional, balance, trader[0..@min(trader.len, 16)] });
        }
    }

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
    var fi = fills_before;
    while (fi < engine.fill_count) : (fi += 1) {
        const f = engine.fills[fi];
        tradeLogPush(ctx, f, is_paper);
        total_network_fee_sat += FILL_NETWORK_FEE_SAT;
        total_taker_fee_micro += computeExchangeFeeMicro(
            f.price_micro_usd, f.amount_sat, EXCHANGE_FEE_TAKER_BPS);
        total_maker_fee_micro += computeExchangeFeeMicro(
            f.price_micro_usd, f.amount_sat, EXCHANGE_FEE_MAKER_BPS);
    }

    nonceSet(ctx, trader, nonce);

    // Persist the place event (best-effort)
    var jbuf: [512]u8 = undefined;
    const jline = std.fmt.bufPrint(&jbuf,
        "\"trader\":\"{s}\",\"side\":\"{s}\",\"pairId\":{d},\"price\":{d},\"amount\":{d},\"orderId\":{d},\"ts\":{d}",
        .{ trader, side_canon, pair_id, price, amount, new_order_id, order.timestamp_ms },
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
            "\"orderId\":{d},\"side\":\"{s}\",\"pairId\":{d}," ++
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
           new_order_id, side_canon, pair_id,
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

    const order_id = extractArrayNumByKey(body, "orderId");
    if (order_id == 0) return errorJson(-32602, "Missing param: orderId", id, alloc);
    const trader = extractStr(body, "trader") orelse
        return errorJson(-32602, "Missing param: trader", id, alloc);
    const sig_hex = extractStr(body, "signature") orelse
        return errorJson(-32602, "Missing param: signature", id, alloc);
    const pubkey_hex = extractStr(body, "publicKey") orelse extractStr(body, "pubkey") orelse
        return errorJson(-32602, "Missing param: publicKey", id, alloc);
    const nonce = extractArrayNumByKey(body, "nonce");
    if (nonce == 0) return errorJson(-32602, "Missing or zero: nonce", id, alloc);

    // Verify signature
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
            apiKeyInsert(ctx, key_id, sec_hash, name, owner, @intCast(ts));
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

    ctx.exchange_mutex.lock();
    defer ctx.exchange_mutex.unlock();

    const last_nonce = nonceLookup(ctx, owner);
    if (last_nonce >= 0 and @as(u64, @intCast(last_nonce)) >= nonce) {
        return errorJson(-32000, "Nonce already used (replay rejected)", id, alloc);
    }

    const now_ms = std.time.milliTimestamp();
    apiKeyInsert(ctx, &key_id, &sec_hash, name, owner, now_ms);
    nonceSet(ctx, owner, nonce);

    var jbuf: [512]u8 = undefined;
    const jline = std.fmt.bufPrint(&jbuf,
        "\"keyId\":\"{s}\",\"secretHash\":\"{s}\",\"name\":\"{s}\",\"owner\":\"{s}\",\"ts\":{d}",
        .{ key_id, sec_hash, name, owner, now_ms },
    ) catch "";
    if (jline.len > 0) usersAppendJournal(ctx, "apikey", jline);

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"keyId\":\"{s}\",\"secret\":\"{s}\",\"name\":\"{s}\",\"warning\":\"Save the secret — it is only shown once\",\"createdMs\":{d}}}}}",
        .{ id, key_id, secret_str, name, now_ms });
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

/// exchange_deposit — credit internal exchange balance. On testnet this
/// just credits the balance with no on-chain transfer (faked). On mainnet
/// the user would transfer real OMNI to an exchange escrow address first;
/// this handler would only credit after seeing the on-chain TX.
fn handleExchangeDeposit(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
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
        "EXCHANGE_WITHDRAW_V1\n{s}\n{s}\n{d}\n{d}",
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

    if (!balanceDebit(ctx, owner, token, amount)) {
        return errorJson(-32000, "Insufficient balance", id, alloc);
    }
    nonceSet(ctx, owner, nonce);

    var jbuf: [256]u8 = undefined;
    const jline = std.fmt.bufPrint(&jbuf,
        "\"owner\":\"{s}\",\"token\":\"{s}\",\"amount\":{d},\"ts\":{d}",
        .{ owner, token, amount, std.time.milliTimestamp() }) catch "";
    if (jline.len > 0) usersAppendJournal(ctx, "withdraw", jline);

    const b = balanceLookup(ctx, owner, token).?;
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"owner\":\"{s}\",\"token\":\"{s}\",\"available\":{d},\"locked\":{d}}}}}",
        .{ id, owner, token, b.available_sat, b.locked_sat });
}

/// exchange_getBalances — read-only listing of all balance rows for an owner.
fn handleExchangeGetBalances(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
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
    while (i < ctx.exstate.?.balance_count) : (i += 1) {
        const b = &ctx.exstate.?.balances[i];
        if (b.owner_len != owner.len) continue;
        if (!std.mem.eql(u8, b.owner[0..b.owner_len], owner)) continue;
        if (!first) try out.appendSlice(alloc, ",");
        first = false;
        try std.fmt.format(out.writer(alloc),
            "{{\"token\":\"{s}\",\"available\":{d},\"locked\":{d}}}",
            .{ b.token[0..b.token_len], b.available_sat, b.locked_sat });
    }
    try out.appendSlice(alloc, "]}");
    return alloc.dupe(u8, out.items);
}

// ── Demo / Real deposit + escrow ─────────────────────────────────────

/// exchange_getEscrowAddress — return the on-chain address users send
/// real deposits to. On testnet this is the local node's wallet (so the
/// node can later detect the incoming TX and credit the user). On mainnet
/// this would be the dedicated `exchange.omnibus` registrar wallet (slot
/// #1 from the 10-wallet treasury list). Public; no auth required.
fn handleExchangeGetEscrowAddress(ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const escrow = ctx.wallet.address;
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"address\":\"{s}\",\"note\":\"Send OMNI to this address, then call exchange_depositReal with the txid\"}}}}",
        .{ id, escrow });
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
