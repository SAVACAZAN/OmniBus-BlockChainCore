/// domain_minter.zig — SoulBound Domain Minter
///
/// Cele 5 domenii PQ ale OmniBus (din Whitepaper):
///   ob_omni_ — ML-KEM-768 (identity layer, non-transferabil)
///   ob_k1_   — Dilithium-5 (signing, transferabil cu conditii)
///   ob_f5_   — Falcon-512  (high-frequency, transferabil)
///   ob_d5_   — SLH-DSA     (archival, non-transferabil)
///   ob_s3_   — Falcon-Light (satellite / IoT, transferabil)
///
/// SoulBound = adresa legata de identitate, NU poate fi transferata
/// (ca SBT - Soulbound Tokens din Ethereum EIP-4973)
///
/// Mintarea unui domeniu costa OMNI SAT si e permanenta.
/// Fiecare domeniu are un nivel (1-100) care creste prin activitate.
const std = @import("std");
const spark = @import("spark_invariants.zig");

// --- TIPURI ------------------------------------------------------------------

pub const DomainType = enum(u8) {
    omni = 0,  // ob_omni_ — ML-KEM-768 — identity, non-transferabil
    k1   = 1,  // ob_k1_   — Dilithium-5
    f5   = 2,  // ob_f5_   — Falcon-512
    d5   = 3,  // ob_d5_   — SLH-DSA — archival, non-transferabil
    s3   = 4,  // ob_s3_   — Falcon-Light

    pub fn prefix(self: DomainType) []const u8 {
        return switch (self) {
            .omni => "ob_omni_",
            .k1   => "ob_k1_",
            .f5   => "ob_f5_",
            .d5   => "ob_d5_",
            .s3   => "ob_s3_",
        };
    }

    pub fn algorithm(self: DomainType) []const u8 {
        return switch (self) {
            .omni => "ML-KEM-768",
            .k1   => "Dilithium-5",
            .f5   => "Falcon-512",
            .d5   => "SLH-DSA",
            .s3   => "Falcon-Light",
        };
    }

    /// Domeniile non-transferabile (SoulBound strict)
    pub fn isSoulBound(self: DomainType) bool {
        return switch (self) {
            .omni, .d5 => true,
            else       => false,
        };
    }

    /// Costul de mintare in SAT OMNI
    pub fn mintCostSat(self: DomainType) u64 {
        return switch (self) {
            .omni => 1_000_000_000,    // 1 OMNI
            .k1   =>   500_000_000,    // 0.5 OMNI
            .f5   =>   250_000_000,    // 0.25 OMNI
            .d5   => 2_000_000_000,    // 2 OMNI (archival = premium)
            .s3   =>   100_000_000,    // 0.1 OMNI
        };
    }
};

pub const MAX_NAME_LEN: usize = 32;
pub const MAX_LEVEL: u8 = 100;

/// Un domeniu mintat pe chain
pub const Domain = struct {
    /// Numele complet, ex: "ob_omni_alice000"
    name:        [MAX_NAME_LEN]u8,
    name_len:    u8,

    domain_type: DomainType,

    /// Adresa owner-ului (hash 32 bytes)
    owner:       [32]u8,

    /// Nivelul domeniului (1-100), creste prin activitate
    level:       u8,

    /// Block-ul la care a fost mintat
    minted_block: u64,

    /// Activ sau revoked
    active:      bool,

    /// Cheia publica PQ asociata domeniului (compressed, max 64 bytes)
    pub_key:     [64]u8,
    pub_key_len: u8,

    pub fn fullName(self: *const Domain) []const u8 {
        return self.name[0..self.name_len];
    }

    pub fn levelUp(self: *Domain) void {
        if (self.level < MAX_LEVEL) self.level += 1;
    }
};

// --- DOMAIN REGISTRY ---------------------------------------------------------

pub const MAX_DOMAINS: usize = 65_536;  // 64K domenii per nod (index local)

