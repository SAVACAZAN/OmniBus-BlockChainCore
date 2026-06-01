#pragma once
#include "../types.hpp"
#include "../crypto/sha256.hpp"
#include "../codec.hpp"
#include "coordinator.hpp"
#include <vector>

namespace omnibus::shard {

struct MetaBlock {
    u32 version;
    u32 height;
    Hash256 prev_hash;
    std::vector<Hash256> shard_roots; // 4 shard state roots
    std::vector<Hash256> cross_shard_txs;
    u32 timestamp;
    std::vector<u8> validator_signature;

    Hash256 hash() const {
        std::vector<u8> buf;
        codec::write_le(version, buf);
        codec::write_le(height, buf);
        buf.insert(buf.end(), prev_hash.begin(), prev_hash.end());
        codec::write_le(timestamp, buf);
        return crypto::sha256d(buf);
    }
};

class Metachain {
    std::vector<MetaBlock> chain_;
    ShardCoordinator coordinator_;
    
public:
    bool add_metablock(const MetaBlock& block);
    std::optional<MetaBlock> get_metablock(u32 height) const;
    Hash256 get_shard_root(u32 height, u32 shard_id) const;
    bool verify_cross_shard_tx(const Hash256& txid, u32 from_shard, u32 to_shard) const;
    u32 current_height() const { return static_cast<u32>(chain_.size()); }
};

} // namespace omnibus::shard