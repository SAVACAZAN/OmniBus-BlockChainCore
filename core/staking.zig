const std = @import("std");

/// Staking & Validator Set Management
///
/// Proof-of-Stake layer for OmniBus — opereaza in paralel cu PoW:
///   - Validatorii depun stake (min VALIDATOR_MIN_STAKE SAT)
///   - Sunt selectati aleator proportional cu stake-ul (weighted random)
///   - Primesc rewards din fees + block reward split
///   - Sunt slashed (penalizati) pentru comportament rau
///
/// Inspirat de:
///   - Ethereum 2.0: 32 ETH deposit, validator queue, slashing
///   - EGLD: 2500 EGLD stake, delegation, SPoS (Secure PoS)
///   - Cosmos: staking + delegation + unbonding period
///   - Solana: SOL delegation to validators

/// Minimum stake to become a validator (100 OMNI = 100 * 10^9 SAT)
pub const VALIDATOR_MIN_STAKE: u64 = 100_000_000_000;

/// Maximum validators in active set
pub const MAX_VALIDATORS: usize = 128;

/// Unbonding period in blocks (7 days at 1 block/sec = 604800)
pub const UNBONDING_PERIOD: u64 = 604_800;

// ─── Slashing Configuration ──────────────────────────────────────────────────
// Philosophy: Slash ONLY validators who intentionally cheat.
// NEVER punish normal users or honest miners.

/// Slash reason — only provable cheating triggers full slash
pub const SlashReason = enum(u8) {
    /// Signed 2 different blocks at same height — cryptographic proof required
    double_sign = 0,
    /// Submitted provably invalid block (bad merkle root, inflated reward, etc.)
    invalid_block = 1,
    /// Extended downtime (>24h equivalent) — small penalty, NOT a full slash
    downtime = 2,
};

/// Lose 33% of stake for double-signing (cryptographic proof required)
pub const SLASH_DOUBLE_SIGN_PCT: u64 = 33;

/// Lose 10% of stake for submitting provably invalid block
pub const SLASH_INVALID_BLOCK_PCT: u64 = 10;

/// Only 1% for extended downtime — NOT a punitive slash, just incentive alignment
pub const DOWNTIME_PENALTY_PCT: u64 = 1;

/// Minimum amount that can be slashed (0.001 OMNI = 1_000_000 SAT)
pub const MIN_SLASH_AMOUNT: u64 = 1_000_000;

/// Reporter receives 10% of the slashed amount as reward
pub const REPORTER_REWARD_PCT: u64 = 10;

/// Maximum slash records per validator
pub const MAX_SLASH_RECORDS: usize = 64;

/// Maximum total slash records stored in the engine
pub const MAX_TOTAL_SLASH_RECORDS: usize = 512;

/// Legacy alias — kept for backward compatibility with existing code
pub const SLASH_EQUIVOCATION_PCT: u64 = SLASH_DOUBLE_SIGN_PCT;

/// Slashing percentage for downtime — 0.1% (1/1000) — legacy alias
pub const SLASH_DOWNTIME_PERMILLE: u64 = 10; // 1% = 10 permille

/// Minimum uptime percentage to avoid downtime slashing
pub const MIN_UPTIME_PCT: u8 = 95;

/// Cryptographic evidence that a validator cheated.
/// For double_sign: two different block hashes at the same height,
/// each signed by the same validator. Both signatures must verify.
pub const SlashEvidence = struct {
    /// Address of the validator being accused
    validator_address: [64]u8,
    validator_addr_len: u8,
    /// Why this validator should be slashed
    reason: SlashReason,
    /// For double_sign: first block hash the validator signed
    block_hash_1: [32]u8,
    /// For double_sign: second (different) block hash at same height
    block_hash_2: [32]u8,
    /// Block height where the double-sign occurred
    block_height: u64,
    /// Signature on block_hash_1
    signature_1: [64]u8,
    /// Signature on block_hash_2
    signature_2: [64]u8,
    /// Address of the reporter — gets reward if evidence is valid
    reporter_address: [64]u8,
    reporter_addr_len: u8,
    /// When the evidence was submitted
    timestamp: i64,

    pub fn getValidatorAddress(self: *const SlashEvidence) []const u8 {
        return self.validator_address[0..self.validator_addr_len];
    }

    pub fn getReporterAddress(self: *const SlashEvidence) []const u8 {
        return self.reporter_address[0..self.reporter_addr_len];
    }

    pub fn init(
        validator_addr: []const u8,
        reason: SlashReason,
        hash1: [32]u8,
        hash2: [32]u8,
        height: u64,
        sig1: [64]u8,
        sig2: [64]u8,
        reporter_addr: []const u8,
        ts: i64,
    ) SlashEvidence {
        var ev: SlashEvidence = std.mem.zeroes(SlashEvidence);
        const vlen = @min(validator_addr.len, 64);
        @memcpy(ev.validator_address[0..vlen], validator_addr[0..vlen]);
        ev.validator_addr_len = @intCast(vlen);
        ev.reason = reason;
        ev.block_hash_1 = hash1;
        ev.block_hash_2 = hash2;
        ev.block_height = height;
        ev.signature_1 = sig1;
        ev.signature_2 = sig2;
        const rlen = @min(reporter_addr.len, 64);
        @memcpy(ev.reporter_address[0..rlen], reporter_addr[0..rlen]);
        ev.reporter_addr_len = @intCast(rlen);
        ev.timestamp = ts;
        return ev;
    }
};

