// OEP-1 41/150 | path=src/wallet/hd.cpp | proj=omnibus-node-cpp | run=2026-06-01-cpp-v1
#include "../../include/omnibus/wallet/hd.hpp"
#include "../../include/omnibus/crypto/bech32.hpp"
#include "../../include/omnibus/wallet/address.hpp"
#include <sstream>
#include <iomanip>

namespace omnibus::wallet {

std::string omni_address(const ExtendedKey& master, u32 account, u32 change, u32 index) {
    std::string path = "m/44'/" + std::to_string(OMNI_COIN_TYPE) + "'/" +
                       std::to_string(account) + "'/" +
                       std::to_string(change) + "/" +
                       std::to_string(index);
    auto key = crypto::derive_path(master, path);
    if (!key.is_private) return "";
    
    auto pubkey = crypto::secp256k1.pubkey_compress(key.key);
    auto hash160 = crypto::secp256k1.hash160_pubkey(pubkey);
    return crypto::native_address_from_hash160(hash160);
}

std::string evm_address(const ExtendedKey& master, u32 account, u32 change, u32 index) {
    std::string path = "m/44'/" + std::to_string(EVM_COIN_TYPE) + "'/" +
                       std::to_string(account) + "'/" +
                       std::to_string(change) + "/" +
                       std::to_string(index);
    auto key = crypto::derive_path(master, path);
    if (!key.is_private) return "";
    
    auto pubkey = crypto::secp256k1.pubkey_uncompress(key.key);
    // Remove prefix byte (0x04)
    std::vector<u8> pubkey_no_prefix(pubkey.begin() + 1, pubkey.end());
    auto keccak = crypto::keccak256(pubkey_no_prefix.data(), pubkey_no_prefix.size());
    
    std::stringstream ss;
    ss << "0x";
    for (size_t i = 12; i < 32; ++i) {
        ss << std::hex << std::setw(2) << std::setfill('0') << static_cast<int>(keccak[i]);
    }
    return to_checksum_address(ss.str());
}

std::string pq_address(const ExtendedKey& master, PqScheme scheme, u32 index, bool soulbound) {
    // Derive seed from master
    std::string path = "m/777'/" + std::to_string(index);
    auto key = crypto::derive_path(master, path);
    
    auto kp = crypto::derive_pq_keypair(key.key, OMNI_COIN_TYPE, scheme, index);
    
    const char* prefix;
    switch (scheme) {
        case PqScheme::ML_DSA_87:
            prefix = soulbound ? "ob_k1_" : "obk1_";
            break;
        case PqScheme::Falcon_512:
            prefix = soulbound ? "ob_f5_" : "obf5_";
            break;
        case PqScheme::SLH_DSA_256s:
            prefix = soulbound ? "ob_s3_" : "obs3_";
            break;
        default:
            prefix = soulbound ? "ob_d5_" : "obd5_";
    }
    
    // Base58 encode public key
    std::string b58 = std::string(prefix) + "not_implemented_base58";
    // In full implementation, use base58 encoding
    return b58;
}

} // namespace omnibus::wallet