pub const DomainRegistry = struct {
    allocator:    std.mem.Allocator,
    domains:      std.array_list.Managed(Domain),
    /// Total SAT colectat din mintare (merge la SupplyGuard)
    collected_sat: u64,

    pub fn init(allocator: std.mem.Allocator) DomainRegistry {
        return DomainRegistry{
            .allocator    = allocator,
            .domains      = std.array_list.Managed(Domain).init(allocator),
            .collected_sat = 0,
        };
    }

    pub fn deinit(self: *DomainRegistry) void {
        self.domains.deinit();
    }

    /// Minteaza un nou domeniu
    /// Returneaza index-ul domeniului in registry
    pub fn mint(self: *DomainRegistry,
                domain_type: DomainType,
                username:    []const u8,   // fara prefix, ex: "alice000"
                owner:       [32]u8,
                pub_key:     []const u8,
                current_block: u64,
                supply_guard: *spark.SupplyGuard) !usize {

        // Verifica lungimea username-ului
        const prefix = domain_type.prefix();
        const full_len = prefix.len + username.len;
        if (full_len > MAX_NAME_LEN) return error.NameTooLong;
        if (username.len == 0) return error.EmptyUsername;

        // Verifica ca nu exista deja
        if (try self.findByName(domain_type, username) != null)
            return error.DomainAlreadyExists;

        // Verifica cost (supply guard)
        const cost = domain_type.mintCostSat();
        try supply_guard.emit(cost);
        self.collected_sat +|= cost;

        // Construieste numele complet
        var name: [MAX_NAME_LEN]u8 = @splat(0);
        @memcpy(name[0..prefix.len], prefix);
        @memcpy(name[prefix.len..full_len], username);

        // Cheia publica
        var pk: [64]u8 = @splat(0);
        const pk_len = @min(pub_key.len, 64);
        @memcpy(pk[0..pk_len], pub_key[0..pk_len]);

        const domain = Domain{
            .name         = name,
            .name_len     = @intCast(full_len),
            .domain_type  = domain_type,
            .owner        = owner,
            .level        = 1,
            .minted_block = current_block,
            .active       = true,
            .pub_key      = pk,
            .pub_key_len  = @intCast(pk_len),
        };

        const idx = self.domains.items.len;
        try self.domains.append(domain);

        std.debug.print("[DOMAIN] Minted: {s} | {s} | level=1 | block={d}\n",
            .{ domain.fullName(), domain_type.algorithm(), current_block });

        return idx;
    }

    /// Cauta un domeniu dupa tip + username
    pub fn findByName(self: *const DomainRegistry,
                       domain_type: DomainType,
                       username:    []const u8) !?*const Domain {
        const prefix = domain_type.prefix();
        const full_len = prefix.len + username.len;
        if (full_len > MAX_NAME_LEN) return null;

        var target: [MAX_NAME_LEN]u8 = @splat(0);
        @memcpy(target[0..prefix.len], prefix);
        @memcpy(target[prefix.len..full_len], username);

        for (self.domains.items) |*d| {
            if (d.active and d.name_len == full_len and
                std.mem.eql(u8, d.name[0..full_len], target[0..full_len]))
            {
                return d;
            }
        }
        return null;
    }

    /// Cauta dupa owner — returneaza toate domeniile unui owner
    pub fn findByOwner(self: *const DomainRegistry,
                        owner: [32]u8,
                        out:   []Domain) u8 {
        var n: u8 = 0;
        for (self.domains.items) |d| {
            if (d.active and std.mem.eql(u8, &d.owner, &owner)) {
                if (n < out.len) {
                    out[n] = d;
                    n += 1;
                }
            }
        }
        return n;
    }

    /// Transfera un domeniu (doar pentru tipurile non-SoulBound)
    pub fn transfer(self: *DomainRegistry,
                     domain_type: DomainType,
                     username:    []const u8,
                     new_owner:   [32]u8) !void {
        if (domain_type.isSoulBound()) return error.SoulBoundCannotTransfer;

        for (self.domains.items) |*d| {
            const prefix = domain_type.prefix();
            const full_len = prefix.len + username.len;
            if (d.active and d.name_len == full_len) {
                var target: [MAX_NAME_LEN]u8 = @splat(0);
                @memcpy(target[0..prefix.len], prefix);
                @memcpy(target[prefix.len..full_len], username);
                if (std.mem.eql(u8, d.name[0..full_len], target[0..full_len])) {
                    d.owner = new_owner;
                    return;
                }
            }
        }
        return error.DomainNotFound;
    }

    /// Level-up un domeniu (prin activitate on-chain)
    pub fn levelUp(self: *DomainRegistry,
                    domain_type: DomainType,
                    username:    []const u8) !void {
        const prefix = domain_type.prefix();
        const full_len = prefix.len + username.len;
        if (full_len > MAX_NAME_LEN) return error.NameTooLong;

        var target: [MAX_NAME_LEN]u8 = @splat(0);
        @memcpy(target[0..prefix.len], prefix);
        @memcpy(target[prefix.len..full_len], username);

        for (self.domains.items) |*d| {
            if (d.active and d.name_len == full_len and
                std.mem.eql(u8, d.name[0..full_len], target[0..full_len]))
            {
                d.levelUp();
                return;
            }
        }
        return error.DomainNotFound;
    }

    pub fn count(self: *const DomainRegistry) usize {
        var n: usize = 0;
        for (self.domains.items) |d| {
            if (d.active) n += 1;
        }
        return n;
    }

    pub fn printStatus(self: *const DomainRegistry) void {
        std.debug.print("[DOMAINS] Total: {d} | Collected: {d} SAT\n",
            .{ self.count(), self.collected_sat });
    }
};

