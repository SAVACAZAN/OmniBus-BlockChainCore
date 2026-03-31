/// oracle.zig — Price Oracle: BID/ASK per exchange + DEX
///
/// Nu facem median/agregare — stocam BID si ASK de pe fiecare exchange separat.
/// Arbitrajul se face in alta parte (HFT-MultiExchange) pe baza acestor date.
///
/// Rolul oracle-ului in blockchain:
///   - Bridge cross-chain are nevoie de un pret "de referinta" trustless
///   - Validatorii OmniBus submitera pretul pe care il vad pe exchange-urile lor
///   - Oracle-ul pastreaza BID/ASK per exchange si calculeaza median DOAR pt bridge
///
/// Exchange-uri suportate: Binance, Kraken, Coinbase, LCX, Bybit, OKX,
///                         + DEX: Uniswap, Raydium, EGLD DEX
const std = @import("std");

// --- TIPURI ------------------------------------------------------------------

pub const ChainId = enum(u8) {
    omni  = 0,
    btc   = 1,
    eth   = 2,
    egld  = 3,
    sol   = 4,
    ada   = 5,
    dot   = 6,
    avax  = 7,
    matic = 8,
    bnb   = 9,
    atom  = 10,
    near  = 11,
    ftm   = 12,
    one   = 13,
    zil   = 14,
    algo  = 15,
    xlm   = 16,
    xrp   = 17,
    ltc   = 18,
    doge  = 19,

    pub fn name(self: ChainId) []const u8 {
        return switch (self) {
            .omni  => "OMNI",  .btc   => "BTC",   .eth   => "ETH",
            .egld  => "EGLD",  .sol   => "SOL",   .ada   => "ADA",
            .dot   => "DOT",   .avax  => "AVAX",  .matic => "MATIC",
            .bnb   => "BNB",   .atom  => "ATOM",  .near  => "NEAR",
            .ftm   => "FTM",   .one   => "ONE",   .zil   => "ZIL",
            .algo  => "ALGO",  .xlm   => "XLM",   .xrp   => "XRP",
            .ltc   => "LTC",   .doge  => "DOGE",
        };
    }
};

/// Exchange-urile de pe care vin preturile
pub const ExchangeId = enum(u8) {
    binance  = 0,
    kraken   = 1,
    coinbase = 2,
    lcx      = 3,
    bybit    = 4,
    okx      = 5,
    uniswap  = 6,   // DEX
    raydium  = 7,   // DEX Solana
    egld_dex = 8,   // DEX MultiversX

    pub fn name(self: ExchangeId) []const u8 {
        return switch (self) {
            .binance  => "Binance",
            .kraken   => "Kraken",
            .coinbase => "Coinbase",
            .lcx      => "LCX",
            .bybit    => "Bybit",
            .okx      => "OKX",
            .uniswap  => "Uniswap",
            .raydium  => "Raydium",
            .egld_dex => "EGLD-DEX",
        };
    }

    pub fn isDex(self: ExchangeId) bool {
        return switch (self) {
            .uniswap, .raydium, .egld_dex => true,
            else => false,
        };
    }
};

pub const MAX_PRICE_AGE_MS: i64 = 60_000;

/// BID/ASK de pe un exchange specific pentru un asset
/// Validatorul OmniBus citeste aceste date si le submitera pe chain
pub const ExchangeQuote = struct {
    chain_id:    ChainId,
    exchange_id: ExchangeId,
    /// Pret BID (cumparatorul plateste) in micro-USD
    bid_micro_usd: u64,
    /// Pret ASK (vanzatorul cere) in micro-USD
    ask_micro_usd: u64,
    /// Volume ultimele 24h in micro-USD (pentru ponderea la bridge)
    volume_24h_micro_usd: u64,
    timestamp_ms: i64,

    pub fn spread(self: *const ExchangeQuote) u64 {
        if (self.ask_micro_usd <= self.bid_micro_usd) return 0;
        return self.ask_micro_usd - self.bid_micro_usd;
    }

    pub fn midPrice(self: *const ExchangeQuote) u64 {
        return (self.bid_micro_usd + self.ask_micro_usd) / 2;
    }

    pub fn isStale(self: *const ExchangeQuote, now_ms: i64) bool {
        return now_ms - self.timestamp_ms > MAX_PRICE_AGE_MS;
    }
};

