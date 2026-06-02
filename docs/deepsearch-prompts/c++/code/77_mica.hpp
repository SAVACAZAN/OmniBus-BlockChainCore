// OEP-1 73/150 | path=include/omnibus/identity/ns.hpp | proj=omnibus-node-cpp | run=2026-06-01-cpp-v1
#pragma once
#include "../types.hpp"
#include <string>
#include <map>
#include <optional>

namespace omnibus::identity {

// Name Service: .omnibus and .arbitraje domains
enum class NSExtension : u8 {
    OMNIBUS = 0,
    ARBITRAJE = 1
};

struct NSRecord {
    std::string name;
    NSExtension ext;
    Hash160 owner;
    std::string target; // resolved address or IPFS hash
    u64 registered_at;
    u64 expires_at;
    u32 renewals;
};

class NameService {
    std::map<std::string, NSRecord> records_;
    static constexpr u64 REGISTER_FEE_OMNI = 100; // 100 OMNI
    static constexpr u64 TRANSFER_FEE_OMNI = 10;  // 10 OMNI
    static constexpr u64 RENEWAL_FEE_OMNI = 50;   // 50 OMNI
    static constexpr u64 DEFAULT_VALIDITY_DAYS = 365;
    
public:
    bool register_name(const std::string& full_name, const Hash160& owner, u64 fee_paid);
    bool transfer_name(const std::string& full_name, const Hash160& new_owner, const Hash160& caller, u64 fee_paid);
    std::optional<std::string> resolve(const std::string& full_name) const;
    std::optional<NSRecord> get_record(const std::string& full_name) const;
    bool renew_name(const std::string& full_name, const Hash160& owner, u64 fee_paid);
};

} // namespace omnibus::identity