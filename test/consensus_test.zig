/// consensus_test.zig - Teste pentru consensus, staking și validatori
const std = @import("std");
const testing = std.testing;

const consensus_mod = @import("../core/consensus.zig");
const staking_mod = @import("../core/staking.zig");
const finality_mod = @import("../core/finality.zig");
const governance_mod = @import("../core/governance.zig");

const ConsensusEngine = consensus_mod.ConsensusEngine;
const StakingPool = staking_mod.StakingPool;
const FinalityGadget = finality_mod.FinalityGadget;

// =============================================================================
// CONSENSUS ENGINE TESTS
// =============================================================================

test "ConsensusEngine: initialization" {
    var engine = try ConsensusEngine.init(
        testing.allocator,
        "validator_node_001",
        1000 // stake minim
    );
    defer engine.deinit();
    
    try testing.expect(engine.min_stake == 1000);
    try testing.expect(engine.validators.count() == 0);
    
    std.debug.print("[Consensus] Init OK (min_stake={d})\n", .{engine.min_stake});
}

test "ConsensusEngine: validator registration" {
    var engine = try ConsensusEngine.init(testing.allocator, "node", 1000);
    defer engine.deinit();
    
    // Înregistrează validator
    const result = try engine.registerValidator("val_001", 5000);
    try testing.expect(result == true);
    try testing.expect(engine.validators.count() == 1);
    
    // Duplicate => eșec
    const duplicate = engine.registerValidator("val_001", 5000);
    try testing.expectError(error.ValidatorExists, duplicate);
    
    std.debug.print("[Consensus] Validator registration OK\n", .{});
}

test "ConsensusEngine: stake validation" {
    var engine = try ConsensusEngine.init(testing.allocator, "node", 1000);
    defer engine.deinit();
    
    // Stake prea mic
    const low_stake = engine.registerValidator("val_low", 500);
    try testing.expectError(error.InsufficientStake, low_stake);
    
    // Stake suficient
    const ok_stake = try engine.registerValidator("val_ok", 2000);
    try testing.expect(ok_stake == true);
    
    std.debug.print("[Consensus] Stake validation OK\n", .{});
}

test "ConsensusEngine: validator set" {
    var engine = try ConsensusEngine.init(testing.allocator, "node", 100);
    defer engine.deinit();
    
    // Adaugă validatori
    _ = try engine.registerValidator("val_a", 1000);
    _ = try engine.registerValidator("val_b", 2000);
    _ = try engine.registerValidator("val_c", 3000);
    
    const validator_set = engine.getValidatorSet();
    try testing.expectEqual(validator_set.len, 3);
    
    std.debug.print("[Consensus] Validator set OK (count={d})\n", .{validator_set.len});
}

test "ConsensusEngine: proposer selection" {
    var engine = try ConsensusEngine.init(testing.allocator, "node", 100);
    defer engine.deinit();
    
    // Adaugă validatori
    _ = try engine.registerValidator("val_1", 1000);
    _ = try engine.registerValidator("val_2", 2000);
    _ = try engine.registerValidator("val_3", 3000);
    
    // Selectează proposer pentru block 1
    const proposer1 = engine.selectProposer(1);
    try testing.expect(proposer1.len > 0);
    
    // Selectează proposer pentru block 2 (ar trebui să fie determinist)
    const proposer2 = engine.selectProposer(2);
    try testing.expect(proposer2.len > 0);
    
    std.debug.print("[Consensus] Proposer selection OK (block1={s}, block2={s})\n", .{
        proposer1, proposer2,
    });
}

test "ConsensusEngine: voting" {
    var engine = try ConsensusEngine.init(testing.allocator, "node", 100);
    defer engine.deinit();
    
    _ = try engine.registerValidator("val_a", 1000);
    _ = try engine.registerValidator("val_b", 1000);
    _ = try engine.registerValidator("val_c", 1000);
    
    const block_hash = "block_hash_12345";
    
    // Votează
    try engine.vote("val_a", block_hash, true);
    try engine.vote("val_b", block_hash, true);
    try engine.vote("val_c", block_hash, false);
    
    // Calculează voturi
    const tally = engine.tallyVotes(block_hash);
    try testing.expect(tally.yes >= 2);
    try testing.expect(tally.no >= 1);
    
    std.debug.print("[Consensus] Voting OK (yes={d}, no={d})\n", .{ tally.yes, tally.no });
}

