const std = @import("std");

/// Built-in DNS / Herotag System
///
/// On-chain name-to-address registry (ca EGLD Herotag, ETH ENS, Solana SNS):
///   - @username -> ob_omni_address
///   - Human-readable names instead of long hex addresses
///   - Names are unique, first-come-first-served
///   - Transfer + expiry support
///
/// Diferenta fata de domain_minter.zig:
///   domain_minter = PQ domain derivation (ob_omni_, ob_k1_, etc.)
///   dns_registry  = human-readable names mapped to addresses (@alice -> ob_omni_...)

/// Maximum name length (like EGLD herotag: 25 chars)
pub const MAX_NAME_LEN: usize = 25;
/// Minimum name length
pub const MIN_NAME_LEN: usize = 3;
/// Maximum registry entries (per-node tracking, full registry on disk)
pub const MAX_ENTRIES: usize = 1024;
/// Registration cost in SAT (1 OMNI)
pub const REGISTER_COST_SAT: u64 = 1_000_000_000;
/// Renewal period in blocks (~1 year = 365.25 * 86400 blocks at 1/s)
pub const RENEWAL_PERIOD_BLOCKS: u64 = 31_557_600;

/// Valid characters for names (alphanumeric + underscore, like EGLD herotag)
fn isValidNameChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '_';
}

/// Validate a name
pub fn isValidName(name: []const u8) bool {
    if (name.len < MIN_NAME_LEN or name.len > MAX_NAME_LEN) return false;
    // Must start with letter
    if (name[0] < 'a' or name[0] > 'z') return false;
    for (name) |c| {
        if (!isValidNameChar(c)) return false;
    }
    return true;
}

/// DNS entry
pub const DnsEntry = struct {
    /// Registered name (lowercase, alphanumeric)
    name: [MAX_NAME_LEN]u8,
    name_len: u8,
    /// Address this name resolves to
    address: [64]u8,
    addr_len: u8,
    /// Owner who registered (may differ from address)
    owner: [64]u8,
    owner_len: u8,
    /// Block when registered
    registered_block: u64,
    /// Block when registration expires
    expires_block: u64,
    /// Is this entry active
    active: bool,

    pub fn getName(self: *const DnsEntry) []const u8 {
        return self.name[0..self.name_len];
    }

    pub fn getAddress(self: *const DnsEntry) []const u8 {
        return self.address[0..self.addr_len];
    }

    pub fn isExpired(self: *const DnsEntry, current_block: u64) bool {
        return current_block >= self.expires_block;
    }
};

