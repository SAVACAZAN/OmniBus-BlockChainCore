/// oracle_main.zig — entry point for the standalone `omnibus-oracle` process.
///
/// Bitcoin pattern, applied to OmniBus: the chain process is *just* the
/// chain. Anything that touches external networks for prices (Coinbase,
/// Kraken, LCX) lives in this separate binary. The chain queries it
/// over JSON-RPC when it needs a price snapshot, identical to how a
/// Bitcoin block explorer queries bitcoind.
///
/// What this process does:
///   1. Starts ExchangeFeed (3 worker threads — Coinbase, Kraken, LCX)
///   2. Exposes a tiny HTTP/JSON-RPC server with these methods:
///        oracle_getPrice(pair)       → { bid, ask, timestamp_ms, source }
///        oracle_getSnapshot()        → fixed 6 important pairs
///        oracle_getAllPairs()        → every (exchange, pair) live entry
///        oracle_health()             → { uptime_ms, prices_count, ... }
///   3. Has its own AtomicClock + RDTSC + skip-when-late timers — no
///      shared state with the chain process.
///
/// Why this matters for performance: the chain's mining loop no longer
/// shares CPU with 3 WebSocket workers + JSON parsers + 1MB price
/// hashmap mutex contention. On a shared-CPU VPS that's the difference
/// between 50/min and a clean 60/min target.
///
/// On baremetal (OmniBus OS) this becomes a separate process with its
/// own MMU page tables, dedicated core via affinity, IPC through shared
/// memory rings instead of localhost TCP — same code, different
/// transport.

const std = @import("std");
const ws_feed = @import("ws_exchange_feed.zig");
const orchestrator = @import("orchestrator.zig");
const pair_registry_mod = @import("pair_registry.zig");

const ORACLE_RPC_PORT: u16 = 28100;
const HTTP_BUF_SIZE: usize = 16 * 1024;

var g_clock: orchestrator.AtomicClock = undefined;
var g_feed: ws_feed.ExchangeFeed = undefined;
var g_pair_registry: ?pair_registry_mod.PairRegistry = null;
var g_running: std.atomic.Value(bool) = std.atomic.Value(bool).init(true);

