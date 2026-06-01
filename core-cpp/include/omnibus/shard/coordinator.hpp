#pragma once
#include "../types.hpp"
#include "../crypto/sha256.hpp"
#include <vector>
#include <map>

namespace omnibus::shard {

constexpr size_t NUM_SHARDS = 4;

inline u32 get_shard_id(const Hash160& address) {
    auto hash = crypto::sha256(address.data(), address.size());
    return hash[0] % NUM_SHARDS;
}

inline u32 get_shard_id(const std::string& address) {
    // Simplified: hash the string
    auto hash = crypto::sha256(reinterpret_cast<const u8*>(address.c_str()), address.size());
    return hash[0] % NUM_SHARDS;
}

struct ShardInfo {
    u32 shard_id;
    std::vector<Hash160> validators;
    u64 total_stake;
    Hash256 latest_block_hash;
    u32 latest_height;
};

class ShardCoordinator {
    std::map<u32, ShardInfo> shards_;
    
public:
    ShardInfo& get_shard(u32 shard_id);
    void assign_validator(u32 shard_id, const Hash160& validator);
    void remove_validator(u32 shard_id, const Hash160& validator);
    void update_shard_head(u32 shard_id, const Hash256& block_hash, u32 height);
    bool cross_shard_transfer(u32 from_shard, u32 to_shard, const Hash256& txid);
};

} // namespace omnibus::shard