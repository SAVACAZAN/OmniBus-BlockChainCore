// OEP-1 126/150 | path=src/shard/coordinator.cpp | proj=omnibus-node-cpp | run=2026-06-01-cpp-v1
#include "../../include/omnibus/shard/coordinator.hpp"
#include <spdlog/spdlog.h>

namespace omnibus::shard {

ShardInfo& ShardCoordinator::get_shard(u32 shard_id) {
    if (shards_.find(shard_id) == shards_.end()) {
        ShardInfo info;
        info.shard_id = shard_id;
        shards_[shard_id] = info;
    }
    return shards_[shard_id];
}

void ShardCoordinator::assign_validator(u32 shard_id, const Hash160& validator) {
    auto& shard = get_shard(shard_id);
    if (std::find(shard.validators.begin(), shard.validators.end(), validator) == shard.validators.end()) {
        shard.validators.push_back(validator);
        spdlog::info("Validator {} assigned to shard {}", validator.data(), shard_id);
    }
}

void ShardCoordinator::remove_validator(u32 shard_id, const Hash160& validator) {
    auto& shard = get_shard(shard_id);
    auto it = std::find(shard.validators.begin(), shard.validators.end(), validator);
    if (it != shard.validators.end()) {
        shard.validators.erase(it);
        spdlog::info("Validator {} removed from shard {}", validator.data(), shard_id);
    }
}

void ShardCoordinator::update_shard_head(u32 shard_id, const Hash256& block_hash, u32 height) {
    auto& shard = get_shard(shard_id);
    shard.latest_block_hash = block_hash;
    shard.latest_height = height;
}

bool ShardCoordinator::cross_shard_transfer(u32 from_shard, u32 to_shard, const Hash256& txid) {
    spdlog::info("Cross-shard transfer from {} to {}, txid: {}", from_shard, to_shard, txid.data());
    return true;
}

} // namespace omnibus::shard