// OEP-1 67/150 | path=include/omnibus/identity/did.hpp | proj=omnibus-node-cpp | run=2026-06-01-cpp-v1
#pragma once
#include "../types.hpp"
#include <string>
#include <optional>

namespace omnibus::identity {

// DID format: did:omnibus:<base58-encoded-hash>
std::string create_did(const Hash160& pubkey_hash);
bool verify_did(const std::string& did, const Hash160& pubkey_hash);
std::optional<Hash160> extract_pubkey_hash(const std::string& did);

// DID Document (simplified)
struct DIDDocument {
    std::string id;
    std::vector<Hash160> verification_methods;
    std::vector<std::string> services;
    u64 created_at;
    u64 updated_at;
};

class DIDRegistry {
    std::map<std::string, DIDDocument> docs_;
    
public:
    bool register_did(const std::string& did, const DIDDocument& doc);
    std::optional<DIDDocument> resolve(const std::string& did) const;
    bool update_did(const std::string& did, const DIDDocument& doc);
};

} // namespace omnibus::identity