// OEP-1 9/33 | path=include/omnibus/crypto/bech32.hpp | proj=omnibus-node-cpp | run=2026-06-01-cpp-v1
#pragma once
#include "../types.hpp"
#include <string>
#include <optional>

namespace omnibus::crypto {

constexpr const char* OB_HRP = "ob";

// Bech32 (v0 witness) encoding/decoding
std::string bech32_encode(const std::string& hrp, const std::vector<u8>& data);
std::optional<std::pair<std::string, std::vector<u8>>> bech32_decode(const std::string& str);

// Convenience for native address: HRP="ob", witness version=0, program=hash160
std::string native_address_from_hash160(const Hash160& hash);
std::optional<Hash160> hash160_from_native_address(const std::string& addr);

} // namespace omnibus::crypto