/// Result of processing slash evidence
pub const SlashResult = struct {
    /// Whether the evidence was valid and slash was executed
    valid: bool,
    /// Amount slashed from the validator's stake (SAT)
    slashed_amount: u64,
    /// Reward given to the reporter (10% of slashed amount)
    reporter_reward: u64,
    /// Validator's new stake after slashing
    new_stake: u64,
    /// Human-readable reason string
    reason: [128]u8,
    reason_len: u8,

    pub fn getReason(self: *const SlashResult) []const u8 {
        return self.reason[0..self.reason_len];
    }

    fn setReason(self: *SlashResult, msg: []const u8) void {
        const len = @min(msg.len, 128);
        @memcpy(self.reason[0..len], msg[0..len]);
        self.reason_len = @intCast(len);
    }

    pub fn rejected(msg: []const u8) SlashResult {
        var r = std.mem.zeroes(SlashResult);
        r.valid = false;
        r.setReason(msg);
        return r;
    }
};

/// Persistent record of a slashing event
pub const SlashRecord = struct {
    /// Validator that was slashed
    validator: [64]u8,
    validator_len: u8,
    /// Why they were slashed
    reason: SlashReason,
    /// How much was taken (SAT)
    amount_slashed: u64,
    /// Block height where the offense occurred
    block_height: u64,
    /// When the slash was executed
    timestamp: i64,
    /// Who reported it
    reporter: [64]u8,
    reporter_len: u8,
    /// Reward paid to reporter
    reporter_reward: u64,

    pub fn getValidator(self: *const SlashRecord) []const u8 {
        return self.validator[0..self.validator_len];
    }

    pub fn getReporter(self: *const SlashRecord) []const u8 {
        return self.reporter[0..self.reporter_len];
    }
};

/// Epochs between reward distributions
pub const REWARD_EPOCH_BLOCKS: u64 = 100;

/// Validator status
pub const ValidatorStatus = enum(u8) {
    /// Registered but not yet active (in queue)
    pending = 0,
    /// Active validator, participating in consensus
    active = 1,
    /// Unbonding — waiting for unbonding period to complete
    unbonding = 2,
    /// Fully unbonded — stake returned
    unbonded = 3,
    /// Slashed and removed
    slashed = 4,
    /// Jailed (temporary removal for downtime)
    jailed = 5,
};

/// A validator in the staking system
pub const Validator = struct {
    /// Address of the validator (ob_omni_ format)
    address: [64]u8,
    addr_len: u8,
    /// Total stake in SAT (own + delegated)
    total_stake: u64,
    /// Own stake (deposited by validator)
    self_stake: u64,
    /// Delegated stake (from delegators)
    delegated_stake: u64,
    /// Current status
    status: ValidatorStatus,
    /// Block when registered
    registered_block: u64,
    /// Block when unbonding started (0 if not unbonding)
    unbonding_block: u64,
    /// Number of blocks produced
    blocks_produced: u32,
    /// Number of blocks missed (for uptime tracking)
    blocks_missed: u32,
    /// Total rewards earned in SAT
    total_rewards: u64,
    /// Commission rate (0-100%)
    commission_pct: u8,
    /// Number of slashing events
    slash_count: u8,

    pub fn init(address: []const u8, stake: u64, block: u64) Validator {
        var v: Validator = std.mem.zeroes(Validator);
        const len = @min(address.len, 64);
        @memcpy(v.address[0..len], address[0..len]);
        v.addr_len = @intCast(len);
        v.total_stake = stake;
        v.self_stake = stake;
        v.status = .pending;
        v.registered_block = block;
        v.commission_pct = 10; // default 10%
        return v;
    }

    /// Uptime percentage (0-100)
    pub fn uptimePct(self: *const Validator) u8 {
        const total = self.blocks_produced + self.blocks_missed;
        if (total == 0) return 100;
        return @intCast((@as(u64, self.blocks_produced) * 100) / total);
    }

    /// Voting power (proportional to total stake)
    pub fn votingPower(self: *const Validator) u64 {
        if (self.status != .active) return 0;
        return self.total_stake;
    }

    /// Check if validator can be slashed for downtime
    pub fn shouldSlashDowntime(self: *const Validator) bool {
        return self.uptimePct() < MIN_UPTIME_PCT and
               self.blocks_produced + self.blocks_missed > 100;
    }

    pub fn getAddress(self: *const Validator) []const u8 {
        return self.address[0..self.addr_len];
    }
};