/// Pretul de referinta pentru bridge — median din mid-price-urile CEX/DEX
/// Acesta NU e pretul de arbitraj — e doar pretul trustless pt bridge
pub const BridgeReferencePrice = struct {
    chain_id:         ChainId,
    reference_micro_usd: u64,   // median din mid-prices
    last_update_ms:   i64,
    source_count:     u8,
    is_valid:         bool,
};

// --- ORACLE ------------------------------------------------------------------

pub const MAX_EXCHANGES: usize = 9;
pub const CHAINS: usize = 20;

pub const PriceOracle = struct {
    /// Quotes per (chain, exchange) — [chain][exchange]
    quotes: [CHAINS][MAX_EXCHANGES]ExchangeQuote,
    quote_valid: [CHAINS][MAX_EXCHANGES]bool,

    /// Pret de referinta pentru bridge (median din toate exchange-urile)
    bridge_prices: [CHAINS]BridgeReferencePrice,

    pub fn init() PriceOracle {
        var oracle: PriceOracle = undefined;
        for (0..CHAINS) |c| {
            for (0..MAX_EXCHANGES) |e| {
                oracle.quote_valid[c][e] = false;
            }
            oracle.bridge_prices[c] = BridgeReferencePrice{
                .chain_id            = @enumFromInt(c),
                .reference_micro_usd = 0,
                .last_update_ms      = 0,
                .source_count        = 0,
                .is_valid            = false,
            };
        }
        return oracle;
    }

    /// Submitera un quote BID/ASK de pe un exchange specific
    pub fn submitQuote(self: *PriceOracle, quote: ExchangeQuote) !void {
        const c = @intFromEnum(quote.chain_id);
        const e = @intFromEnum(quote.exchange_id);
        if (c >= CHAINS or e >= MAX_EXCHANGES) return error.InvalidId;
        if (quote.bid_micro_usd == 0 or quote.ask_micro_usd == 0) return error.InvalidPrice;
        if (quote.ask_micro_usd < quote.bid_micro_usd) return error.InvalidSpread;

        self.quotes[c][e] = quote;
        self.quote_valid[c][e] = true;

        // Recalculeaza pretul de referinta pentru bridge
        self.recalcBridgePrice(c);
    }

    /// Returneaza quote-ul de pe un exchange specific
    pub fn getExchangeQuote(self: *const PriceOracle,
                             chain: ChainId,
                             exchange: ExchangeId) !ExchangeQuote {
        const c = @intFromEnum(chain);
        const e = @intFromEnum(exchange);
        if (!self.quote_valid[c][e]) return error.QuoteNotAvailable;
        const q = self.quotes[c][e];
        const now_ms = std.time.milliTimestamp();
        if (q.isStale(now_ms)) return error.QuoteStale;
        return q;
    }

    /// Returneaza pretul de referinta pentru bridge (median din mid-prices)
    pub fn getBridgePrice(self: *const PriceOracle, chain: ChainId) !BridgeReferencePrice {
        const c = @intFromEnum(chain);
        const p = self.bridge_prices[c];
        if (!p.is_valid) return error.PriceNotAvailable;
        const now_ms = std.time.milliTimestamp();
        if (now_ms - p.last_update_ms > MAX_PRICE_AGE_MS) return error.PriceStale;
        return p;
    }

    /// Gaseste cel mai mic ASK (best ask) dintre toate exchange-urile pt un asset
    pub fn bestAsk(self: *const PriceOracle, chain: ChainId) !ExchangeQuote {
        const c = @intFromEnum(chain);
        const now_ms = std.time.milliTimestamp();
        var best: ?ExchangeQuote = null;

        for (0..MAX_EXCHANGES) |e| {
            if (!self.quote_valid[c][e]) continue;
            const q = self.quotes[c][e];
            if (q.isStale(now_ms)) continue;
            if (best == null or q.ask_micro_usd < best.?.ask_micro_usd) {
                best = q;
            }
        }

        return best orelse error.QuoteNotAvailable;
    }

    /// Gaseste cel mai mare BID (best bid) dintre toate exchange-urile pt un asset
    pub fn bestBid(self: *const PriceOracle, chain: ChainId) !ExchangeQuote {
        const c = @intFromEnum(chain);
        const now_ms = std.time.milliTimestamp();
        var best: ?ExchangeQuote = null;

        for (0..MAX_EXCHANGES) |e| {
            if (!self.quote_valid[c][e]) continue;
            const q = self.quotes[c][e];
            if (q.isStale(now_ms)) continue;
            if (best == null or q.bid_micro_usd > best.?.bid_micro_usd) {
                best = q;
            }
        }

        return best orelse error.QuoteNotAvailable;
    }

    /// Calculeaza pretul de referinta pentru bridge (median mid-price)
    fn recalcBridgePrice(self: *PriceOracle, c: usize) void {
        var mid_prices: [MAX_EXCHANGES]u64 = undefined;
        var count: u8 = 0;
        const now_ms = std.time.milliTimestamp();

        for (0..MAX_EXCHANGES) |e| {
            if (!self.quote_valid[c][e]) continue;
            const q = self.quotes[c][e];
            if (q.isStale(now_ms)) continue;
            mid_prices[count] = q.midPrice();
            count += 1;
        }

        if (count == 0) {
            self.bridge_prices[c].is_valid = false;
            return;
        }

        // Insertion sort
        for (1..count) |i| {
            const key = mid_prices[i];
            var j: usize = i;
            while (j > 0 and mid_prices[j - 1] > key) : (j -= 1) {
                mid_prices[j] = mid_prices[j - 1];
            }
            mid_prices[j] = key;
        }

        self.bridge_prices[c].reference_micro_usd = mid_prices[count / 2];
        self.bridge_prices[c].last_update_ms = now_ms;
        self.bridge_prices[c].source_count = count;
        self.bridge_prices[c].is_valid = true;
    }

    pub fn printStatus(self: *const PriceOracle, chain: ChainId) void {
        const c = @intFromEnum(chain);
        std.debug.print("[ORACLE] {s} quotes:\n", .{chain.name()});
        for (0..MAX_EXCHANGES) |e| {
            if (!self.quote_valid[c][e]) continue;
            const q = self.quotes[c][e];
            const ex: ExchangeId = @enumFromInt(e);
            std.debug.print("  {s}: BID=${d:.4} ASK=${d:.4} spread={d}\n", .{
                ex.name(),
                @as(f64, @floatFromInt(q.bid_micro_usd)) / 1_000_000.0,
                @as(f64, @floatFromInt(q.ask_micro_usd)) / 1_000_000.0,
                q.spread(),
            });
        }
        if (self.bridge_prices[c].is_valid) {
            std.debug.print("  Bridge ref: ${d:.4}\n", .{
                @as(f64, @floatFromInt(self.bridge_prices[c].reference_micro_usd)) / 1_000_000.0,
            });
        }
    }
};

