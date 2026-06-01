#include "../../include/omnibus/dex/grid.hpp"
#include <cmath>
#include <spdlog/spdlog.h>

namespace omnibus::dex {

void GridStrategy::generate_levels() {
    levels.clear();
    double price_step = std::pow(upper_price / lower_price, 1.0 / num_levels);
    
    u64 current_price = lower_price;
    for (u32 i = 0; i < num_levels; ++i) {
        GridLevel level;
        level.price = current_price;
        level.amount = total_investment / num_levels;
        level.is_buy = (i < num_levels / 2); // Lower half buy, upper half sell
        levels.push_back(level);
        
        current_price = static_cast<u64>(current_price * price_step);
    }
}

u64 GridTrading::create_strategy(const GridStrategy& strategy) {
    GridStrategy new_strategy = strategy;
    new_strategy.strategy_id = strategies_.size() + 1;
    new_strategy.generate_levels();
    new_strategy.active = true;
    strategies_[new_strategy.strategy_id] = new_strategy;
    
    spdlog::info("Created grid strategy {} with {} levels", new_strategy.strategy_id, new_strategy.num_levels);
    return new_strategy.strategy_id;
}

bool GridTrading::cancel_strategy(u64 strategy_id, const Hash160& owner) {
    auto it = strategies_.find(strategy_id);
    if (it == strategies_.end()) return false;
    if (it->second.owner != owner) return false;
    
    it->second.active = false;
    spdlog::info("Cancelled grid strategy {}", strategy_id);
    return true;
}

std::vector<Fill> GridTrading::tick(u32 pair_id, u64 current_price) {
    std::vector<Fill> all_fills;
    
    for (auto& [id, strategy] : strategies_) {
        if (!strategy.active || strategy.pair_id != pair_id) continue;
        
        for (auto& level : strategy.levels) {
            if ((level.is_buy && current_price <= level.price) ||
                (!level.is_buy && current_price >= level.price)) {
                // Trigger order
                Order order;
                order.pair_id = pair_id;
                order.side = level.is_buy ? OrderSide::BUY : OrderSide::SELL;
                order.amount = level.amount;
                order.price = level.price;
                order.type = OrderType::LIMIT;
                order.tif = TimeInForce::GTC;
                order.owner = strategy.owner;
                order.timestamp = std::time(nullptr);
                
                // Place order (would need matching engine reference)
                // all_fills = matching_engine.place_order(order);
            }
        }
    }
    
    return all_fills;
}

void GridTrading::follow_orders(const std::vector<Fill>& fills) {
    // Update grid levels based on fills
    // Rebalance positions
    for (const auto& fill : fills) {
        spdlog::debug("Grid order filled: order_id={}, amount={}", fill.order_id, fill.fill_amount);
    }
}

} // namespace omnibus::dex