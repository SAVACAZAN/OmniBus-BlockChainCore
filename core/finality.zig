const std = @import("std");
const secp = @import("secp256k1.zig");
const Secp = secp.Secp256k1Crypto;

/// Domain separator mixed into every attestation signature. Prevents a
/// signature produced for some other OmniBus message (a transaction, an
/// oracle header, etc.) from ever being replayed as a finality vote, and
/// versions the wire format so v2 attestations can't be confused with v1.
pub const ATTESTATION_DOMAIN = "OmniBus-FFG-Attestation-v1";

/// Finality Gadget for OmniBus
/// Adds deterministic finality on top of PoW probabilistic finality.
///
/// Inspired by:
///   - Casper FFG (Ethereum 2.0): 2-phase justify → finalize
///   - Tendermint: instant finality via 2/3+ prevotes → precommits
///   - Bitcoin: 6 confirmations ≈ finality (probabilistic)
///
/// OmniBus approach: Checkpoint-based finality
///   - Every CHECKPOINT_INTERVAL blocks, a checkpoint is proposed
///   - Checkpoint is "justified" when 2/3+ validators attest to it
///   - Checkpoint is "finalized" when the NEXT justified checkpoint references it
///   - Finalized blocks can NEVER be reverted (unlike PoW-only chains)

/// Checkpoint interval (blocks between checkpoints)
pub const CHECKPOINT_INTERVAL: u64 = 64; // Every 64 blocks (~1 min at 1s block time)

/// Minimum confirmations for soft finality (like Bitcoin's 6 confirmations)
pub const SOFT_FINALITY_CONFIRMS: u32 = 6;

/// Maximum number of tracked checkpoints
pub const MAX_CHECKPOINTS: usize = 256;

/// Maximum validators
pub const MAX_VALIDATORS: usize = 128;

/// Checkpoint status
pub const CheckpointStatus = enum(u8) {
    /// Proposed but not yet justified
    Pending = 0,
    /// Justified: 2/3+ validators attested (safe to build on)
    Justified = 1,
    /// Finalized: next checkpoint also justified (irreversible)
    Finalized = 2,
};

/// A checkpoint in the finality chain
pub const Checkpoint = struct {
    /// Epoch number (checkpoint_index)
    epoch: u64,
    /// Block height this checkpoint corresponds to
    block_height: u64,
    /// Block hash at this height
    block_hash: [32]u8,
    /// Status
    status: CheckpointStatus,
    /// Number of attestations received
    attestation_count: u32,
    /// Total voting power that attested
    attested_power: u64,
    /// Block when first attestation arrived
    first_attestation_block: u64,
    /// Reference to parent checkpoint epoch
    parent_epoch: u64,

    /// Check if this checkpoint has supermajority (2/3+)
    pub fn hasSupermajority(self: *const Checkpoint, total_power: u64) bool {
        if (total_power == 0) return false;
        // 2/3+ of total power: attested * 3 >= total * 2
        return self.attested_power * 3 >= total_power * 2;
    }
};

