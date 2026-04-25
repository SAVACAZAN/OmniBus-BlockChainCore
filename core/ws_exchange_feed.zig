/// ws_exchange_feed.zig — Multi-exchange WebSocket ticker feed manager.
///
/// Spawns 3 worker threads (Coinbase, Kraken, LCX) that each connect to a
/// public market-data WebSocket and push ALL live bid/ask updates into a
/// shared StringHashMap (`PriceMap`) keyed by `"{exchange}|{pair}"`.
///
/// All prices are stored in micro-USD (u64): 1 USD = 1_000_000 micro-USD.
/// Treats USDC as USD for LCX (LCX quotes BTC/USDC and LCX/USDC).
///
/// Each thread runs an infinite reconnect loop with exponential backoff
/// (1s, 2s, 4s, 8s, max 30s) on disconnect, until stop() flips the run flag.
///
/// JSON parsing is intentionally minimal — same indexOf-based approach as
/// core/oracle_fetcher.zig. We never construct a full DOM.
///
/// ── Backward compatibility ────────────────────────────────────────────────
/// The old fixed-6-slot API (`snapshot()`, `getMedianBtc()`, `getMedianLcx()`)
/// is preserved: those methods now look up the 6 canonical key combinations
/// inside `prices` and return them in the same order, so main.zig and
/// rpc_server.zig keep working unchanged.
///
/// ── Anti-OOM circuit breakers ─────────────────────────────────────────────
/// Two caps prevent runaway memory growth from a hostile / buggy upstream:
///   - MAX_PAIRS_PER_EXCHANGE = 2000
///   - MAX_TOTAL_PAIRS        = 5000
/// On hit, the new entry is dropped and a rate-limited warning is logged
/// once per minute per exchange.
const std = @import("std");
const ws_client = @import("ws_client.zig");

const WsClient = ws_client.WsClient;

// ── Public types ─────────────────────────────────────────────────────────────

pub const PriceFetch = struct {
    exchange: []const u8,        // "Coinbase" | "Kraken" | "LCX"
    pair: []const u8,            // canonical pair, exchange-specific format
    bid_micro_usd: u64,
    ask_micro_usd: u64,
    timestamp_ms: i64,
    success: bool,

    /// True if the entry hasn't been refreshed in `threshold_ms` milliseconds.
    /// `now_ms` should be `std.time.milliTimestamp()`. Default threshold: 30s.
    pub fn isStale(p: PriceFetch, now_ms: i64, threshold_ms: i64) bool {
        if (!p.success or p.timestamp_ms == 0) return true;
        return (now_ms - p.timestamp_ms) > threshold_ms;
    }
};

pub const PriceKey = struct {
    exchange: []const u8,
    pair: []const u8,
};

pub const PriceMap = std.StringHashMap(PriceFetch);

/// One canonical "important" pair tracked across all 3 exchanges. The label
/// is the user-facing canonical form ("BTC/USD"); per-exchange fields hold
/// the exchange-specific symbol used to look up that pair in `prices`.
pub const ImportantPair = struct {
    label: []const u8,
    lcx: []const u8,
    kraken: []const u8,
    coinbase: []const u8,
};

/// 7 canonical pairs × 3 exchanges = 21 entries from `getImportantSnapshot`.
pub const IMPORTANT_PAIRS = [_]ImportantPair{
    .{ .label = "BTC/USD",  .lcx = "BTC/USDC",  .kraken = "BTC/USD",  .coinbase = "BTC-USD"  },
    .{ .label = "LCX/USD",  .lcx = "LCX/USDC",  .kraken = "LCX/USD",  .coinbase = "LCX-USD"  },
    .{ .label = "ETH/USD",  .lcx = "ETH/USDC",  .kraken = "ETH/USD",  .coinbase = "ETH-USD"  },
    .{ .label = "SOL/USD",  .lcx = "SOL/USDC",  .kraken = "SOL/USD",  .coinbase = "SOL-USD"  },
    .{ .label = "ADA/USD",  .lcx = "ADA/USDC",  .kraken = "ADA/USD",  .coinbase = "ADA-USD"  },
    .{ .label = "SUI/USD",  .lcx = "SUI/USDC",  .kraken = "SUI/USD",  .coinbase = "SUI-USD"  },
    .{ .label = "EGLD/USD", .lcx = "EGLD/USDC", .kraken = "EGLD/USD", .coinbase = "EGLD-USD" },
};

// ── Constants ────────────────────────────────────────────────────────────────

// Default per-session recv buffer. LCX initial snapshot is one giant frame
// containing every listed pair (~50 pairs × ~600B chart-stripped, but with
// chart history can balloon to 200+ KiB). 512 KiB is comfortable headroom;
// allocator gives back unused pages anyway.
const RECV_BUF_SIZE: usize = 512 * 1024;

const BACKOFF_INITIAL_MS: u64 = 1_000;
const BACKOFF_MAX_MS:     u64 = 30_000;

// LCX-specific application-level keepalive: server expects "ping" text frame
// every <= 60s or it disconnects. We send every 30s to be safe.
const LCX_PING_INTERVAL_MS: i64 = 30_000;

// Anti-OOM circuit breaker caps.
pub const MAX_PAIRS_PER_EXCHANGE: usize = 2000;
pub const MAX_TOTAL_PAIRS:        usize = 5000;

/// Default staleness threshold (30 seconds).
pub const DEFAULT_STALE_THRESHOLD_MS: i64 = 30_000;

// Coinbase REST endpoint listing all spot products.
const COINBASE_PRODUCTS_URL = "https://api.exchange.coinbase.com/products";

// Coinbase Advanced WS limit: subscribe in chunks so we don't blow past the
// per-frame size cap on the server side.
const COINBASE_SUBSCRIBE_CHUNK: usize = 100;

