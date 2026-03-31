/// ubi_distributor.zig — UBI Lunar pe Viata
///
/// Din Whitepaper:
///   Profitul din Vault (dupa dublare) → UBI pool
///   UBI = distribuit lunar (1 OMNI/zi per user in Ciclul 1)
///   Adresa Anchor = adresa de pe ob_omni_ domain care primeste UBI
///
/// Model:
///   - UBI pool acumuleaza profit din VaultEngine
///   - La fiecare epoch (126144 blocuri ≈ 1.46 zile), pool-ul e distribuit
///   - Fiecare beneficiar inregistrat primeste cota sa
///   - "Pe viata" = adresa Anchor e SoulBound (ob_omni_), nu poate fi schimbata
///
/// Ciclul 1: 1 paine/zi per user (= 1 OMNI/zi = 83333333 SAT/zi ≈ reward/bloc)
/// Ciclul 2: activat cand 1 miliard oameni au Ciclul 1
const std = @import("std");
const spark = @import("spark_invariants.zig");

// --- CONSTANTE ---------------------------------------------------------------

/// Epoch UBI: la cate blocuri se face distributia
/// 126144 blocuri ≈ 1.46 zile la 1 bloc/s
pub const UBI_EPOCH_BLOCKS: u64 = 126_144;

/// UBI zilnic per beneficiar in Ciclul 1 (in SAT)
/// 1 OMNI/zi = 1_000_000_000 SAT/zi
pub const UBI_DAILY_SAT: u64 = 1_000_000_000;

/// UBI per epoch (proportional cu epoch length)
/// UBI_DAILY_SAT * UBI_EPOCH_BLOCKS / 86400 (secunde/zi)
pub const UBI_PER_EPOCH_SAT: u64 = UBI_DAILY_SAT * UBI_EPOCH_BLOCKS / 86_400;

pub const MAX_BENEFICIARIES: usize = 1_000_000_000;  // 1 miliard (Ciclul 2)

// --- TIPURI ------------------------------------------------------------------

pub const UbiBeneficiary = struct {
    anchor_addr:     [32]u8,   // adresa Anchor (ob_omni_ SoulBound)
    registered_block: u64,
    total_received_sat: u64,
    last_epoch:      u64,      // ultimul epoch la care a primit UBI
    active:          bool,
};

pub const UbiEpochReport = struct {
    epoch_number:    u64,
    block_start:     u64,
    block_end:       u64,
    pool_sat:        u64,       // cat era in pool
    distributed_sat: u64,       // cat s-a distribuit
    beneficiary_count: u64,
    per_beneficiary_sat: u64,
};

// --- UBI DISTRIBUTOR ---------------------------------------------------------

