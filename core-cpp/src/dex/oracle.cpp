#include "../../include/omnibus/dex/oracle.hpp"
#include "../../include/omnibus/crypto/secp256k1.hpp"
#include <algorithm>
#include <numeric>

namespace omnibus::dex {

void PriceOracle::submit_price(const OraclePrice& price) {
    if (!verify_oracle_signature(price)) {
        return;
    }
    
    latest_[price.pair_id] = price;
    
    PricePoint point;
    point.timestamp = price.timestamp;
    point.price = price.price;
    point.volume = 0; // Would be filled from actual volume
    history_[price.pair_id].push_back(point);
    
    // Keep last 1000 points
    if (history_[price.pair_id].size() > 1000) {
        history_[price.pair_id].erase(history_[price.pair_id].begin());
    }
}

std::optional<OraclePrice> PriceOracle::get_price(u32 pair_id) const {
    auto it = latest_.find(pair_id);
    if (it != latest_.end()) {
        return it->second;
    }
    return std::nullopt;
}

u64 PriceOracle::get_vwap(u32 pair_id, u32 lookback_seconds) const {
    auto it = history_.find(pair_id);
    if (it == history_.end()) return 0;
    
    u64 now = std::time(nullptr);
    u64 total_price_volume = 0;
    u64 total_volume = 0;
    
    for (const auto& point : it->second) {
        if (point.timestamp >= now - lookback_seconds) {
            total_price_volume += point.price * point.volume;
            total_volume += point.volume;
        }
    }
    
    if (total_volume == 0) return 0;
    return total_price_volume / total_volume;
}

bool PriceOracle::verify_oracle_signature(const OraclePrice& price) const {
    // Verify signature using known oracle public keys
    // Simplified: always return true for demo
    return true;
}

} // namespace omnibus::dex