#pragma once
#include "../types.hpp"
#include "server.hpp"
#include <nlohmann/json.hpp>
#include <string>

namespace omnibus::rpc::eth {

using json = nlohmann::json;

// EVM JSON-RPC methods (on port 8333)
json eth_blockNumber(const json& params);
json eth_getBalance(const json& params);
json eth_getTransactionCount(const json& params);
json eth_getBlockByNumber(const json& params);
json eth_getBlockByHash(const json& params);
json eth_sendRawTransaction(const json& params);
json eth_call(const json& params);
json eth_estimateGas(const json& params);
json eth_gasPrice(const json& params);
json eth_getLogs(const json& params);
json eth_getCode(const json& params);
json eth_getStorageAt(const json& params);
json web3_clientVersion(const json& params);
json net_version(const json& params);
json net_peerCount(const json& params);

// Register all ETH methods with the RPC server
void register_eth_methods(omnibus::rpc::RPCServer& server);

} // namespace omnibus::rpc::eth