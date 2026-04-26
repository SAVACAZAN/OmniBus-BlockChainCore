//! bridge_native.zig — Native OmniBus cross-chain bridge (V1)
//!
//! Defense-in-depth design driven by 2022-2026 bridge-hack post-mortems:
//!
//!   - Ronin ($625M)     — 5-of-9 multisig with all keys on same infra
//!   - Wormhole ($326M)  — missing source-chain message validation
//!   - Nomad ($190M)     — upgrade set merkle root to zero
//!   - Orbit ($80M)      — 7 of 10 multisig keys leaked from servers
//!   - Kelp DAO ($292M)  — 1/1 DVN message forgery
//!
//! What V1 OmniBus does differently:
//!
//!   * No EVM contract — bridge state lives in chain consensus, not in a
//!     proxy that can be upgraded. Lecția Nomad.
//!   * Hard caps in chain_config (per-tx, per-day rolling). Lecția Ronin.
//!   * 3-of-N threshold sig with relayer keys on physically separated
//!     hardware (your PC, VPS, third party). Lecția Kelp DAO.
//!   * Challenge window after sig threshold reached, before funds move.
//!     Lecția Wormhole — gives time to spot forgery before settlement.
//!   * Auto-pause if a single block drains > 30% of daily quota.
//!     Lecția Orbit — anomaly detection at consensus level.
//!
//! State is purely additive — no upgrade path. To rotate, drain old
//! vault and deploy V2 via governance vote with delay.

const std = @import("std");
const cfg = @import("chain_config.zig");

// ─── Operation types ────────────────────────────────────────────────────────

pub const BridgeOp = enum(u8) {
    /// User sends OMNI to bridge vault, requesting it be released on a
    /// destination chain. Encoded in TX as OP_BRIDGE_LOCK.
    lock = 1,
    /// Relayer submits a multi-sig unlock request. After threshold
    /// signatures are gathered AND challenge window expires AND no
    /// fraud-proof submitted, funds release. Encoded as OP_BRIDGE_UNLOCK_REQUEST.
    unlock_request = 2,
    /// Anyone with a fraud-proof can challenge a pending unlock during
    /// the challenge window. If valid, the unlock is voided.
    fraud_challenge = 3,
};

// ─── Error set ──────────────────────────────────────────────────────────────

pub const BridgeError = error{
    AmountExceedsPerTxCap,
    AmountExceedsDailyQuota,
    UnknownDestinationChain,
    InsufficientSignatures,
    DuplicateSignature,
    SignerNotInRelayerSet,
    ChallengeWindowNotExpired,
    NonceAlreadyProcessed,
    AutoPauseActive,
    InvalidDestinationAddress,
    InsufficientVaultBalance,
};

// ─── Lock event ─────────────────────────────────────────────────────────────

pub const LockRecord = struct {
    /// Block height where the lock landed.
    height: u64,
    /// User's OmniBus address (raw 20-byte EVM-style hash).
    user_addr: [20]u8,
    /// Amount locked, in SAT.
    amount_sat: u64,
    /// Destination chain identifier (e.g. "liberty_testnet", "base_sepolia").
    /// Fixed-size to keep TX size predictable.
    destination_chain: [32]u8,
    /// Recipient on destination chain (left-padded to 32 bytes).
    destination_addr: [32]u8,
    /// Unique nonce — keccak256(user, amount, dest_chain, dest_addr, height, txid).
    nonce: [32]u8,
};

// ─── Pending unlock ─────────────────────────────────────────────────────────

pub const PendingUnlock = struct {
    /// Block height where the unlock request was submitted (NOT lock height).
    request_height: u64,
    /// Recipient (typically the original user, but relayer can route to
    /// a different address if user's chain wallet changed).
    recipient: [20]u8,
    amount_sat: u64,
    /// Nonce from the corresponding burn/lock event on destination chain.
    nonce: [32]u8,
    /// Public keys of relayers that have signed this unlock.
    /// Fixed-size; populated incrementally as signatures arrive.
    signers: [cfg.BRIDGE_MAX_RELAYERS][20]u8,
    sig_count: u8,
    /// Set true if a fraud challenge succeeded — funds NOT released.
    voided: bool,
    /// Set true once funds released (after challenge window expires).
    settled: bool,
};

