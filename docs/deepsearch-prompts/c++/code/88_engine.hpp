// OEP-1 84/150 | path=include/omnibus/mining/pool.hpp | proj=omnibus-node-cpp | run=2026-06-01-cpp-v1
#pragma once
#include "../types.hpp"
#include "engine.hpp"
#include <map>
#include <vector>

namespace omnibus::mining {

struct MiningShare {
    Hash256 block_hash;
    Hash160 miner;
    u32 nonce;
    u64 timestamp;
    u32 difficulty;
    bool is_valid;
};

struct MinerStats {
    Hash160 address;
    u64 shares_submitted;
    u64 valid_shares;
    u64 total_hashrate;
    u64 unpaid_reward;
    u64 last_share_time;
};

class MiningPool {
    std::shared_ptr<MiningEngine> engine_;
    std::map<Hash160, MinerStats> miners_;
    std::vector<MiningShare> share_history_;
    
    static constexpr u64 SHARE_DIFFICULTY_TARGET = 0x1d0fffff; // Lower difficulty for shares
    static constexpr u32 POOL_FEE_BPS = 50; // 0.5%
    
public:
    explicit MiningPool(std::shared_ptr<MiningEngine> engine);
    
    bool submit_share(const MiningShare& share);
    MinerStats get_miner_stats(const Hash160& miner) const;
    std::vector<MinerStats> get_top_miners(size_t count) const;
    void distribute_rewards(const consensus::Block& block);
    u64 calculate_payout(const Hash160& miner, u64 total_valid_shares) const;
};

} // namespace omnibus::mining