fn handleRpc(
    allocator: std.mem.Allocator,
    body: []const u8,
) ![]u8 {
    // Minimal JSON-RPC 2.0 dispatch — same wire format as the main node.
    // We hand-parse method + id rather than pulling in a JSON library;
    // the request shape is fixed and tiny.
    const method_key = "\"method\"";
    const id_key = "\"id\"";

    var method: []const u8 = "";
    if (std.mem.indexOf(u8, body, method_key)) |mi| {
        const after = body[mi + method_key.len ..];
        const q1 = std.mem.indexOfScalar(u8, after, '"') orelse return error.BadRequest;
        const after_q1 = after[q1 + 1 ..];
        const q2 = std.mem.indexOfScalar(u8, after_q1, '"') orelse return error.BadRequest;
        method = after_q1[0..q2];
    }

    var id: u64 = 0;
    if (std.mem.indexOf(u8, body, id_key)) |ii| {
        const after = body[ii + id_key.len ..];
        // skip ":" + whitespace
        var p: usize = 0;
        while (p < after.len and (after[p] == ':' or after[p] == ' ')) : (p += 1) {}
        var end = p;
        while (end < after.len and after[end] >= '0' and after[end] <= '9') : (end += 1) {}
        if (end > p) id = std.fmt.parseInt(u64, after[p..end], 10) catch 0;
    }

    if (std.mem.eql(u8, method, "oracle_health")) {
        const uptime = g_clock.uptimeMs();
        return std.fmt.allocPrint(allocator,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{" ++
            "\"uptime_ms\":{d},\"running\":true,\"rdtsc\":{d}}}}}",
            .{ id, uptime, orchestrator.nowCycles() });
    }

    if (std.mem.eql(u8, method, "oracle_getSnapshot")) {
        const snap = g_feed.snapshot();
        var out = std.array_list.Managed(u8).init(allocator);
        defer out.deinit();
        const w = out.writer();
        try w.print(
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":[",
            .{id});
        for (snap, 0..) |p, i| {
            if (i > 0) try w.writeAll(",");
            try w.print(
                "{{\"exchange\":\"{s}\",\"pair\":\"{s}\",\"bid\":{d}," ++
                "\"ask\":{d},\"timestamp_ms\":{d},\"success\":{}}}",
                .{ p.exchange, p.pair, p.bid_micro_usd, p.ask_micro_usd,
                   p.timestamp_ms, p.success });
        }
        try w.writeAll("]}");
        return out.toOwnedSlice();
    }

    // oracle_getAllPairs — full unbounded dump of every (exchange, pair) live
    // entry the feed holds. Used by chain nodes (OMNIBUS_EXTERNAL_ORACLE=1)
    // to populate their local g_ws_feed for downstream RPCs:
    // omnibus_getallprices / omnibus_getexchangefeed / omnibus_getarbitrage.
    if (std.mem.eql(u8, method, "oracle_getAllPairs")) {
        const all = g_feed.getAllPrices(allocator) catch |err| {
            return std.fmt.allocPrint(allocator,
                "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"error\":{{\"code\":-32603," ++
                "\"message\":\"getAllPrices failed: {s}\"}}}}", .{ id, @errorName(err) });
        };
        defer allocator.free(all);

        var out = std.array_list.Managed(u8).init(allocator);
        defer out.deinit();
        const w = out.writer();
        try w.print(
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"count\":{d},\"prices\":[",
            .{ id, all.len });
        var first = true;
        for (all) |p| {
            if (!p.success) continue;
            if (!first) try w.writeAll(",");
            first = false;
            try w.print(
                "{{\"exchange\":\"{s}\",\"pair\":\"{s}\",\"bid\":{d}," ++
                "\"ask\":{d},\"timestamp_ms\":{d}}}",
                .{ p.exchange, p.pair, p.bid_micro_usd, p.ask_micro_usd, p.timestamp_ms });
        }
        try w.writeAll("]}}");
        return out.toOwnedSlice();
    }

    return std.fmt.allocPrint(allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"error\":{{\"code\":-32601," ++
        "\"message\":\"method not found\"}}}}", .{id});
}

fn handleConnection(conn: std.net.Server.Connection, allocator: std.mem.Allocator) void {
    defer conn.stream.close();
    var buf: [HTTP_BUF_SIZE]u8 = undefined;
    const n = conn.stream.read(&buf) catch return;
    if (n == 0) return;

    // Find request body after \r\n\r\n.
    const sep = std.mem.indexOf(u8, buf[0..n], "\r\n\r\n") orelse return;
    const body = buf[sep + 4 .. n];

    const resp = handleRpc(allocator, body) catch return;
    defer allocator.free(resp);

    var hdr_buf: [256]u8 = undefined;
    const hdr = std.fmt.bufPrint(&hdr_buf,
        "HTTP/1.1 200 OK\r\n" ++
        "Content-Type: application/json\r\n" ++
        "Content-Length: {d}\r\n" ++
        "Connection: close\r\n\r\n",
        .{resp.len}) catch return;

    _ = conn.stream.writeAll(hdr) catch return;
    _ = conn.stream.writeAll(resp) catch return;
}

pub fn main() !void {
    std.debug.print("[ORACLE] omnibus-oracle starting on port {d}\n", .{ORACLE_RPC_PORT});

    g_clock = orchestrator.AtomicClock.initReal();
    const tsc = orchestrator.calibrateTscPerSec(100);
    std.debug.print("[ORACLE] TSC calibrated: {d} Hz ({d:.3} GHz)\n",
        .{ tsc, @as(f64, @floatFromInt(tsc)) / 1e9 });

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    g_feed = ws_feed.ExchangeFeed.init(allocator);
    defer g_feed.deinit();
    g_feed.setClock(&g_clock);

    // Optional pair registry from CLI arg --pair-registry FILE.
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--pair-registry") and i + 1 < args.len) {
            const path = args[i + 1];
            g_pair_registry = pair_registry_mod.loadFile(
                allocator, path) catch |err| blk: {
                std.debug.print("[ORACLE] pair registry load failed: {} — proceeding without\n", .{err});
                break :blk null;
            };
            if (g_pair_registry) |*reg| {
                g_feed.setPairRegistry(reg);
                std.debug.print("[ORACLE] pair registry attached: {s}\n", .{path});
            }
        }
    }

    g_feed.start() catch |err| {
        std.debug.print("[ORACLE] feed start failed: {}\n", .{err});
        return err;
    };
    defer g_feed.stop();

    const addr = try std.net.Address.parseIp4("127.0.0.1", ORACLE_RPC_PORT);
    var server = try addr.listen(.{ .reuse_address = true });
    defer server.deinit();

    std.debug.print("[ORACLE] listening on http://127.0.0.1:{d}\n", .{ORACLE_RPC_PORT});

    while (g_running.load(.acquire)) {
        const conn = server.accept() catch |err| {
            std.debug.print("[ORACLE] accept error: {}\n", .{err});
            std.Thread.sleep(100 * std.time.ns_per_ms);
            continue;
        };
        // Handle synchronously — RPC is tiny, no need for thread pool.
        handleConnection(conn, allocator);
    }
}
