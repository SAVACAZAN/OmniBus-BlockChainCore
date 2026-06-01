#pragma once
#include "../consensus/block.hpp"
#include "../consensus/mempool.hpp"
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
public:
    MiningEngine(Network net, std::shared_ptr<consensus::Mempool> mp, std::shared_ptr<p2p::P2PNode> p2p);
    void start();
    void stop();
private:
    void mine_loop();
    consensus::Block assemble_block(u32 height);
};

} // namespace omnibus::mining