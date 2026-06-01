#pragma once
#include "../types.hpp"
#include <map>
#include <vector>

namespace omnibus::validator {

struct SlashingEvent {
    Hash160 validator;
    u32 height;
    std::string reason; // "double_sign", "downtime", "liveness"
    u64 slashed_amount;
    u64 reporter_reward;
    u64 burned_amount;
};

class SlashingManager {
    std::map<Hash160, std::vector<SlashingEvent>> slash_history_;
    static constexpr u64 SLASH_MULTIPLE_SIGN = 33;  // 33% slash
    static constexpr u64 SLASH_DOWNTIME = 10;       // 10% slash
    static constexpr u64 SLASH_LIVENESS = 1;        // 1% slash
    static constexpr u64 REPORTER_REWARD_PCT = 10;  // 10% of slashed amount to reporter
    
public:
    bool report_slashing(const Hash160& reporter, const SlashingEvent& event);
    u64 calculate_slash_amount(u64 stake, const std::string& reason) const;
    std::vector<SlashingEvent> get_slash_history(const Hash160& validator) const;
    bool is_jailed(const Hash160& validator) const;
    bool unjail(const Hash160& validator, u64 fee_paid);
};

} // namespace omnibus::validator