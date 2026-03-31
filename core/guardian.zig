const std = @import("std");
const secp256k1_mod = @import("secp256k1.zig");

const Secp256k1Crypto = secp256k1_mod.Secp256k1Crypto;

/// Guardian System — On-Chain 2FA (ca MultiversX/EGLD Guardian)
///
/// Fiecare cont poate seta un "guardian" = co-signer obligatoriu:
///   - TX normale: semnatura owner + semnatura guardian
///   - Fara guardian setat: TX normale (doar owner)
///   - Guardian poate fi: hardware wallet, trusted service, alt cont
///   - Guardian nu poate trimite TX singur (doar co-sign)
///
/// Flow:
///   1. Owner seteaza guardian: setGuardian(guardian_pubkey)
///   2. TX: owner semneaza + guardian co-semneaza
///   3. Validare: ambele semnaturi verificate
///   4. Remove guardian: necesita si semnatura guardianului (safety)
///
/// Activare delayed: 20 epochs (previne hijacking instant)

/// Guardian activation delay in blocks (prevent instant hijack)
pub const GUARDIAN_ACTIVATION_DELAY: u64 = 20_000; // ~5.5 ore
/// Maximum guardians per account (for future multi-guardian)
pub const MAX_GUARDIANS: usize = 3;
/// Maximum accounts tracked
pub const MAX_GUARDED_ACCOUNTS: usize = 4096;

/// Guardian status
pub const GuardianStatus = enum(u8) {
    /// Not yet active (in activation delay)
    pending = 0,
    /// Active — required for TX authorization
    active = 1,
    /// Removal pending (in cooldown)
    removing = 2,
    /// Removed
    removed = 3,
};

/// Guardian record for an account
pub const GuardianRecord = struct {
    /// Account address hash
    account: [32]u8,
    /// Guardian's compressed public key (33 bytes secp256k1)
    guardian_pubkey: [33]u8,
    /// When guardian was set
    set_block: u64,
    /// When guardian becomes active
    active_block: u64,
    /// Current status
    status: GuardianStatus,

    pub fn isActive(self: *const GuardianRecord, current_block: u64) bool {
        return self.status == .active and current_block >= self.active_block;
    }
};

/// Guardian Engine
pub const GuardianEngine = struct {
    records: [MAX_GUARDED_ACCOUNTS]GuardianRecord,
    record_count: usize,

    pub fn init() GuardianEngine {
        return .{
            .records = undefined,
            .record_count = 0,
        };
    }

    /// Set a guardian for an account (starts as pending)
    pub fn setGuardian(self: *GuardianEngine, account: [32]u8, guardian_pubkey: [33]u8, current_block: u64) !void {
        // Check if already has active guardian
        if (self.getActiveGuardian(account, current_block) != null) return error.AlreadyGuarded;
        if (self.record_count >= MAX_GUARDED_ACCOUNTS) return error.RegistryFull;

        self.records[self.record_count] = .{
            .account = account,
            .guardian_pubkey = guardian_pubkey,
            .set_block = current_block,
            .active_block = current_block + GUARDIAN_ACTIVATION_DELAY,
            .status = .pending,
        };
        self.record_count += 1;
    }

    /// Activate a pending guardian (called when activation delay passes)
    pub fn activateGuardian(self: *GuardianEngine, account: [32]u8, current_block: u64) !void {
        for (self.records[0..self.record_count]) |*r| {
            if (std.mem.eql(u8, &r.account, &account) and r.status == .pending) {
                if (current_block < r.active_block) return error.ActivationDelayNotMet;
                r.status = .active;
                return;
            }
        }
        return error.NoPendingGuardian;
    }

    /// Remove guardian (requires guardian co-signature)
    pub fn removeGuardian(self: *GuardianEngine, account: [32]u8) !void {
        for (self.records[0..self.record_count]) |*r| {
            if (std.mem.eql(u8, &r.account, &account) and
                (r.status == .active or r.status == .pending))
            {
                r.status = .removed;
                return;
            }
        }
        return error.NoGuardianFound;
    }

    /// Get active guardian for account (null if none)
    pub fn getActiveGuardian(self: *const GuardianEngine, account: [32]u8, current_block: u64) ?[33]u8 {
        for (self.records[0..self.record_count]) |r| {
            if (std.mem.eql(u8, &r.account, &account) and r.isActive(current_block)) {
                return r.guardian_pubkey;
            }
        }
        return null;
    }

    /// Check if account requires guardian co-signature
    pub fn requiresGuardian(self: *const GuardianEngine, account: [32]u8, current_block: u64) bool {
        return self.getActiveGuardian(account, current_block) != null;
    }

    /// Verify a guarded transaction: owner sig + guardian sig
    pub fn verifyGuardedTx(
        self: *const GuardianEngine,
        account: [32]u8,
        message_hash: [32]u8,
        owner_sig: [64]u8,
        owner_pubkey: [33]u8,
        guardian_sig: [64]u8,
        current_block: u64,
    ) bool {
        // 1. Verify owner signature
        if (!Secp256k1Crypto.verify(owner_pubkey, &message_hash, owner_sig)) return false;

        // 2. Get guardian public key
        const guardian_pk = self.getActiveGuardian(account, current_block) orelse {
            // No guardian = only owner sig needed (already verified)
            return true;
        };

        // 3. Verify guardian signature
        return Secp256k1Crypto.verify(guardian_pk, &message_hash, guardian_sig);
    }

    /// Count guarded accounts
    pub fn guardedCount(self: *const GuardianEngine, current_block: u64) usize {
        var count: usize = 0;
        for (self.records[0..self.record_count]) |r| {
            if (r.isActive(current_block)) count += 1;
        }
        return count;
    }
};

