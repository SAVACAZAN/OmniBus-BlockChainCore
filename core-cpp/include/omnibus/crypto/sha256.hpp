#pragma once
#include "../types.hpp"
#include <cstddef>
#ifdef USE_OPENSSL
#include <openssl/sha.h>
#else
#include <sodium/crypto_hash_sha256.h>
#endif

namespace omnibus::crypto {

inline Hash256 sha256(const u8* data, size_t len) {
    Hash256 out;
#ifdef USE_OPENSSL
    SHA256_CTX ctx;
    SHA256_Init(&ctx);
    SHA256_Update(&ctx, data, len);
    SHA256_Final(out.data(), &ctx);
#else
    crypto_hash_sha256(out.data(), data, len);
#endif
    return out;
}

inline Hash256 sha256(const std::vector<u8>& data) {
    return sha256(data.data(), data.size());
}

inline Hash256 sha256d(const u8* data, size_t len) {
    Hash256 first = sha256(data, len);
    return sha256(first.data(), first.size());
}

inline Hash256 sha256d(const std::vector<u8>& data) {
    return sha256d(data.data(), data.size());
}

} // namespace omnibus::crypto