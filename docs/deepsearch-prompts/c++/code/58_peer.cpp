// OEP-1 54/150 | path=src/p2p/node.cpp | proj=omnibus-node-cpp | run=2026-06-01-cpp-v1
#include "../../include/omnibus/p2p/node.hpp"
#include <spdlog/spdlog.h>

namespace omnibus::p2p {

P2PNode::P2PNode(Network net, u16 port)
    : acceptor_(io_, boost::asio::ip::tcp::endpoint(boost::asio::ip::tcp::v4(), port)),
      rng_(std::random_device{}()), net_(net) {
    spdlog::info("P2P node listening on port {}", port);
}

void P2PNode::start() {
    do_accept();
}

void P2PNode::do_accept() {
    auto peer = std::make_shared<Peer>(io_);
    acceptor_.async_accept(peer->socket(),
        [this, peer](boost::system::error_code ec) {
            if (!ec) {
                spdlog::info("New peer connected");
                peer->start_handshake(net_, 0);
                peers_.insert(peer);
                do_accept();
            }
        });
}

void P2PNode::add_seed(const std::string& host, u16 port) {
    connect_to_peer(host, port);
}

void P2PNode::connect_to_peer(const std::string& host, u16 port) {
    auto peer = std::make_shared<Peer>(io_);
    peer->set_on_stable([this, peer]() {
        peers_.insert(peer);
        spdlog::info("Handshake complete with peer");
    });
    peer->connect(host, port);
    peer->start_handshake(net_, 0);
}

void P2PNode::run() {
    io_.run();
}

void P2PNode::stop() {
    io_.stop();
}

} // namespace omnibus::p2p