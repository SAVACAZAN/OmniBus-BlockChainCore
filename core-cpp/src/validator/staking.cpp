#include "../../include/omnibus/validator/staking.hpp"
#include <spdlog/spdlog.h>

namespace omnibus::validator {

bool StakingManager::stake(const Stake& stake) {
    if (stake.amount < tier_minimum_stake(ValidatorTier::OMNI)) {
        return false;
    }
    
    stakes_[stake.staker].push_back(stake);
    validator_total_stake_[stake.validator] += stake.amount;
    
    update_tiers();
    spdlog::info("Stake added: {} -> {} amount={}", stake.omnibus::to_hex(staker), stake.omnibus::to_hex(validator), stake.amount);
    return true;
}

bool StakingManager::unstake(const Hash160& staker, const Hash160& validator, u64 amount) {
    auto it = stakes_.find(staker);
    if (it == stakes_.end()) return false;
    
    u64 remaining = amount;
    for (auto& stake : it->second) {
        if (stake.validator == validator) {
            u64 to_remove = std::min(remaining, stake.amount);
            stake.amount -= to_remove;
            remaining -= to_remove;
            validator_total_stake_[validator] -= to_remove;
            
            if (remaining == 0) break;
        }
    }
    
    // Remove zero stakes
    it->second.erase(
        std::remove_if(it->second.begin(), it->second.end(),
            [](const Stake& s) { return s.amount == 0; }),
        it->second.end());
    
    update_tiers();
    spdlog::info("Stake removed: {} -> {} amount={}", omnibus::to_hex(staker), omnibus::to_hex(validator), amount);
    return true;
}

bool StakingManager::claim_rewards(const Hash160& staker, const Hash160& validator) {
    // Simplified: calculate and distribute rewards
    spdlog::info("Rewards claimed for {} from {}", omnibus::to_hex(staker), omnibus::to_hex(validator));
    return true;
}

u64 StakingManager::get_total_stake(const Hash160& validator) const {
    auto it = validator_total_stake_.find(validator);
    if (it != validator_total_stake_.end()) {
        return it->second;
    }
    return 0;
}

ValidatorTier StakingManager::get_validator_tier(const Hash160& validator) const {
    auto it = validator_tiers_.find(validator);
    if (it != validator_tiers_.end()) {
        return it->second;
    }
    return ValidatorTier::OMNI;
}

void StakingManager::update_tiers() {
    for (const auto& [validator, total] : validator_total_stake_) {
        validator_tiers_[validator] = tier_from_stake(total);
    }
}

} // namespace omnibus::validator