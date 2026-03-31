/// vault_engine.zig — The Vault: surplus trading engine
///
/// Din Whitepaper:
///   Surplus dupa Level 100 → Vault → Lisp Machine trading AI pe 19 chain-uri
///   La dublare → returneaza investitia; profitul → UBI lunar pe viata (adresa Anchor)
///
/// VaultEngine gestioneaza:
///   - Depozite de surplus de la user-i cu Level 100+
///   - Tracking profit/loss per pozitie
///   - Trigger de dublare: cand NAV >= 2x deposit → returneaza capitalul
///   - Profitul ramas → UBI pool (ubi_distributor.zig)
///
/// Nota: executia efectiva a trade-urilor e in HFT-MultiExchange (Zig/TS).
/// vault_engine.zig gestioneaza doar contabilitatea si regulile.
const std = @import("std");
const spark = @import("spark_invariants.zig");

// --- CONSTANTE ---------------------------------------------------------------

/// Nivelul minim pentru acces la Vault
pub const VAULT_MIN_LEVEL: u8 = 100;

/// Factor de dublare: NAV >= deposit * DOUBLE_FACTOR → returneaza capitalul
pub const DOUBLE_FACTOR_PCT: u64 = 200;  // 200% = 2x

/// Fee Vault: 10% din profit merge la protocol (restul 90% → UBI)
pub const VAULT_PROTOCOL_FEE_PCT: u64 = 10;

// --- TIPURI ------------------------------------------------------------------

pub const VaultPositionStatus = enum(u8) {
    active    = 0,
    doubled   = 1,   // Capitalul returnat, profitul in UBI pool
    withdrawn = 2,   // User a retras manual
    liquidated = 3,  // Pozitie lichidata (loss total)
};

/// O pozitie in Vault (un depozit de la un user)
pub const VaultPosition = struct {
    position_id:   u64,
    owner:         [32]u8,    // adresa owner-ului (ob_omni_ domain hash)
    anchor_addr:   [32]u8,    // adresa Anchor pentru UBI
    deposit_sat:   u64,       // cat a depozitat initial
    current_nav_sat: u64,     // Net Asset Value curent
    status:        VaultPositionStatus,
    opened_block:  u64,
    closed_block:  u64,

    /// Profitul curent (0 daca nav < deposit)
    pub fn profitSat(self: *const VaultPosition) u64 {
        if (self.current_nav_sat <= self.deposit_sat) return 0;
        return self.current_nav_sat - self.deposit_sat;
    }

    /// A atins dublarea?
    pub fn hasDoubled(self: *const VaultPosition) bool {
        return self.current_nav_sat * 100 >= self.deposit_sat * DOUBLE_FACTOR_PCT;
    }

    /// Return on Investment in procente (scaled x100)
    pub fn roiPct(self: *const VaultPosition) i64 {
        if (self.deposit_sat == 0) return 0;
        const nav = @as(i64, @intCast(self.current_nav_sat));
        const dep = @as(i64, @intCast(self.deposit_sat));
        return (nav - dep) * 100 / dep;
    }
};

// --- VAULT ENGINE ------------------------------------------------------------

