// core/node/oracle_bridge.zig
// Oracle quorum loader + Oracle Bridge worker (polls standalone omnibus-oracle
// on 127.0.0.1:28100 every 10s, replays prices into g_ws_feed).
// Extracted from main.zig (2026-05-29). Re-exported by main.zig so existing
// call sites keep working.

const std = @import("std");

const rpc_mod = @import("../rpc_server.zig");

// Access main.zig globals (g_oracle_bridge_run, g_oracle_bridge_thread,
// g_ws_feed, g_reputation, g_local_miner_address, g_current_block_height).
const root = @import("root");

// ── Oracle Quorum ─────────────────────────────────────────────────────────
//
// Loads `data/<chain>/oracle_quorum.json` pubkey set into the rpc_server
// quorum registry. When the file is missing or has zero entries,
// `oracle_recordHeader` falls through to the legacy dev-mode `quorum_ok`
// path (which silently accepts anchors with no real signature check).
//
// File format (data/<chain>/oracle_quorum.json):
//   { "pubkeys": ["0x02ab...33-byte-compressed-hex...", ...] }
//
// Up to ORACLE_QUORUM_MAX (16) entries; each must be 66 hex chars (with
// or without leading "0x"). Returns the count of pubkeys loaded; 0 means
// the file was missing or malformed and the registry stays empty.
pub fn loadOracleQuorumPubkeys(path: []const u8) usize {
    var file = std.fs.cwd().openFile(path, .{}) catch |err| {
        std.debug.print("[ORACLE] Quorum config not found at {s}: {s} — quorum disabled (legacy dev-mode)\n",
            .{ path, @errorName(err) });
        return 0;
    };
    defer file.close();

    var buf: [4096]u8 = undefined;
    const n = file.readAll(&buf) catch return 0;
    const content = buf[0..n];

    // Lightweight extraction: find the first ["..."]-style array of hex
    // strings. We don't need a full JSON parser here — the format is
    // controlled by the operator and the only field we read is `pubkeys`.
    const start = std.mem.indexOf(u8, content, "\"pubkeys\"") orelse return 0;
    const open = std.mem.indexOfScalarPos(u8, content, start, '[') orelse return 0;
    const close = std.mem.indexOfScalarPos(u8, content, open + 1, ']') orelse return 0;
    const slice = content[open + 1 .. close];

    var pubs: [rpc_mod.ORACLE_QUORUM_MAX]rpc_mod.OracleQuorumPubkey = undefined;
    var count: usize = 0;
    var i: usize = 0;
    while (i < slice.len and count < pubs.len) {
        const q1 = std.mem.indexOfScalarPos(u8, slice, i, '"') orelse break;
        const q2 = std.mem.indexOfScalarPos(u8, slice, q1 + 1, '"') orelse break;
        var hex = slice[q1 + 1 .. q2];
        if (hex.len >= 2 and hex[0] == '0' and (hex[1] == 'x' or hex[1] == 'X')) {
            hex = hex[2..];
        }
        if (hex.len == 66) {
            var pk: [33]u8 = undefined;
            const ok = blk: {
                var k: usize = 0;
                while (k < 33) : (k += 1) {
                    const hi = std.fmt.charToDigit(hex[k * 2], 16) catch break :blk false;
                    const lo = std.fmt.charToDigit(hex[k * 2 + 1], 16) catch break :blk false;
                    pk[k] = (hi << 4) | lo;
                }
                break :blk true;
            };
            if (ok and (pk[0] == 0x02 or pk[0] == 0x03)) {
                pubs[count] = pk;
                count += 1;
            } else {
                std.debug.print("[ORACLE] Quorum: skipping malformed pubkey (must start with 0x02/0x03)\n", .{});
            }
        }
        i = q2 + 1;
    }

    if (count == 0) return 0;
    rpc_mod.setOracleQuorumPubkeys(pubs[0..count]) catch |err| {
        std.debug.print("[ORACLE] setOracleQuorumPubkeys failed: {s}\n", .{@errorName(err)});
        return 0;
    };
    return count;
}

