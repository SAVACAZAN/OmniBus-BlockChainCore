// OEP-1 74/150 | path=include/omnibus/identity/facets/social.hpp | proj=omnibus-node-cpp | run=2026-06-01-cpp-v1
#pragma once
#include "../../types.hpp"
#include <string>
#include <vector>

namespace omnibus::identity::facets {

struct SocialProfile {
    Hash160 user;
    std::string platform; // "twitter", "github", "linkedin"
    std::string username;
    std::string proof_url; // verification link
    u64 verified_at;
    std::vector<u8> signature;
};

class SocialFacet {
    std::map<Hash160, std::vector<SocialProfile>> profiles_;
    
public:
    bool add_profile(const SocialProfile& profile);
    bool verify_profile(const SocialProfile& profile);
    std::vector<SocialProfile> get_profiles(const Hash160& user) const;
    bool remove_profile(const Hash160& user, const std::string& platform);
};

} // namespace omnibus::identity::facets