/// Hardcoded fallback list of 30+ Coinbase major USD products. Used if the
/// REST product fetch fails (DNS down, rate-limited, network outage). Covers
/// all IMPORTANT_PAIRS plus the most-traded majors so price discovery still
/// works in degraded mode.
const COINBASE_FALLBACK_PRODUCTS = [_][]const u8{
    "BTC-USD",  "ETH-USD",  "SOL-USD",  "LCX-USD",  "ADA-USD",
    "SUI-USD",  "EGLD-USD", "XRP-USD",  "DOGE-USD", "AVAX-USD",
    "DOT-USD",  "LINK-USD", "MATIC-USD","LTC-USD",  "BCH-USD",
    "UNI-USD",  "ATOM-USD", "XLM-USD",  "ETC-USD",  "ALGO-USD",
    "FIL-USD",  "AAVE-USD", "MKR-USD",  "COMP-USD", "SNX-USD",
    "GRT-USD",  "SAND-USD", "MANA-USD", "APE-USD",  "SHIB-USD",
    "CRV-USD",  "NEAR-USD", "OP-USD",   "ARB-USD",  "INJ-USD",
};

// ── ExchangeFeed ─────────────────────────────────────────────────────────────

pub const ExchangeFeed = struct {
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex,

    /// Unbounded price map. Keys are `"{exchange}|{pair}"`, owned by feed
    /// allocator (duped on first insertion of each key).
    prices: PriceMap,

    /// Per-exchange entry counters (used by circuit breakers).
    coinbase_count: usize,
    kraken_count: usize,
    lcx_count: usize,

    /// Last circuit-breaker warning timestamp per exchange (rate-limit log).
    last_cb_warn_coinbase_ms: i64,
    last_cb_warn_kraken_ms: i64,
    last_cb_warn_lcx_ms: i64,

    /// Atomic flag — workers exit their reconnect loops when this goes false.
    run: std.atomic.Value(bool),

    threads: [3]?std.Thread,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .mutex = .{},
            .prices = PriceMap.init(allocator),
            .coinbase_count = 0,
            .kraken_count = 0,
            .lcx_count = 0,
            .last_cb_warn_coinbase_ms = 0,
            .last_cb_warn_kraken_ms = 0,
            .last_cb_warn_lcx_ms = 0,
            .run = std.atomic.Value(bool).init(false),
            .threads = .{ null, null, null },
        };
    }

    /// Tear down the map: free every duped key, free every duped pair string,
    /// then deinit the hashmap. Safe to call multiple times.
    pub fn deinit(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        var it = self.prices.iterator();
        while (it.next()) |entry| {
            // Free the duped composite key.
            self.allocator.free(entry.key_ptr.*);
            // Free the duped pair string (exchange string is a static literal).
            self.allocator.free(entry.value_ptr.pair);
        }
        self.prices.deinit();
        self.coinbase_count = 0;
        self.kraken_count = 0;
        self.lcx_count = 0;
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
    /// Does NOT free the price map — call deinit() for that.
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

    // ── New unbounded API ──────────────────────────────────────────────────

    /// Total number of (exchange, pair) entries currently tracked.
    pub fn count(self: *Self) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.prices.count();
    }

    /// Look up a single price entry by (exchange, pair). Returns null if not
    /// yet seen. Returned slices belong to the feed — copy if you need to
    /// retain them past the next stop()/deinit().
    pub fn getPrice(self: *Self, exchange: []const u8, pair: []const u8) ?PriceFetch {
        var key_buf: [128]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "{s}|{s}", .{ exchange, pair }) catch return null;
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.prices.get(key);
    }

    /// Snapshot all entries in the map. Caller owns the returned slice and
    /// must free it with the supplied allocator. The PriceFetch values still
    /// hold borrowed slices (exchange/pair) — valid until feed.deinit().
    pub fn getAllPrices(self: *Self, alloc: std.mem.Allocator) ![]PriceFetch {
        self.mutex.lock();
        defer self.mutex.unlock();
        var out = try alloc.alloc(PriceFetch, self.prices.count());
        var it = self.prices.iterator();
        var i: usize = 0;
        while (it.next()) |entry| : (i += 1) {
            out[i] = entry.value_ptr.*;
        }
        return out;
    }

    /// Per-block snapshot covering the 7 IMPORTANT_PAIRS × 3 exchanges, in
    /// canonical order. Missing entries appear as zeroed PriceFetch with
    /// `success=false`. Used by main.zig recordBlockPrices.
    pub fn getImportantSnapshot(self: *Self) [21]PriceFetch {
        self.mutex.lock();
        defer self.mutex.unlock();

        var out: [21]PriceFetch = undefined;
        var idx: usize = 0;
        for (IMPORTANT_PAIRS) |ip| {
            out[idx] = self.lookupOrEmpty("Coinbase", ip.coinbase, ip.label);
            idx += 1;
            out[idx] = self.lookupOrEmpty("Kraken", ip.kraken, ip.label);
            idx += 1;
            out[idx] = self.lookupOrEmpty("LCX", ip.lcx, ip.label);
            idx += 1;
        }
        return out;
    }

    // ── Backward-compatible 6-slot API ─────────────────────────────────────

    /// Return a snapshot of the canonical 6 slots (BTC × 3 + LCX × 3).
    /// Slot layout matches the historical ordering used by rpc_server.zig
    /// and main.zig recordBlockPrices.
    pub fn snapshot(self: *Self) [6]PriceFetch {
        self.mutex.lock();
        defer self.mutex.unlock();
        return [6]PriceFetch{
            self.lookupOrEmpty("Coinbase", "BTC-USD",  "BTC/USD"),
            self.lookupOrEmpty("Kraken",   "BTC/USD",  "BTC/USD"),
            self.lookupOrEmpty("LCX",      "BTC/USDC", "BTC/USD"),
            self.lookupOrEmpty("Coinbase", "LCX-USD",  "LCX/USD"),
            self.lookupOrEmpty("Kraken",   "LCX/USD",  "LCX/USD"),
            self.lookupOrEmpty("LCX",      "LCX/USDC", "LCX/USD"),
        };
    }

    /// Median BTC mid-price across the 3 BTC slots. Null if all stale/failed.
    pub fn getMedianBtc(self: *Self) ?u64 {
        const snap = self.snapshot();
        return medianFor(snap[0..3]);
    }

    /// Median LCX mid-price across the 3 LCX slots. Null if none valid.
    pub fn getMedianLcx(self: *Self) ?u64 {
        const snap = self.snapshot();
        return medianFor(snap[3..6]);
    }

    // ── Internal: shared write helpers ─────────────────────────────────────

    /// Internal lookup — caller must hold mutex. Returns the entry if present,
    /// else a zeroed placeholder with the requested exchange/pair labels.
    fn lookupOrEmpty(self: *Self, exchange: []const u8, pair: []const u8, fallback_label: []const u8) PriceFetch {
        var key_buf: [128]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "{s}|{s}", .{ exchange, pair }) catch {
            return .{
                .exchange = exchange, .pair = fallback_label,
                .bid_micro_usd = 0, .ask_micro_usd = 0,
                .timestamp_ms = 0, .success = false,
            };
        };
        if (self.prices.get(key)) |p| {
            // Override the pair field with the canonical label so legacy
            // consumers (which expect "BTC/USD" not "BTC/USDC") see what
            // they always saw.
            return .{
                .exchange = p.exchange,
                .pair = fallback_label,
                .bid_micro_usd = p.bid_micro_usd,
                .ask_micro_usd = p.ask_micro_usd,
                .timestamp_ms = p.timestamp_ms,
                .success = p.success,
            };
        }
        return .{
            .exchange = exchange, .pair = fallback_label,
            .bid_micro_usd = 0, .ask_micro_usd = 0,
            .timestamp_ms = 0, .success = false,
        };
    }

    /// Insert or update a (exchange, pair) entry. `exchange` MUST be one of
    /// the static string literals "Coinbase" / "Kraken" / "LCX" so we don't
    /// have to dupe it. `pair` is duped on first insertion. Circuit breakers
    /// drop the entry (and rate-limit-log) if caps would be exceeded.
    fn upsertPrice(self: *Self, exchange: []const u8, pair: []const u8, bid: u64, ask: u64) void {
        // Compose the composite key on the stack first.
        var key_buf: [128]u8 = undefined;
        const composed = std.fmt.bufPrint(&key_buf, "{s}|{s}", .{ exchange, pair }) catch return;

        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.prices.getPtr(composed)) |existing| {
            // Update in place — no allocation, no counter change.
            existing.bid_micro_usd = bid;
            existing.ask_micro_usd = ask;
            existing.timestamp_ms  = std.time.milliTimestamp();
            existing.success       = true;
            return;
        }

        // New key — check circuit breakers.
        const total_now = self.prices.count();
        const ex_count = self.exchangeCountPtr(exchange);
        if (ex_count.* >= MAX_PAIRS_PER_EXCHANGE) {
            self.warnCircuitBreaker(exchange, pair, MAX_PAIRS_PER_EXCHANGE, true);
            return;
        }
        if (total_now >= MAX_TOTAL_PAIRS) {
            self.warnCircuitBreaker(exchange, pair, MAX_TOTAL_PAIRS, false);
            return;
        }

        // Dupe key + pair string so they outlive the stack buffer.
        const owned_key = self.allocator.dupe(u8, composed) catch return;
        const owned_pair = self.allocator.dupe(u8, pair) catch {
            self.allocator.free(owned_key);
            return;
        };

        const fetch: PriceFetch = .{
            .exchange = exchange, // static literal, no dupe needed
            .pair = owned_pair,
            .bid_micro_usd = bid,
            .ask_micro_usd = ask,
            .timestamp_ms = std.time.milliTimestamp(),
            .success = true,
        };
        self.prices.put(owned_key, fetch) catch {
            self.allocator.free(owned_key);
            self.allocator.free(owned_pair);
            return;
        };
        ex_count.* += 1;
    }

    fn exchangeCountPtr(self: *Self, exchange: []const u8) *usize {
        if (std.mem.eql(u8, exchange, "Coinbase")) return &self.coinbase_count;
        if (std.mem.eql(u8, exchange, "Kraken"))   return &self.kraken_count;
        return &self.lcx_count;
    }

    fn lastWarnPtr(self: *Self, exchange: []const u8) *i64 {
        if (std.mem.eql(u8, exchange, "Coinbase")) return &self.last_cb_warn_coinbase_ms;
        if (std.mem.eql(u8, exchange, "Kraken"))   return &self.last_cb_warn_kraken_ms;
        return &self.last_cb_warn_lcx_ms;
    }

    /// Rate-limited circuit-breaker warning: at most one log per exchange per
    /// minute. `per_exchange` flag distinguishes the two cap types in the log.
    fn warnCircuitBreaker(self: *Self, exchange: []const u8, pair: []const u8, cap: usize, per_exchange: bool) void {
        const now_ms = std.time.milliTimestamp();
        const last = self.lastWarnPtr(exchange);
        if (now_ms - last.* < 60_000) return;
        last.* = now_ms;
        const scope = if (per_exchange) "per-exchange" else "global";
        std.debug.print("[WS-FEED] circuit breaker: dropping {s}|{s} ({s} cap {d})\n",
            .{ exchange, pair, scope, cap });
    }

    /// Mark every entry from a given exchange as failed. Used on disconnect
    /// so consumers can see staleness immediately rather than after timeout.
    fn markExchangeFailed(self: *Self, exchange: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        var it = self.prices.iterator();
        while (it.next()) |entry| {
            if (std.mem.eql(u8, entry.value_ptr.exchange, exchange)) {
                entry.value_ptr.success = false;
            }
        }
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
        feed.markExchangeFailed("Coinbase");
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

    // ── Subscribe ONLY to the 7 IMPORTANT_PAIRS ────────────────────────────
    // Earlier full-market mode (~700 products) crashed the small-RAM VPS.
    // We now stay focused on the 7 pairs the arbitrage panel cares about.
    var product_buf: [IMPORTANT_PAIRS.len][]const u8 = undefined;
    for (IMPORTANT_PAIRS, 0..) |p, i| product_buf[i] = p.coinbase;
    try sendCoinbaseSubscribeStatic(client, feed.allocator, product_buf[0..]);

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

/// Send Coinbase subscribe frames, chunking product_ids to avoid frame size
/// limits. `products` slice elements are owned strings.
fn sendCoinbaseSubscribe(client: *WsClient, alloc: std.mem.Allocator, products: []const []const u8) !void {
    var i: usize = 0;
    while (i < products.len) : (i += COINBASE_SUBSCRIBE_CHUNK) {
        const end = @min(i + COINBASE_SUBSCRIBE_CHUNK, products.len);
        try sendOneCoinbaseChunk(client, alloc, products[i..end]);
    }
}

/// Same as sendCoinbaseSubscribe but for a static [_][]const u8 array.
fn sendCoinbaseSubscribeStatic(client: *WsClient, alloc: std.mem.Allocator, products: []const []const u8) !void {
    try sendCoinbaseSubscribe(client, alloc, products);
}

fn sendOneCoinbaseChunk(client: *WsClient, alloc: std.mem.Allocator, products: []const []const u8) !void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, "{\"type\":\"subscribe\",\"product_ids\":[");
    for (products, 0..) |p, idx| {
        if (idx > 0) try buf.append(alloc, ',');
        try buf.append(alloc, '"');
        try buf.appendSlice(alloc, p);
        try buf.append(alloc, '"');
    }
    try buf.appendSlice(alloc, "],\"channel\":\"ticker\"}");
    try client.send(buf.items);
}

