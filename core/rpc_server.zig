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
};

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
};

/// Porneste serverul HTTP pe portul 8332 (blocking — ruleaza pe thread separat)
pub fn startHTTP(bc: *Blockchain, wallet: *Wallet, allocator: std.mem.Allocator) !void {
    return startHTTPEx(bc, wallet, allocator, .{});
}

/// Versiunea extinsa cu module optionale (mempool, p2p, sync)
pub fn startHTTPEx(bc: *Blockchain, wallet: *Wallet, allocator: std.mem.Allocator, cfg: HTTPConfig) !void {
    const ctx = try allocator.create(ServerCtx);
    ctx.* = .{
        .bc = bc, .wallet = wallet, .allocator = allocator,
        .mempool = cfg.mempool, .p2p = cfg.p2p, .sync_mgr = cfg.sync_mgr,
        .metrics = cfg.metrics, .staking = cfg.staking,
        .channel_mgr = cfg.channel_mgr,
        .pouw = cfg.pouw, .oracle = cfg.oracle,
        .chain_id = cfg.chain_id,
    };
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
        const t = std.Thread.spawn(.{ .stack_size = 4 * 1024 * 1024 }, handleConnCounted, .{thread_ctx}) catch {
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
    if (!isAuthorized(ctx.server_ctx, raw[0..hdr_end], peerIpv4(ctx.conn.address))) {
        writeUnauthorized(ctx.conn.stream);
        return;
    }

    const body = raw[hdr_end + 4 .. total];
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
    if (!isAuthorized(ctx.server_ctx, raw[0..hdr_end], peerIpv4(ctx.conn.address))) {
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
    if (std.mem.eql(u8, method, "getminerinfo"))     return handleMinerInf(ctx, id);
    if (std.mem.eql(u8, method, "getnodelist"))      return handleNodeList(ctx, id);
    if (std.mem.eql(u8, method, "estimatefee"))       return handleEstimateFee(ctx, id);
    if (std.mem.eql(u8, method, "getnonce"))          return handleGetNonce(body, ctx, id);
    if (std.mem.eql(u8, method, "gettransaction"))   return handleGetTx(body, ctx, id);
    if (std.mem.eql(u8, method, "sendopreturn"))     return handleSendOpReturn(body, ctx, id);
    if (std.mem.eql(u8, method, "getaddresshistory")) return handleGetAddrHistory(body, ctx, id);
    if (std.mem.eql(u8, method, "listtransactions"))  return handleListTx(body, ctx, id);
    if (std.mem.eql(u8, method, "minersendtx"))      return handleMinerSendTx(body, ctx, id);
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
    if (std.mem.eql(u8, method, "omnibus_getorderbook"))  return handleOmnibusOrderbook(ctx, id);
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
    const current_height: u64 = @intCast(ctx.bc.chain.items.len);

    // 1. Pending TXs from mempool (0 confirmations)
    for (ctx.bc.mempool.items) |tx| {
        const is_from = std.mem.eql(u8, tx.from_address, addr);
        const is_to = std.mem.eql(u8, tx.to_address, addr);
        if (!is_from and !is_to) continue;
        const dir: []const u8 = if (is_from) "sent" else "received";
        const sep: []const u8 = if (count == 0) "" else ",";
        const e = try std.fmt.allocPrint(alloc,
            "{s}{{\"txid\":\"{s}\",\"from\":\"{s}\",\"to\":\"{s}\",\"amount\":{d},\"fee\":{d},\"confirmations\":0,\"blockHeight\":null,\"direction\":\"{s}\",\"status\":\"pending\"}}",
            .{ sep, tx.hash, tx.from_address, tx.to_address, tx.amount, tx.fee, dir });
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

    defer alloc.free(entries);
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"address\":\"{s}\",\"transactions\":[{s}],\"count\":{d}}}}}",
        .{ id, addr, entries, count });
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

/// Extract peer IPv4 from connection address. Returns 0 on IPv6/unknown
/// (which isAuthorized treats as non-loopback → token required).
fn peerIpv4(addr: std.net.Address) u32 {
    if (addr.any.family == std.posix.AF.INET) {
        return addr.in.sa.addr;
    }
    return 0;
}

/// Auth check: returns true if request is authorized.
/// Rules:
///  - if `auth_token` is null on ServerCtx → always allowed (legacy / dev)
///  - if connection is from 127.0.0.1 → always allowed (local UI)
///  - else: require `Authorization: Bearer <token>` matching ctx.auth_token
fn isAuthorized(ctx: *ServerCtx, header: []const u8, peer_ip: u32) bool {
    if (ctx.auth_token_len == 0) return true; // no auth configured
    const token: []const u8 = ctx.auth_token_buf[0..ctx.auth_token_len];
    // 127.0.0.1 in network byte order = 0x0100007f. Zig stores in.sa.addr
    // raw network-order. Loopback = 127.0.0.0/8, low byte (network order
    // first byte) == 127.
    if ((peer_ip & 0xFF) == 127) return true;
    // Header is case-insensitive per RFC 7230, but most clients send the
    // canonical "Authorization". We accept both common casings.
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
fn canonicalPair(pair: []const u8) []const u8 {
    // ── Coinbase Advanced format (dash) → canonical slash form ───────────
    if (std.mem.eql(u8, pair, "BTC-USD"))   return "BTC/USD";
    if (std.mem.eql(u8, pair, "LCX-USD"))   return "LCX/USD";
    if (std.mem.eql(u8, pair, "ETH-USD"))   return "ETH/USD";
    if (std.mem.eql(u8, pair, "SOL-USD"))   return "SOL/USD";
    if (std.mem.eql(u8, pair, "ADA-USD"))   return "ADA/USD";
    if (std.mem.eql(u8, pair, "SUI-USD"))   return "SUI/USD";
    if (std.mem.eql(u8, pair, "EGLD-USD"))  return "EGLD/USD";
    // ── Kraken-style "BTC/USD" already canonical ─────────────────────────
    if (std.mem.eql(u8, pair, "BTC/USD"))   return "BTC/USD";
    if (std.mem.eql(u8, pair, "LCX/USD"))   return "LCX/USD";
    if (std.mem.eql(u8, pair, "ETH/USD"))   return "ETH/USD";
    if (std.mem.eql(u8, pair, "SOL/USD"))   return "SOL/USD";
    if (std.mem.eql(u8, pair, "ADA/USD"))   return "ADA/USD";
    if (std.mem.eql(u8, pair, "SUI/USD"))   return "SUI/USD";
    if (std.mem.eql(u8, pair, "EGLD/USD"))  return "EGLD/USD";
    // ── LCX USDC variants → USD (USDC ≈ USD for arbitrage) ───────────────
    if (std.mem.eql(u8, pair, "BTC/USDC"))  return "BTC/USD";
    if (std.mem.eql(u8, pair, "LCX/USDC"))  return "LCX/USD";
    if (std.mem.eql(u8, pair, "ETH/USDC"))  return "ETH/USD";
    if (std.mem.eql(u8, pair, "SOL/USDC"))  return "SOL/USD";
    if (std.mem.eql(u8, pair, "ADA/USDC"))  return "ADA/USD";
    if (std.mem.eql(u8, pair, "SUI/USDC"))  return "SUI/USD";
    if (std.mem.eql(u8, pair, "EGLD/USDC")) return "EGLD/USD";
    // ── LCX USDT variants → USD ──────────────────────────────────────────
    if (std.mem.eql(u8, pair, "BTC/USDT"))  return "BTC/USD";
    if (std.mem.eql(u8, pair, "ETH/USDT"))  return "ETH/USD";
    if (std.mem.eql(u8, pair, "SOL/USDT"))  return "SOL/USD";
    if (std.mem.eql(u8, pair, "ADA/USDT"))  return "ADA/USD";
    if (std.mem.eql(u8, pair, "SUI/USDT"))  return "SUI/USD";
    if (std.mem.eql(u8, pair, "EGLD/USDT")) return "EGLD/USD";
    // ── EUR-quoted pairs → USD canonical ─────────────────────────────────
    // The arbitrage matcher converts the bid/ask via the live USDC/EUR FX
    // rate BEFORE comparing. Once converted, the pair is comparable to the
    // USD-quoted entries, so the canonical label collapses too.
    if (std.mem.eql(u8, pair, "BTC/EUR"))   return "BTC/USD";
    if (std.mem.eql(u8, pair, "LCX/EUR"))   return "LCX/USD";
    if (std.mem.eql(u8, pair, "ETH/EUR"))   return "ETH/USD";
    if (std.mem.eql(u8, pair, "SOL/EUR"))   return "SOL/USD";
    if (std.mem.eql(u8, pair, "ADA/EUR"))   return "ADA/USD";
    if (std.mem.eql(u8, pair, "SUI/EUR"))   return "SUI/USD";
    if (std.mem.eql(u8, pair, "EGLD/EUR"))  return "EGLD/USD";
    return pair;
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
        // EUR-quoted entries get bid/ask normalized to USD via the FX rate
        // (skipped entirely if rate unavailable). The pair label is
        // canonicalized so e.g. BTC/EUR + the rate becomes BTC/USD which
        // pairs against Coinbase BTC-USD / Kraken BTC/USD in the matcher.
        var fresh = try alloc.alloc(ws_exchange_feed_mod.PriceFetch, all.len);
        defer alloc.free(fresh);
        var fresh_n: usize = 0;
        // Threshold widened to 5 minutes for arbitrage: Kraken doesn't push
        // ticker updates for low-volume pairs (EGLD, SUI) when there's no
        // trading activity, so the price can sit untouched for >60 s yet
        // remain valid for arbitrage as long as it's still the resting bid/ask.
        // The all-prices grid keeps the tighter 30 s 'stale' display flag.
        const ARBITRAGE_STALE_MS: i64 = 5 * 60 * 1000; // 5 min
        for (all) |p| {
            if (!p.success) continue;
            if (feedIsStale(p, now_ms, ARBITRAGE_STALE_MS)) continue;
            if (p.bid_micro_usd == 0 or p.ask_micro_usd == 0) continue;
            // Skip the FX pair itself — it's a tool, not an arbitrage candidate.
            if (std.mem.eql(u8, p.pair, "USDC/EUR") or
                std.mem.eql(u8, p.pair, "USDC-EUR")) continue;

            var entry = p;
            // Normalize EUR-quoted entries → USD using the live FX rate.
            if (std.mem.endsWith(u8, p.pair, "/EUR") or std.mem.endsWith(u8, p.pair, "-EUR")) {
                const rate = eur_to_usd_micro orelse continue; // skip until FX lands
                // bid_usd_micro = bid_eur_micro * rate / 1_000_000
                entry.bid_micro_usd = (p.bid_micro_usd * rate) / 1_000_000;
                entry.ask_micro_usd = (p.ask_micro_usd * rate) / 1_000_000;
            }
            fresh[fresh_n] = entry;
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

        var i: usize = 0;
        while (i < fresh_n) : (i += 1) {
            var j: usize = 0;
            while (j < fresh_n) : (j += 1) {
                if (i == j) continue;
                const buy = fresh[i];
                const sell = fresh[j];
                // Match canonical pairs (USDC≈USD).
                if (!std.mem.eql(u8, canonicalPair(buy.pair), canonicalPair(sell.pair))) continue;
                // Same exchange isn't arbitrage.
                if (std.mem.eql(u8, buy.exchange, sell.exchange)) continue;
                if (sell.bid_micro_usd <= buy.ask_micro_usd) continue;
                const spread = sell.bid_micro_usd - buy.ask_micro_usd;
                const pct = (@as(f64, @floatFromInt(spread)) /
                             @as(f64, @floatFromInt(buy.ask_micro_usd))) * 100.0;
                if (pct <= 0.05) continue; // 5 bps floor
                opps[opps_n] = .{
                    .pair = canonicalPair(buy.pair),
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
fn handleOmnibusOrderbook(ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
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
