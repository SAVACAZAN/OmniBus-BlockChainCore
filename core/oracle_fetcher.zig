/// Oracle Price Fetcher — fetches real bid/ask prices for BTC and LCX from
/// LCX Exchange, Kraken, and Coinbase Advanced public REST APIs (no auth).
///
/// 6 price slots = 2 assets × 3 exchanges:
///   [0] BTC LCX        [1] BTC Kraken     [2] BTC Coinbase Advanced
///   [3] LCX LCX        [4] LCX Kraken     [5] LCX Coinbase Advanced
///
/// Returns prices in micro-USD (u64): 1 USD = 1_000_000 micro-USD.
/// Example: BTC at $84,321.45 → 84_321_450_000 micro-USD.
///
/// Uses std.http.Client with std.Io.Writer.Allocating (Zig 0.15.x).
/// All HTTP calls are best-effort: errors are caught, never crash the miner.
const std = @import("std");

// ── Public types ─────────────────────────────────────────────────────────────

pub const PriceFetch = struct {
    exchange: []const u8,
    pair: []const u8,
    bid_micro_usd: u64,
    ask_micro_usd: u64,
    timestamp_ms: i64,
    success: bool,
};

pub const OracleFetcher = struct {
    allocator: std.mem.Allocator,
    last_fetch_ms: i64,
    fetch_interval_ms: i64,

    /// 6 price slots — see header comment for layout.
    prices: [6]PriceFetch,
    price_count: u8,

    /// Background-thread state. Mining loop never calls fetchAll directly
    /// any more — it just reads `prices` under `mutex`. The worker thread
    /// owns all blocking HTTPS work.
    mutex: std.Thread.Mutex = .{},
    run: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    worker: ?std.Thread = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .last_fetch_ms = 0,
            .fetch_interval_ms = 10_000, // 10 seconds default
            .prices = [6]PriceFetch{
                .{ .exchange = "LCX",      .pair = "BTC/USD", .bid_micro_usd = 0, .ask_micro_usd = 0, .timestamp_ms = 0, .success = false },
                .{ .exchange = "Kraken",   .pair = "BTC/USD", .bid_micro_usd = 0, .ask_micro_usd = 0, .timestamp_ms = 0, .success = false },
                .{ .exchange = "Coinbase", .pair = "BTC/USD", .bid_micro_usd = 0, .ask_micro_usd = 0, .timestamp_ms = 0, .success = false },
                .{ .exchange = "LCX",      .pair = "LCX/USD", .bid_micro_usd = 0, .ask_micro_usd = 0, .timestamp_ms = 0, .success = false },
                .{ .exchange = "Kraken",   .pair = "LCX/USD", .bid_micro_usd = 0, .ask_micro_usd = 0, .timestamp_ms = 0, .success = false },
                .{ .exchange = "Coinbase", .pair = "LCX/USD", .bid_micro_usd = 0, .ask_micro_usd = 0, .timestamp_ms = 0, .success = false },
            },
            .price_count = 0,
            .mutex = .{},
            .run = std.atomic.Value(bool).init(false),
            .worker = null,
        };
    }

    /// Spawn the background worker. Caller must keep `self` alive
    /// (g_oracle_fetcher is a process-lifetime global, so this is safe).
    /// Idempotent — second call is a no-op.
    ///
    /// CRITICAL: This was the root cause of the periodic 8–9 s block-time
    /// spikes the operator observed. The mining loop used to call
    /// fetchAll() directly every 10 blocks; fetchAll() does 6 sequential
    /// blocking HTTPS calls (LCX + Kraken + Coinbase × BTC + LCX). When
    /// any one of them was slow (~1.5 s timeout × 6 = 9 s worst case),
    /// the entire mining thread stalled for that long. Pattern in the
    /// log: 9 fast blocks (200–400 ms) then 1 block at ~9000 ms,
    /// repeating every 10 blocks. By moving the work to a dedicated
    /// thread that ticks every fetch_interval_ms (default 10 s), the
    /// mining loop now only does a 1 µs mutex-guarded read of the
    /// snapshot — block latency stays uniform.
    pub fn startWorker(self: *Self) !void {
        if (self.run.load(.acquire)) return;
        self.run.store(true, .release);
        self.worker = try std.Thread.spawn(.{}, workerLoop, .{self});
    }

    pub fn stopWorker(self: *Self) void {
        self.run.store(false, .release);
        if (self.worker) |t| {
            t.join();
            self.worker = null;
        }
    }

    fn workerLoop(self: *Self) void {
        // Run an immediate fetch on startup so the first read isn't all
        // zeros, then loop on the configured interval. We sleep in 100 ms
        // chunks so stopWorker() reacts within ~100 ms on shutdown.
        self.fetchAllInternal();
        while (self.run.load(.acquire)) {
            const interval = self.fetch_interval_ms;
            var slept_ms: i64 = 0;
            while (slept_ms < interval and self.run.load(.acquire)) : (slept_ms += 100) {
                std.Thread.sleep(100 * std.time.ns_per_ms);
            }
            if (!self.run.load(.acquire)) break;
            self.fetchAllInternal();
        }
    }

    /// Worker-thread entry point. Same body as the old fetchAll() but
    /// holds the mutex while writing each slot so the mining loop can
    /// take a consistent snapshot. The HTTPS calls themselves run
    /// outside the lock; we only lock for the per-slot store.
    fn fetchAllInternal(self: *Self) void {
        // BTC pair (slots 0-2)
        self.fetchLcxPair(0, "BTC/USDC", "BTC/USD");
        self.fetchKrakenPair(1, "XBTUSD",  "BTC/USD");
        self.fetchCoinbasePair(2, "BTC-USD", "BTC/USD");
        // LCX pair (slots 3-5)
        self.fetchLcxPair(3, "LCX/USDC", "LCX/USD");
        self.fetchKrakenPair(4, "LCXUSD",  "LCX/USD");
        self.fetchCoinbasePair(5, "LCX-USD", "LCX/USD");

        self.mutex.lock();
        defer self.mutex.unlock();
        self.last_fetch_ms = std.time.milliTimestamp();
        self.price_count = 0;
        for (self.prices) |p| {
            if (p.success) self.price_count += 1;
        }
    }

    /// Take a consistent snapshot of all 6 price slots. Constant-time,
    /// holds the mutex for ~1 µs. Safe to call from the mining loop on
    /// every block.
    pub fn snapshot(self: *Self) [6]PriceFetch {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.prices;
    }

    /// DEPRECATED — kept only for tests / one-off CLI scripts that still
    /// want a synchronous fetch. The mining loop must NOT call this any
    /// more (it blocks for ~1–9 s). Use startWorker() once at startup
    /// and call snapshot() on every block instead.
    pub fn fetchAll(self: *Self) void {
        self.fetchAllInternal();
    }

    /// Locked write of a single price slot. fetch* helpers route through
    /// this so the worker thread doesn't tear writes that the mining
    /// loop is reading via snapshot().
    fn storeSlot(self: *Self, slot: usize, p: PriceFetch) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.prices[slot] = p;
    }

    fn markSlotFailed(self: *Self, slot: usize) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.prices[slot].success = false;
    }

    /// Fetch from LCX public ticker API: bestBid / bestAsk in JSON.
    /// LCX response: {"data":{"bestBid":84000.5,"bestAsk":84001.2,...}}
    fn fetchLcxPair(self: *Self, slot: usize, lcx_pair: []const u8, label_pair: []const u8) void {
        var url_buf: [128]u8 = undefined;
        const url = std.fmt.bufPrint(&url_buf,
            "https://exchange-api.lcx.com/api/ticker?pair={s}", .{lcx_pair}) catch {
            self.markSlotFailed(slot);
            return;
        };
        const body = httpGet(self.allocator, url) catch {
            self.markSlotFailed(slot);
            return;
        };
        defer self.allocator.free(body);

        const bid = parseLcxPrice(body, "bestBid");
        const ask = parseLcxPrice(body, "bestAsk");

        if (bid != null or ask != null) {
            const bid_val = bid orelse (ask orelse 0);
            const ask_val = ask orelse (bid orelse 0);
            self.storeSlot(slot, .{
                .exchange      = "LCX",
                .pair          = label_pair,
                .bid_micro_usd = bid_val,
                .ask_micro_usd = ask_val,
                .timestamp_ms  = std.time.milliTimestamp(),
                .success       = true,
            });
        } else {
            self.markSlotFailed(slot);
        }
    }

    /// Fetch from Kraken public ticker API.
    /// Response: {"result":{"<KEY>":{"a":["84001.2",...], "b":["84000.5",...], ...}}}
    /// Note: Kraken uses XBT for BTC. LCX may not be listed → fetch returns
    /// error or empty result, slot stays unsuccessful.
    fn fetchKrakenPair(self: *Self, slot: usize, kraken_pair: []const u8, label_pair: []const u8) void {
        var url_buf: [128]u8 = undefined;
        const url = std.fmt.bufPrint(&url_buf,
            "https://api.kraken.com/0/public/Ticker?pair={s}", .{kraken_pair}) catch {
            self.markSlotFailed(slot);
            return;
        };
        const body = httpGet(self.allocator, url) catch {
            self.markSlotFailed(slot);
            return;
        };
        defer self.allocator.free(body);

        const bid = parseKrakenPrice(body, "\"b\"");
        const ask = parseKrakenPrice(body, "\"a\"");

        if (bid != null or ask != null) {
            const bid_val = bid orelse (ask orelse 0);
            const ask_val = ask orelse (bid orelse 0);
            self.storeSlot(slot, .{
                .exchange      = "Kraken",
                .pair          = label_pair,
                .bid_micro_usd = bid_val,
                .ask_micro_usd = ask_val,
                .timestamp_ms  = std.time.milliTimestamp(),
                .success       = true,
            });
        } else {
            self.markSlotFailed(slot);
        }
    }

    /// Fetch from Coinbase Advanced (api.exchange.coinbase.com) public ticker.
    /// Response: {"ask":"84001.2","bid":"84000.5","price":"84000.85","time":"...","trade_id":...}
    /// LCX may not be listed → 404 → slot stays unsuccessful.
    fn fetchCoinbasePair(self: *Self, slot: usize, cb_pair: []const u8, label_pair: []const u8) void {
        var url_buf: [128]u8 = undefined;
        const url = std.fmt.bufPrint(&url_buf,
            "https://api.exchange.coinbase.com/products/{s}/ticker", .{cb_pair}) catch {
            self.markSlotFailed(slot);
            return;
        };
        const body = httpGet(self.allocator, url) catch {
            self.markSlotFailed(slot);
            return;
        };
        defer self.allocator.free(body);

        const bid = parseQuotedPrice(body, "\"bid\":\"");
        const ask = parseQuotedPrice(body, "\"ask\":\"");

        if (bid != null or ask != null) {
            const bid_val = bid orelse (ask orelse 0);
            const ask_val = ask orelse (bid orelse 0);
            self.storeSlot(slot, .{
                .exchange      = "Coinbase",
                .pair          = label_pair,
                .bid_micro_usd = bid_val,
                .ask_micro_usd = ask_val,
                .timestamp_ms  = std.time.milliTimestamp(),
                .success       = true,
            });
        } else {
            self.markSlotFailed(slot);
        }
    }

    /// Get median BTC price across the 3 BTC slots (0..3).
    /// Returns null if no exchange returned a valid price.
    /// Takes mutex briefly to read a coherent snapshot vs. the worker
    /// thread's writes.
    pub fn getMedianPrice(self: *Self) ?u64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return medianFor(self.prices[0..3]);
    }

    /// Get median LCX price across the 3 LCX slots (3..6).
    pub fn getMedianLcxPrice(self: *Self) ?u64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return medianFor(self.prices[3..6]);
    }

    /// Get best BTC bid (highest) across exchanges
    pub fn getBestBid(self: *Self) ?u64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return bestBidFor(self.prices[0..3]);
    }

    /// Get best BTC ask (lowest) across exchanges
    pub fn getBestAsk(self: *const Self) ?u64 {
        return bestAskFor(self.prices[0..3]);
    }

    /// Format median BTC price as a human-readable string: "$84,321.45"
    pub fn formatMedianPrice(self: *Self, buf: []u8) []const u8 {
        const median = self.getMedianPrice() orelse return "N/A";
        return formatMicroUsd(buf, median);
    }
};

