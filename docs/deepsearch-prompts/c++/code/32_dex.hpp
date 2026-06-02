// OEP-1 28/33 | path=include/omnibus/identity/identity.hpp | proj=omnibus-node-cpp | run=2026-06-01-cpp-v1
#pragma once
#include "../types.hpp"
#include <string>
#include <vector>
#include <optional>

namespace omnibus::identity {

// DID: did:omnibus:<base58>
std::string create_did(const Hash160& pubkey_hash);
bool verify_did(const std::string& did, const Hash160& pubkey_hash);

// OBM (OmniBadge) - 1 byte, 8 positions
struct BadgeSet {
    u8 badges;
    bool has_badge(u8 pos) const;
    void set_badge(u8 pos, bool value);
};

// Manifest (10-leaf Merkle)
struct Manifest {
    std::array<Hash256, 10> leaves;
    Hash256 root() const;
};

// Salt (32 bytes, stored in file with 0600 perms)
class SaltFile {
    std::string path;
    std::vector<u8> salt;
public:
    explicit SaltFile(const std::string& path = "/var/run/omnibus/salt.bin");
    bool load_or_create();
    std::vector<u8> get() const;
};

// KYC / MiCA reporting
struct MicaReport {
    std::string report_id;
    u64 timestamp;
    std::string canonical_json;
    Hash256 pre_hash() const;
};

// Name Service (.omnibus / .arbitraje)
class NameService {
public:
    bool register_name(const std::string& name, const Hash160& owner, u64 fee);
    std::optional<Hash160> resolve(const std::string& name);
};

} // namespace omnibus::identity