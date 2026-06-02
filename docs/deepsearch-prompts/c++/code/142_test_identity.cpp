// OEP-1 138/150 | path=tests/test_wallet.cpp | proj=omnibus-node-cpp | run=2026-06-01-cpp-v1
#include <catch2/catch.hpp>
#include "../include/omnibus/wallet/address.hpp"
#include "../include/omnibus/wallet/hd.hpp"
#include "../include/omnibus/crypto/bip32.hpp"

using namespace omnibus::wallet;

TEST_CASE("EIP-55 checksum", "[wallet]") {
    std::string lower = "0x5aaeb6053f3e94c9b9a09f33669435e7ef1beaed";
    auto checksum = to_checksum_address(lower);
    REQUIRE(checksum == "0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed");
    REQUIRE(verify_checksum_address(checksum));
}

TEST_CASE("BIP-39 PBKDF2 official test vector", "[wallet]") {
    std::string mnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
    std::string passphrase = "TREZOR";
    auto seed = crypto::mnemonic_to_seed(mnemonic, passphrase);
    
    const u8 expected[32] = {
        0xc5, 0x52, 0x57, 0xc3, 0x60, 0xc0, 0x7c, 0x72,
        0x02, 0x9a, 0xeb, 0xc1, 0xb5, 0x3c, 0x05, 0xed,
        0x03, 0x62, 0xad, 0xa3, 0x8e, 0xad, 0x3e, 0x3e,
        0x9e, 0xfa, 0x37, 0x08, 0xe5, 0x34, 0x95, 0x53
    };
    
    REQUIRE(std::equal(seed.begin(), seed.begin() + 32, expected));
}

TEST_CASE("Trezor BIP-44 ETH address", "[wallet]") {
    std::string mnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
    auto seed = crypto::mnemonic_to_seed(mnemonic, "TREZOR");
    auto master = crypto::master_key_from_seed(seed);
    auto eth_addr = evm_address(master, 0, 0, 0);
    
    // Known address from test vector
    REQUIRE(eth_addr == "0x9858EfFD232B4033E47d90003D41EC34EcaEda94");
}

TEST_CASE("Native address parsing", "[wallet]") {
    auto addr = Address("ob1qxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx");
    REQUIRE(addr.is_valid());
    REQUIRE(addr.type() == AddressType::Native);
    
    auto str = addr.to_string();
    REQUIRE(!str.empty());
}