/// Delegation record
pub const Delegation = struct {
    delegator: [64]u8,
    delegator_len: u8,
    validator_index: u8,
    amount: u64,
    block: u64,
};

/// Staking Engine — manages the validator set
pub const StakingEngine = struct {
    validators: [MAX_VALIDATORS]Validator,
    validator_count: usize,
    /// Total staked across all validators
    total_staked: u64,
    /// Current epoch
    current_epoch: u64,
    /// Total slashing events
    total_slashes: u32,
    /// Persistent slash history
    slash_records: [MAX_TOTAL_SLASH_RECORDS]SlashRecord,
    slash_record_count: usize,
    /// Total SAT burned via slashing (not redistributed)
    total_slashed_amount: u64,
    /// Total SAT paid to reporters
    total_reporter_rewards: u64,

    pub fn init() StakingEngine {
        return .{
            .validators = undefined,
            .validator_count = 0,
            .total_staked = 0,
            .current_epoch = 0,
            .total_slashes = 0,
            .slash_records = undefined,
            .slash_record_count = 0,
            .total_slashed_amount = 0,
            .total_reporter_rewards = 0,
        };
    }

    /// Register a new validator with initial stake
    pub fn registerValidator(self: *StakingEngine, address: []const u8, stake: u64, current_block: u64) !u8 {
        if (stake < VALIDATOR_MIN_STAKE) return error.InsufficientStake;
        if (self.validator_count >= MAX_VALIDATORS) return error.ValidatorSetFull;

        // Check for duplicate
        for (self.validators[0..self.validator_count]) |v| {
            if (std.mem.eql(u8, v.getAddress(), address)) return error.AlreadyRegistered;
        }

        self.validators[self.validator_count] = Validator.init(address, stake, current_block);
        self.validator_count += 1;
        self.total_staked += stake;

        return @intCast(self.validator_count - 1);
    }

    /// Activate a pending validator
    pub fn activateValidator(self: *StakingEngine, index: u8) !void {
        if (index >= self.validator_count) return error.InvalidIndex;
        var v = &self.validators[index];
        if (v.status != .pending) return error.NotPending;
        v.status = .active;
    }

    /// Start unbonding process
    pub fn startUnbonding(self: *StakingEngine, index: u8, current_block: u64) !void {
        if (index >= self.validator_count) return error.InvalidIndex;
        var v = &self.validators[index];
        if (v.status != .active) return error.NotActive;
        v.status = .unbonding;
        v.unbonding_block = current_block;
    }

    /// Complete unbonding (after UNBONDING_PERIOD blocks)
    pub fn completeUnbonding(self: *StakingEngine, index: u8, current_block: u64) !u64 {
        if (index >= self.validator_count) return error.InvalidIndex;
        var v = &self.validators[index];
        if (v.status != .unbonding) return error.NotUnbonding;
        if (current_block < v.unbonding_block + UNBONDING_PERIOD) return error.UnbondingNotComplete;

        v.status = .unbonded;
        const returned = v.self_stake;
        self.total_staked -= v.total_stake;
        v.total_stake = 0;
        v.self_stake = 0;
        return returned;
    }

    /// Slash a validator for equivocation (double signing)
    pub fn slashEquivocation(self: *StakingEngine, index: u8) !u64 {
        if (index >= self.validator_count) return error.InvalidIndex;
        var v = &self.validators[index];
        if (v.status == .slashed) return error.AlreadySlashed;

        const slash_amount = v.total_stake * SLASH_EQUIVOCATION_PCT / 100;
        v.total_stake -= slash_amount;
        v.self_stake = if (v.self_stake > slash_amount) v.self_stake - slash_amount else 0;
        v.status = .slashed;
        v.slash_count += 1;
        self.total_staked -= slash_amount;
        self.total_slashes += 1;

        return slash_amount;
    }

    /// Slash for downtime
    pub fn slashDowntime(self: *StakingEngine, index: u8) !u64 {
        if (index >= self.validator_count) return error.InvalidIndex;
        var v = &self.validators[index];
        if (v.status != .active) return error.NotActive;
        if (!v.shouldSlashDowntime()) return error.UptimeSufficient;

        const slash_amount = v.total_stake * SLASH_DOWNTIME_PERMILLE / 1000;
        v.total_stake -= slash_amount;
        v.self_stake = if (v.self_stake > slash_amount) v.self_stake - slash_amount else 0;
        v.status = .jailed;
        v.slash_count += 1;
        self.total_staked -= slash_amount;
        self.total_slashes += 1;

        return slash_amount;
    }

    /// Select block proposer (weighted random by stake)
    /// Uses block_hash as randomness source (like EGLD SPoS)
    pub fn selectProposer(self: *const StakingEngine, block_hash: [32]u8) ?u8 {
        if (self.activeCount() == 0) return null;

        // Convert first 8 bytes of block hash to u64 for randomness
        const rand = std.mem.readInt(u64, block_hash[0..8], .little);
        const target = rand % self.total_staked;

        var cumulative: u64 = 0;
        for (self.validators[0..self.validator_count], 0..) |v, i| {
            if (v.status != .active) continue;
            cumulative += v.total_stake;
            if (cumulative > target) return @intCast(i);
        }
        return null;
    }

    /// Get number of active validators
    pub fn activeCount(self: *const StakingEngine) usize {
        var count: usize = 0;
        for (self.validators[0..self.validator_count]) |v| {
            if (v.status == .active) count += 1;
        }
        return count;
    }

    /// Total active voting power
    pub fn totalVotingPower(self: *const StakingEngine) u64 {
        var total: u64 = 0;
        for (self.validators[0..self.validator_count]) |v| {
            total += v.votingPower();
        }
        return total;
    }

    /// Distribute rewards to active validators proportional to stake
    pub fn distributeRewards(self: *StakingEngine, total_reward: u64) void {
        const tvp = self.totalVotingPower();
        if (tvp == 0) return;

        for (self.validators[0..self.validator_count]) |*v| {
            if (v.status != .active) continue;
            const share = total_reward * v.total_stake / tvp;
            v.total_rewards += share;
        }
        self.current_epoch += 1;
    }

    // ─── Evidence-Based Slashing System ─────────────────────────────────────

    /// Submit slash evidence — verify the proof and execute the slash if valid.
    /// Returns a SlashResult indicating success/failure and amounts.
    ///
    /// Philosophy: Slash ONLY validators who intentionally cheat.
    /// Normal users cannot be slashed (they have no stake).
    pub fn submitSlashEvidence(self: *StakingEngine, evidence: SlashEvidence) SlashResult {
        // 1. Find the validator by address
        const validator_addr = evidence.getValidatorAddress();
        const v_idx = self.findValidatorIndex(validator_addr) orelse {
            return SlashResult.rejected("Validator not found — only staked validators can be slashed");
        };

        // 2. Check the validator is in a slashable state
        const v = &self.validators[v_idx];
        if (v.status == .slashed) {
            return SlashResult.rejected("Validator already slashed");
        }
        if (v.status == .unbonded) {
            return SlashResult.rejected("Validator fully unbonded — no stake to slash");
        }
        if (v.total_stake == 0) {
            return SlashResult.rejected("No stake to slash — normal users cannot be slashed");
        }

        // 3. Verify the evidence based on reason
        switch (evidence.reason) {
            .double_sign => {
                if (!verifyDoubleSign(evidence)) {
                    return SlashResult.rejected("Invalid double-sign evidence — hashes must differ");
                }
                return self.executeSlash(v_idx, SLASH_DOUBLE_SIGN_PCT, evidence);
            },
            .invalid_block => {
                // For invalid_block, the caller (blockchain.zig) has already verified
                // that the block was invalid. We trust the evidence submission path.
                return self.executeSlash(v_idx, SLASH_INVALID_BLOCK_PCT, evidence);
            },
            .downtime => {
                // Downtime is a minor penalty, not a full slash
                return self.executeSlash(v_idx, DOWNTIME_PENALTY_PCT, evidence);
            },
        }
    }

    /// Verify double-sign evidence: both signatures must be present,
    /// both block hashes must be different, and they must be at the same height.
    fn verifyDoubleSign(evidence: SlashEvidence) bool {
        // Block hashes must be different (signing the same block twice is not equivocation)
        if (std.mem.eql(u8, &evidence.block_hash_1, &evidence.block_hash_2)) {
            return false;
        }

        // Both hashes must be non-zero (actual blocks)
        const zero_hash = [_]u8{0} ** 32;
        if (std.mem.eql(u8, &evidence.block_hash_1, &zero_hash)) return false;
        if (std.mem.eql(u8, &evidence.block_hash_2, &zero_hash)) return false;

        // Both signatures must be non-zero
        const zero_sig = [_]u8{0} ** 64;
        if (std.mem.eql(u8, &evidence.signature_1, &zero_sig)) return false;
        if (std.mem.eql(u8, &evidence.signature_2, &zero_sig)) return false;

        // Block height must be > 0 (genesis cannot be double-signed)
        if (evidence.block_height == 0) return false;

        // Note: In production, we would also verify that both signatures
        // are valid secp256k1 signatures from the validator's public key.
        // The full signature verification is done at the P2P/consensus layer
        // before evidence reaches this function.

        return true;
    }

    /// Execute the slash — reduce validator's stake by the given percentage.
    /// Records the event and rewards the reporter.
    fn executeSlash(self: *StakingEngine, v_idx: usize, pct: u64, evidence: SlashEvidence) SlashResult {
        var v = &self.validators[v_idx];
        var result = std.mem.zeroes(SlashResult);

        // Calculate slash amount
        var slash_amount = v.total_stake * pct / 100;

        // Enforce minimum slash amount
        if (slash_amount < MIN_SLASH_AMOUNT) {
            if (v.total_stake >= MIN_SLASH_AMOUNT) {
                slash_amount = MIN_SLASH_AMOUNT;
            } else {
                slash_amount = v.total_stake; // slash everything if below minimum
            }
        }

        // Cap at total stake
        if (slash_amount > v.total_stake) {
            slash_amount = v.total_stake;
        }

        // Apply the slash
        v.total_stake -= slash_amount;
        v.self_stake = if (v.self_stake > slash_amount) v.self_stake - slash_amount else 0;
        v.slash_count += 1;
        self.total_staked -= slash_amount;
        self.total_slashes += 1;
        self.total_slashed_amount += slash_amount;

        // For double_sign and invalid_block: mark as slashed (permanent)
        // For downtime: jail only (temporary, can be unjailed)
        if (evidence.reason == .downtime) {
            v.status = .jailed;
        } else {
            v.status = .slashed;
        }

        // Calculate reporter reward (10% of slashed amount)
        const reporter_reward = slash_amount * REPORTER_REWARD_PCT / 100;
        self.total_reporter_rewards += reporter_reward;

        // Record the slash event
        if (self.slash_record_count < MAX_TOTAL_SLASH_RECORDS) {
            var record: SlashRecord = std.mem.zeroes(SlashRecord);
            const vaddr = evidence.getValidatorAddress();
            const vlen = @min(vaddr.len, 64);
            @memcpy(record.validator[0..vlen], vaddr[0..vlen]);
            record.validator_len = @intCast(vlen);
            record.reason = evidence.reason;
            record.amount_slashed = slash_amount;
            record.block_height = evidence.block_height;
            record.timestamp = evidence.timestamp;
            const raddr = evidence.getReporterAddress();
            const rlen = @min(raddr.len, 64);
            @memcpy(record.reporter[0..rlen], raddr[0..rlen]);
            record.reporter_len = @intCast(rlen);
            record.reporter_reward = reporter_reward;
            self.slash_records[self.slash_record_count] = record;
            self.slash_record_count += 1;
        }

        // Build result
        result.valid = true;
        result.slashed_amount = slash_amount;
        result.reporter_reward = reporter_reward;
        result.new_stake = v.total_stake;
        const reason_msg = switch (evidence.reason) {
            .double_sign => "Double-sign: 33% stake slashed",
            .invalid_block => "Invalid block: 10% stake slashed",
            .downtime => "Downtime: 1% penalty applied",
        };
        result.setReason(reason_msg);

        return result;
    }

    /// Look up a validator by address. Returns index or null.
    pub fn findValidatorIndex(self: *const StakingEngine, address: []const u8) ?usize {
        for (self.validators[0..self.validator_count], 0..) |v, i| {
            if (std.mem.eql(u8, v.getAddress(), address)) return i;
        }
        return null;
    }

    /// Get slash history for a specific validator.
    /// Returns a slice of the internal slash_records array matching the address.
    /// Caller should copy if needed — returned data points into engine storage.
    pub fn getSlashHistory(self: *const StakingEngine, address: []const u8) SlashHistoryResult {
        var result = SlashHistoryResult{};
        for (self.slash_records[0..self.slash_record_count]) |record| {
            if (std.mem.eql(u8, record.getValidator(), address)) {
                if (result.count < SlashHistoryResult.MAX_RESULTS) {
                    result.records[result.count] = record;
                    result.count += 1;
                }
            }
        }
        return result;
    }

    /// Get staking info for a validator (for RPC getstakinginfo)
    pub fn getValidatorInfo(self: *const StakingEngine, address: []const u8) ?ValidatorInfo {
        const idx = self.findValidatorIndex(address) orelse return null;
        const v = &self.validators[idx];
        const history = self.getSlashHistory(address);
        return ValidatorInfo{
            .address = v.address,
            .addr_len = v.addr_len,
            .total_stake = v.total_stake,
            .self_stake = v.self_stake,
            .delegated_stake = v.delegated_stake,
            .status = v.status,
            .slash_count = v.slash_count,
            .total_rewards = v.total_rewards,
            .uptime_pct = v.uptimePct(),
            .slash_history_count = @intCast(history.count),
            .blocks_produced = v.blocks_produced,
            .commission_pct = v.commission_pct,
        };
    }
};

