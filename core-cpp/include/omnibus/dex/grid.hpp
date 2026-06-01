#pragma once
#include "order.hpp"
#include "matching.hpp"
#include <map>
#include <vector>

namespace omnibus::dex {

struct GridLevel {
    u64 price;
    u64 amount;
    bool is_buy;
};

struct GridStrategy {
    u64 strategy_id;
    u32 pair_id;
    u64 lower_price;
    u64 upper_price;
    u32 num_levels;
    u64 total_investment;
    std::vector<GridLevel> levels;
    Hash160 owner;
    bool active;
    
    void generate_levels();
};

class GridTrading {
    std::map<u64, GridStrategy> strategies_;
    
public:
    u64 create_strategy(const GridStrategy& strategy);
    bool cancel_strategy(u64 strategy_id, const Hash160& owner);
    std::vector<Fill> tick(u32 pair_id, u64 current_price);
    void follow_orders(const std::vector<Fill>& fills);
};

} // namespace omnibus::dex