#include "../../include/omnibus/dex/htlc.hpp"
#include "../../include/omnibus/crypto/sha256.hpp"
#include <spdlog/spdlog.h>

namespace omnibus::dex {

bool SwapRegistry::create_swap(const HTLC& swap) {
    if (swaps_.find(swap.swap_id) != swaps_.end()) {
        return false;
    }
    swaps_[swap.swap_id] = swap;
    spdlog::debug("Created HTLC swap: {}", omnibus::to_hex(swap.swap_id));
    return true;
}

bool SwapRegistry::lock_both(const Hash256& swap_id, const Hash256& counterparty_preimage_hash) {
    auto it = swaps_.find(swap_id);
    if (it == swaps_.end()) return false;
    
    if (it->second.state != HtlcState::INIT) return false;
    
    // In a real implementation, would verify counterparty lock tx
    it->second.state = HtlcState::BOTH_LOCKED;
    return true;
}

bool SwapRegistry::claim(const Hash256& swap_id, const std::vector<u8>& preimage) {
    auto it = swaps_.find(swap_id);
    if (it == swaps_.end()) return false;
    
    auto preimage_hash = crypto::sha256(preimage);
    if (preimage_hash != it->second.preimage_hash) {
        return false;
    }
    
    it->second.preimage = preimage;
    it->second.state = HtlcState::CLAIMED;
    preimages_[preimage_hash] = preimage;
    
    spdlog::info("HTLC claim successful: {}", omnibus::to_hex(swap_id));
    return true;
}

bool SwapRegistry::timeout(const Hash256& swap_id, u32 current_height) {
    auto it = swaps_.find(swap_id);
    if (it == swaps_.end()) return false;
    
    if (it->second.state != HtlcState::BOTH_LOCKED && it->second.state != HtlcState::INIT) {
        return false;
    }
    
    if (current_height < it->second.locktime) {
        return false; // Not yet timed out
    }
    
    it->second.state = HtlcState::TIMED_OUT;
    spdlog::info("HTLC timed out: {}", omnibus::to_hex(swap_id));
    return true;
}

std::optional<std::vector<u8>> SwapRegistry::revealed_preimage(const Hash256& preimage_hash) const {
    auto it = preimages_.find(preimage_hash);
    if (it != preimages_.end()) {
        return it->second;
    }
    return std::nullopt;
}

std::optional<HTLC> SwapRegistry::get_swap(const Hash256& swap_id) const {
    auto it = swaps_.find(swap_id);
    if (it != swaps_.end()) {
        return it->second;
    }
    return std::nullopt;
}

} // namespace omnibus::dex