/// Attestation from a validator
pub const Attestation = struct {
    validator_id: u16,
    /// Epoch being attested
    target_epoch: u64,
    /// Source epoch (last justified)
    source_epoch: u64,
    /// Validator's voting power. ADVISORY ONLY — the engine ignores this
    /// field and uses the authoritative power from the validator registry
    /// (so a validator can't inflate its own weight). Kept for telemetry.
    voting_power: u64,
    /// Block hash being attested
    block_hash: [32]u8,
    /// Timestamp (advisory, not signed)
    timestamp: i64,
    /// Compressed secp256k1 public key of the attesting validator (33 bytes).
    /// Must match the key registered for `validator_id`. Zero = unsigned.
    pubkey: [33]u8 = [_]u8{0} ** 33,
    /// ECDSA signature over `signingBytes()` (64 bytes, low-S canonical).
    signature: [64]u8 = [_]u8{0} ** 64,

    /// The exact byte string the signature commits to. Binds the
    /// consensus-relevant fields only: target epoch, source epoch and the
    /// attested block hash. `validator_id` is a local routing index and
    /// `voting_power`/`timestamp` are advisory, so none are signed — this
    /// stops a validator from forging its own weight while keeping the
    /// vote's meaning ("epoch T from source S for block H") tamper-proof.
    pub fn signingBytes(self: *const Attestation) [ATTESTATION_DOMAIN.len + 48]u8 {
        var buf: [ATTESTATION_DOMAIN.len + 48]u8 = undefined;
        @memcpy(buf[0..ATTESTATION_DOMAIN.len], ATTESTATION_DOMAIN);
        const off = ATTESTATION_DOMAIN.len;
        std.mem.writeInt(u64, buf[off..][0..8], self.target_epoch, .big);
        std.mem.writeInt(u64, buf[off + 8 ..][0..8], self.source_epoch, .big);
        @memcpy(buf[off + 16 ..][0..32], &self.block_hash);
        return buf;
    }

    /// Sign this attestation in place with a validator's secp256k1 private
    /// key. Derives and stores the matching compressed pubkey so the
    /// engine can bind the vote to a registered validator.
    pub fn sign(self: *Attestation, private_key: [32]u8) !void {
        self.pubkey = try Secp.privateKeyToPublicKey(private_key);
        const msg = self.signingBytes();
        self.signature = try Secp.sign(private_key, &msg);
    }

    /// Verify the signature against the pubkey carried in the attestation.
    /// Does NOT check that the pubkey is an authorised validator — the
    /// engine does that separately against its registry.
    pub fn verifySig(self: *const Attestation) bool {
        const msg = self.signingBytes();
        return Secp.verify(self.pubkey, &msg, self.signature);
    }
};

/// Slashing condition: equivocation (voting for two different blocks at same epoch)
pub const SlashingEvidence = struct {
    validator_id: u16,
    epoch: u64,
    /// First vote
    hash_a: [32]u8,
    /// Conflicting vote
    hash_b: [32]u8,
};

