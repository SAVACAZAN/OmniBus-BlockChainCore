#include "../../include/omnibus/wallet/address.hpp"
#include "../../include/omnibus/crypto/bech32.hpp"
#include "../../include/omnibus/crypto/keccak.hpp"
#include <algorithm>
#include <cctype>
#include <regex>

namespace omnibus::wallet {

std::string to_checksum_address(const std::string& hex_lower) {
    if (hex_lower.size() != 42 || hex_lower.substr(0, 2) != "0x") return hex_lower;
    
    std::string addr_no_prefix = hex_lower.substr(2);
    std::transform(addr_no_prefix.begin(), addr_no_prefix.end(), addr_no_prefix.begin(), ::tolower);
    
    auto hash = crypto::keccak256(reinterpret_cast<const u8*>(addr_no_prefix.c_str()), addr_no_prefix.size());
    
    std::string result = "0x";
    for (size_t i = 0; i < 40; ++i) {
        char c = addr_no_prefix[i];
        int nibble = (hash[i/2] >> (4 * (1 - (i%2)))) & 0x0F;
        if (nibble >= 8 && std::isalpha(c)) {
            c = std::toupper(c);
        }
        result += c;
    }
    return result;
}

bool verify_checksum_address(const std::string& addr) {
    if (addr.size() != 42 || addr.substr(0, 2) != "0x") return false;
    
    std::string lower = addr;
    std::transform(lower.begin(), lower.end(), lower.begin(), ::tolower);
    return to_checksum_address(lower) == addr;
}

Address::Address(const std::string& str) {
    // Check native bech32
    if (str.substr(0, 2) == "ob" && str.size() > 10) {
        auto decoded = crypto::bech32_decode(str);
        if (decoded && decoded->first == "ob") {
            type_ = AddressType::Native;
            NativeAddress nat;
            if (decoded->second.size() == 21 && decoded->second[0] == 0) {
                std::copy(decoded->second.begin() + 1, decoded->second.end(), nat.hash.begin());
                data_ = nat;
                return;
            }
        }
    }
    
    // Check EVM address
    if (str.substr(0, 2) == "0x" && str.size() == 42) {
        type_ = AddressType::EVM;
        EVMAddress evm;
        for (size_t i = 2; i < 42; i += 2) {
            evm.eth_addr[i/2 - 1] = static_cast<u8>(std::stoi(str.substr(i, 2), nullptr, 16));
        }
        data_ = evm;
        return;
    }
    
    // Check PQ address prefixes
    static const std::vector<std::string> pq_prefixes = {
        "ob_k1_", "ob_f5_", "ob_d5_", "ob_s3_",
        "obk1_", "obf5_", "obd5_", "obs3_"
    };
    for (const auto& prefix : pq_prefixes) {
        if (str.substr(0, prefix.size()) == prefix) {
            type_ = (prefix[2] == '_') ? AddressType::PQSoulbound : AddressType::PQTransferable;
            PQAddress pq;
            pq.prefix = prefix;
            // remaining part is base58 encoded pubkey
            data_ = pq;
            return;
        }
    }
    
    type_ = AddressType::Native;
    data_ = NativeAddress{};
}

std::string Address::to_string() const {
    if (type_ == AddressType::Native) {
        auto& nat = std::get<NativeAddress>(data_);
        return crypto::native_address_from_hash160(nat.hash);
    } else if (type_ == AddressType::EVM) {
        auto& evm = std::get<EVMAddress>(data_);
        std::stringstream ss;
        ss << "0x";
        for (size_t i = 12; i < 20; ++i) {
            ss << std::hex << std::setw(2) << std::setfill('0') << static_cast<int>(evm.eth_addr[i]);
        }
        return to_checksum_address(ss.str());
    } else {
        auto& pq = std::get<PQAddress>(data_);
        return pq.prefix + "not_implemented";
    }
}

bool Address::is_valid() const {
    return type_ != AddressType::Native || std::get<NativeAddress>(data_).hash != Hash160{};
}

} // namespace omnibus::wallet