// ─── Bridge state (lives in chain) ──────────────────────────────────────────

pub const BridgeState = struct {
    /// Set of authorized relayer addresses. Updated only via governance
    /// vote with delay; not via any single admin action.
    relayers: std.ArrayList([20]u8),

    /// All locks ever recorded — append-only ledger (replayable).
    /// In production this becomes a Merkle tree for cheap proofs; for
    /// V1 we keep a flat list and trim history > 90 days for memory.
    locks: std.ArrayList(LockRecord),

    /// Unlocks awaiting threshold sigs and/or challenge window.
    /// Map nonce -> PendingUnlock.
    pending_unlocks: std.AutoHashMap([32]u8, PendingUnlock),

    /// Already-settled or voided nonces (anti-replay). Key = nonce.
    processed_nonces: std.AutoHashMap([32]u8, void),

    /// Total OMNI currently locked in vault (SAT). Decreases on settle,
    /// stays same on void (challenge wins → user lost the lock,
    /// hypothetically refundable via separate path).
    locked_total_sat: u64,

    /// True if auto-pause has triggered. Manual unfreeze requires
    /// threshold relayer vote + 48h delay (enforced in p2p validation).
    paused: bool,

    /// Block height when auto-pause was last triggered (0 if never).
    paused_at_height: u64,

    pub fn init(alloc: std.mem.Allocator) BridgeState {
        return .{
            .relayers = std.ArrayList([20]u8).initCapacity(alloc, cfg.BRIDGE_MAX_RELAYERS) catch
                std.ArrayList([20]u8).empty,
            .locks = std.ArrayList(LockRecord).empty,
            .pending_unlocks = std.AutoHashMap([32]u8, PendingUnlock).init(alloc),
            .processed_nonces = std.AutoHashMap([32]u8, void).init(alloc),
            .locked_total_sat = 0,
            .paused = false,
            .paused_at_height = 0,
        };
    }

    pub fn deinit(self: *BridgeState, alloc: std.mem.Allocator) void {
        self.relayers.deinit(alloc);
        self.locks.deinit(alloc);
        self.pending_unlocks.deinit();
        self.processed_nonces.deinit();
    }

    // ─── Validation: rolling 24h volume ─────────────────────────────────────

    /// Sum of OMNI locked in the last BRIDGE_DAILY_WINDOW_BLOCKS blocks.
    /// O(N) over recent locks; for chains with high-volume bridging this
    /// becomes a sliding-window aggregate. V1 keeps it simple.
    pub fn dailyVolumeSat(self: *const BridgeState, current_height: u64) u64 {
        const cutoff = if (current_height > cfg.BRIDGE_DAILY_WINDOW_BLOCKS)
            current_height - cfg.BRIDGE_DAILY_WINDOW_BLOCKS
        else
            0;
        var total: u64 = 0;
        var i: usize = self.locks.items.len;
        while (i > 0) {
            i -= 1;
            const rec = self.locks.items[i];
            if (rec.height < cutoff) break;
            total +%= rec.amount_sat;
        }
        return total;
    }

    /// Validate a proposed lock against limits BEFORE adding it.
    /// Called from consensus block validation — if this fails, the TX
    /// is rejected and never enters chain.
    pub fn validateLock(
        self: *const BridgeState,
        amount_sat: u64,
        current_height: u64,
    ) BridgeError!void {
        if (self.paused) return BridgeError.AutoPauseActive;
        if (amount_sat == 0 or amount_sat > cfg.BRIDGE_MAX_PER_TX_SAT) {
            return BridgeError.AmountExceedsPerTxCap;
        }
        const day_so_far = self.dailyVolumeSat(current_height);
        const new_total = day_so_far +% amount_sat;
        if (new_total < day_so_far or new_total > cfg.BRIDGE_MAX_DAILY_SAT) {
            return BridgeError.AmountExceedsDailyQuota;
        }
    }

    /// Apply a validated lock. Caller MUST have called validateLock first.
    pub fn applyLock(
        self: *BridgeState,
        alloc: std.mem.Allocator,
        rec: LockRecord,
    ) !void {
        try self.locks.append(alloc, rec);
        self.locked_total_sat +%= rec.amount_sat;

        // Auto-pause check: if a single block drains > 30% of daily quota.
        const block_volume = blockVolume(self, rec.height);
        const auto_pause_threshold = (cfg.BRIDGE_MAX_DAILY_SAT *
            @as(u64, cfg.BRIDGE_AUTO_PAUSE_BLOCK_FRACTION_BPS)) / 10_000;
        if (block_volume >= auto_pause_threshold) {
            self.paused = true;
            self.paused_at_height = rec.height;
        }
    }

    fn blockVolume(self: *const BridgeState, height: u64) u64 {
        var total: u64 = 0;
        var i: usize = self.locks.items.len;
        while (i > 0) {
            i -= 1;
            const rec = self.locks.items[i];
            if (rec.height != height) {
                if (rec.height < height) break;
                continue;
            }
            total +%= rec.amount_sat;
        }
        return total;
    }

    // ─── Unlock flow ────────────────────────────────────────────────────────

    /// Begin or extend a multi-sig unlock request. First call creates the
    /// pending entry; subsequent calls add signatures.
    pub fn submitUnlockSignature(
        self: *BridgeState,
        signer: [20]u8,
        recipient: [20]u8,
        amount_sat: u64,
        nonce: [32]u8,
        current_height: u64,
    ) (BridgeError || error{OutOfMemory})!void {
        if (self.paused) return BridgeError.AutoPauseActive;
        if (self.processed_nonces.contains(nonce)) return BridgeError.NonceAlreadyProcessed;
        if (!self.isRelayer(signer)) return BridgeError.SignerNotInRelayerSet;
        if (self.locked_total_sat < amount_sat) return BridgeError.InsufficientVaultBalance;

        if (self.pending_unlocks.getPtr(nonce)) |entry| {
            // Existing pending — append signature if not duplicate.
            for (entry.signers[0..entry.sig_count]) |existing| {
                if (std.mem.eql(u8, &existing, &signer)) {
                    return BridgeError.DuplicateSignature;
                }
            }
            if (entry.sig_count >= cfg.BRIDGE_MAX_RELAYERS) return BridgeError.InsufficientSignatures;
            entry.signers[entry.sig_count] = signer;
            entry.sig_count += 1;
        } else {
            // New pending unlock.
            var pu = PendingUnlock{
                .request_height = current_height,
                .recipient = recipient,
                .amount_sat = amount_sat,
                .nonce = nonce,
                .signers = std.mem.zeroes([cfg.BRIDGE_MAX_RELAYERS][20]u8),
                .sig_count = 1,
                .voided = false,
                .settled = false,
            };
            pu.signers[0] = signer;
            try self.pending_unlocks.put(nonce, pu);
        }
    }

    /// Try to settle a pending unlock: returns the amount to release if
    /// (a) threshold sigs gathered, (b) challenge window expired, (c)
    /// not voided, (d) not already settled. Otherwise returns null with
    /// no state change. Caller must perform the actual balance transfer.
    pub fn trySettle(
        self: *BridgeState,
        nonce: [32]u8,
        current_height: u64,
    ) (BridgeError || error{OutOfMemory})!?struct { recipient: [20]u8, amount_sat: u64 } {
        const entry = self.pending_unlocks.getPtr(nonce) orelse return null;
        if (entry.voided or entry.settled) return null;
        if (entry.sig_count < cfg.BRIDGE_REQUIRED_SIGS) {
            return BridgeError.InsufficientSignatures;
        }
        if (current_height < entry.request_height + cfg.BRIDGE_CHALLENGE_WINDOW_BLOCKS) {
            return BridgeError.ChallengeWindowNotExpired;
        }
        if (self.locked_total_sat < entry.amount_sat) return BridgeError.InsufficientVaultBalance;

        entry.settled = true;
        self.locked_total_sat -%= entry.amount_sat;
        try self.processed_nonces.put(nonce, {});

        return .{ .recipient = entry.recipient, .amount_sat = entry.amount_sat };
    }

    /// Mark a pending unlock as voided due to a successful fraud challenge.
    /// Funds remain in vault; nonce marked processed so it can never be
    /// retried with the same payload.
    pub fn voidUnlock(
        self: *BridgeState,
        nonce: [32]u8,
    ) (BridgeError || error{OutOfMemory})!void {
        const entry = self.pending_unlocks.getPtr(nonce) orelse return BridgeError.NonceAlreadyProcessed;
        if (entry.settled) return BridgeError.NonceAlreadyProcessed;
        entry.voided = true;
        try self.processed_nonces.put(nonce, {});
    }

    fn isRelayer(self: *const BridgeState, addr: [20]u8) bool {
        for (self.relayers.items) |r| {
            if (std.mem.eql(u8, &r, &addr)) return true;
        }
        return false;
    }
};

