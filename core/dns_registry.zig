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
pub const MAX_ENTRIES: usize = 4096;
/// Registration cost in SAT (1 OMNI = 1e9 SAT).
/// Default cost — used if no per-TLD override.
pub const REGISTER_COST_SAT: u64 = 1_000_000_000;
/// Per-TLD fee. Alex (2026-04-27): "5 sau 10 OMNI"
pub const COST_OMNIBUS_SAT: u64 = 5_000_000_000;   // 5 OMNI per .omnibus name
pub const COST_ARBITRAJE_SAT: u64 = 10_000_000_000; // 10 OMNI per .arbitraje name (premium)
/// Renewal period in blocks (~1 year = 365.25 * 86400 blocks at 1/s)
pub const RENEWAL_PERIOD_BLOCKS: u64 = 31_557_600;

/// Returneaza fee-ul required pentru un TLD (in SAT).
pub fn feeForTld(tld: []const u8) u64 {
    if (std.mem.eql(u8, tld, "omnibus")) return COST_OMNIBUS_SAT;
    if (std.mem.eql(u8, tld, "arbitraje")) return COST_ARBITRAJE_SAT;
    return REGISTER_COST_SAT; // fallback
}

/// Maximum TLD length. ".omnibus" = 7 chars (no dot), ".arbitraje" = 9 chars.
pub const MAX_TLD_LEN: usize = 16;
/// Default TLD if caller doesn't specify (backward compat).
pub const DEFAULT_TLD: []const u8 = "omnibus";

/// Currently allowed TLDs. Add new ones here.
pub const ALLOWED_TLDS = [_][]const u8{
    "omnibus",   // base TLD
    "arbitraje", // for arbitrage agents / market-making nodes
};

pub fn isValidTld(tld: []const u8) bool {
    for (ALLOWED_TLDS) |t| {
        if (std.mem.eql(u8, tld, t)) return true;
    }
    return false;
}

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
    /// TLD (e.g. "omnibus", "arbitraje"). Default = DEFAULT_TLD.
    tld: [MAX_TLD_LEN]u8,
    tld_len: u8,
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

    pub fn getTld(self: *const DnsEntry) []const u8 {
        if (self.tld_len == 0) return DEFAULT_TLD;
        return self.tld[0..self.tld_len];
    }

    /// Full label including TLD: "alice.omnibus" sau "arb_hunter.arbitraje".
    /// `out_buf` must be ≥ MAX_NAME_LEN + 1 + MAX_TLD_LEN.
    pub fn fullLabel(self: *const DnsEntry, out_buf: []u8) []const u8 {
        const n = self.getName();
        const t = self.getTld();
        const total = n.len + 1 + t.len;
        if (out_buf.len < total) return n; // safety fallback
        @memcpy(out_buf[0..n.len], n);
        out_buf[n.len] = '.';
        @memcpy(out_buf[n.len + 1 .. n.len + 1 + t.len], t);
        return out_buf[0..total];
    }

    pub fn getAddress(self: *const DnsEntry) []const u8 {
        return self.address[0..self.addr_len];
    }

    pub fn isExpired(self: *const DnsEntry, current_block: u64) bool {
        return current_block >= self.expires_block;
    }
};

/// Maximum tracked consumed-txid entries (anti-replay pentru fee TX-uri).
/// 4096 ar însemna 4096 nume înregistrate cu fee — generos pentru testnet.
pub const MAX_CONSUMED_TXIDS: usize = 4096;
/// Length of a TX hash hex (SHA256d → 64 hex chars).
pub const TXID_LEN: usize = 64;

