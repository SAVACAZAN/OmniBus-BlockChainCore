// Matching-engine unit tests — extracted from core/matching_engine.zig.
//
// Lives next to matching_engine.zig (in core/) so test-local @imports of
// sibling modules resolve via a normal relative path. Zig 0.15.2 forbids
// `@import("../...")` from a test root file, which is why a `test/`
// location wouldn't work — see core/blockchain_tests.zig for the same
// pattern.
//
// Run via `zig test core/matching_engine_tests.zig` (with the same -Doqs
// flag the chain uses) or via the build.zig `test-chain` step which wires
// it in as the `matching-engine-tests` step.

const std = @import("std");
const me_mod = @import("matching_engine.zig");

const Side                = me_mod.Side;
const Order               = me_mod.Order;
const OrderStatus         = me_mod.OrderStatus;
const MatchingError       = me_mod.MatchingError;
const MatchingEngineWith  = me_mod.MatchingEngineWith;
const MAX_PAIRS           = me_mod.MAX_PAIRS;

// Engine mic pentru teste — incape pe stack (~15KB)
const TestEngine = MatchingEngineWith(64, 32);

// ─── Test helper (file-private to the test module) ───────────────────────────

fn makeTestOrder(
    side: Side,
    price: u64,
    amount: u64,
    ts: i64,
    addr: []const u8,
    pair_id: u16,
) Order {
    var order = Order.empty();
    order.side = side;
    order.price_micro_usd = price;
    order.amount_sat = amount;
    order.timestamp_ms = ts;
    order.pair_id = pair_id;
    order.status = .active;
    order.trader_addr_len = @intCast(addr.len);
    @memcpy(order.trader_address[0..addr.len], addr);
    return order;
}

// --- TESTE -------------------------------------------------------------------

test "init matching engine" {
    const engine = TestEngine.init();
    try std.testing.expectEqual(@as(u32, 0), engine.bid_count);
    try std.testing.expectEqual(@as(u32, 0), engine.ask_count);
    try std.testing.expectEqual(@as(u32, 0), engine.fill_count);
    try std.testing.expectEqual(@as(u64, 1), engine.next_order_id);
    try std.testing.expectEqual(@as(u64, 1), engine.next_fill_id);
    try std.testing.expectEqual(@as(u32, 0), engine.orderCount());
}

test "place buy order — no match" {
    var engine = TestEngine.init();
    const order = makeTestOrder(.buy, 50_000_000, 1_000_000_000, 1000, "alice123", 0);
    try engine.placeOrder(order);

    try std.testing.expectEqual(@as(u32, 1), engine.bid_count);
    try std.testing.expectEqual(@as(u32, 0), engine.ask_count);
    try std.testing.expectEqual(@as(u32, 0), engine.fill_count);
    try std.testing.expectEqual(@as(u32, 1), engine.orderCount());

    // Verifica ordinea in book
    try std.testing.expectEqual(@as(u64, 50_000_000), engine.bids[0].price_micro_usd);
    try std.testing.expectEqual(@as(u64, 1_000_000_000), engine.bids[0].amount_sat);
    try std.testing.expectEqual(OrderStatus.active, engine.bids[0].status);
}

test "place sell order — no match" {
    var engine = TestEngine.init();
    const order = makeTestOrder(.sell, 51_000_000, 500_000_000, 2000, "bob456", 0);
    try engine.placeOrder(order);

    try std.testing.expectEqual(@as(u32, 0), engine.bid_count);
    try std.testing.expectEqual(@as(u32, 1), engine.ask_count);
    try std.testing.expectEqual(@as(u32, 0), engine.fill_count);
    try std.testing.expectEqual(@as(u64, 51_000_000), engine.asks[0].price_micro_usd);
}

test "exact match — full fill" {
    var engine = TestEngine.init();

    // Alice pune un sell la $50
    const sell = makeTestOrder(.sell, 50_000_000, 1_000_000_000, 1000, "alice123", 0);
    try engine.placeOrder(sell);
    try std.testing.expectEqual(@as(u32, 1), engine.ask_count);

    // Bob pune un buy la $50 — trebuie sa faca match complet
    const buy = makeTestOrder(.buy, 50_000_000, 1_000_000_000, 2000, "bob456", 0);
    try engine.placeOrder(buy);

    // Ambele ordine au fost complet umplute
    try std.testing.expectEqual(@as(u32, 0), engine.bid_count);
    try std.testing.expectEqual(@as(u32, 0), engine.ask_count);
    try std.testing.expectEqual(@as(u32, 1), engine.fill_count);

    // Verifica fill-ul
    const fill = engine.fills[0];
    try std.testing.expectEqual(@as(u64, 50_000_000), fill.price_micro_usd);
    try std.testing.expectEqual(@as(u64, 1_000_000_000), fill.amount_sat);
    try std.testing.expect(std.mem.eql(u8, fill.getBuyerAddress(), "bob456"));
    try std.testing.expect(std.mem.eql(u8, fill.getSellerAddress(), "alice123"));
}

