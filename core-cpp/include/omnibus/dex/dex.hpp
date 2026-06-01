#pragma once
#include "../types.hpp"
#include "../storage/compact_tx.hpp"
#include <map>
#include <optional>
#include <deque>

namespace omnibus::dex {

constexpr std::pair<u32, std::string> ASSET_CHAINS[] = {
    {0, "OMNI/USDC"},
    {2, "LCX/USDC"},
    {3, "ETH/USDC"},
    {5, "OMNI/LCX"},
    {6, "OMNI/ETH"}
};
constexpr std::array<u32, 2> RESERVED_PAIR_IDS = {1, 4};

struct Order {
    u32 pair_id;
    bool is_buy;
    u64 amount;  // in base asset satoshis
    u64 price;   // quote per base * 1e8
    u64 timestamp;
    Hash256 txid;
    u32 order_id;
};

class OrderBook {
    std::map<u64, std::deque<Order>> bids; // price -> queue (lowest price first for buys? actually price-time)
    std::map<u64, std::deque<Order>> asks;
public:
    void add_order(const Order& order);
    std::vector<std::pair<Order, u64>> match(u32 pair_id); // returns fills
    bool is_pair_allowed(u32 pair_id) const;
};

} // namespace omnibus::dex