pub const UbiDistributor = struct {
    allocator:     std.mem.Allocator,
    beneficiaries: std.array_list.Managed(UbiBeneficiary),

    /// Pool acumulat din Vault (profit dupa dublare)
    pool_sat:      u64,

    /// Epoch curent
    current_epoch: u64,

    /// Total distribuit de-a lungul tuturor epoch-urilor
    total_distributed_sat: u64,

    /// Rapoarte per epoch
    epoch_reports: std.array_list.Managed(UbiEpochReport),

    pub fn init(allocator: std.mem.Allocator) UbiDistributor {
        return UbiDistributor{
            .allocator            = allocator,
            .beneficiaries        = std.array_list.Managed(UbiBeneficiary).init(allocator),
            .pool_sat             = 0,
            .current_epoch        = 0,
            .total_distributed_sat = 0,
            .epoch_reports        = std.array_list.Managed(UbiEpochReport).init(allocator),
        };
    }

    pub fn deinit(self: *UbiDistributor) void {
        self.beneficiaries.deinit();
        self.epoch_reports.deinit();
    }

    /// Inregistreaza un beneficiar nou (adresa Anchor SoulBound)
    pub fn registerBeneficiary(self: *UbiDistributor,
                                anchor_addr: [32]u8,
                                current_block: u64) !void {
        // Verifica duplicat
        for (self.beneficiaries.items) |b| {
            if (std.mem.eql(u8, &b.anchor_addr, &anchor_addr))
                return error.AlreadyRegistered;
        }

        try self.beneficiaries.append(UbiBeneficiary{
            .anchor_addr      = anchor_addr,
            .registered_block = current_block,
            .total_received_sat = 0,
            .last_epoch       = self.current_epoch,
            .active           = true,
        });

        std.debug.print("[UBI] Beneficiar inregistrat | total: {d}\n",
            .{ self.beneficiaries.items.len });
    }

    /// Adauga profit din VaultEngine in pool
    pub fn addToPool(self: *UbiDistributor, amount_sat: u64) void {
        self.pool_sat +|= amount_sat;
        std.debug.print("[UBI] Pool += {d} SAT | total pool: {d}\n",
            .{ amount_sat, self.pool_sat });
    }

    /// Executa distributia epoch-ului curent
    /// Apelata la fiecare UBI_EPOCH_BLOCKS blocuri
    pub fn distributeEpoch(self: *UbiDistributor,
                            current_block: u64) !UbiEpochReport {
        const active_count = self.activeCount();
        if (active_count == 0) return error.NoBeneficiaries;

        // Cat primeste fiecare: min(pool/count, UBI_PER_EPOCH_SAT)
        const per_beneficiary = @min(
            self.pool_sat / active_count,
            UBI_PER_EPOCH_SAT,
        );

        if (per_beneficiary == 0) return error.PoolEmpty;

        const total_to_distribute = per_beneficiary * active_count;

        // Distribuie la fiecare beneficiar activ
        for (self.beneficiaries.items) |*b| {
            if (!b.active) continue;
            b.total_received_sat +|= per_beneficiary;
            b.last_epoch = self.current_epoch + 1;
        }

        if (self.pool_sat >= total_to_distribute) {
            self.pool_sat -= total_to_distribute;
        } else {
            self.pool_sat = 0;
        }
        self.total_distributed_sat +|= total_to_distribute;

        const report = UbiEpochReport{
            .epoch_number       = self.current_epoch + 1,
            .block_start        = current_block - UBI_EPOCH_BLOCKS,
            .block_end          = current_block,
            .pool_sat           = self.pool_sat + total_to_distribute,
            .distributed_sat    = total_to_distribute,
            .beneficiary_count  = active_count,
            .per_beneficiary_sat = per_beneficiary,
        };

        try self.epoch_reports.append(report);
        self.current_epoch += 1;

        std.debug.print("[UBI] Epoch #{d} | {d} beneficiari | {d} SAT/fiecare | pool ramas: {d}\n",
            .{ report.epoch_number, active_count, per_beneficiary, self.pool_sat });

        return report;
    }

    pub fn activeCount(self: *const UbiDistributor) u64 {
        var n: u64 = 0;
        for (self.beneficiaries.items) |b| {
            if (b.active) n += 1;
        }
        return n;
    }

    pub fn getBeneficiary(self: *const UbiDistributor,
                           anchor_addr: [32]u8) ?*const UbiBeneficiary {
        for (self.beneficiaries.items) |*b| {
            if (std.mem.eql(u8, &b.anchor_addr, &anchor_addr)) return b;
        }
        return null;
    }

    pub fn printStatus(self: *const UbiDistributor) void {
        std.debug.print("[UBI] Beneficiari: {d} | Pool: {d} SAT | Distribuit total: {d} SAT\n",
            .{ self.activeCount(), self.pool_sat, self.total_distributed_sat });
    }
};

// --- TESTE -------------------------------------------------------------------
const testing = std.testing;

test "UBI — constante corecte" {
    try testing.expect(UBI_PER_EPOCH_SAT > 0);
    try testing.expect(UBI_EPOCH_BLOCKS == 126_144);
}

test "UbiDistributor — registerBeneficiary" {
    var ubi = UbiDistributor.init(testing.allocator);
    defer ubi.deinit();

    const addr: [32]u8 = @splat(0x01);
    try ubi.registerBeneficiary(addr, 0);
    try testing.expectEqual(@as(u64, 1), ubi.activeCount());
}

test "UbiDistributor — duplicate returneaza eroare" {
    var ubi = UbiDistributor.init(testing.allocator);
    defer ubi.deinit();

    const addr: [32]u8 = @splat(0x02);
    try ubi.registerBeneficiary(addr, 0);
    try testing.expectError(error.AlreadyRegistered,
        ubi.registerBeneficiary(addr, 1));
}

