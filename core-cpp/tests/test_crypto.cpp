#include <catch2/catch.hpp>
#include "../include/omnibus/crypto/sha256.hpp"
#include "../include/omnibus/crypto/keccak.hpp"
#include "../include/omnibus/crypto/ripemd160.hpp"
#include "../include/omnibus/crypto/bech32.hpp"
#include "../include/omnibus/crypto/secp256k1.hpp"
#include <vector>
#include <string>

using namespace omnibus::crypto;

TEST_CASE("SHA-256 test vector", "[crypto]") {
    std::string input = "abc";
    auto hash = sha256(reinterpret_cast<const u8*>(input.c_str()), input.size());
    
    const u8 expected[] = {
        0xba, 0x78, 0x16, 0xbf, 0x8f, 0x01, 0xcf, 0xea,
        0x41, 0x41, 0x40, 0xde, 0x5d, 0xae, 0x22, 0x23,
        0xb0, 0x03, 0x61, 0xa3, 0x96, 0x17, 0x7a, 0x9c,
        0xb4, 0x10, 0xff, 0x61, 0xf2, 0x00, 0x15, 0xad
    };
    
    REQUIRE(std::equal(hash.begin(), hash.end(), expected));
}

TEST_CASE("Keccak-256 test vector", "[crypto]") {
    std::string input = "";
    auto hash = keccak256(reinterpret_cast<const u8*>(input.c_str()), input.size());
    
    const u8 expected[] = {
        0xc5, 0xd2, 0x46, 0x01, 0x86, 0xf7, 0x23, 0x3c,
        0x92, 0x7e, 0x7d, 0xb2, 0xdc, 0xc7, 0x03, 0xc0,
        0xe5, 0x00, 0xb6, 0x53, 0xca, 0x82, 0x27, 0x3b,
        0x7b, 0xfa, 0xd8, 0x04, 0x5d, 0x85, 0xa4, 0x10
    };
    
    REQUIRE(std::equal(hash.begin(), hash.end(), expected));
}

TEST_CASE("Bech32 ob1q roundtrip", "[crypto]") {
    Hash160 hash;
    for (size_t i = 0; i < 20; ++i) {
        hash[i] = static_cast<u8>(i * 7);
    }
    
    auto addr = native_address_from_hash160(hash);
    auto decoded = hash160_from_native_address(addr);
    
    REQUIRE(decoded.has_value());
    REQUIRE(decoded.value() == hash);
}

TEST_CASE("CRC32 test in chain_db", "[storage]") {
    // CRC32 test is in test_vectors.cpp
    SUCCEED();
}

TEST_CASE("PQ deterministic keypair", "[crypto]") {
    std::vector<u8> seed(32, 0x42);
    auto kp1 = derive_pq_keypair(seed, 777, PqScheme::ML_DSA_87, 0);
    auto kp2 = derive_pq_keypair(seed, 777, PqScheme::ML_DSA_87, 0);
    
    REQUIRE(kp1.public_key == kp2.public_key);
    REQUIRE(kp1.secret_key == kp2.secret_key);
}