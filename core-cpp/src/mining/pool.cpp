#include "../../include/omnibus/mining/pool.hpp"
#include <spdlog/spdlog.h>

namespace omnibus::mining {

MiningPool::MiningPool(std::shared_ptr<MiningEngine> engine) : engine_(engine) {}

bool MiningPool::submit_share(const MiningShare& share) {
    // Validate share
    if (!share.is_valid) return false;
    
    auto& stats = miners_[share.miner];
    stats.shares_submitted++;
    stats.valid_shares++;
    stats.total_hashrate = stats.valid_shares * 1000000; // Simplified
    stats.last_share_time = share.timestamp;
    
    share_history_.push_back(share);
    if (share_history_.size() > 10000) {
        share_history_.erase(share_history_.begin());
    }
    
    spdlog::debug("Share submitted by miner {}", omnibus::to_hex(share.miner));
    return true;
}

MinerStats MiningPool::get_miner_stats(const Hash160& miner) const {
    auto it = miners_.find(miner);
    if (it != miners_.end()) {
        return it->second;
    }
    return MinerStats{miner, 0, 0, 0, 0, 0};
}

std::vector<MinerStats> MiningPool::get_top_miners(size_t count) const {
    std::vector<MinerStats> all;
    for (const auto& [addr, stats] : miners_) {
        all.push_back(stats);
    }
    
    std::sort(all.begin(), all.end(),
        [](const MinerStats& a, const MinerStats& b) {
            return a.valid_shares > b.valid_shares;
        });
    
    if (all.size() > count) {
        all.resize(count);
    }
    return all;
}

void MiningPool::distribute_rewards(const consensus::Block& block) {
    u64 total_valid = 0;
    for (const auto& [addr, stats] : miners_) {
        total_valid += stats.valid_shares;
    }
    
    if (total_valid == 0) return;
    
    u64 block_reward = consensus::BLOCK_REWARD_SAT;
    u64 pool_fee = (block_reward * POOL_FEE_BPS) / 10000;
    u64 to_distribute = block_reward - pool_fee;
    
    for (auto& [addr, stats] : miners_) {
        u64 reward = calculate_payout(addr, total_valid);
        stats.unpaid_reward += reward;
        spdlog::debug("Miner {} earned reward: {}", omnibus::to_hex(addr), reward);
    }
}

u64 MiningPool::calculate_payout(const Hash160& miner, u64 total_valid_shares) const {
    auto it = miners_.find(miner);
    if (it == miners_.end()) return 0;
    
    u64 block_reward = consensus::BLOCK_REWARD_SAT;
    u64 pool_fee = (block_reward * POOL_FEE_BPS) / 10000;
    u64 to_distribute = block_reward - pool_fee;
    
    return (it->second.valid_shares * to_distribute) / total_valid_shares;
}

} // namespace omnibus::mining