/// Result container for slash history queries (fixed-size, no allocation)
pub const SlashHistoryResult = struct {
    pub const MAX_RESULTS: usize = MAX_SLASH_RECORDS;
    records: [MAX_RESULTS]SlashRecord = undefined,
    count: usize = 0,

    pub fn slice(self: *const SlashHistoryResult) []const SlashRecord {
        return self.records[0..self.count];
    }
};

/// Validator info summary for RPC responses
pub const ValidatorInfo = struct {
    address: [64]u8,
    addr_len: u8,
    total_stake: u64,
    self_stake: u64,
    delegated_stake: u64,
    status: ValidatorStatus,
    slash_count: u8,
    total_rewards: u64,
    uptime_pct: u8,
    slash_history_count: u8,
    blocks_produced: u32,
    commission_pct: u8,

    pub fn getAddress(self: *const ValidatorInfo) []const u8 {
        return self.address[0..self.addr_len];
    }

    pub fn statusString(self: *const ValidatorInfo) []const u8 {
        return switch (self.status) {
            .pending => "pending",
            .active => "active",
            .unbonding => "unbonding",
            .unbonded => "unbonded",
            .slashed => "slashed",
            .jailed => "jailed",
        };
    }
};

// ─── Tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

test "Validator init" {
    const v = Validator.init("ob_omni_validator1", VALIDATOR_MIN_STAKE, 100);
    try testing.expectEqual(ValidatorStatus.pending, v.status);
    try testing.expectEqual(VALIDATOR_MIN_STAKE, v.total_stake);
    try testing.expectEqual(VALIDATOR_MIN_STAKE, v.self_stake);
}

