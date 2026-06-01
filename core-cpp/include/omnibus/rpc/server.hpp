#pragma once
#include "../types.hpp"
#include <boost/asio.hpp>
#include <nlohmann/json.hpp>
#include <functional>
#include <map>
#include <memory>
#include <string>

namespace omnibus::rpc {

using json = nlohmann::json;

class RPCServer {
    boost::asio::io_context io_;
    boost::asio::ip::tcp::acceptor acceptor_;
    std::map<std::string, std::function<json(const json&)>> methods_;
    u16 port_;
public:
    RPCServer(u16 port);
    ~RPCServer();
    void start();
    void stop();
    void register_method(const std::string& name, std::function<json(const json&)> handler);
    void run();
private:
    void do_accept();
    void handle_client(std::shared_ptr<boost::asio::ip::tcp::socket> socket);
    json process_request(const json& req);
    static json make_error(int code, const std::string& message, const json& id);
    static json make_result(const json& result, const json& id);
};

// Native OmniBus methods (~140) – simplified sample
class NativeRPC {
public:
    static json getblock(const json& params);
    static json sendtoaddress(const json& params);
    static json getbalance(const json& params);
};

// EVM JSON-RPC (eth_*)
class EVMRPC {
public:
    static json eth_blockNumber(const json& params);
    static json eth_getBalance(const json& params);
    static json eth_sendRawTransaction(const json& params);
};

} // namespace omnibus::rpc