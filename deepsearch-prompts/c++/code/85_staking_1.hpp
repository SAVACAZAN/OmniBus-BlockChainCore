// OEP-1 81/150 | path=include/omnibus/validator/set.hpp | proj=omnibus-node-cpp | run=2026-06-01-cpp-v1
#pragma once
#include "../types.hpp"
#include "tier.hpp"
#include <vector>
#include <set>

namespace omnibus::validator {

struct ValidatorInfo {
    Hash160 address;
    ValidatorTier tier;
    u64 total_stake;
    u64 commission_bps; // basis points
    std::vector<u8> pubkey;
    bool active;
    u32 active_since_height;
};

class ValidatorSet {
    std::map<Hash160, ValidatorInfo> validators_;
    std::vector<Hash160> active_validators_;
    static constexpr size_t MAX_VALIDATORS = 100;
    
public:
    bool register_validator(const ValidatorInfo& info);
    bool unregister_validator(const Hash160& address);
    bool activate_validator(const Hash160& address, u32 height);
    bool deactivate_validator(const Hash160& address);
    std::optional<ValidatorInfo> get_validator(const Hash160& address) const;
    const std::vector<Hash160>& get_active_validators() const { return active_validators_; }
    void update_active_set();
    size_t get_active_count() const { return active_validators_.size(); }
};

} // namespace omnibus::validator