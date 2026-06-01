#pragma once
#include "../types.hpp"
#include <boost/asio.hpp>
#include <memory>
#include <string>
#include <set>

namespace omnibus::ws {

// Forward-declare session type to avoid pulling in boost::beast in the header
struct WsSession;

class WebSocketServer {
    boost::asio::ip::tcp::acceptor acceptor_;
    boost::asio::io_context& io_;
    std::set<std::shared_ptr<WsSession>> sessions_;
    u16 port_;

    void do_accept();
    void on_handshake(std::shared_ptr<WsSession> session, const boost::system::error_code& ec);
    void broadcast_json(const std::string& json_str);
public:
    WebSocketServer(u16 port, boost::asio::io_context& io);
    ~WebSocketServer();
    void start();
    void stop();
    void broadcast(const std::string& event_type, const std::string& data);
};

// 17 event types (topic bitmask)
enum class EventType : u16 {
    NewBlock = 1 << 0,
    NewTransaction = 1 << 1,
    DEXFill = 1 << 2,
    // ...
};

} // namespace omnibus::ws
