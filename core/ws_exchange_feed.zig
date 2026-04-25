/// ws_exchange_feed.zig — Multi-exchange WebSocket ticker feed manager.
///
/// Spawns 3 worker threads (Coinbase, Kraken, LCX) that each connect to a
/// public market-data WebSocket and push live BTC + LCX bid/ask updates into
/// a shared 6-slot price array protected by a mutex.
///
/// Slot layout:
///   [0] BTC  Coinbase    [1] BTC  Kraken    [2] BTC  LCX
///   [3] LCX  Coinbase    [4] LCX  Kraken    [5] LCX  LCX
///
/// All prices are stored in micro-USD (u64): 1 USD = 1_000_000 micro-USD.
/// Treats USDC as USD for LCX (LCX quotes BTC/USDC and LCX/USDC).
///
/// Each thread runs an infinite reconnect loop with exponential backoff
/// (1s, 2s, 4s, 8s, max 30s) on disconnect, until stop() flips the run flag.
///
/// JSON parsing is intentionally minimal — same indexOf-based approach as
/// core/oracle_fetcher.zig. We never construct a full DOM.
const std = @import("std");
const ws_client = @import("ws_client.zig");

const WsClient = ws_client.WsClient;

// ── Public types ─────────────────────────────────────────────────────────────

pub const PriceFetch = struct {
    exchange: []const u8,        // "Coinbase" | "Kraken" | "LCX"
    pair: []const u8,            // "BTC/USD"  | "LCX/USD"
    bid_micro_usd: u64,
    ask_micro_usd: u64,
    timestamp_ms: i64,
    success: bool,
};

// ── Constants ────────────────────────────────────────────────────────────────

const RECV_BUF_SIZE: usize = 64 * 1024;

const BACKOFF_INITIAL_MS: u64 = 1_000;
const BACKOFF_MAX_MS:     u64 = 30_000;

// LCX-specific application-level keepalive: server expects "ping" text frame
// every <= 60s or it disconnects. We send every 30s to be safe.
const LCX_PING_INTERVAL_MS: i64 = 30_000;

// Slot indices — must match the layout above.
const SLOT_BTC_COINBASE: usize = 0;
const SLOT_BTC_KRAKEN:   usize = 1;
const SLOT_BTC_LCX:      usize = 2;
const SLOT_LCX_COINBASE: usize = 3;
const SLOT_LCX_KRAKEN:   usize = 4;
const SLOT_LCX_LCX:      usize = 5;

// ── ExchangeFeed ─────────────────────────────────────────────────────────────

