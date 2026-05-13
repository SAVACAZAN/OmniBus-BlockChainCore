/// explorer_main.zig — entry point for the standalone `omnibus-explorer` process.
///
/// BTC pattern: chain is the chain. Block explorer / WS broadcast /
/// block index DB run separately, talking to the chain over RPC. This
/// matches how mempool.space / blockstream.info / blockchain.info work
/// against bitcoind — they're independent services.
///
/// Status: STUB. Exposes a health endpoint on :28300; the real frontend
/// HTTP/HTTPS serving + WebSocket broadcast pulled out of omnibus-node
/// is a separate session of work (involves migrating frontend/dist
/// serving + WS subscription multiplexing).
///
/// Future evolution:
///   1. Move ws_server.zig (WebSocket broadcast for live block events)
///      into this binary.
///   2. Move HTTP-static-files serving (currently part of omnibus-rpc)
///      here.
///   3. Add a local block index DB so explorer queries don't hit chain
///      RPC for every page-load.
///
/// On baremetal: dedicated process + CPU + IPC over shared memory.

const std = @import("std");
const orchestrator = @import("orchestrator.zig");
const chain_client_mod = @import("chain_rpc_client.zig");

const EXPLORER_RPC_PORT: u16 = 28300;
const HTTP_BUF_SIZE: usize = 8 * 1024;
const POLL_INTERVAL_MS: u64 = 1000;

var g_clock: orchestrator.AtomicClock = undefined;
var g_running: std.atomic.Value(bool) = std.atomic.Value(bool).init(true);
var g_chain_height: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
var g_chain_polls: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
var g_chain_errors: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

fn chainPollerLoop(allocator: std.mem.Allocator) void {
    var client = chain_client_mod.ChainClient.init(allocator);
    defer client.deinit();
    while (g_running.load(.acquire)) {
        if (client.getBlockCount()) |h| {
            g_chain_height.store(h, .release);
            _ = g_chain_polls.fetchAdd(1, .monotonic);
        } else |_| {
            _ = g_chain_errors.fetchAdd(1, .monotonic);
        }
        std.Thread.sleep(POLL_INTERVAL_MS * std.time.ns_per_ms);
    }
}

fn handleRpc(allocator: std.mem.Allocator, body: []const u8) ![]u8 {
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
        var p: usize = 0;
        while (p < after.len and (after[p] == ':' or after[p] == ' ')) : (p += 1) {}
        var end = p;
        while (end < after.len and after[end] >= '0' and after[end] <= '9') : (end += 1) {}
        if (end > p) id = std.fmt.parseInt(u64, after[p..end], 10) catch 0;
    }

    if (std.mem.eql(u8, method, "explorer_health")) {
        return std.fmt.allocPrint(allocator,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{" ++
            "\"uptime_ms\":{d},\"running\":true,\"rdtsc\":{d}," ++
            "\"chain_height\":{d},\"chain_polls\":{d}," ++
            "\"chain_errors\":{d},\"status\":\"bridged\"}}}}",
            .{ id, g_clock.uptimeMs(), orchestrator.nowCycles(),
               g_chain_height.load(.acquire),
               g_chain_polls.load(.monotonic),
               g_chain_errors.load(.monotonic) });
    }

    // explorer_tip: returnează ultimul height știut (cache local)
    if (std.mem.eql(u8, method, "explorer_tip")) {
        return std.fmt.allocPrint(allocator,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"height\":{d}}}}}",
            .{ id, g_chain_height.load(.acquire) });
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
    std.debug.print("[EXPLORER] omnibus-explorer starting on port {d}\n", .{EXPLORER_RPC_PORT});

    g_clock = orchestrator.AtomicClock.initReal();
    const tsc = orchestrator.calibrateTscPerSec(100);
    std.debug.print("[EXPLORER] TSC calibrated: {d} Hz ({d:.3} GHz)\n",
        .{ tsc, @as(f64, @floatFromInt(tsc)) / 1e9 });

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const poller = try std.Thread.spawn(.{}, chainPollerLoop, .{allocator});
    poller.detach();

    const addr = try std.net.Address.parseIp4("127.0.0.1", EXPLORER_RPC_PORT);
    var server = try addr.listen(.{ .reuse_address = true });
    defer server.deinit();

    std.debug.print("[EXPLORER] listening on http://127.0.0.1:{d}\n", .{EXPLORER_RPC_PORT});
    std.debug.print("[EXPLORER] polling chain tip every {d}ms via JSON-RPC\n", .{POLL_INTERVAL_MS});

    while (g_running.load(.acquire)) {
        const conn = server.accept() catch |err| {
            std.debug.print("[EXPLORER] accept error: {}\n", .{err});
            std.Thread.sleep(100 * std.time.ns_per_ms);
            continue;
        };
        handleConnection(conn, allocator);
    }
}
