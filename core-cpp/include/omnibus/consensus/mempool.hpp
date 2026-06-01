#pragma once
#include "../storage/compact_tx.hpp"
#include <deque>
#include <unordered_map>
#include <optional>

namespace omnibus::consensus {

class Mempool {
    std::deque<storage::CompactTransaction> queue; // FIFO
    std::unordered_map<Hash256, size_t> tx_index; // txid -> position
    static constexpr size_t MAX_SIZE = 10000; // configurable

public:
    void add_transaction(const storage::CompactTransaction& tx);
    std::optional<storage::CompactTransaction> pop_front();
    bool contains(const Hash256& txid) const;
    size_t size() const { return queue.size(); }
    void clear();
    // BIP-125 RBF: replace by fee (simplified)
    bool replace_by_fee(const storage::CompactTransaction& new_tx, u64 min_fee);
};

} // namespace omnibus::consensus