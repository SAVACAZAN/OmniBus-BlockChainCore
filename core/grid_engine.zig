//! grid_engine.zig — Grid trading engine pentru OmniBus DEX.
//!
//! Arhitectura (vezi DEX_GRID_SPEC.md pentru detalii complete):
//!
//!   User setează grid { pair_id, price_low, price_high, levels, capital }
//!     → engine generează N buy + N sell orders virtuale în range
//!     → orders vizibile în orderbook ca "open" (fără fonduri locked)
//!     → la fiecare bloc: verifică oracle_price față de levels
//!     → dacă preț atinge un level → fill automat + order opus plasat
//!     → HTLC generat DOAR la momentul fill-ului (nu la plasare)
//!
//! Surse de preț:
//!   1. Trade intern (doi useri se întâlnesc) → prețul fill-ului
//!   2. Oracle extern (price_oracle.zig) → preț de referință
//!
//! Capital efficiency: 1 HTLC activ per fill, nu per order.

const std = @import("std");
const matching_mod = @import("matching_engine.zig");

// ─── Constante ────────────────────────────────────────────────────────────

pub const MAX_GRIDS:  usize = 256;   // max grids simultane pe nod
pub const MAX_LEVELS: u16   = 100;   // max levels per parte (buy sau sell)

// ─── Tipuri publice ───────────────────────────────────────────────────────

/// Configurația unui grid activ.
/// Prețurile sunt în micro-USD cu 6 decimale (1_000_000 = $1.00).
/// Cantitățile sunt în satoshi (1e8) pentru OMNI/BTC sau micro-token (1e6) pentru USDC/LCX.
pub const GridConfig = struct {
    id:            u64,
    owner:         [64]u8 = std.mem.zeroes([64]u8),
    owner_len:     u8     = 0,
    pair_id:       u16,
    price_low:     u64,   // micro-USD
    price_high:    u64,   // micro-USD
    levels:        u16,   // levels per parte (buy + sell = levels * 2)
    total_base:    u64,   // capital BASE disponibil (ex: OMNI în satoshi)
    total_quote:   u64,   // capital QUOTE disponibil (ex: USDC în micro-USD)
    filled_count:  u32    = 0,
    profit_quote:  i64    = 0,  // profit net în quote asset (poate fi negativ)
    active:        bool   = true,
    created_block: u64    = 0,

    pub fn owner_addr(self: *const GridConfig) []const u8 {
        return self.owner[0..self.owner_len];
    }

    /// Pas de preț între două levels consecutive.
    pub fn priceStep(self: *const GridConfig) u64 {
        if (self.levels == 0) return 0;
        return (self.price_high - self.price_low) / (@as(u64, self.levels) * 2);
    }

    /// Prețul buy level i (0 = cel mai mic).
    pub fn buyPrice(self: *const GridConfig, i: u16) u64 {
        return self.price_low + @as(u64, i) * self.priceStep();
    }

    /// Prețul sell level i (0 = primul sell, imediat deasupra mijlocului).
    pub fn sellPrice(self: *const GridConfig, i: u16) u64 {
        const mid = self.price_low + @as(u64, self.levels) * self.priceStep();
        return mid + @as(u64, i) * self.priceStep();
    }

    /// Cantitate base per level (distribuită uniform).
    pub fn basePerLevel(self: *const GridConfig) u64 {
        if (self.levels == 0) return 0;
        return self.total_base / @as(u64, self.levels);
    }

    /// Cantitate quote per level (distribuită uniform).
    pub fn quotePerLevel(self: *const GridConfig) u64 {
        if (self.levels == 0) return 0;
        return self.total_quote / @as(u64, self.levels);
    }
};