test "partial fill" {
    var engine = TestEngine.init();

    // Alice vinde 5 OMNI la $100
    const sell = makeTestOrder(.sell, 100_000_000, 5_000_000_000, 1000, "alice123", 0);
    try engine.placeOrder(sell);

    // Bob cumpara 10 OMNI la $100 — doar 5 se umplu, restul 5 ramane in bids
    const buy = makeTestOrder(.buy, 100_000_000, 10_000_000_000, 2000, "bob456", 0);
    try engine.placeOrder(buy);

    // Sell complet umplut, buy partial
    try std.testing.expectEqual(@as(u32, 0), engine.ask_count);
    try std.testing.expectEqual(@as(u32, 1), engine.bid_count);
    try std.testing.expectEqual(@as(u32, 1), engine.fill_count);

    // Verifica fill-ul
    try std.testing.expectEqual(@as(u64, 5_000_000_000), engine.fills[0].amount_sat);

    // Restul buy-ului ramane in bids cu status partial
    try std.testing.expectEqual(OrderStatus.partial, engine.bids[0].status);
    try std.testing.expectEqual(@as(u64, 5_000_000_000), engine.bids[0].remainingSat());
}

test "price-time priority" {
    var engine = TestEngine.init();

    // Doua sell-uri la acelasi pret — primul plasat trebuie sa fie matched primul
    const sell_early = makeTestOrder(.sell, 50_000_000, 1_000_000_000, 1000, "alice", 0);
    const sell_late = makeTestOrder(.sell, 50_000_000, 1_000_000_000, 2000, "carol", 0);
    try engine.placeOrder(sell_early);
    try engine.placeOrder(sell_late);

    try std.testing.expectEqual(@as(u32, 2), engine.ask_count);

    // Verificam ordinea: cel mai vechi ask e pe pozitia 0
    try std.testing.expectEqual(@as(i64, 1000), engine.asks[0].timestamp_ms);
    try std.testing.expectEqual(@as(i64, 2000), engine.asks[1].timestamp_ms);

    // Bob cumpara 1 OMNI — trebuie sa faca match cu alice (FIFO)
    const buy = makeTestOrder(.buy, 50_000_000, 1_000_000_000, 3000, "bob", 0);
    try engine.placeOrder(buy);

    try std.testing.expectEqual(@as(u32, 1), engine.fill_count);
    try std.testing.expectEqual(@as(u32, 1), engine.ask_count);

    // Fill-ul trebuie sa fie cu alice (sell_early), nu carol
    try std.testing.expect(std.mem.eql(u8, engine.fills[0].getSellerAddress(), "alice"));

    // Carol ramane in book
    try std.testing.expect(std.mem.eql(u8, engine.asks[0].getTraderAddress(), "carol"));
}

test "cancel order" {
    var engine = TestEngine.init();

    const buy = makeTestOrder(.buy, 50_000_000, 1_000_000_000, 1000, "alice", 0);
    try engine.placeOrder(buy);
    try std.testing.expectEqual(@as(u32, 1), engine.bid_count);

    // Ordinea are ID-ul 1 (prima ordine)
    const order_id = engine.bids[0].order_id;
    try engine.cancelOrder(order_id);

    try std.testing.expectEqual(@as(u32, 0), engine.bid_count);
    try std.testing.expectEqual(@as(u32, 0), engine.orderCount());

    // Incercarea de a anula o ordine inexistenta da eroare
    const result = engine.cancelOrder(999);
    try std.testing.expectError(MatchingError.OrderNotFound, result);
}

