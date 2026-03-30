const std = @import("std");
const blockchain_mod  = @import("blockchain.zig");
const wallet_mod      = @import("wallet.zig");
const transaction_mod = @import("transaction.zig");
const mempool_mod     = @import("mempool.zig");
const p2p_mod         = @import("p2p.zig");
const sync_mod        = @import("sync.zig");
const bootstrap       = @import("bootstrap.zig");
const main_mod        = @import("main.zig");

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

const PORT = 8332;
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
    /// Starea miner-ului: true = idle (ex: duplicate_ip_detected), false = active
    is_idle:   bool = false,
    /// Registru de mineri — creste la fiecare registerminer RPC
    registered_miners: [MAX_REGISTERED_MINERS]RegisteredMiner = undefined,
    registered_miner_count: u16 = 0,
    reg_mutex: std.Thread.Mutex = .{},
};

/// Context public expus utilizatorilor externi (alias la ServerCtx)
pub const RPCContext = ServerCtx;

/// Context extins pentru startHTTP cu module optionale
pub const HTTPConfig = struct {
    mempool:  ?*mempool_mod.Mempool  = null,
    p2p:      ?*p2p_mod.P2PNode      = null,
    sync_mgr: ?*sync_mod.SyncManager = null,
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
    };

    const addr = try std.net.Address.parseIp4("0.0.0.0", PORT);
    var server  = try addr.listen(.{ .reuse_address = true });
    defer server.deinit();

    std.debug.print("[RPC] HTTP JSON-RPC 2.0 listening on http://0.0.0.0:{d}\n", .{PORT});

    // Limita thread-uri concurente (previne OOM sub heavy load)
    var active_threads: std.atomic.Value(u32) = .{ .raw = 0 };
    const MAX_CONCURRENT: u32 = 4; // Keep low — each thread has 2MB stack

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

        const thread_ctx = try allocator.create(ConnCtx);
        thread_ctx.* = .{ .conn = conn, .server_ctx = ctx, .active_counter = &active_threads };
        _ = active_threads.fetchAdd(1, .monotonic);
        const t = std.Thread.spawn(.{ .stack_size = 2 * 1024 * 1024 }, handleConnCounted, .{thread_ctx}) catch {
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
    defer _ = ctx.active_counter.fetchSub(1, .monotonic);
    defer ctx.server_ctx.allocator.destroy(ctx);
    defer ctx.conn.stream.close();

    // Reuse existing handleConn logic inline
    var buf: [MAX_REQUEST]u8 = undefined;
    const ws2 = std.os.windows.ws2_32;
    const sock = ctx.conn.stream.handle;

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
    const raw = buf[0..total];

    if (std.mem.startsWith(u8, raw, "OPTIONS")) {
        const cors = "HTTP/1.1 204 No Content\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Allow-Methods: POST, OPTIONS\r\nAccess-Control-Allow-Headers: Content-Type\r\nAccess-Control-Max-Age: 86400\r\nConnection: close\r\n\r\n";
        _ = ctx.conn.stream.write(cors) catch {};
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
            "Access-Control-Allow-Headers: Content-Type\r\n" ++
            "Access-Control-Max-Age: 86400\r\n" ++
            "Connection: close\r\n\r\n";
        _ = ctx.conn.stream.write(cors_response) catch {};
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

fn handleGetLatestBlock(ctx: *ServerCtx, id: u64) ![]u8 {
    const blk = ctx.bc.getLatestBlock();
    return std.fmt.allocPrint(ctx.allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"index\":{d},\"timestamp\":{d},\"hash\":\"{s}\",\"previousHash\":\"{s}\",\"nonce\":{d},\"txCount\":{d}}}}}",
        .{ id, blk.index, blk.timestamp, blk.hash, blk.previous_hash, blk.nonce, blk.transactions.items.len });
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
    // generatewallet disabled — causes stack overflow on RPC thread
    // Use seed node address derivation instead
    if (std.mem.eql(u8, method, "generatewallet"))  return errorJson(-32601, "Use CLI wallet generation", id, alloc);

    return errorJson(-32601, "Method not found", id, alloc);
}

// ─── Extracted RPC Handlers ─────────────────────────────────────────────────

fn handleSendTx(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const to_addr = extractStr(body, "to") orelse extractArrayStr(body, 0) orelse
        return errorJson(-32602, "Missing param: to", id, alloc);
    const amount_sat = extractArrayNum(body, 1);
    if (amount_sat == 0) return errorJson(-32602, "Missing param: amount", id, alloc);
    const tx_id = g_tx_counter.fetchAdd(1, .monotonic);
    // Nonce = max(chain nonce, tx_counter) — unique per TX, set BEFORE sign
    const chain_nonce = ctx.bc.getNextNonce(ctx.wallet.address);
    const nonce = @max(chain_nonce, tx_id);
    var tx = ctx.wallet.createTransactionWithNonce(to_addr, amount_sat, tx_id, nonce, alloc) catch
        return errorJson(-32000, "Sign error", id, alloc);
    if (!tx.isValid()) return errorJson(-32000, "Invalid transaction", id, alloc);
    ctx.bc.addTransaction(tx) catch return errorJson(-32000, "Mempool error", id, alloc);
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"txid\":\"{s}\",\"from\":\"{s}\",\"to\":\"{s}\",\"amount\":{d},\"status\":\"accepted\"}}}}",
        .{ id, tx.hash, tx.from_address, tx.to_address, tx.amount });
}

fn handleGetTxs(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const filter = extractArrayStr(body, 0) orelse extractStr(body, "address") orelse "";
    var entries: []u8 = try alloc.dupe(u8, "");
    var count: usize = 0;
    for (ctx.bc.mempool.items) |tx| {
        if (filter.len > 0 and !std.mem.eql(u8, tx.from_address, filter) and !std.mem.eql(u8, tx.to_address, filter)) continue;
        const dir: []const u8 = if (filter.len > 0 and std.mem.eql(u8, tx.from_address, filter)) "sent" else "received";
        const sep: []const u8 = if (count == 0) "" else ",";
        const e = try std.fmt.allocPrint(alloc, "{s}{{\"txid\":\"{s}\",\"from\":\"{s}\",\"to\":\"{s}\",\"amount\":{d},\"status\":\"pending\",\"direction\":\"{s}\"}}", .{ sep, tx.hash, tx.from_address, tx.to_address, tx.amount, dir });
        const m = try std.fmt.allocPrint(alloc, "{s}{s}", .{ entries, e });
        alloc.free(entries); alloc.free(e); entries = m; count += 1;
    }
    for (ctx.bc.chain.items) |blk| {
        for (blk.transactions.items) |tx| {
            if (filter.len > 0 and !std.mem.eql(u8, tx.from_address, filter) and !std.mem.eql(u8, tx.to_address, filter)) continue;
            const dir: []const u8 = if (filter.len > 0 and std.mem.eql(u8, tx.from_address, filter)) "sent" else "received";
            const sep: []const u8 = if (count == 0) "" else ",";
            const e = try std.fmt.allocPrint(alloc, "{s}{{\"txid\":\"{s}\",\"from\":\"{s}\",\"to\":\"{s}\",\"amount\":{d},\"status\":\"confirmed\",\"direction\":\"{s}\",\"blockHeight\":{d}}}", .{ sep, tx.hash, tx.from_address, tx.to_address, tx.amount, dir, blk.index });
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
        // Notify bootstrap system + miner pool
        bootstrap.BootstrapNode.registered_miner_count = ctx.registered_miner_count;
        main_mod.g_miner_pool.register(addr);
        std.debug.print("[RPC] Miner registered: {s} ({s}) — total: {d}/{d} | pool: {d}\n",
            .{ addr, nid, ctx.registered_miner_count, bootstrap.BootstrapNode.MIN_MINERS_FOR_MINING, main_mod.g_miner_pool.count });
    }

    return std.fmt.allocPrint(alloc, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"status\":\"registered\",\"miner\":\"{s}\",\"node_id\":\"{s}\",\"blockHeight\":{d},\"totalMiners\":{d}}}}}", .{ id, addr, nid, h, ctx.registered_miner_count });
}

fn handlePoolStats(ctx: *ServerCtx, id: u64) ![]u8 {
    const h = ctx.bc.getBlockCount();
    const r = blockchain_mod.blockRewardAt(h);
    return std.fmt.allocPrint(ctx.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"blockHeight\":{d},\"blockRewardSAT\":{d},\"blockRewardOMNI\":{d},\"mempoolSize\":{d},\"difficulty\":{d},\"nodeAddress\":\"{s}\"}}}}", .{ id, h, r, r / 1_000_000_000, ctx.bc.mempool.items.len, ctx.bc.difficulty, ctx.wallet.address });
}

fn handleAddrBal(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const addr = extractArrayStr(body, 0) orelse extractStr(body, "address") orelse
        return errorJson(-32602, "Missing param: address", id, alloc);
    const bal = ctx.bc.getAddressBalance(addr);
    return std.fmt.allocPrint(alloc, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"address\":\"{s}\",\"balance\":{d},\"balanceOMNI\":{d}}}}}", .{ id, addr, bal, bal / 1_000_000_000 });
}

fn handleMpStats(ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    if (ctx.mempool) |m| {
        return std.fmt.allocPrint(alloc, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"size\":{d},\"maxTx\":{d},\"maxBytes\":{d},\"bytes\":{d}}}}}", .{ id, m.size(), mempool_mod.MEMPOOL_MAX_TX, mempool_mod.MEMPOOL_MAX_BYTES, m.bytes() });
    }
    return std.fmt.allocPrint(alloc, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"size\":{d},\"maxTx\":{d},\"maxBytes\":{d},\"bytes\":0}}}}", .{ id, ctx.bc.mempool.items.len, mempool_mod.MEMPOOL_MAX_TX, mempool_mod.MEMPOOL_MAX_BYTES });
}

fn handlePeers(ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const p2p = ctx.p2p orelse return std.fmt.allocPrint(alloc, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"count\":0,\"height\":0,\"peers\":[]}}}}", .{id});
    var pj: []u8 = try alloc.dupe(u8, "");
    var pc: usize = 0;
    for (p2p.peers.items) |peer| {
        const sep: []const u8 = if (pc == 0) "" else ",";
        const e = try std.fmt.allocPrint(alloc, "{s}{{\"id\":\"{s}\",\"host\":\"{s}\",\"port\":{d},\"alive\":{s}}}", .{ sep, peer.node_id, peer.host, peer.port, if (peer.connected) "true" else "false" });
        const m = try std.fmt.allocPrint(alloc, "{s}{s}", .{ pj, e });
        alloc.free(pj); alloc.free(e); pj = m; pc += 1;
    }
    defer alloc.free(pj);
    return std.fmt.allocPrint(alloc, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"count\":{d},\"height\":{d},\"peers\":[{s}]}}}}", .{ id, pc, p2p.chain_height, pj });
}

fn handleSyncSt(ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    if (ctx.sync_mgr) |s| {
        return std.fmt.allocPrint(alloc, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"status\":\"{s}\",\"localHeight\":{d},\"peerHeight\":{d},\"progress\":{d},\"synced\":{s},\"stalled\":{s}}}}}", .{ id, @tagName(s.state.status), s.state.local_height, s.state.peer_height, @as(u64, @intFromFloat(s.state.progressPct())), if (s.isSynced()) "true" else "false", if (s.isStalled()) "true" else "false" });
    }
    const h = ctx.bc.getBlockCount();
    return std.fmt.allocPrint(alloc, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"status\":\"synced\",\"localHeight\":{d},\"peerHeight\":{d},\"progress\":100,\"synced\":true,\"stalled\":false}}}}", .{ id, h, h });
}

fn handleNetInfo(ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const h = ctx.bc.getBlockCount();
    const r = blockchain_mod.blockRewardAt(h);
    const pc: usize = if (ctx.p2p) |p| p.peers.items.len else 0;
    const ms: usize = if (ctx.mempool) |m| m.size() else ctx.bc.mempool.items.len;
    return std.fmt.allocPrint(alloc, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"chain\":\"omnibus-mainnet\",\"version\":\"1.0.0\",\"blockHeight\":{d},\"blockRewardSAT\":{d},\"difficulty\":{d},\"mempoolSize\":{d},\"peerCount\":{d},\"nodeAddress\":\"{s}\",\"nodeBalance\":{d},\"halvingInterval\":126144000,\"maxSupply\":21000000000000000,\"blockTimeMs\":1000,\"subBlocksPerBlock\":10}}}}", .{ id, h, r, ctx.bc.difficulty, ms, pc, ctx.wallet.address, ctx.wallet.getBalance() });
}

fn handleGetBlk(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const h_str = extractArrayStr(body, 0);
    const height: u32 = if (h_str) |s| std.fmt.parseInt(u32, s, 10) catch (std.math.cast(u32, extractArrayNum(body, 0)) orelse 0) else std.math.cast(u32, extractArrayNum(body, 0)) orelse 0;
    const blk = ctx.bc.getBlock(height) orelse return errorJson(-32602, "Block not found", id, alloc);
    return std.fmt.allocPrint(alloc, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"height\":{d},\"timestamp\":{d},\"hash\":\"{s}\",\"previousHash\":\"{s}\",\"nonce\":{d},\"txCount\":{d},\"miner\":\"{s}\",\"rewardSAT\":{d}}}}}", .{ id, blk.index, blk.timestamp, blk.hash, blk.previous_hash, blk.nonce, blk.transactions.items.len, blk.miner_address, blk.reward_sat });
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
        \\{"method":"getbalance","params":["ob_omni_alice"],"id":1}
    ;
    const s = extractArrayStr(json, 0);
    try testing.expect(s != null);
    try testing.expectEqualStrings("ob_omni_alice", s.?);
}

test "extractArrayStr — index 0 din array cu doua elemente" {
    const json =
        \\{"method":"sendtransaction","params":["ob_omni_bob",1000],"id":1}
    ;
    const s = extractArrayStr(json, 0);
    try testing.expect(s != null);
    try testing.expectEqualStrings("ob_omni_bob", s.?);
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
        \\{"method":"sendtransaction","params":["ob_omni_bob",500000000],"id":1}
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