pub const ExchangeFeed = struct {
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex,
    prices: [6]PriceFetch,

    /// Atomic flag — workers exit their reconnect loops when this goes false.
    run: std.atomic.Value(bool),

    threads: [3]?std.Thread,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .mutex = .{},
            .run = std.atomic.Value(bool).init(false),
            .threads = .{ null, null, null },
            .prices = [6]PriceFetch{
                .{ .exchange = "Coinbase", .pair = "BTC/USD", .bid_micro_usd = 0, .ask_micro_usd = 0, .timestamp_ms = 0, .success = false },
                .{ .exchange = "Kraken",   .pair = "BTC/USD", .bid_micro_usd = 0, .ask_micro_usd = 0, .timestamp_ms = 0, .success = false },
                .{ .exchange = "LCX",      .pair = "BTC/USD", .bid_micro_usd = 0, .ask_micro_usd = 0, .timestamp_ms = 0, .success = false },
                .{ .exchange = "Coinbase", .pair = "LCX/USD", .bid_micro_usd = 0, .ask_micro_usd = 0, .timestamp_ms = 0, .success = false },
                .{ .exchange = "Kraken",   .pair = "LCX/USD", .bid_micro_usd = 0, .ask_micro_usd = 0, .timestamp_ms = 0, .success = false },
                .{ .exchange = "LCX",      .pair = "LCX/USD", .bid_micro_usd = 0, .ask_micro_usd = 0, .timestamp_ms = 0, .success = false },
            },
        };
    }

    /// Spawn the 3 worker threads. Returns immediately. Calling start() twice
    /// without an intervening stop() is a no-op (returns successfully).
    pub fn start(self: *Self) !void {
        if (self.run.load(.acquire)) return;
        self.run.store(true, .release);

        self.threads[0] = try std.Thread.spawn(.{}, coinbaseWorker, .{self});
        self.threads[1] = try std.Thread.spawn(.{}, krakenWorker,   .{self});
        self.threads[2] = try std.Thread.spawn(.{}, lcxWorker,      .{self});
    }

    /// Signal all workers to exit, then join them. Safe to call multiple times.
    pub fn stop(self: *Self) void {
        if (!self.run.load(.acquire)) return;
        self.run.store(false, .release);

        for (&self.threads) |*maybe_t| {
            if (maybe_t.*) |t| {
                t.join();
                maybe_t.* = null;
            }
        }
    }

    /// Return a snapshot of all 6 price slots. Holds the mutex briefly.
    pub fn snapshot(self: *Self) [6]PriceFetch {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.prices;
    }

    /// Median BTC mid-price across the 3 BTC slots. Null if all slots stale/failed.
    pub fn getMedianBtc(self: *Self) ?u64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return medianFor(self.prices[0..3]);
    }

    /// Median LCX mid-price across the 3 LCX slots. Null if none valid.
    pub fn getMedianLcx(self: *Self) ?u64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return medianFor(self.prices[3..6]);
    }

    // ── Internal: shared write helper ──────────────────────────────────────

    fn updateSlot(self: *Self, slot: usize, bid: u64, ask: u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.prices[slot].bid_micro_usd = bid;
        self.prices[slot].ask_micro_usd = ask;
        self.prices[slot].timestamp_ms  = std.time.milliTimestamp();
        self.prices[slot].success       = true;
    }

    fn markSlotFailed(self: *Self, slot: usize) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.prices[slot].success = false;
    }
};

// ── Backoff helper ───────────────────────────────────────────────────────────

/// Sleep with exponential backoff, but wake up promptly if run flag clears.
/// Returns the next backoff value (capped at BACKOFF_MAX_MS).
fn sleepBackoff(feed: *ExchangeFeed, current_ms: u64) u64 {
    // Sleep in 100ms ticks so stop() unblocks workers within ~100ms.
    var slept: u64 = 0;
    while (slept < current_ms) {
        if (!feed.run.load(.acquire)) return current_ms;
        const tick: u64 = @min(@as(u64, 100), current_ms - slept);
        std.Thread.sleep(tick * std.time.ns_per_ms);
        slept += tick;
    }
    const next = current_ms * 2;
    return if (next > BACKOFF_MAX_MS) BACKOFF_MAX_MS else next;
}

// ── Coinbase worker ──────────────────────────────────────────────────────────

fn coinbaseWorker(feed: *ExchangeFeed) void {
    var backoff: u64 = BACKOFF_INITIAL_MS;
    while (feed.run.load(.acquire)) {
        runCoinbaseSession(feed) catch {};
        // Mark slots failed on disconnect so stale data is visible upstream.
        feed.markSlotFailed(SLOT_BTC_COINBASE);
        feed.markSlotFailed(SLOT_LCX_COINBASE);
        backoff = sleepBackoff(feed, backoff);
    }
}

fn runCoinbaseSession(feed: *ExchangeFeed) !void {
    var client = try WsClient.connect(
        feed.allocator,
        "advanced-trade-ws.coinbase.com",
        443,
        "/",
        true,
    );
    defer client.close();

    const subscribe =
        \\{"type":"subscribe","product_ids":["BTC-USD","LCX-USD"],"channel":"ticker"}
    ;
    try client.send(subscribe);

    const buf = try feed.allocator.alloc(u8, RECV_BUF_SIZE);
    defer feed.allocator.free(buf);

    while (feed.run.load(.acquire)) {
        const maybe_msg = try client.recv(buf);
        const msg = maybe_msg orelse continue;
        switch (msg.kind) {
            .text => parseCoinbaseTicker(feed, msg.data),
            .ping => try client.sendPong(msg.data),
            .pong => {},
            .close => return error.ConnectionClosed,
        }
    }
}

