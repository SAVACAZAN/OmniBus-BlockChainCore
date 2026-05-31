//! core/node/ws_rpc_init.zig
//!
//! WebSocket server + RPC bind/auth config + DEX user/identity/KYC/profile
//! journal paths — extracted from main.zig.
//!
//! What this does:
//!   - Builds a `WsServer` (value), attaches the blockchain, starts listening.
//!   - Reads OMNIBUS_RPC_BIND / OMNIBUS_RPC_TOKEN env vars (allocator-owned).
//!   - Allocates per-chain exchange-users / identities / kyc / profiles
//!     journal paths and ensures the parent `data/<chain>/` directory exists.
//!
//! What this does NOT do:
//!   - Spawn the rpcThread — that stays in main.zig (uses RPCThreadArgs which
//!     pulls together engines, faucet wallet, etc.).
//!   - Attach the WsServer to the P2P node / publish to `g_ws_srv` — those
//!     need a stable address of the value living in main.zig's stack frame,
//!     so the caller does them right after this returns.
//!
//! Print lines preserved verbatim: `[WS] Server start failed`, `[EXCHANGE]
//! users journal`, `[IDENTITY] journal`, `[KYC] journal`.

const std = @import("std");
const ws_mod = @import("../ws_server.zig");
const blockchain_mod = @import("../blockchain.zig");

pub const WsRpcConfig = struct {
    /// WebSocket server (value, ~live for whole process lifetime).
    /// Caller must `defer ws_srv.deinit()`.
    ws_srv: ws_mod.WsServer,
    /// RPC bind address ("127.0.0.1" by default, or env override).
    /// Owned by caller's allocator. Caller must `allocator.free(rpc_bind)`.
    rpc_bind: []const u8,
    /// Optional RPC auth bearer token (OMNIBUS_RPC_TOKEN env var).
    /// Owned by caller's allocator when present.
    rpc_token: ?[]const u8,
    /// Per-chain exchange-users journal path (nullable on alloc failure).
    /// Owned by caller's allocator when present.
    users_path: ?[]u8,
    /// Per-chain identities journal path.
    identities_path: ?[]u8,
    /// Per-chain KYC attestations journal path.
    kyc_path: ?[]u8,
    /// Per-chain profiles journal path.
    profiles_path: ?[]u8,
};

/// Build the WsServer + RPC config + DEX journal paths.
///
/// `chain_subdir` is "mainnet" | "testnet" | "regtest" (built by caller from
/// config flags). `ws_port` is the already-adjusted port (seed = base,
/// miner = base+1 to avoid conflicts on the same host).
pub fn initWsAndRpcConfig(
    allocator: std.mem.Allocator,
    bc: *blockchain_mod.Blockchain,
    ws_port: u16,
    chain_subdir: []const u8,
) !WsRpcConfig {
    // ── WebSocket server ────────────────────────────────────────────────
    var ws_srv = ws_mod.WsServer.init(ws_port, allocator);
    ws_srv.attachBlockchain(bc);
    ws_srv.start() catch |err| {
        std.debug.print("[WS] Server start failed on port {d}: {} — continuam fara WS\n", .{ ws_port, err });
    };

    // ── RPC bind + auth — env vars OMNIBUS_RPC_BIND / OMNIBUS_RPC_TOKEN ─
    // Default bind = "127.0.0.1" so a fresh node is NOT exposed to the public
    // internet by accident. Public nodes (VPS) must explicitly opt in via
    // OMNIBUS_RPC_BIND=0.0.0.0 + OMNIBUS_RPC_TOKEN=<long-random-string>.
    // ServerCtx now copies the auth token into its own static buffer so we
    // are free to drop the env-allocated string after startHTTPEx returns.
    const rpc_bind = std.process.getEnvVarOwned(allocator, "OMNIBUS_RPC_BIND") catch
        try allocator.dupe(u8, "127.0.0.1");
    const rpc_token: ?[]const u8 = std.process.getEnvVarOwned(allocator, "OMNIBUS_RPC_TOKEN") catch null;

    // ── DEX user / identity / KYC / profile journal paths ───────────────
    // Always present (even when matching engine is off) because login +
    // balance queries are useful by themselves.
    const users_path = std.fmt.allocPrint(allocator, "data/{s}/exchange-users.jsonl", .{chain_subdir}) catch null;
    if (users_path) |p| {
        std.fs.cwd().makePath(std.fs.path.dirname(p) orelse ".") catch {};
        std.debug.print("[EXCHANGE] users journal: {s}\n", .{p});
    }
    const identities_path = std.fmt.allocPrint(allocator, "data/{s}/identities.jsonl", .{chain_subdir}) catch null;
    const kyc_path = std.fmt.allocPrint(allocator, "data/{s}/kyc-attestations.jsonl", .{chain_subdir}) catch null;
    const profiles_path = std.fmt.allocPrint(allocator, "data/{s}/profiles.jsonl", .{chain_subdir}) catch null;
    if (identities_path) |p| std.debug.print("[IDENTITY] journal: {s}\n", .{p});
    if (kyc_path) |p| std.debug.print("[KYC] journal: {s}\n", .{p});
    // profiles journal — makePath done inside startHTTPEx via replayProfilesJournal

    return .{
        .ws_srv = ws_srv,
        .rpc_bind = rpc_bind,
        .rpc_token = rpc_token,
        .users_path = users_path,
        .identities_path = identities_path,
        .kyc_path = kyc_path,
        .profiles_path = profiles_path,
    };
}
