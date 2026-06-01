#include "../../include/omnibus/consensus/block.hpp"
#include "../../include/omnibus/consensus/params.hpp"

namespace omnibus::consensus {

u64 Block::total_subsidy(u32 height) const {
    u64 halvings = height / HALVING_INTERVAL;
    if (halvings >= 64) return 0;
    u64 subsidy = BLOCK_REWARD_SAT;
    subsidy >>= halvings;
    return subsidy;
}

bool Block::is_valid() const {
    if (txs.size() > MAX_BLOCK_TX) return false;
    
    // Check merkle root
    std::vector<Hash256> tx_hashes;
    for (const auto& tx : txs) {
        tx_hashes.push_back(tx.txid());
    }
    auto calc_root = compute_merkle_root(tx_hashes);
    if (calc_root != header.merkle_root) return false;
    
    // Check timestamp not in future (allow 2 hour drift)
    u32 now = static_cast<u32>(std::time(nullptr));
    if (header.timestamp > now + 7200) return false;
    
    return true;
}

} // namespace omnibus::consensus