// OEP-1 86/150 | path=include/omnibus/light/spv.hpp | proj=omnibus-node-cpp | run=2026-06-01-cpp-v1
#pragma once
#include "../types.hpp"
#include "../consensus/block.hpp"
#include <vector>

namespace omnibus::light {

// Simplified SPV block header (124 bytes)
struct SpvBlockHeader {
    u32 version;
    Hash256 prev_block;
    Hash256 merkle_root;
    u32 timestamp;
    u32 bits;
    u32 nonce;
    Hash256 hash; // computed
};

struct SpvProof {
    Hash256 txid;
    std::vector<Hash256> merkle_branch;
    u32 branch_index;
    SpvBlockHeader header;
    
    bool verify() const;
};

class SPVClient {
    std::vector<SpvBlockHeader> headers_;
    std::vector<Hash256> filter_hashes_; // bloom filter hashes for relevant tx
    
public:
    void add_header(const SpvBlockHeader& header);
    bool verify_transaction(const SpvProof& proof) const;
    void set_filter(const std::vector<Hash256>& filter);
    u32 get_best_height() const { return static_cast<u32>(headers_.size()) - 1; }
    SpvBlockHeader get_header(u32 height) const;
};

} // namespace omnibus::light