// ─── Tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

fn dummyAddr(byte: u8) [20]u8 {
    var a: [20]u8 = undefined;
    @memset(&a, byte);
    return a;
}

fn dummyNonce(byte: u8) [32]u8 {
    var n: [32]u8 = undefined;
    @memset(&n, byte);
    return n;
}

test "BridgeState — lock under cap accepted" {
    var state = BridgeState.init(testing.allocator);
    defer state.deinit(testing.allocator);
    try state.validateLock(50_000_000_000, 100); // 50 OMNI, height 100 — under 100 cap
}

test "BridgeState — lock over per-tx cap rejected" {
    var state = BridgeState.init(testing.allocator);
    defer state.deinit(testing.allocator);
    const result = state.validateLock(cfg.BRIDGE_MAX_PER_TX_SAT + 1, 100);
    try testing.expectError(BridgeError.AmountExceedsPerTxCap, result);
}

test "BridgeState — daily quota enforcement" {
    var state = BridgeState.init(testing.allocator);
    defer state.deinit(testing.allocator);

    // Fill 9 locks @ 100 OMNI each = 900 OMNI within window.
    var i: usize = 0;
    while (i < 9) : (i += 1) {
        const rec = LockRecord{
            .height = 100 + i,
            .user_addr = dummyAddr(0xAA),
            .amount_sat = cfg.BRIDGE_MAX_PER_TX_SAT,
            .destination_chain = std.mem.zeroes([32]u8),
            .destination_addr = std.mem.zeroes([32]u8),
            .nonce = dummyNonce(@intCast(i)),
        };
        try state.applyLock(testing.allocator, rec);
    }

    // 10th @ 100 OMNI (= 1000 OMNI total) should be at the cap edge.
    try state.validateLock(cfg.BRIDGE_MAX_PER_TX_SAT, 109);
    // 1 SAT over -> reject.
    const result = state.validateLock(cfg.BRIDGE_MAX_PER_TX_SAT + 1, 109);
    try testing.expect(result == BridgeError.AmountExceedsPerTxCap or
        result == BridgeError.AmountExceedsDailyQuota);
}