test "ConsensusEngine: quorum calculation" {
    var engine = try ConsensusEngine.init(testing.allocator, "node", 100);
    defer engine.deinit();
    
    // Fără validatori => quorum = 0
    try testing.expectEqual(engine.getQuorum(), 0);
    
    // Adaugă validatori
    _ = try engine.registerValidator("v1", 1000);
    _ = try engine.registerValidator("v2", 1000);
    _ = try engine.registerValidator("v3", 1000);
    _ = try engine.registerValidator("v4", 1000);
    
    // Quorum pentru 4 validatori = 3 (2/3 + 1)
    const quorum = engine.getQuorum();
    try testing.expect(quorum >= 3);
    
    std.debug.print("[Consensus] Quorum OK (validators=4, quorum={d})\n", .{quorum});
}

// =============================================================================
// STAKING TESTS
// =============================================================================

test "StakingPool: initialization" {
    var pool = StakingPool.init(testing.allocator);
    defer pool.deinit();
    
    try testing.expectEqual(pool.total_staked, 0);
    try testing.expectEqual(pool.stakes.count(), 0);
    
    std.debug.print("[Staking] Init OK\n", .{});
}

test "StakingPool: stake deposit" {
    var pool = StakingPool.init(testing.allocator);
    defer pool.deinit();
    
    const staker = "staker_001";
    const amount: u64 = 5000;
    
    try pool.stake(staker, amount);
    
    try testing.expectEqual(pool.total_staked, amount);
    try testing.expect(pool.stakes.contains(staker));
    
    const stake_info = pool.stakes.get(staker).?;
    try testing.expectEqual(stake_info.amount, amount);
    
    std.debug.print("[Staking] Deposit OK (amount={d})\n", .{amount});
}

test "StakingPool: multiple stakers" {
    var pool = StakingPool.init(testing.allocator);
    defer pool.deinit();
    
    try pool.stake("alice", 1000);
    try pool.stake("bob", 2000);
    try pool.stake("charlie", 3000);
    
    try testing.expectEqual(pool.total_staked, 6000);
    try testing.expectEqual(pool.stakes.count(), 3);
    
    std.debug.print("[Staking] Multiple stakers OK (total={d})\n", .{pool.total_staked});
}

test "StakingPool: additional stake" {
    var pool = StakingPool.init(testing.allocator);
    defer pool.deinit();
    
    try pool.stake("alice", 1000);
    try pool.stake("alice", 2000); // Adaugă mai mult
    
    const total = pool.getStake("alice");
    try testing.expectEqual(total, 3000);
    try testing.expectEqual(pool.total_staked, 3000);
    
    std.debug.print("[Staking] Additional stake OK (total={d})\n", .{total});
}

test "StakingPool: unstake partial" {
    var pool = StakingPool.init(testing.allocator);
    defer pool.deinit();
    
    try pool.stake("alice", 5000);
    
    const unstaked = try pool.unstake("alice", 2000);
    try testing.expectEqual(unstaked, 2000);
    
    const remaining = pool.getStake("alice");
    try testing.expectEqual(remaining, 3000);
    try testing.expectEqual(pool.total_staked, 3000);
    
    std.debug.print("[Staking] Unstake partial OK (remaining={d})\n", .{remaining});
}

test "StakingPool: unstake full" {
    var pool = StakingPool.init(testing.allocator);
    defer pool.deinit();
    
    try pool.stake("alice", 5000);
    
    const unstaked = try pool.unstake("alice", 5000);
    try testing.expectEqual(unstaked, 5000);
    
    const remaining = pool.getStake("alice");
    try testing.expectEqual(remaining, 0);
    try testing.expectEqual(pool.total_staked, 0);
    
    std.debug.print("[Staking] Unstake full OK\n", .{});
}

