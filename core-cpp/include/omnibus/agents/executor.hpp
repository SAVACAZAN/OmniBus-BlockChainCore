#pragma once
#include "tier.hpp"
#include "../dex/order.hpp"
#include "../validator/staking.hpp"
#include <functional>
#include <nlohmann/json.hpp>

namespace omnibus::agents {

struct AgentAction {
    std::string action_type; // "trade", "stake", "mine", "arbitrage"
    nlohmann::json params;
    u64 timestamp;
    u32 deadline_height;
};

class AgentExecutor {
    std::map<Hash160, AgentTier> agent_tiers_;
    
public:
    bool can_execute(const Hash160& agent, AgentTier required_tier) const;
    bool submit_action(const Hash160& agent, const AgentAction& action);
    dex::Order create_market_order(const Hash160& agent, u32 pair_id, dex::OrderSide side, u64 amount);
    bool delegate_stake(const Hash160& agent, const Hash160& validator, u64 amount);
    bool start_arbitrage_loop(const Hash160& agent, u32 pair_a, u32 pair_b);
};

} // namespace omnibus::agents