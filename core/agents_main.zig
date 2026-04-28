/// agents_main.zig — entry point for the standalone `omnibus-agents` process.
///
/// BTC-style multi-process architecture: the chain process is the chain
/// only. AI agents (which decide trades, claim faucet, etc. based on
/// oracle prices and chain state) live in this dedicated daemon. The
/// daemon watches the chain via JSON-RPC (getblockcount, getbalance,
/// getlatestblock) and submits decisions back as signed transactions
/// (sendrawtransaction).
///
/// Status: STUB. The infrastructure (process, port, health endpoint)
/// is in place; the actual agent_executor → chain RPC bridge is the
/// follow-up work. The chain side already supports opt-out via
/// OMNIBUS_EXTERNAL_AGENTS=1 — when that env is set, the chain skips
/// loadAgentConfig entirely, so this stub running idle is enough to
/// validate the multi-process plumbing without changing chain behaviour.
///
/// Future evolution (separate session):
///   1. Pull agent_manager + agent_executor logic into this binary.
///   2. Replace direct chain.getAddressBalance() calls with RPC.
///   3. Build OracleSnapshot from omnibus-oracle's oracle_getSnapshot
///      instead of g_ws_feed.
///   4. Submit decisions via sendrawtransaction RPC to chain.
///
/// On baremetal (OmniBus OS) this becomes a separate process with
/// dedicated CPU affinity and IPC over shared memory rings — same
/// code, different transport.

const std = @import("std");
const orchestrator = @import("orchestrator.zig");

const AGENTS_RPC_PORT: u16 = 28200;
const HTTP_BUF_SIZE: usize = 8 * 1024;

var g_clock: orchestrator.AtomicClock = undefined;
var g_running: std.atomic.Value(bool) = std.atomic.Value(bool).init(true);

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

    if (std.mem.eql(u8, method, "agents_health")) {
        return std.fmt.allocPrint(allocator,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{" ++
            "\"uptime_ms\":{d},\"running\":true,\"rdtsc\":{d}," ++
            "\"agents_loaded\":0,\"status\":\"stub\"}}}}",
            .{ id, g_clock.uptimeMs(), orchestrator.nowCycles() });
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
    std.debug.print("[AGENTS] omnibus-agents starting (STUB) on port {d}\n", .{AGENTS_RPC_PORT});
    std.debug.print("[AGENTS] Note: this is a placeholder process. Real agent_executor\n" ++
                    "[AGENTS] integration follows the same RPC bridge pattern as\n" ++
                    "[AGENTS] omnibus-oracle. See agents_main.zig docstring.\n", .{});

    g_clock = orchestrator.AtomicClock.initReal();
    const tsc = orchestrator.calibrateTscPerSec(100);
    std.debug.print("[AGENTS] TSC calibrated: {d} Hz ({d:.3} GHz)\n",
        .{ tsc, @as(f64, @floatFromInt(tsc)) / 1e9 });

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const addr = try std.net.Address.parseIp4("127.0.0.1", AGENTS_RPC_PORT);
    var server = try addr.listen(.{ .reuse_address = true });
    defer server.deinit();

    std.debug.print("[AGENTS] listening on http://127.0.0.1:{d}\n", .{AGENTS_RPC_PORT});

    while (g_running.load(.acquire)) {
        const conn = server.accept() catch |err| {
            std.debug.print("[AGENTS] accept error: {}\n", .{err});
            std.Thread.sleep(100 * std.time.ns_per_ms);
            continue;
        };
        handleConnection(conn, allocator);
    }
}