/// Coinbase Advanced ticker payload format (relevant fields only):
///   {"channel":"ticker","events":[{"type":"...","tickers":[
///       {"product_id":"BTC-USD","best_bid":"32705.30","best_ask":"32762.60", ...},
///       {"product_id":"LCX-USD","best_bid":"0.05","best_ask":"0.06", ...}
///   ]}], ...}
///
/// We don't walk JSON structure; we just locate each ticker object by its
/// "product_id":"..." marker, then parse best_bid / best_ask within the
/// short window that follows.
fn parseCoinbaseTicker(feed: *ExchangeFeed, body: []const u8) void {
    parseCoinbaseProduct(feed, body, "\"product_id\":\"BTC-USD\"", SLOT_BTC_COINBASE);
    parseCoinbaseProduct(feed, body, "\"product_id\":\"LCX-USD\"", SLOT_LCX_COINBASE);
}

fn parseCoinbaseProduct(feed: *ExchangeFeed, body: []const u8, marker: []const u8, slot: usize) void {
    const pos = std.mem.indexOf(u8, body, marker) orelse return;
    // A single ticker object is < 1 KiB; bound the search window so we don't
    // accidentally match the next product's bid/ask.
    const window_end = @min(body.len, pos + 1024);
    const window = body[pos..window_end];

    const bid = parseQuotedPrice(window, "\"best_bid\":\"");
    const ask = parseQuotedPrice(window, "\"best_ask\":\"");

    if (bid != null or ask != null) {
        const bid_v = bid orelse (ask orelse 0);
        const ask_v = ask orelse (bid orelse 0);
        feed.updateSlot(slot, bid_v, ask_v);
    }
}

// ── Kraken worker ────────────────────────────────────────────────────────────

fn krakenWorker(feed: *ExchangeFeed) void {
    var backoff: u64 = BACKOFF_INITIAL_MS;
    while (feed.run.load(.acquire)) {
        runKrakenSession(feed) catch {};
        feed.markSlotFailed(SLOT_BTC_KRAKEN);
        feed.markSlotFailed(SLOT_LCX_KRAKEN);
        backoff = sleepBackoff(feed, backoff);
    }
}

fn runKrakenSession(feed: *ExchangeFeed) !void {
    var client = try WsClient.connect(
        feed.allocator,
        "ws.kraken.com",
        443,
        "/v2",
        true,
    );
    defer client.close();

    const subscribe =
        \\{"method":"subscribe","params":{"channel":"ticker","symbol":["BTC/USD","LCX/USD"]}}
    ;
    try client.send(subscribe);

    const buf = try feed.allocator.alloc(u8, RECV_BUF_SIZE);
    defer feed.allocator.free(buf);

    while (feed.run.load(.acquire)) {
        const maybe_msg = try client.recv(buf);
        const msg = maybe_msg orelse continue;
        switch (msg.kind) {
            .text => parseKrakenMessage(feed, msg.data),
            .ping => try client.sendPong(msg.data),
            .pong => {},
            .close => return error.ConnectionClosed,
        }
    }
}

/// Kraken v2 ticker payload (snapshot OR update):
///   {"channel":"ticker","type":"snapshot",
///    "data":[{"symbol":"BTC/USD","bid":65234.1,"ask":65235.0, ...}]}
///
/// Status / heartbeat messages are ignored:
///   {"channel":"status", ...}
///   {"channel":"heartbeat"}
fn parseKrakenMessage(feed: *ExchangeFeed, body: []const u8) void {
    // Cheap channel filter — only act on ticker frames.
    if (std.mem.indexOf(u8, body, "\"channel\":\"ticker\"") == null) return;

    parseKrakenSymbol(feed, body, "\"symbol\":\"BTC/USD\"", SLOT_BTC_KRAKEN);
    parseKrakenSymbol(feed, body, "\"symbol\":\"LCX/USD\"", SLOT_LCX_KRAKEN);
}