test "orderbook merkle root — deterministic" {
    const buy = makeTestOrder(.buy, 50_000_000, 1_000_000_000, 1000, "alice", 0);
    const sell = makeTestOrder(.sell, 51_000_000, 500_000_000, 2000, "bob", 0);

    // Prima rulare — calculam root1
    var root1: [32]u8 = undefined;
    {
        var engine = TestEngine.init();
        try engine.placeOrder(buy);
        try engine.placeOrder(sell);
        root1 = engine.orderbookMerkleRoot();
    }

    // Engine gol — root diferit
    var empty_root: [32]u8 = undefined;
    {
        const engine = TestEngine.init();
        empty_root = engine.orderbookMerkleRoot();
    }
    try std.testing.expect(!std.mem.eql(u8, &root1, &empty_root));

    // A doua rulare cu aceleasi ordine — trebuie sa dea acelasi root
    var root2: [32]u8 = undefined;
    {
        var engine = TestEngine.init();
        try engine.placeOrder(buy);
        try engine.placeOrder(sell);
        root2 = engine.orderbookMerkleRoot();
    }

    try std.testing.expect(std.mem.eql(u8, &root1, &root2));
}

test "self-trade is allowed (matches as normal, fees apply at settlement)" {
    var engine = TestEngine.init();

    // Alice pune un sell
    const sell = makeTestOrder(.sell, 50_000_000, 1_000_000_000, 1000, "alice", 0);
    try engine.placeOrder(sell);

    // Alice pune un buy la acelasi pret — DA, se face match cu sine (e OK,
    // ea plateste fee maker+taker oricum la settlement).
    const buy = makeTestOrder(.buy, 50_000_000, 1_000_000_000, 2000, "alice", 0);
    try engine.placeOrder(buy);

    // Ambele ordine s-au consumat, 1 fill produs.
    try std.testing.expectEqual(@as(u32, 0), engine.bid_count);
    try std.testing.expectEqual(@as(u32, 0), engine.ask_count);
    try std.testing.expectEqual(@as(u32, 1), engine.fill_count);
    // Acelasi trader pe ambele parti — corect, e wash trade legitim.
    try std.testing.expect(std.mem.eql(u8, engine.fills[0].getBuyerAddress(), "alice"));
    try std.testing.expect(std.mem.eql(u8, engine.fills[0].getSellerAddress(), "alice"));
}

test "spread calculation" {
    var engine = TestEngine.init();

    // Inainte de ordine, spread-ul este null
    try std.testing.expect(engine.spread(0) == null);

    // Bid la $49, Ask la $51 → spread = $2
    const buy = makeTestOrder(.buy, 49_000_000, 1_000_000_000, 1000, "alice", 0);
    const sell = makeTestOrder(.sell, 51_000_000, 1_000_000_000, 2000, "bob", 0);
    try engine.placeOrder(buy);
    try engine.placeOrder(sell);

    try std.testing.expectEqual(@as(u64, 49_000_000), engine.bestBid(0).?);
    try std.testing.expectEqual(@as(u64, 51_000_000), engine.bestAsk(0).?);
    try std.testing.expectEqual(@as(u64, 2_000_000), engine.spread(0).?);

    // Pair 1 nu are ordine
    try std.testing.expect(engine.spread(1) == null);
}

test "multiple fills — price levels" {
    var engine = TestEngine.init();

    // Trei sell-uri la preturi diferite
    const sell1 = makeTestOrder(.sell, 100_000_000, 1_000_000_000, 1000, "seller_a", 0); // $100
    const sell2 = makeTestOrder(.sell, 101_000_000, 1_000_000_000, 2000, "seller_b", 0); // $101
    const sell3 = makeTestOrder(.sell, 102_000_000, 1_000_000_000, 3000, "seller_c", 0); // $102
    try engine.placeOrder(sell1);
    try engine.placeOrder(sell2);
    try engine.placeOrder(sell3);

    try std.testing.expectEqual(@as(u32, 3), engine.ask_count);

    // Un buy mare care mananca primele doua nivele de pret
    const buy = makeTestOrder(.buy, 101_000_000, 2_000_000_000, 4000, "buyer_x", 0);
    try engine.placeOrder(buy);

    // 2 fill-uri: $100 si $101
    try std.testing.expectEqual(@as(u32, 2), engine.fill_count);
    try std.testing.expectEqual(@as(u32, 1), engine.ask_count); // $102 ramane

    // Primul fill la $100 (pretul cel mai mic, resting order)
    try std.testing.expectEqual(@as(u64, 100_000_000), engine.fills[0].price_micro_usd);
    // Al doilea fill la $101
    try std.testing.expectEqual(@as(u64, 101_000_000), engine.fills[1].price_micro_usd);

    // Ask-ul ramas este cel de $102
    try std.testing.expectEqual(@as(u64, 102_000_000), engine.asks[0].price_micro_usd);
}

