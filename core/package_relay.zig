//! Package relay (CPFP - Child Pays For Parent) pentru OmniBus mempool.
//!
//! Calculează "ancestor fee rate" pentru un TX: media ponderată a fee/size pe TX-ul
//! curent plus toți părinții lui neconfirmați din mempool. Util la acceptarea TX-urilor
//! cu fee mic care au copii cu fee mare (sau invers).
//!
//! Wrapper subțire — nu stochează TX-urile (mempool e sursa de adevăr), doar le indexează
//! după txid pentru traversare grafului ancestor/descendant.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const TxId = [32]u8;

pub const PackageError = error{
    PackageTooLarge,
    CycleDetected,
    TxNotFound,
};

/// Limita Bitcoin Core default — max 25 TX-uri în ancestor set.
pub const MAX_PACKAGE_SIZE: usize = 25;

pub const TxEntry = struct {
    txid: TxId,
    fee: u64,
    size: u64,
    parents: []const TxId,
    children: []const TxId,

    pub fn feeRate(self: *const TxEntry) u64 {
        if (self.size == 0) return 0;
        return self.fee / self.size;
    }
};

pub const PackageRelay = struct {
    allocator: Allocator,
    transactions: std.AutoHashMap(TxId, TxEntry),

    pub fn init(allocator: Allocator) PackageRelay {
        return .{
            .allocator = allocator,
            .transactions = std.AutoHashMap(TxId, TxEntry).init(allocator),
        };
    }

    pub fn deinit(self: *PackageRelay) void {
        self.transactions.deinit();
    }

    pub fn addTransaction(self: *PackageRelay, entry: TxEntry) !void {
        try self.transactions.put(entry.txid, entry);
    }

    pub fn removeTransaction(self: *PackageRelay, txid: TxId) void {
        _ = self.transactions.remove(txid);
    }

    /// Returnează rata fee/size pentru TX-ul curent + toți strămoșii lui în mempool.
    /// Limita: MAX_PACKAGE_SIZE strămoși (Bitcoin Core compatible).
    pub fn computeAncestorFeeRate(self: *PackageRelay, txid: TxId) !u64 {
        const root = self.transactions.get(txid) orelse return error.TxNotFound;

        var visited = std.AutoHashMap(TxId, void).init(self.allocator);
        defer visited.deinit();

        var queue: std.ArrayList(TxId) = .empty;
        defer queue.deinit(self.allocator);
        try queue.append(self.allocator, root.txid);

        var total_fee: u64 = root.fee;
        var total_size: u64 = root.size;
        var count: usize = 1;
        try visited.put(root.txid, {});

        while (queue.items.len > 0) {
            const current = queue.orderedRemove(0);
            const cur = self.transactions.get(current) orelse continue;
            for (cur.parents) |parent_id| {
                if (visited.contains(parent_id)) continue;
                if (count >= MAX_PACKAGE_SIZE) return error.PackageTooLarge;
                if (self.transactions.get(parent_id)) |parent| {
                    try visited.put(parent_id, {});
                    total_fee += parent.fee;
                    total_size += parent.size;
                    try queue.append(self.allocator, parent_id);
                    count += 1;
                }
            }
        }

        if (total_size == 0) return 0;
        return total_fee / total_size;
    }

    /// True dacă ancestor rate >= min_fee_rate (TX-ul + părinții ar fi acceptat ca pachet).
    pub fn canAcceptPackage(self: *PackageRelay, txid: TxId, min_fee_rate: u64) !bool {
        const ancestor_rate = try self.computeAncestorFeeRate(txid);
        return ancestor_rate >= min_fee_rate;
    }
};

// ============================================================
// Tests
// ============================================================

test "ancestor fee rate combines parent and child" {
    var pr = PackageRelay.init(std.testing.allocator);
    defer pr.deinit();

    const parent_id: TxId = [_]u8{1} ** 32;
    const child_id: TxId = [_]u8{2} ** 32;

    try pr.addTransaction(.{
        .txid = parent_id,
        .fee = 100,
        .size = 100,
        .parents = &[_]TxId{},
        .children = &[_]TxId{child_id},
    });
    try pr.addTransaction(.{
        .txid = child_id,
        .fee = 1000,
        .size = 100,
        .parents = &[_]TxId{parent_id},
        .children = &[_]TxId{},
    });

    // (100+1000) / (100+100) = 5
    const rate = try pr.computeAncestorFeeRate(child_id);
    try std.testing.expectEqual(@as(u64, 5), rate);
}

test "ancestor rate for parent alone equals its own rate" {
    var pr = PackageRelay.init(std.testing.allocator);
    defer pr.deinit();

    const id: TxId = [_]u8{3} ** 32;
    try pr.addTransaction(.{
        .txid = id,
        .fee = 200,
        .size = 50,
        .parents = &[_]TxId{},
        .children = &[_]TxId{},
    });

    try std.testing.expectEqual(@as(u64, 4), try pr.computeAncestorFeeRate(id));
}

test "canAcceptPackage threshold" {
    var pr = PackageRelay.init(std.testing.allocator);
    defer pr.deinit();

    const id: TxId = [_]u8{4} ** 32;
    try pr.addTransaction(.{
        .txid = id,
        .fee = 100,
        .size = 100,
        .parents = &[_]TxId{},
        .children = &[_]TxId{},
    });

    try std.testing.expect(try pr.canAcceptPackage(id, 1));
    try std.testing.expect(!try pr.canAcceptPackage(id, 2));
}

test "TxNotFound when querying unknown txid" {
    var pr = PackageRelay.init(std.testing.allocator);
    defer pr.deinit();

    const missing: TxId = [_]u8{0xFF} ** 32;
    try std.testing.expectError(error.TxNotFound, pr.computeAncestorFeeRate(missing));
}

test "MAX_PACKAGE_SIZE limit enforced" {
    var pr = PackageRelay.init(std.testing.allocator);
    defer pr.deinit();

    // Construim un lanț liniar de 30 TX-uri: i depinde de i-1.
    var chain_ids: [30]TxId = undefined;
    for (0..30) |i| {
        chain_ids[i] = [_]u8{0} ** 32;
        chain_ids[i][0] = @intCast(i);
    }

    // Adăugăm câte unul (folosim slice-uri către array local de o intrare)
    // Mai întâi pe i=0 fără părinți.
    try pr.addTransaction(.{
        .txid = chain_ids[0],
        .fee = 10,
        .size = 10,
        .parents = &[_]TxId{},
        .children = &[_]TxId{},
    });

    // Trebuie să alocăm parents slice ca să trăiască. Folosim arena locală.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    for (1..30) |i| {
        const parents = try a.alloc(TxId, 1);
        parents[0] = chain_ids[i - 1];
        try pr.addTransaction(.{
            .txid = chain_ids[i],
            .fee = 10,
            .size = 10,
            .parents = parents,
            .children = &[_]TxId{},
        });
    }

    try std.testing.expectError(error.PackageTooLarge, pr.computeAncestorFeeRate(chain_ids[29]));
}
