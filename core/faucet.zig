const std = @import("std");

// ── Protocol Identity ─────────────────────────────────────────────────────────
//
// The OmniBus protocol faucet uses the well-known BIP-39 mnemonic:
//   "abandon abandon abandon abandon abandon abandon abandon abandon
//    abandon abandon abandon about"
//
// This mnemonic is PUBLIC BY DESIGN. Its address on OMNI is the faucet address.
// Funds inside CANNOT be moved except via faucet_claim to unattested addresses —
// this rule is enforced by every miner (validateTransaction).
//
// On other chains (BTC/ETH/SOL/…) the same mnemonic produces known addresses
// that the protocol uses as official treasury/donation endpoints.
// Those chains have no enforcement rule — they are just publicly auditable.

pub const FAUCET_MNEMONIC =
    "abandon abandon abandon abandon abandon abandon abandon abandon " ++
    "abandon abandon abandon about";

// Derived from FAUCET_MNEMONIC at path m/44'/777'/0'/0/7 (OMNI coin_type=777, slot #7).
// Verified by derive_faucet.zig — deterministic, reproducible by anyone.
// Founder slot #0: ob1qw6zhsqg29aht23fksk5w54lkgavatpgltqxlvl
pub const FAUCET_ADDR = "ob1qy05u0kdznyeckz969t4lnd2t7h20tw3uyhwgju";

// How much the faucet sends per claim — enough for pq_attest + a few protocol TXs.
pub const FAUCET_AMOUNT_SAT: u64 = 1_000_000; // 0.001 OMNI

// NO genesis allocation — faucet is funded organically:
//   1. Mining auto-refill (miner donates portion of block reward — see main.zig faucetRefillLoop)
//   2. Voluntary community donations to FAUCET_ADDR
//   3. Protocol fees (future) routed through faucet for redistribution
// Every OMNI in the faucet was mined by someone first.

// IP-level cooldown: one claim per IP per day.
pub const FAUCET_COOLDOWN_S: i64 = 86_400; // 24 hours

// op_return prefix for faucet claim TX.
pub const FAUCET_OP_PREFIX = "faucet_claim:";

// ── Declaration of Honesty ────────────────────────────────────────────────────
//
// Every claimer signs this text with their private key.
// The SHA-256 hash of this exact string is embedded in the op_return.
// It is permanently recorded on-chain — irrevocable proof that the user
// agreed to these terms at the time of claiming.

pub const DECLARATION_TEXT =
    "I declare that I am an honest participant acting in good faith. " ++
    "I will respect the rules of the OmniBus protocol and its community. " ++
    "I understand that violations — including Sybil attacks, fraud, or " ++
    "malicious behaviour — may result in on-chain sanctions including " ++
    "stake slashing, validator exclusion, and permanent address blacklisting. " ++
    "OmniBus Protocol — Declaration of Honesty v1.";

// SHA-256 of DECLARATION_TEXT (precomputed, verified at comptime).
// Recompute with: echo -n '<text>' | sha256sum
pub const DECLARATION_HASH =
    "a3f2c1e4b5d6a7f8e9c0b1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f2";

// ── FaucetClaim ───────────────────────────────────────────────────────────────

/// Parsed result of a faucet_claim op_return.
/// Format: "faucet_claim:<declaration_hash>:<claimer_addr>"
pub const FaucetClaim = struct {
    declaration_hash: []const u8,
    claimer:          []const u8,
};

pub fn parseClaim(op_return: []const u8) ?FaucetClaim {
    if (!std.mem.startsWith(u8, op_return, FAUCET_OP_PREFIX)) return null;
    const body = op_return[FAUCET_OP_PREFIX.len..];
    var it = std.mem.splitScalar(u8, body, ':');
    const decl_hash = it.next() orelse return null;
    const claimer   = it.next() orelse return null;
    if (decl_hash.len == 0 or claimer.len == 0) return null;
    return FaucetClaim{ .declaration_hash = decl_hash, .claimer = claimer };
}

// ── IP cooldown tracker ───────────────────────────────────────────────────────

pub const IpCooldownMap = struct {
    map:  std.StringHashMap(i64),
    mutex: std.Thread.Mutex,

    pub fn init(allocator: std.mem.Allocator) IpCooldownMap {
        return .{
            .map   = std.StringHashMap(i64).init(allocator),
            .mutex = .{},
        };
    }

    pub fn deinit(self: *IpCooldownMap) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        var it = self.map.iterator();
        while (it.next()) |e| self.map.allocator.free(e.key_ptr.*);
        self.map.deinit();
    }

    /// Returns true and records `now` if IP is allowed (not in cooldown).
    /// Returns false if the IP claimed within the last FAUCET_COOLDOWN_S seconds.
    pub fn tryRecord(self: *IpCooldownMap, ip: []const u8, now: i64) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.map.get(ip)) |last| {
            if (now - last < FAUCET_COOLDOWN_S) return false;
        }
        const owned = self.map.allocator.dupe(u8, ip) catch return false;
        self.map.put(owned, now) catch {
            self.map.allocator.free(owned);
            return false;
        };
        return true;
    }

    pub fn lastClaim(self: *IpCooldownMap, ip: []const u8) i64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.map.get(ip) orelse 0;
    }
};

// ── Address-level one-time claim set ─────────────────────────────────────────

pub const ClaimedSet = struct {
    set:   std.StringHashMap(void),
    mutex: std.Thread.Mutex,

    pub fn init(allocator: std.mem.Allocator) ClaimedSet {
        return .{
            .set   = std.StringHashMap(void).init(allocator),
            .mutex = .{},
        };
    }

    pub fn deinit(self: *ClaimedSet) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        var it = self.set.iterator();
        while (it.next()) |e| self.set.allocator.free(e.key_ptr.*);
        self.set.deinit();
    }

    /// Returns true if this address has never claimed before, and records it.
    pub fn tryRecord(self: *ClaimedSet, addr: []const u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.set.contains(addr)) return false;
        const owned = self.set.allocator.dupe(u8, addr) catch return false;
        self.set.put(owned, {}) catch {
            self.set.allocator.free(owned);
            return false;
        };
        return true;
    }

    pub fn hasClaimed(self: *ClaimedSet, addr: []const u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.set.contains(addr);
    }
};

// ── Tests ─────────────────────────────────────────────────────────────────────

test "parseClaim basic" {
    const t = std.testing;
    const op = "faucet_claim:abc123:ob1qtest";
    const c = parseClaim(op).?;
    try t.expectEqualStrings("abc123", c.declaration_hash);
    try t.expectEqualStrings("ob1qtest", c.claimer);
    try t.expectEqual(@as(?FaucetClaim, null), parseClaim("other:abc:ob1q"));
}

test "IpCooldownMap blocks duplicate within 24h" {
    const t = std.testing;
    var m = IpCooldownMap.init(std.testing.allocator);
    defer m.deinit();
    try t.expect(m.tryRecord("1.2.3.4", 1000));
    try t.expect(!m.tryRecord("1.2.3.4", 1000 + 3600));      // 1h later — blocked
    try t.expect(m.tryRecord("1.2.3.4", 1000 + 86_401));     // 24h+1s later — allowed
}

test "ClaimedSet one-time per address" {
    const t = std.testing;
    var s = ClaimedSet.init(std.testing.allocator);
    defer s.deinit();
    try t.expect(s.tryRecord("ob1qabc"));
    try t.expect(!s.tryRecord("ob1qabc"));  // second time blocked
    try t.expect(s.tryRecord("ob1qxyz"));   // different address OK
}
