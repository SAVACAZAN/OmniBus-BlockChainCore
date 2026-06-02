// OEP-1 16/33 | path=include/omnibus/consensus/sub_block.hpp | proj=omnibus-node-cpp | run=2026-06-01-cpp-v1
#pragma once
#include "../types.hpp"
#include "../storage/compact_tx.hpp"
#include <vector>

namespace omnibus::consensus {

struct SubBlock {
    u32 index;               // 0..SUB_BLOCKS_PER_BLOCK-1
    u64 timestamp_ms;
    Hash256 prev_hash;       // previous sub‑block hash or block hash
    Hash256 key_block_hash;  // if non-zero, this sub‑block contains a KeyBlock
    std::vector<storage::CompactTransaction> txs;

    Hash256 hash() const;
    bool is_key_block() const { return key_block_hash != Hash256{}; }
};

struct KeyBlock : public SubBlock {
    // Additional validator set update data serialized after txs
    std::vector<u8> validator_set_data;
};

// Pacing: 10 sub‑blocks per block, 40 ms interval
inline u64 sub_block_target_time_ms(u32 sub_idx) {
    return sub_idx * SUB_BLOCK_INTERVAL_MS;
}

} // namespace omnibus::consensus