/// Un fill înregistrat de grid engine.
pub const GridFill = struct {
    grid_id:     u64,
    level_idx:   u16,
    side:        enum(u8) { buy = 0, sell = 1 },
    price:       u64,
    amount_base: u64,
    amount_quote: u64,
    block_height: u64,
    /// hash_lock din HTLC corespunzător (32 bytes hex)
    htlc_hash_lock: [64]u8 = std.mem.zeroes([64]u8),
};

pub const GridError = error{
    InvalidRange,
    TooManyLevels,
    RegistryFull,
    GridNotFound,
    NotOwner,
    AlreadyInactive,
};

// ─── Registry ─────────────────────────────────────────────────────────────

pub const GridRegistry = struct {
    grids:    [MAX_GRIDS]GridConfig = undefined,
    count:    u32 = 0,
    next_id:  u64 = 1,

    const Self = @This();

    pub fn init() Self {
        return .{ .count = 0, .next_id = 1 };
    }

    /// Creează un grid nou. Returnează grid_id.
    pub fn create(
        self: *Self,
        owner:       []const u8,
        pair_id:     u16,
        price_low:   u64,
        price_high:  u64,
        levels:      u16,
        total_base:  u64,
        total_quote: u64,
        current_block: u64,
    ) GridError!u64 {
        if (price_low >= price_high)  return GridError.InvalidRange;
        if (levels == 0 or levels > MAX_LEVELS) return GridError.TooManyLevels;
        if (self.count >= MAX_GRIDS)  return GridError.RegistryFull;

        const id = self.next_id;
        self.next_id += 1;

        var g: GridConfig = .{
            .id            = id,
            .pair_id       = pair_id,
            .price_low     = price_low,
            .price_high    = price_high,
            .levels        = levels,
            .total_base    = total_base,
            .total_quote   = total_quote,
            .active        = true,
            .created_block = current_block,
        };
        const copy_len = @min(owner.len, 64);
        @memcpy(g.owner[0..copy_len], owner[0..copy_len]);
        g.owner_len = @intCast(copy_len);

        self.grids[self.count] = g;
        self.count += 1;
        return id;
    }

    pub fn find(self: *const Self, grid_id: u64) ?*const GridConfig {
        var i: u32 = 0;
        while (i < self.count) : (i += 1) {
            if (self.grids[i].id == grid_id) return &self.grids[i];
        }
        return null;
    }

    fn findMut(self: *Self, grid_id: u64) ?*GridConfig {
        var i: u32 = 0;
        while (i < self.count) : (i += 1) {
            if (self.grids[i].id == grid_id) return &self.grids[i];
        }
        return null;
    }

    pub fn cancel(self: *Self, grid_id: u64, owner: []const u8) GridError!void {
        const g = self.findMut(grid_id) orelse return GridError.GridNotFound;
        if (!std.mem.eql(u8, g.owner[0..g.owner_len], owner)) return GridError.NotOwner;
        if (!g.active) return GridError.AlreadyInactive;
        g.active = false;
    }

    /// Plasează N buy + N sell orders în matching engine pentru un grid nou.
    /// Apelat imediat după create(). engine poate fi null (paper mode / test).
    pub fn placeLevelOrders(
        self:   *Self,
        grid_id: u64,
        engine: *matching_mod.MatchingEngine,
    ) void {
        const g = self.findMut(grid_id) orelse return;
        if (!g.active or g.levels == 0) return;

        const base_per  = g.basePerLevel();   // base SAT per sell level
        const quote_per = g.quotePerLevel();  // quote micro-USD per buy level
        const now_ms    = std.time.milliTimestamp();

        // Paritate: fiecare buy level cheltuie `quote_per` quote → amount_sat
        // = quote_per / price (în base). Fiecare sell level oferă `base_per`
        // base → valoare în quote = base_per * price / 1_000_000. Cele două
        // sunt echivalente la prețul mid când total_base * mid = total_quote.
        // User-ul setează capitalul; noi distribuim uniform pe fiecare nivel.

        // N buy orders: price_low .. mid-1 (crescător)
        var i: u16 = 0;
        while (i < g.levels) : (i += 1) {
            const price = g.buyPrice(i);
            if (price == 0) continue;
            const amount_sat = quote_per * 1_000_000 / price;
            if (amount_sat == 0) continue;
            var order = matching_mod.Order.empty();
            order.order_id        = g.id * 10_000 + @as(u64, i);
            order.pair_id         = g.pair_id;
            order.side            = .buy;
            order.price_micro_usd = price;
            order.amount_sat      = amount_sat;
            order.timestamp_ms    = now_ms;
            order.status          = .active;
            const alen = @min(g.owner_len, 64);
            @memcpy(order.trader_address[0..alen], g.owner[0..alen]);
            order.trader_addr_len = @intCast(alen);
            engine.placeOrder(order) catch {};
        }

        // N sell orders: mid .. price_high (crescător)
        // amount_sat = base_per (base SAT la preț de piață)
        i = 0;
        while (i < g.levels) : (i += 1) {
            if (base_per == 0) continue;
            var order = matching_mod.Order.empty();
            order.order_id        = g.id * 10_000 + @as(u64, g.levels) + @as(u64, i);
            order.pair_id         = g.pair_id;
            order.side            = .sell;
            order.price_micro_usd = g.sellPrice(i);
            order.amount_sat      = base_per;
            order.timestamp_ms    = now_ms;
            order.status          = .active;
            const alen = @min(g.owner_len, 64);
            @memcpy(order.trader_address[0..alen], g.owner[0..alen]);
            order.trader_addr_len = @intCast(alen);
            engine.placeOrder(order) catch {};
        }
    }

    /// Înregistrează un fill pe un grid și actualizează profitul.
    /// Returnează prețul order-ului opus care trebuie plasat automat.
    pub fn recordFill(
        self: *Self,
        grid_id:      u64,
        side:         GridFill.side,
        fill_price:   u64,
        amount_base:  u64,
        amount_quote: u64,  // rezervat pentru calcule viitoare de fee
    ) GridError!u64 {
        _ = amount_quote;
        const g = self.findMut(grid_id) orelse return GridError.GridNotFound;
        g.filled_count += 1;

        // Profit = diferența de preț × cantitate (simplificat)
        const step = g.priceStep();
        if (side == .sell) {
            // sell filled → profit = spread (step) × cantitate
            g.profit_quote += @intCast(step * amount_base / 1_000_000);
            // order opus: buy cu un nivel mai jos
            return if (fill_price >= step) fill_price - step else fill_price;
        } else {
            // buy filled → profit viitor când se va face sell
            g.profit_quote -= @intCast(step * amount_base / 1_000_000);
            // order opus: sell cu un nivel mai sus
            return fill_price + step;
        }
    }

    // ── Persistență ──────────────────────────────────────────────────────

    const MAGIC:   [8]u8 = [_]u8{ 'O', 'M', 'N', 'I', 'G', 'R', 'D', '1' };
    const VERSION: u32   = 1;
    const HEADER_SIZE: usize = 8 + 4 + 4; // magic + version + count
    const ENTRY_SIZE:  usize = 8 + 64 + 1 + 2 + 8 + 8 + 2 + 8 + 8 + 4 + 8 + 1 + 8;
    // id + owner + owner_len + pair_id + price_low + price_high + levels +
    // total_base + total_quote + filled_count + profit_quote(i64) + active + created_block
    // = 8+64+1+2+8+8+2+8+8+4+8+1+8 = 132

    pub fn saveToFile(self: *const Self, path: []const u8) !void {
        var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
        defer file.close();

        var hdr: [HEADER_SIZE]u8 = undefined;
        @memcpy(hdr[0..8], &MAGIC);
        std.mem.writeInt(u32, hdr[8..12], VERSION, .little);
        std.mem.writeInt(u32, hdr[12..16], self.count, .little);
        try file.writeAll(&hdr);

        var i: u32 = 0;
        while (i < self.count) : (i += 1) {
            var rec: [ENTRY_SIZE]u8 = std.mem.zeroes([ENTRY_SIZE]u8);
            const g = &self.grids[i];
            var off: usize = 0;
            std.mem.writeInt(u64, rec[off..][0..8], g.id, .little);            off += 8;
            @memcpy(rec[off..][0..64], &g.owner);                              off += 64;
            rec[off] = g.owner_len;                                             off += 1;
            std.mem.writeInt(u16, rec[off..][0..2], g.pair_id, .little);       off += 2;
            std.mem.writeInt(u64, rec[off..][0..8], g.price_low, .little);     off += 8;
            std.mem.writeInt(u64, rec[off..][0..8], g.price_high, .little);    off += 8;
            std.mem.writeInt(u16, rec[off..][0..2], g.levels, .little);        off += 2;
            std.mem.writeInt(u64, rec[off..][0..8], g.total_base, .little);    off += 8;
            std.mem.writeInt(u64, rec[off..][0..8], g.total_quote, .little);   off += 8;
            std.mem.writeInt(u32, rec[off..][0..4], g.filled_count, .little);  off += 4;
            std.mem.writeInt(i64, rec[off..][0..8], g.profit_quote, .little);  off += 8;
            rec[off] = if (g.active) 1 else 0;                                 off += 1;
            std.mem.writeInt(u64, rec[off..][0..8], g.created_block, .little);
            try file.writeAll(&rec);
        }
    }

    pub fn loadFromFile(self: *Self, path: []const u8) !void {
        var file = std.fs.cwd().openFile(path, .{}) catch |err| switch (err) {
            error.FileNotFound => { self.count = 0; return; },
            else => return err,
        };
        defer file.close();

        var hdr: [HEADER_SIZE]u8 = undefined;
        if (try file.readAll(&hdr) < HEADER_SIZE) return error.CorruptFile;
        if (!std.mem.eql(u8, hdr[0..8], &MAGIC)) return error.BadMagic;
        const ver = std.mem.readInt(u32, hdr[8..12], .little);
        if (ver != VERSION) return error.BadVersion;
        const count = std.mem.readInt(u32, hdr[12..16], .little);
        if (count > MAX_GRIDS) return error.CorruptFile;
        self.count = 0;

        var i: u32 = 0;
        while (i < count) : (i += 1) {
            var rec: [ENTRY_SIZE]u8 = undefined;
            if (try file.readAll(&rec) < ENTRY_SIZE) return error.CorruptFile;
            var g: GridConfig = undefined;
            var off: usize = 0;
            g.id            = std.mem.readInt(u64, rec[off..][0..8], .little); off += 8;
            @memcpy(&g.owner, rec[off..][0..64]);                               off += 64;
            g.owner_len     = rec[off];                                         off += 1;
            g.pair_id       = std.mem.readInt(u16, rec[off..][0..2], .little); off += 2;
            g.price_low     = std.mem.readInt(u64, rec[off..][0..8], .little); off += 8;
            g.price_high    = std.mem.readInt(u64, rec[off..][0..8], .little); off += 8;
            g.levels        = std.mem.readInt(u16, rec[off..][0..2], .little); off += 2;
            g.total_base    = std.mem.readInt(u64, rec[off..][0..8], .little); off += 8;
            g.total_quote   = std.mem.readInt(u64, rec[off..][0..8], .little); off += 8;
            g.filled_count  = std.mem.readInt(u32, rec[off..][0..4], .little); off += 4;
            g.profit_quote  = std.mem.readInt(i64, rec[off..][0..8], .little); off += 8;
            g.active        = rec[off] != 0;                                    off += 1;
            g.created_block = std.mem.readInt(u64, rec[off..][0..8], .little);
            self.grids[self.count] = g;
            self.count += 1;
        }
        // Restaurează next_id
        var max_id: u64 = 0;
        i = 0;
        while (i < self.count) : (i += 1) {
            if (self.grids[i].id > max_id) max_id = self.grids[i].id;
        }
        self.next_id = max_id + 1;
    }
};

