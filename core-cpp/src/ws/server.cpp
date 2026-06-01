#include "../../include/omnibus/ws/server.hpp"
#include <spdlog/spdlog.h>
#include <nlohmann/json.hpp>

namespace omnibus::ws {

WebSocketServer::WebSocketServer(u16 port, boost::asio::io_context& io)
    : acceptor_(io, boost::asio::ip::tcp::endpoint(boost::asio::ip::tcp::v4(), port)), io_(io) {
    spdlog::info("WebSocket server listening on port {}", port);
}

WebSocketServer::~WebSocketServer() { stop(); }

void WebSocketServer::start() {
    do_accept();
}

void WebSocketServer::stop() {
    for (auto& session : sessions_) {
        session->close(boost::beast::websocket::close_code::normal);
    }
    sessions_.clear();
}

void WebSocketServer::do_accept() {
    auto socket = std::make_shared<boost::asio::ip::tcp::socket>(io_);
    acceptor_.async_accept(*socket, [this, socket](boost::system::error_code ec) {
        if (!ec) {
            auto session = std::make_shared<boost::beast::websocket::stream<boost::asio::ip::tcp::socket>>(std::move(*socket));
            session->async_accept([this, session](boost::system::error_code ec2) {
                on_handshake(session, ec2);
            });
        }
        do_accept();
    });
}

void WebSocketServer::on_handshake(std::shared_ptr<boost::beast::websocket::stream<boost::asio::ip::tcp::socket>> session,
                                   boost::system::error_code ec) {
    if (!ec) {
        sessions_.insert(session);
        spdlog::info("WebSocket client connected");
        
        auto buf = std::make_shared<boost::beast::flat_buffer>();
        session->async_read(*buf, [this, session, buf](boost::system::error_code ec2, size_t) {
            if (!ec2) {
                // Process incoming message
                sessions_.erase(session);
            }
        });
    }
}

void WebSocketServer::broadcast(const std::string& event_type, const std::string& data) {
    nlohmann::json msg;
    msg["event"] = event_type;
    msg["data"] = data;
    msg["timestamp"] = std::time(nullptr);
    broadcast_json(msg);
}

void WebSocketServer::broadcast_json(const nlohmann::json& msg) {
    std::string serialized = msg.dump();
    for (auto& session : sessions_) {
        session->async_write(boost::asio::buffer(serialized),
            [](boost::system::error_code ec, size_t) {
                if (ec) spdlog::error("WebSocket broadcast error: {}", ec.message());
            });
    }
}

} // namespace omnibus::ws