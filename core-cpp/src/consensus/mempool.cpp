#include "../../include/omnibus/consensus/mempool.hpp"
#include <algorithm>

namespace omnibus::consensus {

void Mempool::add_transaction(const storage::CompactTransaction& tx) {
    auto txid = tx.txid();
    if (contains(txid)) return;
    
    if (queue.size() >= MAX_SIZE) {
        // Remove oldest
        auto oldest = queue.front();
        auto oldest_id = oldest.txid();
        tx_index.erase(oldest_id);
        queue.pop_front();
    }
    
    queue.push_back(tx);
    tx_index[txid] = queue.size() - 1;
}

std::optional<storage::CompactTransaction> Mempool::pop_front() {
    if (queue.empty()) return std::nullopt;
    auto tx = queue.front();
    auto txid = tx.txid();
    tx_index.erase(txid);
    queue.pop_front();
    
    // Update indices
    for (size_t i = 0; i < queue.size(); ++i) {
        tx_index[queue[i].txid()] = i;
    }
    return tx;
}

bool Mempool::contains(const Hash256& txid) const {
    return tx_index.find(txid) != tx_index.end();
}

void Mempool::clear() {
    queue.clear();
    tx_index.clear();
}

bool Mempool::replace_by_fee(const storage::CompactTransaction& new_tx, u64 min_fee) {
    // Simplified RBF: just add if fee higher
    auto txid = new_tx.txid();
    if (contains(txid)) return false;
    add_transaction(new_tx);
    return true;
}

} // namespace omnibus::consensus