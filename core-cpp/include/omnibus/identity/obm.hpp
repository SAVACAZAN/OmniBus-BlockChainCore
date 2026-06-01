#pragma once
#include "../types.hpp"
#include <array>
#include <bitset>

namespace omnibus::identity {

// OBM (OmniBadge) - 1 byte, 8 positions
class BadgeSet {
    std::bitset<8> badges_;
    
public:
    static constexpr u32 BADGE_THRESHOLD = 5000; // 5000 OMNI required for badge
    
    bool has_badge(u8 pos) const { return pos < 8 && badges_.test(pos); }
    void set_badge(u8 pos, bool value) { if (pos < 8) badges_.set(pos, value); }
    u8 to_byte() const { return static_cast<u8>(badges_.to_ulong()); }
    void from_byte(u8 b) { badges_ = std::bitset<8>(b); }
    
    // Badge positions (customizable per implementation)
    static constexpr u8 BADGE_VERIFIED = 0;
    static constexpr u8 BADGE_KYC = 1;
    static constexpr u8 BADGE_STAKER = 2;
    static constexpr u8 BADGE_VALIDATOR = 3;
    static constexpr u8 BADGE_DEVELOPER = 4;
    static constexpr u8 BADGE_EARLY_ADOPTER = 5;
    static constexpr u8 BADGE_WHALE = 6;
    static constexpr u8 BADGE_GENESIS = 7;
};

} // namespace omnibus::identity