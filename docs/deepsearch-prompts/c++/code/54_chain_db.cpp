// OEP-1 50/150 | path=src/storage/state_trie.cpp | proj=omnibus-node-cpp | run=2026-06-01-cpp-v1
#include "../../include/omnibus/storage/state_trie.hpp"
#include "../../include/omnibus/crypto/sha256.hpp"
#include <algorithm>

namespace omnibus::storage {

Hash256 StateTrie::hash_node(const Node& node) const {
    std::vector<u8> buf;
    for (const auto& [k, v] : node.children) {
        buf.push_back(k);
        buf.insert(buf.end(), v.begin(), v.end());
    }
    if (!node.value.empty()) {
        buf.insert(buf.end(), node.value.begin(), node.value.end());
    }
    return crypto::sha256(buf);
}

void StateTrie::insert(const std::vector<u8>& key, const std::vector<u8>& value) {
    Node node;
    node.value = value;
    node.is_leaf = true;
    
    // Simplified: just store as a single node
    Hash256 node_hash = hash_node(node);
    nodes[node_hash] = node;
    root = node_hash;
}

std::optional<std::vector<u8>> StateTrie::get(const std::vector<u8>& key) const {
    // Simplified: linear search
    for (const auto& [hash, node] : nodes) {
        if (node.value == key) return node.value;
    }
    return std::nullopt;
}

Hash256 StateTrie::commit() {
    return root;
}

} // namespace omnibus::storage