pub const VaultEngine = struct {
    allocator:       std.mem.Allocator,
    positions:       std.array_list.Managed(VaultPosition),
    next_pos_id:     u64,

    /// Total depozitat in Vault
    total_deposits_sat: u64,

    /// Total returnat la user-i (capital la dublare)
    total_returned_sat: u64,

    /// Total profit trimis la UBI pool
    total_ubi_sat: u64,

    /// Total fee protocol
    total_fee_sat: u64,

    pub fn init(allocator: std.mem.Allocator) VaultEngine {
        return VaultEngine{
            .allocator          = allocator,
            .positions          = std.array_list.Managed(VaultPosition).init(allocator),
            .next_pos_id        = 1,
            .total_deposits_sat = 0,
            .total_returned_sat = 0,
            .total_ubi_sat      = 0,
            .total_fee_sat      = 0,
        };
    }

    pub fn deinit(self: *VaultEngine) void {
        self.positions.deinit();
    }

    /// Depozit surplus in Vault (doar level >= 100)
    pub fn deposit(self: *VaultEngine,
                   owner:       [32]u8,
                   anchor_addr: [32]u8,
                   amount_sat:  u64,
                   user_level:  u8,
                   current_block: u64) !u64 {
        if (user_level < VAULT_MIN_LEVEL) return error.LevelTooLow;
        if (amount_sat == 0) return error.ZeroDeposit;

        const pos = VaultPosition{
            .position_id    = self.next_pos_id,
            .owner          = owner,
            .anchor_addr    = anchor_addr,
            .deposit_sat    = amount_sat,
            .current_nav_sat = amount_sat,
            .status         = .active,
            .opened_block   = current_block,
            .closed_block   = 0,
        };

        try self.positions.append(pos);
        self.next_pos_id += 1;
        self.total_deposits_sat +|= amount_sat;

        std.debug.print("[VAULT] Deposit #{d}: {d} SAT | block={d}\n",
            .{ pos.position_id, amount_sat, current_block });

        return pos.position_id;
    }

    /// Actualizeaza NAV-ul unei pozitii (dupa executia trade-urilor HFT)
    pub fn updateNav(self: *VaultEngine,
                     position_id: u64,
                     new_nav_sat: u64) !void {
        const pos = try self.findPosition(position_id);
        if (pos.status != .active) return error.PositionNotActive;
        pos.current_nav_sat = new_nav_sat;
    }

    /// Verifica si proceseaza dublarea (daca NAV >= 2x deposit)
    /// Returneaza: (capital_returnat_sat, profit_ubi_sat)
    pub fn checkAndProcessDoubling(self: *VaultEngine,
                                    position_id: u64,
                                    current_block: u64) !struct { returned: u64, ubi: u64 } {
        const pos = try self.findPosition(position_id);
        if (pos.status != .active) return error.PositionNotActive;
        if (!pos.hasDoubled()) return error.NotDoubledYet;

        const profit = pos.profitSat();
        const fee    = profit * VAULT_PROTOCOL_FEE_PCT / 100;
        const ubi    = profit - fee;

        // Returnam capitalul initial
        const returned = pos.deposit_sat;

        pos.status       = .doubled;
        pos.closed_block = current_block;

        self.total_returned_sat +|= returned;
        self.total_ubi_sat      +|= ubi;
        self.total_fee_sat      +|= fee;

        std.debug.print("[VAULT] Position #{d} DOUBLED! return={d} ubi={d} fee={d}\n",
            .{ position_id, returned, ubi, fee });

        return .{ .returned = returned, .ubi = ubi };
    }

    /// Retragere manuala (inainte de dublare)
    pub fn withdraw(self: *VaultEngine,
                    position_id: u64,
                    current_block: u64) !u64 {
        const pos = try self.findPosition(position_id);
        if (pos.status != .active) return error.PositionNotActive;

        const nav = pos.current_nav_sat;
        pos.status       = .withdrawn;
        pos.closed_block = current_block;

        std.debug.print("[VAULT] Position #{d} withdrawn: {d} SAT\n",
            .{ position_id, nav });

        return nav;
    }

    pub fn findPosition(self: *VaultEngine, position_id: u64) !*VaultPosition {
        for (self.positions.items) |*p| {
            if (p.position_id == position_id) return p;
        }
        return error.PositionNotFound;
    }

    pub fn activeCount(self: *const VaultEngine) usize {
        var n: usize = 0;
        for (self.positions.items) |p| {
            if (p.status == .active) n += 1;
        }
        return n;
    }

    pub fn printStatus(self: *const VaultEngine) void {
        std.debug.print("[VAULT] Positions: {d} active | deposits={d} returned={d} ubi={d}\n",
            .{ self.activeCount(), self.total_deposits_sat,
               self.total_returned_sat, self.total_ubi_sat });
    }
};

// --- TESTE -------------------------------------------------------------------
const testing = std.testing;

const OWNER: [32]u8 = @splat(0xAA);
const ANCHOR: [32]u8 = @splat(0xBB);

test "VaultPosition — profitSat zero cand nav = deposit" {
    const p = VaultPosition{
        .position_id = 1, .owner = OWNER, .anchor_addr = ANCHOR,
        .deposit_sat = 1_000_000, .current_nav_sat = 1_000_000,
        .status = .active, .opened_block = 0, .closed_block = 0,
    };
    try testing.expectEqual(@as(u64, 0), p.profitSat());
}

