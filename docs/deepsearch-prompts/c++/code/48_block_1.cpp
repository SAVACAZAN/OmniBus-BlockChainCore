// OEP-1 44/150 | path=src/consensus/sub_block.cpp | proj=omnibus-node-cpp | run=2026-06-01-cpp-v1
#include "../../include/omnibus/consensus/sub_block.hpp"
#include "../../include/omnibus/crypto/sha256.hpp"
#include "../../include/omnibus/codec.hpp"

namespace omnibus::consensus {

Hash256 SubBlock::hash() const {
    std::vector<u8> buf;
    codec::write_le(index, buf);
    codec::write_le(timestamp_ms, buf);
    buf.insert(buf.end(), prev_hash.begin(), prev_hash.end());
    buf.insert(buf.end(), key_block_hash.begin(), key_block_hash.end());
    
    // Hash all txids
    for (const auto& tx : txs) {
        auto txid = tx.txid();
        buf.insert(buf.end(), txid.begin(), txid.end());
    }
    
    return crypto::sha256d(buf);
}

} // namespace omnibus::consensus