// ─── Tick — apelat la fiecare bloc nou ────────────────────────────────────

/// Rezultat al unui tick: ce fills s-au generat și ce orders opuse trebuie plasate.
pub const TickResult = struct {
    /// Fills generate în acest tick (max 1 per grid activ, de obicei)
    fills:      [MAX_GRIDS]GridFill = undefined,
    fill_count: u32 = 0,

    /// Orders opuse de plasat automat după fills
    /// { grid_id, pair_id, side(buy=0/sell=1), price, amount_base, amount_quote }
    follow_orders:      [MAX_GRIDS]FollowOrder = undefined,
    follow_order_count: u32 = 0,

    pub const FollowOrder = struct {
        grid_id:      u64,
        pair_id:      u16,
        is_buy:       bool,
        price:        u64,
        amount_base:  u64,
        amount_quote: u64,
    };
};

/// Procesează toate grid-urile active față de prețul curent al oracle-ului.
/// oracle_price este în micro-USD (6 decimale).
/// Returnează fills generate și orders opuse de plasat.
pub fn tick(
    registry:     *GridRegistry,
    pair_id:      u16,
    oracle_price: u64,
    block_height: u64,
) TickResult {
    var result = TickResult{};

    var i: u32 = 0;
    while (i < registry.count) : (i += 1) {
        const g = &registry.grids[i];
        if (!g.active) continue;
        if (g.pair_id != pair_id) continue;

        const step = g.priceStep();
        if (step == 0) continue;

        // Verifică sell levels (oracle >= sell_price → fill sell)
        var lvl: u16 = 0;
        while (lvl < g.levels) : (lvl += 1) {
            const sell_p = g.sellPrice(lvl);
            if (oracle_price >= sell_p) {
                const amount_base  = g.basePerLevel();
                const amount_quote = sell_p * amount_base / 1_000_000;

                if (result.fill_count < MAX_GRIDS) {
                    result.fills[result.fill_count] = .{
                        .grid_id      = g.id,
                        .level_idx    = g.levels + lvl,
                        .side         = .sell,
                        .price        = sell_p,
                        .amount_base  = amount_base,
                        .amount_quote = amount_quote,
                        .block_height = block_height,
                    };
                    result.fill_count += 1;
                }

                // Order opus: buy cu un nivel mai jos
                const buy_p = if (sell_p >= step) sell_p - step else sell_p;
                if (result.follow_order_count < MAX_GRIDS) {
                    result.follow_orders[result.follow_order_count] = .{
                        .grid_id     = g.id,
                        .pair_id     = pair_id,
                        .is_buy      = true,
                        .price       = buy_p,
                        .amount_base = amount_base,
                        .amount_quote = buy_p * amount_base / 1_000_000,
                    };
                    result.follow_order_count += 1;
                }
                break; // un fill per tick per grid
            }
        }

        // Verifică buy levels (oracle <= buy_price → fill buy)
        lvl = 0;
        while (lvl < g.levels) : (lvl += 1) {
            // Cel mai mare buy level care e atins (oracle <= buy_price)
            const buy_idx = g.levels - 1 - lvl;
            const buy_p   = g.buyPrice(buy_idx);
            if (oracle_price <= buy_p) {
                const amount_base  = g.basePerLevel();
                const amount_quote = buy_p * amount_base / 1_000_000;

                if (result.fill_count < MAX_GRIDS) {
                    result.fills[result.fill_count] = .{
                        .grid_id      = g.id,
                        .level_idx    = buy_idx,
                        .side         = .buy,
                        .price        = buy_p,
                        .amount_base  = amount_base,
                        .amount_quote = amount_quote,
                        .block_height = block_height,
                    };
                    result.fill_count += 1;
                }

                // Order opus: sell cu un nivel mai sus
                const sell_p = buy_p + step;
                if (result.follow_order_count < MAX_GRIDS) {
                    result.follow_orders[result.follow_order_count] = .{
                        .grid_id      = g.id,
                        .pair_id      = pair_id,
                        .is_buy       = false,
                        .price        = sell_p,
                        .amount_base  = amount_base,
                        .amount_quote = sell_p * amount_base / 1_000_000,
                    };
                    result.follow_order_count += 1;
                }
                break; // un fill per tick per grid
            }
        }
    }

    return result;
}

