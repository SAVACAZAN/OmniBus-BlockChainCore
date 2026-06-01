#pragma once
#include "wire.hpp"
#include <boost/asio.hpp>
#include <memory>
#include <functional>

namespace omnibus::p2p {

class Peer : public std::enable_shared_from_this<Peer> {
    boost::asio::ip::tcp::socket socket_;
    std::array<u8, 8192> read_buffer_;
    std::vector<u8> write_buffer_;
    enum State { CONNECTING, HANDSHAKE_HELLO, HANDSHAKE_WELCOME, STABLE } state_;
    u64 expected_nonce_;
    Network network_;
public:
    Peer(boost::asio::io_context& io);
    void connect(const std::string& host, u16 port);
    void start_handshake(Network net, u32 height);
    void send_message(u8 cmd, const std::vector<u8>& payload);
    void set_on_stable(std::function<void()> cb);
private:
    void do_read();
    void handle_hello(const Hello& hello);
    void handle_welcome(const Welcome& welcome);
};

} // namespace omnibus::p2p