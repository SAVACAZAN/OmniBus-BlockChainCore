// OEP-1 140/150 | path=tests/test_p2p.cpp | proj=omnibus-node-cpp | run=2026-06-01-cpp-v1
#include <catch2/catch.hpp>
#include "../include/omnibus/p2p/wire.hpp"
#include "../include/omnibus/p2p/peer.hpp"
#include "../include/omnibus/codec.hpp"

using namespace omnibus::p2p;
using namespace omnibus;

TEST_CASE("Hello message serialization", "[p2p]") {
    Hello hello;
    hello.version = 1;
    hello.timestamp = 1234567890;
    hello.nonce = 0xDEADBEEFCAFEBABE;
    hello.user_agent = {'t','e','s','t'};
    hello.network = Network::Mainnet;
    hello.height = 1000;
    
    auto serialized = hello.serialize();
    auto deserialized = Hello::deserialize(serialized.data(), serialized.size());
    
    REQUIRE(deserialized.version == hello.version);
    REQUIRE(deserialized.timestamp == hello.timestamp);
    REQUIRE(deserialized.nonce == hello.nonce);
    REQUIRE(deserialized.user_agent == hello.user_agent);
    REQUIRE(deserialized.network == hello.network);
    REQUIRE(deserialized.height == hello.height);
}

TEST_CASE("Varint encoding/decoding", "[p2p]") {
    std::vector<u64> test_values = {0, 1, 127, 128, 16384, 2097152, 0xFFFFFFFFFFFFFFFF};
    
    for (u64 val : test_values) {
        auto encoded = codec::encode_varint(val);
        const u8* ptr = encoded.data();
        size_t len = encoded.size();
        auto decoded = codec::decode_varint(ptr, len);
        REQUIRE(decoded == val);
    }
}

TEST_CASE("Network magic bytes", "[p2p]") {
    REQUIRE(consensus::network_magic(Network::Mainnet) == 0x4F4D4E49); // 'OMNI'
    REQUIRE(consensus::network_magic(Network::Testnet) == 0x54455354); // 'TEST'
    REQUIRE(consensus::network_magic(Network::Devnet) == 0x4445564E);  // 'DEVN'
    REQUIRE(consensus::network_magic(Network::Regtest) == 0x52454754); // 'REGT'
}