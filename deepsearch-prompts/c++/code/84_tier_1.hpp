// OEP-1 80/150 | path=include/omnibus/validator/staking.hpp | proj=omnibus-node-cpp | run=2026-06-01-cpp-v1
#pragma once
#include "../types.hpp"
#include "tier.hpp"
#include <map>

namespace omnibus::validator {

struct Stake {
    Hash160 staker;
    Hash160 validator;
    u64 amount;      // in OMNI
    u64 lock_start;
    u64 lock_end;
    bool auto_restake;
};

class StakingManager {
    std::map<Hash160, std::vector<Stake>> stakes_; // staker -> stakes
    std::map<Hash160, u64> validator_total_stake_; // validator -> total stake
    std::map<Hash160, ValidatorTier> validator_tiers_;
    
public:
    bool stake(const Stake& stake);
    bool unstake(const Hash160& staker, const Hash160& validator, u64 amount);
    bool claim_rewards(const Hash160& staker, const Hash160& validator);
    u64 get_total_stake(const Hash160& validator) const;
    ValidatorTier get_validator_tier(const Hash160& validator) const;
    void update_tiers();
};

} // namespace omnibus::validator