test "clearFills resets fill buffer" {
    var engine = TestEngine.init();

    const sell = makeTestOrder(.sell, 50_000_000, 1_000_000_000, 1000, "alice", 0);
    const buy = makeTestOrder(.buy, 50_000_000, 1_000_000_000, 2000, "bob", 0);
    try engine.placeOrder(sell);
    try engine.placeOrder(buy);

    try std.testing.expectEqual(@as(u32, 1), engine.fill_count);

    engine.clearFills();

    try std.testing.expectEqual(@as(u32, 0), engine.fill_count);
}

test "invalid order rejection" {
    var engine = TestEngine.init();

    // Pret zero
    const bad_price = makeTestOrder(.buy, 0, 1_000_000_000, 1000, "alice", 0);
    try std.testing.expectError(MatchingError.InvalidPrice, engine.placeOrder(bad_price));

    // Cantitate zero
    const bad_amount = makeTestOrder(.buy, 50_000_000, 0, 1000, "alice", 0);
    try std.testing.expectError(MatchingError.InvalidAmount, engine.placeOrder(bad_amount));

    // Pair ID invalid
    var bad_pair = makeTestOrder(.buy, 50_000_000, 1_000_000_000, 1000, "alice", 0);
    bad_pair.pair_id = MAX_PAIRS;
    try std.testing.expectError(MatchingError.InvalidPair, engine.placeOrder(bad_pair));

    // Niciuna din cele de sus nu trebuie sa fi fost adaugata
    try std.testing.expectEqual(@as(u32, 0), engine.orderCount());
}

test "bid sorting — descending price" {
    var engine = TestEngine.init();

    // Insereaza bids in ordine aleatoare
    const b1 = makeTestOrder(.buy, 49_000_000, 1_000_000_000, 1000, "a", 0);
    const b2 = makeTestOrder(.buy, 51_000_000, 1_000_000_000, 2000, "b", 0);
    const b3 = makeTestOrder(.buy, 50_000_000, 1_000_000_000, 3000, "c", 0);

    try engine.placeOrder(b1); // $49
    try engine.placeOrder(b2); // $51
    try engine.placeOrder(b3); // $50

    // Trebuie sortate: $51, $50, $49
    try std.testing.expectEqual(@as(u64, 51_000_000), engine.bids[0].price_micro_usd);
    try std.testing.expectEqual(@as(u64, 50_000_000), engine.bids[1].price_micro_usd);
    try std.testing.expectEqual(@as(u64, 49_000_000), engine.bids[2].price_micro_usd);
}

test "ask sorting — ascending price" {
    var engine = TestEngine.init();

    const a1 = makeTestOrder(.sell, 102_000_000, 1_000_000_000, 1000, "a", 0);
    const a2 = makeTestOrder(.sell, 100_000_000, 1_000_000_000, 2000, "b", 0);
    const a3 = makeTestOrder(.sell, 101_000_000, 1_000_000_000, 3000, "c", 0);

    try engine.placeOrder(a1); // $102
    try engine.placeOrder(a2); // $100
    try engine.placeOrder(a3); // $101

    // Trebuie sortate: $100, $101, $102
    try std.testing.expectEqual(@as(u64, 100_000_000), engine.asks[0].price_micro_usd);
    try std.testing.expectEqual(@as(u64, 101_000_000), engine.asks[1].price_micro_usd);
    try std.testing.expectEqual(@as(u64, 102_000_000), engine.asks[2].price_micro_usd);
}

test "different pairs do not match" {
    var engine = TestEngine.init();

    // Sell OMNI/USD (pair 0) la $50
    const sell = makeTestOrder(.sell, 50_000_000, 1_000_000_000, 1000, "alice", 0);
    try engine.placeOrder(sell);

    // Buy BTC/USD (pair 1) la $50 — nu trebuie sa faca match
    const buy = makeTestOrder(.buy, 50_000_000, 1_000_000_000, 2000, "bob", 1);
    try engine.placeOrder(buy);

    try std.testing.expectEqual(@as(u32, 0), engine.fill_count);
    try std.testing.expectEqual(@as(u32, 1), engine.bid_count);
    try std.testing.expectEqual(@as(u32, 1), engine.ask_count);
}

test "getOrder finds by ID" {
    var engine = TestEngine.init();

    const buy = makeTestOrder(.buy, 50_000_000, 1_000_000_000, 1000, "alice", 0);
    try engine.placeOrder(buy);

    const found = engine.getOrder(1); // primul order_id = 1
    try std.testing.expect(found != null);
    try std.testing.expectEqual(@as(u64, 50_000_000), found.?.price_micro_usd);

    const not_found = engine.getOrder(999);
    try std.testing.expect(not_found == null);
}
