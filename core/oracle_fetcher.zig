/// Oracle Price Fetcher — fetches real BTC/USD prices from LCX, Kraken, and Coinbase
/// public REST APIs (no authentication required).
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

    /// Cached prices: [0]=LCX, [1]=Kraken, [2]=Coinbase
    prices: [3]PriceFetch,
    price_count: u8,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .last_fetch_ms = 0,
            .fetch_interval_ms = 10_000, // 10 seconds default
            .prices = [3]PriceFetch{
                .{ .exchange = "LCX", .pair = "BTC/USD", .bid_micro_usd = 0, .ask_micro_usd = 0, .timestamp_ms = 0, .success = false },
                .{ .exchange = "Kraken", .pair = "BTC/USD", .bid_micro_usd = 0, .ask_micro_usd = 0, .timestamp_ms = 0, .success = false },
                .{ .exchange = "Coinbase", .pair = "BTC/USD", .bid_micro_usd = 0, .ask_micro_usd = 0, .timestamp_ms = 0, .success = false },
            },
            .price_count = 0,
        };
    }

    /// Fetch prices from all 3 exchanges. Best-effort: never returns error.
    pub fn fetchAll(self: *Self) void {
        self.fetchLCX();
        self.fetchKraken();
        self.fetchCoinbase();
        self.last_fetch_ms = std.time.milliTimestamp();

        // Count successful fetches
        self.price_count = 0;
        for (self.prices) |p| {
            if (p.success) self.price_count += 1;
        }
    }

    /// Fetch BTC/USDC from LCX public ticker API
    fn fetchLCX(self: *Self) void {
        // LCX response: {"data":{"bestBid":84000.5,"bestAsk":84001.2,"currentPrice":84000.8,...}}
        const body = httpGet(self.allocator, "https://exchange-api.lcx.com/api/ticker?pair=BTC/USDC") catch {
            self.prices[0].success = false;
            return;
        };
        defer self.allocator.free(body);

        const bid = parseLcxPrice(body, "bestBid");
        const ask = parseLcxPrice(body, "bestAsk");

        if (bid != null or ask != null) {
            const now = std.time.milliTimestamp();
            const bid_val = bid orelse (ask orelse 0);
            const ask_val = ask orelse (bid orelse 0);
            self.prices[0] = .{
                .exchange = "LCX",
                .pair = "BTC/USD",
                .bid_micro_usd = bid_val,
                .ask_micro_usd = ask_val,
                .timestamp_ms = now,
                .success = true,
            };
        } else {
            self.prices[0].success = false;
        }
    }

    /// Fetch BTC/USD from Kraken public ticker API
    fn fetchKraken(self: *Self) void {
        // Kraken response: {"result":{"XXBTZUSD":{"a":["84001.2",...], "b":["84000.5",...], ...}}}
        const body = httpGet(self.allocator, "https://api.kraken.com/0/public/Ticker?pair=XBTUSD") catch {
            self.prices[1].success = false;
            return;
        };
        defer self.allocator.free(body);

        const bid = parseKrakenPrice(body, "\"b\"");
        const ask = parseKrakenPrice(body, "\"a\"");

        if (bid != null or ask != null) {
            const now = std.time.milliTimestamp();
            const bid_val = bid orelse (ask orelse 0);
            const ask_val = ask orelse (bid orelse 0);
            self.prices[1] = .{
                .exchange = "Kraken",
                .pair = "BTC/USD",
                .bid_micro_usd = bid_val,
                .ask_micro_usd = ask_val,
                .timestamp_ms = now,
                .success = true,
            };
        } else {
            self.prices[1].success = false;
        }
    }

    /// Fetch BTC/USD from Coinbase public spot price API
    fn fetchCoinbase(self: *Self) void {
        // Coinbase response: {"data":{"base":"BTC","currency":"USD","amount":"84000.50"}}
        const body = httpGet(self.allocator, "https://api.coinbase.com/v2/prices/BTC-USD/spot") catch {
            self.prices[2].success = false;
            return;
        };
        defer self.allocator.free(body);

        const price = parseCoinbasePrice(body);
        if (price) |p| {
            const now = std.time.milliTimestamp();
            self.prices[2] = .{
                .exchange = "Coinbase",
                .pair = "BTC/USD",
                .bid_micro_usd = p,
                .ask_micro_usd = p,
                .timestamp_ms = now,
                .success = true,
            };
        } else {
            self.prices[2].success = false;
        }
    }

    /// Get median price across all successful fetches, in micro-USD.
    /// Returns null if no exchange returned a valid price.
    pub fn getMedianPrice(self: *const Self) ?u64 {
        var valid: [3]u64 = undefined;
        var count: u8 = 0;
        for (self.prices) |p| {
            if (p.success and p.bid_micro_usd > 0) {
                // Use midpoint of bid/ask
                valid[count] = (p.bid_micro_usd + p.ask_micro_usd) / 2;
                count += 1;
            }
        }

        if (count == 0) return null;
        if (count == 1) return valid[0];

        // Sort ascending
        sortU64(valid[0..count]);

        // Median: middle element or average of two middle
        if (count == 2) return (valid[0] + valid[1]) / 2;
        return valid[count / 2]; // count==3 → valid[1]
    }

    /// Get best bid (highest) across exchanges
    pub fn getBestBid(self: *const Self) ?u64 {
        var best: ?u64 = null;
        for (self.prices) |p| {
            if (p.success and p.bid_micro_usd > 0) {
                if (best == null or p.bid_micro_usd > best.?) {
                    best = p.bid_micro_usd;
                }
            }
        }
        return best;
    }

    /// Get best ask (lowest) across exchanges
    pub fn getBestAsk(self: *const Self) ?u64 {
        var best: ?u64 = null;
        for (self.prices) |p| {
            if (p.success and p.ask_micro_usd > 0) {
                if (best == null or p.ask_micro_usd < best.?) {
                    best = p.ask_micro_usd;
                }
            }
        }
        return best;
    }

    /// Format median price as a human-readable string: "$84,321.45"
    pub fn formatMedianPrice(self: *const Self, buf: []u8) []const u8 {
        const median = self.getMedianPrice() orelse return "N/A";
        const dollars = median / 1_000_000;
        const cents = (median % 1_000_000) / 10_000;
        return std.fmt.bufPrint(buf, "${d}.{d:0>2}", .{ dollars, cents }) catch "ERR";
    }
};

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

/// Parse Coinbase spot price. Format: {"data":{"amount":"84000.50",...}}
pub fn parseCoinbasePrice(body: []const u8) ?u64 {
    const key = "\"amount\":\"";
    const pos = std.mem.indexOf(u8, body, key) orelse return null;
    const val_start = pos + key.len;
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
