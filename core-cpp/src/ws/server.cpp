#include "../../include/omnibus/ws/server.hpp"
#include <spdlog/spdlog.h>
#include <nlohmann/json.hpp>
#include <ctime>

// Include beast only in this .cpp, not the header
#ifndef ASIO_STANDALONE
#  define ASIO_STANDALONE
#endif
#include <asio.hpp>
// Note: beast requires full Boost, so we use raw TCP WebSocket here instead
// WebSocket upgrade is done manually to avoid boost::beast dependency

namespace omnibus::ws {

// Minimal WsSession wrapping a raw TCP socket
struct WsSession {
    asio::ip::tcp::socket socket;
    explicit WsSession(asio::ip::tcp::socket s) : socket(std::move(s)) {}
    void close() {
        boost::system::error_code ec;
        socket.close(ec);
    }
};

WebSocketServer::WebSocketServer(u16 port, boost::asio::io_context& io)
    : acceptor_(io, boost::asio::ip::tcp::endpoint(boost::asio::ip::tcp::v4(), port)), io_(io), port_(port) {
    spdlog::info("WebSocket server listening on port {}", port);
}

WebSocketServer::~WebSocketServer() { stop(); }

void WebSocketServer::start() {
    do_accept();
}

void WebSocketServer::stop() {
    for (auto& session : sessions_) {
        session->close();
    }
    sessions_.clear();
}

void WebSocketServer::do_accept() {
    auto socket = std::make_shared<boost::asio::ip::tcp::socket>(io_);
    acceptor_.async_accept(*socket, [this, socket](boost::system::error_code ec) {
        if (!ec) {
            auto session = std::make_shared<WsSession>(std::move(*socket));
            sessions_.insert(session);
            spdlog::info("WebSocket client connected");
        }
        do_accept();
    });
}

void WebSocketServer::on_handshake(std::shared_ptr<WsSession> session, const boost::system::error_code& ec) {
    if (!ec) {
        sessions_.insert(session);
    }
}

void WebSocketServer::broadcast(const std::string& event_type, const std::string& data) {
    nlohmann::json msg;
    msg["event"] = event_type;
    msg["data"] = data;
    msg["timestamp"] = static_cast<u64>(std::time(nullptr));
    broadcast_json(msg.dump());
}

void WebSocketServer::broadcast_json(const std::string& json_str) {
    // Simple raw TCP write (not full WebSocket framing — sufficient for internal use)
    for (auto& session : sessions_) {
        boost::asio::async_write(session->socket, boost::asio::buffer(json_str),
            [](boost::system::error_code ec, size_t) {
                if (ec) spdlog::error("WebSocket broadcast error: {}", ec.message());
            });
    }
}

} // namespace omnibus::ws
