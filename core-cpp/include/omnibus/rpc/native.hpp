#pragma once
#include "../types.hpp"
#include <nlohmann/json.hpp>
#include <string>

namespace omnibus::rpc::native {

using json = nlohmann::json;

// OmniBus native RPC methods (~140 total, key ones shown)
json getblock(const json& params);
json getblockhash(const json& params);
json getblockcount(const json& params);
json getbestblockhash(const json& params);
json getrawtransaction(const json& params);
json sendrawtransaction(const json& params);
json getbalance(const json& params);
json listunspent(const json& params);
json sendtoaddress(const json& params);
json getnewaddress(const json& params);
json dumpprivkey(const json& params);
json importprivkey(const json& params);
json validateaddress(const json& params);

// DEX methods
json dex_place_order(const json& params);
json dex_cancel_order(const json& params);
json dex_get_orderbook(const json& params);
json dex_get_orders(const json& params);

// Staking methods
json stake_validator(const json& params);
json unstake_validator(const json& params);
json get_staking_info(const json& params);

// Governance methods
json governance_propose(const json& params);
json governance_vote(const json& params);
json governance_get_proposal(const json& params);

// Identity methods
json identity_register_did(const json& params);
json identity_resolve_did(const json& params);
json identity_submit_kyc(const json& params);

// Mining methods
json mining_getmininginfo(const json& params);
json mining_submitblock(const json& params);

// Register all native methods
void register_native_methods(class RPCServer& server);

} // namespace omnibus::rpc::native