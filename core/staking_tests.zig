// staking_tests.zig — extracted inline tests from staking.zig
//
// Zig 0.15.2 constraint: `zig test` operates on the root file and pulls in
// only the symbols it transitively imports. Tests living in a separate
// test-only file therefore must @import the module they exercise. We keep
// these tests inside core/ (not a top-level tests/ dir) so the relative
// @import path stays trivial and so the build-step wiring in build.zig
// (addTest with path "core/staking_tests.zig") stays uniform with the
// other test files in this directory.

const std = @import("std");
const testing = std.testing;

const staking_mod = @import("staking.zig");
const Validator = staking_mod.Validator;
const ValidatorStatus = staking_mod.ValidatorStatus;
const StakingEngine = staking_mod.StakingEngine;
const SlashEvidence = staking_mod.SlashEvidence;
const SlashReason = staking_mod.SlashReason;
const VALIDATOR_MIN_STAKE = staking_mod.VALIDATOR_MIN_STAKE;
const UNBONDING_PERIOD = staking_mod.UNBONDING_PERIOD;
const SLASH_EQUIVOCATION_PCT = staking_mod.SLASH_EQUIVOCATION_PCT;
const SLASH_DOUBLE_SIGN_PCT = staking_mod.SLASH_DOUBLE_SIGN_PCT;
const SLASH_INVALID_BLOCK_PCT = staking_mod.SLASH_INVALID_BLOCK_PCT;
const DOWNTIME_PENALTY_PCT = staking_mod.DOWNTIME_PENALTY_PCT;
const REPORTER_REWARD_PCT = staking_mod.REPORTER_REWARD_PCT;

test "Validator init" {
    const v = Validator.init("ob1q7qlex9x88rf8wny0t09vg5emf5fmd0ksamk0xz", VALIDATOR_MIN_STAKE, 100);
    try testing.expectEqual(ValidatorStatus.pending, v.status);
    try testing.expectEqual(VALIDATOR_MIN_STAKE, v.total_stake);
    try testing.expectEqual(VALIDATOR_MIN_STAKE, v.self_stake);
}

test "Validator uptime" {
    var v = Validator.init("ob1qat0h8a9yrccggrcvypwg248zugvjyjsxuzln5a", VALIDATOR_MIN_STAKE, 0);
    v.blocks_produced = 95;
    v.blocks_missed = 5;
    try testing.expectEqual(@as(u8, 95), v.uptimePct());
}

test "StakingEngine — register validator" {
    var engine = StakingEngine.init();
    const idx = try engine.registerValidator("ob1qn45nph35e84nfjd3dvtx8qpfvm0aljmd9x68z2", VALIDATOR_MIN_STAKE, 100);
    try testing.expectEqual(@as(u8, 0), idx);
    try testing.expectEqual(@as(usize, 1), engine.validator_count);
    try testing.expectEqual(VALIDATOR_MIN_STAKE, engine.total_staked);
}

test "StakingEngine — insufficient stake fails" {
    var engine = StakingEngine.init();
    try testing.expectError(error.InsufficientStake,
        engine.registerValidator("ob1q9a93l0vua9shmad50dsq9x4h6gvurvy9t8q3ja", 1000, 100));
}

test "StakingEngine — duplicate registration fails" {
    var engine = StakingEngine.init();
    _ = try engine.registerValidator("ob1ql4jvfk9f2r6znns0z9n7wygq0gksx8547nuvw9", VALIDATOR_MIN_STAKE, 100);
    try testing.expectError(error.AlreadyRegistered,
        engine.registerValidator("ob1ql4jvfk9f2r6znns0z9n7wygq0gksx8547nuvw9", VALIDATOR_MIN_STAKE, 200));
}

