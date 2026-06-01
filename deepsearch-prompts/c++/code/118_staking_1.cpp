// OEP-1 114/150 | path=src/validator/set.cpp | proj=omnibus-node-cpp | run=2026-06-01-cpp-v1
#include "../../include/omnibus/validator/set.hpp"
#include <algorithm>
#include <spdlog/spdlog.h>

namespace omnibus::validator {

bool ValidatorSet::register_validator(const ValidatorInfo& info) {
    if (validators_.find(info.address) != validators_.end()) {
        return false;
    }
    
    validators_[info.address] = info;
    spdlog::info("Validator registered: {}", info.address.data());
    update_active_set();
    return true;
}

bool ValidatorSet::unregister_validator(const Hash160& address) {
    auto it = validators_.find(address);
    if (it == validators_.end()) return false;
    
    validators_.erase(it);
    spdlog::info("Validator unregistered: {}", address.data());
    update_active_set();
    return true;
}

bool ValidatorSet::activate_validator(const Hash160& address, u32 height) {
    auto it = validators_.find(address);
    if (it == validators_.end()) return false;
    
    it->second.active = true;
    it->second.active_since_height = height;
    spdlog::info("Validator activated: {}", address.data());
    update_active_set();
    return true;
}

bool ValidatorSet::deactivate_validator(const Hash160& address) {
    auto it = validators_.find(address);
    if (it == validators_.end()) return false;
    
    it->second.active = false;
    spdlog::info("Validator deactivated: {}", address.data());
    update_active_set();
    return true;
}

std::optional<ValidatorInfo> ValidatorSet::get_validator(const Hash160& address) const {
    auto it = validators_.find(address);
    if (it != validators_.end()) {
        return it->second;
    }
    return std::nullopt;
}

void ValidatorSet::update_active_set() {
    active_validators_.clear();
    
    std::vector<std::pair<u64, Hash160>> sorted;
    for (const auto& [addr, info] : validators_) {
        if (info.active) {
            sorted.emplace_back(info.total_stake, addr);
        }
    }
    
    // Sort by stake (highest first)
    std::sort(sorted.begin(), sorted.end(),
        [](const auto& a, const auto& b) { return a.first > b.first; });
    
    for (size_t i = 0; i < std::min(sorted.size(), MAX_VALIDATORS); ++i) {
        active_validators_.push_back(sorted[i].second);
    }
}

} // namespace omnibus::validator