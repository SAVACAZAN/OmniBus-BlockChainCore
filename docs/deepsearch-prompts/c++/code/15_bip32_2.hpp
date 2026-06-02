// OEP-1 11/33 | path=include/omnibus/crypto/pq.hpp | proj=omnibus-node-cpp | run=2026-06-01-cpp-v1
#pragma once
#include "../types.hpp"
#include <vector>
#include <string>
#include <oqs/oqs.h>

namespace omnibus::crypto {

enum class PqScheme {
    ML_DSA_87,   // Dilithium5
    Falcon_512,
    SLH_DSA_256s,
    ML_KEM_768   // for key exchange
};

struct PqKeyPair {
    std::vector<u8> public_key;
    std::vector<u8> secret_key;
};

// Deterministic keypair from seed (32 bytes) and coin type + index
PqKeyPair derive_pq_keypair(const std::vector<u8>& seed, u32 coin_type, PqScheme scheme, u32 index);

// Sign and verify
std::vector<u8> pq_sign(const std::vector<u8>& secret_key, const std::vector<u8>& message, PqScheme scheme);
bool pq_verify(const std::vector<u8>& public_key, const std::vector<u8>& message, const std::vector<u8>& signature, PqScheme scheme);

// KEM encapsulation/decapsulation
std::pair<std::vector<u8>, std::vector<u8>> pq_kem_encaps(const std::vector<u8>& public_key, PqScheme scheme);
std::vector<u8> pq_kem_decaps(const std::vector<u8>& secret_key, const std::vector<u8>& ciphertext, PqScheme scheme);

} // namespace omnibus::crypto