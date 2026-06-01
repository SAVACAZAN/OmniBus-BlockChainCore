#pragma once
#include "consensus/block.hpp"
#include "types.hpp"
#include <map>

namespace omnibus {

struct GuardianRule {
    std::string name;
    bool enabled;
    u32 max_block_size_percent;
    u32 max_tx_size_bytes;
    u32 min_relay_fee_rate;
    bool require_2fa_for_large_tx;
    u64 large_tx_threshold;
    std::vector<Hash160> trusted_guardians;
};

struct TwoFactorAuth {
    Hash160 account;
    Hash160 guardian;
    u64 request_time;
    u64 expiry_time;
    std::vector<u8> signature;
    bool approved;
};

class Guardian {
    GuardianRule rules_;
    std::map<Hash160, std::vector<TwoFactorAuth>> pending_2fa_;
    
public:
    void set_rules(const GuardianRule& rules);
    bool check_block(const consensus::Block& block) const;
    bool check_transaction(const storage::CompactTransaction& tx) const;
    bool request_2fa(const Hash160& account, const Hash160& guardian);
    bool approve_2fa(const Hash160& account, const Hash160& guardian, const std::vector<u8>& signature);
    bool is_2fa_approved(const Hash160& account, const Hash256& txid) const;
    void cleanup_expired_requests(u64 current_time);
};

} // namespace omnibus