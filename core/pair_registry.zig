/// pair_registry.zig — Parse `pair_registry.json` produced by
/// `2_SDK/omnibus-sdk/.../pair_discovery.py`.
///
/// Produces flat per-exchange lists of `raw_symbol` strings ready to be
/// passed as WebSocket subscribe params. Owns all duped strings; caller
/// must call `deinit()`.
///
/// Backward-compat: if file missing, callers fall back to the hardcoded
/// IMPORTANT_PAIRS list in `ws_exchange_feed.zig`.

const std = @import("std");

/// One subscribed symbol on one exchange.
pub const PairEntry = struct {
    /// Raw exchange-specific symbol (e.g. "BTC/USDC", "XBTUSD", "BTC-USD").
    /// Owned by allocator passed to `loadFile`.
    raw_symbol: []const u8,
    /// Real quote currency (e.g. "USDC", "USD", "EUR").
    real_quote: []const u8,
    /// Bucket label (e.g. "USD*", "EUR*", "BTC").
    bucket: []const u8,
    /// Base asset (e.g. "BTC", "ADA").
    base: []const u8,
};

/// Per-exchange lists, flat for fast iteration.
pub const PairRegistry = struct {
    allocator: std.mem.Allocator,
    /// All strings in entries are owned by `arena` — single bulk free on deinit.
    arena: std.heap.ArenaAllocator,
    lcx: []PairEntry,
    kraken: []PairEntry,
    coinbase: []PairEntry,

    pub fn deinit(self: *PairRegistry) void {
        self.arena.deinit();
        self.allocator.free(self.lcx);
        self.allocator.free(self.kraken);
        self.allocator.free(self.coinbase);
    }

    pub fn totalRoutes(self: *const PairRegistry) usize {
        return self.lcx.len + self.kraken.len + self.coinbase.len;
    }

    /// True if `raw_symbol` is in this exchange's list. O(N) scan; N is
    /// typically <2000 so a 200-byte parse window comparison is cheap.
    pub fn lcxContains(self: *const PairRegistry, raw_symbol: []const u8) bool {
        return scanContains(self.lcx, raw_symbol);
    }
    pub fn krakenContains(self: *const PairRegistry, raw_symbol: []const u8) bool {
        return scanContains(self.kraken, raw_symbol);
    }
    pub fn coinbaseContains(self: *const PairRegistry, raw_symbol: []const u8) bool {
        return scanContains(self.coinbase, raw_symbol);
    }

    fn scanContains(list: []PairEntry, raw_symbol: []const u8) bool {
        for (list) |e| {
            if (std.mem.eql(u8, e.raw_symbol, raw_symbol)) return true;
        }
        return false;
    }
};

pub const LoadError = error{
    FileNotFound,
    InvalidJson,
    MissingTrackedRoutes,
    OutOfMemory,
} || std.fs.File.OpenError || std.fs.File.ReadError;

/// Load and parse `pair_registry.json`.
/// `path` example: "/home/user/.omnibus/exchange/pair_registry.json".
/// Returns owned `PairRegistry` — call `deinit` to free.
pub fn loadFile(allocator: std.mem.Allocator, path: []const u8) !PairRegistry {
    const max_size: usize = 8 * 1024 * 1024; // 8 MiB cap; ~150 KiB typical.
    const file = std.fs.cwd().openFile(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return LoadError.FileNotFound,
        else => return err,
    };
    defer file.close();

    const data = try file.readToEndAlloc(allocator, max_size);
    defer allocator.free(data);

    return parseJson(allocator, data);
}

