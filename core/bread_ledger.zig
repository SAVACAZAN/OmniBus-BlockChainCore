/// bread_ledger.zig — The Bread Ledger
///
/// Din Whitepaper: "1 OMNI = 1 Paine" — unitate universala de supravietuire
/// Iran = SUA = Romania: o paine costa 1 OMNI oriunde in lume.
///
/// BreadLedger gestioneaza:
///   - Registrul de "paine disponibila" per adresa (UBI primit, necheltuit)
///   - Redemption: user schimba OMNI SAT pe "pain fizica" (voucher QR)
///   - Merchant: inregistrare comercianti acceptanti
///   - Proof-of-Bread: dovada on-chain ca painea a fost livrata
///
/// Ciclul 1: Fiecare user inregistrat primeste 1 paine/zi prin UBI
/// Ciclul 2: Activat cand 1 miliard oameni sunt in Ciclul 1
const std = @import("std");

// --- CONSTANTE ---------------------------------------------------------------

/// 1 paine = 1 OMNI = 1_000_000_000 SAT
pub const BREAD_PRICE_SAT: u64 = 1_000_000_000;

/// Voucher expira in 30 zile = 30 * 86400 blocuri
pub const VOUCHER_EXPIRY_BLOCKS: u64 = 30 * 86_400;

// --- TIPURI ------------------------------------------------------------------

pub const BreadVoucherStatus = enum(u8) {
    pending   = 0,   // emis, neredeemed
    redeemed  = 1,   // redeemed la un merchant
    expired   = 2,   // expirat nefolosit
};

/// Voucher de paine — emis cand user-ul initiaza redemption
pub const BreadVoucher = struct {
    voucher_id:   u64,
    owner:        [32]u8,
    merchant:     [32]u8,   // merchant la care va fi redeemed
    amount_sat:   u64,      // in SAT (multiplu de BREAD_PRICE_SAT)
    bread_count:  u64,      // cate paini (amount_sat / BREAD_PRICE_SAT)
    issued_block: u64,
    redeemed_block: u64,
    status:       BreadVoucherStatus,

    /// Hash QR pentru redemption fizic (SHA256 al voucher_id + owner)
    qr_hash:      [32]u8,

    pub fn isExpired(self: *const BreadVoucher, current_block: u64) bool {
        return current_block > self.issued_block + VOUCHER_EXPIRY_BLOCKS;
    }
};

/// Merchant inregistrat — accepta voucher-e de paine
pub const BreadMerchant = struct {
    merchant_addr: [32]u8,
    name:          [64]u8,
    name_len:      u8,
    country:       [3]u8,    // ISO 3166-1 alpha-3 (ROU, USA, IRN)
    registered_block: u64,
    total_redeemed_sat: u64,
    active:        bool,

    pub fn countryCode(self: *const BreadMerchant) []const u8 {
        return self.country[0..3];
    }
};

/// Proof-of-Bread: dovada on-chain ca painea a fost livrata
pub const BreadDelivery = struct {
    voucher_id:     u64,
    merchant_addr:  [32]u8,
    /// Hash-ul imaginii sau semnaturii de receptie
    proof_hash:     [32]u8,
    delivery_block: u64,
};

// --- BREAD LEDGER ------------------------------------------------------------