// ─── Helpers JSON pentru RPC ──────────────────────────────────────────────

fn writeJsonSafeStr(w: anytype, s: []const u8) !void {
    for (s) |c| {
        if (c == '"')       { try w.writeByte('\''); }
        else if (c == '\\') { try w.writeByte('/');  }
        else if (c < 0x20)  {}
        else                { try w.writeByte(c);    }
    }
}

/// Scrie JSON-ul unui GridConfig într-un ArrayList.
pub fn writeGridJson(
    g:     *const GridConfig,
    out:   *std.ArrayList(u8),
    alloc: std.mem.Allocator,
) !void {
    const w = out.writer(alloc);
    try std.fmt.format(w,
        "{{\"grid_id\":{d},\"pair_id\":{d},\"owner\":\"",
        .{ g.id, g.pair_id });
    try writeJsonSafeStr(w, g.owner[0..g.owner_len]);
    try std.fmt.format(w,
        "\"," ++
        "\"price_low\":{d},\"price_high\":{d},\"levels\":{d}," ++
        "\"total_base\":{d},\"total_quote\":{d}," ++
        "\"filled_count\":{d},\"profit_quote\":{d},\"active\":{s}," ++
        "\"created_block\":{d}}}",
        .{
            g.price_low, g.price_high, g.levels,
            g.total_base, g.total_quote,
            g.filled_count, g.profit_quote,
            if (g.active) "true" else "false",
            g.created_block,
        });
}