test "StakingEngine — activate and unbond flow" {
    var engine = StakingEngine.init();
    const idx = try engine.registerValidator("ob1q9yuwmz5qqands5hjxezasa3lkyafw22t90n2vn", VALIDATOR_MIN_STAKE, 100);

    try engine.activateValidator(idx);
    try testing.expectEqual(ValidatorStatus.active, engine.validators[idx].status);
    try testing.expectEqual(@as(usize, 1), engine.activeCount());

    try engine.startUnbonding(idx, 1000);
    try testing.expectEqual(ValidatorStatus.unbonding, engine.validators[idx].status);
    try testing.expectEqual(@as(usize, 0), engine.activeCount());

    // Cannot complete before unbonding period
    try testing.expectError(error.UnbondingNotComplete,
        engine.completeUnbonding(idx, 1000 + UNBONDING_PERIOD - 1));

    // Can complete after unbonding period
    const returned = try engine.completeUnbonding(idx, 1000 + UNBONDING_PERIOD);
    try testing.expectEqual(VALIDATOR_MIN_STAKE, returned);
    try testing.expectEqual(ValidatorStatus.unbonded, engine.validators[idx].status);
}

test "StakingEngine — slash equivocation" {
    var engine = StakingEngine.init();
    const idx = try engine.registerValidator("ob1q9mgarh46sx6h2erms78rycteuu94z6gekrd7ul", VALIDATOR_MIN_STAKE * 2, 100);
    try engine.activateValidator(idx);

    const slashed = try engine.slashEquivocation(idx);
    // 5% of 200 OMNI = 10 OMNI
    try testing.expectEqual(VALIDATOR_MIN_STAKE * 2 * SLASH_EQUIVOCATION_PCT / 100, slashed);
    try testing.expectEqual(ValidatorStatus.slashed, engine.validators[idx].status);
    try testing.expectEqual(@as(u32, 1), engine.total_slashes);
}

test "StakingEngine — select proposer" {
    var engine = StakingEngine.init();
    _ = try engine.registerValidator("ob1qh4gxcp778xhq6fpuz46u64qt7fv8y9a8l8mgac", VALIDATOR_MIN_STAKE, 100);
    _ = try engine.registerValidator("ob1qd976t74mp7ga3td4h8xquf796ks3xzjn3p7pfk", VALIDATOR_MIN_STAKE * 3, 100);
    try engine.activateValidator(0);
    try engine.activateValidator(1);

    const hash = [_]u8{0x42} ** 32;
    const proposer = engine.selectProposer(hash);
    try testing.expect(proposer != null);
}

test "StakingEngine — distribute rewards" {
    var engine = StakingEngine.init();
    _ = try engine.registerValidator("ob1qvk2hztyyxk5rh3r3zkxq3peknrrpvzsdgn8vum", VALIDATOR_MIN_STAKE, 100);
    _ = try engine.registerValidator("ob1qxtmhxjw00mkyql4ukgg9vgyjlsw4vq2qkhhcdk", VALIDATOR_MIN_STAKE, 100);
    try engine.activateValidator(0);
    try engine.activateValidator(1);

    engine.distributeRewards(1_000_000); // 1M SAT
    // Equal stake -> equal rewards
    try testing.expectEqual(@as(u64, 500_000), engine.validators[0].total_rewards);
    try testing.expectEqual(@as(u64, 500_000), engine.validators[1].total_rewards);
    try testing.expectEqual(@as(u64, 1), engine.current_epoch);
}

test "StakingEngine — weighted reward distribution" {
    var engine = StakingEngine.init();
    _ = try engine.registerValidator("ob1qt40fdlsfdvvvl0w88knhkaeckdnzcpvshkwx6n", VALIDATOR_MIN_STAKE, 100);     // 100 OMNI
    _ = try engine.registerValidator("ob1qd0xalqdwekzlknn4m3nc2espxdyzhxm2urksk6", VALIDATOR_MIN_STAKE * 3, 100); // 300 OMNI
    try engine.activateValidator(0);
    try engine.activateValidator(1);

    engine.distributeRewards(4_000_000); // 4M SAT
    // 1:3 ratio -> 1M : 3M
    try testing.expectEqual(@as(u64, 1_000_000), engine.validators[0].total_rewards);
    try testing.expectEqual(@as(u64, 3_000_000), engine.validators[1].total_rewards);
}

