#include "../../include/omnibus/dex/matching.hpp"
#include "../../include/omnibus/dex/pair.hpp"
#include <algorithm>
#include <spdlog/spdlog.h>

namespace omnibus::dex {

void MatchingEngine::insert_order(const Order& order) {
    if (order.side == OrderSide::BUY) {
        bids[order.price].push_back(order);
        // Sort bids: highest price first
        // Maintain FIFO within same price
    } else {
        asks[order.price].push_back(order);
        // Sort asks: lowest price first
    }
}

std::vector<Fill> MatchingEngine::match_buy(Order& buy_order) {
    std::vector<Fill> fills;
    auto it = asks.begin();
    
    while (it != asks.end() && buy_order.remaining() > 0) {
        if (buy_order.price < it->first) break; // Price too low
        
        for (auto& sell_order : it->second) {
            if (!sell_order.is_active()) continue;
            
            u64 fill_amount = std::min(buy_order.remaining(), sell_order.remaining());
            Fill fill;
            fill.order_id = sell_order.order_id;
            fill.fill_amount = fill_amount;
            fill.fill_price = it->first;
            fill.timestamp = std::time(nullptr);
            
            buy_order.filled_amount += fill_amount;
            sell_order.filled_amount += fill_amount;
            fills.push_back(fill);
            
            if (buy_order.remaining() == 0) break;
        }
        
        // Remove fully filled orders
        it->second.erase(
            std::remove_if(it->second.begin(), it->second.end(),
                [](const Order& o) { return !o.is_active(); }),
            it->second.end());
        
        if (it->second.empty()) {
            it = asks.erase(it);
        } else {
            ++it;
        }
    }
    
    return fills;
}

std::vector<Fill> MatchingEngine::match_sell(Order& sell_order) {
    std::vector<Fill> fills;
    auto it = bids.begin();
    
    while (it != bids.end() && sell_order.remaining() > 0) {
        if (sell_order.price > it->first) break;
        
        for (auto& buy_order : it->second) {
            if (!buy_order.is_active()) continue;
            
            u64 fill_amount = std::min(sell_order.remaining(), buy_order.remaining());
            Fill fill;
            fill.order_id = buy_order.order_id;
            fill.fill_amount = fill_amount;
            fill.fill_price = it->first;
            fill.timestamp = std::time(nullptr);
            
            sell_order.filled_amount += fill_amount;
            buy_order.filled_amount += fill_amount;
            fills.push_back(fill);
            
            if (sell_order.remaining() == 0) break;
        }
        
        it->second.erase(
            std::remove_if(it->second.begin(), it->second.end(),
                [](const Order& o) { return !o.is_active(); }),
            it->second.end());
        
        if (it->second.empty()) {
            it = bids.erase(it);
        } else {
            ++it;
        }
    }
    
    return fills;
}

std::vector<Fill> MatchingEngine::place_order(const Order& order) {
    if (!is_pair_allowed(order.pair_id)) {
        spdlog::warn("Rejected order for reserved pair_id: {}", order.pair_id);
        return {};
    }
    
    Order working = order;
    std::vector<Fill> fills;
    
    if (order.side == OrderSide::BUY) {
        fills = match_buy(working);
    } else {
        fills = match_sell(working);
    }
    
    if (working.remaining() > 0 && working.tif != TimeInForce::IOC && working.tif != TimeInForce::FOK) {
        insert_order(working);
    }
    
    return fills;
}

bool MatchingEngine::cancel_order(u64 order_id, const Hash160& owner) {
    for (auto& [price, orders] : bids) {
        auto it = std::find_if(orders.begin(), orders.end(),
            [order_id, &owner](const Order& o) { return o.order_id == order_id && o.owner == owner; });
        if (it != orders.end()) {
            orders.erase(it);
            return true;
        }
    }
    
    for (auto& [price, orders] : asks) {
        auto it = std::find_if(orders.begin(), orders.end(),
            [order_id, &owner](const Order& o) { return o.order_id == order_id && o.owner == owner; });
        if (it != orders.end()) {
            orders.erase(it);
            return true;
        }
    }
    
    return false;
}

std::optional<Order> MatchingEngine::get_order(u64 order_id) const {
    for (const auto& [price, orders] : bids) {
        for (const auto& order : orders) {
            if (order.order_id == order_id) return order;
        }
    }
    for (const auto& [price, orders] : asks) {
        for (const auto& order : orders) {
            if (order.order_id == order_id) return order;
        }
    }
    return std::nullopt;
}

void MatchingEngine::prune_expired(u32 current_height) {
    for (auto& [price, orders] : bids) {
        orders.erase(std::remove_if(orders.begin(), orders.end(),
            [current_height](const Order& o) {
                return o.expiry_height > 0 && o.expiry_height <= current_height;
            }), orders.end());
    }
    for (auto& [price, orders] : asks) {
        orders.erase(std::remove_if(orders.begin(), orders.end(),
            [current_height](const Order& o) {
                return o.expiry_height > 0 && o.expiry_height <= current_height;
            }), orders.end());
    }
}

Hash256 MatchingEngine::compute_orderbook_root() const {
    std::vector<Hash256> leaves;
    
    for (const auto& [price, orders] : bids) {
        for (const auto& order : orders) {
            // Hash the order
            std::vector<u8> buf;
            codec::write_le(order.order_id, buf);
            codec::write_le(order.price, buf);
            codec::write_le(order.amount, buf);
            leaves.push_back(crypto::sha256(buf));
        }
    }
    
    for (const auto& [price, orders] : asks) {
        for (const auto& order : orders) {
            std::vector<u8> buf;
            codec::write_le(order.order_id, buf);
            codec::write_le(order.price, buf);
            codec::write_le(order.amount, buf);
            leaves.push_back(crypto::sha256(buf));
        }
    }
    
    if (leaves.empty()) return Hash256{};
    return consensus::compute_merkle_root(leaves);
}

} // namespace omnibus::dex