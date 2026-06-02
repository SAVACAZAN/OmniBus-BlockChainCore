// OEP-1 38/150 | path=src/crypto/bech32.cpp | proj=omnibus-node-cpp | run=2026-06-01-cpp-v1
#include "../../include/omnibus/crypto/bech32.hpp"
#include "../../include/omnibus/crypto/sha256.hpp"
#include "../../include/omnibus/crypto/ripemd160.hpp"
#include <algorithm>
#include <cstring>

namespace omnibus::crypto {

static const std::string CHARSET = "qpzry9x8gf2tvdw0s3jn54khce6mua7l";

static u32 polymod(const std::vector<u8>& values) {
    u32 chk = 1;
    static const u32 GEN[] = {0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3};
    for (u8 v : values) {
        u32 b = chk >> 25;
        chk = ((chk & 0x1ffffff) << 5) ^ v;
        for (int i = 0; i < 5; ++i) {
            if ((b >> i) & 1) chk ^= GEN[i];
        }
    }
    return chk;
}

static std::vector<u8> expand_hrp(const std::string& hrp) {
    std::vector<u8> ret;
    for (char c : hrp) ret.push_back(static_cast<u8>(c) >> 5);
    ret.push_back(0);
    for (char c : hrp) ret.push_back(static_cast<u8>(c) & 31);
    return ret;
}

std::string bech32_encode(const std::string& hrp, const std::vector<u8>& data) {
    std::vector<u8> values = expand_hrp(hrp);
    values.insert(values.end(), data.begin(), data.end());
    u32 checksum = polymod(values);
    for (int i = 0; i < 6; ++i) {
        values.push_back((checksum >> (5 * (5 - i))) & 31);
    }
    
    std::string result = hrp + "1";
    for (size_t i = 0; i < values.size() - 6; ++i) {
        result += CHARSET[values[i]];
    }
    return result;
}

std::optional<std::pair<std::string, std::vector<u8>>> bech32_decode(const std::string& str) {
    size_t pos = str.find('1');
    if (pos == std::string::npos || pos == 0 || pos > str.size() - 7) return std::nullopt;
    
    std::string hrp = str.substr(0, pos);
    std::string data_str = str.substr(pos + 1);
    
    std::vector<u8> values;
    for (char c : data_str) {
        auto it = CHARSET.find(c);
        if (it == std::string::npos) return std::nullopt;
        values.push_back(static_cast<u8>(it));
    }
    
    std::vector<u8> hrp_exp = expand_hrp(hrp);
    hrp_exp.insert(hrp_exp.end(), values.begin(), values.end());
    if (polymod(hrp_exp) != 1) return std::nullopt;
    
    std::vector<u8> data(values.begin(), values.end() - 6);
    return std::make_pair(hrp, data);
}

std::string native_address_from_hash160(const Hash160& hash) {
    std::vector<u8> data;
    data.push_back(0); // witness version 0
    for (u8 b : hash) data.push_back(b);
    return bech32_encode(OB_HRP, data);
}

std::optional<Hash160> hash160_from_native_address(const std::string& addr) {
    auto decoded = bech32_decode(addr);
    if (!decoded || decoded->first != OB_HRP) return std::nullopt;
    if (decoded->second.size() != 21 || decoded->second[0] != 0) return std::nullopt;
    
    Hash160 hash;
    std::copy(decoded->second.begin() + 1, decoded->second.end(), hash.begin());
    return hash;
}

} // namespace omnibus::crypto