test "Validator — voting power 0 when not active" {
    var v = Validator.init("ob1q55e7hcjdm4jzqam8x84hxnat3tq96zn3lgv0ks", VALIDATOR_MIN_STAKE, 0);
    try testing.expectEqual(@as(u64, 0), v.votingPower()); // pending -> 0
    v.status = .active;
    try testing.expectEqual(VALIDATOR_MIN_STAKE, v.votingPower()); // active -> stake
}

// ─── Slashing Evidence Tests ────────────────────────────────────────────────

test "SlashEvidence — double-sign with valid evidence executes 33% slash" {
    var engine = StakingEngine.init();
    const stake = VALIDATOR_MIN_STAKE * 3; // 300 OMNI
    const idx = try engine.registerValidator("ob1q07wwsqfsufvqpddnktd65l0htscuk72s090s98", stake, 100);
    try engine.activateValidator(idx);

    // Create double-sign evidence: two different block hashes at same height
    const hash1 = [_]u8{0xAA} ** 32;
    const hash2 = [_]u8{0xBB} ** 32;
    const sig1  = [_]u8{0x11} ** 64;
    const sig2  = [_]u8{0x22} ** 64;
    const evidence = SlashEvidence.init(
        "ob1q07wwsqfsufvqpddnktd65l0htscuk72s090s98", .double_sign,
        hash1, hash2, 500, sig1, sig2,
        "ob1qsc95a03hqdmxfpj43gs67ur3tuwh05snre20xd", 1711800000,
    );

    const result = engine.submitSlashEvidence(evidence);
    try testing.expect(result.valid);

    // 33% of 300 OMNI = 99 OMNI
    const expected_slash = stake * SLASH_DOUBLE_SIGN_PCT / 100;
    try testing.expectEqual(expected_slash, result.slashed_amount);

    // Reporter gets 10% of slashed amount
    const expected_reward = expected_slash * REPORTER_REWARD_PCT / 100;
    try testing.expectEqual(expected_reward, result.reporter_reward);

    // New stake = 300 - 99 = 201 OMNI
    try testing.expectEqual(stake - expected_slash, result.new_stake);

    // Validator is marked slashed
    try testing.expectEqual(ValidatorStatus.slashed, engine.validators[idx].status);

    // Slash count incremented
    try testing.expectEqual(@as(u8, 1), engine.validators[idx].slash_count);
}

test "SlashEvidence — invalid evidence rejected (same block hash)" {
    var engine = StakingEngine.init();
    _ = try engine.registerValidator("ob1qw7y3hp3em4ga4dhz0jtpnqr6fq3sdl6tc69stv", VALIDATOR_MIN_STAKE, 100);
    try engine.activateValidator(0);

    // Same hash for both blocks — NOT double-signing
    const same_hash = [_]u8{0xCC} ** 32;
    const sig1 = [_]u8{0x11} ** 64;
    const sig2 = [_]u8{0x22} ** 64;
    const evidence = SlashEvidence.init(
        "ob1qw7y3hp3em4ga4dhz0jtpnqr6fq3sdl6tc69stv", .double_sign,
        same_hash, same_hash, 500, sig1, sig2,
        "ob1q84vr8qpzmztrxh0pp89m9ajmz277srgv7rs58n", 1711800000,
    );

    const result = engine.submitSlashEvidence(evidence);
    try testing.expect(!result.valid);
    try testing.expectEqual(@as(u64, 0), result.slashed_amount);
    // Validator should NOT be slashed
    try testing.expectEqual(ValidatorStatus.active, engine.validators[0].status);
}