/// Finality Engine
pub const FinalityEngine = struct {
    checkpoints: [MAX_CHECKPOINTS]Checkpoint,
    checkpoint_count: usize,
    /// Last justified epoch
    last_justified_epoch: u64,
    /// Last finalized epoch
    last_finalized_epoch: u64,
    /// Last finalized block height
    last_finalized_height: u64,
    /// Total voting power in current validator set
    total_voting_power: u64,
    /// Track which validators voted per epoch (for equivocation detection)
    validator_votes: [MAX_VALIDATORS]u64, // validator_id → last epoch voted
    /// Detected slashing events
    slash_count: u32,
    /// Authorised validator set, indexed by validator_id.
    /// An attestation only counts if its validator_id is registered, its
    /// pubkey matches `validator_pubkeys[id]`, and its signature verifies.
    validator_pubkeys: [MAX_VALIDATORS][33]u8,
    /// Authoritative voting power per validator_id (used instead of the
    /// attacker-controlled `Attestation.voting_power`).
    validator_power: [MAX_VALIDATORS]u64,
    /// Whether slot `id` holds a registered validator.
    validator_registered: [MAX_VALIDATORS]bool,

    pub fn init(total_voting_power: u64) FinalityEngine {
        var engine: FinalityEngine = undefined;
        engine.checkpoint_count = 0;
        engine.last_justified_epoch = 0;
        engine.last_finalized_epoch = 0;
        engine.last_finalized_height = 0;
        engine.total_voting_power = total_voting_power;
        engine.validator_votes = [_]u64{0} ** MAX_VALIDATORS;
        engine.slash_count = 0;
        engine.validator_pubkeys = [_][33]u8{[_]u8{0} ** 33} ** MAX_VALIDATORS;
        engine.validator_power = [_]u64{0} ** MAX_VALIDATORS;
        engine.validator_registered = [_]bool{false} ** MAX_VALIDATORS;

        // Genesis checkpoint (epoch 0, finalized by definition)
        engine.checkpoints[0] = Checkpoint{
            .epoch = 0,
            .block_height = 0,
            .block_hash = [_]u8{0} ** 32,
            .status = .Finalized,
            .attestation_count = 0,
            .attested_power = total_voting_power,
            .first_attestation_block = 0,
            .parent_epoch = 0,
        };
        engine.checkpoint_count = 1;

        return engine;
    }

    /// Register (or update) an authorised validator. Only attestations
    /// signed by a registered validator's key are counted, and the power
    /// recorded here — not the attacker-supplied `Attestation.voting_power`
    /// — is what accrues toward supermajority. Call this for each member of
    /// the validator set at startup and whenever the set is rebuilt.
    pub fn registerValidator(self: *FinalityEngine, validator_id: u16, pubkey: [33]u8, power: u64) !void {
        if (validator_id >= MAX_VALIDATORS) return error.ValidatorIdOutOfRange;
        self.validator_pubkeys[validator_id] = pubkey;
        self.validator_power[validator_id] = power;
        self.validator_registered[validator_id] = true;
    }

    /// Propose a new checkpoint at given block height
    pub fn proposeCheckpoint(self: *FinalityEngine, block_height: u64, block_hash: [32]u8) !u64 {
        if (self.checkpoint_count >= MAX_CHECKPOINTS) return error.TooManyCheckpoints;
        if (block_height % CHECKPOINT_INTERVAL != 0) return error.NotCheckpointHeight;

        const epoch = block_height / CHECKPOINT_INTERVAL;

        self.checkpoints[self.checkpoint_count] = Checkpoint{
            .epoch = epoch,
            .block_height = block_height,
            .block_hash = block_hash,
            .status = .Pending,
            .attestation_count = 0,
            .attested_power = 0,
            .first_attestation_block = 0,
            .parent_epoch = self.last_justified_epoch,
        };
        self.checkpoint_count += 1;

        return epoch;
    }

    /// Submit an attestation for a checkpoint
    pub fn attest(self: *FinalityEngine, attestation: Attestation) !void {
        // ── Authorisation + signature — must pass before any state mutates ──
        // 1. validator_id must be a registered member of the set.
        if (attestation.validator_id >= MAX_VALIDATORS or
            !self.validator_registered[attestation.validator_id])
            return error.UnknownValidator;
        // 2. The carried pubkey must be EXACTLY the registered key, so a
        //    signature valid under some other key never counts.
        const reg_pubkey = self.validator_pubkeys[attestation.validator_id];
        if (!std.mem.eql(u8, &attestation.pubkey, &reg_pubkey))
            return error.WrongValidatorKey;
        // 3. The signature must verify over the canonical message.
        if (!attestation.verifySig()) return error.InvalidSignature;

        // Find the target checkpoint
        const cp = self.getCheckpointMut(attestation.target_epoch) orelse return error.CheckpointNotFound;

        if (cp.status == .Finalized) return error.AlreadyFinalized;

        // Check for equivocation (double voting). Only reached for an
        // authenticated attestation, so slash_count can't be poisoned by
        // forged votes.
        {
            const last_voted = self.validator_votes[attestation.validator_id];
            if (last_voted == attestation.target_epoch) {
                // Already voted in this epoch — equivocation!
                self.slash_count += 1;
                return error.Equivocation;
            }
            self.validator_votes[attestation.validator_id] = attestation.target_epoch;
        }

        // Verify source epoch is justified
        if (attestation.source_epoch != self.last_justified_epoch and attestation.source_epoch != 0) {
            return error.InvalidSourceEpoch;
        }

        // Add attestation. Power comes from the registry, NOT from the
        // attestation, so a validator cannot inflate its own weight.
        const power = self.validator_power[attestation.validator_id];
        cp.attestation_count += 1;
        cp.attested_power += power;
        if (cp.first_attestation_block == 0) {
            cp.first_attestation_block = attestation.target_epoch * CHECKPOINT_INTERVAL;
        }

        // Check if now justified (2/3+ supermajority)
        if (cp.status == .Pending and cp.hasSupermajority(self.total_voting_power)) {
            cp.status = .Justified;

            // Casper FFG rule: if parent was justified, it becomes finalized
            if (cp.parent_epoch == self.last_justified_epoch and self.last_justified_epoch > self.last_finalized_epoch) {
                const parent = self.getCheckpointMut(self.last_justified_epoch);
                if (parent) |p| {
                    p.status = .Finalized;
                    self.last_finalized_epoch = p.epoch;
                    self.last_finalized_height = p.block_height;
                }
            }

            self.last_justified_epoch = cp.epoch;
        }
    }

    /// Check if a block height is finalized (can never be reverted)
    pub fn isFinalized(self: *const FinalityEngine, block_height: u64) bool {
        return block_height <= self.last_finalized_height;
    }

    /// Check if a block has soft finality (N confirmations, like Bitcoin)
    pub fn hasSoftFinality(_: *const FinalityEngine, block_height: u64, current_height: u64) bool {
        if (current_height < block_height) return false;
        return (current_height - block_height) >= SOFT_FINALITY_CONFIRMS;
    }

    /// Get the latest finalized checkpoint
    pub fn getLastFinalized(self: *const FinalityEngine) ?*const Checkpoint {
        return self.getCheckpoint(self.last_finalized_epoch);
    }

    /// Get checkpoint by epoch
    fn getCheckpoint(self: *const FinalityEngine, epoch: u64) ?*const Checkpoint {
        for (self.checkpoints[0..self.checkpoint_count]) |*cp| {
            if (cp.epoch == epoch) return cp;
        }
        return null;
    }

    /// Get checkpoint by epoch (mutable)
    fn getCheckpointMut(self: *FinalityEngine, epoch: u64) ?*Checkpoint {
        for (self.checkpoints[0..self.checkpoint_count]) |*cp| {
            if (cp.epoch == epoch) return cp;
        }
        return null;
    }
};

