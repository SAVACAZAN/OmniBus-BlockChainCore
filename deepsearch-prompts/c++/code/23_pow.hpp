// OEP-1 19/33 | path=include/omnibus/consensus/finality.hpp | proj=omnibus-node-cpp | run=2026-06-01-cpp-v1
#pragma once
#include "../types.hpp"
#include <vector>
#include <map>

namespace omnibus::consensus {

struct Attestation {
    u32 epoch;
    u32 slot;
    Hash256 block_root;
    std::vector<u8> validator_signature; // aggregated
};

struct Checkpoint {
    u32 epoch;
    Hash256 root;
    u64 total_stake;
};

class FinalityGadget {
    std::map<u32, Checkpoint> checkpoints; // epoch -> checkpoint
    std::vector<Attestation> pending_attestations;
public:
    void add_attestation(const Attestation& att);
    bool finalize_epoch(u32 epoch, u64 total_active_stake);
    std::optional<Checkpoint> last_finalized() const;
};

} // namespace omnibus::consensus