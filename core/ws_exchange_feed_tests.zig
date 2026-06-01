// ws_exchange_feed_tests.zig — Extracted inline tests from ws_exchange_feed.zig.
// parseCoinbaseTicker/parseKrakenMessage/parseLcxMessage promoted to pub in source.

const std = @import("std");
const wsf = @import("ws_exchange_feed.zig");

const ExchangeFeed = wsf.ExchangeFeed;
const PriceFetch = wsf.PriceFetch;
const floatToMicroUsd = wsf.floatToMicroUsd;
const parseQuotedPrice = wsf.parseQuotedPrice;
const parseUnquotedPrice = wsf.parseUnquotedPrice;
const parseCoinbaseTicker = wsf.parseCoinbaseTicker;
const parseKrakenMessage = wsf.parseKrakenMessage;
const parseLcxMessage = wsf.parseLcxMessage;
const DEFAULT_STALE_THRESHOLD_MS = wsf.DEFAULT_STALE_THRESHOLD_MS;
const MAX_PAIRS_PER_EXCHANGE = wsf.MAX_PAIRS_PER_EXCHANGE;

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
        \\{"symbol":"SOL/USD","bid":150.25,"ask":150.30,"last":150.27}]}
    ;
    parseKrakenMessage(&feed, frame);
    try std.testing.expectEqual(@as(usize, 3), feed.count());

    const btc = feed.getPrice("Kraken", "BTC/USD").?;
    try std.testing.expectEqual(@as(u64, 65_234_100_000), btc.bid_micro_usd);
    const sol = feed.getPrice("Kraken", "SOL/USD").?;
    try std.testing.expectEqual(@as(u64, 150_250_000), sol.bid_micro_usd);
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
