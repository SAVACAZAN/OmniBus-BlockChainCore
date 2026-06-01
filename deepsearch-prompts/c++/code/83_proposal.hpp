// OEP-1 79/150 | path=include/omnibus/validator/tier.hpp | proj=omnibus-node-cpp | run=2026-06-01-cpp-v1
#pragma once
#include "../types.hpp"
#include <string>

namespace omnibus::validator {

enum class ValidatorTier : u8 {
    OMNI = 0,      // 100 OMNI
    LOVE = 1,      // 1,000 OMNI
    FOOD = 2,      // 10,000 OMNI
    RENT = 3,      // 100,000 OMNI
    VACATION = 4   // 500,000 OMNI
};

inline u64 tier_minimum_stake(ValidatorTier tier) {
    switch (tier) {
        case ValidatorTier::OMNI:     return 100;
        case ValidatorTier::LOVE:     return 1000;
        case ValidatorTier::FOOD:     return 10000;
        case ValidatorTier::RENT:     return 100000;
        case ValidatorTier::VACATION: return 500000;
        default: return 0;
    }
}

inline ValidatorTier tier_from_stake(u64 stake_omni) {
    if (stake_omni >= 500000) return ValidatorTier::VACATION;
    if (stake_omni >= 100000) return ValidatorTier::RENT;
    if (stake_omni >= 10000) return ValidatorTier::FOOD;
    if (stake_omni >= 1000) return ValidatorTier::LOVE;
    return ValidatorTier::OMNI;
}

} // namespace omnibus::validator