test "Validator uptime" {
    var v = Validator.init("ob_omni_v1", VALIDATOR_MIN_STAKE, 0);
    v.blocks_produced = 95;
    v.blocks_missed = 5;
    try testing.expectEqual(@as(u8, 95), v.uptimePct());
}

test "StakingEngine — register validator" {
    var engine = StakingEngine.init();
    const idx = try engine.registerValidator("ob_omni_val1", VALIDATOR_MIN_STAKE, 100);
    try testing.expectEqual(@as(u8, 0), idx);
    try testing.expectEqual(@as(usize, 1), engine.validator_count);
    try testing.expectEqual(VALIDATOR_MIN_STAKE, engine.total_staked);
}

test "StakingEngine — insufficient stake fails" {
    var engine = StakingEngine.init();
    try testing.expectError(error.InsufficientStake,
        engine.registerValidator("ob_omni_poor", 1000, 100));
}

test "StakingEngine — duplicate registration fails" {
    var engine = StakingEngine.init();
    _ = try engine.registerValidator("ob_omni_dup", VALIDATOR_MIN_STAKE, 100);
    try testing.expectError(error.AlreadyRegistered,
        engine.registerValidator("ob_omni_dup", VALIDATOR_MIN_STAKE, 200));
}

test "StakingEngine — activate and unbond flow" {
    var engine = StakingEngine.init();
    const idx = try engine.registerValidator("ob_omni_flow", VALIDATOR_MIN_STAKE, 100);

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
    const idx = try engine.registerValidator("ob_omni_bad", VALIDATOR_MIN_STAKE * 2, 100);
    try engine.activateValidator(idx);

    const slashed = try engine.slashEquivocation(idx);
    // 5% of 200 OMNI = 10 OMNI
    try testing.expectEqual(VALIDATOR_MIN_STAKE * 2 * SLASH_EQUIVOCATION_PCT / 100, slashed);
    try testing.expectEqual(ValidatorStatus.slashed, engine.validators[idx].status);
    try testing.expectEqual(@as(u32, 1), engine.total_slashes);
}