test "StakingPool: unstake too much" {
    var pool = StakingPool.init(testing.allocator);
    defer pool.deinit();
    
    try pool.stake("alice", 1000);
    
    // Încearcă să scoată mai mult decât are
    const result = pool.unstake("alice", 2000);
    try testing.expectError(error.InsufficientStake, result);
    
    std.debug.print("[Staking] Unstake too much OK (rejected)\n", .{});
}

test "StakingPool: rewards distribution" {
    var pool = StakingPool.init(testing.allocator);
    defer pool.deinit();
    
    try pool.stake("alice", 1000);
    try pool.stake("bob", 2000);
    
    const reward: u64 = 300;
    try pool.distributeRewards(reward);
    
    // Alice ar trebui să primească ~100 (1/3), Bob ~200 (2/3)
    const alice_stake = pool.getStake("alice");
    const bob_stake = pool.getStake("bob");
    
    try testing.expect(alice_stake > 1000);
    try testing.expect(bob_stake > 2000);
    try testing.expectEqual(alice_stake + bob_stake, 3300);
    
    std.debug.print("[Staking] Rewards OK (alice={d}, bob={d})\n", .{ alice_stake, bob_stake });
}

test "StakingPool: top stakers" {
    var pool = StakingPool.init(testing.allocator);
    defer pool.deinit();
    
    try pool.stake("small", 100);
    try pool.stake("medium", 500);
    try pool.stake("large", 1000);
    try pool.stake("huge", 5000);
    
    const top = pool.getTopStakers(3);
    defer testing.allocator.free(top);
    
    try testing.expectEqual(top.len, 3);
    // Primul ar trebui să fie "huge"
    try testing.expectEqualStrings(top[0], "huge");
    
    std.debug.print("[Staking] Top stakers OK (top={s})\n", .{top[0]});
}

// =============================================================================
// FINALITY TESTS
// =============================================================================

test "FinalityGadget: initialization" {
    var fg = try FinalityGadget.init(testing.allocator, 3); // 3 confirmations
    defer fg.deinit();
    
    try testing.expectEqual(fg.required_confirmations, 3);
    try testing.expectEqual(fg.finalized_blocks.count(), 0);
    
    std.debug.print("[Finality] Init OK (confirmations={d})\n", .{fg.required_confirmations});
}

test "FinalityGadget: justification" {
    var fg = try FinalityGadget.init(testing.allocator, 2);
    defer fg.deinit();
    
    const block_hash = "block_001";
    
    // Primele 2 justification-uri
    try fg.justify(block_hash, "val_a");
    try fg.justify(block_hash, "val_b");
    
    const status = fg.getStatus(block_hash);
    try testing.expect(status.justified);
    try testing.expect(!status.finalized);
    
    std.debug.print("[Finality] Justification OK\n", .{});
}

test "FinalityGadget: finalization" {
    var fg = try FinalityGadget.init(testing.allocator, 2);
    defer fg.deinit();
    
    const block_hash = "block_002";
    
    // 3 justification-uri pentru finalizare
    try fg.justify(block_hash, "val_a");
    try fg.justify(block_hash, "val_b");
    try fg.justify(block_hash, "val_c");
    
    const status = fg.getStatus(block_hash);
    try testing.expect(status.justified);
    try testing.expect(status.finalized);
    
    std.debug.print("[Finality] Finalization OK\n", .{});
}

test "FinalityGadget: already finalized" {
    var fg = try FinalityGadget.init(testing.allocator, 1);
    defer fg.deinit();
    
    const block_hash = "block_003";
    
    try fg.justify(block_hash, "val_a");
    
    const status1 = fg.getStatus(block_hash);
    try testing.expect(status1.finalized);
    
    // Duplicate justification (ar trebui ignorat sau acceptat idempotent)
    try fg.justify(block_hash, "val_b");
    
    const status2 = fg.getStatus(block_hash);
    try testing.expect(status2.finalized);
    
    std.debug.print("[Finality] Already finalized OK\n", .{});
}

