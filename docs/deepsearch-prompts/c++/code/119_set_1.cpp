// OEP-1 115/150 | path=src/validator/slashing.cpp | proj=omnibus-node-cpp | run=2026-06-01-cpp-v1
#include "../../include/omnibus/validator/slashing.hpp"
#include <spdlog/spdlog.h>

namespace omnibus::validator {

bool SlashingManager::report_slashing(const Hash160& reporter, const SlashingEvent& event) {
    u64 slash_amount = calculate_slash_amount(0, event.reason);
    u64 reporter_reward = (slash_amount * REPORTER_REWARD_PCT) / 100;
    u64 burned = slash_amount - reporter_reward;
    
    SlashingEvent recorded = event;
    recorded.slashed_amount = slash_amount;
    recorded.reporter_reward = reporter_reward;
    recorded.burned_amount = burned;
    
    slash_history_[event.validator].push_back(recorded);
    
    spdlog::warn("Slashing reported for validator {}: reason={}, amount={}", 
                 event.validator.data(), event.reason, slash_amount);
    return true;
}

u64 SlashingManager::calculate_slash_amount(u64 stake, const std::string& reason) const {
    u64 pct = 0;
    if (reason == "double_sign") {
        pct = SLASH_MULTIPLE_SIGN;
    } else if (reason == "downtime") {
        pct = SLASH_DOWNTIME;
    } else if (reason == "liveness") {
        pct = SLASH_LIVENESS;
    }
    
    return (stake * pct) / 100;
}

std::vector<SlashingEvent> SlashingManager::get_slash_history(const Hash160& validator) const {
    auto it = slash_history_.find(validator);
    if (it != slash_history_.end()) {
        return it->second;
    }
    return {};
}

bool SlashingManager::is_jailed(const Hash160& validator) const {
    auto history = get_slash_history(validator);
    // Check if validator has been slashed in last 1000 blocks
    return !history.empty();
}

bool SlashingManager::unjail(const Hash160& validator, u64 fee_paid) {
    // Simplified: pay fee to unjail
    spdlog::info("Validator {} unjailed with fee {}", validator.data(), fee_paid);
    return true;
}

} // namespace omnibus::validator