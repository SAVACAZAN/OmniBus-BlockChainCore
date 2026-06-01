#include "../../include/omnibus/identity/did.hpp"
#include "../../include/omnibus/crypto/sha256.hpp"
#include <sstream>
#include <iomanip>

namespace omnibus::identity {

std::string create_did(const Hash160& pubkey_hash) {
    // Base58 encoding of pubkey_hash
    // Simplified: use hex for demo
    std::stringstream ss;
    ss << "did:omnibus:";
    for (u8 b : pubkey_hash) {
        ss << std::hex << std::setw(2) << std::setfill('0') << static_cast<int>(b);
    }
    return ss.str();
}

bool verify_did(const std::string& did, const Hash160& pubkey_hash) {
    auto extracted = extract_pubkey_hash(did);
    if (!extracted) return false;
    return *extracted == pubkey_hash;
}

std::optional<Hash160> extract_pubkey_hash(const std::string& did) {
    const std::string prefix = "did:omnibus:";
    if (did.substr(0, prefix.size()) != prefix) return std::nullopt;
    
    std::string hex = did.substr(prefix.size());
    if (hex.size() != 40) return std::nullopt;
    
    Hash160 result;
    for (size_t i = 0; i < 20; ++i) {
        result[i] = static_cast<u8>(std::stoi(hex.substr(i*2, 2), nullptr, 16));
    }
    return result;
}

bool DIDRegistry::register_did(const std::string& did, const DIDDocument& doc) {
    if (docs_.find(did) != docs_.end()) return false;
    docs_[did] = doc;
    return true;
}

std::optional<DIDDocument> DIDRegistry::resolve(const std::string& did) const {
    auto it = docs_.find(did);
    if (it != docs_.end()) {
        return it->second;
    }
    return std::nullopt;
}

bool DIDRegistry::update_did(const std::string& did, const DIDDocument& doc) {
    auto it = docs_.find(did);
    if (it == docs_.end()) return false;
    docs_[did] = doc;
    return true;
}

} // namespace omnibus::identity