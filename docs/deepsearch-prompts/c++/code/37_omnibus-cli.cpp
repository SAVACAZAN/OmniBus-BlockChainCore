// OEP-1 33/33 | path=tests/test_vectors.cpp | proj=omnibus-node-cpp | run=2026-06-01-cpp-v1
#define CATCH_CONFIG_MAIN
#include <catch2/catch.hpp>
#include "../include/omnibus/crypto/bip32.hpp"
#include "../include/omnibus/crypto/bech32.hpp"
#include "../include/omnibus/crypto/sha256.hpp"
#include "../include/omnibus/consensus/genesis.hpp"
#include "../include/omnibus/consensus/params.hpp"
#include "../include/omnibus/wallet/address.hpp"
#include "../include/omnibus/storage/chain_db.hpp"

using namespace omnibus;

TEST_CASE("BIP-39 PBKDF2 official test vector", "[crypto]") {
    std::string mnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
    std::string passphrase = "TREZOR";
    auto seed = crypto::mnemonic_to_seed(mnemonic, passphrase);
    REQUIRE(seed.size() >= 32);
    // First 32 bytes should match known value
    const u8 expected[32] = {0xc5,0x52,0x57,0xc3,0x60,0xc0,0x7c,0x72,0x02,0x9a,0xeb,0xc1,0xb5,0x3c,0x05,0xed,0x03,0x62,0xad,0xa3,0x8e,0xad,0x3e,0x3e,0x9e,0xfa,0x37,0x08,0xe5,0x34,0x95,0x53};
    REQUIRE(std::equal(seed.begin(), seed.begin()+32, expected));
}

TEST_CASE("Trezor BIP-44 ETH address", "[wallet]") {
    std::string mnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
    auto seed = crypto::mnemonic_to_seed(mnemonic, "TREZOR");
    auto master = crypto::master_key_from_seed(seed);
    auto eth_addr = wallet::evm_address(master);
    // Known address: 0x9858EfFD232B4033E47d90003D41EC34EcaEda94
    REQUIRE(eth_addr == "0x9858EfFD232B4033E47d90003D41EC34EcaEda94");
}

TEST_CASE("Bech32 ob1q roundtrip", "[crypto]") {
    Hash160 hash = {0x75,0x1e,0x76,0xe8,/* ... rest dummy ... */ 0x3b,0xd6};
    // fill dummy properly
    std::fill(hash.begin(), hash.end(), 0xaa);
    hash[0]=0x75; hash[19]=0xd6;
    auto addr = crypto::native_address_from_hash160(hash);
    auto decoded = crypto::hash160_from_native_address(addr);
    REQUIRE(decoded.has_value());
    REQUIRE(decoded.value() == hash);
}

TEST_CASE("EIP-55 checksum", "[wallet]") {
    std::string lower = "0x5aaeb6053f3e94c9b9a09f33669435e7ef1beaed";
    auto checksum = wallet::to_checksum_address(lower);
    REQUIRE(checksum == "0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed");
    REQUIRE(wallet::verify_checksum_address(checksum));
}

TEST_CASE("CRC32-IEEE", "[storage]") {
    std::string data = "123456789";
    u32 crc = storage::ChainDB::crc32(reinterpret_cast<const u8*>(data.data()), data.size());
    REQUIRE(crc == 0xCBF43926);
}

TEST_CASE("Genesis hash", "[consensus]") {
    auto genesis = consensus::build_genesis_block(Network::Mainnet);
    auto hash = genesis.hash();
    REQUIRE(hash == consensus::MAINNET_GENESIS_HASH);
}

TEST_CASE("SubBlock pacing", "[consensus]") {
    REQUIRE(consensus::SUB_BLOCKS_PER_BLOCK == 10);
    REQUIRE(consensus::SUB_BLOCK_INTERVAL_MS == 40);
}

TEST_CASE("Reserved pair_id rejection", "[dex]") {
    dex::OrderBook book;
    for (u32 pid : {1,4}) {
        dex::Order order;
        order.pair_id = pid;
        REQUIRE(book.is_pair_allowed(pid) == false);
    }
}

END OEP-1 RUN: proj=omnibus-node-cpp | run=2026-06-01-cpp-v1 | files=33/33 | status=complete