test "SlashEvidence — reporter receives 10% of slashed amount" {
    var engine = StakingEngine.init();
    const stake = VALIDATOR_MIN_STAKE * 10; // 1000 OMNI
    _ = try engine.registerValidator("ob1qm42rt9lh268j0rl8kmcteyghrle0w3ae0twnn2", stake, 100);
    try engine.activateValidator(0);

    const evidence = SlashEvidence.init(
        "ob1qm42rt9lh268j0rl8kmcteyghrle0w3ae0twnn2", .double_sign,
        [_]u8{0xAA} ** 32, [_]u8{0xBB} ** 32, 500,
        [_]u8{0x11} ** 64, [_]u8{0x22} ** 64,
        "ob1qqxmalxrqce9hh3vy6mw8p438fqc62q7vyjznrw", 1711800000,
    );

    const result = engine.submitSlashEvidence(evidence);
    try testing.expect(result.valid);

    // 33% of 1000 OMNI = 330 OMNI slashed
    const expected_slash = stake * SLASH_DOUBLE_SIGN_PCT / 100;
    // Reporter gets 10% of 330 = 33 OMNI
    const expected_reward = expected_slash * REPORTER_REWARD_PCT / 100;
    try testing.expectEqual(expected_reward, result.reporter_reward);
    try testing.expectEqual(expected_reward, engine.total_reporter_rewards);
}

test "SlashEvidence — downtime penalty is only 1%" {
    var engine = StakingEngine.init();
    const stake = VALIDATOR_MIN_STAKE * 10; // 1000 OMNI
    _ = try engine.registerValidator("ob1qg202f8sm2vd3pf2cfm3d4drwg53e66c8fpfruj", stake, 100);
    try engine.activateValidator(0);

    const evidence = SlashEvidence.init(
        "ob1qg202f8sm2vd3pf2cfm3d4drwg53e66c8fpfruj", .downtime,
        [_]u8{0xAA} ** 32, [_]u8{0xBB} ** 32, 500,
        [_]u8{0x11} ** 64, [_]u8{0x22} ** 64,
        "ob1qnm0sq0w2ctj7nqq80pmrukpwwx4rkphtfna0pp", 1711800000,
    );

    const result = engine.submitSlashEvidence(evidence);
    try testing.expect(result.valid);

    // 1% of 1000 OMNI = 10 OMNI
    const expected_slash = stake * DOWNTIME_PENALTY_PCT / 100;
    try testing.expectEqual(expected_slash, result.slashed_amount);

    // Downtime = jailed, NOT slashed (can recover)
    try testing.expectEqual(ValidatorStatus.jailed, engine.validators[0].status);
}

test "SlashEvidence — normal users cannot be slashed (no stake)" {
    var engine = StakingEngine.init();
    // No validators registered — attempting to slash a non-validator address

    const evidence = SlashEvidence.init(
        "ob1qe9kdhg5pnfekq284ksedqrne6g9x0v265vjvwm", .double_sign,
        [_]u8{0xAA} ** 32, [_]u8{0xBB} ** 32, 500,
        [_]u8{0x11} ** 64, [_]u8{0x22} ** 64,
        "ob1qsc95a03hqdmxfpj43gs67ur3tuwh05snre20xd", 1711800000,
    );

    const result = engine.submitSlashEvidence(evidence);
    try testing.expect(!result.valid);
    try testing.expectEqual(@as(u64, 0), result.slashed_amount);
}

test "SlashEvidence — invalid_block slashes 10%" {
    var engine = StakingEngine.init();
    const stake = VALIDATOR_MIN_STAKE * 5; // 500 OMNI
    _ = try engine.registerValidator("ob1q8vjkl2ulxhgnp9ze74xvzf85duxa9yprrp8tld", stake, 100);
    try engine.activateValidator(0);

    const evidence = SlashEvidence.init(
        "ob1q8vjkl2ulxhgnp9ze74xvzf85duxa9yprrp8tld", .invalid_block,
        [_]u8{0xAA} ** 32, [_]u8{0xBB} ** 32, 500,
        [_]u8{0x11} ** 64, [_]u8{0x22} ** 64,
        "ob1qjpz54z9j8sz7kdy855ykr2fa2cs0982mqadvl4", 1711800000,
    );

    const result = engine.submitSlashEvidence(evidence);
    try testing.expect(result.valid);

    // 10% of 500 OMNI = 50 OMNI
    const expected_slash = stake * SLASH_INVALID_BLOCK_PCT / 100;
    try testing.expectEqual(expected_slash, result.slashed_amount);
    try testing.expectEqual(ValidatorStatus.slashed, engine.validators[0].status);
}

