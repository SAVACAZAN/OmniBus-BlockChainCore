#pragma once
#include "../types.hpp"
#include <vector>
#include <optional>
#include <secp256k1.h>
#include <secp256k1_recovery.h>

namespace omnibus::crypto {

class Secp256k1 {
    secp256k1_context* ctx;
public:
    Secp256k1();
    ~Secp256k1();
    Secp256k1(const Secp256k1&) = delete;
    Secp256k1& operator=(const Secp256k1&) = delete;

    std::vector<u8> pubkey_compress(const std::vector<u8>& pubkey_uncompressed);
    std::vector<u8> pubkey_uncompress(const std::vector<u8>& pubkey_compressed);
    Hash160 hash160_pubkey(const std::vector<u8>& pubkey); // RIPEMD160(SHA256(pubkey))

    bool verify(const Hash256& hash, const Sig64& sig, const std::vector<u8>& pubkey);
    std::optional<Sig64> sign(const Hash256& hash, const std::vector<u8>& seckey);
    std::optional<std::vector<u8>> recover_pubkey(const Hash256& hash, const Sig64& sig, bool compressed);
};

extern Secp256k1 secp256k1;

} // namespace omnibus::crypto