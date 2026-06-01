// OEP-1 56/150 | path=src/p2p/sync.cpp | proj=omnibus-node-cpp | run=2026-06-01-cpp-v1
#include "../../include/omnibus/p2p/sync.hpp"
#include <spdlog/spdlog.h>

namespace omnibus::p2p {

SyncManager::SyncManager(std::shared_ptr<storage::ChainDB> db) : db_(db) {}

void SyncManager::start_sync(const std::vector<std::shared_ptr<Peer>>& peers) {
    if (peers.empty()) return;
    
    auto our_height = db_->tip_height();
    spdlog::info("Starting sync from height {}", our_height);
    
    // Simplified: just request headers from the first peer
    state_ = HEADERS;
    request_headers(peers[0], our_height + 1);
}

void SyncManager::request_headers(std::shared_ptr<Peer> peer, u32 start_height) {
    std::vector<u8> payload;
    codec::write_le(start_height, payload);
    peer->send_message(0x10, payload); // 0x10 = GET_HEADERS
}

void SyncManager::receive_headers(const std::vector<BlockHeaderV3>& headers) {
    for (const auto& hdr : headers) {
        // Verify each header
        if (verify_header(hdr)) {
            pending_headers_.push_back(hdr);
        }
    }
    
    if (!headers.empty()) {
        request_blocks();
    }
}

void SyncManager::request_blocks() {
    if (pending_headers_.empty()) {
        state_ = IDLE;
        return;
    }
    
    // Simplified: request blocks by hash
    state_ = BLOCKS;
}

bool SyncManager::verify_header(const BlockHeaderV3& header) const {
    // Simplified verification
    return true;
}

} // namespace omnibus::p2p