// --- TESTE -------------------------------------------------------------------
const testing = std.testing;

fn makeQuote(chain: ChainId, ex: ExchangeId, bid: u64, ask: u64) ExchangeQuote {
    return ExchangeQuote{
        .chain_id            = chain,
        .exchange_id         = ex,
        .bid_micro_usd       = bid,
        .ask_micro_usd       = ask,
        .volume_24h_micro_usd = 1_000_000_000,
        .timestamp_ms        = std.time.milliTimestamp(),
    };
}

test "PriceOracle — init fara quote" {
    var oracle = PriceOracle.init();
    try testing.expectError(error.QuoteNotAvailable, oracle.getExchangeQuote(.btc, .binance));
}

test "PriceOracle — submit quote si getExchangeQuote" {
    var oracle = PriceOracle.init();
    try oracle.submitQuote(makeQuote(.btc, .binance, 49_900_000_000, 50_100_000_000));
    const q = try oracle.getExchangeQuote(.btc, .binance);
    try testing.expectEqual(@as(u64, 49_900_000_000), q.bid_micro_usd);
    try testing.expectEqual(@as(u64, 50_100_000_000), q.ask_micro_usd);
}

test "PriceOracle — spread calculat corect" {
    const q = makeQuote(.eth, .kraken, 3_000_000_000, 3_010_000_000);
    try testing.expectEqual(@as(u64, 10_000_000), q.spread());
}

