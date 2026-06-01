#pragma once
#include <boost/asio.hpp>
#include <boost/beast/websocket.hpp>
#include <set>

namespace omnibus::ws {

class WebSocketServer {
    boost::asio::ip::tcp::acceptor acceptor_;
    boost::asio::io_context& io_;
    std::set<boost::beast::websocket::stream<boost::asio::ip::tcp::socket>*> sessions_;
public:
    WebSocketServer(u16 port, boost::asio::io_context& io);
    void start();
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