// ─── Tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

/// Deterministic, distinct, non-zero test scalars (all < curve order).
fn testKey(seed: u8) [32]u8 {
    return [_]u8{seed} ** 32;
}

/// Register validator `vid` with `power` and return an attestation signed
/// by `priv`. Keeps the security-enabled tests readable.
fn signedAttest(
    engine: *FinalityEngine,
    priv: [32]u8,
    vid: u16,
    power: u64,
    target_epoch: u64,
    source_epoch: u64,
    block_hash: [32]u8,
) !Attestation {
    const pubkey = try Secp.privateKeyToPublicKey(priv);
    try engine.registerValidator(vid, pubkey, power);
    var att = Attestation{
        .validator_id = vid,
        .target_epoch = target_epoch,
        .source_epoch = source_epoch,
        .voting_power = power,
        .block_hash = block_hash,
        .timestamp = 0,
    };
    try att.sign(priv);
    return att;
}

test "FinalityEngine — init with genesis checkpoint" {
    const engine = FinalityEngine.init(1000);
    try testing.expectEqual(@as(usize, 1), engine.checkpoint_count);
    try testing.expectEqual(@as(u64, 0), engine.last_finalized_epoch);
    try testing.expect(engine.isFinalized(0)); // genesis is finalized
}

test "FinalityEngine — propose checkpoint" {
    var engine = FinalityEngine.init(1000);
    const hash = [_]u8{0xAA} ** 32;
    const epoch = try engine.proposeCheckpoint(64, hash);
    try testing.expectEqual(@as(u64, 1), epoch);
    try testing.expectEqual(@as(usize, 2), engine.checkpoint_count);
}

