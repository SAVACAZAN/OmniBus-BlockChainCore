#pragma once
#include "order.hpp"
#include <map>
#include <vector>
#include <optional>

namespace omnibus::dex {

struct Fill {
    u64 order_id;
    u64 fill_amount;
    u64 fill_price;
    u64 timestamp;
    Hash256 txid;
};

class MatchingEngine {
    std::map<u64, std::vector<Order>> bids; // price -> orders (lowest price first for buys? actually highest first)
    std::map<u64, std::vector<Order>> asks; // price -> orders (lowest first)
    
    void insert_order(const Order& order);
    std::vector<Fill> match_buy(Order& buy_order);
    std::vector<Fill> match_sell(Order& sell_order);
    
public:
    std::vector<Fill> place_order(const Order& order);
    bool cancel_order(u64 order_id, const Hash160& owner);
    std::optional<Order> get_order(u64 order_id) const;
    void prune_expired(u32 current_height);
    
    // Merkle orderbook root for block commitment
    Hash256 compute_orderbook_root() const;
};

} // namespace omnibus::dex