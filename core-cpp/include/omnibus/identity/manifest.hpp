#pragma once
#include "../types.hpp"
#include <array>
#include <string>

namespace omnibus::identity {

// Field indices 0..9 for manifest
enum class FieldIndex : u8 {
    NAME = 0,
    EMAIL = 1,
    COUNTRY = 2,
    DOCUMENT_TYPE = 3,
    DOCUMENT_NUMBER = 4,
    DATE_OF_BIRTH = 5,
    ADDRESS = 6,
    PHONE = 7,
    CUSTOM_1 = 8,
    CUSTOM_2 = 9
};

struct Manifest {
    std::array<Hash256, 10> leaves; // Hashed field values
    
    Hash256 root() const;
    void set_field(FieldIndex idx, const std::string& value);
    std::optional<std::string> get_field(FieldIndex idx, const Hash256& leaf_proof) const;
    bool verify_proof(FieldIndex idx, const Hash256& leaf_hash, const std::vector<Hash256>& proof) const;
};

} // namespace omnibus::identity