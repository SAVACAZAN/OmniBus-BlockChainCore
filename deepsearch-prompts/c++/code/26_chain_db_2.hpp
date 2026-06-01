// OEP-1 22/33 | path=include/omnibus/storage/state_trie.hpp | proj=omnibus-node-cpp | run=2026-06-01-cpp-v1
#pragma once
#include "../types.hpp"
#include <map>
#include <vector>
#include <optional>

namespace omnibus::storage {

// Simple Merkle Patricia Trie for account state (like Ethereum)
class StateTrie {
    struct Node {
        std::map<u8, Hash256> children;
        std::vector<u8> value;
        bool is_leaf = false;
    };
    std::map<Hash256, Node> nodes;
    Hash256 root;

    Hash256 hash_node(const Node& node) const;
public:
    void insert(const std::vector<u8>& key, const std::vector<u8>& value);
    std::optional<std::vector<u8>> get(const std::vector<u8>& key) const;
    Hash256 commit();
    Hash256 root_hash() const { return root; }
};

} // namespace omnibus::storage