/// One-shot HTTPS GET to https://api.exchange.coinbase.com/products. Returns
/// a slice of owned product-id strings ("BTC-USD", "ETH-USD", ...). Caller
/// must free each string AND the outer slice.
fn fetchCoinbaseProducts(alloc: std.mem.Allocator) ![][]const u8 {
    var client = std.http.Client{ .allocator = alloc };
    defer client.deinit();

    var wa = std.Io.Writer.Allocating.init(alloc);
    defer wa.deinit();

    const result = try client.fetch(.{
        .location = .{ .url = COINBASE_PRODUCTS_URL },
        .response_writer = &wa.writer,
        .keep_alive = false,
    });
    const status: u16 = @intCast(@intFromEnum(result.status));
    if (status != 200) return error.HttpError;

    const body = wa.written();

    // Body is a JSON array of objects: [{"id":"BTC-USD",...},{"id":"ETH-USD",...}]
    // Walk it with simple indexOf — same minimalist style as the WS parsers.
    var ids: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (ids.items) |s| alloc.free(s);
        ids.deinit(alloc);
    }

    const needle = "\"id\":\"";
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, body, pos, needle)) |found| {
        const v_start = found + needle.len;
        const v_end = std.mem.indexOfPos(u8, body, v_start, "\"") orelse break;
        if (v_end > v_start) {
            const id = try alloc.dupe(u8, body[v_start..v_end]);
            try ids.append(alloc, id);
        }
        pos = v_end + 1;
    }
    if (ids.items.len == 0) return error.NoProductsFound;
    return try ids.toOwnedSlice(alloc);
}