// ─── Oracle Bridge implementation ───────────────────────────────────────────
//
// Pulls oracle_getAllPairs from omnibus-oracle (127.0.0.1:28100) on a 10 s
// cadence and replays each entry into g_ws_feed via upsertPriceExternal.
// The standalone oracle is the only network endpoint that touches Coinbase
// REST + WS, Kraken WS v2, LCX WS — chain process stays clean.
//
// Errors are swallowed (oracle may be restarting); next tick retries.
pub fn startOracleBridge(allocator: std.mem.Allocator) !void {
    if (root.g_oracle_bridge_run.load(.acquire)) return;
    root.g_oracle_bridge_run.store(true, .release);
    root.g_oracle_bridge_thread = try std.Thread.spawn(.{}, oracleBridgeLoop, .{allocator});
}

pub fn stopOracleBridge() void {
    root.g_oracle_bridge_run.store(false, .release);
    if (root.g_oracle_bridge_thread) |t| {
        t.join();
        root.g_oracle_bridge_thread = null;
    }
}

pub fn oracleBridgeLoop(allocator: std.mem.Allocator) void {
    const POLL_INTERVAL_MS: i64 = 10_000;
    const SLEEP_CHUNK_NS: u64 = 250 * std.time.ns_per_ms;

    // First fetch immediately so the dashboard isn't empty for the first 10s.
    oracleBridgeTick(allocator);

    while (root.g_oracle_bridge_run.load(.acquire)) {
        // Sleep in chunks so stop() reacts within ~250 ms.
        var slept_ms: i64 = 0;
        while (slept_ms < POLL_INTERVAL_MS and root.g_oracle_bridge_run.load(.acquire)) {
            std.Thread.sleep(SLEEP_CHUNK_NS);
            slept_ms += 250;
        }
        if (!root.g_oracle_bridge_run.load(.acquire)) break;
        oracleBridgeTick(allocator);
    }
    std.debug.print("[ORACLE-BRIDGE] worker exited\n", .{});
}

pub fn oracleBridgeTick(allocator: std.mem.Allocator) void {
    const body = fetchOracleAllPairs(allocator) catch |err| {
        std.debug.print("[ORACLE-BRIDGE] fetch failed: {s}\n", .{@errorName(err)});
        return;
    };
    defer allocator.free(body);

    // Inject into the local WS feed. Shape from oracle_getAllPairs:
    //   {"jsonrpc":"2.0","id":1,"result":{"count":N,"prices":[
    //     {"exchange":"Coinbase","pair":"BTC-USD","bid":80782650000,
    //      "ask":80782660000,"timestamp_ms":...}, ...
    //   ]}}
    const inserted = parseAndInjectPrices(body);
    if (inserted > 0) {
        std.debug.print("[ORACLE-BRIDGE] injected {d} prices from :28100\n", .{inserted});
        // FOOD reputation credit: this node is acting as oracle relay.
        // creditOraclePush la fiecare tick reusit = 0.01 FOOD per 10s.
        if (root.g_reputation) |*rep_mgr| {
            if (root.g_local_miner_address) |addr| {
                rep_mgr.creditOraclePush(addr, root.g_current_block_height.load(.acquire));
            }
        }
    }
}

