#include "../../include/omnibus/identity/manifest.hpp"
#include "../../include/omnibus/crypto/sha256.hpp"
#include <cstring>

namespace omnibus::identity {

Hash256 Manifest::root() const {
    std::vector<Hash256> hashes(leaves.begin(), leaves.end());
    
    // Build Merkle tree
    while (hashes.size() > 1) {
        if (hashes.size() % 2 == 1) {
            hashes.push_back(hashes.back());
        }
        std::vector<Hash256> next;
        for (size_t i = 0; i < hashes.size(); i += 2) {
            std::vector<u8> concat(hashes[i].begin(), hashes[i].end());
            concat.insert(concat.end(), hashes[i+1].begin(), hashes[i+1].end());
            next.push_back(crypto::sha256(concat));
        }
        hashes.swap(next);
    }
    
    return hashes.empty() ? Hash256{} : hashes[0];
}

void Manifest::set_field(FieldIndex idx, const std::string& value) {
    size_t pos = static_cast<size_t>(idx);
    if (pos >= leaves.size()) return;
    
    leaves[pos] = crypto::sha256(reinterpret_cast<const u8*>(value.c_str()), value.size());
}

std::optional<std::string> Manifest::get_field(FieldIndex idx, const Hash256& leaf_proof) const {
    size_t pos = static_cast<size_t>(idx);
    if (pos >= leaves.size()) return std::nullopt;
    
    // In real implementation, would verify proof against root
    // For demo, just return that the leaf matches
    if (leaves[pos] == leaf_proof) {
        return std::string("verified");
    }
    return std::nullopt;
}

bool Manifest::verify_proof(FieldIndex idx, const Hash256& leaf_hash, const std::vector<Hash256>& proof) const {
    size_t pos = static_cast<size_t>(idx);
    if (pos >= leaves.size()) return false;
    
    Hash256 computed = leaf_hash;
    size_t index = pos;
    
    for (const auto& sibling : proof) {
        std::vector<u8> concat;
        if (index % 2 == 0) {
            concat.insert(concat.end(), computed.begin(), computed.end());
            concat.insert(concat.end(), sibling.begin(), sibling.end());
        } else {
            concat.insert(concat.end(), sibling.begin(), sibling.end());
            concat.insert(concat.end(), computed.begin(), computed.end());
        }
        computed = crypto::sha256(concat);
        index /= 2;
    }
    
    return computed == root();
}

} // namespace omnibus::identity