#pragma once
#include "peer.hpp"
#include <boost/asio.hpp>
#include <set>
#include <random>

namespace omnibus::p2p {

class P2PNode {
    boost::asio::io_context io_;
    boost::asio::ip::tcp::acceptor acceptor_;
    std::set<std::shared_ptr<Peer>> peers_;
    std::mt19937_64 rng_;
    Network net_;
public:
    P2PNode(Network net, u16 port);
    void start();
    void add_seed(const std::string& host, u16 port);
    void run();
    void stop();
private:
    void do_accept();
    void connect_to_peer(const std::string& host, u16 port);
};

} // namespace omnibus::p2p