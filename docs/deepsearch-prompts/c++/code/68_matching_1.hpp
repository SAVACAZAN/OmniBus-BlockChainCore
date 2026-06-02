// OEP-1 64/150 | path=include/omnibus/dex/htlc.hpp | proj=omnibus-node-cpp | run=2026-06-01-cpp-v1
#pragma once
#include "../types.hpp"
#include <optional>
#include <map>

namespace omnibus::dex {

enum class HtlcState : u8 {
    INIT = 0,
    BOTH_LOCKED = 1,
    CLAIMED = 2,
    TIMED_OUT = 3,
    REFUNDED = 4
};

struct HTLC {
    Hash256 swap_id;
    Hash256 preimage_hash;
    std::vector<u8> preimage; // empty until claimed
    Hash160 sender;
    Hash160 receiver;
    u64 amount;
    u32 locktime;
    HtlcState state;
};

class SwapRegistry {
    std::map<Hash256, HTLC> swaps_;
    std::map<Hash256, std::vector<u8>> preimages_; // preimage_hash -> preimage (once revealed)
    
public:
    bool create_swap(const HTLC& swap);
    bool lock_both(const Hash256& swap_id, const Hash256& counterparty_preimage_hash);
    bool claim(const Hash256& swap_id, const std::vector<u8>& preimage);
    bool timeout(const Hash256& swap_id, u32 current_height);
    std::optional<std::vector<u8>> revealed_preimage(const Hash256& preimage_hash) const;
    std::optional<HTLC> get_swap(const Hash256& swap_id) const;
};

} // namespace omnibus::dex