fn parseKrakenSymbol(feed: *ExchangeFeed, body: []const u8, marker: []const u8, slot: usize) void {
    const pos = std.mem.indexOf(u8, body, marker) orelse return;
    const window_end = @min(body.len, pos + 512);
    const window = body[pos..window_end];

    // Kraken v2 emits raw numeric values, not strings.
    const bid = parseUnquotedPrice(window, "\"bid\":");
    const ask = parseUnquotedPrice(window, "\"ask\":");

    if (bid != null or ask != null) {
        const bid_v = bid orelse (ask orelse 0);
        const ask_v = ask orelse (bid orelse 0);
        feed.updateSlot(slot, bid_v, ask_v);
    }
}

// ── LCX worker ───────────────────────────────────────────────────────────────

fn lcxWorker(feed: *ExchangeFeed) void {
    var backoff: u64 = BACKOFF_INITIAL_MS;
    while (feed.run.load(.acquire)) {
        runLcxSession(feed) catch {};
        feed.markSlotFailed(SLOT_BTC_LCX);
        feed.markSlotFailed(SLOT_LCX_LCX);
        backoff = sleepBackoff(feed, backoff);
    }
}

fn runLcxSession(feed: *ExchangeFeed) !void {
    var client = try WsClient.connect(
        feed.allocator,
        "exchange-api.lcx.com",
        443,
        "/ws",
        true,
    );
    defer client.close();

    // PascalCase keys, case-sensitive. Empty subscribe → all pairs; we filter
    // client-side on data.pair.
    const subscribe =
        \\{"Topic":"subscribe","Type":"ticker"}
    ;
    try client.send(subscribe);

    const buf = try feed.allocator.alloc(u8, RECV_BUF_SIZE);
    defer feed.allocator.free(buf);

    var last_ping_ms: i64 = std.time.milliTimestamp();

    while (feed.run.load(.acquire)) {
        // Send app-level "ping" text frame at most every LCX_PING_INTERVAL_MS.
        const now_ms = std.time.milliTimestamp();
        if (now_ms - last_ping_ms >= LCX_PING_INTERVAL_MS) {
            client.send("ping") catch return error.ConnectionClosed;
            last_ping_ms = now_ms;
        }

        const maybe_msg = try client.recv(buf);
        const msg = maybe_msg orelse continue;
        switch (msg.kind) {
            .text => parseLcxMessage(feed, msg.data),
            .ping => try client.sendPong(msg.data),
            .pong => {},
            .close => return error.ConnectionClosed,
        }
    }
}

/// LCX ticker frame (single pair update):
///   {"data":{"pair":"BTC/USDC","bestBid":65234.1,"bestAsk":65235.0, ...}}
/// May also receive subscription ack frames or "pong" — all safely ignored.
fn parseLcxMessage(feed: *ExchangeFeed, body: []const u8) void {
    parseLcxPair(feed, body, "\"pair\":\"BTC/USDC\"", SLOT_BTC_LCX);
    parseLcxPair(feed, body, "\"pair\":\"LCX/USDC\"", SLOT_LCX_LCX);
}

fn parseLcxPair(feed: *ExchangeFeed, body: []const u8, marker: []const u8, slot: usize) void {
    if (std.mem.indexOf(u8, body, marker) == null) return;

    // bestBid / bestAsk are numeric (not quoted) in LCX WS feed.
    const bid = parseUnquotedPrice(body, "\"bestBid\":");
    const ask = parseUnquotedPrice(body, "\"bestAsk\":");

    if (bid != null or ask != null) {
        const bid_v = bid orelse (ask orelse 0);
        const ask_v = ask orelse (bid orelse 0);
        feed.updateSlot(slot, bid_v, ask_v);
    }
}

