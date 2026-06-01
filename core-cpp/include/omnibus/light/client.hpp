#pragma once
#include "spv.hpp"
#include "bloom.hpp"
#include "../p2p/peer.hpp"
#include <memory>
#include <vector>

namespace omnibus::light {

class LightClient {
    std::shared_ptr<p2p::Peer> peer_;
    SPVClient spv_;
    BloomFilter filter_;
    std::vector<Hash256> watched_addresses_;
    
public:
    explicit LightClient(std::shared_ptr<p2p::Peer> peer);
    
    bool sync_headers(u32 start_height, u32 count);
    void watch_address(const Hash160& address);
    void watch_txid(const Hash256& txid);
    void update_filter();
    bool poll_mempool();
    
    // Simplified payment verification
    bool verify_payment(const Hash256& txid, u64 expected_amount, const Hash160& recipient);
    u64 get_balance(const Hash160& address) const;
};

} // namespace omnibus::light