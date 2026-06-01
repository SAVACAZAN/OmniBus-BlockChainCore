#pragma once
#include "../types.hpp"

namespace omnibus::agents {

enum class AgentTier : u8 {
    T1_MINING = 1,      // Basic mining
    T2_TRADING = 2,     // DEX market making
    T3_STAKING = 3,     // Validator staking
    T4_ARBITRAGE = 4    // Cross-shard arbitrage
};

struct TierThresholds {
    u64 min_balance_omni;
    u64 min_tx_count;
    u64 min_stake;
    u32 min_uptime_days;
};

constexpr TierThresholds TIER_CONFIGS[] = {
    {100, 10, 0, 0},      // T1
    {1000, 100, 100, 7},   // T2
    {10000, 1000, 1000, 30}, // T3
    {50000, 5000, 5000, 90}  // T4
};

inline AgentTier calculate_tier(u64 balance, u64 tx_count, u64 stake, u32 uptime_days) {
    if (balance >= 50000 && tx_count >= 5000 && stake >= 5000 && uptime_days >= 90)
        return AgentTier::T4_ARBITRAGE;
    if (balance >= 10000 && tx_count >= 1000 && stake >= 1000 && uptime_days >= 30)
        return AgentTier::T3_STAKING;
    if (balance >= 1000 && tx_count >= 100 && stake >= 100 && uptime_days >= 7)
        return AgentTier::T2_TRADING;
    if (balance >= 100 && tx_count >= 10)
        return AgentTier::T1_MINING;
    return AgentTier::T1_MINING;
}

} // namespace omnibus::agents