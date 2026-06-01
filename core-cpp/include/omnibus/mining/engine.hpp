#pragma once
#include "../consensus/block.hpp"
#include "../consensus/sub_block.hpp"
#include "../consensus/mempool.hpp"
#include "../consensus/params.hpp"
#include "../p2p/node.hpp"
#include <thread>
#include <atomic>

namespace omnibus::mining {

class MiningEngine {
    std::atomic<bool> running_;
    std::thread worker_;
    std::shared_ptr<consensus::Mempool> mempool_;
    std::shared_ptr<p2p::P2PNode> p2p_;
    Network net_;
    Hash160 coinbase_address_;
    u32 height_;
public:
    MiningEngine(Network net, std::shared_ptr<consensus::Mempool> mp,
                 std::shared_ptr<p2p::P2PNode> p2p, const Hash160& coinbase_addr = {});
    ~MiningEngine();
    void start();
    void stop();
private:
    void mine_loop();
    consensus::Block assemble_block(u32 height);
    void create_sub_blocks(consensus::Block& block);
    bool mine_sub_block(consensus::SubBlock& subblock, u32 bits);
    void broadcast_block(const consensus::Block& block);
    bool validate_and_accept_block(const consensus::Block& block);
};

} // namespace omnibus::mining