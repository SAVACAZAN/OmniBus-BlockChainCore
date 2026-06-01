// OEP-1 53/150 | path=src/p2p/peer.cpp | proj=omnibus-node-cpp | run=2026-06-01-cpp-v1
#include "../../include/omnibus/p2p/peer.hpp"
#include "../../include/omnibus/consensus/params.hpp"
#include <spdlog/spdlog.h>
#include <random>

namespace omnibus::p2p {

Peer::Peer(boost::asio::io_context& io) : socket_(io), state_(CONNECTING) {
    std::random_device rd;
    std::mt19937_64 gen(rd());
    expected_nonce_ = gen();
}

void Peer::connect(const std::string& host, u16 port) {
    boost::asio::ip::tcp::resolver resolver(socket_.get_executor());
    auto endpoints = resolver.resolve(host, std::to_string(port));
    boost::asio::async_connect(socket_, endpoints,
        [this](boost::system::error_code ec, auto) {
            if (!ec) {
                spdlog::info("Connected to peer");
                do_read();
            } else {
                spdlog::error("Connect failed: {}", ec.message());
            }
        });
}

void Peer::start_handshake(Network net, u32 height) {
    network_ = net;
    Hello hello;
    hello.version = 1;
    hello.timestamp = std::time(nullptr);
    hello.nonce = expected_nonce_;
    hello.user_agent = {'o','m','n','i','b','u','s','-','c','p','p','/','1','.','0'};
    hello.network = net;
    hello.height = height;
    
    auto payload = hello.serialize();
    send_message(0x01, payload); // 0x01 = HELLO command
    state_ = HANDSHAKE_HELLO;
}

void Peer::send_message(u8 cmd, const std::vector<u8>& payload) {
    write_buffer_.clear();
    codec::write_le(consensus::network_magic(network_), write_buffer_);
    write_buffer_.push_back(cmd);
    codec::write_le(static_cast<u32>(payload.size()), write_buffer_);
    write_buffer_.insert(write_buffer_.end(), payload.begin(), payload.end());
    
    boost::asio::async_write(socket_, boost::asio::buffer(write_buffer_),
        [this](boost::system::error_code ec, size_t) {
            if (ec) spdlog::error("Send failed: {}", ec.message());
        });
}

void Peer::do_read() {
    auto self = shared_from_this();
    boost::asio::async_read(socket_, boost::asio::buffer(read_buffer_, 9), // header
        [this, self](boost::system::error_code ec, size_t len) {
            if (ec) return;
            
            u32 magic = codec::read_le<u32>(read_buffer_.data(), len);
            u8 cmd = read_buffer_[4];
            u32 payload_len = codec::read_le<u32>(read_buffer_.data() + 5, len);
            
            if (payload_len > 0) {
                boost::asio::async_read(socket_, boost::asio::buffer(read_buffer_, payload_len),
                    [this, self, cmd, payload_len](boost::system::error_code ec2, size_t) {
                        if (!ec2) {
                            handle_message(cmd, read_buffer_.data(), payload_len);
                            do_read();
                        }
                    });
            } else {
                handle_message(cmd, nullptr, 0);
                do_read();
            }
        });
}

void Peer::handle_message(u8 cmd, const u8* payload, size_t len) {
    if (cmd == 0x01 && state_ == HANDSHAKE_HELLO) {
        Hello hello = Hello::deserialize(payload, len);
        Welcome welcome;
        welcome.version = 1;
        welcome.timestamp = std::time(nullptr);
        welcome.nonce = hello.nonce;
        welcome.user_agent = {'o','m','n','i','b','u','s','-','c','p','p','/','1','.','0'};
        welcome.network = hello.network;
        welcome.height = 0;
        
        auto wel_payload = welcome.serialize();
        send_message(0x02, wel_payload);
        state_ = HANDSHAKE_WELCOME;
    } else if (cmd == 0x02 && state_ == HANDSHAKE_WELCOME) {
        state_ = STABLE;
        if (on_stable_) on_stable_();
    }
}

void Peer::set_on_stable(std::function<void()> cb) {
    on_stable_ = cb;
}

} // namespace omnibus::p2p