test "FinalityEngine — non-checkpoint height rejected" {
    var engine = FinalityEngine.init(1000);
    const hash = [_]u8{0xBB} ** 32;
    try testing.expectError(error.NotCheckpointHeight, engine.proposeCheckpoint(50, hash));
}

test "FinalityEngine — attest and justify" {
    var engine = FinalityEngine.init(900);
    const hash = [_]u8{0xCC} ** 32;

    _ = try engine.proposeCheckpoint(64, hash);

    // Attest with 2/3+ (601 out of 900 = 66.8% > 66.6%)
    try engine.attest(try signedAttest(&engine, testKey(0x01), 0, 601, 1, 0, hash));

    // Checkpoint should now be justified
    const cp = engine.getCheckpoint(1).?;
    try testing.expectEqual(CheckpointStatus.Justified, cp.status);
    try testing.expectEqual(@as(u64, 1), engine.last_justified_epoch);
}

test "FinalityEngine — finalization via Casper FFG rule" {
    var engine = FinalityEngine.init(900);
    const hash1 = [_]u8{0xDD} ** 32;
    const hash2 = [_]u8{0xEE} ** 32;

    // Propose and justify epoch 1
    _ = try engine.proposeCheckpoint(64, hash1);
    try engine.attest(try signedAttest(&engine, testKey(0x01), 0, 700, 1, 0, hash1));
    try testing.expectEqual(CheckpointStatus.Justified, engine.getCheckpoint(1).?.status);

    // Propose and justify epoch 2 (with source = epoch 1)
    _ = try engine.proposeCheckpoint(128, hash2);
    try engine.attest(try signedAttest(&engine, testKey(0x02), 1, 700, 2, 1, hash2));

    // Epoch 1 should now be FINALIZED (Casper FFG: justified → next justified → finalized)
    try testing.expectEqual(CheckpointStatus.Finalized, engine.getCheckpoint(1).?.status);
    try testing.expectEqual(@as(u64, 1), engine.last_finalized_epoch);
    try testing.expectEqual(@as(u64, 64), engine.last_finalized_height);

    // Block 64 and below are finalized
    try testing.expect(engine.isFinalized(64));
    try testing.expect(engine.isFinalized(0));
    try testing.expect(!engine.isFinalized(65));
}

test "FinalityEngine — equivocation detected" {
    var engine = FinalityEngine.init(900);
    const hash = [_]u8{0xFF} ** 32;

    _ = try engine.proposeCheckpoint(64, hash);

    // First vote OK
    const att1 = try signedAttest(&engine, testKey(0x05), 5, 100, 1, 0, hash);
    try engine.attest(att1);

    // Second vote by same validator (re-signed, still valid) = equivocation
    var att2 = att1;
    att2.timestamp = 101;
    try att2.sign(testKey(0x05));
    try testing.expectError(error.Equivocation, engine.attest(att2));

    try testing.expectEqual(@as(u32, 1), engine.slash_count);
}

test "FinalityEngine — unsigned attestation rejected" {
    var engine = FinalityEngine.init(900);
    const hash = [_]u8{0xCC} ** 32;
    _ = try engine.proposeCheckpoint(64, hash);

    // Register validator 0 but submit an unsigned (zero pubkey/sig) vote.
    const pubkey = try Secp.privateKeyToPublicKey(testKey(0x01));
    try engine.registerValidator(0, pubkey, 700);
    try testing.expectError(error.WrongValidatorKey, engine.attest(.{
        .validator_id = 0, .target_epoch = 1, .source_epoch = 0,
        .voting_power = 700, .block_hash = hash, .timestamp = 0,
    }));
}