/// Coinbase Advanced ticker payload format (relevant fields only):
///   {"channel":"ticker","events":[{"type":"...","tickers":[
///       {"product_id":"BTC-USD","best_bid":"32705.30","best_ask":"32762.60", ...},
///       {"product_id":"ETH-USD","best_bid":"3200.10","best_ask":"3201.40", ...},
///       ... potentially hundreds of products in one frame
///   ]}], ...}
///
/// We walk every `"product_id":"<value>"` occurrence, and for each one parse
/// best_bid / best_ask in the immediately following window. No pre-filtering.
fn parseCoinbaseTicker(feed: *ExchangeFeed, body: []const u8) void {
    const needle = "\"product_id\":\"";
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, body, pos, needle)) |found| {
        const id_start = found + needle.len;
        const id_end = std.mem.indexOfPos(u8, body, id_start, "\"") orelse break;
        if (id_end <= id_start) {
            pos = id_start;
            continue;
        }
        const product_id = body[id_start..id_end];

        // Strict whitelist — only the 7 important pairs reach the price map.
        // Server should already only send these (we subscribed to them only),
        // but defensive in case of stray "subscriptions" ack frames or future
        // additions to the IMPORTANT_PAIRS list.
        if (!isCoinbaseImportant(product_id)) {
            pos = id_end + 1;
            continue;
        }

        // Bound the search window to the next ~1 KiB so we don't accidentally
        // grab the next ticker's bid/ask.
        const win_end = @min(body.len, id_end + 1024);
        const window = body[id_end..win_end];

        const bid = parseQuotedPrice(window, "\"best_bid\":\"");
        const ask = parseQuotedPrice(window, "\"best_ask\":\"");

        if (bid != null or ask != null) {
            const bid_v = bid orelse (ask orelse 0);
            const ask_v = ask orelse (bid orelse 0);
            feed.upsertPrice("Coinbase", product_id, bid_v, ask_v);
        }
        pos = id_end + 1;
    }
}

// ── Kraken worker ────────────────────────────────────────────────────────────