// --- TESTE -------------------------------------------------------------------
const testing = std.testing;

test "DomainType — prefix si algorithm corecte" {
    try testing.expectEqualStrings("ob_omni_",    DomainType.omni.prefix());
    try testing.expectEqualStrings("ob_k1_",      DomainType.k1.prefix());
    try testing.expectEqualStrings("ML-KEM-768",  DomainType.omni.algorithm());
    try testing.expectEqualStrings("Dilithium-5", DomainType.k1.algorithm());
}

test "DomainType — isSoulBound corecte" {
    try testing.expect(DomainType.omni.isSoulBound());
    try testing.expect(DomainType.d5.isSoulBound());
    try testing.expect(!DomainType.k1.isSoulBound());
    try testing.expect(!DomainType.f5.isSoulBound());
    try testing.expect(!DomainType.s3.isSoulBound());
}

test "DomainType — mintCostSat pozitiv" {
    try testing.expect(DomainType.omni.mintCostSat() > 0);
    try testing.expect(DomainType.d5.mintCostSat() > DomainType.k1.mintCostSat());
}

test "DomainRegistry — mint domeniu nou" {
    var sg = spark.SupplyGuard.init();
    var reg = DomainRegistry.init(testing.allocator);
    defer reg.deinit();

    const owner: [32]u8 = @splat(0xAA);
    const pk = [_]u8{0x01} ** 32;

    const idx = try reg.mint(.omni, "alice000", owner, &pk, 1000, &sg);
    try testing.expectEqual(@as(usize, 0), idx);
    try testing.expectEqual(@as(usize, 1), reg.count());
}

test "DomainRegistry — mint adauga costul la supply guard" {
    var sg = spark.SupplyGuard.init();
    var reg = DomainRegistry.init(testing.allocator);
    defer reg.deinit();

    const owner: [32]u8 = @splat(0xAA);
    const pk = [_]u8{0x01} ** 32;

    _ = try reg.mint(.omni, "alice000", owner, &pk, 1000, &sg);
    try testing.expectEqual(DomainType.omni.mintCostSat(), sg.emitted_sat);
    try testing.expectEqual(DomainType.omni.mintCostSat(), reg.collected_sat);
}