test "FinalityEngine — unregistered validator rejected" {
    var engine = FinalityEngine.init(900);
    const hash = [_]u8{0xCC} ** 32;
    _ = try engine.proposeCheckpoint(64, hash);

    // validator 9 was never registered, even though the signature is valid.
    var att = Attestation{
        .validator_id = 9, .target_epoch = 1, .source_epoch = 0,
        .voting_power = 700, .block_hash = hash, .timestamp = 0,
    };
    try att.sign(testKey(0x09));
    try testing.expectError(error.UnknownValidator, engine.attest(att));
}

test "FinalityEngine — signature from wrong key rejected" {
    var engine = FinalityEngine.init(900);
    const hash = [_]u8{0xCC} ** 32;
    _ = try engine.proposeCheckpoint(64, hash);

    // Register validator 0 with key 0x01, then attest with key 0x02.
    const real_pubkey = try Secp.privateKeyToPublicKey(testKey(0x01));
    try engine.registerValidator(0, real_pubkey, 700);
    var att = Attestation{
        .validator_id = 0, .target_epoch = 1, .source_epoch = 0,
        .voting_power = 700, .block_hash = hash, .timestamp = 0,
    };
    try att.sign(testKey(0x02)); // wrong key — pubkey won't match registry
    try testing.expectError(error.WrongValidatorKey, engine.attest(att));
}

test "FinalityEngine — tampered block_hash invalidates signature" {
    var engine = FinalityEngine.init(900);
    const hash = [_]u8{0xCC} ** 32;
    _ = try engine.proposeCheckpoint(64, hash);

    // Sign for `hash`, then flip the attested block_hash before submitting.
    var att = try signedAttest(&engine, testKey(0x01), 0, 700, 1, 0, hash);
    att.block_hash = [_]u8{0xDD} ** 32; // signature no longer covers this
    try testing.expectError(error.InvalidSignature, engine.attest(att));
}

test "FinalityEngine — forged voting_power ignored, registry power used" {
    var engine = FinalityEngine.init(900);
    const hash = [_]u8{0xCC} ** 32;
    _ = try engine.proposeCheckpoint(64, hash);

    // Validator registered with only 100 power. Attestation claims 5000.
    const pubkey = try Secp.privateKeyToPublicKey(testKey(0x01));
    try engine.registerValidator(0, pubkey, 100);
    var att = Attestation{
        .validator_id = 0, .target_epoch = 1, .source_epoch = 0,
        .voting_power = 5000, .block_hash = hash, .timestamp = 0,
    };
    try att.sign(testKey(0x01));
    try engine.attest(att);

    // Only the registry's 100 should have accrued — nowhere near 2/3 of 900,
    // so the checkpoint stays Pending and the forged 5000 was discarded.
    const cp = engine.getCheckpoint(1).?;
    try testing.expectEqual(@as(u64, 100), cp.attested_power);
    try testing.expectEqual(CheckpointStatus.Pending, cp.status);
}

test "FinalityEngine — soft finality" {
    const engine = FinalityEngine.init(1000);
    try testing.expect(!engine.hasSoftFinality(100, 103)); // 3 confirms < 6
    try testing.expect(engine.hasSoftFinality(100, 106));  // 6 confirms = 6
    try testing.expect(engine.hasSoftFinality(100, 200));  // 100 confirms > 6
}

test "Checkpoint — supermajority calculation" {
    var cp = Checkpoint{
        .epoch = 1, .block_height = 64, .block_hash = [_]u8{0} ** 32,
        .status = .Pending, .attestation_count = 0, .attested_power = 0,
        .first_attestation_block = 0, .parent_epoch = 0,
    };

    cp.attested_power = 666;
    try testing.expect(!cp.hasSupermajority(1000)); // 66.6% = exactly 2/3, not >2/3

    cp.attested_power = 667;
    try testing.expect(cp.hasSupermajority(1000)); // 66.7% > 2/3

    cp.attested_power = 900;
    try testing.expect(cp.hasSupermajority(1000)); // 90% > 2/3
}