/// DNS Registry Engine
pub const DnsRegistry = struct {
    entries: [MAX_ENTRIES]DnsEntry,
    entry_count: usize,

    pub fn init() DnsRegistry {
        return .{
            .entries = undefined,
            .entry_count = 0,
        };
    }

    /// Register a new name
    pub fn register(
        self: *DnsRegistry,
        name: []const u8,
        address: []const u8,
        owner: []const u8,
        current_block: u64,
    ) !void {
        if (!isValidName(name)) return error.InvalidName;
        if (self.entry_count >= MAX_ENTRIES) return error.RegistryFull;

        // Check if name already taken and not expired
        if (self.resolve(name, current_block) != null) return error.NameTaken;

        var entry: DnsEntry = std.mem.zeroes(DnsEntry);
        const nlen = @min(name.len, MAX_NAME_LEN);
        @memcpy(entry.name[0..nlen], name[0..nlen]);
        entry.name_len = @intCast(nlen);

        const alen = @min(address.len, 64);
        @memcpy(entry.address[0..alen], address[0..alen]);
        entry.addr_len = @intCast(alen);

        const olen = @min(owner.len, 64);
        @memcpy(entry.owner[0..olen], owner[0..olen]);
        entry.owner_len = @intCast(olen);

        entry.registered_block = current_block;
        entry.expires_block = current_block + RENEWAL_PERIOD_BLOCKS;
        entry.active = true;

        self.entries[self.entry_count] = entry;
        self.entry_count += 1;
    }

    /// Resolve name to address
    pub fn resolve(self: *const DnsRegistry, name: []const u8, current_block: u64) ?[]const u8 {
        for (self.entries[0..self.entry_count]) |*e| {
            if (e.active and !e.isExpired(current_block) and
                std.mem.eql(u8, e.getName(), name))
            {
                return e.getAddress();
            }
        }
        return null;
    }

    /// Reverse resolve: address to name
    pub fn reverseResolve(self: *const DnsRegistry, address: []const u8, current_block: u64) ?[]const u8 {
        for (self.entries[0..self.entry_count]) |*e| {
            if (e.active and !e.isExpired(current_block) and
                std.mem.eql(u8, e.getAddress(), address))
            {
                return e.getName();
            }
        }
        return null;
    }

    /// Renew a name (extend expiry)
    pub fn renew(self: *DnsRegistry, name: []const u8, owner: []const u8, current_block: u64) !void {
        for (self.entries[0..self.entry_count]) |*e| {
            if (std.mem.eql(u8, e.getName(), name)) {
                if (!std.mem.eql(u8, e.owner[0..e.owner_len], owner)) return error.NotOwner;
                e.expires_block = current_block + RENEWAL_PERIOD_BLOCKS;
                return;
            }
        }
        return error.NameNotFound;
    }

    /// Transfer name to new owner/address
    pub fn transfer(self: *DnsRegistry, name: []const u8, current_owner: []const u8,
                     new_address: []const u8, new_owner: []const u8) !void {
        for (self.entries[0..self.entry_count]) |*e| {
            if (std.mem.eql(u8, e.getName(), name)) {
                if (!std.mem.eql(u8, e.owner[0..e.owner_len], current_owner)) return error.NotOwner;
                const alen = @min(new_address.len, 64);
                @memcpy(e.address[0..alen], new_address[0..alen]);
                e.addr_len = @intCast(alen);
                const olen = @min(new_owner.len, 64);
                @memcpy(e.owner[0..olen], new_owner[0..olen]);
                e.owner_len = @intCast(olen);
                return;
            }
        }
        return error.NameNotFound;
    }

    /// Count active (non-expired) entries
    pub fn activeCount(self: *const DnsRegistry, current_block: u64) usize {
        var count: usize = 0;
        for (self.entries[0..self.entry_count]) |e| {
            if (e.active and !e.isExpired(current_block)) count += 1;
        }
        return count;
    }
};

// ─── Tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

test "isValidName — valid names" {
    try testing.expect(isValidName("alice"));
    try testing.expect(isValidName("bob_123"));
    try testing.expect(isValidName("validator_node_01"));
}

test "isValidName — invalid names" {
    try testing.expect(!isValidName("ab"));          // too short
    try testing.expect(!isValidName("ALICE"));        // uppercase
    try testing.expect(!isValidName("alice.bob"));    // dot
    try testing.expect(!isValidName("1alice"));       // starts with number
    try testing.expect(!isValidName("alice bob"));    // space
    try testing.expect(!isValidName("abcdefghijklmnopqrstuvwxyz1")); // too long (27)
}

test "DnsRegistry — register and resolve" {
    var reg = DnsRegistry.init();
    try reg.register("alice", "ob1qxyca6f2cuw906ecwkzj9spdvrtpq0qwmzdefxf", "ob1qxyca6f2cuw906ecwkzj9spdvrtpq0qwmzdefxf", 1000);
    const addr = reg.resolve("alice", 1001);
    try testing.expect(addr != null);
    try testing.expectEqualStrings("ob1qxyca6f2cuw906ecwkzj9spdvrtpq0qwmzdefxf", addr.?);
}

test "DnsRegistry — name taken" {
    var reg = DnsRegistry.init();
    try reg.register("bob", "ob1qvkpmansk8z28n9v9g5rx07x3r9xht7kcv5tkvc", "ob1qvkpmansk8z28n9v9g5rx07x3r9xht7kcv5tkvc", 1000);
    try testing.expectError(error.NameTaken,
        reg.register("bob", "ob1q632e5a5f9njdlucpm2g7cqsf7p2gk3u8h25wah", "ob1q632e5a5f9njdlucpm2g7cqsf7p2gk3u8h25wah", 1001));
}