// ── Helpers shared between BTC and LCX views ────────────────────────────────

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

fn bestBidFor(slice: []const PriceFetch) ?u64 {
    var best: ?u64 = null;
    for (slice) |p| {
        if (p.success and p.bid_micro_usd > 0) {
            if (best == null or p.bid_micro_usd > best.?) best = p.bid_micro_usd;
        }
    }
    return best;
}

fn bestAskFor(slice: []const PriceFetch) ?u64 {
    var best: ?u64 = null;
    for (slice) |p| {
        if (p.success and p.ask_micro_usd > 0) {
            if (best == null or p.ask_micro_usd < best.?) best = p.ask_micro_usd;
        }
    }
    return best;
}

fn formatMicroUsd(buf: []u8, micro: u64) []const u8 {
    const dollars = micro / 1_000_000;
    const cents = (micro % 1_000_000) / 10_000;
    return std.fmt.bufPrint(buf, "${d}.{d:0>2}", .{ dollars, cents }) catch "ERR";
}

// ── HTTP client — uses std.http.Client with std.Io.Writer.Allocating ─────────

/// Perform an HTTP GET and return the response body. Caller must free the result.
fn httpGet(allocator: std.mem.Allocator, url: []const u8) ![]u8 {
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    var wa = std.Io.Writer.Allocating.init(allocator);
    defer wa.deinit();

    const result = try client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &wa.writer,
        .keep_alive = false,
    });

    const status: u16 = @intCast(@intFromEnum(result.status));
    if (status != 200) return error.HttpError;

    return try wa.toOwnedSlice();
}

