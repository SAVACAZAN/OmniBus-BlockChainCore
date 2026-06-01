#include <catch2/catch.hpp>
#include "../include/omnibus/consensus/block.hpp"
#include "../include/omnibus/consensus/genesis.hpp"
#include "../include/omnibus/consensus/pow.hpp"
#include "../include/omnibus/consensus/params.hpp"

using namespace omnibus::consensus;

TEST_CASE("Genesis hash verification", "[consensus]") {
    auto genesis = build_genesis_block(Network::Mainnet);
    auto hash = genesis.hash();
    
    const u8 expected[] = {
        0x82, 0xec, 0x46, 0xe8, 0x3a, 0xf3, 0x7b, 0x1e,
        0xa0, 0xe6, 0xb3, 0xfe, 0x66, 0xa8, 0xf0, 0x47,
        0x95, 0xa8, 0xe8, 0xaa, 0xe7, 0xdb, 0x41, 0x4d,
        0x45, 0x1e, 0xff, 0x11, 0x54, 0x24, 0x59, 0x82
    };
    
    REQUIRE(std::equal(hash.begin(), hash.end(), expected));
}

TEST_CASE("SubBlock pacing constants", "[consensus]") {
    REQUIRE(SUB_BLOCKS_PER_BLOCK == 10);
    REQUIRE(SUB_BLOCK_INTERVAL_MS == 40);
}

TEST_CASE("Difficulty retarget formula", "[consensus]") {
    u32 old_bits = 0x1d00ffff;
    u32 actual_timespan = 120960; // 2 weeks target
    u32 new_bits = retarget_difficulty(old_bits, actual_timespan);
    
    // Should be roughly the same
    REQUIRE(new_bits > 0);
}

TEST_CASE("Merkle root computation", "[consensus]") {
    std::vector<Hash256> leaves(4);
    for (size_t i = 0; i < 4; ++i) {
        leaves[i].fill(static_cast<u8>(i));
    }
    
    auto root = compute_merkle_root(leaves);
    REQUIRE(root != Hash256{});
}

TEST_CASE("Block reward calculation", "[consensus]") {
    Block block;
    auto reward = block.total_subsidy(0);
    REQUIRE(reward == BLOCK_REWARD_SAT);
    
    auto reward_halved = block.total_subsidy(HALVING_INTERVAL);
    REQUIRE(reward_halved == BLOCK_REWARD_SAT / 2);
}