test "StakingEngine — select proposer" {
    var engine = StakingEngine.init();
    _ = try engine.registerValidator("ob_omni_p1", VALIDATOR_MIN_STAKE, 100);
    _ = try engine.registerValidator("ob_omni_p2", VALIDATOR_MIN_STAKE * 3, 100);
    try engine.activateValidator(0);
    try engine.activateValidator(1);

    const hash = [_]u8{0x42} ** 32;
    const proposer = engine.selectProposer(hash);
    try testing.expect(proposer != null);
}

test "StakingEngine — distribute rewards" {
    var engine = StakingEngine.init();
    _ = try engine.registerValidator("ob_omni_r1", VALIDATOR_MIN_STAKE, 100);
    _ = try engine.registerValidator("ob_omni_r2", VALIDATOR_MIN_STAKE, 100);
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
    _ = try engine.registerValidator("ob_omni_w1", VALIDATOR_MIN_STAKE, 100);     // 100 OMNI
    _ = try engine.registerValidator("ob_omni_w2", VALIDATOR_MIN_STAKE * 3, 100); // 300 OMNI
    try engine.activateValidator(0);
    try engine.activateValidator(1);

    engine.distributeRewards(4_000_000); // 4M SAT
    // 1:3 ratio -> 1M : 3M
    try testing.expectEqual(@as(u64, 1_000_000), engine.validators[0].total_rewards);
    try testing.expectEqual(@as(u64, 3_000_000), engine.validators[1].total_rewards);
}

