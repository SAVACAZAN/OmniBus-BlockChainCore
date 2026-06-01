// OEP-1 71/150 | path=include/omnibus/identity/kyc.hpp | proj=omnibus-node-cpp | run=2026-06-01-cpp-v1
#pragma once
#include "../types.hpp"
#include "manifest.hpp"
#include <string>
#include <optional>

namespace omnibus::identity {

enum class KYCLevel : u8 {
    NONE = 0,
    TIER_1 = 1, // Basic (email + phone)
    TIER_2 = 2, // ID verification
    TIER_3 = 3  // Address proof + enhanced
};

struct KYCRecord {
    Hash160 user;
    KYCLevel level;
    u64 verified_at;
    u64 expires_at;
    Manifest manifest;
    std::vector<u8> issuer_signature;
};

class KYCManager {
    std::map<Hash160, KYCRecord> records_;
    
public:
    bool submit_kyc(const Hash160& user, const Manifest& manifest, KYCLevel requested);
    bool verify_kyc(const Hash160& user, KYCLevel level, const std::vector<u8>& issuer_sig);
    std::optional<KYCLevel> get_kyc_level(const Hash160& user) const;
    bool is_kyc_valid(const Hash160& user) const;
    void expire_kyc(u64 current_time);
};

} // namespace omnibus::identity