test "DnsRegistry — expired name can be re-registered" {
    var reg = DnsRegistry.init();
    try reg.register("temp", "ob1qu48cza4ny77jw762kjky6gvsjqz4vmn09suwl9", "ob1qu48cza4ny77jw762kjky6gvsjqz4vmn09suwl9", 1000);
    // After RENEWAL_PERIOD_BLOCKS, name expires
    const future_block = 1000 + RENEWAL_PERIOD_BLOCKS + 1;
    try testing.expect(reg.resolve("temp", future_block) == null);
    // Can re-register
    try reg.register("temp", "ob1q2rjzulwvagksc9wu2eym26jzkyjqnjdl4qgevt", "ob1q2rjzulwvagksc9wu2eym26jzkyjqnjdl4qgevt", future_block);
    try testing.expectEqualStrings("ob1q2rjzulwvagksc9wu2eym26jzkyjqnjdl4qgevt", reg.resolve("temp", future_block + 1).?);
}

test "DnsRegistry — reverse resolve" {
    var reg = DnsRegistry.init();
    try reg.register("carol", "ob1qygr9gcwr2nke94levj9ymmfkdt2as03ln4xeth", "ob1qygr9gcwr2nke94levj9ymmfkdt2as03ln4xeth", 1000);
    const name = reg.reverseResolve("ob1qygr9gcwr2nke94levj9ymmfkdt2as03ln4xeth", 1001);
    try testing.expect(name != null);
    try testing.expectEqualStrings("carol", name.?);
}

test "DnsRegistry — transfer" {
    var reg = DnsRegistry.init();
    try reg.register("dave", "ob1qagagaf3lr3wk4j4ht28atd9hsgu3cxdm765d7n", "ob1qagagaf3lr3wk4j4ht28atd9hsgu3cxdm765d7n", 1000);
    try reg.transfer("dave", "ob1qagagaf3lr3wk4j4ht28atd9hsgu3cxdm765d7n", "ob1qf7wv3txfsxwrxw5nypvpe5r0c3p2srkuqv4clx", "ob1qf7wv3txfsxwrxw5nypvpe5r0c3p2srkuqv4clx");
    try testing.expectEqualStrings("ob1qf7wv3txfsxwrxw5nypvpe5r0c3p2srkuqv4clx", reg.resolve("dave", 1001).?);
}

test "DnsRegistry — transfer by non-owner fails" {
    var reg = DnsRegistry.init();
    try reg.register("eve", "ob1qdz28c9t6r9qy33pu2agsnmms9nje88ejxrltgt", "ob1qdz28c9t6r9qy33pu2agsnmms9nje88ejxrltgt", 1000);
    try testing.expectError(error.NotOwner,
        reg.transfer("eve", "ob1q4h8ygpvx96d8u3mkdt0phyyunmzevgc5k96qgg", "ob1q4h8ygpvx96d8u3mkdt0phyyunmzevgc5k96qgg", "ob1q4h8ygpvx96d8u3mkdt0phyyunmzevgc5k96qgg"));
}

test "DnsRegistry — renew" {
    var reg = DnsRegistry.init();
    try reg.register("frank", "ob1q8lrgnmdspgyj3lwt5d8zehlarzqrdxffsgx5u0", "ob1q8lrgnmdspgyj3lwt5d8zehlarzqrdxffsgx5u0", 1000);
    try reg.renew("frank", "ob1q8lrgnmdspgyj3lwt5d8zehlarzqrdxffsgx5u0", 2000);
    // Should be valid far in the future
    try testing.expect(reg.resolve("frank", 2000 + RENEWAL_PERIOD_BLOCKS - 1) != null);
}

test "DnsRegistry — active count" {
    var reg = DnsRegistry.init();
    try reg.register("aaa", "ob1qrgq6jnvvhcmp03ur849a85mhdvsvaqf6dprzn4", "ob1qrgq6jnvvhcmp03ur849a85mhdvsvaqf6dprzn4", 1000);
    try reg.register("bbb", "ob1qn8hr9y543qdvegeueffktd9lkrt2vq6q457xa0", "ob1qn8hr9y543qdvegeueffktd9lkrt2vq6q457xa0", 1000);
    try testing.expectEqual(@as(usize, 2), reg.activeCount(1001));
}
