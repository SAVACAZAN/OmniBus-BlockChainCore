#include "../../include/omnibus/identity/ns.hpp"
#include <spdlog/spdlog.h>

namespace omnibus::identity {

bool NameService::register_name(const std::string& full_name, const Hash160& owner, u64 fee_paid) {
    // Check fee
    if (fee_paid < REGISTER_FEE_OMNI) {
        return false;
    }
    
    // Check if name already registered
    if (records_.find(full_name) != records_.end()) {
        return false;
    }
    
    NSRecord record;
    record.name = full_name;
    // Determine extension
    if (full_name.find(".omnibus") != std::string::npos) {
        record.ext = NSExtension::OMNIBUS;
    } else if (full_name.find(".arbitraje") != std::string::npos) {
        record.ext = NSExtension::ARBITRAJE;
    } else {
        return false;
    }
    record.owner = owner;
    record.registered_at = std::time(nullptr);
    record.expires_at = record.registered_at + DEFAULT_VALIDITY_DAYS * 86400;
    record.renewals = 0;
    record.target = ""; // Not yet set
    
    records_[full_name] = record;
    spdlog::info("Registered name: {}", full_name);
    return true;
}

bool NameService::transfer_name(const std::string& full_name, const Hash160& new_owner, const Hash160& caller, u64 fee_paid) {
    auto it = records_.find(full_name);
    if (it == records_.end()) return false;
    
    if (it->second.owner != caller) return false;
    
    if (fee_paid < TRANSFER_FEE_OMNI) return false;
    
    it->second.owner = new_owner;
    spdlog::info("Transferred name: {} to new owner", full_name);
    return true;
}

std::optional<std::string> NameService::resolve(const std::string& full_name) const {
    auto it = records_.find(full_name);
    if (it != records_.end() && !it->second.target.empty()) {
        return it->second.target;
    }
    return std::nullopt;
}

std::optional<NSRecord> NameService::get_record(const std::string& full_name) const {
    auto it = records_.find(full_name);
    if (it != records_.end()) {
        return it->second;
    }
    return std::nullopt;
}

bool NameService::renew_name(const std::string& full_name, const Hash160& owner, u64 fee_paid) {
    auto it = records_.find(full_name);
    if (it == records_.end()) return false;
    
    if (it->second.owner != owner) return false;
    
    if (fee_paid < RENEWAL_FEE_OMNI) return false;
    
    it->second.expires_at += DEFAULT_VALIDITY_DAYS * 86400;
    it->second.renewals++;
    spdlog::info("Renewed name: {}", full_name);
    return true;
}

} // namespace omnibus::identity