// ── JSON parsers (minimal, indexOf-based — same idea as oracle_fetcher.zig) ──

/// Parse a quoted JSON price field. Pass the prefix INCLUDING the opening
/// quote, e.g. `"best_bid":"`. Returns price in micro-USD.
pub fn parseQuotedPrice(body: []const u8, prefix_with_quote: []const u8) ?u64 {
    const pos = std.mem.indexOf(u8, body, prefix_with_quote) orelse return null;
    const val_start = pos + prefix_with_quote.len;
    const val_end = std.mem.indexOfPos(u8, body, val_start, "\"") orelse return null;
    if (val_end <= val_start) return null;
    return floatToMicroUsd(body[val_start..val_end]);
}

/// Parse an unquoted (numeric) JSON price field. Pass the prefix as in
/// `"bid":` or `"bestAsk":`. Reads digits + optional decimal point; stops on
/// the first non-numeric character (`,`, `}`, whitespace, etc.).
pub fn parseUnquotedPrice(body: []const u8, prefix: []const u8) ?u64 {
    const pos = std.mem.indexOf(u8, body, prefix) orelse return null;
    var i = pos + prefix.len;

    // Skip whitespace.
    while (i < body.len and (body[i] == ' ' or body[i] == '\t' or body[i] == '\n' or body[i] == '\r')) : (i += 1) {}

    const num_start = i;
    while (i < body.len and ((body[i] >= '0' and body[i] <= '9') or body[i] == '.')) : (i += 1) {}
    if (i == num_start) return null;
    return floatToMicroUsd(body[num_start..i]);
}

/// Convert a decimal string like "84321.45" or "0.000123" to micro-USD
/// (1 USD = 1_000_000). Handles up to 6 decimal places; any extra digits are
/// truncated. Returns null on parse failure.
pub fn floatToMicroUsd(s: []const u8) ?u64 {
    if (s.len == 0) return null;

    const dot_pos = std.mem.indexOf(u8, s, ".");

    const int_part_str = if (dot_pos) |dp| s[0..dp] else s;
    const int_part: u64 = if (int_part_str.len == 0)
        0
    else
        std.fmt.parseUnsigned(u64, int_part_str, 10) catch return null;

    var frac: u64 = 0;
    if (dot_pos) |dp| {
        const frac_str = s[dp + 1 ..];
        const frac_digits = @min(frac_str.len, 6);
        if (frac_digits > 0) {
            frac = std.fmt.parseUnsigned(u64, frac_str[0..frac_digits], 10) catch return null;
            var remaining: usize = 6 - frac_digits;
            while (remaining > 0) : (remaining -= 1) frac *= 10;
        }
    }

    return int_part * 1_000_000 + frac;
}

// ── Median helper (mirrors oracle_fetcher.zig logic) ────────────────────────

fn medianFor(slice: []const PriceFetch) ?u64 {
    var valid: [3]u64 = undefined;
    var count: u8 = 0;
    for (slice) |p| {
        if (p.success and p.bid_micro_usd > 0) {
            valid[count] = (p.bid_micro_usd + p.ask_micro_usd) / 2;
            count += 1;
            if (count == 3) break;
        }
    }
    if (count == 0) return null;
    if (count == 1) return valid[0];
    sortU64(valid[0..count]);
    if (count == 2) return (valid[0] + valid[1]) / 2;
    return valid[count / 2];
}

