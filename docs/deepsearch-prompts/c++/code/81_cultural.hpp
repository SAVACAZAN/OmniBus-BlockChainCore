// OEP-1 77/150 | path=include/omnibus/identity/facets/economic.hpp | proj=omnibus-node-cpp | run=2026-06-01-cpp-v1
#pragma once
#include "../../types.hpp"
#include <string>
#include <vector>

namespace omnibus::identity::facets {

struct EconomicActivity {
    Hash160 user;
    u64 timestamp;
    std::string activity_type; // "trade", "staking", "mining", "governance"
    u64 volume;
    u64 fee_paid;
    Hash256 txid;
};

class EconomicFacet {
    std::map<Hash160, std::vector<EconomicActivity>> activities_;
    
public:
    void record_activity(const EconomicActivity& activity);
    std::vector<EconomicActivity> get_activities(const Hash160& user, u64 from_time, u64 to_time) const;
    u64 calculate_total_volume(const Hash160& user, const std::string& activity_type) const;
};

} // namespace omnibus::identity::facets