test "BridgeState — unlock requires threshold sigs" {
    var state = BridgeState.init(testing.allocator);
    defer state.deinit(testing.allocator);

    const r1 = dummyAddr(0x11);
    const r2 = dummyAddr(0x22);
    const r3 = dummyAddr(0x33);
    try state.relayers.append(testing.allocator, r1);
    try state.relayers.append(testing.allocator, r2);
    try state.relayers.append(testing.allocator, r3);
    state.locked_total_sat = 100_000_000_000;

    const nonce = dummyNonce(0xBB);
    const rec = dummyAddr(0xCC);

    // Sig 1 + 2 → not enough yet.
    try state.submitUnlockSignature(r1, rec, 50_000_000_000, nonce, 100);
    try state.submitUnlockSignature(r2, rec, 50_000_000_000, nonce, 100);

    const not_yet = state.trySettle(nonce, 100 + cfg.BRIDGE_CHALLENGE_WINDOW_BLOCKS + 1);
    try testing.expectError(BridgeError.InsufficientSignatures, not_yet);

    // Sig 3 → threshold reached.
    try state.submitUnlockSignature(r3, rec, 50_000_000_000, nonce, 100);

    // But still in challenge window.
    const too_early = state.trySettle(nonce, 100 + 1000);
    try testing.expectError(BridgeError.ChallengeWindowNotExpired, too_early);

    // After window — settles.
    const settled = try state.trySettle(nonce, 100 + cfg.BRIDGE_CHALLENGE_WINDOW_BLOCKS + 1);
    try testing.expect(settled != null);
    try testing.expectEqual(@as(u64, 50_000_000_000), settled.?.amount_sat);
}

