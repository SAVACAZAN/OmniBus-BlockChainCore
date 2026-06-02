// OEP-1 136/150 | path=tests/test_dex.cpp | proj=omnibus-node-cpp | run=2026-06-01-cpp-v1
#include <catch2/catch.hpp>
#include "../include/omnibus/dex/pair.hpp"
#include "../include/omnibus/dex/matching.hpp"
#include "../include/omnibus/dex/htlc.hpp"

using namespace omnibus::dex;

TEST_CASE("Reserved pair_id rejection", "[dex]") {
    for (u32 pid : {1, 4}) {
        REQUIRE(is_pair_allowed(pid) == false);
    }
    
    for (u32 pid : {0, 2, 3, 5, 6}) {
        REQUIRE(is_pair_allowed(pid) == true);
    }
}

TEST_CASE("Order matching basic", "[dex]") {
    MatchingEngine engine;
    
    Order buy;
    buy.pair_id = 0;
    buy.side = OrderSide::BUY;
    buy.amount = 100;
    buy.price = 50000;
    buy.type = OrderType::LIMIT;
    
    Order sell;
    sell.pair_id = 0;
    sell.side = OrderSide::SELL;
    sell.amount = 50;
    sell.price = 50000;
    sell.type = OrderType::LIMIT;
    
    auto fills1 = engine.place_order(sell);
    auto fills2 = engine.place_order(buy);
    
    // Should match
    REQUIRE(fills2.size() > 0);
}

TEST_CASE("HTLC preimage hidden before claim", "[dex]") {
    SwapRegistry registry;
    
    HTLC swap;
    // Setup swap
    std::vector<u8> preimage = {1, 2, 3, 4};
    swap.preimage_hash = sha256(preimage);
    swap.state = HtlcState::INIT;
    
    registry.create_swap(swap);
    
    auto revealed = registry.revealed_preimage(swap.preimage_hash);
    REQUIRE(revealed.has_value() == false);
    
    registry.claim(swap.swap_id, preimage);
    revealed = registry.revealed_preimage(swap.preimage_hash);
    REQUIRE(revealed.has_value() == true);
    REQUIRE(revealed.value() == preimage);
}

TEST_CASE("Orderbook merkle root", "[dex]") {
    MatchingEngine engine;
    
    Order order;
    order.pair_id = 0;
    order.side = OrderSide::BUY;
    order.amount = 100;
    order.price = 50000;
    order.order_id = 1;
    
    engine.place_order(order);
    
    auto root = engine.compute_orderbook_root();
    REQUIRE(root != Hash256{});
}