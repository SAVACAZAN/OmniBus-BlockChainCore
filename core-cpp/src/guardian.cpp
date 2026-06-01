#include "../include/omnibus/guardian.hpp"
#include <spdlog/spdlog.h>

namespace omnibus {

void Guardian::set_rules(const GuardianRule& rules) {
    rules_ = rules;
    spdlog::info("Guardian rules updated");
}

bool Guardian::check_block(const consensus::Block& block) const {
    // Check block size
    std::vector<u8> serialized;
    for (const auto& tx : block.txs) {
        auto tx_serialized = tx.serialize();
        serialized.insert(serialized.end(), tx_serialized.begin(), tx_serialized.end());
    }
    
    u32 max_size = (consensus::MAX_BLOCK_SIZE_BYTES * rules_.max_block_size_percent) / 100;
    if (serialized.size() > max_size) {
        spdlog::warn("Block size {} exceeds limit {}", serialized.size(), max_size);
        return false;
    }
    
    // Check each transaction
    for (const auto& tx : block.txs) {
        auto tx_serialized = tx.serialize();
        if (tx_serialized.size() > rules_.max_tx_size_bytes) {
            spdlog::warn("Transaction size {} exceeds limit", tx_serialized.size());
            return false;
        }
    }
    
    return true;
}

bool Guardian::check_transaction(const storage::CompactTransaction& tx) const {
    auto tx_serialized = tx.serialize();
    if (tx_serialized.size() > rules_.max_tx_size_bytes) {
        return false;
    }
    
    // Check fee rate (simplified)
    u64 value = tx.total_output_value();
    // Would need to check fee vs size
    
    return true;
}

bool Guardian::request_2fa(const Hash160& account, const Hash160& guardian) {
    TwoFactorAuth auth;
    auth.account = account;
    auth.guardian = guardian;
    auth.request_time = std::time(nullptr);
    auth.expiry_time = auth.request_time + 3600; // 1 hour expiry
    auth.approved = false;
    
    pending_2fa_[account].push_back(auth);
    spdlog::info("2FA requested for account {} from guardian {}", omnibus::to_hex(account), omnibus::to_hex(guardian));
    return true;
}

bool Guardian::approve_2fa(const Hash160& account, const Hash160& guardian, const std::vector<u8>& signature) {
    auto it = pending_2fa_.find(account);
    if (it == pending_2fa_.end()) return false;
    
    for (auto& auth : it->second) {
        if (auth.guardian == guardian && !auth.approved) {
            auth.signature = signature;
            auth.approved = true;
            spdlog::info("2FA approved for account {}", omnibus::to_hex(account));
            return true;
        }
    }
    
    return false;
}

bool Guardian::is_2fa_approved(const Hash160& account, const Hash256& txid) const {
    auto it = pending_2fa_.find(account);
    if (it == pending_2fa_.end()) return false;
    
    for (const auto& auth : it->second) {
        if (auth.approved) {
            return true;
        }
    }
    
    return false;
}

void Guardian::cleanup_expired_requests(u64 current_time) {
    for (auto& [account, requests] : pending_2fa_) {
        requests.erase(
            std::remove_if(requests.begin(), requests.end(),
                [current_time](const TwoFactorAuth& auth) {
                    return auth.expiry_time < current_time;
                }),
            requests.end());
    }
    
    // Remove empty entries
    for (auto it = pending_2fa_.begin(); it != pending_2fa_.end();) {
        if (it->second.empty()) {
            it = pending_2fa_.erase(it);
        } else {
            ++it;
        }
    }
}

} // namespace omnibus