// ── JSON price parsers (simple string search, no full JSON parser needed) ────

/// Parse a float field from LCX JSON: {"data":{"bestBid":84000.5,...}}
/// Looks for `"fieldName":` followed by a number.
/// Returns price in micro-USD (u64).
pub fn parseLcxPrice(body: []const u8, field_name: []const u8) ?u64 {
    // Build search pattern: "fieldName":
    var pattern_buf: [64]u8 = undefined;
    const pattern = std.fmt.bufPrint(&pattern_buf, "\"{s}\":", .{field_name}) catch return null;

    const pos = std.mem.indexOf(u8, body, pattern) orelse return null;
    const after_key = pos + pattern.len;

    // Skip whitespace
    var i = after_key;
    while (i < body.len and (body[i] == ' ' or body[i] == '\t')) : (i += 1) {}

    // Extract the number (may be integer or float, not quoted)
    const num_start = i;
    while (i < body.len and (body[i] >= '0' and body[i] <= '9' or body[i] == '.')) : (i += 1) {}
    if (i == num_start) return null;

    return floatToMicroUsd(body[num_start..i]);
}

/// Parse Kraken bid/ask price. Kraken format: "b":["84000.5","1.2","1234567890"]
/// `key` should be `"\"b\""` or `"\"a\""`.
pub fn parseKrakenPrice(body: []const u8, key: []const u8) ?u64 {
    const pos = std.mem.indexOf(u8, body, key) orelse return null;
    // Find the opening [ after the key
    const bracket_start = std.mem.indexOfPos(u8, body, pos + key.len, "[") orelse return null;
    // Find first quoted string inside the array: ["84000.5", ...]
    const quote1 = std.mem.indexOfPos(u8, body, bracket_start + 1, "\"") orelse return null;
    const quote2 = std.mem.indexOfPos(u8, body, quote1 + 1, "\"") orelse return null;

    if (quote2 <= quote1 + 1) return null;
    return floatToMicroUsd(body[quote1 + 1 .. quote2]);
}

