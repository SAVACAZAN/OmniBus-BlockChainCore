// OEP-1 127/150 | path=src/shard/metachain.cpp | proj=omnibus-node-cpp | run=2026-06-01-cpp-v1
#include "../../include/omnibus/shard/metachain.hpp"
#include "../../include/omnibus/crypto/sha256.hpp"
#include <spdlog/spdlog.h>

namespace omnibus::shard {

bool Metachain::add_metablock(const MetaBlock& block) {
    // Verify previous hash
    if (!chain_.empty()) {
        if (block.prev_hash != chain_.back().hash()) {
            return false;
        }
    }
    
    chain_.push_back(block);
    spdlog::info("Metablock added at height {}", block.height);
    return true;
}

std::optional<MetaBlock> Metachain::get_metablock(u32 height) const {
    if (height < chain_.size()) {
        return chain_[height];
    }
    return std::nullopt;
}

Hash256 Metachain::get_shard_root(u32 height, u32 shard_id) const {
    auto block = get_metablock(height);
    if (block && shard_id < block->shard_roots.size()) {
        return block->shard_roots[shard_id];
    }
    return Hash256{};
}

bool Metachain::verify_cross_shard_tx(const Hash256& txid, u32 from_shard, u32 to_shard) const {
    // Would verify merkle proof from source shard
    spdlog::debug("Verifying cross-shard tx: {}", txid.data());
    return true;
}

} // namespace omnibus::shard