// ─── Teste ────────────────────────────────────────────────────────────────

const testing = std.testing;

test "GridConfig — priceStep și levels calculate corect" {
    const g = GridConfig{
        .id = 1, .pair_id = 0,
        .price_low  = 100_000,  // $0.10
        .price_high = 200_000,  // $0.20
        .levels     = 10,
        .total_base  = 1_000_000_000,
        .total_quote = 1_000_000,
    };
    // step = (200k - 100k) / 20 = 5000 ($0.005)
    try testing.expectEqual(@as(u64, 5_000), g.priceStep());
    // buy[0] = 100_000, buy[9] = 145_000
    try testing.expectEqual(@as(u64, 100_000), g.buyPrice(0));
    try testing.expectEqual(@as(u64, 145_000), g.buyPrice(9));
    // sell[0] = 150_000 (mid), sell[9] = 195_000
    try testing.expectEqual(@as(u64, 150_000), g.sellPrice(0));
    try testing.expectEqual(@as(u64, 195_000), g.sellPrice(9));
}

test "GridRegistry — create, find, cancel" {
    var reg = GridRegistry.init();
    const id = try reg.create("ob1qtest", 0, 100_000, 200_000, 10,
        1_000_000_000, 1_000_000, 100);
    try testing.expectEqual(@as(u64, 1), id);
    try testing.expectEqual(@as(u32, 1), reg.count);

    const g = reg.find(id).?;
    try testing.expectEqual(@as(u16, 10), g.levels);
    try testing.expect(g.active);

    try reg.cancel(id, "ob1qtest");
    try testing.expect(!reg.find(id).?.active);

    // Cancel din nou → AlreadyInactive
    try testing.expectError(GridError.AlreadyInactive, reg.cancel(id, "ob1qtest"));
    // Cancel cu owner greșit
    const id2 = try reg.create("ob1qtest", 0, 100_000, 200_000, 5,
        500_000_000, 500_000, 101);
    try testing.expectError(GridError.NotOwner, reg.cancel(id2, "ob1qother"));
}