/// Parse Coinbase spot price (legacy v2 API). Format: {"data":{"amount":"84000.50",...}}
pub fn parseCoinbasePrice(body: []const u8) ?u64 {
    return parseQuotedPrice(body, "\"amount\":\"");
}

/// Parse a price from a quoted JSON string field.
/// Pass the full prefix INCLUDING the opening quote, e.g. `"bid":"`.
/// Used by Coinbase Advanced ticker which returns: {"bid":"84000.5","ask":"84001.2",...}
pub fn parseQuotedPrice(body: []const u8, prefix_with_quote: []const u8) ?u64 {
    const pos = std.mem.indexOf(u8, body, prefix_with_quote) orelse return null;
    const val_start = pos + prefix_with_quote.len;
    const val_end = std.mem.indexOfPos(u8, body, val_start, "\"") orelse return null;
    if (val_end <= val_start) return null;
    return floatToMicroUsd(body[val_start..val_end]);
}

/// Convert a decimal string like "84321.45" to micro-USD: 84_321_450_000.
/// Handles up to 6 decimal places. Returns null on parse failure.
pub fn floatToMicroUsd(s: []const u8) ?u64 {
    if (s.len == 0) return null;

    // Find the decimal point
    const dot_pos = std.mem.indexOf(u8, s, ".");

    // Parse integer part
    const int_part_str = if (dot_pos) |dp| s[0..dp] else s;
    const int_part = std.fmt.parseUnsigned(u64, int_part_str, 10) catch return null;

    // Parse fractional part (up to 6 digits)
    var frac: u64 = 0;
    if (dot_pos) |dp| {
        const frac_str = s[dp + 1 ..];
        const frac_digits = @min(frac_str.len, 6);
        if (frac_digits > 0) {
            frac = std.fmt.parseUnsigned(u64, frac_str[0..frac_digits], 10) catch return null;
            // Scale up to 6 decimal places
            var remaining = 6 - frac_digits;
            while (remaining > 0) : (remaining -= 1) {
                frac *= 10;
            }
        }
    }

    return int_part * 1_000_000 + frac;
}

