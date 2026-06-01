#include "../../include/omnibus/light/client.hpp"
#include "../../include/omnibus/crypto/sha256.hpp"
#include <spdlog/spdlog.h>

namespace omnibus::light {

LightClient::LightClient(std::shared_ptr<p2p::Peer> peer) : peer_(peer) {}

bool LightClient::sync_headers(u32 start_height, u32 count) {
    spdlog::info("Syncing headers from height {} to {}", start_height, start_height + count);
    // Simplified: would request headers from peer
    for (u32 i = 0; i < count; ++i) {
        SpvBlockHeader header;
        header.version = 1;
        header.height = start_height + i;
        header.timestamp = std::time(nullptr);
        header.hash = crypto::sha256d(reinterpret_cast<const u8*>(&header), sizeof(header));
        spv_.add_header(header);
    }
    return true;
}

void LightClient::watch_address(const Hash160& address) {
    watched_addresses_.push_back(address);
    update_filter();
}

void LightClient::watch_txid(const Hash256& txid) {
    filter_.insert(txid.data(), txid.size());
    update_filter();
}

void LightClient::update_filter() {
    filter_.clear();
    for (const auto& addr : watched_addresses_) {
        filter_.insert(addr.data(), addr.size());
    }
}

bool LightClient::poll_mempool() {
    // Would query peer for filtered mempool
    return true;
}

bool LightClient::verify_payment(const Hash256& txid, u64 expected_amount, const Hash160& recipient) {
    // Would request SPV proof for transaction
    SpvProof proof;
    // Simplified verification
    return proof.verify();
}

u64 LightClient::get_balance(const Hash160& address) const {
    // Would query UTXOs or account balance via SPV
    return 0;
}

} // namespace omnibus::light