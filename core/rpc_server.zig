const std = @import("std");
const blockchain_mod  = @import("blockchain.zig");
const wallet_mod      = @import("wallet.zig");
const transaction_mod = @import("transaction.zig");

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
    pub fn getMempoolSize(self: *RPCServer) u32 { return @intCast(self.blockchain.mempool.items.len); }
};

// ─── HTTP JSON-RPC 2.0 server ─────────────────────────────────────────────────

const PORT = 8332;
const MAX_REQUEST = 8192;

/// Context partajat intre thread-uri (blockchain + wallet)
const ServerCtx = struct {
    bc:        *Blockchain,
    wallet:    *Wallet,
    allocator: std.mem.Allocator,
};

/// Porneste serverul HTTP pe portul 8332 (blocking — ruleaza pe thread separat)
pub fn startHTTP(bc: *Blockchain, wallet: *Wallet, allocator: std.mem.Allocator) !void {
    const ctx = try allocator.create(ServerCtx);
    ctx.* = .{ .bc = bc, .wallet = wallet, .allocator = allocator };

    const addr = try std.net.Address.parseIp4("127.0.0.1", PORT);
    var server  = try addr.listen(.{ .reuse_address = true });
    defer server.deinit();

    std.debug.print("[RPC] HTTP JSON-RPC 2.0 listening on http://127.0.0.1:{d}\n", .{PORT});

    while (true) {
        const conn = server.accept() catch |err| {
            std.debug.print("[RPC] accept error: {}\n", .{err});
            continue;
        };

        // Fiecare conexiune pe thread propriu
        const thread_ctx = try allocator.create(ConnCtx);
        thread_ctx.* = .{ .conn = conn, .server_ctx = ctx };
        const t = try std.Thread.spawn(.{}, handleConn, .{thread_ctx});
        t.detach();
    }
}

const ConnCtx = struct {
    conn:       std.net.Server.Connection,
    server_ctx: *ServerCtx,
};

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

fn dispatch(body: []const u8, ctx: *ServerCtx) ![]u8 {
    const alloc = ctx.allocator;

    // Parse "method" si "id" cu string search simplu (evitam dep JSON)
    const method = extractStr(body, "method") orelse return errorJson(-32600, "Invalid request", 0, alloc);
    const id      = extractId(body);

    if (std.mem.eql(u8, method, "getblockcount")) {
        const count = ctx.bc.getBlockCount();
        return std.fmt.allocPrint(alloc,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{d}}}",
            .{ id, count });
    }

    if (std.mem.eql(u8, method, "getbalance")) {
        const bal_sat = ctx.wallet.getBalance();
        const addr    = ctx.wallet.address;
        const height  = ctx.bc.getBlockCount();
        return std.fmt.allocPrint(alloc,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"address\":\"{s}\",\"balance\":{d},\"balanceOMNI\":{d},\"confirmed\":{d},\"unconfirmed\":0,\"utxos\":[],\"transactions\":[],\"txCount\":0,\"nodeHeight\":{d}}}}}",
            .{ id, addr, bal_sat, bal_sat, bal_sat, height });
    }

    if (std.mem.eql(u8, method, "getlatestblock")) {
        const blk = ctx.bc.getLatestBlock();
        return std.fmt.allocPrint(alloc,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"index\":{d},\"timestamp\":{d},\"hash\":\"{s}\",\"previousHash\":\"{s}\",\"nonce\":{d},\"txCount\":{d}}}}}",
            .{ id, blk.index, blk.timestamp, blk.hash, blk.previous_hash, blk.nonce, blk.transactions.items.len });
    }

    if (std.mem.eql(u8, method, "getmempoolsize")) {
        return std.fmt.allocPrint(alloc,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{d}}}",
            .{ id, ctx.bc.mempool.items.len });
    }

    if (std.mem.eql(u8, method, "getstatus")) {
        return std.fmt.allocPrint(alloc,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"status\":\"running\",\"blockCount\":{d},\"mempoolSize\":{d},\"address\":\"{s}\",\"balance\":{d}}}}}",
            .{ id, ctx.bc.getBlockCount(), ctx.bc.mempool.items.len, ctx.wallet.address, ctx.wallet.getBalance() });
    }

    if (std.mem.eql(u8, method, "sendtransaction")) {
        // params: [to_address, amount_sat]
        const to_addr   = extractStr(body, "to")      orelse
                          extractArrayStr(body, 0)     orelse
                          return errorJson(-32602, "Missing param: to", id, alloc);
        const amount_sat = extractArrayNum(body, 1);
        if (amount_sat == 0) return errorJson(-32602, "Missing param: amount", id, alloc);

        // Creeaza si semneaza tranzactia cu private key-ul wallet-ului
        const tx_id = g_tx_counter.fetchAdd(1, .monotonic);
        var tx = ctx.wallet.createTransaction(to_addr, amount_sat, tx_id, alloc) catch |err| {
            std.debug.print("[RPC] createTransaction error: {}\n", .{err});
            return errorJson(-32000, "Sign error", id, alloc);
        };

        // Valideaza si adauga in mempool
        if (!tx.isValid()) return errorJson(-32000, "Invalid transaction", id, alloc);
        ctx.bc.addTransaction(tx) catch |err| {
            std.debug.print("[RPC] addTransaction error: {}\n", .{err});
            return errorJson(-32000, "Mempool error", id, alloc);
        };

        std.debug.print("[TX] {s} → {s}  {d} SAT  sig={s}...\n",
            .{ tx.from_address, tx.to_address, tx.amount, tx.signature[0..16] });

        return std.fmt.allocPrint(alloc,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"txid\":\"{s}\",\"from\":\"{s}\",\"to\":\"{s}\",\"amount\":{d},\"status\":\"accepted\"}}}}",
            .{ id, tx.hash, tx.from_address, tx.to_address, tx.amount });
    }

    // Method not found
    return errorJson(-32601, "Method not found", id, alloc);
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

fn errorJson(code: i32, msg: []const u8, id: u32, alloc: std.mem.Allocator) ![]u8 {
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