/// Simple insertion sort for a small u64 slice (max 3 elements).
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
// Tests — JSON parsing only, no HTTP calls
// ═══════════════════════════════════════════════════════════════════════════════

test "floatToMicroUsd — integer" {
    const result = floatToMicroUsd("84321");
    try std.testing.expectEqual(@as(?u64, 84_321_000_000), result);
}

test "floatToMicroUsd — 2 decimals" {
    const result = floatToMicroUsd("84321.45");
    try std.testing.expectEqual(@as(?u64, 84_321_450_000), result);
}

test "floatToMicroUsd — 6 decimals" {
    const result = floatToMicroUsd("0.123456");
    try std.testing.expectEqual(@as(?u64, 123_456), result);
}

test "floatToMicroUsd — 1 decimal" {
    const result = floatToMicroUsd("100.5");
    try std.testing.expectEqual(@as(?u64, 100_500_000), result);
}

test "floatToMicroUsd — zero" {
    const result = floatToMicroUsd("0");
    try std.testing.expectEqual(@as(?u64, 0), result);
}

test "floatToMicroUsd — empty string" {
    const result = floatToMicroUsd("");
    try std.testing.expectEqual(@as(?u64, null), result);
}

test "parseLcxPrice — bestBid from real-like JSON" {
    const json =
        \\{"data":{"Symbol":"BTC/USDC","bestBid":84321.45,"bestAsk":84322.10,"currentPrice":84321.77}}
    ;
    const bid = parseLcxPrice(json, "bestBid");
    try std.testing.expectEqual(@as(?u64, 84_321_450_000), bid);

    const ask = parseLcxPrice(json, "bestAsk");
    try std.testing.expectEqual(@as(?u64, 84_322_100_000), ask);
}

test "parseLcxPrice — missing field returns null" {
    const json =
        \\{"data":{"Symbol":"BTC/USDC","currentPrice":84321.77}}
    ;
    const bid = parseLcxPrice(json, "bestBid");
    try std.testing.expectEqual(@as(?u64, null), bid);
}

test "parseKrakenPrice — bid and ask from real-like JSON" {
    const json =
        \\{"error":[],"result":{"XXBTZUSD":{"a":["84322.10","1","1.000"],"b":["84321.45","2","2.000"],"c":["84321.77","0.5"]}}}
    ;
    const ask = parseKrakenPrice(json, "\"a\"");
    try std.testing.expectEqual(@as(?u64, 84_322_100_000), ask);

    const bid = parseKrakenPrice(json, "\"b\"");
    try std.testing.expectEqual(@as(?u64, 84_321_450_000), bid);
}

test "parseKrakenPrice — missing key returns null" {
    const json =
        \\{"error":[],"result":{}}
    ;
    const ask = parseKrakenPrice(json, "\"a\"");
    try std.testing.expectEqual(@as(?u64, null), ask);
}

test "parseCoinbasePrice — amount from real-like JSON" {
    const json =
        \\{"data":{"base":"BTC","currency":"USD","amount":"84321.45"}}
    ;
    const price = parseCoinbasePrice(json);
    try std.testing.expectEqual(@as(?u64, 84_321_450_000), price);
}

test "parseCoinbasePrice — missing amount returns null" {
    const json =
        \\{"data":{"base":"BTC","currency":"USD"}}
    ;
    const price = parseCoinbasePrice(json);
    try std.testing.expectEqual(@as(?u64, null), price);
}

