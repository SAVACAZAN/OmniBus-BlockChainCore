#include "../../include/omnibus/identity/kyc.hpp"
#include <spdlog/spdlog.h>

namespace omnibus::identity {

bool KYCManager::submit_kyc(const Hash160& user, const Manifest& manifest, KYCLevel requested) {
    // Validate manifest
    auto root = manifest.root();
    if (root == Hash256{}) return false;
    
    KYCRecord record;
    record.user = user;
    record.level = requested;
    record.verified_at = 0; // Not yet verified
    record.expires_at = 0;
    record.manifest = manifest;
    
    records_[user] = record;
    spdlog::info("KYC submitted for user {}", omnibus::to_hex(user));
    return true;
}

bool KYCManager::verify_kyc(const Hash160& user, KYCLevel level, const std::vector<u8>& issuer_sig) {
    auto it = records_.find(user);
    if (it == records_.end()) return false;
    
    if (level < it->second.level) return false;
    
    it->second.level = level;
    it->second.verified_at = std::time(nullptr);
    it->second.expires_at = it->second.verified_at + 365 * 86400; // 1 year
    it->second.issuer_signature = issuer_sig;
    
    spdlog::info("KYC verified for user {} at level {}", omnibus::to_hex(user), static_cast<int>(level));
    return true;
}

std::optional<KYCLevel> KYCManager::get_kyc_level(const Hash160& user) const {
    auto it = records_.find(user);
    if (it != records_.end() && is_kyc_valid(user)) {
        return it->second.level;
    }
    return std::nullopt;
}

bool KYCManager::is_kyc_valid(const Hash160& user) const {
    auto it = records_.find(user);
    if (it == records_.end()) return false;
    
    u64 now = std::time(nullptr);
    if (it->second.expires_at > 0 && now > it->second.expires_at) {
        return false;
    }
    
    return it->second.verified_at > 0;
}

void KYCManager::expire_kyc(u64 current_time) {
    for (auto& [user, record] : records_) {
        if (record.expires_at > 0 && current_time > record.expires_at) {
            record.level = KYCLevel::NONE;
            record.verified_at = 0;
            spdlog::debug("KYC expired for user {}", omnibus::to_hex(user));
        }
    }
}

} // namespace omnibus::identity