// ─── Tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

test "GuardianEngine — set guardian (pending)" {
    var engine = GuardianEngine.init();
    const account = [_]u8{0xAA} ** 32;
    const guardian_pk = [_]u8{0x02} ++ [_]u8{0xBB} ** 32;
    try engine.setGuardian(account, guardian_pk, 1000);
    try testing.expectEqual(@as(usize, 1), engine.record_count);
    // Not active yet (pending)
    try testing.expect(!engine.requiresGuardian(account, 1001));
}

test "GuardianEngine — activate after delay" {
    var engine = GuardianEngine.init();
    const account = [_]u8{0xCC} ** 32;
    const guardian_pk = [_]u8{0x02} ++ [_]u8{0xDD} ** 32;
    try engine.setGuardian(account, guardian_pk, 1000);

    // Too early
    try testing.expectError(error.ActivationDelayNotMet,
        engine.activateGuardian(account, 1000 + GUARDIAN_ACTIVATION_DELAY - 1));

    // After delay
    try engine.activateGuardian(account, 1000 + GUARDIAN_ACTIVATION_DELAY);
    try testing.expect(engine.requiresGuardian(account, 1000 + GUARDIAN_ACTIVATION_DELAY));
}

test "GuardianEngine — duplicate guardian fails" {
    var engine = GuardianEngine.init();
    const account = [_]u8{0xEE} ** 32;
    const pk1 = [_]u8{0x02} ++ [_]u8{0x11} ** 32;
    const pk2 = [_]u8{0x02} ++ [_]u8{0x22} ** 32;

    try engine.setGuardian(account, pk1, 1000);
    try engine.activateGuardian(account, 1000 + GUARDIAN_ACTIVATION_DELAY);

    // Already has guardian — try after activation delay
    const after_activation = 1000 + GUARDIAN_ACTIVATION_DELAY + 1;
    try testing.expectError(error.AlreadyGuarded,
        engine.setGuardian(account, pk2, after_activation));
}

test "GuardianEngine — remove guardian" {
    var engine = GuardianEngine.init();
    const account = [_]u8{0xFF} ** 32;
    const pk = [_]u8{0x02} ++ [_]u8{0x33} ** 32;

    try engine.setGuardian(account, pk, 1000);
    try engine.activateGuardian(account, 1000 + GUARDIAN_ACTIVATION_DELAY);
    try testing.expect(engine.requiresGuardian(account, 1000 + GUARDIAN_ACTIVATION_DELAY));

    try engine.removeGuardian(account);
    try testing.expect(!engine.requiresGuardian(account, 1000 + GUARDIAN_ACTIVATION_DELAY + 1));
}

test "GuardianEngine — unguarded account doesn't need guardian" {
    var engine = GuardianEngine.init();
    const account = [_]u8{0x44} ** 32;
    try testing.expect(!engine.requiresGuardian(account, 1000));
}

test "GuardianEngine — guarded count" {
    var engine = GuardianEngine.init();
    const a1 = [_]u8{0x01} ** 32;
    const a2 = [_]u8{0x02} ** 32;
    const pk = [_]u8{0x02} ++ [_]u8{0x55} ** 32;

    try engine.setGuardian(a1, pk, 100);
    try engine.setGuardian(a2, pk, 100);
    try engine.activateGuardian(a1, 100 + GUARDIAN_ACTIVATION_DELAY);
    try engine.activateGuardian(a2, 100 + GUARDIAN_ACTIVATION_DELAY);

    try testing.expectEqual(@as(usize, 2), engine.guardedCount(100 + GUARDIAN_ACTIVATION_DELAY));
}

test "GuardianRecord — isActive" {
    const r = GuardianRecord{
        .account = [_]u8{0} ** 32,
        .guardian_pubkey = [_]u8{0x02} ++ [_]u8{0} ** 32,
        .set_block = 100,
        .active_block = 200,
        .status = .active,
    };
    try testing.expect(!r.isActive(199)); // before activation
    try testing.expect(r.isActive(200));  // exactly at activation
    try testing.expect(r.isActive(300));  // after activation
}
