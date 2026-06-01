#include "../../include/omnibus/rpc/server.hpp"
#include <spdlog/spdlog.h>
#include <sstream>

namespace omnibus::rpc {

RPCServer::RPCServer(u16 port) : acceptor_(io_, boost::asio::ip::tcp::endpoint(boost::asio::ip::tcp::v4(), port)), port_(port) {}

RPCServer::~RPCServer() { stop(); }

void RPCServer::start() {
    do_accept();
    spdlog::info("RPC server listening on port {}", port_);
}

void RPCServer::stop() {
    io_.stop();
}

void RPCServer::register_method(const std::string& name, std::function<json(const json&)> handler) {
    methods_[name] = handler;
}

void RPCServer::run() {
    io_.run();
}

void RPCServer::do_accept() {
    auto socket = std::make_shared<boost::asio::ip::tcp::socket>(io_);
    acceptor_.async_accept(*socket, [this, socket](boost::system::error_code ec) {
        if (!ec) {
            handle_client(socket);
        }
        do_accept();
    });
}

void RPCServer::handle_client(std::shared_ptr<boost::asio::ip::tcp::socket> socket) {
    auto buf = std::make_shared<boost::asio::streambuf>();
    boost::asio::async_read_until(*socket, *buf, "\n",
        [this, socket, buf](boost::system::error_code ec, size_t) {
            if (!ec) {
                std::istream is(buf.get());
                std::string line;
                std::getline(is, line);
                
                try {
                    auto req = json::parse(line);
                    auto resp = process_request(req);
                    std::string resp_str = resp.dump() + "\n";
                    boost::asio::async_write(*socket, boost::asio::buffer(resp_str),
                        [](boost::system::error_code, size_t) {});
                } catch (const std::exception& e) {
                    spdlog::error("RPC error: {}", e.what());
                }
                
                handle_client(socket);
            }
        });
}

json RPCServer::process_request(const json& req) {
    std::string method = req.value("method", "");
    json id = req.value("id", nullptr);
    json params = req.value("params", json::array());
    
    auto it = methods_.find(method);
    if (it != methods_.end()) {
        try {
            json result = it->second(params);
            return make_result(result, id);
        } catch (const std::exception& e) {
            return make_error(-32000, e.what(), id);
        }
    }
    
    return make_error(-32601, "Method not found", id);
}

json RPCServer::make_error(int code, const std::string& message, const json& id) {
    json resp;
    resp["jsonrpc"] = "2.0";
    resp["error"]["code"] = code;
    resp["error"]["message"] = message;
    resp["id"] = id;
    return resp;
}

json RPCServer::make_result(const json& result, const json& id) {
    json resp;
    resp["jsonrpc"] = "2.0";
    resp["result"] = result;
    resp["id"] = id;
    return resp;
}

} // namespace omnibus::rpc