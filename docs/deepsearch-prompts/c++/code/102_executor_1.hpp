// OEP-1 98/150 | path=include/omnibus/agents/manager.hpp | proj=omnibus-node-cpp | run=2026-06-01-cpp-v1
#pragma once
#include "executor.hpp"
#include <map>
#include <vector>

namespace omnibus::agents {

struct AgentProfile {
    Hash160 id;
    AgentTier tier;
    u64 registered_at;
    u64 last_active;
    u64 total_actions;
    u64 success_count;
    u64 reward_earned;
    std::vector<std::string> capabilities;
};

class AgentManager {
    std::map<Hash160, AgentProfile> agents_;
    AgentExecutor executor_;
    
public:
    bool register_agent(const Hash160& agent, const std::vector<std::string>& caps);
    bool update_tier(const Hash160& agent);
    bool record_action(const Hash160& agent, bool success, u64 reward);
    AgentProfile get_profile(const Hash160& agent) const;
    std::vector<AgentProfile> get_top_agents(size_t count) const;
    void distribute_rewards();
    
private:
    void check_tier_upgrades();
    u64 calculate_reward(const AgentProfile& agent, const AgentAction& action) const;
};

} // namespace omnibus::agents