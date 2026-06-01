#pragma once
#include "../types.hpp"
#include "../storage/chain_db.hpp"
#include "peer.hpp"
#include <vector>
#include <memory>

namespace omnibus::p2p {

struct BlockHeaderV3 {
    u32 version;
    Hash256 prev_block;
    Hash256 merkle_root;
    u32 timestamp;
    u32 bits;
    u32 nonce;
    // 130 bytes total
};

class SyncManager {
    enum State { IDLE, HEADERS, BLOCKS } state_ = IDLE;
    std::shared_ptr<storage::ChainDB> db_;
    std::vector<BlockHeaderV3> pending_headers_;
public:
    explicit SyncManager(std::shared_ptr<storage::ChainDB> db);
    void start_sync(const std::vector<std::shared_ptr<Peer>>& peers);
    void request_headers(std::shared_ptr<Peer> peer, u32 start_height);
    void receive_headers(const std::vector<BlockHeaderV3>& headers);
    void request_blocks();
    bool verify_header(const BlockHeaderV3& header) const;
};

} // namespace omnibus::p2p