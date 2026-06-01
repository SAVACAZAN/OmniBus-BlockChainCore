// OEP-1 66/150 | path=include/omnibus/dex/oracle.hpp | proj=omnibus-node-cpp | run=2026-06-01-cpp-v1
#pragma once
#include "../types.hpp"
#include <vector>
#include <map>

namespace omnibus::dex {

struct PricePoint {
    u64 timestamp;
    u64 price; // price * 10^8
    u64 volume;
};

struct OraclePrice {
    u32 pair_id;
    u64 price;
    u64 confidence;
    u64 timestamp;
    std::vector<u8> signature; // signed by oracle
};

class PriceOracle {
    std::map<u32, std::vector<PricePoint>> history_;
    std::map<u32, OraclePrice> latest_;
    
public:
    void submit_price(const OraclePrice& price);
    std::optional<OraclePrice> get_price(u32 pair_id) const;
    u64 get_vwap(u32 pair_id, u32 lookback_seconds) const;
    bool verify_oracle_signature(const OraclePrice& price) const;
};

} // namespace omnibus::dex