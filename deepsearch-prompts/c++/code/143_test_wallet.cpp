// OEP-1 139/150 | path=tests/test_validation.cpp | proj=omnibus-node-cpp | run=2026-06-01-cpp-v1
#include <catch2/catch.hpp>
#include "../include/omnibus/validator/tier.hpp"
#include "../include/omnibus/validator/slashing.hpp"
#include "../include/omnibus/governance/proposal.hpp"

using namespace omnibus::validator;
using namespace omnibus::governance;

TEST_CASE("Validator tier calculation", "[validator]") {
    REQUIRE(tier_minimum_stake(ValidatorTier::OMNI) == 100);
    REQUIRE(tier_minimum_stake(ValidatorTier::LOVE) == 1000);
    REQUIRE(tier_minimum_stake(ValidatorTier::FOOD) == 10000);
    REQUIRE(tier_minimum_stake(ValidatorTier::RENT) == 100000);
    REQUIRE(tier_minimum_stake(ValidatorTier::VACATION) == 500000);
    
    REQUIRE(tier_from_stake(50) == ValidatorTier::OMNI);
    REQUIRE(tier_from_stake(500) == ValidatorTier::OMNI);
    REQUIRE(tier_from_stake(1500) == ValidatorTier::LOVE);
    REQUIRE(tier_from_stake(50000) == ValidatorTier::FOOD);
    REQUIRE(tier_from_stake(200000) == ValidatorTier::RENT);
    REQUIRE(tier_from_stake(1000000) == ValidatorTier::VACATION);
}

TEST_CASE("Slashing percentages", "[validator]") {
    SlashingManager slasher;
    u64 stake = 10000;
    
    u64 slash_double = slasher.calculate_slash_amount(stake, "double_sign");
    REQUIRE(slash_double == 3300); // 33%
    
    u64 slash_downtime = slasher.calculate_slash_amount(stake, "downtime");
    REQUIRE(slash_downtime == 1000); // 10%
    
    u64 slash_liveness = slasher.calculate_slash_amount(stake, "liveness");
    REQUIRE(slash_liveness == 100); // 1%
}

TEST_CASE("Governance proposal quorum", "[governance]") {
    Proposal proposal;
    proposal.quorum = 100;
    proposal.threshold = 5000; // 50%
    
    proposal.votes[Hash160{}] = VoteChoice::YES;
    proposal.votes[Hash160{}] = VoteChoice::YES;
    proposal.compute_tally();
    
    REQUIRE(proposal.tally[VoteChoice::YES] == 2);
    REQUIRE(proposal.tally[VoteChoice::NO] == 0);
    
    // Not enough quorum
    REQUIRE(proposal.can_pass() == false);
    
    // Add more votes
    for (int i = 0; i < 98; ++i) {
        proposal.votes[Hash160{}] = VoteChoice::YES;
    }
    proposal.compute_tally();
    REQUIRE(proposal.can_pass() == true);
}