test "PriceOracle — mid price calculat corect" {
    const q = makeQuote(.eth, .kraken, 3_000_000_000, 3_010_000_000);
    try testing.expectEqual(@as(u64, 3_005_000_000), q.midPrice());
}

test "PriceOracle — best ask din mai multe exchange-uri" {
    var oracle = PriceOracle.init();
    try oracle.submitQuote(makeQuote(.btc, .binance,  49_900_000_000, 50_100_000_000));
    try oracle.submitQuote(makeQuote(.btc, .kraken,   49_800_000_000, 50_000_000_000));  // best ask
    try oracle.submitQuote(makeQuote(.btc, .coinbase, 49_950_000_000, 50_200_000_000));

    const best = try oracle.bestAsk(.btc);
    try testing.expectEqual(ExchangeId.kraken, best.exchange_id);
    try testing.expectEqual(@as(u64, 50_000_000_000), best.ask_micro_usd);
}

test "PriceOracle — best bid din mai multe exchange-uri" {
    var oracle = PriceOracle.init();
    try oracle.submitQuote(makeQuote(.btc, .binance,  49_900_000_000, 50_100_000_000));
    try oracle.submitQuote(makeQuote(.btc, .kraken,   49_800_000_000, 50_000_000_000));
    try oracle.submitQuote(makeQuote(.btc, .coinbase, 49_950_000_000, 50_200_000_000));  // best bid

    const best = try oracle.bestBid(.btc);
    try testing.expectEqual(ExchangeId.coinbase, best.exchange_id);
    try testing.expectEqual(@as(u64, 49_950_000_000), best.bid_micro_usd);
}

test "PriceOracle — bridge price = median mid-price" {
    var oracle = PriceOracle.init();
    // 3 exchange-uri: mid = 50000, 50010, 49990 -> sorted: 49990, 50000, 50010 -> median = 50000
    try oracle.submitQuote(makeQuote(.btc, .binance,  49_900_000_000, 50_100_000_000));  // mid=50000
    try oracle.submitQuote(makeQuote(.btc, .kraken,   49_910_000_000, 50_110_000_000));  // mid=50010
    try oracle.submitQuote(makeQuote(.btc, .coinbase, 49_890_000_000, 50_090_000_000));  // mid=49990

    const bp = try oracle.getBridgePrice(.btc);
    try testing.expectEqual(@as(u64, 50_000_000_000), bp.reference_micro_usd);
    try testing.expectEqual(@as(u8, 3), bp.source_count);
}

test "PriceOracle — invalid spread returneaza eroare" {
    var oracle = PriceOracle.init();
    // ask < bid = invalid
    try testing.expectError(error.InvalidSpread,
        oracle.submitQuote(makeQuote(.eth, .binance, 3_010_000_000, 3_000_000_000)));
}

test "PriceOracle — DEX quote acceptat" {
    var oracle = PriceOracle.init();
    try oracle.submitQuote(makeQuote(.eth, .uniswap, 3_000_000_000, 3_001_000_000));
    const q = try oracle.getExchangeQuote(.eth, .uniswap);
    try testing.expect(ExchangeId.uniswap.isDex());
    try testing.expectEqual(@as(u64, 3_000_000_000), q.bid_micro_usd);
}

test "PriceOracle — ChainId.name() corecte" {
    try testing.expectEqualStrings("BTC",  ChainId.btc.name());
    try testing.expectEqualStrings("OMNI", ChainId.omni.name());
    try testing.expectEqualStrings("EGLD", ChainId.egld.name());
}
