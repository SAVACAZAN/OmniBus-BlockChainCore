#pragma once
#include "../types.hpp"
#include <string>
#include <optional>

namespace omnibus::identity {

// MiCA (Markets in Crypto-Assets) reporting v1
struct MicaReport {
    std::string report_id;
    u64 timestamp;
    Hash160 issuer;
    std::string canonical_json; // JSON string with deterministic ordering
    std::vector<u8> signature;
    
    Hash256 pre_hash() const;
    bool verify() const;
};

class MicaReporter {
    std::map<std::string, MicaReport> reports_;
    
public:
    bool submit_report(const MicaReport& report);
    std::optional<MicaReport> get_report(const std::string& report_id) const;
    std::vector<MicaReport> get_reports_by_issuer(const Hash160& issuer, u64 from_time, u64 to_time) const;
};

} // namespace omnibus::identity