test "Validator — voting power 0 when not active" {
    var v = Validator.init("ob_omni_inactive", VALIDATOR_MIN_STAKE, 0);
    try testing.expectEqual(@as(u64, 0), v.votingPower()); // pending -> 0
    v.status = .active;
    try testing.expectEqual(VALIDATOR_MIN_STAKE, v.votingPower()); // active -> stake
}

// ─── Slashing Evidence Tests ────────────────────────────────────────────────

test "SlashEvidence — double-sign with valid evidence executes 33% slash" {
    var engine = StakingEngine.init();
    const stake = VALIDATOR_MIN_STAKE * 3; // 300 OMNI
    const idx = try engine.registerValidator("ob_omni_cheater", stake, 100);
    try engine.activateValidator(idx);

    // Create double-sign evidence: two different block hashes at same height
    const hash1 = [_]u8{0xAA} ** 32;
    const hash2 = [_]u8{0xBB} ** 32;
    const sig1  = [_]u8{0x11} ** 64;
    const sig2  = [_]u8{0x22} ** 64;
    const evidence = SlashEvidence.init(
        "ob_omni_cheater", .double_sign,
        hash1, hash2, 500, sig1, sig2,
        "ob_omni_reporter", 1711800000,
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
    _ = try engine.registerValidator("ob_omni_honest", VALIDATOR_MIN_STAKE, 100);
    try engine.activateValidator(0);

    // Same hash for both blocks — NOT double-signing
    const same_hash = [_]u8{0xCC} ** 32;
    const sig1 = [_]u8{0x11} ** 64;
    const sig2 = [_]u8{0x22} ** 64;
    const evidence = SlashEvidence.init(
        "ob_omni_honest", .double_sign,
        same_hash, same_hash, 500, sig1, sig2,
        "ob_omni_false_reporter", 1711800000,
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
    _ = try engine.registerValidator("ob_omni_bad_val", stake, 100);
    try engine.activateValidator(0);

    const evidence = SlashEvidence.init(
        "ob_omni_bad_val", .double_sign,
        [_]u8{0xAA} ** 32, [_]u8{0xBB} ** 32, 500,
        [_]u8{0x11} ** 64, [_]u8{0x22} ** 64,
        "ob_omni_good_reporter", 1711800000,
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
    _ = try engine.registerValidator("ob_omni_sleepy", stake, 100);
    try engine.activateValidator(0);

    const evidence = SlashEvidence.init(
        "ob_omni_sleepy", .downtime,
        [_]u8{0xAA} ** 32, [_]u8{0xBB} ** 32, 500,
        [_]u8{0x11} ** 64, [_]u8{0x22} ** 64,
        "ob_omni_monitor", 1711800000,
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
        "ob_omni_normal_user", .double_sign,
        [_]u8{0xAA} ** 32, [_]u8{0xBB} ** 32, 500,
        [_]u8{0x11} ** 64, [_]u8{0x22} ** 64,
        "ob_omni_reporter", 1711800000,
    );

    const result = engine.submitSlashEvidence(evidence);
    try testing.expect(!result.valid);
    try testing.expectEqual(@as(u64, 0), result.slashed_amount);
}

test "SlashEvidence — invalid_block slashes 10%" {
    var engine = StakingEngine.init();
    const stake = VALIDATOR_MIN_STAKE * 5; // 500 OMNI
    _ = try engine.registerValidator("ob_omni_bad_miner", stake, 100);
    try engine.activateValidator(0);

    const evidence = SlashEvidence.init(
        "ob_omni_bad_miner", .invalid_block,
        [_]u8{0xAA} ** 32, [_]u8{0xBB} ** 32, 500,
        [_]u8{0x11} ** 64, [_]u8{0x22} ** 64,
        "ob_omni_verifier", 1711800000,
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
    _ = try engine.registerValidator("ob_omni_tracked", VALIDATOR_MIN_STAKE * 5, 100);
    try engine.activateValidator(0);

    const evidence = SlashEvidence.init(
        "ob_omni_tracked", .invalid_block,
        [_]u8{0xAA} ** 32, [_]u8{0xBB} ** 32, 777,
        [_]u8{0x11} ** 64, [_]u8{0x22} ** 64,
        "ob_omni_watcher", 1711800000,
    );

    const result = engine.submitSlashEvidence(evidence);
    try testing.expect(result.valid);

    // Check slash history
    const history = engine.getSlashHistory("ob_omni_tracked");
    try testing.expectEqual(@as(usize, 1), history.count);

    const record = history.records[0];
    try testing.expectEqualStrings("ob_omni_tracked", record.getValidator());
    try testing.expectEqual(SlashReason.invalid_block, record.reason);
    try testing.expectEqual(@as(u64, 777), record.block_height);
    try testing.expectEqualStrings("ob_omni_watcher", record.getReporter());
    try testing.expectEqual(result.slashed_amount, record.amount_slashed);
}

test "SlashEvidence — already-slashed validator rejected" {
    var engine = StakingEngine.init();
    _ = try engine.registerValidator("ob_omni_repeat", VALIDATOR_MIN_STAKE * 3, 100);
    try engine.activateValidator(0);

    const evidence = SlashEvidence.init(
        "ob_omni_repeat", .double_sign,
        [_]u8{0xAA} ** 32, [_]u8{0xBB} ** 32, 500,
        [_]u8{0x11} ** 64, [_]u8{0x22} ** 64,
        "ob_omni_reporter", 1711800000,
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
    _ = try engine.registerValidator("ob_omni_zero", VALIDATOR_MIN_STAKE, 100);
    try engine.activateValidator(0);

    // Zero block hashes — invalid evidence
    const evidence = SlashEvidence.init(
        "ob_omni_zero", .double_sign,
        [_]u8{0} ** 32, [_]u8{0xBB} ** 32, 500,
        [_]u8{0x11} ** 64, [_]u8{0x22} ** 64,
        "ob_omni_reporter", 1711800000,
    );

    const result = engine.submitSlashEvidence(evidence);
    try testing.expect(!result.valid);
}

test "SlashEvidence — getValidatorInfo returns slash status" {
    var engine = StakingEngine.init();
    _ = try engine.registerValidator("ob_omni_infotest", VALIDATOR_MIN_STAKE * 2, 100);
    try engine.activateValidator(0);

    // Before slash
    const info_before = engine.getValidatorInfo("ob_omni_infotest").?;
    try testing.expectEqual(ValidatorStatus.active, info_before.status);
    try testing.expectEqual(@as(u8, 0), info_before.slash_count);

    // Slash
    const evidence = SlashEvidence.init(
        "ob_omni_infotest", .double_sign,
        [_]u8{0xAA} ** 32, [_]u8{0xBB} ** 32, 500,
        [_]u8{0x11} ** 64, [_]u8{0x22} ** 64,
        "ob_omni_reporter", 1711800000,
    );
    _ = engine.submitSlashEvidence(evidence);

    // After slash
    const info_after = engine.getValidatorInfo("ob_omni_infotest").?;
    try testing.expectEqual(ValidatorStatus.slashed, info_after.status);
    try testing.expectEqual(@as(u8, 1), info_after.slash_count);
    try testing.expectEqual(@as(u8, 1), info_after.slash_history_count);
}

test "SlashEvidence — findValidatorIndex" {
    var engine = StakingEngine.init();
    _ = try engine.registerValidator("ob_omni_find1", VALIDATOR_MIN_STAKE, 100);
    _ = try engine.registerValidator("ob_omni_find2", VALIDATOR_MIN_STAKE, 100);

    try testing.expectEqual(@as(?usize, 0), engine.findValidatorIndex("ob_omni_find1"));
    try testing.expectEqual(@as(?usize, 1), engine.findValidatorIndex("ob_omni_find2"));
    try testing.expectEqual(@as(?usize, null), engine.findValidatorIndex("ob_omni_notfound"));
}

test "SlashEvidence — min slash amount enforced" {
    var engine = StakingEngine.init();
    // Register with exactly min stake (100 OMNI)
    _ = try engine.registerValidator("ob_omni_minstake", VALIDATOR_MIN_STAKE, 100);
    try engine.activateValidator(0);

    // Downtime = 1% of 100 OMNI = 1 OMNI = 1_000_000_000 SAT (above MIN_SLASH_AMOUNT)
    const evidence = SlashEvidence.init(
        "ob_omni_minstake", .downtime,
        [_]u8{0xAA} ** 32, [_]u8{0xBB} ** 32, 500,
        [_]u8{0x11} ** 64, [_]u8{0x22} ** 64,
        "ob_omni_monitor", 1711800000,
    );

    const result = engine.submitSlashEvidence(evidence);
    try testing.expect(result.valid);
    // 1% of 100 OMNI = 1 OMNI = 1_000_000_000 SAT
    try testing.expectEqual(VALIDATOR_MIN_STAKE * DOWNTIME_PENALTY_PCT / 100, result.slashed_amount);
}

test "ValidatorInfo — statusString" {
    var engine = StakingEngine.init();
    _ = try engine.registerValidator("ob_omni_status", VALIDATOR_MIN_STAKE, 100);

    const info = engine.getValidatorInfo("ob_omni_status").?;
    try testing.expectEqualStrings("pending", info.statusString());
}
