// OEP-1 7/33 | path=include/omnibus/crypto/ripemd160.hpp | proj=omnibus-node-cpp | run=2026-06-01-cpp-v1
#pragma once
#include "../types.hpp"
#include <cstddef>
#ifdef USE_OPENSSL
#include <openssl/ripemd.h>
#else
// Minimal implementation (or rely on libsodium if needed)
#include <cstring>
#endif

namespace omnibus::crypto {

inline Hash160 ripemd160(const u8* data, size_t len) {
    Hash160 out;
#ifdef USE_OPENSSL
    RIPEMD160_CTX ctx;
    RIPEMD160_Init(&ctx);
    RIPEMD160_Update(&ctx, data, len);
    RIPEMD160_Final(out.data(), &ctx);
#else
    // Stub: for portability we assume OpenSSL is used; otherwise link against libcrypto.
    // In full implementation, include a public domain RIPEMD-160.
    static_assert(false, "RIPEMD-160 requires OpenSSL or manual implementation");
#endif
    return out;
}

inline Hash160 ripemd160(const std::vector<u8>& data) {
    return ripemd160(data.data(), data.size());
}

} // namespace omnibus::crypto