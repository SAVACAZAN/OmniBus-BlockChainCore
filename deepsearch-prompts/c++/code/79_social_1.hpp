// OEP-1 75/150 | path=include/omnibus/identity/facets/professional.hpp | proj=omnibus-node-cpp | run=2026-06-01-cpp-v1
#pragma once
#include "../../types.hpp"
#include <string>
#include <vector>

namespace omnibus::identity::facets {

struct ProfessionalCredential {
    Hash160 user;
    std::string credential_type; // "education", "certification", "employment"
    std::string issuer;
    std::string credential_id;
    u64 issued_at;
    u64 expires_at;
    Hash256 credential_hash;
    std::vector<u8> issuer_signature;
};

class ProfessionalFacet {
    std::map<Hash160, std::vector<ProfessionalCredential>> credentials_;
    
public:
    bool issue_credential(const ProfessionalCredential& cred);
    bool revoke_credential(const Hash256& cred_hash, const Hash160& issuer);
    std::vector<ProfessionalCredential> get_credentials(const Hash160& user) const;
    bool verify_credential(const ProfessionalCredential& cred) const;
};

} // namespace omnibus::identity::facets