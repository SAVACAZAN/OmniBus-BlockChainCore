// OEP-1 37/150 | path=src/crypto/secp256k1.cpp | proj=omnibus-node-cpp | run=2026-06-01-cpp-v1
#include "../../include/omnibus/crypto/secp256k1.hpp"
#include "../../include/omnibus/crypto/sha256.hpp"
#include "../../include/omnibus/crypto/ripemd160.hpp"
#include <cstring>
#include <stdexcept>

namespace omnibus::crypto {

Secp256k1::Secp256k1() {
    ctx = secp256k1_context_create(SECP256K1_CONTEXT_VERIFY | SECP256K1_CONTEXT_SIGN);
    if (!ctx) throw std::runtime_error("Failed to create secp256k1 context");
}

Secp256k1::~Secp256k1() {
    if (ctx) secp256k1_context_destroy(ctx);
}

std::vector<u8> Secp256k1::pubkey_compress(const std::vector<u8>& pubkey_uncompressed) {
    secp256k1_pubkey pubkey;
    if (!secp256k1_ec_pubkey_parse(ctx, &pubkey, pubkey_uncompressed.data(), pubkey_uncompressed.size())) {
        throw std::runtime_error("Invalid pubkey");
    }
    std::vector<u8> compressed(33);
    size_t out_len = 33;
    secp256k1_ec_pubkey_serialize(ctx, compressed.data(), &out_len, &pubkey, SECP256K1_EC_COMPRESSED);
    return compressed;
}

std::vector<u8> Secp256k1::pubkey_uncompress(const std::vector<u8>& pubkey_compressed) {
    secp256k1_pubkey pubkey;
    if (!secp256k1_ec_pubkey_parse(ctx, &pubkey, pubkey_compressed.data(), pubkey_compressed.size())) {
        throw std::runtime_error("Invalid pubkey");
    }
    std::vector<u8> uncompressed(65);
    size_t out_len = 65;
    secp256k1_ec_pubkey_serialize(ctx, uncompressed.data(), &out_len, &pubkey, SECP256K1_EC_UNCOMPRESSED);
    return uncompressed;
}

Hash160 Secp256k1::hash160_pubkey(const std::vector<u8>& pubkey) {
    auto sha = sha256(pubkey.data(), pubkey.size());
    return ripemd160(sha.data(), sha.size());
}

bool Secp256k1::verify(const Hash256& hash, const Sig64& sig, const std::vector<u8>& pubkey) {
    secp256k1_pubkey pub;
    if (!secp256k1_ec_pubkey_parse(ctx, &pub, pubkey.data(), pubkey.size())) {
        return false;
    }
    secp256k1_ecdsa_signature sig_parsed;
    if (!secp256k1_ecdsa_signature_parse_compact(ctx, &sig_parsed, sig.data())) {
        return false;
    }
    return secp256k1_ecdsa_verify(ctx, &sig_parsed, hash.data(), &pub) == 1;
}

std::optional<Sig64> Secp256k1::sign(const Hash256& hash, const std::vector<u8>& seckey) {
    if (seckey.size() != 32) return std::nullopt;
    secp256k1_ecdsa_signature sig_parsed;
    if (!secp256k1_ecdsa_sign(ctx, &sig_parsed, hash.data(), seckey.data(), nullptr, nullptr)) {
        return std::nullopt;
    }
    Sig64 sig;
    secp256k1_ecdsa_signature_serialize_compact(ctx, sig.data(), &sig_parsed);
    return sig;
}

std::optional<std::vector<u8>> Secp256k1::recover_pubkey(const Hash256& hash, const Sig64& sig, bool compressed) {
    secp256k1_ecdsa_recoverable_signature recover_sig;
    if (!secp256k1_ecdsa_recoverable_signature_parse_compact(ctx, &recover_sig, sig.data(), 0)) {
        return std::nullopt;
    }
    secp256k1_pubkey pubkey;
    if (!secp256k1_ecdsa_recover(ctx, &pubkey, &recover_sig, hash.data())) {
        return std::nullopt;
    }
    std::vector<u8> out(compressed ? 33 : 65);
    size_t out_len = out.size();
    secp256k1_ec_pubkey_serialize(ctx, out.data(), &out_len, &pubkey,
                                  compressed ? SECP256K1_EC_COMPRESSED : SECP256K1_EC_UNCOMPRESSED);
    return out;
}

Secp256k1 secp256k1;

} // namespace omnibus::crypto