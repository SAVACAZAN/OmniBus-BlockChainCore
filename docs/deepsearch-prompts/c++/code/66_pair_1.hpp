// OEP-1 62/150 | path=include/omnibus/dex/order.hpp | proj=omnibus-node-cpp | run=2026-06-01-cpp-v1
#pragma once
#include "../types.hpp"
#include "../storage/compact_tx.hpp"
#include <vector>

namespace omnibus::dex {

enum class OrderType : u8 {
    LIMIT = 0,
    MARKET = 1,
    STOP_LOSS = 2,
    STOP_LIMIT = 3
};

enum class OrderSide : u8 {
    BUY = 0,
    SELL = 1
};

enum class TimeInForce : u8 {
    GTC = 0, // Good till cancelled
    IOC = 1, // Immediate or cancel
    FOK = 2, // Fill or kill
    DAY = 3  // Good for day
};

struct Order {
    u64 order_id;
    u32 pair_id;
    OrderType type;
    OrderSide side;
    u64 amount;      // in base asset (sats)
    u64 price;       // quote per base * 10^8
    u64 filled_amount;
    u64 timestamp;
    TimeInForce tif;
    Hash256 txid;
    Hash160 owner;
    u32 expiry_height;
    
    bool is_active() const { return filled_amount < amount; }
    u64 remaining() const { return amount - filled_amount; }
};

struct OrderBookEntry {
    u64 price;
    u64 total_amount;
    std::vector<Order> orders;
};

} // namespace omnibus::dex