test "SlashEvidence — slash history recorded correctly" {
    var engine = StakingEngine.init();
    _ = try engine.registerValidator("ob1q6dfqmn4kpak86f3mzkmzjcv0h0fhl823qtxr5q", VALIDATOR_MIN_STAKE * 5, 100);
    try engine.activateValidator(0);

    const evidence = SlashEvidence.init(
        "ob1q6dfqmn4kpak86f3mzkmzjcv0h0fhl823qtxr5q", .invalid_block,
        [_]u8{0xAA} ** 32, [_]u8{0xBB} ** 32, 777,
        [_]u8{0x11} ** 64, [_]u8{0x22} ** 64,
        "ob1qdzmdk6kf2fqxn9t5qv56dfy4yzxxjt9lpsvc6d", 1711800000,
    );

    const result = engine.submitSlashEvidence(evidence);
    try testing.expect(result.valid);

    // Check slash history
    const history = engine.getSlashHistory("ob1q6dfqmn4kpak86f3mzkmzjcv0h0fhl823qtxr5q");
    try testing.expectEqual(@as(usize, 1), history.count);

    const record = history.records[0];
    try testing.expectEqualStrings("ob1q6dfqmn4kpak86f3mzkmzjcv0h0fhl823qtxr5q", record.getValidator());
    try testing.expectEqual(SlashReason.invalid_block, record.reason);
    try testing.expectEqual(@as(u64, 777), record.block_height);
    try testing.expectEqualStrings("ob1qdzmdk6kf2fqxn9t5qv56dfy4yzxxjt9lpsvc6d", record.getReporter());
    try testing.expectEqual(result.slashed_amount, record.amount_slashed);
}

test "SlashEvidence — already-slashed validator rejected" {
    var engine = StakingEngine.init();
    _ = try engine.registerValidator("ob1qvpnjfq54zs8gjjnus3k2ukc2nlpquer8qd096w", VALIDATOR_MIN_STAKE * 3, 100);
    try engine.activateValidator(0);

    const evidence = SlashEvidence.init(
        "ob1qvpnjfq54zs8gjjnus3k2ukc2nlpquer8qd096w", .double_sign,
        [_]u8{0xAA} ** 32, [_]u8{0xBB} ** 32, 500,
        [_]u8{0x11} ** 64, [_]u8{0x22} ** 64,
        "ob1qsc95a03hqdmxfpj43gs67ur3tuwh05snre20xd", 1711800000,
    );

    // First slash succeeds
    const r1 = engine.submitSlashEvidence(evidence);
    try testing.expect(r1.valid);
    try testing.expectEqual(ValidatorStatus.slashed, engine.validators[0].status);

    // Second slash rejected (already slashed)
    const r2 = engine.submitSlashEvidence(evidence);
    try testing.expect(!r2.valid);
}

test "SlashEvidence — zero-hash evidence rejected" {
    var engine = StakingEngine.init();
    _ = try engine.registerValidator("ob1qzex282t39hhnf3w83s8qkd4urykd5969lurr7f", VALIDATOR_MIN_STAKE, 100);
    try engine.activateValidator(0);

    // Zero block hashes — invalid evidence
    const evidence = SlashEvidence.init(
        "ob1qzex282t39hhnf3w83s8qkd4urykd5969lurr7f", .double_sign,
        [_]u8{0} ** 32, [_]u8{0xBB} ** 32, 500,
        [_]u8{0x11} ** 64, [_]u8{0x22} ** 64,
        "ob1qsc95a03hqdmxfpj43gs67ur3tuwh05snre20xd", 1711800000,
    );

    const result = engine.submitSlashEvidence(evidence);
    try testing.expect(!result.valid);
}

