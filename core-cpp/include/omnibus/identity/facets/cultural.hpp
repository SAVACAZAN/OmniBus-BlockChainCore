#pragma once
#include "../../types.hpp"
#include <string>
#include <vector>

namespace omnibus::identity::facets {

struct CulturalBadge {
    Hash160 user;
    std::string badge_type; // "artist", "collector", "curator", "patron"
    u64 awarded_at;
    std::string metadata_uri;
    Hash160 awarding_entity;
    std::vector<u8> signature;
};

class CulturalFacet {
    std::map<Hash160, std::vector<CulturalBadge>> badges_;
    
public:
    bool award_badge(const CulturalBadge& badge);
    bool revoke_badge(const Hash160& user, const std::string& badge_type);
    std::vector<CulturalBadge> get_badges(const Hash160& user) const;
    bool has_badge(const Hash160& user, const std::string& badge_type) const;
};

} // namespace omnibus::identity::facets