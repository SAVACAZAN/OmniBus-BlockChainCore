#include "../../include/omnibus/agents/manager.hpp"
#include <spdlog/spdlog.h>

namespace omnibus::agents {

bool AgentManager::register_agent(const Hash160& agent, const std::vector<std::string>& caps) {
    if (agents_.find(agent) != agents_.end()) return false;
    
    AgentProfile profile;
    profile.id = agent;
    profile.tier = AgentTier::T1_MINING;
    profile.registered_at = std::time(nullptr);
    profile.last_active = 0;
    profile.total_actions = 0;
    profile.success_count = 0;
    profile.reward_earned = 0;
    profile.capabilities = caps;
    
    agents_[agent] = profile;
    spdlog::info("Agent registered: {}", omnibus::to_hex(agent));
    return true;
}

bool AgentManager::update_tier(const Hash160& agent) {
    auto it = agents_.find(agent);
    if (it == agents_.end()) return false;
    
    auto new_tier = calculate_tier(it->second.reward_earned, it->second.total_actions,
                                   it->second.reward_earned, 0); // Simplified
    if (new_tier != it->second.tier) {
        it->second.tier = new_tier;
        spdlog::info("Agent {} upgraded to tier {}", omnibus::to_hex(agent), static_cast<int>(new_tier));
    }
    return true;
}

bool AgentManager::record_action(const Hash160& agent, bool success, u64 reward) {
    auto it = agents_.find(agent);
    if (it == agents_.end()) return false;
    
    it->second.last_active = std::time(nullptr);
    it->second.total_actions++;
    if (success) {
        it->second.success_count++;
        it->second.reward_earned += reward;
    }
    
    update_tier(agent);
    return true;
}

AgentProfile AgentManager::get_profile(const Hash160& agent) const {
    auto it = agents_.find(agent);
    if (it != agents_.end()) {
        return it->second;
    }
    return AgentProfile{};
}

std::vector<AgentProfile> AgentManager::get_top_agents(size_t count) const {
    std::vector<AgentProfile> all;
    for (const auto& [id, profile] : agents_) {
        all.push_back(profile);
    }
    
    std::sort(all.begin(), all.end(),
        [](const AgentProfile& a, const AgentProfile& b) {
            return a.reward_earned > b.reward_earned;
        });
    
    if (all.size() > count) all.resize(count);
    return all;
}

void AgentManager::distribute_rewards() {
    // Would calculate and distribute rewards based on agent activity
    spdlog::info("Distributing agent rewards");
}

} // namespace omnibus::agents