test "DomainRegistry — findByName gaseste domeniu" {
    var sg = spark.SupplyGuard.init();
    var reg = DomainRegistry.init(testing.allocator);
    defer reg.deinit();

    const owner: [32]u8 = @splat(0xBB);
    const pk = [_]u8{0x02} ** 32;
    _ = try reg.mint(.k1, "bob00000", owner, &pk, 500, &sg);

    const found = try reg.findByName(.k1, "bob00000");
    try testing.expect(found != null);
    try testing.expectEqualStrings("ob_k1_bob00000", found.?.fullName());
}

test "DomainRegistry — findByName returneaza null pt inexistent" {
    var reg = DomainRegistry.init(testing.allocator);
    defer reg.deinit();
    const found = try reg.findByName(.f5, "nobody00");
    try testing.expect(found == null);
}

test "DomainRegistry — duplicate returneaza eroare" {
    var sg = spark.SupplyGuard.init();
    var reg = DomainRegistry.init(testing.allocator);
    defer reg.deinit();

    const owner: [32]u8 = @splat(0xCC);
    const pk = [_]u8{0x03} ** 32;
    _ = try reg.mint(.s3, "carol000", owner, &pk, 100, &sg);
    try testing.expectError(error.DomainAlreadyExists,
        reg.mint(.s3, "carol000", owner, &pk, 101, &sg));
}

test "DomainRegistry — transfer domeniu non-soulbound" {
    var sg = spark.SupplyGuard.init();
    var reg = DomainRegistry.init(testing.allocator);
    defer reg.deinit();

    const owner1: [32]u8 = @splat(0x11);
    const owner2: [32]u8 = @splat(0x22);
    const pk = [_]u8{0x04} ** 32;
    _ = try reg.mint(.k1, "dave0000", owner1, &pk, 200, &sg);

    try reg.transfer(.k1, "dave0000", owner2);
    const found = try reg.findByName(.k1, "dave0000");
    try testing.expect(std.mem.eql(u8, &found.?.owner, &owner2));
}

test "DomainRegistry — transfer soulbound returneaza eroare" {
    var sg = spark.SupplyGuard.init();
    var reg = DomainRegistry.init(testing.allocator);
    defer reg.deinit();

    const owner: [32]u8 = @splat(0x55);
    const pk = [_]u8{0x05} ** 32;
    _ = try reg.mint(.omni, "eve00000", owner, &pk, 300, &sg);

    try testing.expectError(error.SoulBoundCannotTransfer,
        reg.transfer(.omni, "eve00000", @splat(0x66)));
}

test "DomainRegistry — levelUp creste nivelul" {
    var sg = spark.SupplyGuard.init();
    var reg = DomainRegistry.init(testing.allocator);
    defer reg.deinit();

    const owner: [32]u8 = @splat(0x77);
    const pk = [_]u8{0x06} ** 32;
    _ = try reg.mint(.f5, "frank000", owner, &pk, 400, &sg);

    try reg.levelUp(.f5, "frank000");
    try reg.levelUp(.f5, "frank000");

    const found = try reg.findByName(.f5, "frank000");
    try testing.expectEqual(@as(u8, 3), found.?.level);
}

test "DomainRegistry — findByOwner gaseste toate domeniile" {
    var sg = spark.SupplyGuard.init();
    var reg = DomainRegistry.init(testing.allocator);
    defer reg.deinit();

    const owner: [32]u8 = @splat(0x88);
    const pk = [_]u8{0x07} ** 32;
    _ = try reg.mint(.omni, "grace000", owner, &pk, 500, &sg);
    _ = try reg.mint(.k1,   "grace000", owner, &pk, 500, &sg);

    var out: [10]Domain = undefined;
    const n = reg.findByOwner(owner, &out);
    try testing.expectEqual(@as(u8, 2), n);
}
