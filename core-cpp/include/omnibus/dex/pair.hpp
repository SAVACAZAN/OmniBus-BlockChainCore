#pragma once
#include "../types.hpp"
#include <string>
#include <array>
#include <unordered_map>

namespace omnibus::dex {

struct AssetPair {
    u32 pair_id;
    std::string base_asset;
    std::string quote_asset;
    u64 min_amount;
    u64 max_amount;
    u32 fee_bps; // basis points
};

constexpr std::array<AssetPair, 5> ASSET_CHAINS = {{
    {0, "OMNI", "USDC", 1000, 1000000000000, 10},
    {2, "LCX", "USDC", 1000, 1000000000000, 15},
    {3, "ETH", "USDC", 1000, 1000000000000, 10},
    {5, "OMNI", "LCX", 1000, 1000000000000, 20},
    {6, "OMNI", "ETH", 1000, 1000000000000, 20}
}};

constexpr std::array<u32, 2> RESERVED_PAIR_IDS = {1, 4};

inline bool is_pair_allowed(u32 pair_id) {
    for (u32 reserved : RESERVED_PAIR_IDS) {
        if (pair_id == reserved) return false;
    }
    for (const auto& pair : ASSET_CHAINS) {
        if (pair.pair_id == pair_id) return true;
    }
    return false;
}

inline const AssetPair* get_pair(u32 pair_id) {
    for (const auto& pair : ASSET_CHAINS) {
        if (pair.pair_id == pair_id) return &pair;
    }
    return nullptr;
}

// Cross-pair routing (e.g., OMNI/USDC can route through OMNI/LCX + LCX/USDC)
struct RouteHop {
    u32 from_pair;
    u32 to_pair;
    u32 conversion_fee_bps;
};

} // namespace omnibus::dex