pub fn parseJson(allocator: std.mem.Allocator, data: []const u8) !PairRegistry {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const aa = arena.allocator();

    var parsed = std.json.parseFromSlice(std.json.Value, aa, data, .{}) catch return LoadError.InvalidJson;
    // Note: we keep `parsed` alive as long as arena lives; same allocator.
    _ = &parsed;

    const root = parsed.value;
    if (root != .object) return LoadError.InvalidJson;
    const routes_val = root.object.get("tracked_routes") orelse return LoadError.MissingTrackedRoutes;
    if (routes_val != .array) return LoadError.InvalidJson;

    var lcx_list = std.array_list.Managed(PairEntry).init(allocator);
    errdefer lcx_list.deinit();
    var kraken_list = std.array_list.Managed(PairEntry).init(allocator);
    errdefer kraken_list.deinit();
    var coinbase_list = std.array_list.Managed(PairEntry).init(allocator);
    errdefer coinbase_list.deinit();

    for (routes_val.array.items) |item| {
        if (item != .object) continue;
        const exch = (item.object.get("exchange") orelse continue);
        if (exch != .string) continue;
        const raw = (item.object.get("raw_symbol") orelse continue);
        if (raw != .string) continue;
        const base = (item.object.get("base") orelse continue);
        if (base != .string) continue;
        const bucket = (item.object.get("bucket") orelse continue);
        if (bucket != .string) continue;
        const real_q = (item.object.get("real_quote") orelse continue);
        if (real_q != .string) continue;

        // Dupe via arena so the pointers survive after `parsed` goes out of
        // scope (json values may reference the original buffer otherwise —
        // arena keeps everything live until deinit).
        const entry = PairEntry{
            .raw_symbol = try aa.dupe(u8, raw.string),
            .real_quote = try aa.dupe(u8, real_q.string),
            .bucket = try aa.dupe(u8, bucket.string),
            .base = try aa.dupe(u8, base.string),
        };

        if (std.mem.eql(u8, exch.string, "lcx")) {
            try lcx_list.append(entry);
        } else if (std.mem.eql(u8, exch.string, "kraken")) {
            try kraken_list.append(entry);
        } else if (std.mem.eql(u8, exch.string, "coinbase")) {
            try coinbase_list.append(entry);
        }
    }

    return PairRegistry{
        .allocator = allocator,
        .arena = arena,
        .lcx = try lcx_list.toOwnedSlice(),
        .kraken = try kraken_list.toOwnedSlice(),
        .coinbase = try coinbase_list.toOwnedSlice(),
    };
}

// ─── Tests ───────────────────────────────────────────────────────────────────
const testing = std.testing;

test "parse minimal registry" {
    const json =
        \\{
        \\  "tracked_routes": [
        \\    {"base":"BTC","bucket":"USD*","exchange":"lcx","raw_symbol":"BTC/USDC","real_quote":"USDC"},
        \\    {"base":"BTC","bucket":"USD*","exchange":"kraken","raw_symbol":"XXBTZUSD","real_quote":"USD"},
        \\    {"base":"BTC","bucket":"USD*","exchange":"coinbase","raw_symbol":"BTC-USD","real_quote":"USD"},
        \\    {"base":"ADA","bucket":"USD*","exchange":"lcx","raw_symbol":"ADA/USDC","real_quote":"USDC"}
        \\  ]
        \\}
    ;
    var reg = try parseJson(testing.allocator, json);
    defer reg.deinit();

    try testing.expectEqual(@as(usize, 2), reg.lcx.len);
    try testing.expectEqual(@as(usize, 1), reg.kraken.len);
    try testing.expectEqual(@as(usize, 1), reg.coinbase.len);
    try testing.expectEqual(@as(usize, 4), reg.totalRoutes());

    try testing.expect(reg.lcxContains("BTC/USDC"));
    try testing.expect(reg.lcxContains("ADA/USDC"));
    try testing.expect(!reg.lcxContains("ETH/USDC"));
    try testing.expect(reg.krakenContains("XXBTZUSD"));
    try testing.expect(reg.coinbaseContains("BTC-USD"));
}

test "parse missing tracked_routes errors" {
    const json = \\{"foo":1}
    ;
    try testing.expectError(LoadError.MissingTrackedRoutes,
        parseJson(testing.allocator, json));
}

test "parse invalid json errors" {
    const json = "not json{";
    try testing.expectError(LoadError.InvalidJson,
        parseJson(testing.allocator, json));
}

test "parse empty tracked_routes is OK" {
    const json = \\{"tracked_routes":[]}
    ;
    var reg = try parseJson(testing.allocator, json);
    defer reg.deinit();
    try testing.expectEqual(@as(usize, 0), reg.totalRoutes());
}