/// HTTP POST 127.0.0.1:28100 with body {"jsonrpc":"2.0","id":1,"method":"oracle_getAllPairs"}.
/// Returns the raw response body (caller frees). Hand-rolled — no dependency
/// on std.http.Client (it's heavyweight + has had Zig-version churn).
pub fn fetchOracleAllPairs(allocator: std.mem.Allocator) ![]u8 {
    const addr = try std.net.Address.parseIp4("127.0.0.1", 28100);
    var stream = try std.net.tcpConnectToAddress(addr);
    defer stream.close();

    const req =
        "POST / HTTP/1.1\r\n" ++
        "Host: 127.0.0.1:28100\r\n" ++
        "Content-Type: application/json\r\n" ++
        "Content-Length: 53\r\n" ++
        "Connection: close\r\n\r\n" ++
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"oracle_getAllPairs\"}";

    _ = try stream.writeAll(req);

    // Read response — bounded, single-shot. ~700 entries × 150 B ≈ 100 KiB.
    var resp = std.array_list.Managed(u8).init(allocator);
    defer resp.deinit();

    var buf: [8192]u8 = undefined;
    while (true) {
        const n = stream.read(&buf) catch |err| switch (err) {
            error.ConnectionResetByPeer => break,
            else => return err,
        };
        if (n == 0) break; // EOF — server sent Connection: close after body.
        try resp.appendSlice(buf[0..n]);
        if (resp.items.len > 512 * 1024) break; // hard cap to prevent runaway
    }

    // Strip HTTP headers — body starts after \r\n\r\n.
    const sep = std.mem.indexOf(u8, resp.items, "\r\n\r\n") orelse return error.MalformedResponse;
    const body_start = sep + 4;
    return allocator.dupe(u8, resp.items[body_start..]);
}

/// Tiny JSON walker — looks for "prices":[...] then for each {...} object
/// extracts exchange / pair / bid / ask and calls upsertPriceExternal.
/// Returns count injected. Tolerant of unknown fields, key order, whitespace.
pub fn parseAndInjectPrices(body: []const u8) usize {
    if (root.g_ws_feed == null) return 0;
    const feed = &root.g_ws_feed.?;

    // Find "prices":[
    const arr_marker = "\"prices\":[";
    const arr_idx = std.mem.indexOf(u8, body, arr_marker) orelse return 0;
    var i = arr_idx + arr_marker.len;
    var injected: usize = 0;

    while (i < body.len and body[i] != ']') {
        // Skip whitespace + commas between objects.
        while (i < body.len and (body[i] == ' ' or body[i] == ',' or body[i] == '\n' or body[i] == '\r' or body[i] == '\t')) : (i += 1) {}
        if (i >= body.len or body[i] != '{') break;

        // Find object end. Naive — assumes no nested {} (oracle output never has).
        const obj_start = i;
        const obj_end_rel = std.mem.indexOfScalar(u8, body[obj_start..], '}') orelse break;
        const obj = body[obj_start .. obj_start + obj_end_rel + 1];
        i = obj_start + obj_end_rel + 1;

        const exchange = extractStringField(obj, "exchange") orelse continue;
        const pair = extractStringField(obj, "pair") orelse continue;
        const bid = extractU64Field(obj, "bid") orelse continue;
        const ask = extractU64Field(obj, "ask") orelse continue;

        feed.upsertPriceExternal(exchange, pair, bid, ask);
        injected += 1;
    }
    return injected;
}

fn extractStringField(obj: []const u8, key: []const u8) ?[]const u8 {
    var key_buf: [64]u8 = undefined;
    const k = std.fmt.bufPrint(&key_buf, "\"{s}\":\"", .{key}) catch return null;
    const start = std.mem.indexOf(u8, obj, k) orelse return null;
    const val_start = start + k.len;
    const close = std.mem.indexOfScalarPos(u8, obj, val_start, '"') orelse return null;
    return obj[val_start..close];
}

fn extractU64Field(obj: []const u8, key: []const u8) ?u64 {
    var key_buf: [64]u8 = undefined;
    const k = std.fmt.bufPrint(&key_buf, "\"{s}\":", .{key}) catch return null;
    const start = std.mem.indexOf(u8, obj, k) orelse return null;
    var p = start + k.len;
    while (p < obj.len and (obj[p] == ' ' or obj[p] == '\t')) : (p += 1) {}
    var end = p;
    while (end < obj.len and obj[end] >= '0' and obj[end] <= '9') : (end += 1) {}
    if (end == p) return null;
    return std.fmt.parseInt(u64, obj[p..end], 10) catch null;
}