test "VaultPosition — profitSat calculat corect" {
    const p = VaultPosition{
        .position_id = 1, .owner = OWNER, .anchor_addr = ANCHOR,
        .deposit_sat = 1_000_000, .current_nav_sat = 1_500_000,
        .status = .active, .opened_block = 0, .closed_block = 0,
    };
    try testing.expectEqual(@as(u64, 500_000), p.profitSat());
}

test "VaultPosition — hasDoubled false la 150%" {
    const p = VaultPosition{
        .position_id = 1, .owner = OWNER, .anchor_addr = ANCHOR,
        .deposit_sat = 1_000_000, .current_nav_sat = 1_500_000,
        .status = .active, .opened_block = 0, .closed_block = 0,
    };
    try testing.expect(!p.hasDoubled());
}

test "VaultPosition — hasDoubled true la 200%" {
    const p = VaultPosition{
        .position_id = 1, .owner = OWNER, .anchor_addr = ANCHOR,
        .deposit_sat = 1_000_000, .current_nav_sat = 2_000_000,
        .status = .active, .opened_block = 0, .closed_block = 0,
    };
    try testing.expect(p.hasDoubled());
}

test "VaultEngine — deposit nivel prea mic returneaza eroare" {
    var ve = VaultEngine.init(testing.allocator);
    defer ve.deinit();
    try testing.expectError(error.LevelTooLow,
        ve.deposit(OWNER, ANCHOR, 1_000_000, 50, 100));
}

test "VaultEngine — deposit nivel 100 ok" {
    var ve = VaultEngine.init(testing.allocator);
    defer ve.deinit();
    const id = try ve.deposit(OWNER, ANCHOR, 5_000_000_000, 100, 1000);
    try testing.expectEqual(@as(u64, 1), id);
    try testing.expectEqual(@as(usize, 1), ve.activeCount());
}

test "VaultEngine — updateNav schimba nav" {
    var ve = VaultEngine.init(testing.allocator);
    defer ve.deinit();
    const id = try ve.deposit(OWNER, ANCHOR, 1_000_000_000, 100, 1000);
    try ve.updateNav(id, 1_500_000_000);
    const pos = try ve.findPosition(id);
    try testing.expectEqual(@as(u64, 1_500_000_000), pos.current_nav_sat);
}

test "VaultEngine — checkAndProcessDoubling la 2x" {
    var ve = VaultEngine.init(testing.allocator);
    defer ve.deinit();
    const id = try ve.deposit(OWNER, ANCHOR, 1_000_000_000, 100, 1000);
    try ve.updateNav(id, 2_000_000_000);  // 2x
    const result = try ve.checkAndProcessDoubling(id, 2000);
    try testing.expectEqual(@as(u64, 1_000_000_000), result.returned);
    // profit = 1B, fee = 10% = 100M, ubi = 900M
    try testing.expectEqual(@as(u64, 900_000_000), result.ubi);
}

test "VaultEngine — checkAndProcessDoubling inainte de 2x returneaza eroare" {
    var ve = VaultEngine.init(testing.allocator);
    defer ve.deinit();
    const id = try ve.deposit(OWNER, ANCHOR, 1_000_000_000, 100, 1000);
    try ve.updateNav(id, 1_800_000_000);  // 180%, nu ajunge la 200%
    try testing.expectError(error.NotDoubledYet,
        ve.checkAndProcessDoubling(id, 1500));
}

test "VaultEngine — withdraw returneaza nav curent" {
    var ve = VaultEngine.init(testing.allocator);
    defer ve.deinit();
    const id = try ve.deposit(OWNER, ANCHOR, 1_000_000_000, 100, 1000);
    try ve.updateNav(id, 1_200_000_000);
    const nav = try ve.withdraw(id, 1500);
    try testing.expectEqual(@as(u64, 1_200_000_000), nav);
}

test "VaultEngine — pozitie inchisa nu poate fi updatata" {
    var ve = VaultEngine.init(testing.allocator);
    defer ve.deinit();
    const id = try ve.deposit(OWNER, ANCHOR, 1_000_000_000, 100, 1000);
    _ = try ve.withdraw(id, 1500);
    try testing.expectError(error.PositionNotActive, ve.updateNav(id, 999));
}
