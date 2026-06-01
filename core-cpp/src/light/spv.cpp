#include "../../include/omnibus/light/spv.hpp"
#include "../../include/omnibus/crypto/sha256.hpp"

namespace omnibus::light {

bool SpvProof::verify() const {
    // Compute merkle root from branch
    Hash256 computed = txid;
    size_t idx = branch_index;
    
    for (const auto& sibling : merkle_branch) {
        std::vector<u8> concat;
        if (idx % 2 == 0) {
            concat.insert(concat.end(), computed.begin(), computed.end());
            concat.insert(concat.end(), sibling.begin(), sibling.end());
        } else {
            concat.insert(concat.end(), sibling.begin(), sibling.end());
            concat.insert(concat.end(), computed.begin(), computed.end());
        }
        computed = crypto::sha256d(concat);
        idx /= 2;
    }
    
    // Check against block header merkle root
    return computed == header.merkle_root;
}

void SPVClient::add_header(const SpvBlockHeader& header) {
    headers_.push_back(header);
}

bool SPVClient::verify_transaction(const SpvProof& proof) const {
    if (proof.header.hash != proof.header.hash) return false;
    return proof.verify();
}

void SPVClient::set_filter(const std::vector<Hash256>& filter) {
    filter_hashes_ = filter;
}

SpvBlockHeader SPVClient::get_header(u32 height) const {
    if (height < headers_.size()) {
        return headers_[height];
    }
    return SpvBlockHeader{};
}

} // namespace omnibus::light