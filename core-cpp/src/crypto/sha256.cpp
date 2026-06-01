#include "../../include/omnibus/crypto/sha256.hpp"
#include <cstring>

namespace omnibus::crypto {

#ifdef USE_OPENSSL
// OpenSSL implementation is header-only via inline in sha256.hpp
#else
// libsodium implementation is header-only
#endif

} // namespace omnibus::crypto