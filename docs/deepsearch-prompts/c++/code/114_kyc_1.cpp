// OEP-1 110/150 | path=src/identity/mica.cpp | proj=omnibus-node-cpp | run=2026-06-01-cpp-v1
#include "../../include/omnibus/identity/mica.hpp"
#include "../../include/omnibus/crypto/sha256.hpp"
#include "../../include/omnibus/crypto/secp256k1.hpp"
#include <nlohmann/json.hpp>

namespace omnibus::identity {

Hash256 MicaReport::pre_hash() const {
    // Create canonical JSON string with deterministic ordering
    nlohmann::json j;
    j["report_id"] = report_id;
    j["timestamp"] = timestamp;
    j["issuer"] = std::string(reinterpret_cast<const char*>(issuer.data()), issuer.size());
    j["data"] = nlohmann::json::parse(canonical_json);
    
    std::string canonical = j.dump();
    return crypto::sha256(reinterpret_cast<const u8*>(canonical.c_str()), canonical.size());
}

bool MicaReport::verify() const {
    auto hash = pre_hash();
    return crypto::secp256k1.verify(hash, 
        *reinterpret_cast<const Sig64*>(signature.data()),
        std::vector<u8>()); // Would need issuer pubkey
}

bool MicaReporter::submit_report(const MicaReport& report) {
    if (!report.verify()) {
        return false;
    }
    
    reports_[report.report_id] = report;
    return true;
}

std::optional<MicaReport> MicaReporter::get_report(const std::string& report_id) const {
    auto it = reports_.find(report_id);
    if (it != reports_.end()) {
        return it->second;
    }
    return std::nullopt;
}

std::vector<MicaReport> MicaReporter::get_reports_by_issuer(const Hash160& issuer, u64 from_time, u64 to_time) const {
    std::vector<MicaReport> result;
    for (const auto& [id, report] : reports_) {
        if (report.issuer == issuer && report.timestamp >= from_time && report.timestamp <= to_time) {
            result.push_back(report);
        }
    }
    return result;
}

} // namespace omnibus::identity