fn sortU64(arr: []u64) void {
    if (arr.len <= 1) return;
    for (1..arr.len) |i| {
        const key = arr[i];
        var j: usize = i;
        while (j > 0 and arr[j - 1] > key) {
            arr[j] = arr[j - 1];
            j -= 1;
        }
        arr[j] = key;
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// Tests — JSON parsing + slot logic only (no live WS connections)
// ═══════════════════════════════════════════════════════════════════════════════

test "floatToMicroUsd — integer" {
    try std.testing.expectEqual(@as(?u64, 84_321_000_000), floatToMicroUsd("84321"));
}

test "floatToMicroUsd — 2 decimals" {
    try std.testing.expectEqual(@as(?u64, 84_321_450_000), floatToMicroUsd("84321.45"));
}

test "floatToMicroUsd — 6 decimals" {
    try std.testing.expectEqual(@as(?u64, 123_456), floatToMicroUsd("0.123456"));
}

test "floatToMicroUsd — leading dot" {
    try std.testing.expectEqual(@as(?u64, 500_000), floatToMicroUsd(".5"));
}

test "floatToMicroUsd — empty" {
    try std.testing.expectEqual(@as(?u64, null), floatToMicroUsd(""));
}

test "parseQuotedPrice — Coinbase-style" {
    const json =
        \\{"product_id":"BTC-USD","best_bid":"32705.30","best_ask":"32762.60"}
    ;
    try std.testing.expectEqual(@as(?u64, 32_705_300_000), parseQuotedPrice(json, "\"best_bid\":\""));
    try std.testing.expectEqual(@as(?u64, 32_762_600_000), parseQuotedPrice(json, "\"best_ask\":\""));
}

test "parseQuotedPrice — missing field" {
    const json =
        \\{"product_id":"BTC-USD"}
    ;
    try std.testing.expectEqual(@as(?u64, null), parseQuotedPrice(json, "\"best_bid\":\""));
}

test "parseUnquotedPrice — Kraken numeric" {
    const json =
        \\{"symbol":"BTC/USD","bid":65234.1,"ask":65235.0}
    ;
    try std.testing.expectEqual(@as(?u64, 65_234_100_000), parseUnquotedPrice(json, "\"bid\":"));
    try std.testing.expectEqual(@as(?u64, 65_235_000_000), parseUnquotedPrice(json, "\"ask\":"));
}

test "parseUnquotedPrice — LCX bestBid/bestAsk" {
    const json =
        \\{"data":{"pair":"BTC/USDC","bestBid":65234.5,"bestAsk":65236.7}}
    ;
    try std.testing.expectEqual(@as(?u64, 65_234_500_000), parseUnquotedPrice(json, "\"bestBid\":"));
    try std.testing.expectEqual(@as(?u64, 65_236_700_000), parseUnquotedPrice(json, "\"bestAsk\":"));
}

test "parseUnquotedPrice — small LCX number" {
    const json =
        \\{"data":{"pair":"LCX/USDC","bestBid":0.05432,"bestAsk":0.05444}}
    ;
    try std.testing.expectEqual(@as(?u64, 54_320), parseUnquotedPrice(json, "\"bestBid\":"));
    try std.testing.expectEqual(@as(?u64, 54_440), parseUnquotedPrice(json, "\"bestAsk\":"));
}

test "parseUnquotedPrice — whitespace tolerated" {
    const json = "{\"bid\":   42.5  ,\"ask\": 43}";
    try std.testing.expectEqual(@as(?u64, 42_500_000), parseUnquotedPrice(json, "\"bid\":"));
    try std.testing.expectEqual(@as(?u64, 43_000_000), parseUnquotedPrice(json, "\"ask\":"));
}

test "ExchangeFeed — init has all 6 slots zeroed" {
    var feed = ExchangeFeed.init(std.testing.allocator);
    const snap = feed.snapshot();
    try std.testing.expectEqual(@as(usize, 6), snap.len);
    for (snap) |p| {
        try std.testing.expect(!p.success);
        try std.testing.expectEqual(@as(u64, 0), p.bid_micro_usd);
        try std.testing.expectEqual(@as(u64, 0), p.ask_micro_usd);
    }
    try std.testing.expectEqualStrings("Coinbase", snap[0].exchange);
    try std.testing.expectEqualStrings("Kraken",   snap[1].exchange);
    try std.testing.expectEqualStrings("LCX",      snap[2].exchange);
    try std.testing.expectEqualStrings("BTC/USD",  snap[0].pair);
    try std.testing.expectEqualStrings("LCX/USD",  snap[3].pair);
}

test "ExchangeFeed — updateSlot writes through mutex" {
    var feed = ExchangeFeed.init(std.testing.allocator);
    feed.updateSlot(SLOT_BTC_KRAKEN, 65_000_000_000, 65_010_000_000);
    const snap = feed.snapshot();
    try std.testing.expect(snap[SLOT_BTC_KRAKEN].success);
    try std.testing.expectEqual(@as(u64, 65_000_000_000), snap[SLOT_BTC_KRAKEN].bid_micro_usd);
    try std.testing.expectEqual(@as(u64, 65_010_000_000), snap[SLOT_BTC_KRAKEN].ask_micro_usd);
    try std.testing.expect(snap[SLOT_BTC_KRAKEN].timestamp_ms > 0);
}

test "ExchangeFeed — markSlotFailed clears success flag" {
    var feed = ExchangeFeed.init(std.testing.allocator);
    feed.updateSlot(SLOT_LCX_LCX, 50_000, 51_000);
    feed.markSlotFailed(SLOT_LCX_LCX);
    const snap = feed.snapshot();
    try std.testing.expect(!snap[SLOT_LCX_LCX].success);
}

test "ExchangeFeed — getMedianBtc with 3 slots" {
    var feed = ExchangeFeed.init(std.testing.allocator);
    feed.updateSlot(SLOT_BTC_COINBASE, 84_000_000_000, 84_100_000_000); // mid 84_050
    feed.updateSlot(SLOT_BTC_KRAKEN,   84_200_000_000, 84_300_000_000); // mid 84_250
    feed.updateSlot(SLOT_BTC_LCX,      84_100_000_000, 84_100_000_000); // mid 84_100
    const median = feed.getMedianBtc();
    try std.testing.expect(median != null);
    try std.testing.expectEqual(@as(u64, 84_100_000_000), median.?);
}

test "ExchangeFeed — getMedianBtc with 2 slots is average" {
    var feed = ExchangeFeed.init(std.testing.allocator);
    feed.updateSlot(SLOT_BTC_COINBASE, 84_000_000_000, 84_000_000_000);
    feed.updateSlot(SLOT_BTC_KRAKEN,   84_200_000_000, 84_200_000_000);
    const median = feed.getMedianBtc();
    try std.testing.expect(median != null);
    try std.testing.expectEqual(@as(u64, 84_100_000_000), median.?);
}

test "ExchangeFeed — getMedianBtc returns null when empty" {
    var feed = ExchangeFeed.init(std.testing.allocator);
    try std.testing.expectEqual(@as(?u64, null), feed.getMedianBtc());
    try std.testing.expectEqual(@as(?u64, null), feed.getMedianLcx());
}

test "ExchangeFeed — getMedianLcx independent of BTC slots" {
    var feed = ExchangeFeed.init(std.testing.allocator);
    feed.updateSlot(SLOT_BTC_COINBASE, 84_000_000_000, 84_000_000_000);
    feed.updateSlot(SLOT_LCX_LCX, 50_000, 60_000); // mid 55_000
    try std.testing.expectEqual(@as(?u64, 55_000), feed.getMedianLcx());
    try std.testing.expectEqual(@as(?u64, 84_000_000_000), feed.getMedianBtc());
}

test "Coinbase ticker parse — both products in one frame" {
    var feed = ExchangeFeed.init(std.testing.allocator);
    const frame =
        \\{"channel":"ticker","events":[{"type":"snapshot","tickers":[
        \\{"product_id":"BTC-USD","best_bid":"32705.30","best_ask":"32762.60","price":"32733.00"},
        \\{"product_id":"LCX-USD","best_bid":"0.054320","best_ask":"0.054440","price":"0.05438"}
        \\]}]}
    ;
    parseCoinbaseTicker(&feed, frame);
    const snap = feed.snapshot();
    try std.testing.expect(snap[SLOT_BTC_COINBASE].success);
    try std.testing.expectEqual(@as(u64, 32_705_300_000), snap[SLOT_BTC_COINBASE].bid_micro_usd);
    try std.testing.expectEqual(@as(u64, 32_762_600_000), snap[SLOT_BTC_COINBASE].ask_micro_usd);
    try std.testing.expect(snap[SLOT_LCX_COINBASE].success);
    try std.testing.expectEqual(@as(u64, 54_320), snap[SLOT_LCX_COINBASE].bid_micro_usd);
    try std.testing.expectEqual(@as(u64, 54_440), snap[SLOT_LCX_COINBASE].ask_micro_usd);
}

test "Kraken ticker parse — BTC update only" {
    var feed = ExchangeFeed.init(std.testing.allocator);
    const frame =
        \\{"channel":"ticker","type":"update","data":[{"symbol":"BTC/USD","bid":65234.1,"ask":65235.0,"last":65234.5}]}
    ;
    parseKrakenMessage(&feed, frame);
    const snap = feed.snapshot();
    try std.testing.expect(snap[SLOT_BTC_KRAKEN].success);
    try std.testing.expectEqual(@as(u64, 65_234_100_000), snap[SLOT_BTC_KRAKEN].bid_micro_usd);
    try std.testing.expectEqual(@as(u64, 65_235_000_000), snap[SLOT_BTC_KRAKEN].ask_micro_usd);
    // LCX slot must remain untouched.
    try std.testing.expect(!snap[SLOT_LCX_KRAKEN].success);
}

test "Kraken parser ignores heartbeat / status frames" {
    var feed = ExchangeFeed.init(std.testing.allocator);
    parseKrakenMessage(&feed, "{\"channel\":\"heartbeat\"}");
    parseKrakenMessage(&feed, "{\"channel\":\"status\",\"data\":[{\"system\":\"online\"}]}");
    const snap = feed.snapshot();
    try std.testing.expect(!snap[SLOT_BTC_KRAKEN].success);
    try std.testing.expect(!snap[SLOT_LCX_KRAKEN].success);
}

test "LCX ticker parse — BTC/USDC pair" {
    var feed = ExchangeFeed.init(std.testing.allocator);
    const frame =
        \\{"data":{"pair":"BTC/USDC","bestBid":65234.5,"bestAsk":65236.7,"lastPrice":65235.6}}
    ;
    parseLcxMessage(&feed, frame);
    const snap = feed.snapshot();
    try std.testing.expect(snap[SLOT_BTC_LCX].success);
    try std.testing.expectEqual(@as(u64, 65_234_500_000), snap[SLOT_BTC_LCX].bid_micro_usd);
    try std.testing.expectEqual(@as(u64, 65_236_700_000), snap[SLOT_BTC_LCX].ask_micro_usd);
}

test "LCX ticker parse — LCX/USDC pair" {
    var feed = ExchangeFeed.init(std.testing.allocator);
    const frame =
        \\{"data":{"pair":"LCX/USDC","bestBid":0.054321,"bestAsk":0.054440}}
    ;
    parseLcxMessage(&feed, frame);
    const snap = feed.snapshot();
    try std.testing.expect(snap[SLOT_LCX_LCX].success);
    try std.testing.expectEqual(@as(u64, 54_321), snap[SLOT_LCX_LCX].bid_micro_usd);
    try std.testing.expectEqual(@as(u64, 54_440), snap[SLOT_LCX_LCX].ask_micro_usd);
}

test "LCX parser ignores unknown pair" {
    var feed = ExchangeFeed.init(std.testing.allocator);
    const frame =
        \\{"data":{"pair":"ETH/USDC","bestBid":2000.0,"bestAsk":2001.0}}
    ;
    parseLcxMessage(&feed, frame);
    const snap = feed.snapshot();
    try std.testing.expect(!snap[SLOT_BTC_LCX].success);
    try std.testing.expect(!snap[SLOT_LCX_LCX].success);
}
