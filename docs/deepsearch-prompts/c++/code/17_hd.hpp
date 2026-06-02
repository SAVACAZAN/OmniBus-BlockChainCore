// OEP-1 13/33 | path=include/omnibus/wallet/address.hpp | proj=omnibus-node-cpp | run=2026-06-01-cpp-v1
#pragma once
#include "../types.hpp"
#include <string>
#include <variant>

namespace omnibus::wallet {

// Address kinds
enum class AddressType {
    Native,   // bech32 ob1...
    EVM,      // 0x...
    PQSoulbound,   // ob_k1_... etc
    PQTransferable // obk1_... etc
};

struct NativeAddress {
    Hash160 hash;
};

struct EVMAddress {
    U256 eth_addr; // 20 bytes in lower 20
};

struct PQAddress {
    std::string prefix; // e.g., "ob_k1_"
    std::vector<u8> public_key;
};

using AddressVariant = std::variant<NativeAddress, EVMAddress, PQAddress>;

class Address {
    AddressType type_;
    AddressVariant data_;
public:
    Address(const std::string& str); // parse
    std::string to_string() const;
    AddressType type() const { return type_; }
    bool is_valid() const;
};

// EIP-55 checksum
std::string to_checksum_address(const std::string& hex_lower);
bool verify_checksum_address(const std::string& addr);

} // namespace omnibus::wallet