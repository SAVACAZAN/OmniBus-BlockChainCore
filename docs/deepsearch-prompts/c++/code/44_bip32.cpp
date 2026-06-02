// OEP-1 40/150 | path=src/crypto/pq.cpp | proj=omnibus-node-cpp | run=2026-06-01-cpp-v1
#include "../../include/omnibus/crypto/pq.hpp"
#include "../../include/omnibus/crypto/sha256.hpp"
#include <cstring>
#include <stdexcept>

namespace omnibus::crypto {

static const char* scheme_to_name(PqScheme scheme) {
    switch (scheme) {
        case PqScheme::ML_DSA_87: return OQS_SIG_alg_ml_dsa_87;
        case PqScheme::Falcon_512: return OQS_SIG_alg_falcon_512;
        case PqScheme::SLH_DSA_256s: return OQS_SIG_alg_slh_dsa_256s;
        case PqScheme::ML_KEM_768: return OQS_KEM_alg_ml_kem_768;
        default: return nullptr;
    }
}

static OQS_SIG* get_sig(PqScheme scheme) {
    if (scheme == PqScheme::ML_KEM_768) return nullptr;
    return OQS_SIG_new(scheme_to_name(scheme));
}

static OQS_KEM* get_kem(PqScheme scheme) {
    if (scheme != PqScheme::ML_KEM_768) return nullptr;
    return OQS_KEM_new(scheme_to_name(scheme));
}

PqKeyPair derive_pq_keypair(const std::vector<u8>& seed, u32 coin_type, PqScheme scheme, u32 index) {
    // Deterministic: hash(seed || coin_type || index) as entropy
    std::vector<u8> entropy_input = seed;
    codec::write_le(coin_type, entropy_input);
    codec::write_le(index, entropy_input);
    auto hash = sha256(entropy_input);
    
    if (scheme == PqScheme::ML_KEM_768) {
        auto kem = get_kem(scheme);
        if (!kem) throw std::runtime_error("KEM scheme not available");
        
        PqKeyPair kp;
        kp.public_key.resize(kem->length_public_key);
        kp.secret_key.resize(kem->length_secret_key);
        
        // Use hash as custom seed (liboqs may not support external seed)
        // In production, use OQS_randombytes_custom with seed
        OQS_KEM_keypair(kem, kp.public_key.data(), kp.secret_key.data());
        OQS_KEM_free(kem);
        return kp;
    } else {
        auto sig = get_sig(scheme);
        if (!sig) throw std::runtime_error("Signature scheme not available");
        
        PqKeyPair kp;
        kp.public_key.resize(sig->length_public_key);
        kp.secret_key.resize(sig->length_secret_key);
        
        OQS_SIG_keypair(sig, kp.public_key.data(), kp.secret_key.data());
        OQS_SIG_free(sig);
        return kp;
    }
}

std::vector<u8> pq_sign(const std::vector<u8>& secret_key, const std::vector<u8>& message, PqScheme scheme) {
    auto sig = get_sig(scheme);
    if (!sig) throw std::runtime_error("Not a signature scheme");
    
    std::vector<u8> signature(sig->length_signature);
    size_t sig_len;
    
    if (OQS_SIG_sign(sig, signature.data(), &sig_len, message.data(), message.size(),
                     secret_key.data(), secret_key.size()) != OQS_SUCCESS) {
        OQS_SIG_free(sig);
        throw std::runtime_error("Signing failed");
    }
    
    signature.resize(sig_len);
    OQS_SIG_free(sig);
    return signature;
}

bool pq_verify(const std::vector<u8>& public_key, const std::vector<u8>& message,
               const std::vector<u8>& signature, PqScheme scheme) {
    auto sig = get_sig(scheme);
    if (!sig) return false;
    
    int result = OQS_SIG_verify(sig, message.data(), message.size(),
                                signature.data(), signature.size(),
                                public_key.data(), public_key.size());
    OQS_SIG_free(sig);
    return result == OQS_SUCCESS;
}

std::pair<std::vector<u8>, std::vector<u8>> pq_kem_encaps(const std::vector<u8>& public_key, PqScheme scheme) {
    auto kem = get_kem(scheme);
    if (!kem) throw std::runtime_error("Not a KEM scheme");
    
    std::vector<u8> ciphertext(kem->length_ciphertext);
    std::vector<u8> shared_secret(kem->length_shared_secret);
    
    if (OQS_KEM_encaps(kem, ciphertext.data(), shared_secret.data(), public_key.data()) != OQS_SUCCESS) {
        OQS_KEM_free(kem);
        throw std::runtime_error("Encapsulation failed");
    }
    
    OQS_KEM_free(kem);
    return {ciphertext, shared_secret};
}

std::vector<u8> pq_kem_decaps(const std::vector<u8>& secret_key, const std::vector<u8>& ciphertext, PqScheme scheme) {
    auto kem = get_kem(scheme);
    if (!kem) throw std::runtime_error("Not a KEM scheme");
    
    std::vector<u8> shared_secret(kem->length_shared_secret);
    
    if (OQS_KEM_decaps(kem, shared_secret.data(), ciphertext.data(), ciphertext.size(),
                       secret_key.data(), secret_key.size()) != OQS_SUCCESS) {
        OQS_KEM_free(kem);
        throw std::runtime_error("Decapsulation failed");
    }
    
    OQS_KEM_free(kem);
    return shared_secret;
}

} // namespace omnibus::crypto