pub const BreadLedger = struct {
    allocator:  std.mem.Allocator,
    vouchers:   std.array_list.Managed(BreadVoucher),
    merchants:  std.array_list.Managed(BreadMerchant),
    deliveries: std.array_list.Managed(BreadDelivery),
    next_voucher_id: u64,

    /// Total SAT redeemed (valoarea painilor consumate)
    total_redeemed_sat: u64,

    /// Total paini emise (vouchers)
    total_bread_issued: u64,

    pub fn init(allocator: std.mem.Allocator) BreadLedger {
        return BreadLedger{
            .allocator          = allocator,
            .vouchers           = std.array_list.Managed(BreadVoucher).init(allocator),
            .merchants          = std.array_list.Managed(BreadMerchant).init(allocator),
            .deliveries         = std.array_list.Managed(BreadDelivery).init(allocator),
            .next_voucher_id    = 1,
            .total_redeemed_sat = 0,
            .total_bread_issued = 0,
        };
    }

    pub fn deinit(self: *BreadLedger) void {
        self.vouchers.deinit();
        self.merchants.deinit();
        self.deliveries.deinit();
    }

    /// Inregistreaza un merchant
    pub fn registerMerchant(self: *BreadLedger,
                             merchant_addr: [32]u8,
                             name:          []const u8,
                             country:       [3]u8,
                             current_block: u64) !void {
        // Verifica duplicat
        for (self.merchants.items) |m| {
            if (std.mem.eql(u8, &m.merchant_addr, &merchant_addr))
                return error.MerchantAlreadyRegistered;
        }

        var name_buf: [64]u8 = @splat(0);
        const n = @min(name.len, 64);
        @memcpy(name_buf[0..n], name[0..n]);

        try self.merchants.append(BreadMerchant{
            .merchant_addr      = merchant_addr,
            .name               = name_buf,
            .name_len           = @intCast(n),
            .country            = country,
            .registered_block   = current_block,
            .total_redeemed_sat = 0,
            .active             = true,
        });

        std.debug.print("[BREAD] Merchant inregistrat: {s} ({s})\n",
            .{ name_buf[0..n], &country });
    }

    /// Emite un voucher de paine (user cheltuie SAT din UBI balance)
    pub fn issueVoucher(self: *BreadLedger,
                         owner:         [32]u8,
                         merchant_addr: [32]u8,
                         amount_sat:    u64,
                         current_block: u64) !u64 {
        if (amount_sat < BREAD_PRICE_SAT) return error.AmountTooSmall;
        if (amount_sat % BREAD_PRICE_SAT != 0) return error.AmountNotMultipleOfBreadPrice;

        // Verifica merchant valid
        var merchant_found = false;
        for (self.merchants.items) |m| {
            if (m.active and std.mem.eql(u8, &m.merchant_addr, &merchant_addr)) {
                merchant_found = true;
                break;
            }
        }
        if (!merchant_found) return error.MerchantNotFound;

        // Calculeaza QR hash: SHA256(voucher_id || owner)
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        var id_buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &id_buf, self.next_voucher_id, .little);
        hasher.update(&id_buf);
        hasher.update(&owner);
        var qr_hash: [32]u8 = undefined;
        hasher.final(&qr_hash);

        const bread_count = amount_sat / BREAD_PRICE_SAT;
        const voucher = BreadVoucher{
            .voucher_id    = self.next_voucher_id,
            .owner         = owner,
            .merchant      = merchant_addr,
            .amount_sat    = amount_sat,
            .bread_count   = bread_count,
            .issued_block  = current_block,
            .redeemed_block = 0,
            .status        = .pending,
            .qr_hash       = qr_hash,
        };

        try self.vouchers.append(voucher);
        self.next_voucher_id += 1;
        self.total_bread_issued += bread_count;

        std.debug.print("[BREAD] Voucher #{d}: {d} paini | owner -> merchant\n",
            .{ voucher.voucher_id, bread_count });

        return voucher.voucher_id;
    }

    /// Merchant confirma redemption-ul (scanare QR + livrare)
    pub fn redeemVoucher(self: *BreadLedger,
                          voucher_id:   u64,
                          merchant_addr: [32]u8,
                          proof_hash:   [32]u8,
                          current_block: u64) !void {
        const v = try self.findVoucher(voucher_id);

        if (v.status != .pending) return error.VoucherNotPending;
        if (!std.mem.eql(u8, &v.merchant, &merchant_addr)) return error.WrongMerchant;
        if (v.isExpired(current_block)) {
            v.status = .expired;
            return error.VoucherExpired;
        }

        v.status         = .redeemed;
        v.redeemed_block = current_block;
        self.total_redeemed_sat +|= v.amount_sat;

        // Actualizeaza statistici merchant
        for (self.merchants.items) |*m| {
            if (std.mem.eql(u8, &m.merchant_addr, &merchant_addr)) {
                m.total_redeemed_sat +|= v.amount_sat;
                break;
            }
        }

        // Inregistreaza proof-of-delivery
        try self.deliveries.append(BreadDelivery{
            .voucher_id     = voucher_id,
            .merchant_addr  = merchant_addr,
            .proof_hash     = proof_hash,
            .delivery_block = current_block,
        });

        std.debug.print("[BREAD] Voucher #{d} REDEEMED: {d} paini livrate\n",
            .{ voucher_id, v.bread_count });
    }

    pub fn findVoucher(self: *BreadLedger, voucher_id: u64) !*BreadVoucher {
        for (self.vouchers.items) |*v| {
            if (v.voucher_id == voucher_id) return v;
        }
        return error.VoucherNotFound;
    }

    pub fn pendingCount(self: *const BreadLedger) u64 {
        var n: u64 = 0;
        for (self.vouchers.items) |v| {
            if (v.status == .pending) n += 1;
        }
        return n;
    }

    pub fn printStatus(self: *const BreadLedger) void {
        std.debug.print("[BREAD] Vouchers: {d} issued | {d} pending | {d} SAT redeemed\n",
            .{ self.total_bread_issued, self.pendingCount(), self.total_redeemed_sat });
    }
};

// --- TESTE -------------------------------------------------------------------
const testing = std.testing;

const OWNER:    [32]u8 = @splat(0xAA);
const MERCHANT: [32]u8 = @splat(0xBB);
const PROOF:    [32]u8 = @splat(0xCC);

fn setupLedger(allocator: std.mem.Allocator) !BreadLedger {
    var ledger = BreadLedger.init(allocator);
    try ledger.registerMerchant(MERCHANT, "Brutaria Omni", "ROU"[0..3].*, 100);
    return ledger;
}