test "UbiDistributor — addToPool creste pool" {
    var ubi = UbiDistributor.init(testing.allocator);
    defer ubi.deinit();

    ubi.addToPool(500_000_000);
    try testing.expectEqual(@as(u64, 500_000_000), ubi.pool_sat);
    ubi.addToPool(300_000_000);
    try testing.expectEqual(@as(u64, 800_000_000), ubi.pool_sat);
}

test "UbiDistributor — distributeEpoch fara beneficiari" {
    var ubi = UbiDistributor.init(testing.allocator);
    defer ubi.deinit();

    ubi.addToPool(1_000_000_000);
    try testing.expectError(error.NoBeneficiaries,
        ubi.distributeEpoch(UBI_EPOCH_BLOCKS));
}

test "UbiDistributor — distributeEpoch cu 1 beneficiar" {
    var ubi = UbiDistributor.init(testing.allocator);
    defer ubi.deinit();

    const addr: [32]u8 = @splat(0x03);
    try ubi.registerBeneficiary(addr, 0);
    ubi.addToPool(5_000_000_000);

    const report = try ubi.distributeEpoch(UBI_EPOCH_BLOCKS);
    try testing.expectEqual(@as(u64, 1), report.epoch_number);
    try testing.expectEqual(@as(u64, 1), report.beneficiary_count);
    try testing.expect(report.per_beneficiary_sat > 0);
    try testing.expect(report.distributed_sat > 0);
}

test "UbiDistributor — beneficiar primeste UBI" {
    var ubi = UbiDistributor.init(testing.allocator);
    defer ubi.deinit();

    const addr: [32]u8 = @splat(0x04);
    try ubi.registerBeneficiary(addr, 0);
    ubi.addToPool(10_000_000_000);

    _ = try ubi.distributeEpoch(UBI_EPOCH_BLOCKS);

    const b = ubi.getBeneficiary(addr);
    try testing.expect(b != null);
    try testing.expect(b.?.total_received_sat > 0);
}

test "UbiDistributor — distribuire egala intre 3 beneficiari" {
    var ubi = UbiDistributor.init(testing.allocator);
    defer ubi.deinit();

    try ubi.registerBeneficiary([_]u8{0x01} ** 32, 0);
    try ubi.registerBeneficiary([_]u8{0x02} ** 32, 0);
    try ubi.registerBeneficiary([_]u8{0x03} ** 32, 0);
    ubi.addToPool(30_000_000_000);

    const report = try ubi.distributeEpoch(UBI_EPOCH_BLOCKS);
    try testing.expectEqual(@as(u64, 3), report.beneficiary_count);

    // Toti 3 trebuie sa fi primit aceeasi suma
    const b1 = ubi.getBeneficiary([_]u8{0x01} ** 32);
    const b2 = ubi.getBeneficiary([_]u8{0x02} ** 32);
    const b3 = ubi.getBeneficiary([_]u8{0x03} ** 32);
    try testing.expectEqual(b1.?.total_received_sat, b2.?.total_received_sat);
    try testing.expectEqual(b2.?.total_received_sat, b3.?.total_received_sat);
}

test "UbiDistributor — pool scade dupa distributie" {
    var ubi = UbiDistributor.init(testing.allocator);
    defer ubi.deinit();

    const addr: [32]u8 = @splat(0x05);
    try ubi.registerBeneficiary(addr, 0);
    ubi.addToPool(5_000_000_000);
    const pool_before = ubi.pool_sat;

    _ = try ubi.distributeEpoch(UBI_EPOCH_BLOCKS);
    try testing.expect(ubi.pool_sat < pool_before);
}

test "UbiDistributor — epoch gol returneaza eroare" {
    var ubi = UbiDistributor.init(testing.allocator);
    defer ubi.deinit();

    const addr: [32]u8 = @splat(0x06);
    try ubi.registerBeneficiary(addr, 0);
    // Pool = 0

    try testing.expectError(error.PoolEmpty,
        ubi.distributeEpoch(UBI_EPOCH_BLOCKS));
}