/// DNS Registry Engine
pub const DnsRegistry = struct {
    entries: [MAX_ENTRIES]DnsEntry,
    entry_count: usize,
    /// Treasury address — fee-urile ENS trebuie sa mearga aici. Setat de
    /// caller via setTreasury() la startup. Empty = no fee enforcement (testnet).
    treasury_address: [64]u8,
    treasury_addr_len: u8,
    /// Fee enforcement on/off. Cand off, registername merge fara fee (testnet
    /// dev mode). Cand on, mandatory.
    fee_enforcement: bool,
    /// Set of consumed fee-txids (anti-replay).
    consumed_txids: [MAX_CONSUMED_TXIDS][TXID_LEN]u8,
    consumed_count: usize,

    pub fn init() DnsRegistry {
        return .{
            .entries = undefined,
            .entry_count = 0,
            .treasury_address = std.mem.zeroes([64]u8),
            .treasury_addr_len = 0,
            .fee_enforcement = false,
            .consumed_txids = std.mem.zeroes([MAX_CONSUMED_TXIDS][TXID_LEN]u8),
            .consumed_count = 0,
        };
    }

    /// Set the treasury address pentru fee-uri. Apelat la startup din main.zig
    /// dupa ce wallet-ul e derivat (idx 3 = ens.omnibus per memory).
    pub fn setTreasury(self: *DnsRegistry, address: []const u8) void {
        const len = @min(address.len, 64);
        @memcpy(self.treasury_address[0..len], address[0..len]);
        self.treasury_addr_len = @intCast(len);
    }

    pub fn getTreasury(self: *const DnsRegistry) []const u8 {
        return self.treasury_address[0..self.treasury_addr_len];
    }

    pub fn enableFee(self: *DnsRegistry, enable: bool) void {
        self.fee_enforcement = enable;
    }

    pub fn isTxidConsumed(self: *const DnsRegistry, txid: []const u8) bool {
        if (txid.len != TXID_LEN) return false;
        for (self.consumed_txids[0..self.consumed_count]) |t| {
            if (std.mem.eql(u8, &t, txid[0..TXID_LEN])) return true;
        }
        return false;
    }

    fn consumeTxid(self: *DnsRegistry, txid: []const u8) !void {
        if (txid.len != TXID_LEN) return error.InvalidTxid;
        if (self.consumed_count >= MAX_CONSUMED_TXIDS) return error.ConsumedTxidsFull;
        @memcpy(self.consumed_txids[self.consumed_count][0..], txid[0..TXID_LEN]);
        self.consumed_count += 1;
    }

    /// Register a new name (default TLD = "omnibus" for backward compat).
    pub fn register(
        self: *DnsRegistry,
        name: []const u8,
        address: []const u8,
        owner: []const u8,
        current_block: u64,
    ) !void {
        return self.registerWithTld(name, DEFAULT_TLD, address, owner, current_block);
    }

    /// Verify fee context BEFORE register. Caller-ul (rpc_server) face check-uri:
    ///   - tx confirmed in chain
    ///   - tx.to == treasury_address
    ///   - tx.amount >= feeForTld(tld)
    ///   - tx.txid not already consumed
    /// Apoi apeleaza registerWithTldAndFee(...) care consume txid-ul atomic.
    /// Daca fee_enforcement = false, fee_txid e ignorat (testnet dev mode).
    pub fn registerWithTldAndFee(
        self: *DnsRegistry,
        name: []const u8,
        tld: []const u8,
        address: []const u8,
        owner: []const u8,
        current_block: u64,
        fee_txid: ?[]const u8,
    ) !void {
        if (self.fee_enforcement) {
            const txid = fee_txid orelse return error.FeeRequired;
            if (txid.len != TXID_LEN) return error.InvalidTxid;
            if (self.isTxidConsumed(txid)) return error.TxidAlreadyUsed;
            // Caller (rpc_server) trebuie sa fi validat ca TX exista, are
            // amount corect, si destinatie e treasury. Aici doar consume.
            try self.consumeTxid(txid);
        }
        try self.registerWithTld(name, tld, address, owner, current_block);
    }

    /// Register with explicit TLD ("omnibus" sau "arbitraje").
    pub fn registerWithTld(
        self: *DnsRegistry,
        name: []const u8,
        tld: []const u8,
        address: []const u8,
        owner: []const u8,
        current_block: u64,
    ) !void {
        if (!isValidName(name)) return error.InvalidName;
        if (!isValidTld(tld)) return error.InvalidTld;
        if (self.entry_count >= MAX_ENTRIES) return error.RegistryFull;

        // Name+TLD pair must be unique. "alice.omnibus" si "alice.arbitraje" pot coexista.
        if (self.resolveWithTld(name, tld, current_block) != null) return error.NameTaken;

        var entry: DnsEntry = std.mem.zeroes(DnsEntry);
        const nlen = @min(name.len, MAX_NAME_LEN);
        @memcpy(entry.name[0..nlen], name[0..nlen]);
        entry.name_len = @intCast(nlen);

        const tlen = @min(tld.len, MAX_TLD_LEN);
        @memcpy(entry.tld[0..tlen], tld[0..tlen]);
        entry.tld_len = @intCast(tlen);

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

    /// Resolve name (default TLD = "omnibus" for backward compat).
    pub fn resolve(self: *const DnsRegistry, name: []const u8, current_block: u64) ?[]const u8 {
        return self.resolveWithTld(name, DEFAULT_TLD, current_block);
    }

    /// Resolve with explicit TLD.
    pub fn resolveWithTld(
        self: *const DnsRegistry,
        name: []const u8,
        tld: []const u8,
        current_block: u64,
    ) ?[]const u8 {
        for (self.entries[0..self.entry_count]) |*e| {
            if (!e.active or e.isExpired(current_block)) continue;
            if (!std.mem.eql(u8, e.getName(), name)) continue;
            if (!std.mem.eql(u8, e.getTld(), tld)) continue;
            return e.getAddress();
        }
        return null;
    }

    /// Reverse resolve: address to name (returns first match across TLDs).
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

    // ── Persistence ─────────────────────────────────────────────────────────

    /// Magic header for the persistence file format.
    /// Layout: 8B magic | 4B version | 4B entry_count | entries...
    /// entry: 1B name_len + 25B name | 1B tld_len + 16B tld |
    ///        1B addr_len + 64B addr | 1B owner_len + 64B owner |
    ///        8B reg_block | 8B exp_block | 1B active
    /// = 1+25+1+16+1+64+1+64+8+8+1 = 190 bytes per entry.
    const MAGIC: [8]u8 = [_]u8{ 'O', 'M', 'N', 'I', 'D', 'N', 'S', '1' };
    const VERSION: u32 = 1;
    const HEADER_SIZE: usize = 8 + 4 + 4;
    const ENTRY_SIZE: usize = 190;

    pub fn saveToFile(self: *const DnsRegistry, path: []const u8) !void {
        var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
        defer file.close();
        var buf: [HEADER_SIZE]u8 = undefined;
        @memcpy(buf[0..8], &MAGIC);
        std.mem.writeInt(u32, buf[8..12], VERSION, .little);
        std.mem.writeInt(u32, buf[12..16], @intCast(self.entry_count), .little);
        try file.writeAll(&buf);
        var rec: [ENTRY_SIZE]u8 = undefined;
        for (self.entries[0..self.entry_count]) |e| {
            @memset(&rec, 0);
            rec[0] = e.name_len;
            @memcpy(rec[1..26], &e.name);
            rec[26] = e.tld_len;
            @memcpy(rec[27..43], &e.tld);
            rec[43] = e.addr_len;
            @memcpy(rec[44..108], &e.address);
            rec[108] = e.owner_len;
            @memcpy(rec[109..173], &e.owner);
            std.mem.writeInt(u64, rec[173..181], e.registered_block, .little);
            std.mem.writeInt(u64, rec[181..189], e.expires_block, .little);
            rec[189] = if (e.active) 1 else 0;
            try file.writeAll(&rec);
        }
    }

    pub fn loadFromFile(self: *DnsRegistry, path: []const u8) !void {
        var file = std.fs.cwd().openFile(path, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                // First run — empty registry. Not an error.
                self.entry_count = 0;
                return;
            },
            else => return err,
        };
        defer file.close();
        var hdr: [HEADER_SIZE]u8 = undefined;
        const n = try file.readAll(&hdr);
        if (n < HEADER_SIZE) return error.CorruptFile;
        if (!std.mem.eql(u8, hdr[0..8], &MAGIC)) return error.BadMagic;
        const ver = std.mem.readInt(u32, hdr[8..12], .little);
        if (ver != VERSION) return error.UnsupportedVersion;
        const count = std.mem.readInt(u32, hdr[12..16], .little);
        if (count > MAX_ENTRIES) return error.TooManyEntries;
        self.entry_count = 0;
        var rec: [ENTRY_SIZE]u8 = undefined;
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            const r = try file.readAll(&rec);
            if (r < ENTRY_SIZE) return error.CorruptFile;
            var e: DnsEntry = std.mem.zeroes(DnsEntry);
            e.name_len = rec[0];
            @memcpy(&e.name, rec[1..26]);
            e.tld_len = rec[26];
            @memcpy(&e.tld, rec[27..43]);
            e.addr_len = rec[43];
            @memcpy(&e.address, rec[44..108]);
            e.owner_len = rec[108];
            @memcpy(&e.owner, rec[109..173]);
            e.registered_block = std.mem.readInt(u64, rec[173..181], .little);
            e.expires_block = std.mem.readInt(u64, rec[181..189], .little);
            e.active = rec[189] != 0;
            self.entries[self.entry_count] = e;
            self.entry_count += 1;
        }
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

test "DnsRegistry — same name, different TLDs coexist" {
    var reg = DnsRegistry.init();
    try reg.registerWithTld("alpha", "omnibus", "ob1qaaa", "ob1qaaa", 1000);
    try reg.registerWithTld("alpha", "arbitraje", "ob1qbbb", "ob1qbbb", 1000);
    try testing.expectEqualStrings("ob1qaaa", reg.resolveWithTld("alpha", "omnibus", 1001).?);
    try testing.expectEqualStrings("ob1qbbb", reg.resolveWithTld("alpha", "arbitraje", 1001).?);
}

test "DnsRegistry — invalid TLD rejected" {
    var reg = DnsRegistry.init();
    try testing.expectError(error.InvalidTld,
        reg.registerWithTld("alice", "eth", "ob1qaaa", "ob1qaaa", 1000));
}

test "DnsRegistry — fullLabel renders <name>.<tld>" {
    var reg = DnsRegistry.init();
    try reg.registerWithTld("kimi_alpha", "arbitraje", "ob1qaaa", "ob1qaaa", 1000);
    var buf: [64]u8 = undefined;
    const label = reg.entries[0].fullLabel(&buf);
    try testing.expectEqualStrings("kimi_alpha.arbitraje", label);
}

test "DnsRegistry — save and load round-trip" {
    var reg = DnsRegistry.init();
    try reg.registerWithTld("alice", "omnibus", "ob1qaaa", "ob1qaaa", 1000);
    try reg.registerWithTld("arb_bot", "arbitraje", "ob1qbbb", "ob1qbbb", 2000);

    const tmp_path = "test_dns_roundtrip.bin";
    defer std.fs.cwd().deleteFile(tmp_path) catch {};
    try reg.saveToFile(tmp_path);

    var reg2 = DnsRegistry.init();
    try reg2.loadFromFile(tmp_path);
    try testing.expectEqual(@as(usize, 2), reg2.entry_count);
    try testing.expectEqualStrings("ob1qaaa", reg2.resolveWithTld("alice", "omnibus", 1001).?);
    try testing.expectEqualStrings("ob1qbbb", reg2.resolveWithTld("arb_bot", "arbitraje", 2001).?);
}

test "DnsRegistry — load from missing file returns empty registry" {
    var reg = DnsRegistry.init();
    try reg.loadFromFile("definitely_does_not_exist_12345.bin");
    try testing.expectEqual(@as(usize, 0), reg.entry_count);
}