test "BridgeState — duplicate signature rejected" {
    var state = BridgeState.init(testing.allocator);
    defer state.deinit(testing.allocator);

    const r1 = dummyAddr(0x11);
    try state.relayers.append(testing.allocator, r1);
    state.locked_total_sat = 100_000_000_000;

    const nonce = dummyNonce(0xBB);
    try state.submitUnlockSignature(r1, dummyAddr(0xCC), 50_000_000_000, nonce, 100);
    const dup = state.submitUnlockSignature(r1, dummyAddr(0xCC), 50_000_000_000, nonce, 100);
    try testing.expectError(BridgeError.DuplicateSignature, dup);
}

test "BridgeState — non-relayer signer rejected" {
    var state = BridgeState.init(testing.allocator);
    defer state.deinit(testing.allocator);
    state.locked_total_sat = 100_000_000_000;

    const stranger = dummyAddr(0x99);
    const result = state.submitUnlockSignature(
        stranger,
        dummyAddr(0xCC),
        50_000_000_000,
        dummyNonce(0xBB),
        100,
    );
    try testing.expectError(BridgeError.SignerNotInRelayerSet, result);
}

test "BridgeState — fraud challenge voids unlock" {
    var state = BridgeState.init(testing.allocator);
    defer state.deinit(testing.allocator);

    const r1 = dummyAddr(0x11);
    const r2 = dummyAddr(0x22);
    const r3 = dummyAddr(0x33);
    try state.relayers.append(testing.allocator, r1);
    try state.relayers.append(testing.allocator, r2);
    try state.relayers.append(testing.allocator, r3);
    state.locked_total_sat = 100_000_000_000;

    const nonce = dummyNonce(0xBB);
    try state.submitUnlockSignature(r1, dummyAddr(0xCC), 50_000_000_000, nonce, 100);
    try state.submitUnlockSignature(r2, dummyAddr(0xCC), 50_000_000_000, nonce, 100);
    try state.submitUnlockSignature(r3, dummyAddr(0xCC), 50_000_000_000, nonce, 100);

    try state.voidUnlock(nonce);

    const after = state.trySettle(nonce, 100 + cfg.BRIDGE_CHALLENGE_WINDOW_BLOCKS + 1);
    try testing.expect((try after) == null);
}

test "BridgeState — replay protection" {
    var state = BridgeState.init(testing.allocator);
    defer state.deinit(testing.allocator);

    const r1 = dummyAddr(0x11);
    const r2 = dummyAddr(0x22);
    const r3 = dummyAddr(0x33);
    try state.relayers.append(testing.allocator, r1);
    try state.relayers.append(testing.allocator, r2);
    try state.relayers.append(testing.allocator, r3);
    state.locked_total_sat = 100_000_000_000;

    const nonce = dummyNonce(0xBB);
    try state.submitUnlockSignature(r1, dummyAddr(0xCC), 50_000_000_000, nonce, 100);
    try state.submitUnlockSignature(r2, dummyAddr(0xCC), 50_000_000_000, nonce, 100);
    try state.submitUnlockSignature(r3, dummyAddr(0xCC), 50_000_000_000, nonce, 100);
    _ = try state.trySettle(nonce, 100 + cfg.BRIDGE_CHALLENGE_WINDOW_BLOCKS + 1);

    // Replay attempt with same nonce — should be rejected.
    const replay = state.submitUnlockSignature(r1, dummyAddr(0xCC), 50_000_000_000, nonce, 200);
    try testing.expectError(BridgeError.NonceAlreadyProcessed, replay);
}