fn krakenWorker(feed: *ExchangeFeed) void {
    var backoff: u64 = BACKOFF_INITIAL_MS;
    while (feed.run.load(.acquire)) {
        runKrakenSession(feed) catch {};
        feed.markExchangeFailed("Kraken");
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

    // Subscribe ONLY to the 7 IMPORTANT_PAIRS (was wildcard "*" before, but
    // ~600 Kraken pairs flooded the VPS RAM).
    var sym_list: std.ArrayList(u8) = .empty;
    defer sym_list.deinit(feed.allocator);
    try sym_list.appendSlice(feed.allocator,
        "{\"method\":\"subscribe\",\"params\":{\"channel\":\"ticker\",\"symbol\":[");
    for (IMPORTANT_PAIRS, 0..) |p, i| {
        if (i > 0) try sym_list.append(feed.allocator, ',');
        try sym_list.append(feed.allocator, '"');
        try sym_list.appendSlice(feed.allocator, p.kraken);
        try sym_list.append(feed.allocator, '"');
    }
    try sym_list.appendSlice(feed.allocator, "]}}");
    try client.send(sym_list.items);

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
///    "data":[{"symbol":"BTC/USD","bid":65234.1,"ask":65235.0, ...},
///            {"symbol":"ETH/USD","bid":3200.1, "ask":3201.0, ...}]}
///
/// We walk every `"symbol":"<value>"` and parse the bid/ask in its window.
/// Status / heartbeat messages are ignored via the cheap channel filter.
fn parseKrakenMessage(feed: *ExchangeFeed, body: []const u8) void {
    if (std.mem.indexOf(u8, body, "\"channel\":\"ticker\"") == null) return;

    const needle = "\"symbol\":\"";
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, body, pos, needle)) |found| {
        const s_start = found + needle.len;
        const s_end = std.mem.indexOfPos(u8, body, s_start, "\"") orelse break;
        if (s_end <= s_start) {
            pos = s_start;
            continue;
        }
        const symbol = body[s_start..s_end];

        // Strict whitelist — same defensive filter as Coinbase parser.
        // Avoids accidentally accepting BTCB/USD, WETH/USD etc. if Kraken
        // ever expands what they push under the same connection.
        if (!isKrakenImportant(symbol)) {
            pos = s_end + 1;
            continue;
        }

        const win_end = @min(body.len, s_end + 512);
        const window = body[s_end..win_end];

        // Kraken v2 emits raw numeric values, not strings.
        const bid = parseUnquotedPrice(window, "\"bid\":");
        const ask = parseUnquotedPrice(window, "\"ask\":");

        if (bid != null or ask != null) {
            const bid_v = bid orelse (ask orelse 0);
            const ask_v = ask orelse (bid orelse 0);
            feed.upsertPrice("Kraken", symbol, bid_v, ask_v);
        }
        pos = s_end + 1;
    }
}

// ── LCX worker ───────────────────────────────────────────────────────────────

fn lcxWorker(feed: *ExchangeFeed) void {
    var backoff: u64 = BACKOFF_INITIAL_MS;
    while (feed.run.load(.acquire)) {
        runLcxSession(feed) catch {};
        feed.markExchangeFailed("LCX");
        backoff = sleepBackoff(feed, backoff);
    }
}

