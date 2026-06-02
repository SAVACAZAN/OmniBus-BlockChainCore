// OEP-1 15/33 | path=include/omnibus/consensus/block.hpp | proj=omnibus-node-cpp | run=2026-06-01-cpp-v1
#pragma once
#include "../types.hpp"
#include "../crypto/sha256.hpp"
#include "../storage/compact_tx.hpp"
#include <vector>
#include <cstring>

namespace omnibus::consensus {

using namespace storage;

struct BlockHeader {
    u32 version;
    Hash256 prev_block;
    Hash256 merkle_root;
    u32 timestamp;
    u32 bits;
    u32 nonce;

    Hash256 hash() const {
        std::vector<u8> buf;
        codec::write_le(version, buf);
        buf.insert(buf.end(), prev_block.begin(), prev_block.end());
        buf.insert(buf.end(), merkle_root.begin(), merkle_root.end());
        codec::write_le(timestamp, buf);
        codec::write_le(bits, buf);
        codec::write_le(nonce, buf);
        return crypto::sha256d(buf);
    }
};

struct Block {
    BlockHeader header;
    std::vector<CompactTransaction> txs;

    Hash256 hash() const { return header.hash(); }
    u64 total_subsidy(u32 height) const;
    bool is_valid() const;
};

// Merkle root computation (double SHA256 of concatenated pairs)
inline Hash256 compute_merkle_root(const std::vector<Hash256>& leaves) {
    if (leaves.empty()) return Hash256{};
    std::vector<Hash256> tree = leaves;
    while (tree.size() > 1) {
        if (tree.size() % 2 == 1) tree.push_back(tree.back());
        std::vector<Hash256> next;
        for (size_t i = 0; i < tree.size(); i += 2) {
            std::vector<u8> concat(tree[i].begin(), tree[i].end());
            concat.insert(concat.end(), tree[i+1].begin(), tree[i+1].end());
            next.push_back(crypto::sha256d(concat));
        }
        tree.swap(next);
    }
    return tree[0];
}

} // namespace omnibus::consensus