test "GridRegistry — invalid range și too many levels" {
    var reg = GridRegistry.init();
    try testing.expectError(GridError.InvalidRange,
        reg.create("ob1q", 0, 200_000, 100_000, 10, 100, 100, 1));
    try testing.expectError(GridError.TooManyLevels,
        reg.create("ob1q", 0, 100_000, 200_000, 0, 100, 100, 1));
    try testing.expectError(GridError.TooManyLevels,
        reg.create("ob1q", 0, 100_000, 200_000, 101, 100, 100, 1));
}

test "tick — fill sell când oracle >= sell_price" {
    var reg = GridRegistry.init();
    _ = try reg.create("ob1q", 0, 100_000, 200_000, 10,
        1_000_000_000, 1_000_000, 1);

    // oracle la $0.16 = 160_000 → atinge primul sell level >= oracle (sell[0]=150_000)
    // logica: orice sell_level <= oracle_price se execută
    const result = tick(&reg, 0, 160_000, 2);
    try testing.expect(result.fill_count > 0);
    try testing.expectEqual(.sell, result.fills[0].side);
    // primul sell level = 150_000 (mid), e <= 160_000 → fill
    try testing.expectEqual(@as(u64, 150_000), result.fills[0].price);

    // follow order = buy cu un nivel mai jos (145_000 = 150_000 - 5_000)
    try testing.expect(result.follow_order_count > 0);
    try testing.expect(result.follow_orders[0].is_buy);
    try testing.expectEqual(@as(u64, 145_000), result.follow_orders[0].price);
}