fn runLcxSession(feed: *ExchangeFeed) !void {
    // Confirmed via direct python websockets test against the live server:
    // - "/" returns HTTP 200 (no WS upgrade) → handshake fails.
    // - "/ws" accepts upgrade AND streams ticker snapshots/updates.
    var client = try WsClient.connect(
        feed.allocator,
        "exchange-api.lcx.com",
        443,
        "/ws",
        true,
    );
    defer client.close();

    // Public ticker subscribe is brand-less; one snapshot frame contains
    // ALL pairs as a JSON object: {"data":{"BTC/USDC":{...},"LCX/USDC":{...}}}
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

/// LCX ticker frame format (verified via live test):
///   {"type":"ticker","topic":"snapshot","pair":"","data":{
///     "1INCH/EUR":{"bestBid":..,"bestAsk":..,...},
///     "BTC/USDC":{"bestBid":..,"bestAsk":..,...},
///     "LCX/USDC":{"bestBid":..,"bestAsk":..,...},
///     ... ALL pairs in one frame
///   }}
///
/// We walk EVERY top-level key of `data` (not just BTC/LCX). Each key is a
/// pair name; its sub-object holds bestBid/bestAsk we parse with the existing
/// helpers. Brace-balancing isolates each sub-object so neighbours don't bleed.
/// True if `key` (LCX pair string from a snapshot frame) matches one of the
/// 7 IMPORTANT_PAIRS in their LCX form. Strict equality — no substring
/// matching — to avoid confusing similar-looking tickers (e.g. "BTCB/USDC"
/// (Binance Wrapped BTC) vs "BTC/USDC" or "WETH/USDC" vs "ETH/USDC").
fn isLcxImportant(key: []const u8) bool {
    inline for (IMPORTANT_PAIRS) |p| {
        if (std.mem.eql(u8, key, p.lcx)) return true;
    }
    return false;
}

/// Same as isLcxImportant but for Coinbase Advanced product_id format
/// ("BTC-USD", "ETH-USD", ...). Strict equality to skip "BTCB-USD",
/// "WETH-USD", "JSOL-USD" and friends that share a prefix.
fn isCoinbaseImportant(product_id: []const u8) bool {
    inline for (IMPORTANT_PAIRS) |p| {
        if (std.mem.eql(u8, product_id, p.coinbase)) return true;
    }
    return false;
}

/// Same for Kraken v2 symbol format ("BTC/USD", "ETH/USD", ...).
fn isKrakenImportant(symbol: []const u8) bool {
    inline for (IMPORTANT_PAIRS) |p| {
        if (std.mem.eql(u8, symbol, p.kraken)) return true;
    }
    return false;
}

fn parseLcxMessage(feed: *ExchangeFeed, body: []const u8) void {
    // Locate the start of the data object: `"data":{`. Everything we want
    // lives inside its braces.
    const data_marker = "\"data\":{";
    const data_pos = std.mem.indexOf(u8, body, data_marker) orelse return;
    const data_open = data_pos + data_marker.len; // points just AFTER outer `{`

    // Walk the object: at depth 1 a `"<key>":{` introduces a per-pair
    // sub-object; brace-balance to find its matching `}`, then parse.
    var i: usize = data_open;
    var in_string: bool = false;
    var escape: bool = false;
    while (i < body.len) : (i += 1) {
        const c = body[i];
        if (in_string) {
            if (escape) { escape = false; }
            else if (c == '\\') { escape = true; }
            else if (c == '"') { in_string = false; }
            continue;
        }
        if (c == '}') return; // closing the data object → done
        if (c == '"') {
            // Start of a key. Read until closing quote.
            const key_start = i + 1;
            var j = key_start;
            var k_escape = false;
            while (j < body.len) : (j += 1) {
                const kc = body[j];
                if (k_escape) { k_escape = false; continue; }
                if (kc == '\\') { k_escape = true; continue; }
                if (kc == '"') break;
            }
            if (j >= body.len) return;
            const key = body[key_start..j];
            // Expect `":` then `{` (skipping whitespace). If anything else,
            // skip and continue scanning at j+1.
            var p = j + 1;
            while (p < body.len and (body[p] == ' ' or body[p] == '\t')) : (p += 1) {}
            if (p >= body.len or body[p] != ':') { i = j; continue; }
            p += 1;
            while (p < body.len and (body[p] == ' ' or body[p] == '\t')) : (p += 1) {}
            if (p >= body.len) return;
            if (body[p] != '{') {
                // Value is not an object — skip past it (could be string,
                // number, etc.). Advance to next comma at depth 0.
                i = p;
                while (i < body.len and body[i] != ',' and body[i] != '}') : (i += 1) {}
                continue;
            }
            // Brace-balance the sub-object.
            const obj_open = p + 1;
            var depth: i32 = 1;
            var sub_in_string = false;
            var sub_escape = false;
            var q: usize = obj_open;
            while (q < body.len) : (q += 1) {
                const sc = body[q];
                if (sub_in_string) {
                    if (sub_escape) { sub_escape = false; }
                    else if (sc == '\\') { sub_escape = true; }
                    else if (sc == '"') { sub_in_string = false; }
                } else {
                    if (sc == '"') { sub_in_string = true; }
                    else if (sc == '{') { depth += 1; }
                    else if (sc == '}') { depth -= 1; if (depth == 0) { q += 1; break; } }
                }
            }
            // Filter: keep ONLY the 7 IMPORTANT_PAIRS (LCX symbol field).
            // LCX subscribe always streams ALL pairs (one snapshot frame
            // contains 50+ markets). Storing them all crashed the small
            // VPS, so we discard non-important keys here.
            if (!isLcxImportant(key)) {
                i = q - 1;
                continue;
            }
            const window = body[p..q];
            parseLcxPairWindow(feed, key, window);
            i = q - 1; // for-loop will i+=1
            continue;
        }
    }
}

/// Parse bid/ask from a single pair's sub-object window, then upsert.
fn parseLcxPairWindow(feed: *ExchangeFeed, pair: []const u8, window: []const u8) void {
    const unquoted_pairs = [_]struct { bk: []const u8, ak: []const u8 }{
        .{ .bk = "\"bestBid\":", .ak = "\"bestAsk\":" },
        .{ .bk = "\"bid\":",     .ak = "\"ask\":" },
    };
    const quoted_pairs = [_]struct { bk: []const u8, ak: []const u8 }{
        .{ .bk = "\"bestBid\":\"", .ak = "\"bestAsk\":\"" },
        .{ .bk = "\"bid\":\"",     .ak = "\"ask\":\"" },
    };

    var bid: ?u64 = null;
    var ask: ?u64 = null;
    for (unquoted_pairs) |p| {
        if (bid == null) bid = parseUnquotedPrice(window, p.bk);
        if (ask == null) ask = parseUnquotedPrice(window, p.ak);
        if (bid != null and ask != null) break;
    }
    for (quoted_pairs) |p| {
        if (bid == null) bid = parseQuotedPrice(window, p.bk);
        if (ask == null) ask = parseQuotedPrice(window, p.ak);
        if (bid != null and ask != null) break;
    }

    if (bid != null or ask != null) {
        const bid_v = bid orelse (ask orelse 0);
        const ask_v = ask orelse (bid orelse 0);
        feed.upsertPrice("LCX", pair, bid_v, ask_v);
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
    var n: u8 = 0;
    for (slice) |p| {
        if (p.success and p.bid_micro_usd > 0) {
            valid[n] = (p.bid_micro_usd + p.ask_micro_usd) / 2;
            n += 1;
            if (n == 3) break;
        }
    }
    if (n == 0) return null;
    if (n == 1) return valid[0];
    sortU64(valid[0..n]);
    if (n == 2) return (valid[0] + valid[1]) / 2;
    return valid[n / 2];
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
// Tests — JSON parsing + map logic only (no live WS connections)
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

test "ExchangeFeed — init starts empty, snapshot returns 6 placeholders" {
    var feed = ExchangeFeed.init(std.testing.allocator);
    defer feed.deinit();
    try std.testing.expectEqual(@as(usize, 0), feed.count());
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

test "ExchangeFeed — upsertPrice writes through mutex" {
    var feed = ExchangeFeed.init(std.testing.allocator);
    defer feed.deinit();
    feed.upsertPrice("Kraken", "BTC/USD", 65_000_000_000, 65_010_000_000);
    const snap = feed.snapshot();
    try std.testing.expect(snap[1].success); // SLOT_BTC_KRAKEN
    try std.testing.expectEqual(@as(u64, 65_000_000_000), snap[1].bid_micro_usd);
    try std.testing.expectEqual(@as(u64, 65_010_000_000), snap[1].ask_micro_usd);
    try std.testing.expect(snap[1].timestamp_ms > 0);
}

test "ExchangeFeed — markExchangeFailed clears success flag" {
    var feed = ExchangeFeed.init(std.testing.allocator);
    defer feed.deinit();
    feed.upsertPrice("LCX", "LCX/USDC", 50_000, 51_000);
    feed.markExchangeFailed("LCX");
    const snap = feed.snapshot();
    try std.testing.expect(!snap[5].success); // SLOT_LCX_LCX
}

test "ExchangeFeed — getMedianBtc with 3 slots" {
    var feed = ExchangeFeed.init(std.testing.allocator);
    defer feed.deinit();
    feed.upsertPrice("Coinbase", "BTC-USD",  84_000_000_000, 84_100_000_000); // mid 84_050
    feed.upsertPrice("Kraken",   "BTC/USD",  84_200_000_000, 84_300_000_000); // mid 84_250
    feed.upsertPrice("LCX",      "BTC/USDC", 84_100_000_000, 84_100_000_000); // mid 84_100
    const median = feed.getMedianBtc();
    try std.testing.expect(median != null);
    try std.testing.expectEqual(@as(u64, 84_100_000_000), median.?);
}

test "ExchangeFeed — getMedianBtc with 2 slots is average" {
    var feed = ExchangeFeed.init(std.testing.allocator);
    defer feed.deinit();
    feed.upsertPrice("Coinbase", "BTC-USD", 84_000_000_000, 84_000_000_000);
    feed.upsertPrice("Kraken",   "BTC/USD", 84_200_000_000, 84_200_000_000);
    const median = feed.getMedianBtc();
    try std.testing.expect(median != null);
    try std.testing.expectEqual(@as(u64, 84_100_000_000), median.?);
}

test "ExchangeFeed — getMedianBtc returns null when empty" {
    var feed = ExchangeFeed.init(std.testing.allocator);
    defer feed.deinit();
    try std.testing.expectEqual(@as(?u64, null), feed.getMedianBtc());
    try std.testing.expectEqual(@as(?u64, null), feed.getMedianLcx());
}

test "ExchangeFeed — getMedianLcx independent of BTC slots" {
    var feed = ExchangeFeed.init(std.testing.allocator);
    defer feed.deinit();
    feed.upsertPrice("Coinbase", "BTC-USD", 84_000_000_000, 84_000_000_000);
    feed.upsertPrice("LCX", "LCX/USDC", 50_000, 60_000); // mid 55_000
    try std.testing.expectEqual(@as(?u64, 55_000), feed.getMedianLcx());
    try std.testing.expectEqual(@as(?u64, 84_000_000_000), feed.getMedianBtc());
}

test "ExchangeFeed — getPrice + getAllPrices" {
    var feed = ExchangeFeed.init(std.testing.allocator);
    defer feed.deinit();
    feed.upsertPrice("Coinbase", "ETH-USD", 3_200_100_000, 3_201_400_000);
    feed.upsertPrice("Kraken",   "SOL/USD",   145_500_000, 145_700_000);

    const eth = feed.getPrice("Coinbase", "ETH-USD");
    try std.testing.expect(eth != null);
    try std.testing.expectEqual(@as(u64, 3_200_100_000), eth.?.bid_micro_usd);

    try std.testing.expectEqual(@as(usize, 2), feed.count());
    const all = try feed.getAllPrices(std.testing.allocator);
    defer std.testing.allocator.free(all);
    try std.testing.expectEqual(@as(usize, 2), all.len);
}

test "PriceFetch.isStale" {
    const now: i64 = 1_000_000;
    const fresh = PriceFetch{ .exchange = "Coinbase", .pair = "BTC-USD",
        .bid_micro_usd = 1, .ask_micro_usd = 1, .timestamp_ms = now - 5_000, .success = true };
    const stale = PriceFetch{ .exchange = "Coinbase", .pair = "BTC-USD",
        .bid_micro_usd = 1, .ask_micro_usd = 1, .timestamp_ms = now - 60_000, .success = true };
    const failed = PriceFetch{ .exchange = "Coinbase", .pair = "BTC-USD",
        .bid_micro_usd = 1, .ask_micro_usd = 1, .timestamp_ms = now - 1_000, .success = false };
    try std.testing.expect(!fresh.isStale(now, DEFAULT_STALE_THRESHOLD_MS));
    try std.testing.expect(stale.isStale(now, DEFAULT_STALE_THRESHOLD_MS));
    try std.testing.expect(failed.isStale(now, DEFAULT_STALE_THRESHOLD_MS));
}

test "ExchangeFeed — getImportantSnapshot returns 21 entries in canonical order" {
    var feed = ExchangeFeed.init(std.testing.allocator);
    defer feed.deinit();
    feed.upsertPrice("Coinbase", "BTC-USD", 84_000_000_000, 84_100_000_000);
    feed.upsertPrice("Kraken",   "ETH/USD",  3_200_000_000,  3_201_000_000);
    feed.upsertPrice("LCX",      "SOL/USDC",   145_000_000,    146_000_000);

    const snap = feed.getImportantSnapshot();
    try std.testing.expectEqual(@as(usize, 21), snap.len);

    // Layout: 7 pairs × {Coinbase, Kraken, LCX}.
    // BTC/USD Coinbase = idx 0
    try std.testing.expect(snap[0].success);
    try std.testing.expectEqualStrings("Coinbase", snap[0].exchange);
    try std.testing.expectEqualStrings("BTC/USD", snap[0].pair);
    try std.testing.expectEqual(@as(u64, 84_000_000_000), snap[0].bid_micro_usd);

    // ETH/USD = pair index 2 → base 6. Kraken = +1 = idx 7
    try std.testing.expect(snap[7].success);
    try std.testing.expectEqualStrings("Kraken", snap[7].exchange);

    // SOL/USD = pair index 3 → base 9. LCX = +2 = idx 11
    try std.testing.expect(snap[11].success);
    try std.testing.expectEqualStrings("LCX", snap[11].exchange);

    // EGLD/USD all 3 unset
    try std.testing.expect(!snap[18].success);
    try std.testing.expect(!snap[19].success);
    try std.testing.expect(!snap[20].success);
}

test "Coinbase ticker parse — both products in one frame, no pre-filter" {
    var feed = ExchangeFeed.init(std.testing.allocator);
    defer feed.deinit();
    const frame =
        \\{"channel":"ticker","events":[{"type":"snapshot","tickers":[
        \\{"product_id":"BTC-USD","best_bid":"32705.30","best_ask":"32762.60","price":"32733.00"},
        \\{"product_id":"LCX-USD","best_bid":"0.054320","best_ask":"0.054440","price":"0.05438"},
        \\{"product_id":"ETH-USD","best_bid":"3200.10","best_ask":"3201.40","price":"3200.50"}
        \\]}]}
    ;
    parseCoinbaseTicker(&feed, frame);
    try std.testing.expectEqual(@as(usize, 3), feed.count());

    const btc = feed.getPrice("Coinbase", "BTC-USD").?;
    try std.testing.expectEqual(@as(u64, 32_705_300_000), btc.bid_micro_usd);
    const lcx = feed.getPrice("Coinbase", "LCX-USD").?;
    try std.testing.expectEqual(@as(u64, 54_320), lcx.bid_micro_usd);
    const eth = feed.getPrice("Coinbase", "ETH-USD").?;
    try std.testing.expectEqual(@as(u64, 3_200_100_000), eth.bid_micro_usd);
}

test "Kraken ticker parse — multiple symbols, no pre-filter" {
    var feed = ExchangeFeed.init(std.testing.allocator);
    defer feed.deinit();
    const frame =
        \\{"channel":"ticker","type":"update","data":[
        \\{"symbol":"BTC/USD","bid":65234.1,"ask":65235.0,"last":65234.5},
        \\{"symbol":"ETH/USD","bid":3200.1,"ask":3201.0,"last":3200.5},
        \\{"symbol":"DOGE/USD","bid":0.075,"ask":0.076,"last":0.0755}]}
    ;
    parseKrakenMessage(&feed, frame);
    try std.testing.expectEqual(@as(usize, 3), feed.count());

    const btc = feed.getPrice("Kraken", "BTC/USD").?;
    try std.testing.expectEqual(@as(u64, 65_234_100_000), btc.bid_micro_usd);
    const doge = feed.getPrice("Kraken", "DOGE/USD").?;
    try std.testing.expectEqual(@as(u64, 75_000), doge.bid_micro_usd);
}

test "Kraken parser ignores heartbeat / status frames" {
    var feed = ExchangeFeed.init(std.testing.allocator);
    defer feed.deinit();
    parseKrakenMessage(&feed, "{\"channel\":\"heartbeat\"}");
    parseKrakenMessage(&feed, "{\"channel\":\"status\",\"data\":[{\"system\":\"online\"}]}");
    try std.testing.expectEqual(@as(usize, 0), feed.count());
}

test "LCX ticker parse — walks all keys in data object" {
    var feed = ExchangeFeed.init(std.testing.allocator);
    defer feed.deinit();
    const frame =
        \\{"type":"ticker","topic":"snapshot","pair":"","data":{
        \\"BTC/USDC":{"bestBid":65234.5,"bestAsk":65236.7,"lastPrice":65235.6},
        \\"LCX/USDC":{"bestBid":0.054321,"bestAsk":0.054440},
        \\"ETH/USDC":{"bestBid":3200.10,"bestAsk":3201.40}}}
    ;
    parseLcxMessage(&feed, frame);
    try std.testing.expectEqual(@as(usize, 3), feed.count());

    const btc = feed.getPrice("LCX", "BTC/USDC").?;
    try std.testing.expectEqual(@as(u64, 65_234_500_000), btc.bid_micro_usd);
    const lcx = feed.getPrice("LCX", "LCX/USDC").?;
    try std.testing.expectEqual(@as(u64, 54_321), lcx.bid_micro_usd);
    const eth = feed.getPrice("LCX", "ETH/USDC").?;
    try std.testing.expectEqual(@as(u64, 3_200_100_000), eth.bid_micro_usd);
}

test "LCX parser - single update frame still works" {
    var feed = ExchangeFeed.init(std.testing.allocator);
    defer feed.deinit();
    const frame =
        \\{"data":{"BTC/USDC":{"bestBid":65234.5,"bestAsk":65236.7}}}
    ;
    parseLcxMessage(&feed, frame);
    const btc = feed.getPrice("LCX", "BTC/USDC").?;
    try std.testing.expectEqual(@as(u64, 65_234_500_000), btc.bid_micro_usd);
}

test "Circuit breaker — per-exchange cap rejects new entries" {
    var feed = ExchangeFeed.init(std.testing.allocator);
    defer feed.deinit();

    // Saturate Kraken just under the per-exchange cap, then push past.
    var i: usize = 0;
    var pair_buf: [16]u8 = undefined;
    while (i < MAX_PAIRS_PER_EXCHANGE) : (i += 1) {
        const pair = std.fmt.bufPrint(&pair_buf, "X{d}/USD", .{i}) catch unreachable;
        feed.upsertPrice("Kraken", pair, 1, 2);
    }
    try std.testing.expectEqual(@as(usize, MAX_PAIRS_PER_EXCHANGE), feed.kraken_count);

    // One past the cap → dropped.
    feed.upsertPrice("Kraken", "OVERFLOW/USD", 99, 100);
    try std.testing.expectEqual(@as(usize, MAX_PAIRS_PER_EXCHANGE), feed.kraken_count);
    try std.testing.expect(feed.getPrice("Kraken", "OVERFLOW/USD") == null);
}
