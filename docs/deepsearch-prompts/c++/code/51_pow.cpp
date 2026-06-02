// OEP-1 47/150 | path=src/consensus/finality.cpp | proj=omnibus-node-cpp | run=2026-06-01-cpp-v1
#include "../../include/omnibus/consensus/finality.hpp"
#include <algorithm>

namespace omnibus::consensus {

void FinalityGadget::add_attestation(const Attestation& att) {
    pending_attestations.push_back(att);
}

bool FinalityGadget::finalize_epoch(u32 epoch, u64 total_active_stake) {
    u64 total_vote = 0;
    Hash256 target_root;
    bool has_root = false;
    
    for (const auto& att : pending_attestations) {
        if (att.epoch == epoch) {
            total_vote += 1; // Simplified: each attestation represents some stake
            if (!has_root) {
                target_root = att.block_root;
                has_root = true;
            }
        }
    }
    
    // 2/3 majority required
    if (total_vote * 3 >= total_active_stake * 2) {
        Checkpoint cp;
        cp.epoch = epoch;
        cp.root = target_root;
        cp.total_stake = total_vote;
        checkpoints[epoch] = cp;
        return true;
    }
    return false;
}

std::optional<Checkpoint> FinalityGadget::last_finalized() const {
    if (checkpoints.empty()) return std::nullopt;
    return checkpoints.rbegin()->second;
}

} // namespace omnibus::consensus