test "OracleFetcher — getMedianPrice with manually set prices" {
    const allocator = std.testing.allocator;
    var fetcher = OracleFetcher.init(allocator);

    // Simulate 3 successful fetches
    fetcher.prices[0] = .{
        .exchange = "LCX",
        .pair = "BTC/USD",
        .bid_micro_usd = 84_000_000_000, // $84,000
        .ask_micro_usd = 84_100_000_000,
        .timestamp_ms = 1000,
        .success = true,
    };
    fetcher.prices[1] = .{
        .exchange = "Kraken",
        .pair = "BTC/USD",
        .bid_micro_usd = 84_200_000_000, // $84,200
        .ask_micro_usd = 84_300_000_000,
        .timestamp_ms = 1000,
        .success = true,
    };
    fetcher.prices[2] = .{
        .exchange = "Coinbase",
        .pair = "BTC/USD",
        .bid_micro_usd = 84_100_000_000, // $84,100
        .ask_micro_usd = 84_100_000_000,
        .timestamp_ms = 1000,
        .success = true,
    };
    fetcher.price_count = 3;

    // Midpoints: LCX=84050, Kraken=84250, Coinbase=84100
    // Sorted: 84050, 84100, 84250 → median = 84100
    const median = fetcher.getMedianPrice();
    try std.testing.expect(median != null);
    try std.testing.expectEqual(@as(u64, 84_100_000_000), median.?);
}

test "OracleFetcher — getMedianPrice with 2 exchanges" {
    const allocator = std.testing.allocator;
    var fetcher = OracleFetcher.init(allocator);

    fetcher.prices[0] = .{
        .exchange = "LCX",
        .pair = "BTC/USD",
        .bid_micro_usd = 84_000_000_000,
        .ask_micro_usd = 84_000_000_000,
        .timestamp_ms = 1000,
        .success = true,
    };
    fetcher.prices[1] = .{
        .exchange = "Kraken",
        .pair = "BTC/USD",
        .bid_micro_usd = 84_200_000_000,
        .ask_micro_usd = 84_200_000_000,
        .timestamp_ms = 1000,
        .success = true,
    };
    // Coinbase failed
    fetcher.prices[2].success = false;
    fetcher.price_count = 2;

    // Average of 84000 and 84200 = 84100
    const median = fetcher.getMedianPrice();
    try std.testing.expect(median != null);
    try std.testing.expectEqual(@as(u64, 84_100_000_000), median.?);
}

test "OracleFetcher — getMedianPrice with no successful fetches" {
    const allocator = std.testing.allocator;
    var fetcher = OracleFetcher.init(allocator);

    const median = fetcher.getMedianPrice();
    try std.testing.expectEqual(@as(?u64, null), median);
}

test "OracleFetcher — getBestBid and getBestAsk" {
    const allocator = std.testing.allocator;
    var fetcher = OracleFetcher.init(allocator);

    fetcher.prices[0] = .{
        .exchange = "LCX",
        .pair = "BTC/USD",
        .bid_micro_usd = 84_000_000_000,
        .ask_micro_usd = 84_100_000_000,
        .timestamp_ms = 1000,
        .success = true,
    };
    fetcher.prices[1] = .{
        .exchange = "Kraken",
        .pair = "BTC/USD",
        .bid_micro_usd = 84_200_000_000,
        .ask_micro_usd = 84_050_000_000,
        .timestamp_ms = 1000,
        .success = true,
    };
    fetcher.prices[2].success = false;

    // Best bid = highest = Kraken 84200
    try std.testing.expectEqual(@as(?u64, 84_200_000_000), fetcher.getBestBid());
    // Best ask = lowest = Coinbase 84050
    try std.testing.expectEqual(@as(?u64, 84_050_000_000), fetcher.getBestAsk());
}

test "OracleFetcher — formatMedianPrice" {
    const allocator = std.testing.allocator;
    var fetcher = OracleFetcher.init(allocator);

    fetcher.prices[0] = .{
        .exchange = "LCX",
        .pair = "BTC/USD",
        .bid_micro_usd = 84_321_450_000,
        .ask_micro_usd = 84_321_450_000,
        .timestamp_ms = 1000,
        .success = true,
    };
    fetcher.price_count = 1;

    var buf: [64]u8 = undefined;
    const formatted = fetcher.formatMedianPrice(&buf);
    try std.testing.expectEqualStrings("$84321.45", formatted);
}

test "sortU64 — 3 elements" {
    var arr = [_]u64{ 300, 100, 200 };
    sortU64(&arr);
    try std.testing.expectEqual(@as(u64, 100), arr[0]);
    try std.testing.expectEqual(@as(u64, 200), arr[1]);
    try std.testing.expectEqual(@as(u64, 300), arr[2]);
}

test "sortU64 — already sorted" {
    var arr = [_]u64{ 100, 200, 300 };
    sortU64(&arr);
    try std.testing.expectEqual(@as(u64, 100), arr[0]);
    try std.testing.expectEqual(@as(u64, 200), arr[1]);
    try std.testing.expectEqual(@as(u64, 300), arr[2]);
}
