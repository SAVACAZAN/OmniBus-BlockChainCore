// core/node/rpc_thread.zig
// JSON-RPC HTTP server thread wrapper.
// Extracted from main.zig (2026-05-29). Hosts the long-running thread that
// drives `rpc_server.startHTTPEx`. Re-exported by main.zig so existing call
// sites (`std.Thread.spawn(.{}, rpcThread, .{RPCThreadArgs{...}})`) keep
// working unchanged.

const std = @import("std");

const rpc_mod          = @import("../rpc_server.zig");
const blockchain_mod   = @import("../blockchain.zig");
const wallet_mod       = @import("../wallet.zig");
const mempool_mod      = @import("../mempool.zig");
const p2p_mod          = @import("../p2p.zig");
const sync_mod         = @import("../sync.zig");
const benchmark_mod    = @import("../benchmark.zig");
const payment_mod      = @import("../payment_channel.zig");
const staking_mod      = @import("../staking.zig");
const dns_mod          = @import("../dns_registry.zig");
const matching_mod     = @import("../matching_engine.zig");
const evm_escrow_mod   = @import("../evm_escrow_watcher.zig");
const bridge_mod       = @import("../bridge_native.zig");
const grid_mod         = @import("../grid_engine.zig");
const fills_log_mod    = @import("../fills_log.zig");

const Blockchain = blockchain_mod.Blockchain;
const Wallet     = wallet_mod.Wallet;

pub const RPCThreadArgs = struct {
    bc:       *Blockchain,
    wallet:   *Wallet,
    /// Optional faucet wallet (loaded only when --faucet-mode is set).
    /// Forwarded to the RPC server so handler `claimFaucet` can sign
    /// 0.1-OMNI grants without touching the miner's primary key.
    faucet_wallet: ?*Wallet,
    /// Per-claim grant in SAT. 0 means faucet is disabled at runtime.
    faucet_grant_sat: u64,
    /// On-chain DNS / ENS registry — names like "alice.omnibus" → ob1q…
    dns:      *dns_mod.DnsRegistry,
    alloc:    std.mem.Allocator,
    mempool:  *mempool_mod.Mempool,
    p2p:      *p2p_mod.P2PNode,
    sync_mgr: *sync_mod.SyncManager,
    metrics:  *benchmark_mod.Metrics,
    channel_mgr: *payment_mod.ChannelManager,
    staking:  *staking_mod.StakingEngine,
    chain_id: u32,
    /// RPC port from chain config — 8332/18332/28332/38332.
    /// Without this all chains collide on hardcoded 8332.
    rpc_port: u16,
    /// Bind address. "127.0.0.1" by default for safety, "0.0.0.0" only for
    /// nodes intended to be public RPC endpoints.
    rpc_bind: []const u8,
    /// Optional bearer token. When set, non-loopback requests must include
    /// `Authorization: Bearer <token>`.
    rpc_token: ?[]const u8,
    /// Native DEX matching engine. Allocated once at startup, shared across
    /// RPC threads. Null = exchange disabled (light nodes).
    exchange: ?*matching_mod.MatchingEngine,
    /// Paper-trading matching engine (separate from real-money). Same lock,
    /// different state. Null when paper trader is disabled.
    exchange_paper: ?*matching_mod.MatchingEngine,
    /// EVM escrow watcher — verifies BIDs on OMNI/<EVM> pairs are backed.
    evm_escrow_watcher: ?*evm_escrow_mod.Watcher,
    /// Path to `data/<chain>/orders.jsonl`. Empty = in-memory only (regtest).
    orders_path: ?[]const u8,
    /// Path to `data/<chain>/exchange-users.jsonl`. Stores apikeys + balances.
    users_path: ?[]const u8,
    /// Path to `data/<chain>/identities.jsonl`. Stores public nickname /
    /// ENS-pref / visibility per address.
    identities_path: ?[]const u8,
    /// Path to `data/<chain>/kyc-attestations.jsonl`. Signed level proofs.
    kyc_path: ?[]const u8,
    /// Address of the KYC issuer (registrar slot 4 = `kyc.omnibus`).
    /// Null = node accepts no KYC issuance (read-only KYC).
    kyc_issuer_address: ?[]const u8,
    /// Cross-chain bridge state. Allocated once, shared with RPC thread.
    bridge: ?*bridge_mod.BridgeState,
    /// Grid trading registry. Allocated once at startup, shared with RPC thread.
    grid_registry: ?*grid_mod.GridRegistry,
    /// Path to grid_registry.bin for persistence. Null = in-memory only.
    grid_path: ?[]const u8,
    /// Path to `data/<chain>/profiles.jsonl`. Append-only journal of
    /// profile_init / profile_update events. Replayed at startup so
    /// identity profiles survive node restarts. Null = in-memory only.
    profiles_path: ?[]const u8,
    /// Append-only binary trade fills log. Persistent across restarts;
    /// queried by exchange_getUserTrades. Local to this node only.
    fills_log: ?*fills_log_mod.FillsLog,
};

pub fn rpcThread(args: RPCThreadArgs) void {
    rpc_mod.startHTTPEx(args.bc, args.wallet, args.alloc, .{
        .mempool  = args.mempool,
        .p2p      = args.p2p,
        .sync_mgr = args.sync_mgr,
        .metrics  = args.metrics,
        .channel_mgr = args.channel_mgr,
        .staking  = args.staking,
        .chain_id = args.chain_id,
        .port     = args.rpc_port,
        .bind_host = args.rpc_bind,
        .auth_token = args.rpc_token,
        .faucet_wallet = args.faucet_wallet,
        .faucet_grant_sat = args.faucet_grant_sat,
        .dns = args.dns,
        .exchange = args.exchange,
        .exchange_paper = args.exchange_paper,
        .evm_escrow_watcher = args.evm_escrow_watcher,
        .orders_path = args.orders_path,
        .users_path = args.users_path,
        .identities_path = args.identities_path,
        .kyc_path = args.kyc_path,
        .kyc_issuer_address = args.kyc_issuer_address,
        .bridge = args.bridge,
        .grid_registry = args.grid_registry,
        .grid_path = args.grid_path,
        .profiles_path = args.profiles_path,
        .fills_log = args.fills_log,
    }) catch |err| {
        std.debug.print("[RPC] startHTTP error: {}\n", .{err});
    };
}