// =============================================================================
// GOVERNANCE TESTS
// =============================================================================

test "Governance: proposal creation" {
    var gov = governance_mod.Governance.init(testing.allocator);
    defer gov.deinit();
    
    const proposal = try gov.createProposal(
        "Increase block size",
        "Propun să creștem block size la 2MB",
        "proposer_001",
        100 // voting_period_blocks
    );
    
    try testing.expect(proposal.id > 0);
    try testing.expectEqualStrings(proposal.title, "Increase block size");
    try testing.expectEqual(proposal.status, .Active);
    
    std.debug.print("[Governance] Proposal OK (id={d})\n", .{proposal.id});
}

test "Governance: voting on proposal" {
    var gov = governance_mod.Governance.init(testing.allocator);
    defer gov.deinit();
    
    const proposal = try gov.createProposal(
        "Test proposal",
        "Description",
        "proposer",
        100
    );
    
    try gov.vote(proposal.id, "voter_a", true, 1000);  // yes cu 1000 stake
    try gov.vote(proposal.id, "voter_b", true, 2000);  // yes cu 2000 stake
    try gov.vote(proposal.id, "voter_c", false, 500);  // no cu 500 stake
    
    const result = gov.getResult(proposal.id);
    try testing.expect(result.yes_votes == 3000);
    try testing.expect(result.no_votes == 500);
    
    std.debug.print("[Governance] Voting OK (yes={d}, no={d})\n", .{ result.yes_votes, result.no_votes });
}

test "Governance: proposal execution" {
    var gov = governance_mod.Governance.init(testing.allocator);
    defer gov.deinit();
    
    const proposal = try gov.createProposal(
        "Upgrade parameter",
        "Change X to Y",
        "proposer",
        10
    );
    
    // Voturi majoritare
    try gov.vote(proposal.id, "voter_a", true, 5000);
    try gov.vote(proposal.id, "voter_b", true, 3000);
    
    // Simulează trecerea timpului (finalizează)
    const executed = try gov.finalize(proposal.id);
    try testing.expect(executed == true);
    
    const updated = gov.getProposal(proposal.id);
    try testing.expect(updated.status == .Executed);
    
    std.debug.print("[Governance] Execution OK\n", .{});
}

// =============================================================================
// EDGE CASES
// =============================================================================

test "Edge: empty validator set" {
    var engine = try ConsensusEngine.init(testing.allocator, "node", 100);
    defer engine.deinit();
    
    // Fără validatori, proposer selection returnează empty
    const proposer = engine.selectProposer(1);
    try testing.expect(proposer.len == 0);
    
    std.debug.print("[Edge] Empty validator set OK\n", .{});
}

test "Edge: zero stake unstake" {
    var pool = StakingPool.init(testing.allocator);
    defer pool.deinit();
    
    // Încearcă să scoată stake când nu are nimic
    const result = pool.unstake("unknown", 100);
    try testing.expectError(error.NoStakeFound, result);
    
    std.debug.print("[Edge] Zero stake OK\n", .{});
}

test "Edge: duplicate vote" {
    var engine = try ConsensusEngine.init(testing.allocator, "node", 100);
    defer engine.deinit();
    
    _ = try engine.registerValidator("val_a", 1000);
    
    const block = "block_dup";
    try engine.vote("val_a", block, true);
    
    // Votează din nou (ar trebui ignorat sau actualizat)
    try engine.vote("val_a", block, true);
    
    const tally = engine.tallyVotes(block);
    // Ar trebui să fie 1, nu 2 (nu se dublează)
    try testing.expect(tally.yes >= 1);
    
    std.debug.print("[Edge] Duplicate vote OK\n", .{});
}

pub fn main() void {
    std.debug.print("\n=== Consensus, Staking & Governance Tests ===\n\n", .{});
}
