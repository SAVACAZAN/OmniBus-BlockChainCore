// OEP-1 128/150 | path=src/agents/executor.cpp | proj=omnibus-node-cpp | run=2026-06-01-cpp-v1
#include "../../include/omnibus/agents/executor.hpp"
#include <spdlog/spdlog.h>

namespace omnibus::agents {

bool AgentExecutor::can_execute(const Hash160& agent, AgentTier required_tier) const {
    auto it = agent_tiers_.find(agent);
    if (it == agent_tiers_.end()) return false;
    return static_cast<int>(it->second) >= static_cast<int>(required_tier);
}

bool AgentExecutor::submit_action(const Hash160& agent, const AgentAction& action) {
    if (!can_execute(agent, AgentTier::T1_MINING)) {
        spdlog::warn("Agent {} cannot execute action - insufficient tier", agent.data());
        return false;
    }
    
    spdlog::info("Agent {} submitted action: {}", agent.data(), action.action_type);
    return true;
}

dex::Order AgentExecutor::create_market_order(const Hash160& agent, u32 pair_id, dex::OrderSide side, u64 amount) {
    dex::Order order;
    order.pair_id = pair_id;
    order.side = side;
    order.amount = amount;
    order.type = dex::OrderType::MARKET;
    order.timestamp = std::time(nullptr);
    order.owner = agent;
    
    spdlog::info("Agent {} created market order: pair={}, side={}, amount={}", 
                 agent.data(), pair_id, static_cast<int>(side), amount);
    return order;
}

bool AgentExecutor::delegate_stake(const Hash160& agent, const Hash160& validator, u64 amount) {
    spdlog::info("Agent {} staking {} to validator {}", agent.data(), amount, validator.data());
    return true;
}

bool AgentExecutor::start_arbitrage_loop(const Hash160& agent, u32 pair_a, u32 pair_b) {
    spdlog::info("Agent {} starting arbitrage between pair {} and {}", agent.data(), pair_a, pair_b);
    return true;
}

} // namespace omnibus::agents