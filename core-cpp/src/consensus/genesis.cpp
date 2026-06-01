#include "../../include/omnibus/consensus/genesis.hpp"
#include "../../include/omnibus/consensus/block.hpp"
#include "../../include/omnibus/consensus/params.hpp"
#include "../../include/omnibus/storage/compact_tx.hpp"

namespace omnibus::consensus {

Block build_genesis_block(Network net) {
    Block genesis;
    genesis.header.version = 1;
    genesis.header.prev_block = Hash256{};
    genesis.header.merkle_root = Hash256{};
    genesis.header.timestamp = GENESIS_TIMESTAMP;
    genesis.header.bits = 0x1d00ffff; // Easy difficulty for genesis
    genesis.header.nonce = 0;
    
    // Create coinbase transaction
    storage::CompactTransaction coinbase;
    coinbase.version = 1;
    coinbase.locktime = 0;
    // Simplified: coinbase input
    coinbase.inputs = {}; // Empty for genesis
    coinbase.outputs = {}; // Output to genesis reward address
    
    genesis.txs.push_back(coinbase);
    
    // Compute merkle root
    std::vector<Hash256> tx_hashes;
    for (const auto& tx : genesis.txs) {
        tx_hashes.push_back(tx.txid());
    }
    genesis.header.merkle_root = compute_merkle_root(tx_hashes);
    
    return genesis;
}

bool verify_genesis_block(const Block& block, Network net) {
    auto genesis = build_genesis_block(net);
    return block.hash() == genesis.hash();
}

} // namespace omnibus::consensus