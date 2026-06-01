// OEP-1 92/150 | path=include/omnibus/ws/server.hpp | proj=omnibus-node-cpp | run=2026-06-01-cpp-v1
#pragma once
#include <boost/asio.hpp>
#include <boost/beast/core.hpp>
#include <boost/beast/websocket.hpp>
#include <set>
#include <memory>
#include <functional>

namespace omnibus::ws {

class WebSocketServer : public std::enable_shared_from_this<WebSocketServer> {
    boost::asio::ip::tcp::acceptor acceptor_;
    boost::asio::io_context& io_;
    std::set<std::shared_ptr<boost::beast::websocket::stream<boost::asio::ip::tcp::socket>>> sessions_;
    
public:
    WebSocketServer(u16 port, boost::asio::io_context& io);
    ~WebSocketServer();
    
    void start();
    void stop();
    void broadcast(const std::string& event_type, const std::string& data);
    void broadcast_json(const nlohmann::json& msg);
    
private:
    void do_accept();
    void on_accept(boost::system::error_code ec, 
                   boost::asio::ip::tcp::socket socket);
    void on_handshake(std::shared_ptr<boost::beast::websocket::stream<boost::asio::ip::tcp::socket>> session,
                      boost::system::error_code ec);
};

} // namespace omnibus::ws