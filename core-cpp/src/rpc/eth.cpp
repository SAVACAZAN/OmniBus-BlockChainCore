#include "../../include/omnibus/rpc/eth.hpp"
#include "../../include/omnibus/rpc/server.hpp"
#include <spdlog/spdlog.h>

namespace omnibus::rpc::eth {

json eth_blockNumber(const json& params) {
    // Return current block height as hex
    return "0x0";
}

json eth_getBalance(const json& params) {
    if (params.size() < 1) {
        throw std::runtime_error("Missing address parameter");
    }
    return "0x0";
}

json eth_getTransactionCount(const json& params) {
    return "0x0";
}

json eth_getBlockByNumber(const json& params) {
    return nullptr;
}

json eth_getBlockByHash(const json& params) {
    return nullptr;
}

json eth_sendRawTransaction(const json& params) {
    if (params.size() < 1) {
        throw std::runtime_error("Missing raw transaction");
    }
    std::string raw_tx = params[0];
    spdlog::info("eth_sendRawTransaction: {}", raw_tx.substr(0, 64));
    return "0x" + std::string(64, '0');
}

json eth_call(const json& params) {
    return "0x";
}

json eth_estimateGas(const json& params) {
    return "0x5208"; // 21000 gas
}

json eth_gasPrice(const json& params) {
    return "0x3b9aca00"; // 1e9 wei
}

json eth_getLogs(const json& params) {
    return json::array();
}

json eth_getCode(const json& params) {
    return "0x";
}

json eth_getStorageAt(const json& params) {
    return "0x";
}

json web3_clientVersion(const json& params) {
    return "omnibus-cpp/v1.0.0";
}

json net_version(const json& params) {
    return "7771";
}

json net_peerCount(const json& params) {
    return "0x0";
}

void register_eth_methods(RPCServer& server) {
    server.register_method("eth_blockNumber", eth_blockNumber);
    server.register_method("eth_getBalance", eth_getBalance);
    server.register_method("eth_getTransactionCount", eth_getTransactionCount);
    server.register_method("eth_getBlockByNumber", eth_getBlockByNumber);
    server.register_method("eth_getBlockByHash", eth_getBlockByHash);
    server.register_method("eth_sendRawTransaction", eth_sendRawTransaction);
    server.register_method("eth_call", eth_call);
    server.register_method("eth_estimateGas", eth_estimateGas);
    server.register_method("eth_gasPrice", eth_gasPrice);
    server.register_method("eth_getLogs", eth_getLogs);
    server.register_method("eth_getCode", eth_getCode);
    server.register_method("eth_getStorageAt", eth_getStorageAt);
    server.register_method("web3_clientVersion", web3_clientVersion);
    server.register_method("net_version", net_version);
    server.register_method("net_peerCount", net_peerCount);
}

} // namespace omnibus::rpc::eth