test "BreadVoucher — isExpired dupa 30 zile" {
    const v = BreadVoucher{
        .voucher_id = 1, .owner = OWNER, .merchant = MERCHANT,
        .amount_sat = BREAD_PRICE_SAT, .bread_count = 1,
        .issued_block = 1000, .redeemed_block = 0,
        .status = .pending, .qr_hash = @splat(0),
    };
    const expiry = 1000 + VOUCHER_EXPIRY_BLOCKS;
    try testing.expect(!v.isExpired(expiry - 1));
    try testing.expect(v.isExpired(expiry + 1));
}

test "BreadLedger — registerMerchant ok" {
    var ledger = BreadLedger.init(testing.allocator);
    defer ledger.deinit();
    try ledger.registerMerchant(MERCHANT, "Brutaria Test", "ROU"[0..3].*, 0);
    try testing.expectEqual(@as(usize, 1), ledger.merchants.items.len);
}

test "BreadLedger — duplicate merchant returneaza eroare" {
    var ledger = BreadLedger.init(testing.allocator);
    defer ledger.deinit();
    try ledger.registerMerchant(MERCHANT, "Brutaria Test", "ROU"[0..3].*, 0);
    try testing.expectError(error.MerchantAlreadyRegistered,
        ledger.registerMerchant(MERCHANT, "Alta Brutarie", "ROU"[0..3].*, 1));
}

test "BreadLedger — issueVoucher ok" {
    var ledger = try setupLedger(testing.allocator);
    defer ledger.deinit();

    const vid = try ledger.issueVoucher(OWNER, MERCHANT, BREAD_PRICE_SAT, 200);
    try testing.expectEqual(@as(u64, 1), vid);
    try testing.expectEqual(@as(u64, 1), ledger.total_bread_issued);
}

test "BreadLedger — issueVoucher suma prea mica returneaza eroare" {
    var ledger = try setupLedger(testing.allocator);
    defer ledger.deinit();

    try testing.expectError(error.AmountTooSmall,
        ledger.issueVoucher(OWNER, MERCHANT, 100, 200));
}

test "BreadLedger — issueVoucher suma non-multiplu returneaza eroare" {
    var ledger = try setupLedger(testing.allocator);
    defer ledger.deinit();

    try testing.expectError(error.AmountNotMultipleOfBreadPrice,
        ledger.issueVoucher(OWNER, MERCHANT, BREAD_PRICE_SAT + 1, 200));
}

test "BreadLedger — issueVoucher merchant invalid returneaza eroare" {
    var ledger = try setupLedger(testing.allocator);
    defer ledger.deinit();

    const fake_merchant: [32]u8 = @splat(0xFF);
    try testing.expectError(error.MerchantNotFound,
        ledger.issueVoucher(OWNER, fake_merchant, BREAD_PRICE_SAT, 200));
}

test "BreadLedger — redeemVoucher ok" {
    var ledger = try setupLedger(testing.allocator);
    defer ledger.deinit();

    const vid = try ledger.issueVoucher(OWNER, MERCHANT, BREAD_PRICE_SAT * 3, 200);
    try ledger.redeemVoucher(vid, MERCHANT, PROOF, 201);

    const v = try ledger.findVoucher(vid);
    try testing.expectEqual(BreadVoucherStatus.redeemed, v.status);
    try testing.expectEqual(@as(u64, BREAD_PRICE_SAT * 3), ledger.total_redeemed_sat);
    try testing.expectEqual(@as(u64, 1), ledger.deliveries.items.len);
}

test "BreadLedger — redeem de doua ori returneaza eroare" {
    var ledger = try setupLedger(testing.allocator);
    defer ledger.deinit();

    const vid = try ledger.issueVoucher(OWNER, MERCHANT, BREAD_PRICE_SAT, 200);
    try ledger.redeemVoucher(vid, MERCHANT, PROOF, 201);
    try testing.expectError(error.VoucherNotPending,
        ledger.redeemVoucher(vid, MERCHANT, PROOF, 202));
}

test "BreadLedger — redeem merchant gresit returneaza eroare" {
    var ledger = try setupLedger(testing.allocator);
    defer ledger.deinit();

    const vid = try ledger.issueVoucher(OWNER, MERCHANT, BREAD_PRICE_SAT, 200);
    const alt_merchant: [32]u8 = @splat(0xDD);
    try testing.expectError(error.WrongMerchant,
        ledger.redeemVoucher(vid, alt_merchant, PROOF, 201));
}

test "BreadLedger — pendingCount scade dupa redeem" {
    var ledger = try setupLedger(testing.allocator);
    defer ledger.deinit();

    _ = try ledger.issueVoucher(OWNER, MERCHANT, BREAD_PRICE_SAT, 200);
    _ = try ledger.issueVoucher(OWNER, MERCHANT, BREAD_PRICE_SAT, 200);
    try testing.expectEqual(@as(u64, 2), ledger.pendingCount());

    const vid = try ledger.issueVoucher(OWNER, MERCHANT, BREAD_PRICE_SAT, 200);
    try ledger.redeemVoucher(vid, MERCHANT, PROOF, 201);
    try testing.expectEqual(@as(u64, 2), ledger.pendingCount());
}