test "SlashEvidence — getValidatorInfo returns slash status" {
    var engine = StakingEngine.init();
    _ = try engine.registerValidator("ob1qmptfv85h99as98m6q7kxpxtwj9sxnf8afmfufk", VALIDATOR_MIN_STAKE * 2, 100);
    try engine.activateValidator(0);

    // Before slash
    const info_before = engine.getValidatorInfo("ob1qmptfv85h99as98m6q7kxpxtwj9sxnf8afmfufk").?;
    try testing.expectEqual(ValidatorStatus.active, info_before.status);
    try testing.expectEqual(@as(u8, 0), info_before.slash_count);

    // Slash
    const evidence = SlashEvidence.init(
        "ob1qmptfv85h99as98m6q7kxpxtwj9sxnf8afmfufk", .double_sign,
        [_]u8{0xAA} ** 32, [_]u8{0xBB} ** 32, 500,
        [_]u8{0x11} ** 64, [_]u8{0x22} ** 64,
        "ob1qsc95a03hqdmxfpj43gs67ur3tuwh05snre20xd", 1711800000,
    );
    _ = engine.submitSlashEvidence(evidence);

    // After slash
    const info_after = engine.getValidatorInfo("ob1qmptfv85h99as98m6q7kxpxtwj9sxnf8afmfufk").?;
    try testing.expectEqual(ValidatorStatus.slashed, info_after.status);
    try testing.expectEqual(@as(u8, 1), info_after.slash_count);
    try testing.expectEqual(@as(u8, 1), info_after.slash_history_count);
}

test "SlashEvidence — findValidatorIndex" {
    var engine = StakingEngine.init();
    _ = try engine.registerValidator("ob1q53pw4mlyd6zal09t9n64y8xxduxwagu243dw92", VALIDATOR_MIN_STAKE, 100);
    _ = try engine.registerValidator("ob1q7q4cpxqdk64k4f2aplx6gfkz3n9y2fcv3hr4vp", VALIDATOR_MIN_STAKE, 100);

    try testing.expectEqual(@as(?usize, 0), engine.findValidatorIndex("ob1q53pw4mlyd6zal09t9n64y8xxduxwagu243dw92"));
    try testing.expectEqual(@as(?usize, 1), engine.findValidatorIndex("ob1q7q4cpxqdk64k4f2aplx6gfkz3n9y2fcv3hr4vp"));
    try testing.expectEqual(@as(?usize, null), engine.findValidatorIndex("ob1qg2ynfn7kl0zguy464cdefj5rekl2hfnujpwemu"));
}

test "SlashEvidence — min slash amount enforced" {
    var engine = StakingEngine.init();
    // Register with exactly min stake (100 OMNI)
    _ = try engine.registerValidator("ob1qnyf830tqvt2ga9eursstnyecqafe5kjlwye74v", VALIDATOR_MIN_STAKE, 100);
    try engine.activateValidator(0);

    // Downtime = 1% of 100 OMNI = 1 OMNI = 1_000_000_000 SAT (above MIN_SLASH_AMOUNT)
    const evidence = SlashEvidence.init(
        "ob1qnyf830tqvt2ga9eursstnyecqafe5kjlwye74v", .downtime,
        [_]u8{0xAA} ** 32, [_]u8{0xBB} ** 32, 500,
        [_]u8{0x11} ** 64, [_]u8{0x22} ** 64,
        "ob1qnm0sq0w2ctj7nqq80pmrukpwwx4rkphtfna0pp", 1711800000,
    );

    const result = engine.submitSlashEvidence(evidence);
    try testing.expect(result.valid);
    // 1% of 100 OMNI = 1 OMNI = 1_000_000_000 SAT
    try testing.expectEqual(VALIDATOR_MIN_STAKE * DOWNTIME_PENALTY_PCT / 100, result.slashed_amount);
}

test "ValidatorInfo — statusString" {
    var engine = StakingEngine.init();
    _ = try engine.registerValidator("ob1qtl52x3awh05zqpmmqyvv8am67d3c2dvlgqs3se", VALIDATOR_MIN_STAKE, 100);

    const info = engine.getValidatorInfo("ob1qtl52x3awh05zqpmmqyvv8am67d3c2dvlgqs3se").?;
    try testing.expectEqualStrings("pending", info.statusString());
}