test "tick — fill buy când oracle <= buy_price" {
    var reg = GridRegistry.init();
    _ = try reg.create("ob1q", 0, 100_000, 200_000, 10,
        1_000_000_000, 1_000_000, 1);

    // oracle la $0.12 = 120_000 → atinge buy[4] = 120_000
    const result = tick(&reg, 0, 120_000, 3);
    try testing.expect(result.fill_count > 0);
    try testing.expectEqual(.buy, result.fills[0].side);

    // follow order = sell cu un nivel mai sus
    try testing.expect(result.follow_order_count > 0);
    try testing.expect(!result.follow_orders[0].is_buy);
}

test "tick — ignoră pair_id diferit" {
    var reg = GridRegistry.init();
    _ = try reg.create("ob1q", 0, 100_000, 200_000, 10,
        1_000_000_000, 1_000_000, 1);

    // tick pe pair_id=3 (ETH/USDC) — gridul e pe pair_id=0
    const result = tick(&reg, 3, 160_000, 2);
    try testing.expectEqual(@as(u32, 0), result.fill_count);
}

test "GridRegistry — persistență round-trip" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path_buf = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(path_buf);
    const path = try std.fmt.allocPrint(testing.allocator, "{s}/grid_registry.bin", .{path_buf});
    defer testing.allocator.free(path);

    var reg = GridRegistry.init();
    const id1 = try reg.create("ob1qalex", 0, 100_000, 200_000, 10,
        1_000_000_000, 500_000, 50);
    _ = try reg.create("ob1qbob",  3, 150_000, 300_000, 5,
        500_000_000, 250_000, 51);
    try reg.cancel(id1, "ob1qalex");
    try reg.saveToFile(path);

    var reg2 = GridRegistry.init();
    try reg2.loadFromFile(path);
    try testing.expectEqual(@as(u32, 2), reg2.count);
    try testing.expect(!reg2.find(id1).?.active);
    try testing.expectEqual(@as(u16, 5), reg2.find(2).?.levels);
    try testing.expectEqual(@as(u64, 3), reg2.next_id);
}
